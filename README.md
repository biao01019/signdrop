# iOS 自签名工具

装进 iPhone 里用的原生 App（不是网页工具）。7 个页面按设计稿 1:1 复刻，
签名在设备本地完成，不联网、不上传 IPA。

## 想让它出现在你手机桌面上？

**已经编好了，直接下：**

```
https://github.com/biao01019/signdrop/releases/download/latest/SignKit-unsigned.ipa
```

这是**未签名**的包，还要用你自己的 Apple ID 签一次才能装进 iPhone。

iOS 的 App 必须由 macOS 上的 Xcode 编译一次，Windows 上做不了——这是苹果的工具链限制。
这里的做法是让 GitHub 的 macOS 机器替我们编（`.github/workflows/ios-build.yml`），
你只负责最后一步签名安装。

完整步骤（Windows 上的 Sideloadly 操作、7 天续签、免费账号的限制）在
**[docs/install-ios.md](docs/install-ios.md)**，大约 15 分钟。

```
下载 IPA → Sideloadly 填入 Apple ID → 装好 → 信任开发者描述文件
```

装进去之后，签名、改 Bundle ID、续签全部在手机上完成，不用再碰电脑。

---

## 项目结构

| | [`ios/`](ios/) · 手机端 App | [`app/`](app/) · 电脑端工具 |
|---|---|---|
| 运行在哪 | iPhone 里的原生 App | 电脑上的本地网页服务 |
| 适合 | 想脱离电脑、随时随地签名 | 首次配对、批量处理、调试 |
| 签名在哪算 | 设备本地（Swift 实现） | 电脑本地（调用 zsign） |
| 状态 | **主推**，见 [ios/README.md](ios/README.md) | 可用，保留作为桌面端助手 |

界面预览：`docs/ui/index.html`（7 屏 1:1 复刻，和 SwiftUI 用同一套坐标）。

以下内容是电脑端工具的说明。

---

用**你自己的 Apple ID**给 IPA 签名并安装到自己的设备上。没有云服务、没有别人的证书、
没有签名名额买卖——证书和私钥始终在你本机。

```
选凭证 → 选 IPA → 签名 → 装到手机
```

---

## 它解决什么问题

App Store 下架的应用、自己改过图标/名字的包、内测版本、想装第二个副本（应用分身），
这些都没法走 App Store。iOS 的规矩是：**没有苹果签名的包不能运行**。

所以只能用一个开发者证书重新签一遍。手动做这件事很痛苦——要改 Bundle ID、清理旧签名、
处理嵌套扩展、算好描述文件里的设备列表、用 zsign 打包。这个工具把这一串自动化了。

---

## 两种凭证来源

| | 手动证书模式（推荐） | Apple ID 一键模式（实验性） |
|---|---|---|
| 凭证怎么来 | 你在 developer.apple.com 建证书和描述文件，导出两个文件 | 工具代替你登录、注册设备、申请证书 |
| 稳定性 | 高，不受苹果接口变动影响 | 低，使用的是未公开接口，苹果随时会改 |
| 需要什么 | p12 文件 + mobileprovision 文件 | Apple ID + 密码 + 两步验证 |
| 建议 | 日常都用这个 | 想省事、且能接受随时失效时再用 |

**先用手动证书模式**。它一样是你自己的账号，但踩不到任何灰区，也不会因为苹果某天
调整接口就整个不能用。

---

## 快速开始

### 1. 装依赖

```bash
pip install -r requirements.txt
```

Windows 上还需要一个签名引擎 zsign：

1. 去 https://github.com/zhlynn/zsign/releases 下载 Windows 版
2. 解压出 `zsign.exe`，放到项目的 `tools/` 目录

### 2. 准备两个文件

**证书（.p12）**
1. 打开 https://developer.apple.com/account/resources/certificates
2. 点 `+`，选 *Apple Development*，跟着向导生成 CSR 并上传
3. 下载 `.cer`，双击导入钥匙串/证书管理器
4. 找到这张证书 → 右键导出 → 格式选 `.p12` → 设一个密码
   - Windows：`certmgr.msc` → 个人 → 证书 → 右键导出
   - macOS：钥匙串访问 → 我的证书 → 右键导出

