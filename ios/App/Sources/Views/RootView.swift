import SwiftUI

/// 根视图：登录门 + 四个 Tab + 三级页面的全屏覆盖
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            if model.isSignedIn {
                tabs
            } else {
                LoginView()
                    .transition(.opacity)
            }

            overlays
        }
        .animation(.easeInOut(duration: 0.2), value: model.isSignedIn)
        .animation(.easeOut(duration: 0.24), value: model.showsSignConfig)
        .animation(.easeOut(duration: 0.24), value: model.showsCertImport)
        .animation(.easeOut(duration: 0.26), value: model.detailApp?.id)
        .alert(alertTitle, isPresented: alertBinding) {
            Button("好", role: .cancel) {
                model.errorMessage = nil
                model.notice = nil
            }
        } message: {
            Text(model.errorMessage ?? model.notice ?? "")
        }
    }

    // MARK: Tab 容器

    private var tabs: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch model.tab {
                case .apps: AppsHomeView()
                case .certs: CertsView()
                case .tasks: TasksView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 设计稿里胶囊底边距屏幕底 22（压在 Home 指示条安全区之上）
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                FloatingTabBar(selection: $model.tab)
                    .padding(.bottom, 22)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(true)
        }
    }

    // MARK: 全屏覆盖

    @ViewBuilder
    private var overlays: some View {
        if model.showsSignConfig {
            SignConfigView()
                .transition(.move(edge: .bottom))
                .zIndex(2)
        }

        if model.showsCertImport {
            CertImportView()
                .transition(.move(edge: .bottom))
                .zIndex(3)
        }

        if let app = model.detailApp {
            ZStack {
                Palette.bg.ignoresSafeArea()
                AppDetailView(app: app)
            }
            .transition(.move(edge: .trailing))
            .zIndex(1)
        }
    }

    // MARK: 提示

    private var alertTitle: String {
        model.errorMessage == nil ? "提示" : "出错了"
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || model.notice != nil },
            set: { showing in
                if !showing {
                    model.errorMessage = nil
                    model.notice = nil
                }
            }
        )
    }
}
