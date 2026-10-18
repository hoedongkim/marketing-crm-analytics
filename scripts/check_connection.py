#!/usr/bin/env python3
"""Check the Snowflake setup end to end, after the admin bootstrap and before loading.

    python scripts/check_connection.py           # make sf-check
    python scripts/check_connection.py --bi      # make sf-check-bi

Pipeline user (SVC_CRM_PIPELINE, role CRM_LOADER, key pair):
  session identity, account identifier vs .env, secondary roles (reported, then pinned
  to NONE so no other role's privileges leak into the checks), warehouse settings from SHOW WAREHOUSES
  (X-Small, auto-suspend 60, auto-resume, resource monitor, Gen1 / QAS off where those
  columns exist), that the warehouse can run a query, the loader's RAW privileges, that
  CRM_TRANSFORMER can be used and sees RAW, STAGING and MART, and that RAW tables
  created by the loader are readable by the transformer (future grants).
--bi additionally connects as SVC_CRM_BI with CRM_REPORTER and confirms it can see MART
  but NOT RAW (a SELECT on RAW must fail).

Prints PASS / FAIL / WARN / INFO lines and exits 1 if any check failed (2 if the
configuration is missing or the connection is refused).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sfconn  # noqa: E402  (stdlib-only at import time)

ADMIN_ROLES = {"ACCOUNTADMIN", "ORGADMIN", "SECURITYADMIN", "SYSADMIN", "USERADMIN"}
DATABASE = "MARKETING_CRM"
WAREHOUSE_MONITOR = "RM_MARKETING_WH"
# A small query that needs a running warehouse and has an exact, deterministic answer.
WAREHOUSE_QUERY = (
    "SELECT COUNT(*), MAX(RN) FROM ("
    "SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS RN FROM TABLE(GENERATOR(ROWCOUNT => 1000)))"
)


class Report:
    def __init__(self) -> None:
        self.failures = 0
        self.warnings = 0

    def line(self, status: str, name: str, detail: str = "") -> None:
        print(f"{status:<5} {name}" + (f": {detail}" if detail else ""))

    def ok(self, name: str, detail: str = "") -> None:
        self.line("PASS", name, detail)

    def fail(self, name: str, detail: str = "") -> None:
        self.failures += 1
        self.line("FAIL", name, detail)

    def warn(self, name: str, detail: str = "") -> None:
        self.warnings += 1
        self.line("WARN", name, detail)

    def info(self, name: str, detail: str = "") -> None:
        self.line("INFO", name, detail)

    def check(self, condition: bool, name: str, ok_detail: str, fail_detail: str) -> bool:
        (self.ok if condition else self.fail)(name, ok_detail if condition else fail_detail)
        return condition


def rows_as_dicts(cur) -> list[dict[str, object]]:
    names = [col.name.lower() for col in cur.description] if cur.description else []
    return [dict(zip(names, row)) for row in cur.fetchall()]


def json_list(value: object) -> list[str]:
    try:
        parsed = json.loads(str(value))
    except (TypeError, ValueError):
        return []
    return [str(v).upper() for v in parsed] if isinstance(parsed, list) else []


def norm_account(value: str) -> str:
    return value.strip().upper().replace("_", "-")


def session_info(cur) -> dict[str, object]:
    cur.execute(
        "SELECT CURRENT_ACCOUNT(), CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME(), "
        "CURRENT_REGION(), CURRENT_USER(), CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), "
        "CURRENT_AVAILABLE_ROLES(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA(), "
        "CURRENT_VERSION()"
    )
    keys = ("account_locator", "org_account", "region", "user", "role", "secondary_roles",
            "available_roles", "warehouse", "database", "schema", "version")
    return dict(zip(keys, cur.fetchone()))


def secondary_roles_empty(value: object) -> bool:
    """CURRENT_SECONDARY_ROLES() returns JSON like {"roles":"","value":""} when none are active."""
    try:
        parsed = json.loads(str(value))
    except (TypeError, ValueError):
        return False
    return isinstance(parsed, dict) and not parsed.get("roles") and not parsed.get("value")


def report_secondary_roles(rep: Report, cur, value: object, prefix: str = "") -> None:
    """Report the login default, then pin secondary roles to NONE for the rest of the checks.

    DEFAULT_SECONDARY_ROLES = () is only a login default. If it is not in effect, the
    privileges of every other granted role would leak into the checks below (for example
    the RAW -> transformer future-grant check would pass through CRM_LOADER), so the
    session is pinned to its primary role exactly like the SQL files do.
    """
    if secondary_roles_empty(value):
        rep.ok(f"{prefix}secondary roles", "none active at login (DEFAULT_SECONDARY_ROLES = ())")
    else:
        rep.warn(f"{prefix}secondary roles",
                 f"active at login: {value}; expected none (re-run bootstrap section 5). "
                 "Pinned to NONE for these checks")
    cur.execute("USE SECONDARY ROLES NONE")


def schema_names(cur) -> set[str]:
    cur.execute(f"SHOW SCHEMAS IN DATABASE {DATABASE}")
    return {str(r.get("name")).upper() for r in rows_as_dicts(cur)}


def table_names(cur, schema: str) -> set[str]:
    cur.execute(f"SHOW TABLES IN SCHEMA {DATABASE}.{schema}")
    return {str(r.get("name")).upper() for r in rows_as_dicts(cur)}


def check_grants(rep: Report, cur, role: str, expected: list[tuple[str, str, str]]) -> None:
    """expected: (privilege, granted_on, name). Tolerant: a refused SHOW is only a warning."""
    from snowflake.connector.errors import Error as SnowflakeError

    try:
        cur.execute(f"SHOW GRANTS TO ROLE {role}")
        grants = {
            (str(r.get("privilege")).upper(), str(r.get("granted_on")).upper(),
             str(r.get("name")).upper().replace('"', ""))
            for r in rows_as_dicts(cur)
        }
    except SnowflakeError as exc:
        rep.warn(f"{role} grants", f"SHOW GRANTS refused ({exc.errno}); skipped")
        return
    missing = [e for e in expected if e not in grants]
    rep.check(
        not missing, f"{role} privileges",
        ", ".join(f"{p} on {o.lower()} {n}" for p, o, n in expected),
        "missing " + "; ".join(f"{p} on {o.lower()} {n}" for p, o, n in missing)
        + " (re-run sections 3-4 of build/snowflake_bootstrap.sql)",
    )


def check_pipeline(rep: Report, skip_warehouse_query: bool) -> dict[str, object]:
    """Checks as SVC_CRM_PIPELINE. Returns facts the BI checks reuse."""
    from snowflake.connector.errors import Error as SnowflakeError

    facts: dict[str, object] = {}
    loader = sfconn.setting("SNOWFLAKE_LOADER_ROLE")
    transformer = sfconn.setting("SNOWFLAKE_TRANSFORMER_ROLE")
    warehouse = sfconn.setting("SNOWFLAKE_WAREHOUSE")
    settings = sfconn.resolve_settings(role=loader, schema="RAW")
    kind = "encrypted" if settings.key.encrypted else "unencrypted"
    rep.ok("config", f"account {settings.account}, user {settings.user}, key {settings.key.path.name} "
                     f"({kind}, RSA {settings.key.bits}, {settings.key.fingerprint})")
    for warning in settings.key.warnings:
        rep.warn("key file", warning)

    conn = sfconn.connect(settings, tool="check_connection")
    try:
        cur = conn.cursor()
        s = session_info(cur)
        rep.ok("connect", f"key-pair login as {s['user']} with role {s['role']}")
        rep.info("session", f"org-account {s['org_account']}, locator {s['account_locator']}, "
                            f"region {s['region']}, Snowflake {s['version']}")
        if norm_account(str(s["org_account"])) == norm_account(settings.account):
            rep.ok("account identifier", f".env SNOWFLAKE_ACCOUNT matches {s['org_account']}")
        else:
            rep.warn("account identifier",
                     f".env has {settings.account}, the preferred form is {s['org_account']}")
        rep.check(str(s["role"]).upper() == loader, "role", loader, f"got {s['role']}, expected {loader}")
        rep.check(str(s["warehouse"] or "").upper() == warehouse, "warehouse in use", warehouse,
                  f"got {s['warehouse']}; does {loader} have USAGE on {warehouse}?")
        rep.check(str(s["database"] or "").upper() == DATABASE, "database in use", DATABASE,
                  f"got {s['database']}; does {loader} have USAGE on {DATABASE}?")
        report_secondary_roles(rep, cur, s["secondary_roles"])

        available = set(json_list(s["available_roles"]))
        rep.check({loader, transformer} <= available, "available roles", ", ".join(sorted(available)),
                  f"{sorted(available)} lacks {sorted({loader, transformer} - available)}")
        admin = sorted(available & ADMIN_ROLES)
        rep.check(not admin, "no admin roles", "the service user holds no system/admin role",
                  f"{admin} granted to {settings.user}; revoke them")

        # Warehouse configuration (SHOW does not resume the warehouse).
        cur.execute(f"SHOW WAREHOUSES LIKE '{warehouse}'")
        whs = rows_as_dicts(cur)
        if not whs:
            rep.fail("warehouse", f"SHOW WAREHOUSES LIKE '{warehouse}' returned nothing")
        else:
            wh = whs[0]
            size = str(wh.get("size", "")).upper().replace("-", "")
            rep.check(size == "XSMALL", "warehouse size", str(wh.get("size")), f"{wh.get('size')} (expected X-Small)")
            rep.check(str(wh.get("type", "")).upper() == "STANDARD", "warehouse type", "STANDARD",
                      f"{wh.get('type')} (expected STANDARD)")
            rep.check(str(wh.get("auto_suspend")) == "60", "auto_suspend", "60 s",
                      f"{wh.get('auto_suspend')} (expected 60)")
            rep.check(str(wh.get("auto_resume")).lower() == "true", "auto_resume", "true",
                      f"{wh.get('auto_resume')} (expected true)")
            monitor = str(wh.get("resource_monitor") or "null")
            if monitor.upper() == WAREHOUSE_MONITOR:
                rep.ok("resource monitor", monitor)
            else:
                rep.warn("resource monitor",
                         f"{monitor} as seen by {loader}; expected {WAREHOUSE_MONITOR}. Verify as "
                         f"ACCOUNTADMIN with SHOW WAREHOUSES (bootstrap section 6)")
            if "generation" in wh:
                gen = str(wh["generation"])
                (rep.ok if gen == "1" else rep.warn)("generation", f"{gen} (expected 1: Gen2 bills more)")
            if "resource_constraint" in wh:
                rc = str(wh["resource_constraint"] or "")
                if rc.upper() in ("STANDARD_GEN_1", "", "NULL", "NONE"):
                    rep.ok("resource_constraint", rc or "(empty)")
                else:
                    rep.warn("resource_constraint", f"{rc} (expected STANDARD_GEN_1)")
            if "generation" not in wh and "resource_constraint" not in wh:
                rep.info("generation", "SHOW WAREHOUSES has no generation column here")
            if "enable_query_acceleration" in wh:
                qas = str(wh["enable_query_acceleration"]).lower()
                (rep.ok if qas == "false" else rep.warn)(
                    "query acceleration", f"{qas}" + ("" if qas == "false" else
                    " (serverless credits not capped by resource monitors; set it to FALSE)"))
            rep.info("warehouse state", str(wh.get("state")))

        if skip_warehouse_query:
            rep.info("warehouse query", "skipped (--no-warehouse-query)")
        else:
            # Needs compute: resumes the warehouse for at most ~60 s of X-Small (1/60 credit).
            # The result cache is off for this session so a re-run really uses the warehouse.
            # ROW_NUMBER is gap-free (SEQ4 alone is not guaranteed to be), so the expected
            # result is exact: 1000 rows, highest row number 1000.
            cur.execute("ALTER SESSION SET USE_CACHED_RESULT = FALSE")
            row = cur.execute(WAREHOUSE_QUERY).fetchone()
            rep.check(tuple(int(v) for v in row) == (1000, 1000), "warehouse query",
                      f"{warehouse} resumed and ran a query", f"unexpected result {row}, expected (1000, 1000)")

        # Loader privileges and RAW visibility.
        check_grants(rep, cur, loader, [
            ("USAGE", "WAREHOUSE", warehouse),
            ("USAGE", "DATABASE", DATABASE),
            ("USAGE", "SCHEMA", f"{DATABASE}.RAW"),
            ("CREATE TABLE", "SCHEMA", f"{DATABASE}.RAW"),
            ("CREATE STAGE", "SCHEMA", f"{DATABASE}.RAW"),
            ("CREATE FILE FORMAT", "SCHEMA", f"{DATABASE}.RAW"),
        ])
        loader_schemas = schema_names(cur)
        rep.check("RAW" in loader_schemas, f"{loader} sees schema RAW", "yes",
                  f"visible: {sorted(loader_schemas)}")
        loader_tables = table_names(cur, "RAW") if "RAW" in loader_schemas else set()
        rep.info("RAW tables", f"{len(loader_tables)} ({', '.join(sorted(loader_tables)) or 'none yet: run make load'})")

        # Transformer: same session, switch role.
        try:
            cur.execute(f"USE ROLE {transformer}")
            rep.ok(f"USE ROLE {transformer}", "granted to the pipeline user")
        except SnowflakeError as exc:
            rep.fail(f"USE ROLE {transformer}", sfconn.describe_error(exc))
            return facts
        schemas = schema_names(cur)
        missing = {"RAW", "STAGING", "MART"} - schemas
        rep.check(not missing, "schemas", f"RAW, STAGING, MART visible to {transformer}",
                  f"missing {sorted(missing)} (bootstrap section 1/3)")
        check_grants(rep, cur, transformer, [
            ("USAGE", "SCHEMA", f"{DATABASE}.RAW"),
            ("CREATE TABLE", "SCHEMA", f"{DATABASE}.STAGING"),
            ("CREATE VIEW", "SCHEMA", f"{DATABASE}.STAGING"),
            ("CREATE TABLE", "SCHEMA", f"{DATABASE}.MART"),
            ("CREATE VIEW", "SCHEMA", f"{DATABASE}.MART"),
        ])
        if loader_tables:
            visible = table_names(cur, "RAW")
            rep.check(loader_tables <= visible, "future grants RAW -> transformer",
                      f"{transformer} can read all {len(loader_tables)} RAW tables",
                      f"not readable by {transformer}: {sorted(loader_tables - visible)}")
        mart_tables = table_names(cur, "MART") if "MART" in schemas else set()
        facts["connection_test_exists"] = "CONNECTION_TEST" in mart_tables
        rep.info("MART tables", ", ".join(sorted(mart_tables)) or "none yet")
    finally:
        conn.close()
    return facts


def check_bi(rep: Report, facts: dict[str, object]) -> None:
    from snowflake.connector.errors import Error as SnowflakeError

    reporter = sfconn.setting("SNOWFLAKE_REPORTER_ROLE")
    warehouse = sfconn.setting("SNOWFLAKE_WAREHOUSE")
    settings = sfconn.resolve_settings(
        role=reporter,
        user_var="SNOWFLAKE_BI_USER",
        key_var="SNOWFLAKE_BI_PRIVATE_KEY_PATH",
        passphrase_var=None,
        schema="MART",
        allow_encrypted=False,
    )
    rep.ok("BI config", f"user {settings.user}, key {settings.key.path.name} "
                        f"(unencrypted, RSA {settings.key.bits}, {settings.key.fingerprint})")
    for warning in settings.key.warnings:
        rep.warn("BI key file", warning)
    conn = sfconn.connect(settings, tool="check_connection:bi")
    try:
        cur = conn.cursor()
        s = session_info(cur)
        rep.ok("BI connect", f"key-pair login as {s['user']} with role {s['role']}")
        report_secondary_roles(rep, cur, s["secondary_roles"], prefix="BI ")
        rep.check(str(s["role"]).upper() == reporter, "BI role", reporter, f"got {s['role']}")
        rep.check(str(s["warehouse"] or "").upper() == warehouse, "BI warehouse", warehouse,
                  f"got {s['warehouse']}; does {reporter} have USAGE on {warehouse}?")
        available = set(json_list(s["available_roles"])) - {"PUBLIC"}
        extra_hint = ""
        if "SNOWFLAKE_LEARNING_ROLE" in available:
            extra_hint = ("; SNOWFLAKE_LEARNING_ROLE comes from the trial granting it to PUBLIC: "
                          "re-run build/snowflake_bootstrap.sql (section 6 revokes it)")
        rep.check(available == {reporter}, "BI roles", f"only {reporter} (+ PUBLIC)",
                  f"{sorted(available)}: the BI user should hold {reporter} only{extra_hint}")

        schemas = schema_names(cur)
        rep.check("MART" in schemas, "BI sees MART", "yes", f"visible: {sorted(schemas)}")
        hidden = {"RAW", "STAGING"} & schemas
        rep.check(not hidden, "BI cannot see RAW/STAGING", "neither is visible",
                  f"{sorted(hidden)} visible to {reporter}")

        try:
            cur.execute(f"SELECT COUNT(*) FROM {DATABASE}.RAW.CAMPAIGNS")
            rep.fail("BI blocked from RAW", f"{reporter} could read RAW.CAMPAIGNS; revoke that grant")
        except SnowflakeError as exc:
            if exc.errno == 2003:  # object does not exist or not authorized
                rep.ok("BI blocked from RAW", "SELECT on RAW.CAMPAIGNS fails as expected (002003)")
            else:
                rep.warn("BI blocked from RAW", f"SELECT failed with an unexpected error: {exc.errno} {exc.raw_msg}")

        try:
            n = cur.execute(f"SELECT COUNT(*) FROM {DATABASE}.MART.CONNECTION_TEST").fetchone()[0]
            rep.ok("BI reads MART", f"MART.CONNECTION_TEST has {n} rows")
        except SnowflakeError as exc:
            if facts.get("connection_test_exists"):
                rep.fail("BI reads MART", f"MART.CONNECTION_TEST exists but {reporter} cannot read it "
                                          f"({exc.errno}); check the MART future grants (bootstrap section 4)")
            else:
                rep.info("BI reads MART", "MART.CONNECTION_TEST not built yet: run make connection-test-table")
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check the Snowflake setup (make sf-check).")
    parser.add_argument("--bi", action="store_true", help="also check SVC_CRM_BI / CRM_REPORTER")
    parser.add_argument("--no-warehouse-query", action="store_true",
                        help="skip the query that resumes the warehouse")
    args = parser.parse_args(argv)

    rep = Report()
    try:
        found = sfconn.load_env()
        if found:
            rep.info(".env", str(sfconn.ENV_FILE))
        else:
            rep.info(".env", "not found; using shell environment variables only")
        facts = check_pipeline(rep, args.no_warehouse_query)
        if args.bi:
            print()
            check_bi(rep, facts)
    except sfconn.ConfigError as exc:
        rep.fail("config", str(exc))
        return 2
    except sfconn.ConnectError as exc:
        rep.fail("connect", str(exc))
        return 2
    except ImportError as exc:
        rep.fail("python environment", f"{exc}. Run 'make setup' first.")
        return 2
    except Exception as exc:  # a Snowflake error in the middle of a check
        if type(exc).__module__.startswith("snowflake.connector"):
            rep.fail("query", sfconn.describe_error(exc))
            return 1
        raise

    print()
    if rep.failures:
        print(f"FAIL  {rep.failures} check(s) failed, {rep.warnings} warning(s). "
              "See docs/setup_snowflake.md (Troubleshooting).")
        return 1
    print(f"PASS  all checks passed ({rep.warnings} warning(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
