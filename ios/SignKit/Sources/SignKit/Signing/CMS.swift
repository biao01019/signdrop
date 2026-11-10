import Foundation
import Security

/// 极简 DER 游标，只用于从证书里取出 issuer 与 serialNumber。
public struct DERScanner {

    public struct Element {
        public let tag: UInt8
        public let tagStart: Int
        public let contentStart: Int
        public let contentEnd: Int
        public let bytes: [UInt8]

        public var raw: [UInt8] {
            Array(bytes[tagStart..<contentEnd])
        }

        public var content: [UInt8] {
            Array(bytes[contentStart..<contentEnd])
        }

        public var isConstructed: Bool {
            tag & 0x20 != 0
        }
    }

    private let bytes: [UInt8]
    private var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var isAtEnd: Bool {
        offset >= bytes.count
    }

    public mutating func read() -> Element? {
        guard offset + 2 <= bytes.count else { return nil }
        let tagStart = offset
        let tag = bytes[offset]
        offset += 1

        var length = 0
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard offset + length <= bytes.count else { return nil }
        let contentStart = offset
        let contentEnd = offset + length
        offset = contentEnd
        return Element(
            tag: tag,
            tagStart: tagStart,
            contentStart: contentStart,
            contentEnd: contentEnd,
            bytes: bytes
        )
    }
}

/// 一个可用的签名身份：私钥 + 证书链。
///
/// 私钥有两种来源：
///   - 用户导入的 p12 → 走 `SecIdentity`，能顺带拿到证书链
///   - Apple ID 登录后在设备上现生成的密钥 → 直接持有 `SecKey`，没有 SecIdentity
///
/// iOS 上 `SecIdentityCreateWithCertificate` 不可用，从 Keychain 里单独取出的私钥和
/// 证书没法拼成 SecIdentity，所以这里统一收敛到「私钥 + 证书」，CMS 签名只依赖这两样。
public struct SigningIdentity {

    public let identity: SecIdentity?
    public let privateKey: SecKey
    public let certificates: [SecCertificate]
    public let commonName: String
    public let teamID: String?

    public init(identity: SecIdentity, certificates: [SecCertificate], teamID: String?) throws {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let resolved = key else {
            throw SignError.identity("无法从 p12 中取出私钥")
        }
        try self.init(
            privateKey: resolved,
            certificates: certificates,
            teamID: teamID,
            identity: identity
        )
    }

    /// 直接用现成的私钥构造（Apple ID 模式）。
    public init(privateKey: SecKey, certificates: [SecCertificate], teamID: String?) throws {
        try self.init(
            privateKey: privateKey,
            certificates: certificates,
            teamID: teamID,
            identity: nil
        )
    }

    private init(
        privateKey: SecKey,
        certificates: [SecCertificate],
        teamID: String?,
        identity: SecIdentity?
    ) throws {
        guard let leaf = certificates.first else {
            throw SignError.identity("证书链为空")
        }
        self.identity = identity
        self.privateKey = privateKey
        self.certificates = certificates
        self.teamID = teamID

        var name: CFString?
        guard SecCertificateCopyCommonName(leaf, &name) == errSecSuccess,
              let resolved = name as String? else {
            throw SignError.identity("无法读取证书的 Common Name")
        }
        self.commonName = resolved
    }

    /// 从 Apple 开发证书的 CN 里提取 Team ID。
    /// 形如 "Apple Development: foo@bar.com (ABCDE12345)"。
    public static func extractTeamID(from commonName: String) -> String? {
        guard let open = commonName.lastIndex(of: "("),
              let close = commonName.lastIndex(of: ")"),
              open < close else { return nil }
        let candidate = commonName[commonName.index(after: open)..<close]
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 10 else { return nil }
        return trimmed
    }
}

/// 构造 PKCS#7 / CMS 的 Detached SignedData，供 `LC_CODE_SIGNATURE` 使用。
public enum CMSBuilder {

