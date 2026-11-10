import Foundation

/// Apple 代码签名的二进制 blob 结构。
///
/// 这些结构没有公开文档，都是从 `Security.framework` 的 `codesign.h` 反推出来的稳定格式，
/// 十多年来未变。所有整数均为大端序。
public enum CSMagic {
    public static let requirement: UInt32 = 0xFADE0C00
    public static let requirements: UInt32 = 0xFADE0C01
    public static let codeDirectory: UInt32 = 0xFADE0C02
    public static let embeddedSignature: UInt32 = 0xFADE0CC0
    public static let embeddedEntitlements: UInt32 = 0xFADE7171
    public static let embeddedDEREntitlements: UInt32 = 0xFADE7172
    public static let blobWrapper: UInt32 = 0xFADE0B01
}

/// SuperBlob（CMS wrapper）里的槽位类型。
public enum CSSlot: UInt32 {
    case codeDirectory = 0
    case infoPlist = 1
    case requirements = 2
    case resourceDirectory = 3
    case application = 4
    case entitlements = 5
    case derEntitlements = 7
    case signature = 0x10000
}

public enum HashType: UInt8 {
    case sha1 = 1
    case sha256 = 2

    public var hashSize: Int {
        switch self {
        case .sha1: return 20
        case .sha256: return 32
        }
    }

    public func digest(_ bytes: [UInt8]) -> [UInt8] {
        switch self {
        case .sha1: return Hash.sha1(bytes)
        case .sha256: return Hash.sha256(bytes)
        }
    }

    public func digest(_ data: Data) -> Data {
        switch self {
        case .sha1: return Hash.sha1(data)
        case .sha256: return Hash.sha256(data)
        }
    }
}

public enum BigEndian {

    public static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    public static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    public static func write(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    public static func write(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for (index, shift) in stride(from: 56, through: 0, by: -8).enumerated() {
            bytes[offset + index] = UInt8((value >> UInt64(shift)) & 0xFF)
        }
    }
}

/// 生成 CodeDirectory。
///
/// 这是签名的核心：它把 Mach-O 的每个内存页哈希后串起来，再由 CMS 对整块签名。
/// 系统安装时据此校验二进制是否被改动。
public enum CodeDirectoryBuilder {

    public struct Options {
        public var identifier: String
        public var teamID: String?
        /// 被签名区域的长度，通常是 LC_CODE_SIGNATURE 起点（页对齐前）
        public var codeLimit: Int
        public var pageSize: Int
        public var hashType: HashType
        public var flags: UInt32
        public var execSegBase: UInt64
        public var execSegLimit: UInt64
        public var execSegFlags: UInt64
        /// key 为槽位序号：1 表示特殊槽 -1（Info.plist），4 表示 -4（entitlements）
        public var specialSlots: [Int: [UInt8]]

        public init(
            identifier: String,
            teamID: String? = nil,
            codeLimit: Int,
            pageSize: Int = 4096,
            hashType: HashType = .sha256,
            flags: UInt32 = 0,
            execSegBase: UInt64 = 0,
            execSegLimit: UInt64 = 0,
            execSegFlags: UInt64 = 0,
            specialSlots: [Int: [UInt8]] = [:]
        ) {
            self.identifier = identifier
            self.teamID = teamID
            self.codeLimit = codeLimit
            self.pageSize = pageSize
            self.hashType = hashType
            self.flags = flags
            self.execSegBase = execSegBase
            self.execSegLimit = execSegLimit
            self.execSegFlags = execSegFlags
            self.specialSlots = specialSlots
        }
    }

    /// version 0x20400 的头部长度固定为 88 字节。
    public static let headerSize = 88
    public static let version: UInt32 = 0x20400

