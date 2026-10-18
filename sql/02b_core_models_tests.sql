-- =============================================================================
-- Phase 3 / 02b tests: read-only tests of the core MART models
-- -----------------------------------------------------------------------------
-- Purpose
--   Prove that the five core MART tables built by 02b_core_models.sql are correct at their
--   grain and never double count:
--     blocks 0-6    contract (names, order, types, comments), STAGING inputs, row counts, keys,
--                   NOT NULL, relationships (NOT EXISTS)
--     blocks 7-8    DIM_DATE: a gap-free calendar with the right attributes
--     blocks 9-11   control totals in every table (the no-fan-out proof), the lead-cohort
--                   semantics of FCT_LEAD_CONVERSIONS, lead score segments
--     blocks 12-16  MART_CAMPAIGN_PERFORMANCE: every campaign and every base equals the Phase 2
--                   baseline, the channel roll-up equals the publisher reference, ratios are
--                   ratios of sums, ratio sanity, the ROAS ranking
--     block 17      activity months vs lead-cohort months, all 36 months
--   These are the Phase 5 dbt tests written as SQL: unique, not_null, relationships,
--   accepted values, expression tests, and equality tests against the Phase 2 baseline (which
--   Phase 5 can load as a dbt seed).
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02b_core_models.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02b_core_models_tests.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 22
--   statements, under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02b_core_models_tests.txt.
-- Role
--   CRM_TRANSFORMER, which owns the MART tables and can read the STAGING views.
-- Reading the results
--   STATUS = PASS means the table reproduced the expected value exactly. The one tolerance is
--   the contract's sum-back rule for BUDGET_PRORATED, "within 0.01 per campaign" (block 9
--   check 11); the stored 6-dp value itself is checked exactly, row by row (block 12), and its
--   table total exactly (block 9 check 10).
--   No vacuous passes:
--     - Every block that compares groups with an expected list (tables, columns, campaigns,
--       channels, segments, months, sample dates, ranks) uses a FULL OUTER JOIN, so a missing
--       or an unexpected group is its own FAIL row. Block 12 counts the campaigns that match
--       after a FULL OUTER JOIN of all sources, so a campaign missing anywhere fails every
--       check of that block.
--     - Zero counts sit next to the number of rows they were evaluated on, or the same block
--       checks that number (blocks 4, 5, 10, 15). The zero counts of block 6 carry no row
--       count of their own; an empty table would pass them, but it fails block 3 in the same
--       run. So the suite as a whole cannot pass on an empty or NULL-filled table.
--     - No check compares a model with itself. Expected values come from the sources below,
--       never from the table under test. Block 12 checks each ratio column and
--       BUDGET_PRORATED against values divided and rounded in Python [D], not by Snowflake, so
--       a rounding path shared with the model cannot hide an error.
--   (Totals of mixed measures share one NUMBER column, so counts print as e.g. 16691.000000.)
-- Where the expected values come from (never from the object under test)
--   [C]    The Phase 3 MART core contract: table and column names, order and types, grain,
--          KPI formulas, the 0/1 flags, AS_OF_DATE 2025-12-31 and the 21-day maturity window,
--          as specified for Phase 3 and written in the header of 02b_core_models.sql.
--   [E01]  docs/evidence/01_data_profiling.txt, the Phase 2 profile of clean RAW in Snowflake
--          (statement number in brackets).
--   [P1]   The local profile "table integrity" (2026-10-13, DuckDB + Python): sum of
--          lead_score 13,233,637.
--   [P3]   The local profile "KPI reconciliation" (2026-10-13), computed twice from the CSV
--          files (DuckDB, and Python csv + Decimal; 1,650 values, 0 mismatches), before any
--          Snowflake object existed. Sections used: kpi_channel_bases, kpi_channel_ratios,
--          campaign_kpi_full (= expected_campaign_kpi.csv, 120 campaigns x 12 bases),
--          lead_score_segments, monthly_activity_vs_cohort (36 months), campaign_top10_roas /
--          campaign_bottom10_roas, flag_budget, flag_leads_gt_clicks_campaign,
--          campaign_min_conversions, campaign_roas_lt1. Ratios there are rounded once, half
--          away from zero, rates and ROAS to 6 dp and currency to 4 dp. The MART columns follow
--          the same convention: the model casts every dividend to NUMBER(32,18), so ROUND is
--          the only rounding (02b_core_models.sql header, "Rounding"). The test expressions
--          that divide in Snowflake (blocks 9 and 14) use the same cast, so they are not
--          rounded twice either; they are compared with [P3] values computed outside Snowflake.
--   [D]    Python 3 csv + decimal (ROUND_HALF_UP, 60-digit precision), 2026-10-14, outside
--          Snowflake: the 9 ratio columns of each of the 120 campaigns from the [P3] bases in
--          expected_campaign_kpi.csv, and BUDGET_PRORATED = budget / window days (end_date -
--          start_date + 1) from data/raw/source/campaigns.csv, each rounded once to the stored
--          scale (CMP0050: 37,882.58 / 127 = 298.28803149... -> 298.288031). Table total of
--          BUDGET_PRORATED = SUM(share x window days) = 5,418,642.159820.
--   [PUB]  The publisher's reference output (spend and attributed revenue by channel),
--          reproduced to the cent in [P3] and in [E01 31].
--   [CAL]  Calendar facts computed with Python's datetime module (2026-10-14), independently of
--          Snowflake: 2023-01-01..2025-12-31 has 1,096 days (365 / 366 / 365), 313 weekend days,
--          36 months and 158 ISO weeks (Monday starts); the attributes of six sample dates.
--   [S1]   sql/setup/03_connection_test.sql (Phase 1): CONNECTION_TEST has 159 rows and spend
--          4,523,050.02.
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where   [6] 1 contract   [7] 2 STAGING inputs   [8] 3 row counts
--   [9] 4 keys   [10] 5 not null   [11] 6 relationships   [12] 7 DIM_DATE calendar
--   [13] 8 DIM_DATE sample dates   [14] 9 control totals   [15] 10 lead-cohort semantics
--   [16] 11 lead score segments   [17] 12 campaigns vs the Phase 2 baseline
--   [18] 13 channel roll-up (bases)   [19] 14 channel roll-up (ratios of sums)
--   [20] 15 ratio sanity   [21] 16 ROAS ranking   [22] 17 activity vs cohort months
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.MART;


-- -----------------------------------------------------------------------------
-- 0. Who ran this, where and when. Expect role CRM_TRANSFORMER with no secondary roles on
--    MARKETING_WH, schema MARKETING_CRM.MART.
-- -----------------------------------------------------------------------------
SELECT CURRENT_USER() AS USER_NAME, CURRENT_ROLE() AS ROLE_NAME, CURRENT_SECONDARY_ROLES() AS SECONDARY_ROLES,
       CURRENT_WAREHOUSE() AS WAREHOUSE_NAME, CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() AS SCHEMA_NAME,
       TO_VARCHAR(SYSDATE(), 'YYYY-MM-DD HH24:MI') || ' UTC' AS RUN_AT,
       IFF(CURRENT_ROLE() = 'CRM_TRANSFORMER' AND CURRENT_WAREHOUSE() = 'MARKETING_WH'
           AND CURRENT_DATABASE() = 'MARKETING_CRM' AND CURRENT_SCHEMA() = 'MART'
           AND PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles::STRING = '', 'PASS', 'FAIL') AS STATUS;


-- -----------------------------------------------------------------------------
-- 1. Contract: MART holds exactly the five core tables (plus the Phase 1 CONNECTION_TEST, the
--    five Phase 4 analysis marts and, since Phase 6, MART_CONVERSION_FUNNEL), the core tables
--    each with the contract columns, in contract order, with contract types and comments
--    Question: can Data Studio, the Phase 4 marts and the dbt port (Phase 5) rely on these
--      names and types?
--    Why: Data Studio binds fields by column name, and a Sheets snapshot keeps the names. A
--      renamed column, a FLOAT where NUMBER(18,2) was promised, a lower-case or non-ASCII
--      name, or a column without its KPI comment would break or blur the dashboard. Any other
--      object in MART appears as its own FAIL row. CONNECTION_TEST must still exist (Phase 6
--      drops it); its columns are not part of this contract.
--    Expected [C]: 9 / 10 / 10 / 21 / 28 columns, 0 problems, a table comment on each table.
-- -----------------------------------------------------------------------------
WITH contract (TABLE_NAME, ORDINAL, COLUMN_NAME, DATA_TYPE) AS (   -- [C]
  SELECT * FROM VALUES
    ('DIM_DATE', 1, 'DATE_DAY', 'DATE'),                  ('DIM_DATE', 2, 'YEAR', 'NUMBER(4,0)'),
    ('DIM_DATE', 3, 'QUARTER', 'NUMBER(1,0)'),            ('DIM_DATE', 4, 'MONTH_START', 'DATE'),
    ('DIM_DATE', 5, 'MONTH_NAME', 'TEXT'),                ('DIM_DATE', 6, 'WEEK_START', 'DATE'),
    ('DIM_DATE', 7, 'DAY_OF_WEEK_ISO', 'NUMBER(1,0)'),    ('DIM_DATE', 8, 'DAY_NAME', 'TEXT'),
    ('DIM_DATE', 9, 'IS_WEEKEND', 'BOOLEAN'),
    ('DIM_CAMPAIGN', 1, 'CAMPAIGN_ID', 'TEXT'),           ('DIM_CAMPAIGN', 2, 'CAMPAIGN_NAME', 'TEXT'),
    ('DIM_CAMPAIGN', 3, 'CHANNEL', 'TEXT'),               ('DIM_CAMPAIGN', 4, 'OBJECTIVE', 'TEXT'),
    ('DIM_CAMPAIGN', 5, 'START_DATE', 'DATE'),            ('DIM_CAMPAIGN', 6, 'END_DATE', 'DATE'),
    ('DIM_CAMPAIGN', 7, 'CAMPAIGN_DAYS', 'NUMBER(38,0)'), ('DIM_CAMPAIGN', 8, 'BUDGET', 'NUMBER(12,2)'),
    ('DIM_CAMPAIGN', 9, 'START_YEAR', 'NUMBER(4,0)'),     ('DIM_CAMPAIGN', 10, 'START_MONTH', 'DATE'),
    ('FCT_DAILY_SPEND', 1, 'SPEND_ID', 'TEXT'),           ('FCT_DAILY_SPEND', 2, 'CAMPAIGN_ID', 'TEXT'),
    ('FCT_DAILY_SPEND', 3, 'SPEND_DATE', 'DATE'),         ('FCT_DAILY_SPEND', 4, 'SPEND_MONTH', 'DATE'),
    ('FCT_DAILY_SPEND', 5, 'CHANNEL', 'TEXT'),            ('FCT_DAILY_SPEND', 6, 'OBJECTIVE', 'TEXT'),
    ('FCT_DAILY_SPEND', 7, 'IMPRESSIONS', 'NUMBER(38,0)'), ('FCT_DAILY_SPEND', 8, 'CLICKS', 'NUMBER(38,0)'),
    ('FCT_DAILY_SPEND', 9, 'SPEND', 'NUMBER(12,2)'),      ('FCT_DAILY_SPEND', 10, 'BUDGET_PRORATED', 'NUMBER(18,6)'),
    ('FCT_LEAD_CONVERSIONS', 1, 'LEAD_ID', 'TEXT'),       ('FCT_LEAD_CONVERSIONS', 2, 'CAMPAIGN_ID', 'TEXT'),
    ('FCT_LEAD_CONVERSIONS', 3, 'CHANNEL', 'TEXT'),       ('FCT_LEAD_CONVERSIONS', 4, 'OBJECTIVE', 'TEXT'),
    ('FCT_LEAD_CONVERSIONS', 5, 'CREATED_DATE', 'DATE'),  ('FCT_LEAD_CONVERSIONS', 6, 'CREATED_MONTH', 'DATE'),
    ('FCT_LEAD_CONVERSIONS', 7, 'LEAD_SOURCE', 'TEXT'),   ('FCT_LEAD_CONVERSIONS', 8, 'LEAD_SCORE', 'NUMBER(3,0)'),
    ('FCT_LEAD_CONVERSIONS', 9, 'LEAD_SCORE_SEGMENT', 'TEXT'),
    ('FCT_LEAD_CONVERSIONS', 10, 'CONVERSION_ID', 'TEXT'), ('FCT_LEAD_CONVERSIONS', 11, 'CONVERTED_DATE', 'DATE'),
    ('FCT_LEAD_CONVERSIONS', 12, 'CONVERTED_MONTH', 'DATE'), ('FCT_LEAD_CONVERSIONS', 13, 'CONVERSION_TYPE', 'TEXT'),
    ('FCT_LEAD_CONVERSIONS', 14, 'IS_CONVERTED', 'NUMBER(1,0)'), ('FCT_LEAD_CONVERSIONS', 15, 'IS_TRIAL', 'NUMBER(1,0)'),
    ('FCT_LEAD_CONVERSIONS', 16, 'IS_PURCHASE', 'NUMBER(1,0)'), ('FCT_LEAD_CONVERSIONS', 17, 'REVENUE', 'NUMBER(12,2)'),
    ('FCT_LEAD_CONVERSIONS', 18, 'DAYS_TO_CONVERT', 'NUMBER(38,0)'),
    ('FCT_LEAD_CONVERSIONS', 19, 'CONVERTED_AFTER_CAMPAIGN_END', 'NUMBER(1,0)'),
    ('FCT_LEAD_CONVERSIONS', 20, 'AS_OF_DATE', 'DATE'),   ('FCT_LEAD_CONVERSIONS', 21, 'IS_MATURE', 'NUMBER(1,0)'),
    ('MART_CAMPAIGN_PERFORMANCE', 1, 'CAMPAIGN_ID', 'TEXT'),       ('MART_CAMPAIGN_PERFORMANCE', 2, 'CAMPAIGN_NAME', 'TEXT'),
    ('MART_CAMPAIGN_PERFORMANCE', 3, 'CHANNEL', 'TEXT'),           ('MART_CAMPAIGN_PERFORMANCE', 4, 'OBJECTIVE', 'TEXT'),
    ('MART_CAMPAIGN_PERFORMANCE', 5, 'START_DATE', 'DATE'),        ('MART_CAMPAIGN_PERFORMANCE', 6, 'END_DATE', 'DATE'),
    ('MART_CAMPAIGN_PERFORMANCE', 7, 'CAMPAIGN_DAYS', 'NUMBER(38,0)'), ('MART_CAMPAIGN_PERFORMANCE', 8, 'START_YEAR', 'NUMBER(4,0)'),
    ('MART_CAMPAIGN_PERFORMANCE', 9, 'START_MONTH', 'DATE'),       ('MART_CAMPAIGN_PERFORMANCE', 10, 'BUDGET', 'NUMBER(12,2)'),
    ('MART_CAMPAIGN_PERFORMANCE', 11, 'SPEND_DAYS', 'NUMBER(38,0)'), ('MART_CAMPAIGN_PERFORMANCE', 12, 'IMPRESSIONS', 'NUMBER(38,0)'),
    ('MART_CAMPAIGN_PERFORMANCE', 13, 'CLICKS', 'NUMBER(38,0)'),   ('MART_CAMPAIGN_PERFORMANCE', 14, 'SPEND', 'NUMBER(18,2)'),
    ('MART_CAMPAIGN_PERFORMANCE', 15, 'LEADS', 'NUMBER(38,0)'),    ('MART_CAMPAIGN_PERFORMANCE', 16, 'CONVERTED_LEADS', 'NUMBER(38,0)'),
    ('MART_CAMPAIGN_PERFORMANCE', 17, 'TRIALS', 'NUMBER(38,0)'),   ('MART_CAMPAIGN_PERFORMANCE', 18, 'PURCHASES', 'NUMBER(38,0)'),
    ('MART_CAMPAIGN_PERFORMANCE', 19, 'REVENUE', 'NUMBER(18,2)'),  ('MART_CAMPAIGN_PERFORMANCE', 20, 'CTR', 'NUMBER(18,6)'),
    ('MART_CAMPAIGN_PERFORMANCE', 21, 'CLICK_TO_LEAD_RATE', 'NUMBER(18,6)'),
    ('MART_CAMPAIGN_PERFORMANCE', 22, 'LEAD_CONVERSION_RATE', 'NUMBER(18,6)'),
    ('MART_CAMPAIGN_PERFORMANCE', 23, 'PURCHASE_RATE', 'NUMBER(18,6)'),
    ('MART_CAMPAIGN_PERFORMANCE', 24, 'COST_PER_LEAD', 'NUMBER(18,4)'),
    ('MART_CAMPAIGN_PERFORMANCE', 25, 'COST_PER_CONVERSION', 'NUMBER(18,4)'),
    ('MART_CAMPAIGN_PERFORMANCE', 26, 'COST_PER_PURCHASE', 'NUMBER(18,4)'),
    ('MART_CAMPAIGN_PERFORMANCE', 27, 'ROAS', 'NUMBER(18,6)'),
    ('MART_CAMPAIGN_PERFORMANCE', 28, 'BUDGET_UTILIZATION', 'NUMBER(18,6)')
),
expected_objects (TABLE_NAME, HAS_CONTRACT) AS (   -- [C]; CONNECTION_TEST is kept until Phase 6
  -- The five Phase 4 analysis marts (sql/02c_analysis_marts.sql) are expected objects too, but
  -- their column contract is tested in sql/02c_analysis_marts_tests.sql, so HAS_CONTRACT = FALSE.
  -- MART_CONVERSION_FUNNEL (Phase 6, built by dbt only, no SQL twin) likewise: its columns and
  -- values are tested by dbt (models/marts/_marts.yml, tests/marts/assert_conversion_funnel_reconciles.sql).
  SELECT * FROM VALUES ('DIM_DATE', TRUE), ('DIM_CAMPAIGN', TRUE), ('FCT_DAILY_SPEND', TRUE),
                       ('FCT_LEAD_CONVERSIONS', TRUE), ('MART_CAMPAIGN_PERFORMANCE', TRUE), ('CONNECTION_TEST', FALSE),
                       ('FCT_CAMPAIGN_DAILY_ACTIVITY', FALSE), ('MART_MONTHLY_MARKETING', FALSE),
                       ('MART_MONTHLY_COHORT', FALSE), ('MART_CHANNEL_PERFORMANCE', FALSE), ('MART_LEAD_QUALITY', FALSE),
                       ('MART_CONVERSION_FUNNEL', FALSE)
),
objects AS (
  SELECT TABLE_NAME, TABLE_TYPE, COMMENT FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'MART'
),
actual AS (
  SELECT TABLE_NAME, ORDINAL_POSITION AS ORDINAL, COLUMN_NAME, COMMENT,
         IFF(DATA_TYPE = 'NUMBER', 'NUMBER(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')', DATA_TYPE) AS DATA_TYPE
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'MART'
    AND TABLE_NAME IN (SELECT TABLE_NAME FROM expected_objects WHERE HAS_CONTRACT)  -- column contract: Phase 3 tables only
),
compared AS (
  SELECT COALESCE(k.TABLE_NAME, a.TABLE_NAME) AS TABLE_NAME, k.ORDINAL AS CONTRACT_ORDINAL, a.ORDINAL AS ACTUAL_ORDINAL,
         CASE WHEN a.COLUMN_NAME IS NULL                           THEN 'missing ' || k.COLUMN_NAME
              WHEN k.COLUMN_NAME IS NULL                           THEN 'unexpected ' || a.COLUMN_NAME
              WHEN a.ORDINAL <> k.ORDINAL                          THEN k.COLUMN_NAME || ' at position ' || a.ORDINAL
              WHEN a.DATA_TYPE <> k.DATA_TYPE                      THEN k.COLUMN_NAME || ' is ' || a.DATA_TYPE
              WHEN NOT REGEXP_LIKE(a.COLUMN_NAME, '^[A-Z][A-Z0-9_]*$') THEN a.COLUMN_NAME || ' is not UPPERCASE ASCII'
              WHEN NULLIF(TRIM(a.COMMENT), '') IS NULL             THEN a.COLUMN_NAME || ' has no comment'
         END AS PROBLEM
  FROM contract k
  FULL OUTER JOIN actual a ON a.TABLE_NAME = k.TABLE_NAME AND a.COLUMN_NAME = k.COLUMN_NAME
),
per_table AS (
  SELECT TABLE_NAME, COUNT(CONTRACT_ORDINAL) AS CONTRACT_COLUMNS, COUNT(ACTUAL_ORDINAL) AS ACTUAL_COLUMNS,
         COUNT(PROBLEM) AS PROBLEMS, COALESCE(LISTAGG(PROBLEM, '; ') WITHIN GROUP (ORDER BY PROBLEM), '') AS PROBLEM_LIST
  FROM compared
  GROUP BY TABLE_NAME
)
SELECT COALESCE(e.TABLE_NAME, o.TABLE_NAME, p.TABLE_NAME) AS TABLE_NAME, o.TABLE_TYPE,
       COALESCE(p.CONTRACT_COLUMNS, 0) AS CONTRACT_COLUMNS, COALESCE(p.ACTUAL_COLUMNS, 0) AS ACTUAL_COLUMNS,
       COALESCE(p.PROBLEMS, 0) AS PROBLEMS, COALESCE(p.PROBLEM_LIST, '') AS PROBLEM_LIST,
       NULLIF(TRIM(o.COMMENT), '') IS NOT NULL AS HAS_TABLE_COMMENT,
       IFF(e.TABLE_NAME IS NOT NULL AND o.TABLE_TYPE = 'BASE TABLE' AND NULLIF(TRIM(o.COMMENT), '') IS NOT NULL
           AND (NOT e.HAS_CONTRACT OR (p.CONTRACT_COLUMNS > 0 AND p.PROBLEMS = 0)), 'PASS', 'FAIL') AS STATUS
