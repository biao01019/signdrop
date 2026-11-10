import SwiftUI

/// 底部悬浮导航：369×60 的胶囊，选中项是 85.4×53.3 的蓝色药丸
struct FloatingTabBar: View {
    @Binding var selection: AppModel.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Tab.allCases, id: \.rawValue) { tab in
                item(for: tab)
            }
        }
        .padding(.horizontal, Metrics.tabBarPadding)
        .frame(height: Metrics.tabBarHeight)
        .background(
            Capsule()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.09), radius: 12, x: 0, y: 6)
        )
        .padding(.horizontal, Metrics.tabBarInset)
    }

    private func item(for tab: AppModel.Tab) -> some View {
        let isOn = selection == tab
        return Button(action: {
            withAnimation(.easeOut(duration: 0.18)) { selection = tab }
        }) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(tab.title)
                    .font(isOn ? TypeScale.tabLabelOn : TypeScale.tabLabel)
            }
            .foregroundColor(isOn ? .white : Palette.sub)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.tabPillHeight)
            .background(
                Capsule().fill(isOn ? Palette.blue : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 二级页的顶部导航（返回按钮 + 居中标题）
struct NavBar: View {
    var title: String
    var leading: String?
    var onLeading: (() -> Void)?
    var onBack: (() -> Void)?

    var body: some View {
        ZStack {
            Text(title)
                .font(TypeScale.button)
                .foregroundColor(Palette.ink)

            HStack {
                if let leading = leading {
                    Button(action: { onLeading?() }) {
                        Text(leading)
                            .font(TypeScale.button)
                            .foregroundColor(Palette.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if let onBack = onBack {
                    Button(action: onBack) {
                        ZStack {
                            Circle().fill(Palette.chip)
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(hex: 0x3A3A3C))
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
        .frame(height: 32)
        .padding(.top, 11)
    }
}

/// 大标题 + 右侧动作按钮
struct LargeTitleBar<Trailing: View>: View {
    var title: String
    var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(TypeScale.pageTitle)
                .kerning(-0.3)
                .foregroundColor(Palette.ink)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: 38, alignment: .bottom)
        .padding(.top, 1)
    }
}

extension LargeTitleBar where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
