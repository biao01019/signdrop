"""SQLite 持久层。单文件、零配置，适合本地工具。

表设计要点：
  - accounts 一个账号一行，证书信息随账号走（一个 Apple ID 一个开发证书足够）
  - devices 以 UDID 为主键，全局去重——同一台设备不该被重复注册
  - apps 记录"哪个 IPA 被签成了什么包、装在哪台设备、什么时候过期"
  - jobs 让签名/安装这类长任务可以异步跑，前端轮询进度
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    apple_id      TEXT UNIQUE NOT NULL,
    display_name  TEXT DEFAULT '',
    adsid         TEXT DEFAULT '',
    password_enc  TEXT DEFAULT '',   -- 仅在用户勾选"记住密码"时非空
    session_json  TEXT DEFAULT '',
    cert_p12      TEXT DEFAULT '',
    cert_password TEXT DEFAULT '',
    cert_serial   TEXT DEFAULT '',
    cert_expires  TEXT DEFAULT '',
    team_id       TEXT DEFAULT '',
    created_at    REAL NOT NULL,
    updated_at    REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
    udid       TEXT PRIMARY KEY,
    name       TEXT DEFAULT '',
    account_id INTEGER,
    source     TEXT DEFAULT 'usb',   -- usb | manual
    created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS apps (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER,
    bundle_id    TEXT NOT NULL,
    name         TEXT DEFAULT '',
    version      TEXT DEFAULT '',
    source_ipa   TEXT NOT NULL,
    signed_ipa   TEXT DEFAULT '',
    profile_path TEXT DEFAULT '',
    device_udid  TEXT DEFAULT '',
    status       TEXT DEFAULT 'signed',
    expires_at   TEXT DEFAULT '',
    created_at   REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS credentials (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    label         TEXT NOT NULL,
    bundle_hint   TEXT DEFAULT '',
    team_id       TEXT DEFAULT '',
    p12_path      TEXT NOT NULL,
    p12_password  TEXT NOT NULL,     -- 用 vault 加密后存
    profile_path  TEXT NOT NULL,
    expires_at    TEXT DEFAULT '',
    device_count  INTEGER DEFAULT 0,
    created_at    REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS jobs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL,
    status     TEXT NOT NULL,        -- pending | running | done | failed
    progress   INTEGER DEFAULT 0,
    message    TEXT DEFAULT '',
    result     TEXT DEFAULT '',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
"""


