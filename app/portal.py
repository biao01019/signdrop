"""开发者后台（Developer Services）客户端。

同样属于逆向接口，标记为实验性。每条 action 都集中放在 _ACTIONS 里，
苹果改地址时只需要改这一处。

会话头需要三样东西：
  - X-Apple-I-Identity-Id  （adsid，账号的数字 ID）
  - X-Apple-GS-Token       （fetch_token 拿到的令牌）
  - X-Apple-ID-Session-Id  （登录会话）
外加 anisette 的那组设备指纹头。
"""

from __future__ import annotations

import base64
import plistlib
import uuid
from dataclasses import dataclass

from .net import HttpSession

_BASE = "https://developerservices2.apple.apple.com/services/QH65B2/"

_ACTIONS = {
    "list_teams": "ios/listTeams.action",
    "add_device": "ios/addDevice.action",
    "list_devices": "ios/listDevices.action",
    "submit_csr": "ios/submitDevelopmentCSR.action",
    "revoke_cert": "ios/revokeDevelopmentCert.action",
    "add_app_id": "ios/addAppId.action",
    "download_team_profile": "ios/downloadTeamProvisioningProfile.action",
    "list_profiles": "ios/listProvisioningProfiles.action",
    "delete_profile": "ios/deleteProvisioningProfile.action",
}

_CLIENT_ID = "XABBG36SBA"  # 开发者后台的固定 clientId


class PortalError(RuntimeError):
    pass


@dataclass
class Team:
    team_id: str
    name: str
    type: str = ""


class DeveloperPortal:
    def __init__(
        self,
        http: HttpSession,
        *,
        anisette_headers: dict[str, str],
        adsid: str,
        token: str,
        session_id: str,
    ) -> None:
        self.http = http
        self.anisette_headers = anisette_headers
        self.adsid = adsid
        self.token = token
        self.session_id = session_id

    # -- 底层调用 -----------------------------------------------------------
    def _headers(self) -> dict[str, str]:
        headers = dict(self.anisette_headers)
        headers.update(
            {
                "X-Apple-I-Identity-Id": self.adsid,
                "X-Apple-GS-Token": self.token,
                "X-Apple-ID-Session-Id": self.session_id,
                "Accept": "text/x-xml-plist",
                "Content-Type": "application/x-www-form-urlencoded",
            }
        )
        return headers

    def _call(self, action: str, **params: str) -> dict:
        params.setdefault("clientId", _CLIENT_ID)
        response = self.http.request(
            "POST",
            _BASE + _ACTIONS[action],
            form={k: str(v) for k, v in params.items()},
            headers=self._headers(),
        )
        if response.status != 200:
            raise PortalError(
                f"开发者接口 {action} 返回 HTTP {response.status}：{response.text[:300]}"
            )
        try:
            data = plistlib.loads(response.body)
        except Exception as exc:  # noqa: BLE001 - plistlib 异常类型不统一
            raise PortalError(
                f"开发者接口 {action} 返回内容无法解析，可能是被重定向到登录页："
                f"{response.text[:200]}"
            ) from exc

        if isinstance(data, dict) and data.get("resultCode") not in (None, 0):
            raise PortalError(
                f"开发者接口 {action} 失败：{data.get('resultString') or data.get('userString') or data}"
            )
        return data

    # -- 业务方法 -----------------------------------------------------------
    def list_teams(self) -> list[Team]:
        data = self._call("list_teams")
        teams = data.get("teams", []) or []
        return [
            Team(
                team_id=str(item.get("teamId", "")),
                name=item.get("name", ""),
                type=item.get("type", ""),
            )
            for item in teams
        ]

    def register_device(self, udid: str, name: str, team_id: str) -> dict:
        """把设备加进账号。免费账号一年只有 100 个名额，备注要写清楚便于回收。"""
        data = self._call(
            "add_device",
            devices=udid,
            name=name or f"device-{udid[-6:]}",
            teamId=team_id,
        )
        return data.get("device", {}) or {}

    def list_devices(self, team_id: str) -> list[dict]:
        return self._call("list_devices", teamId=team_id).get("devices", []) or []

    def submit_csr(self, csr_der: bytes, machine_name: str, team_id: str) -> tuple[bytes, str]:
        """提交 CSR，返回 (证书 DER, 证书序列号)。"""
        data = self._call(
            "submit_csr",
            csrContent=base64.b64encode(csr_der).decode(),
            machineId=str(uuid.uuid4()).upper(),
            machineName=machine_name,
            teamId=team_id,
        )
        cert = data.get("certificate", {}) or {}
        content = cert.get("certContent")
        if not content:
            raise PortalError("苹果没有返回证书内容，可能是证书数量已达上限（免费账号 2 个）")
        der = content if isinstance(content, bytes) else base64.b64decode(content)
        return der, str(cert.get("serialNum", ""))

    def add_app_id(self, identifier: str, name: str, team_id: str) -> str:
        """注册 App ID。如果已存在，苹果会报错，此时视为成功并返回空。"""
        try:
            data = self._call(
                "add_app_id",
                identifier=identifier,
                name=name,
                teamId=team_id,
                features='{"push":false,"gameCenter":false,"inAppPurchase":false,"icloud":false}',
            )
        except PortalError as exc:
            if "already" in str(exc).lower() or "duplicate" in str(exc).lower():
                return ""
            raise
        return str((data.get("appId") or {}).get("appIdId", ""))

    def download_profile(self, team_id: str, app_id_id: str) -> bytes:
        data = self._call(
            "download_team_profile", teamId=team_id, appIdId=app_id_id
        )
        profile = data.get("provisioningProfile")
        if not profile:
            raise PortalError("苹果没有返回描述文件，检查设备是否已注册")
        return profile if isinstance(profile, bytes) else base64.b64decode(profile)
