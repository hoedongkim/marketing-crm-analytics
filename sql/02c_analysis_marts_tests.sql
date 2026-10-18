-- =============================================================================
-- Phase 4 / 02c tests: read-only tests of the analysis marts
-- -----------------------------------------------------------------------------
-- Purpose
--   Prove that the five analysis marts built by 02c_analysis_marts.sql are correct at their
--   grain, never double count, and keep the plan's guard rails visible in their results:
--     blocks 0-3    contract (names, order, types, comments), row counts and grain keys, NOT NULL
--     blocks 4-6    FCT_CAMPAIGN_DAILY_ACTIVITY: the spine, every total (all five marts, against
--                   the known totals and the Phase 3 tables), every campaign = MART_CAMPAIGN_PERFORMANCE
--     blocks 7-8    the two monthly marts, all 180 channel-months, against independent paths
--     blocks 9-12   activity basis vs lead-cohort basis: 36 months, how often they differ, the
--                   cross-month share (13,675 = 34.45%), cohort semantics, lag by channel
--     block 13      volume by year next to the number of active campaigns (2025)
--     blocks 14-17  MART_CHANNEL_PERFORMANCE: bases, ratios, shares, Wilson interval, sanity
--     blocks 18-19  MART_LEAD_QUALITY: all 50 rows, roll-ups to segment, band and channel
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02c_analysis_marts.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/02c_analysis_marts_tests.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 24 statements,
--   under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02c_analysis_marts_tests.txt.
-- Role
--   CRM_TRANSFORMER, which owns the MART tables and can read the STAGING views.
-- Reading the results
--   STATUS = PASS means the mart reproduced the expected value exactly. The one tolerance is
--   the contract sum-back rule of BUDGET_PRORATED, "within 0.01 per campaign" (block 6); its
--   table total is checked exactly (block 5).
--   No vacuous passes, no tautologies (the conventions of 02b_core_models_tests.sql):
--     - Every comparison of groups with an expected list (tables, columns, campaigns, months,
--       channel-months, channels, bands, segments, years) is a FULL OUTER JOIN, so a missing
--       or an unexpected group is its own FAIL row or lowers the matching count.
--     - Zero counts sit next to the number of rows they were evaluated on, or the same run
--       checks that number (blocks 2, 4, 10, 11, 17).
--     - No mart is compared with itself or with the expression that built it. Expected values
--       come from the sources below. Where a mart is compared with another table, it is a
--       different path: the daily activity fact (built from FCT_DAILY_SPEND and
--       FCT_LEAD_CONVERSIONS) against MART_CAMPAIGN_PERFORMANCE (built from STAGING); the
--       activity mart (built from the daily spine) against the Phase 3 facts grouped by their
--       own month columns and campaign windows from DIM_CAMPAIGN; the cohort mart (built from
--       FCT_LEAD_CONVERSIONS) against STAGING; the channel mart (built from the Phase 3 facts)
--       against the roll-up of MART_CAMPAIGN_PERFORMANCE and against [P3] / [PUB].
--     - Ratios divided in Snowflake by a test cast their dividend to NUMBER(32,18), like the
--       models, so ROUND is the only rounding; they are compared with values divided and
--       rounded outside Snowflake ([P3], [D]).
--   Some blocks compute a wrong number on purpose, labelled as such: the activity-basis
--   "conversions / leads of the same month" (block 10) is shown so that it is never charted.
--   (Totals of mixed measures share one NUMBER column, so counts print as e.g. 39696.000000.)
-- Where the expected values come from (never from the object under test)
--   [C]    The Phase 4 analysis mart contract, as written in the header of 02c_analysis_marts.sql:
--          table and column names, order and types; grains (36 months x 5 channels = 180,
--          5 channels x 10 bands = 50); the spine START_DATE .. END_DATE + 21; the band edges and
--          their segments (Low 1-40, Medium 41-70, High 71-100); AS_OF_DATE 2025-12-31 with the
--          21-day maturity window (every lead mature).
--   [E01]  docs/evidence/01_data_profiling.txt, the Phase 2 profile of clean RAW in Snowflake
--          (statement number in brackets): [18] the ten score bands, [22] rows per year of
--          created_at and converted_at, [23] window days, spend rows without leads, [24] the
--          4,716 conversions after their campaign ended, [25] the lag by channel, [27] campaigns
--          started and active per year, [28] active campaigns per month.
--   [P1]   The local profile "table integrity" (2026-10-13): sum of lead_score 13,233,637.
--   [P3]   The local profile "KPI reconciliation" (2026-10-13, DuckDB and Python Decimal, before
--          Snowflake existed), the same values that 02b_core_models_tests.sql carries inline:
--          kpi_channel_bases (block 13 there), kpi_channel_ratios (block 14), lead_score_segments
--          (block 11) and monthly_activity_vs_cohort (block 17, 36 months).
--   [PL]   The local pre-load profiling quoted in docs/architecture.md, decision 7: 13,675
--          conversions (34.45%) land in a later calendar month than their lead. No Snowflake
--          evidence printed it before this file (block 11).
--   [D]    Python 3 csv + decimal (ROUND_HALF_UP, 60-digit precision), 2026-10-14, outside
--          Snowflake, from data/raw/source/campaigns.csv, daily_spend.csv, leads.csv and
--          conversions.csv: the spine (13,760 rows, 0 days clipped, last day 2025-12-23; 1,746
--          post-flight and 11,209 total rows with a conversion); BUDGET_PRORATED by year
--          (shares rounded once to 6 dp); spend and revenue by year; channel-month counts (159
--          with spend, 161 with conversions, 2 with conversions but no campaign in flight, 159
--          where the two bases differ, 19 with no conversion on either); 36 months whose two
--          bases differ; the naive and cohort monthly ratio extremes; same-month 26,021 and
--          later-month 13,675 conversions, by channel; the summed lag 417,029; per channel CPC,
--          CPM, the three shares and the Wilson bounds (z = 1.959964, exact to 60 digits, and
--          in float: the same 6-dp values, none within 4 x 10^-8 of a rounding midpoint); all
--          50 rows of MART_LEAD_QUALITY and the band roll-up.
--   [PUB]  The publisher reference output (spend and attributed revenue by channel), reproduced
--          to the cent in [P3] and [E01 31].
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where   [6] 1 contract   [7] 2 row counts and keys   [8] 3 not null
--   [9] 4 daily spine   [10] 5 control totals   [11] 6 daily activity vs campaign table
--   [12] 7 monthly activity, 180 rows   [13] 8 monthly cohort, 180 rows   [14] 9 36 months, both bases
--   [15] 10 activity vs cohort   [16] 11 cohort semantics   [17] 12 cohort by channel
--   [18] 13 years and active campaigns   [19] 14 channel bases   [20] 15 channel ratios
--   [21] 16 channel interval and shares   [22] 17 channel sanity   [23] 18 lead quality, 50 rows
--   [24] 19 lead quality roll-ups
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
-- 1. Contract: the five analysis marts exist as tables with the contract columns, in contract
--    order, with contract types and comments; MART holds nothing else
--    Question: can the Phase 4 analyses, Data Studio and the dbt port rely on these names and
--      types?
--    Why: Data Studio binds fields by column name and the Sheets snapshot keeps the names. A
--      renamed column, a FLOAT where NUMBER(18,6) was promised, a lower-case or non-ASCII name,
--      or a column without its comment fails here. The Phase 3 core tables and CONNECTION_TEST
--      must still exist (their columns are tested by 02b_core_models_tests.sql block 1), and so
--      must MART_CONVERSION_FUNNEL since Phase 6 (dbt only; its columns are tested by dbt); any
--      other object in MART is its own FAIL row.
--    Expected [C]: 15 / 12 / 11 / 27 / 12 columns, 0 problems, a table comment on every table.
-- -----------------------------------------------------------------------------
WITH contract (TABLE_NAME, ORDINAL, COLUMN_NAME, DATA_TYPE) AS (   -- [C]
  SELECT * FROM VALUES
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 1, 'CAMPAIGN_ID', 'TEXT'),         ('FCT_CAMPAIGN_DAILY_ACTIVITY', 2, 'ACTIVITY_DATE', 'DATE'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 3, 'ACTIVITY_MONTH', 'DATE'),      ('FCT_CAMPAIGN_DAILY_ACTIVITY', 4, 'CHANNEL', 'TEXT'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 5, 'OBJECTIVE', 'TEXT'),           ('FCT_CAMPAIGN_DAILY_ACTIVITY', 6, 'IS_IN_FLIGHT', 'NUMBER(1,0)'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 7, 'IMPRESSIONS', 'NUMBER(38,0)'), ('FCT_CAMPAIGN_DAILY_ACTIVITY', 8, 'CLICKS', 'NUMBER(38,0)'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 9, 'SPEND', 'NUMBER(18,2)'),       ('FCT_CAMPAIGN_DAILY_ACTIVITY', 10, 'BUDGET_PRORATED', 'NUMBER(18,6)'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 11, 'LEADS', 'NUMBER(38,0)'),      ('FCT_CAMPAIGN_DAILY_ACTIVITY', 12, 'CONVERSIONS', 'NUMBER(38,0)'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 13, 'TRIALS', 'NUMBER(38,0)'),     ('FCT_CAMPAIGN_DAILY_ACTIVITY', 14, 'PURCHASES', 'NUMBER(38,0)'),
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 15, 'REVENUE', 'NUMBER(18,2)'),
    ('MART_MONTHLY_MARKETING', 1, 'MONTH_START', 'DATE'),              ('MART_MONTHLY_MARKETING', 2, 'CHANNEL', 'TEXT'),
    ('MART_MONTHLY_MARKETING', 3, 'ACTIVE_CAMPAIGNS', 'NUMBER(38,0)'), ('MART_MONTHLY_MARKETING', 4, 'SPEND', 'NUMBER(18,2)'),
    ('MART_MONTHLY_MARKETING', 5, 'IMPRESSIONS', 'NUMBER(38,0)'),      ('MART_MONTHLY_MARKETING', 6, 'CLICKS', 'NUMBER(38,0)'),
    ('MART_MONTHLY_MARKETING', 7, 'LEADS', 'NUMBER(38,0)'),            ('MART_MONTHLY_MARKETING', 8, 'CONVERSIONS', 'NUMBER(38,0)'),
    ('MART_MONTHLY_MARKETING', 9, 'TRIALS', 'NUMBER(38,0)'),           ('MART_MONTHLY_MARKETING', 10, 'PURCHASES', 'NUMBER(38,0)'),
    ('MART_MONTHLY_MARKETING', 11, 'REVENUE', 'NUMBER(18,2)'),         ('MART_MONTHLY_MARKETING', 12, 'BUDGET_PRORATED', 'NUMBER(18,6)'),
    ('MART_MONTHLY_COHORT', 1, 'COHORT_MONTH', 'DATE'),                ('MART_MONTHLY_COHORT', 2, 'CHANNEL', 'TEXT'),
    ('MART_MONTHLY_COHORT', 3, 'LEADS', 'NUMBER(38,0)'),               ('MART_MONTHLY_COHORT', 4, 'CONVERTED_LEADS', 'NUMBER(38,0)'),
    ('MART_MONTHLY_COHORT', 5, 'TRIALS', 'NUMBER(38,0)'),              ('MART_MONTHLY_COHORT', 6, 'PURCHASES', 'NUMBER(38,0)'),
    ('MART_MONTHLY_COHORT', 7, 'REVENUE', 'NUMBER(18,2)'),             ('MART_MONTHLY_COHORT', 8, 'CONVERTED_SAME_MONTH', 'NUMBER(38,0)'),
    ('MART_MONTHLY_COHORT', 9, 'CONVERTED_LATER_MONTH', 'NUMBER(38,0)'), ('MART_MONTHLY_COHORT', 10, 'SUM_DAYS_TO_CONVERT', 'NUMBER(38,0)'),
    ('MART_MONTHLY_COHORT', 11, 'MATURE_LEADS', 'NUMBER(38,0)'),
    ('MART_CHANNEL_PERFORMANCE', 1, 'CHANNEL', 'TEXT'),                ('MART_CHANNEL_PERFORMANCE', 2, 'CAMPAIGNS', 'NUMBER(38,0)'),
    ('MART_CHANNEL_PERFORMANCE', 3, 'BUDGET', 'NUMBER(18,2)'),         ('MART_CHANNEL_PERFORMANCE', 4, 'SPEND', 'NUMBER(18,2)'),
    ('MART_CHANNEL_PERFORMANCE', 5, 'IMPRESSIONS', 'NUMBER(38,0)'),    ('MART_CHANNEL_PERFORMANCE', 6, 'CLICKS', 'NUMBER(38,0)'),
    ('MART_CHANNEL_PERFORMANCE', 7, 'LEADS', 'NUMBER(38,0)'),          ('MART_CHANNEL_PERFORMANCE', 8, 'CONVERTED_LEADS', 'NUMBER(38,0)'),
    ('MART_CHANNEL_PERFORMANCE', 9, 'TRIALS', 'NUMBER(38,0)'),         ('MART_CHANNEL_PERFORMANCE', 10, 'PURCHASES', 'NUMBER(38,0)'),
    ('MART_CHANNEL_PERFORMANCE', 11, 'REVENUE', 'NUMBER(18,2)'),       ('MART_CHANNEL_PERFORMANCE', 12, 'CTR', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 13, 'CLICK_TO_LEAD_RATE', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 14, 'LEAD_CONVERSION_RATE', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 15, 'PURCHASE_RATE', 'NUMBER(18,6)'), ('MART_CHANNEL_PERFORMANCE', 16, 'COST_PER_LEAD', 'NUMBER(18,4)'),
    ('MART_CHANNEL_PERFORMANCE', 17, 'COST_PER_CONVERSION', 'NUMBER(18,4)'),
    ('MART_CHANNEL_PERFORMANCE', 18, 'COST_PER_PURCHASE', 'NUMBER(18,4)'),
    ('MART_CHANNEL_PERFORMANCE', 19, 'ROAS', 'NUMBER(18,6)'),          ('MART_CHANNEL_PERFORMANCE', 20, 'BUDGET_UTILIZATION', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 21, 'CPC', 'NUMBER(18,4)'),           ('MART_CHANNEL_PERFORMANCE', 22, 'CPM', 'NUMBER(18,4)'),
    ('MART_CHANNEL_PERFORMANCE', 23, 'SPEND_SHARE', 'NUMBER(18,6)'),   ('MART_CHANNEL_PERFORMANCE', 24, 'LEADS_SHARE', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 25, 'REVENUE_SHARE', 'NUMBER(18,6)'), ('MART_CHANNEL_PERFORMANCE', 26, 'LCR_CI_LOW', 'NUMBER(18,6)'),
    ('MART_CHANNEL_PERFORMANCE', 27, 'LCR_CI_HIGH', 'NUMBER(18,6)'),
    ('MART_LEAD_QUALITY', 1, 'CHANNEL', 'TEXT'),                       ('MART_LEAD_QUALITY', 2, 'SCORE_BAND', 'TEXT'),
    ('MART_LEAD_QUALITY', 3, 'SCORE_BAND_MIN', 'NUMBER(3,0)'),         ('MART_LEAD_QUALITY', 4, 'SCORE_BAND_MAX', 'NUMBER(3,0)'),
    ('MART_LEAD_QUALITY', 5, 'LEAD_SCORE_SEGMENT', 'TEXT'),            ('MART_LEAD_QUALITY', 6, 'LEADS', 'NUMBER(38,0)'),
    ('MART_LEAD_QUALITY', 7, 'SUM_LEAD_SCORE', 'NUMBER(38,0)'),        ('MART_LEAD_QUALITY', 8, 'CONVERTED_LEADS', 'NUMBER(38,0)'),
    ('MART_LEAD_QUALITY', 9, 'TRIALS', 'NUMBER(38,0)'),                ('MART_LEAD_QUALITY', 10, 'PURCHASES', 'NUMBER(38,0)'),
    ('MART_LEAD_QUALITY', 11, 'REVENUE', 'NUMBER(18,2)'),              ('MART_LEAD_QUALITY', 12, 'SUM_DAYS_TO_CONVERT', 'NUMBER(38,0)')
),
expected_objects (TABLE_NAME, ORD, HAS_CONTRACT) AS (   -- [C]; the Phase 3 core and CONNECTION_TEST are checked by 02b
  SELECT * FROM VALUES
    ('FCT_CAMPAIGN_DAILY_ACTIVITY', 1, TRUE), ('MART_MONTHLY_MARKETING', 2, TRUE), ('MART_MONTHLY_COHORT', 3, TRUE),
    ('MART_CHANNEL_PERFORMANCE', 4, TRUE), ('MART_LEAD_QUALITY', 5, TRUE),
    ('DIM_DATE', 6, FALSE), ('DIM_CAMPAIGN', 7, FALSE), ('FCT_DAILY_SPEND', 8, FALSE), ('FCT_LEAD_CONVERSIONS', 9, FALSE),
    ('MART_CAMPAIGN_PERFORMANCE', 10, FALSE), ('CONNECTION_TEST', 11, FALSE),
    ('MART_CONVERSION_FUNNEL', 12, FALSE)   -- Phase 6, dbt only: columns tested by dbt (_marts.yml)
),
objects AS (
  SELECT TABLE_NAME, TABLE_TYPE, COMMENT FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'MART'
),
actual AS (   -- the columns of the five analysis marts
  SELECT TABLE_NAME, ORDINAL_POSITION AS ORDINAL, COLUMN_NAME, COMMENT,
         IFF(DATA_TYPE = 'NUMBER', 'NUMBER(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')', DATA_TYPE) AS DATA_TYPE
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'MART'
    AND TABLE_NAME IN ('FCT_CAMPAIGN_DAILY_ACTIVITY', 'MART_MONTHLY_MARKETING', 'MART_MONTHLY_COHORT',
                       'MART_CHANNEL_PERFORMANCE', 'MART_LEAD_QUALITY')
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
       IFF(e.HAS_CONTRACT, 'Phase 4 contract', IFF(e.TABLE_NAME IS NOT NULL, 'exists (02b tests)', 'UNEXPECTED')) AS CHECKED_AS,
       COALESCE(p.CONTRACT_COLUMNS, 0) AS CONTRACT_COLUMNS, COALESCE(p.ACTUAL_COLUMNS, 0) AS ACTUAL_COLUMNS,
       COALESCE(p.PROBLEMS, 0) AS PROBLEMS, COALESCE(p.PROBLEM_LIST, '') AS PROBLEM_LIST,
       NULLIF(TRIM(o.COMMENT), '') IS NOT NULL AS HAS_TABLE_COMMENT,
       IFF(e.TABLE_NAME IS NOT NULL AND o.TABLE_TYPE = 'BASE TABLE' AND NULLIF(TRIM(o.COMMENT), '') IS NOT NULL
           AND (NOT e.HAS_CONTRACT OR (p.CONTRACT_COLUMNS > 0 AND p.PROBLEMS = 0)), 'PASS', 'FAIL') AS STATUS
FROM expected_objects e
FULL OUTER JOIN objects   o ON o.TABLE_NAME = e.TABLE_NAME
FULL OUTER JOIN per_table p ON p.TABLE_NAME = COALESCE(e.TABLE_NAME, o.TABLE_NAME)
ORDER BY COALESCE(e.ORD, 99), 1;


-- -----------------------------------------------------------------------------
-- 2. Row counts and grain keys: exactly one row per member of the grain
--    Question: did a spine or a join add rows (fan-out) or lose rows, and is the grain key
--      unique and never NULL?
--    Why: Snowflake does not enforce keys. A duplicated campaign-day would double its spend, a
--      duplicated channel-month its whole month. Each expected row count is also derived from
--      the Phase 3 dimensions (ROWS_FROM_DIMENSIONS), so the spine size is checked twice: the
--      daily spine = SUM(CAMPAIGN_DAYS + 21) over DIM_CAMPAIGN = 11,240 + 120 x 21 (unclipped:
--      no END_DATE + 21 passes 2025-12-31, block 4); the monthly marts = months of DIM_DATE x
--      channels of DIM_CAMPAIGN; the lead quality mart = channels x 10 bands.
--    Expected: 13,760 [D] / 180 / 180 / 5 / 50 [C]; 0 NULL keys, 0 duplicated keys.
-- -----------------------------------------------------------------------------
WITH duplicated_keys AS (   -- one row per grain key value that occurs more than once
            SELECT 1 AS ORD FROM FCT_CAMPAIGN_DAILY_ACTIVITY GROUP BY CAMPAIGN_ID, ACTIVITY_DATE HAVING COUNT(*) > 1
  UNION ALL SELECT 2        FROM MART_MONTHLY_MARKETING      GROUP BY MONTH_START, CHANNEL     HAVING COUNT(*) > 1
  UNION ALL SELECT 3        FROM MART_MONTHLY_COHORT         GROUP BY COHORT_MONTH, CHANNEL    HAVING COUNT(*) > 1
  UNION ALL SELECT 4        FROM MART_CHANNEL_PERFORMANCE    GROUP BY CHANNEL                  HAVING COUNT(*) > 1
  UNION ALL SELECT 5        FROM MART_LEAD_QUALITY           GROUP BY CHANNEL, SCORE_BAND      HAVING COUNT(*) > 1
),
dims AS (
  SELECT (SELECT SUM(CAMPAIGN_DAYS + 21) FROM DIM_CAMPAIGN)  AS SPINE_ROWS,
         (SELECT COUNT(DISTINCT MONTH_START) FROM DIM_DATE)  AS MONTHS,
         (SELECT COUNT(DISTINCT CHANNEL) FROM DIM_CAMPAIGN)  AS CHANNELS
),
grain AS (
            SELECT 1 AS ORD, 'FCT_CAMPAIGN_DAILY_ACTIVITY' AS TABLE_NAME, 'CAMPAIGN_ID + ACTIVITY_DATE' AS GRAIN_KEY,
                   COUNT(*) AS ROW_COUNT, COUNT_IF(CAMPAIGN_ID IS NULL OR ACTIVITY_DATE IS NULL) AS NULL_KEYS,
                   (SELECT SPINE_ROWS FROM dims) AS ROWS_FROM_DIMENSIONS, 13760 AS EXPECTED_ROWS
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 2, 'MART_MONTHLY_MARKETING', 'MONTH_START + CHANNEL', COUNT(*),
                   COUNT_IF(MONTH_START IS NULL OR CHANNEL IS NULL), (SELECT MONTHS * CHANNELS FROM dims), 180
            FROM MART_MONTHLY_MARKETING
  UNION ALL SELECT 3, 'MART_MONTHLY_COHORT', 'COHORT_MONTH + CHANNEL', COUNT(*),
                   COUNT_IF(COHORT_MONTH IS NULL OR CHANNEL IS NULL), (SELECT MONTHS * CHANNELS FROM dims), 180
            FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 4, 'MART_CHANNEL_PERFORMANCE', 'CHANNEL', COUNT(*), COUNT_IF(CHANNEL IS NULL),
                   (SELECT CHANNELS FROM dims), 5
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 5, 'MART_LEAD_QUALITY', 'CHANNEL + SCORE_BAND', COUNT(*), COUNT_IF(CHANNEL IS NULL OR SCORE_BAND IS NULL),
                   (SELECT CHANNELS * 10 FROM dims), 50
            FROM MART_LEAD_QUALITY
)
SELECT g.TABLE_NAME, g.GRAIN_KEY, g.ROW_COUNT, g.ROWS_FROM_DIMENSIONS, g.EXPECTED_ROWS, g.NULL_KEYS,
       COUNT(d.ORD) AS DUPLICATED_KEYS,
       IFF(g.ROW_COUNT = g.EXPECTED_ROWS AND g.ROWS_FROM_DIMENSIONS = g.EXPECTED_ROWS AND g.NULL_KEYS = 0
           AND COUNT(d.ORD) = 0, 'PASS', 'FAIL') AS STATUS
FROM grain g
LEFT JOIN duplicated_keys d ON d.ORD = g.ORD
GROUP BY g.ORD, g.TABLE_NAME, g.GRAIN_KEY, g.ROW_COUNT, g.ROWS_FROM_DIMENSIONS, g.EXPECTED_ROWS, g.NULL_KEYS
ORDER BY g.ORD;


-- -----------------------------------------------------------------------------
-- 3. Not null: every column of every analysis mart, one row per table
--    Question: did a spine leave a hole, i.e. a NULL where "nothing happened" should be 0?
--    Why: every measure is COALESCEd onto a complete spine, so a NULL would mean a broken join;
--      in Data Studio a NULL measure makes SUM silently smaller and a NULL CHANNEL becomes a
--      "null" bucket. The ratio columns of MART_CHANNEL_PERFORMANCE may be NULL by design when
--      a denominator is 0; no channel has a zero denominator, so they are expected non-NULL too.
--    Expected: 0 NULL cells in 15 / 12 / 11 / 27 / 12 columns [C]; rows as in block 2.
-- -----------------------------------------------------------------------------
WITH null_cells AS (
  SELECT 1 AS ORD, 'FCT_CAMPAIGN_DAILY_ACTIVITY' AS TABLE_NAME, 13760 AS EXPECTED_ROWS, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID, COUNT_IF(ACTIVITY_DATE IS NULL) AS ACTIVITY_DATE,
               COUNT_IF(ACTIVITY_MONTH IS NULL) AS ACTIVITY_MONTH, COUNT_IF(CHANNEL IS NULL) AS CHANNEL,
               COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE, COUNT_IF(IS_IN_FLIGHT IS NULL) AS IS_IN_FLIGHT,
               COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS, COUNT_IF(CLICKS IS NULL) AS CLICKS, COUNT_IF(SPEND IS NULL) AS SPEND,
               COUNT_IF(BUDGET_PRORATED IS NULL) AS BUDGET_PRORATED, COUNT_IF(LEADS IS NULL) AS LEADS,
               COUNT_IF(CONVERSIONS IS NULL) AS CONVERSIONS, COUNT_IF(TRIALS IS NULL) AS TRIALS,
               COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE
        FROM FCT_CAMPAIGN_DAILY_ACTIVITY)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CAMPAIGN_ID, ACTIVITY_DATE, ACTIVITY_MONTH, CHANNEL, OBJECTIVE, IS_IN_FLIGHT,
                                          IMPRESSIONS, CLICKS, SPEND, BUDGET_PRORATED, LEADS, CONVERSIONS, TRIALS,
                                          PURCHASES, REVENUE))
  UNION ALL
  SELECT 2, 'MART_MONTHLY_MARKETING', 180, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(MONTH_START IS NULL) AS MONTH_START, COUNT_IF(CHANNEL IS NULL) AS CHANNEL,
               COUNT_IF(ACTIVE_CAMPAIGNS IS NULL) AS ACTIVE_CAMPAIGNS, COUNT_IF(SPEND IS NULL) AS SPEND,
               COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS, COUNT_IF(CLICKS IS NULL) AS CLICKS, COUNT_IF(LEADS IS NULL) AS LEADS,
               COUNT_IF(CONVERSIONS IS NULL) AS CONVERSIONS, COUNT_IF(TRIALS IS NULL) AS TRIALS,
               COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE,
               COUNT_IF(BUDGET_PRORATED IS NULL) AS BUDGET_PRORATED
        FROM MART_MONTHLY_MARKETING)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (MONTH_START, CHANNEL, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS,
                                          CONVERSIONS, TRIALS, PURCHASES, REVENUE, BUDGET_PRORATED))
  UNION ALL
  SELECT 3, 'MART_MONTHLY_COHORT', 180, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(COHORT_MONTH IS NULL) AS COHORT_MONTH, COUNT_IF(CHANNEL IS NULL) AS CHANNEL,
               COUNT_IF(LEADS IS NULL) AS LEADS, COUNT_IF(CONVERTED_LEADS IS NULL) AS CONVERTED_LEADS,
               COUNT_IF(TRIALS IS NULL) AS TRIALS, COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE,
               COUNT_IF(CONVERTED_SAME_MONTH IS NULL) AS CONVERTED_SAME_MONTH,
               COUNT_IF(CONVERTED_LATER_MONTH IS NULL) AS CONVERTED_LATER_MONTH,
               COUNT_IF(SUM_DAYS_TO_CONVERT IS NULL) AS SUM_DAYS_TO_CONVERT, COUNT_IF(MATURE_LEADS IS NULL) AS MATURE_LEADS
        FROM MART_MONTHLY_COHORT)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (COHORT_MONTH, CHANNEL, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE,
                                          CONVERTED_SAME_MONTH, CONVERTED_LATER_MONTH, SUM_DAYS_TO_CONVERT, MATURE_LEADS))
  UNION ALL
  SELECT 4, 'MART_CHANNEL_PERFORMANCE', 5, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(CAMPAIGNS IS NULL) AS CAMPAIGNS, COUNT_IF(BUDGET IS NULL) AS BUDGET,
               COUNT_IF(SPEND IS NULL) AS SPEND, COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS, COUNT_IF(CLICKS IS NULL) AS CLICKS,
               COUNT_IF(LEADS IS NULL) AS LEADS, COUNT_IF(CONVERTED_LEADS IS NULL) AS CONVERTED_LEADS,
               COUNT_IF(TRIALS IS NULL) AS TRIALS, COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE,
               COUNT_IF(CTR IS NULL) AS CTR, COUNT_IF(CLICK_TO_LEAD_RATE IS NULL) AS CLICK_TO_LEAD_RATE,
               COUNT_IF(LEAD_CONVERSION_RATE IS NULL) AS LEAD_CONVERSION_RATE, COUNT_IF(PURCHASE_RATE IS NULL) AS PURCHASE_RATE,
               COUNT_IF(COST_PER_LEAD IS NULL) AS COST_PER_LEAD, COUNT_IF(COST_PER_CONVERSION IS NULL) AS COST_PER_CONVERSION,
               COUNT_IF(COST_PER_PURCHASE IS NULL) AS COST_PER_PURCHASE, COUNT_IF(ROAS IS NULL) AS ROAS,
               COUNT_IF(BUDGET_UTILIZATION IS NULL) AS BUDGET_UTILIZATION, COUNT_IF(CPC IS NULL) AS CPC, COUNT_IF(CPM IS NULL) AS CPM,
               COUNT_IF(SPEND_SHARE IS NULL) AS SPEND_SHARE, COUNT_IF(LEADS_SHARE IS NULL) AS LEADS_SHARE,
               COUNT_IF(REVENUE_SHARE IS NULL) AS REVENUE_SHARE, COUNT_IF(LCR_CI_LOW IS NULL) AS LCR_CI_LOW,
               COUNT_IF(LCR_CI_HIGH IS NULL) AS LCR_CI_HIGH
        FROM MART_CHANNEL_PERFORMANCE)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CHANNEL, CAMPAIGNS, BUDGET, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS,
                                          TRIALS, PURCHASES, REVENUE, CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE,
                                          PURCHASE_RATE, COST_PER_LEAD, COST_PER_CONVERSION, COST_PER_PURCHASE, ROAS,
                                          BUDGET_UTILIZATION, CPC, CPM, SPEND_SHARE, LEADS_SHARE, REVENUE_SHARE,
                                          LCR_CI_LOW, LCR_CI_HIGH))
  UNION ALL
  SELECT 5, 'MART_LEAD_QUALITY', 50, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(SCORE_BAND IS NULL) AS SCORE_BAND,
               COUNT_IF(SCORE_BAND_MIN IS NULL) AS SCORE_BAND_MIN, COUNT_IF(SCORE_BAND_MAX IS NULL) AS SCORE_BAND_MAX,
               COUNT_IF(LEAD_SCORE_SEGMENT IS NULL) AS LEAD_SCORE_SEGMENT, COUNT_IF(LEADS IS NULL) AS LEADS,
               COUNT_IF(SUM_LEAD_SCORE IS NULL) AS SUM_LEAD_SCORE, COUNT_IF(CONVERTED_LEADS IS NULL) AS CONVERTED_LEADS,
               COUNT_IF(TRIALS IS NULL) AS TRIALS, COUNT_IF(PURCHASES IS NULL) AS PURCHASES, COUNT_IF(REVENUE IS NULL) AS REVENUE,
               COUNT_IF(SUM_DAYS_TO_CONVERT IS NULL) AS SUM_DAYS_TO_CONVERT
        FROM MART_LEAD_QUALITY)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CHANNEL, SCORE_BAND, SCORE_BAND_MIN, SCORE_BAND_MAX, LEAD_SCORE_SEGMENT, LEADS,
                                          SUM_LEAD_SCORE, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, SUM_DAYS_TO_CONVERT))
)
SELECT TABLE_NAME, ROW_COUNT, COUNT(*) AS COLUMNS_CHECKED, SUM(NULL_CELLS) AS NULL_CELLS,
       COALESCE(LISTAGG(IFF(NULL_CELLS > 0, COLUMN_NAME, NULL), ', ') WITHIN GROUP (ORDER BY COLUMN_NAME), '') AS COLUMNS_WITH_NULLS,
       0 AS EXPECTED,
       IFF(ROW_COUNT = EXPECTED_ROWS AND SUM(NULL_CELLS) = 0, 'PASS', 'FAIL') AS STATUS
