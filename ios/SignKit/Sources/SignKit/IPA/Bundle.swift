import Foundation

/// 包内一个可签名的单元（主 App、扩展、框架、Watch App）。
public struct SignableBundle {

    public enum Kind: String {
        case mainApp = "主程序"
        case appExtension = "扩展"
        case framework = "动态库"
        case watchApp = "Watch App"
        case other = "其他"

        /// 框架与 dylib 不带 entitlements
        public var needsEntitlements: Bool {
            self != .framework
        }
    }

    public let url: URL
    public let kind: Kind
    /// 相对于解压根目录的路径，用于生成可读日志
    public let relativePath: String
    public var bundleID: String
    public var infoPlist: [String: Any]
    public var executableURL: URL?
    /// 嵌套深度，越大越靠内层，签名时先处理
    public var depth: Int

    public var executableName: String {
        infoPlist["CFBundleExecutable"] as? String ?? ""
    }
}

public enum BundleScanner {

    /// 扫描整个 Payload，按"内层在前"的顺序返回所有可签名单元。
    public static func scan(payload: URL) throws -> [SignableBundle] {
        guard let appURL = try findMainApp(in: payload) else {
            throw SignError.archive("Payload 里没有找到 .app 目录")
        }

        var results: [SignableBundle] = []
        try collect(bundleURL: appURL, kind: .mainApp, depth: 0, root: payload, into: &results)

        // 深度降序：先签框架和扩展，最后签主 App
        return results.sorted { $0.depth > $1.depth }
    }

    public static func findMainApp(in payload: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let apps = contents.filter { $0.pathExtension == "app" }
        // 有多个 .app 时取目录最大的那个（通常是主包，其余是 Watch 子包）
        return apps.max { lhs, rhs in
            directorySize(lhs) < directorySize(rhs)
        }
    }

    private static func collect(
        bundleURL: URL,
        kind: SignableBundle.Kind,
        depth: Int,
        root: URL,
        into results: inout [SignableBundle]
    ) throws {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            // Watch App 的 stub 可能没有 Info.plist，跳过但不报错
            return
        }

        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let executable = plist["CFBundleExecutable"] as? String
        let executableURL = executable.map { bundleURL.appendingPathComponent($0) }

        results.append(
            SignableBundle(
                url: bundleURL,
                kind: kind,
                relativePath: relativePath(of: bundleURL, under: root),
                bundleID: bundleID,
                infoPlist: plist,
                executableURL: executableURL,
                depth: depth
            )
        )

        // 嵌套目录：Frameworks 里可能是 framework 或 dylib，PlugIns/Extensions 里是 appex
        let nestedContainers = ["Frameworks", "PlugIns", "Extensions", "Watch", "AppClips"]

        for container in nestedContainers {
            let containerURL = bundleURL.appendingPathComponent(container)
            guard FileManager.default.fileExists(atPath: containerURL.path) else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                let ext = child.pathExtension
                let childKind: SignableBundle.Kind
                switch ext {
                case "framework": childKind = .framework
                case "appex": childKind = .appExtension
                case "app":
                    childKind = kind == .mainApp && container == "Watch" ? .watchApp : .other
                case "dylib":
                    // 裸动态库没有 Info.plist，单独登记后继续
                    results.append(
                        SignableBundle(
                            url: child,
                            kind: .framework,
                            relativePath: relativePath(of: child, under: root),
                            bundleID: child.deletingPathExtension().lastPathComponent,
                            infoPlist: [:],
                            executableURL: child,
                            depth: depth + 1
                        )
                    )
                    continue
                default: continue
                }
                try collect(
                    bundleURL: child,
                    kind: childKind,
                    depth: depth + 1,
                    root: root,
                    into: &results
                )
            }
        }
    }

    public static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        var trimmed = String(full.dropFirst(base.count))
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return trimmed
    }

    public static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(size)
        }
        return total
    }
}

/// 修改包标识与显示名。
public enum BundleRewriter {

    /// 计算新的 Bundle ID。
    ///
    /// 主包用用户指定的新 ID；嵌套单元把原来的主包前缀换成新前缀，
    /// 这样 `com.old.app.widget` 会变成 `com.new.app.widget`，保持层级关系。
    public static func remappedID(
        original: String,
        oldMainID: String,
        newMainID: String
    ) -> String {
        if original == oldMainID { return newMainID }
        if original.hasPrefix(oldMainID + ".") {
            return newMainID + original.dropFirst(oldMainID.count)
        }
        // 前缀不匹配（第三方 SDK 框架）时保持原 ID，避免把别人的标识改坏
        return original
    }

    public static func apply(
        to bundle: inout SignableBundle,
        oldMainID: String,
        newMainID: String,
        displayName: String?
    ) throws {
        let newID = remappedID(
            original: bundle.bundleID,
            oldMainID: oldMainID,
            newMainID: newMainID
        )
        bundle.bundleID = newID

        // 裸 dylib 没有 Info.plist。这里必须提前返回：如果继续往空字典里塞键，
        // 会把一个 .dylib 文件当成目录写 Info.plist，直接失败。
        guard !bundle.infoPlist.isEmpty else { return }

        bundle.infoPlist["CFBundleIdentifier"] = newID

        if bundle.kind == .mainApp, let displayName, !displayName.isEmpty {
            bundle.infoPlist["CFBundleDisplayName"] = displayName
            bundle.infoPlist["CFBundleName"] = displayName
        }

        let plistURL = bundle.url.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: bundle.infoPlist,
            format: .binary,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    /// 清掉旧签名残留。顺序无所谓，但 `_CodeSignature` 必须整个删掉，
    /// 否则系统会拿旧的资源封印去校验新包。
    public static func stripSignatureArtifacts(in bundleURL: URL) throws {
        let fm = FileManager.default
        let candidates = ["_CodeSignature", "SC_Info"]
        for name in candidates {
            let target = bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
        let codeResources = bundleURL.appendingPathComponent("CodeResources")
        if fm.fileExists(atPath: codeResources.path) {
            try fm.removeItem(at: codeResources)
        }
        let embedded = bundleURL.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: embedded.path) {
            try fm.removeItem(at: embedded)
        }
    }

    /// 生成每个可执行单元的 entitlements。
    public static func entitlements(
        for bundle: SignableBundle,
        profile: ProvisioningProfile
    ) -> [String: Any] {
        guard bundle.kind.needsEntitlements else { return [:] }

        var result = profile.entitlements
        let teamID = profile.teamIdentifier
        let fullID = "\(teamID).\(bundle.bundleID)"

        result["application-identifier"] = fullID
        result["com.apple.developer.team-identifier"] = teamID

        // keychain 分组第一项必须跟着 Bundle ID 走，否则扩展读不到共享钥匙串
        if let groups = result["keychain-access-groups"] as? [String], !groups.isEmpty {
            var updated = groups
            updated[0] = fullID
            result["keychain-access-groups"] = updated
        }

        // entitlements 完全沿用描述文件，只跟随团队与 Bundle ID 调整标识。
        // 不要删除 get-task-allow：开发签名下扩展同样需要它才能被调试。
        return result
    }
}
