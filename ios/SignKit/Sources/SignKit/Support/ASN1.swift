import Foundation

/// 最小 DER 编码器。
///
/// 只覆盖 CMS/PKCS#7 SignedData 与 Apple 签名 blob 需要的类型，不做完整 ASN.1 支持。
/// DER 与 BER 的关键差异在这里都有体现：长度用最短形式、SET OF 必须按编码字典序排序、
/// INTEGER 为正数时若首字节高位为 1 需要补 0x00。
public enum DER {

    // MARK: - 基础编码

    public static func length(_ n: Int) -> [UInt8] {
        precondition(n >= 0, "DER 长度不能为负")
        if n < 0x80 {
            return [UInt8(n)]
        }
        var bytes: [UInt8] = []
        var value = n
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func tlv(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    public static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        tlv(tag: 0x30, items.flatMap { $0 })
    }

    /// SET OF：DER 要求成员按各自编码的字典序升序排列。
    public static func set(_ items: [[UInt8]]) -> [UInt8] {
        let ordered = items.sorted { $0.lexicographicallyPrecedes($1) }
        return tlv(tag: 0x31, ordered.flatMap { $0 })
    }

    public static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var content = bytes
        // 去掉多余前导零
        while content.count > 1 && content[0] == 0 && content[1] < 0x80 {
            content.removeFirst()
        }
        if content.isEmpty { content = [0] }
        // 正整数：最高位为 1 时补零，避免被解释成负数
        if let first = content.first, first & 0x80 != 0 {
            content.insert(0, at: 0)
        }
        return tlv(tag: 0x02, content)
    }

    public static func integer(_ value: Int) -> [UInt8] {
        if value == 0 { return tlv(tag: 0x02, [0]) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return integer(bytes)
    }

    public static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tag: 0x04, bytes)
    }

    public static func null() -> [UInt8] {
        [0x05, 0x00]
    }

    public static func utf8String(_ string: String) -> [UInt8] {
        tlv(tag: 0x0C, Array(string.utf8))
    }

    public static func printableString(_ string: String) -> [UInt8] {
        tlv(tag: 0x13, Array(string.utf8))
    }

    public static func boolean(_ value: Bool) -> [UInt8] {
        tlv(tag: 0x01, [value ? 0xFF : 0x00])
    }

    /// 上下文标签。[0] IMPLICIT / EXPLICIT 都通过 constructed 区分。
    public static func context(_ tag: Int, constructed: Bool, _ content: [UInt8]) -> [UInt8] {
        let tagByte: UInt8 = 0x80 | (constructed ? 0x20 : 0x00) | UInt8(tag & 0x1F)
        return tlv(tag: tagByte, content)
    }

    /// OBJECT IDENTIFIER，输入点分字符串如 "1.2.840.113549.1.7.2"。
    public static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(parts.count >= 2, "OID 至少需要两级")
        var content: [UInt8] = []
        content.append(UInt8(parts[0] * 40 + parts[1]))
        for value in parts.dropFirst(2) {
            content.append(contentsOf: base128(value))
        }
        return tlv(tag: 0x06, content)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0] }
        var groups: [UInt8] = []
        var v = value
        while v > 0 {
            groups.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        for index in 0..<(groups.count - 1) {
            groups[index] |= 0x80
        }
        return groups
    }

    /// UTCTime，格式 YYMMDDHHMMSSZ（UTC）。
    public static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(tag: 0x17, Array(formatter.string(from: date).utf8))
    }

    /// GeneralizedTime，格式 YYYYMMDDHHMMSSZ。
    public static func generalizedTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(tag: 0x18, Array(formatter.string(from: date).utf8))
    }
}

// MARK: - 常用 OID

public enum OID {
    public static let data = "1.2.840.113549.1.7.1"
    public static let signedData = "1.2.840.113549.1.7.2"
    public static let contentType = "1.2.840.113549.1.9.3"
    public static let messageDigest = "1.2.840.113549.1.9.4"
    public static let signingTime = "1.2.840.113549.1.9.5"
    public static let sha1 = "1.3.14.3.2.26"
    public static let sha256 = "2.16.840.1.101.3.4.2.1"
    public static let rsaEncryption = "1.2.840.113549.1.1.1"
    public static let commonName = "2.5.4.3"
    public static let organizationalUnit = "2.5.4.11"
    public static let organization = "2.5.4.10"
    public static let country = "2.5.4.6"
}

// MARK: - 便捷哈希

import CryptoKit

public enum Hash {

    public static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// 递归目录哈希用的 SHA1（兼容 Apple 的 CodeResources 规则）。
    public static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        Array(sha1(Data(bytes)))
    }

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(sha256(Data(bytes)))
    }
}
