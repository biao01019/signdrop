import Foundation

/// Apple ID 登录状态机。
///
/// 三步：账号 → 密码（SRP 握手）→ 验证码（账号开了双重认证才需要）。
/// 密码不参与任何明文传输，SRP 协商出的密钥只在本次会话里活着。
///
/// ⚠️ 走的是苹果未公开的私有接口（GrandSlam + idmsa），参数是社区逆向出来的。
/// 苹果改动后这里会失效，届时需要按新的抓包结果调整 `Endpoint` 里的地址。
/// 密码学部分（SRP）是可靠的，已用 RFC 5054 官方向量验证。
public final class AppleIDAuth {

    public enum Stage: String, Sendable {
        case idle
        case password
        case twoFactor
        case authenticated
    }

    public struct State: Sendable {
        public var appleID: String = ""
        public var displayName: String = ""
        public var adsid: String = ""
        public var sessionID: String = ""
        public var scnt: String = ""
        public var token: String = ""
        public var stage: Stage = .idle
    }

    public enum AuthError: LocalizedError {
        case notStarted
        case passwordRejected(String)
        case accountLocked(String)
        case rateLimited(String)
        case unsupportedChallenge(String)
        case notAuthenticated
        case missingToken(String)

        public var errorDescription: String? {
            switch self {
            case .notStarted:
                return "请先提交 Apple ID"
            case .passwordRejected(let detail):
                return "账号或密码不正确。\(detail)"
            case .accountLocked(let detail):
                return "账号被限制，可能需要先在浏览器登录一次解锁。\(detail)"
            case .rateLimited(let detail):
                return "请求过于频繁，苹果限流了，等几分钟再试。\(detail)"
            case .unsupportedChallenge(let detail):
                return "登录需要额外验证（\(detail)），当前版本还不支持这种方式"
            case .notAuthenticated:
                return "账号尚未完成登录"
            case .missingToken(let detail):
                return "没有拿到开发者令牌：\(detail)"
            }
        }
    }

    private enum Endpoint {
        static let gsa = "https://gsa.apple.com"
        static let idmsa = "https://idmsa.apple.com/appleauth"
        static var bootstrap: String { "\(gsa)/gm/bootstrap/init" }
        static var signInInit: String { "\(idmsa)/auth/signin/init" }
        static var signInComplete: String { "\(idmsa)/auth/signin/complete?isRememberMeEnabled=true" }
        static var verifyCode: String { "\(idmsa)/auth/verify/trusteddevice/securitycode" }
        static var trust: String { "\(idmsa)/auth/2sv/trust" }
        static var appToken: String { "\(gsa)/gm/apptokens" }
    }

    /// 网页端 iCloud / 开发者后台使用的固定 widget key（社区通用值）。
    private static let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
    private static let oauthClient = "com.apple.gs.appleid.auth"

    private let anisette: AnisetteClient
    private let client: HTTPClient
    private var anisetteHeaders: [String: String] = [:]
    private var srp: SRPClient?
    private var srpPassword: String = ""
    private var cValue: String = ""

    public private(set) var state = State()

    public init(anisette: AnisetteClient, client: HTTPClient = HTTPClient()) {
        self.anisette = anisette
        self.client = client
    }

    // MARK: - 第一步：账号

    public func start(appleID: String) async throws -> State {
        let trimmed = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        state = State(appleID: trimmed, stage: .password)
        anisetteHeaders = try await anisette.headers()

        // bootstrap 把设备指纹绑定到这次会话，失败不致命，继续走
        if let response = try? await client.post(
            Endpoint.bootstrap,
            json: ["clientInfo": ["bootstrap": true, "cfu": true, "cfu2": true]],
            headers: baseHeaders()
        ) {
            absorb(response)
        }
        return state
    }

    // MARK: - 第二步：密码

    /// - Parameter hashPassword: 先用 s2k_fo（密码先做一次 SHA-256）尝试；若苹果只接受
    ///   原始口令会返回 401，此时用 `hashPassword: false` 重试一次即可。
    public func submitPassword(_ password: String, hashPassword: Bool = true) async throws -> State {
        guard state.stage != .idle, !state.appleID.isEmpty else {
            throw AuthError.notStarted
        }

        let derived = hashPassword ? Hash.sha256(Data(password.utf8)).hexString : password
        let srpClient = SRPClient(username: state.appleID, password: derived)
        self.srp = srpClient
        self.srpPassword = derived

        let initResponse = try await client.post(
            Endpoint.signInInit,
            json: [
                "a": srpClient.publicABase64,
                "accountName": state.appleID,
                "protocols": ["s2k", "s2k_fo"]
            ],
            headers: baseHeaders()
        )
        absorb(initResponse)

        guard initResponse.status == 200 else {
            throw describe(initResponse, prefix: "密码预交换失败")
        }

        let payload = initResponse.json()
        guard let saltText = payload["salt"] as? String,
              let bText = payload["b"] as? String,
              let salt = B64.decode(saltText),
              let bValue = B64.decode(bText) else {
            throw AuthError.passwordRejected("苹果没有返回 salt / B，接口结构可能已变更")
        }
        cValue = (payload["c"] as? String) ?? ""

        try srpClient.setServerValues(salt: salt, serverPublicB: bValue)

        let complete = try await client.post(
            Endpoint.signInComplete,
            json: [
                "accountName": state.appleID,
                "c": cValue,
                "m1": srpClient.proofBase64,
                "m2": B64.encode(try srpClient.expectedServerProof()),
                "rememberMe": true
            ],
            headers: baseHeaders()
        )
        absorb(complete)

        if complete.status == 200 {
            state.stage = .authenticated
            readIdentity(complete.json())
            return state
        }

        if complete.status == 409 || complete.status == 403 {
            let authType = ((complete.json()["authType"] as? String) ?? "").lowercased()
            if ["hsa2", "hsa", "sa", "trusteddevice"].contains(authType) {
                state.stage = .twoFactor
                return state
            }
            throw AuthError.unsupportedChallenge(authType.isEmpty ? "\(complete.status)" : authType)
        }

        throw describe(complete, prefix: "密码校验失败")
    }

