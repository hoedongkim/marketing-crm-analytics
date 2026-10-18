#!/usr/bin/env python3
"""Compute the dbt seeds of independent expected values from the raw CSV files.

    python scripts/independent_check.py            # (re)write the two generated seeds
    python scripts/independent_check.py --check    # regenerate into a temp dir, diff, exit 1 on any difference

Why this exists
    The dbt tests of Phase 5 compare the models with values that were computed WITHOUT
    Snowflake and without the SQL under test: an independent path from the published files to
    the expected numbers. In Phases 2-4 those values lived in scratch scripts and inline VALUES
    lists; this script makes them reproducible from the repository. It uses only the Python
    standard library (csv + decimal): no Snowflake, no DuckDB, no pandas.

What it writes (dbt/seeds/, loaded by `dbt build` into MARKETING_CRM.STAGING)
    expected_campaign_kpi.csv  one row per campaign (120): channel, objective, budget, and the
                               campaign's funnel bases summed from daily_spend, leads and
                               conversions (each fact aggregated to the campaign on its own).
                               Same columns and values as the Phase 2 local baseline
                               (2026-10-13, DuckDB and Python agreed on all 1,650 values).
    expected_totals.csv        metric,value: control totals and the time and segment counts
                               the marts must reproduce (see METRIC_NOTES below).
    Every amount is an exact Decimal: sums of the 2-dp source amounts are printed with their
    natural 2 dp, and the one derived amount (budget_prorated) is rounded once, half up, to
    6 dp per spend row, the convention of the MART column it checks.

What it only checks (never writes)
    publisher_channel_reference.csv is typed in by hand from the publisher's dataset page (its
    "finished output" table: spend and attributed revenue by channel). It is the outside
    reference, so it is not computed here. --check (and every normal run) compares it with the
    channel roll-up of the CSV files and fails on any difference.

Inputs: data/raw/source/{campaigns,daily_spend,leads,conversions}.csv (`make data`).
Exit codes: 0 ok; 1 a generated seed differs from the committed one, or the publisher
reference disagrees with the CSV files; 2 missing input or malformed data.
"""

from __future__ import annotations

import argparse
import csv
import difflib
import sys
import tempfile
from collections import defaultdict
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "data" / "raw" / "source"
SEED_DIR = REPO_ROOT / "dbt" / "seeds"
CAMPAIGN_FILE = "expected_campaign_kpi.csv"
TOTALS_FILE = "expected_totals.csv"
PUBLISHER_FILE = "publisher_channel_reference.csv"

# Assumptions shared with the models (documented in sql/02b_core_models.sql and 02c):
POST_WINDOW_DAYS = 21                 # observed maximum lead-to-conversion lag, 0..21 days
COVERAGE_START = date(2023, 1, 1)     # documented coverage start = first DIM_DATE day
COVERAGE_END = date(2025, 12, 31)     # documented coverage end = last DIM_DATE day
AS_OF_DATE = date(2025, 12, 31)       # assumed as-of date of FCT_LEAD_CONVERSIONS (IS_MATURE)
MATURITY_DAYS = 21                    # a lead is mature once it has had the full 21-day window
SEGMENTS = (("low", 1, 40), ("medium", 41, 70), ("high", 71, 100))   # plan score bands

CAMPAIGN_COLUMNS = ["campaign_id", "channel", "objective", "budget", "spend_days", "spend",
                    "impressions", "clicks", "leads", "converted_leads", "trials", "purchases",
                    "revenue"]

METRIC_NOTES = {   # metric -> what it counts (printed with --explain, kept here for review)
    "campaigns": "campaigns.csv rows",
    "budget": "SUM(budget), whole campaigns",
    "spend_rows": "daily_spend.csv rows (campaign x active day)",
    "spend": "SUM(spend)",
    "impressions": "SUM(impressions)",
    "clicks": "SUM(clicks)",
    "budget_prorated": "SUM over spend rows of ROUND_HALF_UP(budget / window days, 6)",
    "leads": "leads.csv rows",
    "sum_lead_score": "SUM(lead_score)",
    "converted_leads": "conversions.csv rows (a lead converts at most once)",
    "trials": "conversions of type trial",
    "purchases": "conversions of type purchase",
    "revenue": "SUM(revenue), last-touch attributed",
    "trial_revenue": "SUM(revenue) of trials (0.00 by the business rule)",
    "leads_without_conversion": "leads with no conversion row",
    "conversions_after_campaign_end": "conversions dated after their campaign's end_date",
    "revenue_after_campaign_end": "revenue of those conversions",
    "conversions_later_month": "conversions in a later calendar month than their lead",
    "max_days_to_convert": "largest converted_at - created_at, in days",
    "mature_leads": "leads created on or before 2025-12-31 - 21 days = 2025-12-10 (IS_MATURE = 1)",
    "activity_spine_rows": "SUM over campaigns of days from start_date to min(end_date + 21, 2025-12-31)",
    "leads_low": "leads with lead_score 1-40",
    "leads_medium": "leads with lead_score 41-70",
    "leads_high": "leads with lead_score 71-100",
    "converted_low": "converted leads with lead_score 1-40",
    "converted_medium": "converted leads with lead_score 41-70",
    "converted_high": "converted leads with lead_score 71-100",
    "calendar_days": "days from 2023-01-01 to 2025-12-31 inclusive (the DIM_DATE spine)",
    "calendar_weekend_days": "Saturdays and Sundays among them",
}


