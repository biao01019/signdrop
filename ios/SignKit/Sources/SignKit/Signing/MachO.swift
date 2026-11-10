import Foundation

public enum SignError: LocalizedError {
    case invalidMachO(String)
    case unsupported(String)
    case archive(String)
    case profile(String)
    case crypto(String)
    case identity(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMachO(let detail): return "Mach-O 结构异常：\(detail)"
        case .unsupported(let detail): return "暂不支持：\(detail)"
        case .archive(let detail): return "安装包处理失败：\(detail)"
        case .profile(let detail): return "描述文件无效：\(detail)"
        case .crypto(let detail): return "加密操作失败：\(detail)"
        case .identity(let detail): return "签名身份不可用：\(detail)"
        }
    }
}

/// 单个 Mach-O 二进制的可写视图。
///
/// 签名流程会在文件尾部追加代码签名数据，并把 `__LINKEDIT` 段撑到覆盖它。
/// 已经带签名的二进制会先被截断，避免签名区嵌套导致包体膨胀。
public struct MachOImage {

    public struct SegmentInfo {
        public let name: String
        public let vmaddr: UInt64
        public let vmsize: UInt64
        public let fileoff: UInt64
        public let filesize: UInt64
        public let commandOffset: Int
    }

    public struct CodeSignatureCommand {
        public let commandOffset: Int
        public let dataOffset: UInt64
        public let dataSize: UInt64
    }

    public private(set) var bytes: [UInt8]
    public private(set) var headerSize: Int
    public private(set) var segments: [SegmentInfo]
    public private(set) var codeSignature: CodeSignatureCommand?

    private let sizeofcmds: UInt32
    private let ncmds: UInt32
    private let firstSectionOffset: UInt64

    public static let lcCodeSignature: UInt32 = 0x1D
    public static let lcSegment64: UInt32 = 0x19

    public init(data: Data) throws {
        var raw = [UInt8](data)
        guard raw.count >= 32 else {
            throw SignError.invalidMachO("文件太小，不足一个 64 位 Mach-O 头部")
        }

        let magic = MachOImage.readUInt32(raw, 0)
        guard magic == 0xFEEDFACF else {
            if magic == 0xCAFEBABE || magic == 0xBEBAFECA || magic == 0xCAFEBABF {
                throw SignError.unsupported("这是通用二进制（fat）包，需要先拆分成单一架构再签名")
            }
            throw SignError.invalidMachO(String(format: "magic 为 0x%08X，不是 64 位 Mach-O", magic))
        }

        let cpuType = MachOImage.readUInt32(raw, 4)
        _ = cpuType
        let commandsCount = MachOImage.readUInt32(raw, 16)
        let commandsSize = MachOImage.readUInt32(raw, 20)
        let headerBytes = 32

        guard headerBytes + Int(commandsSize) <= raw.count else {
            throw SignError.invalidMachO("sizeofcmds 超出文件长度，文件可能被截断")
        }

        var parsedSegments: [SegmentInfo] = []
        var signatureCommand: CodeSignatureCommand?
        var cursor = headerBytes
        var minSectionOffset: UInt64 = UInt64(raw.count)

        for _ in 0..<commandsCount {
            guard cursor + 8 <= raw.count else { break }
            let command = MachOImage.readUInt32(raw, cursor)
            let commandSize = MachOImage.readUInt32(raw, cursor + 4)
            guard commandSize >= 8 else { break }

            if command == MachOImage.lcSegment64, commandSize >= 72 {
                let name = MachOImage.readSegmentName(raw, cursor + 8)
                let vmaddr = MachOImage.readUInt64(raw, cursor + 24)
                let vmsize = MachOImage.readUInt64(raw, cursor + 32)
                let fileoff = MachOImage.readUInt64(raw, cursor + 40)
                let filesize = MachOImage.readUInt64(raw, cursor + 48)
                let nsects = MachOImage.readUInt32(raw, cursor + 64)

                parsedSegments.append(
                    SegmentInfo(
                        name: name,
                        vmaddr: vmaddr,
                        vmsize: vmsize,
                        fileoff: fileoff,
                        filesize: filesize,
                        commandOffset: cursor
                    )
                )

                // 记录所有 section 的最小文件偏移，用于判断 load commands 后还有多少空隙
                var sectionCursor = cursor + 72
                for _ in 0..<nsects {
                    guard sectionCursor + 80 <= raw.count else { break }
                    let sectionOffset = MachOImage.readUInt32(raw, sectionCursor + 48)
                    if sectionOffset > 0 {
                        minSectionOffset = min(minSectionOffset, UInt64(sectionOffset))
                    }
                    sectionCursor += 80
                }
            } else if command == MachOImage.lcCodeSignature, commandSize >= 16 {
                let dataOffset = UInt64(MachOImage.readUInt32(raw, cursor + 8))
                let dataSize = UInt64(MachOImage.readUInt32(raw, cursor + 12))
                signatureCommand = CodeSignatureCommand(
                    commandOffset: cursor,
                    dataOffset: dataOffset,
                    dataSize: dataSize
                )
            }

            cursor += Int(commandSize)
        }

        guard parsedSegments.contains(where: { $0.name == "__LINKEDIT" }) else {
            throw SignError.invalidMachO("没有找到 __LINKEDIT 段")
        }

        self.bytes = raw
        self.headerSize = headerBytes
        self.segments = parsedSegments
        self.codeSignature = signatureCommand
        self.sizeofcmds = commandsSize
        self.ncmds = commandsCount
        self.firstSectionOffset = minSectionOffset == UInt64(raw.count) ? 0 : minSectionOffset
    }

    // MARK: - 布局计算

