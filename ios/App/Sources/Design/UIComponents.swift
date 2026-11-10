import SwiftUI

// MARK: - 卡片

struct CardBackground: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var shadowed: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .shadow(
                    color: shadowed ? Color.black.opacity(0.045) : .clear,
                    radius: 10, x: 0, y: 2
                )
        )
    }
}

extension View {
    func card(radius: CGFloat = Metrics.cardRadius,
              fill: Color = Palette.card,
              shadowed: Bool = true) -> some View {
        modifier(CardBackground(radius: radius, fill: fill, shadowed: shadowed))
    }
}

/// 卡片内部的分隔线（左右各留 16，和设计稿一致）
struct DividerLine: View {
    var inset: CGFloat = Metrics.cardPadding
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: Metrics.hairline)
            .padding(.horizontal, inset)
    }
}

// MARK: - 文字

struct SectionHeader: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.body)
                .foregroundColor(Palette.sub)
            Spacer(minLength: 0)
            if let trailing = trailing {
                Text(trailing)
                    .font(TypeScale.body)
                    .foregroundColor(Palette.ter)
            }
        }
        .padding(.horizontal, Metrics.sectionPadding)
    }
}

// MARK: - 徽标

enum BadgeKind {
    case ok, warn, danger, info

    var background: Color {
        switch self {
        case .ok: return Palette.greenBg
        case .warn: return Palette.orangeBg
        case .danger: return Palette.redBg
        case .info: return Palette.tint
        }
    }

    var foreground: Color {
        switch self {
        case .ok: return Palette.greenText
        case .warn: return Palette.orangeText
        case .danger: return Palette.red
        case .info: return Palette.blue
        }
    }
}

struct BadgeView: View {
    var text: String
    var kind: BadgeKind

    var body: some View {
        Text(text)
            .font(TypeScale.badge)
            .foregroundColor(kind.foreground)
            .padding(.horizontal, 7)
            .frame(height: 20.6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind.background)
            )
    }
}

// MARK: - 进度条

struct ProgressTrack: View {
    var value: Double
    var tint: Color
    var height: CGFloat

    init(value: Double, tint: Color = Palette.blue, height: CGFloat = 6) {
        self.value = value
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 图标

struct IconTile: View {
    var symbol: String
    var size: CGFloat = Metrics.cardIcon
    var radius: CGFloat = Metrics.cardIconRadius
    var tint: Color = Palette.tint
    var foreground: Color = Palette.blue

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint)
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundColor(foreground)
        }
        .frame(width: size, height: size)
    }
}

struct AppIconTile: View {
    var colors: [Color]
    var symbol: String
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: colors),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

struct CircleIconButton: View {
    var symbol: String
    var size: CGFloat = 34
    var iconSize: CGFloat = 15
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Palette.chip)
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(Color(hex: 0x3A3A3C))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChevronView: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Palette.chevron)
    }
}

// MARK: - 开关

/// 设计稿的开关是 50.4×30.7、滑块 26.3，系统 Toggle 尺寸对不上，这里自绘。
struct SwitchControl: View {
    @Binding var isOn: Bool

    var body: some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.green : Palette.chip)
                Circle()
                    .fill(Color.white)
                    .frame(width: 26.3, height: 26.3)
                    .shadow(color: Color.black.opacity(0.15), radius: 1.5, x: 0, y: 0.5)
                    .padding(.horizontal, 2.2)
            }
            .frame(width: 50.4, height: 30.7)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 按钮

struct PrimaryButton: View {
    var title: String
    var height: CGFloat = Metrics.buttonHeight
    var font: Font = TypeScale.button
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(Palette.blue)
                )
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
    }
}

/// 整行可点的容器（去掉系统高亮）
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.black.opacity(0.03) : Color.clear)
    }
}


// MARK: - 分享面板

import UIKit

/// 把签名好的 IPA 交给系统分享：存到「文件」、发给微信、AirDrop 给其他设备都行。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