class DataError(Exception):
    pass


def read_rows(name: str) -> list[dict[str, str]]:
    path = SOURCE_DIR / f"{name}.csv"
    if not path.is_file():
        raise DataError(f"missing {path.relative_to(REPO_ROOT)}; run 'make data' first")
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def parse_date(text: str) -> date:
    return date.fromisoformat(text)   # the clean release is strictly YYYY-MM-DD


def compute() -> tuple[list[list[str]], list[list[str]], dict[str, dict[str, Decimal]]]:
    """Return (campaign rows, totals rows, channel roll-up) from the four CSV files."""
    campaigns = {r["campaign_id"]: r for r in read_rows("campaigns")}
    if len(campaigns) != 120:
        raise DataError(f"expected 120 distinct campaigns, found {len(campaigns)}")
    zero = Decimal("0.00")
    per = {cid: defaultdict(lambda: Decimal(0)) for cid in campaigns}
    for cid, row in campaigns.items():
        per[cid]["spend"] = zero
        per[cid]["revenue"] = zero
    totals: dict[str, Decimal] = defaultdict(lambda: Decimal(0))
    totals["trial_revenue"] = zero
    totals["revenue_after_campaign_end"] = zero

    window_days = {cid: (parse_date(r["end_date"]) - parse_date(r["start_date"])).days + 1
                   for cid, r in campaigns.items()}
    q6 = Decimal("0.000001")
    for row in read_rows("daily_spend"):
        cid = row["campaign_id"]
        if cid not in per:
            raise DataError(f"spend row {row['spend_id']} has unknown campaign {cid}")
        stats = per[cid]
        stats["spend_days"] += 1
        stats["spend"] += Decimal(row["spend"])
        stats["impressions"] += int(row["impressions"])
        stats["clicks"] += int(row["clicks"])
        budget = Decimal(campaigns[cid]["budget"])
        totals["budget_prorated"] += (budget / window_days[cid]).quantize(q6, rounding=ROUND_HALF_UP)

    leads: dict[str, tuple[str, date, int]] = {}
    for row in read_rows("leads"):
        cid = row["campaign_id"]
        if cid not in per:
            raise DataError(f"lead {row['lead_id']} has unknown campaign {cid}")
        score = int(row["lead_score"])
        created = parse_date(row["created_at"])
        leads[row["lead_id"]] = (cid, created, score)
        per[cid]["leads"] += 1
        if created <= AS_OF_DATE - timedelta(days=MATURITY_DAYS):
            totals["mature_leads"] += 1
        totals["sum_lead_score"] += score
        for name, low, high in SEGMENTS:
            if low <= score <= high:
                totals[f"leads_{name}"] += 1

    converted: set[str] = set()
    for row in read_rows("conversions"):
        lead_id = row["lead_id"]
        if lead_id not in leads:
            raise DataError(f"conversion {row['conversion_id']} has unknown lead {lead_id}")
        if lead_id in converted:
            raise DataError(f"lead {lead_id} converts twice")
        converted.add(lead_id)
        cid, created, score = leads[lead_id]
        stats = per[cid]
        revenue = Decimal(row["revenue"])
        converted_on = parse_date(row["converted_at"])
        stats["converted_leads"] += 1
        stats["revenue"] += revenue
        if row["conversion_type"] == "trial":
            stats["trials"] += 1
            totals["trial_revenue"] += revenue
        elif row["conversion_type"] == "purchase":
            stats["purchases"] += 1
        else:
            raise DataError(f"unknown conversion_type {row['conversion_type']!r}")
        if converted_on > parse_date(campaigns[cid]["end_date"]):
            totals["conversions_after_campaign_end"] += 1
            totals["revenue_after_campaign_end"] += revenue
        if (converted_on.year, converted_on.month) > (created.year, created.month):
            totals["conversions_later_month"] += 1
        totals["max_days_to_convert"] = max(totals["max_days_to_convert"], (converted_on - created).days)
        for name, low, high in SEGMENTS:
            if low <= score <= high:
                totals[f"converted_{name}"] += 1

    for cid, row in campaigns.items():
        start, end = parse_date(row["start_date"]), parse_date(row["end_date"])
        spine_end = min(end + timedelta(days=POST_WINDOW_DAYS), COVERAGE_END)
        totals["activity_spine_rows"] += (spine_end - start).days + 1

    day = COVERAGE_START
    while day <= COVERAGE_END:
        totals["calendar_days"] += 1
        totals["calendar_weekend_days"] += 1 if day.isoweekday() >= 6 else 0
        day += timedelta(days=1)

    campaign_rows = []
    for cid in sorted(campaigns):
        c, s = campaigns[cid], per[cid]
        campaign_rows.append([cid, c["channel"], c["objective"], c["budget"], str(s["spend_days"]),
                              str(s["spend"]), str(s["impressions"]), str(s["clicks"]), str(s["leads"]),
                              str(s["converted_leads"]), str(s["trials"]), str(s["purchases"]),
                              str(s["revenue"])])

    def campaign_sum(field: str) -> Decimal:
        return sum((per[cid][field] for cid in campaigns), Decimal(0) if field not in ("spend", "revenue") else zero)

    totals["campaigns"] = Decimal(len(campaigns))
    totals["budget"] = sum((Decimal(c["budget"]) for c in campaigns.values()), zero)
    for field, metric in (("spend_days", "spend_rows"), ("spend", "spend"), ("impressions", "impressions"),
                          ("clicks", "clicks"), ("leads", "leads"), ("converted_leads", "converted_leads"),
                          ("trials", "trials"), ("purchases", "purchases"), ("revenue", "revenue")):
        totals[metric] = campaign_sum(field)
    totals["leads_without_conversion"] = totals["leads"] - totals["converted_leads"]
    totals_rows = [[metric, str(totals[metric])] for metric in METRIC_NOTES]

    channels: dict[str, dict[str, Decimal]] = defaultdict(lambda: {"spend": zero, "attributed_revenue": zero})
    for cid, c in campaigns.items():
        channels[c["channel"]]["spend"] += per[cid]["spend"]
        channels[c["channel"]]["attributed_revenue"] += per[cid]["revenue"]
    return campaign_rows, totals_rows, dict(channels)


