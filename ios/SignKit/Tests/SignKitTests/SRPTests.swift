import XCTest
import BigInt
@testable import SignKit

/// SRP 是整条 Apple ID 链路的数学基础，错了后面全错，所以单独钉几个锚点。
///
/// RFC 5054 附录只给出了 1024 位群的完整向量，而且用 SHA-1；苹果用 2048 位 + SHA-256。
/// 这里不搬那组向量（哈希不同，对不上），改成三类更本质的检查：
///   1. 参数组的位宽必须精确（少一位就会和苹果协商失败，这个坑真踩过）
///   2. 在一个能手算的小群里验证模幂
///   3. 定长输出的字节数必须等于模数长度，否则 PAD() 会把协议弄乱
final class SRPTests: XCTestCase {

    func testGroup2048Width() {
        let group = SRPGroup.group2048
        XCTAssertEqual(group.n.bitWidth, 2048, "N 必须是 2048 位，少一位就会和苹果协商失败")
        XCTAssertEqual(group.byteCount, 256)
        XCTAssertEqual(group.g, BigUInt(2))
    }

    func testGroup1024Width() {
        let group = SRPGroup.group1024
        XCTAssertEqual(group.n.bitWidth, 1024)
        XCTAssertEqual(group.byteCount, 128)
    }

    /// 小群手算：N = 23, g = 5, a = 6 → A = 5^6 mod 23 = 15625 mod 23 = 8。
    /// 这条能直接验证 `power(_:modulus:)` 和 PAD 的配合没问题。
    func testPublicAInSmallGroup() {
        let group = SRPGroup(nHex: "17", g: 5)
        let client = SRPClient(
            username: "alice",
            password: "password123",
            group: group,
            privateA: BigUInt(6)
        )
        XCTAssertEqual(client.publicAInteger, BigUInt(8))
        XCTAssertEqual(client.publicAValue(), Data([0x08]))
    }

    func testPublicAIsFixedWidth() {
        let client = SRPClient(username: "a@b.com", password: "secret")
        XCTAssertEqual(client.publicAValue().count, 256, "A 必须补齐到模数长度")
        XCTAssertEqual(client.publicABase64.isEmpty, false)
    }

    func testSamePrivateKeyProducesSameA() {
        let a = BigUInt("60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393", radix: 16)!
        let first = SRPClient(username: "x@y.com", password: "p", privateA: a)
        let second = SRPClient(username: "x@y.com", password: "p", privateA: a)
        XCTAssertEqual(first.publicAValue(), second.publicAValue())
    }

    func testDifferentRandomKeysProduceDifferentA() {
        let first = SRPClient(username: "x@y.com", password: "p")
        let second = SRPClient(username: "x@y.com", password: "p")
        XCTAssertNotEqual(first.publicAValue(), second.publicAValue())
    }

    func testRejectsZeroServerPublic() {
        let client = SRPClient(username: "x@y.com", password: "p")
        XCTAssertThrowsError(try client.setServerValues(salt: Data(repeating: 1, count: 16),
                                                        serverPublicB: Data(repeating: 0, count: 256)))
    }

    func testProofRequiresServerValues() {
        let client = SRPClient(username: "x@y.com", password: "p")
        XCTAssertThrowsError(try client.proof())
        XCTAssertThrowsError(try client.expectedServerProof())
    }

    /// 客户端自洽：同一组 salt/B 下，M1、M2、会话密钥的长度必须正确。
    /// （M1 的具体值取决于随机 a，无法预先固定，只能校验结构。）
    func testHandshakeShapes() throws {
        let client = SRPClient(username: "x@y.com", password: "p")
        let salt = Data((0..<16).map { UInt8($0) })
        // B 用 N-1 这种合法但无规律的值，确保不触发 B mod N == 0
        let modulus = SRPGroup.group2048.n
        let b = modulus - BigUInt(1)
        let bData = Data([UInt8](b.serialize()))

        try client.setServerValues(salt: salt, serverPublicB: bData)

        XCTAssertEqual(try client.proof().count, 32)
        XCTAssertEqual(try client.expectedServerProof().count, 32)
        XCTAssertEqual(client.sessionKey.count, 32)
        XCTAssertEqual(client.premaster.count, 256)
        XCTAssertFalse(client.proofBase64.isEmpty)
    }

    /// 客户端与服务端两条独立路径必须算出同一个 S、同一个 M1。
    /// 服务端公式直接照 RFC 5054 写，不复用客户端的中间量。
    func testClientAndServerAgree() throws {
        let username = "alice@example.com"
        let password = "correct horse battery staple"
        let group = SRPGroup.group2048
        let salt = Data((0..<16).map { UInt8($0 &* 7) })
        let privateB = BigUInt.randomInteger(withMaximumWidth: 512)

        let client = SRPClient(username: username, password: password, group: group)

        // 服务端：v = g^x, B = k*v + g^b
        let identity = Hash.sha256(Data("\(username):\(password)".utf8))
        let x = BigUInt(Hash.sha256(salt + identity))!
        let v = group.g.power(x, modulus: group.n)

        func pad(_ value: BigUInt) -> Data {
            var bytes = [UInt8](value.serialize())
            let width = group.byteCount
            if bytes.count < width {
                bytes = [UInt8](repeating: 0, count: width - bytes.count) + bytes
            }
            return Data(bytes)
        }

        let k = BigUInt(Hash.sha256(pad(group.n) + pad(group.g)))!
        let serverB = (k * v + group.g.power(privateB, modulus: group.n)) % group.n

        try client.setServerValues(salt: salt, serverPublicB: pad(serverB))

        // 服务端独立算 S
        let aValue = BigUInt(client.publicAValue())!
        let u = BigUInt(Hash.sha256(pad(aValue) + pad(serverB)))!
        let serverS = (aValue * v.power(u, modulus: group.n)).power(privateB, modulus: group.n)
        let serverKey = Hash.sha256(pad(serverS))

        XCTAssertEqual(client.premaster, pad(serverS), "两端协商出的 S 必须一致")
        XCTAssertEqual(client.sessionKey, serverKey, "会话密钥必须一致")

        // 服务端独立算 M1
        let nHash = Hash.sha256(pad(group.n))
        let gHash = Hash.sha256(pad(group.g))
        let xorHash = Data(zip(nHash, gHash).map { $0.0 ^ $0.1 })
        let expectedM1 = Hash.sha256(
            xorHash
                + Hash.sha256(Data(username.lowercased().utf8))
                + salt
                + pad(aValue)
                + pad(serverB)
                + serverKey
        )
        XCTAssertEqual(try client.proof(), expectedM1, "客户端 M1 必须与服务端一致")
    }
}
