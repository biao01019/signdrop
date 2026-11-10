import Foundation

/// Anisette：给苹果接口补上设备指纹头。
///
/// 苹果的认证接口要求请求头里带 `X-Apple-I-MD` 这一组值，它们原本由 iOS 设备上的
/// AOSKit 用苹果私有的 OTP 算法生成。App 在沙盒里读不到 AOSKit，所以要借助
/// anisette 服务代算。
///
/// 传输边界要讲清楚：发给 anisette 服务的只有**设备指纹**（一个随机生成的
/// machine id 和本机时间），不含 Apple ID、不含密码。账号密码走的是 SRP，
/// 密码从不离开本机。
///
/// 自建服务（推荐，Docker 一条命令）：
///     docker run -d -p 6969:6969 dadoum/anisette-v3-server
public final class AnisetteClient {

    public enum AnisetteError: LocalizedError {
        case badResponse(String)
        case missingProvisioning
        case serverError(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let detail):
                return "anisette 服务返回了无法识别的内容：\(detail)"
            case .missingProvisioning:
                return "anisette 服务没有返回 X-Apple-I-MD，服务可能版本过旧或已失效"
            case .serverError(let detail):
                return "anisette 服务报错：\(detail)"
            }
        }
    }

    /// 社区公共实例。正式使用建议换成自建地址，避免和别人的请求混在同一个队列。
    public static let defaultBaseURL = "https://ani.sidestore.io"

    private let baseURL: URL
    private let client: HTTPClient
    private let storage: UserDefaults

    private static let machineKey = "signdrop.anisette.machineID"

    public init(
        baseURL: URL = URL(string: AnisetteClient.defaultBaseURL)!,
        client: HTTPClient = HTTPClient(timeout: 20),
        storage: UserDefaults = .standard
    ) {
        self.baseURL = baseURL
        self.client = client
        self.storage = storage
    }

    /// 设备标识要长期稳定，否则苹果会把它当成新设备，频繁触发二次验证。
    public var machineID: String {
        if let existing = storage.string(forKey: Self.machineKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        storage.set(generated, forKey: Self.machineKey)
        return generated
    }

    public func resetMachineID() {
        storage.removeObject(forKey: Self.machineKey)
    }

    /// 取一组可直接用于苹果接口的请求头。
    public func headers() async throws -> [String: String] {
        let payload: [String: Any] = [
            "provisioning_path": "",
            "user_agent": Self.userAgent,
            "machine_id": machineID
        ]

        let response: HTTPResponse
        do {
            response = try await client.post(baseURL.absoluteString, json: payload)
        } catch {
            throw AnisetteError.serverError(
                "连不上 anisette 服务（\(baseURL.absoluteString)）。"
                + "可以自建一份：docker run -d -p 6969:6969 dadoum/anisette-v3-server，"
                + "然后在设置里改成 http://127.0.0.1:6969"
            )
        }

        guard response.status == 200 else {
            throw AnisetteError.serverError("HTTP \(response.status) — \(response.text.prefix(200))")
        }

        var body = response.json()
        if body.isEmpty {
            // 有的实现直接返回纯文本头，兜底用响应头
            body = response.headers
        }
        if let nested = body["result"] as? [String: Any] {
            body = nested
        }
        if let message = body["error"] as? String, !message.isEmpty {
            throw AnisetteError.serverError(message)
        }

        var result: [String: String] = [:]
        for (key, value) in body where key.hasPrefix("X-Apple-") {
            result[key] = "\(value)"
        }

        guard result["X-Apple-I-MD"] != nil else {
            throw AnisetteError.missingProvisioning
        }

        result["X-Apple-I-Client-Time"] = result["X-Apple-I-Client-Time"] ?? Self.clientTime()
        result["X-Apple-I-TimeZone"] = result["X-Apple-I-TimeZone"] ?? TimeZone.current.identifier
        result["X-Apple-Locale"] = result["X-Apple-Locale"] ?? "zh_CN"
        result["X-Apple-I-SRL-NO"] = result["X-Apple-I-SRL-NO"] ?? "0"
        result["User-Agent"] = Self.userAgent
        return result
    }

    static var userAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    static func clientTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }
}
