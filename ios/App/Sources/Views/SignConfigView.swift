import SwiftUI
import UniformTypeIdentifiers

/// 03 · 签名配置
struct SignConfigView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var showImporter = false
    @State private var showCertPicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                NavBar(
                    title: "签名配置",
                    leading: "取消",
                    onLeading: { model.showsSignConfig = false },
                    onBack: nil
                )

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        fileCard
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, 12.2)

                        SectionHeader("签名证书")
                            .padding(.top, 15.5)

                        certCard
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, 16.5)

                        SectionHeader("应用信息")
                            .padding(.top, 14.5)

                        infoCard
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, 16.5)

                        SectionHeader("高级选项")
                            .padding(.top, 14.5)

                        advancedCard
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, 16.5)

                        Text("预计耗时 30 秒 · 签名完成后自动安装到本机")
                            .font(TypeScale.body)
                            .foregroundColor(Palette.ter)
                            .padding(.top, 24)

                        Color.clear.frame(height: 30)
                    }
                }

                PrimaryButton(
                    title: "开始签名",
                    height: Metrics.bigButtonHeight,
                    font: TypeScale.bigButton,
                    enabled: model.pendingIPAURL != nil || !model.pendingIPAName.isEmpty
                ) {
                    model.startSign()
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 1)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.ipa],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let copied = try? AppState.importFile(from: url, to: "Imports")
                let target = copied ?? url
                model.pendingIPAURL = target
                model.pendingIPAName = target.lastPathComponent
                let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
                model.pendingIPASize = bytes / 1024 / 1024
                model.draftDisplayName = target.lastPathComponent.replacingOccurrences(of: ".ipa", with: "")
            }
        }
        .confirmationDialog("选择签名证书", isPresented: $showCertPicker, titleVisibility: .visible) {
            ForEach(model.certs) { cert in
                Button("\(cert.title) · \(cert.team)") { model.defaultCertID = cert.id }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 文件

    private var fileCard: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "doc.text")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.pendingIPAName.isEmpty ? "未选择 IPA" : model.pendingIPAName)
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                Text(fileSubtitle)
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: { showImporter = true }) {
                Text("更换")
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.blue)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 71.5)
        .card()
    }

    private var fileSubtitle: String {
        let size = model.pendingIPASize > 0
            ? String(format: "%.1f MB", model.pendingIPASize)
            : "选择要签名的安装包"
        return "\(size) · 今天 \(Self.timeText()) 导入"
    }

    // MARK: 证书

    private var certCard: some View {
        let cert = model.defaultCert
        return Button(action: { showCertPicker = true }) {
            HStack(spacing: 12) {
                IconTile(
                    symbol: cert?.kind.symbol ?? "checkmark.shield",
                    tint: cert?.kind.tint ?? Palette.tint,
                    foreground: cert?.kind.foreground ?? Palette.blue
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(cert?.title ?? "选择证书")
                        .font(TypeScale.cardTitle)
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                    Text(cert.map { "剩余 \($0.daysLeft) 天 · 设备 \($0.devices.count)/3" } ?? "还没有可用证书")
                        .font(TypeScale.meta)
                        .foregroundColor(Palette.sub)
                }

                Spacer(minLength: 8)
                ChevronView()
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 61.9)
            .card()
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 应用信息

    private var infoCard: some View {
        VStack(spacing: 0) {
            fieldRow("显示名称", text: $model.draftDisplayName, placeholder: "App 名称")
            DividerLine()
            fieldRow("Bundle ID", text: $model.draftBundleID, placeholder: "com.example.app")
            DividerLine()
            fieldRow("版本号", text: $model.draftVersion, placeholder: "1.0.0")
        }
        .card()
    }

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(TypeScale.cardTitle)
                .foregroundColor(Palette.ink)
            Spacer(minLength: 8)
            TextField(placeholder, text: text)
                .font(TypeScale.value)
                .foregroundColor(Palette.sub)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 45.5)
    }

    // MARK: 高级选项

    private var advancedCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("签名完成后自动安装")
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.ink)
                Spacer()
                SwitchControl(isOn: $model.autoInstall)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 59)

            DividerLine()

            HStack {
                Text("保留原始应用图标")
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.ink)
                Spacer()
                SwitchControl(isOn: $model.keepOriginalIcon)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 59)
        }
        .card()
    }

    private static func timeText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}
