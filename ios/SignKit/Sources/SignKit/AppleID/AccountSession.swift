import Foundation

/// 把「输 Apple ID」到「拿到能签名的证书」这一整条链收成一个门面。
///
/// 调用方只需要关心两件事：登录、拿证书。中间的门户调用、CSR、设备注册都在这里。
public final class AccountSession {

    /// 一次可用于签名的完整身份。
    public struct ProvisionedIdentity {
        public let certificate: Data      // DER
        public let profile: Data          // .mobileprovision
        public let teamID: String
        public let commonName: String
        public let keyTag: String         // Keychain 里的私钥标签
        public let bundleID: String
        public let expiresAt: Date
        public let deviceCount: Int
    }

    public enum SessionError: LocalizedError {
        case noTeam
        case noAppID(String)
        case certificateMismatch

        public var errorDescription: String? {
            switch self {
            case .noTeam:
                return "这个 Apple ID 下没有可用的开发团队，请先在 Xcode 或开发者网站同意协议"
            case .noAppID(let bundleID):
                return "无法为 \(bundleID) 找到或创建 App ID，可能是本周名额已用完（免费账号每周 10 个）"
            case .certificateMismatch:
                return "证书与描述文件不匹配，请重新获取"
            }
        }
    }

    public private(set) var auth: AppleIDAuth
    private let anisette: AnisetteClient
    private let client: HTTPClient
    private var portal: DeveloperPortal?
    private var anisetteHeaders: [String: String] = [:]

    public init(anisette: AnisetteClient = AnisetteClient(), client: HTTPClient = HTTPClient()) {
        self.anisette = anisette
        self.client = client
        self.auth = AppleIDAuth(anisette: anisette, client: client)
    }

    public var appleID: String { auth.state.appleID }
    public var isAuthenticated: Bool { auth.state.stage == .authenticated }

    // MARK: - 登录

    /// 完整登录。账号开了双重认证时，用 `codeProvider` 取验证码。
    public func signIn(
        appleID: String,
        password: String,
        codeProvider: (() async throws -> String)? = nil
    ) async throws {
        _ = try await auth.start(appleID: appleID)

        var state: AppleIDAuth.State
        do {
            state = try await auth.submitPassword(password)
        } catch {
            // 部分账号只接受 s2k（原始口令），用未哈希的密码再试一次
            state = try await auth.submitPassword(password, hashPassword: false)
        }

        if state.stage == .twoFactor {
            guard let codeProvider = codeProvider else {
                throw AppleIDAuth.AuthError.unsupportedChallenge("需要双重认证验证码")
            }
            let code = try await codeProvider()
            _ = try await auth.submitCode(code)
        }

        _ = try await auth.fetchToken()
        anisetteHeaders = try await anisette.headers()
        portal = DeveloperPortal(
            client: client,
            anisetteHeaders: anisetteHeaders,
            adsid: auth.state.adsid,
            token: auth.state.token,
            sessionID: auth.state.sessionID
        )
    }

    // MARK: - 取证书

    /// 申请一张新的开发证书 + 对应描述文件。
    ///
    /// - Parameters:
    ///   - udid: 目标设备的真实 UDID。描述文件里必须有它，签出来的包才能装上。
    ///   - bundleID: 要签的 App 的 Bundle ID，会顺带注册 App ID。
    public func provision(
        udid: String,
        deviceName: String,
        bundleID: String
    ) async throws -> ProvisionedIdentity {
        guard let portal = portal else {
            throw AppleIDAuth.AuthError.notAuthenticated
        }

        let teams = try await portal.listTeams()
        guard let team = teams.first else { throw SessionError.noTeam }

        // 设备注册：已存在就不重复加，否则会白占名额
        let existing = try await portal.listDevices(teamID: team.teamID)
        let registered = existing.contains { device in
            let value = "\(device["deviceNumber"] ?? "")"
            return value.caseInsensitiveCompare(udid) == .orderedSame
        }
        if !registered {
            try await portal.registerDevice(udid: udid, name: deviceName, teamID: team.teamID)
        }

        // 密钥 + CSR
        let keyTag = "signdrop.key.\(team.teamID)"
        let privateKey = try AppleCertificate.generateKeyPair(tag: keyTag)
        let csr = try AppleCertificate.makeCSR(
            privateKey: privateKey,
            commonName: "Signdrop \(team.teamID)",
            email: auth.state.displayName.isEmpty ? nil : auth.state.displayName
        )
        let (certificate, _) = try await portal.submitCSR(
            csr,
            machineName: "Signdrop",
            teamID: team.teamID
        )

        // App ID
        var appIDID = try await portal.addAppID(
            identifier: bundleID,
            name: bundleID,
            teamID: team.teamID
        )
        if appIDID.isEmpty {
            appIDID = try await findAppID(portal: portal, teamID: team.teamID, bundleID: bundleID)
        }
        guard !appIDID.isEmpty else {
            throw SessionError.noAppID(bundleID)
        }

        let profile = try await portal.downloadProfile(teamID: team.teamID, appIDID: appIDID)
        let parsed = try ProvisioningProfile(data: profile)

        return ProvisionedIdentity(
            certificate: certificate,
            profile: profile,
            teamID: team.teamID,
            commonName: (try? AppleCertificate.parseCertificate(certificate).summary.commonName) ?? "",
            keyTag: keyTag,
            bundleID: bundleID,
            expiresAt: parsed.expirationDate,
            deviceCount: parsed.provisionedDevices.count
        )
    }

    /// 列出账号里已有的证书/描述文件，用于"重签"时不重复申请（免费账号只有 2 张证书）。
    public func existingProfiles(teamID: String) async throws -> [[String: Any]] {
        guard let portal = portal else { return [] }
        let data = try await portalListProfiles(portal: portal, teamID: teamID)
        return data
    }

    // MARK: - 内部

    private func findAppID(
        portal: DeveloperPortal,
        teamID: String,
        bundleID: String
    ) async throws -> String {
        let candidates = try await portal.listAppIDs(teamID: teamID)
        for item in candidates {
            let identifier = "\(item["identifier"] ?? "")"
            let appIDID = "\(item["appIdId"] ?? "")"
            // 苹果返回的 identifier 带团队前缀与通配符，做一次宽松匹配
            if identifier == bundleID
                || identifier.hasSuffix(".\(bundleID)")
                || identifier.contains(bundleID) {
                return appIDID
            }
        }
        return ""
    }

    private func portalListProfiles(portal: DeveloperPortal, teamID: String) async throws -> [[String: Any]] {
        try await portal.listProfiles(teamID: teamID)
    }
}