FROM null_cells
GROUP BY ORD, TABLE_NAME, ROW_COUNT, EXPECTED_ROWS
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4. FCT_CAMPAIGN_DAILY_ACTIVITY: the spine and the flight flag
--    Question: does every campaign get exactly the days START_DATE .. END_DATE + 21, does
--      IS_IN_FLIGHT mark exactly the days that have a spend row, and does every input row land
--      on the spine?
--    Why: the spine exists to keep the conversions that land after a campaign ended. A gap, a
--      day too few at the end, or a wrong flight flag would drop or misplace them. Checks 8-9
--      define a flight day independently of the model formula: a day with a FCT_DAILY_SPEND
--      row (every window day has exactly one, [E01 23]). Checks 20-22 count input rows the
--      LEFT JOINs of the model would have lost (NOT EXISTS). Checks 13-16 are the post-flight
--      conversions of the Phase 2 profile. (Check numbers are the ORD values below, which set
--      the printed row order.)
--    Expected: as listed; [E01 22-24], [C], [D].
-- -----------------------------------------------------------------------------
WITH steps AS (             -- day gaps inside each campaign spine
  SELECT DATEDIFF('day', LAG(ACTIVITY_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY ACTIVITY_DATE), ACTIVITY_DATE) AS STEP_DAYS
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
),
bounds AS (                 -- first and last spine day of each campaign vs its window in DIM_CAMPAIGN
  SELECT f.CAMPAIGN_ID, MIN(f.ACTIVITY_DATE) AS FIRST_DAY, MAX(f.ACTIVITY_DATE) AS LAST_DAY, d.START_DATE, d.END_DATE
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY f
  JOIN DIM_CAMPAIGN d ON d.CAMPAIGN_ID = f.CAMPAIGN_ID      -- many days -> one campaign
  GROUP BY f.CAMPAIGN_ID, d.START_DATE, d.END_DATE
),
flags AS (                  -- each spine row with "has a spend row on this date" from FCT_DAILY_SPEND (one row per key)
  SELECT f.IS_IN_FLIGHT, IFF(s.SPEND_ID IS NOT NULL, 1, 0) AS HAS_SPEND_ROW
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY f
  LEFT JOIN FCT_DAILY_SPEND s ON s.CAMPAIGN_ID = f.CAMPAIGN_ID AND s.SPEND_DATE = f.ACTIVITY_DATE
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows' AS CHECK_NAME, COUNT(*) AS ACTUAL, 13760 AS EXPECTED FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 2, 'in-flight rows (IS_IN_FLIGHT = 1) = campaign window days', COUNT_IF(IS_IN_FLIGHT = 1), 11240
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 3, 'post-flight rows (IS_IN_FLIGHT = 0) = 120 campaigns x 21 days', COUNT_IF(IS_IN_FLIGHT = 0), 2520
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 4, 'first ACTIVITY_DATE (YYYYMMDD) = first START_DATE', TO_NUMBER(TO_CHAR(MIN(ACTIVITY_DATE), 'YYYYMMDD')), 20230104
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 5, 'last ACTIVITY_DATE (YYYYMMDD) = last END_DATE + 21 (nothing clipped at 2025-12-31)',
                   TO_NUMBER(TO_CHAR(MAX(ACTIVITY_DATE), 'YYYYMMDD')), 20251223 FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 6, 'campaigns whose spine is not exactly START_DATE .. END_DATE + 21',
                   (SELECT COUNT_IF(FIRST_DAY <> START_DATE OR LAST_DAY <> DATEADD('day', 21, END_DATE)) FROM bounds), 0
  UNION ALL SELECT 7, 'consecutive spine days of a campaign not exactly 1 day apart', (SELECT COUNT_IF(STEP_DAYS <> 1) FROM steps), 0
  UNION ALL SELECT 8, 'in-flight rows without a FCT_DAILY_SPEND row', (SELECT COUNT_IF(IS_IN_FLIGHT = 1 AND HAS_SPEND_ROW = 0) FROM flags), 0
  UNION ALL SELECT 9, 'post-flight rows with a FCT_DAILY_SPEND row', (SELECT COUNT_IF(IS_IN_FLIGHT = 0 AND HAS_SPEND_ROW = 1) FROM flags), 0
  UNION ALL SELECT 10, 'post-flight rows with spend, impressions, clicks, budget or leads <> 0',
                   COUNT_IF(IS_IN_FLIGHT = 0 AND (SPEND <> 0 OR IMPRESSIONS <> 0 OR CLICKS <> 0 OR BUDGET_PRORATED <> 0 OR LEADS <> 0)), 0
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 11, 'in-flight rows with SPEND > 0 (spend > 0 on every spend row)', COUNT_IF(IS_IN_FLIGHT = 1 AND SPEND > 0), 11240
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 12, 'in-flight rows with 0 leads (spend days without leads)', COUNT_IF(IS_IN_FLIGHT = 1 AND LEADS = 0), 7
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 13, 'conversions on post-flight rows (after the campaign ended)', SUM(IFF(IS_IN_FLIGHT = 0, CONVERSIONS, 0)), 4716
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 14, '... of which trials', SUM(IFF(IS_IN_FLIGHT = 0, TRIALS, 0)), 2765 FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 15, '... of which purchases', SUM(IFF(IS_IN_FLIGHT = 0, PURCHASES, 0)), 1951 FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 16, '... their revenue', SUM(IFF(IS_IN_FLIGHT = 0, REVENUE, 0)), 2532266.74 FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 17, 'conversions on in-flight rows (39,696 - 4,716)', SUM(IFF(IS_IN_FLIGHT = 1, CONVERSIONS, 0)), 34980
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 18, 'post-flight rows with at least 1 conversion', COUNT_IF(IS_IN_FLIGHT = 0 AND CONVERSIONS > 0), 1746
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 19, 'rows with at least 1 conversion', COUNT_IF(CONVERSIONS > 0), 11209 FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 20, 'FCT_DAILY_SPEND rows without a spine row', COUNT(*), 0
            FROM FCT_DAILY_SPEND s
            WHERE NOT EXISTS (SELECT 1 FROM FCT_CAMPAIGN_DAILY_ACTIVITY f
                              WHERE f.CAMPAIGN_ID = s.CAMPAIGN_ID AND f.ACTIVITY_DATE = s.SPEND_DATE)
  UNION ALL SELECT 21, 'leads whose (campaign, created date) has no spine row', COUNT(*), 0
            FROM FCT_LEAD_CONVERSIONS l
            WHERE NOT EXISTS (SELECT 1 FROM FCT_CAMPAIGN_DAILY_ACTIVITY f
                              WHERE f.CAMPAIGN_ID = l.CAMPAIGN_ID AND f.ACTIVITY_DATE = l.CREATED_DATE)
  UNION ALL SELECT 22, 'conversions whose (campaign, converted date) has no spine row', COUNT(*), 0
            FROM FCT_LEAD_CONVERSIONS l
            WHERE l.IS_CONVERTED = 1
              AND NOT EXISTS (SELECT 1 FROM FCT_CAMPAIGN_DAILY_ACTIVITY f
                              WHERE f.CAMPAIGN_ID = l.CAMPAIGN_ID AND f.ACTIVITY_DATE = l.CONVERTED_DATE)
  UNION ALL SELECT 23, 'rows whose ACTIVITY_MONTH is not day 1 of the month of ACTIVITY_DATE',
                   COUNT_IF(DAY(ACTIVITY_MONTH) <> 1 OR DATEDIFF('month', ACTIVITY_MONTH, ACTIVITY_DATE) <> 0), 0
            FROM FCT_CAMPAIGN_DAILY_ACTIVITY
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 5. Control totals: every analysis mart adds up to the known totals and to the Phase 3 tables
--    Question: does each mart, summed on its own, reproduce the totals, to the cent?
--    Why: this is the grain rule as a test (G1). A fan-out would inflate a total (11.3 B of
--      spend for the naive spend x leads join), a lost row would shorten it. Each mart is
--      summed on its own, never joined to another table first. PHASE3_VALUE is the same measure
--      summed live from the Phase 3 table it comes from (FCT_DAILY_SPEND, FCT_LEAD_CONVERSIONS,
--      DIM_CAMPAIGN); STATUS needs the mart to equal both the expected value and PHASE3_VALUE.
--    Expected: spend 4,523,050.02, impressions 436,844,819, clicks 7,102,319, leads 261,684,
--      converted 39,696, trials 23,005, purchases 16,691, revenue 21,561,839.01, campaigns 120,
--      budget 5,418,642.16 [P3; E01 31]; BUDGET_PRORATED 5,418,642.159820 (02b [D]); lead score
--      13,233,637 [P1]; summed lag 417,029 [D]; mature leads 261,684 [C].
-- -----------------------------------------------------------------------------
WITH p3 AS (                -- the Phase 3 totals, each from its own table
  SELECT (SELECT SUM(SPEND) FROM FCT_DAILY_SPEND)                AS SPEND,
         (SELECT SUM(IMPRESSIONS) FROM FCT_DAILY_SPEND)          AS IMPRESSIONS,
         (SELECT SUM(CLICKS) FROM FCT_DAILY_SPEND)               AS CLICKS,
         (SELECT SUM(BUDGET_PRORATED) FROM FCT_DAILY_SPEND)      AS BUDGET_PRORATED,
         (SELECT COUNT(*) FROM DIM_CAMPAIGN)                     AS CAMPAIGNS,
         (SELECT SUM(BUDGET) FROM DIM_CAMPAIGN)                  AS BUDGET,
         (SELECT COUNT(*) FROM FCT_LEAD_CONVERSIONS)             AS LEADS,
         (SELECT SUM(IS_CONVERTED) FROM FCT_LEAD_CONVERSIONS)    AS CONVERTED,
         (SELECT SUM(IS_TRIAL) FROM FCT_LEAD_CONVERSIONS)        AS TRIALS,
         (SELECT SUM(IS_PURCHASE) FROM FCT_LEAD_CONVERSIONS)     AS PURCHASES,
         (SELECT SUM(REVENUE) FROM FCT_LEAD_CONVERSIONS)         AS REVENUE,
         (SELECT SUM(LEAD_SCORE) FROM FCT_LEAD_CONVERSIONS)      AS LEAD_SCORE,
         (SELECT SUM(DAYS_TO_CONVERT) FROM FCT_LEAD_CONVERSIONS) AS DAYS_TO_CONVERT,
         (SELECT SUM(IS_MATURE) FROM FCT_LEAD_CONVERSIONS)       AS MATURE
),
a AS (SELECT SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(BUDGET_PRORATED) AS BUDGET_PRORATED,
             SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES,
             SUM(REVENUE) AS REVENUE
      FROM FCT_CAMPAIGN_DAILY_ACTIVITY),
m AS (SELECT SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(BUDGET_PRORATED) AS BUDGET_PRORATED,
             SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES,
             SUM(REVENUE) AS REVENUE
      FROM MART_MONTHLY_MARKETING),
c AS (SELECT SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES,
             SUM(REVENUE) AS REVENUE, SUM(SUM_DAYS_TO_CONVERT) AS SUM_DAYS_TO_CONVERT, SUM(MATURE_LEADS) AS MATURE_LEADS
      FROM MART_MONTHLY_COHORT),
ch AS (SELECT SUM(CAMPAIGNS) AS CAMPAIGNS, SUM(BUDGET) AS BUDGET, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS,
              SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(TRIALS) AS TRIALS,
              SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE
       FROM MART_CHANNEL_PERFORMANCE),
q AS (SELECT SUM(LEADS) AS LEADS, SUM(SUM_LEAD_SCORE) AS SUM_LEAD_SCORE, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
             SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE,
             SUM(SUM_DAYS_TO_CONVERT) AS SUM_DAYS_TO_CONVERT
      FROM MART_LEAD_QUALITY)
SELECT TABLE_NAME, MEASURE, ACTUAL, PHASE3_VALUE, EXPECTED,
       IFF(ACTUAL = EXPECTED AND ACTUAL = PHASE3_VALUE, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'FCT_CAMPAIGN_DAILY_ACTIVITY' AS TABLE_NAME, 'SUM(SPEND)' AS MEASURE,
                   a.SPEND AS ACTUAL, p3.SPEND AS PHASE3_VALUE, 4523050.02 AS EXPECTED FROM a, p3
  UNION ALL SELECT 2, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(IMPRESSIONS)', a.IMPRESSIONS, p3.IMPRESSIONS, 436844819 FROM a, p3
  UNION ALL SELECT 3, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(CLICKS)', a.CLICKS, p3.CLICKS, 7102319 FROM a, p3
  UNION ALL SELECT 4, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(BUDGET_PRORATED)', a.BUDGET_PRORATED, p3.BUDGET_PRORATED, 5418642.159820 FROM a, p3
  UNION ALL SELECT 5, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(LEADS)', a.LEADS, p3.LEADS, 261684 FROM a, p3
  UNION ALL SELECT 6, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(CONVERSIONS)', a.CONVERSIONS, p3.CONVERTED, 39696 FROM a, p3
  UNION ALL SELECT 7, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(TRIALS)', a.TRIALS, p3.TRIALS, 23005 FROM a, p3
  UNION ALL SELECT 8, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(PURCHASES)', a.PURCHASES, p3.PURCHASES, 16691 FROM a, p3
  UNION ALL SELECT 9, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 'SUM(REVENUE)', a.REVENUE, p3.REVENUE, 21561839.01 FROM a, p3
  UNION ALL SELECT 10, 'MART_MONTHLY_MARKETING', 'SUM(SPEND)', m.SPEND, p3.SPEND, 4523050.02 FROM m, p3
  UNION ALL SELECT 11, 'MART_MONTHLY_MARKETING', 'SUM(IMPRESSIONS)', m.IMPRESSIONS, p3.IMPRESSIONS, 436844819 FROM m, p3
  UNION ALL SELECT 12, 'MART_MONTHLY_MARKETING', 'SUM(CLICKS)', m.CLICKS, p3.CLICKS, 7102319 FROM m, p3
  UNION ALL SELECT 13, 'MART_MONTHLY_MARKETING', 'SUM(BUDGET_PRORATED)', m.BUDGET_PRORATED, p3.BUDGET_PRORATED, 5418642.159820 FROM m, p3
  UNION ALL SELECT 14, 'MART_MONTHLY_MARKETING', 'SUM(LEADS)', m.LEADS, p3.LEADS, 261684 FROM m, p3
  UNION ALL SELECT 15, 'MART_MONTHLY_MARKETING', 'SUM(CONVERSIONS)', m.CONVERSIONS, p3.CONVERTED, 39696 FROM m, p3
  UNION ALL SELECT 16, 'MART_MONTHLY_MARKETING', 'SUM(TRIALS)', m.TRIALS, p3.TRIALS, 23005 FROM m, p3
  UNION ALL SELECT 17, 'MART_MONTHLY_MARKETING', 'SUM(PURCHASES)', m.PURCHASES, p3.PURCHASES, 16691 FROM m, p3
  UNION ALL SELECT 18, 'MART_MONTHLY_MARKETING', 'SUM(REVENUE)', m.REVENUE, p3.REVENUE, 21561839.01 FROM m, p3
  UNION ALL SELECT 19, 'MART_MONTHLY_COHORT', 'SUM(LEADS)', c.LEADS, p3.LEADS, 261684 FROM c, p3
  UNION ALL SELECT 20, 'MART_MONTHLY_COHORT', 'SUM(CONVERTED_LEADS)', c.CONVERTED_LEADS, p3.CONVERTED, 39696 FROM c, p3
  UNION ALL SELECT 21, 'MART_MONTHLY_COHORT', 'SUM(TRIALS)', c.TRIALS, p3.TRIALS, 23005 FROM c, p3
  UNION ALL SELECT 22, 'MART_MONTHLY_COHORT', 'SUM(PURCHASES)', c.PURCHASES, p3.PURCHASES, 16691 FROM c, p3
  UNION ALL SELECT 23, 'MART_MONTHLY_COHORT', 'SUM(REVENUE)', c.REVENUE, p3.REVENUE, 21561839.01 FROM c, p3
  UNION ALL SELECT 24, 'MART_MONTHLY_COHORT', 'SUM(SUM_DAYS_TO_CONVERT)', c.SUM_DAYS_TO_CONVERT, p3.DAYS_TO_CONVERT, 417029 FROM c, p3
  UNION ALL SELECT 25, 'MART_MONTHLY_COHORT', 'SUM(MATURE_LEADS)', c.MATURE_LEADS, p3.MATURE, 261684 FROM c, p3
  UNION ALL SELECT 26, 'MART_CHANNEL_PERFORMANCE', 'SUM(CAMPAIGNS)', ch.CAMPAIGNS, p3.CAMPAIGNS, 120 FROM ch, p3
  UNION ALL SELECT 27, 'MART_CHANNEL_PERFORMANCE', 'SUM(BUDGET)', ch.BUDGET, p3.BUDGET, 5418642.16 FROM ch, p3
  UNION ALL SELECT 28, 'MART_CHANNEL_PERFORMANCE', 'SUM(SPEND)', ch.SPEND, p3.SPEND, 4523050.02 FROM ch, p3
  UNION ALL SELECT 29, 'MART_CHANNEL_PERFORMANCE', 'SUM(IMPRESSIONS)', ch.IMPRESSIONS, p3.IMPRESSIONS, 436844819 FROM ch, p3
  UNION ALL SELECT 30, 'MART_CHANNEL_PERFORMANCE', 'SUM(CLICKS)', ch.CLICKS, p3.CLICKS, 7102319 FROM ch, p3
  UNION ALL SELECT 31, 'MART_CHANNEL_PERFORMANCE', 'SUM(LEADS)', ch.LEADS, p3.LEADS, 261684 FROM ch, p3
  UNION ALL SELECT 32, 'MART_CHANNEL_PERFORMANCE', 'SUM(CONVERTED_LEADS)', ch.CONVERTED_LEADS, p3.CONVERTED, 39696 FROM ch, p3
  UNION ALL SELECT 33, 'MART_CHANNEL_PERFORMANCE', 'SUM(TRIALS)', ch.TRIALS, p3.TRIALS, 23005 FROM ch, p3
  UNION ALL SELECT 34, 'MART_CHANNEL_PERFORMANCE', 'SUM(PURCHASES)', ch.PURCHASES, p3.PURCHASES, 16691 FROM ch, p3
  UNION ALL SELECT 35, 'MART_CHANNEL_PERFORMANCE', 'SUM(REVENUE)', ch.REVENUE, p3.REVENUE, 21561839.01 FROM ch, p3
  UNION ALL SELECT 36, 'MART_LEAD_QUALITY', 'SUM(LEADS)', q.LEADS, p3.LEADS, 261684 FROM q, p3
  UNION ALL SELECT 37, 'MART_LEAD_QUALITY', 'SUM(SUM_LEAD_SCORE)', q.SUM_LEAD_SCORE, p3.LEAD_SCORE, 13233637 FROM q, p3
  UNION ALL SELECT 38, 'MART_LEAD_QUALITY', 'SUM(CONVERTED_LEADS)', q.CONVERTED_LEADS, p3.CONVERTED, 39696 FROM q, p3
  UNION ALL SELECT 39, 'MART_LEAD_QUALITY', 'SUM(TRIALS)', q.TRIALS, p3.TRIALS, 23005 FROM q, p3
  UNION ALL SELECT 40, 'MART_LEAD_QUALITY', 'SUM(PURCHASES)', q.PURCHASES, p3.PURCHASES, 16691 FROM q, p3
  UNION ALL SELECT 41, 'MART_LEAD_QUALITY', 'SUM(REVENUE)', q.REVENUE, p3.REVENUE, 21561839.01 FROM q, p3
  UNION ALL SELECT 42, 'MART_LEAD_QUALITY', 'SUM(SUM_DAYS_TO_CONVERT)', q.SUM_DAYS_TO_CONVERT, p3.DAYS_TO_CONVERT, 417029 FROM q, p3
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6. FCT_CAMPAIGN_DAILY_ACTIVITY rolled up to the campaign = MART_CAMPAIGN_PERFORMANCE, every campaign
--    Question: summed over its spine, does each of the 120 campaigns carry exactly the numbers
--      of the campaign table?
--    Why: totals can hide offsetting errors (a conversion booked under the wrong campaign); a
--      campaign-by-campaign comparison cannot. The two tables come from different paths: the
--      activity fact from the Phase 3 facts by date, MART_CAMPAIGN_PERFORMANCE from STAGING by
--      campaign (tested against the Phase 2 baseline in 02b block 12). The post-flight
--      conversions of each campaign must equal its CONVERTED_AFTER_CAMPAIGN_END leads in
--      FCT_LEAD_CONVERSIONS (Phase 3 flag). BUDGET_PRORATED sums back to BUDGET within 0.01
--      (the contract sum-back rule; the 6-dp shares make it inexact by design).
--      FULL OUTER JOIN of the three: a campaign missing anywhere lowers CAMPAIGNS_MATCHING.
--    Expected: 120 campaigns joined and 120 matching in every check.
-- -----------------------------------------------------------------------------
WITH rolled AS (            -- the activity fact rolled up to the campaign on its own
  SELECT CAMPAIGN_ID, COUNT(*) AS SPINE_DAYS, SUM(IS_IN_FLIGHT) AS FLIGHT_DAYS,
         MIN(ACTIVITY_DATE) AS FIRST_DAY, MAX(ACTIVITY_DATE) AS LAST_DAY,
         MIN(CHANNEL) AS MIN_CHANNEL, MAX(CHANNEL) AS MAX_CHANNEL, COUNT_IF(CHANNEL IS NULL) AS NULL_CHANNEL,
         MIN(OBJECTIVE) AS MIN_OBJECTIVE, MAX(OBJECTIVE) AS MAX_OBJECTIVE, COUNT_IF(OBJECTIVE IS NULL) AS NULL_OBJECTIVE,
         SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(SPEND) AS SPEND, SUM(BUDGET_PRORATED) AS BUDGET_PRORATED,
         SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(TRIALS) AS TRIALS, SUM(PURCHASES) AS PURCHASES,
         SUM(REVENUE) AS REVENUE, SUM(IFF(IS_IN_FLIGHT = 0, CONVERSIONS, 0)) AS POST_FLIGHT_CONVERSIONS
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  GROUP BY CAMPAIGN_ID
),
late AS (                   -- the Phase 3 flag, per campaign
  SELECT CAMPAIGN_ID, SUM(CONVERTED_AFTER_CAMPAIGN_END) AS CONVERTED_AFTER_END
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CAMPAIGN_ID
),
matches AS (
  SELECT COUNT(*) AS CAMPAIGNS_JOINED,
         COUNT_IF(r.MIN_CHANNEL = m.CHANNEL AND r.MAX_CHANNEL = m.CHANNEL AND r.NULL_CHANNEL = 0)         AS CHANNEL,
         COUNT_IF(r.MIN_OBJECTIVE = m.OBJECTIVE AND r.MAX_OBJECTIVE = m.OBJECTIVE AND r.NULL_OBJECTIVE = 0) AS OBJECTIVE,
         COUNT_IF(r.FIRST_DAY = m.START_DATE)                         AS FIRST_DAY_EQ_START_DATE,
         COUNT_IF(r.LAST_DAY = DATEADD('day', 21, m.END_DATE))        AS LAST_DAY_EQ_END_DATE_PLUS_21,
         COUNT_IF(r.SPINE_DAYS = m.CAMPAIGN_DAYS + 21)                AS SPINE_DAYS_EQ_CAMPAIGN_DAYS_PLUS_21,
         COUNT_IF(r.FLIGHT_DAYS = m.SPEND_DAYS)                       AS FLIGHT_DAYS_EQ_SPEND_DAYS,
         COUNT_IF(r.IMPRESSIONS = m.IMPRESSIONS)                      AS IMPRESSIONS,
         COUNT_IF(r.CLICKS = m.CLICKS)                                AS CLICKS,
         COUNT_IF(r.SPEND = m.SPEND)                                  AS SPEND,
         COUNT_IF(r.LEADS = m.LEADS)                                  AS LEADS,
         COUNT_IF(r.CONVERSIONS = m.CONVERTED_LEADS)                  AS CONVERSIONS_EQ_CONVERTED_LEADS,
         COUNT_IF(r.TRIALS = m.TRIALS)                                AS TRIALS,
         COUNT_IF(r.PURCHASES = m.PURCHASES)                          AS PURCHASES,
         COUNT_IF(r.REVENUE = m.REVENUE)                              AS REVENUE,
         COUNT_IF(ABS(r.BUDGET_PRORATED - m.BUDGET) <= 0.01)          AS BUDGET_PRORATED_WITHIN_0_01_OF_BUDGET,
         COUNT_IF(r.POST_FLIGHT_CONVERSIONS = l.CONVERTED_AFTER_END)  AS POST_FLIGHT_EQ_CONVERTED_AFTER_END
  FROM rolled r
  FULL OUTER JOIN MART_CAMPAIGN_PERFORMANCE m ON m.CAMPAIGN_ID = r.CAMPAIGN_ID
  FULL OUTER JOIN late l                      ON l.CAMPAIGN_ID = COALESCE(r.CAMPAIGN_ID, m.CAMPAIGN_ID)
)
SELECT CHECK_ID AS CHECK_NAME, CAMPAIGNS_JOINED, CAMPAIGNS_MATCHING, 120 AS EXPECTED,
       IFF(CAMPAIGNS_JOINED = 120 AND CAMPAIGNS_MATCHING = 120, 'PASS', 'FAIL') AS STATUS
FROM matches
UNPIVOT (CAMPAIGNS_MATCHING FOR CHECK_ID IN (
  CHANNEL, OBJECTIVE, FIRST_DAY_EQ_START_DATE, LAST_DAY_EQ_END_DATE_PLUS_21, SPINE_DAYS_EQ_CAMPAIGN_DAYS_PLUS_21,
  FLIGHT_DAYS_EQ_SPEND_DAYS, IMPRESSIONS, CLICKS, SPEND, LEADS, CONVERSIONS_EQ_CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE,
  BUDGET_PRORATED_WITHIN_0_01_OF_BUDGET, POST_FLIGHT_EQ_CONVERTED_AFTER_END))
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 7. MART_MONTHLY_MARKETING: all 180 channel-months against the Phase 3 facts
--    Question: does every channel-month carry exactly what happened in it?
--    Why: the mart is built from the daily activity spine. Here the expected values come from
--      the Phase 3 facts without the spine, each grouped by its own activity month column
--      (FCT_DAILY_SPEND.SPEND_MONTH, FCT_LEAD_CONVERSIONS.CREATED_MONTH for leads and
--      CONVERTED_MONTH for conversions), and ACTIVE_CAMPAIGNS from the campaign windows in
--      DIM_CAMPAIGN (START_DATE <= last day of the month AND END_DATE >= first day), a different
--      formula from the model's distinct in-flight campaigns. Each input is aggregated to
--      channel x month on its own, then joined 1:1 to the 36 x 5 spine, and the result is FULL
--      OUTER JOINed with the mart.
--    Expected: 180 channel-months joined and 180 matching for every column.
-- -----------------------------------------------------------------------------
WITH months AS (SELECT DISTINCT MONTH_START FROM DIM_DATE),
channels AS (SELECT DISTINCT CHANNEL FROM DIM_CAMPAIGN),
spend_m AS (
  SELECT SPEND_MONTH AS MONTH_START, CHANNEL, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS,
         SUM(BUDGET_PRORATED) AS BUDGET_PRORATED
  FROM FCT_DAILY_SPEND GROUP BY SPEND_MONTH, CHANNEL
),
leads_m AS (
  SELECT CREATED_MONTH AS MONTH_START, CHANNEL, COUNT(*) AS LEADS
  FROM FCT_LEAD_CONVERSIONS GROUP BY CREATED_MONTH, CHANNEL
),
conversions_m AS (
  SELECT CONVERTED_MONTH AS MONTH_START, CHANNEL, COUNT(*) AS CONVERSIONS, SUM(IS_TRIAL) AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM FCT_LEAD_CONVERSIONS WHERE IS_CONVERTED = 1 GROUP BY CONVERTED_MONTH, CHANNEL
),
active_m AS (               -- campaigns whose window overlaps the month
  SELECT m.MONTH_START, c.CHANNEL, COUNT(*) AS ACTIVE_CAMPAIGNS
  FROM months m
  JOIN DIM_CAMPAIGN c ON c.START_DATE <= LAST_DAY(m.MONTH_START, 'month') AND c.END_DATE >= m.MONTH_START
  GROUP BY m.MONTH_START, c.CHANNEL
),
expected AS (
  SELECT m.MONTH_START, ch.CHANNEL,
         COALESCE(a.ACTIVE_CAMPAIGNS, 0) AS ACTIVE_CAMPAIGNS, COALESCE(s.SPEND, 0) AS SPEND,
         COALESCE(s.IMPRESSIONS, 0) AS IMPRESSIONS, COALESCE(s.CLICKS, 0) AS CLICKS, COALESCE(l.LEADS, 0) AS LEADS,
         COALESCE(v.CONVERSIONS, 0) AS CONVERSIONS, COALESCE(v.TRIALS, 0) AS TRIALS, COALESCE(v.PURCHASES, 0) AS PURCHASES,
         COALESCE(v.REVENUE, 0) AS REVENUE, COALESCE(s.BUDGET_PRORATED, 0) AS BUDGET_PRORATED
  FROM months m
  CROSS JOIN channels ch
  LEFT JOIN spend_m       s ON s.MONTH_START = m.MONTH_START AND s.CHANNEL = ch.CHANNEL
  LEFT JOIN leads_m       l ON l.MONTH_START = m.MONTH_START AND l.CHANNEL = ch.CHANNEL
  LEFT JOIN conversions_m v ON v.MONTH_START = m.MONTH_START AND v.CHANNEL = ch.CHANNEL
  LEFT JOIN active_m      a ON a.MONTH_START = m.MONTH_START AND a.CHANNEL = ch.CHANNEL
),
matches AS (
  SELECT COUNT(*) AS CHANNEL_MONTHS_JOINED,
         COUNT_IF(t.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS,
         COUNT_IF(t.SPEND = e.SPEND)                       AS SPEND,
         COUNT_IF(t.IMPRESSIONS = e.IMPRESSIONS)           AS IMPRESSIONS,
         COUNT_IF(t.CLICKS = e.CLICKS)                     AS CLICKS,
         COUNT_IF(t.LEADS = e.LEADS)                       AS LEADS,
         COUNT_IF(t.CONVERSIONS = e.CONVERSIONS)           AS CONVERSIONS,
         COUNT_IF(t.TRIALS = e.TRIALS)                     AS TRIALS,
         COUNT_IF(t.PURCHASES = e.PURCHASES)               AS PURCHASES,
         COUNT_IF(t.REVENUE = e.REVENUE)                   AS REVENUE,
         COUNT_IF(t.BUDGET_PRORATED = e.BUDGET_PRORATED)   AS BUDGET_PRORATED
  FROM MART_MONTHLY_MARKETING t
  FULL OUTER JOIN expected e ON e.MONTH_START = t.MONTH_START AND e.CHANNEL = t.CHANNEL
)
SELECT COLUMN_NAME, CHANNEL_MONTHS_JOINED, CHANNEL_MONTHS_MATCHING, 180 AS EXPECTED,
       IFF(CHANNEL_MONTHS_JOINED = 180 AND CHANNEL_MONTHS_MATCHING = 180, 'PASS', 'FAIL') AS STATUS
FROM matches
UNPIVOT (CHANNEL_MONTHS_MATCHING FOR COLUMN_NAME IN (ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS,
                                                     TRIALS, PURCHASES, REVENUE, BUDGET_PRORATED))
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 8. MART_MONTHLY_COHORT: all 180 channel-months against STAGING
--    Question: does every cohort row carry exactly what the leads created in that month and
--      channel later did?
--    Why: the mart is built from FCT_LEAD_CONVERSIONS. Here the expected values are recomputed
--      from the clean STAGING views (STG_LEADS LEFT JOIN STG_CONVERSIONS on LEAD_ID, 1:0..1;
--      STG_CAMPAIGNS for the channel, n:1) with their own DATE_TRUNC and DATEDIFF, aggregated
--      to cohort month x channel, then joined 1:1 to the 36 x 5 spine. MATURE_LEADS uses the
--      contract rule: created on or before AS_OF_DATE - 21 days = 2025-12-10 [C].
--    Expected: 180 channel-months joined and 180 matching for every column.
-- -----------------------------------------------------------------------------
WITH months AS (SELECT DISTINCT MONTH_START AS COHORT_MONTH FROM DIM_DATE),
channels AS (SELECT DISTINCT CHANNEL FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS),
staging_cohort AS (
  SELECT DATE_TRUNC('month', l.CREATED_DATE) AS COHORT_MONTH, c.CHANNEL,
         COUNT(*)                                     AS LEADS,
         COUNT(v.CONVERSION_ID)                       AS CONVERTED_LEADS,
         COUNT_IF(v.CONVERSION_TYPE = 'trial')        AS TRIALS,
         COUNT_IF(v.CONVERSION_TYPE = 'purchase')     AS PURCHASES,
         COALESCE(SUM(v.REVENUE), 0)                  AS REVENUE,
         COUNT_IF(DATE_TRUNC('month', v.CONVERTED_DATE) = DATE_TRUNC('month', l.CREATED_DATE)) AS CONVERTED_SAME_MONTH,
         COUNT_IF(DATE_TRUNC('month', v.CONVERTED_DATE) > DATE_TRUNC('month', l.CREATED_DATE)) AS CONVERTED_LATER_MONTH,
         COALESCE(SUM(DATEDIFF('day', l.CREATED_DATE, v.CONVERTED_DATE)), 0)                   AS SUM_DAYS_TO_CONVERT,
         COUNT_IF(l.CREATED_DATE <= '2025-12-10'::DATE)                                         AS MATURE_LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID       -- 1:0..1
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c        ON c.CAMPAIGN_ID = l.CAMPAIGN_ID -- n:1
  GROUP BY DATE_TRUNC('month', l.CREATED_DATE), c.CHANNEL
),
expected AS (
  SELECT m.COHORT_MONTH, ch.CHANNEL,
         COALESCE(s.LEADS, 0) AS LEADS, COALESCE(s.CONVERTED_LEADS, 0) AS CONVERTED_LEADS, COALESCE(s.TRIALS, 0) AS TRIALS,
         COALESCE(s.PURCHASES, 0) AS PURCHASES, COALESCE(s.REVENUE, 0) AS REVENUE,
         COALESCE(s.CONVERTED_SAME_MONTH, 0) AS CONVERTED_SAME_MONTH, COALESCE(s.CONVERTED_LATER_MONTH, 0) AS CONVERTED_LATER_MONTH,
         COALESCE(s.SUM_DAYS_TO_CONVERT, 0) AS SUM_DAYS_TO_CONVERT, COALESCE(s.MATURE_LEADS, 0) AS MATURE_LEADS
  FROM months m
  CROSS JOIN channels ch
  LEFT JOIN staging_cohort s ON s.COHORT_MONTH = m.COHORT_MONTH AND s.CHANNEL = ch.CHANNEL
),
matches AS (
  SELECT COUNT(*) AS CHANNEL_MONTHS_JOINED,
         COUNT_IF(t.LEADS = e.LEADS)                                 AS LEADS,
         COUNT_IF(t.CONVERTED_LEADS = e.CONVERTED_LEADS)             AS CONVERTED_LEADS,
         COUNT_IF(t.TRIALS = e.TRIALS)                               AS TRIALS,
         COUNT_IF(t.PURCHASES = e.PURCHASES)                         AS PURCHASES,
         COUNT_IF(t.REVENUE = e.REVENUE)                             AS REVENUE,
         COUNT_IF(t.CONVERTED_SAME_MONTH = e.CONVERTED_SAME_MONTH)   AS CONVERTED_SAME_MONTH,
         COUNT_IF(t.CONVERTED_LATER_MONTH = e.CONVERTED_LATER_MONTH) AS CONVERTED_LATER_MONTH,
         COUNT_IF(t.SUM_DAYS_TO_CONVERT = e.SUM_DAYS_TO_CONVERT)     AS SUM_DAYS_TO_CONVERT,
         COUNT_IF(t.MATURE_LEADS = e.MATURE_LEADS)                   AS MATURE_LEADS
  FROM MART_MONTHLY_COHORT t
  FULL OUTER JOIN expected e ON e.COHORT_MONTH = t.COHORT_MONTH AND e.CHANNEL = t.CHANNEL
)
SELECT COLUMN_NAME, CHANNEL_MONTHS_JOINED, CHANNEL_MONTHS_MATCHING, 180 AS EXPECTED,
       IFF(CHANNEL_MONTHS_JOINED = 180 AND CHANNEL_MONTHS_MATCHING = 180, 'PASS', 'FAIL') AS STATUS
FROM matches
UNPIVOT (CHANNEL_MONTHS_MATCHING FOR COLUMN_NAME IN (LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, CONVERTED_SAME_MONTH,
                                                     CONVERTED_LATER_MONTH, SUM_DAYS_TO_CONVERT, MATURE_LEADS))
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 9. All 36 months, both bases, against the Phase 2 baseline
--    Question: rolled up over the channels, do the two monthly marts reproduce the baseline
--      month by month, and how far apart are the two bases?
--    Why: architecture decision 7 (G3). Each mart is aggregated to the month ON ITS OWN, and
--      only then joined 1:1 on the month. This side-by-side is a test comparison, never a
--      chart: activity conversions (counted when they happen) and cohort converted leads
--      (counted in the month of their lead) answer different questions. LEADS is the one
--      measure both bases share (a lead belongs to the month it was created), so it must agree.
--      ACTIVE_CAMPAIGNS is summed over channels, which is valid within one month (a campaign
--      has one channel); it is printed next to the volumes because they follow it (G7).
--      BASES_DIFFER is descriptive; block 10 counts it.
--    Expected: all 36 rows of [P3 monthly_activity_vs_cohort] (spend, leads, activity and cohort
--      conversions and revenue) and ACTIVE_CAMPAIGNS = [E01 28].
-- -----------------------------------------------------------------------------
WITH marketing AS (
  SELECT MONTH_START, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS,
         SUM(CONVERSIONS) AS CONVERSIONS, SUM(REVENUE) AS REVENUE
  FROM MART_MONTHLY_MARKETING GROUP BY MONTH_START
),
cohort AS (
  SELECT COHORT_MONTH AS MONTH_START, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(CONVERTED_LATER_MONTH) AS CONVERTED_LATER_MONTH, SUM(REVENUE) AS REVENUE
  FROM MART_MONTHLY_COHORT GROUP BY COHORT_MONTH
),
expected (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, LEADS, ACTIVITY_CONVERSIONS, COHORT_CONVERSIONS, ACTIVITY_REVENUE,
          COHORT_REVENUE) AS (   -- [E01 28] active campaigns; [P3 monthly_activity_vs_cohort] the rest
  SELECT * FROM VALUES
    ('2023-01-01'::DATE,  3,   23686.55,  1325,  110,  212,  52800.58, 104789.28),
    ('2023-02-01'::DATE,  5,   49461.61,  2825,  325,  427, 170806.55, 203501.92),
    ('2023-03-01'::DATE, 10,  104283.65,  6229,  798,  914, 393351.94, 459636.12),
    ('2023-04-01'::DATE, 11,  104393.90,  5748,  902,  880, 474970.42, 467059.31),
    ('2023-05-01'::DATE, 14,   97734.10,  5188,  811,  771, 435288.12, 433096.71),
    ('2023-06-01'::DATE, 18,  123064.68,  7491,  963, 1137, 569578.22, 657294.35),
    ('2023-07-01'::DATE, 16,  116810.98,  7779, 1273, 1220, 699206.04, 688314.91),
    ('2023-08-01'::DATE, 18,  134065.09,  9024, 1221, 1377, 672633.67, 757947.97),
    ('2023-09-01'::DATE, 18,  155294.61, 10771, 1590, 1604, 884815.77, 873286.79),
    ('2023-10-01'::DATE, 19,  171832.62, 10930, 1654, 1648, 939852.38, 982891.87),
    ('2023-11-01'::DATE, 16,  191171.25, 10526, 1582, 1575, 904954.17, 896561.10),
    ('2023-12-01'::DATE, 17,  186463.37,  9713, 1550, 1471, 877224.49, 814229.75),
    ('2024-01-01'::DATE, 12,  122943.61,  6493, 1158,  975, 618809.35, 505522.79),
    ('2024-02-01'::DATE, 11,  100601.92,  5638,  794,  882, 441376.15, 490071.45),
    ('2024-03-01'::DATE, 16,  130497.60,  7576, 1063, 1172, 568388.08, 639937.50),
    ('2024-04-01'::DATE, 19,  196892.88, 10413, 1424, 1588, 795905.02, 826515.58),
    ('2024-05-01'::DATE, 17,  177398.24,  8898, 1550, 1332, 813289.19, 759968.60),
    ('2024-06-01'::DATE, 13,  129762.16,  5954, 1035,  918, 581296.94, 491639.76),
    ('2024-07-01'::DATE, 13,  115762.43,  5895,  861,  879, 468529.67, 469706.98),
    ('2024-08-01'::DATE, 18,  185052.08, 10718, 1316, 1607, 687143.69, 845201.71),
    ('2024-09-01'::DATE, 20,  205363.34, 11825, 1780, 1779, 950923.18, 942884.99),
    ('2024-10-01'::DATE, 18,  219378.73, 11683, 1830, 1771, 961348.25, 938239.29),
    ('2024-11-01'::DATE, 19,  181790.58, 10557, 1579, 1588, 857423.40, 865052.92),
    ('2024-12-01'::DATE, 18,  205754.77, 11721, 1758, 1831, 933214.90, 980609.89),
    ('2025-01-01'::DATE, 16,  189821.49, 10136, 1699, 1557, 926132.23, 867523.60),
    ('2025-02-01'::DATE, 13,   97550.77,  6308, 1116,  930, 619062.19, 501984.76),
    ('2025-03-01'::DATE, 12,  103654.48,  7226, 1061, 1099, 598344.60, 621952.09),
    ('2025-04-01'::DATE, 13,   95842.28,  6504,  969, 1036, 544558.36, 577892.10),
    ('2025-05-01'::DATE, 14,  109131.26,  7506, 1183, 1113, 629458.15, 565975.71),
    ('2025-06-01'::DATE, 14,   94604.52,  6371,  971,  996, 515898.62, 554537.00),
    ('2025-07-01'::DATE, 15,  132922.32,  7710, 1101, 1156, 601132.60, 603557.74),
    ('2025-08-01'::DATE, 14,  138359.57,  7339, 1190, 1109, 596182.42, 586219.70),
    ('2025-09-01'::DATE, 11,   65610.05,  3680,  700,  513, 381379.89, 265118.01),
    ('2025-10-01'::DATE,  5,   48774.54,  2826,  462,  445, 228041.53, 222570.47),
    ('2025-11-01'::DATE,  3,   16510.95,  1093,  256,  173, 137433.25,  96402.96),
    ('2025-12-01'::DATE,  1,     807.04,    65,   61,   11,  31085.00,   4143.33)
)
SELECT TO_CHAR(COALESCE(a.MONTH_START, c.MONTH_START, e.MONTH_START), 'YYYY-MM') AS MONTH,
       a.ACTIVE_CAMPAIGNS, a.SPEND, a.LEADS, a.CONVERSIONS AS ACTIVITY_CONVERSIONS, c.CONVERTED_LEADS AS COHORT_CONVERTED_LEADS,
       c.CONVERTED_LATER_MONTH AS COHORT_CONVERTED_LATER, a.REVENUE AS ACTIVITY_REVENUE, c.REVENUE AS COHORT_REVENUE,
       IFF(a.CONVERSIONS <> c.CONVERTED_LEADS, 'yes', 'no') AS BASES_DIFFER,
       IFF(a.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND a.SPEND = e.SPEND AND a.LEADS = e.LEADS AND c.LEADS = e.LEADS
           AND a.CONVERSIONS = e.ACTIVITY_CONVERSIONS AND c.CONVERTED_LEADS = e.COHORT_CONVERSIONS
           AND a.REVENUE = e.ACTIVITY_REVENUE AND c.REVENUE = e.COHORT_REVENUE, 'PASS', 'FAIL') AS STATUS
FROM marketing a
FULL OUTER JOIN cohort   c ON c.MONTH_START = a.MONTH_START
FULL OUTER JOIN expected e ON e.MONTH_START = COALESCE(a.MONTH_START, c.MONTH_START)
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 10. Activity basis vs lead-cohort basis: same totals, different months
--    Question: is the reason for keeping two monthly tables visible in the data?
--    Why: both bases count every conversion exactly once (39,696; revenue 21,561,839.01), but in
--      different months. If they agreed month by month, one table would do. Checks 6-11 count
--      how often they disagree. Checks 16-23 compute, on purpose, the wrong monthly ratio that
--      a blended chart would show, activity CONVERSIONS / LEADS of the same month, next to the
--      cohort rate CONVERTED_LEADS / LEADS: the first swings, the second stays narrow (the
--      month of each extreme as YYYYMM). Checks 12-15 describe the activity table: 2
--      channel-months have conversions but no campaign in flight, i.e. only conversions that
--      landed after their campaign ended.
--    Expected: totals [P3]; counts and extremes [D] (the 36-month extremes are also derivable
--      from the [P3] rows of block 9: 110 / 1,325, 61 / 65, 513 / 3,680, 11 / 65).
-- -----------------------------------------------------------------------------
WITH marketing_m AS (       -- the activity mart rolled up to the month on its own
  SELECT MONTH_START, SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(REVENUE) AS REVENUE
  FROM MART_MONTHLY_MARKETING GROUP BY MONTH_START
),
cohort_m AS (               -- the cohort mart rolled up to the month on its own
  SELECT COHORT_MONTH AS MONTH_START, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(REVENUE) AS REVENUE
  FROM MART_MONTHLY_COHORT GROUP BY COHORT_MONTH
),
by_month AS (               -- 1:1 on the month
  SELECT a.MONTH_START, TO_NUMBER(TO_CHAR(a.MONTH_START, 'YYYYMM')) AS YYYYMM,
         a.CONVERSIONS, c.CONVERTED_LEADS, a.REVENUE AS ACTIVITY_REVENUE, c.REVENUE AS COHORT_REVENUE,
         ROUND(a.CONVERSIONS::NUMBER(32,18) / NULLIF(a.LEADS, 0), 6)     AS NAIVE_RATIO,    -- WRONG on purpose: mixes the bases
         ROUND(c.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(c.LEADS, 0), 6) AS COHORT_RATE
  FROM marketing_m a
  JOIN cohort_m c ON c.MONTH_START = a.MONTH_START
),
by_channel_month AS (       -- 1:1 on month and channel
  SELECT a.MONTH_START, a.CHANNEL, a.SPEND, a.ACTIVE_CAMPAIGNS, a.CONVERSIONS, c.CONVERTED_LEADS
  FROM MART_MONTHLY_MARKETING a
  JOIN MART_MONTHLY_COHORT c ON c.COHORT_MONTH = a.MONTH_START AND c.CHANNEL = a.CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'MART_MONTHLY_MARKETING: SUM(CONVERSIONS) (activity basis)' AS CHECK_NAME,
                   (SELECT SUM(CONVERSIONS) FROM marketing_m) AS ACTUAL, 39696 AS EXPECTED
  UNION ALL SELECT 2, 'MART_MONTHLY_COHORT: SUM(CONVERTED_LEADS) (cohort basis)', (SELECT SUM(CONVERTED_LEADS) FROM cohort_m), 39696
  UNION ALL SELECT 3, 'MART_MONTHLY_MARKETING: SUM(REVENUE)', (SELECT SUM(REVENUE) FROM marketing_m), 21561839.01
  UNION ALL SELECT 4, 'MART_MONTHLY_COHORT: SUM(REVENUE)', (SELECT SUM(REVENUE) FROM cohort_m), 21561839.01
  UNION ALL SELECT 5, 'months compared', (SELECT COUNT(*) FROM by_month), 36
  UNION ALL SELECT 6, 'months where activity CONVERSIONS <> cohort CONVERTED_LEADS',
                   (SELECT COUNT_IF(CONVERSIONS <> CONVERTED_LEADS) FROM by_month), 36
  UNION ALL SELECT 7, 'months where activity REVENUE <> cohort REVENUE',
                   (SELECT COUNT_IF(ACTIVITY_REVENUE <> COHORT_REVENUE) FROM by_month), 36
  UNION ALL SELECT 8, 'channel-months compared', (SELECT COUNT(*) FROM by_channel_month), 180
  UNION ALL SELECT 9, 'channel-months where activity CONVERSIONS <> cohort CONVERTED_LEADS',
                   (SELECT COUNT_IF(CONVERSIONS <> CONVERTED_LEADS) FROM by_channel_month), 159
  UNION ALL SELECT 10, 'channel-months with 0 conversions on both bases',
                   (SELECT COUNT_IF(CONVERSIONS = 0 AND CONVERTED_LEADS = 0) FROM by_channel_month), 19
  UNION ALL SELECT 11, 'channel-months equal on both bases and not 0',
                   (SELECT COUNT_IF(CONVERSIONS = CONVERTED_LEADS AND CONVERSIONS > 0) FROM by_channel_month), 2
  UNION ALL SELECT 12, 'channel-months with spend (activity)', (SELECT COUNT_IF(SPEND > 0) FROM by_channel_month), 159
  UNION ALL SELECT 13, 'channel-months with a campaign in flight', (SELECT COUNT_IF(ACTIVE_CAMPAIGNS > 0) FROM by_channel_month), 159
  UNION ALL SELECT 14, 'channel-months with conversions (activity)', (SELECT COUNT_IF(CONVERSIONS > 0) FROM by_channel_month), 161
  UNION ALL SELECT 15, 'channel-months with conversions but no campaign in flight',
                   (SELECT COUNT_IF(CONVERSIONS > 0 AND ACTIVE_CAMPAIGNS = 0) FROM by_channel_month), 2
  UNION ALL SELECT 16, 'WRONG on purpose: activity CONVERSIONS / LEADS of the same month, lowest', (SELECT MIN(NAIVE_RATIO) FROM by_month), 0.083019
  UNION ALL SELECT 17, '... month of the lowest (YYYYMM)', (SELECT MIN_BY(YYYYMM, NAIVE_RATIO) FROM by_month), 202301
  UNION ALL SELECT 18, 'WRONG on purpose: activity CONVERSIONS / LEADS of the same month, highest', (SELECT MAX(NAIVE_RATIO) FROM by_month), 0.938462
  UNION ALL SELECT 19, '... month of the highest (YYYYMM)', (SELECT MAX_BY(YYYYMM, NAIVE_RATIO) FROM by_month), 202512
  UNION ALL SELECT 20, 'cohort rate CONVERTED_LEADS / LEADS, lowest month', (SELECT MIN(COHORT_RATE) FROM by_month), 0.139402
  UNION ALL SELECT 21, '... month of the lowest (YYYYMM)', (SELECT MIN_BY(YYYYMM, COHORT_RATE) FROM by_month), 202509
  UNION ALL SELECT 22, 'cohort rate CONVERTED_LEADS / LEADS, highest month', (SELECT MAX(COHORT_RATE) FROM by_month), 0.169231
  UNION ALL SELECT 23, '... month of the highest (YYYYMM)', (SELECT MAX_BY(YYYYMM, COHORT_RATE) FROM by_month), 202512
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 11. MART_MONTHLY_COHORT: cohort semantics and the cross-month share
--    Question: do the cohort columns mean what the contract says, and how many conversions
--      cross a month boundary?
--    Why: CONVERTED_SAME_MONTH and CONVERTED_LATER_MONTH must partition the converted leads (no
--      conversion precedes its lead), TRIALS and PURCHASES too (one conversion per lead, to one
--      type). The cross-month share is the reason activity and cohort months differ. The local
--      pre-load baseline put it at 13,675 conversions = 34.45% [PL]; this check is its first
--      Snowflake evidence. The mean lag re-derived from SUM_DAYS_TO_CONVERT must equal the
--      Phase 2 lag profile.
--    Expected: 0 for checks 2-5 on 180 rows [C]; 26,021 [D] and 13,675 [PL; D]; share
--      13,675 / 39,696 = 0.344493 [D] (34.45% [PL]); summed lag 417,029 [D]; mean lag 10.5056
--      [E01 25].
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows evaluated' AS CHECK_NAME, COUNT(*) AS ACTUAL, 180 AS EXPECTED FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 2, 'rows where CONVERTED_SAME_MONTH + CONVERTED_LATER_MONTH <> CONVERTED_LEADS',
                   COUNT_IF(CONVERTED_SAME_MONTH + CONVERTED_LATER_MONTH <> CONVERTED_LEADS), 0 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 3, 'rows where TRIALS + PURCHASES <> CONVERTED_LEADS', COUNT_IF(TRIALS + PURCHASES <> CONVERTED_LEADS), 0
            FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 4, 'rows where CONVERTED_LEADS > LEADS', COUNT_IF(CONVERTED_LEADS > LEADS), 0 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 5, 'rows where MATURE_LEADS <> LEADS (every lead mature at the assumed as-of date)',
                   COUNT_IF(MATURE_LEADS <> LEADS), 0 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 6, 'SUM(CONVERTED_SAME_MONTH)', SUM(CONVERTED_SAME_MONTH), 26021 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 7, 'SUM(CONVERTED_LATER_MONTH): conversions in a later month than their lead',
                   SUM(CONVERTED_LATER_MONTH), 13675 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 8, 'cross-month share = SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS), 6 dp',
                   ROUND(SUM(CONVERTED_LATER_MONTH)::NUMBER(32,18) / SUM(CONVERTED_LEADS), 6), 0.344493 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 9, 'SUM(SUM_DAYS_TO_CONVERT)', SUM(SUM_DAYS_TO_CONVERT), 417029 FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 10, 'mean lag = SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS), 4 dp',
                   ROUND(SUM(SUM_DAYS_TO_CONVERT)::NUMBER(32,18) / SUM(CONVERTED_LEADS), 4), 10.5056 FROM MART_MONTHLY_COHORT
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 12. MART_MONTHLY_COHORT by channel: converted leads, cross-month conversions and mean lag
--    Question: per channel, do the cohort bases reproduce the channel conversions [P3], the
--      cross-month counts [D] and the Phase 2 mean lag [E01 25]?
--    Why: the dashboard filters the cohort page by channel; each channel must re-derive its
--      own mean lag from the additive SUM_DAYS_TO_CONVERT. CROSS_MONTH_SHARE is descriptive
--      (its counts are checked). A missing or unexpected channel is its own FAIL row.
--    Expected: as listed ([P3 kpi_channel_bases], [D], [E01 25]).
-- -----------------------------------------------------------------------------
WITH by_channel AS (
  SELECT CHANNEL, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(CONVERTED_SAME_MONTH) AS SAME_MONTH,
         SUM(CONVERTED_LATER_MONTH) AS LATER_MONTH,
         ROUND(SUM(CONVERTED_LATER_MONTH)::NUMBER(32,18) / NULLIF(SUM(CONVERTED_LEADS), 0), 6) AS CROSS_MONTH_SHARE,
         ROUND(SUM(SUM_DAYS_TO_CONVERT)::NUMBER(32,18) / NULLIF(SUM(CONVERTED_LEADS), 0), 4)   AS MEAN_LAG
  FROM MART_MONTHLY_COHORT
  GROUP BY CHANNEL
),
expected (CHANNEL, LEADS, CONVERTED_LEADS, SAME_MONTH, LATER_MONTH, MEAN_LAG) AS (   -- [P3]; [D]; [D]; [E01 25]
  SELECT * FROM VALUES
    ('affiliate',   67849, 10352, 6845, 3507, 10.4954),
    ('display',     45149,  6744, 4397, 2347, 10.5101),
    ('paid_search', 65268, 10019, 6534, 3485, 10.5017),
    ('paid_social', 57619,  8648, 5651, 2997, 10.5774),
    ('video',       25799,  3933, 2594, 1339, 10.3766)
)
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL, b.LEADS, b.CONVERTED_LEADS, b.SAME_MONTH, b.LATER_MONTH,
       b.CROSS_MONTH_SHARE, b.MEAN_LAG, e.MEAN_LAG AS EXPECTED_MEAN_LAG,
       IFF(b.LEADS = e.LEADS AND b.CONVERTED_LEADS = e.CONVERTED_LEADS AND b.SAME_MONTH = e.SAME_MONTH
           AND b.LATER_MONTH = e.LATER_MONTH AND b.MEAN_LAG = e.MEAN_LAG, 'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 13. Volume by year next to the number of campaigns (G7)
--    Question: does activity by year reproduce the baseline, and is the 2025 drop in volume
--      visible together with the drop in running campaigns?
--    Why: 2025 totals are lower, and the reason in this data is the portfolio: 22 campaigns
--      started in 2025 against 50 in 2024 [E01 27]. A trend chart without the campaign count
--      would invite a "2025 performed worse" reading. The rows also show why ACTIVE_CAMPAIGNS
--      is not additive across months: summed over the months it gives campaign-months (490 in
--      total), and campaigns active per year add up to 143 although there are 120 campaigns
--      (23 cross a year boundary). Each source is aggregated to the year on its own (ROLLUP adds
--      the TOTAL row), then joined 1:1 on the year.
--    Expected: started and active [E01 27]; campaign-months = the 12 monthly values of [E01 28]
--      summed; leads and conversions [E01 22]; spend, revenue and BUDGET_PRORATED by year [D].
-- -----------------------------------------------------------------------------
WITH started AS (           -- DIM_CAMPAIGN: campaigns by start year
  SELECT IFF(GROUPING(START_YEAR) = 1, 'TOTAL', START_YEAR::VARCHAR) AS YEAR, COUNT(*) AS CAMPAIGNS_STARTED
  FROM DIM_CAMPAIGN
  GROUP BY ROLLUP (START_YEAR)
),
active AS (                 -- the daily spine: distinct campaigns with an in-flight day in the year
  SELECT IFF(GROUPING(YR) = 1, 'TOTAL', YR::VARCHAR) AS YEAR,
         COUNT(DISTINCT IFF(IS_IN_FLIGHT = 1, CAMPAIGN_ID, NULL)) AS CAMPAIGNS_ACTIVE
  FROM (SELECT YEAR(ACTIVITY_DATE) AS YR, CAMPAIGN_ID, IS_IN_FLIGHT FROM FCT_CAMPAIGN_DAILY_ACTIVITY)
  GROUP BY ROLLUP (YR)
),
monthly AS (                -- the activity mart: volumes, and campaign-months
  SELECT IFF(GROUPING(YR) = 1, 'TOTAL', YR::VARCHAR) AS YEAR,
         SUM(ACTIVE_CAMPAIGNS) AS CAMPAIGN_MONTHS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS,
         SUM(CONVERSIONS) AS CONVERSIONS, SUM(REVENUE) AS REVENUE, SUM(BUDGET_PRORATED) AS BUDGET_PRORATED
  FROM (SELECT YEAR(MONTH_START) AS YR, ACTIVE_CAMPAIGNS, SPEND, LEADS, CONVERSIONS, REVENUE, BUDGET_PRORATED
        FROM MART_MONTHLY_MARKETING)
  GROUP BY ROLLUP (YR)
),
expected (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, CAMPAIGN_MONTHS, SPEND, LEADS, CONVERSIONS, REVENUE, BUDGET_PRORATED) AS (
  SELECT * FROM VALUES
    ('2023',   48,  48, 165, 1458262.41,  87549, 12779,  7075482.35, 1750679.286340),
    ('2024',   50,  60, 194, 1971198.34, 107371, 16148,  8677647.82, 2349894.124804),
    ('2025',   22,  35, 131, 1093589.27,  66764, 10769,  5808708.84, 1318068.748676),
    ('TOTAL', 120, 120, 490, 4523050.02, 261684, 39696, 21561839.01, 5418642.159820)
)
SELECT COALESCE(m.YEAR, e.YEAR) AS YEAR, s.CAMPAIGNS_STARTED, a.CAMPAIGNS_ACTIVE, m.CAMPAIGN_MONTHS, m.SPEND, m.LEADS,
       m.CONVERSIONS, m.REVENUE, m.BUDGET_PRORATED,
       IFF(s.CAMPAIGNS_STARTED = e.CAMPAIGNS_STARTED AND a.CAMPAIGNS_ACTIVE = e.CAMPAIGNS_ACTIVE
           AND m.CAMPAIGN_MONTHS = e.CAMPAIGN_MONTHS AND m.SPEND = e.SPEND AND m.LEADS = e.LEADS
           AND m.CONVERSIONS = e.CONVERSIONS AND m.REVENUE = e.REVENUE AND m.BUDGET_PRORATED = e.BUDGET_PRORATED,
           'PASS', 'FAIL') AS STATUS
FROM monthly m
FULL OUTER JOIN expected e ON e.YEAR = m.YEAR
LEFT JOIN started s ON s.YEAR = COALESCE(m.YEAR, e.YEAR)
LEFT JOIN active  a ON a.YEAR = COALESCE(m.YEAR, e.YEAR)
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 14. MART_CHANNEL_PERFORMANCE: the bases, against the baseline, the publisher and the campaign table
--    Question: does the channel scorecard carry the channel funnel exactly, by two independent
--      routes?
--    Why: the mart aggregates the Phase 3 facts straight to the channel. Its bases must equal
--      (a) the baseline [P3 kpi_channel_bases], whose spend and revenue are the publisher
--      reference [PUB], an outside check of the whole path, and (b) the SUM by channel of
--      MART_CAMPAIGN_PERFORMANCE, built from STAGING by campaign. GROUP BY ROLLUP adds the TOTAL
--      row on both sides. A missing or unexpected channel is its own FAIL row.
--    Expected: the 6 rows of [P3 kpi_channel_bases] (TRIALS = conversions - purchases there).
-- -----------------------------------------------------------------------------
WITH mart AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_TOTAL,
         SUM(CAMPAIGNS) AS CAMPAIGNS, SUM(BUDGET) AS BUDGET, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(TRIALS) AS TRIALS,
         SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM MART_CHANNEL_PERFORMANCE
  GROUP BY ROLLUP (CHANNEL)
),
campaign_rollup AS (        -- the Phase 3 campaign table summed by channel
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL) AS CHANNEL,
         COUNT(*) AS CAMPAIGNS, SUM(BUDGET) AS BUDGET, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(TRIALS) AS TRIALS,
         SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM MART_CAMPAIGN_PERFORMANCE
  GROUP BY ROLLUP (CHANNEL)
),
expected (CHANNEL, CAMPAIGNS, BUDGET, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE) AS (
  SELECT * FROM VALUES   -- spend and revenue: [PUB]; all columns: [P3 kpi_channel_bases]
    ('affiliate',    24, 1025491.41,  857835.07,  95314042, 2386856,  67849, 10352,  6020,  4332,  5610700.73),
    ('display',      24, 1138158.37,  955297.00, 146967688,  879874,  45149,  6744,  3873,  2871,  3734117.43),
    ('paid_search',  24, 1079299.66,  897091.53,  49837405, 1740314,  65268, 10019,  5815,  4204,  5439329.35),
    ('paid_social',  24, 1180823.70,  984731.88,  89520215, 1602785,  57619,  8648,  5002,  3646,  4690137.28),
    ('video',        24,  994869.02,  828094.54,  55205469,  492490,  25799,  3933,  2295,  1638,  2087554.22),
    ('TOTAL',       120, 5418642.16, 4523050.02, 436844819, 7102319, 261684, 39696, 23005, 16691, 21561839.01)
)
SELECT COALESCE(m.CHANNEL, e.CHANNEL) AS CHANNEL, m.CAMPAIGNS, m.BUDGET, m.SPEND, m.IMPRESSIONS, m.CLICKS, m.LEADS,
       m.CONVERTED_LEADS, m.TRIALS, m.PURCHASES, m.REVENUE,
       IFF(m.SPEND = e.SPEND AND m.REVENUE = e.REVENUE, 'yes', 'NO') AS EQUALS_PUBLISHER,
       IFF(m.CAMPAIGNS = r.CAMPAIGNS AND m.BUDGET = r.BUDGET AND m.SPEND = r.SPEND AND m.IMPRESSIONS = r.IMPRESSIONS
           AND m.CLICKS = r.CLICKS AND m.LEADS = r.LEADS AND m.CONVERTED_LEADS = r.CONVERTED_LEADS AND m.TRIALS = r.TRIALS
           AND m.PURCHASES = r.PURCHASES AND m.REVENUE = r.REVENUE, 'yes', 'NO') AS EQUALS_CAMPAIGN_ROLLUP,
       IFF(m.CAMPAIGNS = e.CAMPAIGNS AND m.BUDGET = e.BUDGET AND m.SPEND = e.SPEND AND m.IMPRESSIONS = e.IMPRESSIONS
           AND m.CLICKS = e.CLICKS AND m.LEADS = e.LEADS AND m.CONVERTED_LEADS = e.CONVERTED_LEADS AND m.TRIALS = e.TRIALS
           AND m.PURCHASES = e.PURCHASES AND m.REVENUE = e.REVENUE
           AND m.CAMPAIGNS = r.CAMPAIGNS AND m.BUDGET = r.BUDGET AND m.SPEND = r.SPEND AND m.IMPRESSIONS = r.IMPRESSIONS
           AND m.CLICKS = r.CLICKS AND m.LEADS = r.LEADS AND m.CONVERTED_LEADS = r.CONVERTED_LEADS AND m.TRIALS = r.TRIALS
           AND m.PURCHASES = r.PURCHASES AND m.REVENUE = r.REVENUE, 'PASS', 'FAIL') AS STATUS
FROM mart m
FULL OUTER JOIN expected        e ON e.CHANNEL = m.CHANNEL
FULL OUTER JOIN campaign_rollup r ON r.CHANNEL = COALESCE(m.CHANNEL, e.CHANNEL)
ORDER BY COALESCE(m.IS_TOTAL, 1), m.SPEND DESC;


-- -----------------------------------------------------------------------------
-- 15. MART_CHANNEL_PERFORMANCE: the channel-grain ratios
--    Question: are the stored channel KPIs the ratios of the channel sums, exactly?
--    Why: these are the numbers the scorecard shows. Two independent checks: (a) the values of
--      the baseline, divided and rounded outside Snowflake ([P3 kpi_channel_ratios] for the
--      nine campaign-table KPIs, [D] for CPC and CPM), and (b) the same ratios recomputed here
--      as SUM(numerator) / SUM(denominator) of MART_CAMPAIGN_PERFORMANCE by channel, the way
--      Data Studio must aggregate the campaign table. A swapped numerator, a wrong scale or a
--      double rounding fails both. ROAS is attributed revenue / spend (G4).
--    Expected: [P3 kpi_channel_ratios]; CPC and CPM [D].
-- -----------------------------------------------------------------------------
WITH campaign_ratios AS (   -- the campaign table rolled up, ratios of sums, dividend cast so ROUND is the only rounding
  SELECT CHANNEL,
         ROUND(SUM(CLICKS)::NUMBER(32,18)          / NULLIF(SUM(IMPRESSIONS), 0), 6)     AS CTR,
         ROUND(SUM(LEADS)::NUMBER(32,18)           / NULLIF(SUM(CLICKS), 0), 6)          AS CLICK_TO_LEAD_RATE,
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 6)           AS LEAD_CONVERSION_RATE,
         ROUND(SUM(PURCHASES)::NUMBER(32,18)       / NULLIF(SUM(LEADS), 0), 6)           AS PURCHASE_RATE,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(LEADS), 0), 4)           AS COST_PER_LEAD,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(CONVERTED_LEADS), 0), 4) AS COST_PER_CONVERSION,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(PURCHASES), 0), 4)       AS COST_PER_PURCHASE,
         ROUND(SUM(REVENUE)::NUMBER(32,18)         / NULLIF(SUM(SPEND), 0), 6)           AS ROAS,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(BUDGET), 0), 6)          AS BUDGET_UTILIZATION,
         ROUND(SUM(SPEND)::NUMBER(32,18)           / NULLIF(SUM(CLICKS), 0), 4)          AS CPC,
         ROUND((SUM(SPEND) * 1000)::NUMBER(32,18)  / NULLIF(SUM(IMPRESSIONS), 0), 4)     AS CPM
  FROM MART_CAMPAIGN_PERFORMANCE
  GROUP BY CHANNEL
),
expected (CHANNEL, CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_RATE, COST_PER_LEAD, COST_PER_CONVERSION,
          COST_PER_PURCHASE, ROAS, BUDGET_UTILIZATION, CPC, CPM) AS (
  SELECT * FROM VALUES   -- [P3 kpi_channel_ratios]; CPC, CPM [D]
    ('affiliate',   0.025042, 0.028426, 0.152574, 0.063848, 12.6433,  82.8666, 198.0229, 6.540536, 0.836511, 0.3594,  9.0001),
    ('display',     0.005987, 0.051313, 0.149372, 0.063589, 21.1588, 141.6514, 332.7402, 3.908855, 0.839336, 1.0857,  6.5000),
    ('paid_search', 0.034920, 0.037504, 0.153506, 0.064411, 13.7447,  89.5390, 213.3900, 6.063294, 0.831179, 0.5155, 18.0004),
    ('paid_social', 0.017904, 0.035949, 0.150089, 0.063278, 17.0904, 113.8682, 270.0855, 4.762857, 0.833936, 0.6144, 11.0001),
    ('video',       0.008921, 0.052385, 0.152448, 0.063491, 32.0979, 210.5504, 505.5522, 2.520913, 0.832365, 1.6814, 15.0002)
)
SELECT COALESCE(m.CHANNEL, e.CHANNEL) AS CHANNEL, m.CTR, m.CLICK_TO_LEAD_RATE, m.LEAD_CONVERSION_RATE, m.PURCHASE_RATE,
       m.COST_PER_LEAD, m.COST_PER_CONVERSION, m.COST_PER_PURCHASE, m.ROAS, m.BUDGET_UTILIZATION, m.CPC, m.CPM,
       IFF(m.CTR = r.CTR AND m.CLICK_TO_LEAD_RATE = r.CLICK_TO_LEAD_RATE AND m.LEAD_CONVERSION_RATE = r.LEAD_CONVERSION_RATE
           AND m.PURCHASE_RATE = r.PURCHASE_RATE AND m.COST_PER_LEAD = r.COST_PER_LEAD
           AND m.COST_PER_CONVERSION = r.COST_PER_CONVERSION AND m.COST_PER_PURCHASE = r.COST_PER_PURCHASE
           AND m.ROAS = r.ROAS AND m.BUDGET_UTILIZATION = r.BUDGET_UTILIZATION AND m.CPC = r.CPC AND m.CPM = r.CPM,
           'yes', 'NO') AS EQUALS_CAMPAIGN_ROLLUP,
       IFF(m.CTR = e.CTR AND m.CLICK_TO_LEAD_RATE = e.CLICK_TO_LEAD_RATE AND m.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE
           AND m.PURCHASE_RATE = e.PURCHASE_RATE AND m.COST_PER_LEAD = e.COST_PER_LEAD
           AND m.COST_PER_CONVERSION = e.COST_PER_CONVERSION AND m.COST_PER_PURCHASE = e.COST_PER_PURCHASE
           AND m.ROAS = e.ROAS AND m.BUDGET_UTILIZATION = e.BUDGET_UTILIZATION AND m.CPC = e.CPC AND m.CPM = e.CPM
           AND m.CTR = r.CTR AND m.CLICK_TO_LEAD_RATE = r.CLICK_TO_LEAD_RATE AND m.LEAD_CONVERSION_RATE = r.LEAD_CONVERSION_RATE
           AND m.PURCHASE_RATE = r.PURCHASE_RATE AND m.COST_PER_LEAD = r.COST_PER_LEAD
           AND m.COST_PER_CONVERSION = r.COST_PER_CONVERSION AND m.COST_PER_PURCHASE = r.COST_PER_PURCHASE
           AND m.ROAS = r.ROAS AND m.BUDGET_UTILIZATION = r.BUDGET_UTILIZATION AND m.CPC = r.CPC AND m.CPM = r.CPM,
           'PASS', 'FAIL') AS STATUS
