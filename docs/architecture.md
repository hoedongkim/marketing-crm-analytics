# Architecture

Status (2026-10-18): Phases 1-5 are built and run in the Snowflake trial account (created
2026-10-13, AWS US East 2, 30-day trial ending about 2026-11-12). Phase 6 (the dashboard) is done:
the report is public and reads the frozen Google Sheets snapshot (decision 8). Phase 7
(documentation) is next.

- **Phase 1 (2026-10-13):** bootstrap (run twice, idempotent), checks, RAW load reconciled exactly
  to the files, and the Data Studio key-pair connection.
- **Phase 2 (2026-10-13):** RAW profiled in Snowflake SQL ([data_profile.md](data_profile.md)).
- **Phase 3 (2026-10-14):** `make models` built STAGING (8 views: `STG_*` and `STG_CHALLENGE_*`)
  and the core MART (5 tables: `DIM_DATE`, `DIM_CAMPAIGN`, `FCT_DAILY_SPEND`,
  `FCT_LEAD_CONVERSIONS`, `MART_CAMPAIGN_PERFORMANCE`). Their tests pass: 194 + 245 PASS rows,
  0 FAIL ([evidence](evidence/)). Cleaning rules and results: [data_cleaning.md](data_cleaning.md);
  every object and column: [data_dictionary.md](data_dictionary.md).
- **Phase 4 (2026-10-14):** `make analysis-marts analyses` built 5 analysis marts in MART
  (`FCT_CAMPAIGN_DAILY_ACTIVITY`, `MART_MONTHLY_MARKETING`, `MART_MONTHLY_COHORT`,
  `MART_CHANNEL_PERFORMANCE`, `MART_LEAD_QUALITY`; 13,760 / 180 / 180 / 5 / 50 rows) and ran the
  four read-only analysis files, one per dashboard page (`sql/03_marketing_overview.sql` to
  `sql/06_marketing_efficiency.sql`). Every check passes: 258 test rows for the marts and 126 /
  232 / 150 / 80 check rows in the four analyses, 0 FAIL ([evidence](evidence/)). KPI formulas and
  the Data Studio fields: [kpi_definitions.md](kpi_definitions.md); answers to the business
  questions (draft, finalised in Phase 7): [business_insights.md](business_insights.md).
- **Phase 5 (2026-10-14):** the dbt Core 1.12 project in `dbt/` now builds every STAGING view and
  MART table under the same names (decision 10). `make dbt-build`: 3 seeds, 8 staging views, the
  ephemeral `int_lead_conversions`, 10 MART tables, 245 data tests and 7 unit tests, PASS=273
  ERROR=0 ([evidence](evidence/05_dbt_build.txt)). Parity with the hand-written build: 18 of 18
  objects have identical rows, columns and types, and all 7 Phase 3-4 check files pass on the dbt
  build, 1,288 PASS rows, 0 FAIL ([evidence](evidence/05_dbt_parity.txt)).
  `FCT_LEAD_CONVERSIONS` now reads its campaign attributes from `STG_CAMPAIGNS` through
  `int_lead_conversions` instead of from `DIM_CAMPAIGN`; the values are identical (tested).
  The hand-written `sql/02*.sql` files stay as the Phase 3-4 record and as the reference of the
  read-only parity checks. The dbt project, its tests and the parity proof: [dbt.md](dbt.md);
  the model lineage: [lineage.md](lineage.md).
