#!/usr/bin/env python3
"""Load the dataset CSVs into MARKETING_CRM.RAW and prove the landing is lossless.

    python scripts/load_raw.py --dataset source              # make load
    python scripts/load_raw.py --dataset challenge           # make load-challenge
    python scripts/load_raw.py --dataset source --dry-run    # offline, no Snowflake

(a) Local verification, standard library only: pinned SHA-256, UTF-8, LF line endings,
    exact header, the same field count on every record. Then LOCAL CONTROL TOTALS with
    csv + decimal.Decimal: rows, distinct primary keys, per-column empty-string counts,
    per-column total character length (catches lost or added whitespace), and for the
    source release the numeric sums (budget, impressions, clicks, spend, lead_score,
    revenue) and the purchase count, which must equal the values profiled on 2026-10-13.
(b) Unless --dry-run: connect as CRM_LOADER (SVC_CRM_PIPELINE, key pair), run
    sql/setup/01_raw_objects.sql, PUT each file to @MARKETING_CRM.RAW.CRM_STAGE/<prefix>/,
    pre-check every staged record's field count, then TRUNCATE + COPY each table with
    lineage columns (_SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT).
(c) REMOTE CONTROL TOTALS computed in Snowflake SQL, compared EXACTLY with (a). Prints a
    table, writes build/load_report_<dataset>.json, exits non-zero on any mismatch.

--dry-run runs (a) and prints the SQL that (b) and (c) would run. It never imports the
Snowflake connector or reads .env, so it works offline.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RAW_OBJECTS_SQL = REPO_ROOT / "sql" / "setup" / "01_raw_objects.sql"
BUILD_DIR = REPO_ROOT / "build"

STAGE = "@MARKETING_CRM.RAW.CRM_STAGE"
FILE_FORMAT = "MARKETING_CRM.RAW.FF_CSV_LOSSLESS"
RAW_SCHEMA = "MARKETING_CRM.RAW"

# --------------------------------------------------------------------------------------
# SQL templates (everything (b) and (c) send to Snowflake, apart from 01_raw_objects.sql)
# --------------------------------------------------------------------------------------

# PUT runs from a driver, not from Snowsight. The file:// path is quoted so a path with
# spaces still works. It must not contain glob characters (* ? [ ]): the connector passes
# every PUT source through glob.glob(), so such a path would match nothing or the wrong
# files. A single quote or a backslash would break or alter the quoted SQL literal.
# check_put_paths() refuses all of these before anything is sent to Snowflake.
# AUTO_COMPRESS gzips the upload (stage file <name>.csv.gz); OVERWRITE replaces an
# earlier upload of the same name.
PUT_SQL = "PUT '{file_uri}' {stage}/{prefix}/ AUTO_COMPRESS = TRUE OVERWRITE = TRUE"

# Field-count pre-check on the staged file, BEFORE any table is truncated.
# Why it is needed: ERROR_ON_COLUMN_COUNT_MISMATCH is ignored by a COPY with a SELECT
# transform (the loader needs one for the lineage columns), so a short or long record
# would load silently. Why the check is correct: with EMPTY_FIELD_AS_NULL = FALSE and
# NULL_IF = (), an empty field comes back as '' and no text value comes back as NULL.
# So positional column $k is NULL only when the record has fewer than k fields:
#   $N IS NULL         -> fewer than N fields (an empty LAST field is '', not NULL)
#   $(N+1) IS NOT NULL -> more than N fields (an extra empty field is '', still not NULL)
# A record is well-formed iff $N IS NOT NULL AND $(N+1) IS NULL. The record count must
# also equal the local count (SKIP_HEADER = 1 drops the header).
PRECHECK_SQL = """\
SELECT METADATA$FILENAME AS FILE_NAME,
       COUNT(*) AS N_RECORDS,
       COUNT_IF(t.${n} IS NULL OR t.${n_plus_1} IS NOT NULL) AS N_WRONG_FIELD_COUNT
