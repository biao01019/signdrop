import Foundation
import Security
import SignKit

/// 凭证保险箱。
///
/// p12 与描述文件都是高敏感数据，放 Keychain（`WhenUnlockedThisDeviceOnly`）而不是普通文件：
/// 设备锁屏后不可读，且不会随 iCloud 备份外泄。
enum Vault {

    private static let service = "com.signkit.vault"
    private static let account = "credentials.v1"

    static func save(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.writeFailed(status)
        }
    }

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum VaultError: LocalizedError {
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let status):
            return "无法写入钥匙串（状态码 \(status)）"
        }
    }
}

/// 一套可用于签名的凭证。
///
/// 私钥有两种来路：
///   - `.p12`：用户从电脑上导入（AltServer / Sideloadly / 开发者后台导出的）
///   - `.keychain`：App 内用 Apple ID 现申请，私钥生成在本机 Keychain，从不落文件
struct Credential: Identifiable, Codable, Equatable {

    enum KeySource: String, Codable {
        case p12
        case keychain
    }

    var id = UUID()
    var label: String
    var teamID: String
    var commonName: String
    var profileName: String
    var applicationIdentifier: String
    var expiresAt: Date

    var p12: Data
    var password: String
    var profile: Data

    var deviceCount: Int
    var isWildcard: Bool
    var provisionsAllDevices: Bool

    /// 旧数据没有这两个字段，用 optional 保持向后兼容。
    var keySource: KeySource?
    var keyTag: String?
    var certificateDER: Data?

    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
    }

    var isExpired: Bool { expiresAt < Date() }

    /// 能不能用来签这个 Bundle ID。
    /// 与 `ProvisioningProfile.canSign` 保持同一套规则：先剥掉 Team 前缀再匹配。
    func allows(bundleID: String) -> Bool {
        guard !applicationIdentifier.isEmpty else { return false }

        var pattern = applicationIdentifier
        if pattern.hasPrefix(teamID + ".") {
            pattern = String(pattern.dropFirst(teamID.count + 1))
        }

        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            return bundleID.hasPrefix(String(pattern.dropLast(1)))
        }
        return pattern == bundleID
    }

    func loadIdentity() throws -> SigningIdentity {
        switch keySource ?? .p12 {
        case .p12:
            return try Credential.readIdentity(p12: p12, password: password, teamID: teamID)
        case .keychain:
            guard let tag = keyTag, !tag.isEmpty else {
                throw SignError.identity("这条凭证没有关联的私钥，请重新获取证书")
            }
            guard let key = AppleCertificate.loadKey(tag: tag) else {
                throw SignError.identity("Keychain 里的私钥已不存在（可能被系统清理），请重新获取证书")
            }
            guard let der = certificateDER, !der.isEmpty else {
                throw SignError.identity("缺少证书内容，请重新获取证书")
            }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw SignError.identity("证书内容损坏，请重新获取")
            }
            return try SigningIdentity(privateKey: key, certificates: [certificate], teamID: teamID)
        }
    }

    static func readIdentity(p12: Data, password: String, teamID: String) throws -> SigningIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, options, &items)

        guard status == errSecSuccess else {
            throw SignError.identity(
                status == errSecAuthFailed
                    ? "p12 密码不正确"
                    : "无法读取 p12（状态码 \(status)），请确认文件未损坏"
            )
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw SignError.identity("p12 里没有找到证书与私钥，可能是只导出了证书")
        }

        let secIdentity = identityRef as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return try SigningIdentity(identity: secIdentity, certificates: chain, teamID: teamID)
    }

    func loadProfile() throws -> ProvisioningProfile {
        try ProvisioningProfile(data: profile)
    }

    static func make(label: String, p12: Data, password: String, profile: Data) throws -> Credential {
        let parsed = try ProvisioningProfile(data: profile)
        let identity = try readIdentity(
            p12: p12,
            password: password,
            teamID: parsed.teamIdentifier
        )

        return Credential(
            label: label,
            teamID: parsed.teamIdentifier,
            commonName: identity.commonName,
            profileName: parsed.name,
            applicationIdentifier: parsed.applicationIdentifier,
            expiresAt: parsed.expirationDate,
            p12: p12,
            password: password,
            profile: profile,
            deviceCount: parsed.provisionedDevices.count,
            isWildcard: parsed.isWildcard,
            provisionsAllDevices: parsed.provisionsAllDevices
        )
    }

    /// Apple ID 模式拿到的凭证：私钥在 Keychain，不生成 p12。
    static func makeFromAppleID(
        label: String,
        teamID: String,
        commonName: String,
        certificate: Data,
        profile: Data,
        keyTag: String
    ) throws -> Credential {
        let parsed = try ProvisioningProfile(data: profile)
        return Credential(
            label: label.isEmpty ? "Apple ID 证书" : label,
            teamID: teamID.isEmpty ? parsed.teamIdentifier : teamID,
            commonName: commonName,
            profileName: parsed.name,
            applicationIdentifier: parsed.applicationIdentifier,
            expiresAt: parsed.expirationDate,
            p12: Data(),
            password: "",
            profile: profile,
            deviceCount: parsed.provisionedDevices.count,
            isWildcard: parsed.isWildcard,
            provisionsAllDevices: parsed.provisionsAllDevices,
            keySource: .keychain,
            keyTag: keyTag,
            certificateDER: certificate
        )
    }
}

/// 已签名的产物。
struct SignedApp: Identifiable, Codable {

    var id = UUID()
    var name: String
    var bundleID: String
    var version: String
    var signedAt: Date
    var expiresAt: Date
    var fileName: String
    var sizeBytes: UInt64

    var fileURL: URL {
        SignedApp.directory.appendingPathComponent(fileName)
    }

    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
