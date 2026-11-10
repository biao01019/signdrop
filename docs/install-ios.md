# 怎么把它装进 iPhone

这份文档只解决一件事：**从仓库里的源码，到你手机上能点开的图标。**

---

## 先说清楚那道硬门槛

iOS 上任何一个 App 都是 Mach-O 可执行文件，只能由 macOS 上的 `clang` / `swiftc` 加 iOS SDK 产出。
Windows 上没有这套工具链，也没有任何替代品——这不是方案选择，是苹果的规矩。

所以「我能直接在你的 Windows 电脑上生成一个 .ipa」这句话是不成立的。**必须有一台 Mac 编译一次**，
或者借 GitHub 的 macOS 机器编译（免费）。编译出来的包是**未签名**的，再用你自己的 Apple ID 签一次才能装。

编译只需要做一次。装进去之后，日常签名、改 Bundle ID、续签都在手机上完成，不用再碰电脑。

---

## 三条路，按省事程度排

| | 需要什么 | 花多久 | 之后续签 |
|---|---|---|---|
| **A. GitHub Actions + Sideloadly** | 一个 GitHub 账号（免费）+ Windows 电脑 + 数据线 | 约 15 分钟 | 每 7 天重装一次 |
| **B. Mac + Xcode** | 一台 Mac | 约 10 分钟 | 每 7 天 ⌘R 一次 |
| **C. 付费开发者账号** | $99/年 | 同 A 或 B | 1 年 |

三条路的产物是同一个 App，区别只在签名用的账号。

---

## 路线 A：GitHub Actions + Sideloadly（Windows 用户走这条）

### A1. 建仓库、推代码

在 [github.com/new](https://github.com/new) 建一个**私有**仓库（名字随意，比如 `signdrop`），不要勾选任何模板。

然后在项目根目录（有 `ios/` 和 `.github/` 的那一层）执行：

```bash
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/<你的账号>/signdrop.git
git push -u origin main
```

第一次 push 会弹浏览器让你登录 GitHub，登录一次以后就记住了。

> 私有仓库完全够用。Actions 对私有仓库同样免费（每月 2000 分钟，这个工程一次编译约 4 分钟）。

### A2. 等它编译

push 上去后自动开始跑：仓库页 → **Actions** → 左侧 `build`。

两个任务按顺序执行：

1. `核心逻辑测试` —— 跑 SignKit 的单元测试（DER、Mach-O 注入、CMS 签名）
2. `编译并打包未签名 IPA` —— `xcodegen` 生成工程 → `xcodebuild` 编译 → 打包成 `SignKit-unsigned.ipa`

绿了之后，IPA 挂在 **Releases → latest** 上，直链长这样：

```
https://github.com/<你的账号>/signdrop/releases/download/latest/SignKit-unsigned.ipa
```

浏览器直接打开就下载，不用登录。

> 编译失败的话把 Actions 里的 `build-log` 下下来，是 Swift 编译错误，改完再 push 一次即可。
> 这份工程是本机（Windows）写的，没经过编译器验证，第一次很可能有几处要修。

### A3. 用 Sideloadly 签名安装（Windows）

1. 装 [iTunes](https://www.apple.com/itunes/download/win64) —— 装官网上那个 exe 版，**不要装 Microsoft Store 版**，Sideloadly 要靠它带的 USB 驱动
2. 装 [Sideloadly](https://sideloadly.io/)（Windows 版，绿色单文件）
3. iPhone 用数据线连电脑，手机上点「信任此电脑」
4. 打开 Sideloadly：
   - **IPA** 拖入刚下载的 `SignKit-unsigned.ipa`
   - **Apple ID** 填你自己的，`@icloud.com` 或 `@gmail.com` 都行
   - **Bundle ID** 改成一个全世界唯一的，例如 `com.你的名字.signdrop`
   - 点 **Start**，会让你输 Apple ID 密码，收到双重认证验证码后填进去
5. 装完后，手机上第一次打开会提示「未受信任的开发者」：
   **设置 → 通用 → VPN 与设备管理 → 开发者 App → 点你的 Apple ID → 信任**

图标出现在桌面上，就能用了。

> 免费 Apple ID 的包 **7 天后失效**（点开闪退）。到期用 A3 再拖一次即可，数据不丢。
> 一个免费账号同时最多 3 个自签 App。

---

## 路线 B：有 Mac

```bash
cd ios
brew install xcodegen
xcodegen generate
open SignKit.xcodeproj
```

Xcode 里：选 `SignKitApp` target → Signing & Capabilities → Team 选你的 Apple ID（免费的 Personal Team 就行）
→ Bundle Identifier 改成唯一的 → 连上 iPhone → ⌘R。

7 天后重按一次 ⌘R。

---

## 装进去之后，能做什么、不能做什么

### 能做

- **用你自己的证书给任意 IPA 重签名**：导入 `.p12` + `.mobileprovision`，选包，改 Bundle ID 和显示名，签名全在手机本地完成（Mach-O 重写、CodeDirectory 重算、CMS 签名），不联网
- 递归处理扩展和 Watch App，第三方框架的 ID 保持原样
- 查看剩余有效期、到期提醒、重新签名
- 应用分身：一套通配证书签任意后缀的 Bundle ID

### 不能做（免费账号尤其要注意）

**一、签好的包，还是得靠 SideStore / Sideloadly 装到手机上。**

App 自己调 `installd` 安装会被系统拒绝——iOS 只接受来自 USB 通道的安装请求，要绕过必须用
「VPN 环回 + 模拟 usbmuxd」（SideStore 的 minimuxer + StosVPN 就是干这个的），而 Network Extension
权限免费账号申请不到。所以流程是：**本工具重签 → 分享到「文件」→ SideStore 里选这个包安装**。

**二、免费 Apple ID 用不了「手动证书」模式。**

免费账号进不去开发者门户的 Certificates / Profiles 页面，也就导不出 `.p12` 和 `.mobileprovision`。
想用这个模式，需要 $99/年 的付费开发者账号。

要让免费账号也能签，得把 Apple ID 登录（SRP + anisette + 门户接口）做进 App 里，像 AltStore 那样——
项目里已经有这份 Python 实现（`app/srp.py`、`app/auth.py`、`app/portal.py`，SRP 用 RFC 5054 官方向量校准过），
但移植到 Swift 是一块不小的工作，而且这套接口是逆向出来的，苹果一改就废。

**三、App Store 下载的加密包签不了。** 带 `SC_Info`（FairPlay 加壳）的包重签后无法运行，工具会识别并提示。

**四、资源封印（CodeResources）还没生成。** 只覆盖了 CodeDirectory 的三个特殊槽，开发签名通常够用；
如果安装时报「签名无效」，第一个要补的就是这个。

---

## 常见报错

| 现象 | 原因 | 处理 |
|---|---|---|
| `xcodebuild` 报一堆 Swift 编译错误 | 工程没在本机编译过 | 看 `build-log`，改完 push 重跑 |
| Sideloadly 卡在 `Generating...` / 提示 auth 失败 | Apple ID 双重认证或设备未信任 | 先在手机上「信任此电脑」，验证码填对；还不行换应用专用密码 |
| 打开闪退 | 证书过期（满 7 天） | 重新走 A3 装一次 |
| 提示「无法验证 App」 | 没信任开发者描述文件 | 设置 → 通用 → VPN 与设备管理 → 信任 |
| 签名后安装报「签名无效」 | CodeDirectory 特殊槽不完整 | 见上面第四条限制 |
| 装的包在桌面出现但点开白屏 | IPA 是加密包或 Bundle ID 冲突 | 换未加密的包，换一个 Bundle ID |
