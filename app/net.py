"""极简 HTTP 会话封装（标准库实现，不引入 requests）。

苹果的接口需要 cookie 会话 + 自定义头 + 读取错误响应体（409 里带着 2FA 信息），
标准库的 urllib 都能做，只是样板多，这里收一层。
"""

from __future__ import annotations

import gzip
import http.cookiejar
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field


@dataclass
class Response:
    status: int
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes = b""

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self) -> dict:
        try:
            return json.loads(self.body or b"{}")
        except json.JSONDecodeError:
            return {}

    def header(self, name: str) -> str:
        return self.headers.get(name.lower(), "")


class HttpSession:
    def __init__(self, default_headers: dict[str, str] | None = None, timeout: float = 30.0):
        self.timeout = timeout
        self.default_headers = dict(default_headers or {})
        self._jar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._jar)
        )

    def cookies(self) -> dict[str, str]:
        return {cookie.name: cookie.value for cookie in self._jar}

    def request(
        self,
        method: str,
        url: str,
        *,
        json_body: dict | None = None,
        form: dict | None = None,
        headers: dict[str, str] | None = None,
        raw: bytes | None = None,
    ) -> Response:
        merged = {**self.default_headers, **(headers or {})}
        data: bytes | None = raw
        if json_body is not None:
            data = json.dumps(json_body).encode()
            merged.setdefault("Content-Type", "application/json")
        elif form is not None:
            data = urllib.parse.urlencode(form).encode()
            merged.setdefault("Content-Type", "application/x-www-form-urlencoded")

        request = urllib.request.Request(url, data=data, headers=merged, method=method)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                body = response.read()
                if response.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
                return Response(
                    status=response.status,
                    headers={k.lower(): v for k, v in response.headers.items()},
                    body=body,
                )
        except urllib.error.HTTPError as exc:
            body = exc.read() or b""
            if exc.headers and exc.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            return Response(
                status=exc.code,
                headers={k.lower(): v for k, v in (exc.headers or {}).items()},
                body=body,
            )
