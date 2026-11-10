# SignKit · iOS 端自签名工具

在 iPhone 上直接给 IPA 重签名的工具。用自己的 Apple ID 证书，不碰任何第三方证书，也没有签名名额买卖。

签名逻辑全部在设备本地完成：解析 Mach-O、重建 CodeDirectory、生成 CMS 签名、重打包。不上传 IPA，不联网。

---

## 先看两个绕不过去的约束

**一、这个 App 自己必须先被装一次。**

它没法给自己签名。第一次装进去只有三条路：

| 方式 | 需要什么 | 有效期 |
|---|---|---|
| Xcode 直连 | 一台 Mac + 免费 Apple ID | 7 天，到期需重连一次 |
| SideStore / AltStore | 一台电脑装一次 SideStore | 之后 7 天自动续签 |
| 付费开发者账号 | $99/年 | 1 年 |

装进去之后，日常签名和续签就不再需要电脑。

**二、签好的包要装到手机上，目前还需要 SideStore 帮一次。**

iOS 的 `installd` 只接受来自 USB 通道的安装请求。普通沙盒 App 直接调用会被拒绝，必须用「VPN 环回隧道 + 模拟 usbmuxd」把它骗过去——SideStore 就是靠这个实现的（minimuxer + StosVPN）。免费 Apple ID 无法申请 Network Extension 权限，所以这一步没法用纯公开 API 完成。

所以当前流程是：**本工具负责重签 → 分享到「文件」或直接交给 SideStore → SideStore 完成安装**。整个过程中不需要电脑。

---

## 装进手机的三种方式

### 方式 A：GitHub Actions + SideStore（无需 Mac）

1. 把 `ios/` 目录推到一个 GitHub 仓库，Actions 会自动编译（见 `.github/workflows/ios-build.yml`）
2. 下载产物 `SignKit-unsigned-ipa`
3. 手机装好 SideStore（首次需要电脑，按 SideStore 官网步骤执行）
4. SideStore → 加号 → 从「文件」选择 `SignKit-unsigned.ipa`
5. SideStore 会用你的 Apple ID 签好并安装

### 方式 B：Xcode 直连（有 Mac 时最快）

```bash
cd ios
brew install xcodegen
xcodegen generate
open SignKit.xcodeproj
```

在 Xcode 里：

1. 选中 `SignKitApp` target → Signing & Capabilities
2. Team 选你自己的 Apple ID（免费的 "Personal Team" 即可）
3. Bundle Identifier 改成一个唯一的，例如 `com.yourname.signkit`
4. 连上 iPhone，⌘R 运行

7 天后图标会打不开，重新 ⌘R 一次即可。

### 方式 C：付费账号签名后长期使用

同上，把 Team 换成付费开发者账号，有效期变成 1 年。

---

## 用起来

### 1. 准备证书（一次性）

