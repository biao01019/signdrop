import Foundation

/// 苹果接口要用的最小 HTTP 客户端。
///
/// 只用 Foundation 自带的 `URLSession`，不引第三方网络库：这里的请求形态很单一
/// （JSON / 表单 / 自定义头），而且需要拿到**响应头**（`scnt`、`X-Apple-ID-Session-Id`
/// 这些会话标识都藏在头里，body 里没有）。
public struct HTTPResponse {
    public let status: Int
    /// 统一小写做 key，苹果返回的头大小写不稳定。
    public let headers: [String: String]
    public let body: Data

    public var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    public func plist() -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }
}

public enum HTTPError: LocalizedError {
    case invalidURL(String)
    case transport(String)
    case status(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "地址无效：\(value)"
        case .transport(let detail):
            return "网络请求失败：\(detail)"
        case .status(let code, let detail):
            return "服务器返回 HTTP \(code)：\(detail)"
        }
    }
}

public final class HTTPClient {

    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.timeout = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func post(
        _ url: String,
        json: [String: Any]? = nil,
        form: [String: String]? = nil,
        headers: [String: String] = [:],
        raw: Data? = nil
    ) async throws -> HTTPResponse {
        var body: Data?
        var merged = headers

        if let json = json {
            body = try JSONSerialization.data(withJSONObject: json)
            merged["Content-Type"] = "application/json"
        } else if let form = form {
            body = Self.formEncode(form).data(using: .utf8)
            merged["Content-Type"] = "application/x-www-form-urlencoded"
        } else if let raw = raw {
            body = raw
        }

        return try await send(url, method: "POST", body: body, headers: merged)
    }

    public func get(_ url: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(url, method: "GET", body: nil, headers: headers)
    }

    private func send(
        _ url: String,
        method: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> HTTPResponse {
        guard let target = URL(string: url) else {
            throw HTTPError.invalidURL(url)
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.transport("响应不是 HTTP")
            }
            var normalized: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                normalized[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(status: http.statusCode, headers: normalized, body: data)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    /// 表单编码。苹果的开发者接口对顺序没要求，但必须正确转义。
    static func formEncode(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Base64 容错

public enum B64 {

    /// 苹果返回的 base64 有时缺 padding，`Data(base64Encoded:)` 会直接失败。
    public static func decode(_ value: String) -> Data? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }
}
