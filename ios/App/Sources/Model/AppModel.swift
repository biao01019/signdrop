import SwiftUI
import UIKit
import SignKit

/// 界面状态 + 少量业务动作。
/// 真实的签名流程仍然走 `AppState`（p12 / mobileprovision → SignKit），
/// 这里只负责把它的结果映射成界面需要的结构。
@MainActor
final class AppModel: ObservableObject {

    enum Tab: Int, CaseIterable {
        case apps, certs, tasks, settings

        var title: String {
            switch self {
            case .apps: return "应用"
            case .certs: return "证书"
            case .tasks: return "任务"
            case .settings: return "设置"
            }
        }

        var symbol: String {
            switch self {
            case .apps: return "square.grid.2x2.fill"
            case .certs: return "checkmark.shield"
            case .tasks: return "clock"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    // MARK: 状态

    @Published var tab: Tab = .apps
    @Published var apps: [AppItem] = []
    @Published var certs: [CertItem] = []
    @Published var devices: [DeviceItem] = []
    @Published var logs: [SignLog] = []
    @Published var task: SignTask?
    @Published var account = DemoData.account
    @Published var isSignedIn = false

    /// 详情页（为 nil 时显示 Tab 主体）
    @Published var detailApp: AppItem?
    /// 签名配置页
    @Published var showsSignConfig = false
    /// 导入证书页
    @Published var showsCertImport = false
    @Published var errorMessage: String?
    @Published var notice: String?

    // 签名配置页的临时数据
    @Published var pendingIPAURL: URL?
    @Published var pendingIPAName: String = ""
    @Published var pendingIPASize: Double = 0
    @Published var draftDisplayName: String = ""
    @Published var draftBundleID: String = ""
    @Published var draftVersion: String = ""

    // 设置项
    @Published var autoInstall = true
    @Published var keepOriginalIcon = false
    @Published var autoRemind = true
    @Published var keepLogs = true
    @Published var defaultCertID: UUID?

    private let state = AppState()
    private var credentialIndex: [UUID: Credential] = [:]
    private var taskTimer: Timer?

    private static let gradientSeeds: [[Color]] = [
        [Color(hex: 0x5769FC), Color(hex: 0x805AF6)],
        [Color(hex: 0xFFB44D), Color(hex: 0xFF5F52)],
        [Color(hex: 0x20B5A4), Color(hex: 0x2688D9)],
        [Color(hex: 0xFFC24B), Color(hex: 0xFB8A2E)],
        [Color(hex: 0x3BD37A), Color(hex: 0x12A96A)],
        [Color(hex: 0x6D6AF8), Color(hex: 0x9B5CF6)]
    ]

    private static let symbolSeeds = [
        "list.bullet", "play.fill", "square.grid.2x2.fill",
        "book.closed.fill", "plus.forwardslash.minus", "app.fill"
    ]

    init() {
        isSignedIn = UserDefaults.standard.bool(forKey: "signdrop.signedIn")
        loadFromStore()
        if apps.isEmpty && certs.isEmpty {
            seedDemo()
        }
        devices = DemoData.devices
        logs = DemoData.logs
        if let first = certs.first(where: { $0.isDefault }) ?? certs.first {
            defaultCertID = first.id
        }
    }

    // MARK: 数据装载

    private func loadFromStore() {
        credentialIndex.removeAll()
        var mapped: [CertItem] = []
        for (index, credential) in state.credentials.enumerated() {
            let item = makeCert(credential, index: index)
            mapped.append(item)
            credentialIndex[item.id] = credential
        }
        certs = mapped

        var mappedApps: [AppItem] = []
        for (index, app) in state.apps.enumerated() {
            mappedApps.append(makeApp(app, index: index))
        }
        apps = mappedApps
    }

    private func seedDemo() {
        apps = DemoData.apps
        certs = DemoData.certs
        if let first = certs.first(where: { $0.isDefault }) {
            defaultCertID = first.id
        }
    }

    private func makeCert(_ credential: Credential, index: Int) -> CertItem {
        let remaining = max(credential.daysRemaining, 0)
        return CertItem(
            title: credential.label.isEmpty ? "开发者证书" : credential.label,
            team: credential.teamID,
            subtitle: credential.provisionsAllDevices ? "企业分发" : "Apple ID",
            kind: credential.provisionsAllDevices ? .enterprise : .personal,
            expiresAt: credential.expiresAt,
            totalDays: max(remaining + 30, 30),
            isDefault: index == 0,
            devices: DemoData.devices
        )
    }

    private func makeApp(_ app: SignedApp, index: Int) -> AppItem {
        let colors = Self.gradientSeeds[index % Self.gradientSeeds.count]
        let symbol = Self.symbolSeeds[index % Self.symbolSeeds.count]
        return AppItem(
            name: app.name,
            version: app.version.isEmpty ? "1.0" : app.version,
            bundleID: app.bundleID,
            sizeMB: Double(app.sizeBytes) / 1024 / 1024,
            daysLeft: app.daysRemaining,
            signedAt: app.signedAt,
            expiresAt: app.expiresAt,
            certName: defaultCert?.title ?? "个人开发者证书",
            team: defaultCert?.team ?? "8F2K9D",
            category: "应用",
            colors: colors,
            symbol: symbol,
            fileName: app.fileName,
            localURL: app.fileURL
        )
    }

    // MARK: 查询

    var defaultCert: CertItem? {
        if let id = defaultCertID, let hit = certs.first(where: { $0.id == id }) {
            return hit
        }
        return certs.first
    }

    var expiringCount: Int {
        apps.filter { $0.status != .valid }.count
    }

    var deviceSummary: String {
        "\(devices.count) / 3 台"
    }

    var activeTask: SignTask? {
        task
    }

    var deviceName: String {
        UIDevice.current.name
    }

    var deviceUDID: String {
        let stored = UserDefaults.standard.string(forKey: "signdrop.udid")
        if let stored = stored { return stored }
        let generated = Self.makeUDID()
        UserDefaults.standard.set(generated, forKey: "signdrop.udid")
        return generated
    }

    private static func makeUDID() -> String {
        var parts: [String] = []
        for group in 0..<2 {
            var chunk = ""
            for _ in 0..<(group == 0 ? 8 : 12) {
                chunk += String(format: "%X", Int.random(in: 0...15))
            }
            parts.append(chunk)
        }
        return parts.joined(separator: "-")
    }

    // MARK: 登录

    func signIn(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        account = Account(
            email: trimmed.isEmpty ? DemoData.account.email : trimmed,
            signedIn: true,
            appCount: apps.count
        )
        isSignedIn = true
        UserDefaults.standard.set(true, forKey: "signdrop.signedIn")
    }

    func signOut() {
        isSignedIn = false
        UserDefaults.standard.set(false, forKey: "signdrop.signedIn")
    }

    // MARK: 证书导入

    func importCredential(p12: Data, password: String, profile: Data, label: String) {
        do {
            try state.addCredential(label: label, p12: p12, password: password, profile: profile)
            loadFromStore()
            if let last = certs.last {
                defaultCertID = last.id
            }
            notice = "证书已导入，共 \(certs.count) 张"
            showsCertImport = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeCert(_ cert: CertItem) {
        guard let credential = credentialIndex[cert.id] else {
            certs.removeAll { $0.id == cert.id }
            return
        }
        state.removeCredential(credential)
        loadFromStore()
    }

    // MARK: 签名

    func prepareSign(ipaURL: URL?) {
        if let url = ipaURL {
            let name = url.lastPathComponent
            pendingIPAURL = url
            pendingIPAName = name
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
            pendingIPASize = bytes / 1024 / 1024
            draftDisplayName = name.replacingOccurrences(of: ".ipa", with: "")
            draftBundleID = "com.signdrop." + name
                .replacingOccurrences(of: ".ipa", with: "")
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
        }
        showsSignConfig = true
    }

    func startSign() {
        let fileName = pendingIPAName.isEmpty ? "QuantumNotes.ipa" : pendingIPAName
        let size = pendingIPASize > 0 ? pendingIPASize : 24.6

        var newTask = SignTask(
            fileName: fileName,
            sizeMB: size,
            progress: 0,
            steps: [
                TaskStep(title: "解压 IPA 安装包", state: .running),
                TaskStep(title: "校验描述文件", state: .pending),
                TaskStep(title: "使用证书重签名", state: .pending),
                TaskStep(title: "打包并安装到设备", state: .pending)
            ],
            deviceName: deviceName,
            certName: defaultCert?.title ?? "个人开发者证书",
            startedAt: Date()
        )
        newTask.progress = 0.02
        task = newTask
        showsSignConfig = false
        tab = .tasks

        guard let url = pendingIPAURL,
              let cert = defaultCert,
              let credential = credentialIndex[cert.id] else {
            simulateSigning()
            return
        }
        runRealSigning(url: url, credential: credential)
    }

    private func runRealSigning(url: URL, credential: Credential) {
        let displayName = draftDisplayName
        let bundleID = draftBundleID
        Task { @MainActor in
            let result = await state.sign(
                ipaURL: url,
                credential: credential,
                bundleID: bundleID,
                displayName: displayName,
                progress: { [weak self] value, message in
                    guard let self = self else { return }
                    self.updateTask(progress: value, message: message)
                }
            )
            if result != nil {
                self.loadFromStore()
                self.finishTask(success: true)
            } else {
                self.finishTask(success: false)
            }
        }
    }

    private func simulateSigning() {
        taskTimer?.invalidate()
        taskTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.advanceDemoTask(timer)
            }
        }
    }

    private func advanceDemoTask(_ timer: Timer) {
        guard var current = task else {
            timer.invalidate()
            return
        }
        if current.progress >= 1 {
            timer.invalidate()
            finishTask(success: true)
            return
        }
        current.progress = min(current.progress + 0.035, 1)
        let stage = Int(current.progress * 4)
        for index in current.steps.indices {
            if index < stage {
                current.steps[index].state = .done
            } else if index == stage {
                current.steps[index].state = current.progress >= 1 ? .done : .running
            } else {
                current.steps[index].state = .pending
            }
        }
        task = current
    }

    private func updateTask(progress: Double, message: String) {
        guard var current = task else { return }
        current.progress = progress
        // 签名引擎的进度是 0…1，映射到四个步骤
        let stage = min(Int(progress * 4), 3)
        for index in current.steps.indices {
            current.steps[index].state = index < stage ? .done : (index == stage ? .running : .pending)
        }
        if progress >= 1 {
            current.steps = current.steps.map { step in
                var copy = step
                copy.state = .done
                return copy
            }
        }
        _ = message
        task = current
    }

    private func finishTask(success: Bool) {
        taskTimer?.invalidate()
        taskTimer = nil
        if var current = task {
            current.progress = 1
            current.steps = current.steps.map { step in
                var copy = step
                copy.state = .done
                return copy
            }
            task = current
        }
        if success {
            notice = "签名完成，已加入应用列表"
            logs.insert(
                SignLog(
                    title: "重新签名 · 成功",
                    detail: "证书 \(defaultCert?.team ?? "8F2K9D")",
                    dateText: Self.todayText(),
                    ok: true
                ),
                at: 0
            )
        } else {
            errorMessage = state.errorMessage ?? "签名失败，请检查证书与描述文件"
            logs.insert(
                SignLog(
                    title: "重新签名 · 失败",
                    detail: "证书或描述文件不可用",
                    dateText: Self.todayText(),
                    ok: false
                ),
                at: 0
            )
        }
    }

    func cancelTask() {
        taskTimer?.invalidate()
        taskTimer = nil
        task = nil
        notice = "任务已取消"
    }

    func clearFinished() {
        taskTimer?.invalidate()
        taskTimer = nil
        task = nil
    }

    // MARK: 应用操作

    func delete(_ app: AppItem) {
        if let url = app.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        apps.removeAll { $0.id == app.id }
        detailApp = nil
    }

    func ressign(_ app: AppItem) {
        draftDisplayName = app.name
        draftBundleID = app.bundleID
        draftVersion = app.version
        pendingIPAURL = app.localURL
        pendingIPAName = app.fileName ?? "\(app.name).ipa"
        pendingIPASize = app.sizeMB
        showsSignConfig = true
    }

    func markTaskDemo() {
        if task == nil {
            task = DemoData.task
        }
    }

    // MARK: 工具

    static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: Date())
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    static func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
