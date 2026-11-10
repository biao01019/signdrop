"""IPA 改写：换 Bundle ID、换显示名、清掉旧签名、注入新描述文件。

这是"给别人的 IPA 重新签名"里最容易翻车的一环。几个必须处理的点：

1. 旧的 _CodeSignature / CodeResources / SC_Info 必须删干净，
   否则新签名和旧签名混在一起，安装时会报 0xE8008015 之类的错。
2. 嵌套包（.appex 扩展、Watch App）的 Bundle ID 必须以主包 ID 为前缀，
   否则描述文件的通配规则匹配不上，签出来的包装上就崩。
3. Frameworks 里的 Info.plist 不能动 —— 框架的 ID 一改就断引用。
4. 删除扩展是必要的兜底：免费的 Apple ID 账号一次只能签 3 个 App，
   带扩展的包往往因为扩展没有对应描述文件而整体签名失败。
"""

from __future__ import annotations

import plistlib
import re
import shutil
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

MAIN_INFO_RE = re.compile(r"^Payload/([^/]+\.app)/Info\.plist$")
# 这些子目录里的 bundle 需要跟着主包一起改 ID
MANAGED_SUBDIRS = ("PlugIns/", "Watch/", "AppClips/", "Extensions/")
# 这些目录整块丢弃
STRIPPABLE_SUBDIRS = ("PlugIns/", "Watch/", "AppClips/", "Extensions/")
DROPPED_NAMES = ("_CodeSignature/", "SC_Info/", "__MACOSX/")
DROPPED_SUFFIXES = ("embedded.mobileprovision", "CodeResources")


class IPAError(RuntimeError):
    pass


@dataclass
class IPAInfo:
    path: Path
    app_bundle: str
    bundle_id: str
    display_name: str
    name: str
    version: str
    build: str
    executable: str
    min_os: str
    size: int
    nested_bundles: list[str] = field(default_factory=list)

    @property
    def has_extensions(self) -> bool:
        return bool(self.nested_bundles)


@dataclass
class PatchResult:
    out_path: Path
    bundle_id: str
    display_name: str
    stripped_bundles: list[str]
    injected_profile: bool


def _find_main_info(zf: zipfile.ZipFile) -> str:
    for name in zf.namelist():
        if MAIN_INFO_RE.match(name):
            return name
    raise IPAError(
        "这个压缩包里找不到 Payload/xxx.app/Info.plist，可能不是合法 IPA。"
        "（注意：越狱用的 .deb 或已加密的 App Store 包不能直接签）"
    )


def _nested_info_entries(names: list[str], app_prefix: str) -> list[str]:
    """找出所有需要跟着改 ID 的嵌套 bundle 的 Info.plist。"""
    result: list[str] = []
    for name in names:
        if not name.endswith("/Info.plist") or name.startswith(app_prefix + "Frameworks/"):
            continue
        relative = name[len(app_prefix):]
        if not any(relative.startswith(sub) for sub in MANAGED_SUBDIRS):
            continue
        if name.endswith(".appex/Info.plist") or ".app/Info.plist" in name:
            result.append(name)
    return result


def inspect(path: str | Path) -> IPAInfo:
    path = Path(path)
    if not path.is_file():
        raise IPAError(f"文件不存在：{path}")
    if path.suffix.lower() != ".ipa":
        raise IPAError("只支持 .ipa 文件")

    with zipfile.ZipFile(path) as zf:
        try:
            bad = zf.testzip()
        except zipfile.BadZipFile as exc:
            raise IPAError("IPA 已损坏，无法作为 zip 打开") from exc
        if bad is not None:
            raise IPAError(f"IPA 内文件校验失败：{bad}")

        main_info = _find_main_info(zf)
        app_bundle = MAIN_INFO_RE.match(main_info).group(1)  # type: ignore[union-attr]
        app_prefix = f"Payload/{app_bundle}/"
        plist = plistlib.loads(zf.read(main_info))
        nested = _nested_info_entries(zf.namelist(), app_prefix)

    bundle_id = plist.get("CFBundleIdentifier", "")
    if not bundle_id:
        raise IPAError("Info.plist 缺少 CFBundleIdentifier")

    return IPAInfo(
        path=path,
        app_bundle=app_bundle,
        bundle_id=bundle_id,
        display_name=plist.get("CFBundleDisplayName") or plist.get("CFBundleName") or app_bundle[:-4],
        name=plist.get("CFBundleName", ""),
        version=plist.get("CFBundleShortVersionString", "0"),
        build=plist.get("CFBundleVersion", "0"),
        executable=plist.get("CFBundleExecutable", ""),
        min_os=plist.get("MinimumOSVersion", ""),
        size=path.stat().st_size,
        nested_bundles=nested,
    )


