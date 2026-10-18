"""Shared Snowflake connection helper for the project scripts.

- Loads the repo-root .env (python-dotenv); variables already set in the shell win.
- Validates every setting before touching the network, with messages that never
  contain secrets (no key material, no passphrase).
- Opens a key-pair (SNOWFLAKE_JWT) connection with an explicit role, warehouse and
  database, tagged QUERY_TAG = 'marketing-crm:<tool>' so the project's queries are easy
  to find in QUERY_HISTORY.
- run_sql_file() executes a multi-statement .sql file statement by statement, using the
  connector's own splitter (handles comments, quoted strings and $$ blocks).

Only the standard library is imported at module level: the connector, python-dotenv and
cryptography are imported inside the functions that need them, so offline code paths
(e.g. load_raw.py --dry-run) never load them.
"""

from __future__ import annotations

import base64
import hashlib
import io
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
SETUP_DOC = "docs/setup_snowflake.md"

DEFAULTS = {
    "SNOWFLAKE_USER": "SVC_CRM_PIPELINE",
    "SNOWFLAKE_WAREHOUSE": "MARKETING_WH",
    "SNOWFLAKE_DATABASE": "MARKETING_CRM",
    "SNOWFLAKE_LOADER_ROLE": "CRM_LOADER",
    "SNOWFLAKE_TRANSFORMER_ROLE": "CRM_TRANSFORMER",
    "SNOWFLAKE_BI_USER": "SVC_CRM_BI",
    "SNOWFLAKE_REPORTER_ROLE": "CRM_REPORTER",
}

# Known connection errors -> what to check. Error numbers from the Snowflake drivers.
ERROR_HINTS = {
    390144: [
        "JWT token is invalid. Usual causes, in order:",
        "  1. SNOWFLAKE_ACCOUNT is not this account's identifier (use ORGNAME-ACCOUNTNAME,",
        "     exactly as the last row of the bootstrap SQL printed it).",
        "  2. The key in the .p8 file is not the one registered for this user: compare the",
        "     local fingerprint below with RSA_PUBLIC_KEY_FP from DESC USER.",
        "  3. The computer clock is off by more than a minute (JWTs are time-limited).",
    ],
    250001: [
        "Could not reach Snowflake. Check SNOWFLAKE_ACCOUNT (no https://, no",
        ".snowflakecomputing.com) and your network connection.",
    ],
    390100: [
        "Incorrect username or authentication. Check SNOWFLAKE_USER and that the bootstrap",
        "SQL created the user (SHOW USERS LIKE 'SVC_CRM%').",
    ],
    390189: [
        "The requested role is not granted to this user. Re-run section 5 of",
        "build/snowflake_bootstrap.sql (GRANT ROLE ... TO USER ...).",
    ],
}


class ConfigError(Exception):
    """A setting is missing or invalid. The message is safe to print."""


class ConnectError(Exception):
    """Snowflake refused the connection. The message is safe to print."""


class SqlFileError(Exception):
    """A statement in a .sql file failed. The message is safe to print."""


@dataclass(frozen=True)
class KeyInfo:
    path: Path
    encrypted: bool
    bits: int
    fingerprint: str  # 'SHA256:<base64>', the format DESC USER shows as RSA_PUBLIC_KEY_FP
    warnings: tuple[str, ...] = ()


@dataclass
class StatementResult:
    index: int
    sql: str
    query_id: str | None
    columns: list[str] = field(default_factory=list)
    rows: list[tuple] = field(default_factory=list)


def load_env() -> bool:
    """Load REPO_ROOT/.env into os.environ (shell variables win). Returns True if found.

    interpolate=False: a value is never expanded, so a key passphrase containing '$' or
    '${...}' reaches the connector exactly as typed. Unquoted values still lose anything
    after ' #' (a comment), which is why .env.example asks for the passphrase in single
    quotes.
    """
    try:
        from dotenv import load_dotenv
    except ImportError as exc:  # pragma: no cover - only without `make setup`
        raise ConfigError("python-dotenv is not installed. Run 'make setup' first.") from exc
    if ENV_FILE.is_file():
        load_dotenv(ENV_FILE, override=False, interpolate=False)
        return True
    return False


def setting(name: str, *, required: bool = True) -> str | None:
    """Return a stripped setting from the environment, falling back to DEFAULTS."""
    value = os.environ.get(name, "").strip()
    if value:
        return value
    if name in DEFAULTS:
        return DEFAULTS[name]
    if not required:
        return None
    if ENV_FILE.is_file():
        where = f"Set {name} in .env"
    else:
        where = "There is no .env file yet: run 'cp .env.example .env' and fill it in"
    raise ConfigError(f"{name} is not set. {where} (see {SETUP_DOC}).")


