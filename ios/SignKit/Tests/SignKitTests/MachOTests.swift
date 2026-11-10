import XCTest
@testable import SignKit

/// 手工拼一个最小可解析的 arm64 Mach-O，避免依赖系统二进制（macOS 上的 /bin/ls 是通用包）。
enum MachOFixture {

    static func thin(
        payloadSize: Int = 0x100,
        paddingTo: Int = 0x1000
    ) -> Data {
        var bytes: [UInt8] = []

        func u32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }
        func u64(_ value: UInt64) {
            for index in 0..<8 {
                bytes.append(UInt8((value >> UInt64(index * 8)) & 0xFF))
            }
        }
        func name16(_ text: String) {
            var field = Array(text.utf8)
            field = Array(field.prefix(16))
            field.append(contentsOf: [UInt8](repeating: 0, count: 16 - field.count))
            bytes.append(contentsOf: field)
        }

        // mach_header_64
        u32(0xFEEDFACF)   // magic
        u32(0x0100000C)   // cputype: arm64
        u32(0)            // cpusubtype
        u32(2)            // filetype: MH_EXECUTE
        u32(2)            // ncmds
        u32(152 + 72)     // sizeofcmds
        u32(0x00200085)   // flags
        u32(0)            // reserved

        // __TEXT
        u32(0x19)
        u32(152)
        name16("__TEXT")
        u64(0x1_0000_0000)
        u64(0x4000)
        u64(0)
        u64(UInt64(paddingTo))
        u32(7)
        u32(5)
        u32(1)            // nsects
        u32(0)

        // __text section
        name16("__text")
        name16("__TEXT")
        u64(0x1_0000_0000 + UInt64(paddingTo))
        u64(UInt64(payloadSize))
        u32(UInt32(paddingTo))
        u32(2)
        u32(0)
        u32(0)
        u32(0x80000400)
        u32(0)
        u32(0)
        u32(0)

        // __LINKEDIT
        u32(0x19)
        u32(72)
        name16("__LINKEDIT")
        u64(0x1_0000_4000)
        u64(0x4000)
        u64(UInt64(paddingTo))
        u64(UInt64(payloadSize))
        u32(7)
        u32(1)
        u32(0)
        u32(0)

        bytes.append(contentsOf: [UInt8](repeating: 0, count: paddingTo - bytes.count))
        bytes.append(contentsOf: [UInt8](repeating: 0x90, count: payloadSize))
        return Data(bytes)
    }

    static func fat() -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0xCA
        bytes[1] = 0xFE
        bytes[2] = 0xBA
        bytes[3] = 0xBE
        return Data(bytes)
    }
}

final class MachOTests: XCTestCase {

    func testParsesSegmentsAndSections() throws {
        let image = try MachOImage(data: MachOFixture.thin())
        XCTAssertEqual(image.segments.count, 2)
        XCTAssertEqual(image.segments.map(\.name), ["__TEXT", "__LINKEDIT"])
        XCTAssertEqual(image.availableHeaderPadding, 0x1000 - 256)
        XCTAssertNil(image.codeSignature)
    }

    func testRejectsFatBinary() {
        XCTAssertThrowsError(try MachOImage(data: MachOFixture.fat())) { error in
            guard case SignError.unsupported = error else {
                return XCTFail("应该报 unsupported，实际是 \(error)")
            }
        }
    }

    func testRejectsNonMachO() {
        XCTAssertThrowsError(try MachOImage(data: Data(repeating: 0, count: 64)))
    }

    func testInjectSignatureAndReparse() throws {
        var image = try MachOImage(data: MachOFixture.thin())
        let (offset, signedData) = image.prepareSignatureSlot()

        XCTAssertEqual(offset % 16, 0)
        XCTAssertEqual(signedData.count, offset)
        XCTAssertEqual(offset, 0x1100)   // 0x1000 + 0x100 已对齐

        let blob = [UInt8](repeating: 0xAB, count: 4096)
        try image.attachSignature(blob, at: offset)

        let reparsed = try MachOImage(data: image.data())
        let command = try XCTUnwrap(reparsed.codeSignature)
        XCTAssertEqual(Int(command.dataOffset), offset)
        XCTAssertEqual(Int(command.dataSize), blob.count)

        // __LINKEDIT 必须覆盖到文件末尾
        let linkedit = try XCTUnwrap(reparsed.segments.first { $0.name == "__LINKEDIT" })
        XCTAssertGreaterThanOrEqual(linkedit.fileoff + linkedit.filesize, UInt64(offset + blob.count))
        XCTAssertGreaterThanOrEqual(linkedit.vmsize, linkedit.filesize)
    }

    func testStripRemovesSignatureData() throws {
        var image = try MachOImage(data: MachOFixture.thin())
        let (offset, _) = image.prepareSignatureSlot()
        try image.attachSignature([UInt8](repeating: 0xCD, count: 2048), at: offset)
        let signedCount = image.data().count

        var stripped = try MachOImage(data: image.data())
        try stripped.stripExistingSignature()

        XCTAssertLessThan(stripped.data().count, signedCount)
        XCTAssertNil(try MachOImage(data: stripped.data()).codeSignature)
        XCTAssertEqual(stripped.data().count, offset)

        // 去掉签名后可以再次签名，说明结构可重复处理
        let (secondOffset, _) = stripped.prepareSignatureSlot()
        try stripped.attachSignature([UInt8](repeating: 0xEF, count: 1024), at: secondOffset)
        XCTAssertNotNil(try MachOImage(data: stripped.data()).codeSignature)
    }

    func testNoPaddingSpaceIsReported() throws {
        // 把第一个 section 的文件偏移压到紧贴 load commands，只剩 0 空隙
        var data = MachOFixture.thin(payloadSize: 0x10, paddingTo: 0x1000)
        var bytes = [UInt8](data)
        // __text section 的 offset 字段位于 32 + 72 + 48 = 152
        let sectionOffsetField = 32 + 72 + 48
        bytes[sectionOffsetField] = 0x00
        bytes[sectionOffsetField + 1] = 0x01
        bytes[sectionOffsetField + 2] = 0x00
        bytes[sectionOffsetField + 3] = 0x00
        data = Data(bytes)

        var image = try MachOImage(data: data)
        XCTAssertEqual(image.availableHeaderPadding, 0)

        let (offset, _) = image.prepareSignatureSlot()
        XCTAssertThrowsError(try image.attachSignature([0x00], at: offset))
    }
}