    public static func build(data: Data, options: Options) throws -> [UInt8] {
        let pageSize = max(options.pageSize, 1)
        let limit = min(options.codeLimit, data.count)
        guard limit > 0 else {
            throw SignError.invalidMachO("codeLimit 为 0，无法计算代码页哈希")
        }

        // 代码页哈希：按页切分，最后不足一页的按实际长度计算（不做补零）
        var slots: [[UInt8]] = []
        var offset = 0
        let bytes = [UInt8](data.prefix(limit))
        while offset < limit {
            let end = min(offset + pageSize, limit)
            slots.append(options.hashType.digest(Array(bytes[offset..<end])))
            offset = end
        }

        let maxSpecial = options.specialSlots.keys.max() ?? 0
        let hashSize = options.hashType.hashSize
        let identBytes = Array(options.identifier.utf8) + [0]
        let teamBytes: [UInt8] = {
            guard let team = options.teamID, !team.isEmpty else { return [] }
            return Array(team.utf8) + [0]
        }()

        let identOffset = headerSize
        let teamOffset = teamBytes.isEmpty ? 0 : headerSize + identBytes.count
        let hashOffset = headerSize + identBytes.count + teamBytes.count + maxSpecial * hashSize
        let totalLength = hashOffset + slots.count * hashSize

        var blob: [UInt8] = []
        blob.reserveCapacity(totalLength)

        BigEndian.append(CSMagic.codeDirectory, to: &blob)
        BigEndian.append(UInt32(totalLength), to: &blob)
        BigEndian.append(version, to: &blob)
        BigEndian.append(options.flags, to: &blob)
        BigEndian.append(UInt32(hashOffset), to: &blob)
        BigEndian.append(UInt32(identOffset), to: &blob)
        BigEndian.append(UInt32(maxSpecial), to: &blob)
        BigEndian.append(UInt32(slots.count), to: &blob)
        BigEndian.append(UInt32(limit), to: &blob)
        blob.append(options.hashType.hashSize == 20 ? 20 : 32)
        blob.append(options.hashType.rawValue)
        blob.append(0) // platform
        blob.append(UInt8(log2PageSize(pageSize)))
        BigEndian.append(0, to: &blob)  // spare2
        BigEndian.append(0, to: &blob)  // scatterOffset
        BigEndian.append(UInt32(teamOffset), to: &blob)
        BigEndian.append(0, to: &blob)  // spare3
        BigEndian.append(UInt64(limit), to: &blob)
        BigEndian.append(options.execSegBase, to: &blob)
        BigEndian.append(options.execSegLimit, to: &blob)
        BigEndian.append(options.execSegFlags, to: &blob)

        precondition(blob.count == headerSize, "CodeDirectory 头部长度应为 88，实际 \(blob.count)")

        blob.append(contentsOf: identBytes)
        blob.append(contentsOf: teamBytes)

        // 特殊槽按 -maxSpecial ... -1 顺序排列，缺失的填零
        if maxSpecial > 0 {
            for slot in stride(from: maxSpecial, through: 1, by: -1) {
                if let digest = options.specialSlots[slot], digest.count == hashSize {
                    blob.append(contentsOf: digest)
                } else {
                    blob.append(contentsOf: [UInt8](repeating: 0, count: hashSize))
                }
            }
        }

        for slot in slots {
            blob.append(contentsOf: slot)
        }

        guard blob.count == totalLength else {
            throw SignError.invalidMachO("CodeDirectory 长度计算不一致：期望 \(totalLength)，实际 \(blob.count)")
        }
        return blob
    }

    private static func log2PageSize(_ size: Int) -> Int {
        var value = size
        var result = 0
        while value > 1 {
            value >>= 1
            result += 1
        }
        return result
    }
}

/// 空的需求集。开发签名不需要额外的 designated requirement。
public enum RequirementsBlob {

    public static func empty() -> [UInt8] {
        var blob: [UInt8] = []
        BigEndian.append(CSMagic.requirements, to: &blob)
        BigEndian.append(UInt32(12), to: &blob)
        BigEndian.append(UInt32(0), to: &blob)
        return blob
    }
}

/// entitlements blob。iOS 接受 XML plist 文本形式（magic 0xfade7171）。
public enum EntitlementsBlob {

    public static func build(plist: [String: Any]) throws -> [UInt8] {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        var blob: [UInt8] = []
        BigEndian.append(CSMagic.embeddedEntitlements, to: &blob)
        BigEndian.append(UInt32(8 + data.count), to: &blob)
        blob.append(contentsOf: [UInt8](data))
        return blob
    }
}

/// 把若干 blob 打包成 SuperBlob。
public enum SuperBlob {

    public struct Entry {
        public let slot: CSSlot
        public let blob: [UInt8]

        public init(slot: CSSlot, blob: [UInt8]) {
            self.slot = slot
            self.blob = blob
        }
    }

    public static func build(entries: [Entry]) -> [UInt8] {
        let count = entries.count
        let indexSize = 12 + count * 8
        var body: [UInt8] = []
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(indexSize + body.count)
            body.append(contentsOf: entry.blob)
        }

        var blob: [UInt8] = []
        BigEndian.append(CSMagic.embeddedSignature, to: &blob)
        BigEndian.append(UInt32(indexSize + body.count), to: &blob)
        BigEndian.append(UInt32(count), to: &blob)
        for (index, entry) in entries.enumerated() {
            BigEndian.append(entry.slot.rawValue, to: &blob)
            BigEndian.append(UInt32(offsets[index]), to: &blob)
        }
        blob.append(contentsOf: body)
        return blob
    }
}
