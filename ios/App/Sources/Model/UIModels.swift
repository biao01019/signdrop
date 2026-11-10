import SwiftUI
import SignKit

// MARK: - 应用

enum AppStatus {
    case valid, expiring, expired

    var badgeText: String {
        switch self {
        case .valid: return ""
        case .expiring: return "即将到期"
        case .expired: return "需要重签"
        }
    }

    var badgeKind: BadgeKind {
        switch self {
        case .valid: return .ok
        case .expiring: return .warn
        case .expired: return .danger
        }
    }

    var color: Color {
        switch self {
        case .valid: return Palette.green
        case .expiring: return Palette.orange
        case .expired: return Palette.red
        }
    }
}

struct AppItem: Identifiable {
    var id = UUID()
    var name: String
    var version: String
    var bundleID: String
    var sizeMB: Double
    var daysLeft: Int
    var signedAt: Date
    var expiresAt: Date
    var certName: String
    var team: String
    var category: String
    var colors: [Color]
    var symbol: String
    var fileName: String?
    var localURL: URL?

    var status: AppStatus {
        if daysLeft < 0 { return .expired }
        if daysLeft <= 30 { return .expiring }
        return .valid
    }

    var statusLine: String {
        if daysLeft < 0 { return "已过期 \(-daysLeft) 天" }
        return "剩余 \(daysLeft) 天"
    }

    var metaLine: String { "v\(version) · \(statusLine)" }

    var sizeText: String { String(format: "%.1f MB", sizeMB) }
}

// MARK: - 证书

enum CertKind {
    case personal, enterprise

    var symbol: String {
        switch self {
        case .personal: return "checkmark.shield"
        case .enterprise: return "building.2"
        }
    }

    var tint: Color {
        switch self {
        case .personal: return Palette.tint
        case .enterprise: return Palette.orangeBg
        }
    }

    var foreground: Color {
        switch self {
        case .personal: return Palette.blue
        case .enterprise: return Palette.orange
        }
    }
}

struct DeviceItem: Identifiable {
    var id = UUID()
    var name: String
    var udid: String
    var activated: Bool
    var isTablet: Bool
}

struct CertItem: Identifiable {
    var id = UUID()
    var title: String
    var team: String
    var subtitle: String
    var kind: CertKind
    var expiresAt: Date
    var totalDays: Int
    var isDefault: Bool
    var devices: [DeviceItem]

    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
    }

    var progress: Double {
        guard totalDays > 0 else { return 0 }
        return min(max(Double(daysLeft) / Double(totalDays), 0.02), 1)
    }

    var badge: BadgeKind? {
        if daysLeft <= 0 { return .danger }
        if daysLeft <= 30 { return .warn }
        return nil
    }
}

// MARK: - 任务

enum StepState {
    case done, running, pending
}

struct TaskStep: Identifiable {
    var id = UUID()
    var title: String
    var state: StepState
}

struct SignTask: Identifiable {
    var id = UUID()
    var fileName: String
    var sizeMB: Double
    var progress: Double
    var steps: [TaskStep]
    var deviceName: String
    var certName: String
    var startedAt: Date

    var percentText: String { "\(Int((progress * 100).rounded()))%" }

    var detailLine: String {
        "\(fileName) · " + String(format: "%.1f MB", sizeMB)
    }
}

// MARK: - 记录

struct SignLog: Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var dateText: String
    var ok: Bool
}

// MARK: - 账号

struct Account {
    var email: String
    var signedIn: Bool
    var appCount: Int
}

// MARK: - 示例数据
//
// 与设计稿逐条对应，用于首次启动时把界面撑起来；真实数据接入后由 AppModel 覆盖。

enum DemoData {