def _should_drop(name: str, app_prefix: str, strip_extensions: bool) -> bool:
    if any(marker in name for marker in DROPPED_NAMES):
        return True
    if name.endswith(DROPPED_SUFFIXES):
        return True
    if strip_extensions:
        relative = name[len(app_prefix):] if name.startswith(app_prefix) else ""
        if relative and any(relative.startswith(sub) for sub in STRIPPABLE_SUBDIRS):
            return True
    return False


def _rebase_id(old_id: str, old_prefix: str, new_prefix: str) -> str:
    """把 com.foo.bar.widget 变成 com.new.bar2.widget —— 保住后缀，换掉前缀。"""
    if old_id == old_prefix:
        return new_prefix
    if old_id.startswith(old_prefix + "."):
        return new_prefix + old_id[len(old_prefix):]
    return old_id


def patch(
    src: str | Path,
    dst: str | Path,
    *,
    bundle_id: str | None = None,
    display_name: str | None = None,
    profile: bytes | None = None,
    strip_extensions: bool = False,
) -> PatchResult:
    """生成一个改写后的 IPA。不负责签名，签名交给 zsign。"""
    info = inspect(src)
    src = Path(src)
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)

    new_bundle = bundle_id or info.bundle_id
    app_prefix = f"Payload/{info.app_bundle}/"
    main_info = app_prefix + "Info.plist"

    with zipfile.ZipFile(src) as zin:
        managed = set(_nested_info_entries(zin.namelist(), app_prefix))
        # 记录每个嵌套 bundle 的旧 ID，用于生成新 ID
        nested_ids: dict[str, str] = {}
        for entry in managed:
            try:
                nested_ids[entry] = plistlib.loads(zin.read(entry)).get("CFBundleIdentifier", "")
            except Exception:  # noqa: BLE001 - 坏的 Info.plist 保持原样即可
                nested_ids[entry] = ""

        stripped: list[str] = []
        tmp = dst.with_suffix(".tmp")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                name = item.filename
                if _should_drop(name, app_prefix, strip_extensions):
                    if name.startswith(app_prefix) and name != app_prefix:
                        rel = name[len(app_prefix):]
                        if any(rel.startswith(s) for s in STRIPPABLE_SUBDIRS):
                            stripped.append(rel)
                    continue

                if name == main_info:
                    plist = plistlib.loads(zin.read(name))
                    plist["CFBundleIdentifier"] = new_bundle
                    if display_name:
                        plist["CFBundleDisplayName"] = display_name
                        plist["CFBundleName"] = display_name
                    data = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
                elif name in managed:
                    plist = plistlib.loads(zin.read(name))
                    old_nested = nested_ids.get(name, "")
                    if old_nested:
                        plist["CFBundleIdentifier"] = _rebase_id(
                            old_nested, info.bundle_id, new_bundle
                        )
                    data = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
                else:
                    data = zin.read(name)

                zout.writestr(item, data)

            if profile:
                zout.writestr(f"{app_prefix}embedded.mobileprovision", profile)

        tmp.replace(dst)

    return PatchResult(
        out_path=dst,
        bundle_id=new_bundle,
        display_name=display_name or info.display_name,
        stripped_bundles=sorted({s.split("/")[1] for s in stripped if "/" in s}),
        injected_profile=profile is not None,
    )


def suggest_bundle_id(original: str, suffix: str) -> str:
    """给"应用分身"生成一个新 Bundle ID：com.foo.bar -> com.foo.bar.<suffix>"""
    suffix = re.sub(r"[^A-Za-z0-9]", "", suffix) or "alt"
    return f"{original}.{suffix}"