def write_csv(path: Path, header: list[str], rows: list[list[str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def write_seeds(target: Path, campaign_rows: list[list[str]], totals_rows: list[list[str]]) -> None:
    target.mkdir(parents=True, exist_ok=True)
    write_csv(target / CAMPAIGN_FILE, CAMPAIGN_COLUMNS, campaign_rows)
    write_csv(target / TOTALS_FILE, ["metric", "value"], totals_rows)


def check_publisher(channels: dict[str, dict[str, Decimal]]) -> list[str]:
    """Compare the typed-in publisher reference with the channel roll-up of the CSV files."""
    path = SEED_DIR / PUBLISHER_FILE
    if not path.is_file():
        return [f"missing {path.relative_to(REPO_ROOT)} (typed in by hand from the dataset page)"]
    with path.open(newline="", encoding="utf-8") as handle:
        reference = {r["channel"]: r for r in csv.DictReader(handle)}
    problems = []
    for channel in sorted(set(reference) | set(channels)):
        ref, got = reference.get(channel), channels.get(channel)
        if ref is None or got is None:
            problems.append(f"channel {channel}: only in {'the CSV files' if ref is None else 'the reference'}")
            continue
        for column in ("spend", "attributed_revenue"):
            if Decimal(ref[column]) != got[column]:
                problems.append(f"channel {channel} {column}: reference {ref[column]} != CSV files {got[column]}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="regenerate into a temp dir and diff against the committed seeds (exit 1 on any difference)")
    parser.add_argument("--explain", action="store_true", help="also print what each total counts")
    args = parser.parse_args(argv)
    try:
        campaign_rows, totals_rows, channels = compute()
    except (DataError, KeyError, ValueError, ArithmeticError) as exc:
        print(f"FAIL  {type(exc).__name__}: {exc}")
        return 2

    failures = 0
    if args.check:
        with tempfile.TemporaryDirectory(prefix="independent_check_") as tmp:
            write_seeds(Path(tmp), campaign_rows, totals_rows)
            for name in (CAMPAIGN_FILE, TOTALS_FILE):
                fresh = (Path(tmp) / name).read_text(encoding="utf-8").splitlines(keepends=True)
                committed_path = SEED_DIR / name
                committed = (committed_path.read_text(encoding="utf-8").splitlines(keepends=True)
                             if committed_path.is_file() else [])
                diff = list(difflib.unified_diff(committed, fresh, f"committed/{name}", f"regenerated/{name}"))
                if diff:
                    failures += 1
                    print(f"FAIL  dbt/seeds/{name} differs from a fresh computation:")
                    sys.stdout.writelines(diff)
                else:
                    print(f"OK    dbt/seeds/{name}: {len(fresh) - 1} rows, identical to a fresh computation")
    else:
        write_seeds(SEED_DIR, campaign_rows, totals_rows)
        print(f"wrote dbt/seeds/{CAMPAIGN_FILE} ({len(campaign_rows)} rows) and "
              f"dbt/seeds/{TOTALS_FILE} ({len(totals_rows)} rows)")

    problems = check_publisher(channels)
    if problems:
        failures += 1
        print(f"FAIL  dbt/seeds/{PUBLISHER_FILE} disagrees with the CSV files:")
        for problem in problems:
            print(f"      {problem}")
    else:
        print(f"OK    dbt/seeds/{PUBLISHER_FILE}: spend and attributed revenue of all "
              f"{len(channels)} channels equal the CSV roll-up to the cent")

    print("totals: " + ", ".join(f"{metric}={value}" for metric, value in totals_rows))
    if args.explain:
        for metric, _value in totals_rows:
            print(f"  {metric:32s} {METRIC_NOTES[metric]}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
