import XCTest
@testable import SignKit

final class ProfileTests: XCTestCase {

    private func makeProfile(
        appID: String = "ABCDE12345.com.example.*",
        expiration: Date = Date().addingTimeInterval(86400 * 30),
        devices: [String]? = ["00008030-001A2B3C4D5E6F70"],
        allDevices: Bool = false
    ) throws -> Data {
        var plist: [String: Any] = [
            "Name": "SignKit Test Profile",
            "TeamIdentifier": ["ABCDE12345"],
            "ApplicationIdentifierPrefix": ["ABCDE12345"],
            "CreationDate": Date().addingTimeInterval(-86400),
            "ExpirationDate": expiration,
            "Entitlements": [
                "application-identifier": appID,
                "com.apple.developer.team-identifier": "ABCDE12345",
                "get-task-allow": true,
                "keychain-access-groups": [appID]
            ],
            "UUID": UUID().uuidString,
            "DeveloperCertificates": [Data([0x30, 0x03, 0x02, 0x01, 0x01])]
        ]
        if let devices {
            plist["ProvisionedDevices"] = devices
        }
        if allDevices {
            plist["ProvisionsAllDevices"] = true
        }

        let inner = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        // 模拟 CMS 外壳：前面是 ASN.1 头，后面是填充
        var wrapped = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])
        wrapped.append(inner)
        wrapped.append(Data([0x00, 0x00, 0x00]))
        return wrapped
    }

    func testParsesWrappedPlist() throws {
        let profile = try ProvisioningProfile(data: makeProfile())
        XCTAssertEqual(profile.name, "SignKit Test Profile")
        XCTAssertEqual(profile.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(profile.applicationIdentifier, "ABCDE12345.com.example.*")
        XCTAssertEqual(profile.provisionedDevices, ["00008030-001A2B3C4D5E6F70"])
        XCTAssertEqual(profile.entitlements["get-task-allow"] as? Bool, true)
        XCTAssertFalse(profile.isExpired)
        XCTAssertTrue(profile.isWildcard)
    }

    func testWildcardCoversSubdomains() throws {
        let profile = try ProvisioningProfile(data: makeProfile())
        XCTAssertTrue(profile.canSign(bundleID: "com.example.app"))
        XCTAssertTrue(profile.canSign(bundleID: "com.example.app.widget"))
        XCTAssertFalse(profile.canSign(bundleID: "com.other.app"))
    }

    func testFullyWildcardProfileAcceptsAnyBundleID() throws {
        // "TEAMID.*" 是最常见的通配描述文件，任何 Bundle ID 都该放行
        let profile = try ProvisioningProfile(data: makeProfile(appID: "ABCDE12345.*"))
        XCTAssertTrue(profile.canSign(bundleID: "com.anything.at.all"))
        XCTAssertTrue(profile.canSign(bundleID: "singleword"))
    }

    func testExactAppIDRejectsOtherBundleIDs() throws {
        let profile = try ProvisioningProfile(
            data: makeProfile(appID: "ABCDE12345.com.example.app")
        )
        XCTAssertFalse(profile.isWildcard)
        XCTAssertTrue(profile.canSign(bundleID: "com.example.app"))
        XCTAssertFalse(profile.canSign(bundleID: "com.example.other"))
    }

    func testDeviceWhitelist() throws {
        let profile = try ProvisioningProfile(data: makeProfile())
        XCTAssertTrue(profile.includesDevice(udid: "00008030-001A2B3C4D5E6F70"))
        XCTAssertFalse(profile.includesDevice(udid: "00008030-FFFFFFFFFFFFFFFF"))
    }

    func testEnterpriseProfileHasNoDeviceLimit() throws {
        let profile = try ProvisioningProfile(
            data: makeProfile(devices: nil, allDevices: true)
        )
        XCTAssertTrue(profile.provisionsAllDevices)
        XCTAssertTrue(profile.includesDevice(udid: "任意设备"))
    }

    func testExpiredProfileIsDetected() throws {
        let past = Date().addingTimeInterval(-86400 * 2)
        let profile = try ProvisioningProfile(data: makeProfile(expiration: past))
        XCTAssertTrue(profile.isExpired)
        XCTAssertLessThan(profile.daysRemaining, 0)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try ProvisioningProfile(data: Data(repeating: 0x41, count: 512))) { error in
            guard case SignError.profile = error else {
                return XCTFail("应该报 profile 错误，实际是 \(error)")
            }
        }
    }
}

final class BundleRewriterTests: XCTestCase {

    func testRemapsNestedIdentifiers() {
        let old = "com.old.app"
        let new = "com.new.app"

        XCTAssertEqual(
            BundleRewriter.remappedID(original: old, oldMainID: old, newMainID: new),
            new
        )
        XCTAssertEqual(
            BundleRewriter.remappedID(original: "com.old.app.widget", oldMainID: old, newMainID: new),
            "com.new.app.widget"
        )
        // 第三方框架不在原主包前缀下，必须原样保留
        XCTAssertEqual(
            BundleRewriter.remappedID(original: "com.alamofire.AFNetworking", oldMainID: old, newMainID: new),
            "com.alamofire.AFNetworking"
        )
    }

    func testEntitlementsFollowTeamAndBundleID() throws {
        let plist: [String: Any] = [
            "Name": "P",
            "TeamIdentifier": ["TEAM123456"],
            "ExpirationDate": Date().addingTimeInterval(86400),
            "Entitlements": [
                "application-identifier": "TEAM123456.com.example.*",
                "keychain-access-groups": ["TEAM123456.com.example.*"],
                "get-task-allow": true
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let profile = try ProvisioningProfile(data: data)
        let bundle = SignableBundle(
            url: URL(fileURLWithPath: "/tmp/X.app"),
            kind: .mainApp,
            relativePath: "X.app",
            bundleID: "com.changed.id",
            infoPlist: [:],
            executableURL: nil,
            depth: 0
        )

        let entitlements = BundleRewriter.entitlements(for: bundle, profile: profile)
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TEAM123456.com.changed.id")
        XCTAssertEqual(
            entitlements["keychain-access-groups"] as? [String],
            ["TEAM123456.com.changed.id"]
        )
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String, "TEAM123456")
        XCTAssertEqual(entitlements["get-task-allow"] as? Bool, true)
    }

    func testFrameworkGetsNoEntitlements() throws {
        let plist: [String: Any] = [
            "Name": "P",
            "TeamIdentifier": ["TEAM123456"],
            "ExpirationDate": Date().addingTimeInterval(86400),
            "Entitlements": ["application-identifier": "TEAM123456.*"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let profile = try ProvisioningProfile(data: data)
        let framework = SignableBundle(
            url: URL(fileURLWithPath: "/tmp/X.framework"),
            kind: .framework,
            relativePath: "X.framework",
            bundleID: "com.example.lib",
            infoPlist: [:],
            executableURL: nil,
            depth: 1
        )
        XCTAssertTrue(BundleRewriter.entitlements(for: framework, profile: profile).isEmpty)
    }
}
