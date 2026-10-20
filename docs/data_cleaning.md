# Phase 3: data cleaning (STAGING)

**Goal of Phase 3:** create analysis-ready, cleaned data: typed and tested STAGING views, and the
core MART models built on them. **Status: done (2026-10-14).** This page covers the cleaning half
(STAGING): the rules, why they look the way they do, what the cleaning-challenge track showed,
and what the tests guarantee. dbt builds and tests the views ([dbt.md](dbt.md)); the objects and
their columns are listed in the [data dictionary](data_dictionary.md).

Every number on this page is copied from the evidence files, cited as *file [statement]* in the
style of [data_profile.md](data_profile.md):

| Tag | Evidence file | Produced by |
|---|---|---|
| `02` | [`evidence/02_data_cleaning.txt`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/02_data_cleaning.txt) | [`sql/02_data_cleaning.sql`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/sql/02_data_cleaning.sql), 13 statements: builds the 8 views |
| `02T` | [`evidence/02_data_cleaning_tests.txt`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/02_data_cleaning_tests.txt) | [`sql/02_data_cleaning_tests.sql`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/sql/02_data_cleaning_tests.sql), 25 statements: read-only tests |
| `02bT` | [`evidence/02b_core_models_tests.txt`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/02b_core_models_tests.txt) | [`sql/02b_core_models_tests.sql`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/sql/02b_core_models_tests.sql), 22 statements: MART tests |
| `B` | [`evidence/05_dbt_build.txt`](evidence/05_dbt_build.txt) | `make dbt-build`: the dbt build and every dbt test (full log) |
| `01 §x [n]`, `01b x [n]` | [`evidence/01_data_profiling.txt`](evidence/01_data_profiling.txt), [`evidence/01b_challenge_profiling.txt`](evidence/01b_challenge_profiling.txt) | Phase 2 profiling (block, statement) |

The `02`, `02T` and `02bT` files come from the first version of the build. The models were first
written as plain SQL and moved to dbt with identical results (parity check); that version is in
the git history at commit dbe41f7, where the links above point.

Nothing here answers a business question; that is Phase 4.

## Contents

