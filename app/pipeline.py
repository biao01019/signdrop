"""签名流水线：把 IPA + 凭证，变成可以直接装到手机上的包。

每一步都往 progress 回调里报进度，前端据此显示进度条。失败时抛出的异常信息
都写成"用户能照着做"的句子，而不是把底层报错直接甩出去。
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import config, credentials, device, ipa, zsign


class PipelineError(RuntimeError):
    pass


@dataclass
class SignRequest:
    ipa_path: str
    credential_id: int
    bundle_id: str = ""
    display_name: str = ""
    strip_extensions: bool = True


def _safe_filename(name: str, fallback: str = "app") -> str:
    cleaned = re.sub(r'[\\/:*?"<>|\s]+', "_", name).strip("_")
    return cleaned or fallback


def run_sign(cfg: config.Config, request: SignRequest, progress=None, store=None) -> dict:
    def step(percent: int, message: str) -> None:
        if progress:
            progress(percent, message)

    # 1. 检查输入
    step(5, "检查 IPA 结构")
    try:
        info = ipa.inspect(request.ipa_path)
    except ipa.IPAError as exc:
        raise PipelineError(str(exc)) from exc

    step(15, "加载签名凭证")
    if store is None:
        from .store import Store

        store = Store(cfg.db_path)
    try:
        credential = credentials.load(cfg, store, request.credential_id)
    except credentials.CredentialError as exc:
        raise PipelineError(str(exc)) from exc

    if credential.is_expired:
        raise PipelineError(
            f"凭证已于 {credential.expires_at:%Y-%m-%d} 过期，请重新生成描述文件后再签。"
        )

    bundle_id = (request.bundle_id or info.bundle_id).strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.\-]*", bundle_id):
        raise PipelineError(f"Bundle ID 格式不合法：{bundle_id}")

    if not credential.allows_bundle_id(bundle_id):
        raise PipelineError(
            f"描述文件只允许 {credential.app_id}，但当前 Bundle ID 是 {bundle_id}。\n"
            f"两种解决办法：\n"
            f"  1) 改成描述文件允许的 Bundle ID（去掉「应用分身」里的新 ID）\n"
            f"  2) 去开发者后台为 {bundle_id} 单独建一个 App ID 和描述文件"
        )

    # 2. 改写 IPA
    step(35, "改写 Bundle ID 并清理旧签名")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    work = cfg.work_dir / f"{_safe_filename(info.display_name)}-{stamp}"
    work.mkdir(parents=True, exist_ok=True)
    patched = work / "patched.ipa"

    try:
        patch_result = ipa.patch(
            request.ipa_path,
            patched,
            bundle_id=bundle_id,
            display_name=request.display_name or None,
            strip_extensions=request.strip_extensions,
        )
    except ipa.IPAError as exc:
        raise PipelineError(str(exc)) from exc

    display_name = request.display_name or info.display_name
    final_name = f"{_safe_filename(display_name)}-{stamp}.ipa"

    # 3. 签名
    if cfg.mock_mode:
        step(80, "演示模式：跳过真实签名")
        signed = cfg.work_dir / final_name.replace(".ipa", "-patched.ipa")
        signed.write_bytes(patched.read_bytes())
        mock = True
        log = "演示模式未调用 zsign，产物只做了结构与 Bundle ID 改写，不能安装到设备。"
    else:
        step(60, "调用 zsign 重新签名（大包可能需要几分钟）")
        binary = zsign.locate(cfg.zsign_path)
        if binary is None:
            raise PipelineError(
                "找不到 zsign，无法签名。\n"
                "下载：https://github.com/zhlynn/zsign/releases\n"
                "放到项目的 tools/ 目录（Windows 文件名 zsign.exe），或在设置里填完整路径。\n"
                "想先看流程可以打开「演示模式」，它会跳过真实签名。"
            )
        signed = cfg.work_dir / final_name
        try:
            log = zsign.sign(
                patched,
                credential.profile_path,
                credential.p12_path,
                credential.p12_password,
                signed,
                binary=binary,
                display_name=request.display_name or None,
            )
        except zsign.ZSignError as exc:
            raise PipelineError(str(exc)) from exc
        mock = False

    if not signed.is_file() or signed.stat().st_size == 0:
        raise PipelineError("签名产物为空，重试一次；若仍失败请检查 p12 与描述文件是否配对")

    # 4. 记录
    step(95, "写入签名记录")
    app_id = store.add_app(
        bundle_id=bundle_id,
        name=display_name,
        version=f"{info.version} ({info.build})",
        source_ipa=str(Path(request.ipa_path).resolve()),
        signed_ipa=str(signed.resolve()),
        profile_path=str(credential.profile_path),
        status="patched" if mock else "signed",
        expires_at=credential.expires_at.isoformat() if credential.expires_at else "",
    )
    step(100, "完成")

    return {
        "app_id": app_id,
        "signed_path": str(signed.resolve()),
        "bundle_id": bundle_id,
        "display_name": display_name,
        "version": f"{info.version} ({info.build})",
        "size": signed.stat().st_size,
        "days_left": credential.days_left,
        "expires_at": credential.expires_at.isoformat() if credential.expires_at else "",
        "stripped_bundles": patch_result.stripped_bundles,
        "mock": mock,
        "log_tail": log[-1200:],
    }


def run_install(app_row: dict, udid: str, progress=None) -> dict:
    def step(percent: int, message: str) -> None:
        if progress:
            progress(percent, message)

    path = Path(app_row.get("signed_ipa", ""))
    if not path.is_file():
        raise PipelineError("签名产物已被删除，请重新签名")

    step(20, "检查设备连接")
    if not device.has_pymobiledevice3():
        raise PipelineError(
            "未安装 pymobiledevice3，无法通过 USB 安装。\n"
            "执行 pip install pymobiledevice3 后重试，或用爱思助手手动安装这个文件：\n"
            f"{path}"
        )

    step(45, "推送到设备并安装")
    try:
        log = device.install(udid, str(path))
    except device.DeviceError as exc:
        raise PipelineError(str(exc)) from exc

    step(100, "安装完成")
    return {"installed_on": udid, "log_tail": log[-800:]}
