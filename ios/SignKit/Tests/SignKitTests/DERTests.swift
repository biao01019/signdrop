import XCTest
@testable import SignKit

final class DERTests: XCTestCase {

    func testLengthEncoding() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(127), [0x7F])
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(255), [0x81, 0xFF])
        XCTAssertEqual(DER.length(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(DER.length(65535), [0x82, 0xFF, 0xFF])
    }

    func testIntegerEncoding() {
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(1), [0x02, 0x01, 0x01])
        // 最高位为 1 时必须补 0x00，否则会被当成负数
        XCTAssertEqual(DER.integer(128), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(DER.integer(255), [0x02, 0x02, 0x00, 0xFF])
        XCTAssertEqual(DER.integer(256), [0x02, 0x02, 0x01, 0x00])
    }

    func testOIDEncoding() {
        // PKCS#7 signedData
        XCTAssertEqual(
            DER.oid("1.2.840.113549.1.7.2"),
            [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        )
        // SHA-256
        XCTAssertEqual(
            DER.oid("2.16.840.1.101.3.4.2.1"),
            [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        )
        // commonName
        XCTAssertEqual(DER.oid("2.5.4.3"), [0x06, 0x03, 0x55, 0x04, 0x03])
    }

    func testSetMustBeSorted() {
        let integer = DER.integer(2)                     // 02 01 02
        let sequence = DER.sequence([DER.integer(1)])    // 30 03 02 01 01
        // 0x02 < 0x30，排序后 integer 在前；顺序传反也必须输出同样结果
        let expected: [UInt8] = [0x31, 0x08] + integer + sequence
        XCTAssertEqual(DER.set([integer, sequence]), expected)
        XCTAssertEqual(DER.set([sequence, integer]), expected)
    }

    func testContextTag() {
        XCTAssertEqual(DER.context(0, constructed: true, [0x01]), [0xA0, 0x01, 0x01])
        XCTAssertEqual(DER.context(1, constructed: true, [0x00]), [0xA1, 0x01, 0x00])
    }

    func testScannerReadsNestedSequence() {
        let inner = DER.sequence([DER.integer(7), DER.utf8String("ab")])
        let outer = DER.sequence([inner])
        var scanner = DERScanner(outer)
        let root = scanner.read()
        XCTAssertEqual(root?.tag, 0x30)

        var innerScanner = DERScanner(root!.bytes, offset: root!.contentStart)
        let first = innerScanner.read()
        XCTAssertEqual(first?.tag, 0x30)

        var leafScanner = DERScanner(first!.bytes, offset: first!.contentStart)
        XCTAssertEqual(leafScanner.read()?.tag, 0x02)
        XCTAssertEqual(leafScanner.read()?.content, [0x61, 0x62])
    }
}

final class CodeDirectoryTests: XCTestCase {

    private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    func testHeaderAndLayout() throws {
        let data = Data(repeating: 0x41, count: 5000)
        let blob = try CodeDirectoryBuilder.build(
            data: data,
            options: CodeDirectoryBuilder.Options(
                identifier: "com.test.app",
                codeLimit: 5000
            )
        )

        XCTAssertEqual(readUInt32(blob, 0), 0xFADE0C02)
        XCTAssertEqual(readUInt32(blob, 4), UInt32(blob.count))
        XCTAssertEqual(readUInt32(blob, 8), 0x20400)
        XCTAssertEqual(readUInt32(blob, 20), 88)                 // identOffset
        XCTAssertEqual(readUInt32(blob, 24), 0)                  // nSpecialSlots
        XCTAssertEqual(readUInt32(blob, 28), 2)                  // nCodeSlots：5000 字节 = 2 页
        XCTAssertEqual(readUInt32(blob, 32), 5000)               // codeLimit
        XCTAssertEqual(blob[36], 32)                             // hashSize
        XCTAssertEqual(blob[37], 2)                              // hashType = sha256
        XCTAssertEqual(blob[39], 12)                             // pageSize = 2^12

        // identOffset 之后是 "com.test.app\0"
        let identBytes = Array(blob[88..<(88 + 13)])
        XCTAssertEqual(String(decoding: identBytes.dropLast(), as: UTF8.self), "com.test.app")
    }

    func testCodeSlotHashesMatchPages() throws {
        let data = Data(repeating: 0x41, count: 5000)
        let blob = try CodeDirectoryBuilder.build(
            data: data,
            options: CodeDirectoryBuilder.Options(
                identifier: "a",
                codeLimit: 5000
            )
        )
        let hashOffset = Int(readUInt32(blob, 16))
        XCTAssertEqual(hashOffset, 88 + 2)

        let firstPage = Hash.sha256(Data(data[0..<4096]))
        let secondPage = Hash.sha256(Data(data[4096..<5000]))
        XCTAssertEqual(Array(blob[hashOffset..<(hashOffset + 32)]), firstPage)
        XCTAssertEqual(Array(blob[(hashOffset + 32)..<(hashOffset + 64)]), secondPage)
        // 最后一页按实际长度计算，不做补零
        XCTAssertNotEqual(secondPage, Hash.sha256(Data(repeating: 0x41, count: 4096)))
    }

    func testSpecialSlotsArePaddedInReverseOrder() throws {
        let data = Data(repeating: 0x00, count: 100)
        let entitlementsHash = [UInt8](repeating: 0xEE, count: 32)
        let blob = try CodeDirectoryBuilder.build(
            data: data,
            options: CodeDirectoryBuilder.Options(
                identifier: "x",
                codeLimit: 100,
                specialSlots: [1: [UInt8](repeating: 0x11, count: 32), 5: entitlementsHash]
            )
        )

        let nSpecial = Int(readUInt32(blob, 24))
        let hashOffset = Int(readUInt32(blob, 16))
        XCTAssertEqual(nSpecial, 5)
        XCTAssertEqual(hashOffset, 88 + 2 + 5 * 32)

        // slot -1 紧挨在 hashOffset 之前
        XCTAssertEqual(Array(blob[(hashOffset - 32)..<hashOffset]), [UInt8](repeating: 0x11, count: 32))
        // slot -5 在特殊区最前面
        let slot5 = hashOffset - 5 * 32
        XCTAssertEqual(Array(blob[slot5..<(slot5 + 32)]), entitlementsHash)
        // 未提供的槽填零
        XCTAssertEqual(Array(blob[(hashOffset - 64)..<(hashOffset - 32)]), [UInt8](repeating: 0, count: 32))
    }

    func testZeroCodeLimitThrows() {
        XCTAssertThrowsError(
            try CodeDirectoryBuilder.build(
                data: Data(),
                options: CodeDirectoryBuilder.Options(identifier: "x", codeLimit: 0)
            )
        )
    }
}

final class SuperBlobTests: XCTestCase {

    func testIndexOffsetsAreAbsolute() {
        let cd = [UInt8](repeating: 0x01, count: 10)
        let req = [UInt8](repeating: 0x02, count: 12)
        let blob = SuperBlob.build(entries: [
            .init(slot: .codeDirectory, blob: cd),
            .init(slot: .requirements, blob: req)
        ])

        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(blob[offset]) << 24 | UInt32(blob[offset + 1]) << 16
                | UInt32(blob[offset + 2]) << 8 | UInt32(blob[offset + 3])
        }

        XCTAssertEqual(readUInt32(0), 0xFADE0CC0)
        XCTAssertEqual(readUInt32(4), UInt32(blob.count))
        XCTAssertEqual(readUInt32(8), 2)
        XCTAssertEqual(readUInt32(12), 0)                       // slot: codeDirectory
        XCTAssertEqual(readUInt32(16), 28)                      // 12 + 2*8
        XCTAssertEqual(readUInt32(20), CSSlot.requirements.rawValue)
        XCTAssertEqual(readUInt32(24), 38)                      // 28 + 10
        XCTAssertEqual(Array(blob[28..<38]), cd)
        XCTAssertEqual(Array(blob[38..<50]), req)
    }
}