    /// 放一个 `linkedit_data_command` 需要的字节数。
    public static let signatureCommandSize = 16

    /// load commands 末尾到第一个 section 之间的可用空隙。
    public var availableHeaderPadding: Int {
        let commandsEnd = headerSize + Int(sizeofcmds)
        guard firstSectionOffset > 0 else { return 0 }
        return max(0, Int(firstSectionOffset) - commandsEnd)
    }

    /// 去掉已有签名，返回干净的可写副本。
    public mutating func stripExistingSignature() throws {
        guard let signature = codeSignature else { return }

        // 旧签名必须位于文件尾部，否则说明结构不符合预期，直接放弃处理以免损坏
        let expected = signature.dataOffset + signature.dataSize
        guard expected <= UInt64(bytes.count) else {
            throw SignError.invalidMachO("旧签名区超出文件长度")
        }

        // 截到签名起点，把旧 CodeDirectory / CMS 一并丢掉
        bytes.removeSubrange(Int(signature.dataOffset)..<bytes.count)

        if let linkeditIndex = segments.firstIndex(where: { $0.name == "__LINKEDIT" }) {
            let old = segments[linkeditIndex]
            let newSize = max(0, signature.dataOffset - old.fileoff)
            segments[linkeditIndex] = SegmentInfo(
                name: old.name,
                vmaddr: old.vmaddr,
                vmsize: MachOImage.align(newSize, 0x4000),
                fileoff: old.fileoff,
                filesize: newSize,
                commandOffset: old.commandOffset
            )
        }
        codeSignature = nil
    }

    /// 把文件补齐到 16 字节边界，返回签名区起点与被签名区域的完整字节。
    ///
    /// 必须分成"准备"和"写入"两步：CodeDirectory 的 codeLimit 就是签名区起点，
    /// 而 CodeDirectory 本身又是签名 blob 的一部分，长度依赖 codeLimit。
    public mutating func prepareSignatureSlot() -> (offset: Int, signedData: Data) {
        while bytes.count % 16 != 0 {
            bytes.append(0)
        }
        return (bytes.count, Data(bytes))
    }

    /// 写入签名 blob，并维护 `__LINKEDIT` 与 `LC_CODE_SIGNATURE`。
    public mutating func attachSignature(_ blob: [UInt8], at offset: Int) throws {
        guard offset == bytes.count else {
            throw SignError.invalidMachO("签名区起点与文件长度不一致（\(offset) / \(bytes.count)）")
        }
        guard let linkeditIndex = segments.firstIndex(where: { $0.name == "__LINKEDIT" }) else {
            throw SignError.invalidMachO("没有找到 __LINKEDIT 段")
        }
        let linkedit = segments[linkeditIndex]

        // 先确定 LC_CODE_SIGNATURE 的位置，放不下就立刻失败，避免写坏文件
        let commandOffset: Int
        let needsNewCommand: Bool
        if let existing = codeSignature {
            commandOffset = existing.commandOffset
            needsNewCommand = false
        } else {
            guard availableHeaderPadding >= MachOImage.signatureCommandSize else {
                throw SignError.invalidMachO(
                    "load commands 后只剩 \(availableHeaderPadding) 字节空隙，放不下签名命令"
                )
            }
            commandOffset = headerSize + Int(sizeofcmds)
            needsNewCommand = true
        }

        bytes.append(contentsOf: blob)

        // __LINKEDIT 必须覆盖到文件末尾。vmsize 只需不小于 filesize，
        // 用页大小向上对齐即可，不能拿 vmaddr 参与相减（会下溢）。
        let newFileSize = UInt64(bytes.count) - linkedit.fileoff
        let newVMSize = MachOImage.align(newFileSize, 0x4000)

        MachOImage.writeUInt64(&bytes, linkedit.commandOffset + 32, newVMSize)
        MachOImage.writeUInt64(&bytes, linkedit.commandOffset + 48, newFileSize)

        if needsNewCommand {
            MachOImage.writeUInt32(&bytes, 16, ncmds + 1)
            MachOImage.writeUInt32(&bytes, 20, sizeofcmds + UInt32(MachOImage.signatureCommandSize))
        }

        MachOImage.writeUInt32(&bytes, commandOffset, MachOImage.lcCodeSignature)
        MachOImage.writeUInt32(&bytes, commandOffset + 4, UInt32(MachOImage.signatureCommandSize))
        MachOImage.writeUInt32(&bytes, commandOffset + 8, UInt32(offset))
        MachOImage.writeUInt32(&bytes, commandOffset + 12, UInt32(blob.count))
    }

    public func data() -> Data {
        Data(bytes)
    }

    // MARK: - 读写工具

    static func align(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        guard alignment > 1 else { return value }
        return (value + alignment - 1) / alignment * alignment
    }

    // Mach-O 的所有整数字段都是小端序（arm64 / x86_64 均如此）。
    // 注意不要和 Apple 签名 blob 的大端序混淆。

    static func readUInt32(_ raw: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | UInt32(raw[offset + 1]) << 8
            | UInt32(raw[offset + 2]) << 16
            | UInt32(raw[offset + 3]) << 24
    }

    static func readUInt64(_ raw: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(raw[offset + index])
        }
        return value
    }

    static func writeUInt32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func writeUInt64(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            buffer[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xFF)
        }
    }

    static func readSegmentName(_ raw: [UInt8], _ offset: Int) -> String {
        var nameBytes: [UInt8] = []
        for index in 0..<16 {
            let byte = raw[offset + index]
            if byte == 0 { break }
            nameBytes.append(byte)
        }
        return String(decoding: nameBytes, as: UTF8.self)
    }
}
