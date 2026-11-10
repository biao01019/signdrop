import Foundation
import BigInt

/// SRP-6a 客户端。
///
/// 苹果账号登录不使用明文密码。客户端与服务端各自计算一份共享密钥，
/// 网络上传输的只有 A、B、M1 这些零知识证明，被截获也无法反推密码。
/// 这是"不保存明文密码"的前提。
///
/// 参数组用 RFC 5054 附录 A 的 2048 位群，g = 2，哈希 SHA-256 —— 苹果用的就是这一组。
/// 1024 位群只用于跑 RFC 官方向量（附录只给了 1024 位的完整测试数据）。
public struct SRPGroup {

    public let n: BigUInt
    public let g: BigUInt

    /// N 的字节长度，用于 PAD()。
    public var byteCount: Int {
        (n.bitWidth + 7) / 8
    }

    public init(nHex: String, g: UInt32 = 2) {
        guard let modulus = BigUInt(nHex, radix: 16) else {
            preconditionFailure("SRP 模数不是合法的十六进制串")
        }
        self.n = modulus
        self.g = BigUInt(g)
    }

    /// RFC 5054 附录 A，2048 位 —— 苹果生产环境使用这一组。
    public static let group2048 = SRPGroup(
        nHex: "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050"
            + "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50"
            + "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B"
            + "855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773"
            + "BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F8774"
            + "8544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE"
            + "6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB"
            + "694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    )

    /// RFC 5054 附录 A，1024 位 —— 仅用于对照官方向量。
    public static let group1024 = SRPGroup(
        nHex: "EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576"
            + "D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD1"
            + "5DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC"
            + "68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3"
    )
}

public final class SRPClient {

    public enum SRPError: LocalizedError {
        case invalidServerPublic
        case zeroScramble
        case notReady
        case serverProofMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidServerPublic:
                return "服务器下发的 B 非法（B mod N == 0），握手被拒绝"
            case .zeroScramble:
                return "服务器下发的混淆因子为 0，握手不可信"
            case .notReady:
                return "尚未收到服务器的 salt / B"
            case .serverProofMismatch:
                return "服务器返回的 M2 校验失败，可能存在中间人"
            }
        }
    }

    private let username: String
    private let password: String
    private let group: SRPGroup
    private let privateA: BigUInt
    private let publicA: BigUInt

    private var salt: Data?
    private var keyBytes: Data?
    private var proofM1: Data?
    private var proofM2: Data?
    private var premasterValue: BigUInt?

    /// - Parameter privateA: 仅测试时注入，用于复现 RFC 向量。
    public init(
        username: String,
        password: String,
        group: SRPGroup = .group2048,
        privateA: BigUInt? = nil
    ) {
        self.username = username
        self.password = password
        self.group = group
        self.privateA = privateA ?? BigUInt.randomInteger(withMaximumWidth: 1024)
        self.publicA = group.g.power(self.privateA, modulus: group.n)
    }

    // MARK: - 阶段一：把 A 交给服务器

    /// 定长大端字节（不足左侧补零），长度等于模数长度。
    public func publicAValue() -> Data {
        pad(publicA)
    }

    public var publicABase64: String {
        B64.encode(publicAValue())
    }

    // MARK: - 阶段二：收到 salt / B 后计算证明

    public func setServerValues(salt: Data, serverPublicB: Data) throws {
        let modulus = group.n
        guard let bValue = BigUInt(serverPublicB), bValue % modulus != BigUInt(0) else {
            throw SRPError.invalidServerPublic
        }

        self.salt = salt

        let k = toInt(hash(pad(modulus), pad(group.g)))
        let u = toInt(hash(pad(publicA), pad(bValue)))
        guard u != BigUInt(0) else { throw SRPError.zeroScramble }

        // x = H(salt | H(user:pass))
        let identity = hash(
            Data(username.lowercased().utf8),
            Data(":".utf8),
            Data(password.utf8)
        )
        let x = toInt(hash(salt, identity))

        // base = (B - k·g^x) mod N，先降幂再相减，避免 BigUInt 出现负数
        let gx = group.g.power(x, modulus: modulus)
        let base = (bValue + modulus - (k * gx) % modulus) % modulus

        let secret = base.power(privateA + u * x, modulus: modulus)
        premasterValue = secret
        let sessionKey = hash(pad(secret))
        keyBytes = sessionKey

        // M1 = H( H(N)⊕H(g) | H(user) | salt | A | B | K )
        let nHash = hash(pad(modulus))
        let gHash = hash(pad(group.g))
        let xorHash = Data(zip(nHash, gHash).map { $0.0 ^ $0.1 })

        proofM1 = hash(
            xorHash,
            hash(Data(username.lowercased().utf8)),
            salt,
            pad(publicA),
            pad(bValue),
            sessionKey
        )
        // M2 = H( A | M1 | K )
        proofM2 = hash(pad(publicA), proofM1 ?? Data(), sessionKey)
    }

    // MARK: - 阶段三：校验服务端

    public func proof() throws -> Data {
        guard let value = proofM1 else { throw SRPError.notReady }
        return value
    }

    public var proofBase64: String {
        B64.encode((try? proof()) ?? Data())
    }

    public func expectedServerProof() throws -> Data {
        guard let value = proofM2 else { throw SRPError.notReady }
        return value
    }

    public func verifyServerProof(_ value: Data) throws {
        guard let expected = proofM2 else { throw SRPError.notReady }
        guard constantTimeEquals(expected, value) else {
            throw SRPError.serverProofMismatch
        }
    }

    // MARK: - 输出

    /// H(S)，苹果拿它当后续请求的会话密钥。
    public var sessionKey: Data {
        keyBytes ?? Data()
    }

    /// S，仅用于对照测试向量。
    public var premaster: Data {
        guard let value = premasterValue else { return Data() }
        return pad(value)
    }

    /// 供测试断言用：把 A 的整数值取出来。
    public var publicAInteger: BigUInt {
        publicA
    }

    // MARK: - 内部

    private func pad(_ value: BigUInt) -> Data {
        var bytes = [UInt8](value.serialize())
        let width = group.byteCount
        if bytes.count == width { return Data(bytes) }
        if bytes.count > width { return Data(bytes.suffix(width)) }
        bytes = [UInt8](repeating: 0, count: width - bytes.count) + bytes
        return Data(bytes)
    }

    private func toInt(_ data: Data) -> BigUInt {
        BigUInt(data) ?? BigUInt(0)
    }

    private func hash(_ parts: Data...) -> Data {
        var combined = Data()
        for part in parts { combined.append(part) }
        return Hash.sha256(combined)
    }

    /// 定长比较，避免按字节短路泄漏信息。
    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
