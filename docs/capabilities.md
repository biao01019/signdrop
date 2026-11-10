# 现在能做什么，以及为什么有些事做不到

这份文档只写实际状态，不写规划。判断标准很直接：**代码是不是真的连了苹果、真的产出了可用的字节**。

## 已经跑通的

| 能力 | 实现位置 | 验证方式 |
|---|---|---|
| Apple ID 登录 | `SignKit/AppleID/SRP.swift`、`AppleIDAuth.swift` | SRP 有 9 项单元测试（含小群手算、两端协商一致性） |
| 设备指纹（anisette） | `SignKit/AppleID/Anisette.swift` | 需真实网络，未做自动化测试 |
| 证书申请 | `AppleID/AppleCertificate.swift`、`DeveloperPortal.swift` | CSR 用 Security 框架生成，需真机验证 |
| 注册设备 / 创建 App ID / 下载描述文件 | `AppleID/DeveloperPortal.swift` | 需真机验证 |
| 本地重签 IPA | `Signing/Signer.swift`、`MachO.swift`、`CodeDirectory.swift`、`CMS.swift` | 31 项测试；CMS 用 `openssl cms -verify` 交叉验证 |
| 证书导入（p12 + mobileprovision） | `Vault.swift` | 解析走 Security 框架 |
| 导出签名结果 | `Views/AppDetailView.swift` 的分享按钮 | 系统分享面板 |

登录 → 拿证书 → 选 IPA → 重签 → 导出，这条链在代码层面是通的。**没有演示数据，没有定时器模拟进度**：`AppModel` 里不存在 `DemoData`，签不出来就是报错。

## 还差的三块

### 1. 签完自动安装到手机 —— 免费账号做不到

这才是"和牛蛙助手一样"的最后一环。牛蛙和 SideStore 的做法是：内置一个 Network Extension 的假 VPN，在本机模拟 USB 通道（usbmuxd），把 App 自己发起的安装请求伪装成"从数据线来的"。

**Network Extension 需要付费开发者账号的 entitlement**，免费 Apple ID 申请不到。这不是代码问题，是苹果的授权限制。

所以当前版本的闭环是：签完 → 导出 IPA → 交给 Sideloadly / SideStore / 牛蛙助手里已有的通道安装。**比全自动多两步，但功能是完整的**。

### 2. UDID 得手动填

描述文件里必须有这台设备的 UDID，签出来的包才装得上。iOS 的 App 沙盒读不到自己的 UDID，这是从 iOS 7 起就封死的。

现在需要在「证书」页手动填一次（40 位或 24 位十六进制），填完记在本机，以后不用再填。获取方式：数据线连电脑，Finder / iTunes 设备信息里点序列号会切换成 UDID。

想做成自动的，需要描述文件 OTA 分发那套（本地 HTTPS + 受信任证书），复杂度高，排在自动安装之后。

### 3. 7 天续签提醒

免费账号签出来的包 7 天过期。现在会在列表里显示剩余天数，但不会主动推送提醒。`autoRemind` 这个开关目前是界面占位。

做起来不难（本地通知 + 到期前 7 天触发），但续签之后仍然要手动导出安装，所以它的价值取决于第 1 条能不能解决。

## 免费账号的硬限制

这些是苹果的规则，任何工具都绕不过：

- 证书 **7 天**过期，过期后 App 打不开
- 同时最多 **3 个**自签 App
- 每 7 天最多 **10 个** App ID
- 账号下最多 **2 张**开发证书
- 一年最多 **100 台**设备

所以这个 App 默认申请**通配符 App ID**（`TEAMID.*`），一张证书能签任意 Bundle ID，不浪费 App ID 名额。

## 一个必须说清楚的点

anisette 服务会收到本机的设备指纹（一个随机生成的 machine id + 时间）。它**收不到你的 Apple ID 和密码**——账号密码走 SRP，密码只在本机参与运算，网络上传输的是零知识证明。

要彻底不经过第三方，可以自建：

```bash
docker run -d -p 6969:6969 dadoum/anisette-v3-server
```

然后在 `AnisetteClient.defaultBaseURL` 里改成 `http://127.0.0.1:6969`。

## 要做到和牛蛙助手等价，需要你提供什么

牛蛙的 6 项能力里，我们已经有了 3 项（本地重签、Apple ID 登录、证书申请），
第 1 项（首次安装）可以用 Sideloadly 平替。剩下两项——**手机端直接安装**和
**自动续签**——都卡在同一个东西上：Network Extension。

### 关键事实

`com.apple.developer.networking.networkextension`（packet-tunnel-provider）
**不需要向苹果单独申请**，付费团队在 App ID 里自助勾选即可（Apple DTS 工程师
在开发者论坛明确说明：restricted but not managed）。免费个人团队拿不到，
是因为免费描述文件不包含任何 restricted entitlement。

所以门槛只有一条：**$99/年 的 Apple Developer Program**。

### 清单

| 项 | 必要性 | 用途 | 成本 |
|---|---|---|---|
| Apple Developer Program | **必需**（要免电脑安装就必须） | Network Extension entitlement；证书 1 年有效，不用 7 天续签 | $99/年 |
| 设备 UDID | 必需 | 描述文件必须包含本机 UDID | 免费，手动填一次 |
| 2FA 验证码 | 必需（每次登录） | 苹果登录第二步 | 免费 |
| 自建 anisette 服务 | 强烈建议 | 公共实例随时可能挂，挂了就登不上 | 一台能跑 Docker 的机器，或 $5/月 VPS |
| 域名 + HTTPS | 可选 | 只有走 OTA 分发（装到别人手机）才需要；自己用不上 | ~$10/年 |

### 付费账号顺带解决的问题

证书从 **7 天变 1 年**、设备上限 100 台、App ID 不再受每周 10 个限制。
也就是说「7 天续签」这个痛点直接消失——不需要做自动续签，因为不用续签。

### 明确不做的事

- 企业证书（$299，只发给有 D-U-N-S 的公司）：滥用必被吊销，那是"掉签"的根源
- 共享证书池 / 代签服务：等于把别人的账号搭进去
- 把用户 IPA 传到服务器：签名必须全程在本机