- **Phase 6 (prepared 2026-10-14, done 2026-10-18):**
  - **Funnel mart.** dbt added one table, `MART_CONVERSION_FUNNEL` (channel × funnel stage, 25
    rows, the five funnel bases of `MART_CHANNEL_PERFORMANCE` as rows for the funnel chart; no
    stored ratio, decision 9). It was built with `make dbt-build-select
    DBT_SELECT=mart_conversion_funnel+`, not a full rebuild, and `make dbt-test` passed all 258
    data tests and 7 unit tests ([evidence](evidence/06_funnel_mart.txt)).
  - **Build spec and validation.** [dashboard_spec.md](dashboard_spec.md) specifies the four
    pages component by component, and [dashboard_validation.md](dashboard_validation.md) is
    the sign-off checklist. `sql/07_dashboard_validation.sql` computes every expected value
    from the same tables and ratio-of-sums fields as the report and checks it against
    independent references: 27 statements, 359 PASS rows, 0 FAIL
    ([evidence](evidence/07_dashboard_validation.txt)).
  - **Snapshot tooling (decision 8).** `make export-marts` and `make export-check` are written
    and have run: 8 tables in [exports/](../exports/README.md), equal to the live tables
    ([evidence](evidence/06_export_check.txt)). The Google steps are in
    [sheets_snapshot.md](sheets_snapshot.md).
  - **Report and snapshot.** The four-page report was built by hand on the live Snowflake
    connector and checked against `sql/07` (pass 1). A copy in a personal Google account (the
    university Workspace blocks public links) reads seven Google Sheets data sources built from
    the export of 2026-10-14; it was repaired, checked again (pass 2, every value matching) and
    made public. Sign-off and build logs: [dashboard_validation.md](dashboard_validation.md);
    screenshots: [dashboards/](../dashboards/).
- **Not built yet:** the final write-up (Phase 7).

## Data flow

```
 Analytics Engineering dataset v1.0.0 (CC BY 4.0, synthetic)
 ┌──────────────────────────────┐   ┌────────────────────────────────────┐
 │ clean release: 4 CSVs        │   │ cleaning-challenge: 4 dirty CSVs   │
 │ campaigns, daily_spend,      │   │ duplicates, blanks, casing/space,  │
 │ leads, conversions           │   │ slash dates                        │
 └──────────────┬───────────────┘   └─────────────────┬──────────────────┘
                └──────────────────┬──────────────────┘
                                   │  make data: pinned SHA-256, safe unzip (local)
                                   │  make load / load-challenge: local checks + totals
                                   ▼  PUT ─► stage ─► pre-check ─► COPY (CRM_LOADER)
 ┌───────────────────────────────────────────────────────────────────────────────────┐
 │ Snowflake  MARKETING_CRM                                    warehouse MARKETING_WH│
 │                                                             (X-Small, Gen1)       │
 │  RAW        all-VARCHAR, lossless, + _SOURCE_FILE/_SOURCE_ROW_NUMBER/_LOADED_AT   │
 │             CAMPAIGNS  DAILY_SPEND  LEADS  CONVERSIONS     CHALLENGE_* (x4)       │
 │                │  typed, trimmed, flagged, deduplicated      │ challenge track:   │
 │                ▼  (Phase 3 SQL; dbt Core in Phase 5)         ▼ the same rules     │
 │  STAGING    8 views 1:1 with RAW:                            STG_CHALLENGE_* (x4) │
 │             STG_CAMPAIGNS  STG_DAILY_SPEND                   + 2 provable *_FILLED│
 │             STG_LEADS  STG_CONVERSIONS                       reconciled vs STG_*: │
 │                │                                             6,118 of 6,120 rows  │
 │                ▼  aggregate each fact to a common grain FIRST, then join          │
 │  MART       core (Phase 3): DIM_DATE  DIM_CAMPAIGN  FCT_DAILY_SPEND               │
 │             FCT_LEAD_CONVERSIONS  MART_CAMPAIGN_PERFORMANCE                       │
 │             analysis marts (Phase 4): FCT_CAMPAIGN_DAILY_ACTIVITY (daily          │
 │             spine to END_DATE + 21)  MART_MONTHLY_MARKETING (activity)            │
 │             MART_MONTHLY_COHORT (lead cohort)  MART_CHANNEL_PERFORMANCE           │
 │             MART_LEAD_QUALITY                    (owner: CRM_TRANSFORMER)         │
 │             funnel chart (Phase 6): MART_CONVERSION_FUNNEL                        │
 └────────────────┬──────────────────────────────────────────────────────────────────┘
                  │  Snowflake connector, key pair, Owner's credentials (CRM_REPORTER)
                  ▼
 Google Data Studio report, four pages: Marketing Overview · Conversion Funnel ·
   Lead Quality & CRM · Marketing Efficiency & ROAS
   build phase:  live connector to MART
   public phase: frozen Google Sheets snapshot of the final MART tables + provenance note
                 (make export-marts -> exports/; steps: sheets_snapshot.md)
```

