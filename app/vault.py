"""本地密钥箱：用机器本地的对称密钥加密敏感字段。

刻意不引入系统钥匙串依赖（Windows Credential Manager / macOS Keychain API
在原生 Python 里都要额外依赖），改成"密钥文件 + Fernet"：

  - 密钥文件 data/secret.key，首次运行自动生成，权限尽量收紧
  - 只加密密码这类敏感字段；证书 p12 本身已有独立密码保护

这样即使整个 data 目录被拷走，没有 secret.key 也解不出明文密码。
要更硬的隔离，可把 secret.key 移到 U 盘或改用系统钥匙串。
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

_cached: dict[Path, Fernet] = {}


class VaultError(RuntimeError):
    pass


def _load_cipher(data_dir: Path) -> Fernet:
    key_path = data_dir / "secret.key"
    if key_path in _cached:
        return _cached[key_path]

    if not key_path.exists():
        key = Fernet.generate_key()
        key_path.write_bytes(key)
        try:
            os.chmod(key_path, stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass  # Windows 上语义有限，忽略
    cipher = Fernet(key_path.read_bytes())
    _cached[key_path] = cipher
    return cipher


def encrypt(data_dir: Path, plaintext: str) -> str:
    return _load_cipher(data_dir).encrypt(plaintext.encode()).decode()


def decrypt(data_dir: Path, token: str) -> str:
    try:
        return _load_cipher(data_dir).decrypt(token.encode()).decode()
    except InvalidToken as exc:
        raise VaultError(
            "本地密钥与密文不匹配，可能是 data/secret.key 被替换或删除。"
            "请重新登录苹果账号。"
        ) from exc
