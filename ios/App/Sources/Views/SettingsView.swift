import SwiftUI
import UIKit

/// 06 · 设置
///
/// 纵向节奏（相对屏幕顶端，设计稿实测值）：
/// 大标题 60 / 账号卡 120.4（高 67.2）/「签名」203.6 / 签名卡 236.1（3×53.9）
/// 「设备」413.8 / 设备卡 446.3（2×47.5 + 说明）/「通用」597.1 / 通用卡 629.6（2×46）
/// 页脚 740
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                LargeTitleBar("设置")

                accountCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 22.4)

                SectionHeader("签名")
                    .padding(.top, 16)

                signCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.5)

                SectionHeader("设备")
                    .padding(.top, 16)

                deviceCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.5)

                SectionHeader("通用")
                    .padding(.top, 16)

                generalCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.5)

                Text("Signdrop v1.2.0 · 本地签名，数据不出设备")
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.ter)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 17.8)

                Color.clear.frame(height: 118)
            }
        }
    }

    // MARK: 账号

    private var accountCard: some View {
        Button(action: { model.tab = .certs }) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(
                        LinearGradient(
                            colors: [Color(hex: 0x6D6AF8), Color(hex: 0x9B5CF6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.account.email)
                        .font(TypeScale.cardTitle)
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                        .frame(height: 20, alignment: .leading)
                    Text(model.isSignedIn
                         ? "证书同步已开启 · \(model.apps.count) 个应用"
                         : "未登录 · 仅本机保存")
                        .font(TypeScale.meta)
                        .foregroundColor(Palette.sub)
                        .lineLimit(1)
                        .frame(height: 16, alignment: .leading)
                }
                .offset(y: -1.6)

                Spacer(minLength: 8)

                HStack(spacing: 9) {
                    BadgeView(text: model.isSignedIn ? "已登录" : "未登录",
                              kind: model.isSignedIn ? .ok : .info)
                    chevronSlot
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, Metrics.cardPadding)
            .frame(height: 67.2)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RowButtonStyle())
        .card()
    }

    // MARK: 签名

    private var signCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("默认证书")
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text(model.defaultCert?.title ?? "未选择")
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
                chevronSlot
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 53.9)
            .contentShape(Rectangle())
            .onTapGesture { model.tab = .certs }

            DividerLine()

            toggleRow("到期前自动提醒", isOn: $model.autoRemind, height: 53.9)

            DividerLine()

            toggleRow("保留签名记录", isOn: $model.keepLogs, height: 53.9)
        }
        .card()
    }

    // MARK: 设备

    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("设备名称")
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text(model.deviceName)
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 47.5)

            DividerLine()

            HStack(spacing: 0) {
                Text("UDID")
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text(model.deviceUDID)
                    .font(TypeScale.valueStrong)
                    .kerning(0.2)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                copyChip
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 47.5)

            DividerLine()

            Text("添加新设备后需重新签名，才能安装到该设备")
                .font(TypeScale.meta)
                .foregroundColor(Palette.ter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 8.5)
                .padding(.bottom, 14.8)
        }
        .card()
    }

    private var copyChip: some View {
        Button(action: {
            UIPasteboard.general.string = model.deviceUDID
            model.notice = "UDID 已复制"
        }) {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text("复制")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Palette.blue)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.tint)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.leading, 8)
    }

    // MARK: 通用

    private var generalCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("外观")
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text("跟随系统")
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                chevronSlot
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 46)

            DividerLine()

            HStack(spacing: 0) {
                Text("清理缓存")
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text("1.2 GB")
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                chevronSlot
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 46)
        }
        .card()
    }

    // MARK: 零件

    private func toggleRow(_ title: String, isOn: Binding<Bool>, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TypeScale.rowTitle)
                .foregroundColor(Palette.ink)
            Spacer(minLength: 8)
            SwitchControl(isOn: isOn)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: height)
    }

    /// 设计稿里 chevron 右侧留 16、占位宽 18
    private var chevronSlot: some View {
        ChevronView(size: 13)
            .frame(width: 18, alignment: .trailing)
    }
}
