"""Anisette 客户端：向 anisette 服务索取苹果设备指纹头。

苹果的认证接口要求请求头里带一组 X-Apple-I-MD* 设备标识，这些值由苹果设备上
的 AOSKit 生成，普通 PC 算不出来，所以需要 anisette 服务代算。

协议很简单：POST 一个 JSON，返回一组头。
自行部署可参考 https://github.com/Dadoum/anisette-v3-server（Docker 一条命令）。
公共实例不稳定且会把你的请求和他人混在一起，正式使用请自建。
"""

from __future__ import annotations

import datetime as dt
import json
import urllib.error
import urllib.request

DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)


class AnisetteError(RuntimeError):
    pass


def _local_timezone_name() -> str:
    tz = dt.datetime.now().astimezone().tzinfo
    return getattr(tz, "key", None) or "Asia/Shanghai"


def _client_time() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class AnisetteClient:
    def __init__(
        self,
        base_url: str,
        user_agent: str = DEFAULT_USER_AGENT,
        timeout: float = 20.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.user_agent = user_agent
        self.timeout = timeout

    def headers(self, provisioning_path: str = "") -> dict[str, str]:
        """取一组可直接用于苹果接口的请求头。"""
        payload = json.dumps(
            {"provisioning_path": provisioning_path, "user_agent": self.user_agent}
        ).encode()
        request = urllib.request.Request(
            self.base_url + "/",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "User-Agent": self.user_agent,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.URLError as exc:
            raise AnisetteError(
                f"连不上 anisette 服务（{self.base_url}）：{exc.reason}。\n"
                "解决方式二选一：\n"
                "  1) 自建：docker run -d -p 6969:6969 dadoum/anisette-v3-server，"
                "然后把设置里的地址改成 http://127.0.0.1:6969\n"
                "  2) 换一个公共实例地址"
            ) from exc

        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise AnisetteError(
                f"anisette 服务返回了非 JSON 内容，可能地址填错了：{raw[:200]!r}"
            ) from exc

        if "error" in data:
            raise AnisetteError(f"anisette 服务报错：{data['error']}")

        # 兼容两种返回结构：直接给头，或包在 result 里
        if "result" in data and isinstance(data["result"], dict):
            data = data["result"]

        headers = {k: str(v) for k, v in data.items() if k.startswith("X-Apple-")}
        if "X-Apple-I-MD" not in headers:
            raise AnisetteError(
                "anisette 服务未返回 X-Apple-I-MD，服务可能版本过旧或已失效"
            )

        headers.setdefault("X-Apple-I-Client-Time", _client_time())
        headers.setdefault("X-Apple-I-TimeZone", _local_timezone_name())
        headers.setdefault("X-Apple-Locale", "zh_CN")
        headers.setdefault("X-Apple-I-SRL-NO", "0")
        headers["User-Agent"] = self.user_agent
        return headers