def check_account(account: str) -> str:
    """Accept the bare identifier (ORG-ACCOUNT, or a legacy locator); reject URLs."""
    lowered = account.lower()
    if "://" in account or "snowflakecomputing.com" in lowered or "/" in account:
        raise ConfigError(
            "SNOWFLAKE_ACCOUNT must be the bare account identifier, e.g. MYORG-MYACCOUNT, "
            "without https:// and without .snowflakecomputing.com."
        )
    if not re.fullmatch(r"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*", account):
        raise ConfigError(
            "SNOWFLAKE_ACCOUNT contains unexpected characters; expected something like MYORG-MYACCOUNT."
        )
    return account


def inspect_private_key(
    path_value: str, var_name: str, passphrase: str | None, *, allow_encrypted: bool = True
) -> KeyInfo:
    """Validate a PEM private key file locally and compute its public-key fingerprint.

    allow_encrypted=False is for the BI key: the Data Studio connector rejects encrypted keys.
    Raises ConfigError with a printable message. Never returns or prints key material.
    """
    if path_value.startswith("~"):
        raise ConfigError(
            f"{var_name} starts with '~'. Use the absolute path instead "
            f"({Path(path_value).expanduser()}): dbt does not expand '~'."
        )
    path = Path(path_value)
    if not path.is_absolute():
        raise ConfigError(f"{var_name} must be an absolute path (got a relative path).")
    if not path.is_file():
        raise ConfigError(
            f"{var_name} points to {path}, which does not exist. Run 'make keys' or fix the path."
        )
    warnings = []
    if path.stat().st_mode & 0o077:
        warnings.append(f"{path.name} is readable by other users; run: chmod 600 {path}")

    data = path.read_bytes()
    first_line = data.split(b"\n", 1)[0].strip()
    if b"PUBLIC KEY" in first_line:
        raise ConfigError(f"{var_name} points to a PUBLIC key ({path.name}); use the .p8 private key.")
    encrypted = first_line == b"-----BEGIN ENCRYPTED PRIVATE KEY-----"
    if not encrypted and first_line not in (
        b"-----BEGIN PRIVATE KEY-----",
        b"-----BEGIN RSA PRIVATE KEY-----",
    ):
        raise ConfigError(f"{var_name}: {path.name} is not a PEM private key (unexpected first line).")
    if encrypted and not allow_encrypted:
        raise ConfigError(
            f"{path.name} is an ENCRYPTED key, but the Google Data Studio connector only accepts "
            "unencrypted keys. Generate the BI key with 'make keys' (it is always -nocrypt)."
        )
    if encrypted and not passphrase:
        raise ConfigError(
            f"{path.name} is encrypted but SNOWFLAKE_PRIVATE_KEY_PASSPHRASE is empty. "
            "Set it in .env (or in your shell)."
        )
    if passphrase and not encrypted:
        warnings.append(f"{path.name} is not encrypted; the passphrase setting is ignored.")

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    try:
        key = serialization.load_pem_private_key(
            data, password=passphrase.encode("utf-8") if encrypted and passphrase else None
        )
    except (TypeError, ValueError) as exc:
        reason = "wrong passphrase?" if encrypted else "corrupt or unsupported key file"
        raise ConfigError(f"Could not load {path.name} ({reason}): {type(exc).__name__}.") from None
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ConfigError(f"{path.name} is not an RSA key; Snowflake key-pair auth needs RSA >= 2048 bits.")
    if key.key_size < 2048:
        raise ConfigError(f"{path.name} is a {key.key_size}-bit key; Snowflake requires at least 2048 bits.")
    spki = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(spki).digest()).decode("ascii")
    return KeyInfo(path, encrypted, key.key_size, fingerprint, tuple(warnings))


@dataclass(frozen=True)
class ConnectionSettings:
    account: str
    user: str
    role: str
    warehouse: str
    database: str
    schema: str | None
    key: KeyInfo
    passphrase: str | None  # kept out of repr below

    def __repr__(self) -> str:  # never show the passphrase
        return (
            f"ConnectionSettings(account={self.account!r}, user={self.user!r}, role={self.role!r}, "
            f"warehouse={self.warehouse!r}, database={self.database!r}, schema={self.schema!r}, "
            f"key={self.key.path.name!r})"
        )


