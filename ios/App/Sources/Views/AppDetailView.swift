import SwiftUI

/// 02 · 应用详情
struct AppDetailView: View {
    @EnvironmentObject private var model: AppModel
    let app: AppItem

    @State private var showDeleteConfirm = false
    @State private var shareURL: URL?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                NavBar(
                    title: "应用详情",
                    onBack: { model.detailApp = nil },
                    trailingSymbol: app.localURL == nil ? nil : "square.and.arrow.up",
                    onTrailing: { shareURL = app.localURL }
                )

                hero
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 12)

                infoCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 22.5)

                remainCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.8)

                actionRow
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.3)

                SectionHeader("签名记录", trailing: "\(model.logs.count) 次")
                    .padding(.top, 15.9)

                logsCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.5)

                Color.clear.frame(height: 40)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .confirmationDialog("卸载后会删除本地签名的安装包，手机上的 App 也会失效。",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("卸载并删除", role: .destructive) { model.delete(app) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 头部

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIconTile(
                colors: app.colors,
                symbol: app.symbol,
                size: 84,
                radius: 20
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(TypeScale.heroTitle)
                    .kerning(-0.4)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                Text("v\(app.version) · \(app.sizeText) · \(app.category)")
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
                    .padding(.top, 2)

                HStack(spacing: 6) {
                    BadgeView(
                        text: app.status == .expired ? "已过期" : "已签名",
                        kind: app.status == .expired ? .danger : .ok
                    )
                    BadgeView(
                        text: app.certName.contains("企业") ? "企业证书" : "个人证书",
                        kind: .info
                    )
                }
                .padding(.top, 7)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 1)
    }

    // MARK: 签名信息

    private var infoCard: some View {
        VStack(spacing: 0) {
            Text("签名信息")
                .font(TypeScale.body)
                .foregroundColor(Palette.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 10)
                .padding(.bottom, 7)

            DividerLine()
            infoRow("签名证书", app.certName)
            DividerLine()
            infoRow("Bundle ID", app.bundleID)
            DividerLine()
            infoRow("签名时间", AppModel.dateText(app.signedAt))
        }
        .card()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(TypeScale.body)
                .foregroundColor(Palette.sub)
            Spacer(minLength: 8)
            Text(value)
                .font(TypeScale.bodyStrong)
                .foregroundColor(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 42)
    }

    // MARK: 剩余有效期

    private var remainCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(app.daysLeft >= 0 ? "剩余 \(app.daysLeft) 天" : "已过期 \(-app.daysLeft) 天")
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: 8)
                Text("\(AppModel.dateText(app.expiresAt))到期")
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.sub)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 15)

            ProgressTrack(value: remainRatio, tint: app.status.color, height: 6)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 13)

            Text("将于到期前 7 天自动提醒重新签名")
                .font(TypeScale.body)
                .foregroundColor(Palette.ter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 11)
                .padding(.bottom, 14.5)
        }
        .card()
    }

    private var remainRatio: Double {
        let total = max(app.daysLeft, 1) + 40
        return min(max(Double(app.daysLeft) / Double(total), 0), 1)
    }

    // MARK: 操作

    private var actionRow: some View {
        HStack(spacing: 12.5) {
            PrimaryButton(title: "重新签名") {
                model.ressign(app)
            }
            Button(action: { showDeleteConfirm = true }) {
                Text("卸载")
                    .font(TypeScale.button)
                    .foregroundColor(Palette.red)
                    .frame(width: 104, height: Metrics.buttonHeight)
                    .card(radius: Metrics.controlRadius)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: 记录

    private var logsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.logs.enumerated()), id: \.element.id) { index, log in
                logRow(log)
                if index < model.logs.count - 1 {
                    DividerLine()
                }
            }
        }
        .card()
    }

    private func logRow(_ log: SignLog) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(log.ok ? Palette.green : Palette.red)
                .frame(width: 7, height: 7)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(log.title)
                    .font(TypeScale.valueStrong)
                    .foregroundColor(Palette.ink)
                Text(log.detail)
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.sub)
            }

            Spacer(minLength: 8)

            Text(log.dateText)
                .font(TypeScale.meta)
                .foregroundColor(Palette.sub)
                .padding(.top, 1)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 57.1, alignment: .center)
    }
}
