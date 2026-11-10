"""设备通信：枚举已连接的 iPhone、安装 IPA。

优先用 pymobiledevice3（纯 Python，Windows 上不需要装 iTunes 全家桶）。
没装就降级为手动填 UDID + 走 OTA 安装页，功能不中断。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from dataclasses import dataclass


class DeviceError(RuntimeError):
    pass


@dataclass
class Device:
    udid: str
    name: str
    ios: str = ""
    connection: str = ""
    source: str = "usb"


def _run(args: list[str], timeout: int = 60) -> tuple[int, str, str]:
    try:
        completed = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
        return completed.returncode, completed.stdout or "", completed.stderr or ""
    except FileNotFoundError as exc:
        raise DeviceError(f"命令不存在：{args[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise DeviceError(f"命令超时：{' '.join(args)}") from exc


def has_pymobiledevice3() -> bool:
    return (
        shutil.which("pymobiledevice3") is not None
        or _module_available("pymobiledevice3")
    )


def _module_available(name: str) -> bool:
    try:
        import importlib.util

        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def _pmd3(*args: str, timeout: int = 60) -> tuple[int, str, str]:
    """调用 pymobiledevice3。优先走模块方式，避免 PATH 没配好。"""
    if _module_available("pymobiledevice3"):
        return _run([sys.executable, "-m", "pymobiledevice3", *args], timeout)
    exe = shutil.which("pymobiledevice3")
    if exe:
        return _run([exe, *args], timeout)
    raise DeviceError(
        "未安装 pymobiledevice3。执行 `pip install pymobiledevice3` 即可；"
        "或者跳过 USB 识别，直接手动填写设备 UDID。"
    )


def list_devices() -> list[Device]:
    """列出通过 USB / 局域网连接、且已信任本机的设备。"""
    if not has_pymobiledevice3():
        return []

    try:
        code, out, err = _pmd3("usbmux", "list")
    except DeviceError:
        return []
    if code != 0:
        return []

    try:
        raw = json.loads(out)
    except json.JSONDecodeError:
        return []

    devices: list[Device] = []
    for item in raw if isinstance(raw, list) else []:
        udid = item.get("UniqueDeviceID") or item.get("Identifier") or ""
        if not udid:
            continue
        devices.append(
            Device(
                udid=udid,
                name=item.get("DeviceName") or "iPhone",
                ios=item.get("ProductVersion", ""),
                connection=item.get("ConnectionType", "USB"),
            )
        )
    return devices


def install(udid: str, ipa_path: str, timeout: int = 600) -> str:
    """在指定设备上安装已签名的 IPA。"""
    code, out, err = _pmd3("apps", "install", ipa_path, "--udid", udid, timeout=timeout)
    log = (out or "") + (err or "")
    if code != 0:
        raise DeviceError(_explain_install_failure(log))
    return log.strip()


def _explain_install_failure(log: str) -> str:
    """把苹果那一串十六进制错误码翻译成人话，这是用户最需要的部分。"""
    hints = {
        "0xE8008015": "描述文件里没有这台设备的 UDID —— 先把设备注册到账号，再重新签名。",
        "0xE8008016": "签名不完整，通常是嵌套扩展没签或被改动过。试试勾选「移除扩展」后重签。",
        "0xE8008017": "包本身损坏，重新导出 IPA 再试。",
        "0xE8008018": "设备上的旧版本还在，先卸载再装。",
        "0xE8008019": "证书已被吊销或过期，需要重新申请开发证书。",
        "0xE8008001": "签名证书不是开发证书，检查 p12 是否用错。",
        "Afc": "设备未解锁或未信任本机，解锁屏幕并点「信任」后重试。",
        "DeveloperMode": "设备未开启开发者模式：设置 - 隐私与安全性 - 开发者模式。",
    }
    matched = [tip for code, tip in hints.items() if code.lower() in log.lower()]
    if matched:
        return "安装失败：" + " ".join(matched) + f"\n原始输出：\n{log[-800:]}"
    return f"安装失败：\n{log[-1200:]}"
