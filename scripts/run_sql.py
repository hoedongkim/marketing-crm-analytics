#!/usr/bin/env python3
"""Run a multi-statement .sql file in Snowflake as the pipeline user with a given role.

    python scripts/run_sql.py --role CRM_TRANSFORMER sql/setup/03_connection_test.sql
    python scripts/run_sql.py --role CRM_LOADER sql/setup/02_raw_load_checks.sql
    python scripts/run_sql.py --dry-run sql/setup/01_raw_objects.sql   # offline: show the split

Connects as SVC_CRM_PIPELINE (key pair, settings from .env), executes the statements in
order with the connector's splitter (comments removed, quoted strings and $$ blocks kept),
prints each statement's first line and its result (up to --max-rows rows), and stops with
exit code 1 at the first failing statement. A USE ROLE inside the file takes effect from
that statement on, exactly as in a Snowsight worksheet.

Check rows: any result column named STATUS (case-insensitive) whose value is exactly
'FAIL' counts as a failed check. After all statements ran, the script prints
"FAIL  <file>: N check row(s) FAIL" and exits 1 if there was at least one, so a
reconciliation file such as 02_raw_load_checks.sql or the check at the end of
03_connection_test.sql fails the command, not just its printed output. Other STATUS
values (PASS, LOADED, "Statement executed successfully.") are not judged.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sfconn  # noqa: E402


def print_result(result: sfconn.StatementResult, max_rows: int) -> None:
    print(f"[{result.index:>2}] {sfconn.first_line(result.sql)}")
    if not result.columns:
        return
    # A one-cell status result ("Statement executed successfully.") is shown inline.
    if len(result.columns) == 1 and len(result.rows) == 1 and result.columns[0].lower() == "status":
        print(f"     {result.rows[0][0]}")
        return
    shown = result.rows[:max_rows]
    cells = [[("NULL" if v is None else str(v)) for v in row] for row in shown]
    widths = [min(40, max([len(c)] + [len(r[i]) for r in cells])) for i, c in enumerate(result.columns)]
    print("     " + "  ".join(c[:w].ljust(w) for c, w in zip(result.columns, widths)))
    for row in cells:
        print("     " + "  ".join(v[:w].ljust(w) for v, w in zip(row, widths)))
    if len(result.rows) > max_rows:
        print(f"     ... {len(result.rows) - max_rows} more rows")


def count_failed_checks(result: sfconn.StatementResult) -> int:
    """Rows whose STATUS column (case-insensitive name) is exactly 'FAIL'."""
    positions = [i for i, name in enumerate(result.columns) if name.strip().upper() == "STATUS"]
    return sum(
        1
        for row in result.rows
        if any(str(row[i]).strip().upper() == "FAIL" for i in positions if i < len(row))
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run a .sql file in Snowflake (pipeline user).")
    parser.add_argument("sql_file", type=Path)
    parser.add_argument("--role", help="role to connect with, e.g. CRM_LOADER or CRM_TRANSFORMER")
    parser.add_argument("--max-rows", type=int, default=50, help="rows to print per result (default 50)")
    parser.add_argument("--dry-run", action="store_true",
                        help="only split the file and print the statements (no connection)")
    args = parser.parse_args(argv)

    path = args.sql_file if args.sql_file.is_absolute() else Path.cwd() / args.sql_file
    if not path.is_file():
        print(f"FAIL  {args.sql_file}: no such file")
        return 2
    try:
        statements = sfconn.split_sql(path.read_text(encoding="utf-8"))
    except ImportError:
        print("FAIL  snowflake-connector-python is not installed. Run 'make setup' first.")
        return 2

    if args.dry_run:
        print(f"{path.name}: {len(statements)} statements")
        for i, sql in enumerate(statements, start=1):
            print(f"[{i:>2}] {sfconn.first_line(sql)}")
        return 0

    if not args.role:
        print("FAIL  --role is required unless --dry-run is given")
        return 2
    role = args.role.upper()
    for sql in statements:
        match = re.match(r"USE\s+ROLE\s+(\w+)", sql, flags=re.IGNORECASE)
        if match and match.group(1).upper() != role:
            print(f"WARN  {path.name} switches to role {match.group(1).upper()} (connected as {role})")

    try:
        sfconn.load_env()
        settings = sfconn.resolve_settings(role=role)
        conn = sfconn.connect(settings, tool=f"run_sql:{path.stem}")
    except (sfconn.ConfigError, sfconn.ConnectError) as exc:
        print(f"FAIL  {exc}")
        return 2

    print(f"Running {path.name} ({len(statements)} statements) as {settings.user} / {role}")
    failed_checks: list[tuple[int, int]] = []  # (statement index, FAIL rows)

    def on_result(result: sfconn.StatementResult) -> None:
        print_result(result, args.max_rows)
        n_fail = count_failed_checks(result)
        if n_fail:
            failed_checks.append((result.index, n_fail))
            print(f"     ^ {n_fail} check row(s) with STATUS = FAIL")

    try:
        sfconn.run_sql_file(conn, path, on_result=on_result)
    except sfconn.SqlFileError as exc:
        print(f"FAIL  {exc}")
        return 1
    finally:
        conn.close()
    if failed_checks:
        total = sum(n for _, n in failed_checks)
        where = ", ".join(f"statement {i}" for i, _ in failed_checks)
        print(f"FAIL  {path.name}: {total} check row(s) FAIL ({where}); "
              f"all {len(statements)} statements executed")
        return 1
    print(f"OK    {path.name}: all {len(statements)} statements executed, no check row says FAIL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
