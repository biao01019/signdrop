import SwiftUI
import UIKit
import SignKit

/// 界面状态 + 业务动作。
///
/// 这里没有任何演示数据：应用列表来自 `AppState` 里真实签出来的 IPA，
/// 证书来自 Keychain 里真实存在的凭证，登录走 SRP 真连苹果。
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

    enum LoginStage {
        case credentials
        case twoFactor
        case signedIn
    }

    // MARK: 状态

    @Published var tab: Tab = .apps
    @Published var apps: [AppItem] = []
    @Published var certs: [CertItem] = []
    @Published var devices: [DeviceItem] = []
    @Published var logs: [SignLog] = []
    @Published var task: SignTask?
    @Published var account = Account(email: "", signedIn: false, appCount: 0)
    @Published var isSignedIn = false

    /// 详情页（为 nil 时显示 Tab 主体）
    @Published var detailApp: AppItem?
    /// 签名配置页
    @Published var showsSignConfig = false
    /// 导入证书页
    @Published var showsCertImport = false
    @Published var errorMessage: String?
    @Published var notice: String?

    // 登录
    @Published var loginStage: LoginStage = .credentials
    @Published var isLoggingIn = false
    @Published var loginError: String?
    @Published var accountEmail = ""

    // 证书
    @Published var isFetchingCertificate = false
    @Published var certificateError: String?
    @Published var savedUDID = ""

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
    private var session: AccountSession?
    private var codeContinuation: CheckedContinuation<String, Error>?

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
        savedUDID = UserDefaults.standard.string(forKey: "signdrop.udid") ?? ""
        accountEmail = UserDefaults.standard.string(forKey: "signdrop.email") ?? ""
        let restored = UserDefaults.standard.bool(forKey: "signdrop.signedIn") && !accountEmail.isEmpty
        isSignedIn = restored
        loginStage = restored ? .signedIn : .credentials
        if restored {
            account = Account(email: accountEmail, signedIn: true, appCount: 0)
        }

        rebuildDevices()
        loadFromStore()
        account.appCount = apps.count

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

        apps = state.apps.enumerated().map { makeApp($0.element, index: $0.offset) }
        account.appCount = apps.count
    }

    private func makeCert(_ credential: Credential, index: Int) -> CertItem {
        let remaining = max(credential.daysRemaining, 0)
        let total = max(remaining, 1) + 30
        return CertItem(
            title: credential.label.isEmpty ? "开发者证书" : credential.label,
            team: credential.teamID,
            subtitle: credential.provisionsAllDevices ? "企业分发" : "Apple ID",
            kind: credential.provisionsAllDevices ? .enterprise : .personal,
            expiresAt: credential.expiresAt,
            totalDays: total,
            isDefault: index == 0,
            devices: devices
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
            certName: defaultCert?.title ?? "",
            team: defaultCert?.team ?? "",
            category: "应用",
            colors: colors,
            symbol: symbol,
            fileName: app.fileName,
            localURL: app.fileURL
        )
    }

    private func rebuildDevices() {
        let udid = savedUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUDID(udid) else {
            devices = []
            return
        }
        devices = [
            DeviceItem(
                name: UIDevice.current.name,
                udid: udid,
                activated: true,
                isTablet: UIDevice.current.userInterfaceIdiom == .pad
            )
        ]
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

    var activeTask: SignTask? { task }

    var deviceName: String {
        UIDevice.current.name
    }

    var deviceUDID: String {
        savedUDID
    }

    var hasUDID: Bool {
        Self.isValidUDID(savedUDID)
    }

    static func isValidUDID(_ value: String) -> Bool {
        let cleaned = value.replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 24 || cleaned.count == 40 else { return false }
        return cleaned.allSatisfy { $0.isHexDigit }
    }

    func updateUDID(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        savedUDID = cleaned
        UserDefaults.standard.set(cleaned, forKey: "signdrop.udid")
        rebuildDevices()
        loadFromStore()
    }

    // MARK: 登录

    func login(email: String, password: String) async {
        guard !isLoggingIn else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") else {
            loginError = "请输入完整的 Apple ID（邮箱形式）"
            return
        }
        guard !password.isEmpty else {
            loginError = "请输入密码"
            return
        }

        isLoggingIn = true
        loginError = nil
        loginStage = .credentials

        let session = AccountSession()
        self.session = session

        do {
            try await session.signIn(appleID: trimmedEmail, password: password) { [weak self] in
                guard let self = self else {
                    throw AppleIDAuth.AuthError.notAuthenticated
                }
                return try await self.awaitVerificationCode()
            }
            completeLogin(email: trimmedEmail)
        } catch {
            loginError = error.localizedDescription
            loginStage = .credentials
            self.session = nil
            codeContinuation = nil
            appendLog(title: "Apple ID 登录失败", detail: error.localizedDescription, ok: false)
        }

        isLoggingIn = false
    }

    /// 挂起等待用户输入验证码。登录流程本身还在 await 里跑着。
    private func awaitVerificationCode() async throws -> String {
        loginStage = .twoFactor
        return try await withCheckedThrowingContinuation { continuation in
            self.codeContinuation = continuation
        }
    }

    func submitVerificationCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        continuation.resume(returning: trimmed)
    }

    func cancelVerification() {
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        continuation.resume(throwing: AppleIDAuth.AuthError.notAuthenticated)
        loginStage = .credentials
        session = nil
    }

    private func completeLogin(email: String) {
        accountEmail = email
        account = Account(email: email, signedIn: true, appCount: apps.count)
        isSignedIn = true
        loginStage = .signedIn
        loginError = nil
        UserDefaults.standard.set(true, forKey: "signdrop.signedIn")
        UserDefaults.standard.set(email, forKey: "signdrop.email")
        appendLog(title: "Apple ID 登录成功", detail: email, ok: true)
    }

    func signOut() {
        isSignedIn = false
        loginStage = .credentials
        account = Account(email: "", signedIn: false, appCount: 0)
        accountEmail = ""
        session = nil
        UserDefaults.standard.set(false, forKey: "signdrop.signedIn")
        UserDefaults.standard.removeObject(forKey: "signdrop.email")
    }

    // MARK: 证书

    /// 用当前登录的 Apple ID 现场申请一张开发证书 + 描述文件。
    ///
    /// 默认申请通配符 App ID（`TEAMID.*`），这样一张证书能签任意 Bundle ID，
    /// 不会把免费账号"每周 10 个 App ID"的额度耗在每一款 App 上。
    func fetchCertificate(wildcard: Bool = true) async {
        guard let session = session, session.isAuthenticated else {
            certificateError = "请先登录 Apple ID"
            return
        }
        let udid = savedUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUDID(udid) else {
            certificateError = "请先填写这台设备的 UDID（40 位或 24 位十六进制）"
            return
        }

        isFetchingCertificate = true
        certificateError = nil

        do {
            let identity = try await session.provision(
                udid: udid,
                deviceName: deviceName,
                bundleID: wildcard ? "*" : "com.signdrop.\(UUID().uuidString.prefix(8).lowercased())"
            )
            try state.addAppleIDCredential(identity)
            loadFromStore()
            if let last = certs.last {
                defaultCertID = last.id
            }
            appendLog(title: "申请证书成功", detail: "Team \(identity.teamID) · \(identity.deviceCount) 台设备", ok: true)
            notice = "证书已就绪，可以直接签名了"
            showsCertImport = false
        } catch {
            certificateError = error.localizedDescription
            appendLog(title: "申请证书失败", detail: error.localizedDescription, ok: false)
        }

        isFetchingCertificate = false
    }

    // MARK: 证书导入（手动 p12）

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
        guard let url = ipaURL else {
            errorMessage = "没有拿到文件，请重新选择 IPA"
            return
        }
        let name = url.lastPathComponent
        pendingIPAURL = url
        pendingIPAName = name
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        pendingIPASize = bytes / 1024 / 1024

        let base = name.replacingOccurrences(of: ".ipa", with: "")
        draftDisplayName = base

        // Bundle ID 优先从 IPA 里读，读不到再拼一个
        if let metadata = try? IPAMetadata.read(ipa: url), !metadata.bundleID.isEmpty {
            draftBundleID = metadata.bundleID
            draftVersion = metadata.version
            if !metadata.displayName.isEmpty {
                draftDisplayName = metadata.displayName
            }
        } else {
            draftBundleID = "com.signdrop." + base
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
        }

        showsSignConfig = true
    }

    func startSign() {
        guard let url = pendingIPAURL else {
            errorMessage = "请先选择要签名的 IPA 文件"
            return
        }
        guard let cert = defaultCert, let credential = credentialIndex[cert.id] else {
            errorMessage = "还没有可用证书。请先在证书页用 Apple ID 获取，或导入 p12"
            return
        }

        let fileName = pendingIPAName.isEmpty ? url.lastPathComponent : pendingIPAName
        var newTask = SignTask(
            fileName: fileName,
            sizeMB: pendingIPASize,
            progress: 0,
            steps: [
                TaskStep(title: "解压 IPA 安装包", state: .running),
                TaskStep(title: "校验描述文件", state: .pending),
                TaskStep(title: "使用证书重签名", state: .pending),
                TaskStep(title: "生成安装包", state: .pending)
            ],
            deviceName: deviceName,
            certName: cert.title,
            startedAt: Date()
        )
        newTask.progress = 0.02
        task = newTask
        showsSignConfig = false
        tab = .tasks

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
                    self?.updateTask(progress: value, message: message)
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

    private func updateTask(progress: Double, message: String) {
        guard var current = task else { return }
        current.progress = progress
        let stage = min(Int(progress * 4), 3)
        for index in current.steps.indices {
            current.steps[index].state = index < stage ? .done : (index == stage ? .running : .pending)
        }
        if progress >= 1 {
            for index in current.steps.indices {
                current.steps[index].state = .done
            }
        }
        _ = message
        task = current
    }

    private func finishTask(success: Bool) {
        if var current = task {
            current.progress = 1
            for index in current.steps.indices {
                current.steps[index].state = .done
            }
            task = current
        }

        if success {
            notice = "签名完成，已加入应用列表"
            appendLog(title: "重新签名 · 成功", detail: defaultCert?.team ?? "", ok: true)
        } else {
            let detail = state.errorMessage ?? "签名失败，请检查证书与描述文件"
            errorMessage = detail
            appendLog(title: "重新签名 · 失败", detail: detail, ok: false)
        }
    }

    func cancelTask() {
        task = nil
        notice = "任务已取消"
    }

    func clearFinished() {
        task = nil
    }

    // MARK: 应用操作

    func delete(_ app: AppItem) {
        if let signed = state.apps.first(where: { $0.fileName == app.fileName }) {
            state.delete(signed)
        } else if let url = app.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        apps.removeAll { $0.id == app.id }
        detailApp = nil
        account.appCount = apps.count
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

    // MARK: 日志

    private func appendLog(title: String, detail: String, ok: Bool) {
        guard keepLogs else { return }
        logs.insert(
            SignLog(title: title, detail: detail, dateText: Self.todayText(), ok: ok),
            at: 0
        )
        if logs.count > 60 { logs.removeLast(logs.count - 60) }
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
