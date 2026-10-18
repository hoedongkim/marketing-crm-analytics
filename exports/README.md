# exports/: the frozen data behind the dashboard

These files are a frozen copy of the Snowflake `MARKETING_CRM.MART` tables that the Google Data
Studio dashboard is built on (Phase 6: the report is being built by hand from
[docs/dashboard_spec.md](../docs/dashboard_spec.md)). The Snowflake trial ends about
**2026-11-12**. From then on, the public dashboard is to serve these tables from Google Sheets
instead of the live connector ([docs/architecture.md](../docs/architecture.md), decision 8). The
steps to switch are in [docs/sheets_snapshot.md](../docs/sheets_snapshot.md).

Nothing here was computed in Python or in a spreadsheet. Every number is a value of a dbt-built
Snowflake table, written out exactly as stored.

## Files

| File | What it is |
|---|---|
| `<TABLE>.csv` (8 files) | One file per MART table, named after it. |
| `marketing_crm_dashboard_snapshot.xlsx` | The workbook you upload to Google Drive. The first sheet is `README`: provenance, export time, row counts, caveats and attribution. Then comes one sheet per table, named after the table. |
| `manifest.json` | Machine-readable provenance and checksums for every file (see [Integrity](#integrity)). |

| Table (CSV and sheet) | Rows | Grain | Basis |
|---|---:|---|---|
| `MART_CHANNEL_PERFORMANCE` | 5 | one row per channel | full range 2023-01-01..2025-12-31; its ratio columns are valid at channel grain only |
| `MART_CAMPAIGN_PERFORMANCE` | 120 | one row per campaign | full range; its ratio columns are valid at campaign grain only; `START_DATE` / `START_MONTH` are campaign attributes, not activity dates |
| `MART_MONTHLY_MARKETING` | 180 | activity month × channel (36 × 5) | activity (`MONTH_START`) |
| `MART_MONTHLY_COHORT` | 180 | lead-cohort month × channel (36 × 5) | lead cohort (`COHORT_MONTH`) |
| `MART_CONVERSION_FUNNEL` | 25 | channel × funnel stage (5 × 5) | full range; long format for the funnel chart |
| `MART_LEAD_QUALITY` | 50 | channel × 10-point lead-score band (5 × 10) | lead cohort, full range |
| `FCT_CAMPAIGN_DAILY_ACTIVITY` | 13,760 | campaign × day, `START_DATE` to `END_DATE` + 21 days | activity (`ACTIVITY_DATE`, `ACTIVITY_MONTH`) |
| `DIM_CAMPAIGN` | 120 | one row per campaign | campaign attributes; exported for completeness, not used by the report (the campaign filter reads `MART_CAMPAIGN_PERFORMANCE`, [dashboard_spec.md](../docs/dashboard_spec.md) D1) |

The column definitions are in [docs/data_dictionary.md](../docs/data_dictionary.md). The KPIs and
the Data Studio calculated fields valid on each table are in
[docs/kpi_definitions.md](../docs/kpi_definitions.md). The list of exported tables is the constant
`EXPORT_TABLES` in [`scripts/export_marts.py`](../scripts/export_marts.py). To export another table,
add it there with its grain key and run the export again.

Not exported: `FCT_LEAD_CONVERSIONS` (261,684 rows, one per lead), `FCT_DAILY_SPEND` and `DIM_DATE`.
The dashboard does not read them.

## Format

- **CSV.**
  - Encoding and layout: UTF-8, LF line ends, one header row with the exact UPPERCASE Snowflake column names in table order.
  - Row order: by the table's grain key (in `manifest.json` as `order_by`; checked unique).
  - Numbers: plain decimals at the column's scale. `NUMBER(18,6)` gives `0.016258`, `NUMBER(18,2)` gives `955297.00`; never an exponent or a float artefact.
  - Other values: dates `YYYY-MM-DD`; booleans `TRUE` / `FALSE`; NULL is an empty field. The only NULLs are `PREV_STAGE_VALUE` on the 5 first-stage rows of `MART_CONVERSION_FUNNEL`.
- **Workbook.**
  - Cells: numeric cells hold numbers, written as their exact decimal text and formatted at the column's scale (`0`, `0.00`, `0.0000`, `0.000000`, no thousands separator). Date cells hold dates formatted `yyyy-mm-dd`. Text cells hold text, so `SCORE_BAND` values such as `01-10` stay text.
  - Layout: the header row is bold and frozen. Each data sheet holds nothing but the table, with the header in row 1 and the data from row 2, so Data Studio can read it as a data source.
  - Attribution: a note on cell `A1` of every data sheet. The `README` sheet repeats it.
- **Use the workbook for Google Sheets, not the CSVs.** Importing a CSV into Sheets with automatic conversion turns `01-10` into a date and can reformat numbers. The workbook's typed cells avoid both problems. The CSVs are for diffs, review on GitHub and other tools.

## How they were produced

```bash
make export-marts   # export, as the BI user -> exports/ ; log -> docs/evidence/06_export_marts.txt
make export-check   # verify files + live tables  ; log -> docs/evidence/06_export_check.txt
make export-check EXPORT_CHECK_ARGS=--offline   # verify the files only (works after the trial)
```

1. **Who reads the data.** `scripts/export_marts.py` connects as **`SVC_CRM_BI` with role
   `CRM_REPORTER`** (key pair, settings from `.env`). That is the identity of the Data Studio
   connector, which can read `MART` and nothing else, so the export contains exactly what the
   dashboard's data sources read.
2. **What it runs.** For each table: one `SELECT <columns> ... ORDER BY <grain key>`, then one
   aggregate query (`COUNT(*)`, `HASH_AGG(*)`, `SUM` of every `NUMBER` column, NULL count of every
   column). Both are read-only.
3. **The cross-check.** The rows fetched must reproduce the aggregate query exactly (row count,
   sums, NULL counts). Otherwise the run fails: the table may have been rebuilt mid-export.
4. **Writing.** All files are written to a temporary directory and checked offline: SHA-256, sums,
   and the workbook compared with the CSVs cell by cell. Only then do they replace the previous
   export, all together. A failed run leaves `exports/` unchanged.

Re-running the export on unchanged tables reproduces the CSVs byte for byte (same SHA-256). The
workbook and `manifest.json` change on every run, because they record the export time and query
IDs.

## Integrity

`manifest.json` records:

- **Export level:** the export time (UTC); the source (`MARKETING_CRM.MART`, built by dbt Core,
  read as `SVC_CRM_BI` / `CRM_REPORTER`); the dbt project (`marketing_crm`); the dataset and its
  version (v1.0.0); the attribution and caveats; the tool versions; the workbook's SHA-256 and sheet
  list.
- **Per table:** the row count; the columns with their Snowflake types; the grain key; the CSV's
  SHA-256 and size; the Snowflake query IDs of the data and checksum queries; the export time; the
  table's last-altered time in Snowflake; its table comment; and the checksums (`rows`,
  `hash_agg`, `sums`, `null_counts`).

`make export-check` proves the chain in both directions:

- **Files against the manifest.** Each CSV's SHA-256, header, row count, key order, column sums
  and NULL counts are checked against the manifest, and every workbook cell against its CSV.
- **The live table against the manifest.** While Snowflake is reachable, the check re-queries each
  table as the BI user and compares `COUNT(*)`, `HASH_AGG(*)`, the column sums and the NULL counts
  with the manifest. It exits 1 on any difference.

After the trial ends, only the offline half can run. The evidence of the live comparison is
[docs/evidence/06_export_check.txt](../docs/evidence/06_export_check.txt).

## Caveats

- **Synthetic data.** It describes a fictional business: no real companies, people or industry benchmarks.
- **Last-touch attribution.** ROAS and revenue by channel or campaign describe attributed revenue, not the causal effect of spend. Offline and view-through conversions are not included.
- **Two time bases, never on one date axis.** Activity months (`MART_MONTHLY_MARKETING.MONTH_START`, `FCT_CAMPAIGN_DAILY_ACTIVITY.ACTIVITY_DATE`) and lead-cohort months (`MART_MONTHLY_COHORT.COHORT_MONTH`) are different bases. Conversion rates exist on the cohort basis only.
- **Ratios over several rows** are `SUM(numerator) / SUM(denominator)`. Never `SUM` or `AVG` a stored ratio column.
- **Budget utilisation** is valid only over whole campaigns: the campaign and channel tables.

## License and attribution

These files are an adaptation of a CC BY 4.0 dataset and are shared under the same license
terms. The repository's MIT license covers the code, not this data.

> Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0"
> (https://www.analyticsengineering.com/datasets/marketing-campaigns), CC BY 4.0
> (https://creativecommons.org/licenses/by/4.0/). Typed, cleaned and aggregated by Hoedong Kim;
> not endorsed by the publisher.

**Changes from the source (CC BY 4.0 §3(a)(1)(B)):**

- What was done: the four source CSVs were loaded byte for byte into Snowflake, then typed and
  cleaned in `STAGING`. They were aggregated into these `MART` tables by the dbt models in
  [`dbt/`](../dbt/).
- What is not included: the raw source files themselves (see [data/README.md](../data/README.md)).