    static func days(_ count: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: count, to: Date()) ?? Date()
    }

    static let apps: [AppItem] = [
        AppItem(
            name: "Quantum Notes",
            version: "2.4.1",
            bundleID: "com.quantum.notes",
            sizeMB: 24.6,
            daysLeft: 87,
            signedAt: days(-64),
            expiresAt: days(87),
            certName: "个人开发者证书",
            team: "8F2K9D",
            category: "效率",
            colors: [Color(hex: 0x5769FC), Color(hex: 0x805AF6)],
            symbol: "list.bullet",
            fileName: nil,
            localURL: nil
        ),
        AppItem(
            name: "Muse Player",
            version: "1.8.0",
            bundleID: "com.muse.player",
            sizeMB: 41.2,
            daysLeft: 21,
            signedAt: days(-130),
            expiresAt: days(21),
            certName: "个人开发者证书",
            team: "8F2K9D",
            category: "音乐",
            colors: [Color(hex: 0xFFB44D), Color(hex: 0xFF5F52)],
            symbol: "play.fill",
            fileName: nil,
            localURL: nil
        ),
        AppItem(
            name: "Grid Wallet",
            version: "3.0.2",
            bundleID: "com.grid.wallet",
            sizeMB: 18.9,
            daysLeft: -2,
            signedAt: days(-152),
            expiresAt: days(-2),
            certName: "企业证书 · In-House",
            team: "QK72LM",
            category: "财务",
            colors: [Color(hex: 0x20B5A4), Color(hex: 0x2688D9)],
            symbol: "square.grid.2x2.fill",
            fileName: nil,
            localURL: nil
        ),
        AppItem(
            name: "Lumen Reader",
            version: "5.1.4",
            bundleID: "com.lumen.reader",
            sizeMB: 63.4,
            daysLeft: 87,
            signedAt: days(-64),
            expiresAt: days(87),
            certName: "个人开发者证书",
            team: "8F2K9D",
            category: "图书",
            colors: [Color(hex: 0xFFC24B), Color(hex: 0xFB8A2E)],
            symbol: "book.closed.fill",
            fileName: nil,
            localURL: nil
        ),
        AppItem(
            name: "Aurora Calc",
            version: "1.2.3",
            bundleID: "com.aurora.calc",
            sizeMB: 8.7,
            daysLeft: 45,
            signedAt: days(-106),
            expiresAt: days(45),
            certName: "个人开发者证书",
            team: "8F2K9D",
            category: "工具",
            colors: [Color(hex: 0x3BD37A), Color(hex: 0x12A96A)],
            symbol: "plus.forwardslash.minus",
            fileName: nil,
            localURL: nil
        )
    ]

    static let devices: [DeviceItem] = [
        DeviceItem(name: "iPhone 15 Pro", udid: "00008101-000A2F8C8F3A", activated: true, isTablet: false),
        DeviceItem(name: "iPad Air", udid: "00008102-000B4D91B21C", activated: true, isTablet: true)
    ]

    static let certs: [CertItem] = [
        CertItem(
            title: "个人开发者证书",
            team: "8F2K9D",
            subtitle: "Apple ID",
            kind: .personal,
            expiresAt: days(123),
            totalDays: 198,
            isDefault: true,
            devices: devices
        ),
        CertItem(
            title: "企业证书 · In-House",
            team: "QK72LM",
            subtitle: "企业分发",
            kind: .enterprise,
            expiresAt: days(6),
            totalDays: 50,
            isDefault: false,
            devices: []
        )
    ]

    static let logs: [SignLog] = [
        SignLog(title: "重新签名 · 成功", detail: "更新至 v2.4.1 · 证书 8F2K9D", dateText: "10月12日", ok: true),
        SignLog(title: "首次签名 · 成功", detail: "导入 IPA 并安装到设备", dateText: "8月10日", ok: true),
        SignLog(title: "更新签名 · 失败", detail: "证书已过期 · 需重新签名", dateText: "7月28日", ok: false)
    ]

    static let task: SignTask = SignTask(
        fileName: "QuantumNotes.ipa",
        sizeMB: 24.6,
        progress: 0.68,
        steps: [
            TaskStep(title: "解压 IPA 安装包", state: .done),
            TaskStep(title: "校验描述文件", state: .done),
            TaskStep(title: "使用证书重签名", state: .running),
            TaskStep(title: "打包并安装到设备", state: .pending)
        ],
        deviceName: "iPhone 15 Pro",
        certName: "个人开发者证书",
        startedAt: Date()
    )

    static let account = Account(email: "quantum@icloud.com", signedIn: true, appCount: 5)
}
