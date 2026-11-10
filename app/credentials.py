"""凭证管理（手动证书模式）。

为什么这是默认路径：
    走这条路的凭证由用户在 developer.apple.com 亲手生成，工具不接触任何私有接口，
    因此不会因为苹果改接口而失效，也不涉及账号密码。工程上这是最稳的一条。

用户需要准备两个文件：
    1) development.p12 —— 开发证书（导出时设一个密码）
    2) xxx.mobileprovision —— 描述文件（里面包含允许安装的设备 UDID 列表）

工具负责：校验、保存、判断有效期、检查 Bundle ID 是否匹配、签名、安装。
"""

from __future__ import annotations

import shutil
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.serialization import pkcs12

from . import certs, config, vault
from .store import Store


class CredentialError(RuntimeError):
    pass


@dataclass
class Credential:
    id: int
    label: str
    p12_path: Path
    p12_password: str
    profile_path: Path
    team_id: str
    expires_at: datetime | None
    device_count: int
    app_id: str

    @property
    def days_left(self) -> int:
        if not self.expires_at:
            return 0
        return max(0, (self.expires_at - datetime.now(timezone.utc)).days)

    @property
    def is_expired(self) -> bool:
        return self.days_left == 0

    def allows_bundle_id(self, bundle_id: str) -> bool:
        """描述文件的 application-identifier 是通配还是精确匹配。"""
        if not self.app_id:
            return True
        pattern = self.app_id.split(".", 1)[-1] if "." in self.app_id else self.app_id
        if pattern.endswith("*"):
            return bundle_id.startswith(pattern[:-1])
        return bundle_id == pattern


def _verify_p12(path: Path, password: str) -> None:
    try:
        data = path.read_bytes()
        key, cert, _ = pkcs12.load_key_and_certificates(data, password.encode() or None)
    except ValueError as exc:
        raise CredentialError(
            "p12 打不开：密码不对，或文件不是有效的 PKCS#12。"
            "（从钥匙串导出时选 .p12 格式，并记住设置的密码）"
        ) from exc
    if key is None or cert is None:
        raise CredentialError("p12 里缺少私钥或证书，导出的可能只是证书而非完整凭证")


def import_credential(
    cfg: config.Config,
    store: Store,
    *,
    p12_source: str | Path,
    p12_password: str,
    profile_source: str | Path,
    label: str = "",
) -> dict:
    p12_source = Path(p12_source)
    profile_source = Path(profile_source)

    if not p12_source.is_file():
        raise CredentialError(f"找不到 p12 文件：{p12_source}")
    if not profile_source.is_file():
        raise CredentialError(f"找不到描述文件：{profile_source}")

    _verify_p12(p12_source, p12_password)

    profile_data = profile_source.read_bytes()
    profile = certs.parse_profile(profile_data)
    if profile.is_expired:
        raise CredentialError(
            f"描述文件已在 {profile.expiration:%Y-%m-%d} 过期，去开发者后台重新生成一个"
        )

    target_dir = cfg.certs_dir / f"cred_{int(time.time())}"
    target_dir.mkdir(parents=True, exist_ok=True)
    p12_target = target_dir / "development.p12"
    profile_target = target_dir / "profile.mobileprovision"
    shutil.copy2(p12_source, p12_target)
    shutil.copy2(profile_source, profile_target)

    credential_id = store.add_credential(
        label=label or profile.name or p12_source.stem,
        p12_path=str(p12_target),
        p12_password=vault.encrypt(cfg.data_path, p12_password),
        profile_path=str(profile_target),
        team_id=profile.team_id,
        bundle_hint=profile.app_id,
        expires_at=profile.expiration.isoformat() if profile.expiration else "",
        device_count=len(profile.devices),
    )
    return summary(load(cfg, store, credential_id))


def load(cfg: config.Config, store: Store, credential_id: int) -> Credential:
    row = store.get_credential(credential_id)
    if not row:
        raise CredentialError("凭证不存在，可能已被删除")
    try:
        password = vault.decrypt(cfg.data_path, row["p12_password"])
    except vault.VaultError as exc:
        raise CredentialError(str(exc)) from exc

    expires = None
    if row["expires_at"]:
        try:
            expires = datetime.fromisoformat(row["expires_at"])
        except ValueError:
            expires = None

    return Credential(
        id=row["id"],
        label=row["label"],
        p12_path=Path(row["p12_path"]),
        p12_password=password,
        profile_path=Path(row["profile_path"]),
        team_id=row["team_id"],
        expires_at=expires,
        device_count=row["device_count"],
        app_id=row["bundle_hint"],
    )


def summary(credential: Credential) -> dict:
    """给前端用的脱敏结构——永远不返回 p12 密码。"""
    state = "expired" if credential.is_expired else (
        "expiring" if credential.days_left <= 7 else "ok"
    )
    return {
        "id": credential.id,
        "label": credential.label,
        "team_id": credential.team_id,
        "app_id": credential.app_id,
        "device_count": credential.device_count,
        "expires_at": credential.expires_at.isoformat() if credential.expires_at else "",
        "days_left": credential.days_left,
        "state": state,
        "p12_exists": credential.p12_path.is_file(),
        "profile_exists": credential.profile_path.is_file(),
    }
