# Data dictionary

Every object that exists after Phase 5, plus the one table Phase 6 added, layer by layer: **RAW** (8 tables) → **STAGING**
(8 views, plus 3 dbt seed tables of test inputs since Phase 5) → **MART core** (5 tables,
Phase 3) → **MART analysis marts** (5 tables, Phase 4) → **MART conversion funnel** (1 table,
added by dbt in Phase 6). For each object: grain, row count,
primary key, and every column with its type and meaning. The KPIs built on these columns, with
their Data Studio formulas, are in [kpi_definitions.md](kpi_definitions.md).

Since Phase 5, dbt builds every STAGING view and MART table under the same name
(`make dbt-build`, project in [`dbt/`](../dbt/), described in [dbt.md](dbt.md)); the
hand-written SQL of Phases 3-4 built the same objects first. The rebuild changed no row, column,
type or column order: 18 of 18 objects have the same row count and row hash, and 245 of 245
columns the same position, type and nullability (`05P` A.1-A.2). So everything below holds for the
dbt-built objects; the evidence tags still point at the Phase 3-4 runs that first printed each
number. `MART_CONVERSION_FUNNEL` is the exception: dbt built it first, in Phase 6, and it has no
hand-written SQL twin ([below](#mart-conversion-funnel-phase-6)).

How to read this page:

- **Types** are the deployed types, read from `MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS` on
  2026-10-14 with a read-only query run as `CRM_TRANSFORMER` through `scripts/run_sql.py`: after
  `make models` for RAW, STAGING and the MART core, and after `make analysis-marts` for the
  analysis marts. The contract tests check the same names, positions and types on every run
  (`02T [6]` for STAGING, `02bT [6]` for the MART core, `02cT [6]` for the analysis marts). To
  re-read them (run once per schema):

  ```sql
  SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME,
         CASE WHEN DATA_TYPE = 'NUMBER' THEN 'NUMBER(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')'
              ELSE DATA_TYPE END AS TYPE
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'STAGING'          -- or 'RAW', 'MART'
  ORDER BY TABLE_NAME, ORDINAL_POSITION;
  ```
- **Row counts** are copied from the evidence files. Sources are given as *file [statement]*,
  like [data_profile.md](data_profile.md):

  | Tag | Evidence file | Produced by |
  |---|---|---|
  | `02` | [`evidence/02_data_cleaning.txt`](evidence/02_data_cleaning.txt) | `sql/02_data_cleaning.sql` (builds STAGING) |
  | `02T` | [`evidence/02_data_cleaning_tests.txt`](evidence/02_data_cleaning_tests.txt) | `sql/02_data_cleaning_tests.sql` |
  | `02b` | [`evidence/02b_core_models.txt`](evidence/02b_core_models.txt) | `sql/02b_core_models.sql` (builds MART) |
  | `02bT` | [`evidence/02b_core_models_tests.txt`](evidence/02b_core_models_tests.txt) | `sql/02b_core_models_tests.sql` |
  | `02c` | [`evidence/02c_analysis_marts.txt`](evidence/02c_analysis_marts.txt) | `sql/02c_analysis_marts.sql` (builds the analysis marts) |
  | `02cT` | [`evidence/02c_analysis_marts_tests.txt`](evidence/02c_analysis_marts_tests.txt) | `sql/02c_analysis_marts_tests.sql` |
  | `05P` | [`evidence/05_dbt_parity.txt`](evidence/05_dbt_parity.txt) | the Phase 5 parity report (dbt build vs SQL build, seeds) |
  | `06F` | [`evidence/06_funnel_mart.txt`](evidence/06_funnel_mart.txt) | Phase 6: `make dbt-build-select DBT_SELECT=mart_conversion_funnel+`, `make dbt-test`, the 02b / 02c object checks, the deployed types |

- **Descriptions** come from the code: the RAW column comments in
  [`sql/setup/01_raw_objects.sql`](../sql/setup/01_raw_objects.sql), the rules in
  [`sql/02_data_cleaning.sql`](../sql/02_data_cleaning.sql) and the MART column comments that
  [`sql/02b_core_models.sql`](../sql/02b_core_models.sql) and
  [`sql/02c_analysis_marts.sql`](../sql/02c_analysis_marts.sql) set (visible in Snowsight and in
  `INFORMATION_SCHEMA.COLUMNS.COMMENT`). Since Phase 5 the comments come from the dbt YAML
  descriptions (`persist_docs`): the MART column comments are the Phase 3-4 ones, unchanged, and
  the STAGING view columns now have comments too, from `dbt/models/staging/_staging.yml`
  (`05P` B). The cleaning rules and their reasons are in [data_cleaning.md](data_cleaning.md).

Type conventions:

- `TEXT` is Snowflake's name for `VARCHAR`. Every `TEXT` column in this project has the default
  maximum length, 16,777,216 characters; a declared length has no storage cost in Snowflake.
- **Keys are tested, not declared.** `INFORMATION_SCHEMA` reports `IS_NULLABLE = YES` for every
  column, because views and `CREATE TABLE ... AS` declare no constraints (and Snowflake would not
  enforce a primary key anyway). "PK" on this page means *unique and not NULL, checked by a
  test*; the **NULL** notes say where a NULL is allowed and which test guarantees the rest.

## Contents

1. [Layers at a glance](#layers-at-a-glance)
2. [RAW](#raw)
3. [STAGING](#staging)
   - [RAW to STAGING mapping](#raw-to-staging-mapping)
   - [Cleaning rule kinds](#cleaning-rule-kinds)
   - [DQ_ISSUES codes](#dq_issues-codes)
   - [Views](#views)
   - [Seeds (Phase 5)](#seeds-phase-5)
4. [MART core](#mart-core)
   - [Tables](#tables)
   - [KPI definitions: MART_CAMPAIGN_PERFORMANCE](#kpi-definitions-mart_campaign_performance)
   - [Which date column to use](#which-date-column-to-use)
5. [MART analysis marts (Phase 4)](#mart-analysis-marts-phase-4)
   - [FCT_CAMPAIGN_DAILY_ACTIVITY](#fct_campaign_daily_activity)
   - [MART_MONTHLY_MARKETING](#mart_monthly_marketing)
   - [MART_MONTHLY_COHORT](#mart_monthly_cohort)
   - [MART_CHANNEL_PERFORMANCE](#mart_channel_performance)
   - [MART_LEAD_QUALITY](#mart_lead_quality)
6. [MART conversion funnel (Phase 6)](#mart-conversion-funnel-phase-6)
   - [MART_CONVERSION_FUNNEL](#mart_conversion_funnel)

## Layers at a glance

| Layer | Object | Kind | Grain (one row per ...) | Primary key | Other unique keys | Rows | Source of the count |
|---|---|---|---|---|---|---:|---|
| RAW | `CAMPAIGNS` | table | campaign | `CAMPAIGN_ID` (source) | | 120 | `02T [9]` |
| RAW | `DAILY_SPEND` | table | campaign × active date | `SPEND_ID` (source) | | 11,240 | `02T [9]` |
| RAW | `LEADS` | table | lead | `LEAD_ID` (source) | | 261,684 | `02T [9]` |
| RAW | `CONVERSIONS` | table | converted lead | `CONVERSION_ID` (source) | | 39,696 | `02T [9]` |
| RAW | `CHALLENGE_CAMPAIGNS` | table | campaign, intended (has 1 exact duplicate) | none (dirty) | | 121 | `02T [21]` |
| RAW | `CHALLENGE_DAILY_SPEND` | table | campaign × date, intended (1 duplicate) | none (dirty) | | 2,001 | `02T [21]` |
| RAW | `CHALLENGE_LEADS` | table | lead, intended (1 duplicate) | none (dirty) | | 2,001 | `02T [21]` |
| RAW | `CHALLENGE_CONVERSIONS` | table | converted lead, intended (1 duplicate) | none (dirty) | | 2,001 | `02T [21]` |
| STAGING | `STG_CAMPAIGNS` | view | campaign | `CAMPAIGN_ID` | `CAMPAIGN_NAME` | 120 | `02 [13]` |
| STAGING | `STG_DAILY_SPEND` | view | campaign × active date | `SPEND_ID` | `(CAMPAIGN_ID, SPEND_DATE)` | 11,240 | `02 [13]` |
| STAGING | `STG_LEADS` | view | lead | `LEAD_ID` | | 261,684 | `02 [13]` |
| STAGING | `STG_CONVERSIONS` | view | converted lead | `CONVERSION_ID` | `LEAD_ID` | 39,696 | `02 [13]` |
| STAGING | `STG_CHALLENGE_CAMPAIGNS` | view | campaign | `CAMPAIGN_ID` | | 120 | `02 [13]` |
| STAGING | `STG_CHALLENGE_DAILY_SPEND` | view | campaign × date | `SPEND_ID` | | 2,000 | `02 [13]` |
| STAGING | `STG_CHALLENGE_LEADS` | view | lead | `LEAD_ID` | | 2,000 | `02 [13]` |
| STAGING | `STG_CHALLENGE_CONVERSIONS` | view | converted lead | `CONVERSION_ID` | | 2,000 | `02 [13]` |
| STAGING | `EXPECTED_CAMPAIGN_KPI` | table (dbt seed, transient) | campaign | `CAMPAIGN_ID` | | 120 | `05P` E |
| STAGING | `EXPECTED_TOTALS` | table (dbt seed, transient) | metric | `METRIC` | | 29 | `05P` E |
| STAGING | `PUBLISHER_CHANNEL_REFERENCE` | table (dbt seed, transient) | channel | `CHANNEL` | | 5 | `05P` E |
| MART | `DIM_DATE` | table | calendar day, 2023-01-01..2025-12-31 | `DATE_DAY` | | 1,096 | `02b [15]`, `02bT [8]` |
| MART | `DIM_CAMPAIGN` | table | campaign | `CAMPAIGN_ID` | `CAMPAIGN_NAME` | 120 | `02b [15]`, `02bT [8]` |
| MART | `FCT_DAILY_SPEND` | table | campaign × active date | `SPEND_ID` | `(CAMPAIGN_ID, SPEND_DATE)` | 11,240 | `02b [15]`, `02bT [8]` |
| MART | `FCT_LEAD_CONVERSIONS` | table | lead (the lead-cohort fact) | `LEAD_ID` | `CONVERSION_ID` where not NULL | 261,684 | `02b [15]`, `02bT [8]` |
| MART | `MART_CAMPAIGN_PERFORMANCE` | table | campaign | `CAMPAIGN_ID` | | 120 | `02b [15]`, `02bT [8]` |
| MART | `FCT_CAMPAIGN_DAILY_ACTIVITY` | table | campaign × day, `START_DATE`..`END_DATE` + 21 | `(CAMPAIGN_ID, ACTIVITY_DATE)` | | 13,760 | `02c [15]`, `02cT [7]` |
| MART | `MART_MONTHLY_MARKETING` | table | month × channel (activity basis) | `(MONTH_START, CHANNEL)` | | 180 | `02c [15]`, `02cT [7]` |
| MART | `MART_MONTHLY_COHORT` | table | lead cohort month × channel | `(COHORT_MONTH, CHANNEL)` | | 180 | `02c [15]`, `02cT [7]` |
| MART | `MART_CHANNEL_PERFORMANCE` | table | channel, full range | `CHANNEL` | | 5 | `02c [15]`, `02cT [7]` |
| MART | `MART_LEAD_QUALITY` | table | channel × 10-point score band | `(CHANNEL, SCORE_BAND)` | | 50 | `02c [15]`, `02cT [7]` |
| MART | `MART_CONVERSION_FUNNEL` | table | channel × funnel stage, full range (Phase 6) | `(CHANNEL, STAGE_ORDER)` | `(CHANNEL, STAGE)` | 25 | `06F` steps 2 and 7 |
| MART | `CONNECTION_TEST` | table | channel × month (Phase 1 only) | | | 159 | `02b [15]`, `02bT [8]` |

Keys: RAW in Phase 2 (`01 §3.1 [8]`, [data_profile.md](data_profile.md#data-quality-summary));
STAGING `02T [11]` (block 5) and `02T [21]` (block 15, challenge views); MART core `02bT [9]`
(block 4); analysis marts `02cT [7]` (no NULL and no duplicated grain key, and exactly the rows
their dimension spines produce); `MART_CONVERSION_FUNNEL` by dbt tests (`06F` steps 2-3).
`CONNECTION_TEST` is the Phase 1 Data Studio test table
([`sql/setup/03_connection_test.sql`](../sql/setup/03_connection_test.sql)): it is not part of
the model, the Phase 3 and Phase 4 files and dbt leave it untouched, and the dashboard and the
export do not use it. It stays for the Phase 1 checks deferred to Phase 6
([phase1_connection_test.md](phase1_connection_test.md), sections D-F).

Who can read what ([architecture.md](architecture.md#security-model)): `CRM_LOADER` writes RAW;
`CRM_TRANSFORMER` reads RAW and owns every STAGING view and MART table; `CRM_REPORTER` (the role
of `SVC_CRM_BI`, the Data Studio service user) reads MART only.

## RAW

The landing zone, loaded by `make load` / `make load-challenge` (role `CRM_LOADER`). Every
business column is `TEXT`, in source column order, exactly as in the file: a blank cell is the
empty string `''`, never NULL, and nothing is trimmed (architecture decision 1). The four
`CHALLENGE_*` tables have the same columns, types and order as their clean counterparts; they hold
the publisher's dirty extracts and are never unioned with the clean release. Only STAGING reads
RAW.

**Lineage columns** (the last three columns of every RAW table, and passed through to every
STAGING view):

| Column | Type | Meaning |
|---|---|---|
| `_SOURCE_FILE` | `TEXT` | Staged file the row came from (`METADATA$FILENAME`). |
| `_SOURCE_ROW_NUMBER` | `NUMBER(38,0)` | Data row in that file, 1 = the first row after the header (`METADATA$FILE_ROW_NUMBER`); the file line is this + 1. |
| `_LOADED_AT` | `TIMESTAMP_LTZ` | Start time of the load (`METADATA$START_SCAN_TIME`). |

### RAW.CAMPAIGNS · RAW.CHALLENGE_CAMPAIGNS

One row per campaign. 120 rows (challenge: 121, including 1 exact duplicate).

| # | Column | Type | Meaning (clean release) |
|---:|---|---|---|
| 1 | `CAMPAIGN_ID` | `TEXT` | Stable campaign key, e.g. `CMP0001` (PK in the source). |
| 2 | `CAMPAIGN_NAME` | `TEXT` | Display name. |
| 3 | `CHANNEL` | `TEXT` | Paid media channel: affiliate, display, paid_search, paid_social, video. |
| 4 | `OBJECTIVE` | `TEXT` | awareness, lead_gen or acquisition. |
| 5 | `START_DATE` | `TEXT` | First active date, text `YYYY-MM-DD`. |
| 6 | `END_DATE` | `TEXT` | Last active date (inclusive), text `YYYY-MM-DD`. |
| 7 | `BUDGET` | `TEXT` | Planned campaign budget, decimal text with 2 dp. |
| 8-10 | lineage | | see above |

### RAW.DAILY_SPEND · RAW.CHALLENGE_DAILY_SPEND

One row per campaign per active date. 11,240 rows (challenge: 2,001, including 1 exact duplicate).

| # | Column | Type | Meaning (clean release) |
|---:|---|---|---|
| 1 | `SPEND_ID` | `TEXT` | Stable delivery key, e.g. `DSP0000001` (PK in the source). |
| 2 | `CAMPAIGN_ID` | `TEXT` | Delivered campaign (FK to CAMPAIGNS). |
| 3 | `SPEND_DATE` | `TEXT` | Delivery date, text `YYYY-MM-DD`. |
| 4 | `IMPRESSIONS` | `TEXT` | Served impressions, integer text. |
| 5 | `CLICKS` | `TEXT` | Recorded clicks, integer text. |
| 6 | `SPEND` | `TEXT` | Media cost, decimal text with 2 dp. |
| 7-9 | lineage | | see above |

### RAW.LEADS · RAW.CHALLENGE_LEADS

One row per lead. 261,684 rows (challenge: 2,001, including 1 exact duplicate).

| # | Column | Type | Meaning (clean release) |
|---:|---|---|---|
| 1 | `LEAD_ID` | `TEXT` | Stable lead key, e.g. `L00000001` (PK in the source). |
| 2 | `CAMPAIGN_ID` | `TEXT` | Attributed campaign (FK to CAMPAIGNS). |
| 3 | `CREATED_AT` | `TEXT` | Lead creation date, text `YYYY-MM-DD` (a date, despite the name; STAGING renames it `CREATED_DATE`). |
| 4 | `LEAD_SOURCE` | `TEXT` | Attributed source channel (equals the campaign channel in v1.0.0). |
| 5 | `LEAD_SCORE` | `TEXT` | Qualification score 1-100, integer text. |
| 6-8 | lineage | | see above |

### RAW.CONVERSIONS · RAW.CHALLENGE_CONVERSIONS

One row per converted lead. 39,696 rows (challenge: 2,001, including 1 exact duplicate).

| # | Column | Type | Meaning (clean release) |
|---:|---|---|---|
| 1 | `CONVERSION_ID` | `TEXT` | Stable conversion key, e.g. `CV0000001` (PK in the source). |
| 2 | `LEAD_ID` | `TEXT` | Converted lead (FK to LEADS, one-to-one). |
| 3 | `CONVERTED_AT` | `TEXT` | Conversion date, text `YYYY-MM-DD` (a date; STAGING renames it `CONVERTED_DATE`). |
| 4 | `CONVERSION_TYPE` | `TEXT` | trial or purchase. |
| 5 | `REVENUE` | `TEXT` | Attributed revenue (last touch), decimal text with 2 dp; 0.00 for trials. |
| 6-8 | lineage | | see above |

## STAGING

Eight views, one per RAW table, at the RAW table's grain after de-duplication: built by
`make staging` (`sql/02_data_cleaning.sql`) in Phase 3 and by dbt since Phase 5 (the models
`dbt/models/staging/stg_*.sql`, rules in `dbt/macros/staging/`), with the same names, columns and
rows. Views follow the dbt staging convention: always in sync with RAW, nothing stored, no
refresh step. Since Phase 5 STAGING also holds three small seed tables, test inputs only
([Seeds (Phase 5)](#seeds-phase-5)).

- **Clean track:** `STG_CAMPAIGNS`, `STG_DAILY_SPEND`, `STG_LEADS`, `STG_CONVERSIONS`. The only
  input of MART.
- **Challenge track:** `STG_CHALLENGE_*`, the same rules on the dirty extracts, plus two
  provable fills in separate `*_FILLED` columns. Used only to reconcile against the clean views
  (`02T` blocks 15-19); MART never reads them, because every challenge key also exists in the
  clean release.
- **Every row is kept.** A problem is flagged in `DQ_ISSUES`, never silently dropped or fixed in
  place. In the clean views every row is valid: 0 issue codes on 120 / 11,240 / 261,684 / 39,696
  rows (`02 [13]`, `02T [10]`).
- **Column order in every view:** the business columns, then `DQ_ISSUES`, `DQ_IS_VALID` and the
  three lineage columns of the row that was kept. The challenge views append their fill column at
  the end, so their first columns line up with the clean view position by position (`02T [6]`).

### RAW to STAGING mapping

Every RAW business column maps to exactly one STAGING column of the same name, except the two
date columns of leads and conversions, which are renamed because their values are dates, not
timestamps. The rule kinds are defined in the next section.

| RAW table | RAW column (`TEXT`) | STAGING column | STAGING type | Rule kind |
|---|---|---|---|---|
| CAMPAIGNS | `CAMPAIGN_ID` | `CAMPAIGN_ID` | `TEXT` | id |
| | `CAMPAIGN_NAME` | `CAMPAIGN_NAME` | `TEXT` | name |
| | `CHANNEL` | `CHANNEL` | `TEXT` | code |
| | `OBJECTIVE` | `OBJECTIVE` | `TEXT` | code |
| | `START_DATE` | `START_DATE` | `DATE` | date |
| | `END_DATE` | `END_DATE` | `DATE` | date |
| | `BUDGET` | `BUDGET` | `NUMBER(12,2)` | money |
| | (derived) | `CAMPAIGN_DAYS` | `NUMBER(38,0)` | `END_DATE - START_DATE + 1` |
| DAILY_SPEND | `SPEND_ID` | `SPEND_ID` | `TEXT` | id |
| | `CAMPAIGN_ID` | `CAMPAIGN_ID` | `TEXT` | id |
| | `SPEND_DATE` | `SPEND_DATE` | `DATE` | date |
| | `IMPRESSIONS` | `IMPRESSIONS` | `NUMBER(38,0)` | integer |
| | `CLICKS` | `CLICKS` | `NUMBER(38,0)` | integer |
| | `SPEND` | `SPEND` | `NUMBER(12,2)` | money |
| LEADS | `LEAD_ID` | `LEAD_ID` | `TEXT` | id |
| | `CAMPAIGN_ID` | `CAMPAIGN_ID` | `TEXT` | id |
| | `CREATED_AT` | **`CREATED_DATE`** (renamed) | `DATE` | date |
| | `LEAD_SOURCE` | `LEAD_SOURCE` | `TEXT` | code |
| | `LEAD_SCORE` | `LEAD_SCORE` | `NUMBER(3,0)` | integer (3 digits) |
| CONVERSIONS | `CONVERSION_ID` | `CONVERSION_ID` | `TEXT` | id |
| | `LEAD_ID` | `LEAD_ID` | `TEXT` | id |
| | `CONVERTED_AT` | **`CONVERTED_DATE`** (renamed) | `DATE` | date |
| | `CONVERSION_TYPE` | `CONVERSION_TYPE` | `TEXT` | code |
| | `REVENUE` | `REVENUE` | `NUMBER(12,2)` | money |
| every table | `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER`, `_LOADED_AT` | same names | same types | passed through from the kept copy |
| (new) | | `DQ_ISSUES`, `DQ_IS_VALID` | `ARRAY`, `BOOLEAN` | see [DQ_ISSUES codes](#dq_issues-codes) |
| CHALLENGE_CAMPAIGNS | (derived) | `CAMPAIGN_NAME_FILLED` | `TEXT` | provable fill, challenge view only |
| CHALLENGE_DAILY_SPEND | (derived) | `SPEND_DATE_FILLED` | `DATE` | provable fill, challenge view only |

The `CHALLENGE_*` RAW tables map the same way to the `STG_CHALLENGE_*` views.

### Cleaning rule kinds

Every rule reads the trimmed value `T = NULLIF(TRIM(x, ' \t\r\n'), '')`: edges trimmed of
space, tab, CR and LF, and a blank (`''` or whitespace only) turned into NULL. The same rules run
in all 8 views. Why each rule looks the way it does (lenient `TRY_` casts, shape routing, the
`INITCAP` caveat, regex escaping) is explained in [data_cleaning.md](data_cleaning.md#the-rules).

| Kind | Typed value | Accepted shape (else flagged) | Value when the shape is wrong |
|---|---|---|---|
| id | `UPPER(T)` | `CMP[0-9]{4}`, `DSP[0-9]{7}`, `L[0-9]{8}`, `CV[0-9]{7}` | kept, `nonconforming` |
| code | `LOWER(T)` | snake_case `[a-z]+(_[a-z]+)*` | kept, `nonconforming` |
| name | `INITCAP(T)` (`CAMPAIGN_NAME` only, never a code) | `<Channel Words> <yyyy> <nnn>` | kept, `nonconforming` |
| date | ISO `[0-9]{4}-[0-9]{2}-[0-9]{2}` → `TRY_TO_DATE(T, 'YYYY-MM-DD')`; year-first slash `[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}` → `TRY_TO_DATE(T, 'YYYY/MM/DD')`, flagged `slash_ymd` | one of the two shapes, and a real date | NULL, `unparseable` |
| integer | `TRY_TO_NUMBER(T, 38, 0)`; `LEAD_SCORE`: `TRY_TO_NUMBER(T, 3, 0)` | `[0-9]+` | NULL, `unparseable` |
| money | `TRY_TO_NUMBER(T, 12, 2)` | `[0-9]+[.][0-9]{2}` | NULL, `unparseable` |

De-duplication: one row per key, `QUALIFY ROW_NUMBER() OVER (PARTITION BY <key> ORDER BY <number
of NULL business fields> ASC, _SOURCE_ROW_NUMBER ASC) = 1`. The most complete copy wins, then the
first one in the file; the lineage columns describe that copy. A row whose key is missing is never
collapsed with another one.

### DQ_ISSUES codes

`DQ_ISSUES` is an `ARRAY` of `'<column>:<issue>'` strings, one per problem cell, plus row-level
codes. `<column>` is the STAGING column name in lower case (so `created_date`, not `created_at`).
A clean row has an empty array, and `DQ_IS_VALID = (ARRAY_SIZE(DQ_ISSUES) = 0)`.

| Code | Meaning | Columns it can appear on | Value in STAGING |
|---|---|---|---|
| `<column>:missing` | Blank (`''` or whitespace only) or NULL in RAW | every business column | NULL |
| `<column>:untrimmed` | Leading or trailing whitespace (space, tab, CR, LF) was removed | every business column | the trimmed value |
| `<column>:recased` | The letter case was changed (id upper, code lower, name initcap) | ids, codes, `campaign_name` | the recased value |
| `<column>:nonconforming` | Kept, but does not fit the documented shape of an id, code or name | ids, codes, `campaign_name` | kept as is (after trim and recasing) |
| `<column>:slash_ymd` | A year-first slash date, parsed as Y/M/D | date columns | the parsed date |
| `<column>:unparseable` | Date or number text that fits no accepted shape, or fails the cast (e.g. `2023-02-29`) | date and number columns | NULL |
| `row:duplicate_copies=N` | The key had N copies in RAW; one row is kept | row | the kept copy |
| `row:duplicate_copies_differ` | The copies of a key disagree after cleaning | row | the kept copy |

Observed (`02 [13]`): the clean views carry no code. The challenge views carry 18 codes on 15
rows (4 / 3 / 4 / 4 rows per view):

| View | Codes (1 row each) |
|---|---|
| `STG_CHALLENGE_CAMPAIGNS` | `row:duplicate_copies=2`, `campaign_name:untrimmed`, `campaign_name:recased`, `start_date:slash_ymd`, `campaign_name:missing` |
| `STG_CHALLENGE_DAILY_SPEND` | `row:duplicate_copies=2`, `spend_date:slash_ymd`, `spend_date:missing` |
| `STG_CHALLENGE_LEADS` | `row:duplicate_copies=2`, `lead_source:untrimmed`, `lead_source:recased`, `created_date:slash_ymd`, `created_date:missing` |
| `STG_CHALLENGE_CONVERSIONS` | `row:duplicate_copies=2`, `conversion_type:untrimmed`, `conversion_type:recased`, `converted_date:slash_ymd`, `converted_date:missing` |

Business rules (clicks ≤ impressions, trial ⇒ revenue 0.00, ...) are not flags. They are tests
(`02T [15]`, block 9).

### Views

The tables below list the business columns. Every view ends with the five common columns:

| Column | Type | Meaning |
|---|---|---|
| `DQ_ISSUES` | `ARRAY` | Issue codes of the row, empty when clean ([codes](#dq_issues-codes)). |
| `DQ_IS_VALID` | `BOOLEAN` | `ARRAY_SIZE(DQ_ISSUES) = 0`. TRUE on every row of the clean views (`02T [10]`). |
| `_SOURCE_FILE` | `TEXT` | Lineage of the kept copy (see [RAW](#raw)). |
| `_SOURCE_ROW_NUMBER` | `NUMBER(38,0)` | Lineage of the kept copy. |
| `_LOADED_AT` | `TIMESTAMP_LTZ` | Lineage of the kept copy. |

**NULLs.** In the four clean views, the 23 business columns and `CAMPAIGN_DAYS` have 0 NULL
cells (`02T [12]`, block 6: 24 columns). In the challenge views a NULL business value marks a
defect: its cell carries a `missing` or `unparseable` code (today: the 4 blank cells, `02T [22]`).

#### STG_CAMPAIGNS

One row per campaign; 120 rows. PK `CAMPAIGN_ID`; `CAMPAIGN_NAME` is unique too (`02T [11]`).
13 columns.

| # | Column | Type | Meaning |
|---:|---|---|---|
| 1 | `CAMPAIGN_ID` | `TEXT` | Campaign key, e.g. `CMP0001`. |
| 2 | `CAMPAIGN_NAME` | `TEXT` | Display name, `<Channel Words> <yyyy> <nnn>`, e.g. `Display 2023 008`. |
| 3 | `CHANNEL` | `TEXT` | affiliate, display, paid_search, paid_social, video: 24 campaigns each (`02T [13]`). |
| 4 | `OBJECTIVE` | `TEXT` | acquisition (35), awareness (44), lead_gen (41) (`02T [13]`). |
| 5 | `START_DATE` | `DATE` | First day of the campaign window; 2023-01-04..2025-08-28 (`02T [16]`). |
| 6 | `END_DATE` | `DATE` | Last day of the window, inclusive; 2023-03-14..2025-12-02 (`02T [16]`). |
| 7 | `BUDGET` | `NUMBER(12,2)` | Budget for the whole window; total 5,418,642.16 (`02T [18]`). |
| 8 | `CAMPAIGN_DAYS` | `NUMBER(38,0)` | Derived: `END_DATE - START_DATE + 1`, the inclusive window length. 46..150; equals the campaign's number of spend rows; sums to 11,240 (`02T [17]`). |
| 9-13 | common | | |

#### STG_DAILY_SPEND

One row per campaign per active date; 11,240 rows. PK `SPEND_ID`; `(CAMPAIGN_ID, SPEND_DATE)` is
unique (`02T [11]`). 11 columns. Aggregate it to the campaign (or campaign × date) before joining
any other fact.

| # | Column | Type | Meaning |
|---:|---|---|---|
| 1 | `SPEND_ID` | `TEXT` | Delivery key, e.g. `DSP0000001`. |
| 2 | `CAMPAIGN_ID` | `TEXT` | FK to `STG_CAMPAIGNS` (0 orphans, `02T [14]`). |
| 3 | `SPEND_DATE` | `DATE` | Delivery date; 2023-01-04..2025-12-02, 1,064 distinct dates (`02T [16]`). |
| 4 | `IMPRESSIONS` | `NUMBER(38,0)` | Served impressions; total 436,844,819 (`02T [18]`). |
| 5 | `CLICKS` | `NUMBER(38,0)` | Recorded clicks; total 7,102,319 (`02T [18]`). |
| 6 | `SPEND` | `NUMBER(12,2)` | Media cost; total 4,523,050.02 (`02T [18]`). |
| 7-11 | common | | |

#### STG_LEADS

One row per lead; 261,684 rows. PK `LEAD_ID` (`02T [11]`). 10 columns.

| # | Column | Type | Meaning |
|---:|---|---|---|
| 1 | `LEAD_ID` | `TEXT` | Lead key, e.g. `L00000001`. |
| 2 | `CAMPAIGN_ID` | `TEXT` | Attributed campaign, FK to `STG_CAMPAIGNS` (0 orphans, `02T [14]`). |
| 3 | `CREATED_DATE` | `DATE` | Lead creation date (RAW `CREATED_AT`); 2023-01-04..2025-12-02 (`02T [16]`). |
| 4 | `LEAD_SOURCE` | `TEXT` | Source channel as delivered. Equals the campaign's `CHANNEL` for all 261,684 leads (`02T [20]`, a WARN-level check); use `CHANNEL` from the campaign. |
| 5 | `LEAD_SCORE` | `NUMBER(3,0)` | Qualification score; between 1 and 100 on every row (`02T [15]`); sum 13,233,637 (`02T [18]`). How it is produced is undocumented. |
| 6-10 | common | | |

#### STG_CONVERSIONS

One row per converted lead; 39,696 rows. PK `CONVERSION_ID`; `LEAD_ID` is unique too: a lead
converts at most once (`02T [11]`). 10 columns.

| # | Column | Type | Meaning |
|---:|---|---|---|
| 1 | `CONVERSION_ID` | `TEXT` | Conversion key, e.g. `CV0000001`. |
| 2 | `LEAD_ID` | `TEXT` | Converted lead, FK to `STG_LEADS` (0 orphans; 221,988 leads have no conversion, `02T [14]`). |
| 3 | `CONVERTED_DATE` | `DATE` | Conversion date (RAW `CONVERTED_AT`); 2023-01-05..2025-12-21 (`02T [16]`); 0 to 21 days after the lead (`02T [17]`). |
| 4 | `CONVERSION_TYPE` | `TEXT` | trial (23,005) or purchase (16,691) (`02T [13]`). |
| 5 | `REVENUE` | `NUMBER(12,2)` | Last-touch attributed revenue; 0.00 for every trial, > 0 for every purchase (`02T [15]`); total 21,561,839.01 (`02T [18]`). |
| 6-10 | common | | |

#### STG_CHALLENGE_CAMPAIGNS · STG_CHALLENGE_DAILY_SPEND · STG_CHALLENGE_LEADS · STG_CHALLENGE_CONVERSIONS

The same columns, types and order as the clean view, then (for two of them) one fill column at
the end (`02T [6]`). 120 / 2,000 / 2,000 / 2,000 rows from 121 / 2,001 / 2,001 / 2,001 RAW rows;
every key unique and not NULL (`02T [21]`). Reconciliation only: never read by MART.

| View | # | Extra column | Type | Meaning |
|---|---:|---|---|---|
| `STG_CHALLENGE_CAMPAIGNS` | 14 | `CAMPAIGN_NAME_FILLED` | `TEXT` | `COALESCE(CAMPAIGN_NAME, INITCAP(REPLACE(CHANNEL, '_', ' ')) \|\| ' ' \|\| YEAR(START_DATE) \|\| ' ' \|\| RIGHT(CAMPAIGN_ID, 3))`: the campaign naming rule fills a blank name. |
| `STG_CHALLENGE_DAILY_SPEND` | 12 | `SPEND_DATE_FILLED` | `DATE` | `COALESCE(SPEND_DATE, previous + 1 day)`, only when previous + 1 = next − 1, with previous and next taken in `SPEND_ID` order within the campaign (`LAG` / `LEAD`). |

`STG_CHALLENGE_LEADS.CREATED_DATE` and `STG_CHALLENGE_CONVERSIONS.CONVERTED_DATE` have no fill
column: their blank dates are not uniquely recoverable and stay NULL
([data_cleaning.md](data_cleaning.md#challenge-track-results)).

### Seeds (Phase 5)

Three tables that `dbt build` loads from the CSV files in [`dbt/seeds/`](../dbt/seeds/): the
expected values the dbt tests compare the models with. **No model reads them**, so they are not
part of the data model; `CRM_REPORTER` (Data Studio) cannot see STAGING at all. They are
transient tables (dbt's seed default; no Fail-safe), owned by `CRM_TRANSFORMER`
(`05P` A.2), and `sql/02_data_cleaning_tests.sql` block 1 lists them as allowed non-contract
objects of STAGING (`05P` D). Each table and column has a comment from
[`dbt/seeds/_seeds.yml`](../dbt/seeds/_seeds.yml). How they are made and checked:
[dbt.md](dbt.md#seeds-independent-expected-values).

| Table | Rows | Columns (type) | Made by | Read by |
|---|---:|---|---|---|
| `EXPECTED_CAMPAIGN_KPI` | 120 | `CAMPAIGN_ID`, `CHANNEL`, `OBJECTIVE` (`TEXT`); `BUDGET` (`NUMBER(12,2)`); `SPEND_DAYS` (`NUMBER(38,0)`); `SPEND` (`NUMBER(18,2)`); `IMPRESSIONS`, `CLICKS`, `LEADS`, `CONVERTED_LEADS`, `TRIALS`, `PURCHASES` (`NUMBER(38,0)`); `REVENUE` (`NUMBER(18,2)`) | `scripts/independent_check.py` from the CSV files (Python `csv` + `decimal`, no Snowflake) | 3 singular tests: campaign bases, campaign attributes, prorated budget |
| `EXPECTED_TOTALS` | 29 | `METRIC` (`TEXT`), `VALUE` (`NUMBER(38,6)`; counts are whole numbers) | the same script | 8 singular tests: control totals, spend, time counts, score segments, calendar, RAW row counts |
| `PUBLISHER_CHANNEL_REFERENCE` | 5 | `CHANNEL` (`TEXT`), `SPEND`, `ATTRIBUTED_REVENUE` (`NUMBER(18,2)`) | typed in by hand from the publisher's dataset page; `make expected-seeds-check` compares it with the CSV roll-up | 1 singular test: the channel roll-up of MART |

The types are the `column_types` that `dbt/dbt_project.yml` sets for the seeds. Which test reads
which seed: [lineage.md](lineage.md#seeds-and-singular-tests).

## MART core

Five tables built from the four clean `STG_*` views only, never from `STG_CHALLENGE_*`: by
`make marts` (`sql/02b_core_models.sql`) in Phase 3 and by dbt since Phase 5
(`dbt/models/marts/`, permanent tables with the same names, columns and rows). They are tables,
not views, because Data Studio queries them repeatedly; each one rebuilds from STAGING in seconds.
In the dbt build `FCT_LEAD_CONVERSIONS` reads the campaign attributes from `STG_CAMPAIGNS` through
the ephemeral `int_lead_conversions` instead of from `DIM_CAMPAIGN`; the values are identical
(tested against the independent seed, [dbt.md](dbt.md#tests)).

- **Grain rule.** A fact is only ever joined to something with one row per join key: a fact to a
  dimension (n:1), or two inputs each aggregated to the same grain first (1:1). Two facts are
  never joined row by row ([architecture.md](architecture.md#design-decisions), decision 6).
  Total spend is 4,523,050.02 in every table that carries spend (`02bT [14]`).
- **Names and comments.** UPPERCASE ASCII column names (Data Studio field names, kept by the
  Sheets snapshot). Every table and every column has a COMMENT (`02b [15]`: columns with a
  comment = columns, in all five tables; `02bT [6]`: table comments).
- **Types.** Counts `NUMBER(38,0)`; 0/1 flags `NUMBER(1,0)`, so they SUM; money as delivered
  `NUMBER(12,2)` (daily spend, revenue per lead, campaign budget) and summed per campaign
  `NUMBER(18,2)` (`MART_CAMPAIGN_PERFORMANCE.SPEND`, `REVENUE`); rates, ROAS and
  `BUDGET_PRORATED` `NUMBER(18,6)`; cost per unit `NUMBER(18,4)`; months are `DATE`s (the first
  day of the month), so Data Studio treats them as dates.
- **Roles** in the column tables: *key*, *FK*, *attribute* (group or filter by it), *measure*
  (additive: SUM it), *flag* (0/1, additive), *ratio* (campaign grain only), *date*.
- **NULLs.** Every column that must have a value has 0 NULL cells (`02bT [10]`, block 5). The
  only columns that may be NULL are the five conversion columns of `FCT_LEAD_CONVERSIONS` (NULL
  exactly when the lead did not convert, `02bT [15]`) and the ratio columns of
  `MART_CAMPAIGN_PERFORMANCE` (NULL when a denominator is 0; 0 such campaigns today, `02bT [20]`).

### Tables

#### DIM_DATE

One row per calendar day, gap-free from 2023-01-01 to 2025-12-31, the documented coverage of the
dataset; 1,096 rows, 36 months, 158 ISO weeks, 313 weekend days (`02bT [12]`). PK `DATE_DAY`.
32 of the days have no spend row, 32 have no lead and 16 have no conversion (`02bT [11]`): the
spine keeps them, so they show as 0 on a time axis.

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `DATE_DAY` | `DATE` | key | Calendar day. Join key for `SPEND_DATE`, `CREATED_DATE`, `CONVERTED_DATE`. |
| 2 | `YEAR` | `NUMBER(4,0)` | attribute | Calendar year. |
| 3 | `QUARTER` | `NUMBER(1,0)` | attribute | Calendar quarter, 1-4. |
| 4 | `MONTH_START` | `DATE` | attribute | First day of the month. Join key for `SPEND_MONTH`, `CREATED_MONTH`, `CONVERTED_MONTH`. |
| 5 | `MONTH_NAME` | `TEXT` | attribute | Full English month name, e.g. January. |
| 6 | `WEEK_START` | `DATE` | attribute | Monday of the ISO week (from `DAYOFWEEKISO`, independent of the `WEEK_START` session parameter). The first week starts 2022-12-26, before the spine. |
| 7 | `DAY_OF_WEEK_ISO` | `NUMBER(1,0)` | attribute | 1 = Monday ... 7 = Sunday. |
| 8 | `DAY_NAME` | `TEXT` | attribute | Full English day name, e.g. Monday. |
| 9 | `IS_WEEKEND` | `BOOLEAN` | attribute | TRUE on Saturday and Sunday. A filter, never a measure (the only BOOLEAN in MART). |

#### DIM_CAMPAIGN

One row per campaign; 120 rows. PK `CAMPAIGN_ID`; `CAMPAIGN_NAME` is unique too (`02bT [9]`).
Source: `STG_CAMPAIGNS`. `CHANNEL` here is the canonical channel dimension of every MART table.

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CAMPAIGN_ID` | `TEXT` | key | Campaign key, e.g. `CMP0001`. |
| 2 | `CAMPAIGN_NAME` | `TEXT` | attribute | Campaign name, unique. |
| 3 | `CHANNEL` | `TEXT` | attribute | affiliate, display, paid_search, paid_social, video. Leads' `LEAD_SOURCE` only duplicates it. |
| 4 | `OBJECTIVE` | `TEXT` | attribute | acquisition, awareness, lead_gen. Partly confounded with channel (display is 17 of 24 lead_gen, [data_profile.md](data_profile.md#structure-and-grain)), so compare objectives within a channel. |
| 5 | `START_DATE` | `DATE` | attribute | First day of the campaign window. |
| 6 | `END_DATE` | `DATE` | attribute | Last day of the window. Conversions of its leads can land up to 21 days later. |
| 7 | `CAMPAIGN_DAYS` | `NUMBER(38,0)` | attribute | `END_DATE - START_DATE + 1`; equals the campaign's number of spend rows. |
| 8 | `BUDGET` | `NUMBER(12,2)` | measure | Budget for the whole window. Additive across campaigns, **not across dates**: for budget by month or year use `FCT_DAILY_SPEND.BUDGET_PRORATED`. Total 5,418,642.16 (`02bT [14]`). |
| 9 | `START_YEAR` | `NUMBER(4,0)` | attribute | Year of `START_DATE` (campaigns can run into the next year). |
| 10 | `START_MONTH` | `DATE` | attribute | First day of the month of `START_DATE`. |

#### FCT_DAILY_SPEND

The delivery fact: one row per campaign per active day; 11,240 rows. PK `SPEND_ID`;
`(CAMPAIGN_ID, SPEND_DATE)` is unique (`02bT [9]`). Source: `STG_DAILY_SPEND`, with `CHANNEL` and
`OBJECTIVE` looked up n:1 in `DIM_CAMPAIGN` (one campaign row per key, so no fan-out).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `SPEND_ID` | `TEXT` | key | Spend row key. |
| 2 | `CAMPAIGN_ID` | `TEXT` | FK | to `DIM_CAMPAIGN`. |
| 3 | `SPEND_DATE` | `DATE` | date, FK | Activity date, to `DIM_DATE.DATE_DAY`. |
| 4 | `SPEND_MONTH` | `DATE` | date | Activity month: `DATE_TRUNC('month', SPEND_DATE)`. |
| 5 | `CHANNEL` | `TEXT` | attribute | Channel of the campaign, from `DIM_CAMPAIGN`. |
| 6 | `OBJECTIVE` | `TEXT` | attribute | Objective of the campaign, from `DIM_CAMPAIGN`. |
| 7 | `IMPRESSIONS` | `NUMBER(38,0)` | measure | Impressions on the day; total 436,844,819 (`02bT [14]`). |
| 8 | `CLICKS` | `NUMBER(38,0)` | measure | Clicks on the day; total 7,102,319. CTR = `SUM(CLICKS) / SUM(IMPRESSIONS)`. |
| 9 | `SPEND` | `NUMBER(12,2)` | measure | Media spend on the day; total 4,523,050.02. CPC = `SUM(SPEND) / SUM(CLICKS)`. |
| 10 | `BUDGET_PRORATED` | `NUMBER(18,6)` | measure | Campaign `BUDGET / CAMPAIGN_DAYS`, rounded once to 6 dp: the budget spread evenly over the window days, for budget totals by month or year. Sums back to each campaign's budget within 0.01 (0 campaigns outside; table total 5,418,642.159820, `02bT [14]`). An even spread is an assumption, not observed pacing: do not report `SPEND / BUDGET_PRORATED` below whole campaigns as budget utilisation. |

#### FCT_LEAD_CONVERSIONS

The lead-cohort fact: one row per lead, converted or not; 261,684 rows. PK `LEAD_ID`;
`CONVERSION_ID` is unique where it is not NULL (221,988 NULLs = unconverted leads, `02bT [9]`).
Source: `STG_LEADS` LEFT JOIN `STG_CONVERSIONS` on `LEAD_ID` (1:0..1, because `LEAD_ID` is unique in
conversions), plus `DIM_CAMPAIGN` (n:1). Cohort KPIs group by `CREATED_MONTH`; `CONVERTED_MONTH`
is the activity month; the two are never put on one date axis
([architecture.md](architecture.md#design-decisions), decision 7).

| # | Column | Type | Role | Meaning | NULL when |
|---:|---|---|---|---|---|
| 1 | `LEAD_ID` | `TEXT` | key | Lead key. | never |
| 2 | `CAMPAIGN_ID` | `TEXT` | FK | Campaign the lead is attributed to, to `DIM_CAMPAIGN`. | never |
| 3 | `CHANNEL` | `TEXT` | attribute | Channel of the campaign, from `DIM_CAMPAIGN`. Use this, not `LEAD_SOURCE`. | never |
| 4 | `OBJECTIVE` | `TEXT` | attribute | Objective of the campaign. | never |
| 5 | `CREATED_DATE` | `DATE` | date, FK | Lead creation date (cohort date), to `DIM_DATE.DATE_DAY`. The first date column, so Data Studio may pick it as the default date-range dimension: a date-range control then filters leads by cohort. | never |
| 6 | `CREATED_MONTH` | `DATE` | date | Lead cohort month: `DATE_TRUNC('month', CREATED_DATE)`. | never |
| 7 | `LEAD_SOURCE` | `TEXT` | attribute | Lead source as delivered; equals `CHANNEL` for every lead today. Kept for lineage. | never |
| 8 | `LEAD_SCORE` | `NUMBER(3,0)` | attribute | Lead score 1-100; how it is produced is undocumented, and it is not assumed to predict conversion. | never |
| 9 | `LEAD_SCORE_SEGMENT` | `TEXT` | attribute | `Low` (1-40), `Medium` (41-70), `High` (71-100): 104,245 / 78,862 / 78,577 leads (`02bT [16]`). | never (would be NULL for a missing or out-of-range score) |
| 10 | `CONVERSION_ID` | `TEXT` | attribute | Conversion key. | not converted |
| 11 | `CONVERTED_DATE` | `DATE` | date, FK | Conversion date, to `DIM_DATE.DATE_DAY`. | not converted |
| 12 | `CONVERTED_MONTH` | `DATE` | date | Activity month of the conversion. Never on one axis with `CREATED_MONTH`. | not converted |
| 13 | `CONVERSION_TYPE` | `TEXT` | attribute | trial or purchase. | not converted |
| 14 | `IS_CONVERTED` | `NUMBER(1,0)` | flag | 1 if the lead converted (trial or purchase). `SUM` = converted leads (39,696); `SUM / COUNT(LEAD_ID)` = lead conversion rate. | never |
| 15 | `IS_TRIAL` | `NUMBER(1,0)` | flag | 1 if the lead converted to a trial (sum 23,005). | never |
| 16 | `IS_PURCHASE` | `NUMBER(1,0)` | flag | 1 if the lead converted to a purchase (sum 16,691). `SUM / COUNT(LEAD_ID)` = purchase rate. | never |
| 17 | `REVENUE` | `NUMBER(12,2)` | measure | Last-touch attributed revenue, `COALESCE(revenue, 0)`: 0.00 for trials and unconverted leads, so it sums (total 21,561,839.01). `SUM / COUNT(LEAD_ID)` = revenue per lead. | never |
| 18 | `DAYS_TO_CONVERT` | `NUMBER(38,0)` | measure | `DATEDIFF('day', CREATED_DATE, CONVERTED_DATE)`, 0..21 (`02bT [15]`). `AVG` covers converted leads only. | not converted |
| 19 | `CONVERTED_AFTER_CAMPAIGN_END` | `NUMBER(1,0)` | flag | 1 if `CONVERTED_DATE` is after the campaign's `END_DATE` (4,716 leads, `02bT [15]`). A campaign-window filter would drop these conversions. | never |
| 20 | `AS_OF_DATE` | `DATE` | attribute | 2025-12-31, the end of the documented coverage. **An assumption**: the data alone does not prove the youngest cohorts complete ([data_profile.md](data_profile.md#time)). | never |
| 21 | `IS_MATURE` | `NUMBER(1,0)` | flag | 1 if `CREATED_DATE <= AS_OF_DATE - 21` days (21 = the observed maximum lag): the lead has had its full conversion window. 1 for all 261,684 leads under the assumption (`02bT [15]`). | never |

`02bT [14]` totals: 261,684 rows, `SUM(IS_CONVERTED)` 39,696, `SUM(IS_TRIAL)` 23,005,
`SUM(IS_PURCHASE)` 16,691, `SUM(REVENUE)` 21,561,839.01, `SUM(LEAD_SCORE)` 13,233,637.

#### MART_CAMPAIGN_PERFORMANCE

One row per campaign; 120 rows. PK `CAMPAIGN_ID` (`02bT [9]`). This is the grain-safe pattern:
spend (`STG_DAILY_SPEND`), leads (`STG_LEADS`) and conversions (`STG_CONVERSIONS`, via their lead)
are each aggregated to one row per campaign in their own CTE, and only then joined 1:1 to
`DIM_CAMPAIGN`. Its 12 base and attribute columns equal the Phase 2 baseline (the local pre-load
KPI profile, [data_cleaning.md](data_cleaning.md#how-it-was-produced)), and its 9 ratio
columns equal an independent Python computation, for 120 of 120 campaigns each (`02bT [17]`).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CAMPAIGN_ID` | `TEXT` | key | Campaign key. |
| 2 | `CAMPAIGN_NAME` | `TEXT` | attribute | From `DIM_CAMPAIGN`. |
| 3 | `CHANNEL` | `TEXT` | attribute | Canonical channel, from `DIM_CAMPAIGN`. |
| 4 | `OBJECTIVE` | `TEXT` | attribute | From `DIM_CAMPAIGN`. |
| 5 | `START_DATE` | `DATE` | attribute | First day of the window. A campaign attribute, **not an activity date** (see [Which date column to use](#which-date-column-to-use)). |
| 6 | `END_DATE` | `DATE` | attribute | Last day of the window. A campaign attribute, not an activity date. |
| 7 | `CAMPAIGN_DAYS` | `NUMBER(38,0)` | attribute | `END_DATE - START_DATE + 1`. |
| 8 | `START_YEAR` | `NUMBER(4,0)` | attribute | Year of `START_DATE`; 23 campaigns run into the next year, so it is not an activity year. |
| 9 | `START_MONTH` | `DATE` | attribute | First day of the month of `START_DATE`; not an activity month. |
| 10 | `BUDGET` | `NUMBER(12,2)` | measure | Campaign budget for the whole window. Additive across campaigns. |
| 11 | `SPEND_DAYS` | `NUMBER(38,0)` | measure | Number of spend rows (active days). |
| 12 | `IMPRESSIONS` | `NUMBER(38,0)` | measure | Sum of daily impressions. |
| 13 | `CLICKS` | `NUMBER(38,0)` | measure | Sum of daily clicks. |
| 14 | `SPEND` | `NUMBER(18,2)` | measure | Sum of daily spend; total 4,523,050.02. |
| 15 | `LEADS` | `NUMBER(38,0)` | measure | Leads attributed to the campaign. |
| 16 | `CONVERTED_LEADS` | `NUMBER(38,0)` | measure | Leads that converted (trial or purchase). |
| 17 | `TRIALS` | `NUMBER(38,0)` | measure | Leads that converted to a trial. |
| 18 | `PURCHASES` | `NUMBER(38,0)` | measure | Leads that converted to a purchase. |
| 19 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue of the campaign's leads; total 21,561,839.01. |
| 20-28 | KPI columns | `NUMBER(18,6)` / `NUMBER(18,4)` | ratio | See [KPI definitions](#kpi-definitions-mart_campaign_performance). |

A campaign without leads or conversions would get 0 in those columns (`COALESCE`), not lose its
spend. Totals: `02bT [14]`.

### KPI definitions: MART_CAMPAIGN_PERFORMANCE

All nine are computed from the campaign sums in the same row, after the 1:1 joins. Each
denominator is wrapped in `NULLIF(denominator, 0)`, so a zero denominator gives NULL, never a
division error or a fake 0.

| # | Column | Formula | Numerator | Denominator | Type (dp) | Aggregate across campaigns as |
|---:|---|---|---|---|---|---|
| 20 | `CTR` | clicks per impression | `CLICKS` | `IMPRESSIONS` | `NUMBER(18,6)` (6) | `SUM(CLICKS) / SUM(IMPRESSIONS)` |
| 21 | `CLICK_TO_LEAD_RATE` | leads per click | `LEADS` | `CLICKS` | `NUMBER(18,6)` (6) | `SUM(LEADS) / SUM(CLICKS)` |
| 22 | `LEAD_CONVERSION_RATE` | converted leads (trial or purchase) per lead | `CONVERTED_LEADS` | `LEADS` | `NUMBER(18,6)` (6) | `SUM(CONVERTED_LEADS) / SUM(LEADS)` |
| 23 | `PURCHASE_RATE` | purchases per lead | `PURCHASES` | `LEADS` | `NUMBER(18,6)` (6) | `SUM(PURCHASES) / SUM(LEADS)` |
| 24 | `COST_PER_LEAD` | spend per lead | `SPEND` | `LEADS` | `NUMBER(18,4)` (4) | `SUM(SPEND) / SUM(LEADS)` |
| 25 | `COST_PER_CONVERSION` | spend per converted lead | `SPEND` | `CONVERTED_LEADS` | `NUMBER(18,4)` (4) | `SUM(SPEND) / SUM(CONVERTED_LEADS)` |
| 26 | `COST_PER_PURCHASE` | spend per purchase | `SPEND` | `PURCHASES` | `NUMBER(18,4)` (4) | `SUM(SPEND) / SUM(PURCHASES)` |
| 27 | `ROAS` | attributed revenue per unit of spend | `REVENUE` | `SPEND` | `NUMBER(18,6)` (6) | `SUM(REVENUE) / SUM(SPEND)` |
| 28 | `BUDGET_UTILIZATION` | share of the budget spent | `SPEND` | `BUDGET` | `NUMBER(18,6)` (6) | `SUM(SPEND) / SUM(BUDGET)`, over whole campaigns only |

- **Grain caveat.** The ratio columns are valid **only at campaign grain**, e.g. in a campaign
  ranking table. Any chart that aggregates campaigns (a channel, an objective, a scorecard) must
  compute `SUM(numerator) / SUM(denominator)` from the base columns next to them, never `SUM` or
  `AVG` of the ratio column: an average of campaign ratios weights every campaign equally,
  whatever its size. `02bT [19]` (block 14) checks the channel and total ratios as ratios of sums,
  and prints the plain average of the campaign ROAS values next to them; the two differ for every
  channel and for the total.
- **Rounding.** Each ratio is rounded once, half away from zero, from the exact quotient: the
  dividend is cast to `NUMBER(32,18)` before the division, so `ROUND` to the stored scale is the
  only rounding (header of `sql/02b_core_models.sql`, "Rounding").
- **Budget.** Budget is additive across campaigns but not across dates, so budget utilisation
  exists only at campaign grain (architecture decision 9). For budget by month or year, use
  `FCT_DAILY_SPEND.BUDGET_PRORATED`.
- **ROAS** rests on the dataset's last-touch attribution: it describes attributed revenue, not
  causal impact.
- **No KPI results here.** This page defines the columns. Every KPI with its Data Studio
  calculated field is in [kpi_definitions.md](kpi_definitions.md); the Phase 4 answers to the
  business questions are in [business_insights.md](business_insights.md) (draft).

### Which date column to use

| Question | Date column | Table |
|---|---|---|
| Spend, impressions, clicks by day or month | `SPEND_DATE`, `SPEND_MONTH` (activity) | `FCT_DAILY_SPEND` |
| Conversion rate of the leads created in a month (cohort) | `CREATED_DATE`, `CREATED_MONTH` | `FCT_LEAD_CONVERSIONS` |
| Conversions or revenue by when they happened | `CONVERTED_DATE`, `CONVERTED_MONTH` (activity) | `FCT_LEAD_CONVERSIONS` |
| Campaign rankings and channel roll-ups over the full range | none: no date-range dimension | `MART_CAMPAIGN_PERFORMANCE` |
| Calendar attributes, empty days shown as 0 | `DATE_DAY`, `MONTH_START`, `WEEK_START` | `DIM_DATE` |
| Spend, leads, conversions and revenue per campaign-day, including the 21 days after the flight (activity) | `ACTIVITY_DATE`, `ACTIVITY_MONTH` | `FCT_CAMPAIGN_DAILY_ACTIVITY` |
| Monthly activity by channel, with the number of campaigns in flight | `MONTH_START` (activity) | `MART_MONTHLY_MARKETING` |
| Monthly conversion rate, cross-month share and mean lag of the leads created in a month | `COHORT_MONTH` (cohort) | `MART_MONTHLY_COHORT` |
| Channel scorecard over the full range | none: no date-range dimension | `MART_CHANNEL_PERFORMANCE` |
| Conversion by lead score band or segment | none: no date-range dimension | `MART_LEAD_QUALITY` |

`START_DATE`, `START_YEAR` and `START_MONTH` are campaign attributes. A date-range control, year
filter or time axis on them puts a whole campaign (its spend, leads and revenue) at its start,
and 23 campaigns cross a year boundary. For activity over time use the Phase 4 tables below:
`FCT_CAMPAIGN_DAILY_ACTIVITY` (a daily spine to `END_DATE + 21`) and `MART_MONTHLY_MARKETING`;
for cohort rates over time, `MART_MONTHLY_COHORT`. The two bases never share a date axis.

## MART analysis marts (Phase 4)

Five tables built by `make analysis-marts` (`sql/02c_analysis_marts.sql`) from the MART core
(`DIM_DATE`, `DIM_CAMPAIGN`, `FCT_DAILY_SPEND`, `FCT_LEAD_CONVERSIONS`), never from STAGING
directly, so they share the tested Phase 3 definitions (canonical `CHANNEL`, `BUDGET_PRORATED`,
the 0/1 flags, `DAYS_TO_CONVERT`). In the SQL build they were snapshots of the core, rebuilt by
`make analysis-marts` after every `make marts`; since Phase 5 dbt builds them (same names) after
the core tables they depend on, in one run. 13,760 / 180 / 180 / 5 / 50 rows, every column
commented (`02c [15]`).

- **Grain rule.** Each input is aggregated to the target grain in its own CTE and only then joined
  1:1 to a spine of dimension members (campaign × date, month × channel, channel × score band),
  never fact to fact ([architecture.md](architecture.md#design-decisions), decision 6). Every table
  adds up to the known totals: spend 4,523,050.02, impressions 436,844,819, clicks 7,102,319,
  leads 261,684, converted leads 39,696 (23,005 trials, 16,691 purchases), revenue 21,561,839.01,
  `BUDGET_PRORATED` 5,418,642.159820 (`02cT [10]`).
- **Independent paths.** The daily spine rolled up to campaigns equals `MART_CAMPAIGN_PERFORMANCE`
  for 120 of 120 campaigns (`02cT [11]`); the monthly marts equal the Phase 3 facts and STAGING
  for 180 of 180 channel-months (`02cT [12]`, `02cT [13]`); the channel mart equals the publisher
  reference and the campaign roll-up (`02cT [19]`, `02cT [20]`); the lead-quality mart equals
  independent values for 50 of 50 rows (`02cT [23]`).
- **Zeros, not missing rows.** Each spine lists every member of its grain and `COALESCE` turns
  "nothing happened" into 0, so a time axis shows a gap as 0. No column has a NULL cell
  (`02cT [8]`).
- **Additive bases.** Counts, money and the `SUM_*` columns add up across rows. Averages are
  derived, never stored: average score = `SUM(SUM_LEAD_SCORE) / SUM(LEADS)`, mean lag =
  `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)`. Two exceptions, stated on the column:
  `ACTIVE_CAMPAIGNS` (additive across channels within a month, not across months) and `BUDGET`
  (whole campaigns only).
- **Ratios.** Only `MART_CHANNEL_PERFORMANCE` stores ratios, valid at its grain (one row per
  channel, full range). Everywhere else a ratio is `SUM / SUM` of the bases
  ([kpi_definitions.md](kpi_definitions.md)).
- **Basis.** Each table is on the activity basis or the lead-cohort basis, stated in its table
  comment; the two never share a date axis (decision 7).
- **Types.** Counts `NUMBER(38,0)`; 0/1 flags `NUMBER(1,0)`; every money column `NUMBER(18,2)`,
  because each is a SUM over source rows (so the daily `SPEND` here is `NUMBER(18,2)`, while
  `FCT_DAILY_SPEND.SPEND` is `NUMBER(12,2)`); `BUDGET_PRORATED` `NUMBER(18,6)`; rates, ROAS,
  shares and interval bounds `NUMBER(18,6)`; cost per unit `NUMBER(18,4)`; score band edges
  `NUMBER(3,0)`; months are `DATE`s (first day of the month). Read from `INFORMATION_SCHEMA` after
  `make analysis-marts` on 2026-10-14; the contract test checks them on every run (`02cT [6]`).
- **Roles** as in the [MART core](#mart-core), plus *semi-additive*: additive across some
  dimensions only.

### FCT_CAMPAIGN_DAILY_ACTIVITY

The activity fact: one row per campaign per calendar day from `START_DATE` to `END_DATE` + 21
days (the observed maximum lag), clipped at 2025-12-31 (nothing is clipped today: the last day is
2025-12-23). 13,760 rows: 11,240 flight days (`IS_IN_FLIGHT = 1`, one per `FCT_DAILY_SPEND` row)
and 2,520 post-flight days (120 × 21) (`02cT [9]`). PK `(CAMPAIGN_ID, ACTIVITY_DATE)`
(`02cT [7]`). Spine: `DIM_CAMPAIGN` × `DIM_DATE`. Inputs, each aggregated to campaign × date
first: `FCT_DAILY_SPEND` by `SPEND_DATE`, `FCT_LEAD_CONVERSIONS` by `CREATED_DATE` (leads) and by
`CONVERTED_DATE` (conversions). The post-flight rows carry no spend and the 4,716 conversions
(2,532,266.74 of revenue) that land after a campaign ended (`02cT [9]`). Activity basis: never
divide `CONVERSIONS` by `LEADS` here.

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CAMPAIGN_ID` | `TEXT` | key, FK | Campaign, to `DIM_CAMPAIGN`. Grain key with `ACTIVITY_DATE`. |
| 2 | `ACTIVITY_DATE` | `DATE` | key, date | Calendar day, to `DIM_DATE.DATE_DAY`. |
| 3 | `ACTIVITY_MONTH` | `DATE` | date | First day of the month of `ACTIVITY_DATE`. |
| 4 | `CHANNEL` | `TEXT` | attribute | Channel of the campaign, from `DIM_CAMPAIGN`. |
| 5 | `OBJECTIVE` | `TEXT` | attribute | Objective of the campaign, from `DIM_CAMPAIGN`. |
| 6 | `IS_IN_FLIGHT` | `NUMBER(1,0)` | flag | 1 if `START_DATE <= ACTIVITY_DATE <= END_DATE` (a flight day, which always has a spend row), 0 on the 21 days after. `SUM` = flight days. |
| 7 | `IMPRESSIONS` | `NUMBER(38,0)` | measure | Impressions on the day (by spend date); 0 after the flight. |
| 8 | `CLICKS` | `NUMBER(38,0)` | measure | Clicks on the day; 0 after the flight. |
| 9 | `SPEND` | `NUMBER(18,2)` | measure | Spend on the day; 0 after the flight. Total 4,523,050.02. |
| 10 | `BUDGET_PRORATED` | `NUMBER(18,6)` | measure | `FCT_DAILY_SPEND.BUDGET_PRORATED` on flight days, 0 after: the planned budget of the day. Total 5,418,642.159820. An even spread is an assumption, not observed pacing: not a utilisation base below whole campaigns. |
| 11 | `LEADS` | `NUMBER(38,0)` | measure | Leads created on the day (by created date). 7 flight days have none (`02cT [9]`). |
| 12 | `CONVERSIONS` | `NUMBER(38,0)` | measure | Conversions (trial or purchase) booked on the day (by converted date) for leads of the campaign, up to 21 days after the flight: 34,980 on flight days, 4,716 after (`02cT [9]`). Not a numerator for `LEADS` of the same days. |
| 13 | `TRIALS` | `NUMBER(38,0)` | measure | Trial conversions booked on the day. A parallel outcome to `PURCHASES`, not a stage before it. |
| 14 | `PURCHASES` | `NUMBER(38,0)` | measure | Purchase conversions booked on the day. |
| 15 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue booked on the day; 0.00 for trials. Total 21,561,839.01. |

### MART_MONTHLY_MARKETING

The monthly activity mart: one row per `MONTH_START` × `CHANNEL`, all 36 months (2023-01..2025-12)
× 5 channels = 180 rows, zeros where nothing happened (159 channel-months have spend, 161 have
conversions, `02cT [15]`). PK `(MONTH_START, CHANNEL)` (`02cT [7]`). Built from
`FCT_CAMPAIGN_DAILY_ACTIVITY` rolled up to channel × month, joined 1:1 to a 36 × 5 month ×
channel spine. Activity basis: what was spent and booked in each month. It answers "what did we
spend and book in March?", not "how well did March's leads convert?" (that is
`MART_MONTHLY_COHORT`). Its 36 monthly totals reproduce the Phase 2 baseline (`02cT [14]`).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `MONTH_START` | `DATE` | key, date | Activity month (first day), 2023-01-01..2025-12-01; FK to `DIM_DATE.MONTH_START`. Never on one axis with `MART_MONTHLY_COHORT.COHORT_MONTH`. |
| 2 | `CHANNEL` | `TEXT` | key, attribute | Canonical channel, from `DIM_CAMPAIGN`. |
| 3 | `ACTIVE_CAMPAIGNS` | `NUMBER(38,0)` | semi-additive | Campaigns of the channel in flight on at least 1 day of the month. Additive across channels within a month, **not across months**: over all 180 rows it sums to 490 campaign-months, not 120 campaigns (`02cT [18]`). 1 to 20 per month over all channels (`03 [7]`). Read every volume next to it. |
| 4 | `SPEND` | `NUMBER(18,2)` | measure | Spend in the month (by spend date). Total 4,523,050.02. |
| 5 | `IMPRESSIONS` | `NUMBER(38,0)` | measure | Impressions in the month (by spend date). |
| 6 | `CLICKS` | `NUMBER(38,0)` | measure | Clicks in the month (by spend date). |
| 7 | `LEADS` | `NUMBER(38,0)` | measure | Leads created in the month (by created date). |
| 8 | `CONVERSIONS` | `NUMBER(38,0)` | measure | Conversions (trial or purchase) in the month (by converted date), whenever their lead was created. Total 39,696. Not a numerator for `LEADS` of the same month: for conversion rates use `MART_MONTHLY_COHORT`. |
| 9 | `TRIALS` | `NUMBER(38,0)` | measure | Trial conversions in the month. |
| 10 | `PURCHASES` | `NUMBER(38,0)` | measure | Purchase conversions in the month. |
| 11 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue booked in the month (by converted date). Total 21,561,839.01. `SUM(REVENUE) / SUM(SPEND)` is activity-basis ROAS. |
| 12 | `BUDGET_PRORATED` | `NUMBER(18,6)` | measure | Planned budget of the month: the prorated daily budget summed over its flight days. Total 5,418,642.159820. `SPEND / BUDGET_PRORATED` of a month is pacing against an even spread, not budget utilisation. |

### MART_MONTHLY_COHORT

The monthly lead-cohort mart: one row per `COHORT_MONTH` × `CHANNEL`, 36 × 5 = 180 rows. PK
`(COHORT_MONTH, CHANNEL)` (`02cT [7]`). `FCT_LEAD_CONVERSIONS` aggregated by `CREATED_MONTH` ×
`CHANNEL`, joined 1:1 to the same spine. Lead-cohort basis: the leads created in a month and what
they later did, wherever the conversion landed. Same totals as the activity mart (39,696
conversions, 21,561,839.01 of revenue) but different months: conversions differ in 36 of 36 months
and in 159 of 180 channel-months (`02cT [15]`), because 13,675 of 39,696 conversions (0.344493)
land in a later month than their lead (`02cT [16]`).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `COHORT_MONTH` | `DATE` | key, date | Month the leads were created (`FCT_LEAD_CONVERSIONS.CREATED_MONTH`), 2023-01-01..2025-12-01. Never on one axis with `MART_MONTHLY_MARKETING.MONTH_START`. |
| 2 | `CHANNEL` | `TEXT` | key, attribute | Canonical channel, from `DIM_CAMPAIGN`. |
| 3 | `LEADS` | `NUMBER(38,0)` | measure | Leads created in the cohort month: the denominator of the cohort conversion rate. Total 261,684. |
| 4 | `CONVERTED_LEADS` | `NUMBER(38,0)` | measure | Leads of the cohort that converted (trial or purchase), whenever. Cohort conversion rate = `SUM(CONVERTED_LEADS) / SUM(LEADS)`. |
| 5 | `TRIALS` | `NUMBER(38,0)` | measure | Leads of the cohort that converted to a trial. |
| 6 | `PURCHASES` | `NUMBER(38,0)` | measure | Leads of the cohort that converted to a purchase. Purchase rate = `SUM(PURCHASES) / SUM(LEADS)`. |
| 7 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue of the cohort's leads. Total 21,561,839.01. |
| 8 | `CONVERTED_SAME_MONTH` | `NUMBER(38,0)` | measure | Converted leads whose conversion landed in the cohort month (26,021 in total). `CONVERTED_SAME_MONTH + CONVERTED_LATER_MONTH = CONVERTED_LEADS` in every row (`02cT [16]`). |
| 9 | `CONVERTED_LATER_MONTH` | `NUMBER(38,0)` | measure | Converted leads whose conversion landed in a later month (13,675 in total). Cross-month share = `SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS)`. |
| 10 | `SUM_DAYS_TO_CONVERT` | `NUMBER(38,0)` | measure | Sum of `DAYS_TO_CONVERT` over the cohort's converted leads (0 if none); total 417,029 (`02cT [10]`). Mean lag = `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)`. |
| 11 | `MATURE_LEADS` | `NUMBER(38,0)` | measure | Leads created at least 21 days before the assumed as-of date 2025-12-31 (`SUM(IS_MATURE)`). Equals `LEADS` in every row under that assumption (`02cT [16]`); a cohort with fewer mature leads would still be converting. |

### MART_CHANNEL_PERFORMANCE

The channel scorecard: one row per `CHANNEL`, 5 rows, full range 2023-01-01..2025-12-31, no date
dimension. PK `CHANNEL` (`02cT [7]`). Campaigns and budget (`DIM_CAMPAIGN`), delivery and spend
(`FCT_DAILY_SPEND`), and leads, conversions and revenue (`FCT_LEAD_CONVERSIONS`) are each
aggregated to the channel first, then joined 1:1. It does not read `MART_CAMPAIGN_PERFORMANCE`, so
the tests compare the two: its bases and 11 ratios equal the channel roll-up of the campaign table,
and spend and revenue equal the publisher reference per channel (`02cT [19]`, `02cT [20]`). The
ratio columns are valid at channel grain only; NULL only for a zero denominator (0 channels,
`02cT [22]`).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CHANNEL` | `TEXT` | key | affiliate, display, paid_search, paid_social, video. |
| 2 | `CAMPAIGNS` | `NUMBER(38,0)` | measure | Campaigns of the channel (24 each). |
| 3 | `BUDGET` | `NUMBER(18,2)` | measure | Sum of the channel's campaign budgets (whole campaigns). Total 5,418,642.16. |
| 4 | `SPEND` | `NUMBER(18,2)` | measure | Spend, full range. Total 4,523,050.02. |
| 5 | `IMPRESSIONS` | `NUMBER(38,0)` | measure | Impressions, full range. |
| 6 | `CLICKS` | `NUMBER(38,0)` | measure | Clicks, full range. |
| 7 | `LEADS` | `NUMBER(38,0)` | measure | Leads, full range. |
| 8 | `CONVERTED_LEADS` | `NUMBER(38,0)` | measure | Leads that converted (trial or purchase); `TRIALS + PURCHASES`. |
| 9 | `TRIALS` | `NUMBER(38,0)` | measure | Leads that converted to a trial; parallel to `PURCHASES`, not a stage before it. |
| 10 | `PURCHASES` | `NUMBER(38,0)` | measure | Leads that converted to a purchase. |
| 11 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue, full range. Total 21,561,839.01. |
| 12-27 | ratio columns | see below | ratio | Channel grain only. Across channels compute `SUM(numerator) / SUM(denominator)`. |

| # | Column | Type | Formula | Note |
|---:|---|---|---|---|
| 12 | `CTR` | `NUMBER(18,6)` | `CLICKS / IMPRESSIONS` | |
| 13 | `CLICK_TO_LEAD_RATE` | `NUMBER(18,6)` | `LEADS / CLICKS` | Aggregate funnel ratio of two different units. |
| 14 | `LEAD_CONVERSION_RATE` | `NUMBER(18,6)` | `CONVERTED_LEADS / LEADS` | Interval in columns 26-27. |
| 15 | `PURCHASE_RATE` | `NUMBER(18,6)` | `PURCHASES / LEADS` | |
| 16 | `COST_PER_LEAD` | `NUMBER(18,4)` | `SPEND / LEADS` | |
| 17 | `COST_PER_CONVERSION` | `NUMBER(18,4)` | `SPEND / CONVERTED_LEADS` | |
| 18 | `COST_PER_PURCHASE` | `NUMBER(18,4)` | `SPEND / PURCHASES` | |
| 19 | `ROAS` | `NUMBER(18,6)` | `REVENUE / SPEND` | Last-touch attributed, not causal. |
| 20 | `BUDGET_UTILIZATION` | `NUMBER(18,6)` | `SPEND / BUDGET` | Valid: a channel holds whole campaigns over the full range. |
| 21 | `CPC` | `NUMBER(18,4)` | `SPEND / CLICKS` | |
| 22 | `CPM` | `NUMBER(18,4)` | `SPEND x 1000 / IMPRESSIONS` | Near-round per channel: a generator property, not a market price. |
| 23 | `SPEND_SHARE` | `NUMBER(18,6)` | `SPEND / total SPEND of the 5 channels` | Rounded per row: the five sum to 1.000000 (`02cT [22]`). A share of all five channels, even when a chart filters channels. |
| 24 | `LEADS_SHARE` | `NUMBER(18,6)` | `LEADS / total LEADS` | The five sum to 0.999999 (`02cT [22]`). |
| 25 | `REVENUE_SHARE` | `NUMBER(18,6)` | `REVENUE / total REVENUE` | The five sum to 0.999999 (`02cT [22]`). |
| 26 | `LCR_CI_LOW` | `NUMBER(18,6)` | Wilson 95% interval of `LEAD_CONVERSION_RATE`, lower bound (z = 1.959964) | Computed in FLOAT (it needs `SQRT`), rounded once; equals an independent 60-digit computation (`02cT [21]`). Not additive: never `SUM` or `AVG` across channels. Sampling noise only. |
| 27 | `LCR_CI_HIGH` | `NUMBER(18,6)` | upper bound of the same interval | As column 26. |

### MART_LEAD_QUALITY

One row per `CHANNEL` × `SCORE_BAND`: 5 channels × 10 bands of 10 score points = 50 rows. PK
`(CHANNEL, SCORE_BAND)` (`02cT [7]`). `FCT_LEAD_CONVERSIONS` aggregated by channel and band
(`SCORE_BAND_MIN = FLOOR((LEAD_SCORE - 1) / 10) x 10 + 1`), joined 1:1 to a channel × band spine
built from an explicit 10-row band list. The bands align with the plan segments, so the table
rolls up to segment, band or channel with `SUM`. 50 of 50 rows equal independent values, and no
lead's band segment disagrees with `FCT_LEAD_CONVERSIONS.LEAD_SCORE_SEGMENT` (`02cT [23]`). Bands
hold 25,748 to 26,396 leads (`02cT [24]`). Association only: how the score is produced is
undocumented, and it is not assumed to predict conversion.

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CHANNEL` | `TEXT` | key, attribute | Canonical channel, from `DIM_CAMPAIGN`. |
| 2 | `SCORE_BAND` | `TEXT` | key, attribute | `01-10`, `11-20`, ..., `91-100`; zero-padded so it sorts correctly as text. |
| 3 | `SCORE_BAND_MIN` | `NUMBER(3,0)` | attribute | Lowest score of the band (1, 11, ..., 91). Group or sort by it, never `SUM` (Data Studio sums a number by default). |
| 4 | `SCORE_BAND_MAX` | `NUMBER(3,0)` | attribute | Highest score of the band (10, 20, ..., 100). As column 3. |
| 5 | `LEAD_SCORE_SEGMENT` | `TEXT` | attribute | `Low` (1-40), `Medium` (41-70), `High` (71-100). Bands never straddle a cut-off, so `SUM` by segment is exact. |
| 6 | `LEADS` | `NUMBER(38,0)` | measure | Leads of the channel with a score in the band. Total 261,684. |
| 7 | `SUM_LEAD_SCORE` | `NUMBER(38,0)` | measure | Sum of `LEAD_SCORE` of those leads; total 13,233,637 (`02cT [10]`). Average score = `SUM(SUM_LEAD_SCORE) / SUM(LEADS)`. |
| 8 | `CONVERTED_LEADS` | `NUMBER(38,0)` | measure | Leads of the band that converted (trial or purchase). Conversion rate = `SUM(CONVERTED_LEADS) / SUM(LEADS)`: association with the score. |
| 9 | `TRIALS` | `NUMBER(38,0)` | measure | Leads of the band that converted to a trial. |
| 10 | `PURCHASES` | `NUMBER(38,0)` | measure | Leads of the band that converted to a purchase. |
| 11 | `REVENUE` | `NUMBER(18,2)` | measure | Last-touch attributed revenue of the band's leads. |
| 12 | `SUM_DAYS_TO_CONVERT` | `NUMBER(38,0)` | measure | Sum of `DAYS_TO_CONVERT` over the band's converted leads (0 if none). Mean lag = `SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS)`. |

## MART conversion funnel (Phase 6)

One table added in Phase 6 for the dashboard's funnel chart (Conversion Funnel page), the
`mart_conversion_funnel` that the plan's dbt sketch named ([dbt.md](dbt.md#plan-names-and-the-models-that-serve-them)).
dbt builds it (`dbt/models/marts/mart_conversion_funnel.sql`) from `MART_CHANNEL_PERFORMANCE`;
there is no hand-written SQL twin, so neither `make parity-check` nor the Phase 3-4 contract
blocks cover its columns. Its contract is in dbt: the column descriptions and 12 data tests in
`dbt/models/marts/_marts.yml` and the singular test
`dbt/tests/marts/assert_conversion_funnel_reconciles.sql`, which compares every stage total with
`expected_totals` and every one of the 25 cells with `expected_campaign_kpi` rolled up to channels
(both independent seeds). `sql/02b_core_models_tests.sql` and `sql/02c_analysis_marts_tests.sql`
block 1 list it as an expected MART table with a table comment (`06F` steps 4-5).

### MART_CONVERSION_FUNNEL

The funnel in long format: one row per `CHANNEL` × `STAGE_ORDER`, 5 channels × 5 stages = 25 rows,
full range 2023-01-01..2025-12-31, no date dimension. PK `(CHANNEL, STAGE_ORDER)`; `STAGE` is
one-to-one with `STAGE_ORDER`. The five stages are the funnel bases of `MART_CHANNEL_PERFORMANCE`,
one per row; each stage sums over the channels to its known total (`06F` step 7, statement [9]):

| `STAGE_ORDER` | `STAGE` | Base it holds | Total over the 5 channels |
|---:|---|---|---:|
| 1 | `Impressions` | `IMPRESSIONS` | 436,844,819 |
| 2 | `Clicks` | `CLICKS` | 7,102,319 |
| 3 | `Leads` | `LEADS` | 261,684 |
| 4 | `Converted leads` | `CONVERTED_LEADS` (trials + purchases) | 39,696 |
| 5 | `Purchases` | `PURCHASES` | 16,691 |

- **An aggregate campaign funnel, not a person journey.** The stages are different units (an
  impression is not a person). A lead converts at most once, to a trial or a purchase, so
  `Purchases` is the subset of converted leads that converted to a purchase, not a later step
  taken by the same person after a trial.
- **Additive within a stage only.** `STAGE_VALUE` adds up across channels within one stage, never
  across stages, so every chart uses `STAGE` as its dimension (or a filter on `STAGE`).
- **No `ALL` row and no stored ratio.** The all-channel funnel is the `SUM` over the channels; a
  total row would double count. `PREV_STAGE_VALUE` and `TOP_OF_FUNNEL_VALUE` are additive across
  channels too, so the stage ratios are ratios of sums at any channel filter
  ([kpi_definitions.md](kpi_definitions.md#funnel-stages-and-stage-conversion)).

| # | Column | Type | Role | Meaning |
|---:|---|---|---|---|
| 1 | `CHANNEL` | `TEXT` | key, attribute | Canonical channel, from `MART_CHANNEL_PERFORMANCE` (i.e. `DIM_CAMPAIGN`). No `ALL` row. |
| 2 | `STAGE_ORDER` | `NUMBER(1,0)` | key, attribute | Funnel position 1-5. Sort the `STAGE` axis by it with aggregation *Min*, never `SUM` (Data Studio sums a number by default). |
| 3 | `STAGE` | `TEXT` | attribute | `Impressions`, `Clicks`, `Leads`, `Converted leads`, `Purchases`. The chart dimension. |
| 4 | `STAGE_VALUE` | `NUMBER(38,0)` | measure | The stage's base for the channel, full range. Additive across channels within a stage. |
| 5 | `PREV_STAGE_VALUE` | `NUMBER(38,0)` | measure | `STAGE_VALUE` of the previous stage of the same channel; NULL on stage 1, the only NULLs in the table. Stage conversion = `SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE)`. |
| 6 | `TOP_OF_FUNNEL_VALUE` | `NUMBER(38,0)` | measure | The channel's impressions, repeated on its 5 rows. Share of top of funnel = `SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE)`. Never `SUM` across stages. |

Types read from `INFORMATION_SCHEMA.COLUMNS` after the Phase 6 build on 2026-10-14 (`06F` step 7,
statement [6]); the table is permanent, owned by `CRM_TRANSFORMER`, and `CRM_REPORTER` reads it
through the MART future grant (`06F` step 7, statement [7]).
