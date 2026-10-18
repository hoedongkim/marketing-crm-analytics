# dbt (Phase 5)

Phase 5 moved the hand-written Phase 3-4 SQL build into a dbt Core project in [`dbt/`](../dbt/).
dbt now builds every STAGING view and MART table, under the **same names in the same schemas**, so
the four analysis files (`sql/03-06`) keep working unchanged (`P` C) and the Data Studio dashboard
of Phase 6 is built on the same table names. The principle of the project holds: every business metric
is computed in Snowflake SQL, dbt manages and tests that SQL pipeline, and Data Studio only
visualises.

Status (2026-10-14): done. `make dbt-build` ran with 0 errors and 0 deprecations, and the dbt-built
objects have the same rows, columns and types as the SQL-built ones (only the comments differ, by
design). Phase 6 (2026-10-14) added one model, `mart_conversion_funnel`
([below](#plan-names-and-the-models-that-serve-them)), built and tested with
`make dbt-build-select DBT_SELECT=mart_conversion_funnel+` and `make dbt-test`, not with a full
build: the project now has 20 models (11 MART tables), 258 data tests (16 singular) and 7 unit
tests, all passing (`F`). The counts in [At a glance](#at-a-glance) and [Tests](#tests) are the
Phase 5 full build (`B`, `P`); [lineage.md](lineage.md) always shows the current ones. Sources for
every number on this page:

| Tag | Evidence file | Produced by |
|---|---|---|
| `B` | [`evidence/05_dbt_build.txt`](evidence/05_dbt_build.txt) | `make dbt-build`: parse, build, source freshness, docs generate (full log) |
| `P` | [`evidence/05_dbt_parity.txt`](evidence/05_dbt_parity.txt) | the parity report: `make parity-snapshot` / `parity-diff` / `parity-check` / `sql-checks` / `seeds-check` (now `expected-seeds-check`), the test inventory and lineage from the manifest, the planted-defect runs, and the wiring checks that need no Snowflake query (section I) |
| `F` | [`evidence/06_funnel_mart.txt`](evidence/06_funnel_mart.txt) | Phase 6: `make dbt-parse`, `make dbt-build-select DBT_SELECT=mart_conversion_funnel+`, `make dbt-test`, the read-only `sql/02b` and `sql/02c` test files, planted defects for the new singular test, the deployed types and grants |

The lineage graph, generated from the dbt manifest, is on its own page: **[lineage.md](lineage.md)**.

## Contents

1. [At a glance](#at-a-glance)
2. [Why dbt Core v1, not v2 (Fusion)](#why-dbt-core-v1-not-v2-fusion)
3. [Project layout](#project-layout)
4. [Layers and conventions](#layers-and-conventions)
5. [Schema names: the generate_schema_name override](#schema-names-the-generate_schema_name-override)
6. [Sources and freshness](#sources-and-freshness)
7. [Tests](#tests)
8. [Seeds: independent expected values](#seeds-independent-expected-values)
9. [Parity with the hand-written SQL build](#parity-with-the-hand-written-sql-build)
10. [Plan names and the models that serve them](#plan-names-and-the-models-that-serve-them)
11. [How to run](#how-to-run)

## At a glance

| What | Result | Source |
|---|---|---|
| Versions | dbt Core 1.12.5, dbt-snowflake 1.12.2; dbt_utils 1.4.1 | `B` ("Running with dbt=1.12.5", "Registered adapter: snowflake=1.12.2"); [`package-lock.yml`](../dbt/package-lock.yml) |
| Project | 8 sources, 19 models (8 views, 1 ephemeral, 10 tables), 3 seeds, 245 data tests, 7 unit tests, 2 exposures | `B` ("Found 19 models, 245 data tests, 3 seeds, 8 sources, 2 exposures, 684 macros, 7 unit tests"), `P` section F |
| `dbt parse --no-partial-parse --show-all-deprecations` | 0 deprecations; `make dbt-parse` and `make dbt-build` now also make any deprecation an error, so the 0 is enforced | `B` (first block), `P` step 2 and section I |
| `dbt build` | `PASS=273 WARN=0 ERROR=0 SKIP=0 NO-OP=2 REUSED=0 TOTAL=275` in 34.01 s (the 2 NO-OPs are the exposures) | `B` |
| `dbt source freshness` | 8 of 8 PASS | `B` |
| `dbt docs generate` | catalog written | `B` (last line) |
| Parity with the SQL build | 18 of 18 objects with identical row count and `HASH_AGG(*)`; 245 of 245 columns with identical position, type and nullability | `P` sections A-A.2 |
| Read-only rebuild of the hand-written SQL vs the dbt objects | 18 of 18 PASS (MINUS 0 / 0 both ways), 2 of 2 control rows detect their planted difference | `P` section A.3 |
| The 7 hand-written Phase 3-4 check files on the dbt objects | 1,288 PASS rows (1,285 on the SQL build), 0 FAIL | `P` section C |

`TOTAL=275` is every node the build ran: 3 seeds + 8 views + 10 tables + 245 data tests + 7 unit
tests + 2 exposures. The ephemeral model is compiled into its child, so it is not a node of the run.

## Why dbt Core v1, not v2 (Fusion)

Checked on 2026-10-13 against PyPI and the dbt documentation (the setup research for this phase;
sources: [dbt versions and support](https://docs.getdbt.com/docs/dbt-versions/core),
[installing dbt](https://docs.getdbt.com/docs/local/install-dbt),
[upgrading to v2](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/upgrading-to-v2),
[licensing](https://docs.getdbt.com/docs/dbt-licensing),
[connection profiles](https://docs.getdbt.com/docs/local/connection-profiles),
[PyPI `dbt`](https://pypi.org/project/dbt/), and the
[dbt-snowflake changelog](https://github.com/dbt-labs/dbt-adapters/blob/main/dbt-snowflake/CHANGELOG.md)):

- **`pip install dbt` no longer installs dbt Core.** Since September 2026 the PyPI package `dbt`
  is dbt v2 ("Fusion", a Rust rewrite). It does not use the Python `dbt-snowflake` adapter; its
  adapters use ADBC drivers that are downloaded from the dbt Labs CDN on first run. This project
  installs `dbt-core~=1.12.5` and `dbt-snowflake~=1.12.2` explicitly ([`requirements.txt`](../requirements.txt)),
  and `dbt-snowflake` 1.12 itself pins `dbt-core<2.0`. **Never run `pip install dbt` in this venv**:
  it would install v2 and compete for the `dbt` command.
- **v1 is the mature, supported line.** dbt Core 1.12 is Apache 2.0 and in Active support until
  2027-07-15, which covers this project. The v2 maturity signals still conflict (the docs list v2
  as released with Active support; the README and the PyPI classifiers still say beta / alpha),
  and the Fusion distribution is proprietary (free) software.
- **v2 does not currently read `profiles.yml` from the working directory** (it expects
  `~/.dbt/`), and this project keeps a committed, secret-free `dbt/profiles.yml` next to
  `dbt_project.yml`.
- **The project stays ready for v2.** Every YAML file uses the current syntax (`data_tests:`,
  test inputs under `arguments:`, options under `config:`, freshness under `config:`), and the
  full parse lists 0 deprecations (`B`), which dbt Labs names as the precondition for a move to v2.
  `make dbt-parse` and `make dbt-build` turn any deprecation into an error
  (`--warn-error-options '{"error": ["Deprecations"]}'`), so a new one cannot slip in unnoticed
  (`P` I).

## Project layout

```
dbt/
├── dbt_project.yml          layers, materializations, persist_docs, vars (the documented assumptions), seed column types
├── profiles.yml             one target `prod`; every connection setting from env_var() (committed: no secrets)
├── packages.yml             dbt_utils 1.4.1
├── package-lock.yml         the resolved version + hash (committed; `make dbt-deps` installs exactly this)
├── macros/
│   ├── generate_schema_name.sql   models land in exactly STAGING / MART (see below)
│   └── staging/                   the cleaning rules, one macro per entity, shared by the clean and the challenge track:
│                                  clean_campaigns, clean_daily_spend, clean_leads, clean_conversions
├── models/
│   ├── overview.md          the front page of the dbt docs site
│   ├── exposures.yml        downstream consumers: the Data Studio dashboard, the Phase 4 analyses
│   ├── staging/             _sources.yml (RAW, freshness), _staging.yml (descriptions + tests),
│   │                        _staging_unit_tests.yml, 8 stg_*.sql (one macro call each)
│   ├── intermediate/        int_lead_conversions.sql (ephemeral), _intermediate.yml
│   └── marts/               _marts.yml, _marts_unit_tests.yml, 11 models: dim_*, fct_*, mart_*
├── seeds/                   expected_campaign_kpi.csv, expected_totals.csv (generated),
│                            publisher_channel_reference.csv (typed in), _seeds.yml
└── tests/                   16 singular tests: marts/ (11), staging/ (3), challenge/ (2)
```

`dbt/target/`, `dbt/dbt_packages/` and `dbt/logs/` are git-ignored (build output, installed
packages, logs). `package-lock.yml` and the seeds are committed.

## Layers and conventions

| Layer | Folder | Materialized | Schema | Objects | Reads |
|---|---|---|---|---|---|
| sources | `models/staging/_sources.yml` | (RAW tables, loaded by `make load`) | `RAW` | 8: 4 clean + 4 `CHALLENGE_*` | - |
| staging | `models/staging/` | view | `STAGING` | `STG_CAMPAIGNS`, `STG_DAILY_SPEND`, `STG_LEADS`, `STG_CONVERSIONS` and the 4 `STG_CHALLENGE_*` | one source each |
| intermediate | `models/intermediate/` | ephemeral (no object) | - | `int_lead_conversions` | `stg_leads`, `stg_conversions`, `stg_campaigns` |
| marts | `models/marts/` | permanent table | `MART` | `DIM_DATE`, `DIM_CAMPAIGN`, `FCT_DAILY_SPEND`, `FCT_LEAD_CONVERSIONS`, `MART_CAMPAIGN_PERFORMANCE`, `FCT_CAMPAIGN_DAILY_ACTIVITY`, `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`, `MART_CHANNEL_PERFORMANCE`, `MART_LEAD_QUALITY`; since Phase 6 `MART_CONVERSION_FUNNEL` (dbt only, no SQL twin) | staging, intermediate, other marts |
| seeds | `seeds/` | table (dbt's seed default: transient) | `STAGING` | `EXPECTED_CAMPAIGN_KPI`, `EXPECTED_TOTALS`, `PUBLISHER_CHANNEL_REFERENCE` | read by tests only |

- **Same objects as the SQL build.** Every model has the name and schema of the object
  `sql/02*.sql` built, the same column order and the same column types (`P` A.2), so dbt replaced
  the SQL build in place. dbt names are lower case (`stg_leads`); Snowflake stores the unquoted
  identifiers in upper case (`STAGING.STG_LEADS`).
- **Staging** views are one per RAW table, at the RAW grain after de-duplication; a problem is
  flagged in `DQ_ISSUES`, never dropped ([data_cleaning.md](data_cleaning.md)). The rules live in
  four macros (`macros/staging/clean_*.sql`), so each clean view and its challenge twin run the
  identical rules; each `stg_*.sql` is a single macro call on its source.
- **Intermediate** is ephemeral: `int_lead_conversions` (one row per lead, LEFT JOIN its
  conversion, plus the attributes of its campaign) is compiled into `fct_lead_conversions` as a CTE
  and creates no object. It reads the campaign attributes from `stg_campaigns`, where the SQL build
  read `DIM_CAMPAIGN`; the values are identical (`P` A.1, and
  `tests/marts/assert_campaign_attributes_match_independent_seed.sql`).
- **Marts** are permanent tables (`+transient: false`; dbt-snowflake would default to transient),
  as in the SQL build (`P` A.2: `IS_TRANSIENT = NO` for all 10).
- **Grain rule** (architecture decision 6): every mart aggregates each fact to the target grain in
  its own CTE before any join. The singular test `assert_total_spend_in_every_mart` fails on any
  fan-out.
- **Comments everywhere.** `+persist_docs: {relation: true, columns: true}` writes every model and
  column description to Snowflake as a `COMMENT`. The MART column descriptions are the Phase 3-4
  comments copied verbatim (155 of 155 identical, `P` B.1); the STAGING view columns gained 90
  comments (`P` B.3). The Phase 3-4 contract tests check that every object and MART column has one.
- **Assumptions in one place.** `dbt_project.yml` `vars`: the coverage 2023-01-01..2025-12-31
  (the `DIM_DATE` spine), the as-of date 2025-12-31, the 21-day maturity window and the 21-day
  post-flight window. The tests that check model output do not read these vars back: the seeds,
  unit tests and singular tests pin the same values on their own, so changing a var makes them
  fail until they agree. The one exception is on purpose: `assert_campaign_windows` reads
  `post_window_days` to check that the data still fits the assumption.
- **`ref()` and `source()` only.** No model names a schema or a database; dbt derives the DAG
  from the references ([lineage.md](lineage.md)).

## Schema names: the generate_schema_name override

dbt's default `generate_schema_name` prefixes the target schema: a model with `+schema: MART` in a
target whose schema is `STAGING` would land in `STAGING_MART`. The project overrides it in
[`macros/generate_schema_name.sql`](../dbt/macros/generate_schema_name.sql): a node with a custom
schema lands in exactly that schema, upper-cased, and a node without one falls back to the
profile's schema. `flags.require_valid_schema_from_generate_schema_name: true` turns a null
result into a parse error (without the flag, dbt 1.12 only emits a deprecation warning).

The tradeoff, accepted for this one-person trial project (architecture decision 10):

- **One target, named `prod`, because that is what it is.** Every dbt run replaces the live
  STAGING views and MART tables that Data Studio and the analyses read. There is no development
  copy to try a change in first.
- **A failed run can leave a mixed state.** `dbt build` skips the nodes downstream of a failure,
  but the upstream nodes are already rebuilt, until the next green run.
- **Isolation would need an admin change.** A second database, or per-developer schemas plus a
  `target.name != 'prod'` branch in the macro that adds a suffix. `CRM_TRANSFORMER` cannot create
  schemas, so either needs the admin first.
- **Until then, select.** `make dbt-build-select DBT_SELECT=stg_leads+` rebuilds and tests only
  the changed model and everything downstream of it; the full build is for refreshing everything.

## Sources and freshness

[`models/staging/_sources.yml`](../dbt/models/staging/_sources.yml) declares the 8 RAW tables as
the source `raw`, without a `database:` key, so a source always resolves to the profile's database
(`SNOWFLAKE_DATABASE`): the models can never read RAW from one database while building in another.
The 4 clean source keys carry `unique` and `not_null` tests (8 tests, `B`), so a duplicate in a
reload fails the build before staging runs.

Freshness reads `_LOADED_AT`, the load start time the loader writes on every RAW row
(architecture decision 1). The dataset is a static, versioned release loaded once, so "fresh"
cannot mean "loaded today"; the thresholds only catch a RAW layer that was never loaded or is
unexpectedly old: **warn after 30 days** (the length of the Snowflake trial), **error after 365
days**. `dbt build` does not check freshness, so `make dbt-build` runs `dbt source freshness`
after the build: 8 of 8 PASS (`B`).

## Tests

245 data tests and 7 unit tests, all passing in the build (`B`, `P` section G). Data tests run
after the node they test; unit tests run before their model is built, on mocked inputs. Phase 6
added 13 data tests on `mart_conversion_funnel` (12 generic + 1 singular): 258 data tests, all
passing in `make dbt-test` (`F` step 3); the per-type counts below are the Phase 5 build.

### Data tests by type

| Type | Count | What it guards here (examples) |
|---|---:|---|
| `not_null` | 97 | every key and every column that must have a value (the columns that may be NULL by design, such as the conversion columns of an unconverted lead, are left out) |
| `dbt_utils.accepted_range` | 36 | positive spend, impressions, clicks and budgets; rates and shares within 0..1; lead score 1-100; lag 0-21 days; campaigns of at least 1 day; `QUARTER` 1-4, `DAY_OF_WEEK_ISO` 1-7 |
| `accepted_values` | 29 | the 5 channel codes (also on `LEAD_SOURCE`), the 3 objectives, `trial` / `purchase`, the score segments `Low` / `Medium` / `High` and the 10 score bands, the 0/1 flags, `DQ_IS_VALID` TRUE on every clean row, the years 2023-2025 |
| `unique` | 25 | primary keys (`CAMPAIGN_ID`, `SPEND_ID`, `LEAD_ID`, `CONVERSION_ID`, `DATE_DAY`, `CHANNEL`) and alternate keys (`CAMPAIGN_NAME`; `STG_CONVERSIONS.LEAD_ID`: a lead converts at most once) |
| `dbt_utils.expression_is_true` | 21 | row invariants: `end_date >= start_date`, `clicks <= impressions`, `trials + purchases = converted_leads`, `is_trial + is_purchase = is_converted`, `converted_same_month + converted_later_month = converted_leads`, `mature_leads <= leads` |
| `relationships` | 16 | 3 in staging (spend and leads to `stg_campaigns`, conversions to `stg_leads`), 13 in marts (4 to `dim_campaign`, 9 date and month columns to `dim_date`) |
| singular (`dbt/tests/*.sql`) | 15 | cross-model and independent checks, below |
| `dbt_utils.unique_combination_of_columns` | 6 | composite grain keys: `(campaign_id, spend_date)` twice, `(campaign_id, activity_date)`, `(month_start, channel)`, `(cohort_month, channel)`, `(channel, score_band)` |
| **total** | **245** | severity `error` 244, `warn` 1 |

The counts are `P` section G. They include the 8 tests on the RAW source keys and 7 on the seed
keys and values (each listed by name in `B`). The one `warn` test is
`assert_lead_source_matches_campaign_channel`: `LEAD_SOURCE` matches the campaign's channel for
every lead today, but MART never relies on it (every fact takes the channel from `DIM_CAMPAIGN`),
so a mismatch would be drift in the source to look at, not a broken pipeline. The same check is a
WARN in `sql/02_data_cleaning_tests.sql` (block 14). Per-model counts: [lineage.md](lineage.md#models).

### Singular tests

Sixteen SQL files in [`dbt/tests/`](../dbt/tests/) (fifteen in Phase 5), each returning the rows
that violate a rule. Most are dbt ports of a block of the hand-written test files; 12 of them
compare a model with a seed of independent expected values
([lineage.md](lineage.md#seeds-and-singular-tests)).

| Test | Guards |
|---|---|
| `staging/assert_staging_keeps_every_raw_row` | each clean view has one row per RAW row (flag, never drop) |
| `staging/assert_campaign_windows` | one spend row per campaign day; no spend row or lead outside its campaign window; every conversion 0-21 days after its lead |
| `staging/assert_lead_source_matches_campaign_channel` | the `warn` check above |
| `challenge/assert_challenge_defects_flagged` | the rules flag exactly the 15 injected defects of the dirty extracts that Phase 2 located, each with the expected codes and value ([data_cleaning.md](data_cleaning.md#challenge-track-results)) |
| `challenge/assert_challenge_reconciliation` | after cleaning, the challenge rows equal their clean rows except exactly the 2 blank dates that no evidence can recover (the Phase 3 result) |
| `marts/assert_total_spend_in_every_mart` | spend is 4,523,050.02 in every model that carries it: no fan-out |
| `marts/assert_control_totals_in_every_mart` | every other additive base (campaigns, budget, impressions, clicks, leads, score sum, conversions, trials, purchases, revenue, mature leads) equals its independent total in every model that carries it |
| `marts/assert_campaign_kpi_equals_independent_seed` | every campaign of `MART_CAMPAIGN_PERFORMANCE` equals the independent per-campaign bases, both directions |
| `marts/assert_campaign_attributes_match_independent_seed` | channel and objective in `DIM_CAMPAIGN` and on every row of three facts equal `campaigns.csv` |
| `marts/assert_channel_rollup_equals_publisher_reference` | spend and revenue per channel equal the publisher's own published figures, on two separate paths |
| `marts/assert_budget_prorated_sums` | `BUDGET_PRORATED` totals the independent value and sums back to each campaign's budget |
| `marts/assert_activity_and_cohort_months_differ_but_agree_in_total` | the activity and cohort monthly series agree in total but differ by month (13,675 conversions land in a later month) |
| `marts/assert_post_flight_activity` | the daily spine has the independent row count (13,760) and books the 4,716 after-end conversions on post-flight days |
| `marts/assert_lead_score_segments` | leads and conversions per score segment equal the independent counts in the fact and in `MART_LEAD_QUALITY` |
| `marts/assert_dim_date_calendar` | `DIM_DATE` is the gap-free 2023-01-01..2025-12-31 calendar, checked against literals, not the build vars |
| `marts/assert_conversion_funnel_reconciles` (Phase 6) | `MART_CONVERSION_FUNNEL`: each stage sums to its independent total, all 25 channel × stage cells equal the per-campaign seed rolled up to channels, `PREV_STAGE_VALUE` is the previous stage of the same channel (NULL on stage 1) and `TOP_OF_FUNNEL_VALUE` its impressions; 6 planted defects each caught by the expected check (`F` step 6) |

A test that compares with a seed fails when the seed value is missing (`IS DISTINCT FROM`, `FULL
OUTER JOIN`), so none can pass vacuously.

### Unit tests

Seven unit tests (`unit_tests:` in [`_staging_unit_tests.yml`](../dbt/models/staging/_staging_unit_tests.yml)
and [`_marts_unit_tests.yml`](../dbt/models/marts/_marts_unit_tests.yml)) feed a model a few
hand-made rows and compare its output with the expected rows. They pin the logic that the real
data does not exercise: the clean release has no dirty value, no zero denominator, no lead on a
maturity boundary.

| Unit test | Model | What it pins |
|---|---|---|
| `stg_leads_routes_dates_by_shape_and_flags_each_cell` | `stg_leads` | date parsing by shape: ISO, year-first slash (flagged), blank (NULL, missing), impossible or drifted dates (NULL, unparseable); padded and recased values; a score that overflows |
| `stg_conversions_keeps_most_complete_copy_and_flags_duplicates` | `stg_conversions` | de-duplication keeps the most complete copy, records the number of copies and whether they differ; money needs exactly 2 decimals |
| `stg_challenge_daily_spend_fills_a_blank_date_only_when_one_day_fits` | `stg_challenge_daily_spend` | `SPEND_DATE_FILLED` fills a blank only when exactly one day fits between its neighbours in the same campaign |
| `fct_lead_conversions_score_segment_boundaries_and_flags` | `fct_lead_conversions` | segment boundaries 40/41 and 70/71, NULL for a missing score; the 0/1 flags, revenue 0.00 and NULL lag when unconverted; `IS_MATURE` on both sides of the maturity boundary |
| `mart_campaign_performance_zero_denominators_give_null` | `mart_campaign_performance` | every ratio is NULL, not an error or a fake 0, when its denominator is 0; sums and ratios of sums, rounded once |
| `fct_campaign_daily_activity_spine_ends_at_end_date_plus_21` | `fct_campaign_daily_activity` | the spine ends at `END_DATE + 21`, is clipped at the coverage end, and books post-flight conversions on post-flight days |
| `mart_channel_performance_wilson_interval` | `mart_channel_performance` | the Wilson 95% interval equals an independent 60-digit computation; NULL bounds for a channel without leads |

**Can they fail?** Four deliberately broken copies of the logic were run on 2026-10-14 and each
was restored byte-identical afterwards (`P` section H): flipping the `IS_MATURE` comparison from
`<=` to `>` fails all 10 rows of the fct_lead_conversions unit test, `<=` to `<` fails the
boundary lead; dropping the campaign partition from the spend-date fill, or filling whenever a
previous date exists, each fails the fill unit test on its intended row. A seed copy with one
campaign relabelled and one removed makes `assert_campaign_attributes_match_independent_seed`
return 8 failing rows covering all 4 models it checks.

## Seeds: independent expected values

The singular tests need expected values that were computed without Snowflake and without the
SQL under test. In Phases 2-4 those values lived in scratch scripts and inline `VALUES` lists;
Phase 5 makes them reproducible from the repository as dbt seeds
([`seeds/_seeds.yml`](../dbt/seeds/_seeds.yml)):

| Seed | Rows | Content | Made by |
|---|---:|---|---|
| `expected_campaign_kpi` | 120 | per campaign: channel, objective, budget and the 9 funnel bases (13 columns) | [`scripts/independent_check.py`](../scripts/independent_check.py) |
| `expected_totals` | 29 | `metric,value`: control totals, time counts (after-end and later-month conversions, spine rows, mature leads), score segment sizes, calendar days | `scripts/independent_check.py` |
| `publisher_channel_reference` | 5 | spend and attributed revenue per channel, as printed on the publisher's dataset page | typed in by hand (the outside check) |

- **Independent path.** `independent_check.py` reads `data/raw/source/*.csv` with the Python
  standard library only (`csv`, `decimal`, `datetime`): no Snowflake, no SQL, no pandas. Every
  amount is an exact `Decimal`.
- **Reproducible.** `make expected-seeds` rewrites the two generated seeds; `make
  expected-seeds-check` regenerates them in a temporary directory and fails on any difference,
  and also checks the hand-typed publisher reference against the CSV roll-up to the cent. It
  passed (`P` section E), and `make dbt-build` runs it first, so the build never tests against
  stale expectations. `expected_campaign_kpi.csv` is byte-identical to the Phase 2 local
  baseline of 2026-10-13 (`P` E).
- **Where they live.** `dbt build` loads them as three small transient tables in `STAGING`
  (`P` A.2). No model reads them, and `CRM_REPORTER` (Data Studio) cannot see `STAGING`. After the dbt build, `SVC_CRM_BI` / `CRM_REPORTER` read all 11 MART tables (the 10 dbt-built ones plus `CONNECTION_TEST`) through the MART future grants and still cannot see `RAW` or `STAGING` (`P` section J).
  `sql/02_data_cleaning_tests.sql` block 1 lists them as allowed non-contract objects (`P` D).

## Parity with the hand-written SQL build

The goal was a port, not a rewrite: the dbt build had to produce exactly the objects the
Phase 3-4 SQL produced. Four independent checks (`P`):

1. **Snapshot before and after.** `sql/parity/parity_snapshot.sql` fingerprinted every STAGING and
   MART object on the SQL build (before the first dbt run) and again on the dbt build;
   `scripts/parity_diff.py` compared the two field by field (`P` A):
   - **Data:** `COUNT(*)` and `HASH_AGG(*)` identical for 18 of 18 objects, for example
     `STG_LEADS` 261,684 rows, hash 6233214971418270007 both times; `MART_CHANNEL_PERFORMANCE`
     5 rows, hash -8733952273888884832 both times (all 18 in `P` A.1).
   - **Shape:** 18 of 18 objects keep their type, transient flag and owner (8 views; 10 permanent
     tables, owner `CRM_TRANSFORMER`); 245 of 245 columns keep their position, full type and
     nullability (`P` A.2).
2. **Read-only rebuild from RAW.** `scripts/parity_minus.py` turns the 18 `CREATE` bodies of
   `sql/02*.sql` into one CTE chain from RAW per object and compares each with the deployed dbt
   object by `COUNT`, `MINUS` in both directions and `HASH_AGG`. 18 of 18 PASS, and 2 of 2 control
   rows detect a planted difference (a 1-cent budget change, and a duplicated row that only
   `COUNT` and `HASH_AGG` can see) (`P` A.3). This check creates nothing and needs no SQL build,
   so it can be repeated at any time (`make parity-check`).
3. **Comments.** The 155 MART column comments are identical character for character; the 18
   relation comments changed only in their provenance sentence ("Built by dbt (models/...,
   ported from sql/...)"); 90 STAGING column comments were added (`P` B).
4. **The hand-written checks on the dbt objects.** The 7 Phase 3-4 check files, run read-only on
   the dbt build, all exit 0 (`P` C):

   | File | PASS on the SQL build | PASS on the dbt build | FAIL |
   |---|---:|---:|---:|
   | `sql/02_data_cleaning_tests.sql` | 194 | 197 | 0 |
   | `sql/02b_core_models_tests.sql` | 245 | 245 | 0 |
   | `sql/02c_analysis_marts_tests.sql` | 258 | 258 | 0 |
   | `sql/03_marketing_overview.sql` | 126 | 126 | 0 |
   | `sql/04_conversion_funnel.sql` | 232 | 232 | 0 |
   | `sql/05_lead_analysis.sql` | 150 | 150 | 0 |
   | `sql/06_marketing_efficiency.sql` | 80 | 80 | 0 |
   | **total** | **1,285** | **1,288** | **0** |

   The 3 extra rows are the 3 seed tables in block 1 of the first file, the only edit in `sql/`
   (`P` D). In the other six files every output line except the session line is identical to the
   Phase 3-4 evidence, every printed analysis number included.

The SQL files stay in `sql/` as the record of Phases 3-4 and as the reference of these checks.
`make staging` / `marts` / `analysis-marts` / `models` still run them, but they are labelled
legacy: they would replace the dbt-built objects (comments included) until the next dbt build.

## Plan names and the models that serve them

The Phase 5 sketch named page-shaped marts such as `mart_conversion_funnel` and
`mart_marketing_efficiency`. The built marts are organised by **grain** instead (campaign,
channel, month × channel, cohort month × channel, channel × score band, campaign × day), and
each dashboard page reads the tables whose grain its charts need. A page-shaped table would
repeat the same additive bases at the same grain as an existing table: two copies of one KPI
that could drift apart, and Data Studio would still need the bases to re-aggregate ratios
(architecture decision 9). The [coverage matrix](kpi_definitions.md#coverage-matrix) maps every
KPI of every page to its table and columns.

**`mart_conversion_funnel` exists since Phase 6**, for one reason the grain tables cannot serve:
a funnel or bar chart needs the stages as **rows** (one dimension `STAGE`, one metric), while
`MART_CHANNEL_PERFORMANCE` holds them as five columns. It is that table's five funnel bases
unpivoted, 5 channels × 5 stages = 25 rows, read from `mart_channel_performance` so the two cannot
drift apart (the singular test `assert_conversion_funnel_reconciles` also compares every cell with
the independent seeds). It stores no ratio and no `ALL` row; its `PREV_STAGE_VALUE` and
`TOP_OF_FUNNEL_VALUE` columns are additive across channels, so the stage ratios are thin ratios of
sums that stay correct under a channel filter
([KPI definition](kpi_definitions.md#funnel-stages-and-stage-conversion),
[columns](data_dictionary.md#mart_conversion_funnel)). `mart_marketing_efficiency` is still served
by the grain tables:

| Plan name / dashboard page | Served by | KPIs (coverage matrix) |
|---|---|---|
| `mart_conversion_funnel` / page 2, Conversion Funnel | **`MART_CONVERSION_FUNNEL`** (Phase 6, the model of that name: the funnel chart, channel × stage in long format); `MART_CHANNEL_PERFORMANCE` (the funnel bases impressions → clicks → leads → conversions per channel, with CTR, click-to-lead, lead conversion rate and its Wilson interval, CPL, cost per conversion); `MART_MONTHLY_COHORT` (conversion rate by lead cohort month); `MART_CAMPAIGN_PERFORMANCE` (the same bases per campaign) | [Page 2](kpi_definitions.md#page-2-conversion-funnel) |
| `mart_marketing_efficiency` / page 4, Marketing Efficiency & ROAS | `MART_CHANNEL_PERFORMANCE` and `MART_CAMPAIGN_PERFORMANCE` (spend, attributed revenue, ROAS, CPL, cost per conversion, budget utilisation: both hold whole campaigns, so budget is additive there); `MART_MONTHLY_MARKETING` (spend and revenue over time) | [Page 4](kpi_definitions.md#page-4-marketing-efficiency--roas) |
| page 1, Marketing Overview | `MART_MONTHLY_MARKETING`, `MART_CHANNEL_PERFORMANCE`, `MART_MONTHLY_COHORT`, `FCT_CAMPAIGN_DAILY_ACTIVITY` | [Page 1](kpi_definitions.md#page-1-marketing-overview) |
| page 3, Lead Quality & CRM | `MART_LEAD_QUALITY`, `MART_MONTHLY_COHORT`, `FCT_LEAD_CONVERSIONS` | [Page 3](kpi_definitions.md#page-3-lead-quality--crm) |

The intermediate model the sketch named, `int_lead_conversions`, exists under that name.

## How to run

dbt always runs from the **repository root** with `--project-dir dbt --profiles-dir dbt`
(the make targets do this). dbt 1.12 loads the first `.env` it finds from the working directory
upward (`load_dotenv(find_dotenv(usecwd=True), override=False)` in dbt-core's `cli/main.py`), so the
root `.env` supplies the connection, and variables already set in the shell win over it. Checked
without a Snowflake query (`P` I): with an empty environment (`env -i`), `dbt parse` succeeds from
the repository root and fails outside it with "Env var required but not provided:
'SNOWFLAKE_ACCOUNT'".

First time (after the Phase 1 setup and `make load`):

```bash
make dbt-deps          # install dbt_utils exactly as pinned in dbt/package-lock.yml
make dbt-debug         # versions, profile from the root .env, Snowflake connection
make dbt-build         # seeds check, parse, build, source freshness, docs -> docs/evidence/05_dbt_build.txt
```

| Target | What it does | Writes to Snowflake |
|---|---|---|
| `make expected-seeds` / `expected-seeds-check` | regenerate / verify the independent seeds from the CSV files (offline) | no |
| `make dbt-deps` | install the pinned packages into `dbt/dbt_packages/` | no |
| `make dbt-debug` | `dbt debug` | no |
| `make dbt-parse` | full parse listing every deprecation; any deprecation fails it (no query) | no |
| `make dbt-build` | `expected-seeds-check`, then parse, `dbt build` (everything), source freshness, docs generate; replaces `docs/evidence/05_dbt_build.txt` only when every step passes | **yes: every STAGING and MART object** |
| `make dbt-build-select DBT_SELECT=...` | `dbt build --select ...`, e.g. `stg_leads+`; output in `build/` | yes: the selected objects |
| `make dbt-test [DBT_SELECT=...]` | data and unit tests on the deployed objects, no rebuild; output in `build/dbt_test.txt` | no deployed object (each unit test creates and drops an empty temporary table) |
| `make dbt-freshness` | `dbt source freshness` | no |
| `make dbt-docs` | `dbt docs generate --static`: `dbt/target/index.html` and the single-file `dbt/target/static_index.html` (git-ignored) | no |
| `make dbt-lineage` | `dbt parse`, then `scripts/dbt_lineage.py` rewrites [lineage.md](lineage.md) | no |
| `make dbt-parity` | read-only: parity snapshot, diff against the SQL-build snapshot when `build/parity_before.txt` exists, `parity-check`, `sql-checks`; output in `build/` | no |

The same commands without make, from the repository root:

```bash
.venv/bin/dbt build --project-dir dbt --profiles-dir dbt --select stg_leads+   # one model and its descendants
.venv/bin/dbt test  --project-dir dbt --profiles-dir dbt --select test_type:unit
.venv/bin/dbt docs serve --project-dir dbt --profiles-dir dbt                    # the docs site on localhost:8080
```

**Cost.** The warehouse is a shared X-Small with a 4-credit daily account monitor (2 until it tripped during this phase)
(`RM_ACCOUNT_DAILY`, architecture decision 4); the full build takes about 34 s (`B`). Prefer
`dbt-build-select` and `dbt-test` over repeated full builds. If a run fails with "cannot be
resumed because resource monitor 'RM_ACCOUNT_DAILY' has exceeded its quota", stop: the monitor
resets at 00:00 UTC, and no retry can succeed before then (this happened on 2026-10-14, after the
Phase 5 build and parity runs).