Since Phase 5, dbt (`make dbt-build`, project in `dbt/`) builds the STAGING views and MART tables
shown above, under the same names; the SQL build of Phases 3-4 created exactly the same objects
(decision 10). dbt also loads three small seed tables of independent expected values into
STAGING (`EXPECTED_CAMPAIGN_KPI`, `EXPECTED_TOTALS`, `PUBLISHER_CHANNEL_REFERENCE`); only tests
read them, and `CRM_REPORTER` cannot see STAGING. The same flow as a generated graph, model by
model: [lineage.md](lineage.md).

## Security model

The warehouse, database, schemas, custom roles and users are owned by system roles (SYSADMIN,
USERADMIN; ACCOUNTADMIN for the resource monitors). Objects *inside* the schemas are owned by the
project roles that create them: RAW tables, stage and file format by `CRM_LOADER`; STAGING and MART
tables and views by `CRM_TRANSFORMER`. Programmatic access uses key-pair service users with one
purpose each. The admin user (yours, with MFA) runs the bootstrap once; after that it is used only
for monitoring and break-glass tasks, never by the tooling.

| Role | Owned by | Can | Cannot |
|---|---|---|---|
| `CRM_LOADER` | USERADMIN (granted to SYSADMIN) | use MARKETING_WH; create tables, stage, file format in RAW; PUT/COPY/TRUNCATE its RAW tables | see STAGING or MART |
| `CRM_TRANSFORMER` | USERADMIN (granted to SYSADMIN) | read all current + future RAW tables; create tables/views in STAGING and MART | write RAW; create schemas |
| `CRM_REPORTER` | USERADMIN (granted to SYSADMIN) | read all current + future tables/views in MART | see RAW or STAGING |

| User | Type | Auth | Roles | Default role | Used by |
|---|---|---|---|---|---|
| `SVC_CRM_PIPELINE` | SERVICE | RSA key pair (`RSA_PUBLIC_KEY`); key unencrypted by default, optionally AES-256 | CRM_LOADER, CRM_TRANSFORMER | CRM_LOADER | `make sf-check`, `make load`; as CRM_TRANSFORMER: `make connection-test-table`, `make profile` / `profile-challenge`, `make analyses`, dbt (`make dbt-build`, `dbt-build-select`, `dbt-test`, `dbt-docs`), the read-only parity checks (`make dbt-parity`); the read-only dashboard validation `sql/07_dashboard_validation.sql` (Phase 6); the legacy SQL build `make staging` / `marts` / `analysis-marts` |
| `SVC_CRM_BI` | SERVICE | RSA key pair, **unencrypted** (connector requirement) | CRM_REPORTER | CRM_REPORTER | Google Data Studio connector; `make sf-check-bi`; `make export-marts` / `export-check` (Phase 6), so the export reads exactly what the connector reads |
| your admin user | PERSON | password + MFA (passkey/TOTP) | ACCOUNTADMIN | — | the one-time bootstrap, monitoring |

Both service users have `DEFAULT_SECONDARY_ROLES = ()`, so by default a session starts with only
the role it requests, and the project's SQL files and checks also run `USE SECONDARY ROLES NONE`.
This prevents accidental cross-role writes, but it is **not a security boundary**: whoever holds
`svc_crm_pipeline.p8` can run `USE SECONDARY ROLES ALL` or `USE ROLE CRM_TRANSFORMER` and use both
roles. Real separation would need separate loader and transformer users. Neither service user holds
an admin role (`make sf-check` fails if one does).

