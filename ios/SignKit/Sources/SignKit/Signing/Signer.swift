import Foundation
import ZIPFoundation

public struct SignConfiguration {

    /// 留空表示沿用原 Bundle ID，只做重签。
    public var newBundleID: String?
    public var displayName: String?
    public var identity: SigningIdentity
    public var profile: ProvisioningProfile
    /// 用于校验描述文件是否覆盖这台设备
    public var deviceUDID: String?

    public init(
        newBundleID: String? = nil,
        displayName: String? = nil,
        identity: SigningIdentity,
        profile: ProvisioningProfile,
        deviceUDID: String? = nil
    ) {
        self.newBundleID = newBundleID
        self.displayName = displayName
        self.identity = identity
        self.profile = profile
        self.deviceUDID = deviceUDID
    }
}

public struct SignOutcome {
    public let outputURL: URL
    public let bundleID: String
    public let displayName: String
    public let signedUnitCount: Int
    public let expiresAt: Date
    public let sizeBytes: UInt64
}

public enum Signer {

    public typealias ProgressHandler = (Double, String) -> Void

    public static func sign(
        ipa: URL,
        to output: URL,
        configuration: SignConfiguration,
        progress: ProgressHandler? = nil
    ) throws -> SignOutcome {

        let fm = FileManager.default
        let workRoot = fm.temporaryDirectory
            .appendingPathComponent("signkit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workRoot) }

        // 1. 解压
        progress?(0.03, "解压安装包")
        let unpacked = workRoot.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: ipa, to: unpacked)
        } catch {
            throw SignError.archive("解压失败：\(error.localizedDescription)")
        }

        let payload = unpacked.appendingPathComponent("Payload", isDirectory: true)
        guard fm.fileExists(atPath: payload.path) else {
            throw SignError.archive("缺少 Payload 目录，这不是有效的 IPA 文件")
        }

        // 2. 扫描
        progress?(0.10, "分析包结构")
        var bundles = try BundleScanner.scan(payload: payload)
        guard let mainIndex = bundles.firstIndex(where: { $0.kind == .mainApp }) else {
            throw SignError.archive("Payload 里没有主程序")
        }

        let oldMainID = bundles[mainIndex].bundleID
        guard !oldMainID.isEmpty else {
            throw SignError.archive("主程序的 Info.plist 缺少 CFBundleIdentifier")
        }

        let requested = configuration.newBundleID?.trimmingCharacters(in: .whitespaces)
        let newMainID = (requested?.isEmpty == false) ? requested! : oldMainID

        // 3. 前置校验：早失败比签完再失败好得多
        try validate(bundleID: newMainID)
        try validateProfile(configuration, bundleID: newMainID)

        let displayName = configuration.displayName?.trimmingCharacters(in: .whitespaces)
        let finalName = (displayName?.isEmpty == false) ? displayName! : (bundles[mainIndex].infoPlist["CFBundleDisplayName"] as? String ?? "")

        // 4. 改写标识
        progress?(0.16, "改写 Bundle ID")
        for index in bundles.indices {
            try BundleRewriter.apply(
                to: &bundles[index],
                oldMainID: oldMainID,
                newMainID: newMainID,
                displayName: finalName
            )
        }

        // 5. 从内到外逐个签名
        let ordered = bundles.sorted { $0.depth > $1.depth }
        let total = max(ordered.count, 1)

        for (index, bundle) in ordered.enumerated() {
            let ratio = 0.18 + 0.62 * (Double(index) / Double(total))
            progress?(ratio, "签名 \(bundle.relativePath)")

            try BundleRewriter.stripSignatureArtifacts(in: bundle.url)

            if bundle.kind.needsEntitlements {
                try configuration.profile.raw.write(
                    to: bundle.url.appendingPathComponent("embedded.mobileprovision"),
                    options: .atomic
                )
            }

            guard let executable = bundle.executableURL,
                  fm.fileExists(atPath: executable.path) else { continue }

            let entitlements = BundleRewriter.entitlements(for: bundle, profile: configuration.profile)
            try signExecutable(
                at: executable,
                identifier: bundle.bundleID,
                teamID: configuration.profile.teamIdentifier,
                entitlements: entitlements,
                identity: configuration.identity,
                infoPlist: bundle.url.appendingPathComponent("Info.plist")
            )
        }

