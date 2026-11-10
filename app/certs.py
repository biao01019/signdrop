"""证书相关：生成 RSA 密钥对、构造 CSR、导出 p12、解析描述文件。

流程上，开发者证书是这样来的：
  1. 本地生成 RSA 2048 私钥（永不外传）
  2. 用私钥对公钥签出 CSR（Certificate Signing Request）
  3. 把 CSR 提交给苹果，苹果签发 .cer 证书
  4. 私钥 + 证书打包成 p12，交给 zsign 使用

私钥只在内存和本地 p12 里出现，这是"用户自己的账号自己签"的核心。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID


class CertError(RuntimeError):
    pass


def generate_key(bits: int = 2048) -> rsa.RSAPrivateKey:
    if bits < 2048:
        raise CertError("RSA 密钥至少 2048 位，否则苹果会拒绝签发")
    return rsa.generate_private_key(public_exponent=65537, key_size=bits)


def make_csr(
    key: rsa.RSAPrivateKey, common_name: str, email: str | None = None
) -> bytes:
    """生成 DER 格式的 CSR，苹果开发者接口要的就是 DER。"""
    builder = x509.CertificateSigningRequestBuilder().subject_name(
        x509.Name(
            [
                x509.NameAttribute(NameOID.COMMON_NAME, common_name),
                *(
                    [x509.NameAttribute(NameOID.EMAIL_ADDRESS, email)]
                    if email
                    else []
                ),
            ]
        )
    )
    return builder.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.DER)


def load_certificate(der: bytes) -> x509.Certificate:
    try:
        return x509.load_der_x509_certificate(der)
    except ValueError:
        try:
            return x509.load_pem_x509_certificate(der)
        except ValueError as exc:
            raise CertError("无法解析苹果返回的证书，可能是错误页而非 .cer") from exc


def export_p12(key: rsa.RSAPrivateKey, cert: x509.Certificate, password: str) -> bytes:
    """把私钥和证书打包成 p12，zsign 用它签名。"""
    return pkcs12.serialize_key_and_certificates(
        name=cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value.encode(),
        key=key,
        cert=cert,
        cas=None,
        encryption_algorithm=serialization.BestAvailableEncryption(password.encode()),
    )


def key_to_pem(key: rsa.RSAPrivateKey) -> bytes:
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def load_key_pem(data: bytes) -> rsa.RSAPrivateKey:
    key = serialization.load_pem_private_key(data, password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise CertError("私钥不是 RSA，无法用于 iOS 签名")
    return key


# --------------------------------------------------------------------------
# 描述文件解析
# --------------------------------------------------------------------------


@dataclass
class ProvisioningProfile:
    """从 .mobileprovision 里能读出来的关键信息。

    .mobileprovision 本质是 CMS 签名容器，里面包着一个 plist。这里不做完整
    ASN.1 解析，直接截取其中的 XML 段——这是社区通行做法，足够稳定。
    """

    name: str = ""
    uuid: str = ""
    team_id: str = ""
    app_id: str = ""
    expiration: datetime | None = None
    devices: list[str] = field(default_factory=list)
    entitlements: dict = field(default_factory=dict)
    raw: bytes = b""

    @property
    def is_expired(self) -> bool:
        if not self.expiration:
            return True
        return self.expiration < datetime.now(timezone.utc)

    @property
    def days_left(self) -> int:
        if not self.expiration:
            return 0
        return max(0, (self.expiration - datetime.now(timezone.utc)).days)


def parse_profile(data: bytes) -> ProvisioningProfile:
    import plistlib

    match = re.search(rb"<\?xml.*?</plist>", data, re.S)
    if not match:
        raise CertError("描述文件里找不到 plist 段，文件可能不完整")
    try:
        plist = plistlib.loads(match.group(0))
    except Exception as exc:  # noqa: BLE001 - plistlib 抛的异常类型不统一
        raise CertError(f"描述文件 plist 解析失败：{exc}") from exc

    expiration = plist.get("ExpirationDate")
    if isinstance(expiration, datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)

    entitlements = plist.get("Entitlements", {}) or {}
    return ProvisioningProfile(
        name=plist.get("Name", ""),
        uuid=plist.get("UUID", ""),
        team_id=",".join(plist.get("TeamIdentifier", []) or []),
        app_id=entitlements.get("application-identifier", ""),
        expiration=expiration,
        devices=list(plist.get("ProvisionedDevices", []) or []),
        entitlements=entitlements,
        raw=data,
    )