Trial accounts grant the provisioned `SNOWFLAKE_LEARNING_ROLE` to `PUBLIC` (seen on the first real
run, 2026-10-13), which would let both service users switch to it and use `SNOWFLAKE_LEARNING_WH`.
The bootstrap therefore grants that role directly to the admin and revokes it from `PUBLIC`
(`make sf-check-bi` fails while the BI user can still see it).

## Design decisions

"Decided" means agreed (or fixed for the phase named). "Written" means the code exists in this
repository; "run" means it has been executed in the Snowflake account (Phase 1 on 2026-10-13, Phases 3, 4, 5 and the Phase 6 preparation on 2026-10-14). "Proposed" means not yet agreed.

### 1. RAW is all VARCHAR, plus lineage columns (decided; written and run in Phase 1)

- **What.** Every business column lands as VARCHAR, in source column order, through a lossless file format:
  - `EMPTY_FIELD_AS_NULL = FALSE`, `NULL_IF = ()`
  - `ESCAPE_UNENCLOSED_FIELD = NONE`, `TRIM_SPACE = FALSE`
  - `REPLACE_INVALID_CHARACTERS = FALSE`
- **Why.**
  - A load can never fail on, or silently coerce, a value like `2023/05/15`, `' TRIAL '` or an empty string.
  - RAW stays a byte-faithful, replayable copy.
  - Typing and cleaning live in STAGING as versioned, tested SQL, which is where a reviewer looks for them.
- **Proof.** `make load` compares per-column empty counts, NULL counts and total character length, plus numeric sums, between the local file and Snowflake, exactly.
- **Lineage.** `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER` and `_LOADED_AT` (from the stage metadata) let every STAGING row point back to a file line. They also support dbt source freshness and deterministic de-duplication of the challenge extracts.
- **Cost.** Every column needs an explicit cast in STAGING. Storage overhead is negligible at this size.
- **Pre-check.** The loader's COPY uses a SELECT transform to add the lineage columns, and with a transform Snowflake ignores `ERROR_ON_COLUMN_COUNT_MISMATCH`. The loader therefore checks every staged record's field count before it truncates anything.

### 2. Key-pair `TYPE = SERVICE` users from day 1 (decided; written and run in Phase 1)

- **The alternative.** Trial accounts are exempt from Snowflake's single-factor-password deprecation, so a password user would work today.
- **Why not.**
  - The setup should not depend on that exemption. If the account is converted to paid, password sign-in for non-human users is blocked, and humans need MFA.
  - Service users cannot have passwords, so there is nothing to leak or rotate except a key file kept outside the repo.
  - dbt Core and the Python connector support key-pair natively.
- **Legacy key property.** Keys use the `RSA_PUBLIC_KEY` property rather than the newer named key pairs (July 2026). Named key pairs add `ROLE_RESTRICTION`, which only works if the client sends a role in its JWT, and no one documents whether the Data Studio connector does.

### 3. Gen1 warehouse with Query Acceleration off (decided; written and run in Phase 1)

- **What changed in 2026.** New standard warehouses default to Gen2 since the 2026_03 bundle, which bills a higher credit rate. Since the 2026_06 bundle (BCR-2373), QAS is on by default for all new standard warehouses, Gen1 included.
- **Why QAS matters.** QAS credits are serverless, and resource monitors do not cap them.
- **What the bootstrap sets.** `GENERATION = '1'`, and `ENABLE_QUERY_ACCELERATION = FALSE` inside an exception-handling block, because Standard edition has no QAS and the docs do not say whether setting it errors there.
- **Other settings.** X-Small, `AUTO_SUSPEND = 60` (billing has a 60-second minimum per resume, so lower saves nothing), initially suspended, 15-minute statement timeout.

### 4. Two resource monitors (decided; written and run in Phase 1)

