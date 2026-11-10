"""zsign 封装。

为什么用 zsign 而不是自己写签名：
  - 它是目前最快的跨平台重签工具（C++），Windows/Linux/macOS 都能跑
  - 会自动处理嵌套 framework 的签名顺序、entitlements 注入、LC_CODE_SIGNATURE
  - 自己实现等于重写一遍苹果的 code signing，没有必要

下载：https://github.com/zhlynn/zsign/releases
放哪：项目根目录的 tools/ 下，或者任何在 PATH 里的位置。
Linux/macOS 记得 chmod +x。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class ZSignError(RuntimeError):
    pass


def locate(explicit: str = "") -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    which = shutil.which("zsign")
    if which:
        candidates.append(Path(which))
    for name in ("zsign.exe", "zsign"):
        candidates.append(ROOT / "tools" / name)
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def version(binary: Path) -> str:
    try:
        out = subprocess.run(
            [str(binary), "--version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return "unknown"


def sign(
    ipa: str | Path,
    profile: str | Path,
    p12: str | Path,
    p12_password: str,
    out: str | Path,
    *,
    binary: Path | None = None,
    bundle_id: str | None = None,
    display_name: str | None = None,
    compression: int = 9,
    timeout: int = 900,
) -> str:
    """对 IPA 签名。返回 zsign 的输出日志。"""
    exe = binary or locate()
    if exe is None:
        raise ZSignError(
            "找不到 zsign。请从 https://github.com/zhlynn/zsign/releases 下载，"
            "放到项目的 tools/ 目录（Windows 放 zsign.exe），或在设置里填写完整路径。"
        )

    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)

    command = [
        str(exe),
        "-k", str(p12),
        "-p", p12_password,
        "-m", str(profile),
        "-o", str(out),
        "-z", str(compression),
    ]
    if bundle_id:
        command += ["-b", bundle_id]
    if display_name:
        command += ["-n", display_name]
    command.append(str(ipa))

    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
    except subprocess.TimeoutExpired as exc:
        raise ZSignError(f"zsign 执行超过 {timeout} 秒仍未结束，已中止") from exc
    except OSError as exc:
        raise ZSignError(f"无法启动 zsign：{exc}") from exc

    log = (completed.stdout or "") + (completed.stderr or "")
    if completed.returncode != 0 or not out.exists():
        raise ZSignError(f"zsign 签名失败（退出码 {completed.returncode}）：\n{log[-1500:]}")
    return log
