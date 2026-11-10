"""SRP 实现的正确性验证。

用 RFC 5054 Appendix B 的官方测试向量校验密码学核心。RFC 只给 1024-bit 群的
完整数据，所以测试在 1024 位上跑，生产用 2048 位——两者的算法完全一致，只有
模数长度不同。这也是为什么 SRPClient 允许注入 group 和 private_a。
"""

from __future__ import annotations

import hashlib
import unittest

from app.srp import GROUP_1024, GROUP_2048, SRPClient, SRPServer, SRPError

# RFC 5054 Appendix B (1024-bit group, SHA-1)
RFC_A = "60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393"
RFC_B = "E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20"
RFC_SALT = "BEB25379D1A8581EB5A727673A2441EE"
RFC_APUB = (
    "61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E890"
    "3211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E"
    "42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261"
    "EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B"
)
RFC_BPUB = (
    "BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964"
    "DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610"
    "D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A"
    "00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58"
)
RFC_PREMASTER = (
    "B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E3"
    "59B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C"
    "00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB3394"
    "3CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A"
)


class TestGroupConstants(unittest.TestCase):
    def test_2048_group_is_2048_bits(self):
        self.assertEqual(GROUP_2048.n.bit_length(), 2048)
        self.assertEqual(GROUP_2048.size, 256)

    def test_1024_group_is_1024_bits(self):
        self.assertEqual(GROUP_1024.n.bit_length(), 1024)
        self.assertEqual(GROUP_1024.size, 128)

    def test_multiplier_k_2048(self):
        """k = H(N | PAD(g))。Apple 用 2048 群 + SHA-256，此值作回归锚点防止改坏常量。"""
        digest = hashlib.sha1()
        digest.update(GROUP_2048.n.to_bytes(256, "big"))
        digest.update((2).to_bytes(256, "big"))
        self.assertEqual(digest.hexdigest().upper(), "A56303F32C60E599E82C396F0D57F1B344A7313C")


class TestRFC5054Vector(unittest.TestCase):
    def test_public_a_matches_rfc(self):
        client = SRPClient(
            "alice",
            "password123",
            sha=hashlib.sha1,
            group=GROUP_1024,
            private_a=int(RFC_A, 16),
        )
        self.assertEqual(client.public_a().hex().upper(), RFC_APUB)

    def test_server_public_b_matches_rfc(self):
        server = SRPServer(
            "alice",
            "password123",
            bytes.fromhex(RFC_SALT),
            sha=hashlib.sha1,
            group=GROUP_1024,
            private_b=int(RFC_B, 16),
        )
        self.assertEqual(f"{server.public_b:0256X}", RFC_BPUB)

    def test_premaster_secret_matches_rfc(self):
        """这条最关键：S 一致说明 k、x、u、模幂全部算对了。"""
        client = SRPClient(
            "alice",
            "password123",
            sha=hashlib.sha1,
            group=GROUP_1024,
            private_a=int(RFC_A, 16),
        )
        client.set_server_values(bytes.fromhex(RFC_SALT), bytes.fromhex(RFC_BPUB))
        self.assertEqual(client.premaster.hex().upper(), RFC_PREMASTER)


class TestHandshake(unittest.TestCase):
    def test_双方协商出一致的会话密钥(self):
        salt = b"\x01" * 16
        client = SRPClient("User@Example.com", "correct horse")
        server = SRPServer("user@example.com", "correct horse", salt)

        client.set_server_values(salt, server.public_b)
        ok, m2, server_key = server.verify(client.public_a(), client.proof())

        self.assertTrue(ok, "服务端未能验证客户端证明")
        self.assertEqual(server_key, client.session_key)
        client.verify_server_proof(m2)

    def test_错误密码无法通过(self):
        salt = b"\x02" * 16
        server = SRPServer("alice", "right-password", salt)
        client = SRPClient("alice", "wrong-password")
        client.set_server_values(salt, server.public_b)
        ok, _, _ = server.verify(client.public_a(), client.proof())
        self.assertFalse(ok)

    def test_篡改的服务器证明会被拒绝(self):
        salt = b"\x03" * 16
        client = SRPClient("alice", "pw")
        server = SRPServer("alice", "pw", salt)
        client.set_server_values(salt, server.public_b)
        _, m2, _ = server.verify(client.public_a(), client.proof())
        tampered = bytes([m2[0] ^ 0xFF]) + m2[1:]
        with self.assertRaises(SRPError):
            client.verify_server_proof(tampered)

    def test_B为零时拒绝握手(self):
        client = SRPClient("alice", "pw")
        with self.assertRaises(SRPError):
            client.set_server_values(b"\x00" * 16, 0)


if __name__ == "__main__":
    unittest.main()
