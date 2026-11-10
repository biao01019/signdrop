import Foundation

/// 开发者后台（Developer Services）客户端。
///
/// 会话需要三样东西：`X-Apple-I-Identity-Id`（adsid）、`X-Apple-GS-Token`（登录换来的令牌）、
/// `X-Apple-ID-Session-Id`，再叠加 anisette 的设备指纹头。
///
/// 和登录一样属于逆向接口，所有 action 名集中在 `Action` 里，苹果改地址只需改一处。
public final class DeveloperPortal {

    public struct Team: Sendable {
        public let teamID: String
        public let name: String
        public let type: String
    }

    public enum PortalError: LocalizedError {
        case http(Int, String)
        case unparsable(String)
        case business(String)
        case emptyCertificate
        case emptyProfile

        public var errorDescription: String? {
            switch self {
            case .http(let code, let detail):
                return "开发者接口返回 HTTP \(code)：\(detail)"
            case .unparsable(let action):
                return "开发者接口 \(action) 返回内容无法解析，可能是会话失效被重定向到登录页"
            case .business(let message):
                return "开发者接口失败：\(message)"
            case .emptyCertificate:
                return "苹果没有返回证书内容，可能是证书数量已达上限（免费账号 2 个）"
            case .emptyProfile:
                return "苹果没有返回描述文件，检查设备是否已注册"
            }
        }
    }

    private enum Action {
        static let base = "https://developerservices2.apple.apple.com/services/QH65B2/"
        static let listTeams = "ios/listTeams.action"
        static let addDevice = "ios/addDevice.action"
        static let listDevices = "ios/listDevices.action"
        static let submitCSR = "ios/submitDevelopmentCSR.action"
        static let revokeCert = "ios/revokeDevelopmentCert.action"
        static let addAppID = "ios/addAppId.action"
        static let listAppIDs = "ios/listAppIds.action"
        static let downloadProfile = "ios/downloadTeamProvisioningProfile.action"
        static let listProfiles = "ios/listProvisioningProfiles.action"
        static let deleteProfile = "ios/deleteProvisioningProfile.action"
    }

    /// 开发者后台的固定 clientId。
    private static let clientID = "XABBG36SBA"

    private let client: HTTPClient
    private let anisetteHeaders: [String: String]
    private let adsid: String
    private let token: String
    private let sessionID: String

    public init(
        client: HTTPClient,
        anisetteHeaders: [String: String],
        adsid: String,
        token: String,
        sessionID: String
    ) {
        self.client = client
        self.anisetteHeaders = anisetteHeaders
        self.adsid = adsid
        self.token = token
        self.sessionID = sessionID
    }

    // MARK: - 底层调用

    private func headers() -> [String: String] {
        var headers = anisetteHeaders
        headers["X-Apple-I-Identity-Id"] = adsid
        headers["X-Apple-GS-Token"] = token
        headers["X-Apple-ID-Session-Id"] = sessionID
        headers["Accept"] = "text/x-xml-plist"
        return headers
    }

    private func call(_ action: String, params: [String: String] = [:]) async throws -> [String: Any] {
        var values = params
        values["clientId"] = Self.clientID

        let response = try await client.post(
            Action.base + action,
            form: values,
            headers: headers()
        )
        guard response.status == 200 else {
            throw PortalError.http(response.status, String(response.text.prefix(300)))
        }
        guard let data = response.plist() else {
            throw PortalError.unparsable(action)
        }

        if let code = data["resultCode"] as? Int, code != 0 {
            let message = (data["resultString"] as? String)
                ?? (data["userString"] as? String)
                ?? "\(code)"
            throw PortalError.business(message)
        }
        return data
    }

    // MARK: - 业务

    public func listTeams() async throws -> [Team] {
        let data = try await call(Action.listTeams)
        let teams = (data["teams"] as? [[String: Any]]) ?? []
        return teams.map {
            Team(
                teamID: "\($0["teamId"] ?? "")",
                name: "\($0["name"] ?? "")",
                type: "\($0["type"] ?? "")"
            )
        }
    }

    /// 把设备加进账号。
    /// 免费账号一年 100 个名额，`name` 写清楚设备名便于以后回收。
    @discardableResult
    public func registerDevice(udid: String, name: String, teamID: String) async throws -> [String: Any] {
        let suffix = String(udid.suffix(6))
        let data = try await call(
            Action.addDevice,
            params: [
                "devices": udid,
                "name": name.isEmpty ? "device-\(suffix)" : name,
                "teamId": teamID
            ]
        )
        return (data["device"] as? [String: Any]) ?? [:]
    }

    public func listDevices(teamID: String) async throws -> [[String: Any]] {
        let data = try await call(Action.listDevices, params: ["teamId": teamID])
        return (data["devices"] as? [[String: Any]]) ?? []
    }

    /// 提交 CSR，返回 (证书 DER, 序列号)。
    public func submitCSR(_ der: Data, machineName: String, teamID: String) async throws -> (Data, String) {
        let data = try await call(
            Action.submitCSR,
            params: [
                "csrContent": B64.encode(der),
                "machineId": UUID().uuidString.uppercased(),
                "machineName": machineName,
                "teamId": teamID
            ]
        )
        guard let certificate = data["certificate"] as? [String: Any] else {
            throw PortalError.emptyCertificate
        }

        if let raw = certificate["certContent"] as? Data {
            return (raw, "\(certificate["serialNum"] ?? "")")
        }
        if let text = certificate["certContent"] as? String, let raw = B64.decode(text) {
            return (raw, "\(certificate["serialNum"] ?? "")")
        }
        throw PortalError.emptyCertificate
    }

    /// 注册 App ID。已存在时苹果会报错，这里当作成功处理（返回空串）。
    @discardableResult
    public func addAppID(identifier: String, name: String, teamID: String) async throws -> String {
        do {
            let data = try await call(
                Action.addAppID,
                params: [
                    "identifier": identifier,
                    "name": name,
                    "teamId": teamID,
                    "features": "{\"push\":false,\"gameCenter\":false,\"inAppPurchase\":false,\"icloud\":false}"
                ]
            )
            return "\((data["appId"] as? [String: Any])?["appIdId"] ?? "")"
        } catch let error as PortalError {
            let message = error.localizedDescription.lowercased()
            if message.contains("already") || message.contains("duplicate") || message.contains("exist") {
                return ""
            }
            throw error
        }
    }

    /// 列出账号里已注册的 App ID。用于 `addAppID` 报"已存在"时反查它的 appIdId。
    public func listAppIDs(teamID: String) async throws -> [[String: Any]] {
        let data = try await call(Action.listAppIDs, params: ["teamId": teamID])
        return (data["appIds"] as? [[String: Any]]) ?? []
    }

    /// 列出已有描述文件。免费账号只有 2 张证书、每 7 天 10 个 App ID，
    /// 重签时应当复用而不是重新申请。
    public func listProfiles(teamID: String) async throws -> [[String: Any]] {
        let data = try await call(Action.listProfiles, params: ["teamId": teamID])
        return (data["provisioningProfiles"] as? [[String: Any]]) ?? []
    }

    /// 下载描述文件。必须先把设备 UDID 注册进账号，否则苹果会拒绝。
    public func downloadProfile(teamID: String, appIDID: String) async throws -> Data {
        let data = try await call(
            Action.downloadProfile,
            params: ["teamId": teamID, "appIdId": appIDID]
        )
        if let raw = data["provisioningProfile"] as? Data {
            return raw
        }
        if let text = data["provisioningProfile"] as? String, let raw = B64.decode(text) {
            return raw
        }
        throw PortalError.emptyProfile
    }
}
