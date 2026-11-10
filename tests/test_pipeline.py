"""端到端流水线测试。

不依赖苹果服务器、不依赖真机：本地生成自签证书 + 合成描述文件，
在演示模式下跑通"导入凭证 → 改写 IPA → 出包 → 记录"整条链路。
真实签名那一段由 zsign 负责，它是否可用由运行时探测，这里不测。
"""

from __future__ import annotations

import plistlib
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from app import certs, config, credentials, pipeline
from app.store import Store


def make_p12(path: Path, password: str = "test123") -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "iPhone Developer: Test")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=365))
        .sign(key, hashes.SHA256())
    )
    path.write_bytes(certs.export_p12(key, cert, password))


def make_profile(
    path: Path,
    *,
    app_id: str = "ABCDE12345.*",
    days: int = 300,
    devices: list[str] | None = None,
) -> None:
    plist = plistlib.dumps(
        {
            "Name": "Test Provisioning Profile",
            "UUID": "11111111-2222-3333-4444-555555555555",
            "TeamIdentifier": ["ABCDE12345"],
            # XML 格式要求 naive datetime，工具解析时会补上 UTC
            "ExpirationDate": (
                datetime.now(timezone.utc) + timedelta(days=days)
            ).replace(tzinfo=None),
            "ProvisionedDevices": devices or ["00008030-000000000000000E"],
            "Entitlements": {
                "application-identifier": app_id,
                "get-task-allow": True,
            },
        },
        fmt=plistlib.FMT_XML,
    )
    # 真实描述文件外层是 CMS 容器，这里加个壳让解析路径和线上一致
    path.write_bytes(b"\x30\x82\x10\x00\x06\x09*\x86H\x86\xf7\x0d\x01\x07\x02" + plist)


def make_ipa(path: Path, bundle_id: str = "com.example.demo") -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(
            "Payload/Demo.app/Info.plist",
            plistlib.dumps(
                {
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleName": "Demo",
                    "CFBundleDisplayName": "Demo",
                    "CFBundleExecutable": "Demo",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                },
                fmt=plistlib.FMT_BINARY,
            ),
        )
        zf.writestr("Payload/Demo.app/Demo", b"\xcf\xfa\xed\xfe" + b"\x00" * 32)
        zf.writestr("Payload/Demo.app/_CodeSignature/CodeResources", b"old")


class PipelineTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.cfg = config.Config(data_dir=str(root / "data"), mock_mode=True)
        self.store = Store(self.cfg.db_path)

        self.p12 = root / "dev.p12"
        self.profile = root / "dev.mobileprovision"
        self.ipa = root / "demo.ipa"
        make_p12(self.p12)
        make_profile(self.profile)
        make_ipa(self.ipa)

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def _import(self, **kwargs) -> dict:
        return credentials.import_credential(
            self.cfg,
            self.store,
            p12_source=str(self.p12),
            p12_password=kwargs.get("password", "test123"),
            profile_source=str(self.profile),
            label="测试证书",
        )

    def test_导入凭证并读出有效期(self):
        summary = self._import()
        self.assertEqual(summary["team_id"], "ABCDE12345")
        self.assertEqual(summary["device_count"], 1)
        self.assertGreater(summary["days_left"], 290)
        self.assertEqual(summary["state"], "ok")

    def test_密码错误时给出可操作的提示(self):
        with self.assertRaises(credentials.CredentialError) as ctx:
            self._import(password="wrong")
        self.assertIn("密码", str(ctx.exception))

    def test_签名流水线产出可用包(self):
        credential = self._import()
        result = pipeline.run_sign(
            self.cfg,
            pipeline.SignRequest(ipa_path=str(self.ipa), credential_id=credential["id"]),
            store=self.store,
        )

        self.assertTrue(result["mock"])
        self.assertTrue(Path(result["signed_path"]).is_file())
        self.assertEqual(result["bundle_id"], "com.example.demo")
        self.assertGreater(result["days_left"], 290)

        with zipfile.ZipFile(result["signed_path"]) as zf:
            self.assertFalse(any("_CodeSignature" in n for n in zf.namelist()))
            info = plistlib.loads(zf.read("Payload/Demo.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], "com.example.demo")

        apps = self.store.list_apps()
        self.assertEqual(len(apps), 1)
        self.assertEqual(apps[0]["status"], "patched")

    def test_分身改BundleID(self):
        credential = self._import()
        result = pipeline.run_sign(
            self.cfg,
            pipeline.SignRequest(
                ipa_path=str(self.ipa),
                credential_id=credential["id"],
                bundle_id="com.example.demo.work",
                display_name="Demo 工作号",
            ),
            store=self.store,
        )
        with zipfile.ZipFile(result["signed_path"]) as zf:
            info = plistlib.loads(zf.read("Payload/Demo.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], "com.example.demo.work")
            self.assertEqual(info["CFBundleDisplayName"], "Demo 工作号")

    def test_描述文件不允许的BundleID会被拦下(self):
        make_profile(self.profile, app_id="ABCDE12345.com.allowed.app")
        credential = self._import()
        with self.assertRaises(pipeline.PipelineError) as ctx:
            pipeline.run_sign(
                self.cfg,
                pipeline.SignRequest(
                    ipa_path=str(self.ipa),
                    credential_id=credential["id"],
                    bundle_id="com.example.other",
                ),
                store=self.store,
            )
        self.assertIn("只允许", str(ctx.exception))

    def test_过期描述文件拒绝导入(self):
        make_profile(self.profile, days=-5)
        with self.assertRaises(credentials.CredentialError) as ctx:
            self._import()
        self.assertIn("过期", str(ctx.exception))

    def test_通配BundleID可任意签(self):
        credential = self._import()
        for bundle in ("com.example.demo", "com.another.app", "io.test.x"):
            result = pipeline.run_sign(
                self.cfg,
                pipeline.SignRequest(
                    ipa_path=str(self.ipa),
                    credential_id=credential["id"],
                    bundle_id=bundle,
                ),
                store=self.store,
            )
            self.assertEqual(result["bundle_id"], bundle)


if __name__ == "__main__":
    unittest.main()
