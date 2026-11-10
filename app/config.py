"""全局配置。所有路径都落在项目目录内，方便打包搬迁。"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config.json"


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 8722
    # Anisette 服务：提供苹果设备指纹数据，是免密登录的前提。
    # 默认用公共实例，长期使用建议自建（见 docs/apple-api.md）。
    anisette_url: str = "https://ani.sidestore.io"
    # zsign 可执行文件路径，留空则自动在 PATH / tools 目录里找
    zsign_path: str = ""
    # 演示模式：不连苹果服务器、不真签名，只跑通整条流水线，方便先看界面
    mock_mode: bool = False
    data_dir: str = str(ROOT / "data")

    @property
    def data_path(self) -> Path:
        path = Path(self.data_dir)
        path.mkdir(parents=True, exist_ok=True)
        return path

    @property
    def db_path(self) -> Path:
        return self.data_path / "app.db"

    @property
    def certs_dir(self) -> Path:
        path = self.data_path / "certs"
        path.mkdir(parents=True, exist_ok=True)
        return path

    @property
    def work_dir(self) -> Path:
        path = self.data_path / "work"
        path.mkdir(parents=True, exist_ok=True)
        return path


def load() -> Config:
    if CONFIG_PATH.exists():
        try:
            raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            raw = {}
        known = {k: v for k, v in raw.items() if k in Config.__dataclass_fields__}
        return Config(**known)
    return Config()


def save(cfg: Config) -> None:
    CONFIG_PATH.write_text(
        json.dumps(asdict(cfg), ensure_ascii=False, indent=2), encoding="utf-8"
    )
