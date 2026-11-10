import Foundation
import Security

/// 描述文件（mobileprovision）的解析结果。
///
/// 文件本身是一个 CMS SignedData，第三层载荷才是 plist。这里只做"取出载荷"，
/// 不验证 Apple 的签名——设备安装时会自己验。
public struct ProvisioningProfile {

    public let raw: Data
    public let plist: [String: Any]
    public let name: String
    public let teamIdentifier: String
    public let applicationIdentifier: String
    public let entitlements: [String: Any]
    public let expirationDate: Date
    public let creationDate: Date?
    public let provisionedDevices: [String]
    public let developerCertificates: [Data]
    public let provisionsAllDevices: Bool
    public let uuid: String?

    public var isExpired: Bool {
        expirationDate < Date()
    }

    public var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
    }

    /// 通配符描述文件能把任意 Bundle ID 签成同一个 App ID。
    public var isWildcard: Bool {
        applicationIdentifier.hasSuffix(".*") || entitlements["application-identifier"] as? String == "*"
    }

    /// 描述文件允许的 Bundle ID 前缀，例如 `ABCDE12345.com.example.`
    public var bundleIDPrefix: String {
        if let full = entitlements["application-identifier"] as? String {
            return full
        }
        return "\(teamIdentifier)."
    }

    public init(data: Data) throws {
        self.raw = data
        let payload = try ProvisioningProfile.extractPayload(from: data)

        guard let parsed = try PropertyListSerialization.propertyList(
            from: payload,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SignError.profile("描述文件载荷不是字典")
        }
        self.plist = parsed

        guard let name = parsed["Name"] as? String else {
            throw SignError.profile("缺少 Name 字段，可能不是有效的 mobileprovision")
        }
        self.name = name

        let teams = parsed["TeamIdentifier"] as? [String] ?? []
        self.teamIdentifier = teams.first ?? ""

        let entitlements = parsed["Entitlements"] as? [String: Any] ?? [:]
        self.entitlements = entitlements
        self.applicationIdentifier = entitlements["application-identifier"] as? String ?? ""

        guard let expiration = parsed["ExpirationDate"] as? Date else {
            throw SignError.profile("缺少 ExpirationDate")
        }
        self.expirationDate = expiration
        self.creationDate = parsed["CreationDate"] as? Date
        self.provisionedDevices = parsed["ProvisionedDevices"] as? [String] ?? []
        self.developerCertificates = parsed["DeveloperCertificates"] as? [Data] ?? []
        self.provisionsAllDevices = parsed["ProvisionsAllDevices"] as? Bool ?? false
        self.uuid = parsed["UUID"] as? String
    }

    // MARK: - 校验

    /// 判断描述文件能否用于给定的 Bundle ID。
    ///
    /// entitlements 里的 `application-identifier` 形如 `TEAMID.com.example.*`，
    /// 而调用方传进来的是不含 Team 前缀的 Bundle ID，所以要先剥掉前缀再比。
    public func canSign(bundleID: String) -> Bool {
        guard !applicationIdentifier.isEmpty else { return false }

        var pattern = applicationIdentifier
        if pattern.hasPrefix(teamIdentifier + ".") {
            pattern = String(pattern.dropFirst(teamIdentifier.count + 1))
        }

        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            // "com.example.*" → 前缀 "com.example."
            return bundleID.hasPrefix(String(pattern.dropLast(1)))
        }
        return pattern == bundleID
    }

    /// 设备是否在白名单内。企业证书（ProvisionsAllDevices）不限设备。
    public func includesDevice(udid: String) -> Bool {
        if provisionsAllDevices { return true }
        return provisionedDevices.contains(udid)
    }

    /// 描述文件内是否包含指定的证书（按 DER 比对）。
    public func contains(certificate: SecCertificateWrapper) -> Bool {
        developerCertificates.contains(certificate.der)
    }

    // MARK: - 载荷提取

    static func extractPayload(from data: Data) throws -> Data {
        let bytes = [UInt8](data)

        if let start = find(bytes, Array("<?xml".utf8), from: 0),
           let end = find(bytes, Array("</plist>".utf8), from: start) {
            let stop = end + "</plist>".utf8.count
            return Data(bytes[start..<stop])
        }

        if let start = find(bytes, Array("bplist00".utf8), from: 0) {
            // 二进制 plist 的长度由尾部 trailer 决定，这里退化为"从起始到文件末"，
            // PropertyListSerialization 能容忍尾部填充。
            let slice = Data(bytes[start...])
            if (try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil)) != nil {
                return slice
            }
        }

        throw SignError.profile("未找到 plist 载荷，文件可能已损坏或不是 mobileprovision")
    }

    private static func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        guard from <= limit else { return nil }
        for index in from...limit {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
        }
        return nil
    }
}

/// `SecCertificate` 的轻量包装，便于跨模块比较与测试。
public struct SecCertificateWrapper: Equatable {
    public let der: Data

    public init(_ certificate: SecCertificate) {
        self.der = SecCertificateCopyData(certificate) as Data
    }

    public init(der: Data) {
        self.der = der
    }

    public static func == (lhs: SecCertificateWrapper, rhs: SecCertificateWrapper) -> Bool {
        lhs.der == rhs.der
    }
}
