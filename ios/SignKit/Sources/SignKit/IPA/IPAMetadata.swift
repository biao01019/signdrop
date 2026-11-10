import Foundation
import ZIPFoundation

/// IPA 的基础信息，用于在列表里展示"选之前就知道这是什么包"。
public struct IPAMetadata {

    public let bundleID: String
    public let version: String
    public let buildVersion: String
    public let displayName: String
    public let executableName: String
    public let isEncrypted: Bool
    public let sizeBytes: UInt64

    public static func read(ipa url: URL) throws -> IPAMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw SignError.archive("无法打开 zip：\(error.localizedDescription)")
        }

        // 主包的 Info.plist 位于 Payload/X.app/Info.plist
        let plistEntries = archive.filter { entry in
            let parts = entry.path.components(separatedBy: "/")
            return parts.count == 3
                && parts[0] == "Payload"
                && parts[1].hasSuffix(".app")
                && parts[2] == "Info.plist"
        }

        guard let entry = plistEntries.first else {
            throw SignError.archive("安装包里找不到主程序的 Info.plist")
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }

        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw SignError.archive("Info.plist 解析失败")
        }

        // 有些 App Store 包会带 PkgInfo 之外的加密标记，SC_Info 目录是加壳特征
        let encrypted = archive.contains { $0.path.contains("/SC_Info/") }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        return IPAMetadata(
            bundleID: plist["CFBundleIdentifier"] as? String ?? "",
            version: plist["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: plist["CFBundleVersion"] as? String ?? "",
            displayName: (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? entry.path.components(separatedBy: "/")[1]
                    .replacingOccurrences(of: ".app", with: ""),
            executableName: plist["CFBundleExecutable"] as? String ?? "",
            isEncrypted: encrypted,
            sizeBytes: size
        )
    }
}