- **`RM_MARKETING_WH`: 20 credits a month on the project warehouse.** Notify at 50% and 75%, suspend at 90%, suspend immediately at 100%.
- **`RM_ACCOUNT_DAILY`: 4 credits a day across the whole account** (2 until 2026-10-14; raised after it tripped during legitimate parallel work in Phase 5, when the project had used 2.19 credits on MARKETING_WH and $5 of the $400 balance). Notify at 75%, suspend at 100%. It also covers the trial's own `SNOWFLAKE_LEARNING_WH` / `COMPUTE_WH`, whose auto-suspend is set to 60 s as well.
- **Sizing, worst case.** `RM_MARKETING_WH` bounds the project warehouse to 20 credits a month (at most $100 at Snowflake University's "about $5 per credit"). `RM_ACCOUNT_DAILY` stops a runaway on any warehouse within a day; since MARKETING_WH is already capped monthly, the daily cap mainly guards the trial's own warehouses, which this project does not use. Serverless features and storage are outside both monitors. The expected use of this project is a few credits in total.
- **Idempotent.** The bootstrap creates each monitor only if it is missing and then alters it in place. `CREATE OR REPLACE` would start a fresh usage count, and dropping a monitor lets the warehouses it suspended resume, so a re-run of the bootstrap must not do either.
- **Limits.** Monitors reset at 00:00 UTC, count cloud-services credits, and only notify admins who opted in to notifications in Snowsight.

### 5. Cleaning-challenge extracts as a separate track (decided 2026-10-13; written and run in Phase 3)

- **Where they live.** The publisher's dirty extracts land in `RAW.CHALLENGE_*`: same all-VARCHAR DDL, own stage prefix `challenge/`. They are **never unioned with the clean release**: every challenge key also exists in the clean release, so a union double-counts.
- **What they contain.** 121 / 2,001 / 2,001 / 2,001 rows with 15 injected defects:
  - one exact duplicate per table;
  - casing/whitespace defects;
  - year-first slash dates;
  - four blank required values.
- **Built in Phase 3.** The `STAGING.STG_CHALLENGE_*` views (`STG_CHALLENGE_CAMPAIGNS`, `_DAILY_SPEND`, `_LEADS`, `_CONVERSIONS`; dbt models `stg_challenge_*` with the same names in Phase 5) apply the same cleaning rules as the clean `STG_*` views: inline SQL in `sql/02_data_cleaning.sql`, one shared macro in Phase 5. The two provable fills sit in separate columns, `CAMPAIGN_NAME_FILLED` and `SPEND_DATE_FILLED`.
- **Result** (`sql/02_data_cleaning_tests.sql` blocks 15-19, [evidence](evidence/02_data_cleaning_tests.txt)). 6,124 RAW rows become 6,120; all 15 defects are flagged. Compared with the clean staging views by key, 6,116 of 6,120 rows match with the blanks left NULL and 6,118 with the fills, as expected. The 2 residual cells are the blank dates that no evidence can recover (L00000030 `CREATED_DATE`, CV0000030 `CONVERTED_DATE`); both stay NULL, never a wrong value. Details: [data_cleaning.md](data_cleaning.md#challenge-track-results).
- **Scope.** MART and the dashboard stay on the clean release: `sql/02b_core_models.sql` reads only the clean `STG_*` views.

### 6. Grain rule: aggregate each fact to a common grain before joining (decided; written and run in the Phase 3 MART)

`daily_spend` is one row per campaign per day; `leads` is one row per lead. Joining them on
`campaign_id` multiplies every spend row by the campaign's lead count:

| Method | Rows | Total spend |
|---|---|---|
| `SUM(daily_spend.spend)` (correct) | 11,240 | 4,523,050.02 |
| naive `daily_spend JOIN leads ON campaign_id` | 25,941,510 | 11,286,380,144.15 (**2,495×**) |
| join on campaign_id and same date | 261,684 | 123,557,885.18 (27×) |

- **Rule.** Every MART fact aggregates spend, leads and conversions separately, to campaign or campaign × date, before the join. Ratios such as CTR, CPL and ROAS are ratios of sums, never averages of row-level ratios.
- **Where it is applied (Phase 3).** `MART_CAMPAIGN_PERFORMANCE` aggregates spend, leads and conversions to one row per campaign in separate CTEs, then joins them 1:1 to `DIM_CAMPAIGN`; the two facts take `CHANNEL` / `OBJECTIVE` from `DIM_CAMPAIGN` (n:1); `FCT_DAILY_SPEND` carries `BUDGET_PRORATED` instead of repeating the campaign budget on daily rows ([data_dictionary.md](data_dictionary.md#mart-core)).
- **Where it is applied (Phase 4).** Each analysis mart aggregates every input to its target grain in its own CTE and only then joins it 1:1 to a spine of dimension members (campaign × date, month × channel, channel × score band), never fact to fact ([data_dictionary.md](data_dictionary.md#mart-analysis-marts-phase-4)). `sql/02c_analysis_marts_tests.sql` checks that every one of them adds up to the same totals as the Phase 3 tables (spend 4,523,050.02, revenue 21,561,839.01, ...; [evidence](evidence/02c_analysis_marts_tests.txt), statement [10]).
- **Tests.** `sql/02b_core_models_tests.sql` (block 9) fails `make marts` (and so `make models`) if total spend in any MART table that carries spend differs from 4,523,050.02, and block 12 compares every campaign's bases with the Phase 2 baseline (the local pre-load KPI profile, 120 campaigns × 12 bases, carried inline in the test file). Phase 5 ported both to dbt singular tests that compare with seeds of independent expected values: `assert_total_spend_in_every_mart` and `assert_campaign_kpi_equals_independent_seed` ([dbt.md](dbt.md#tests)).

### 7. Activity-based and lead-cohort time series stay separate (decided; lead-cohort fact written and run in Phase 3, activity spine and monthly marts in Phase 4)

- **Why two bases are needed.** 34.45% of conversions (13,675 of 39,696) happen in a later calendar month than their lead (first found by local pre-load profiling; since Phase 4 printed by Snowflake SQL: [`02c_analysis_marts_tests.txt`](evidence/02c_analysis_marts_tests.txt) statement [16] and [`04_funnel.txt`](evidence/04_funnel.txt) statement [17]), and 4,716 happen after their campaign ended, up to 21 days later ([data_profile.md](data_profile.md#time); `02_data_cleaning_tests.txt` block 11).
- **What goes wrong if they are mixed.** "Conversions this month ÷ leads this month" swings from 8.3% to 93.8%, while the lead-cohort rate stays between 13.9% and 16.9% in every month (both computed from the 36 months in [`02b_core_models_tests.txt`](evidence/02b_core_models_tests.txt), block 17: 110 / 1,325 in 2023-01 and 61 / 65 in 2025-12; 513 / 3,680 in 2025-09 and 11 / 65 in 2025-12). Phase 4 prints both series side by side and checks their ranges: 0.083019 to 0.938462 vs 0.139402 to 0.169231 ([`04_funnel.txt`](evidence/04_funnel.txt), statements [16]-[17]).
- **The two time series.**
  - The **activity fact** (campaign × date, on a date spine running to `end_date + 21`) carries spend, leads by `created_at`, and conversions/revenue by `converted_at`. Built in Phase 4 as `FCT_CAMPAIGN_DAILY_ACTIVITY` (13,760 rows: 11,240 flight days + 120 × 21 post-flight days, which carry the 4,716 conversions after a campaign ended), on top of the Phase 3 delivery fact `FCT_DAILY_SPEND` (campaign × active day). Its monthly roll-up is `MART_MONTHLY_MARKETING` (channel × month).
  - The **lead-cohort fact** (one row per lead) carries conversion flags, lag and revenue by the lead's cohort month. Built in Phase 3 as `FCT_LEAD_CONVERSIONS`, with `CREATED_MONTH` (cohort) and `CONVERTED_MONTH` (activity) as separate columns. Its monthly roll-up is `MART_MONTHLY_COHORT` (channel × cohort month), built in Phase 4.
- **In the dashboard.** The two get separate data sources with clearly labelled date dimensions; they are never blended on one date field.

### 8. Dashboard durability plan (decided 2026-10-13; export tooling written and run in Phase 6, 2026-10-14; the Google steps not done yet)

- **The problem.** A Snowflake trial ends after its trial period or when the $400 is spent. A suspended account can be logged into but cannot run queries, so live Data Studio charts fail once their cache expires.
- **Deadline.** The trial was created on 2026-10-13 and ends about **2026-11-12** (30 days; confirm the date in Snowsight). The snapshot is due by about **2026-11-07**, leaving a few days of margin, so Phase 6 must be finished by then (Phases 1-5 are done). Phase 7 (documentation) can follow.
- **During Phases 1-6.** The report uses the live Snowflake connector (`SVC_CRM_BI`, Owner's credentials, long freshness interval).
- **Reusable data sources only.** Every data source, live Snowflake and later Google Sheets, is created from the Data Studio home page (Create » Data source), which makes it reusable. Sources created inside a report are embedded, and Google states that embedded sources are accessible to anyone with the report link. Before any link is shared, Resource » Manage added data sources must show no embedded source.
- **Before the trial ends.**
  - Export each final MART table (all small and pre-aggregated, with UPPERCASE ASCII columns) to a Google Sheet in the owner's My Drive. Each Sheet carries the attribution below in a note or header cell outside the data range.
  - Swap each chart's data source to its Sheet and re-check every number against Snowflake.
  - Add a provenance note: *KPIs computed in Snowflake SQL (MARKETING_CRM.MART); this public version serves a frozen export from <date> via Google Sheets because the Snowflake trial ended; SQL in the repository.*
- **Attribution (CC BY 4.0).** Every public report page has a header or footer text box (the dashboard uses a report-level header line, [dashboard_spec.md](dashboard_spec.md) section 1.3), and every Sheet a note: *Data: Analytics Engineering, "Marketing Campaigns & Conversions Dataset v1.0.0" (https://www.analyticsengineering.com/datasets/marketing-campaigns), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Typed, cleaned and aggregated by Hoedong Kim; not endorsed by the publisher.* CC BY 4.0 requires attribution, a license link and an indication that the material was modified for every shared adaptation, including the Phase 1 test report.
- **Why Sheets.** Extract Data sources are not relied on: Google does not document their behaviour when the upstream fails. The BigQuery sandbox expires tables after 60 days.
- **The export tooling (written and run in Phase 6).** `make export-marts` reads the 7 tables the report uses, plus `DIM_CAMPAIGN`, as `SVC_CRM_BI` / `CRM_REPORTER`, the connector's identity, and writes [exports/](../exports/README.md): one CSV per table, `marketing_crm_dashboard_snapshot.xlsx` (one typed sheet per table, the attribution as a note on cell A1, a `README` sheet with provenance and caveats) and `manifest.json` (rows, columns and types, SHA-256, query IDs, `HASH_AGG`, column sums). The rows fetched must equal a second aggregate query, and the files replace the previous export only after they pass the offline checks. `make export-check` compares the files with the manifest and, while Snowflake is up, the live tables with the manifest; `EXPORT_CHECK_ARGS=--offline` still checks the files after the trial. First run 2026-10-14: 8 tables, 14,440 rows, every check PASS ([export](evidence/06_export_marts.txt), [check](evidence/06_export_check.txt)). The Google steps (upload, convert, re-point the report, re-check every number, provenance note) are the runbook [sheets_snapshot.md](sheets_snapshot.md) and spec section 9; none of them has been done yet.
- **Rehearsal.** Planned on one chart in the Phase 1 connection test (section F). It was deferred to Phase 6 with sections D-E and has not been run; the full swap of [sheets_snapshot.md](sheets_snapshot.md) covers it (results row 13).

### 9. Conventions (decided)

- **Measurement.** The dataset is synthetic and attribution is last-touch. ROAS and revenue by channel describe attributed revenue, not causal impact.
- **Date ranges.** Dashboards use a fixed date range (2023-01-01 to 2025-12-31), because relative ranges are empty for this data.
- **KPI logic.** It lives in Snowflake SQL / dbt models, not in Data Studio calculated fields, which do not survive a data-source swap.
- **Ratios in the dashboard.** Data Studio re-aggregates whatever a chart shows, for example a scorecard over a date range or a channel filter on a monthly table. A pre-computed ratio column would then be summed or averaged, which is wrong. So:
  - MART ships the **additive numerator and denominator** columns (spend, impressions, clicks, leads, conversions, revenue) next to any ratio. Budget is additive across campaigns but not across dates, so budget utilisation is computed only from tables that hold whole campaigns over the full range (`MART_CAMPAIGN_PERFORMANCE`, `MART_CHANNEL_PERFORMANCE`).
  - The only calculated fields allowed in Data Studio are thin ratios of sums such as `SUM(CLICKS) / SUM(IMPRESSIONS)` or `SUM(REVENUE) / SUM(SPEND)`. Each one is listed in [kpi_definitions.md](kpi_definitions.md#quick-reference-the-data-studio-fields) so it can be recreated exactly after the Sheets swap. The campaign-grain KPI columns of `MART_CAMPAIGN_PERFORMANCE`, with numerator, denominator and the ratio-of-sums form of each, are defined in [data_dictionary.md](data_dictionary.md#kpi-definitions-mart_campaign_performance).
  - Pre-computed ratio columns are used only in charts at exactly the table's grain (for example a campaign ranking table on `MART_CAMPAIGN_PERFORMANCE`, or a channel table on `MART_CHANNEL_PERFORMANCE`, the only Phase 4 mart that stores ratios).
  - The Phase 6 funnel table `MART_CONVERSION_FUNNEL` follows the same rule. It stores no ratio. Next to each stage's `STAGE_VALUE` it carries the previous stage's value and the channel's impressions (`PREV_STAGE_VALUE`, `TOP_OF_FUNNEL_VALUE`), both additive across channels, so the stage conversion and the share of the top of the funnel are thin ratios of sums that stay correct under a channel filter ([kpi_definitions.md](kpi_definitions.md#funnel-stages-and-stage-conversion)).

### 10. dbt replaces the SQL build in place, with one target (decided and built in Phase 5)

- **Same names, same schemas.** dbt builds `STAGING.STG_*` (views) and `MART.*` (permanent tables) under
  the names of the Phase 3-4 SQL build. `dbt/macros/generate_schema_name.sql` uses a model's schema
  as is (no `<target>_` prefix), so the consumers keep their names: the analyses in `sql/03-06`
  pass unchanged on the dbt build, and the Phase 6 Data Studio sources are built on the same
  tables. The intermediate model is ephemeral and creates no object; the seeds of independent
  expected values land in `STAGING` and only tests read them.
- **The cost: no development copy.** There is one target, named `prod` in `dbt/profiles.yml`
  because that is what it is. Every dbt run replaces the objects Data Studio reads. dbt stops the
  nodes downstream of a failure, but the upstream nodes are already rebuilt, so a failed run can
  leave new upstream tables next to the previous downstream ones until the next green run.
  Isolation would need a second database or per-developer schemas plus a `target.name != 'prod'`
  branch in the macro; CRM_TRANSFORMER cannot create schemas, so that needs an admin change first.
  Until then, `--select` limits a run to the changed nodes and their descendants.
- **The SQL build is the record, not a second writer.** `sql/02*.sql` stay as the hand-written
  Phase 3-4 build. `make staging` / `marts` / `analysis-marts` / `models` are labelled legacy:
  they would replace the dbt-built objects. The parity proof does not need them:
  `make parity-check` rebuilds each hand-written object from RAW inside one query and compares it
  with the deployed object (COUNT, MINUS both ways, HASH_AGG), creating nothing, and
  `make sql-checks` re-runs the read-only Phase 3-4 check files on whatever is deployed;
  `make dbt-parity` runs both, after a fresh fingerprint snapshot. Details and results:
  [dbt.md](dbt.md#parity-with-the-hand-written-sql-build).