在 [developer.apple.com](https://developer.apple.com/account/resources) 上：

1. **Certificates** → 加号 → *Apple Development* → 按提示在本机生成 CSR 并上传 → 下载 `.cer`
2. 双击 `.cer` 导入钥匙串 → 找到带私钥的那条 → 右键导出 `.p12`，设一个密码
3. **Devices** → 加号 → 填入你的 UDID（在 Finder 里点设备名旁边的型号处可以看到）
4. **Profiles** → 加号 → *iOS App Development* → 选 App ID、证书、设备 → 下载 `.mobileprovision`

> 想签不同的 App（应用分身），最省事的办法是建一个**通配 App ID**，例如 `com.yourname.*`，这样一套凭证能签任意后缀的 Bundle ID。

### 2. 导入到工具里

设置 → 导入证书 → 选 `.p12`、填密码、选 `.mobileprovision`。

保存时会用你的密码实际解密一次 p12，密码不对立刻报错，不会存进去。凭证存放在系统钥匙串（`WhenUnlockedThisDeviceOnly`），锁屏后读不到，也不会进 iCloud 备份。

### 3. 签名

首页加号 → 选 IPA → 选凭证 → 改不改 Bundle ID 都行 → 开始。

会做的事：

- 递归改写主包、扩展（`.appex`）、Watch App 的 Bundle ID，保持层级关系
- 第三方框架的 ID 原样保留（改了会崩）
- 清掉旧的 `_CodeSignature`、`CodeResources`、`SC_Info`
- 先签内层框架和扩展，再签外层主程序
- 每个可执行文件重算 CodeDirectory 并做 RSA-2048/SHA-256 的 CMS 签名

---

## 不能做的和已知限制

**资源封印（CodeResources）尚未生成。** CodeDirectory 只覆盖了 `Info.plist`、Requirements 和 entitlements 三个特殊槽。对开发签名的安装流程通常够用，但如果安装时报「签名无效」，这是第一个要补的地方。

**加密的 IPA 签不了。** 从 App Store 下载的包带 `SC_Info`（FairPlay 加壳），重签后无法运行。工具会识别并提示。需要用未加密的包。

**通用二进制（fat）会报错。** 目前只处理单架构 arm64。遇到 fat 包会明确报错而不是写坏文件。

**需要手动提供 p12 和描述文件。** 没有做 Apple ID 一键登录——那套 GrandSlam/idmsa 接口是逆向出来的，苹果一改就废，而且失败时几乎给不出有效信息。

---

## 代码结构

```
ios/
  SignKit/                    核心库，可独立测试
    Sources/SignKit/
      Support/ASN1.swift        DER 编码器 + OID + 哈希
      Signing/CodeDirectory.swift  CodeDirectory / SuperBlob / entitlements blob
      Signing/MachO.swift       Mach-O 解析与 LC_CODE_SIGNATURE 注入
      Signing/CMS.swift         PKCS#7 SignedData 构造
      Signing/Signer.swift      完整流程编排
      IPA/Bundle.swift          包扫描、ID 改写、entitlements 生成
      IPA/ProvisioningProfile.swift  描述文件解析与校验
      IPA/IPAMetadata.swift     IPA 元信息读取
    Tests/SignKitTests/         25+ 项测试
  App/Sources/                SwiftUI 界面
    SignKitApp.swift            入口，注入 AppModel
    AppState.swift              凭证 / 产物的真实读写与签名调用
    Vault.swift                 钥匙串加密存储
    Design/Theme.swift          Palette / Metrics / TypeScale（设计稿实测值）
    Design/UIComponents.swift   卡片、徽标、开关、按钮等零件
    Model/UIModels.swift        界面模型 + 设计稿示例数据
    Model/AppModel.swift        界面状态机（Tab、任务进度、导入导出）
    Views/AppsHomeView.swift    01 我的应用
    Views/AppDetailView.swift   02 应用详情
    Views/SignConfigView.swift  03 签名配置
    Views/CertsView.swift       04 证书（含 05 导入证书）
    Views/TasksView.swift       05 任务
    Views/SettingsView.swift    06 设置
    Views/LoginView.swift       07 登录
    Views/FloatingTabBar.swift  底部悬浮导航 + 二级页导航条
    Views/RootView.swift        Tab 容器 + 全屏覆盖层
  project.yml                 XcodeGen 配置
```

## 界面

7 个页面按 `Signdrop · iOS 自签名 App UI.pdf` 1:1 复刻，画布 393×852（iPhone 15 Pro）。

设计值先量化成一张规格表，再落到 `Design/Theme.swift` 里——所有颜色、字号、间距都写在代码里，不从系统默认值猜：

| 项 | 值 |
|---|---|
| 背景 / 卡片 | `#F1F1F6` / `#FFFFFF` |
| 主色 / 高亮底 | `#0079FF` / `#E9F1FF` |
| 主文字 / 次要 / 三级 | `#1B1B1D` / `#8A8A8E` / `#A7A7AE` |
| 大标题 / 登录标题 / 卡片标题 | 32 bold / 28 bold / 15 semibold |
| 正文 / 次要 / 徽标 / Tab | 14 / 13·12 / 11 / 10 |
| 卡片 | 左右 16、宽 361、圆角 20 |
| 列表行 / 卡内行 | 69.6 / 53.9·47.5·46 |
| 悬浮 Tab Bar | 369×60 胶囊，选中药丸 85.4×53.3 |
| 开关 | 50.4×30.7，滑块 26.3 |

设计稿的字号整体比 iOS 标准小一档（约为 0.89 倍），系统 Toggle 的尺寸也对不上，所以开关是自绘的，没有直接用 `Toggle`。

`docs/ui/index.html` 是同一套坐标的 HTML 版预览，改设计时先在那边调数值、再同步到 SwiftUI。



```bash
cd ios/SignKit
swift test
```

重点覆盖：

- **DER 编码**：整数补零、OID 编码、`SET OF` 必须排序
- **CodeDirectory**：头部 88 字节布局、页哈希、特殊槽倒序填充
- **Mach-O 注入**：用合成的最小 arm64 二进制验证注入后可重新解析、`__LINKEDIT` 覆盖到文件末尾、去签名后可重复签名
- **CMS**：生成后用 `openssl cms -verify` 实际校验；篡改内容后必须校验失败
- **描述文件**：通配符匹配、设备白名单、过期判断

CMS 那组测试是判断签名能不能被系统接受的最可靠手段——比肉眼检查 ASN.1 结构靠谱得多。

## 许可与责任

只用于签你自己拥有或已获授权的应用。分发破解版 App 属于侵犯著作权；用他人证书签名属于违规。工具本身不提供证书，也不联网，所有责任在使用者。
