"""Apple ID 登录（实验性）。

⚠️ 重要说明
    这一段走的是苹果未公开的私有接口（GrandSlam + idmsa），参数是社区逆向出来的。
    苹果随时可能改动，改动后这里就会失效，需要按新的抓包结果调整 _ENDPOINTS
    和各步骤的请求体。所以：

      - 默认流程不依赖它（用「手动证书模式」，见 credentials.py）
      - 打开它之前，请先确认你接受"可能随时失效"这个前提
      - 出问题时的参考实现：AltStore/AltSign(Swift)、SideStore、Provision

密码学部分是可靠的：SRP 已通过 RFC 5054 官方向量验证（tests/test_srp.py），
密码明文不落盘、不出网。
"""

from __future__ import annotations

import base64
import hashlib
import time
from dataclasses import asdict, dataclass, field

from .anisette import AnisetteClient
from .net import HttpSession
from .srp import SRPClient

GSA = "https://gsa.apple.com"
IDMSA = "https://idmsa.apple.com/appleauth"

_ENDPOINTS = {
    "bootstrap": f"{GSA}/gm/bootstrap/init",
    "signin_init": f"{IDMSA}/auth/signin/init",
    "signin_complete": f"{IDMSA}/auth/signin/complete",
    "verify_code": f"{IDMSA}/auth/verify/trusteddevice/securitycode",
    "trust": f"{IDMSA}/auth/2sv/trust",
    "app_token": f"{GSA}/gm/apptokens",
}

# 网页端 iCloud/开发者后台使用的固定 widget key（社区通用值）
_WIDGET_KEY = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
_OAUTH_CLIENT = "com.apple.gs.appleid.auth"


class AuthError(RuntimeError):
    pass


@dataclass
class AuthState:
    apple_id: str = ""
    display_name: str = ""
    adsid: str = ""
    session_id: str = ""
    scnt: str = ""
    token: str = ""
    team_id: str = ""
    stage: str = "idle"  # idle | password | two_factor | authenticated
    last_error: str = ""
    anisette_headers: dict[str, str] = field(default_factory=dict)

    def public(self) -> dict:
        data = asdict(self)
        data.pop("anisette_headers", None)
        data.pop("token", None)  # 令牌不出后端
        return data


def _b64decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.b64decode(value + padding)


