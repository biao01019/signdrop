import SwiftUI
import UniformTypeIdentifiers

/// 01 · 我的应用
struct AppsHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    LargeTitleBar("我的应用") {
                        HStack(spacing: 8.6) {
                            CircleIconButton(symbol: "magnifyingglass", iconSize: 16) {}
                            CircleIconButton(symbol: "ellipsis", iconSize: 16) {}
                        }
                    }

                    certCard
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 24.4)

                    SectionHeader("已安装应用", trailing: "\(model.apps.count) 个")
                        .padding(.top, 19.8)

                    appsCard
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 16.5)

                    Color.clear.frame(height: 150)
                }
            }

            fab
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.ipa],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let copied = try? AppState.importFile(from: url, to: "Imports")
                model.prepareSign(ipaURL: copied ?? url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: 证书摘要卡

    private var certCard: some View {
        let cert = model.defaultCert
        let title = cert?.title ?? "尚未导入证书"
        let team = cert?.team ?? "—"
        let expireText = cert.map { "\(Self.yearText($0.expiresAt))到期" } ?? "导入 .p12 与描述文件后开始"
        let days = cert?.daysLeft ?? 0
        let tint = cert?.kind == .enterprise ? Palette.orange : Palette.blue

        return Button(action: { model.tab = .certs }) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(
                        symbol: cert?.kind.symbol ?? "exclamationmark.shield",
                        tint: cert?.kind.tint ?? Palette.chip,
                        foreground: cert?.kind.foreground ?? Palette.sub
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(TypeScale.cardTitle)
                            .foregroundColor(Palette.ink)
                            .lineLimit(1)
                        Text(cert == nil ? expireText : "Team \(team) · \(expireText)")
                            .font(TypeScale.meta)
                            .foregroundColor(Palette.sub)
                            .lineLimit(1)
                    }
                    .padding(.top, 1)

                    Spacer(minLength: 8)

                    if let cert = cert {
                        BadgeView(
                            text: cert.daysLeft > 0 ? "有效" : "已过期",
                            kind: cert.daysLeft > 0 ? .ok : .danger
                        )
                    }
                }
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 14)

                ProgressTrack(value: cert?.progress ?? 0, tint: tint)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.top, 12)

                HStack {
                    Text(cert == nil ? "导入后自动计算有效期" : "剩余 \(days) 天")
                        .font(TypeScale.body)
                        .foregroundColor(Palette.sub)
                    Spacer()
                    Text("管理证书")
                        .font(TypeScale.bodyStrong)
                        .foregroundColor(Palette.blue)
                }
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 16)
                .padding(.bottom, 15)
            }
            .card()
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 应用列表

    private var appsCard: some View {
        VStack(spacing: 0) {
            if model.apps.isEmpty {
                emptyState
            } else {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    appRow(app)
                    if index < model.apps.count - 1 {
                        DividerLine(inset: 0)
                    }
                }
            }
        }
        .card()
    }

    private func appRow(_ app: AppItem) -> some View {
        Button(action: { model.detailApp = app }) {
            HStack(spacing: 12) {
                AppIconTile(
                    colors: app.colors,
                    symbol: app.symbol,
                    size: Metrics.listIcon,
                    radius: Metrics.listIconRadius
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(TypeScale.rowTitle)
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                    Text(app.metaLine)
                        .font(TypeScale.meta)
                        .foregroundColor(Palette.sub)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if app.status == .valid {
                    ChevronView()
                } else {
                    BadgeView(text: app.status.badgeText, kind: app.status.badgeKind)
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: Metrics.listRowHeight)
        }
        .buttonStyle(RowButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Palette.ter)
            Text("还没有签名的应用")
                .font(TypeScale.rowLabel)
                .foregroundColor(Palette.sub)
            Text("点右下角的 + 选择 IPA")
                .font(TypeScale.meta)
                .foregroundColor(Palette.ter)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    // MARK: 悬浮按钮

    private var fab: some View {
        Button(action: { showImporter = true }) {
            ZStack {
                Circle()
                    .fill(Palette.blue)
                    .shadow(color: Palette.blue.opacity(0.32), radius: 12, x: 0, y: 8)
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.trailing, Metrics.pagePadding)
        .padding(.bottom, 81)
    }

    static func yearText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
