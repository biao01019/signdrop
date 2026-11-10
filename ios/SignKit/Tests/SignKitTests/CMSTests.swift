import XCTest
import Foundation
@testable import SignKit

#if canImport(Security)
import Security

/// 用 openssl 校验 CMS 输出，这是在没有真机的情况下判断签名结构是否正确的唯一可靠手段。
final class CMSTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signkit-cms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testGeneratedCMSVerifiesWithOpenSSL() throws {
        guard let openssl = Shell.which("openssl") else {
            throw XCTSkip("环境里没有 openssl，跳过")
        }

        let identity = try makeIdentity(openssl: openssl)

        let content = Data("SignKit code directory placeholder".utf8)
        let signature = try CMSBuilder.signature(for: content, identity: identity)

        let sigURL = workDirectory.appendingPathComponent("sig.der")
        let contentURL = workDirectory.appendingPathComponent("content.bin")
        try Data(signature).write(to: sigURL)
        try content.write(to: contentURL)

        let output = try Shell.run(openssl, [
            "cms", "-verify",
            "-inform", "DER",
            "-in", sigURL.path,
            "-content", contentURL.path,
            "-noverify",
            "-binary"
        ])
        // 带 -binary 时 openssl 把校验通过的内容原样吐到 stdout，
        // 成功与否看退出码（非 0 会被 Shell.run 直接抛错）。
        XCTAssertTrue(
            output.contains("SignKit code directory placeholder") || output.contains("Verification successful"),
            "openssl 校验失败，输出：\(output)"
        )
    }

    func testTamperedContentFailsVerification() throws {
        guard let openssl = Shell.which("openssl") else {
            throw XCTSkip("环境里没有 openssl，跳过")
        }
        let identity = try makeIdentity(openssl: openssl)

        let original = Data("original payload".utf8)
        var tampered = original
        tampered[0] ^= 0xFF

        let signature = try CMSBuilder.signature(for: original, identity: identity)
        let sigURL = workDirectory.appendingPathComponent("sig2.der")
        let tamperedURL = workDirectory.appendingPathComponent("tampered.bin")
        try Data(signature).write(to: sigURL)
        try tampered.write(to: tamperedURL)

        XCTAssertThrowsError(
            try Shell.run(openssl, [
                "cms", "-verify",
                "-inform", "DER",
                "-in", sigURL.path,
                "-content", tamperedURL.path,
                "-noverify",
                "-binary"
            ])
        )
    }

    func testCMSContainsRequiredAttributes() throws {
        guard let openssl = Shell.which("openssl") else {
            throw XCTSkip("环境里没有 openssl，跳过")
        }
        let identity = try makeIdentity(openssl: openssl)
        let signature = try CMSBuilder.signature(for: Data("x".utf8), identity: identity)

        let sigURL = workDirectory.appendingPathComponent("sig3.der")
        try Data(signature).write(to: sigURL)

        let dump = try Shell.run(openssl, ["asn1parse", "-inform", "DER", "-in", sigURL.path])
        // contentType 与 messageDigest 是 Apple 强制要求的认证属性。
        // asn1parse 对已知 OID 打印名字而非点分数字，两种形式都接受。
        XCTAssertTrue(
            dump.contains("1.2.840.113549.1.9.3") || dump.contains("contentType"),
            "缺少 contentType 属性"
        )
        XCTAssertTrue(
            dump.contains("1.2.840.113549.1.9.4") || dump.contains("messageDigest"),
            "缺少 messageDigest 属性"
        )
        XCTAssertTrue(dump.contains("pkcs7-signedData") || dump.contains("1.2.840.113549.1.7.2"),
                      "外壳不是 SignedData")
    }

    // MARK: - 辅助

    private func makeIdentity(openssl: String) throws -> SigningIdentity {
        let keyURL = workDirectory.appendingPathComponent("key.pem")
        let certURL = workDirectory.appendingPathComponent("cert.pem")
        let p12URL = workDirectory.appendingPathComponent("identity.p12")

        try Shell.run(openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "1",
            "-subj", "/CN=SignKit Test (TEAM123456)/O=SignKit"
        ])

        // OpenSSL 3 默认用 AES-256-CBC + PBKDF2 + HMAC-SHA256 封 p12，
        // SecPKCS12Import 只认传统的 PBE-SHA1-3DES / SHA1 MAC，否则报 -25293。
        // 不同 openssl 发行版支持的参数不同，逐组降级尝试。
        let passphrase = "signkit"
        let base = ["pkcs12", "-export",
                    "-inkey", keyURL.path, "-in", certURL.path,
                    "-out", p12URL.path, "-passout", "pass:\(passphrase)"]
        let variants: [[String]] = [
            ["-legacy"],
            ["-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
            ["-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES"],
            []
        ]
        var exported = false
        for extra in variants {
            do {
                try Shell.run(openssl, base + extra)
                exported = true
                break
            } catch {
                try? FileManager.default.removeItem(at: p12URL)
            }
        }
        guard exported else {
            throw SignError.identity("无法导出测试 p12")
        }

        let p12Data = try Data(contentsOf: p12URL)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(p12Data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw SignError.identity("导入测试 p12 失败，状态码 \(status)")
        }

        let secIdentity = identityRef as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return try SigningIdentity(identity: secIdentity, certificates: chain, teamID: "TEAM123456")
    }
}

enum Shell {

    static func which(_ name: String) -> String? {
        let candidates = ["/usr/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outData, as: UTF8.self)
        let errorOutput = String(decoding: errData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Shell",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) 退出码 \(process.terminationStatus)：\(errorOutput)"]
            )
        }
        return output
    }
}
#endif
