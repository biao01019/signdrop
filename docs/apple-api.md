# 苹果接口说明（实验性部分）

这份文档只讲一件事：`app/auth.py` 和 `app/portal.py` 里那套私有接口是怎么组织的、
失效了怎么修。**不追求完整性**，只记录已经编码进项目的假设。

---

## 整体链路

```
anisette 服务 ──► X-Apple-I-MD* 设备指纹头
      │
      ▼
gsa.apple.com/gm/bootstrap/init     建立会话
      │
      ▼
idmsa.apple.com/auth/signin/init    SRP 第一步：交 A，拿 salt / B
      │
      ▼
idmsa.apple.com/auth/signin/complete SRP 第二步：交 M1，拿会话
      │                                （需要 2FA 时返回 409）
      ▼
idmsa.apple.com/auth/verify/...      提交验证码
idmsa.apple.com/auth/2sv/trust       建立信任会话
      │
      ▼
gsa.apple.com/gm/apptokens           换取开发者令牌
      │
      ▼
developerservices2.apple.apple.com/services/QH65B2/...
   ios/listTeams.action
   ios/addDevice.action
   ios/submitDevelopmentCSR.action
   ios/addAppId.action
   ios/downloadTeamProvisioningProfile.action
```

## 三个关键前提

**1. 密码不参与传输**

`signin/init` 之前会对密码做一次 SHA-256 得到 `s2k_fo` 形式的口令，
再丢进 SRP 计算。网络上只有 `A`、`M1`，截获也没法反推。这是协议设计保证的，
不是本项目的实现细节——所以"密码不出网"这句话是可信的。

**2. anisette 头是必需的**

苹果要求请求里带 `X-Apple-I-MD` 这类由设备 AOSKit 生成的值。普通电脑算不出来，
必须由 anisette 服务代算。公共实例共享且不稳定，长期用请自建：

```bash
docker run -d -p 6969:6969 dadoum/anisette-v3-server
```

然后在本工具设置里把地址改成 `http://127.0.0.1:6969`。

**3. 这些地址会变**

苹果调整接口时，通常表现为：返回 HTML 登录页、返回 `resultCode != 0`、
或者干脆 404。修的时候只需要动 `_ENDPOINTS` / `_ACTIONS` 两个字典，
业务代码不用碰——这是当初把它们抽出来的原因。

---

## 如果一键登录失败

先确认是哪一步断的：

| 现象 | 大概率原因 | 怎么办 |
|---|---|---|
| `连不上 anisette 服务` | 地址错或服务挂了 | 自建一个，或换个可用实例 |
| `密码预交换失败` | 苹果改了 signin/init 的字段 | 抓包对照，注意入参名是否变成 `a`/`accountName` |
| `需要额外验证` | 账号被要求设备确认 | 先在浏览器登录一次 iCloud，解锁账号 |
| `验证码校验失败` | 会话头没带全 | 检查 `X-Apple-ID-Session-Id` 与 `scnt` 是否都到位 |
| `获取开发者令牌失败` | apptokens 参数变了 | 这一步最脆，需要校准 `checksum` / `key` / `gp` 的算法 |
| `开发者接口 ... HTTP 302` | 令牌无效，被踢回登录 | 重新登录，确认拿到的 token 属于 `com.apple.gs.appleid.auth` |

参考实现（按可读性排序）：

- **AltSign**（Swift，AltStore 的签名核心）——最贴近本文档的结构
- **SideStore**（Swift）——它的 anisette 与免电脑续签部分是独有的
- **Provision**（Swift，iOS 端应用）

---

## 为什么默认不启用

不是技术洁癖。真实情况是：这条路能跑，但**维护成本高**——苹果每次调接口都要跟。
对手动证书模式来说，这条链路完全是可选的：证书和描述文件在网页上点几下就有，
剩下的自动化工作一样不少。

所以工程的取舍是：把稳定的部分做扎实（签名、改写、校验、安装），
把不稳定的部分做成可关闭的开关。