FROM MART_CHANNEL_PERFORMANCE m
FULL OUTER JOIN expected        e ON e.CHANNEL = m.CHANNEL
FULL OUTER JOIN campaign_ratios r ON r.CHANNEL = COALESCE(m.CHANNEL, e.CHANNEL)
ORDER BY m.ROAS DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 16. MART_CHANNEL_PERFORMANCE: Wilson interval and shares
--    Question: are the interval bounds and the shares exactly the independently computed
--      values, and does each interval bracket its rate?
--    Why: the bounds are the one FLOAT computation in the marts (SQRT). [D] computed them twice
--      outside Snowflake, exactly (60 digits) and in float, with the same 6-dp result; no exact
--      bound lies within 4 x 10^-8 of a rounding midpoint, so an exact comparison is safe.
--      CONTAINS_POOLED_RATE (descriptive here, counted in block 17) shows whether the pooled
--      rate of all channels, 0.151694 [P3], lies inside the interval. CI_WIDTH is descriptive.
--    Expected: shares and bounds [D]; LCR_CI_LOW < LEAD_CONVERSION_RATE < LCR_CI_HIGH, all
--      inside 0..1, in every row.
-- -----------------------------------------------------------------------------
WITH expected (CHANNEL, SPEND_SHARE, LEADS_SHARE, REVENUE_SHARE, LCR_CI_LOW, LCR_CI_HIGH) AS (
  SELECT * FROM VALUES   -- [D]
    ('affiliate',   0.189659, 0.259278, 0.260214, 0.149888, 0.155299),
    ('display',     0.211206, 0.172533, 0.173182, 0.146114, 0.152690),
    ('paid_search', 0.198338, 0.249415, 0.252266, 0.150760, 0.156291),
    ('paid_social', 0.217714, 0.220185, 0.217520, 0.147196, 0.153029),
    ('video',       0.183083, 0.098588, 0.096817, 0.148113, 0.156886)
)
SELECT COALESCE(m.CHANNEL, e.CHANNEL) AS CHANNEL, m.LEADS, m.CONVERTED_LEADS, m.LCR_CI_LOW, m.LEAD_CONVERSION_RATE,
       m.LCR_CI_HIGH, m.LCR_CI_HIGH - m.LCR_CI_LOW AS CI_WIDTH,
       IFF(0.151694 BETWEEN m.LCR_CI_LOW AND m.LCR_CI_HIGH, 'yes', 'no') AS CONTAINS_POOLED_RATE,
       m.SPEND_SHARE, m.LEADS_SHARE, m.REVENUE_SHARE,
       IFF(m.LCR_CI_LOW = e.LCR_CI_LOW AND m.LCR_CI_HIGH = e.LCR_CI_HIGH
           AND m.SPEND_SHARE = e.SPEND_SHARE AND m.LEADS_SHARE = e.LEADS_SHARE AND m.REVENUE_SHARE = e.REVENUE_SHARE
           AND m.LCR_CI_LOW < m.LEAD_CONVERSION_RATE AND m.LEAD_CONVERSION_RATE < m.LCR_CI_HIGH
           AND m.LCR_CI_LOW > 0 AND m.LCR_CI_HIGH < 1, 'PASS', 'FAIL') AS STATUS