    // MARK: - 第三步：验证码

    public func submitCode(_ code: String) async throws -> State {
        guard state.stage == .twoFactor else {
            throw AuthError.unsupportedChallenge("当前不在等待验证码的阶段")
        }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await client.post(
            Endpoint.verifyCode,
            json: ["securityCode": ["code": trimmed]],
            headers: baseHeaders()
        )
        absorb(response)
        guard response.status == 200 || response.status == 204 else {
            throw describe(response, prefix: "验证码校验失败")
        }

        let trust = try await client.get(Endpoint.trust, headers: baseHeaders())
        absorb(trust)
        guard trust.status == 200 || trust.status == 204 else {
            throw describe(trust, prefix: "建立信任会话失败")
        }

        state.stage = .authenticated
        readIdentity(trust.json())
        return state
    }

    // MARK: - 第四步：换开发者令牌

    public func fetchToken() async throws -> String {
        guard state.stage == .authenticated else {
            throw AuthError.notAuthenticated
        }

        let checksum = B64.encode(Hash.sha256(Data(cValue.utf8)))
        let key = B64.encode(srp?.sessionKey ?? Data())

        let response = try await client.post(
            Endpoint.appToken,
            json: [
                "app": [Self.oauthClient],
                "c": cValue,
                "checksum": checksum,
                "key": key,
                "gp": B64.encode(Data(repeating: 0x30, count: 32))
            ],
            headers: baseHeaders()
        )

        guard response.status == 200 else {
            throw describe(response, prefix: "获取开发者令牌失败")
        }

        let payload = response.json()
        let tokens = payload["tokens"] as? [String: Any]
        let entry = tokens?[Self.oauthClient] as? [String: Any]
        guard let token = entry?["token"] as? String, !token.isEmpty else {
            throw AuthError.missingToken("响应结构可能已变更")
        }
        state.token = token
        return token
    }

    // MARK: - 内部

    private func baseHeaders() -> [String: String] {
        var headers = anisetteHeaders
        headers["Accept"] = "application/json"
        headers["X-Requested-With"] = "XMLHttpRequest"
        headers["X-Apple-Widget-Key"] = Self.widgetKey
        if !state.sessionID.isEmpty {
            headers["X-Apple-ID-Session-Id"] = state.sessionID
        }
        if !state.scnt.isEmpty {
            headers["scnt"] = state.scnt
        }
        return headers
    }

    private func absorb(_ response: HTTPResponse) {
        if let value = response.header("x-apple-id-session-id"), !value.isEmpty {
            state.sessionID = value
        }
        if let value = response.header("scnt"), !value.isEmpty {
            state.scnt = value
        }
    }

    private func readIdentity(_ payload: [String: Any]) {
        if let adsid = payload["adsid"] as? String {
            state.adsid = adsid
        } else if let dsid = payload["dsid"] as? String {
            state.adsid = dsid
        }
        if let name = payload["displayName"] as? String {
            state.displayName = name
        } else if let account = payload["accountName"] as? String {
            state.displayName = account
        }
    }

    private func describe(_ response: HTTPResponse, prefix: String) -> Error {
        let body = response.json()
        let detail: String
        if let errors = body["serviceErrors"] as? [[String: Any]],
           let first = errors.first,
           let message = first["message"] as? String {
            detail = message
        } else if let message = body["errorMessage"] as? String {
            detail = message
        } else if let message = body["message"] as? String {
            detail = message
        } else {
            detail = String(response.text.prefix(200))
        }

        switch response.status {
        case 401:
            return AuthError.passwordRejected(detail.isEmpty ? "" : "（\(detail)）")
        case 403:
            return AuthError.accountLocked(detail.isEmpty ? "" : "（\(detail)）")
        case 429:
            return AuthError.rateLimited(detail.isEmpty ? "" : "（\(detail)）")
        default:
            return AuthError.passwordRejected("HTTP \(response.status) — \(detail)")
        }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
