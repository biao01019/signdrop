import SwiftUI

// MARK: - 调色板
//
// 全部取自设计稿（Signdrop UI.pdf）的实际像素值，不要按 iOS 默认色改。

enum Palette {
    static let bg = Color(hex: 0xF1F1F6)
    static let card = Color.white

    static let blue = Color(hex: 0x0079FF)
    static let tint = Color(hex: 0xE9F1FF)
    static let chip = Color(hex: 0xE6E6EC)

    static let ink = Color(hex: 0x1B1B1D)
    static let sub = Color(hex: 0x8A8A8E)
    static let ter = Color(hex: 0xA7A7AE)
    static let divider = Color(hex: 0xF0F0F2)
    static let chevron = Color(hex: 0xC4C4C6)

    static let green = Color(hex: 0x33C758)
    static let greenText = Color(hex: 0x21A24A)
    static let greenBg = Color(hex: 0xE7F7EC)

    static let orange = Color(hex: 0xFF9400)
    static let orangeText = Color(hex: 0xC37500)
    static let orangeBg = Color(hex: 0xFFF6E6)

    static let red = Color(hex: 0xD93B2E)
    static let redBg = Color(hex: 0xFFECE9)

    static let track = Color(hex: 0xE9E9EF)
}

// MARK: - 尺寸
//
// 设计稿画布 393×852（iPhone 15 Pro），下列数值就是稿上的实际坐标差。

enum Metrics {
    static let screenW: CGFloat = 393

    static let pagePadding: CGFloat = 16
    static let sectionPadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14

    static let hairline: CGFloat = 1.4

    /// 大标题：文字顶部距屏幕顶端
    static let largeTitleTop: CGFloat = 60

    /// 列表行
    static let listRowHeight: CGFloat = 69.6
    static let listIcon: CGFloat = 48
    static let listIconRadius: CGFloat = 13

    /// 卡片内小图标
    static let cardIcon: CGFloat = 40
    static let cardIconRadius: CGFloat = 12

    /// 底部悬浮 Tab Bar
    static let tabBarHeight: CGFloat = 60
    static let tabBarRadius: CGFloat = 30
    static let tabBarInset: CGFloat = 12
    static let tabBarPadding: CGFloat = 13.4
    static let tabPillHeight: CGFloat = 53.3

    /// 主按钮
    static let buttonHeight: CGFloat = 50
    static let bigButtonHeight: CGFloat = 51.5
}

// MARK: - 字阶
//
// 设计稿的字号约为 iOS 标准字号的 0.89 倍，这里直接用实测值。

enum TypeScale {
    static let pageTitle = Font.system(size: 32, weight: .bold)
    static let loginTitle = Font.system(size: 28, weight: .bold)
    static let heroTitle = Font.system(size: 21, weight: .bold)

    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 15, weight: .semibold)
    static let rowLabel = Font.system(size: 15, weight: .regular)

    static let button = Font.system(size: 16, weight: .semibold)
    static let bigButton = Font.system(size: 17, weight: .semibold)

    static let value = Font.system(size: 14, weight: .regular)
    static let valueStrong = Font.system(size: 14, weight: .semibold)

    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)

    static let meta = Font.system(size: 12, weight: .regular)
    static let metaStrong = Font.system(size: 12, weight: .semibold)

    static let badge = Font.system(size: 11, weight: .medium)
    static let tabLabel = Font.system(size: 10, weight: .medium)
    static let tabLabelOn = Font.system(size: 10, weight: .semibold)
}

// MARK: - 颜色工具

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
