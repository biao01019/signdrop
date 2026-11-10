import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SignKit

extension UTType {
    static var ipa: UTType { UTType(filenameExtension: "ipa") ?? .data }
    static var mobileprovision: UTType { UTType(filenameExtension: "mobileprovision") ?? .data }
    static var p12: UTType { UTType(filenameExtension: "p12") ?? .data }
}

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var credentials: [Credential] = []
    @Published private(set) var apps: [SignedApp] = []
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var errorMessage: String?
    @Published var notice: String?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        loadCredentials()
        loadApps()
    }

    // MARK: - 凭证

    private func loadCredentials() {
        guard let data = Vault.load(),
              let decoded = try? decoder.decode([Credential].self, from: data) else {
            return
        }
        credentials = decoded
    }

    private func persistCredentials() {
        guard let data = try? encoder.encode(credentials) else { return }
        try? Vault.save(data)
    }

    func addCredential(label: String, p12: Data, password: String, profile: Data) throws {
        let credential = try Credential.make(
            label: label.isEmpty ? "未命名证书" : label,
            p12: p12,
            password: password,
            profile: profile
        )
        if let index = credentials.firstIndex(where: { $0.applicationIdentifier == credential.applicationIdentifier
            && $0.commonName == credential.commonName }) {
            credentials[index] = credential
        } else {
            credentials.append(credential)
        }
        persistCredentials()
    }

    func removeCredential(_ credential: Credential) {
        credentials.removeAll { $0.id == credential.id }
        persistCredentials()
    }

    // MARK: - 产物

    private var appsIndexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("apps.json")
    }

    private func loadApps() {
        guard let data = try? Data(contentsOf: appsIndexURL),
              let decoded = try? decoder.decode([SignedApp].self, from: data) else {
            return
        }
        // 文件被系统清理或用户手动删除时，同步剔除索引里的幽灵条目
        apps = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func persistApps() {
        guard let data = try? encoder.encode(apps) else { return }
        try? data.write(to: appsIndexURL, options: .atomic)
    }

    func delete(_ app: SignedApp) {
        try? FileManager.default.removeItem(at: app.fileURL)
        apps.removeAll { $0.id == app.id }
        persistApps()
    }

    // MARK: - 签名

    func sign(
        ipaURL: URL,
        credential: Credential,
        bundleID: String,
        displayName: String,
        progress handler: ((Double, String) -> Void)? = nil
    ) async -> SignedApp? {
        guard !isWorking else { return nil }

        isWorking = true
        progress = 0
        progressText = "准备中"
        defer { isWorking = false }

        do {
            let identity = try credential.loadIdentity()
            let profile = try credential.loadProfile()

            let name = displayName.isEmpty ? "Signed" : displayName
            let stamp = Int(Date().timeIntervalSince1970)
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            let output = SignedApp.directory.appendingPathComponent("\(safeName)-\(stamp).ipa")

            let configuration = SignConfiguration(
                newBundleID: bundleID.isEmpty ? nil : bundleID,
                displayName: name,
                identity: identity,
                profile: profile
            )

            let outcome = try await runInBackground {
                try Signer.sign(
                    ipa: ipaURL,
                    to: output,
                    configuration: configuration
                ) { [weak self] value, message in
                    Task { @MainActor in
                        self?.progress = value
                        self?.progressText = message
                        handler?(value, message)
                    }
                }
            }

            let metadata = try? IPAMetadata.read(ipa: output)
            let app = SignedApp(
                name: outcome.displayName.isEmpty ? name : outcome.displayName,
                bundleID: outcome.bundleID,
                version: metadata?.version ?? "",
                signedAt: Date(),
                expiresAt: outcome.expiresAt,
                fileName: output.lastPathComponent,
                sizeBytes: outcome.sizeBytes
            )
            apps.insert(app, at: 0)
            persistApps()
            notice = "签名完成，共处理 \(outcome.signedUnitCount) 个可签名单元"
            return app
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 把阻塞的签名流程放到后台队列，避免卡住主线程。
    private func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 工具

    /// 把用户选中的文件拷进沙盒。文件选择器给的是临时授权 URL，
    /// 必须在回调作用域内复制，否则后续读取会失败。
    nonisolated static func importFile(from url: URL, to folder: String) throws -> URL {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
