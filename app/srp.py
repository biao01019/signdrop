"""SRP-6a 客户端实现，用于苹果账号登录（GrandSlam / idmsa）。

为什么需要它：Apple ID 登录不走明文密码，而是 SRP-6a 握手。密码只在本机
参与计算，网络上传输的是 A、M1 这类零知识证明，即使被截获也无法反推出密码。
这也是本工具"不保存明文密码"的前提。

参数组：RFC 5054 的 2048-bit 群（Apple 使用的就是这一组），g = 2。
哈希：Apple 用 SHA-256；单元测试用 SHA-1 + 1024-bit 群对照 RFC 官方向量，
因为 RFC 只给出了 1024 位群的完整测试数据。

测试锚点（tests/test_srp.py）：
  - 2048-bit N 的 bit_length 必须为 2048
  - 1024-bit 群可用 RFC 附录 B 的 a/b/s 复现出 A、B 与 premaster secret
  - 客户端与服务端双方能协商出相同的 M1 / M2
"""

from __future__ import annotations

import base64
import hashlib
import secrets
from dataclasses import dataclass
from typing import Callable

ShaFactory = Callable[[], "hashlib._Hash"]


@dataclass(frozen=True)
class Group:
    n_hex: str
    g: int = 2

    @property
    def n(self) -> int:
        return int(self.n_hex, 16)

    @property
    def size(self) -> int:
        """N 的字节长度，用于 PAD()。"""
        return (self.n.bit_length() + 7) // 8


# RFC 5054 Appendix A, 2048-bit group —— Apple 生产环境使用这一组
GROUP_2048 = Group(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050"
    "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50"
    "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B"
    "855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773"
    "BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F8774"
    "8544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE"
    "6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB"
    "694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
)

# RFC 5054 Appendix A, 1024-bit group —— 仅用于跑官方测试向量
GROUP_1024 = Group(
    "EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576"
    "D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD1"
    "5DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC"
    "68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3"
)

N = GROUP_2048.n
g = GROUP_2048.g


class SRPError(RuntimeError):
    pass


def _h(sha: ShaFactory, *parts: bytes) -> bytes:
    digest = sha()
    for part in parts:
        digest.update(part)
    return digest.digest()


def _int(data: bytes) -> int:
    return int.from_bytes(data, "big")


