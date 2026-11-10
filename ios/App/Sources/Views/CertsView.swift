import SwiftUI
import UniformTypeIdentifiers

/// 04 · 证书
struct CertsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                LargeTitleBar("证书") {
                    CircleIconButton(symbol: "plus", iconSize: 17) {
                        model.showsCertImport = true
                    }
                }

                if model.certs.isEmpty {
                    emptyCard
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 24.4)
                } else {
                    ForEach(Array(model.certs.enumerated()), id: \.element.id) { index, cert in
                        certCard(cert)
                            .padding(.horizontal, Metrics.pagePadding)
                            .padding(.top, index == 0 ? 24.4 : 18.7)
                    }
                }

                SectionHeader("签名设备", trailing: model.deviceSummary)
                    .padding(.top, 15.5)

                devicesCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 16.6)

                importButton
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 19.7)

                warningCard
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 19.7)

                Color.clear.frame(height: 150)
            }
        }
    }

    // MARK: 证书卡

    private func certCard(_ cert: CertItem) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    symbol: cert.kind.symbol,
                    tint: cert.kind.tint,
                    foreground: cert.kind.foreground
                )

                Text(cert.title)
                    .font(TypeScale.cardTitle)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .padding(.top, 6)

                Spacer(minLength: 8)

                if cert.isDefault {
                    BadgeView(text: "默认", kind: .info)
                        .padding(.top, 10)
                } else if let badge = cert.badge {
                    BadgeView(text: badge == .danger ? "已过期" : "即将到期", kind: badge)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 14)

            HStack(spacing: 8) {
                Text("Team \(cert.team) · \(cert.subtitle)")
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("剩余 \(cert.daysLeft) 天")
                    .font(TypeScale.metaStrong)
                    .foregroundColor(cert.badge == .warn ? Palette.orangeText : Palette.blue)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 8.5)

            ProgressTrack(
                value: cert.progress,
                tint: cert.badge == .warn ? Palette.orange : Palette.blue,
                height: 5.3
            )
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 11.8)
            .padding(.bottom, 13.3)
        }
        .card()
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            IconTile(symbol: "checkmark.shield", size: 44, radius: 14)
            Text("还没有证书")
                .font(TypeScale.cardTitle)
                .foregroundColor(Palette.ink)
            Text("导入 .p12 与 .mobileprovision 后即可签名")
                .font(TypeScale.meta)
                .foregroundColor(Palette.sub)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .card()
    }

    // MARK: 设备

    private var devicesCard: some View {
        VStack(spacing: 0) {
            if model.devices.isEmpty {
                Text("还没有激活的设备")
                    .font(TypeScale.body)
                    .foregroundColor(Palette.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    deviceRow(device)
                    if index < model.devices.count - 1 {
                        DividerLine()
                    }
                }
            }
        }
        .card()
    }

    private func deviceRow(_ device: DeviceItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.isTablet ? "ipad" : "iphone")
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(Palette.ink)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(TypeScale.rowTitle)
                    .foregroundColor(Palette.ink)
                Text("UDID \(shortUDID(device.udid))")
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.sub)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if device.activated {
                BadgeView(text: "已激活", kind: .ok)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 58.3)
    }

    private func shortUDID(_ udid: String) -> String {
        let parts = udid.split(separator: "-")
        guard parts.count == 2 else { return udid }
        let head = parts[0]
        let tail = parts[1]
        let headText = String(head.prefix(8))
        let tailText = String(tail.suffix(4))
        return "\(headText)-\(String(tail.prefix(4)))...\(tailText)"
    }

    // MARK: 导入 / 提示

    private var importButton: some View {
        Button(action: { model.showsCertImport = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("导入 .p12 / .mobileprovision")
                    .font(TypeScale.cardTitle)
            }
            .foregroundColor(Palette.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 52.8)
            .card()
        }
        .buttonStyle(RowButtonStyle())
    }

    private var warningCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(Palette.orange)
                .padding(.top, 1)

            Text("企业证书签名的 App 需在「设置 > 通用 > VPN 与设备管理」中信任后才能运行")
                .font(TypeScale.body)
                .foregroundColor(Palette.orangeText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 13)
        .card(radius: 16, fill: Palette.orangeBg, shadowed: false)
    }
}

// MARK: - 导入证书

struct CertImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var p12Data: Data?
    @State private var p12Name = ""
    @State private var profileData: Data?
    @State private var profileName = ""
    @State private var password = ""
    @State private var label = ""
    @State private var pickingP12 = false
    @State private var pickingProfile = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("证书文件")) {
                    Button(action: { pickingP12 = true }) {
                        HStack {
                            Text("证书（.p12）")
                            Spacer()
                            Text(p12Name.isEmpty ? "选择文件" : p12Name)
                                .foregroundColor(p12Name.isEmpty ? Palette.blue : Palette.sub)
                                .lineLimit(1)
                        }
                    }

                    Button(action: { pickingProfile = true }) {
                        HStack {
                            Text("描述文件")
                            Spacer()
                            Text(profileName.isEmpty ? "选择文件" : profileName)
                                .foregroundColor(profileName.isEmpty ? Palette.blue : Palette.sub)
                                .lineLimit(1)
                        }
                    }

                    HStack {
                        Text("p12 密码")
                        Spacer()
                        SecureField("导出时设置的密码", text: $password)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("备注名称")
                        Spacer()
                        TextField("个人开发者证书", text: $label)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section(footer: Text("证书与私钥只保存在本机钥匙串，不会上传。")) {
                    Button(action: importAction) {
                        Text("导入证书")
                            .font(TypeScale.button)
                            .foregroundColor(canImport ? Palette.blue : Palette.ter)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canImport)
                }
            }
            .navigationBarTitle("导入证书", displayMode: .inline)
            .navigationBarItems(trailing: Button("取消") {
                model.showsCertImport = false
            })
        }
        .fileImporter(isPresented: $pickingP12, allowedContentTypes: [.p12, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                p12Data = readData(url)
                p12Name = url.lastPathComponent
            }
        }
        .fileImporter(isPresented: $pickingProfile, allowedContentTypes: [.mobileprovision, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                profileData = readData(url)
                profileName = url.lastPathComponent
            }
        }
    }

    private var canImport: Bool {
        p12Data != nil && profileData != nil && !password.isEmpty
    }

    private func importAction() {
        guard let p12 = p12Data, let profile = profileData else { return }
        model.importCredential(
            p12: p12,
            password: password,
            profile: profile,
            label: label.isEmpty ? "个人开发者证书" : label
        )
    }

    private func readData(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
