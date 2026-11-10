import Foundation
import Security

/// 开发者证书的生成与解析。
///
/// 整条链是这样的：
///   1. 本机生成 RSA 2048 私钥（存 Keychain，`ThisDeviceOnly`，永不外传）
///   2. 用私钥签出 CSR（Certificate Signing Request，DER 格式）
///   3. 把 CSR 交给苹果，苹果签发 .cer
///   4. 私钥 + 证书一起用于 CMS 签名
///
/// 私钥始终留在设备上，这是"用户自己的账号自己签"的核心。
public enum AppleCertificate {

    public enum CertError: LocalizedError {
        case keyGeneration(String)
        case missingPublicKey
        case exportPublicKey(String)
        case sign(String)
        case parseCertificate

        public var errorDescription: String? {
            switch self {
            case .keyGeneration(let detail):
                return "生成 RSA 密钥失败：\(detail)"
            case .missingPublicKey:
                return "无法从私钥导出公钥"
            case .exportPublicKey(let detail):
                return "导出公钥失败：\(detail)"
            case .sign(let detail):
                return "CSR 签名失败：\(detail)"
            case .parseCertificate:
                return "苹果返回的内容不是有效的证书（可能是错误页而非 .cer）"
            }
        }
    }

    /// 证书摘要，够界面显示就行。
    public struct Summary {
        public let commonName: String
        public let teamID: String?
    }

    // MARK: - 密钥

    /// 生成并持久化一对 RSA 2048 密钥。
    ///
    /// 用 `kSecAttrIsPermanent` 存进 Keychain：iOS 上要拿到可用的签名身份必须这一步，
    /// 而且 `ThisDeviceOnly` 保证它不会随 iCloud 备份离开设备。
    public static func generateKeyPair(tag: String) throws -> SecKey {
        deleteKey(tag: tag)

        let tagData = Data(tag.utf8)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "未知原因"
            throw CertError.keyGeneration(message)
        }
        return key
    }

    public static func loadKey(tag: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecKey)
    }

    public static func deleteKey(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8)
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - CSR

    /// 生成 DER 格式的 CSR。苹果开发者接口要的就是 DER。
    public static func makeCSR(
        privateKey: SecKey,
        commonName: String,
        email: String? = nil
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertError.missingPublicKey
        }

        var exportError: Unmanaged<CFError>?
        guard let rawPublicRef = SecKeyCopyExternalRepresentation(publicKey, &exportError) else {
            let message = (exportError?.takeRetainedValue()).map { String(describing: $0) } ?? "未知原因"
            throw CertError.exportPublicKey(message)
        }
        let rawPublic = rawPublicRef as Data

        // SecKeyCopyExternalRepresentation 对 RSA 返回 PKCS#1 的 RSAPublicKey，
        // 正好是 SubjectPublicKeyInfo 里 BIT STRING 需要的内容。
        let algorithmIdentifier = DER.sequence([
            DER.oid(OID.rsaEncryption),
            DER.null()
        ])
        let subjectPublicKeyInfo = DER.sequence([
            algorithmIdentifier,
            DER.tlv(tag: 0x03, [0x00] + [UInt8](rawPublic))
        ])

        var nameEntries: [[UInt8]] = [
            DER.set([
                DER.sequence([
                    DER.oid(OID.commonName),
                    DER.utf8String(commonName)
                ])
            ])
        ]
        if let email = email, !email.isEmpty {
            nameEntries.append(
                DER.set([
                    DER.sequence([
                        DER.oid("1.2.840.113549.1.9.1"),
                        DER.tlv(tag: 0x16, Array(email.utf8))
                    ])
                ])
            )
        }
        let subject = DER.sequence(nameEntries)

        // CertificationRequestInfo ::= SEQUENCE {
        //   version INTEGER, subject Name, subjectPKInfo, attributes [0] IMPLICIT
        // }
        let requestInfo = DER.sequence([
            DER.integer(0),
            subject,
            subjectPublicKeyInfo,
            DER.context(0, constructed: true, [])
        ])

        var signError: Unmanaged<CFError>?
        guard let signatureRef = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(requestInfo) as CFData,
            &signError
        ) else {
            let message = (signError?.takeRetainedValue()).map { String(describing: $0) } ?? "未知原因"
            throw CertError.sign(message)
        }
        let signature = signatureRef as Data

        let signatureAlgorithm = DER.sequence([
            DER.oid("1.2.840.113549.1.1.11"),
            DER.null()
        ])

        let csr = DER.sequence([
            requestInfo,
            signatureAlgorithm,
            DER.tlv(tag: 0x03, [0x00] + [UInt8](signature))
        ])

        return Data(csr)
    }

    // MARK: - 解析苹果返回的证书

    public static func parseCertificate(_ der: Data) throws -> (certificate: SecCertificate, summary: Summary) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertError.parseCertificate
        }
        let commonName = (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        return (
            certificate,
            Summary(
                commonName: commonName,
                teamID: SigningIdentity.extractTeamID(from: commonName)
            )
        )
    }
}
