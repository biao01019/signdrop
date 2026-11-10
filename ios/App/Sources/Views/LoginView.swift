import SwiftUI

/// 07 · 登录
///
/// 设计稿用的是 24 的页边距（其它页面是 16），控件宽 345 / 输入卡 344.1。
/// 纵向：logo 180（68×68）· 标题 259 · 副标题 308 · 输入卡 348.4（高 100.3）
/// 忘记密码 466 · 登录 501.4 · 或使用 577 · Apple 604.6 · 特性卡 674.2（高 60）· 页脚 748
///
/// 这里是真的连苹果：密码走 SRP，密码明文不上网络也不落盘。
/// 账号开了双重认证时，输入卡会原地切成验证码输入，布局高度不变。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showsPassword = false
    @State private var appleHint = false
    @FocusState private var focused: Field?

    private enum Field { case email, password, code }

    private let pagePadding: CGFloat = 24

    private var isTwoFactor: Bool {
        model.loginStage == .twoFactor
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                logo
                    .padding(.leading, pagePadding)
                    .padding(.top, 121)

                Text(isTwoFactor ? "两步验证" : "欢迎回来")
                    .font(TypeScale.loginTitle)
                    .kerning(-0.3)
                    .foregroundColor(Palette.ink)
                    .frame(height: 34, alignment: .leading)
                    .padding(.leading, pagePadding)
                    .padding(.top, 11)

                Text(isTwoFactor
                     ? "输入你信任设备上显示的 6 位验证码"
                     : "用你的 Apple ID 登录，证书在本机生成")
                    .font(TypeScale.value)
                    .foregroundColor(Palette.sub)
                    .frame(height: 19, alignment: .leading)
                    .padding(.leading, pagePadding)
                    .padding(.top, 15)

                inputCard
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 21.4)

                statusRow
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 17.3)

                PrimaryButton(
                    title: primaryTitle,
                    height: 51.3,
                    font: TypeScale.bigButton,
                    enabled: !model.isLoggingIn
                ) {
                    focused = nil
                    submit()
                }
                .padding(.horizontal, pagePadding)
                .padding(.top, 19.4)

                orDivider
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 24.3)

                appleButton
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 11.6)

                if appleHint {
                    Text("「通过 Apple 继续」拿不到开发者证书——签名必须用 Apple ID 密码向苹果申请。用上面的邮箱密码登录即可。")
                        .font(TypeScale.meta)
                        .foregroundColor(Palette.orangeText)
                        .lineSpacing(2)
                        .padding(.horizontal, pagePadding)
                        .padding(.top, 8)
                }

                featuresCard
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 18.3)

                footer
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 13.8)

                Color.clear.frame(height: 40)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .onAppear { email = model.accountEmail }
    }

    // MARK: 动作

    private var primaryTitle: String {
        if model.isLoggingIn { return isTwoFactor ? "验证中…" : "登录中…" }
        return isTwoFactor ? "验证" : "登录"
    }

    private func submit() {
        if isTwoFactor {
            model.submitVerificationCode(code)
        } else {
            Task { await model.login(email: email, password: password) }
        }
    }

    // MARK: 标识

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x6D6AF8), Color(hex: 0x9B5CF6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color(hex: 0x6D6AF8).opacity(0.28), radius: 12, x: 0, y: 10)
            Image(systemName: "checkmark.shield")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: 68, height: 68)
    }

    // MARK: 输入

    private var inputCard: some View {
        ZStack {
            if isTwoFactor {
                verificationRow
            } else {
                credentialRows
            }
        }
        .frame(height: 100.3)
        .card()
    }

    private var credentialRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Palette.sub)
                    .frame(width: 19)

                ZStack(alignment: .leading) {
                    if email.isEmpty {
                        Text("你的 Apple ID")
                            .font(.system(size: 16))
                            .foregroundColor(Palette.ter)
                    }
                    TextField("", text: $email)
                        .font(.system(size: 16))
                        .foregroundColor(Palette.ink)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($focused, equals: .email)
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 50)

            Rectangle()
                .fill(Palette.divider)
                .frame(height: Metrics.hairline)
                .padding(.leading, Metrics.cardPadding)

            HStack(spacing: 12) {
                Image(systemName: "lock")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Palette.sub)
                    .frame(width: 19)

                ZStack(alignment: .leading) {
                    if password.isEmpty {
                        Text("••••••••")
                            .font(.system(size: 17))
                            .kerning(2)
                            .foregroundColor(Palette.ter)
                            .padding(.bottom, 4)
                    }
                    // 注意：View 上的 .kerning 是 iOS 16 API，输入控件不能加，
                    // 密码圆点的字距只作用在占位 Text 上。
                    if showsPassword {
                        TextField("", text: $password)
                            .font(.system(size: 17))
                            .foregroundColor(Palette.ink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .focused($focused, equals: .password)
                    } else {
                        SecureField("", text: $password)
                            .font(.system(size: 17))
                            .foregroundColor(Palette.ink)
                            .focused($focused, equals: .password)
                    }
                }

                Button(action: { showsPassword.toggle() }) {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(Color(hex: 0xB6B6BC))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: 48.9)
        }
    }

    private var verificationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Palette.blue)
                .frame(width: 19)

            ZStack(alignment: .leading) {
                if code.isEmpty {
                    Text("6 位验证码")
                        .font(.system(size: 16))
                        .foregroundColor(Palette.ter)
                }
                TextField("", text: $code)
                    .font(.system(size: 17))
                    .foregroundColor(Palette.ink)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused, equals: .code)
            }

            Text("\(code.count)/6")
                .font(.system(size: 12))
                .foregroundColor(Palette.ter)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 100.3)
        .onAppear { focused = .code }
    }

    // MARK: 状态行（替换设计稿上的「忘记密码?」）

    @ViewBuilder
    private var statusRow: some View {
        Group {
            if let error = model.loginError {
                Text(error)
                    .font(TypeScale.meta)
                    .foregroundColor(Palette.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if isTwoFactor {
                Button(action: { model.cancelVerification() }) {
                    Text("返回重新登录")
                        .font(TypeScale.bodyStrong)
                        .foregroundColor(Palette.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button(action: {}) {
                    Text("忘记密码?")
                        .font(TypeScale.bodyStrong)
                        .foregroundColor(Palette.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 16)
    }

    // MARK: 分隔与第三方

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(hex: 0xE2E2E8))
                .frame(height: 1)
            Text("或使用")
                .font(TypeScale.meta)
                .foregroundColor(Palette.ter)
            Rectangle()
                .fill(Color(hex: 0xE2E2E8))
                .frame(height: 1)
        }
        .frame(height: 16)
    }

    private var appleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                appleHint.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "applelogo")
                    .font(.system(size: 19, weight: .medium))
                Text("通过 Apple 继续")
                    .font(TypeScale.bigButton)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 51.3)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(Color(hex: 0x17171A))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 特性

    private var featuresCard: some View {
        HStack(spacing: 0) {
            feature("checkmark.shield", "本地签名")
            feature("lock", "私钥不上传")
            feature("arrow.left.square", "随时可退出")
        }
        .frame(height: 60)
        .card()
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Palette.blue)
                .frame(height: 19)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Palette.sub)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 页脚

    private var footer: some View {
        HStack(spacing: 6) {
            Text("登录即表示同意")
                .font(TypeScale.body)
                .foregroundColor(Palette.sub)
            Button(action: {}) {
                Text("使用条款")
                    .font(TypeScale.bodyStrong)
                    .foregroundColor(Palette.blue)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}