1. [What was built](#what-was-built)
2. [How it was produced](#how-it-was-produced)
3. [The rules](#the-rules)
4. [Challenge track results](#challenge-track-results)
5. [What the main pipeline guarantees](#what-the-main-pipeline-guarantees)
6. [Deliberate choices and limits](#deliberate-choices-and-limits)

## What was built

Eight views in `MARKETING_CRM.STAGING`, one per RAW table, at the RAW table's grain after
de-duplication (`02 [5-12]`).

| Track | RAW table → STAGING view | RAW rows | STAGING rows | Rows with a DQ issue | Read by |
|---|---|---:|---:|---:|---|
| clean | `CAMPAIGNS` → `STG_CAMPAIGNS` | 120 | 120 | 0 | MART |
| clean | `DAILY_SPEND` → `STG_DAILY_SPEND` | 11,240 | 11,240 | 0 | MART |
| clean | `LEADS` → `STG_LEADS` | 261,684 | 261,684 | 0 | MART |
| clean | `CONVERSIONS` → `STG_CONVERSIONS` | 39,696 | 39,696 | 0 | MART |
| challenge | `CHALLENGE_CAMPAIGNS` → `STG_CHALLENGE_CAMPAIGNS` | 121 | 120 | 4 | the reconciliation tests only |
| challenge | `CHALLENGE_DAILY_SPEND` → `STG_CHALLENGE_DAILY_SPEND` | 2,001 | 2,000 | 3 | the reconciliation tests only |
| challenge | `CHALLENGE_LEADS` → `STG_CHALLENGE_LEADS` | 2,001 | 2,000 | 4 | the reconciliation tests only |
| challenge | `CHALLENGE_CONVERSIONS` → `STG_CHALLENGE_CONVERSIONS` | 2,001 | 2,000 | 4 | the reconciliation tests only |

Sources: RAW rows `02T [9]`, `[21]`; STAGING rows and flagged rows `02 [13]`.

- **One set of rules for both tracks.** Phase 2 found the clean release defect-free
  ([data_profile.md](data_profile.md#data-quality-summary)), so on the clean views the rules change
  no value; they guard the main pipeline against a future dirty load. The challenge extracts carry
  the publisher's 15 injected defects, so running the *same* rules on them shows that the rules
  actually catch and repair defects. The tests show both halves: the clean views keep every RAW
  row and reproduce the Phase 2 control totals exactly, and the challenge views reproduce the
  clean views except for 2 cells no evidence can recover.
- **Why views.** The dbt staging convention: always in sync with RAW, nothing stored, no refresh
  step. dbt builds them from [`dbt/models/staging/`](../dbt/models/staging/) ([dbt.md](dbt.md)).
- **Why the tracks never mix.** Every challenge key also exists in the clean release
  (`02T [23]`), so a union would double-count. MART reads only the clean views
  (architecture decision 5).

## How it was produced

| | Build | Tests |
|---|---|---|
| dbt | the 8 models in [`dbt/models/staging/`](../dbt/models/staging/), one macro call each; the rules are in [`dbt/macros/staging/clean_*.sql`](../dbt/macros/staging/), one macro per entity | generic tests in [`_staging.yml`](../dbt/models/staging/_staging.yml), unit tests in [`_staging_unit_tests.yml`](../dbt/models/staging/_staging_unit_tests.yml), singular tests in [`dbt/tests/staging/`](../dbt/tests/staging/) and [`dbt/tests/challenge/`](../dbt/tests/challenge/) |
| Command | `make dbt-build` builds and tests every STAGING view and MART table | `make dbt-test` re-runs the tests on the deployed views, no rebuild |
| Run as | `SVC_CRM_PIPELINE`, role `CRM_TRANSFORMER`, warehouse `MARKETING_WH` (from `.env`, read by [`dbt/profiles.yml`](../dbt/profiles.yml)) | same |
| Result | 8 views created (`B`) | the full build ends `PASS=273 WARN=0 ERROR=0` (`B`) |

The first version's test file ran as the same user and role, with no secondary roles, last on
2026-10-14 06:05 UTC (`02T [5]`): **194 PASS rows, 0 FAIL, 0 WARN**, exit 0 (`02T`).

- **Evidence rule.** As for the Phase 2 targets, `make dbt-build` writes its log to `build/` first
  (`tee`, with `set -o pipefail` keeping dbt's exit code), and the evidence file is replaced only
  after every step exits 0. A failed run cannot overwrite the evidence.
- **Expected values never come from the view under test.** They come from the Phase 2 evidence,
  the Phase 2 conventions in the header of `sql/01b_challenge_profiling.sql` and the local
  baselines computed from the CSV files without Snowflake: in dbt, the seeds written by
  [`scripts/independent_check.py`](../scripts/independent_check.py)
  ([dbt.md](dbt.md#seeds-independent-expected-values)) and literal `VALUES` lists in the singular
  tests. "The Phase 2 baseline" on this page means those local pre-load values (e.g. 120
  campaigns × 12 bases, 36 months).
- **No vacuous passes.** Every comparison with an expected list or seed uses a `FULL OUTER JOIN`
  or `IS DISTINCT FROM`, so a missing or unexpected value, row or defect is its own failing row; a
  test that finds 0 bad rows relies on the row counts checked in the same run
  (`assert_staging_keeps_every_raw_row`).

## The rules

Each view is one chain of CTEs, identical in all 8 views:

| Step | CTE | What it does | SQL technique |
|---|---|---|---|
| 0 | `source` | `SELECT *` from the RAW table, untouched | |
| 1 | `trimmed` | Trim the edges of space, tab, CR and LF; a blank becomes NULL. The raw value is kept next to the trimmed one so step 3 can say what changed | `NULLIF(TRIM(x, ' \t\r\n'), '')` |
| 2 | `typed` | Type each column by its kind: ids, codes, names, dates, integers, money | `UPPER` / `LOWER` / `INITCAP`, `CASE WHEN REGEXP_LIKE(...) THEN TRY_TO_DATE(...)` / `TRY_TO_NUMBER(...)` |
| 3 | `flagged` | One `'<column>:<issue>'` code per problem cell | `IFF(...)`, `ARRAY_CONSTRUCT_COMPACT` |
| 4 | `deduped` | One row per key; record the copy count | `ROW_NUMBER() ... QUALIFY`, `COUNT(*) OVER (PARTITION BY key)` |
| 5 | final | `DQ_ISSUES` = cell codes + row codes; `DQ_IS_VALID = ARRAY_SIZE(DQ_ISSUES) = 0` | `ARRAY_CAT` |

The exact expressions per column kind and the full list of DQ codes are in the
[data dictionary](data_dictionary.md#cleaning-rule-kinds). The reasons:

### 1. Blanks become NULL, and are flagged

RAW keeps a blank cell as `''`, because the load used `EMPTY_FIELD_AS_NULL = FALSE` (lossless
landing, architecture decision 1). `NULLIF(TRIM(x, ' \t\r\n'), '')` turns `''` and whitespace-only
cells into NULL, and the cell gets `<column>:missing`. The character list is spelled out because
Snowflake's `TRIM(x)` without one removes only the space character (Phase 2 conventions, header of
`sql/01b_challenge_profiling.sql`). An NBSP (`CHR(160)`) is deliberately not trimmed: `'42'` +
NBSP becomes NULL + `unparseable` instead of being accepted (`02T [7]`).

### 2. Ids, codes and names: and the INITCAP caveat

Ids are upper-cased, codes (`channel`, `objective`, `lead_source`, `conversion_type`)
lower-cased, and only the one name column, `campaign_name`, goes through `INITCAP`. `INITCAP`
treats `_` as a word break, so `'paid_search'` would become `'Paid_Search'`: it must never touch a
code. A value that had to be trimmed or recased keeps its cleaned value and gets `untrimmed` /
`recased`; one that does not fit its documented shape (`CMP0000`, snake_case, `<Channel Words>
<yyyy> <nnn>`) is kept and flagged `nonconforming` (`02T [7]`: `' TRIAL '` → `trial`,
`' DISPLAY 2023 008 '` → `Display 2023 008`, `'paid-search'` and `'CMP001'` → nonconforming).

### 3. Dates: routed by shape, pattern AND cast, never AUTO

Phase 2 showed that Snowflake's `TRY_` casts are lenient on their own (`01 §2.2 [7]`):
`TRY_TO_DATE('2023-1-5', 'YYYY-MM-DD')` returns 2023-01-05, and a pattern alone would accept
`2023-02-29`, whose cast is NULL. So a date is typed only if its text matches a shape **and** the
cast succeeds:

| Shape | Parsed with | Code | Why |
|---|---|---|---|
| ISO `[0-9]{4}-[0-9]{2}-[0-9]{2}` | `TRY_TO_DATE(T, 'YYYY-MM-DD')` | none | the documented source format |
| year-first slash `[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}` | `TRY_TO_DATE(T, 'YYYY/MM/DD')` | `slash_ymd` | a known defect class: Phase 2 showed Y/D/M fits none of the 4 slash dates (`01b 4d`), and asked Phase 3 to parse with exactly this gate (header of `sql/01b_challenge_profiling.sql`, "Conventions") |
| anything else, or an impossible date | | `unparseable`, value NULL | e.g. `05/15/2023`, `2023/15/05`, `2023-02-29`, and ISO drift such as `2023-1-5` |

The asymmetry is deliberate: a deviation from the documented ISO format is drift and is rejected,
while the slash route recovers one proven defect class, and both are flagged, so neither is
accepted silently. `02T [7]` pins all of these cases, and `02T [16]` shows the typed dates
reproduce the Phase 2 coverage (min, max, distinct dates, span, rows per year) for all 5 date
columns.

### 4. Numbers: pattern AND cast, with explicit precision

The same leniency applies to numbers (`01 §2.2 [7]`): `TRY_TO_NUMBER('42.0')` returns 42, and
`TRY_TO_NUMBER('1250.405', 12, 2)` silently rounds to 1250.41. Integers must match `[0-9]+` and
cast with `TRY_TO_NUMBER(T, 38, 0)` (`LEAD_SCORE`: `(T, 3, 0)`, so `1000` is rejected); money must
match `[0-9]+[.][0-9]{2}` and cast with `TRY_TO_NUMBER(T, 12, 2)`. Otherwise the value is NULL +
`unparseable` (`02T [7]`: `-5`, `42.0`, `1250.4`, `1250.405`, `125040`, `1250x40`). A padded number
such as `' 42'` keeps its value and is flagged `untrimmed`, exactly like a padded id or date: the
row still fails `DQ_IS_VALID`, so nothing is accepted silently.

### 5. Regex escaping: found while building Phase 3

In a single-quoted Snowflake string a backslash is an escape character, and an unknown escape is
dropped. So the natural money pattern `'^[0-9]+\.[0-9]{2}$'` reaches the regex engine as
`^[0-9]+.[0-9]{2}$`, where `.` matches any character: it accepts `1250x40`, and worse `125040`,
which the cast would turn into 125040.00. `02T [7]` shows this in its `TRAP_GATE` column. Every
pattern therefore writes a literal dot as `[.]` and a digit as `[0-9]`, so no pattern needs a
backslash, and `02T [8]` (block 2b) checked that the deployed view definitions contained exactly
the tested rule texts and no naive backslash-dot, `AUTO` or `::DATE` (29 rule texts per view, 8
views PASS).

### 6. De-duplication with ROW_NUMBER + QUALIFY

```sql
QUALIFY ROW_NUMBER() OVER (PARTITION BY <key>
                           ORDER BY <number of NULL business fields> ASC, _SOURCE_ROW_NUMBER ASC) = 1
```

The most complete copy wins, then the first one in the file. `COUNT(*) OVER (PARTITION BY key)`
writes `row:duplicate_copies=N` on the kept row; if the copies disagree after cleaning, the row
also gets `row:duplicate_copies_differ`, so a conflicting copy is never dropped without trace. A
row whose key is missing is never collapsed with another one: its partition key falls back to its
own file and row number.

### 7. Keep every row: flags, not filters

STAGING never drops or guesses a row. Problems go to `DQ_ISSUES`, and `DQ_IS_VALID` summarises
them. Business rules (clicks ≤ impressions, trial ⇒ revenue 0.00, ...) are tests, not flags
(`02T [15]`). Outliers are kept too: Phase 2 found that every 1.5 × IQR outlier passes all 10
business rules ([data_profile.md](data_profile.md#distributions)). MART takes every STAGING row and
never filters on `DQ_IS_VALID`, because dropping a flagged spend or revenue row would silently
break the control totals; instead the tests fail if any clean-view row is flagged (`02T [10]`,
`02bT [7]`).

### Refinements over the Phase 2 preview

Phase 2 previewed these rules read-only (`01b` section 8). Phase 3 refines the preview in four
deliberate ways, none of which changes a value on this data (`02T` blocks 15-19 still reproduce
the Phase 2 results):

| | Phase 2 preview | Phase 3 views |
|---|---|---|
| De-dup order | first copy (`ORDER BY _SOURCE_ROW_NUMBER`) | fewest NULL fields first, then the first copy. The 4 duplicated keys have byte-identical copies (`01b 2a`), so source row 1 is kept either way |
| Trim | plain `TRIM` (spaces only; enough for these files, `01b 3a`) | also tab, CR and LF |
| Numbers | `TRY_TO_NUMBER(TRIM(x))` alone | integer and money patterns in front of the cast, explicit precision |
| Blank ids | left as `''` | NULL + `<column>:missing`, like every other column |

## Challenge track results

### The 15 defects: found, cleaned, flagged, or unrecoverable

Raw values are from Phase 2 (`01b 7 [30]`, [data_profile.md](data_profile.md#cleaning-challenge-extracts));
everything to the right of them is from `02T [22]`, which maps the DQ codes to the Phase 2 defect
list with a `FULL OUTER JOIN` and checks codes and values. The dbt test
[`assert_challenge_defects_flagged`](../dbt/tests/challenge/assert_challenge_defects_flagged.sql)
checks the same codes and values on every build.

| # | Class | Cell | Raw value | STAGING value | `*_FILLED` | DQ codes | Outcome |
|---:|---|---|---|---|---|---|---|
| 1 | duplicate row | CMP0001 | 2 identical copies | 1 row | | `row:duplicate_copies=2` | cleaned, flagged |
| 2 | duplicate row | DSP0000001 | 2 identical copies | 1 row | | `row:duplicate_copies=2` | cleaned, flagged |
| 3 | duplicate row | L00000001 | 2 identical copies | 1 row | | `row:duplicate_copies=2` | cleaned, flagged |
| 4 | duplicate row | CV0000001 | 2 identical copies | 1 row | | `row:duplicate_copies=2` | cleaned, flagged |
| 5 | casing/whitespace | CMP0008 `CAMPAIGN_NAME` | `[ DISPLAY 2023 008 ]` | `Display 2023 008` | | `untrimmed`, `recased` | cleaned, flagged |
| 6 | casing/whitespace | L00000008 `LEAD_SOURCE` | `[ PAID_SEARCH ]` | `paid_search` | | `untrimmed`, `recased` | cleaned, flagged |
| 7 | casing/whitespace | CV0000008 `CONVERSION_TYPE` | `[ TRIAL ]` | `trial` | | `untrimmed`, `recased` | cleaned, flagged |
| 8 | slash date | CMP0018 `START_DATE` | `2023/05/15` | 2023-05-15 | | `slash_ymd` | cleaned, flagged |
| 9 | slash date | DSP0000018 `SPEND_DATE` | `2023/07/04` | 2023-07-04 | | `slash_ymd` | cleaned, flagged |
| 10 | slash date | L00000018 `CREATED_DATE` | `2023/06/17` | 2023-06-17 | | `slash_ymd` | cleaned, flagged |
| 11 | slash date | CV0000018 `CONVERTED_DATE` | `2023/07/05` | 2023-07-05 | | `slash_ymd` | cleaned, flagged |
| 12 | blank value | CMP0030 `CAMPAIGN_NAME` | `[]` | NULL | `Affiliate 2024 030` | `missing` | flagged; recovered in the fill column |
| 13 | blank value | DSP0000030 `SPEND_DATE` | `[]` | NULL | 2023-07-16 | `missing` | flagged; recovered in the fill column |
| 14 | blank value | L00000030 `CREATED_DATE` | `[]` | NULL | (no fill column) | `missing` | flagged; **unrecoverable** |
| 15 | blank value | CV0000030 `CONVERTED_DATE` | `[]` | NULL | (no fill column) | `missing` | flagged; **unrecoverable** |

In short (`02T [22]`, class and grand totals):

- **All 15 defects are flagged**, with 18 codes in total (each casing/whitespace cell carries two:
  4 + 3 × 2 + 4 + 4), on 15 distinct rows. No other row carries a code (`02 [13]`).
- **11 are cleaned in place:** 4 duplicate copies collapsed, 3 casing/whitespace values
  normalised, 4 slash dates parsed as Y/M/D. Each cleaned value equals the clean release
  (`02T [24]`).
- **2 blanks are recovered by a provable fill**, kept apart from the original column, which stays
  NULL:
  - `CAMPAIGN_NAME_FILLED`: the naming rule `INITCAP(REPLACE(channel, '_', ' ')) || ' ' ||
    YEAR(start_date) || ' ' || RIGHT(campaign_id, 3)` holds for every named campaign in Phase 2,
    which leaves exactly one candidate (`01b 5b`, `5c`). (`INITCAP` is applied to the channel only
    after `_` becomes a space.)
  - `SPEND_DATE_FILLED`: previous + 1 day, used only when it also equals next − 1 day, with
    neighbours in `SPEND_ID` order within the campaign (`LAG` / `LEAD`). Phase 2 confirmed the one
    candidate order-free from CMP0001's date spine (`01b 5d`).
- **2 blanks are unrecoverable and stay NULL.** L00000030's created date has 2 candidates
  (2023-06-17 or 2023-06-18) and CV0000030's converted date 22 (2023-06-26..2023-07-17)
  (`01b 5c`). A guess would be a fabricated value, so the column stays NULL with its `missing`
  flag.

### De-duplication

`02T [21]`: 6,124 RAW rows become 6,120 STAGING rows: exactly 4 surplus copies collapsed, 4
duplicated keys flagged, 0 NULL keys, 6,120 distinct keys, and 15 rows with
`DQ_IS_VALID = FALSE`.

### Reconciliation with the clean release

Each challenge row is compared with its clean-release row by key, with `EQUAL_NULL` on every
contract column (DQ and lineage columns are not compared). Once as the view is ("blanks NULL"),
and once with the `*_FILLED` columns in place of the original column (`02T [24]`):

| View | Rows | Match, blanks NULL | Not matching | Match, with fills | Not matching |
|---|---:|---:|---|---:|---|
| `STG_CHALLENGE_CAMPAIGNS` | 120 | 119 | CMP0030 | 120 | |
| `STG_CHALLENGE_DAILY_SPEND` | 2,000 | 1,999 | DSP0000030 | 2,000 | |
| `STG_CHALLENGE_LEADS` | 2,000 | 1,999 | L00000030 | 1,999 | L00000030 |
| `STG_CHALLENGE_CONVERSIONS` | 2,000 | 1,999 | CV0000030 | 1,999 | CV0000030 |
| **Total** | **6,120** | **6,116** | | **6,118** | |

The cell-level check (`02T [25]`) names the only differing cells:

| Cell | Challenge value | After fills | Clean release | Outcome |
|---|---|---|---|---|
| CMP0030 `CAMPAIGN_NAME` | NULL | `Affiliate 2024 030` | `Affiliate 2024 030` | fixed by fill |
| DSP0000030 `SPEND_DATE` | NULL | 2023-07-16 | 2023-07-16 | fixed by fill |
| L00000030 `CREATED_DATE` | NULL | NULL | 2023-06-18 | residual mismatch |
| CV0000030 `CONVERTED_DATE` | NULL | NULL | 2023-07-13 | residual mismatch |

So with the fills, **6,118 of 6,120 rows** reproduce the clean release exactly, as Phase 2
predicted (architecture decision 5), and the 2 residual cells are NULL, never a wrong value. The
dbt test [`assert_challenge_reconciliation`](../dbt/tests/challenge/assert_challenge_reconciliation.sql)
checks both row counts and the 2 residual cells on every build.

Two more facts from `02T [23]`: every challenge key exists in the clean views (0 missing in each
of the 4 views), and 1,687 challenge conversions point to leads outside the leads extract, all of
which exist in `STG_LEADS`. That comes from how the extracts were cut (Phase 2, `01b 1c`), not
from a defect.

## What the main pipeline guarantees

The main pipeline is the clean release: `RAW.{CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS}` →
`STG_*` → MART. dbt tests it on every `make dbt-build`, all passing (`B`; the tests are listed in
[dbt.md](dbt.md#tests)). The tables below give each guarantee as a block of the first version's
test files, with the number of PASS rows in their last run.

**STAGING** (`02T`, 194 PASS rows in total; in dbt: the tests in `_staging.yml`,
`_staging_unit_tests.yml`, `dbt/tests/staging/` and `dbt/tests/challenge/`):

| Block | Guarantee | PASS rows | Evidence |
|---|---|---:|---|
| 0 | Runs as `CRM_TRANSFORMER` with no secondary roles, on `MARKETING_WH` | 1 | `02T [5]` |
| 1 | All 8 objects are views with exactly the contract columns, order and types (13 / 11 / 10 / 10 columns clean, 14 / 12 / 10 / 10 challenge) | 8 | `02T [6]` |
| 2 | Rule unit tests: 30 edge-case inputs through the trim, type gates and codes give the expected value and codes | 30 | `02T [7]` |
| 2b | The deployed views contain exactly those rule texts, and no naive backslash-dot, `AUTO` or `::DATE` | 8 | `02T [8]` |
| 3 | Every RAW row reaches STAGING: 120 / 11,240 / 261,684 / 39,696 rows | 4 | `02T [9]` |
| 4 | No clean-view row carries a DQ issue | 4 | `02T [10]` |
| 5 | 7 keys unique and not NULL (`GROUP BY ... HAVING COUNT(*) > 1`): the 4 PKs, `CAMPAIGN_NAME`, `(CAMPAIGN_ID, SPEND_DATE)`, conversions' `LEAD_ID` | 7 | `02T [11]` |
| 6 | 0 NULLs in the 23 business columns and `CAMPAIGN_DAYS` | 24 | `02T [12]` |
| 7 | Accepted values of the 4 code columns, each with its Phase 2 row count (15 values) | 15 | `02T [13]` |
| 8 | Relationships (`NOT EXISTS`): 0 orphans for the 3 foreign keys; every campaign has spend, leads and conversions; 221,988 leads without a conversion | 7 | `02T [14]` |
| 9 | The 10 Phase 2 business rules: 0 violations. Spend ≤ budget is checked after summing spend per campaign; leads ≤ clicks after counting leads per campaign × day (11,233 campaign-days with leads) | 10 | `02T [15]` |
| 10 | Typed dates reproduce the Phase 2 coverage of all 5 date columns; 0 dates outside the documented coverage 2023-01-01..2025-12-31 | 5 | `02T [16]` |
| 11 | Campaign windows: `CAMPAIGN_DAYS` 46..150, summing to 11,240 and equal to each campaign's spend rows; 0 spend rows or leads outside their window; 7 spend days with zero leads; 0 conversions before their lead or more than 21 days after it; 4,716 after the campaign end | 12 | `02T [17]` |
| 12 | Control totals to the cent: budget 5,418,642.16, spend 4,523,050.02, impressions 436,844,819, clicks 7,102,319, lead score 13,233,637, revenue 21,561,839.01, 16,691 purchases, 23,005 trials | 8 | `02T [18]` |
| 13 | A grain-safe channel summary (each fact aggregated to the campaign first, then 1:1 joins) reproduces the Phase 2 channel table and the publisher's spend and revenue by channel | 6 | `02T [19]` |
| 14 | `LEAD_SOURCE` equals the campaign `CHANNEL` (warning level: WARN, never FAIL); 0 mismatches, clean and challenge | 2 | `02T [20]` |
| 15-19 | Challenge track: de-duplication, the 15 defects, keys in the clean views, reconciliation by row and by cell ([above](#challenge-track-results)) | 43 | `02T [21-25]` |

**MART core** (`02bT`, 245 PASS rows; in dbt: the tests in `_marts.yml`, `_marts_unit_tests.yml`
and `dbt/tests/marts/`; the tables are described in the
[data dictionary](data_dictionary.md#mart-core)):

| Block | Guarantee | PASS rows | Evidence |
|---|---|---:|---|
| 0-1 | Run context; MART holds exactly the 5 core tables with the contract columns, order, types and comments, plus the Phase 1 connection-test table and the 5 Phase 4 analysis marts (their columns were tested in [`02c`](https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/docs/evidence/02c_analysis_marts_tests.txt)) | 12 | `02bT [5-6]` |
| 2-3 | Built from complete, unflagged STAGING rows; each table has exactly the rows of its grain (1,096 / 120 / 11,240 / 261,684 / 120) | 10 | `02bT [7-8]` |
| 4-6 | Keys unique and not NULL; 0 NULLs where a value is required; every foreign key (campaigns and dates) finds its dimension row, in both directions | 29 | `02bT [9-11]` |
| 7-8 | `DIM_DATE` is a gap-free calendar 2023-01-01..2025-12-31 with correct attributes | 22 | `02bT [12-13]` |
| 9 | **Spend is never double counted:** `SUM(SPEND)` is 4,523,050.02 in every table that carries spend, and every other measure has the same total in every table; `BUDGET_PRORATED` sums back to each campaign budget within 0.01 | 30 | `02bT [14]` |
| 10-11 | Lead-cohort semantics of `FCT_LEAD_CONVERSIONS` (flags, lag 0..21, 4,716 conversions after the campaign end, `AS_OF_DATE`, maturity); lead score segments | 22 | `02bT [15-16]` |
| 12 | Every campaign, every base column, in every MART table equals the Phase 2 campaign baseline; every ratio equals an independent Python computation | 38 | `02bT [17]` |
| 13-16 | Channel roll-up equals the Phase 2 channel bases, and its spend and revenue the publisher reference; channel ratios are ratios of sums; ratio sanity; the ROAS ranking matches the baseline | 46 | `02bT [18-21]` |
| 17 | Activity months and lead-cohort months reproduce the Phase 2 baseline for all 36 months | 36 | `02bT [22]` |

## Deliberate choices and limits

- **Flags, not fixes, wherever a value is uncertain.** Only provable repairs change a value; the
  two fills live in separate columns and the two unrecoverable dates stay NULL.
- **ISO drift is rejected, not repaired.** `2023-1-5` becomes NULL + `unparseable`, because ISO is
  the documented format; only the year-first slash class is recovered. Both cases are flagged.
- **An NBSP is neither trimmed nor accepted.** It makes a number `unparseable` and an id or code
  `nonconforming`; Phase 2 found no NBSP in any file (0 non-printable cells: `01b 3a` for the
  extracts, [data_profile.md](data_profile.md#data-quality-summary) for the clean release).
- **The challenge extracts are partial per campaign** (Phase 2, `01b 1d`), so they support row
  and cell reconciliation, not funnel KPIs. MART and the dashboard use only the clean release.
- **Business rules are tested on the clean views.** On the challenge rows, Phase 2 found 0
  violations of its 10 rule checks (`01b 6b [29]`); Phase 3 re-tests `lead_source` = channel there
  (`02T [20]`).
- **Rules are inline SQL**, not UDFs, because `CRM_TRANSFORMER` cannot create UDFs. They live in
  one shared macro per entity (`dbt/macros/staging/clean_*.sql`), so a clean view and its
  challenge view compile from the same rules, and the unit tests in `_staging_unit_tests.yml` pin
  them on edge-case inputs ([dbt.md](dbt.md#unit-tests)).