def resolve_settings(
    *,
    role: str,
    user_var: str = "SNOWFLAKE_USER",
    key_var: str = "SNOWFLAKE_PRIVATE_KEY_PATH",
    passphrase_var: str | None = "SNOWFLAKE_PRIVATE_KEY_PASSPHRASE",
    schema: str | None = None,
    allow_encrypted: bool = True,
) -> ConnectionSettings:
    """Read and validate everything needed to connect. Raises ConfigError."""
    account = check_account(setting("SNOWFLAKE_ACCOUNT"))
    user = setting(user_var)
    key_path = setting(key_var)
    passphrase = os.environ.get(passphrase_var, "") if passphrase_var else ""
    key = inspect_private_key(key_path, key_var, passphrase or None, allow_encrypted=allow_encrypted)
    return ConnectionSettings(
        account=account,
        user=user,
        role=role,
        warehouse=setting("SNOWFLAKE_WAREHOUSE"),
        database=setting("SNOWFLAKE_DATABASE"),
        schema=schema,
        key=key,
        passphrase=passphrase or None,
    )


def connect(settings: ConnectionSettings, *, tool: str, numbers_as_decimal: bool = False):
    """Open a key-pair connection. Raises ConnectError with a printable message.

    numbers_as_decimal=True returns NUMBER columns with a scale as decimal.Decimal, exactly as
    stored. By default the connector's Arrow result path turns them into float, which is fine
    for printing but not for exports that must reproduce every digit (scripts/export_marts.py).
    """
    import snowflake.connector
    from snowflake.connector.errors import Error as SnowflakeError

    params: dict[str, Any] = {
        "account": settings.account,
        "user": settings.user,
        "authenticator": "SNOWFLAKE_JWT",
        "private_key_file": str(settings.key.path),
        "role": settings.role,
        "warehouse": settings.warehouse,
        "database": settings.database,
        "session_parameters": {"QUERY_TAG": f"marketing-crm:{tool}"},
        "login_timeout": 60,
    }
    if settings.key.encrypted:
        params["private_key_file_pwd"] = settings.passphrase
    if numbers_as_decimal:
        params["arrow_number_to_decimal"] = True
    if settings.schema:
        params["schema"] = settings.schema
    try:
        return snowflake.connector.connect(**params)
    except SnowflakeError as exc:
        raise ConnectError(describe_error(exc, settings)) from None


def describe_error(exc: Exception, settings: ConnectionSettings | None = None) -> str:
    """One readable block for a connector error, with hints for the common cases."""
    errno = getattr(exc, "errno", None)
    sqlstate = getattr(exc, "sqlstate", None)
    msg = (getattr(exc, "raw_msg", None) or getattr(exc, "msg", None) or str(exc)).strip()
    lines = [f"Snowflake error {errno} ({sqlstate}): {msg}"]
    lines += ERROR_HINTS.get(errno, [])
    if settings is not None:
        lines.append(
            f"Tried: account={settings.account} user={settings.user} role={settings.role} "
            f"key={settings.key.path.name} ({settings.key.fingerprint})"
        )
    return "\n".join(lines)


def split_sql(text: str) -> list[str]:
    """Split SQL text into statements with the connector's splitter (comments removed)."""
    from snowflake.connector.util_text import split_statements

    statements = []
    for statement, _is_put_get in split_statements(io.StringIO(text), remove_comments=True):
        statement = statement.strip()
        if statement and statement != ";":
            statements.append(statement)
    return statements


def run_sql_file(
    conn,
    path: Path,
    *,
    on_result: Callable[[StatementResult], None] | None = None,
) -> list[StatementResult]:
    """Execute every statement of a .sql file in order and return their results.

    Stops at the first failing statement and raises SqlFileError naming it.
    """
    from snowflake.connector.errors import Error as SnowflakeError

    text = Path(path).read_text(encoding="utf-8")
    results = []
    for index, sql in enumerate(split_sql(text), start=1):
        cur = conn.cursor()
        try:
            cur.execute(sql)
            columns = [col.name for col in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
        except SnowflakeError as exc:
            first = first_line(sql)
            raise SqlFileError(
                f"{Path(path).name}, statement {index} failed: {first}\n{describe_error(exc)}"
            ) from None
        finally:
            cur.close()
        result = StatementResult(index, sql, cur.sfqid, columns, rows)
        results.append(result)
        if on_result:
            on_result(result)
    return results


def first_line(sql: str, width: int = 100) -> str:
    """The first non-empty line of a statement, shortened for log output."""
    line = next((ln.strip() for ln in sql.splitlines() if ln.strip()), "")
    return line if len(line) <= width else line[: width - 3] + "..."