FROM MART_CHANNEL_PERFORMANCE m
FULL OUTER JOIN expected e ON e.CHANNEL = m.CHANNEL
ORDER BY m.LEAD_CONVERSION_RATE DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 17. MART_CHANNEL_PERFORMANCE: sanity and the aggregate funnel
--    Question: are the channel numbers internally consistent, and what do the intervals say
--      about the channel differences in lead conversion rate?
--    Why:
--      - The funnel is an aggregate campaign funnel (G2): impressions > clicks > leads >
--        converted leads count different units, and TRIALS + PURCHASES = CONVERTED_LEADS
--        because each converted lead has exactly one outcome (checks 3-4).
--      - Rates inside 0..1, no channel over budget, purchases a subset of conversions, cost per
--        lead <= per conversion <= per purchase (checks 5-8).
--      - The shares are rounded per row, so their sums are compared exactly with the sums of
--        the rounded [D] values, not with 1 (checks 9-11).
--      - Checks 12-13: every channel interval contains the pooled rate, and no two channel
--        intervals are disjoint. Under the interval assumptions (independent leads, sampling
--        noise only) the channel differences in LEAD_CONVERSION_RATE are within noise. Overlap
--        is not a formal test, and nothing here is causal.
--    Expected: 5 channels; 0 for checks 2-8 [C]; share sums 1.000000 / 0.999999 / 0.999999 [D];
--      5 and 0 [D].
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'channels evaluated' AS CHECK_NAME, COUNT(*) AS ACTUAL, 5 AS EXPECTED FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 2, 'channels with a NULL ratio (a zero denominator)',
                   COUNT_IF(CTR IS NULL OR CLICK_TO_LEAD_RATE IS NULL OR LEAD_CONVERSION_RATE IS NULL OR PURCHASE_RATE IS NULL
                            OR COST_PER_LEAD IS NULL OR COST_PER_CONVERSION IS NULL OR COST_PER_PURCHASE IS NULL OR ROAS IS NULL
                            OR BUDGET_UTILIZATION IS NULL OR CPC IS NULL OR CPM IS NULL OR SPEND_SHARE IS NULL
                            OR LEADS_SHARE IS NULL OR REVENUE_SHARE IS NULL OR LCR_CI_LOW IS NULL OR LCR_CI_HIGH IS NULL), 0
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 3, 'channels where the funnel counts do not fall: IMPRESSIONS > CLICKS > LEADS > CONVERTED_LEADS',
                   COUNT_IF(NOT (IMPRESSIONS > CLICKS AND CLICKS > LEADS AND LEADS > CONVERTED_LEADS)), 0
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 4, 'channels where TRIALS + PURCHASES <> CONVERTED_LEADS (two outcomes, not two stages)',
                   COUNT_IF(TRIALS + PURCHASES <> CONVERTED_LEADS), 0 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 5, 'rates or shares outside 0..1',
                   COUNT_IF(CTR NOT BETWEEN 0 AND 1 OR CLICK_TO_LEAD_RATE NOT BETWEEN 0 AND 1
                            OR LEAD_CONVERSION_RATE NOT BETWEEN 0 AND 1 OR PURCHASE_RATE NOT BETWEEN 0 AND 1
                            OR SPEND_SHARE NOT BETWEEN 0 AND 1 OR LEADS_SHARE NOT BETWEEN 0 AND 1
                            OR REVENUE_SHARE NOT BETWEEN 0 AND 1), 0
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 6, 'BUDGET_UTILIZATION > 1 (channel over budget)', COUNT_IF(BUDGET_UTILIZATION > 1), 0 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 7, 'PURCHASE_RATE > LEAD_CONVERSION_RATE', COUNT_IF(PURCHASE_RATE > LEAD_CONVERSION_RATE), 0
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 8, 'cost per lead > per conversion, or per conversion > per purchase',
                   COUNT_IF(COST_PER_LEAD > COST_PER_CONVERSION OR COST_PER_CONVERSION > COST_PER_PURCHASE), 0
            FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 9, 'SUM(SPEND_SHARE) (rounded per row)', SUM(SPEND_SHARE), 1.000000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 10, 'SUM(LEADS_SHARE) (rounded per row)', SUM(LEADS_SHARE), 0.999999 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 11, 'SUM(REVENUE_SHARE) (rounded per row)', SUM(REVENUE_SHARE), 0.999999 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 12, 'channels whose 95% interval contains the pooled rate 0.151694',
                   COUNT_IF(0.151694 BETWEEN LCR_CI_LOW AND LCR_CI_HIGH), 5 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 13, 'channel pairs whose 95% intervals do not overlap',
                   (SELECT COUNT(*) FROM MART_CHANNEL_PERFORMANCE x JOIN MART_CHANNEL_PERFORMANCE y
                      ON x.CHANNEL < y.CHANNEL AND (x.LCR_CI_HIGH < y.LCR_CI_LOW OR y.LCR_CI_HIGH < x.LCR_CI_LOW)), 0
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 18. MART_LEAD_QUALITY: all 50 rows against the independent computation
--    Question: does every channel x band row carry exactly its leads, score sum, conversions,
--      revenue and lag sum, and the right band edges and segment?
--    Why: totals and roll-ups (block 19) could hide leads moved between neighbouring bands (an
--      off-by-one edge moves about 2,600 leads per score value); a row-by-row comparison cannot.
--      The 50 expected rows were computed from the CSV files in Python [D]; the band edges and
--      segments come from the contract [C]. FULL OUTER JOIN: a missing or extra row lowers the
--      matching count. The last check confirms the band segments against the Phase 3 segment
--      of every lead (FCT_LEAD_CONVERSIONS.LEAD_SCORE_SEGMENT): 0 leads whose band has another
--      segment, or no band at all.
--    Expected: 50 rows joined, 50 matching in every check [D, C]; 0 misaligned leads.
-- -----------------------------------------------------------------------------
WITH bands (SCORE_BAND, SCORE_BAND_MIN, SCORE_BAND_MAX, LEAD_SCORE_SEGMENT) AS (   -- [C]
  SELECT * FROM VALUES
    ('01-10',   1,  10, 'Low'),    ('11-20',  11,  20, 'Low'),    ('21-30',  21,  30, 'Low'),    ('31-40',  31,  40, 'Low'),
    ('41-50',  41,  50, 'Medium'), ('51-60',  51,  60, 'Medium'), ('61-70',  61,  70, 'Medium'),
    ('71-80',  71,  80, 'High'),   ('81-90',  81,  90, 'High'),   ('91-100', 91, 100, 'High')
),
expected (CHANNEL, SCORE_BAND, LEADS, SUM_LEAD_SCORE, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, SUM_DAYS_TO_CONVERT) AS (
  SELECT * FROM VALUES   -- [D]
    ('affiliate', '01-10', 6688, 36495, 424, 274, 150, 187334.49, 4527),
    ('affiliate', '11-20', 6792, 105150, 533, 321, 212, 267340.32, 5453),
    ('affiliate', '21-30', 6798, 173320, 712, 394, 318, 422688.72, 7488),
    ('affiliate', '31-40', 6783, 240891, 857, 491, 366, 478078.11, 8955),
    ('affiliate', '41-50', 6956, 316676, 979, 528, 451, 598996.17, 10006),
    ('affiliate', '51-60', 6703, 372137, 1054, 616, 438, 557136.06, 11323),
    ('affiliate', '61-70', 6820, 446525, 1224, 754, 470, 599454.88, 12845),
    ('affiliate', '71-80', 6625, 500236, 1336, 733, 603, 768185.92, 13971),
    ('affiliate', '81-90', 6792, 580764, 1558, 906, 652, 872723.19, 16390),
    ('affiliate', '91-100', 6892, 658388, 1675, 1003, 672, 858762.87, 17690),
    ('display', '01-10', 4548, 24955, 303, 172, 131, 185806.75, 3225),
    ('display', '11-20', 4470, 69012, 344, 209, 135, 166655.18, 3500),
    ('display', '21-30', 4417, 112198, 428, 239, 189, 261359.99, 4445),
    ('display', '31-40', 4565, 161950, 559, 325, 234, 282364.09, 6052),
    ('display', '41-50', 4547, 206756, 669, 392, 277, 378700.13, 7195),
    ('display', '51-60', 4520, 250899, 699, 412, 287, 384788.35, 7167),
    ('display', '61-70', 4563, 298774, 801, 463, 338, 421960.04, 8219),
    ('display', '71-80', 4441, 335350, 912, 511, 401, 511222.74, 9663),
    ('display', '81-90', 4501, 384594, 983, 550, 433, 566038.86, 10165),
    ('display', '91-100', 4577, 437190, 1046, 600, 446, 575221.30, 11249),
    ('paid_search', '01-10', 6482, 35507, 397, 225, 172, 232966.53, 4254),
    ('paid_search', '11-20', 6492, 100514, 535, 308, 227, 266820.13, 5593),
    ('paid_search', '21-30', 6338, 161547, 636, 379, 257, 328081.52, 6842),
    ('paid_search', '31-40', 6532, 232237, 803, 462, 341, 424777.87, 8647),
    ('paid_search', '41-50', 6585, 299995, 946, 574, 372, 492933.18, 9839),
    ('paid_search', '51-60', 6565, 364345, 1089, 638, 451, 579671.71, 11308),
    ('paid_search', '61-70', 6592, 431926, 1221, 717, 504, 657541.90, 13023),
    ('paid_search', '71-80', 6699, 506080, 1368, 791, 577, 753710.99, 14525),
    ('paid_search', '81-90', 6537, 558958, 1478, 845, 633, 843329.74, 15339),
    ('paid_search', '91-100', 6446, 615458, 1546, 876, 670, 859495.78, 15847),
    ('paid_social', '01-10', 5850, 31960, 355, 224, 131, 169639.04, 3706),
    ('paid_social', '11-20', 5847, 90937, 452, 259, 193, 261687.76, 4693),
    ('paid_social', '21-30', 5602, 142988, 578, 326, 252, 331086.05, 6185),
    ('paid_social', '31-40', 5830, 206977, 675, 395, 280, 355562.67, 7109),
    ('paid_social', '41-50', 5671, 258224, 769, 445, 324, 418900.42, 7918),
    ('paid_social', '51-60', 5728, 317695, 920, 501, 419, 515701.16, 9651),
    ('paid_social', '61-70', 5761, 377594, 1102, 650, 452, 573433.06, 11602),
    ('paid_social', '71-80', 5788, 436406, 1162, 669, 493, 637991.73, 12341),
    ('paid_social', '81-90', 5699, 487559, 1209, 715, 494, 630421.15, 12878),
    ('paid_social', '91-100', 5843, 557933, 1426, 818, 608, 795714.24, 15390),
    ('video', '01-10', 2625, 14700, 163, 95, 68, 73999.48, 1820),
    ('video', '11-20', 2457, 37709, 208, 110, 98, 125967.66, 2298),
    ('video', '21-30', 2593, 66068, 270, 163, 107, 129634.39, 3087),
    ('video', '31-40', 2536, 89777, 273, 169, 104, 124065.35, 2954),
    ('video', '41-50', 2534, 115555, 361, 194, 167, 207158.35, 3870),
    ('video', '51-60', 2657, 147312, 433, 244, 189, 246313.57, 4448),
    ('video', '61-70', 2660, 174350, 491, 284, 207, 275657.50, 5046),
    ('video', '71-80', 2631, 198701, 538, 305, 233, 309785.69, 5262),
    ('video', '81-90', 2539, 217099, 567, 353, 214, 264549.57, 5710),
    ('video', '91-100', 2567, 245266, 629, 378, 251, 330422.66, 6316)
),
misaligned AS (             -- leads whose Phase 3 segment differs from the segment of their band, or with no band
  SELECT COUNT(*) AS LEADS
  FROM FCT_LEAD_CONVERSIONS f
  LEFT JOIN bands b ON f.LEAD_SCORE BETWEEN b.SCORE_BAND_MIN AND b.SCORE_BAND_MAX   -- bands do not overlap: 0..1 match
  WHERE b.SCORE_BAND IS NULL OR b.LEAD_SCORE_SEGMENT IS DISTINCT FROM f.LEAD_SCORE_SEGMENT
),
matches AS (
  SELECT COUNT(*) AS ROWS_JOINED,
         COUNT_IF(q.SCORE_BAND_MIN = b.SCORE_BAND_MIN AND q.SCORE_BAND_MAX = b.SCORE_BAND_MAX) AS BAND_EDGES,
         COUNT_IF(q.LEAD_SCORE_SEGMENT = b.LEAD_SCORE_SEGMENT)     AS LEAD_SCORE_SEGMENT,
         COUNT_IF(q.LEADS = e.LEADS)                               AS LEADS,
         COUNT_IF(q.SUM_LEAD_SCORE = e.SUM_LEAD_SCORE)             AS SUM_LEAD_SCORE,
         COUNT_IF(q.CONVERTED_LEADS = e.CONVERTED_LEADS)           AS CONVERTED_LEADS,
         COUNT_IF(q.TRIALS = e.TRIALS)                             AS TRIALS,
         COUNT_IF(q.PURCHASES = e.PURCHASES)                       AS PURCHASES,
         COUNT_IF(q.REVENUE = e.REVENUE)                           AS REVENUE,
         COUNT_IF(q.SUM_DAYS_TO_CONVERT = e.SUM_DAYS_TO_CONVERT)   AS SUM_DAYS_TO_CONVERT
  FROM expected e
  LEFT JOIN bands b ON b.SCORE_BAND = e.SCORE_BAND                                     -- n:1
  FULL OUTER JOIN MART_LEAD_QUALITY q ON q.CHANNEL = e.CHANNEL AND q.SCORE_BAND = e.SCORE_BAND
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED AND ROWS_JOINED = 50, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT 'rows matching: ' || CHECK_ID AS CHECK_NAME, ROWS_MATCHING AS ACTUAL, 50 AS EXPECTED, ROWS_JOINED, 1 AS ORD
  FROM matches
  UNPIVOT (ROWS_MATCHING FOR CHECK_ID IN (BAND_EDGES, LEAD_SCORE_SEGMENT, LEADS, SUM_LEAD_SCORE, CONVERTED_LEADS, TRIALS,
                                          PURCHASES, REVENUE, SUM_DAYS_TO_CONVERT))
  UNION ALL
  SELECT 'rows joined (expected FULL OUTER JOIN mart)', ROWS_JOINED, 50, ROWS_JOINED, 0 FROM matches
  UNION ALL
  SELECT 'leads whose Phase 3 LEAD_SCORE_SEGMENT differs from their band, or without a band',
         (SELECT LEADS FROM misaligned), 0, (SELECT ROWS_JOINED FROM matches), 2
)
ORDER BY ORD, CHECK_NAME;