        // 6. 重新打包
        progress?(0.85, "重新打包")
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        try fm.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fm.zipItem(
                at: unpacked,
                to: output,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
        } catch {
            throw SignError.archive("打包失败：\(error.localizedDescription)")
        }

        progress?(0.97, "校验产物")
        let attributes = try? fm.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        progress?(1.0, "完成")
        return SignOutcome(
            outputURL: output,
            bundleID: newMainID,
            displayName: finalName,
            signedUnitCount: ordered.count,
            expiresAt: configuration.profile.expirationDate,
            sizeBytes: size
        )
    }

    // MARK: - 校验

    private static func validate(bundleID: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleID.isEmpty,
              bundleID.rangeOfCharacter(from: allowed.inverted) == nil,
              bundleID.contains(".") else {
            throw SignError.archive("Bundle ID「\(bundleID)」不合法，只能包含字母、数字、点和短横线，且需要至少一个点")
        }
    }

    private static func validateProfile(_ configuration: SignConfiguration, bundleID: String) throws {
        let profile = configuration.profile

        if profile.isExpired {
            throw SignError.profile(
                "描述文件已于 \(Self.dateFormatter.string(from: profile.expirationDate)) 过期，请重新生成"
            )
        }

        guard profile.canSign(bundleID: bundleID) else {
            let hint = profile.isWildcard
                ? "该描述文件只覆盖 \(profile.applicationIdentifier)，新的 Bundle ID 必须落在这个前缀下"
                : "该描述文件绑定的 App ID 是 \(profile.applicationIdentifier)，改 Bundle ID 需要重新生成描述文件"
            throw SignError.profile(hint)
        }

        if let udid = configuration.deviceUDID, !profile.includesDevice(udid: udid) {
            throw SignError.profile("描述文件的设备列表里没有这台设备（\(udid)），请先把它加进开发者后台")
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - 单个可执行文件

    /// 对单个 Mach-O 做完整签名。
    ///
    /// 顺序不能颠倒：CodeDirectory 的 codeLimit 就是签名区起点，
    /// 而 CodeDirectory 本身又是被 CMS 签名的内容。
    static func signExecutable(
        at url: URL,
        identifier: String,
        teamID: String,
        entitlements: [String: Any],
        identity: SigningIdentity,
        infoPlist: URL?
    ) throws {

        let original = try Data(contentsOf: url)
        var image: MachOImage
        do {
            image = try MachOImage(data: original)
        } catch SignError.unsupported {
            throw SignError.unsupported(
                "\(url.lastPathComponent) 是通用二进制（fat），请先用 lipo 拆成 arm64 单一架构"
            )
        }

        try image.stripExistingSignature()
        let (slotOffset, signedData) = image.prepareSignatureSlot()

        let requirements = RequirementsBlob.empty()
        let entitlementsBlob = entitlements.isEmpty ? nil : try EntitlementsBlob.build(plist: entitlements)

        // 特殊槽编号遵循 cs_blobs.h：-1 Info.plist、-2 Requirements、-5 Entitlements
        var specialSlots: [Int: [UInt8]] = [:]
        if let infoPlist, let plistData = try? Data(contentsOf: infoPlist) {
            specialSlots[1] = Array(Hash.sha256(plistData))
        }
        specialSlots[2] = Hash.sha256(requirements)
        if let entitlementsBlob {
            specialSlots[5] = Hash.sha256(entitlementsBlob)
        }

        let directory = try CodeDirectoryBuilder.build(
            data: signedData,
            options: CodeDirectoryBuilder.Options(
                identifier: identifier,
                teamID: teamID.isEmpty ? nil : teamID,
                codeLimit: slotOffset,
                hashType: .sha256,
                flags: 0,
                specialSlots: specialSlots
            )
        )

        let cms = try CMSBuilder.signature(for: Data(directory), identity: identity)

        var entries: [SuperBlob.Entry] = [
            SuperBlob.Entry(slot: .codeDirectory, blob: directory),
            SuperBlob.Entry(slot: .requirements, blob: requirements)
        ]
        if let entitlementsBlob {
            entries.append(SuperBlob.Entry(slot: .entitlements, blob: entitlementsBlob))
        }
        entries.append(SuperBlob.Entry(slot: .signature, blob: cms))

        let superBlob = SuperBlob.build(entries: entries)
        try image.attachSignature(superBlob, at: slotOffset)

        try image.data().write(to: url, options: .atomic)
        // 原子写会重建文件，权限会掉成 644。可执行位丢了，装上去就点不开。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