**描述文件（.mobileprovision）**
1. 先在 *Devices* 里加上你的设备 UDID（工具里能直接读到）
2. 去 *Profiles* → `+` → *iOS App Development*
3. 选证书、选设备、填 App ID（不确定就用通配 `*`）
4. 下载 `.mobileprovision`

### 3. 启动

```bash
python run.py
```

浏览器会自动打开 `http://127.0.0.1:8722`，按界面上的 1→2→3→4 走就行。

---

## 用之前该知道的三件事

**1. 免费账号只能装 3 个 App，7 天过期**

用普通 Apple ID（不付费）在 Xcode 里签，限制是同时最多 3 个 App、证书 7 天失效。
付费的 Apple Developer Program（688 元/年）把这个限制放宽到 1 年、App 数量不限。
工具会在到期前显示剩余天数，但**续签这一步必须重跑一遍签名**，iOS 不会自动续。

**2. 一台设备一年只能注册 100 次**

这是账号级配额，所有 App 共用。所以别拿它给不认识的设备签名，额度用完了
要等第二年 1 月 1 日重置（或者换账号）。

**3. 装完要在手机上点"信任"**

设置 → 通用 → VPN 与设备管理 → 找到你的开发者证书 → 信任。
iOS 17 以上还要开：设置 → 隐私与安全性 → 开发者模式。

---

## 功能

- 换 Bundle ID 装第二个副本（应用分身），显示名可改
- 自动清理 `_CodeSignature` / `CodeResources` / `SC_Info`，避免新旧签名打架
- 嵌套扩展（`.appex`、Watch App）的 Bundle ID 自动跟着换前缀
- 可选移除扩展与小组件——免费账号最容易在这里签名失败
- 描述文件校验：过期、Bundle ID 不匹配都会在签之前拦下来并说明原因
- 签名/安装走后台任务，界面有进度
- USB 直连安装（需 `pymobiledevice3`），失败时把苹果的错误码翻译成人话

---

## 项目结构

```
app/
  main.py         HTTP 接口（只监听 127.0.0.1）
  pipeline.py     签名流水线：校验 → 改写 → 签名 → 记录
  ipa.py          IPA 改写（Bundle ID、清旧签名、注入描述文件）
  credentials.py  凭证导入与校验
  certs.py        密钥/CSR/p12 生成，描述文件解析
  zsign.py        zsign 封装
  device.py       USB 设备枚举与安装
  srp.py          SRP-6a（苹果登录的密码学核心）
  anisette.py     设备指纹服务客户端
  auth.py         Apple ID 登录（实验性）
  portal.py       开发者后台接口（实验性）
  store.py        SQLite 持久层
  vault.py        本地密钥箱（加密存密码）
web/index.html    单页界面，无构建步骤
tests/            25 项测试
```

## 测试

```bash
python -m unittest discover -s tests -v
```

其中 SRP 部分用 RFC 5054 官方测试向量校验——包括 `premaster secret` 的逐字节比对，
不是"自己跟自己一致"那种假测试。IPA 改写和签名流水线用合成包做端到端验证。

---

## 已知边界

- **Apple ID 一键模式尚未在真实账号上验证**。`app/auth.py` 的接口形态来自社区逆向，
  参数细节可能需要按实际抓包校准。跑不通就用手动证书模式，功能完全一样。
- **不做 7 天自动续签**。那需要在 iOS 端跑一个 WireGuard 环回网关（SideStore 的做法），
  是另一个量级的工程。目前是到期前提醒你重签。
- **不做 OTA 分发**。`itms-services` 需要公网 HTTPS 域名，一旦对外就是个"应用分发平台"，
  合规风险完全不同。本工具只走 USB 本地安装。
- 签名引擎依赖 zsign，本仓库不包含它的二进制。

## 合规

- 只签你自己拥有或已获授权的 IPA。给破解版签名属于侵犯著作权。
- 不要用这个工具对外提供"代签名"服务：批量卖签名名额违反 Apple 开发者协议，
  账号会被封，已签的包会一起失效。
- 证书私钥和密码只存在本机 `data/` 目录，密码用 `data/secret.key` 加密。
  这个目录别提交到 git，也别共享。