FROM {stage}/{prefix}/{staged_name} (FILE_FORMAT => '{file_format}') t
GROUP BY 1"""

# Full refresh. TRUNCATE also clears the table's load metadata, so the COPY below loads
# the re-uploaded file again without FORCE = TRUE.
TRUNCATE_SQL = "TRUNCATE TABLE IF EXISTS {raw_schema}.{table}"

COPY_SQL = """\
COPY INTO {raw_schema}.{table} ({column_list}, _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT)
FROM (
  SELECT {positional_list},
         METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
  FROM {stage}/{prefix}/ t
)
FILES = ('{staged_name}')
FILE_FORMAT = (FORMAT_NAME = '{file_format}')
ON_ERROR = ABORT_STATEMENT"""

# The remote control-totals query is generated per table by remote_totals_sql() below:
#   COUNT(*), COUNT(DISTINCT pk), and per column COUNT_IF(c = ''), COUNT_IF(c IS NULL),
#   SUM(LENGTH(c)); for the source release SUM(TO_NUMBER(c[, 12, 2])) and COUNT_IF(...);
#   plus lineage checks on _SOURCE_FILE / _SOURCE_ROW_NUMBER / _LOADED_AT.

# --------------------------------------------------------------------------------------
# Dataset definitions
# --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TableSpec:
    name: str  # file stem and table suffix, e.g. "daily_spend"
    columns: tuple[str, ...]  # header, in file order
    pk: str
    sums: tuple[tuple[str, str], ...] = ()  # (column, "int" | "dec2")
    value_counts: tuple[tuple[str, str], ...] = ()  # (column, value)

    @property
    def file_name(self) -> str:
        return f"{self.name}.csv"


TABLES = (
    TableSpec(
        "campaigns",
        ("campaign_id", "campaign_name", "channel", "objective", "start_date", "end_date", "budget"),
        pk="campaign_id",
        sums=(("budget", "dec2"),),
    ),
    TableSpec(
        "daily_spend",
        ("spend_id", "campaign_id", "spend_date", "impressions", "clicks", "spend"),
        pk="spend_id",
        sums=(("impressions", "int"), ("clicks", "int"), ("spend", "dec2")),
    ),
    TableSpec(
        "leads",
        ("lead_id", "campaign_id", "created_at", "lead_source", "lead_score"),
        pk="lead_id",
        sums=(("lead_score", "int"),),
    ),
    TableSpec(
        "conversions",
        ("conversion_id", "lead_id", "converted_at", "conversion_type", "revenue"),
        pk="conversion_id",
        sums=(("revenue", "dec2"),),
        value_counts=(("conversion_type", "purchase"),),
    ),
)


@dataclass(frozen=True)
class Dataset:
    key: str
    subdir: str  # under --data-dir
    stage_prefix: str
    table_prefix: str
    numeric_totals: bool  # sums + value counts (source release only)
    sha256: dict[str, str]
    expected: dict[str, dict[str, object]]
    description: str


# Expected values: profiled locally on 2026-10-13 with two independent methods (DuckDB and
# csv + Decimal) that agreed on all 1,650 compared values; row counts match the publisher
# README. SHA-256 of the source CSVs from the byte-level profile; challenge CSVs hashed
# from the checksum-verified challenge zip.
DATASETS = {
    "source": Dataset(
        key="source",
        subdir="source",
        stage_prefix="source",
        table_prefix="",
        numeric_totals=True,
        sha256={
            "campaigns": "ee8a5e842a3a100c303a4a3b40ecef3b9f3c80d8b803cc84a30e8f3ac5cd638a",
            "daily_spend": "e653b309c2209a876ca8590b41f7c8ef79e73d020594541342eba72341a7d8b5",
            "leads": "b8e48b0317f1110abe65272c9a92e98dc744d5e5179bde806dc568bdfa692761",
            "conversions": "04816bfcfa48aa15ff1198f6f19ac509022a3657cd122771d855b54d14d83598",
        },
        expected={
            "campaigns": {"rows": 120, "distinct_pk": 120, "empty_cells": 0,
                          "sum:budget": Decimal("5418642.16")},
            "daily_spend": {"rows": 11240, "distinct_pk": 11240, "empty_cells": 0,
                            "sum:impressions": Decimal("436844819"),
                            "sum:clicks": Decimal("7102319"),
                            "sum:spend": Decimal("4523050.02")},
            "leads": {"rows": 261684, "distinct_pk": 261684, "empty_cells": 0,
                      "sum:lead_score": Decimal("13233637")},
            "conversions": {"rows": 39696, "distinct_pk": 39696, "empty_cells": 0,
                            "sum:revenue": Decimal("21561839.01"),
                            "count:conversion_type=purchase": 16691},
        },
        description="clean release v1.0.0 -> RAW.CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS",
    ),
    "challenge": Dataset(
        key="challenge",
        subdir="cleaning-challenge/raw",
        stage_prefix="challenge",
        table_prefix="CHALLENGE_",
        numeric_totals=False,
        sha256={
            "campaigns": "55eccd8a78ee6481d16cbb62f3c64d464bceb7aacaa80142a36b543ece5b05db",
            "daily_spend": "25450222d97d0d0d469d72629504a42e3310a17944dd85aedaad5a155db1cc43",
            "leads": "700278cb58930eb5f335c2de3493bd6ad78070fe39a272cb98ab3ccdb888176f",
            "conversions": "ccf2deff63314e5b27f616020176c4dceb755adecd0dc6779c4e879c0078a03a",
        },
        # Each extract repeats its first data row as the last line (1 exact duplicate) and
        # has one blank required value in data row 30 (profiling p4, 2026-10-13).
        expected={
            "campaigns": {"rows": 121, "distinct_pk": 120, "empty_cells": 1},
            "daily_spend": {"rows": 2001, "distinct_pk": 2000, "empty_cells": 1},
            "leads": {"rows": 2001, "distinct_pk": 2000, "empty_cells": 1},
            "conversions": {"rows": 2001, "distinct_pk": 2000, "empty_cells": 1},
        },
        description="dirty cleaning-challenge extracts -> RAW.CHALLENGE_* (separate track, never unioned)",
    ),
}

INT_RE = re.compile(r"-?[0-9]{1,38}")
DEC2_RE = re.compile(r"-?[0-9]{1,10}(\.[0-9]{1,2})?")  # fits TO_NUMBER(x, 12, 2) exactly
MAX_PROBLEMS_PER_FILE = 10

# --------------------------------------------------------------------------------------
# (a) Local verification and control totals
# --------------------------------------------------------------------------------------


@dataclass
class LocalFile:
    spec: TableSpec
    path: Path
    size: int = 0
    sha256: str = ""
    metrics: dict[str, object] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)

    @property
    def rows(self) -> int:
        return int(self.metrics.get("rows", 0))


def metric_keys(spec: TableSpec, numeric_totals: bool) -> list[str]:
    """Every metric compared between local and Snowflake, in a stable order."""
    keys = ["rows", "distinct_pk"]
    for col in spec.columns:
        keys += [f"empty:{col}", f"null:{col}", f"chars:{col}"]
    if numeric_totals:
        keys += [f"sum:{col}" for col, _kind in spec.sums]
        keys += [f"count:{col}={value}" for col, value in spec.value_counts]
    return keys


def scan_file(spec: TableSpec, path: Path, dataset: Dataset) -> LocalFile:
    result = LocalFile(spec, path)

    def problem(message: str) -> None:
        if len(result.problems) < MAX_PROBLEMS_PER_FILE:
            result.problems.append(message)
        elif len(result.problems) == MAX_PROBLEMS_PER_FILE:
            result.problems.append("... further problems not shown")

    if not path.is_file():
        problem(f"missing: {path} (run 'make data')")
        return result
    raw = path.read_bytes()
    result.size = len(raw)
    result.sha256 = hashlib.sha256(raw).hexdigest()
    if result.sha256 != dataset.sha256[spec.name]:
        problem(f"SHA-256 {result.sha256} differs from the pinned {dataset.sha256[spec.name]}")
    if raw.startswith(b"\xef\xbb\xbf"):
        problem("starts with a UTF-8 byte-order mark (header check would fail)")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problem(f"not valid UTF-8 at byte {exc.start}")
        return result
    if "\r" in text:
        problem("contains CR characters; expected LF-only line endings (RECORD_DELIMITER = '\\n')")
    if not text.endswith("\n"):
        problem("does not end with a newline")

    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    try:
        header = next(reader)
    except StopIteration:
        problem("file is empty")
        return result
    if tuple(header) != spec.columns:
        problem(f"header {header} != expected {list(spec.columns)}")
        return result

    n = len(spec.columns)
    pk_index = spec.columns.index(spec.pk)
    sum_index = [(spec.columns.index(col), col, kind) for col, kind in spec.sums]
    count_index = [(spec.columns.index(col), col, value) for col, value in spec.value_counts]
    rows = 0
    pks: set[str] = set()
    empties = Counter()
    chars = Counter()
    sums = {col: Decimal(0) for col, _kind in spec.sums}
    counts = Counter()
    try:
        for record in reader:
            rows += 1
            line_no = rows + 1
            if reader.line_num != line_no:
                problem(f"record {rows} spans several lines (ends on line {reader.line_num})")
                line_no = reader.line_num
            if len(record) != n:
                problem(f"line {line_no}: {len(record)} fields, expected {n}")
                continue
            pks.add(record[pk_index])
            for i, value in enumerate(record):
                if value == "":
                    empties[spec.columns[i]] += 1
                chars[spec.columns[i]] += len(value)
            if dataset.numeric_totals:
                for i, col, kind in sum_index:
                    value = record[i]
                    pattern = INT_RE if kind == "int" else DEC2_RE
                    if not pattern.fullmatch(value):
                        problem(f"line {line_no}: {col}={value!r} is not a valid {kind} value")
                        continue
                    sums[col] += Decimal(value)
                for i, col, value in count_index:
                    if record[i] == value:
                        counts[col] += 1
    except csv.Error as exc:
        problem(f"CSV parse error near line {reader.line_num}: {exc}")
        return result

    metrics: dict[str, object] = {"rows": rows, "distinct_pk": len(pks)}
    for col in spec.columns:
        metrics[f"empty:{col}"] = empties[col]
        metrics[f"null:{col}"] = 0  # a CSV field is never NULL; the file format keeps it that way
        metrics[f"chars:{col}"] = chars[col]
    if dataset.numeric_totals:
        for col, _kind in spec.sums:
            metrics[f"sum:{col}"] = sums[col]
        for col, value in spec.value_counts:
            metrics[f"count:{col}={value}"] = counts[col]
    result.metrics = metrics

    # Compare with the profiled expectations.
    summary = summary_metrics(result)
    for key, want in dataset.expected[spec.name].items():
        got = summary.get(key)
        if not same(got, want):
            problem(f"{key} = {got}, expected {want} (profiling 2026-10-13)")
    return result


def summary_metrics(local: LocalFile) -> dict[str, object]:
    """Metrics plus the derived per-table totals used for expectations and display."""
    out = dict(local.metrics)
    out["empty_cells"] = sum(local.metrics.get(f"empty:{c}", 0) for c in local.spec.columns)
    out["chars_total"] = sum(local.metrics.get(f"chars:{c}", 0) for c in local.spec.columns)
    return out


def same(a: object, b: object) -> bool:
    """Exact equality across int / Decimal / str numerics (no float anywhere)."""
    if a is None or b is None:
        return a is b
    try:
        return Decimal(str(a)) == Decimal(str(b))
    except InvalidOperation:
        return str(a) == str(b)


def fmt(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, int):
        return f"{value:,}"
    if isinstance(value, Decimal):
        if value == value.to_integral_value() and value.as_tuple().exponent >= 0:
            return f"{int(value):,}"
        return f"{value:,.2f}"
    return str(value)


def verify_local(dataset: Dataset, data_dir: Path) -> list[LocalFile]:
    base = data_dir / dataset.subdir
    files = [scan_file(spec, base / spec.file_name, dataset) for spec in TABLES]
    print(f"== (a) Local verification: {dataset.key} ({dataset.description})")
    print(f"   files: {display_path(base)}")
    for f in files:
        status = "OK" if not f.problems else "FAIL"
        if f.metrics:
            detail = (f"{f.size:>10,} B  sha256 {f.sha256[:12]}..  {f.rows:>7,} rows x "
                      f"{len(f.spec.columns)} fields  header/UTF-8/LF checked")
        else:
            detail = "not scanned"
        print(f"   {status:4}  {f.spec.file_name:<16} {detail}")
        for p in f.problems:
            print(f"         - {p}")
    return files


def print_local_totals(dataset: Dataset, files: list[LocalFile]) -> None:
    print()
    print("   Local control totals (csv + decimal.Decimal) vs expected values from profiling:")
    print(f"   {'TABLE':<14} {'METRIC':<32} {'LOCAL':>18} {'EXPECTED':>18}  STATUS")
    for f in files:
        if not f.metrics:
            continue
        summary = summary_metrics(f)
        expected = dataset.expected[f.spec.name]
        for key in display_keys(f.spec, dataset):
            want = expected.get(key)
            status = "" if want is None else ("PASS" if same(summary.get(key), want) else "FAIL")
            print(f"   {f.spec.name:<14} {label(key, f.spec):<32} {fmt(summary.get(key)):>18} "
                  f"{fmt(want):>18}  {status}")


def display_keys(spec: TableSpec, dataset: Dataset) -> list[str]:
    keys = ["rows", "distinct_pk", "empty_cells", "chars_total"]
    if dataset.numeric_totals:
        keys += [f"sum:{col}" for col, _kind in spec.sums]
        keys += [f"count:{col}={value}" for col, value in spec.value_counts]
    return keys


def label(key: str, spec: TableSpec) -> str:
    if key == "distinct_pk":
        return f"distinct {spec.pk}"
    if key == "empty_cells":
        return "empty cells (all columns)"
    if key == "chars_total":
        return "characters (all columns)"
    if key.startswith("sum:"):
        return f"sum({key[4:]})"
    if key.startswith("count:"):
        col, value = key[6:].split("=", 1)
        return f"count({col} = '{value}')"
    return key


def display_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


# --------------------------------------------------------------------------------------
# SQL rendering
# --------------------------------------------------------------------------------------


def table_name(dataset: Dataset, spec: TableSpec) -> str:
    return f"{dataset.table_prefix}{spec.name}".upper()


# Characters a PUT source path must not contain (see PUT_SQL above).
PUT_PATH_FORBIDDEN = {"*": "glob wildcard", "?": "glob wildcard", "[": "glob character class",
                      "]": "glob character class", "'": "single quote", "\\": "backslash"}


def put_path_problem(path: Path) -> str | None:
    """Why this file cannot be uploaded with PUT as-is, or None if it can."""
    text = str(path.resolve())
    bad = sorted({PUT_PATH_FORBIDDEN[ch] for ch in text if ch in PUT_PATH_FORBIDDEN})
    if bad:
        return f"{text} contains a {', '.join(bad)}"
    return None


def check_put_paths(files: list[LocalFile]) -> None:
    """Refuse, before connecting, any data path that PUT would mis-read."""
    problems = [msg for msg in (put_path_problem(f.path) for f in files) if msg]
    if problems:
        raise SystemExit(
            "error: these data paths cannot be uploaded with PUT (the connector expands * ? [ ] "
            "as glob patterns, and a quote or backslash breaks the SQL literal):\n  "
            + "\n  ".join(problems)
            + "\nMove the data to a plain directory and pass it with --data-dir (make load DATA_DIR=...)."
        )


def render_put(dataset: Dataset, local: LocalFile) -> str:
    absolute = local.path.resolve()
    problem = put_path_problem(absolute)
    if problem:  # check_put_paths() normally stops this earlier
        raise SystemExit(f"error: {problem}; move the data to a plain directory.")
    return PUT_SQL.format(file_uri=f"file://{absolute}", stage=STAGE, prefix=dataset.stage_prefix)


def render_precheck(dataset: Dataset, spec: TableSpec) -> str:
    n = len(spec.columns)
    return PRECHECK_SQL.format(
        n=n, n_plus_1=n + 1, stage=STAGE, prefix=dataset.stage_prefix,
        staged_name=f"{spec.file_name}.gz", file_format=FILE_FORMAT,
    )


def render_truncate(dataset: Dataset, spec: TableSpec) -> str:
    return TRUNCATE_SQL.format(raw_schema=RAW_SCHEMA, table=table_name(dataset, spec))


def render_copy(dataset: Dataset, spec: TableSpec) -> str:
    return COPY_SQL.format(
        raw_schema=RAW_SCHEMA,
        table=table_name(dataset, spec),
        column_list=", ".join(c.upper() for c in spec.columns),
        positional_list=", ".join(f"t.${i}" for i in range(1, len(spec.columns) + 1)),
        stage=STAGE,
        prefix=dataset.stage_prefix,
        staged_name=f"{spec.file_name}.gz",
        file_format=FILE_FORMAT,
    )


def remote_metric_exprs(dataset: Dataset, spec: TableSpec) -> list[tuple[str, str]]:
    """(metric key, Snowflake SQL expression) pairs, aligned with metric_keys()."""
    exprs = [("rows", "COUNT(*)"), ("distinct_pk", f"COUNT(DISTINCT {spec.pk.upper()})")]
    for col in spec.columns:
        c = col.upper()
        exprs += [
            (f"empty:{col}", f"COUNT_IF({c} = '')"),
            (f"null:{col}", f"COUNT_IF({c} IS NULL)"),
            (f"chars:{col}", f"COALESCE(SUM(LENGTH({c})), 0)"),
        ]
    if dataset.numeric_totals:
        for col, kind in spec.sums:
            cast = f"TO_NUMBER({col.upper()})" if kind == "int" else f"TO_NUMBER({col.upper()}, 12, 2)"
            exprs.append((f"sum:{col}", f"SUM({cast})"))
        for col, value in spec.value_counts:
            exprs.append((f"count:{col}={value}", f"COUNT_IF({col.upper()} = '{value}')"))
    assert [k for k, _ in exprs] == metric_keys(spec, dataset.numeric_totals)
    return exprs


LINEAGE_EXPRS = [
    ("lineage:files", "COUNT(DISTINCT _SOURCE_FILE)"),
    ("lineage:file_name", "MIN(_SOURCE_FILE)"),
    ("lineage:file_null", "COUNT_IF(_SOURCE_FILE IS NULL)"),
    ("lineage:row_null", "COUNT_IF(_SOURCE_ROW_NUMBER IS NULL)"),
    ("lineage:row_min", "MIN(_SOURCE_ROW_NUMBER)"),
    ("lineage:row_max", "MAX(_SOURCE_ROW_NUMBER)"),
    ("lineage:row_distinct", "COUNT(DISTINCT _SOURCE_ROW_NUMBER)"),
    ("lineage:loaded_at_null", "COUNT_IF(_LOADED_AT IS NULL)"),
    ("lineage:loaded_at_max", "TO_VARCHAR(MAX(_LOADED_AT))"),
]


def render_remote_totals(dataset: Dataset, spec: TableSpec) -> tuple[str, list[str]]:
    pairs = remote_metric_exprs(dataset, spec) + LINEAGE_EXPRS
    select_list = ",\n       ".join(f'{expr} AS "{key}"' for key, expr in pairs)
    sql = f"SELECT {select_list}\nFROM {RAW_SCHEMA}.{table_name(dataset, spec)}"
    return sql, [key for key, _ in pairs]


def print_planned_sql(dataset: Dataset, files: list[LocalFile]) -> None:
    print()
    print("== SQL that a real run sends (connected as SVC_CRM_PIPELINE, role CRM_LOADER):")
    print(f"-- 1. every statement of {display_path(RAW_OBJECTS_SQL)} (file format, stage, RAW tables)")
    print("-- 2. upload (PUT runs from the driver; it cannot run in a Snowsight worksheet)")
    for f in files:
        print(render_put(dataset, f) + ";")
    print("-- 3. field-count pre-check of each staged file (before anything is truncated)")
    for f in files:
        print(render_precheck(dataset, f.spec) + ";")
    print("-- 4. full refresh of each table")
    for f in files:
        print(render_truncate(dataset, f.spec) + ";")
        print(render_copy(dataset, f.spec) + ";")
    print("-- 5. remote control totals, compared exactly with the local ones")
    for f in files:
        print(render_remote_totals(dataset, f.spec)[0] + ";")


# --------------------------------------------------------------------------------------
# (b) + (c) Load and reconcile
# --------------------------------------------------------------------------------------


def fetch_dicts(cur) -> list[dict[str, object]]:
    names = [col.name.lower() for col in cur.description] if cur.description else []
    return [dict(zip(names, row)) for row in cur.fetchall()]


def run_load(dataset: Dataset, files: list[LocalFile]) -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import sfconn

    report: dict[str, object] = {
        "dataset": dataset.key,
        "description": dataset.description,
        "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": {f.spec.name: {"path": display_path(f.path), "bytes": f.size, "sha256": f.sha256}
                  for f in files},
    }
    try:
        sfconn.load_env()
        role = sfconn.setting("SNOWFLAKE_LOADER_ROLE")
        settings = sfconn.resolve_settings(role=role, schema="RAW")
        for warning in settings.key.warnings:
            print(f"   WARN  {warning}")
        print()
        print(f"== (b) Connecting: account {settings.account}, user {settings.user}, role {role}, "
              f"key {settings.key.path.name} ({settings.key.fingerprint})")
        conn = sfconn.connect(settings, tool=f"load_raw:{dataset.key}")
    except (sfconn.ConfigError, sfconn.ConnectError) as exc:
        print(f"FAIL  {exc}")
        return 2

    from snowflake.connector.errors import Error as SnowflakeError

    report["status"] = "FAIL"  # until reconcile() proves otherwise
    try:
        cur = conn.cursor()
        report["snowflake"] = dict(zip(
            ("account", "user", "role", "warehouse"),
            cur.execute("SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME(), "
                        "CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE()").fetchone(),
        ))

        print(f"   running {display_path(RAW_OBJECTS_SQL)}")
        sfconn.run_sql_file(
            conn, RAW_OBJECTS_SQL,
            on_result=lambda r: print(f"     [{r.index:>2}] {sfconn.first_line(r.sql, 70)}"),
        )

        print("   PUT")
        report["put"] = {}
        for f in files:
            rows = fetch_dicts(cur.execute(render_put(dataset, f)))
            status = rows[0].get("status") if rows else None
            report["put"][f.spec.name] = {"status": status, "query_id": cur.sfqid,
                                          "target": rows[0].get("target") if rows else None}
            print(f"     {f.spec.file_name:<16} -> {STAGE}/{dataset.stage_prefix}/ "
                  f"{rows[0].get('target') if rows else '?'}  {status}")
            if status != "UPLOADED":
                print(f"FAIL  PUT of {f.spec.file_name} returned status {status!r}")
                return 1

        print("   Stage pre-check (field count of every staged record)")
        report["precheck"] = {}
        precheck_ok = True
        for f in files:
            rows = fetch_dicts(cur.execute(render_precheck(dataset, f.spec)))
            n_records = sum(int(r["n_records"]) for r in rows)
            n_bad = sum(int(r["n_wrong_field_count"]) for r in rows)
            ok = len(rows) == 1 and n_records == f.rows and n_bad == 0
            precheck_ok &= ok
            report["precheck"][f.spec.name] = {"records": n_records, "wrong_field_count": n_bad,
                                               "files": len(rows), "ok": ok}
            print(f"     {'PASS' if ok else 'FAIL'}  {f.spec.file_name:<16} {n_records:>9,} records "
                  f"(local {f.rows:,}), {n_bad} with a wrong field count")
        if not precheck_ok:
            print("FAIL  stage pre-check failed; no table was truncated.")
            return 1

        print("   TRUNCATE + COPY")
        report["copy"] = {}
        for f in files:
            table = table_name(dataset, f.spec)
            cur.execute(render_truncate(dataset, f.spec))
            rows = fetch_dicts(cur.execute(render_copy(dataset, f.spec)))
            loaded = sum(int(r.get("rows_loaded") or 0) for r in rows)
            statuses = sorted({str(r.get("status")) for r in rows})
            ok = statuses == ["LOADED"] and loaded == f.rows
            report["copy"][f.spec.name] = {"table": f"{RAW_SCHEMA}.{table}", "status": statuses,
                                           "rows_loaded": loaded, "query_id": cur.sfqid, "ok": ok}
            print(f"     {'PASS' if ok else 'FAIL'}  {RAW_SCHEMA}.{table:<22} {loaded:>9,} rows loaded "
                  f"(status {', '.join(statuses) or 'none'})")
            if not ok:
                print(f"FAIL  COPY into {table} did not load exactly {f.rows:,} rows. "
                      "The table may now be empty; fix the cause and run the load again.")
                return 1

        print()
        print("== (c) Remote control totals (Snowflake SQL) vs local (csv + Decimal)")
        return reconcile(dataset, files, cur, report)
    except SnowflakeError as exc:
        report["error"] = sfconn.describe_error(exc)
        print(f"FAIL  {report['error']}")
        return 1
    except sfconn.SqlFileError as exc:
        report["error"] = str(exc)
        print(f"FAIL  {exc}")
        return 1
    finally:
        conn.close()
        out = write_report(dataset, report)
        print(f"Report: {display_path(out)}")


def write_report(dataset: Dataset, report: dict[str, object]) -> Path:
    report["finished_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    BUILD_DIR.mkdir(exist_ok=True)
    out = BUILD_DIR / f"load_report_{dataset.key}.json"
    out.write_text(json.dumps(report, indent=2, default=str) + "\n", encoding="utf-8")
    return out


def reconcile(dataset: Dataset, files: list[LocalFile], cur, report: dict[str, object]) -> int:
    all_ok = True
    report["tables"] = {}
    print(f"   {'TABLE':<26} {'METRIC':<32} {'LOCAL':>18} {'SNOWFLAKE':>18}  STATUS")
    for f in files:
        sql, keys = render_remote_totals(dataset, f.spec)
        row = cur.execute(sql).fetchone()
        remote = dict(zip(keys, row))
        compared = metric_keys(f.spec, dataset.numeric_totals)
        mismatches = [k for k in compared if not same(f.metrics.get(k), remote.get(k))]

        # Lineage: one file, a unique contiguous row number per record, a load timestamp.
        rows = f.rows
        row_min, row_max = remote["lineage:row_min"], remote["lineage:row_max"]
        lineage_checks = {
            "one source file": remote["lineage:files"] == 1 and remote["lineage:file_null"] == 0,
            "file name": str(remote["lineage:file_name"] or "").endswith(
                f"{dataset.stage_prefix}/{f.spec.file_name}.gz"),
            "row numbers unique": remote["lineage:row_null"] == 0 and remote["lineage:row_distinct"] == rows,
            "row numbers contiguous": row_min is not None and int(row_max) - int(row_min) + 1 == rows,
            "_LOADED_AT set": remote["lineage:loaded_at_null"] == 0,
        }
        table_ok = not mismatches and all(lineage_checks.values())
        all_ok &= table_ok

        table = f"{RAW_SCHEMA}.{table_name(dataset, f.spec)}".replace("MARKETING_CRM.", "")
        remote_summary = dict(remote)
        remote_summary["empty_cells"] = sum(remote.get(f"empty:{c}", 0) for c in f.spec.columns)
        remote_summary["chars_total"] = sum(remote.get(f"chars:{c}", 0) for c in f.spec.columns)
        local_summary = summary_metrics(f)
        for key in display_keys(f.spec, dataset):
            ok = same(local_summary.get(key), remote_summary.get(key))
            print(f"   {table:<26} {label(key, f.spec):<32} {fmt(local_summary.get(key)):>18} "
                  f"{fmt(remote_summary.get(key)):>18}  {'PASS' if ok else 'FAIL'}")
        for key in mismatches:
            print(f"   {table:<26} {key:<32} {fmt(f.metrics.get(key)):>18} {fmt(remote.get(key)):>18}  FAIL")
        failed_lineage = [name for name, ok in lineage_checks.items() if not ok]
        print(f"   {table:<26} {len(compared)} metrics compared exactly: "
              f"{'all match' if not mismatches else f'{len(mismatches)} MISMATCH'}; lineage "
              f"{'OK' if not failed_lineage else 'FAIL: ' + ', '.join(failed_lineage)} "
              f"(first _SOURCE_ROW_NUMBER = {row_min}: 1 means the header is not counted)")

        report["tables"][f.spec.name] = {
            "table": f"{RAW_SCHEMA}.{table_name(dataset, f.spec)}",
            "ok": table_ok,
            "metrics": {k: {"local": str(f.metrics.get(k)), "snowflake": str(remote.get(k)),
                            "match": k not in mismatches} for k in compared},
            "lineage": {k: str(v) for k, v in remote.items() if k.startswith("lineage:")},
            "lineage_checks": lineage_checks,
        }

    report["status"] = "PASS" if all_ok else "FAIL"
    print()
    print(f"{'PASS' if all_ok else 'FAIL'}  {dataset.key}: RAW landing "
          f"{'matches the local files exactly' if all_ok else 'does NOT match the local files'}.")
    return 0 if all_ok else 1


# --------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dataset", choices=sorted(DATASETS), required=True)
    parser.add_argument("--dry-run", action="store_true",
                        help="local checks + print the SQL; no Snowflake import or connection")
    parser.add_argument("--data-dir", default="data/raw",
                        help="directory that holds source/ and cleaning-challenge/ (default: data/raw)")
    args = parser.parse_args(argv)

    dataset = DATASETS[args.dataset]
    data_dir = Path(args.data_dir)
    if not data_dir.is_absolute():
        data_dir = REPO_ROOT / data_dir

    files = verify_local(dataset, data_dir)
    print_local_totals(dataset, files)
    failed = [f for f in files if f.problems]
    if failed:
        print()
        print(f"FAIL  local verification failed for: {', '.join(f.spec.file_name for f in failed)}. "
              "Nothing was sent to Snowflake.")
        return 1
    print()
    print(f"PASS  local verification: {len(files)} files, every record has the expected field count, "
          "control totals equal the profiled values.")
    check_put_paths(files)  # before any connection, so 01_raw_objects.sql never runs in vain

    if args.dry_run:
        print_planned_sql(dataset, files)
        print()
        print("Dry run: Snowflake was not contacted.")
        return 0
    return run_load(dataset, files)


if __name__ == "__main__":
    sys.exit(main())
