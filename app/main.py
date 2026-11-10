"""HTTP 接口层。只跑在本机 127.0.0.1，不对外暴露。

设计原则：
  - 所有耗时操作（签名/安装）都走后台任务 + 轮询，避免请求超时
  - 任何异常都翻译成中文人话再返回，前端直接展示
  - 密钥、密码、令牌永不出现在响应里
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

from . import auth as auth_module
from . import config, credentials, device, ipa, pipeline, vault, zsign
from .anisette import AnisetteClient
from .store import Store

ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = ROOT / "web"

app = FastAPI(title="iOS 自签名工具", docs_url=None, redoc_url=None)

cfg = config.load()
store = Store(cfg.db_path)
_ctx: dict[str, object] = {"auth": None}


# --------------------------------------------------------------------------
# 请求模型
# --------------------------------------------------------------------------
class SettingsIn(BaseModel):
    mock_mode: bool | None = None
    anisette_url: str | None = None
    zsign_path: str | None = None


class LoginIn(BaseModel):
    apple_id: str
    password: str
    remember: bool = False


class CodeIn(BaseModel):
    code: str


class CredentialIn(BaseModel):
    p12_path: str
    p12_password: str
    profile_path: str
    label: str = ""


class DeviceIn(BaseModel):
    udid: str
    name: str = ""


class SignIn(BaseModel):
    ipa_path: str
    credential_id: int
    bundle_id: str = ""
    display_name: str = ""
    strip_extensions: bool = True


class InstallIn(BaseModel):
    udid: str


# --------------------------------------------------------------------------
# 工具
# --------------------------------------------------------------------------
def _current_auth():
    return _ctx.get("auth")


def _run_job(job_id: int, work) -> None:
    def target() -> None:
        store.update_job(job_id, status="running", message="开始")

        def progress(percent: int, message: str) -> None:
            store.update_job(job_id, progress=percent, message=message)

        try:
            result = work(progress)
            store.update_job(
                job_id, status="done", progress=100, message="完成", result=result
            )
        except Exception as exc:  # noqa: BLE001 - 任务线程必须兜住所有异常
            store.update_job(job_id, status="failed", message=str(exc))

    threading.Thread(target=target, daemon=True).start()


# --------------------------------------------------------------------------
# 页面
# --------------------------------------------------------------------------
@app.get("/")
def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html")


# --------------------------------------------------------------------------
# 状态与设置
# --------------------------------------------------------------------------
@app.get("/api/status")
def status() -> dict:
    binary = zsign.locate(cfg.zsign_path)
    account = store.get_account()
    return {
        "mock_mode": cfg.mock_mode,
        "anisette_url": cfg.anisette_url,
        "zsign_path": str(binary) if binary else "",
        "zsign_version": zsign.version(binary) if binary else "",
        "has_pymobiledevice3": device.has_pymobiledevice3(),
        "account": {"apple_id": account["apple_id"], "display_name": account["display_name"]}
        if account
        else None,
        "auth_stage": getattr(_current_auth(), "state", None).stage
        if _current_auth()
        else "idle",
    }


@app.post("/api/settings")
def update_settings(payload: SettingsIn) -> dict:
    if payload.mock_mode is not None:
        cfg.mock_mode = payload.mock_mode
    if payload.anisette_url:
        cfg.anisette_url = payload.anisette_url
    if payload.zsign_path is not None:
        cfg.zsign_path = payload.zsign_path
    config.save(cfg)
    return {"ok": True, **status()}


# --------------------------------------------------------------------------
# 账号（实验性的一键模式）
# --------------------------------------------------------------------------
@app.post("/api/login")
def login(payload: LoginIn) -> dict:
    if cfg.mock_mode:
        authenticator = auth_module.DemoAuth()
    else:
        authenticator = auth_module.AppleIDAuth(AnisetteClient(cfg.anisette_url))
    _ctx["auth"] = authenticator

    try:
        state = authenticator.start(payload.apple_id)
        state = authenticator.submit_password(payload.password)
    except auth_module.AuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - 网络异常统统翻译
        raise HTTPException(status_code=400, detail=f"登录失败：{exc}") from exc

    if payload.remember and not cfg.mock_mode:
        store.upsert_account(
            payload.apple_id,
            password_enc=vault.encrypt(cfg.data_path, payload.password),
            updated_at=time.time(),
        )

    return {"stage": state.stage, "display_name": state.display_name}


@app.post("/api/login/code")
def login_code(payload: CodeIn) -> dict:
    authenticator = _current_auth()
    if not authenticator:
        raise HTTPException(status_code=400, detail="请先提交 Apple ID 和密码")
    try:
        state = authenticator.submit_code(payload.code)
        authenticator.fetch_token()
    except auth_module.AuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"stage": state.stage, "adsid": state.adsid}


@app.post("/api/logout")
def logout() -> dict:
    _ctx["auth"] = None
    account = store.get_account()
    if account:
        store.delete_account(account["id"])
    return {"ok": True}


# --------------------------------------------------------------------------
# 凭证
# --------------------------------------------------------------------------
@app.get("/api/credentials")
def list_credentials() -> list[dict]:
    result = []
    for row in store.list_credentials():
        try:
            result.append(credentials.summary(credentials.load(cfg, store, row["id"])))
        except credentials.CredentialError as exc:
            result.append(
                {"id": row["id"], "label": row["label"], "state": "broken", "error": str(exc)}
            )
    return result


@app.post("/api/credentials")
def add_credential(payload: CredentialIn) -> dict:
    try:
        return credentials.import_credential(
            cfg,
            store,
            p12_source=payload.p12_path,
            p12_password=payload.p12_password,
            profile_source=payload.profile_path,
            label=payload.label,
        )
    except credentials.CredentialError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.delete("/api/credentials/{credential_id}")
def remove_credential(credential_id: int) -> dict:
    store.delete_credential(credential_id)
    return {"ok": True}


# --------------------------------------------------------------------------
# 设备
# --------------------------------------------------------------------------
@app.get("/api/devices")
def list_devices() -> dict:
    usb = [d.__dict__ for d in device.list_devices()]
    saved = store.list_devices()
    known = {d["udid"] for d in saved}
    return {
        "usb": usb,
        "saved": saved,
        "usb_online": [d for d in usb if d["udid"] in known],
    }


@app.post("/api/devices")
def add_device(payload: DeviceIn) -> dict:
    udid = payload.udid.strip()
    if len(udid) < 20:
        raise HTTPException(
            status_code=400,
            detail="UDID 看起来不对：应该是 40 位十六进制（老设备）或 24 位加连字符（新设备）。"
            "可以在设备连接到电脑后从本工具的设备列表里直接读取。",
        )
    store.add_device(udid, payload.name or f"设备 {udid[-6:]}", None, "manual")
    return {"ok": True}


@app.delete("/api/devices/{udid}")
def remove_device(udid: str) -> dict:
    store.delete_device(udid)
    return {"ok": True}


# --------------------------------------------------------------------------
# 文件浏览（本地选 IPA，不走上传，几百兆的包更省事）
# --------------------------------------------------------------------------
@app.get("/api/fs")
def browse(path: str = "", ext: str = "ipa") -> dict:
    wanted = {("." + e.strip().lower().lstrip(".")) for e in ext.split(",") if e.strip()}
    base = Path(path) if path else Path.home()
    if not base.exists():
        raise HTTPException(status_code=400, detail=f"路径不存在：{base}")
    if not base.is_dir():
        raise HTTPException(status_code=400, detail="请选择一个文件夹")

    entries = []
    try:
        for child in sorted(base.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            if child.name.startswith("."):
                continue
            if child.is_dir():
                entries.append({"name": child.name, "path": str(child), "type": "dir"})
            elif child.suffix.lower() in wanted:
                entries.append(
                    {
                        "name": child.name,
                        "path": str(child),
                        "type": "file",
                        "size": child.stat().st_size,
                    }
                )
    except PermissionError as exc:
        raise HTTPException(status_code=400, detail="这个目录没有访问权限") from exc

    return {
        "cwd": str(base),
        "parent": str(base.parent) if base.parent != base else "",
        "entries": entries,
    }


@app.post("/api/ipa/inspect")
def inspect_ipa(payload: dict) -> dict:
    path = payload.get("path", "")
    try:
        info = ipa.inspect(path)
    except (ipa.IPAError, OSError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {
        "app_bundle": info.app_bundle,
        "bundle_id": info.bundle_id,
        "display_name": info.display_name,
        "version": f"{info.version} ({info.build})",
        "min_os": info.min_os,
        "size": info.size,
        "nested_bundles": len(info.nested_bundles),
    }


# --------------------------------------------------------------------------
# 签名与安装
# --------------------------------------------------------------------------
@app.post("/api/sign")
def sign(payload: SignIn) -> dict:
    job_id = store.create_job("sign")
    request = pipeline.SignRequest(
        ipa_path=payload.ipa_path,
        credential_id=payload.credential_id,
        bundle_id=payload.bundle_id,
        display_name=payload.display_name,
        strip_extensions=payload.strip_extensions,
    )

    def work(progress):
        return pipeline.run_sign(cfg, request, progress, store=store)

    _run_job(job_id, work)
    return {"job_id": job_id}


@app.get("/api/jobs/{job_id}")
def job_status(job_id: int) -> dict:
    job = store.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="任务不存在")
    return job


@app.get("/api/apps")
def list_apps() -> list[dict]:
    return store.list_apps()


@app.post("/api/apps/{app_id}/install")
def install(app_id: int, payload: InstallIn) -> dict:
    row = store.get_app(app_id)
    if not row:
        raise HTTPException(status_code=404, detail="找不到这个 App 记录")
    job_id = store.create_job("install")

    def work(progress):
        result = pipeline.run_install(row, payload.udid, progress)
        store.update_app(app_id, device_udid=payload.udid, status="installed")
        return result

    _run_job(job_id, work)
    return {"job_id": job_id}
