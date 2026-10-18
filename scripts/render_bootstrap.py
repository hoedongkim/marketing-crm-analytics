#!/usr/bin/env python3
"""Render the one-time admin SQL with this machine's public keys.

    python scripts/render_bootstrap.py --key-dir "$HOME/.snowflake/keys"    # make bootstrap-sql

Reads svc_crm_pipeline.pub and svc_crm_bi.pub from the key directory, validates them
(PEM SubjectPublicKeyInfo, RSA, at least 2048 bits, two different keys), strips the
BEGIN/END lines and newlines (the form RSA_PUBLIC_KEY expects), substitutes them into
sql/setup/00_bootstrap.template.sql and writes build/snowflake_bootstrap.sql (mode 600;
build/ is git-ignored). Standard library only; public keys are not secret, but the file
is account-specific, so it stays out of git.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = REPO_ROOT / "sql" / "setup" / "00_bootstrap.template.sql"
OUTPUT = REPO_ROOT / "build" / "snowflake_bootstrap.sql"

# placeholder -> (public key file, user it belongs to)
KEYS = {
    "PIPELINE_PUBLIC_KEY": ("svc_crm_pipeline.pub", "SVC_CRM_PIPELINE"),
    "BI_PUBLIC_KEY": ("svc_crm_bi.pub", "SVC_CRM_BI"),
}
RSA_ENCRYPTION_OID = bytes.fromhex("2a864886f70d010101")  # 1.2.840.113549.1.1.1
MIN_BITS = 2048
PLACEHOLDER_RE = re.compile(r"\{\{\s*([A-Z_]+)\s*\}\}")


class KeyProblem(Exception):
    pass


def read_tlv(buf: bytes, pos: int) -> tuple[int, int, int]:
    """Read one DER TLV at pos -> (tag, value_start, value_end)."""
    if pos + 2 > len(buf):
        raise KeyProblem("truncated DER")
    tag, first = buf[pos], buf[pos + 1]
    pos += 2
    if first < 0x80:
        length = first
    else:
        n = first & 0x7F
        if n == 0 or n > 4 or pos + n > len(buf):
            raise KeyProblem("bad DER length")
        length = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    if pos + length > len(buf):
        raise KeyProblem("truncated DER value")
    return tag, pos, pos + length


def rsa_modulus_bits(der: bytes) -> int:
    """SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }."""
    tag, start, end = read_tlv(der, 0)
    if tag != 0x30 or end != len(der):
        raise KeyProblem("not a DER SEQUENCE")
    tag, alg_start, alg_end = read_tlv(der, start)
    if tag != 0x30:
        raise KeyProblem("missing AlgorithmIdentifier")
    tag, oid_start, oid_end = read_tlv(der, alg_start)
    if tag != 0x06 or der[oid_start:oid_end] != RSA_ENCRYPTION_OID:
        raise KeyProblem("not an RSA public key (Snowflake key-pair auth needs RSA)")
    tag, bits_start, bits_end = read_tlv(der, alg_end)
    if tag != 0x03 or der[bits_start] != 0:
        raise KeyProblem("malformed public-key BIT STRING")
    inner = der[bits_start + 1:bits_end]
    tag, seq_start, _ = read_tlv(inner, 0)
    if tag != 0x30:
        raise KeyProblem("malformed RSAPublicKey")
    tag, n_start, n_end = read_tlv(inner, seq_start)
    if tag != 0x02:
        raise KeyProblem("missing RSA modulus")
    return int.from_bytes(inner[n_start:n_end], "big").bit_length()


def load_public_key(path: Path) -> tuple[str, int, str]:
    """Return (one-line base64 body, modulus bits, 'SHA256:<base64>' fingerprint)."""
    if not path.is_file():
        raise KeyProblem(f"{path} not found. Run 'make keys' first (or pass the right KEY_DIR).")
    try:
        text = path.read_text(encoding="ascii")
    except UnicodeDecodeError:
        raise KeyProblem(f"{path.name} is not an ASCII PEM file") from None
    if "PRIVATE KEY" in text:
        raise KeyProblem(f"{path.name} contains a PRIVATE key. Never paste private keys into SQL; "
                         "point at the .pub file.")
    if "BEGIN RSA PUBLIC KEY" in text:
        raise KeyProblem(f"{path.name} is a PKCS#1 'RSA PUBLIC KEY'; Snowflake expects the "
                         "'PUBLIC KEY' form from: openssl rsa -in key.p8 -pubout -out key.pub")
    lines = [line.strip() for line in text.strip().splitlines() if line.strip()]
    if len(lines) < 3 or lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        raise KeyProblem(f"{path.name} is not a PEM public key (BEGIN/END PUBLIC KEY lines missing)")
    body = "".join(lines[1:-1])
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", body):
        raise KeyProblem(f"{path.name}: the key body is not base64")
    try:
        der = base64.b64decode(body, validate=True)
    except binascii.Error:
        raise KeyProblem(f"{path.name}: the key body is not valid base64") from None
    bits = rsa_modulus_bits(der)
    if bits < MIN_BITS:
        raise KeyProblem(f"{path.name} is a {bits}-bit RSA key; Snowflake requires at least {MIN_BITS}.")
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode("ascii")
    return body, bits, fingerprint


def check_private_key_pair(key_dir: Path, pub_name: str, must_be_unencrypted: bool) -> list[str]:
    """Look only at the first line of the matching .p8 (never the key itself)."""
    p8 = key_dir / pub_name.replace(".pub", ".p8")
    if not p8.is_file():
        return [f"{p8.name} not found next to {pub_name}; you will need it for .env"]
    with p8.open("rb") as fh:
        first = fh.readline().strip()
    if must_be_unencrypted and first == b"-----BEGIN ENCRYPTED PRIVATE KEY-----":
        raise KeyProblem(f"{p8.name} is encrypted, but the Google Data Studio connector only accepts "
                         "unencrypted keys. Regenerate the BI key with 'make keys'.")
    return []


def render(template: str, values: dict[str, str]) -> str:
    found = set(PLACEHOLDER_RE.findall(template))
    if found != set(values):
        raise KeyProblem(f"template placeholders {sorted(found)} do not match {sorted(values)}")
    out = PLACEHOLDER_RE.sub(lambda m: values[m.group(1)], template)
    if "{{" in out or "}}" in out:
        raise KeyProblem("unrendered '{{' or '}}' left in the output")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render build/snowflake_bootstrap.sql.")
    parser.add_argument("--key-dir", default=os.environ.get("KEY_DIR", str(Path.home() / ".snowflake" / "keys")),
                        help="directory with svc_crm_pipeline.pub and svc_crm_bi.pub")
    parser.add_argument("--template", type=Path, default=TEMPLATE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args(argv)
    key_dir = Path(args.key_dir).expanduser()

    values: dict[str, str] = {}
    summary = []
    notes = []
    try:
        for placeholder, (pub_name, user) in KEYS.items():
            body, bits, fingerprint = load_public_key(key_dir / pub_name)
            notes += check_private_key_pair(key_dir, pub_name, must_be_unencrypted=(user == "SVC_CRM_BI"))
            values[placeholder] = body
            summary.append((user, pub_name, bits, fingerprint))
        if values["PIPELINE_PUBLIC_KEY"] == values["BI_PUBLIC_KEY"]:
            raise KeyProblem("both users would get the SAME public key; each user needs its own key pair.")
        rendered = render(args.template.read_text(encoding="utf-8"), values)
    except KeyProblem as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    out = args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(rendered)
    os.chmod(out, 0o600)

    try:
        shown = out.resolve().relative_to(REPO_ROOT)
    except ValueError:
        shown = out
    print(f"Wrote {shown} (mode 600, {len(rendered.splitlines())} lines) from {args.template.name}")
    print(f"Public keys from {key_dir}:")
    for user, pub_name, bits, fingerprint in summary:
        print(f"  {user:<17} {pub_name:<21} RSA {bits}  {fingerprint}")
    for note in notes:
        print(f"  note: {note}")
    print()
    print("Next (the human admin does this; see docs/setup_snowflake.md, step 5):")
    print("  1. Sign in to Snowsight as your admin user (the one with ACCOUNTADMIN).")
    print("  2. Open a new SQL worksheet, paste the whole file, and click Run All.")
    print("     Every statement is idempotent, so a re-run after a fix is safe.")
    print("  3. The last result row shows SNOWFLAKE_ACCOUNT and both key fingerprints:")
    print("     the fingerprints must equal the two above.")
    print("  4. cp .env.example .env && chmod 600 .env, then fill in SNOWFLAKE_ACCOUNT and:")
    print(f"       SNOWFLAKE_PRIVATE_KEY_PATH={key_dir / 'svc_crm_pipeline.p8'}")
    print(f"       SNOWFLAKE_BI_PRIVATE_KEY_PATH={key_dir / 'svc_crm_bi.p8'}")
    print("  5. make sf-check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