class AppleIDAuth:
    """Apple ID 登录状态机。一次登录需要三步：账号 → 密码 → 验证码（如果需要）。"""

    def __init__(self, anisette: AnisetteClient, timeout: float = 30.0) -> None:
        self.anisette = anisette
        self.state = AuthState()
        self._srp: SRPClient | None = None
        self._c_value: str = ""
        self._http = HttpSession(timeout=timeout)

    # -- 内部 ---------------------------------------------------------------
    def _base_headers(self) -> dict[str, str]:
        headers = dict(self.state.anisette_headers)
        headers.setdefault("Accept", "application/json")
        headers.setdefault("X-Requested-With", "XMLHttpRequest")
        headers.setdefault("X-Apple-Widget-Key", _WIDGET_KEY)
        if self.state.session_id:
            headers["X-Apple-ID-Session-Id"] = self.state.session_id
        if self.state.scnt:
            headers["scnt"] = self.state.scnt
        return headers

    def _absorb_session_headers(self, response) -> None:
        for key in ("x-apple-id-session-id", "x-apple-id-session-id".upper()):
            if response.header(key):
                self.state.session_id = response.header(key)
        if response.header("scnt"):
            self.state.scnt = response.header("scnt")

    # -- 第一步：账号 ---------------------------------------------------------
    def start(self, apple_id: str) -> AuthState:
        self.state = AuthState(apple_id=apple_id, stage="password")
        self.state.anisette_headers = self.anisette.headers()

        # bootstrap 用来把设备指纹绑定到这次会话，拿不到也不致命
        response = self._http.request(
            "POST",
            _ENDPOINTS["bootstrap"],
            json_body={"clientInfo": {"bootstrap": True, "cfu": True, "cfu2": True}},
            headers=self._base_headers(),
        )
        self._absorb_session_headers(response)
        return self.state

    # -- 第二步：密码 ---------------------------------------------------------
    def submit_password(self, password: str) -> AuthState:
        if self.state.stage == "idle":
            raise AuthError("请先提交 Apple ID")

        response = self._http.request(
            "POST",
            _ENDPOINTS["signin_init"],
            json_body={
                "a": self._srp_public(password),
                "accountName": self.state.apple_id,
                "protocols": ["s2k", "s2k_fo"],
            },
            headers=self._base_headers(),
        )
        self._absorb_session_headers(response)

        if response.status != 200:
            raise AuthError(self._describe_failure(response, "密码预交换失败"))

        payload = response.json()
        protocol = payload.get("protocol", "s2k")
        salt = _b64decode(payload["salt"])
        b_pub = _b64decode(payload["b"])
        self._c_value = payload.get("c", "")

        assert self._srp is not None
        self._srp.set_server_values(salt, b_pub)

        complete = self._http.request(
            "POST",
            _ENDPOINTS["signin_complete"] + "?isRememberMeEnabled=true",
            json_body={
                "accountName": self.state.apple_id,
                "c": self._c_value,
                "m1": self._srp.proof_b64(),
                "m2": base64.b64encode(self._srp.expected_server_proof()).decode(),
                "rememberMe": True,
            },
            headers=self._base_headers(),
        )
        self._absorb_session_headers(complete)

        if complete.status == 200:
            self.state.stage = "authenticated"
            self._read_identity(complete.json())
            return self.state

        if complete.status in (409, 403):
            body = complete.json()
            auth_type = (body.get("authType") or "").lower()
            if auth_type in ("hsa2", "hsa", "sa", "trusteddevice"):
                self.state.stage = "two_factor"
                return self.state
            raise AuthError(f"登录需要额外验证（{auth_type or complete.status}），当前版本还不支持")

        raise AuthError(self._describe_failure(complete, "密码校验失败"))

    def _srp_public(self, password: str) -> str:
        """Apple 的 s2k_fo 协议会先对密码做一次 SHA-256 再进 SRP。

        如果苹果回退到只认 s2k（原始口令），登录会返回 401，届时把这里的
        预处理去掉即可——这两种协议的分支点只在这一处。
        """
        candidate = hashlib.sha256(password.encode()).hexdigest()
        self._srp = SRPClient(self.state.apple_id, candidate)
        return self._srp.public_a_b64()

    # -- 第三步：验证码 -------------------------------------------------------
    def submit_code(self, code: str) -> AuthState:
        if self.state.stage != "two_factor":
            raise AuthError("当前不在等待验证码的阶段")

        response = self._http.request(
            "POST",
            _ENDPOINTS["verify_code"],
            json_body={"securityCode": {"code": code}},
            headers=self._base_headers(),
        )
        self._absorb_session_headers(response)
        if response.status not in (200, 204):
            raise AuthError(self._describe_failure(response, "验证码校验失败"))

        trust = self._http.request("GET", _ENDPOINTS["trust"], headers=self._base_headers())
        self._absorb_session_headers(trust)
        if trust.status not in (200, 204):
            raise AuthError(self._describe_failure(trust, "建立信任会话失败"))

        self.state.stage = "authenticated"
        self._read_identity(trust.json())
        return self.state

    # -- 第四步：换开发者令牌 --------------------------------------------------
    def fetch_token(self) -> str:
        """换取访问开发者后台的令牌。

        这是整条链上最脆弱的一步：需要把 SRP 协商出的密钥、会话 cookie 和
        apptoken 的校验和拼在一起。如果这里报错，说明苹果改了参数，
        请对照 AltSign 的 `fetchAnisetteData` / `AppleAPI.fetchToken` 校准。
        """
        if self.state.stage != "authenticated":
            raise AuthError("账号尚未完成登录，无法获取令牌")

        response = self._http.request(
            "POST",
            _ENDPOINTS["app_token"],
            json_body={
                "app": [_OAUTH_CLIENT],
                "c": self._c_value,
                "checksum": base64.b64encode(
                    hashlib.sha256(self._c_value.encode()).digest()
                ).decode(),
                "key": base64.b64encode(self._srp.session_key).decode() if self._srp else "",
                "gp": base64.b64encode(b"0" * 32).decode(),
            },
            headers=self._base_headers(),
        )
        payload = response.json()
        if response.status != 200:
            raise AuthError(
                self._describe_failure(response, "获取开发者令牌失败")
                + "\n（这一步依赖苹果私有参数，若持续失败请改用手动证书模式）"
            )
        token = (payload.get("tokens") or {}).get(_OAUTH_CLIENT, {}).get("token", "")
        if not token:
            raise AuthError("苹果未返回开发者令牌，响应结构可能已变更")
        self.state.token = token
        return token

    # -- 辅助 ---------------------------------------------------------------
    def _read_identity(self, payload: dict) -> None:
        self.state.adsid = payload.get("adsid", "") or payload.get("dsid", "")
        name = payload.get("displayName") or payload.get("accountName") or ""
        self.state.display_name = name

    def _describe_failure(self, response, prefix: str) -> str:
        body = response.json()
        detail = (
            body.get("serviceErrors")
            or body.get("errorMessage")
            or body.get("message")
            or response.text[:300]
        )
        if response.status == 401:
            return f"{prefix}：账号或密码不正确。（{detail}）"
        if response.status == 403:
            return f"{prefix}：账号被限制，可能需要先在浏览器登录一次解锁。（{detail}）"
        if response.status == 429:
            return f"{prefix}：请求过于频繁，苹果限流了，等几分钟再试。（{detail}）"
        return f"{prefix}：HTTP {response.status} — {detail}"


class DemoAuth:
    """演示模式用的假登录，只为了让界面和流水线跑通，不会连苹果任何接口。"""

    def __init__(self) -> None:
        self.state = AuthState(apple_id="demo@example.com", display_name="演示账号", stage="authenticated")

    def start(self, apple_id: str) -> AuthState:
        self.state.apple_id = apple_id or "demo@example.com"
        self.state.stage = "password"
        return self.state

    def submit_password(self, password: str) -> AuthState:
        time.sleep(0.3)
        self.state.stage = "authenticated"
        self.state.token = "demo-token"
        self.state.adsid = "0000000000"
        return self.state

    def submit_code(self, code: str) -> AuthState:
        self.state.stage = "authenticated"
        return self.state

    def fetch_token(self) -> str:
        return "demo-token"