FROM expected_objects e
FULL OUTER JOIN objects   o ON o.TABLE_NAME = e.TABLE_NAME
FULL OUTER JOIN per_table p ON p.TABLE_NAME = COALESCE(e.TABLE_NAME, o.TABLE_NAME)
ORDER BY DECODE(COALESCE(e.TABLE_NAME, o.TABLE_NAME, p.TABLE_NAME), 'DIM_DATE', 1, 'DIM_CAMPAIGN', 2, 'FCT_DAILY_SPEND', 3,
                'FCT_LEAD_CONVERSIONS', 4, 'MART_CAMPAIGN_PERFORMANCE', 5, 'CONNECTION_TEST', 6, 7), 1;


-- -----------------------------------------------------------------------------
-- 2. STAGING inputs: MART was built from complete, unflagged rows
--    Question: are the four clean STAGING views complete, with no row flagged by DQ_ISSUES?
--    Why: MART deliberately does not filter on DQ_IS_VALID (a dropped spend row would
--      silently break the totals). This precondition makes a flagged input fail here, next
--      to the MART tests, instead of flowing into the dashboard unnoticed. It repeats
--      02_data_cleaning_tests.sql blocks 3-4 on purpose, as the MART-side guard.
--    Expected: 120 / 11,240 / 261,684 / 39,696 rows [E01 5], 0 rows not DQ_IS_VALID.
-- -----------------------------------------------------------------------------
SELECT VIEW_NAME, N_ROWS, EXPECTED_ROWS, NOT_VALID_ROWS, 0 AS EXPECTED_NOT_VALID,
       IFF(N_ROWS = EXPECTED_ROWS AND NOT_VALID_ROWS = 0, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'STAGING.STG_CAMPAIGNS' AS VIEW_NAME, COUNT(*) AS N_ROWS, 120 AS EXPECTED_ROWS,
                   COUNT_IF(DQ_IS_VALID IS DISTINCT FROM TRUE) AS NOT_VALID_ROWS
            FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS
  UNION ALL SELECT 2, 'STAGING.STG_DAILY_SPEND', COUNT(*), 11240, COUNT_IF(DQ_IS_VALID IS DISTINCT FROM TRUE)
            FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND
  UNION ALL SELECT 3, 'STAGING.STG_LEADS', COUNT(*), 261684, COUNT_IF(DQ_IS_VALID IS DISTINCT FROM TRUE)
            FROM MARKETING_CRM.STAGING.STG_LEADS
  UNION ALL SELECT 4, 'STAGING.STG_CONVERSIONS', COUNT(*), 39696, COUNT_IF(DQ_IS_VALID IS DISTINCT FROM TRUE)
            FROM MARKETING_CRM.STAGING.STG_CONVERSIONS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 3. Row counts: each table has exactly the rows of its grain
--    Question: did a join add rows (fan-out) or drop rows (an INNER JOIN on a missing key)?
--    Why: each fact keeps the grain of its STAGING source: one row per spend row, one row per
--      lead. A fact with more rows than its source has fanned out; with fewer, it lost rows.
--      The campaign tables have one row per campaign. CONNECTION_TEST must be untouched.
--    Expected: 1,096 [CAL] / 120 / 11,240 / 261,684 / 120 [C; E01 5]; CONNECTION_TEST 159 [S1];
--      each fact's row count also equals its source's.
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, GRAIN, ROW_COUNT, SOURCE_NAME, SOURCE_ROWS, EXPECTED,
       IFF(ROW_COUNT = EXPECTED AND (SOURCE_ROWS IS NULL OR SOURCE_ROWS = EXPECTED), 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'DIM_DATE' AS TABLE_NAME, 'one row per calendar day' AS GRAIN,
                   (SELECT COUNT(*) FROM DIM_DATE) AS ROW_COUNT, '(date spine)' AS SOURCE_NAME, NULL AS SOURCE_ROWS,
                   1096 AS EXPECTED
  UNION ALL SELECT 2, 'DIM_CAMPAIGN', 'one row per campaign', (SELECT COUNT(*) FROM DIM_CAMPAIGN),
                   'STG_CAMPAIGNS', (SELECT COUNT(*) FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS), 120
  UNION ALL SELECT 3, 'FCT_DAILY_SPEND', 'one row per campaign x active day', (SELECT COUNT(*) FROM FCT_DAILY_SPEND),
                   'STG_DAILY_SPEND', (SELECT COUNT(*) FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND), 11240
  UNION ALL SELECT 4, 'FCT_LEAD_CONVERSIONS', 'one row per lead', (SELECT COUNT(*) FROM FCT_LEAD_CONVERSIONS),
                   'STG_LEADS', (SELECT COUNT(*) FROM MARKETING_CRM.STAGING.STG_LEADS), 261684
  UNION ALL SELECT 5, 'MART_CAMPAIGN_PERFORMANCE', 'one row per campaign', (SELECT COUNT(*) FROM MART_CAMPAIGN_PERFORMANCE),
                   'STG_CAMPAIGNS', (SELECT COUNT(*) FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS), 120
  UNION ALL SELECT 6, 'CONNECTION_TEST', 'Phase 1 test table, untouched', (SELECT COUNT(*) FROM CONNECTION_TEST),
                   '(Phase 1)', NULL, 159
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4. Keys: unique and not null (GROUP BY ... HAVING COUNT(*) > 1)
--    Question: does every primary key, and the grain key of FCT_DAILY_SPEND, identify exactly
--      one row?
--    Why: Snowflake does not enforce PRIMARY KEY or UNIQUE. A duplicated campaign in
--      DIM_CAMPAIGN would double every fact joined to it; a duplicated (CAMPAIGN_ID,
--      SPEND_DATE) would double a day's spend; a CONVERSION_ID on two lead rows would mean the
--      LEFT JOIN fanned out. CONVERSION_ID is NULL for unconverted leads by design, so its
--      expected NULL count is 221,988 and only non-NULL values are checked for duplicates.
--    Expected: 0 duplicated keys everywhere; 0 NULL keys except CONVERSION_ID (221,988 [E01 19]);
--      rows as in block 3.
-- -----------------------------------------------------------------------------
WITH duplicated_keys AS (   -- one row per key value that occurs more than once
            SELECT 1 AS ORD FROM DIM_DATE                  GROUP BY DATE_DAY                HAVING COUNT(*) > 1
  UNION ALL SELECT 2        FROM DIM_CAMPAIGN              GROUP BY CAMPAIGN_ID             HAVING COUNT(*) > 1
  UNION ALL SELECT 3        FROM DIM_CAMPAIGN              GROUP BY CAMPAIGN_NAME           HAVING COUNT(*) > 1
  UNION ALL SELECT 4        FROM FCT_DAILY_SPEND           GROUP BY SPEND_ID                HAVING COUNT(*) > 1
  UNION ALL SELECT 5        FROM FCT_DAILY_SPEND           GROUP BY CAMPAIGN_ID, SPEND_DATE HAVING COUNT(*) > 1
  UNION ALL SELECT 6        FROM FCT_LEAD_CONVERSIONS      GROUP BY LEAD_ID                 HAVING COUNT(*) > 1
  UNION ALL SELECT 7        FROM FCT_LEAD_CONVERSIONS      WHERE CONVERSION_ID IS NOT NULL
                                                           GROUP BY CONVERSION_ID           HAVING COUNT(*) > 1
  UNION ALL SELECT 8        FROM MART_CAMPAIGN_PERFORMANCE GROUP BY CAMPAIGN_ID             HAVING COUNT(*) > 1
),
keys AS (   -- rows and NULL keys per key
            SELECT 1 AS ORD, 'DIM_DATE' AS TABLE_NAME, 'DATE_DAY (PK)' AS KEY_COLUMNS, COUNT(*) AS ROW_COUNT,
                   COUNT_IF(DATE_DAY IS NULL) AS NULL_KEYS, 1096 AS EXPECTED_ROWS, 0 AS EXPECTED_NULL_KEYS FROM DIM_DATE
  UNION ALL SELECT 2, 'DIM_CAMPAIGN', 'CAMPAIGN_ID (PK)', COUNT(*), COUNT_IF(CAMPAIGN_ID IS NULL), 120, 0 FROM DIM_CAMPAIGN
  UNION ALL SELECT 3, 'DIM_CAMPAIGN', 'CAMPAIGN_NAME (alternate key)', COUNT(*), COUNT_IF(CAMPAIGN_NAME IS NULL), 120, 0
            FROM DIM_CAMPAIGN
  UNION ALL SELECT 4, 'FCT_DAILY_SPEND', 'SPEND_ID (PK)', COUNT(*), COUNT_IF(SPEND_ID IS NULL), 11240, 0 FROM FCT_DAILY_SPEND
  UNION ALL SELECT 5, 'FCT_DAILY_SPEND', 'CAMPAIGN_ID + SPEND_DATE (grain)', COUNT(*),
                   COUNT_IF(CAMPAIGN_ID IS NULL OR SPEND_DATE IS NULL), 11240, 0 FROM FCT_DAILY_SPEND
  UNION ALL SELECT 6, 'FCT_LEAD_CONVERSIONS', 'LEAD_ID (PK)', COUNT(*), COUNT_IF(LEAD_ID IS NULL), 261684, 0
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 7, 'FCT_LEAD_CONVERSIONS', 'CONVERSION_ID (NULL = not converted)', COUNT(*),
                   COUNT_IF(CONVERSION_ID IS NULL), 261684, 221988 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 8, 'MART_CAMPAIGN_PERFORMANCE', 'CAMPAIGN_ID (PK)', COUNT(*), COUNT_IF(CAMPAIGN_ID IS NULL), 120, 0
            FROM MART_CAMPAIGN_PERFORMANCE
)
SELECT k.TABLE_NAME, k.KEY_COLUMNS, k.ROW_COUNT, k.NULL_KEYS, k.EXPECTED_NULL_KEYS, COUNT(d.ORD) AS DUPLICATED_KEYS,
       0 AS EXPECTED_DUPLICATED,
       IFF(k.ROW_COUNT = k.EXPECTED_ROWS AND k.NULL_KEYS = k.EXPECTED_NULL_KEYS AND COUNT(d.ORD) = 0, 'PASS', 'FAIL') AS STATUS
FROM keys k
LEFT JOIN duplicated_keys d ON d.ORD = k.ORD
GROUP BY k.ORD, k.TABLE_NAME, k.KEY_COLUMNS, k.ROW_COUNT, k.NULL_KEYS, k.EXPECTED_NULL_KEYS, k.EXPECTED_ROWS
ORDER BY k.ORD;


-- -----------------------------------------------------------------------------
-- 5. Not null: every column that must always have a value, one row per table
--    Question: did a join leave a hole (a NULL channel, a NULL spend) anywhere?
--    Why: a NULL CHANNEL would put spend into an "unknown" bucket of every channel chart; a
--      NULL measure would make SUM silently smaller. Not checked here, by design: the five
--      conversion columns of FCT_LEAD_CONVERSIONS (NULL exactly when the lead did not
--      convert, block 10) and the ratio columns of MART_CAMPAIGN_PERFORMANCE (NULL when a
--      denominator is 0, block 15). COLUMNS_WITH_NULLS names any offender.
--    Expected: 0 NULL cells in 9 / 10 / 10 / 16 / 19 columns [C]; rows as in block 3.
-- -----------------------------------------------------------------------------
WITH null_cells AS (
  SELECT 1 AS ORD, 'DIM_DATE' AS TABLE_NAME, 1096 AS EXPECTED_ROWS, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(DATE_DAY IS NULL) AS DATE_DAY, COUNT_IF(YEAR IS NULL) AS YEAR, COUNT_IF(QUARTER IS NULL) AS QUARTER,
               COUNT_IF(MONTH_START IS NULL) AS MONTH_START, COUNT_IF(MONTH_NAME IS NULL) AS MONTH_NAME,
               COUNT_IF(WEEK_START IS NULL) AS WEEK_START, COUNT_IF(DAY_OF_WEEK_ISO IS NULL) AS DAY_OF_WEEK_ISO,
               COUNT_IF(DAY_NAME IS NULL) AS DAY_NAME, COUNT_IF(IS_WEEKEND IS NULL) AS IS_WEEKEND
        FROM DIM_DATE)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (DATE_DAY, YEAR, QUARTER, MONTH_START, MONTH_NAME, WEEK_START,
                                          DAY_OF_WEEK_ISO, DAY_NAME, IS_WEEKEND))
  UNION ALL
  SELECT 2, 'DIM_CAMPAIGN', 120, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID, COUNT_IF(CAMPAIGN_NAME IS NULL) AS CAMPAIGN_NAME,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE,
               COUNT_IF(START_DATE IS NULL) AS START_DATE, COUNT_IF(END_DATE IS NULL) AS END_DATE,
               COUNT_IF(CAMPAIGN_DAYS IS NULL) AS CAMPAIGN_DAYS, COUNT_IF(BUDGET IS NULL) AS BUDGET,
               COUNT_IF(START_YEAR IS NULL) AS START_YEAR, COUNT_IF(START_MONTH IS NULL) AS START_MONTH
        FROM DIM_CAMPAIGN)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE,
                                          CAMPAIGN_DAYS, BUDGET, START_YEAR, START_MONTH))
  UNION ALL
  SELECT 3, 'FCT_DAILY_SPEND', 11240, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(SPEND_ID IS NULL) AS SPEND_ID, COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID,
               COUNT_IF(SPEND_DATE IS NULL) AS SPEND_DATE, COUNT_IF(SPEND_MONTH IS NULL) AS SPEND_MONTH,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE,
               COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS, COUNT_IF(CLICKS IS NULL) AS CLICKS,
               COUNT_IF(SPEND IS NULL) AS SPEND, COUNT_IF(BUDGET_PRORATED IS NULL) AS BUDGET_PRORATED
        FROM FCT_DAILY_SPEND)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, SPEND_MONTH, CHANNEL, OBJECTIVE,
                                          IMPRESSIONS, CLICKS, SPEND, BUDGET_PRORATED))
  UNION ALL
  SELECT 4, 'FCT_LEAD_CONVERSIONS', 261684, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(LEAD_ID IS NULL) AS LEAD_ID, COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE,
               COUNT_IF(CREATED_DATE IS NULL) AS CREATED_DATE, COUNT_IF(CREATED_MONTH IS NULL) AS CREATED_MONTH,
               COUNT_IF(LEAD_SOURCE IS NULL) AS LEAD_SOURCE, COUNT_IF(LEAD_SCORE IS NULL) AS LEAD_SCORE,
               COUNT_IF(LEAD_SCORE_SEGMENT IS NULL) AS LEAD_SCORE_SEGMENT, COUNT_IF(IS_CONVERTED IS NULL) AS IS_CONVERTED,
               COUNT_IF(IS_TRIAL IS NULL) AS IS_TRIAL, COUNT_IF(IS_PURCHASE IS NULL) AS IS_PURCHASE,
               COUNT_IF(REVENUE IS NULL) AS REVENUE, COUNT_IF(CONVERTED_AFTER_CAMPAIGN_END IS NULL) AS CONVERTED_AFTER_CAMPAIGN_END,
               COUNT_IF(AS_OF_DATE IS NULL) AS AS_OF_DATE, COUNT_IF(IS_MATURE IS NULL) AS IS_MATURE
        FROM FCT_LEAD_CONVERSIONS)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CHANNEL, OBJECTIVE, CREATED_DATE, CREATED_MONTH,
                                          LEAD_SOURCE, LEAD_SCORE, LEAD_SCORE_SEGMENT, IS_CONVERTED, IS_TRIAL,
                                          IS_PURCHASE, REVENUE, CONVERTED_AFTER_CAMPAIGN_END, AS_OF_DATE, IS_MATURE))
  UNION ALL
  SELECT 5, 'MART_CAMPAIGN_PERFORMANCE', 120, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID, COUNT_IF(CAMPAIGN_NAME IS NULL) AS CAMPAIGN_NAME,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE,
               COUNT_IF(START_DATE IS NULL) AS START_DATE, COUNT_IF(END_DATE IS NULL) AS END_DATE,
               COUNT_IF(CAMPAIGN_DAYS IS NULL) AS CAMPAIGN_DAYS, COUNT_IF(START_YEAR IS NULL) AS START_YEAR,
               COUNT_IF(START_MONTH IS NULL) AS START_MONTH, COUNT_IF(BUDGET IS NULL) AS BUDGET,
               COUNT_IF(SPEND_DAYS IS NULL) AS SPEND_DAYS, COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS,
               COUNT_IF(CLICKS IS NULL) AS CLICKS, COUNT_IF(SPEND IS NULL) AS SPEND, COUNT_IF(LEADS IS NULL) AS LEADS,
               COUNT_IF(CONVERTED_LEADS IS NULL) AS CONVERTED_LEADS, COUNT_IF(TRIALS IS NULL) AS TRIALS,
               COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE
        FROM MART_CAMPAIGN_PERFORMANCE)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE,
                                          CAMPAIGN_DAYS, START_YEAR, START_MONTH, BUDGET, SPEND_DAYS, IMPRESSIONS,
                                          CLICKS, SPEND, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE))
)
SELECT TABLE_NAME, ROW_COUNT, COUNT(*) AS COLUMNS_CHECKED, SUM(NULL_CELLS) AS NULL_CELLS,
       COALESCE(LISTAGG(IFF(NULL_CELLS > 0, COLUMN_NAME, NULL), ', ') WITHIN GROUP (ORDER BY COLUMN_NAME), '') AS COLUMNS_WITH_NULLS,
       0 AS EXPECTED,
       IFF(ROW_COUNT = EXPECTED_ROWS AND SUM(NULL_CELLS) = 0, 'PASS', 'FAIL') AS STATUS
