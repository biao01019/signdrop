"""IPA 改写逻辑的测试。用合成 IPA 覆盖真实场景里最容易出错的几种情况。"""

from __future__ import annotations

import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from app import ipa


def _plist(bundle_id: str, name: str = "Demo", executable: str = "Demo") -> bytes:
    return plistlib.dumps(
        {
            "CFBundleIdentifier": bundle_id,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "MinimumOSVersion": "14.0",
        },
        fmt=plistlib.FMT_BINARY,
    )


def build_sample_ipa(path: Path) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Payload/Demo.app/Info.plist", _plist("com.example.demo"))
        zf.writestr("Payload/Demo.app/Demo", b"\xcf\xfa\xed\xfe" + b"\x00" * 64)
        zf.writestr("Payload/Demo.app/_CodeSignature/CodeResources", b"old")
        zf.writestr("Payload/Demo.app/embedded.mobileprovision", b"OLD-PROFILE")
        zf.writestr("Payload/Demo.app/Frameworks/Lib.framework/Info.plist", _plist("com.example.lib", "Lib", "Lib"))
        zf.writestr("Payload/Demo.app/PlugIns/Widget.appex/Info.plist", _plist("com.example.demo.widget", "Widget", "Widget"))
        zf.writestr("Payload/Demo.app/PlugIns/Widget.appex/_CodeSignature/CodeResources", b"old")


class TestInspect(unittest.TestCase):
    def test_读取基本信息(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "demo.ipa"
            build_sample_ipa(src)
            info = ipa.inspect(src)
            self.assertEqual(info.bundle_id, "com.example.demo")
            self.assertEqual(info.app_bundle, "Demo.app")
            self.assertEqual(info.display_name, "Demo")
            self.assertEqual(info.version, "1.2.3")
            self.assertEqual(info.build, "45")
            self.assertTrue(info.has_extensions)
            self.assertEqual(len(info.nested_bundles), 1)

    def test_非IPA文件报明确错误(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.ipa"
            with zipfile.ZipFile(bad, "w") as zf:
                zf.writestr("hello.txt", b"hi")
            with self.assertRaises(ipa.IPAError) as ctx:
                ipa.inspect(bad)
            self.assertIn("Info.plist", str(ctx.exception))


class TestPatch(unittest.TestCase):
    def test_改BundleID并清掉旧签名(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "demo.ipa"
            dst = Path(tmp) / "out.ipa"
            build_sample_ipa(src)

            result = ipa.patch(
                src,
                dst,
                bundle_id="com.user.demo2",
                display_name="Demo2",
                profile=b"NEW-PROFILE",
                strip_extensions=True,
            )

            self.assertEqual(result.bundle_id, "com.user.demo2")
            with zipfile.ZipFile(dst) as zf:
                names = zf.namelist()
                self.assertFalse(any("_CodeSignature" in n for n in names))
                self.assertEqual(
                    zf.read("Payload/Demo.app/embedded.mobileprovision"), b"NEW-PROFILE"
                )
                # 扩展被整块删除
                self.assertFalse(any("PlugIns" in n for n in names))

                main = plistlib.loads(zf.read("Payload/Demo.app/Info.plist"))
                self.assertEqual(main["CFBundleIdentifier"], "com.user.demo2")
                self.assertEqual(main["CFBundleDisplayName"], "Demo2")

                # 框架 ID 必须原样保留，改了会断引用
                framework = plistlib.loads(
                    zf.read("Payload/Demo.app/Frameworks/Lib.framework/Info.plist")
                )
                self.assertEqual(framework["CFBundleIdentifier"], "com.example.lib")

                self.assertEqual(zf.testzip(), None)

    def test_保留扩展时嵌套包ID跟着换前缀(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "demo.ipa"
            dst = Path(tmp) / "out.ipa"
            build_sample_ipa(src)

            ipa.patch(src, dst, bundle_id="com.user.demo2", strip_extensions=False)

            with zipfile.ZipFile(dst) as zf:
                widget = plistlib.loads(
                    zf.read("Payload/Demo.app/PlugIns/Widget.appex/Info.plist")
                )
                self.assertEqual(widget["CFBundleIdentifier"], "com.user.demo2.widget")
                # 扩展自己的旧签名也要清掉
                self.assertFalse(
                    any("PlugIns/Widget.appex/_CodeSignature" in n for n in zf.namelist())
                )

    def test_不传profile时不注入描述文件(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "demo.ipa"
            dst = Path(tmp) / "out.ipa"
            build_sample_ipa(src)
            ipa.patch(src, dst)
            with zipfile.ZipFile(dst) as zf:
                self.assertFalse(
                    any(n.endswith("embedded.mobileprovision") for n in zf.namelist())
                )

    def test_原文件不被修改(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "demo.ipa"
            dst = Path(tmp) / "out.ipa"
            build_sample_ipa(src)
            before = src.read_bytes()
            ipa.patch(src, dst, bundle_id="com.other.app")
            self.assertEqual(src.read_bytes(), before)


class TestBundleIdHelpers(unittest.TestCase):
    def test_分身ID生成(self):
        self.assertEqual(
            ipa.suggest_bundle_id("com.example.demo", "2"), "com.example.demo.2"
        )

    def test_过滤非法字符(self):
        self.assertEqual(
            ipa.suggest_bundle_id("com.example.demo", "工作 副本"),
            "com.example.demo.alt",
        )


if __name__ == "__main__":
    unittest.main()