-- -----------------------------------------------------------------------------
-- 19. MART_LEAD_QUALITY: roll-ups to segment, band and channel
--    Question: summed the way the Lead Quality page will sum it, does the table reproduce the
--      segment sizes, the band sizes and the channel totals, and how does the conversion rate
--      vary with the score?
--    Why: the dashboard groups this table by LEAD_SCORE_SEGMENT, SCORE_BAND or CHANNEL with SUM.
--      CONVERSION_RATE is SUM(CONVERTED_LEADS) / SUM(LEADS), a ratio of sums, compared exactly.
--      In this synthetic data it rises with the score band; that is an association, and since
--      the scoring method is undocumented it is not evidence that the score predicts or
--      causes conversion (G5). AVG_LEAD_SCORE (SUM_LEAD_SCORE / LEADS) is descriptive.
--      A missing or unexpected group is its own FAIL row (FULL OUTER JOIN).
--    Expected: segments [P3 lead_score_segments] (104,245 / 78,862 / 78,577 leads; 9,505 /
--      12,758 / 17,433 converted); band leads [E01 18], band conversions, purchases, revenue
--      and rates [D]; channels [P3 kpi_channel_bases, kpi_channel_ratios], revenue [PUB].
-- -----------------------------------------------------------------------------
WITH actual AS (
  SELECT 'segment' AS LEVEL, LEAD_SCORE_SEGMENT AS GROUP_VALUE, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE,
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 6) AS CONVERSION_RATE,
         ROUND(SUM(SUM_LEAD_SCORE)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 4)  AS AVG_LEAD_SCORE
  FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL
  SELECT 'band', SCORE_BAND, SUM(LEADS), SUM(CONVERTED_LEADS), SUM(PURCHASES), SUM(REVENUE),
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 6),
         ROUND(SUM(SUM_LEAD_SCORE)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 4)
  FROM MART_LEAD_QUALITY GROUP BY SCORE_BAND
  UNION ALL
  SELECT 'channel', CHANNEL, SUM(LEADS), SUM(CONVERTED_LEADS), SUM(PURCHASES), SUM(REVENUE),
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 6),
         ROUND(SUM(SUM_LEAD_SCORE)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 4)
  FROM MART_LEAD_QUALITY GROUP BY CHANNEL
),
expected (LEVEL, GROUP_VALUE, ORD, LEADS, CONVERTED_LEADS, PURCHASES, REVENUE, CONVERSION_RATE) AS (
  SELECT * FROM VALUES
    ('segment', 'Low',          1, 104245,  9505, 3965, 5075916.10, 0.091179),   -- [P3 lead_score_segments]
    ('segment', 'Medium',       2,  78862, 12758, 5346, 6908346.48, 0.161776),
    ('segment', 'High',         3,  78577, 17433, 7380, 9577576.43, 0.221859),
    ('band',    '01-10',        4,  26193,  1642,  652,  849746.29, 0.062689),   -- leads [E01 18]; the rest [D]
    ('band',    '11-20',        5,  26058,  2072,  865, 1088471.05, 0.079515),
    ('band',    '21-30',        6,  25748,  2624, 1123, 1472850.67, 0.101911),
    ('band',    '31-40',        7,  26246,  3167, 1325, 1664848.09, 0.120666),
    ('band',    '41-50',        8,  26293,  3724, 1591, 2096688.25, 0.141635),
    ('band',    '51-60',        9,  26173,  4195, 1784, 2283610.85, 0.160280),
    ('band',    '61-70',       10,  26396,  4839, 1971, 2528047.38, 0.183323),
    ('band',    '71-80',       11,  26184,  5316, 2307, 2980897.07, 0.203025),
    ('band',    '81-90',       12,  26068,  5795, 2426, 3177062.51, 0.222303),
    ('band',    '91-100',      13,  26325,  6322, 2647, 3419616.85, 0.240152),
    ('channel', 'affiliate',   14,  67849, 10352, 4332, 5610700.73, 0.152574),   -- [P3]; revenue [PUB]
    ('channel', 'display',     15,  45149,  6744, 2871, 3734117.43, 0.149372),
    ('channel', 'paid_search', 16,  65268, 10019, 4204, 5439329.35, 0.153506),
    ('channel', 'paid_social', 17,  57619,  8648, 3646, 4690137.28, 0.150089),
    ('channel', 'video',       18,  25799,  3933, 1638, 2087554.22, 0.152448)
)
SELECT COALESCE(a.LEVEL, e.LEVEL) AS LEVEL, COALESCE(a.GROUP_VALUE, e.GROUP_VALUE) AS GROUP_VALUE, a.LEADS, a.CONVERTED_LEADS,
       a.PURCHASES, a.REVENUE, a.CONVERSION_RATE, a.AVG_LEAD_SCORE,
       IFF(a.LEADS = e.LEADS AND a.CONVERTED_LEADS = e.CONVERTED_LEADS AND a.PURCHASES = e.PURCHASES AND a.REVENUE = e.REVENUE
           AND a.CONVERSION_RATE = e.CONVERSION_RATE, 'PASS', 'FAIL') AS STATUS
FROM actual a
FULL OUTER JOIN expected e ON e.LEVEL = a.LEVEL AND e.GROUP_VALUE = a.GROUP_VALUE
ORDER BY e.ORD NULLS LAST, 1, 2;