FROM null_cells
GROUP BY ORD, TABLE_NAME, ROW_COUNT, EXPECTED_ROWS
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6. Relationships (NOT EXISTS): every foreign key finds its dimension row, in both directions
--    Question: does every fact row find its campaign and its dates, and does every campaign
--      and every conversion reach MART?
--    Why: Snowflake does not enforce FOREIGN KEY. In Data Studio an orphan campaign or date
--      shows as a blank or "null" member, and an INNER JOIN in a later mart would silently
--      drop its spend or revenue. NOT EXISTS stays correct when a key is NULL, unlike NOT IN.
--      The month columns must hit DIM_DATE.MONTH_START, the key the month-grain marts join on.
--      Days of the spine without spend, leads or conversions are expected (they are why
--      DIM_DATE exists): no spend on 2023-01-01..03 and 2025-12-03..31.
--    Expected: 0 orphans; DIM_DATE days without spend 32 [E01 23]; days without a lead
--      1,096 - 1,064 = 32 and without a conversion 1,096 - 1,080 = 16 (distinct dates [E01 22]);
--      leads without a conversion 221,988 [E01 19].
-- -----------------------------------------------------------------------------
SELECT RELATIONSHIP, ROWS_FOUND, EXPECTED, IFF(ROWS_FOUND = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'FCT_DAILY_SPEND.CAMPAIGN_ID -> DIM_CAMPAIGN' AS RELATIONSHIP, COUNT(*) AS ROWS_FOUND, 0 AS EXPECTED
            FROM FCT_DAILY_SPEND f WHERE NOT EXISTS (SELECT 1 FROM DIM_CAMPAIGN d WHERE d.CAMPAIGN_ID = f.CAMPAIGN_ID)
  UNION ALL SELECT 2, 'FCT_LEAD_CONVERSIONS.CAMPAIGN_ID -> DIM_CAMPAIGN', COUNT(*), 0
            FROM FCT_LEAD_CONVERSIONS f WHERE NOT EXISTS (SELECT 1 FROM DIM_CAMPAIGN d WHERE d.CAMPAIGN_ID = f.CAMPAIGN_ID)
  UNION ALL SELECT 3, 'MART_CAMPAIGN_PERFORMANCE.CAMPAIGN_ID -> DIM_CAMPAIGN', COUNT(*), 0
            FROM MART_CAMPAIGN_PERFORMANCE m WHERE NOT EXISTS (SELECT 1 FROM DIM_CAMPAIGN d WHERE d.CAMPAIGN_ID = m.CAMPAIGN_ID)
  UNION ALL SELECT 4, 'DIM_CAMPAIGN without a MART_CAMPAIGN_PERFORMANCE row', COUNT(*), 0
            FROM DIM_CAMPAIGN d WHERE NOT EXISTS (SELECT 1 FROM MART_CAMPAIGN_PERFORMANCE m WHERE m.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 5, 'DIM_CAMPAIGN without FCT_DAILY_SPEND rows', COUNT(*), 0
            FROM DIM_CAMPAIGN d WHERE NOT EXISTS (SELECT 1 FROM FCT_DAILY_SPEND f WHERE f.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 6, 'DIM_CAMPAIGN without FCT_LEAD_CONVERSIONS rows', COUNT(*), 0
            FROM DIM_CAMPAIGN d WHERE NOT EXISTS (SELECT 1 FROM FCT_LEAD_CONVERSIONS f WHERE f.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 7, 'STG_CONVERSIONS rows missing from FCT_LEAD_CONVERSIONS', COUNT(*), 0
            FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
            WHERE NOT EXISTS (SELECT 1 FROM FCT_LEAD_CONVERSIONS f WHERE f.CONVERSION_ID = v.CONVERSION_ID)
  UNION ALL SELECT 8, 'FCT_DAILY_SPEND.SPEND_DATE -> DIM_DATE', COUNT(*), 0
            FROM FCT_DAILY_SPEND f WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_DAY = f.SPEND_DATE)
  UNION ALL SELECT 9, 'FCT_LEAD_CONVERSIONS.CREATED_DATE -> DIM_DATE', COUNT(*), 0
            FROM FCT_LEAD_CONVERSIONS f WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_DAY = f.CREATED_DATE)
  UNION ALL SELECT 10, 'FCT_LEAD_CONVERSIONS.CONVERTED_DATE -> DIM_DATE (converted leads)', COUNT(*), 0
            FROM FCT_LEAD_CONVERSIONS f
            WHERE f.CONVERTED_DATE IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_DAY = f.CONVERTED_DATE)
  UNION ALL SELECT 11, 'DIM_CAMPAIGN.START_DATE / END_DATE -> DIM_DATE', COUNT(*), 0
            FROM DIM_CAMPAIGN c
            WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_DAY = c.START_DATE)
               OR NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.DATE_DAY = c.END_DATE)
  UNION ALL SELECT 12, 'month columns -> DIM_DATE.MONTH_START (SPEND_, CREATED_, CONVERTED_, START_MONTH)', COUNT(*), 0
            FROM (          SELECT SPEND_MONTH AS M FROM FCT_DAILY_SPEND
                  UNION ALL SELECT CREATED_MONTH FROM FCT_LEAD_CONVERSIONS
                  UNION ALL SELECT CONVERTED_MONTH FROM FCT_LEAD_CONVERSIONS WHERE CONVERTED_MONTH IS NOT NULL
                  UNION ALL SELECT START_MONTH FROM DIM_CAMPAIGN) x
            WHERE NOT EXISTS (SELECT 1 FROM DIM_DATE d WHERE d.MONTH_START = x.M)
  UNION ALL SELECT 13, 'DIM_DATE days without a FCT_DAILY_SPEND row', COUNT(*), 32
            FROM DIM_DATE d WHERE NOT EXISTS (SELECT 1 FROM FCT_DAILY_SPEND f WHERE f.SPEND_DATE = d.DATE_DAY)
  UNION ALL SELECT 14, 'DIM_DATE days without a lead', COUNT(*), 32
            FROM DIM_DATE d WHERE NOT EXISTS (SELECT 1 FROM FCT_LEAD_CONVERSIONS f WHERE f.CREATED_DATE = d.DATE_DAY)
  UNION ALL SELECT 15, 'DIM_DATE days without a conversion', COUNT(*), 16
            FROM DIM_DATE d WHERE NOT EXISTS (SELECT 1 FROM FCT_LEAD_CONVERSIONS f WHERE f.CONVERTED_DATE = d.DATE_DAY)
  UNION ALL SELECT 16, 'FCT_LEAD_CONVERSIONS leads without a conversion (expected)', COUNT(*), 221988
            FROM FCT_LEAD_CONVERSIONS f
            WHERE NOT EXISTS (SELECT 1 FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v WHERE v.LEAD_ID = f.LEAD_ID)
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 7. DIM_DATE: a gap-free calendar
--    Question: does the spine cover exactly 2023-01-01..2025-12-31, one row per day, with
--      consistent month and ISO-week attributes?
--    Why: a gap would hide a day from every time axis; a duplicate would double it. The
--      generator spine is numbered with ROW_NUMBER() precisely so that it has no gaps; checks
--      4-5 prove it two ways (span = rows, and every step is one day). Checks 10 and 12 test
--      properties of MONTH_START and WEEK_START (first of the month; a Monday 0-6 days before
--      the day); block 8 tests concrete values.
--    Expected [CAL]: 1,096 rows; 2023-01-01..2025-12-31; 365 / 366 / 365 days per year;
--      36 months; 12 quarters; 158 ISO weeks; 313 weekend days; 157 Mondays and 157 Sundays.
-- -----------------------------------------------------------------------------
WITH steps AS (
  SELECT DATEDIFF('day', LAG(DATE_DAY) OVER (ORDER BY DATE_DAY), DATE_DAY) AS STEP_DAYS FROM DIM_DATE
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows' AS CHECK_NAME, COUNT(*) AS ACTUAL, 1096 AS EXPECTED FROM DIM_DATE
  UNION ALL SELECT 2, 'first DATE_DAY (YYYYMMDD)', TO_NUMBER(TO_CHAR(MIN(DATE_DAY), 'YYYYMMDD')), 20230101 FROM DIM_DATE
  UNION ALL SELECT 3, 'last DATE_DAY (YYYYMMDD)',  TO_NUMBER(TO_CHAR(MAX(DATE_DAY), 'YYYYMMDD')), 20251231 FROM DIM_DATE
  UNION ALL SELECT 4, 'span in days, MAX - MIN + 1 (= rows: no gaps)', DATEDIFF('day', MIN(DATE_DAY), MAX(DATE_DAY)) + 1, 1096
            FROM DIM_DATE
  UNION ALL SELECT 5, 'consecutive days not exactly 1 day apart', (SELECT COUNT_IF(STEP_DAYS <> 1) FROM steps), 0
  UNION ALL SELECT 6, 'days in 2023', COUNT_IF(YEAR = 2023), 365 FROM DIM_DATE
  UNION ALL SELECT 7, 'days in 2024 (leap year)', COUNT_IF(YEAR = 2024), 366 FROM DIM_DATE
  UNION ALL SELECT 8, 'days in 2025', COUNT_IF(YEAR = 2025), 365 FROM DIM_DATE
  UNION ALL SELECT 9, 'distinct MONTH_START', COUNT(DISTINCT MONTH_START), 36 FROM DIM_DATE
  UNION ALL SELECT 10, 'rows whose MONTH_START is not day 1 of the month of DATE_DAY',
                   COUNT_IF(DAY(MONTH_START) <> 1 OR DATEDIFF('month', MONTH_START, DATE_DAY) <> 0
                            OR DATEDIFF('day', MONTH_START, DATE_DAY) NOT BETWEEN 0 AND 30), 0 FROM DIM_DATE
  UNION ALL SELECT 11, 'distinct (YEAR, QUARTER)', COUNT(DISTINCT YEAR, QUARTER), 12 FROM DIM_DATE
  UNION ALL SELECT 12, 'rows whose WEEK_START is not a Monday 0-6 days before DATE_DAY',
                   COUNT_IF(DAYOFWEEKISO(WEEK_START) <> 1 OR DATEDIFF('day', WEEK_START, DATE_DAY) NOT BETWEEN 0 AND 6), 0
            FROM DIM_DATE
  UNION ALL SELECT 13, 'distinct WEEK_START (ISO weeks touched)', COUNT(DISTINCT WEEK_START), 158 FROM DIM_DATE
  UNION ALL SELECT 14, 'weekend days (IS_WEEKEND)', COUNT_IF(IS_WEEKEND), 313 FROM DIM_DATE
  UNION ALL SELECT 15, 'Mondays (DAY_OF_WEEK_ISO = 1, DAY_NAME Monday)', COUNT_IF(DAY_OF_WEEK_ISO = 1 AND DAY_NAME = 'Monday'), 157
            FROM DIM_DATE
  UNION ALL SELECT 16, 'Sundays (DAY_OF_WEEK_ISO = 7, DAY_NAME Sunday, IS_WEEKEND)',
                   COUNT_IF(DAY_OF_WEEK_ISO = 7 AND DAY_NAME = 'Sunday' AND IS_WEEKEND), 157 FROM DIM_DATE
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 8. DIM_DATE: every attribute of six sample dates
--    Question: are the attribute values right, not just consistent?
--    Why: the dates cover the edges and traps: the first day (a Sunday, whose ISO week starts
--      in 2022), the first Monday, a leap day, the Monday of an ISO week that belongs to the
--      next ISO year (2024-12-30), a mid-year Sunday and the last day. A missing date is its
--      own FAIL row (FULL OUTER JOIN).
--    Expected [CAL]: as listed.
-- -----------------------------------------------------------------------------
WITH expected (DATE_DAY, YEAR, QUARTER, MONTH_START, MONTH_NAME, WEEK_START, DAY_OF_WEEK_ISO, DAY_NAME, IS_WEEKEND) AS (
  SELECT * FROM VALUES
    ('2023-01-01'::DATE, 2023, 1, '2023-01-01'::DATE, 'January',  '2022-12-26'::DATE, 7, 'Sunday',    TRUE),
    ('2023-01-02'::DATE, 2023, 1, '2023-01-01'::DATE, 'January',  '2023-01-02'::DATE, 1, 'Monday',    FALSE),
    ('2024-02-29'::DATE, 2024, 1, '2024-02-01'::DATE, 'February', '2024-02-26'::DATE, 4, 'Thursday',  FALSE),
    ('2024-12-30'::DATE, 2024, 4, '2024-12-01'::DATE, 'December', '2024-12-30'::DATE, 1, 'Monday',    FALSE),
    ('2025-06-15'::DATE, 2025, 2, '2025-06-01'::DATE, 'June',     '2025-06-09'::DATE, 7, 'Sunday',    TRUE),
    ('2025-12-31'::DATE, 2025, 4, '2025-12-01'::DATE, 'December', '2025-12-29'::DATE, 3, 'Wednesday', FALSE)
),
actual AS (
  SELECT * FROM DIM_DATE WHERE DATE_DAY IN (SELECT DATE_DAY FROM expected)
)
SELECT COALESCE(a.DATE_DAY, e.DATE_DAY) AS DATE_DAY, a.YEAR, a.QUARTER, a.MONTH_START, a.MONTH_NAME, a.WEEK_START,
       a.DAY_OF_WEEK_ISO, a.DAY_NAME, a.IS_WEEKEND,
       IFF(a.YEAR = e.YEAR AND a.QUARTER = e.QUARTER AND a.MONTH_START = e.MONTH_START AND a.MONTH_NAME = e.MONTH_NAME
           AND a.WEEK_START = e.WEEK_START AND a.DAY_OF_WEEK_ISO = e.DAY_OF_WEEK_ISO AND a.DAY_NAME = e.DAY_NAME
           AND a.IS_WEEKEND = e.IS_WEEKEND, 'PASS', 'FAIL') AS STATUS
FROM actual a
FULL OUTER JOIN expected e ON e.DATE_DAY = a.DATE_DAY
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 9. Control totals: the same totals in every table that carries a measure (no fan-out)
--    Question: does every MART table add up to the Phase 2 totals, to the cent?
--    Why: this is the project's grain rule as a test (architecture decision 6): if a join had
--      fanned out, spend would be inflated (11.3 B for the naive spend x leads join); if a
--      join had dropped rows, it would be short. Each table is summed on its own, never
--      joined to another table first. BUDGET_PRORATED: each daily share is rounded to 6 dp,
--      so its total is not the budget total to the cent. Check 10 compares it exactly with
--      the total of the correctly rounded shares [D]; check 11 is the contract's sum-back rule,
--      the one tolerance of this file: it counts the campaigns whose shares do not add up to
--      the campaign budget within 0.01 (GROUP BY ... HAVING). The overall ratios are ratios of
--      the sums (never averages of row-level ratios), each dividend cast to NUMBER(32,18) so
--      the ROUND is the only rounding, as in the model; check 30 builds ROAS from the two
--      facts, each summed on its own, then divided.
--    Expected: spend 4,523,050.02, impressions 436,844,819, clicks 7,102,319, budget
--      5,418,642.16, window days 11,240 [P3; E01 23, 27, 31]; SUM(BUDGET_PRORATED)
--      5,418,642.159820 [D]; leads 261,684, converted 39,696,
--      trials 23,005, purchases 16,691, revenue 21,561,839.01, unconverted 221,988 [P3; E01 19,
--      31]; lead_score sum 13,233,637 [P1]; ROAS 4.767102, CPL 17.2844, lead conversion rate
--      0.151694 [P3 headline]; CONNECTION_TEST spend 4,523,050.02 [S1].
-- -----------------------------------------------------------------------------
WITH prorated_by_campaign AS (   -- campaigns whose prorated budget does not sum back to the budget within 0.01
  SELECT f.CAMPAIGN_ID
  FROM FCT_DAILY_SPEND f
  JOIN DIM_CAMPAIGN d ON d.CAMPAIGN_ID = f.CAMPAIGN_ID     -- many days -> one campaign
  GROUP BY f.CAMPAIGN_ID, d.BUDGET                         -- budget grouped, never summed
  HAVING ABS(SUM(f.BUDGET_PRORATED) - d.BUDGET) > 0.01
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, TOLERANCE, IFF(ABS(ACTUAL - EXPECTED) <= TOLERANCE, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'FCT_DAILY_SPEND: SUM(SPEND)' AS CHECK_NAME,
                   (SELECT SUM(SPEND) FROM FCT_DAILY_SPEND) AS ACTUAL, 4523050.02 AS EXPECTED, 0 AS TOLERANCE
  UNION ALL SELECT 2, 'MART_CAMPAIGN_PERFORMANCE: SUM(SPEND)', (SELECT SUM(SPEND) FROM MART_CAMPAIGN_PERFORMANCE), 4523050.02, 0
  UNION ALL SELECT 3, 'CONNECTION_TEST: SUM(SPEND) (Phase 1, untouched)', (SELECT SUM(SPEND) FROM CONNECTION_TEST), 4523050.02, 0
  UNION ALL SELECT 4, 'FCT_DAILY_SPEND: SUM(IMPRESSIONS)', (SELECT SUM(IMPRESSIONS) FROM FCT_DAILY_SPEND), 436844819, 0
  UNION ALL SELECT 5, 'MART_CAMPAIGN_PERFORMANCE: SUM(IMPRESSIONS)', (SELECT SUM(IMPRESSIONS) FROM MART_CAMPAIGN_PERFORMANCE), 436844819, 0
  UNION ALL SELECT 6, 'FCT_DAILY_SPEND: SUM(CLICKS)', (SELECT SUM(CLICKS) FROM FCT_DAILY_SPEND), 7102319, 0
  UNION ALL SELECT 7, 'MART_CAMPAIGN_PERFORMANCE: SUM(CLICKS)', (SELECT SUM(CLICKS) FROM MART_CAMPAIGN_PERFORMANCE), 7102319, 0
  UNION ALL SELECT 8, 'DIM_CAMPAIGN: SUM(BUDGET)', (SELECT SUM(BUDGET) FROM DIM_CAMPAIGN), 5418642.16, 0
  UNION ALL SELECT 9, 'MART_CAMPAIGN_PERFORMANCE: SUM(BUDGET)', (SELECT SUM(BUDGET) FROM MART_CAMPAIGN_PERFORMANCE), 5418642.16, 0
  UNION ALL SELECT 10, 'FCT_DAILY_SPEND: SUM(BUDGET_PRORATED) = total of the shares rounded once to 6 dp',
                   (SELECT SUM(BUDGET_PRORATED) FROM FCT_DAILY_SPEND), 5418642.159820, 0
  UNION ALL SELECT 11, 'FCT_DAILY_SPEND: campaigns whose SUM(BUDGET_PRORATED) is off BUDGET by > 0.01',
                   (SELECT COUNT(*) FROM prorated_by_campaign), 0, 0
  UNION ALL SELECT 12, 'DIM_CAMPAIGN: SUM(CAMPAIGN_DAYS)', (SELECT SUM(CAMPAIGN_DAYS) FROM DIM_CAMPAIGN), 11240, 0
  UNION ALL SELECT 13, 'MART_CAMPAIGN_PERFORMANCE: SUM(SPEND_DAYS)', (SELECT SUM(SPEND_DAYS) FROM MART_CAMPAIGN_PERFORMANCE), 11240, 0
  UNION ALL SELECT 14, 'FCT_LEAD_CONVERSIONS: leads (rows)', (SELECT COUNT(*) FROM FCT_LEAD_CONVERSIONS), 261684, 0
  UNION ALL SELECT 15, 'FCT_LEAD_CONVERSIONS: SUM(IS_CONVERTED)', (SELECT SUM(IS_CONVERTED) FROM FCT_LEAD_CONVERSIONS), 39696, 0
  UNION ALL SELECT 16, 'FCT_LEAD_CONVERSIONS: SUM(IS_TRIAL)', (SELECT SUM(IS_TRIAL) FROM FCT_LEAD_CONVERSIONS), 23005, 0
  UNION ALL SELECT 17, 'FCT_LEAD_CONVERSIONS: SUM(IS_PURCHASE)', (SELECT SUM(IS_PURCHASE) FROM FCT_LEAD_CONVERSIONS), 16691, 0
  UNION ALL SELECT 18, 'FCT_LEAD_CONVERSIONS: SUM(REVENUE)', (SELECT SUM(REVENUE) FROM FCT_LEAD_CONVERSIONS), 21561839.01, 0
  UNION ALL SELECT 19, 'FCT_LEAD_CONVERSIONS: unconverted leads (IS_CONVERTED = 0)',
                   (SELECT COUNT_IF(IS_CONVERTED = 0) FROM FCT_LEAD_CONVERSIONS), 221988, 0
  UNION ALL SELECT 20, 'FCT_LEAD_CONVERSIONS: SUM(LEAD_SCORE)', (SELECT SUM(LEAD_SCORE) FROM FCT_LEAD_CONVERSIONS), 13233637, 0
  UNION ALL SELECT 21, 'MART_CAMPAIGN_PERFORMANCE: SUM(LEADS)', (SELECT SUM(LEADS) FROM MART_CAMPAIGN_PERFORMANCE), 261684, 0
  UNION ALL SELECT 22, 'MART_CAMPAIGN_PERFORMANCE: SUM(CONVERTED_LEADS)',
                   (SELECT SUM(CONVERTED_LEADS) FROM MART_CAMPAIGN_PERFORMANCE), 39696, 0
  UNION ALL SELECT 23, 'MART_CAMPAIGN_PERFORMANCE: SUM(TRIALS)', (SELECT SUM(TRIALS) FROM MART_CAMPAIGN_PERFORMANCE), 23005, 0
  UNION ALL SELECT 24, 'MART_CAMPAIGN_PERFORMANCE: SUM(PURCHASES)', (SELECT SUM(PURCHASES) FROM MART_CAMPAIGN_PERFORMANCE), 16691, 0
  UNION ALL SELECT 25, 'MART_CAMPAIGN_PERFORMANCE: SUM(REVENUE)', (SELECT SUM(REVENUE) FROM MART_CAMPAIGN_PERFORMANCE), 21561839.01, 0
  UNION ALL SELECT 26, 'overall ROAS = SUM(REVENUE) / SUM(SPEND), 6 dp',
                   (SELECT ROUND(SUM(REVENUE)::NUMBER(32,18) / SUM(SPEND), 6) FROM MART_CAMPAIGN_PERFORMANCE), 4.767102, 0
  UNION ALL SELECT 27, 'overall CPL = SUM(SPEND) / SUM(LEADS), 4 dp',
                   (SELECT ROUND(SUM(SPEND)::NUMBER(32,18) / SUM(LEADS), 4) FROM MART_CAMPAIGN_PERFORMANCE), 17.2844, 0
  UNION ALL SELECT 28, 'overall lead conversion rate = SUM(IS_CONVERTED) / COUNT(*), 6 dp',
                   (SELECT ROUND(SUM(IS_CONVERTED)::NUMBER(32,18) / COUNT(*), 6) FROM FCT_LEAD_CONVERSIONS), 0.151694, 0
  UNION ALL SELECT 29, 'overall CTR = SUM(CLICKS) / SUM(IMPRESSIONS), 6 dp',
                   (SELECT ROUND(SUM(CLICKS)::NUMBER(32,18) / SUM(IMPRESSIONS), 6) FROM FCT_DAILY_SPEND), 0.016258, 0
  UNION ALL SELECT 30, 'overall ROAS from the two facts, each summed first, 6 dp',
                   ROUND((SELECT SUM(REVENUE) FROM FCT_LEAD_CONVERSIONS)::NUMBER(32,18) / (SELECT SUM(SPEND) FROM FCT_DAILY_SPEND), 6),
                   4.767102, 0
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 10. FCT_LEAD_CONVERSIONS: the lead-cohort semantics
--    Question: do the flags, the NULL pattern, the lag and the window flags mean what the
--      contract says?
--    Why: Data Studio will SUM the 0/1 flags and AVG the lag, so they must be exact:
--      - a converted lead has every conversion column; an unconverted lead has none, REVENUE
--        0.00 and both type flags 0 (checks 1-5);
--      - IS_TRIAL + IS_PURCHASE = IS_CONVERTED on every row: a lead converts once, to one type;
--      - DAYS_TO_CONVERT reproduces the Phase 2 lag profile (0..21, mean 10.5056, 1,811 on the
--        same day), which also proves the date arithmetic and its direction;
--      - CONVERTED_AFTER_CAMPAIGN_END reproduces the 4,716 late conversions by type and revenue;
--      - with AS_OF_DATE 2025-12-31 every lead is mature.
--    Expected: [E01 19, 24, 25, 26] and [C] as listed; trial revenue 0.00 [E01 17].
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'converted leads (IS_CONVERTED = 1)' AS CHECK_NAME, COUNT_IF(IS_CONVERTED = 1) AS ACTUAL,
                   39696 AS EXPECTED FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 2, 'converted leads missing a conversion column',
                   COUNT_IF(IS_CONVERTED = 1 AND (CONVERSION_ID IS NULL OR CONVERTED_DATE IS NULL OR CONVERTED_MONTH IS NULL
                                                  OR CONVERSION_TYPE IS NULL OR DAYS_TO_CONVERT IS NULL)), 0
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 3, 'unconverted leads (IS_CONVERTED = 0)', COUNT_IF(IS_CONVERTED = 0), 221988 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 4, 'unconverted leads with a conversion column, revenue or type flag',
                   COUNT_IF(IS_CONVERTED = 0 AND (CONVERSION_ID IS NOT NULL OR CONVERTED_DATE IS NOT NULL
                                                  OR CONVERTED_MONTH IS NOT NULL OR CONVERSION_TYPE IS NOT NULL
                                                  OR DAYS_TO_CONVERT IS NOT NULL OR REVENUE <> 0
                                                  OR IS_TRIAL <> 0 OR IS_PURCHASE <> 0)), 0
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 5, 'rows where IS_TRIAL + IS_PURCHASE <> IS_CONVERTED', COUNT_IF(IS_TRIAL + IS_PURCHASE <> IS_CONVERTED), 0
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 6, 'revenue of trials', SUM(IFF(IS_TRIAL = 1, REVENUE, 0)), 0 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 7, 'DAYS_TO_CONVERT: values (converted leads only)', COUNT(DAYS_TO_CONVERT), 39696 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 8, 'DAYS_TO_CONVERT: minimum (no conversion before its lead)', MIN(DAYS_TO_CONVERT), 0 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 9, 'DAYS_TO_CONVERT: maximum', MAX(DAYS_TO_CONVERT), 21 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 10, 'DAYS_TO_CONVERT: values outside 0..21', COUNT_IF(DAYS_TO_CONVERT NOT BETWEEN 0 AND 21), 0
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 11, 'DAYS_TO_CONVERT: mean, 4 dp', ROUND(AVG(DAYS_TO_CONVERT), 4), 10.5056 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 12, 'same-day conversions (DAYS_TO_CONVERT = 0)', COUNT_IF(DAYS_TO_CONVERT = 0), 1811 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 13, 'SUM(CONVERTED_AFTER_CAMPAIGN_END)', SUM(CONVERTED_AFTER_CAMPAIGN_END), 4716 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 14, '... of which purchases', SUM(CONVERTED_AFTER_CAMPAIGN_END * IS_PURCHASE), 1951 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 15, '... of which trials', SUM(CONVERTED_AFTER_CAMPAIGN_END * IS_TRIAL), 2765 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 16, '... their revenue', SUM(IFF(CONVERTED_AFTER_CAMPAIGN_END = 1, REVENUE, 0)), 2532266.74
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 17, 'CONVERTED_AFTER_CAMPAIGN_END on unconverted leads',
                   COUNT_IF(CONVERTED_AFTER_CAMPAIGN_END = 1 AND IS_CONVERTED = 0), 0 FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 18, 'rows with AS_OF_DATE = 2025-12-31', COUNT_IF(AS_OF_DATE = '2025-12-31'::DATE), 261684
            FROM FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 19, 'SUM(IS_MATURE) (all leads mature at the assumed as-of date)', SUM(IS_MATURE), 261684
            FROM FCT_LEAD_CONVERSIONS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 11. Lead score segments: the plan's analytical bands
--    Question: do the Low / Medium / High bands hold the right leads, conversions and revenue?
--    Why: these are the rows of the Lead Quality page. An off-by-one band edge (e.g. 40 in
--      Medium) would move about 2,600 leads per score value; the counts catch it. The rates
--      are ratios of sums (converted / leads), not averages. A NULL segment, or any other
--      value, is its own FAIL row (FULL OUTER JOIN). MIN_SCORE / MAX_SCORE are diagnostic.
--    Expected: leads 104,245 / 78,862 / 78,577 [E01 18; P3 lead_score_segments]; converted,
--      purchases, revenue and conversion rate [P3 lead_score_segments].
-- -----------------------------------------------------------------------------
WITH actual AS (
  SELECT LEAD_SCORE_SEGMENT AS SEGMENT, MIN(LEAD_SCORE) AS MIN_SCORE, MAX(LEAD_SCORE) AS MAX_SCORE, COUNT(*) AS LEADS,
         SUM(IS_CONVERTED) AS CONVERTED, SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE,
         ROUND(SUM(IS_CONVERTED) / COUNT(*), 6) AS CONVERSION_RATE
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY LEAD_SCORE_SEGMENT
),
expected (SEGMENT, ORD, LEADS, CONVERTED, PURCHASES, REVENUE, CONVERSION_RATE) AS (
  SELECT * FROM VALUES
    ('Low',    1, 104245,  9505, 3965, 5075916.10, 0.091179),
    ('Medium', 2,  78862, 12758, 5346, 6908346.48, 0.161776),
    ('High',   3,  78577, 17433, 7380, 9577576.43, 0.221859)
)
SELECT COALESCE(a.SEGMENT, e.SEGMENT, 'NULL') AS SEGMENT, a.MIN_SCORE, a.MAX_SCORE, a.LEADS, a.CONVERTED, a.PURCHASES,
       a.REVENUE, a.CONVERSION_RATE,
       IFF(a.LEADS = e.LEADS AND a.CONVERTED = e.CONVERTED AND a.PURCHASES = e.PURCHASES AND a.REVENUE = e.REVENUE
           AND a.CONVERSION_RATE = e.CONVERSION_RATE, 'PASS', 'FAIL') AS STATUS
FROM actual a
FULL OUTER JOIN expected e ON e.SEGMENT = a.SEGMENT
ORDER BY e.ORD NULLS LAST;


-- -----------------------------------------------------------------------------
-- 12. Every campaign, every base, in every MART table: equal to the Phase 2 baseline
--    Question: does each of the 120 campaigns carry exactly its Phase 2 numbers, whichever
--      MART table a dashboard reads them from?
--    Why: totals can hide offsetting errors (spend moved from one campaign to another); a
--      campaign-by-campaign comparison cannot. The expected rows are the 120 campaigns of the
--      local baseline [P3 campaign_kpi_full = expected_campaign_kpi.csv], computed from the
--      CSV files twice (DuckDB and Python Decimal) before Snowflake existed. Compared with them:
--        - MART_CAMPAIGN_PERFORMANCE, all 12 base columns;
--        - DIM_CAMPAIGN (channel, objective, budget);
--        - FCT_DAILY_SPEND and FCT_LEAD_CONVERSIONS, each rolled up to the campaign on its own
--          (the denormalised CHANNEL / OBJECTIVE must be the campaign's on every row);
--        - BUDGET_PRORATED on every row of the campaign (MIN = MAX = expected), exactly, against
--          budget / window days rounded once to 6 dp in Python [D]. No tolerance: a value
--          rounded twice (CMP0050: 298.288032 instead of 298.288031), a 4-dp or a truncated
--          share fails here, although each would still sum back within 0.01 (block 9 check 11);
--        - the 9 ratio columns, exactly, against the contract formula evaluated on the [P3]
--          bases in Python and rounded once, half away from zero [D]. The expected ratios are
--          not computed by Snowflake, so they do not share the model's division and rounding
--          path: a swapped numerator, a wrong denominator, a wrong scale or a double rounding
--          fails here. (No campaign has a zero denominator, so the NULLIF guards are not
--          exercised; block 15 check 2 counts NULL ratios.)
--      All six sources are FULL OUTER JOINed on CAMPAIGN_ID, so a campaign missing from any
--      of them (or an extra one) lowers CAMPAIGNS_MATCHING, or raises CAMPAIGNS_JOINED above
--      120, in every row.
--    Expected: 120 campaigns joined and 120 matching in all 38 checks ([P3] bases, [D] for
--      BUDGET_PRORATED and the 9 ratios).
-- -----------------------------------------------------------------------------
WITH expected (CAMPAIGN_ID, CHANNEL, OBJECTIVE, BUDGET, SPEND_DAYS, SPEND, IMPRESSIONS, CLICKS, LEADS,
               CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE) AS (   -- [P3] expected_campaign_kpi.csv, 120 rows
  SELECT * FROM VALUES
    ('CMP0001', 'paid_search', 'awareness', 14867.16, 62, 13679.39, 759938, 26014, 1374, 213, 133, 80, 105014.02),
    ('CMP0002', 'paid_social', 'awareness', 49422.28, 53, 47041.22, 4276448, 73217, 1849, 300, 160, 140, 191521.25),
    ('CMP0003', 'display', 'lead_gen', 40769.77, 91, 30895.96, 4753179, 28419, 1536, 240, 138, 102, 141758.89),
    ('CMP0004', 'video', 'acquisition', 29625.96, 125, 27494.98, 1832953, 16420, 803, 124, 60, 64, 80962.12),
    ('CMP0005', 'affiliate', 'acquisition', 18614.72, 71, 17057.46, 1895242, 48361, 2239, 344, 201, 143, 189914.53),
    ('CMP0006', 'paid_search', 'acquisition', 50135.67, 104, 35513.84, 1972946, 69302, 3235, 510, 293, 217, 288606.28),
    ('CMP0007', 'paid_social', 'acquisition', 37197.92, 49, 34977.43, 3179742, 57551, 1699, 237, 130, 107, 131491.52),
    ('CMP0008', 'display', 'lead_gen', 76141.89, 110, 62684.63, 9643736, 57850, 2969, 462, 273, 189, 251896.65),
    ('CMP0009', 'video', 'lead_gen', 63858.28, 150, 54786.64, 3652395, 32479, 1720, 260, 158, 102, 120655.46),
    ('CMP0010', 'affiliate', 'awareness', 73569.34, 107, 57375.18, 6374973, 160210, 3740, 542, 327, 215, 294187.44),
    ('CMP0011', 'paid_search', 'lead_gen', 53840.09, 51, 40961.29, 2275604, 80009, 1785, 281, 157, 124, 154659.51),
    ('CMP0012', 'paid_social', 'acquisition', 35704.57, 46, 25887.38, 2353377, 41116, 1552, 225, 137, 88, 117346.11),
    ('CMP0013', 'display', 'lead_gen', 25531.87, 72, 22247.21, 3422613, 21052, 1102, 165, 95, 70, 87891.93),
    ('CMP0014', 'video', 'awareness', 48616.15, 124, 43162.47, 2877457, 25773, 1325, 213, 133, 80, 100888.56),
    ('CMP0015', 'affiliate', 'awareness', 60983.68, 109, 58887.07, 6542960, 164871, 3808, 606, 362, 244, 319263.94),
    ('CMP0016', 'paid_search', 'lead_gen', 18289.41, 139, 15462.39, 858967, 30641, 1560, 243, 137, 106, 137600.04),
    ('CMP0017', 'paid_social', 'lead_gen', 21125.06, 54, 17839.66, 1621763, 28449, 1415, 221, 126, 95, 123567.41),
    ('CMP0018', 'display', 'acquisition', 9256.84, 75, 7405.03, 1139204, 6717, 334, 48, 37, 11, 16103.51),
    ('CMP0019', 'video', 'awareness', 27023.53, 62, 21498.81, 1433234, 12854, 684, 105, 52, 53, 61371.59),
    ('CMP0020', 'affiliate', 'lead_gen', 75829.28, 133, 60255.89, 6695040, 166576, 4632, 689, 407, 282, 348047.15),
    ('CMP0021', 'paid_search', 'awareness', 76193.25, 138, 71337.50, 3963132, 137678, 4727, 691, 400, 291, 380892.89),
    ('CMP0022', 'paid_social', 'acquisition', 38866.07, 48, 28807.41, 2618833, 46535, 1649, 265, 148, 117, 150535.58),
    ('CMP0023', 'display', 'acquisition', 21131.30, 97, 19629.01, 3019801, 17689, 932, 141, 76, 65, 75318.47),
    ('CMP0024', 'video', 'acquisition', 77960.53, 143, 66524.17, 4434898, 39676, 2111, 319, 173, 146, 179567.16),
    ('CMP0025', 'affiliate', 'awareness', 65761.80, 77, 58281.78, 6475717, 163545, 2695, 389, 217, 172, 207748.05),
    ('CMP0026', 'paid_search', 'acquisition', 49802.17, 116, 41140.87, 2285552, 80957, 3653, 590, 362, 228, 299599.91),
    ('CMP0027', 'paid_social', 'awareness', 11757.40, 78, 10152.69, 922938, 16216, 834, 123, 68, 55, 58963.11),
    ('CMP0028', 'display', 'lead_gen', 8612.99, 126, 6701.48, 1030942, 6115, 272, 44, 22, 22, 32574.62),
    ('CMP0029', 'video', 'awareness', 41244.99, 100, 36046.43, 2403062, 21378, 1142, 201, 119, 82, 102693.84),
    ('CMP0030', 'affiliate', 'acquisition', 56128.75, 63, 51492.57, 5721370, 145350, 2205, 366, 224, 142, 168745.08),
    ('CMP0031', 'paid_search', 'acquisition', 36274.33, 115, 28183.59, 1565701, 55470, 2894, 418, 247, 171, 214055.64),
    ('CMP0032', 'paid_social', 'acquisition', 61445.05, 67, 43909.18, 3991715, 69557, 2300, 323, 181, 142, 177976.13),
    ('CMP0033', 'display', 'lead_gen', 56822.40, 70, 45239.74, 6959923, 41058, 2035, 293, 174, 119, 147335.34),
    ('CMP0034', 'video', 'awareness', 39122.92, 119, 34180.02, 2278627, 20473, 1044, 140, 83, 57, 67619.25),
    ('CMP0035', 'affiliate', 'awareness', 22324.72, 82, 15913.35, 1768110, 43987, 2218, 341, 199, 142, 191083.78),
    ('CMP0036', 'paid_search', 'lead_gen', 53747.66, 83, 41412.64, 2300663, 81904, 2879, 444, 256, 188, 216453.46),
    ('CMP0037', 'paid_social', 'lead_gen', 47793.96, 97, 40531.48, 3684637, 65341, 2946, 441, 268, 173, 225273.98),
    ('CMP0038', 'display', 'lead_gen', 39747.04, 79, 36151.63, 5561759, 33458, 1797, 270, 155, 115, 153430.06),
    ('CMP0039', 'video', 'acquisition', 30625.16, 148, 24066.86, 1604409, 14425, 733, 114, 75, 39, 51293.31),
    ('CMP0040', 'affiliate', 'awareness', 15821.08, 70, 14920.90, 1657845, 41619, 2064, 321, 175, 146, 183150.82),
    ('CMP0041', 'paid_search', 'acquisition', 74625.44, 56, 66691.10, 3705038, 125449, 1960, 307, 173, 134, 176741.68),
    ('CMP0042', 'paid_social', 'lead_gen', 27889.72, 75, 21665.55, 1969563, 35453, 1785, 251, 141, 110, 140973.92),
    ('CMP0043', 'display', 'awareness', 57653.83, 129, 42997.20, 6614896, 39394, 2110, 313, 184, 129, 164223.35),
    ('CMP0044', 'video', 'acquisition', 14555.92, 85, 11538.17, 769186, 7092, 344, 53, 31, 22, 27269.70),
    ('CMP0045', 'affiliate', 'awareness', 11542.55, 54, 10543.72, 1171498, 28539, 1430, 214, 126, 88, 120094.29),
    ('CMP0046', 'paid_search', 'acquisition', 14833.84, 101, 11529.48, 640483, 22049, 1184, 190, 110, 80, 107179.82),
    ('CMP0047', 'paid_social', 'acquisition', 55545.45, 69, 50118.56, 4556197, 83181, 2410, 378, 229, 149, 183275.60),
    ('CMP0048', 'display', 'lead_gen', 66122.96, 132, 57998.75, 8922825, 54756, 2888, 457, 271, 186, 251435.20),
    ('CMP0049', 'video', 'acquisition', 28288.51, 128, 25032.55, 1668797, 14904, 745, 110, 66, 44, 61265.88),
    ('CMP0050', 'affiliate', 'awareness', 37882.58, 127, 35219.40, 3913208, 96110, 4086, 659, 360, 299, 388919.88),
    ('CMP0051', 'paid_search', 'awareness', 51270.89, 83, 36822.31, 2045648, 71113, 2799, 430, 253, 177, 226283.44),
    ('CMP0052', 'paid_social', 'awareness', 53436.27, 80, 48307.28, 4391528, 79763, 2751, 404, 236, 168, 216454.46),
    ('CMP0053', 'display', 'acquisition', 40111.22, 54, 35394.75, 5445323, 33034, 1576, 232, 133, 99, 125386.68),
    ('CMP0054', 'video', 'awareness', 16931.72, 58, 14158.05, 943849, 8525, 459, 86, 49, 37, 49365.00),
    ('CMP0055', 'affiliate', 'acquisition', 46092.80, 93, 41199.55, 4577688, 111445, 3241, 507, 288, 219, 285329.47),
    ('CMP0056', 'paid_search', 'acquisition', 60120.49, 113, 52535.84, 2918609, 103965, 3838, 595, 358, 237, 316984.23),
    ('CMP0057', 'paid_social', 'lead_gen', 55880.39, 115, 52562.77, 4778384, 83684, 3693, 559, 311, 248, 313791.40),
    ('CMP0058', 'display', 'lead_gen', 29871.43, 107, 25905.51, 3985413, 24136, 1246, 203, 115, 88, 118383.74),
    ('CMP0059', 'video', 'acquisition', 22521.39, 146, 19164.26, 1277566, 11581, 568, 91, 53, 38, 52871.36),
    ('CMP0060', 'affiliate', 'acquisition', 79884.92, 147, 62309.32, 6923196, 174518, 5104, 768, 442, 326, 417738.92),
    ('CMP0061', 'paid_search', 'lead_gen', 50880.95, 132, 48907.03, 2716997, 96240, 4239, 688, 405, 283, 369829.93),
    ('CMP0062', 'paid_social', 'lead_gen', 64913.07, 130, 49907.15, 4536957, 81572, 3878, 579, 333, 246, 321241.52),
    ('CMP0063', 'display', 'lead_gen', 58760.38, 73, 57437.04, 8836434, 54760, 2319, 346, 200, 146, 185403.34),
    ('CMP0064', 'video', 'lead_gen', 74222.90, 63, 55178.97, 3678578, 32140, 1687, 247, 153, 94, 128190.29),
    ('CMP0065', 'affiliate', 'awareness', 24191.51, 46, 18328.31, 2036457, 50924, 1594, 233, 137, 96, 121541.17),
    ('CMP0066', 'paid_search', 'lead_gen', 26228.76, 64, 19802.18, 1100095, 38647, 1884, 304, 184, 120, 158871.86),
    ('CMP0067', 'paid_social', 'acquisition', 76431.14, 51, 59042.06, 5367438, 98121, 1785, 269, 157, 112, 146717.83),
    ('CMP0068', 'display', 'lead_gen', 68674.80, 122, 57515.62, 8848499, 52503, 2854, 396, 228, 168, 229511.53),
    ('CMP0069', 'video', 'awareness', 31275.60, 114, 23146.07, 1543036, 13447, 677, 109, 67, 42, 56263.84),
    ('CMP0070', 'affiliate', 'awareness', 18386.12, 98, 17318.50, 1924236, 49209, 2587, 381, 214, 167, 218374.17),
    ('CMP0071', 'paid_search', 'lead_gen', 78158.38, 87, 62202.61, 3455663, 122752, 3045, 436, 249, 187, 227161.15),
    ('CMP0072', 'paid_social', 'awareness', 49808.42, 56, 37097.85, 3372508, 59297, 1935, 299, 182, 117, 153874.58),
    ('CMP0073', 'display', 'awareness', 79487.06, 116, 64824.15, 9972899, 58897, 3112, 487, 255, 232, 289502.55),
    ('CMP0074', 'video', 'awareness', 30992.79, 50, 26109.81, 1740637, 16515, 934, 119, 73, 46, 56859.44),
    ('CMP0075', 'affiliate', 'lead_gen', 27312.34, 71, 23249.91, 2583289, 64594, 2401, 353, 213, 140, 160754.44),
    ('CMP0076', 'paid_search', 'lead_gen', 47970.37, 66, 40845.75, 2269176, 79088, 2290, 331, 192, 139, 175902.92),
    ('CMP0077', 'paid_social', 'lead_gen', 18894.65, 117, 14837.21, 1348784, 24267, 1299, 194, 118, 76, 99552.05),
    ('CMP0078', 'display', 'lead_gen', 31875.08, 48, 24620.80, 3787793, 21845, 1133, 175, 112, 63, 88381.66),
    ('CMP0079', 'video', 'lead_gen', 75572.78, 90, 62230.93, 4148695, 36484, 1932, 292, 182, 110, 137737.16),
    ('CMP0080', 'affiliate', 'awareness', 20903.18, 141, 17904.18, 1989290, 48136, 2644, 394, 222, 172, 232990.96),
    ('CMP0081', 'paid_search', 'awareness', 48241.24, 142, 43017.04, 2389775, 83585, 4149, 605, 327, 278, 361820.39),
    ('CMP0082', 'paid_social', 'awareness', 53455.13, 91, 47464.49, 4314913, 78161, 3027, 436, 254, 182, 222854.23),
    ('CMP0083', 'display', 'lead_gen', 61419.31, 116, 48391.76, 7444837, 43964, 2404, 329, 181, 148, 187352.30),
    ('CMP0084', 'video', 'awareness', 8102.32, 111, 6105.33, 406990, 3640, 145, 14, 7, 7, 11132.24),
    ('CMP0085', 'affiliate', 'awareness', 63165.68, 52, 51639.87, 5737739, 141324, 1820, 280, 169, 111, 157336.90),
    ('CMP0086', 'paid_search', 'awareness', 13698.33, 114, 11691.91, 649503, 23060, 1277, 211, 110, 101, 126855.40),
    ('CMP0087', 'paid_social', 'awareness', 20215.14, 49, 16943.37, 1540288, 26423, 1328, 211, 127, 84, 114353.68),
    ('CMP0088', 'display', 'lead_gen', 54373.06, 117, 41644.02, 6406714, 38203, 2023, 306, 183, 123, 170722.89),
    ('CMP0089', 'video', 'acquisition', 48147.87, 62, 43045.82, 2869701, 25011, 1374, 221, 123, 98, 123929.88),
    ('CMP0090', 'affiliate', 'acquisition', 34681.00, 93, 28020.73, 3113371, 77939, 3094, 479, 294, 185, 253215.70),
    ('CMP0091', 'paid_search', 'lead_gen', 33046.33, 99, 32104.58, 1783546, 61551, 3002, 446, 263, 183, 246347.10),
    ('CMP0092', 'paid_social', 'lead_gen', 64885.51, 96, 49872.48, 4533820, 82614, 3207, 491, 267, 224, 301738.54),
    ('CMP0093', 'display', 'awareness', 78979.48, 110, 72153.85, 11100544, 65717, 3273, 478, 280, 198, 250142.87),
    ('CMP0094', 'video', 'lead_gen', 66477.07, 127, 49539.43, 3302583, 29814, 1606, 256, 139, 117, 146756.00),
    ('CMP0095', 'affiliate', 'acquisition', 23477.18, 104, 17881.69, 1986813, 49335, 2639, 385, 219, 166, 203419.10),
    ('CMP0096', 'paid_search', 'awareness', 27118.28, 54, 23764.00, 1320200, 47049, 1846, 296, 170, 126, 167071.09),
    ('CMP0097', 'paid_social', 'awareness', 50950.03, 84, 40602.61, 3691106, 65301, 2746, 433, 250, 183, 233705.96),
    ('CMP0098', 'display', 'lead_gen', 49776.78, 49, 43337.61, 6667302, 39332, 1619, 227, 134, 93, 124429.85),
    ('CMP0099', 'video', 'awareness', 12962.09, 106, 9348.40, 623190, 5440, 242, 35, 20, 15, 21200.08),
    ('CMP0100', 'affiliate', 'lead_gen', 61774.40, 62, 43167.80, 4796396, 125371, 2170, 323, 195, 128, 170090.72),
    ('CMP0101', 'paid_search', 'awareness', 74445.68, 50, 52545.91, 2919195, 100547, 1750, 279, 161, 118, 155541.15),
    ('CMP0102', 'paid_social', 'awareness', 75494.94, 112, 67070.47, 6097270, 110317, 3836, 571, 340, 231, 270077.02),
    ('CMP0103', 'display', 'lead_gen', 33787.21, 73, 28256.07, 4347053, 26071, 1392, 220, 132, 88, 104150.85),
    ('CMP0104', 'video', 'awareness', 58750.28, 82, 53604.75, 3573622, 31808, 1703, 249, 148, 101, 133477.72),
    ('CMP0105', 'affiliate', 'lead_gen', 75627.48, 99, 55272.82, 6141382, 155852, 3462, 523, 304, 219, 292696.59),
    ('CMP0106', 'paid_search', 'acquisition', 41333.42, 104, 33985.21, 1888021, 64380, 3119, 467, 281, 186, 236669.30),
    ('CMP0107', 'paid_social', 'awareness', 74343.86, 125, 66794.72, 6072187, 110441, 4138, 611, 373, 238, 316085.27),
    ('CMP0108', 'display', 'awareness', 56160.77, 127, 48553.90, 7469773, 45480, 2461, 344, 182, 162, 215141.67),
    ('CMP0109', 'video', 'awareness', 69532.05, 141, 50775.13, 3384966, 30290, 1599, 240, 130, 110, 135789.95),
    ('CMP0110', 'affiliate', 'acquisition', 37632.26, 139, 30384.26, 3375958, 84712, 4123, 640, 383, 257, 330555.85),
    ('CMP0111', 'paid_search', 'acquisition', 40817.34, 125, 36543.87, 2030160, 68540, 3453, 529, 312, 217, 280808.45),
    ('CMP0112', 'paid_social', 'acquisition', 57155.15, 47, 48945.75, 4449593, 81006, 1645, 259, 140, 119, 162840.68),
    ('CMP0113', 'display', 'lead_gen', 20114.75, 129, 19245.76, 2960829, 17765, 902, 145, 78, 67, 93150.52),
    ('CMP0114', 'video', 'awareness', 59545.21, 111, 54531.03, 3635362, 32255, 1723, 264, 160, 104, 143825.54),
    ('CMP0115', 'affiliate', 'lead_gen', 53698.12, 55, 52989.89, 5887740, 143437, 1925, 313, 173, 140, 183931.07),
    ('CMP0116', 'paid_search', 'acquisition', 43360.18, 109, 36411.20, 2022793, 70324, 3326, 515, 282, 233, 308379.69),
    ('CMP0117', 'paid_social', 'awareness', 78212.52, 117, 64353.11, 5850226, 105202, 3912, 568, 326, 242, 315925.45),
    ('CMP0118', 'display', 'lead_gen', 72976.15, 145, 56065.52, 8625397, 51659, 2860, 423, 235, 188, 230488.96),
    ('CMP0119', 'video', 'acquisition', 18913.00, 65, 16825.46, 1121676, 10066, 499, 71, 41, 30, 36568.85),
    ('CMP0120', 'affiliate', 'acquisition', 20205.92, 57, 18220.92, 2024524, 50892, 1928, 302, 169, 133, 171570.71)
),
expected_exact (CAMPAIGN_ID, BUDGET_PRORATED, CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_RATE,
                COST_PER_LEAD, COST_PER_CONVERSION, COST_PER_PURCHASE, ROAS, BUDGET_UTILIZATION) AS (   -- [D], 120 rows
  SELECT * FROM VALUES   -- BUDGET_PRORATED and rates/ROAS 6 dp, cost per unit 4 dp, each rounded once, half up
    ('CMP0001',  239.792903, 0.034232, 0.052818, 0.155022, 0.058224,   9.9559,  64.2225, 170.9924,  7.676806, 0.920108),
    ('CMP0002',  932.495849, 0.017121, 0.025254, 0.162250, 0.075717,  25.4414, 156.8041, 336.0087,  4.071350, 0.951822),
    ('CMP0003',  448.019451, 0.005979, 0.054048, 0.156250, 0.066406,  20.1146, 128.7332, 302.9016,  4.588266, 0.757815),
    ('CMP0004',  237.007680, 0.008958, 0.048904, 0.154421, 0.079701,  34.2403, 221.7337, 429.6091,  2.944615, 0.928071),
    ('CMP0005',  262.179155, 0.025517, 0.046298, 0.153640, 0.063868,   7.6183,  49.5856, 119.2829, 11.133811, 0.916343),
    ('CMP0006',  482.073750, 0.035126, 0.046680, 0.157651, 0.067079,  10.9780,  69.6350, 163.6582,  8.126586, 0.708355),
    ('CMP0007',  759.141224, 0.018099, 0.029522, 0.139494, 0.062978,  20.5871, 147.5841, 326.8919,  3.759325, 0.940306),
    ('CMP0008',  692.199000, 0.005999, 0.051322, 0.155608, 0.063658,  21.1130, 135.6810, 331.6647,  4.018476, 0.823261),
    ('CMP0009',  425.721867, 0.008893, 0.052957, 0.151163, 0.059302,  31.8527, 210.7178, 537.1239,  2.202279, 0.857941),
    ('CMP0010',  687.563925, 0.025131, 0.023344, 0.144920, 0.057487,  15.3410, 105.8583, 266.8613,  5.127434, 0.779879),
    ('CMP0011', 1055.688039, 0.035159, 0.022310, 0.157423, 0.069468,  22.9475, 145.7697, 330.3330,  3.775748, 0.760795),
    ('CMP0012',  776.186304, 0.017471, 0.037747, 0.144974, 0.056701,  16.6800, 115.0550, 294.1748,  4.532947, 0.725044),
    ('CMP0013',  354.609306, 0.006151, 0.052347, 0.149728, 0.063521,  20.1880, 134.8316, 317.8173,  3.950694, 0.871351),
    ('CMP0014',  392.065726, 0.008957, 0.051410, 0.160755, 0.060377,  32.5754, 202.6407, 539.5309,  2.337414, 0.887822),
    ('CMP0015',  559.483303, 0.025198, 0.023097, 0.159139, 0.064076,  15.4640,  97.1734, 241.3405,  5.421631, 0.965620),
    ('CMP0016',  131.578489, 0.035672, 0.050912, 0.155769, 0.067949,   9.9118,  63.6312, 145.8716,  8.899015, 0.845429),
    ('CMP0017',  391.204815, 0.017542, 0.049738, 0.156184, 0.067138,  12.6075,  80.7224, 187.7859,  6.926556, 0.844479),
    ('CMP0018',  123.424533, 0.005896, 0.049725, 0.143713, 0.032934,  22.1707, 154.2715, 673.1845,  2.174672, 0.799952),
    ('CMP0019',  435.863387, 0.008969, 0.053213, 0.153509, 0.077485,  31.4310, 204.7506, 405.6379,  2.854651, 0.795559),
    ('CMP0020',  570.144962, 0.024881, 0.027807, 0.148748, 0.060881,  13.0086,  87.4541, 213.6734,  5.776152, 0.794626),
    ('CMP0021',  552.125000, 0.034740, 0.034334, 0.146182, 0.061561,  15.0915, 103.2381, 245.1460,  5.339308, 0.936271),
    ('CMP0022',  809.709792, 0.017769, 0.035436, 0.160703, 0.070952,  17.4696, 108.7072, 246.2172,  5.225585, 0.741197),
    ('CMP0023',  217.848454, 0.005858, 0.052688, 0.151288, 0.069742,  21.0612, 139.2128, 301.9848,  3.837100, 0.928907),
    ('CMP0024',  545.178531, 0.008946, 0.053206, 0.151113, 0.069162,  31.5131, 208.5397, 455.6450,  2.699277, 0.853306),
    ('CMP0025',  854.049351, 0.025255, 0.016479, 0.144341, 0.063822,  21.6259, 149.8246, 338.8476,  3.564545, 0.886256),
    ('CMP0026',  429.329052, 0.035421, 0.045123, 0.161511, 0.062414,  11.2622,  69.7303, 180.4424,  7.282294, 0.826086),
    ('CMP0027',  150.735897, 0.017570, 0.051431, 0.147482, 0.065947,  12.1735,  82.5422, 184.5944,  5.807634, 0.863515),
    ('CMP0028',   68.357063, 0.005931, 0.044481, 0.161765, 0.080882,  24.6378, 152.3064, 304.6127,  4.860810, 0.778067),
    ('CMP0029',  412.449900, 0.008896, 0.053419, 0.176007, 0.071804,  31.5643, 179.3355, 439.5906,  2.848932, 0.873959),
    ('CMP0030',  890.932540, 0.025405, 0.015170, 0.165986, 0.064399,  23.3526, 140.6901, 362.6237,  3.277076, 0.917401),
    ('CMP0031',  315.428957, 0.035428, 0.052172, 0.144437, 0.059088,   9.7386,  67.4249, 164.8163,  7.595045, 0.776957),
    ('CMP0032',  917.090299, 0.017425, 0.033066, 0.140435, 0.061739,  19.0909, 135.9417, 309.2196,  4.053278, 0.714609),
    ('CMP0033',  811.748571, 0.005899, 0.049564, 0.143980, 0.058477,  22.2308, 154.4018, 380.1659,  3.256768, 0.796160),
    ('CMP0034',  328.764034, 0.008985, 0.050994, 0.134100, 0.054598,  32.7395, 244.1430, 599.6495,  1.978327, 0.873657),
    ('CMP0035',  272.252683, 0.024878, 0.050424, 0.153742, 0.064022,   7.1746,  46.6667, 112.0658, 12.007766, 0.712813),
    ('CMP0036',  647.562169, 0.035600, 0.035151, 0.154220, 0.065300,  14.3844,  93.2717, 220.2800,  5.226749, 0.770501),
    ('CMP0037',  492.721237, 0.017733, 0.045087, 0.149695, 0.058724,  13.7581,  91.9081, 234.2860,  5.558000, 0.848046),
    ('CMP0038',  503.127089, 0.006016, 0.053709, 0.150250, 0.063996,  20.1178, 133.8949, 314.3620,  4.244070, 0.909543),
    ('CMP0039',  206.926757, 0.008991, 0.050815, 0.155525, 0.053206,  32.8334, 211.1128, 617.0990,  2.131284, 0.785853),
    ('CMP0040',  226.015429, 0.025104, 0.049593, 0.155523, 0.070736,   7.2291,  46.4826, 102.1979, 12.274784, 0.943102),
    ('CMP0041', 1332.597143, 0.033859, 0.015624, 0.156633, 0.068367,  34.0261, 217.2349, 497.6948,  2.650154, 0.893678),
    ('CMP0042',  371.862933, 0.018000, 0.050348, 0.140616, 0.061625,  12.1376,  86.3169, 196.9595,  6.506824, 0.776829),
    ('CMP0043',  446.928915, 0.005955, 0.053561, 0.148341, 0.061137,  20.3778, 137.3712, 333.3116,  3.819396, 0.745782),
    ('CMP0044',  171.246118, 0.009220, 0.048505, 0.154070, 0.063953,  33.5412, 217.7013, 524.4623,  2.363434, 0.792679),
    ('CMP0045',  213.750926, 0.024361, 0.050107, 0.149650, 0.061538,   7.3732,  49.2697, 119.8150, 11.390125, 0.913465),
    ('CMP0046',  146.869703, 0.034426, 0.053699, 0.160473, 0.067568,   9.7377,  60.6815, 144.1185,  9.296154, 0.777242),
    ('CMP0047',  805.006522, 0.018257, 0.028973, 0.156846, 0.061826,  20.7961, 132.5888, 336.3662,  3.656841, 0.902298),
    ('CMP0048',  500.931515, 0.006137, 0.052743, 0.158241, 0.064404,  20.0827, 126.9119, 311.8212,  4.335183, 0.877135),
    ('CMP0049',  221.003984, 0.008931, 0.049987, 0.147651, 0.059060,  33.6007, 227.5686, 568.9216,  2.447449, 0.884902),
    ('CMP0050',  298.288031, 0.024560, 0.042514, 0.161282, 0.073177,   8.6195,  53.4437, 117.7906, 11.042774, 0.929699),
    ('CMP0051',  617.721566, 0.034763, 0.039360, 0.153626, 0.063237,  13.1555,  85.6333, 208.0356,  6.145281, 0.718191),
    ('CMP0052',  667.953375, 0.018163, 0.034490, 0.146856, 0.061069,  17.5599, 119.5725, 287.5433,  4.480783, 0.904017),
    ('CMP0053',  742.800370, 0.006066, 0.047708, 0.147208, 0.062817,  22.4586, 152.5636, 357.5227,  3.542522, 0.882415),
    ('CMP0054',  291.926207, 0.009032, 0.053842, 0.187364, 0.080610,  30.8454, 164.6285, 382.6500,  3.486709, 0.836185),
    ('CMP0055',  495.621505, 0.024345, 0.029082, 0.156433, 0.067572,  12.7120,  81.2614, 188.1258,  6.925548, 0.893839),
    ('CMP0056',  532.039735, 0.035621, 0.036916, 0.155029, 0.061751,  13.6883,  88.2955, 221.6702,  6.033676, 0.873843),
    ('CMP0057',  485.916435, 0.017513, 0.044130, 0.151367, 0.067154,  14.2331,  94.0300, 211.9467,  5.969841, 0.940630),
    ('CMP0058',  279.172243, 0.006056, 0.051624, 0.162921, 0.070626,  20.7909, 127.6133, 294.3808,  4.569829, 0.867234),
    ('CMP0059',  154.256096, 0.009065, 0.049046, 0.160211, 0.066901,  33.7399, 210.5963, 504.3226,  2.758852, 0.850936),
    ('CMP0060',  543.434830, 0.025208, 0.029246, 0.150470, 0.063871,  12.2079,  81.1319, 191.1329,  6.704277, 0.779989),
    ('CMP0061',  385.461742, 0.035421, 0.044046, 0.162302, 0.066761,  11.5374,  71.0858, 172.8164,  7.561897, 0.961205),
    ('CMP0062',  499.331308, 0.017979, 0.047541, 0.149304, 0.063435,  12.8693,  86.1954, 202.8746,  6.436784, 0.768831),
    ('CMP0063',  804.936712, 0.006197, 0.042348, 0.149202, 0.062958,  24.7680, 166.0030, 393.4044,  3.227940, 0.977479),
    ('CMP0064', 1178.141270, 0.008737, 0.052489, 0.146414, 0.055720,  32.7083, 223.3966, 587.0103,  2.323173, 0.743422),
    ('CMP0065',  525.902391, 0.025006, 0.031302, 0.146173, 0.060226,  11.4983,  78.6623, 190.9199,  6.631335, 0.757634),
    ('CMP0066',  409.824375, 0.035131, 0.048749, 0.161359, 0.063694,  10.5107,  65.1388, 165.0182,  8.022948, 0.754980),
    ('CMP0067', 1498.649804, 0.018281, 0.018192, 0.150700, 0.062745,  33.0768, 219.4872, 527.1613,  2.484971, 0.772487),
    ('CMP0068',  562.908197, 0.005934, 0.054359, 0.138753, 0.058865,  20.1526, 145.2415, 342.3549,  3.990421, 0.837507),
    ('CMP0069',  274.347368, 0.008715, 0.050346, 0.161004, 0.062038,  34.1892, 212.3493, 551.0969,  2.430816, 0.740068),
    ('CMP0070',  187.613469, 0.025573, 0.052572, 0.147275, 0.064554,   6.6944,  45.4554, 103.7036, 12.609300, 0.941933),
    ('CMP0071',  898.372184, 0.035522, 0.024806, 0.143186, 0.061412,  20.4278, 142.6665, 332.6343,  3.651955, 0.795853),
    ('CMP0072',  889.436071, 0.017582, 0.032632, 0.154522, 0.060465,  19.1720, 124.0731, 317.0756,  4.147803, 0.744811),
    ('CMP0073',  685.233276, 0.005906, 0.052838, 0.156491, 0.074550,  20.8304, 133.1091, 279.4144,  4.465968, 0.815531),
    ('CMP0074',  619.855800, 0.009488, 0.056555, 0.127409, 0.049251,  27.9548, 219.4102, 567.6046,  2.177704, 0.842448),
    ('CMP0075',  384.680845, 0.025005, 0.037171, 0.147022, 0.058309,   9.6834,  65.8638, 166.0708,  6.914196, 0.851260),
    ('CMP0076',  726.823788, 0.034853, 0.028955, 0.144541, 0.060699,  17.8366, 123.4011, 293.8543,  4.306517, 0.851479),
    ('CMP0077',  161.492735, 0.017992, 0.053529, 0.149346, 0.058507,  11.4220,  76.4805, 195.2264,  6.709621, 0.785260),
    ('CMP0078',  664.064167, 0.005767, 0.051865, 0.154457, 0.055605,  21.7306, 140.6903, 390.8063,  3.589715, 0.772415),
    ('CMP0079',  839.697556, 0.008794, 0.052955, 0.151139, 0.056936,  32.2106, 213.1196, 565.7357,  2.213323, 0.823457),
    ('CMP0080',  148.249504, 0.024198, 0.054928, 0.149017, 0.065053,   6.7716,  45.4421, 104.0941, 13.013216, 0.856529),
    ('CMP0081',  339.727042, 0.034976, 0.049638, 0.145818, 0.067004,  10.3681,  71.1025, 154.7376,  8.411095, 0.891707),
    ('CMP0082',  587.419011, 0.018114, 0.038728, 0.144037, 0.060126,  15.6804, 108.8635, 260.7939,  4.695178, 0.887931),
    ('CMP0083',  529.476810, 0.005905, 0.054681, 0.136855, 0.061564,  20.1297, 147.0874, 326.9714,  3.871574, 0.787892),
    ('CMP0084',   72.993874, 0.008944, 0.039835, 0.096552, 0.048276,  42.1057, 436.0950, 872.1900,  1.823364, 0.753529),
    ('CMP0085', 1214.724615, 0.024631, 0.012878, 0.153846, 0.060989,  28.3736, 184.4281, 465.2241,  3.046811, 0.817531),
    ('CMP0086',  120.160789, 0.035504, 0.055377, 0.165231, 0.079092,   9.1558,  55.4119, 115.7615, 10.849844, 0.853528),
    ('CMP0087',  412.553878, 0.017155, 0.050259, 0.158886, 0.063253,  12.7586,  80.3003, 201.7068,  6.749170, 0.838152),
    ('CMP0088',  464.727009, 0.005963, 0.052954, 0.151261, 0.060801,  20.5853, 136.0916, 338.5693,  4.099578, 0.765894),
    ('CMP0089',  776.578548, 0.008716, 0.054936, 0.160844, 0.071325,  31.3288, 194.7775, 439.2431,  2.879022, 0.894034),
    ('CMP0090',  372.913978, 0.025034, 0.039698, 0.154816, 0.059793,   9.0565,  58.4984, 151.4634,  9.036727, 0.807956),
    ('CMP0091',  333.801313, 0.034510, 0.048773, 0.148568, 0.060959,  10.6944,  71.9834, 175.4349,  7.673270, 0.971502),
    ('CMP0092',  675.890729, 0.018222, 0.038819, 0.153103, 0.069847,  15.5511, 101.5733, 222.6450,  6.050201, 0.768623),
    ('CMP0093',  717.995273, 0.005920, 0.049804, 0.146043, 0.060495,  22.0452, 150.9495, 364.4134,  3.466799, 0.913577),
    ('CMP0094',  523.441496, 0.009027, 0.053867, 0.159402, 0.072852,  30.8465, 193.5134, 423.4139,  2.962408, 0.745211),
    ('CMP0095',  225.742115, 0.024831, 0.053491, 0.145889, 0.062903,   6.7759,  46.4459, 107.7210, 11.375832, 0.761663),
    ('CMP0096',  502.190370, 0.035638, 0.039236, 0.160347, 0.068256,  12.8732,  80.2838, 188.6032,  7.030428, 0.876309),
    ('CMP0097',  606.547976, 0.017691, 0.042051, 0.157684, 0.066642,  14.7861,  93.7705, 221.8722,  5.755934, 0.796910),
    ('CMP0098', 1015.852653, 0.005899, 0.041162, 0.140210, 0.057443,  26.7681, 190.9146, 465.9958,  2.871175, 0.870639),
    ('CMP0099',  122.283868, 0.008729, 0.044485, 0.144628, 0.061983,  38.6298, 267.0971, 623.2267,  2.267776, 0.721211),
    ('CMP0100',  996.361290, 0.026139, 0.017309, 0.148848, 0.058986,  19.8930, 133.6464, 337.2484,  3.940222, 0.698798),
    ('CMP0101', 1488.913600, 0.034443, 0.017405, 0.159429, 0.067429,  30.0262, 188.3366, 445.3043,  2.960100, 0.705829),
    ('CMP0102',  674.061964, 0.018093, 0.034773, 0.148853, 0.060219,  17.4845, 117.4614, 290.3484,  4.026765, 0.888410),
    ('CMP0103',  462.838493, 0.005997, 0.053393, 0.158046, 0.063218,  20.2989, 128.4367, 321.0917,  3.685964, 0.836295),
    ('CMP0104',  716.466829, 0.008901, 0.053540, 0.146213, 0.059307,  31.4767, 215.2801, 530.7401,  2.490035, 0.912417),
    ('CMP0105',  763.913939, 0.025377, 0.022213, 0.151069, 0.063258,  15.9656, 105.6842, 252.3873,  5.295489, 0.730856),
    ('CMP0106',  397.436731, 0.034099, 0.048447, 0.149727, 0.059634,  10.8962,  72.7735, 182.7162,  6.963891, 0.822221),
    ('CMP0107',  594.750880, 0.018188, 0.037468, 0.147656, 0.057516,  16.1418, 109.3203, 280.6501,  4.732189, 0.898456),
    ('CMP0108',  442.210787, 0.006089, 0.054112, 0.139781, 0.065827,  19.7293, 141.1451, 299.7154,  4.430986, 0.864552),
    ('CMP0109',  493.135106, 0.008948, 0.052790, 0.150094, 0.068793,  31.7543, 211.5630, 461.5921,  2.674340, 0.730241),
    ('CMP0110',  270.735683, 0.025093, 0.048671, 0.155227, 0.062333,   7.3695,  47.4754, 118.2267, 10.879181, 0.807399),
    ('CMP0111',  326.538720, 0.033761, 0.050379, 0.153200, 0.062844,  10.5832,  69.0810, 168.4049,  7.684146, 0.895303),
    ('CMP0112', 1216.067021, 0.018205, 0.020307, 0.157447, 0.072340,  29.7543, 188.9797, 411.3088,  3.326963, 0.856366),
    ('CMP0113',  155.928295, 0.006000, 0.050774, 0.160754, 0.074279,  21.3368, 132.7294, 287.2501,  4.840054, 0.956798),
    ('CMP0114',  536.443333, 0.008873, 0.053418, 0.153221, 0.060360,  31.6489, 206.5569, 524.3368,  2.637499, 0.915792),
    ('CMP0115',  976.329455, 0.024362, 0.013421, 0.162597, 0.072727,  27.5272, 169.2968, 378.4992,  3.471060, 0.986811),
    ('CMP0116',  397.799817, 0.034766, 0.047295, 0.154841, 0.070054,  10.9474,  70.7014, 156.2712,  8.469364, 0.839738),
    ('CMP0117',  668.483077, 0.017983, 0.037186, 0.145194, 0.061861,  16.4502, 113.2977, 265.9219,  4.909249, 0.822798),
    ('CMP0118',  503.283793, 0.005989, 0.055363, 0.147902, 0.065734,  19.6033, 132.5426, 298.2209,  4.111064, 0.768272),
    ('CMP0119',  290.969231, 0.008974, 0.049573, 0.142285, 0.060120,  33.7184, 236.9783, 560.8487,  2.173423, 0.889624),
    ('CMP0120',  354.489825, 0.025138, 0.037884, 0.156639, 0.068983,   9.4507,  60.3342, 136.9994,  9.416139, 0.901761)
),
spend_facts AS (            -- FCT_DAILY_SPEND rolled up to the campaign on its own
  SELECT CAMPAIGN_ID, COUNT(*) AS SPEND_DAYS, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS,
         MIN(BUDGET_PRORATED) AS MIN_BUDGET_PRORATED, MAX(BUDGET_PRORATED) AS MAX_BUDGET_PRORATED,
         COUNT_IF(BUDGET_PRORATED IS NULL) AS NULL_BUDGET_PRORATED,
         MIN(CHANNEL) AS MIN_CHANNEL, MAX(CHANNEL) AS MAX_CHANNEL, COUNT_IF(CHANNEL IS NULL) AS NULL_CHANNEL,
         MIN(OBJECTIVE) AS MIN_OBJECTIVE, MAX(OBJECTIVE) AS MAX_OBJECTIVE, COUNT_IF(OBJECTIVE IS NULL) AS NULL_OBJECTIVE
  FROM FCT_DAILY_SPEND
  GROUP BY CAMPAIGN_ID
),
lead_facts AS (             -- FCT_LEAD_CONVERSIONS rolled up to the campaign on its own
  SELECT CAMPAIGN_ID, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS, SUM(IS_TRIAL) AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE,
         MIN(CHANNEL) AS MIN_CHANNEL, MAX(CHANNEL) AS MAX_CHANNEL, COUNT_IF(CHANNEL IS NULL) AS NULL_CHANNEL,
         MIN(OBJECTIVE) AS MIN_OBJECTIVE, MAX(OBJECTIVE) AS MAX_OBJECTIVE, COUNT_IF(OBJECTIVE IS NULL) AS NULL_OBJECTIVE
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CAMPAIGN_ID
),
matches AS (                -- one row: for each check, the number of campaigns whose values match
  SELECT COUNT(*) AS CAMPAIGNS_JOINED,
         -- MART_CAMPAIGN_PERFORMANCE: the 12 base columns
         COUNT_IF(m.CHANNEL = e.CHANNEL)                   AS MART_CAMPAIGN_PERFORMANCE__CHANNEL,
         COUNT_IF(m.OBJECTIVE = e.OBJECTIVE)               AS MART_CAMPAIGN_PERFORMANCE__OBJECTIVE,
         COUNT_IF(m.BUDGET = e.BUDGET)                     AS MART_CAMPAIGN_PERFORMANCE__BUDGET,
         COUNT_IF(m.SPEND_DAYS = e.SPEND_DAYS)             AS MART_CAMPAIGN_PERFORMANCE__SPEND_DAYS,
         COUNT_IF(m.SPEND = e.SPEND)                       AS MART_CAMPAIGN_PERFORMANCE__SPEND,
         COUNT_IF(m.IMPRESSIONS = e.IMPRESSIONS)           AS MART_CAMPAIGN_PERFORMANCE__IMPRESSIONS,
         COUNT_IF(m.CLICKS = e.CLICKS)                     AS MART_CAMPAIGN_PERFORMANCE__CLICKS,
         COUNT_IF(m.LEADS = e.LEADS)                       AS MART_CAMPAIGN_PERFORMANCE__LEADS,
         COUNT_IF(m.CONVERTED_LEADS = e.CONVERTED_LEADS)   AS MART_CAMPAIGN_PERFORMANCE__CONVERTED_LEADS,
         COUNT_IF(m.TRIALS = e.TRIALS)                     AS MART_CAMPAIGN_PERFORMANCE__TRIALS,
         COUNT_IF(m.PURCHASES = e.PURCHASES)               AS MART_CAMPAIGN_PERFORMANCE__PURCHASES,
         COUNT_IF(m.REVENUE = e.REVENUE)                   AS MART_CAMPAIGN_PERFORMANCE__REVENUE,
         -- MART_CAMPAIGN_PERFORMANCE: the 9 ratios = the contract formula on the [P3] bases, rounded in Python [D]
         COUNT_IF(m.CTR                  = x.CTR)                  AS MART_CAMPAIGN_PERFORMANCE__CTR,
         COUNT_IF(m.CLICK_TO_LEAD_RATE   = x.CLICK_TO_LEAD_RATE)   AS MART_CAMPAIGN_PERFORMANCE__CLICK_TO_LEAD_RATE,
         COUNT_IF(m.LEAD_CONVERSION_RATE = x.LEAD_CONVERSION_RATE) AS MART_CAMPAIGN_PERFORMANCE__LEAD_CONVERSION_RATE,
         COUNT_IF(m.PURCHASE_RATE        = x.PURCHASE_RATE)        AS MART_CAMPAIGN_PERFORMANCE__PURCHASE_RATE,
         COUNT_IF(m.COST_PER_LEAD        = x.COST_PER_LEAD)        AS MART_CAMPAIGN_PERFORMANCE__COST_PER_LEAD,
         COUNT_IF(m.COST_PER_CONVERSION  = x.COST_PER_CONVERSION)  AS MART_CAMPAIGN_PERFORMANCE__COST_PER_CONVERSION,
         COUNT_IF(m.COST_PER_PURCHASE    = x.COST_PER_PURCHASE)    AS MART_CAMPAIGN_PERFORMANCE__COST_PER_PURCHASE,
         COUNT_IF(m.ROAS                 = x.ROAS)                 AS MART_CAMPAIGN_PERFORMANCE__ROAS,
         COUNT_IF(m.BUDGET_UTILIZATION   = x.BUDGET_UTILIZATION)   AS MART_CAMPAIGN_PERFORMANCE__BUDGET_UTILIZATION,
         -- DIM_CAMPAIGN
         COUNT_IF(d.CHANNEL = e.CHANNEL)                   AS DIM_CAMPAIGN__CHANNEL,
         COUNT_IF(d.OBJECTIVE = e.OBJECTIVE)               AS DIM_CAMPAIGN__OBJECTIVE,
         COUNT_IF(d.BUDGET = e.BUDGET)                     AS DIM_CAMPAIGN__BUDGET,
         -- FCT_DAILY_SPEND rolled up to the campaign
         COUNT_IF(s.SPEND_DAYS = e.SPEND_DAYS)             AS FCT_DAILY_SPEND__SPEND_DAYS,
         COUNT_IF(s.SPEND = e.SPEND)                       AS FCT_DAILY_SPEND__SPEND,
         COUNT_IF(s.IMPRESSIONS = e.IMPRESSIONS)           AS FCT_DAILY_SPEND__IMPRESSIONS,
         COUNT_IF(s.CLICKS = e.CLICKS)                     AS FCT_DAILY_SPEND__CLICKS,
         COUNT_IF(s.MIN_BUDGET_PRORATED = x.BUDGET_PRORATED AND s.MAX_BUDGET_PRORATED = x.BUDGET_PRORATED
                  AND s.NULL_BUDGET_PRORATED = 0)            AS FCT_DAILY_SPEND__BUDGET_PRORATED,
         COUNT_IF(s.MIN_CHANNEL = e.CHANNEL AND s.MAX_CHANNEL = e.CHANNEL AND s.NULL_CHANNEL = 0)         AS FCT_DAILY_SPEND__CHANNEL,
         COUNT_IF(s.MIN_OBJECTIVE = e.OBJECTIVE AND s.MAX_OBJECTIVE = e.OBJECTIVE AND s.NULL_OBJECTIVE = 0) AS FCT_DAILY_SPEND__OBJECTIVE,
         -- FCT_LEAD_CONVERSIONS rolled up to the campaign
         COUNT_IF(l.LEADS = e.LEADS)                       AS FCT_LEAD_CONVERSIONS__LEADS,
         COUNT_IF(l.CONVERTED_LEADS = e.CONVERTED_LEADS)   AS FCT_LEAD_CONVERSIONS__CONVERTED_LEADS,
         COUNT_IF(l.TRIALS = e.TRIALS)                     AS FCT_LEAD_CONVERSIONS__TRIALS,
         COUNT_IF(l.PURCHASES = e.PURCHASES)               AS FCT_LEAD_CONVERSIONS__PURCHASES,
         COUNT_IF(l.REVENUE = e.REVENUE)                   AS FCT_LEAD_CONVERSIONS__REVENUE,
         COUNT_IF(l.MIN_CHANNEL = e.CHANNEL AND l.MAX_CHANNEL = e.CHANNEL AND l.NULL_CHANNEL = 0)         AS FCT_LEAD_CONVERSIONS__CHANNEL,
         COUNT_IF(l.MIN_OBJECTIVE = e.OBJECTIVE AND l.MAX_OBJECTIVE = e.OBJECTIVE AND l.NULL_OBJECTIVE = 0) AS FCT_LEAD_CONVERSIONS__OBJECTIVE
  FROM expected e
  FULL OUTER JOIN expected_exact            x ON x.CAMPAIGN_ID = e.CAMPAIGN_ID
  FULL OUTER JOIN MART_CAMPAIGN_PERFORMANCE m ON m.CAMPAIGN_ID = COALESCE(e.CAMPAIGN_ID, x.CAMPAIGN_ID)
  FULL OUTER JOIN DIM_CAMPAIGN              d ON d.CAMPAIGN_ID = COALESCE(e.CAMPAIGN_ID, x.CAMPAIGN_ID, m.CAMPAIGN_ID)
  FULL OUTER JOIN spend_facts               s ON s.CAMPAIGN_ID = COALESCE(e.CAMPAIGN_ID, x.CAMPAIGN_ID, m.CAMPAIGN_ID, d.CAMPAIGN_ID)
  FULL OUTER JOIN lead_facts                l ON l.CAMPAIGN_ID = COALESCE(e.CAMPAIGN_ID, x.CAMPAIGN_ID, m.CAMPAIGN_ID, d.CAMPAIGN_ID,
                                                                     s.CAMPAIGN_ID)
)
SELECT SPLIT_PART(CHECK_ID, '__', 1) AS MODEL, SPLIT_PART(CHECK_ID, '__', 2) AS COLUMN_NAME,
       CASE WHEN SPLIT_PART(CHECK_ID, '__', 2) IN ('CTR', 'CLICK_TO_LEAD_RATE', 'LEAD_CONVERSION_RATE', 'PURCHASE_RATE',
                                                    'COST_PER_LEAD', 'COST_PER_CONVERSION', 'COST_PER_PURCHASE', 'ROAS',
                                                    'BUDGET_UTILIZATION')
                 THEN 'exact [D], rounded once in Python'
            WHEN CHECK_ID = 'FCT_DAILY_SPEND__BUDGET_PRORATED' THEN 'exact [D] on every row of the campaign'
            WHEN STARTSWITH(CHECK_ID, 'FCT_') AND SPLIT_PART(CHECK_ID, '__', 2) IN ('CHANNEL', 'OBJECTIVE')
                 THEN 'every row of the campaign'
            WHEN STARTSWITH(CHECK_ID, 'FCT_') THEN 'rolled up to the campaign'
            ELSE 'equal'
       END AS COMPARISON,
       CAMPAIGNS_JOINED, CAMPAIGNS_MATCHING, 120 AS EXPECTED,
       IFF(CAMPAIGNS_JOINED = 120 AND CAMPAIGNS_MATCHING = 120, 'PASS', 'FAIL') AS STATUS
FROM matches
UNPIVOT (CAMPAIGNS_MATCHING FOR CHECK_ID IN (
  MART_CAMPAIGN_PERFORMANCE__CHANNEL, MART_CAMPAIGN_PERFORMANCE__OBJECTIVE, MART_CAMPAIGN_PERFORMANCE__BUDGET,
  MART_CAMPAIGN_PERFORMANCE__SPEND_DAYS, MART_CAMPAIGN_PERFORMANCE__SPEND, MART_CAMPAIGN_PERFORMANCE__IMPRESSIONS,
  MART_CAMPAIGN_PERFORMANCE__CLICKS, MART_CAMPAIGN_PERFORMANCE__LEADS, MART_CAMPAIGN_PERFORMANCE__CONVERTED_LEADS,
  MART_CAMPAIGN_PERFORMANCE__TRIALS, MART_CAMPAIGN_PERFORMANCE__PURCHASES, MART_CAMPAIGN_PERFORMANCE__REVENUE,
  MART_CAMPAIGN_PERFORMANCE__CTR, MART_CAMPAIGN_PERFORMANCE__CLICK_TO_LEAD_RATE,
  MART_CAMPAIGN_PERFORMANCE__LEAD_CONVERSION_RATE, MART_CAMPAIGN_PERFORMANCE__PURCHASE_RATE,
  MART_CAMPAIGN_PERFORMANCE__COST_PER_LEAD, MART_CAMPAIGN_PERFORMANCE__COST_PER_CONVERSION,
  MART_CAMPAIGN_PERFORMANCE__COST_PER_PURCHASE, MART_CAMPAIGN_PERFORMANCE__ROAS,
  MART_CAMPAIGN_PERFORMANCE__BUDGET_UTILIZATION,
  DIM_CAMPAIGN__CHANNEL, DIM_CAMPAIGN__OBJECTIVE, DIM_CAMPAIGN__BUDGET,
  FCT_DAILY_SPEND__SPEND_DAYS, FCT_DAILY_SPEND__SPEND, FCT_DAILY_SPEND__IMPRESSIONS, FCT_DAILY_SPEND__CLICKS,
  FCT_DAILY_SPEND__BUDGET_PRORATED, FCT_DAILY_SPEND__CHANNEL, FCT_DAILY_SPEND__OBJECTIVE,
  FCT_LEAD_CONVERSIONS__LEADS, FCT_LEAD_CONVERSIONS__CONVERTED_LEADS, FCT_LEAD_CONVERSIONS__TRIALS,
  FCT_LEAD_CONVERSIONS__PURCHASES, FCT_LEAD_CONVERSIONS__REVENUE, FCT_LEAD_CONVERSIONS__CHANNEL,
  FCT_LEAD_CONVERSIONS__OBJECTIVE))
ORDER BY DECODE(MODEL, 'MART_CAMPAIGN_PERFORMANCE', 1, 'DIM_CAMPAIGN', 2, 'FCT_DAILY_SPEND', 3, 4), COMPARISON, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 13. Channel roll-up of MART_CAMPAIGN_PERFORMANCE: the bases
--    Question: summed by channel, does the campaign table reproduce the channel funnel, and
--      the publisher's own numbers?
--    Why: this is how the Marketing Overview page will aggregate the table (SUM of additive
--      bases by CHANNEL). Spend and attributed revenue per channel also equal the publisher's
--      reference output to the cent: an outside check of the whole path from the published
--      files through RAW, STAGING and MART. GROUP BY ROLLUP adds the TOTAL row. A missing or
--      unexpected channel is its own FAIL row (FULL OUTER JOIN).
--    Expected: the 6 rows of [P3 kpi_channel_bases]; spend and revenue = [PUB] = [E01 31].
-- -----------------------------------------------------------------------------
WITH by_channel AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_TOTAL,
         COUNT(*) AS CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(REVENUE) AS REVENUE, SUM(BUDGET) AS BUDGET,
         SUM(SPEND_DAYS) AS SPEND_DAYS, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS,
         SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES
  FROM MART_CAMPAIGN_PERFORMANCE
  GROUP BY ROLLUP (CHANNEL)
),
expected (CHANNEL, CAMPAIGNS, SPEND, REVENUE, BUDGET, SPEND_DAYS, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS,
          TRIALS, PURCHASES) AS (
  SELECT * FROM VALUES   -- spend and revenue: [PUB]; all columns: [P3 kpi_channel_bases]
    ('affiliate',    24,  857835.07,  5610700.73, 1025491.41,  2150,  95314042, 2386856,  67849, 10352,  6020,  4332),
    ('paid_search',  24,  897091.53,  5439329.35, 1079299.66,  2307,  49837405, 1740314,  65268, 10019,  5815,  4204),
    ('paid_social',  24,  984731.88,  4690137.28, 1180823.70,  1906,  89520215, 1602785,  57619,  8648,  5002,  3646),
    ('display',      24,  955297.00,  3734117.43, 1138158.37,  2367, 146967688,  879874,  45149,  6744,  3873,  2871),
    ('video',        24,  828094.54,  2087554.22,  994869.02,  2510,  55205469,  492490,  25799,  3933,  2295,  1638),
    ('TOTAL',       120, 4523050.02, 21561839.01, 5418642.16, 11240, 436844819, 7102319, 261684, 39696, 23005, 16691)
)
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL, b.CAMPAIGNS, b.SPEND, b.REVENUE, b.BUDGET, b.SPEND_DAYS, b.IMPRESSIONS,
       b.CLICKS, b.LEADS, b.CONVERTED_LEADS, b.TRIALS, b.PURCHASES,
       IFF(b.SPEND = e.SPEND AND b.REVENUE = e.REVENUE, 'yes', 'NO') AS EQUALS_PUBLISHER,
       IFF(b.CAMPAIGNS = e.CAMPAIGNS AND b.SPEND = e.SPEND AND b.REVENUE = e.REVENUE AND b.BUDGET = e.BUDGET
           AND b.SPEND_DAYS = e.SPEND_DAYS AND b.IMPRESSIONS = e.IMPRESSIONS AND b.CLICKS = e.CLICKS AND b.LEADS = e.LEADS
           AND b.CONVERTED_LEADS = e.CONVERTED_LEADS AND b.TRIALS = e.TRIALS AND b.PURCHASES = e.PURCHASES,
           'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY b.IS_TOTAL, b.SPEND DESC;


-- -----------------------------------------------------------------------------
-- 14. Channel roll-up of MART_CAMPAIGN_PERFORMANCE: KPIs as ratios of sums
--    Question: computed the way Data Studio must compute them, SUM(numerator) /
--      SUM(denominator) of the base columns, do the channel KPIs equal the baseline?
--    Why: the stored ratio columns are valid only per campaign. Averaging them over a channel
--      gives a different, wrong number: the diagnostic column AVG_OF_CAMPAIGN_ROAS shows it
--      next to the correct ROAS (not part of STATUS). The TOTAL row carries the headline KPIs
--      (ROAS 4.767102, CPL 17.2844). Rounding as in [P3]: rates and ROAS 6 dp, cost 4 dp, rounded
--      once (the NUMBER(32,18) cast keeps the quotient at 18 dp before ROUND).
--    Expected: the 6 rows of [P3 kpi_channel_ratios].
-- -----------------------------------------------------------------------------
WITH by_channel AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_TOTAL,
         -- each dividend cast to NUMBER(32,18), so ROUND is the only rounding, as in [P3] and the model
         ROUND(SUM(CLICKS)::NUMBER(32,18)          / NULLIF(SUM(IMPRESSIONS), 0), 6)     AS CTR,
         ROUND(SUM(LEADS)::NUMBER(32,18)           / NULLIF(SUM(CLICKS), 0), 6)          AS CLICK_TO_LEAD_RATE,
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 6)           AS LEAD_CONVERSION_RATE,
         ROUND(SUM(PURCHASES)::NUMBER(32,18)       / NULLIF(SUM(LEADS), 0), 6)           AS PURCHASE_RATE,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(LEADS), 0), 4)           AS COST_PER_LEAD,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(CONVERTED_LEADS), 0), 4) AS COST_PER_CONVERSION,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(PURCHASES), 0), 4)       AS COST_PER_PURCHASE,
         ROUND(SUM(REVENUE)::NUMBER(32,18)         / NULLIF(SUM(SPEND), 0), 6)           AS ROAS,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(BUDGET), 0), 6)          AS BUDGET_UTILIZATION,
         ROUND(AVG(ROAS), 6)                                              AS AVG_OF_CAMPAIGN_ROAS   -- diagnostic: the wrong way
  FROM MART_CAMPAIGN_PERFORMANCE
  GROUP BY ROLLUP (CHANNEL)
),
expected (CHANNEL, CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_RATE, COST_PER_LEAD, COST_PER_CONVERSION,
          COST_PER_PURCHASE, ROAS, BUDGET_UTILIZATION) AS (
  SELECT * FROM VALUES   -- [P3 kpi_channel_ratios]
    ('affiliate',   0.025042, 0.028426, 0.152574, 0.063848, 12.6433,  82.8666, 198.0229, 6.540536, 0.836511),
    ('paid_search', 0.034920, 0.037504, 0.153506, 0.064411, 13.7447,  89.5390, 213.3900, 6.063294, 0.831179),
    ('paid_social', 0.017904, 0.035949, 0.150089, 0.063278, 17.0904, 113.8682, 270.0855, 4.762857, 0.833936),
    ('display',     0.005987, 0.051313, 0.149372, 0.063589, 21.1588, 141.6514, 332.7402, 3.908855, 0.839336),
    ('video',       0.008921, 0.052385, 0.152448, 0.063491, 32.0979, 210.5504, 505.5522, 2.520913, 0.832365),
    ('TOTAL',       0.016258, 0.036845, 0.151694, 0.063783, 17.2844, 113.9422, 270.9874, 4.767102, 0.834720)
)
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL, b.CTR, b.CLICK_TO_LEAD_RATE, b.LEAD_CONVERSION_RATE, b.PURCHASE_RATE,
       b.COST_PER_LEAD, b.COST_PER_CONVERSION, b.COST_PER_PURCHASE, b.ROAS, b.BUDGET_UTILIZATION, b.AVG_OF_CAMPAIGN_ROAS,
       IFF(b.CTR = e.CTR AND b.CLICK_TO_LEAD_RATE = e.CLICK_TO_LEAD_RATE AND b.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE
           AND b.PURCHASE_RATE = e.PURCHASE_RATE AND b.COST_PER_LEAD = e.COST_PER_LEAD
           AND b.COST_PER_CONVERSION = e.COST_PER_CONVERSION AND b.COST_PER_PURCHASE = e.COST_PER_PURCHASE
           AND b.ROAS = e.ROAS AND b.BUDGET_UTILIZATION = e.BUDGET_UTILIZATION, 'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY b.IS_TOTAL, b.ROAS DESC;


-- -----------------------------------------------------------------------------
-- 15. Ratio sanity at campaign grain
--    Question: are the stored campaign ratios defined everywhere and inside their logical
--      ranges?
--    Why: a rate above 1 or a negative cost means a numerator and denominator from different
--      grains. Every campaign has impressions, clicks, leads, conversions, purchases, spend
--      and a budget, so no NULLIF guard should fire here (check 2). Purchases are a subset of
--      conversions, and conversions of leads, so PURCHASE_RATE <= LEAD_CONVERSION_RATE and
--      COST_PER_LEAD <= COST_PER_CONVERSION <= COST_PER_PURCHASE (checks 8-9). The extremes
--      come from the baseline, rounded to the stored 6 dp (utilisation: 0.6987975601... ->
--      0.698798, 0.9868108976... -> 0.986811).
--    Expected: 120 campaigns; 0 for checks 2-9 [C; P3 campaign_spend_zero_conversions,
--      campaign_roas_lt1, flag_budget; E01 17]; extremes [P3 flag_leads_gt_clicks_campaign,
--      flag_budget, campaign_min_conversions].
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'campaigns evaluated' AS CHECK_NAME, COUNT(*) AS ACTUAL, 120 AS EXPECTED FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 2, 'campaigns with a NULL ratio (a zero denominator)',
                   COUNT_IF(CTR IS NULL OR CLICK_TO_LEAD_RATE IS NULL OR LEAD_CONVERSION_RATE IS NULL OR PURCHASE_RATE IS NULL
                            OR COST_PER_LEAD IS NULL OR COST_PER_CONVERSION IS NULL OR COST_PER_PURCHASE IS NULL
                            OR ROAS IS NULL OR BUDGET_UTILIZATION IS NULL), 0 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 3, 'rates outside 0..1 (CTR, CLICK_TO_LEAD, LEAD_CONVERSION, PURCHASE)',
                   COUNT_IF(CTR NOT BETWEEN 0 AND 1 OR CLICK_TO_LEAD_RATE NOT BETWEEN 0 AND 1
                            OR LEAD_CONVERSION_RATE NOT BETWEEN 0 AND 1 OR PURCHASE_RATE NOT BETWEEN 0 AND 1), 0
            FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 4, 'BUDGET_UTILIZATION outside 0..1 (over budget)', COUNT_IF(BUDGET_UTILIZATION NOT BETWEEN 0 AND 1), 0
            FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 5, 'ROAS <= 0', COUNT_IF(ROAS <= 0), 0 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 6, 'ROAS < 1 (attributed revenue below spend)', COUNT_IF(ROAS < 1), 0 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 7, 'cost per lead / conversion / purchase <= 0',
                   COUNT_IF(COST_PER_LEAD <= 0 OR COST_PER_CONVERSION <= 0 OR COST_PER_PURCHASE <= 0), 0
            FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 8, 'PURCHASE_RATE > LEAD_CONVERSION_RATE', COUNT_IF(PURCHASE_RATE > LEAD_CONVERSION_RATE), 0
            FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 9, 'cost per lead > per conversion, or per conversion > per purchase',
                   COUNT_IF(COST_PER_LEAD > COST_PER_CONVERSION OR COST_PER_CONVERSION > COST_PER_PURCHASE), 0
            FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 10, 'lowest CLICK_TO_LEAD_RATE', MIN(CLICK_TO_LEAD_RATE), 0.012878 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 11, 'highest CLICK_TO_LEAD_RATE', MAX(CLICK_TO_LEAD_RATE), 0.056555 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 12, 'lowest BUDGET_UTILIZATION', MIN(BUDGET_UTILIZATION), 0.698798 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 13, 'highest BUDGET_UTILIZATION', MAX(BUDGET_UTILIZATION), 0.986811 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 14, 'fewest CONVERTED_LEADS of a campaign (CMP0084)', MIN(CONVERTED_LEADS), 14 FROM MART_CAMPAIGN_PERFORMANCE
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 16. ROAS ranking: the 10 best and the 10 worst campaigns
--    Question: does the campaign-grain ROAS rank the campaigns exactly as the baseline does?
--    Why: "which campaigns acquire customers most cost-efficiently" will be read off this
--      ranking. Comparing rank by rank (FULL OUTER JOIN on ranking and rank) checks the campaign,
--      its name and its stored ROAS at once. ROW_NUMBER breaks ties by CAMPAIGN_ID; there are
--      no ties at 6 dp in either list.
--    Expected: [P3 campaign_top10_roas, campaign_bottom10_roas].
-- -----------------------------------------------------------------------------
WITH ranked AS (
  SELECT 'top 10' AS RANKING, ROW_NUMBER() OVER (ORDER BY ROAS DESC, CAMPAIGN_ID) AS RANK_IN_LIST,
         CAMPAIGN_ID, CAMPAIGN_NAME, ROAS
  FROM MART_CAMPAIGN_PERFORMANCE
  QUALIFY ROW_NUMBER() OVER (ORDER BY ROAS DESC, CAMPAIGN_ID) <= 10
  UNION ALL
  SELECT 'bottom 10', ROW_NUMBER() OVER (ORDER BY ROAS ASC, CAMPAIGN_ID), CAMPAIGN_ID, CAMPAIGN_NAME, ROAS
  FROM MART_CAMPAIGN_PERFORMANCE
  QUALIFY ROW_NUMBER() OVER (ORDER BY ROAS ASC, CAMPAIGN_ID) <= 10
),
expected (RANKING, RANK_IN_LIST, CAMPAIGN_ID, CAMPAIGN_NAME, ROAS) AS (
  SELECT * FROM VALUES
    ('top 10',     1, 'CMP0080', 'Affiliate 2024 080',   13.013216),
    ('top 10',     2, 'CMP0070', 'Affiliate 2024 070',   12.609300),
    ('top 10',     3, 'CMP0040', 'Affiliate 2023 040',   12.274784),
    ('top 10',     4, 'CMP0035', 'Affiliate 2025 035',   12.007766),
    ('top 10',     5, 'CMP0045', 'Affiliate 2024 045',   11.390125),
    ('top 10',     6, 'CMP0095', 'Affiliate 2025 095',   11.375832),
    ('top 10',     7, 'CMP0005', 'Affiliate 2024 005',   11.133811),
    ('top 10',     8, 'CMP0050', 'Affiliate 2023 050',   11.042774),
    ('top 10',     9, 'CMP0110', 'Affiliate 2025 110',   10.879181),
    ('top 10',    10, 'CMP0086', 'Paid Search 2023 086', 10.849844),
    ('bottom 10',  1, 'CMP0084', 'Video 2023 084',        1.823364),
    ('bottom 10',  2, 'CMP0034', 'Video 2024 034',        1.978327),
    ('bottom 10',  3, 'CMP0039', 'Video 2025 039',        2.131284),
    ('bottom 10',  4, 'CMP0119', 'Video 2025 119',        2.173423),
    ('bottom 10',  5, 'CMP0018', 'Display 2023 018',      2.174672),
    ('bottom 10',  6, 'CMP0074', 'Video 2023 074',        2.177704),
    ('bottom 10',  7, 'CMP0009', 'Video 2024 009',        2.202279),
    ('bottom 10',  8, 'CMP0079', 'Video 2024 079',        2.213323),
    ('bottom 10',  9, 'CMP0099', 'Video 2023 099',        2.267776),
    ('bottom 10', 10, 'CMP0064', 'Video 2024 064',        2.323173)
)
SELECT COALESCE(r.RANKING, e.RANKING) AS RANKING, COALESCE(r.RANK_IN_LIST, e.RANK_IN_LIST) AS RANK_IN_LIST,
       r.CAMPAIGN_ID, r.CAMPAIGN_NAME, r.ROAS, e.CAMPAIGN_ID AS EXPECTED_CAMPAIGN, e.ROAS AS EXPECTED_ROAS,
       IFF(r.CAMPAIGN_ID = e.CAMPAIGN_ID AND r.CAMPAIGN_NAME = e.CAMPAIGN_NAME AND r.ROAS = e.ROAS, 'PASS', 'FAIL') AS STATUS
FROM ranked r
FULL OUTER JOIN expected e ON e.RANKING = r.RANKING AND e.RANK_IN_LIST = r.RANK_IN_LIST
ORDER BY RANKING DESC, RANK_IN_LIST;


-- -----------------------------------------------------------------------------
-- 17. Activity months vs lead-cohort months, all 36 months
--    Question: do the month columns carry both time bases correctly: spend and conversions by
--      the month they happened (activity), and conversions by the month their lead was created
--      (cohort)?
--    Why: architecture decision 7. 34% of conversions land in a later month than their lead,
--      so the two bases differ in every month (2025-12: 61 activity conversions, but 11 of
--      that month's 65 leads converted). Each measure is aggregated to the month ON ITS OWN
--      (spend by SPEND_MONTH, leads and cohort conversions by CREATED_MONTH, activity
--      conversions by CONVERTED_MONTH), and only then joined 1:1 to the 36-month spine from
--      DIM_DATE: the same aggregate-first rule as MART_CAMPAIGN_PERFORMANCE, on the month
--      grain. A month missing on either side is its own FAIL row (FULL OUTER JOIN).
--    Expected: all 36 rows x 6 bases of [P3 monthly_activity_vs_cohort] (DuckDB and Python
--      Decimal agree on all 216 values; the 12 edge months also equal [E01 32]).
-- -----------------------------------------------------------------------------
WITH months AS (                     -- the month spine: 36 rows
  SELECT DISTINCT MONTH_START FROM DIM_DATE
),
spend_by_month AS (                  -- activity: spend by the month it was spent
  SELECT SPEND_MONTH AS MONTH_START, SUM(SPEND) AS SPEND FROM FCT_DAILY_SPEND GROUP BY SPEND_MONTH
),
cohort_by_month AS (                 -- cohort: leads, and what those leads later did, by CREATED_MONTH
  SELECT CREATED_MONTH AS MONTH_START, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS COHORT_CONVERSIONS,
         SUM(REVENUE) AS COHORT_REVENUE
  FROM FCT_LEAD_CONVERSIONS GROUP BY CREATED_MONTH
),
activity_by_month AS (               -- activity: conversions by the month they happened
  SELECT CONVERTED_MONTH AS MONTH_START, SUM(IS_CONVERTED) AS ACTIVITY_CONVERSIONS, SUM(REVENUE) AS ACTIVITY_REVENUE
  FROM FCT_LEAD_CONVERSIONS WHERE IS_CONVERTED = 1 GROUP BY CONVERTED_MONTH
),
actual AS (                          -- every input has one row per month now: 1:1 joins to the spine
  SELECT m.MONTH_START, COALESCE(s.SPEND, 0) AS SPEND, COALESCE(c.LEADS, 0) AS LEADS,
         COALESCE(a.ACTIVITY_CONVERSIONS, 0) AS ACTIVITY_CONVERSIONS, COALESCE(c.COHORT_CONVERSIONS, 0) AS COHORT_CONVERSIONS,
         COALESCE(a.ACTIVITY_REVENUE, 0) AS ACTIVITY_REVENUE, COALESCE(c.COHORT_REVENUE, 0) AS COHORT_REVENUE
  FROM months m
  LEFT JOIN spend_by_month    s ON s.MONTH_START = m.MONTH_START
  LEFT JOIN cohort_by_month   c ON c.MONTH_START = m.MONTH_START
  LEFT JOIN activity_by_month a ON a.MONTH_START = m.MONTH_START
),
expected (MONTH_START, SPEND, LEADS, ACTIVITY_CONVERSIONS, COHORT_CONVERSIONS, ACTIVITY_REVENUE, COHORT_REVENUE) AS (
  SELECT * FROM VALUES   -- [P3 monthly_activity_vs_cohort]
    ('2023-01-01'::DATE, 23686.55, 1325, 110, 212, 52800.58, 104789.28),
    ('2023-02-01'::DATE, 49461.61, 2825, 325, 427, 170806.55, 203501.92),
    ('2023-03-01'::DATE, 104283.65, 6229, 798, 914, 393351.94, 459636.12),
    ('2023-04-01'::DATE, 104393.90, 5748, 902, 880, 474970.42, 467059.31),
    ('2023-05-01'::DATE, 97734.10, 5188, 811, 771, 435288.12, 433096.71),
    ('2023-06-01'::DATE, 123064.68, 7491, 963, 1137, 569578.22, 657294.35),
    ('2023-07-01'::DATE, 116810.98, 7779, 1273, 1220, 699206.04, 688314.91),
    ('2023-08-01'::DATE, 134065.09, 9024, 1221, 1377, 672633.67, 757947.97),
    ('2023-09-01'::DATE, 155294.61, 10771, 1590, 1604, 884815.77, 873286.79),
    ('2023-10-01'::DATE, 171832.62, 10930, 1654, 1648, 939852.38, 982891.87),
    ('2023-11-01'::DATE, 191171.25, 10526, 1582, 1575, 904954.17, 896561.10),
    ('2023-12-01'::DATE, 186463.37, 9713, 1550, 1471, 877224.49, 814229.75),
    ('2024-01-01'::DATE, 122943.61, 6493, 1158, 975, 618809.35, 505522.79),
    ('2024-02-01'::DATE, 100601.92, 5638, 794, 882, 441376.15, 490071.45),
    ('2024-03-01'::DATE, 130497.60, 7576, 1063, 1172, 568388.08, 639937.50),
    ('2024-04-01'::DATE, 196892.88, 10413, 1424, 1588, 795905.02, 826515.58),
    ('2024-05-01'::DATE, 177398.24, 8898, 1550, 1332, 813289.19, 759968.60),
    ('2024-06-01'::DATE, 129762.16, 5954, 1035, 918, 581296.94, 491639.76),
    ('2024-07-01'::DATE, 115762.43, 5895, 861, 879, 468529.67, 469706.98),
    ('2024-08-01'::DATE, 185052.08, 10718, 1316, 1607, 687143.69, 845201.71),
    ('2024-09-01'::DATE, 205363.34, 11825, 1780, 1779, 950923.18, 942884.99),
    ('2024-10-01'::DATE, 219378.73, 11683, 1830, 1771, 961348.25, 938239.29),
    ('2024-11-01'::DATE, 181790.58, 10557, 1579, 1588, 857423.40, 865052.92),
    ('2024-12-01'::DATE, 205754.77, 11721, 1758, 1831, 933214.90, 980609.89),
    ('2025-01-01'::DATE, 189821.49, 10136, 1699, 1557, 926132.23, 867523.60),
    ('2025-02-01'::DATE, 97550.77, 6308, 1116, 930, 619062.19, 501984.76),
    ('2025-03-01'::DATE, 103654.48, 7226, 1061, 1099, 598344.60, 621952.09),
    ('2025-04-01'::DATE, 95842.28, 6504, 969, 1036, 544558.36, 577892.10),
    ('2025-05-01'::DATE, 109131.26, 7506, 1183, 1113, 629458.15, 565975.71),
    ('2025-06-01'::DATE, 94604.52, 6371, 971, 996, 515898.62, 554537.00),
    ('2025-07-01'::DATE, 132922.32, 7710, 1101, 1156, 601132.60, 603557.74),
    ('2025-08-01'::DATE, 138359.57, 7339, 1190, 1109, 596182.42, 586219.70),
    ('2025-09-01'::DATE, 65610.05, 3680, 700, 513, 381379.89, 265118.01),
    ('2025-10-01'::DATE, 48774.54, 2826, 462, 445, 228041.53, 222570.47),
    ('2025-11-01'::DATE, 16510.95, 1093, 256, 173, 137433.25, 96402.96),
    ('2025-12-01'::DATE, 807.04, 65, 61, 11, 31085.00, 4143.33)
)
SELECT TO_CHAR(COALESCE(a.MONTH_START, e.MONTH_START), 'YYYY-MM') AS MONTH, a.SPEND, a.LEADS, a.ACTIVITY_CONVERSIONS,
       a.COHORT_CONVERSIONS, a.ACTIVITY_REVENUE, a.COHORT_REVENUE,
       IFF(a.SPEND = e.SPEND AND a.LEADS = e.LEADS AND a.ACTIVITY_CONVERSIONS = e.ACTIVITY_CONVERSIONS
           AND a.COHORT_CONVERSIONS = e.COHORT_CONVERSIONS AND a.ACTIVITY_REVENUE = e.ACTIVITY_REVENUE
           AND a.COHORT_REVENUE = e.COHORT_REVENUE, 'PASS', 'FAIL') AS STATUS
FROM actual a
FULL OUTER JOIN expected e ON e.MONTH_START = a.MONTH_START
ORDER BY 1;