    public static func signature(for content: Data, identity: SigningIdentity) throws -> [UInt8] {
        guard let leaf = identity.certificates.first else {
            throw SignError.identity("证书链为空")
        }

        let key = identity.privateKey

        let issuerAndSerial = try issuerAndSerialNumber(of: leaf)
        let contentDigest = Hash.sha256(content)

        // 1. 认证属性：contentType 与 messageDigest 是 Apple 强制要求的
        let contentTypeAttr = DER.sequence([
            DER.oid(OID.contentType),
            DER.set([DER.oid(OID.data)])
        ])
        let messageDigestAttr = DER.sequence([
            DER.oid(OID.messageDigest),
            DER.set([DER.octetString([UInt8](contentDigest))])
        ])

        // 用于计算签名的编码：SET OF，标签 0x31
        let attributesForSigning = DER.set([contentTypeAttr, messageDigestAttr])

        // 2. 对属性集合签名（RSA PKCS#1 v1.5 + SHA-256，由 Security 内部完成哈希）
        var error: Unmanaged<CFError>?
        guard let signatureRef = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(attributesForSigning) as CFData,
            &error
        ) else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "未知错误"
            throw SignError.crypto("RSA 签名失败：\(detail)")
        }
        let signed = signatureRef as Data

        // 3. SignerInfo 里的属性字段用 [0] IMPLICIT：内容与签名时完全一致，
        //    只是把 SET OF 的 0x31 换成 0xA0，长度字段不需要重新编码
        var attributesFixed = attributesForSigning
        attributesFixed[0] = 0xA0

        let sha256Algorithm = DER.sequence([
            DER.oid(OID.sha256),
            DER.null()
        ])
        let rsaAlgorithm = DER.sequence([
            DER.oid(OID.rsaEncryption),
            DER.null()
        ])

        let signerInfo = DER.sequence([
            DER.integer(1),
            issuerAndSerial,
            sha256Algorithm,
            attributesFixed,
            rsaAlgorithm,
            DER.octetString([UInt8](signed))
        ])

        // 4. 证书集合，[0] IMPLICIT
        var certificatesContent: [UInt8] = []
        for certificate in identity.certificates {
            certificatesContent.append(contentsOf: [UInt8](SecCertificateCopyData(certificate) as Data))
        }

        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256Algorithm]),
            DER.sequence([DER.oid(OID.data)]),
            DER.context(0, constructed: true, certificatesContent),
            DER.set([signerInfo])
        ])

        return DER.sequence([
            DER.oid(OID.signedData),
            DER.context(0, constructed: true, signedData)
        ])
    }

    /// 从证书 TBS 里取出 issuer 的完整 DER 与序列号。
    private static func issuerAndSerialNumber(of certificate: SecCertificate) throws -> [UInt8] {
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        var cursor = DERScanner(der)

        guard let root = cursor.read(), root.tag == 0x30 else {
            throw SignError.identity("证书不是合法的 DER SEQUENCE")
        }
        var inner = DERScanner(root.bytes, offset: root.contentStart)
        guard let tbs = inner.read(), tbs.tag == 0x30 else {
            throw SignError.identity("证书缺少 tbsCertificate")
        }

        var tbsCursor = DERScanner(tbs.bytes, offset: tbs.contentStart)
        guard var node = tbsCursor.read() else {
            throw SignError.identity("tbsCertificate 内容为空")
        }
        if node.tag == 0xA0 {
            guard let next = tbsCursor.read() else {
                throw SignError.identity("tbsCertificate 结构异常")
            }
            node = next
        }
        guard node.tag == 0x02 else {
            throw SignError.identity("未找到序列号")
        }
        let serialDER = node.raw

        // 跳过 signatureAlgorithm，下一个 SEQUENCE 就是 issuer Name
        guard let _ = tbsCursor.read(),
              let issuer = tbsCursor.read(),
              issuer.tag == 0x30 else {
            throw SignError.identity("未找到 issuer Name")
        }

        return DER.sequence([issuer.raw, serialDER])
    }
}