class Store:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(SCHEMA)
        self._conn.commit()

    # -- 通用 ---------------------------------------------------------------
    def _now(self) -> float:
        return time.time()

    def close(self) -> None:
        self._conn.close()

    # -- 账号 ---------------------------------------------------------------
    def upsert_account(self, apple_id: str, **fields: Any) -> int:
        now = self._now()
        row = self._conn.execute(
            "SELECT id FROM accounts WHERE apple_id = ?", (apple_id,)
        ).fetchone()
        if row:
            if fields:
                assignments = ", ".join(f"{k} = ?" for k in fields)
                self._conn.execute(
                    f"UPDATE accounts SET {assignments}, updated_at = ? WHERE id = ?",
                    (*fields.values(), now, row["id"]),
                )
        else:
            fields.setdefault("created_at", now)
            fields.setdefault("updated_at", now)
            keys = ["apple_id", *fields.keys()]
            placeholders = ", ".join("?" for _ in keys)
            cur = self._conn.execute(
                f"INSERT INTO accounts ({', '.join(keys)}) VALUES ({placeholders})",
                (apple_id, *fields.values()),
            )
            row = {"id": cur.lastrowid}
        self._conn.commit()
        return int(row["id"])

    def get_account(self, account_id: int | None = None) -> dict | None:
        if account_id is None:
            row = self._conn.execute(
                "SELECT * FROM accounts ORDER BY updated_at DESC LIMIT 1"
            ).fetchone()
        else:
            row = self._conn.execute(
                "SELECT * FROM accounts WHERE id = ?", (account_id,)
            ).fetchone()
        return dict(row) if row else None

    def delete_account(self, account_id: int) -> None:
        self._conn.execute("DELETE FROM accounts WHERE id = ?", (account_id,))
        self._conn.execute("DELETE FROM devices WHERE account_id = ?", (account_id,))
        self._conn.commit()

    # -- 设备 ---------------------------------------------------------------
    def add_device(self, udid: str, name: str, account_id: int | None, source: str = "usb") -> None:
        self._conn.execute(
            """INSERT INTO devices (udid, name, account_id, source, created_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(udid) DO UPDATE SET name = excluded.name,
                                              account_id = excluded.account_id""",
            (udid, name, account_id, source, self._now()),
        )
        self._conn.commit()

    def list_devices(self, account_id: int | None = None) -> list[dict]:
        if account_id is None:
            rows = self._conn.execute("SELECT * FROM devices ORDER BY created_at").fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM devices WHERE account_id = ? ORDER BY created_at",
                (account_id,),
            ).fetchall()
        return [dict(r) for r in rows]

    def delete_device(self, udid: str) -> None:
        self._conn.execute("DELETE FROM devices WHERE udid = ?", (udid,))
        self._conn.commit()

    # -- 应用 ---------------------------------------------------------------
    def add_app(self, **fields: Any) -> int:
        fields.setdefault("created_at", self._now())
        keys = list(fields.keys())
        placeholders = ", ".join("?" for _ in keys)
        cur = self._conn.execute(
            f"INSERT INTO apps ({', '.join(keys)}) VALUES ({placeholders})",
            tuple(fields.values()),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def update_app(self, app_id: int, **fields: Any) -> None:
        if not fields:
            return
        assignments = ", ".join(f"{k} = ?" for k in fields)
        self._conn.execute(
            f"UPDATE apps SET {assignments} WHERE id = ?", (*fields.values(), app_id)
        )
        self._conn.commit()

    def list_apps(self) -> list[dict]:
        rows = self._conn.execute("SELECT * FROM apps ORDER BY id DESC").fetchall()
        return [dict(r) for r in rows]

    def get_app(self, app_id: int) -> dict | None:
        row = self._conn.execute("SELECT * FROM apps WHERE id = ?", (app_id,)).fetchone()
        return dict(row) if row else None

    # -- 凭证 ---------------------------------------------------------------
    def add_credential(
        self,
        *,
        label: str,
        p12_path: str,
        p12_password: str,
        profile_path: str,
        team_id: str = "",
        bundle_hint: str = "",
        expires_at: str = "",
        device_count: int = 0,
    ) -> int:
        cur = self._conn.execute(
            """INSERT INTO credentials
               (label, bundle_hint, team_id, p12_path, p12_password, profile_path,
                expires_at, device_count, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                label,
                bundle_hint,
                team_id,
                p12_path,
                p12_password,
                profile_path,
                expires_at,
                device_count,
                self._now(),
            ),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def list_credentials(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM credentials ORDER BY id DESC"
        ).fetchall()
        return [dict(r) for r in rows]

    def get_credential(self, credential_id: int) -> dict | None:
        row = self._conn.execute(
            "SELECT * FROM credentials WHERE id = ?", (credential_id,)
        ).fetchone()
        return dict(row) if row else None

    def delete_credential(self, credential_id: int) -> None:
        self._conn.execute("DELETE FROM credentials WHERE id = ?", (credential_id,))
        self._conn.commit()

    # -- 任务 ---------------------------------------------------------------
    def create_job(self, kind: str) -> int:
        now = self._now()
        cur = self._conn.execute(
            "INSERT INTO jobs (kind, status, progress, message, created_at, updated_at)"
            " VALUES (?, 'pending', 0, '', ?, ?)",
            (kind, now, now),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def update_job(
        self,
        job_id: int,
        *,
        status: str | None = None,
        progress: int | None = None,
        message: str | None = None,
        result: Any = None,
    ) -> None:
        fields: dict[str, Any] = {"updated_at": self._now()}
        if status is not None:
            fields["status"] = status
        if progress is not None:
            fields["progress"] = progress
        if message is not None:
            fields["message"] = message
        if result is not None:
            fields["result"] = json.dumps(result, ensure_ascii=False)
        assignments = ", ".join(f"{k} = ?" for k in fields)
        self._conn.execute(
            f"UPDATE jobs SET {assignments} WHERE id = ?", (*fields.values(), job_id)
        )
        self._conn.commit()

    def get_job(self, job_id: int) -> dict | None:
        row = self._conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if not row:
            return None
        job = dict(row)
        if job["result"]:
            try:
                job["result"] = json.loads(job["result"])
            except json.JSONDecodeError:
                pass
        return job