class SRPClient:
    """客户端一侧的 SRP-6a 状态机。

    用法::

        c = SRPClient("user@example.com", "password")
        a_pub = c.public_a()            # 第一步交给服务器
        c.set_server_values(salt, b_pub)  # 服务器回 salt / B
        m1 = c.proof()                  # 第二步交给服务器验证
        c.verify_server_proof(m2)       # 验证服务器确实知道校验子
        api_key = c.session_key
    """

    def __init__(
        self,
        username: str,
        password: str,
        sha: ShaFactory = hashlib.sha256,
        group: Group = GROUP_2048,
        private_a: int | None = None,
    ) -> None:
        self.username = username
        self.password = password
        self._sha = sha
        self._group = group
        self._size = group.size
        # 1024-bit 随机私钥；测试时可注入以复现 RFC 向量
        self._a = private_a if private_a is not None else secrets.randbits(1024)
        self._a_pub = pow(group.g, self._a, group.n)
        self._salt: bytes | None = None
        self._b_pub: int | None = None
        self._k_bytes: bytes | None = None
        self._premaster: int | None = None
        self._m1: bytes | None = None
        self._m2: bytes | None = None

    # -- 工具 --------------------------------------------------------------
    def _pad(self, value: int) -> bytes:
        return value.to_bytes(self._size, "big")

    # -- 阶段一：把 A 交给服务器 -------------------------------------------
    def public_a(self) -> bytes:
        return self._pad(self._a_pub)

    def public_a_b64(self) -> str:
        return base64.b64encode(self.public_a()).decode()

    # -- 阶段二：拿到 salt / B 后计算证明 ---------------------------------
    def set_server_values(self, salt: bytes, b_pub: bytes | int) -> None:
        n, gg = self._group.n, self._group.g
        self._salt = salt
        self._b_pub = _int(b_pub) if isinstance(b_pub, bytes) else b_pub

        if self._b_pub % n == 0:
            raise SRPError("服务器下发的 B 非法（B mod N == 0）")

        k = _int(_h(self._sha, self._pad(n), self._pad(gg)))  # k = H(N | PAD(g))
        u = _int(_h(self._sha, self._pad(self._a_pub), self._pad(self._b_pub)))
        if u == 0:
            raise SRPError("服务器下发的 u 为 0，握手不可信")

        x = _int(
            _h(
                self._sha,
                salt,
                _h(
                    self._sha,
                    self.username.lower().encode(),
                    b":",
                    self.password.encode(),
                ),
            )
        )

        base = (self._b_pub - k * pow(gg, x, n)) % n
        s = pow(base, self._a + u * x, n)
        self._premaster = s
        self._k_bytes = _h(self._sha, self._pad(s))

        xor_h = bytes(
            a ^ b
            for a, b in zip(_h(self._sha, self._pad(n)), _h(self._sha, self._pad(gg)))
        )
        self._m1 = _h(
            self._sha,
            xor_h,
            _h(self._sha, self.username.lower().encode()),
            salt,
            self._pad(self._a_pub),
            self._pad(self._b_pub),
            self._k_bytes,
        )
        self._m2 = _h(self._sha, self._pad(self._a_pub), self._m1, self._k_bytes)

    def proof(self) -> bytes:
        if self._m1 is None:
            raise SRPError("尚未收到服务器的 salt / B")
        return self._m1

    def proof_b64(self) -> str:
        return base64.b64encode(self.proof()).decode()

    def expected_server_proof(self) -> bytes:
        if self._m2 is None:
            raise SRPError("尚未收到服务器的 salt / B")
        return self._m2

    def verify_server_proof(self, m2: bytes) -> None:
        if self._m2 is None:
            raise SRPError("尚未收到服务器的 salt / B")
        if not secrets.compare_digest(m2, self._m2):
            raise SRPError("服务器返回的 M2 校验失败，可能存在中间人")

    @property
    def session_key(self) -> bytes:
        """H(S)，Apple 会把它当作后续请求的会话密钥。"""
        if self._k_bytes is None:
            raise SRPError("会话密钥尚未生成")
        return self._k_bytes

    @property
    def premaster(self) -> bytes:
        """S，仅用于对照测试向量。"""
        if self._premaster is None:
            raise SRPError("尚未协商出共享密钥")
        return self._pad(self._premaster)


class SRPServer:
    """极简服务端实现，只为验证两端能协商出同样的密钥与证明。"""

    def __init__(
        self,
        username: str,
        password: str,
        salt: bytes,
        sha: ShaFactory = hashlib.sha256,
        group: Group = GROUP_2048,
        private_b: int | None = None,
    ) -> None:
        self.username = username
        self.password = password
        self.salt = salt
        self._sha = sha
        self._group = group
        self._size = group.size
        self._b = private_b if private_b is not None else secrets.randbits(512)
        v = pow(
            group.g,
            _int(
                _h(
                    sha,
                    salt,
                    _h(sha, username.lower().encode(), b":", password.encode()),
                )
            ),
            group.n,
        )
        self._v = v
        k = _int(_h(sha, self._pad(group.n), self._pad(group.g)))
        self.public_b = (k * v + pow(group.g, self._b, group.n)) % group.n

    def _pad(self, value: int) -> bytes:
        return value.to_bytes(self._size, "big")

    def verify(self, a_pub: bytes, m1: bytes) -> tuple[bool, bytes, bytes]:
        """返回 (是否通过, M2, session_key)。"""
        n = self._group.n
        a = _int(a_pub)
        if a % n == 0:
            return False, b"", b""
        k = _int(_h(self._sha, self._pad(n), self._pad(self._group.g)))
        u = _int(_h(self._sha, self._pad(a), self._pad(self.public_b)))
        s = pow((a * pow(self._v, u, n)) % n, self._b, n)
        key = _h(self._sha, self._pad(s))
        xor_h = bytes(
            x ^ y
            for x, y in zip(
                _h(self._sha, self._pad(n)), _h(self._sha, self._pad(self._group.g))
            )
        )
        expected = _h(
            self._sha,
            xor_h,
            _h(self._sha, self.username.lower().encode()),
            self.salt,
            self._pad(a),
            self._pad(self.public_b),
            key,
        )
        m2 = _h(self._sha, self._pad(a), expected, key)
        return secrets.compare_digest(expected, m1), m2, key
