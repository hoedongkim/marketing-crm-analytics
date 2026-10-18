-- =============================================================================
-- Phase 6 / 07: dashboard validation - the numbers every Data Studio component must show
-- -----------------------------------------------------------------------------
-- Purpose
--   The read-only reference for checking the four-page Data Studio report that is built by
--   hand from docs/dashboard_spec.md. For every component of that spec (KPI cards, the table
--   behind each chart, the top rows of each table) it prints the numbers the report must show,
--   computed the way the report computes them: from the SAME MART tables, with the same default
--   aggregations, card filters and thin SUM(x) / SUM(y) calculated fields (dashboard_spec.md
--   section 0.5, all from docs/kpi_definitions.md), under the same filter. Each figure is then
--   checked against an independent reference (never the query under test or the table it
--   reads). docs/dashboard_validation.md turns this output into the sign-off checklist
--   (expected / observed / match).
-- Filter states (the spot checks of dashboard_spec.md, so the builder sets one set of filters)
--   default  report date range 2023-01-01..2025-12-31 (decision 9), all channels, no campaign
--   video    the Channel drop-down set to video; date range unchanged
--   2024     the date range control set to 2024-01-01..2024-12-31; all channels
--   plus     2025 where the spec spot-checks it (the "2025 vs 2024" strip P1-K1..P1-K5 and the
--            cohort block P2-09..P2-12) and the Campaign drop-down set to "Affiliate 2024 080".
--   The date control filters a chart only through its own date field: MM by MONTH_START, COH by
--   COHORT_MONTH, DAILY by ACTIVITY_DATE. CH, CAMP (its dates are Text, spec decision D3), LQ
--   and FUN have no date field, so in state 2024 they must show the default values. Block 0b
--   checks the Snowflake side of that: CH, LQ and FUN have no DATE / TIME / TIMESTAMP column,
--   and the date columns of the other sources are exactly the ones dashboard_spec.md 0.4 keeps
--   as dates or turns into Text. The card blocks of CH and LQ (6, 11, 15) therefore print no
--   2024 rows: such a row could only repeat the default check.
-- Data sources (codes of dashboard_spec.md section 0.3, all SELECT * of one MART table)
--   MM = MART_MONTHLY_MARKETING (activity), COH = MART_MONTHLY_COHORT (lead cohort),
--   CH = MART_CHANNEL_PERFORMANCE, CAMP = MART_CAMPAIGN_PERFORMANCE, LQ = MART_LEAD_QUALITY,
--   FUN = MART_CONVERSION_FUNNEL, DAILY = FCT_CAMPAIGN_DAILY_ACTIVITY.
-- Components (IDs of dashboard_spec.md) and the block that holds their numbers
--   setup   G2 gate test: one channel control across the seven sources            block 0c
--   page 1  P1-01..P1-07 KPI cards                                                 block 1
--           P1-K1..P1-K5 "2025 vs 2024" strip                                      block 2
--           P1-08 spend + campaigns in flight, P1-10 conversions + purchases,
--           P4-07 spend vs revenue: the monthly activity series (MM)               block 3, 3c
--           P1-09 leads by channel                                                 block 4
--           P1-11, P2-14, P4-11, P4-12: the campaign charts (CAMP)                 block 5, 5c
--   page 2  P2-01..P2-05 KPI cards (CH)                                            block 6
--           P2-06 funnel chart, P2-07 funnel stage table (FUN)                     block 7
--           P2-08 channel funnel comparison (CH)                                   block 8
--           P2-09 lead conversion rate by lead cohort month (COH)                  block 9
--           P2-10..P2-12 conversion time cards (COH, DAILY)                        block 10
--   page 3  P3-01..P3-05 KPI cards (LQ)                                            block 11
--           P3-06 conversion by score segment, P3-07 segment table                 block 12
--           P3-08 leads and conversion by score band                               block 13
--           P3-09 days to convert by channel, P3-10 channel lead quality,
--           P3-11 score mix by channel (LQ by CHANNEL)                             block 14
--   page 4  P4-01..P4-06 KPI cards (CH)                                            block 15
--           P4-08 channel efficiency, P4-09 spend share vs revenue share (CH)      block 16
--   extras  Campaign drop-down "Affiliate 2024 080" (P1-12, P2-13, P4-10)          block 17
--           display rounding guard                                                 block 18
--   P4-13 is a text box with numbers from docs/business_insights.md, not a chart.
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after the dbt build (make dbt-build or dbt-build-select):
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/07_dashboard_validation.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 27 statements,
--   well under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/07_dashboard_validation.txt.
-- Role
--   CRM_TRANSFORMER: it reads MART (the report's tables) and STAGING (the references).
--   CRM_REPORTER, the report's role, can run the MART side of every query, not the references.
-- Inputs
--   MARKETING_CRM.MART: the seven tables above. MARKETING_CRM.STAGING, references only: the dbt
--   seeds EXPECTED_TOTALS, EXPECTED_CAMPAIGN_KPI, PUBLISHER_CHANNEL_REFERENCE and the views
--   STG_CAMPAIGNS, STG_DAILY_SPEND, STG_LEADS, STG_CONVERSIONS.
-- Where the expected values come from (never from the query under test or its table)
--   [SEED]  dbt seeds made by scripts/independent_check.py from the published CSV files with
--           Python csv + decimal, no Snowflake: EXPECTED_TOTALS (control totals, segment sizes,
--           conversions in a later month, after campaign end), EXPECTED_CAMPAIGN_KPI (the bases
--           and budget of each of the 120 campaigns; rolled up here to channels and ranked here
--           for the campaign charts).
--   [PUB]   PUBLISHER_CHANNEL_REFERENCE: spend and attributed revenue by channel, typed in from
--           the publisher's dataset page (the outside check).
--   [E03] [E04] [E05] [E06] [E02cT]  Phase 4 evidence numbers, copied mechanically from
--           docs/evidence/03_overview.txt, 04_funnel.txt, 05_lead.txt, 06_efficiency.txt and
--           02c_analysis_marts_tests.txt (statement in brackets) into the VALUES lists below.
--           Those statements passed their own checks against [P3]/[D] (the local pre-load
--           profile and Python decimal). They carry the date-dependent references (2024,
--           2025, the monthly series) and the score, lag and interval figures.
--   [STG]   recomputed here from the STAGING views (the cleaned source rows, upstream of every
--           MART table), each fact aggregated to the target grain before any join. Used only
--           where no seed or evidence number exists (the video monthly series, video score
--           bands, video cohort shares, lag and after-end counts of a year): an independent
--           aggregation path, not independent data.
--   [C]     by construction (36 months, 12 months of a year, 5 channels).
-- Reading the results
--   KPI-card blocks (1, 6, 10, 11, 15, 17) print one row per card x state (block 2, the strip,
--   one row per card x channel set):
--     VALUE      the exact figure, 6 dp (counts print as e.g. 120.000000)
--     SHOWN      the card as the spec sets it: Compact numbers OFF, decimals 0 for counts and 2
--                for money, ratios, scores and days, Percent fields 2 dp ("15.17%")
--     COMPACT    the same card with Compact numbers ON at default precision (1 decimal, as in
--                Google's example 553,939 -> 553.9K), for values of 1,000 or more
--     COMPACT_2DP  the same with Decimal precision 2 (blocks 1 and 15: 4.52M, 39.70K)
--     REFERENCE  the independent value; REF_SOURCE where it comes from
--     NEAR_HALF  'yes' if the exact value is within 1e-9 of a rounding midpoint at the shown
--                precision: Data Studio rounds binary floating point and may show the last
--                digit 1 lower there (block 2 runs it on both years and both changes of the
--                strip; block 18 on every table cell)
--     STATUS     PASS if VALUE equals REFERENCE at the reference's precision (counts exactly,
--                money to the cent, rates 6 dp, costs and averages 4 dp)
--   Chart and table blocks print the chart's rows at the shown precision (percent columns end in
--   _PCT and are already x 100), plus EQUALS_... columns and STATUS. Integers and money compare
--   exactly. Every ratio divides a NUMBER(32,18) dividend, so the one ROUND is the only rounding.
-- Statement map (index printed by run_sql.py -> block; c = the check of the block before it)
--   [1-4] context   [5] 0a who/where   [6] 0b inputs   [7] 0c G2 gate values
--   Page 1: [8] 1 cards   [9] 2 "2025 vs 2024" strip   [10] 3 monthly activity series
--           [11] 3c series totals   [12] 4 leads by channel   [13] 5 campaign charts
--           [14] 5c campaign chart checks
--   Page 2: [15] 6 cards   [16] 7 funnel   [17] 8 channel funnel table   [18] 9 cohort series
--           [19] 10 conversion time cards
--   Page 3: [20] 11 cards   [21] 12 segments   [22] 13 score bands   [23] 14 channel charts
--   Page 4: [24] 15 cards   [25] 16 channel efficiency and shares
--   Extras: [26] 17 campaign drop-down   [27] 18 rounding guard
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.MART;


-- -----------------------------------------------------------------------------
-- 0a. Who ran this, where and when. Expect role CRM_TRANSFORMER with no secondary roles on
--     MARKETING_WH, schema MARKETING_CRM.MART.
-- -----------------------------------------------------------------------------
SELECT CURRENT_USER() AS USER_NAME, CURRENT_ROLE() AS ROLE_NAME, CURRENT_SECONDARY_ROLES() AS SECONDARY_ROLES,
       CURRENT_WAREHOUSE() AS WAREHOUSE_NAME, CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() AS SCHEMA_NAME,
       TO_VARCHAR(SYSDATE(), 'YYYY-MM-DD HH24:MI') || ' UTC' AS RUN_AT,
       IFF(CURRENT_ROLE() = 'CRM_TRANSFORMER' AND CURRENT_WAREHOUSE() = 'MARKETING_WH'
           AND CURRENT_DATABASE() = 'MARKETING_CRM' AND CURRENT_SCHEMA() = 'MART'
           AND PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles::STRING = '', 'PASS', 'FAIL') AS STATUS;


-- -----------------------------------------------------------------------------
-- 0b. Inputs: the seven report sources (dashboard_spec.md 0.3, with their row counts there)
--     and the three seeds. A missing table is a FAIL row (the expected list drives the join).
--     DATE_COLUMNS: the DATE / TIME / TIMESTAMP columns of each report source, read from
--     INFORMATION_SCHEMA.COLUMNS. The connector types each of them as a date, so these are the
--     only fields the date range control could filter on. Expected (dashboard_spec.md 0.4, D3):
--     CH, LQ and FUN have none, so the date control cannot change their charts (the
--     "2024: unchanged" rows of dashboard_validation.md); CAMP's three and DAILY's ACTIVITY_MONTH
--     are exactly the columns 0.4 turns into Text; MM, COH and DAILY keep one date field each
--     (DATE_FIELD_AFTER_SPEC). A date column added to a MART table later fails here until the
--     spec types it.
-- -----------------------------------------------------------------------------
WITH expected (TABLE_SCHEMA, TABLE_NAME, SOURCE_CODE, EXPECTED_ROWS, EXPECTED_DATE_COLUMNS, DATE_FIELD_AFTER_SPEC) AS (
  SELECT * FROM VALUES
    ('MART',    'MART_MONTHLY_MARKETING',      'MM',    180,   'MONTH_START',                       'MONTH_START'),
    ('MART',    'MART_MONTHLY_COHORT',         'COH',   180,   'COHORT_MONTH',                      'COHORT_MONTH'),
    ('MART',    'MART_CHANNEL_PERFORMANCE',    'CH',    5,     '',                                  'none'),
    ('MART',    'MART_CAMPAIGN_PERFORMANCE',   'CAMP',  120,   'END_DATE, START_DATE, START_MONTH', 'none (all three -> Text, D3)'),
    ('MART',    'MART_LEAD_QUALITY',           'LQ',    50,    '',                                  'none'),
    ('MART',    'MART_CONVERSION_FUNNEL',      'FUN',   25,    '',                                  'none'),
    ('MART',    'FCT_CAMPAIGN_DAILY_ACTIVITY', 'DAILY', 13760, 'ACTIVITY_DATE, ACTIVITY_MONTH',     'ACTIVITY_DATE; ACTIVITY_MONTH -> Text'),
    ('STAGING', 'EXPECTED_TOTALS',             'seed',  29,    NULL,                                NULL),
    ('STAGING', 'EXPECTED_CAMPAIGN_KPI',       'seed',  120,   NULL,                                NULL),
    ('STAGING', 'PUBLISHER_CHANNEL_REFERENCE', 'seed',  5,     NULL,                                NULL)
),
date_cols AS (
  SELECT TABLE_SCHEMA, TABLE_NAME, LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY COLUMN_NAME) AS DATE_COLUMNS
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE DATA_TYPE IN ('DATE', 'TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ')
  GROUP BY TABLE_SCHEMA, TABLE_NAME
)
SELECT e.TABLE_SCHEMA || '.' || e.TABLE_NAME AS OBJECT_NAME, e.SOURCE_CODE, t.TABLE_TYPE, t.ROW_COUNT, e.EXPECTED_ROWS,
       IFF(e.SOURCE_CODE = 'seed', '', COALESCE(d.DATE_COLUMNS, '(none)')) AS DATE_COLUMNS,
       COALESCE(e.DATE_FIELD_AFTER_SPEC, '') AS DATE_FIELD_AFTER_SPEC,
       IFF(t.ROW_COUNT = e.EXPECTED_ROWS
           AND (e.SOURCE_CODE = 'seed' OR COALESCE(d.DATE_COLUMNS, '') = e.EXPECTED_DATE_COLUMNS), 'PASS', 'FAIL') AS STATUS
FROM expected e
LEFT JOIN MARKETING_CRM.INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_SCHEMA = e.TABLE_SCHEMA AND t.TABLE_NAME = e.TABLE_NAME
LEFT JOIN date_cols d
  ON d.TABLE_SCHEMA = e.TABLE_SCHEMA AND d.TABLE_NAME = e.TABLE_NAME
ORDER BY e.TABLE_SCHEMA, e.SOURCE_CODE = 'seed', e.TABLE_NAME;


-- -----------------------------------------------------------------------------
-- 0c. Gate test G2 (dashboard_spec.md 1.4): one scorecard of SUM(LEADS) per data source (FUN:
--     the Leads row of a STAGE table), all channels and video. All seven must follow the one
--     channel control; a source that keeps 261,684 when video is selected is not reached by it.
--     MM, COH and DAILY need the full date range (they have a date field).
--     Expected: [SEED EXPECTED_TOTALS] leads; [SEED EXPECTED_CAMPAIGN_KPI] video leads.
-- -----------------------------------------------------------------------------
WITH per_source (CHECK_ID, SOURCE_CODE, ALL_CHANNELS, VIDEO) AS (
  SELECT 'a', 'MM', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM MART_MONTHLY_MARKETING
  UNION ALL SELECT 'b', 'COH', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM MART_MONTHLY_COHORT
  UNION ALL SELECT 'c', 'CAMP', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'd', 'LQ', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM MART_LEAD_QUALITY
  UNION ALL SELECT 'e', 'DAILY', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 'f', 'FUN (row Leads)', SUM(STAGE_VALUE), SUM(IFF(CHANNEL = 'video', STAGE_VALUE, 0))
            FROM MART_CONVERSION_FUNNEL WHERE STAGE = 'Leads'
  UNION ALL SELECT 'g', 'CH', SUM(LEADS), SUM(IFF(CHANNEL = 'video', LEADS, 0)) FROM MART_CHANNEL_PERFORMANCE
),
ref AS (
  SELECT (SELECT VALUE FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS WHERE METRIC = 'leads') AS ALL_CHANNELS,
         (SELECT SUM(LEADS) FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CHANNEL = 'video') AS VIDEO
)
SELECT p.CHECK_ID, p.SOURCE_CODE, p.ALL_CHANNELS, p.VIDEO, r.ALL_CHANNELS::NUMBER(38,0) AS REF_ALL, r.VIDEO AS REF_VIDEO,
       IFF(p.ALL_CHANNELS = r.ALL_CHANNELS AND p.VIDEO = r.VIDEO, 'PASS', 'FAIL') AS STATUS
FROM per_source p CROSS JOIN ref r
ORDER BY p.CHECK_ID;


-- =============================================================================
-- PAGE 1: MARKETING OVERVIEW
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. P1-01..P1-07 KPI cards, states default / video / 2024. Filters: date, channel.
--    WHAT THE REPORT DOES: P1-02..P1-06 sum MM (activity basis: spend by spend date,
--      conversions by conversion date) under the date range on MONTH_START; P1-01 counts
--      distinct CAMPAIGN_ID of DAILY with the card filter "In flight only" (IS_IN_FLIGHT = 1):
--      campaigns in flight on at least one day of the range; P1-07 is the lead-cohort rate on
--      COH (of the leads created in the range, the share that converted), never MM CONVERSIONS
--      / LEADS of the same months (decision 7).
--    Expected: default [SEED EXPECTED_TOTALS]; video [SEED EXPECTED_CAMPAIGN_KPI roll-up],
--      spend [PUB]; 2024 [E03 12] (campaigns active, spend, leads, conversions), [E03 7] (sum
--      of the 2024 impressions and clicks), [E04 16] (sum of the 2024 cohorts).
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER, DATE_FROM, DATE_TO) AS (
  SELECT COLUMN1, COLUMN2, COLUMN3, TO_DATE(COLUMN4), TO_DATE(COLUMN5) FROM VALUES
    ('default', 1, NULL,    '2023-01-01', '2025-12-31'),
    ('video',   2, 'video', '2023-01-01', '2025-12-31'),
    ('2024',    3, NULL,    '2024-01-01', '2024-12-31')
),
kpis (ID, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P1-01', 'Total campaigns',       'DAILY: COUNT_DISTINCT(CAMPAIGN_ID)',     'count', 0),
    ('P1-02', 'Total marketing spend', 'MM: SUM(SPEND)',                         'money', 2),
    ('P1-03', 'Total impressions',     'MM: SUM(IMPRESSIONS)',                   'count', 0),
    ('P1-04', 'Total clicks',          'MM: SUM(CLICKS)',                        'count', 0),
    ('P1-05', 'Total leads',           'MM: SUM(LEADS)',                         'count', 0),
    ('P1-06', 'Conversions (booked)',  'MM: SUM(CONVERSIONS)',                   'count', 0),
    ('P1-07', 'Conversion rate',       'COH: SUM(CONVERTED_LEADS)/SUM(LEADS)',   'pct',   6)
),
e03_years (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, SPEND, LEADS, CONVERSIONS, REVENUE, COST_PER_LEAD) AS (
  SELECT * FROM VALUES                    -- [E03 12]
    (2023, 48, 48, 1458262.41, 87549, 12779, 7075482.35, 16.6565),
    (2024, 50, 60, 1971198.34, 107371, 16148, 8677647.82, 18.3588),
    (2025, 22, 35, 1093589.27, 66764, 10769, 5808708.84, 16.3799)
),
e03_months (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5, COLUMN6, COLUMN7, COLUMN8, COLUMN9 FROM VALUES   -- [E03 7]
    ('2023-01-01', 3, 23686.55, 3236794, 26846, 1325, 110, 48, 52800.58),
    ('2023-02-01', 5, 49461.61, 4866080, 73735, 2825, 325, 138, 170806.55),
    ('2023-03-01', 10, 104283.65, 9813887, 175460, 6229, 798, 319, 393351.94),
    ('2023-04-01', 11, 104393.90, 9572073, 161209, 5748, 902, 390, 474970.42),
    ('2023-05-01', 14, 97734.10, 10047414, 120442, 5188, 811, 340, 435288.12),
    ('2023-06-01', 18, 123064.68, 12269872, 155305, 7491, 963, 416, 569578.22),
    ('2023-07-01', 16, 116810.98, 10016789, 164873, 7779, 1273, 541, 699206.04),
    ('2023-08-01', 18, 134065.09, 11592470, 199287, 9024, 1221, 523, 672633.67),
    ('2023-09-01', 18, 155294.61, 15617704, 258284, 10771, 1590, 677, 884815.77),
    ('2023-10-01', 19, 171832.62, 17486983, 279402, 10930, 1654, 716, 939852.38),
    ('2023-11-01', 16, 191171.25, 20749569, 305434, 10526, 1582, 697, 904954.17),
    ('2023-12-01', 17, 186463.37, 19437016, 306843, 9713, 1550, 661, 877224.49),
    ('2024-01-01', 12, 122943.61, 13104007, 165184, 6493, 1158, 485, 618809.35),
    ('2024-02-01', 11, 100601.92, 10406404, 141705, 5638, 794, 350, 441376.15),
    ('2024-03-01', 16, 130497.60, 11125570, 220466, 7576, 1063, 446, 568388.08),
    ('2024-04-01', 19, 196892.88, 14608167, 294204, 10413, 1424, 635, 795905.02),
    ('2024-05-01', 17, 177398.24, 13236736, 231211, 8898, 1550, 629, 813289.19),
    ('2024-06-01', 13, 129762.16, 11178475, 134643, 5954, 1035, 445, 581296.94),
    ('2024-07-01', 13, 115762.43, 10712011, 144079, 5895, 861, 365, 468529.67),
    ('2024-08-01', 18, 185052.08, 16908939, 346907, 10718, 1316, 537, 687143.69),
    ('2024-09-01', 20, 205363.34, 17869193, 402727, 11825, 1780, 738, 950923.18),
    ('2024-10-01', 18, 219378.73, 19061854, 376815, 11683, 1830, 749, 961348.25),
    ('2024-11-01', 19, 181790.58, 16211254, 284218, 10557, 1579, 655, 857423.40),
    ('2024-12-01', 18, 205754.77, 20725796, 349890, 11721, 1758, 712, 933214.90),
    ('2025-01-01', 16, 189821.49, 19580708, 319963, 10136, 1699, 723, 926132.23),
    ('2025-02-01', 13, 97550.77, 9704557, 178946, 6308, 1116, 480, 619062.19),
    ('2025-03-01', 12, 103654.48, 11850554, 164981, 7226, 1061, 449, 598344.60),
    ('2025-04-01', 13, 95842.28, 10640020, 145638, 6504, 969, 406, 544558.36),
    ('2025-05-01', 14, 109131.26, 11261990, 181634, 7506, 1183, 489, 629458.15),
    ('2025-06-01', 14, 94604.52, 10184559, 149656, 6371, 971, 380, 515898.62),
    ('2025-07-01', 15, 132922.32, 14172264, 221074, 7710, 1101, 462, 601132.60),
    ('2025-08-01', 14, 138359.57, 14979140, 236728, 7339, 1190, 476, 596182.42),
    ('2025-09-01', 11, 65610.05, 7477070, 89094, 3680, 700, 301, 381379.89),
    ('2025-10-01', 5, 48774.54, 5545040, 67223, 2826, 462, 182, 228041.53),
    ('2025-11-01', 3, 16510.95, 1520494, 26975, 1093, 256, 109, 137433.25),
    ('2025-12-01', 1, 807.04, 73366, 1238, 65, 61, 22, 31085.00)
),
e04_cohort (COHORT_MONTH, LEADS, CONVERTED_LEADS, CONVERTED_LATER_MONTH, CONVERSION_RATE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5 FROM VALUES                                         -- [E04 16]
    ('2023-01-01', 1325, 212, 102, 0.160000),
    ('2023-02-01', 2825, 427, 204, 0.151150),
    ('2023-03-01', 6229, 914, 320, 0.146733),
    ('2023-04-01', 5748, 880, 298, 0.153097),
    ('2023-05-01', 5188, 771, 258, 0.148612),
    ('2023-06-01', 7491, 1137, 432, 0.151782),
    ('2023-07-01', 7779, 1220, 379, 0.156832),
    ('2023-08-01', 9024, 1377, 535, 0.152593),
    ('2023-09-01', 10771, 1604, 549, 0.148918),
    ('2023-10-01', 10930, 1648, 543, 0.150778),
    ('2023-11-01', 10526, 1575, 536, 0.149629),
    ('2023-12-01', 9713, 1471, 457, 0.151447),
    ('2024-01-01', 6493, 975, 274, 0.150162),
    ('2024-02-01', 5638, 882, 362, 0.156438),
    ('2024-03-01', 7576, 1172, 471, 0.154699),
    ('2024-04-01', 10413, 1588, 635, 0.152502),
    ('2024-05-01', 8898, 1332, 417, 0.149697),
    ('2024-06-01', 5954, 918, 300, 0.154182),
    ('2024-07-01', 5895, 879, 318, 0.149109),
    ('2024-08-01', 10718, 1607, 609, 0.149935),
    ('2024-09-01', 11825, 1779, 608, 0.150444),
    ('2024-10-01', 11683, 1771, 549, 0.151588),
    ('2024-11-01', 10557, 1588, 558, 0.150422),
    ('2024-12-01', 11721, 1831, 631, 0.156215),
    ('2025-01-01', 10136, 1557, 489, 0.153611),
    ('2025-02-01', 6308, 930, 303, 0.147432),
    ('2025-03-01', 7226, 1099, 341, 0.152090),
    ('2025-04-01', 6504, 1036, 408, 0.159287),
    ('2025-05-01', 7506, 1113, 338, 0.148281),
    ('2025-06-01', 6371, 996, 363, 0.156333),
    ('2025-07-01', 7710, 1156, 418, 0.149935),
    ('2025-08-01', 7339, 1109, 337, 0.151111),
    ('2025-09-01', 3680, 513, 150, 0.139402),
    ('2025-10-01', 2826, 445, 133, 0.157466),
    ('2025-11-01', 1093, 173, 50, 0.158280),
    ('2025-12-01', 65, 11, 0, 0.169231)
),
monthly AS (                -- P1-02..P1-06 as the report computes them
  SELECT s.STATE, SUM(m.SPEND) AS SPEND, SUM(m.IMPRESSIONS) AS IMPRESSIONS, SUM(m.CLICKS) AS CLICKS,
         SUM(m.LEADS) AS LEADS, SUM(m.CONVERSIONS) AS CONVERSIONS
  FROM states s
  JOIN MART_MONTHLY_MARKETING m
    ON m.MONTH_START BETWEEN s.DATE_FROM AND s.DATE_TO AND (s.CHANNEL_FILTER IS NULL OR m.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE
),
cohort AS (                 -- P1-07
  SELECT s.STATE, SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(c.LEADS) AS COHORT_LEADS
  FROM states s
  JOIN MART_MONTHLY_COHORT c
    ON c.COHORT_MONTH BETWEEN s.DATE_FROM AND s.DATE_TO AND (s.CHANNEL_FILTER IS NULL OR c.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE
),
active AS (                 -- P1-01
  SELECT s.STATE, COUNT(DISTINCT a.CAMPAIGN_ID) AS CAMPAIGNS
  FROM states s
  JOIN FCT_CAMPAIGN_DAILY_ACTIVITY a
    ON a.ACTIVITY_DATE BETWEEN s.DATE_FROM AND s.DATE_TO AND (s.CHANNEL_FILTER IS NULL OR a.CHANNEL = s.CHANNEL_FILTER)
   AND a.IS_IN_FLIGHT = 1
  GROUP BY s.STATE
),
dash AS (
  SELECT s.STATE, s.STATE_NO, a.CAMPAIGNS, m.SPEND, m.IMPRESSIONS, m.CLICKS, m.LEADS, m.CONVERSIONS,
         c.CONVERTED_LEADS, c.COHORT_LEADS
  FROM states s
  LEFT JOIN active a  ON a.STATE = s.STATE
  LEFT JOIN monthly m ON m.STATE = s.STATE
  LEFT JOIN cohort c  ON c.STATE = s.STATE
),
seed_totals AS (
  SELECT MAX(IFF(METRIC = 'campaigns', VALUE, NULL))       AS CAMPAIGNS,
         MAX(IFF(METRIC = 'spend', VALUE, NULL))           AS SPEND,
         MAX(IFF(METRIC = 'impressions', VALUE, NULL))     AS IMPRESSIONS,
         MAX(IFF(METRIC = 'clicks', VALUE, NULL))          AS CLICKS,
         MAX(IFF(METRIC = 'leads', VALUE, NULL))           AS LEADS,
         MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERTED_LEADS
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
ref AS (
  SELECT 'default' AS STATE, CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS,
         CONVERTED_LEADS AS CONVERSIONS, CONVERTED_LEADS, LEADS AS COHORT_LEADS
  FROM seed_totals
  UNION ALL
  SELECT 'video', COUNT(*), (SELECT SPEND FROM MARKETING_CRM.STAGING.PUBLISHER_CHANNEL_REFERENCE WHERE CHANNEL = 'video'),
         SUM(IMPRESSIONS), SUM(CLICKS), SUM(LEADS), SUM(CONVERTED_LEADS), SUM(CONVERTED_LEADS), SUM(LEADS)
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI
  WHERE CHANNEL = 'video'
  UNION ALL
  SELECT '2024', y.CAMPAIGNS_ACTIVE, y.SPEND, m.IMPRESSIONS, m.CLICKS, y.LEADS, y.CONVERSIONS, c.CONVERTED_LEADS, c.LEADS
  FROM e03_years y
  CROSS JOIN (SELECT SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS FROM e03_months WHERE YEAR(MONTH_START) = 2024) m
  CROSS JOIN (SELECT SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(LEADS) AS LEADS FROM e04_cohort WHERE YEAR(COHORT_MONTH) = 2024) c
  WHERE y.YEAR = 2024
),
card_rows AS (
  SELECT k.ID, d.STATE, d.STATE_NO, k.COMPONENT, k.FIELD, k.KIND, k.DP,
         (CASE k.ID WHEN 'P1-01' THEN d.CAMPAIGNS   WHEN 'P1-02' THEN d.SPEND  WHEN 'P1-03' THEN d.IMPRESSIONS
                    WHEN 'P1-04' THEN d.CLICKS      WHEN 'P1-05' THEN d.LEADS  WHEN 'P1-06' THEN d.CONVERSIONS
                    WHEN 'P1-07' THEN d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.COHORT_LEADS, 0) END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P1-01' THEN r.CAMPAIGNS   WHEN 'P1-02' THEN r.SPEND  WHEN 'P1-03' THEN r.IMPRESSIONS
                    WHEN 'P1-04' THEN r.CLICKS      WHEN 'P1-05' THEN r.LEADS  WHEN 'P1-06' THEN r.CONVERSIONS
                    WHEN 'P1-07' THEN r.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(r.COHORT_LEADS, 0) END)::NUMBER(38,18) AS R,
         CASE WHEN d.STATE = 'default' THEN 'SEED EXPECTED_TOTALS'
              WHEN d.STATE = 'video' AND k.ID = 'P1-02' THEN 'PUB video spend'
              WHEN d.STATE = 'video' THEN 'SEED EXPECTED_CAMPAIGN_KPI, video'
              WHEN k.ID = 'P1-01' THEN 'E03 [12] CAMPAIGNS_ACTIVE 2024'
              WHEN k.ID IN ('P1-03', 'P1-04') THEN 'E03 [7] sum of the 2024 months'
              WHEN k.ID = 'P1-07' THEN 'E04 [16] sum of the 2024 cohorts'
              ELSE 'E03 [12] year 2024' END AS REF_SOURCE
  FROM dash d
  JOIN ref r ON r.STATE = d.STATE
  CROSS JOIN kpis k
)
SELECT ID, STATE, COMPONENT, FIELD,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       CASE WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000000 THEN TO_VARCHAR(ROUND(V / 1000000, 1), 'FM999,990.0') || 'M'
            WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000    THEN TO_VARCHAR(ROUND(V / 1000, 1), 'FM999,990.0') || 'K'
            ELSE '' END AS COMPACT,
       CASE WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000000 THEN TO_VARCHAR(ROUND(V / 1000000, 2), 'FM999,990.00') || 'M'
            WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000    THEN TO_VARCHAR(ROUND(V / 1000, 2), 'FM999,990.00') || 'K'
            ELSE '' END AS COMPACT_2DP,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM card_rows
ORDER BY ID, STATE_NO;


-- -----------------------------------------------------------------------------
-- 2. P1-K1..P1-K5 "2025 vs 2024" strip: each card has its own fixed date range 2025-01-01..
--    2025-12-31 and the comparison date range "Previous year" (2024-01-01..2024-12-31); it
--    follows the channel control only. Rows: all channels and video.
--    HOW TO READ: VALUE_2025 is the card, CHANGE the comparison label (percent change, shown by
--      Data Studio with 1 decimal next to an arrow), ABS_CHANGE what "Show absolute change"
--      shows instead. For the rate card both are changes of the rate: -0.11% relative,
--      -0.02% absolute (points). NEAR_HALF: 'yes' if VALUE_2025, VALUE_2024, ABS_CHANGE (2 dp)
--      or CHANGE (1 dp) sits within 1e-9 of a rounding midpoint (see the header).
--    TRAP (column IF_PREVIOUS_PERIOD, all channels only): "Previous period" would compare with
--      the 365 days before, 2024-01-02..2024-12-31 (2024 has 366 days). MM and COH key every
--      month on its 1st day, so that window drops January 2024 and the change is wrong.
--    Expected: all channels [E03 12] (active campaigns, spend, leads, conversions) and [E04 16]
--      (cohort sums per year); video [E06 13] (active campaigns, spend), [E03 9] (leads), [STG]
--      (conversions by conversion year, cohort rate by creation year); previous period [E03 7]
--      and [E04 16] without 2024-01, campaigns [STG] windows overlapping 2024-01-02..2024-12-31.
-- -----------------------------------------------------------------------------
WITH wins (WIN, DATE_FROM, DATE_TO) AS (
  SELECT COLUMN1, TO_DATE(COLUMN2), TO_DATE(COLUMN3) FROM VALUES
    ('2025', '2025-01-01', '2025-12-31'), ('2024', '2024-01-01', '2024-12-31'), ('pp', '2024-01-02', '2024-12-31')
),
chans (CHANNELS, CHANNEL_FILTER, CHANNEL_NO) AS (
  SELECT * FROM VALUES ('all channels', NULL, 1), ('video', 'video', 2)
),
cards (ID, CARD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P1-K1', 'Active campaigns', 'count', 0), ('P1-K2', 'Spend', 'money', 2), ('P1-K3', 'Leads', 'count', 0),
    ('P1-K4', 'Conversions (booked)', 'count', 0), ('P1-K5', 'Conversion rate (lead cohorts)', 'pct', 6)
),
e03_years (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, SPEND, LEADS, CONVERSIONS, REVENUE, COST_PER_LEAD) AS (
  SELECT * FROM VALUES                    -- [E03 12]
    (2023, 48, 48, 1458262.41, 87549, 12779, 7075482.35, 16.6565),
    (2024, 50, 60, 1971198.34, 107371, 16148, 8677647.82, 18.3588),
    (2025, 22, 35, 1093589.27, 66764, 10769, 5808708.84, 16.3799)
),
e03_months (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5, COLUMN6, COLUMN7, COLUMN8, COLUMN9 FROM VALUES   -- [E03 7]
    ('2023-01-01', 3, 23686.55, 3236794, 26846, 1325, 110, 48, 52800.58),
    ('2023-02-01', 5, 49461.61, 4866080, 73735, 2825, 325, 138, 170806.55),
    ('2023-03-01', 10, 104283.65, 9813887, 175460, 6229, 798, 319, 393351.94),
    ('2023-04-01', 11, 104393.90, 9572073, 161209, 5748, 902, 390, 474970.42),
    ('2023-05-01', 14, 97734.10, 10047414, 120442, 5188, 811, 340, 435288.12),
    ('2023-06-01', 18, 123064.68, 12269872, 155305, 7491, 963, 416, 569578.22),
    ('2023-07-01', 16, 116810.98, 10016789, 164873, 7779, 1273, 541, 699206.04),
    ('2023-08-01', 18, 134065.09, 11592470, 199287, 9024, 1221, 523, 672633.67),
    ('2023-09-01', 18, 155294.61, 15617704, 258284, 10771, 1590, 677, 884815.77),
    ('2023-10-01', 19, 171832.62, 17486983, 279402, 10930, 1654, 716, 939852.38),
    ('2023-11-01', 16, 191171.25, 20749569, 305434, 10526, 1582, 697, 904954.17),
    ('2023-12-01', 17, 186463.37, 19437016, 306843, 9713, 1550, 661, 877224.49),
    ('2024-01-01', 12, 122943.61, 13104007, 165184, 6493, 1158, 485, 618809.35),
    ('2024-02-01', 11, 100601.92, 10406404, 141705, 5638, 794, 350, 441376.15),
    ('2024-03-01', 16, 130497.60, 11125570, 220466, 7576, 1063, 446, 568388.08),
    ('2024-04-01', 19, 196892.88, 14608167, 294204, 10413, 1424, 635, 795905.02),
    ('2024-05-01', 17, 177398.24, 13236736, 231211, 8898, 1550, 629, 813289.19),
    ('2024-06-01', 13, 129762.16, 11178475, 134643, 5954, 1035, 445, 581296.94),
    ('2024-07-01', 13, 115762.43, 10712011, 144079, 5895, 861, 365, 468529.67),
    ('2024-08-01', 18, 185052.08, 16908939, 346907, 10718, 1316, 537, 687143.69),
    ('2024-09-01', 20, 205363.34, 17869193, 402727, 11825, 1780, 738, 950923.18),
    ('2024-10-01', 18, 219378.73, 19061854, 376815, 11683, 1830, 749, 961348.25),
    ('2024-11-01', 19, 181790.58, 16211254, 284218, 10557, 1579, 655, 857423.40),
    ('2024-12-01', 18, 205754.77, 20725796, 349890, 11721, 1758, 712, 933214.90),
    ('2025-01-01', 16, 189821.49, 19580708, 319963, 10136, 1699, 723, 926132.23),
    ('2025-02-01', 13, 97550.77, 9704557, 178946, 6308, 1116, 480, 619062.19),
    ('2025-03-01', 12, 103654.48, 11850554, 164981, 7226, 1061, 449, 598344.60),
    ('2025-04-01', 13, 95842.28, 10640020, 145638, 6504, 969, 406, 544558.36),
    ('2025-05-01', 14, 109131.26, 11261990, 181634, 7506, 1183, 489, 629458.15),
    ('2025-06-01', 14, 94604.52, 10184559, 149656, 6371, 971, 380, 515898.62),
    ('2025-07-01', 15, 132922.32, 14172264, 221074, 7710, 1101, 462, 601132.60),
    ('2025-08-01', 14, 138359.57, 14979140, 236728, 7339, 1190, 476, 596182.42),
    ('2025-09-01', 11, 65610.05, 7477070, 89094, 3680, 700, 301, 381379.89),
    ('2025-10-01', 5, 48774.54, 5545040, 67223, 2826, 462, 182, 228041.53),
    ('2025-11-01', 3, 16510.95, 1520494, 26975, 1093, 256, 109, 137433.25),
    ('2025-12-01', 1, 807.04, 73366, 1238, 65, 61, 22, 31085.00)
),
e04_cohort (COHORT_MONTH, LEADS, CONVERTED_LEADS, CONVERTED_LATER_MONTH, CONVERSION_RATE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5 FROM VALUES                                         -- [E04 16]
    ('2023-01-01', 1325, 212, 102, 0.160000),
    ('2023-02-01', 2825, 427, 204, 0.151150),
    ('2023-03-01', 6229, 914, 320, 0.146733),
    ('2023-04-01', 5748, 880, 298, 0.153097),
    ('2023-05-01', 5188, 771, 258, 0.148612),
    ('2023-06-01', 7491, 1137, 432, 0.151782),
    ('2023-07-01', 7779, 1220, 379, 0.156832),
    ('2023-08-01', 9024, 1377, 535, 0.152593),
    ('2023-09-01', 10771, 1604, 549, 0.148918),
    ('2023-10-01', 10930, 1648, 543, 0.150778),
    ('2023-11-01', 10526, 1575, 536, 0.149629),
    ('2023-12-01', 9713, 1471, 457, 0.151447),
    ('2024-01-01', 6493, 975, 274, 0.150162),
    ('2024-02-01', 5638, 882, 362, 0.156438),
    ('2024-03-01', 7576, 1172, 471, 0.154699),
    ('2024-04-01', 10413, 1588, 635, 0.152502),
    ('2024-05-01', 8898, 1332, 417, 0.149697),
    ('2024-06-01', 5954, 918, 300, 0.154182),
    ('2024-07-01', 5895, 879, 318, 0.149109),
    ('2024-08-01', 10718, 1607, 609, 0.149935),
    ('2024-09-01', 11825, 1779, 608, 0.150444),
    ('2024-10-01', 11683, 1771, 549, 0.151588),
    ('2024-11-01', 10557, 1588, 558, 0.150422),
    ('2024-12-01', 11721, 1831, 631, 0.156215),
    ('2025-01-01', 10136, 1557, 489, 0.153611),
    ('2025-02-01', 6308, 930, 303, 0.147432),
    ('2025-03-01', 7226, 1099, 341, 0.152090),
    ('2025-04-01', 6504, 1036, 408, 0.159287),
    ('2025-05-01', 7506, 1113, 338, 0.148281),
    ('2025-06-01', 6371, 996, 363, 0.156333),
    ('2025-07-01', 7710, 1156, 418, 0.149935),
    ('2025-08-01', 7339, 1109, 337, 0.151111),
    ('2025-09-01', 3680, 513, 150, 0.139402),
    ('2025-10-01', 2826, 445, 133, 0.157466),
    ('2025-11-01', 1093, 173, 50, 0.158280),
    ('2025-12-01', 65, 11, 0, 0.169231)
),
e06_video (YEAR, CHANNEL, ACTIVE_CAMPAIGNS, SPEND) AS (
  SELECT * FROM VALUES                    -- [E06 13], video rows of 2024 and 2025
    (2024, 'video', 12, 503790.97),
    (2025, 'video', 8, 129218.74)
),
e03_video (YEAR, CHANNEL, SPEND, LEADS) AS (
  SELECT * FROM VALUES                    -- [E03 9], video rows of 2024 and 2025
    (2024, 'video', 503790.97, 15733),
    (2025, 'video', 129218.74, 3889)
),
act AS (                    -- the report: DAILY, "In flight only", each window
  SELECT w.WIN, c.CHANNELS, COUNT(DISTINCT a.CAMPAIGN_ID) AS CAMPAIGNS
  FROM wins w CROSS JOIN chans c
  JOIN FCT_CAMPAIGN_DAILY_ACTIVITY a
    ON a.IS_IN_FLIGHT = 1 AND a.ACTIVITY_DATE BETWEEN w.DATE_FROM AND w.DATE_TO
   AND (c.CHANNEL_FILTER IS NULL OR a.CHANNEL = c.CHANNEL_FILTER)
  GROUP BY w.WIN, c.CHANNELS
),
mon AS (                    -- MM
  SELECT w.WIN, c.CHANNELS, SUM(m.SPEND) AS SPEND, SUM(m.LEADS) AS LEADS, SUM(m.CONVERSIONS) AS CONVERSIONS
  FROM wins w CROSS JOIN chans c
  JOIN MART_MONTHLY_MARKETING m
    ON m.MONTH_START BETWEEN w.DATE_FROM AND w.DATE_TO AND (c.CHANNEL_FILTER IS NULL OR m.CHANNEL = c.CHANNEL_FILTER)
  GROUP BY w.WIN, c.CHANNELS
),
coh AS (                    -- COH
  SELECT w.WIN, c.CHANNELS, SUM(h.CONVERTED_LEADS)::NUMBER(32,18) / SUM(h.LEADS) AS LCR
  FROM wins w CROSS JOIN chans c
  JOIN MART_MONTHLY_COHORT h
    ON h.COHORT_MONTH BETWEEN w.DATE_FROM AND w.DATE_TO AND (c.CHANNEL_FILTER IS NULL OR h.CHANNEL = c.CHANNEL_FILTER)
  GROUP BY w.WIN, c.CHANNELS
),
stg_video_conv AS (         -- [STG] video conversions by conversion year
  SELECT YEAR(v.CONVERTED_DATE) AS YEAR, COUNT(*) AS CONVERSIONS
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID AND c.CHANNEL = 'video'
  GROUP BY 1
),
stg_video_cohort AS (       -- [STG] video cohort rate by creation year (a lead converts at most once)
  SELECT YEAR(l.CREATED_DATE) AS YEAR, COUNT(v.LEAD_ID)::NUMBER(32,18) / COUNT(*) AS LCR
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID AND c.CHANNEL = 'video'
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID
  GROUP BY 1
),
cohort_years AS (           -- [E04 16] cohort rate per year
  SELECT YEAR(COHORT_MONTH) AS YEAR, SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS) AS LCR
  FROM e04_cohort GROUP BY 1
),
ref (WIN, CHANNELS, CAMPAIGNS, SPEND, LEADS, CONVERSIONS, LCR) AS (
  SELECT TO_VARCHAR(y.YEAR), 'all channels', y.CAMPAIGNS_ACTIVE, y.SPEND, y.LEADS, y.CONVERSIONS, h.LCR
  FROM e03_years y JOIN cohort_years h ON h.YEAR = y.YEAR
  WHERE y.YEAR IN (2024, 2025)
  UNION ALL
  SELECT 'pp', 'all channels',
         (SELECT COUNT(*) FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS WHERE START_DATE <= '2024-12-31' AND END_DATE >= '2024-01-02'),
         m.SPEND, m.LEADS, m.CONVERSIONS, h.LCR
  FROM (SELECT SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS
        FROM e03_months WHERE MONTH_START BETWEEN '2024-02-01' AND '2024-12-01') m
  CROSS JOIN (SELECT SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS) AS LCR
              FROM e04_cohort WHERE COHORT_MONTH BETWEEN '2024-02-01' AND '2024-12-01') h
  UNION ALL
  SELECT TO_VARCHAR(e6.YEAR), 'video', e6.ACTIVE_CAMPAIGNS, e6.SPEND, e3.LEADS, sc.CONVERSIONS, sh.LCR
  FROM e06_video e6
  JOIN e03_video e3 ON e3.YEAR = e6.YEAR
  JOIN stg_video_conv sc ON sc.YEAR = e6.YEAR
  JOIN stg_video_cohort sh ON sh.YEAR = e6.YEAR
),
long_rows AS (
  SELECT k.ID, k.CARD, k.KIND, k.DP, c.CHANNELS, c.CHANNEL_NO, w.WIN,
         (CASE k.ID WHEN 'P1-K1' THEN a.CAMPAIGNS WHEN 'P1-K2' THEN m.SPEND WHEN 'P1-K3' THEN m.LEADS
                    WHEN 'P1-K4' THEN m.CONVERSIONS ELSE h.LCR END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P1-K1' THEN r.CAMPAIGNS WHEN 'P1-K2' THEN r.SPEND WHEN 'P1-K3' THEN r.LEADS
                    WHEN 'P1-K4' THEN r.CONVERSIONS ELSE r.LCR END)::NUMBER(38,18) AS R
  FROM cards k CROSS JOIN chans c CROSS JOIN wins w
  LEFT JOIN act a ON a.WIN = w.WIN AND a.CHANNELS = c.CHANNELS
  LEFT JOIN mon m ON m.WIN = w.WIN AND m.CHANNELS = c.CHANNELS
  LEFT JOIN coh h ON h.WIN = w.WIN AND h.CHANNELS = c.CHANNELS
  LEFT JOIN ref r ON r.WIN = w.WIN AND r.CHANNELS = c.CHANNELS
),
wide AS (
  SELECT ID, CARD, KIND, DP, CHANNELS, CHANNEL_NO,
         MAX(IFF(WIN = '2025', V, NULL)) AS CUR, MAX(IFF(WIN = '2024', V, NULL)) AS PY,
         MAX(IFF(WIN = 'pp' AND CHANNELS = 'all channels', V, NULL)) AS PP,
         BOOLAND_AGG(R IS NULL OR COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                                                   ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE)) AS ALL_EQUAL,
         COUNT_IF(R IS NOT NULL) AS VALUES_CHECKED
  FROM long_rows
  GROUP BY ID, CARD, KIND, DP, CHANNELS, CHANNEL_NO
)
SELECT ID, CHANNELS, CARD,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(CUR, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(CUR * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(CUR, 2), 'FM999,999,999,990.00') END AS VALUE_2025,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(PY, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(PY * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(PY, 2), 'FM999,999,999,990.00') END AS VALUE_2024,
       TO_VARCHAR(ROUND((CUR - PY) * 100 / NULLIF(PY, 0), 1), 'FM999,990.0') || '%' AS CHANGE,
       ROUND((CUR - PY) * 100 / NULLIF(PY, 0), 4) AS CHANGE_PCT_4DP,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(CUR - PY, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND((CUR - PY) * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(CUR - PY, 2), 'FM999,999,999,990.00') END AS ABS_CHANGE,
       IFF(PP IS NULL, '', TO_VARCHAR(ROUND((CUR - PP) * 100 / NULLIF(PP, 0), 1), 'FM999,990.0') || '%') AS IF_PREVIOUS_PERIOD,
       IFF((KIND <> 'count' AND (ABS(MOD(ABS(CUR) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001
                                 OR ABS(MOD(ABS(PY) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001
                                 OR ABS(MOD(ABS(CUR - PY) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001))
           OR ABS(MOD(ABS((CUR - PY) * 1000 / NULLIF(PY, 0)), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       VALUES_CHECKED,
       IFF(ALL_EQUAL AND VALUES_CHECKED = IFF(CHANNELS = 'all channels', 3, 2), 'PASS', 'FAIL') AS STATUS
FROM wide
ORDER BY ID, CHANNEL_NO;


-- -----------------------------------------------------------------------------
-- 3. The monthly activity series on MM (dimension MONTH_START as Year Month, 36 points, sorted
--    ascending): P1-08 (bars SPEND, line ACTIVE_CAMPAIGNS), P1-10 (lines CONVERSIONS and
--    PURCHASES), P4-07 (bars SPEND, line REVENUE).
--    STATES: default = the 36 rows; video = the same 36 months, VID_ columns (a month without
--      video activity is 0, not a gap: MM has a row for every month x channel); 2024 = the 12
--      rows with YEAR_2024 = yes, same values as in the default state.
--    CAVEAT: activity basis. A month's CONVERSIONS and REVENUE come partly from earlier
--      months' leads (decision 7); 2025-12 is the tail of one campaign (807.04 of spend).
--    Expected: all channels [E03 7] month by month (all five measures); video [STG]
--      (STG_DAILY_SPEND by spend month; STG_CONVERSIONS by conversion month through STG_LEADS
--      to the campaign's channel; campaigns whose window overlaps the month). Totals: 3c.
-- -----------------------------------------------------------------------------
WITH e03_months (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5, COLUMN6, COLUMN7, COLUMN8, COLUMN9 FROM VALUES   -- [E03 7]
    ('2023-01-01', 3, 23686.55, 3236794, 26846, 1325, 110, 48, 52800.58),
    ('2023-02-01', 5, 49461.61, 4866080, 73735, 2825, 325, 138, 170806.55),
    ('2023-03-01', 10, 104283.65, 9813887, 175460, 6229, 798, 319, 393351.94),
    ('2023-04-01', 11, 104393.90, 9572073, 161209, 5748, 902, 390, 474970.42),
    ('2023-05-01', 14, 97734.10, 10047414, 120442, 5188, 811, 340, 435288.12),
    ('2023-06-01', 18, 123064.68, 12269872, 155305, 7491, 963, 416, 569578.22),
    ('2023-07-01', 16, 116810.98, 10016789, 164873, 7779, 1273, 541, 699206.04),
    ('2023-08-01', 18, 134065.09, 11592470, 199287, 9024, 1221, 523, 672633.67),
    ('2023-09-01', 18, 155294.61, 15617704, 258284, 10771, 1590, 677, 884815.77),
    ('2023-10-01', 19, 171832.62, 17486983, 279402, 10930, 1654, 716, 939852.38),
    ('2023-11-01', 16, 191171.25, 20749569, 305434, 10526, 1582, 697, 904954.17),
    ('2023-12-01', 17, 186463.37, 19437016, 306843, 9713, 1550, 661, 877224.49),
    ('2024-01-01', 12, 122943.61, 13104007, 165184, 6493, 1158, 485, 618809.35),
    ('2024-02-01', 11, 100601.92, 10406404, 141705, 5638, 794, 350, 441376.15),
    ('2024-03-01', 16, 130497.60, 11125570, 220466, 7576, 1063, 446, 568388.08),
    ('2024-04-01', 19, 196892.88, 14608167, 294204, 10413, 1424, 635, 795905.02),
    ('2024-05-01', 17, 177398.24, 13236736, 231211, 8898, 1550, 629, 813289.19),
    ('2024-06-01', 13, 129762.16, 11178475, 134643, 5954, 1035, 445, 581296.94),
    ('2024-07-01', 13, 115762.43, 10712011, 144079, 5895, 861, 365, 468529.67),
    ('2024-08-01', 18, 185052.08, 16908939, 346907, 10718, 1316, 537, 687143.69),
    ('2024-09-01', 20, 205363.34, 17869193, 402727, 11825, 1780, 738, 950923.18),
    ('2024-10-01', 18, 219378.73, 19061854, 376815, 11683, 1830, 749, 961348.25),
    ('2024-11-01', 19, 181790.58, 16211254, 284218, 10557, 1579, 655, 857423.40),
    ('2024-12-01', 18, 205754.77, 20725796, 349890, 11721, 1758, 712, 933214.90),
    ('2025-01-01', 16, 189821.49, 19580708, 319963, 10136, 1699, 723, 926132.23),
    ('2025-02-01', 13, 97550.77, 9704557, 178946, 6308, 1116, 480, 619062.19),
    ('2025-03-01', 12, 103654.48, 11850554, 164981, 7226, 1061, 449, 598344.60),
    ('2025-04-01', 13, 95842.28, 10640020, 145638, 6504, 969, 406, 544558.36),
    ('2025-05-01', 14, 109131.26, 11261990, 181634, 7506, 1183, 489, 629458.15),
    ('2025-06-01', 14, 94604.52, 10184559, 149656, 6371, 971, 380, 515898.62),
    ('2025-07-01', 15, 132922.32, 14172264, 221074, 7710, 1101, 462, 601132.60),
    ('2025-08-01', 14, 138359.57, 14979140, 236728, 7339, 1190, 476, 596182.42),
    ('2025-09-01', 11, 65610.05, 7477070, 89094, 3680, 700, 301, 381379.89),
    ('2025-10-01', 5, 48774.54, 5545040, 67223, 2826, 462, 182, 228041.53),
    ('2025-11-01', 3, 16510.95, 1520494, 26975, 1093, 256, 109, 137433.25),
    ('2025-12-01', 1, 807.04, 73366, 1238, 65, 61, 22, 31085.00)
),
dash AS (                   -- what the three charts plot
  SELECT MONTH_START,
         SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(CONVERSIONS) AS CONVERSIONS,
         SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE,
         SUM(IFF(CHANNEL = 'video', ACTIVE_CAMPAIGNS, 0)) AS VID_ACTIVE_CAMPAIGNS,
         SUM(IFF(CHANNEL = 'video', SPEND, 0))            AS VID_SPEND,
         SUM(IFF(CHANNEL = 'video', CONVERSIONS, 0))      AS VID_CONVERSIONS,
         SUM(IFF(CHANNEL = 'video', PURCHASES, 0))        AS VID_PURCHASES,
         SUM(IFF(CHANNEL = 'video', REVENUE, 0))          AS VID_REVENUE
  FROM MART_MONTHLY_MARKETING
  WHERE MONTH_START BETWEEN '2023-01-01' AND '2025-12-31'
  GROUP BY MONTH_START
),
stg_video AS (SELECT CAMPAIGN_ID, START_DATE, END_DATE FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS WHERE CHANNEL = 'video'),
stg_spend AS (              -- [STG] video spend by spend month
  SELECT DATE_TRUNC('month', d.SPEND_DATE) AS MONTH_START, SUM(d.SPEND) AS SPEND
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND d
  JOIN stg_video c ON c.CAMPAIGN_ID = d.CAMPAIGN_ID
  GROUP BY 1
),
stg_conversions AS (        -- [STG] video conversions, purchases, revenue by conversion month (conversion -> lead -> campaign, n:1 each)
  SELECT DATE_TRUNC('month', v.CONVERTED_DATE) AS MONTH_START, COUNT(*) AS CONVERSIONS,
         COUNT_IF(v.CONVERSION_TYPE = 'purchase') AS PURCHASES, SUM(v.REVENUE) AS REVENUE
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  JOIN stg_video c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY 1
),
stg_active AS (             -- [STG] video campaigns whose window overlaps the month (in flight on at least one day)
  SELECT e.MONTH_START, COUNT(c.CAMPAIGN_ID) AS ACTIVE_CAMPAIGNS
  FROM e03_months e
  LEFT JOIN stg_video c ON c.START_DATE <= LAST_DAY(e.MONTH_START) AND c.END_DATE >= e.MONTH_START
  GROUP BY e.MONTH_START
)
SELECT TO_VARCHAR(COALESCE(d.MONTH_START, e.MONTH_START), 'YYYY-MM') AS MONTH,
       IFF(YEAR(COALESCE(d.MONTH_START, e.MONTH_START)) = 2024, 'yes', '') AS YEAR_2024,
       d.ACTIVE_CAMPAIGNS, d.SPEND, d.CONVERSIONS, d.PURCHASES, d.REVENUE,
       d.VID_ACTIVE_CAMPAIGNS, d.VID_SPEND, d.VID_CONVERSIONS, d.VID_PURCHASES, d.VID_REVENUE,
       IFF(d.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND d.SPEND = e.SPEND AND d.CONVERSIONS = e.CONVERSIONS
           AND d.PURCHASES = e.PURCHASES AND d.REVENUE = e.REVENUE, 'yes', 'NO') AS ALL_EQUALS_E03,
       IFF(d.VID_ACTIVE_CAMPAIGNS = a.ACTIVE_CAMPAIGNS AND d.VID_SPEND = COALESCE(s.SPEND, 0)
           AND d.VID_CONVERSIONS = COALESCE(v.CONVERSIONS, 0) AND d.VID_PURCHASES = COALESCE(v.PURCHASES, 0)
           AND d.VID_REVENUE = COALESCE(v.REVENUE, 0), 'yes', 'NO') AS VID_EQUALS_STG,
       IFF(ALL_EQUALS_E03 = 'yes' AND VID_EQUALS_STG = 'yes', 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN e03_months e ON e.MONTH_START = d.MONTH_START
LEFT JOIN stg_spend s       ON s.MONTH_START = COALESCE(d.MONTH_START, e.MONTH_START)
LEFT JOIN stg_conversions v ON v.MONTH_START = COALESCE(d.MONTH_START, e.MONTH_START)
LEFT JOIN stg_active a      ON a.MONTH_START = COALESCE(d.MONTH_START, e.MONTH_START)
ORDER BY MONTH;


-- -----------------------------------------------------------------------------
-- 3c. The series of block 3 per state: points plotted and sums (what a summary, a cumulative
--     line or the matching card shows), plus the peaks the spec names.
--     Expected: point counts [C]; default sums [SEED EXPECTED_TOTALS]; video sums [PUB] (spend,
--     revenue) and [SEED EXPECTED_CAMPAIGN_KPI] (conversions, purchases: every conversion of a
--     video lead falls inside the full range); 2024 sums [E03 12], purchases [E03 7]; peaks
--     [E03 7]; video months with spend [STG].
-- -----------------------------------------------------------------------------
WITH e03_years (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, SPEND, LEADS, CONVERSIONS, REVENUE, COST_PER_LEAD) AS (
  SELECT * FROM VALUES                    -- [E03 12]
    (2023, 48, 48, 1458262.41, 87549, 12779, 7075482.35, 16.6565),
    (2024, 50, 60, 1971198.34, 107371, 16148, 8677647.82, 18.3588),
    (2025, 22, 35, 1093589.27, 66764, 10769, 5808708.84, 16.3799)
),
e03_months (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5, COLUMN6, COLUMN7, COLUMN8, COLUMN9 FROM VALUES   -- [E03 7]
    ('2023-01-01', 3, 23686.55, 3236794, 26846, 1325, 110, 48, 52800.58),
    ('2023-02-01', 5, 49461.61, 4866080, 73735, 2825, 325, 138, 170806.55),
    ('2023-03-01', 10, 104283.65, 9813887, 175460, 6229, 798, 319, 393351.94),
    ('2023-04-01', 11, 104393.90, 9572073, 161209, 5748, 902, 390, 474970.42),
    ('2023-05-01', 14, 97734.10, 10047414, 120442, 5188, 811, 340, 435288.12),
    ('2023-06-01', 18, 123064.68, 12269872, 155305, 7491, 963, 416, 569578.22),
    ('2023-07-01', 16, 116810.98, 10016789, 164873, 7779, 1273, 541, 699206.04),
    ('2023-08-01', 18, 134065.09, 11592470, 199287, 9024, 1221, 523, 672633.67),
    ('2023-09-01', 18, 155294.61, 15617704, 258284, 10771, 1590, 677, 884815.77),
    ('2023-10-01', 19, 171832.62, 17486983, 279402, 10930, 1654, 716, 939852.38),
    ('2023-11-01', 16, 191171.25, 20749569, 305434, 10526, 1582, 697, 904954.17),
    ('2023-12-01', 17, 186463.37, 19437016, 306843, 9713, 1550, 661, 877224.49),
    ('2024-01-01', 12, 122943.61, 13104007, 165184, 6493, 1158, 485, 618809.35),
    ('2024-02-01', 11, 100601.92, 10406404, 141705, 5638, 794, 350, 441376.15),
    ('2024-03-01', 16, 130497.60, 11125570, 220466, 7576, 1063, 446, 568388.08),
    ('2024-04-01', 19, 196892.88, 14608167, 294204, 10413, 1424, 635, 795905.02),
    ('2024-05-01', 17, 177398.24, 13236736, 231211, 8898, 1550, 629, 813289.19),
    ('2024-06-01', 13, 129762.16, 11178475, 134643, 5954, 1035, 445, 581296.94),
    ('2024-07-01', 13, 115762.43, 10712011, 144079, 5895, 861, 365, 468529.67),
    ('2024-08-01', 18, 185052.08, 16908939, 346907, 10718, 1316, 537, 687143.69),
    ('2024-09-01', 20, 205363.34, 17869193, 402727, 11825, 1780, 738, 950923.18),
    ('2024-10-01', 18, 219378.73, 19061854, 376815, 11683, 1830, 749, 961348.25),
    ('2024-11-01', 19, 181790.58, 16211254, 284218, 10557, 1579, 655, 857423.40),
    ('2024-12-01', 18, 205754.77, 20725796, 349890, 11721, 1758, 712, 933214.90),
    ('2025-01-01', 16, 189821.49, 19580708, 319963, 10136, 1699, 723, 926132.23),
    ('2025-02-01', 13, 97550.77, 9704557, 178946, 6308, 1116, 480, 619062.19),
    ('2025-03-01', 12, 103654.48, 11850554, 164981, 7226, 1061, 449, 598344.60),
    ('2025-04-01', 13, 95842.28, 10640020, 145638, 6504, 969, 406, 544558.36),
    ('2025-05-01', 14, 109131.26, 11261990, 181634, 7506, 1183, 489, 629458.15),
    ('2025-06-01', 14, 94604.52, 10184559, 149656, 6371, 971, 380, 515898.62),
    ('2025-07-01', 15, 132922.32, 14172264, 221074, 7710, 1101, 462, 601132.60),
    ('2025-08-01', 14, 138359.57, 14979140, 236728, 7339, 1190, 476, 596182.42),
    ('2025-09-01', 11, 65610.05, 7477070, 89094, 3680, 700, 301, 381379.89),
    ('2025-10-01', 5, 48774.54, 5545040, 67223, 2826, 462, 182, 228041.53),
    ('2025-11-01', 3, 16510.95, 1520494, 26975, 1093, 256, 109, 137433.25),
    ('2025-12-01', 1, 807.04, 73366, 1238, 65, 61, 22, 31085.00)
),
m AS (SELECT * FROM MART_MONTHLY_MARKETING WHERE MONTH_START BETWEEN '2023-01-01' AND '2025-12-31'),
mm AS (SELECT MONTH_START, SUM(SPEND) AS SPEND, SUM(CONVERSIONS) AS CONVERSIONS, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS
       FROM m GROUP BY MONTH_START),
seed AS (
  SELECT MAX(IFF(METRIC = 'spend', VALUE, NULL)) AS SPEND, MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERSIONS,
         MAX(IFF(METRIC = 'purchases', VALUE, NULL)) AS PURCHASES, MAX(IFF(METRIC = 'revenue', VALUE, NULL)) AS REVENUE
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
pub AS (SELECT SPEND, ATTRIBUTED_REVENUE FROM MARKETING_CRM.STAGING.PUBLISHER_CHANNEL_REFERENCE WHERE CHANNEL = 'video'),
seed_video AS (SELECT SUM(CONVERTED_LEADS) AS CONVERSIONS, SUM(PURCHASES) AS PURCHASES
               FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CHANNEL = 'video'),
stg_video_spend_months AS (
  SELECT COUNT(DISTINCT DATE_TRUNC('month', d.SPEND_DATE)) AS MONTHS
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND d
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = d.CAMPAIGN_ID AND c.CHANNEL = 'video'
),
checks (CHECK_NO, CHECK_NAME, ACTUAL, EXPECTED, SOURCE) AS (
  SELECT 1, 'default: months plotted', COUNT(DISTINCT MONTH_START), 36, '[C] 2023-01..2025-12' FROM m
  UNION ALL SELECT 2, 'default: SUM(SPEND)', SUM(SPEND), (SELECT SPEND FROM seed), 'SEED EXPECTED_TOTALS' FROM m
  UNION ALL SELECT 3, 'default: SUM(CONVERSIONS)', SUM(CONVERSIONS), (SELECT CONVERSIONS FROM seed), 'SEED EXPECTED_TOTALS' FROM m
  UNION ALL SELECT 4, 'default: SUM(PURCHASES)', SUM(PURCHASES), (SELECT PURCHASES FROM seed), 'SEED EXPECTED_TOTALS' FROM m
  UNION ALL SELECT 5, 'default: SUM(REVENUE)', SUM(REVENUE), (SELECT REVENUE FROM seed), 'SEED EXPECTED_TOTALS' FROM m
  UNION ALL SELECT 6, 'default: peak spend month (YYYYMM)', (SELECT TO_NUMBER(TO_VARCHAR(MAX_BY(MONTH_START, SPEND), 'YYYYMM')) FROM mm),
                   (SELECT TO_NUMBER(TO_VARCHAR(MAX_BY(MONTH_START, SPEND), 'YYYYMM')) FROM e03_months), 'E03 [7]'
  UNION ALL SELECT 7, 'default: peak conversions month (YYYYMM)', (SELECT TO_NUMBER(TO_VARCHAR(MAX_BY(MONTH_START, CONVERSIONS), 'YYYYMM')) FROM mm),
                   (SELECT TO_NUMBER(TO_VARCHAR(MAX_BY(MONTH_START, CONVERSIONS), 'YYYYMM')) FROM e03_months), 'E03 [7]'
  UNION ALL SELECT 8, 'default: most campaigns in flight', (SELECT MAX(ACTIVE_CAMPAIGNS) FROM mm),
                   (SELECT MAX(ACTIVE_CAMPAIGNS) FROM e03_months), 'E03 [7]'
  UNION ALL SELECT 9, 'video: months plotted', COUNT(DISTINCT IFF(CHANNEL = 'video', MONTH_START, NULL)), 36, '[C] zero rows kept' FROM m
  UNION ALL SELECT 10, 'video: months with SPEND > 0', COUNT(DISTINCT IFF(CHANNEL = 'video' AND SPEND > 0, MONTH_START, NULL)),
                   (SELECT MONTHS FROM stg_video_spend_months), '[STG] video spend months' FROM m
  UNION ALL SELECT 11, 'video: SUM(SPEND)', SUM(IFF(CHANNEL = 'video', SPEND, 0)), (SELECT SPEND FROM pub), 'PUB video' FROM m
  UNION ALL SELECT 12, 'video: SUM(CONVERSIONS)', SUM(IFF(CHANNEL = 'video', CONVERSIONS, 0)), (SELECT CONVERSIONS FROM seed_video),
                   'SEED EXPECTED_CAMPAIGN_KPI' FROM m
  UNION ALL SELECT 13, 'video: SUM(PURCHASES)', SUM(IFF(CHANNEL = 'video', PURCHASES, 0)), (SELECT PURCHASES FROM seed_video),
                   'SEED EXPECTED_CAMPAIGN_KPI' FROM m
  UNION ALL SELECT 14, 'video: SUM(REVENUE)', SUM(IFF(CHANNEL = 'video', REVENUE, 0)), (SELECT ATTRIBUTED_REVENUE FROM pub), 'PUB video' FROM m
  UNION ALL SELECT 15, '2024: months plotted', COUNT(DISTINCT IFF(YEAR(MONTH_START) = 2024, MONTH_START, NULL)), 12, '[C] 2024-01..2024-12' FROM m
  UNION ALL SELECT 16, '2024: SUM(SPEND)', SUM(IFF(YEAR(MONTH_START) = 2024, SPEND, 0)), (SELECT SPEND FROM e03_years WHERE YEAR = 2024), 'E03 [12]' FROM m
  UNION ALL SELECT 17, '2024: SUM(CONVERSIONS)', SUM(IFF(YEAR(MONTH_START) = 2024, CONVERSIONS, 0)), (SELECT CONVERSIONS FROM e03_years WHERE YEAR = 2024), 'E03 [12]' FROM m
  UNION ALL SELECT 18, '2024: SUM(PURCHASES)', SUM(IFF(YEAR(MONTH_START) = 2024, PURCHASES, 0)),
                   (SELECT SUM(PURCHASES) FROM e03_months WHERE YEAR(MONTH_START) = 2024), 'E03 [7] sum of 2024' FROM m
  UNION ALL SELECT 19, '2024: SUM(REVENUE)', SUM(IFF(YEAR(MONTH_START) = 2024, REVENUE, 0)), (SELECT REVENUE FROM e03_years WHERE YEAR = 2024), 'E03 [12]' FROM m
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,2) AS ACTUAL, EXPECTED::NUMBER(38,2) AS EXPECTED, SOURCE,
       IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM checks
ORDER BY CHECK_NO;


-- -----------------------------------------------------------------------------
-- 4. P1-09 Leads by channel: horizontal bar chart on MM, dimension CHANNEL, metric SUM(LEADS),
--    sorted by leads descending, 5 bars. State video = the video bar only (25,799); state 2024
--    = LEADS_2024 in BAR_ORDER_2024 (paid_search moves to the top). Lead volume follows the
--    number of running campaigns.
--    Expected: default [SEED EXPECTED_CAMPAIGN_KPI roll-up]; 2024 [E03 9].
-- -----------------------------------------------------------------------------
WITH e03_year_channel (YEAR, CHANNEL, SPEND, LEADS) AS (
  SELECT * FROM VALUES                    -- [E03 9], 2024 rows
    (2024, 'paid_search', 437390.55, 29566),
    (2024, 'affiliate', 393675.01, 28727),
    (2024, 'paid_social', 387302.85, 21435),
    (2024, 'video', 503790.97, 15733),
    (2024, 'display', 249038.96, 11910)
),
dash AS (
  SELECT CHANNEL, SUM(LEADS) AS LEADS, SUM(IFF(MONTH_START BETWEEN '2024-01-01' AND '2024-12-31', LEADS, 0)) AS LEADS_2024
  FROM MART_MONTHLY_MARKETING
  WHERE MONTH_START BETWEEN '2023-01-01' AND '2025-12-31'
  GROUP BY CHANNEL
),
seed AS (SELECT CHANNEL, SUM(LEADS) AS LEADS FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI GROUP BY CHANNEL)
SELECT COALESCE(d.CHANNEL, s.CHANNEL, e.CHANNEL) AS CHANNEL,
       RANK() OVER (ORDER BY d.LEADS DESC NULLS LAST) AS BAR_ORDER, d.LEADS, s.LEADS AS SEED_LEADS,
       RANK() OVER (ORDER BY d.LEADS_2024 DESC NULLS LAST) AS BAR_ORDER_2024, d.LEADS_2024, e.LEADS AS E03_LEADS_2024,
       IFF(d.LEADS = s.LEADS AND d.LEADS_2024 = e.LEADS, 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN seed s ON s.CHANNEL = d.CHANNEL
FULL OUTER JOIN e03_year_channel e ON e.CHANNEL = COALESCE(d.CHANNEL, s.CHANNEL)
ORDER BY BAR_ORDER;


-- -----------------------------------------------------------------------------
-- 5. The four campaign charts on CAMP (one row per campaign; ratio columns are the calculated
--    fields of the spec, which equal the campaign's own ratio per row and give a correct
--    summary row):
--      P1-11 Campaign performance table    sorted by SPEND desc; rows 1-10 + summary
--      P2-14 Campaign conversion rate      sorted by Lead conversion rate desc; rows 1-10, the
--                                          last 5 (= rows 1-5 when re-sorted ascending), summary
--      P4-11 Campaign ROAS ranking         sorted by ROAS (attributed) desc; rows 1-10, the last
--                                          5, summary
--      P4-12 Top 10 lowest cost/purchase   bar chart sorted by Cost per purchase ascending; 10 bars
--    STATES: default (120 campaigns) and video (24). State 2024: unchanged, because the spec
--      types CAMP's dates as Text (D3); block 5c shows what a missed D3 would show. The Campaign
--      drop-down state is block 17. Ties on a sort key are broken by CAMPAIGN_ID here (block 5c
--      shows that none touches the rows shown).
--    HOW TO READ: _PCT columns are percent with 2 dp; CPL, ROAS, CPP (cost per purchase) 2 dp.
--    Expected: [SEED EXPECTED_CAMPAIGN_KPI] ranked here with the same keys; EQUALS_SEED compares
--      the campaign at each position and its bases and budget exactly (summary: also the count).
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER) AS (
  SELECT * FROM VALUES ('default', 1, NULL), ('video', 2, 'video')
),
report_tables (TABLE_ID, TABLE_NO, SORT_KEY, LAST_ROWS, HAS_SUMMARY) AS (
  SELECT * FROM VALUES ('P1-11', 1, 'SPEND', 0, TRUE), ('P2-14', 2, 'LCR', 5, TRUE),
                       ('P4-11', 3, 'ROAS', 5, TRUE), ('P4-12', 4, 'CPP_ASC', 0, FALSE)
),
dash_rows AS (              -- the report: CAMP under each state
  SELECT s.STATE, s.STATE_NO, c.CAMPAIGN_ID, c.CAMPAIGN_NAME, c.CHANNEL, c.OBJECTIVE, c.SPEND, c.LEADS,
         c.CONVERTED_LEADS, c.PURCHASES, c.REVENUE, c.BUDGET
  FROM states s
  JOIN MART_CAMPAIGN_PERFORMANCE c ON (s.CHANNEL_FILTER IS NULL OR c.CHANNEL = s.CHANNEL_FILTER)
),
ref_rows AS (               -- [SEED]
  SELECT s.STATE, k.CAMPAIGN_ID, k.SPEND, k.LEADS, k.CONVERTED_LEADS, k.PURCHASES, k.REVENUE, k.BUDGET
  FROM states s
  JOIN MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI k ON (s.CHANNEL_FILTER IS NULL OR k.CHANNEL = s.CHANNEL_FILTER)
),
dash_ranked AS (
  SELECT t.TABLE_ID, t.TABLE_NO, t.LAST_ROWS, t.HAS_SUMMARY, d.*,
         ROW_NUMBER() OVER (PARTITION BY t.TABLE_ID, d.STATE ORDER BY
           CASE t.SORT_KEY WHEN 'SPEND'   THEN d.SPEND::NUMBER(38,18)
                           WHEN 'ROAS'    THEN (d.REVENUE::NUMBER(32,18) / NULLIF(d.SPEND, 0))::NUMBER(38,18)
                           WHEN 'LCR'     THEN (d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.LEADS, 0))::NUMBER(38,18)
                           ELSE -(d.SPEND::NUMBER(32,18) / NULLIF(d.PURCHASES, 0))::NUMBER(38,18) END DESC NULLS LAST,
           d.CAMPAIGN_ID) AS ROW_NO,
         COUNT(*) OVER (PARTITION BY t.TABLE_ID, d.STATE) AS ROWS_IN_STATE
  FROM report_tables t CROSS JOIN dash_rows d
),
ref_ranked AS (
  SELECT t.TABLE_ID, r.*,
         ROW_NUMBER() OVER (PARTITION BY t.TABLE_ID, r.STATE ORDER BY
           CASE t.SORT_KEY WHEN 'SPEND'   THEN r.SPEND::NUMBER(38,18)
                           WHEN 'ROAS'    THEN (r.REVENUE::NUMBER(32,18) / NULLIF(r.SPEND, 0))::NUMBER(38,18)
                           WHEN 'LCR'     THEN (r.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(r.LEADS, 0))::NUMBER(38,18)
                           ELSE -(r.SPEND::NUMBER(32,18) / NULLIF(r.PURCHASES, 0))::NUMBER(38,18) END DESC NULLS LAST,
           r.CAMPAIGN_ID) AS ROW_NO
  FROM report_tables t CROSS JOIN ref_rows r
),
ref_totals AS (
  SELECT STATE, COUNT(*) AS CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE, SUM(BUDGET) AS BUDGET
  FROM ref_rows GROUP BY STATE
),
table_rows AS (
  SELECT d.TABLE_ID, d.TABLE_NO, d.STATE, d.STATE_NO, d.ROW_NO AS SORT_NO, TO_VARCHAR(d.ROW_NO) AS ROW_NO,
         d.CAMPAIGN_ID, d.CAMPAIGN_NAME, d.CHANNEL, d.OBJECTIVE, d.SPEND, d.LEADS, d.CONVERTED_LEADS, d.PURCHASES,
         d.REVENUE, d.BUDGET,
         IFF(r.CAMPAIGN_ID = d.CAMPAIGN_ID AND r.SPEND = d.SPEND AND r.LEADS = d.LEADS AND r.CONVERTED_LEADS = d.CONVERTED_LEADS
             AND r.PURCHASES = d.PURCHASES AND r.REVENUE = d.REVENUE AND r.BUDGET = d.BUDGET, 'yes', 'NO') AS EQUALS_SEED
  FROM dash_ranked d
  LEFT JOIN ref_ranked r ON r.TABLE_ID = d.TABLE_ID AND r.STATE = d.STATE AND r.ROW_NO = d.ROW_NO
  WHERE d.ROW_NO <= 10 OR d.ROW_NO > d.ROWS_IN_STATE - d.LAST_ROWS
  UNION ALL
  SELECT d.TABLE_ID, d.TABLE_NO, d.STATE, d.STATE_NO, 999, 'summary', NULL, COUNT(*) || ' campaigns', NULL, NULL,
         SUM(d.SPEND), SUM(d.LEADS), SUM(d.CONVERTED_LEADS), SUM(d.PURCHASES), SUM(d.REVENUE), SUM(d.BUDGET),
         IFF(COUNT(*) = MAX(t.CAMPAIGNS) AND SUM(d.SPEND) = MAX(t.SPEND) AND SUM(d.LEADS) = MAX(t.LEADS)
             AND SUM(d.CONVERTED_LEADS) = MAX(t.CONVERTED_LEADS) AND SUM(d.PURCHASES) = MAX(t.PURCHASES)
             AND SUM(d.REVENUE) = MAX(t.REVENUE) AND SUM(d.BUDGET) = MAX(t.BUDGET), 'yes', 'NO')
  FROM dash_ranked d
  LEFT JOIN ref_totals t ON t.STATE = d.STATE
  WHERE d.HAS_SUMMARY
  GROUP BY d.TABLE_ID, d.TABLE_NO, d.STATE, d.STATE_NO
)
SELECT TABLE_ID, STATE, ROW_NO, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, SPEND, LEADS, CONVERTED_LEADS,
       PURCHASES, REVENUE, BUDGET,
       ROUND(SPEND::NUMBER(32,18) / NULLIF(LEADS, 0), 2)                       AS CPL,
       ROUND((CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(LEADS, 0), 2)     AS LCR_PCT,
       ROUND(REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0), 2)                     AS ROAS,
       ROUND(SPEND::NUMBER(32,18) / NULLIF(PURCHASES, 0), 2)                   AS CPP,
       ROUND((SPEND * 100)::NUMBER(32,18) / NULLIF(BUDGET, 0), 2)              AS UTIL_PCT,
       EQUALS_SEED, IFF(EQUALS_SEED = 'yes', 'PASS', 'FAIL') AS STATUS
FROM table_rows
ORDER BY TABLE_NO, STATE_NO, SORT_NO;


-- -----------------------------------------------------------------------------
-- 5c. Campaign chart checks: rows per state, ties on the sort keys, re-sort extremes, the D3
--     diagnostic and the summary-row trap.
--     - Rows per state: 120 / 24.
--     - Ties: a tie on a sort key among the rows shown (and the next one) would make Data
--       Studio's order differ from block 5 without any number being wrong; 0 = order fixed.
--     - Re-sort (spec P4-11): by Budget utilisation ascending / descending, row 1.
--     - D3 diagnostic: if CAMP kept START_DATE as a Date, Data Studio would pick it as the date
--       range dimension and state 2024 would show the 50 campaigns STARTED in 2024 (not the 60
--       that ran in 2024) instead of all 120.
--     - Summary-row trap (INFO, no reference): what a summary row shows if a STORED ratio column
--       (default aggregation Sum, or Average) is used instead of the calculated field.
--     Expected: [SEED] counts and the seed's own extremes; [E03 12] started / active per year.
-- -----------------------------------------------------------------------------
WITH e03_years (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, SPEND, LEADS, CONVERSIONS, REVENUE, COST_PER_LEAD) AS (
  SELECT * FROM VALUES                    -- [E03 12]
    (2023, 48, 48, 1458262.41, 87549, 12779, 7075482.35, 16.6565),
    (2024, 50, 60, 1971198.34, 107371, 16148, 8677647.82, 18.3588),
    (2025, 22, 35, 1093589.27, 66764, 10769, 5808708.84, 16.3799)
),
c AS (
  SELECT CAMPAIGN_ID, CHANNEL, START_DATE, SPEND, REVENUE, LEADS, CONVERTED_LEADS, PURCHASES, BUDGET,
         ROAS, COST_PER_LEAD, LEAD_CONVERSION_RATE,
         (REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0))::NUMBER(38,18)          AS ROAS_EXACT,
         (CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0))::NUMBER(38,18)  AS LCR_EXACT,
         (SPEND::NUMBER(32,18) / NULLIF(PURCHASES, 0))::NUMBER(38,18)        AS CPP_EXACT,
         (SPEND::NUMBER(32,18) / NULLIF(BUDGET, 0))::NUMBER(38,18)           AS UTIL_EXACT
  FROM MART_CAMPAIGN_PERFORMANCE
),
seed AS (
  SELECT COUNT(*) AS CAMPAIGNS, COUNT_IF(CHANNEL = 'video') AS VIDEO_CAMPAIGNS,
         ROUND(SUM(REVENUE)::NUMBER(32,18) / SUM(SPEND), 6) AS ROAS,
         ROUND(MIN(SPEND::NUMBER(32,18) / BUDGET), 6) AS MIN_UTIL, ROUND(MAX(SPEND::NUMBER(32,18) / BUDGET), 6) AS MAX_UTIL,
         TO_NUMBER(SUBSTR(MIN_BY(CAMPAIGN_ID, SPEND::NUMBER(32,18) / BUDGET), 4)) AS MIN_UTIL_CAMPAIGN,
         TO_NUMBER(SUBSTR(MAX_BY(CAMPAIGN_ID, SPEND::NUMBER(32,18) / BUDGET), 4)) AS MAX_UTIL_CAMPAIGN
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI
),
ranked AS (
  SELECT st.STATE, x.*,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.SPEND DESC, x.CAMPAIGN_ID)       AS RN_SPEND,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.LCR_EXACT DESC, x.CAMPAIGN_ID)   AS RN_LCR,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.LCR_EXACT ASC, x.CAMPAIGN_ID)    AS RN_LCR_ASC,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.ROAS_EXACT DESC, x.CAMPAIGN_ID)  AS RN_ROAS,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.ROAS_EXACT ASC, x.CAMPAIGN_ID)   AS RN_ROAS_ASC,
         ROW_NUMBER() OVER (PARTITION BY st.STATE ORDER BY x.CPP_EXACT ASC, x.CAMPAIGN_ID)    AS RN_CPP
  FROM (SELECT 'default' AS STATE UNION ALL SELECT 'video') st
  JOIN c x ON st.STATE = 'default' OR x.CHANNEL = 'video'
),
ties AS (                   -- keys shown (and the next one) that occur more than once in the state
  SELECT 'SPEND' AS SORT_KEY, STATE, SPEND::NUMBER(38,18) AS K FROM ranked WHERE RN_SPEND <= 11
  UNION ALL SELECT 'LCR', STATE, LCR_EXACT FROM ranked WHERE RN_LCR <= 11 OR RN_LCR_ASC <= 6
  UNION ALL SELECT 'ROAS', STATE, ROAS_EXACT FROM ranked WHERE RN_ROAS <= 11 OR RN_ROAS_ASC <= 6
  UNION ALL SELECT 'CPP', STATE, CPP_EXACT FROM ranked WHERE RN_CPP <= 11
),
tie_count AS (
  SELECT COUNT(*) AS TIED_KEYS FROM (SELECT SORT_KEY, STATE, K FROM ties GROUP BY 1, 2, 3 HAVING COUNT(*) > 1)
),
checks (CHECK_NO, CHECK_NAME, ACTUAL, EXPECTED, SOURCE, KIND) AS (
  SELECT 1, 'default: campaigns in the charts', COUNT(*), (SELECT CAMPAIGNS FROM seed), 'SEED EXPECTED_CAMPAIGN_KPI', 'check' FROM c
  UNION ALL SELECT 2, 'video: campaigns in the charts', COUNT_IF(CHANNEL = 'video'), (SELECT VIDEO_CAMPAIGNS FROM seed),
                   'SEED EXPECTED_CAMPAIGN_KPI', 'check' FROM c
  UNION ALL SELECT 3, 'tied sort keys among the rows shown', (SELECT TIED_KEYS FROM tie_count), 0, 'requirement', 'check'
  UNION ALL SELECT 4, 'P4-11 by util. asc: row 1 (CMP no.)', TO_NUMBER(SUBSTR(MIN_BY(CAMPAIGN_ID, UTIL_EXACT), 4)),
                   (SELECT MIN_UTIL_CAMPAIGN FROM seed), 'SEED min SPEND/BUDGET', 'check' FROM c
  UNION ALL SELECT 5, '... its budget utilisation', ROUND(MIN(UTIL_EXACT), 6), (SELECT MIN_UTIL FROM seed), 'SEED min SPEND/BUDGET', 'check' FROM c
  UNION ALL SELECT 6, 'P4-11 by util. desc: row 1 (CMP no.)', TO_NUMBER(SUBSTR(MAX_BY(CAMPAIGN_ID, UTIL_EXACT), 4)),
                   (SELECT MAX_UTIL_CAMPAIGN FROM seed), 'SEED max SPEND/BUDGET', 'check' FROM c
  UNION ALL SELECT 7, '... its budget utilisation', ROUND(MAX(UTIL_EXACT), 6), (SELECT MAX_UTIL FROM seed), 'SEED max SPEND/BUDGET', 'check' FROM c
  UNION ALL SELECT 8, 'D3 missed: 2024 shows campaigns STARTED', COUNT_IF(START_DATE BETWEEN '2024-01-01' AND '2024-12-31'),
                   (SELECT CAMPAIGNS_STARTED FROM e03_years WHERE YEAR = 2024), 'E03 [12] CAMPAIGNS_STARTED', 'check' FROM c
  UNION ALL SELECT 9, '... campaigns that RAN in 2024 (P1-01)', NULL, (SELECT CAMPAIGNS_ACTIVE FROM e03_years WHERE YEAR = 2024),
                   'E03 [12] CAMPAIGNS_ACTIVE', 'info'
  UNION ALL SELECT 10, 'summary: ROAS as ratio of sums (right)', ROUND(SUM(REVENUE)::NUMBER(32,18) / SUM(SPEND), 6),
                   (SELECT ROAS FROM seed), 'SEED ratio of sums', 'check' FROM c
  UNION ALL SELECT 11, 'summary trap: SUM(stored ROAS)', SUM(ROAS), NULL, 'wrong if shown', 'info' FROM c
  UNION ALL SELECT 12, 'summary trap: AVG(stored ROAS)', ROUND(AVG(ROAS), 6), NULL, 'wrong if shown', 'info' FROM c
  UNION ALL SELECT 13, 'summary trap: SUM(stored COST_PER_LEAD)', SUM(COST_PER_LEAD), NULL, 'wrong if shown', 'info' FROM c
  UNION ALL SELECT 14, 'summary trap: AVG(stored LCR)', ROUND(AVG(LEAD_CONVERSION_RATE), 6), NULL, 'wrong if shown', 'info' FROM c
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED, SOURCE,
       IFF(KIND = 'info', 'INFO', IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL')) AS STATUS
FROM checks
ORDER BY CHECK_NO;


-- =============================================================================
-- PAGE 2: CONVERSION FUNNEL
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6. P2-01..P2-05 KPI cards on CH (full range), states default / video. Filters: channel.
--    State 2024 is not computed: CH has no date column (block 0b), so the date control cannot
--    change these cards and they keep their default values; a 2024 row here could only repeat
--    the default check.
--    Expected: default [SEED EXPECTED_TOTALS]; video [SEED EXPECTED_CAMPAIGN_KPI roll-up].
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER) AS (
  SELECT * FROM VALUES ('default', 1, NULL), ('video', 2, 'video')
),
kpis (ID, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P2-01', 'CTR (clicks / impressions)', 'CH: SUM(CLICKS)/SUM(IMPRESSIONS)',    'pct', 6),
    ('P2-02', 'Click-to-lead rate',         'CH: SUM(LEADS)/SUM(CLICKS)',          'pct', 6),
    ('P2-03', 'Lead conversion rate',       'CH: SUM(CONVERTED_LEADS)/SUM(LEADS)', 'pct', 6),
    ('P2-04', 'Cost per lead',              'CH: SUM(SPEND)/SUM(LEADS)',           'num', 4),
    ('P2-05', 'Cost per conversion',        'CH: SUM(SPEND)/SUM(CONVERTED_LEADS)', 'num', 4)
),
dash AS (
  SELECT s.STATE, s.STATE_NO, SUM(c.IMPRESSIONS) AS IMPRESSIONS, SUM(c.CLICKS) AS CLICKS, SUM(c.LEADS) AS LEADS,
         SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(c.SPEND) AS SPEND
  FROM states s
  JOIN MART_CHANNEL_PERFORMANCE c ON (s.CHANNEL_FILTER IS NULL OR c.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE, s.STATE_NO
),
seed_totals AS (
  SELECT MAX(IFF(METRIC = 'impressions', VALUE, NULL)) AS IMPRESSIONS, MAX(IFF(METRIC = 'clicks', VALUE, NULL)) AS CLICKS,
         MAX(IFF(METRIC = 'leads', VALUE, NULL)) AS LEADS, MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERTED_LEADS,
         MAX(IFF(METRIC = 'spend', VALUE, NULL)) AS SPEND
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
ref AS (
  SELECT 'default' AS STATE, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, SPEND FROM seed_totals
  UNION ALL
  SELECT 'video', SUM(IMPRESSIONS), SUM(CLICKS), SUM(LEADS), SUM(CONVERTED_LEADS), SUM(SPEND)
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CHANNEL = 'video'
),
card_rows AS (
  SELECT k.ID, d.STATE, d.STATE_NO, k.COMPONENT, k.FIELD, k.KIND, k.DP,
         (CASE k.ID WHEN 'P2-01' THEN d.CLICKS::NUMBER(32,18) / NULLIF(d.IMPRESSIONS, 0)
                    WHEN 'P2-02' THEN d.LEADS::NUMBER(32,18) / NULLIF(d.CLICKS, 0)
                    WHEN 'P2-03' THEN d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P2-04' THEN d.SPEND::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P2-05' THEN d.SPEND::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0) END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P2-01' THEN r.CLICKS::NUMBER(32,18) / NULLIF(r.IMPRESSIONS, 0)
                    WHEN 'P2-02' THEN r.LEADS::NUMBER(32,18) / NULLIF(r.CLICKS, 0)
                    WHEN 'P2-03' THEN r.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(r.LEADS, 0)
                    WHEN 'P2-04' THEN r.SPEND::NUMBER(32,18) / NULLIF(r.LEADS, 0)
                    WHEN 'P2-05' THEN r.SPEND::NUMBER(32,18) / NULLIF(r.CONVERTED_LEADS, 0) END)::NUMBER(38,18) AS R,
         CASE d.STATE WHEN 'default' THEN 'SEED EXPECTED_TOTALS' ELSE 'SEED EXPECTED_CAMPAIGN_KPI, video' END AS REF_SOURCE
  FROM dash d
  JOIN ref r ON r.STATE = d.STATE
  CROSS JOIN kpis k
)
SELECT ID, STATE, COMPONENT, FIELD,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM card_rows
ORDER BY ID, STATE_NO;


-- -----------------------------------------------------------------------------
-- 7. P2-06 funnel chart and P2-07 funnel stage table on FUN: dimension STAGE sorted by
--    STAGE_ORDER (Min, ascending), metric SUM(STAGE_VALUE); P2-07 adds the calculated fields
--    Stage conversion = SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE) ("% of previous stage", which
--    is also the funnel's "% of previous" label) and Share of top of funnel =
--    SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE) ("% of impressions", 2 dp and 4 dp).
--    STATES: default; video (VID_ columns); 2024 = unchanged (FUN has no date field). Stage 1
--      has no previous stage: NULL here, "-" or 100% in Data Studio.
--    CAVEAT: an aggregate campaign funnel of different units, not a person journey; Purchases
--      are the converted leads that bought (parallel to trials), not a step after a trial.
--    Expected: [SEED EXPECTED_TOTALS] stage totals; [SEED EXPECTED_CAMPAIGN_KPI] video. The two
--      denominators are checked too, because the two percent columns divide by them:
--      SUM(PREV_STAGE_VALUE) must equal the seed value of the stage before (NULL for stage 1)
--      and SUM(TOP_OF_FUNNEL_VALUE) the seed impressions, for all channels and for video
--      (EQUALS_SEED covers value, previous stage and top of funnel).
-- -----------------------------------------------------------------------------
WITH f AS (
  SELECT STAGE_ORDER, STAGE,
         SUM(STAGE_VALUE) AS V, SUM(PREV_STAGE_VALUE) AS PREV_V, SUM(TOP_OF_FUNNEL_VALUE) AS TOP_V,
         SUM(IFF(CHANNEL = 'video', STAGE_VALUE, NULL))         AS VID_V,
         SUM(IFF(CHANNEL = 'video', PREV_STAGE_VALUE, NULL))    AS VID_PREV_V,
         SUM(IFF(CHANNEL = 'video', TOP_OF_FUNNEL_VALUE, NULL)) AS VID_TOP_V
  FROM MART_CONVERSION_FUNNEL
  GROUP BY STAGE_ORDER, STAGE
),
seed_totals AS (
  SELECT MAX(IFF(METRIC = 'impressions', VALUE, NULL)) AS S1, MAX(IFF(METRIC = 'clicks', VALUE, NULL)) AS S2,
         MAX(IFF(METRIC = 'leads', VALUE, NULL)) AS S3, MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS S4,
         MAX(IFF(METRIC = 'purchases', VALUE, NULL)) AS S5
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
seed_video AS (
  SELECT SUM(IMPRESSIONS) AS S1, SUM(CLICKS) AS S2, SUM(LEADS) AS S3, SUM(CONVERTED_LEADS) AS S4, SUM(PURCHASES) AS S5
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CHANNEL = 'video'
),
expected (STAGE_ORDER, STAGE, EXP_V, EXP_PREV_V, EXP_TOP_V, EXP_VID_V, EXP_VID_PREV_V, EXP_VID_TOP_V) AS (
  SELECT 1, 'Impressions', t.S1, NULL, t.S1, a.S1, NULL, a.S1 FROM seed_totals t CROSS JOIN seed_video a
  UNION ALL SELECT 2, 'Clicks', t.S2, t.S1, t.S1, a.S2, a.S1, a.S1 FROM seed_totals t CROSS JOIN seed_video a
  UNION ALL SELECT 3, 'Leads', t.S3, t.S2, t.S1, a.S3, a.S2, a.S1 FROM seed_totals t CROSS JOIN seed_video a
  UNION ALL SELECT 4, 'Converted leads', t.S4, t.S3, t.S1, a.S4, a.S3, a.S1 FROM seed_totals t CROSS JOIN seed_video a
  UNION ALL SELECT 5, 'Purchases', t.S5, t.S4, t.S1, a.S5, a.S4, a.S1 FROM seed_totals t CROSS JOIN seed_video a
)
SELECT COALESCE(f.STAGE_ORDER, e.STAGE_ORDER) AS STAGE_ORDER, COALESCE(f.STAGE, e.STAGE) AS STAGE,
       f.V AS VALUE,
       ROUND((f.V * 100)::NUMBER(32,18) / NULLIF(f.PREV_V, 0), 2)              AS PCT_OF_PREVIOUS,
       ROUND((f.V * 100)::NUMBER(32,18) / NULLIF(f.TOP_V, 0), 2)               AS PCT_OF_IMPRESSIONS,
       ROUND((f.V * 100)::NUMBER(32,18) / NULLIF(f.TOP_V, 0), 4)               AS PCT_OF_IMPRESSIONS_4DP,
       ROUND((f.V * 100)::NUMBER(32,18) / NULLIF(MAX(f.V) OVER (), 0), 2)      AS FUNNEL_PCT_OF_MAX,
       f.VID_V AS VID_VALUE,
       ROUND((f.VID_V * 100)::NUMBER(32,18) / NULLIF(f.VID_PREV_V, 0), 2)      AS VID_PCT_OF_PREVIOUS,
       ROUND((f.VID_V * 100)::NUMBER(32,18) / NULLIF(f.VID_TOP_V, 0), 4)       AS VID_PCT_OF_IMPR_4DP,
       IFF(f.V = e.EXP_V AND EQUAL_NULL(f.PREV_V, e.EXP_PREV_V) AND f.TOP_V = e.EXP_TOP_V
           AND f.VID_V = e.EXP_VID_V AND EQUAL_NULL(f.VID_PREV_V, e.EXP_VID_PREV_V) AND f.VID_TOP_V = e.EXP_VID_TOP_V
           AND f.STAGE = e.STAGE, 'yes', 'NO') AS EQUALS_SEED,
       IFF(EQUALS_SEED = 'yes', 'PASS', 'FAIL') AS STATUS
FROM f
FULL OUTER JOIN expected e ON e.STAGE_ORDER = f.STAGE_ORDER
ORDER BY STAGE_ORDER;


-- -----------------------------------------------------------------------------
-- 8. P2-08 channel funnel comparison: table on CH, one row per channel, sorted by Lead
--    conversion rate descending, no summary row: IMPRESSIONS, CLICKS, Click-through rate, LEADS,
--    Click-to-lead rate, CONVERTED_LEADS, Lead conversion rate, the STORED Wilson bounds
--    LCR_CI_LOW / LCR_CI_HIGH (Percent, one row per channel), Cost per lead, Cost per
--    conversion. State video = the video row; state 2024 = unchanged (no date field).
--    Expected: bases [SEED EXPECTED_CAMPAIGN_KPI roll-up]; interval bounds [E04 8] (6 dp).
-- -----------------------------------------------------------------------------
WITH e04_ci (CHANNEL, LCR_CI_LOW, LCR_CI_HIGH) AS (
  SELECT * FROM VALUES                    -- [E04 8]
    ('paid_search', 0.150760, 0.156291),
    ('affiliate', 0.149888, 0.155299),
    ('video', 0.148113, 0.156886),
    ('paid_social', 0.147196, 0.153029),
    ('display', 0.146114, 0.152690)
),
seed AS (
  SELECT CHANNEL, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS,
         SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(SPEND) AS SPEND
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI GROUP BY CHANNEL
)
SELECT COALESCE(d.CHANNEL, s.CHANNEL) AS CHANNEL,
       RANK() OVER (ORDER BY d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.LEADS, 0) DESC NULLS LAST) AS ROW_NO,
       d.IMPRESSIONS, d.CLICKS,
       ROUND((d.CLICKS * 100)::NUMBER(32,18) / NULLIF(d.IMPRESSIONS, 0), 2)       AS CTR_PCT,
       d.LEADS,
       ROUND((d.LEADS * 100)::NUMBER(32,18) / NULLIF(d.CLICKS, 0), 2)             AS CTL_PCT,
       d.CONVERTED_LEADS,
       ROUND((d.CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)    AS LCR_PCT,
       ROUND(d.LCR_CI_LOW * 100, 2)                                               AS CI_LOW_PCT,
       ROUND(d.LCR_CI_HIGH * 100, 2)                                              AS CI_HIGH_PCT,
       ROUND(d.SPEND::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)                      AS CPL,
       ROUND(d.SPEND::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0), 2)            AS COST_PER_CONVERSION,
       IFF(d.IMPRESSIONS = s.IMPRESSIONS AND d.CLICKS = s.CLICKS AND d.LEADS = s.LEADS AND d.CONVERTED_LEADS = s.CONVERTED_LEADS
           AND d.SPEND = s.SPEND AND d.LCR_CI_LOW = e.LCR_CI_LOW AND d.LCR_CI_HIGH = e.LCR_CI_HIGH, 'yes', 'NO') AS EQUALS_REFERENCES,
       IFF(EQUALS_REFERENCES = 'yes', 'PASS', 'FAIL') AS STATUS
FROM MART_CHANNEL_PERFORMANCE d
FULL OUTER JOIN seed s ON s.CHANNEL = d.CHANNEL
LEFT JOIN e04_ci e ON e.CHANNEL = COALESCE(d.CHANNEL, s.CHANNEL)
ORDER BY ROW_NO;


-- -----------------------------------------------------------------------------
-- 9. P2-09 Lead conversion rate by lead cohort month: time series on COH, dimension
--    COHORT_MONTH (Year Month), metric Lead conversion rate = SUM(CONVERTED_LEADS) / SUM(LEADS):
--    of the leads created in the month, the share that converted (whenever). Never on one axis
--    with MM (decision 7). Missing data: Line Breaks.
--    STATES: default = LCR_PCT, 36 points; video = VID_LCR_PCT (NULL where video had no leads:
--      a line break, not 0%); 2024 / 2025 = the 12 rows of the year (gate G1: with the
--      report-level date control on page 1 set to 2025, this chart shows only the 2025 rows).
--    Expected: all channels [E04 16] month by month (leads, converted leads, rate 6 dp); video
--      [STG] (STG_LEADS by created month; their STG_CONVERSIONS by the lead's month).
-- -----------------------------------------------------------------------------
WITH e04_cohort (COHORT_MONTH, LEADS, CONVERTED_LEADS, CONVERTED_LATER_MONTH, CONVERSION_RATE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5 FROM VALUES      -- [E04 16]
    ('2023-01-01', 1325, 212, 102, 0.160000),
    ('2023-02-01', 2825, 427, 204, 0.151150),
    ('2023-03-01', 6229, 914, 320, 0.146733),
    ('2023-04-01', 5748, 880, 298, 0.153097),
    ('2023-05-01', 5188, 771, 258, 0.148612),
    ('2023-06-01', 7491, 1137, 432, 0.151782),
    ('2023-07-01', 7779, 1220, 379, 0.156832),
    ('2023-08-01', 9024, 1377, 535, 0.152593),
    ('2023-09-01', 10771, 1604, 549, 0.148918),
    ('2023-10-01', 10930, 1648, 543, 0.150778),
    ('2023-11-01', 10526, 1575, 536, 0.149629),
    ('2023-12-01', 9713, 1471, 457, 0.151447),
    ('2024-01-01', 6493, 975, 274, 0.150162),
    ('2024-02-01', 5638, 882, 362, 0.156438),
    ('2024-03-01', 7576, 1172, 471, 0.154699),
    ('2024-04-01', 10413, 1588, 635, 0.152502),
    ('2024-05-01', 8898, 1332, 417, 0.149697),
    ('2024-06-01', 5954, 918, 300, 0.154182),
    ('2024-07-01', 5895, 879, 318, 0.149109),
    ('2024-08-01', 10718, 1607, 609, 0.149935),
    ('2024-09-01', 11825, 1779, 608, 0.150444),
    ('2024-10-01', 11683, 1771, 549, 0.151588),
    ('2024-11-01', 10557, 1588, 558, 0.150422),
    ('2024-12-01', 11721, 1831, 631, 0.156215),
    ('2025-01-01', 10136, 1557, 489, 0.153611),
    ('2025-02-01', 6308, 930, 303, 0.147432),
    ('2025-03-01', 7226, 1099, 341, 0.152090),
    ('2025-04-01', 6504, 1036, 408, 0.159287),
    ('2025-05-01', 7506, 1113, 338, 0.148281),
    ('2025-06-01', 6371, 996, 363, 0.156333),
    ('2025-07-01', 7710, 1156, 418, 0.149935),
    ('2025-08-01', 7339, 1109, 337, 0.151111),
    ('2025-09-01', 3680, 513, 150, 0.139402),
    ('2025-10-01', 2826, 445, 133, 0.157466),
    ('2025-11-01', 1093, 173, 50, 0.158280),
    ('2025-12-01', 65, 11, 0, 0.169231)
),
dash AS (
  SELECT COHORT_MONTH, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(IFF(CHANNEL = 'video', LEADS, 0)) AS VID_LEADS,
         SUM(IFF(CHANNEL = 'video', CONVERTED_LEADS, 0)) AS VID_CONVERTED_LEADS
  FROM MART_MONTHLY_COHORT
  WHERE COHORT_MONTH BETWEEN '2023-01-01' AND '2025-12-31'
  GROUP BY COHORT_MONTH
),
stg_video AS (SELECT CAMPAIGN_ID FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS WHERE CHANNEL = 'video'),
stg_leads AS (
  SELECT DATE_TRUNC('month', l.CREATED_DATE) AS COHORT_MONTH, COUNT(*) AS LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS l JOIN stg_video c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY 1
),
stg_converted AS (
  SELECT DATE_TRUNC('month', l.CREATED_DATE) AS COHORT_MONTH, COUNT(*) AS CONVERTED_LEADS
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  JOIN stg_video c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY 1
)
SELECT TO_VARCHAR(COALESCE(d.COHORT_MONTH, e.COHORT_MONTH), 'YYYY-MM') AS COHORT_MONTH,
       TO_VARCHAR(YEAR(COALESCE(d.COHORT_MONTH, e.COHORT_MONTH))) AS YEAR,
       d.LEADS, d.CONVERTED_LEADS,
       ROUND((d.CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)         AS LCR_PCT,
       d.VID_LEADS, d.VID_CONVERTED_LEADS,
       ROUND((d.VID_CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.VID_LEADS, 0), 2) AS VID_LCR_PCT,
       IFF(d.LEADS = e.LEADS AND d.CONVERTED_LEADS = e.CONVERTED_LEADS
           AND ROUND(d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.LEADS, 0), 6) = e.CONVERSION_RATE, 'yes', 'NO') AS ALL_EQUALS_E04,
       IFF(d.VID_LEADS = COALESCE(l.LEADS, 0) AND d.VID_CONVERTED_LEADS = COALESCE(v.CONVERTED_LEADS, 0), 'yes', 'NO') AS VID_EQUALS_STG,
       IFF(ALL_EQUALS_E04 = 'yes' AND VID_EQUALS_STG = 'yes', 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN e04_cohort e ON e.COHORT_MONTH = d.COHORT_MONTH
LEFT JOIN stg_leads l     ON l.COHORT_MONTH = COALESCE(d.COHORT_MONTH, e.COHORT_MONTH)
LEFT JOIN stg_converted v ON v.COHORT_MONTH = COALESCE(d.COHORT_MONTH, e.COHORT_MONTH)
ORDER BY COHORT_MONTH;


-- -----------------------------------------------------------------------------
-- 10. P2-10..P2-12 conversion time cards, states default / video / 2024 / 2025.
--     P2-10 Mean days to convert and P2-11 Cross-month share on COH (by lead cohort month: the
--     leads created in the range); P2-12 Conversions after campaign end on DAILY, SUM(CONVERSIONS)
--     with the card filter "After flight" (IS_IN_FLIGHT = 0), by ACTIVITY_DATE (conversions
--     booked in the range after their campaign's END_DATE).
--     Expected: default [E04 18] mean lag, [SEED EXPECTED_TOTALS] conversions_later_month /
--       converted_leads and conversions_after_campaign_end; video [E04 18] (mean lag,
--       AFTER_CAMPAIGN_END), cross-month share [STG]; 2024 and 2025 [E04 16] (later-month and
--       converted sums of the year's cohorts), mean lag and after-end count [STG].
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER, DATE_FROM, DATE_TO) AS (
  SELECT COLUMN1, COLUMN2, COLUMN3, TO_DATE(COLUMN4), TO_DATE(COLUMN5) FROM VALUES
    ('default', 1, NULL,    '2023-01-01', '2025-12-31'),
    ('video',   2, 'video', '2023-01-01', '2025-12-31'),
    ('2024',    3, NULL,    '2024-01-01', '2024-12-31'),
    ('2025',    4, NULL,    '2025-01-01', '2025-12-31')
),
kpis (ID, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P2-10', 'Mean days to convert',   'COH: Mean days to convert',             'num',   4),
    ('P2-11', 'Converted in later mth', 'COH: Cross-month share',                'pct',   6),
    ('P2-12', 'Conversions after end',  'DAILY: SUM(CONVERSIONS), After flight', 'count', 0)
),
e04_lag (GROUP_VALUE, CONVERSIONS, MEAN_DAYS, AFTER_CAMPAIGN_END) AS (
  SELECT * FROM VALUES                    -- [E04 18]
    ('all', 39696, 10.5056, 4716),
    ('affiliate', 10352, 10.4954, 1263),
    ('display', 6744, 10.5101, 777),
    ('paid_search', 10019, 10.5017, 1108),
    ('paid_social', 8648, 10.5774, 1162),
    ('video', 3933, 10.3766, 406)
),
e04_cohort (COHORT_MONTH, LEADS, CONVERTED_LEADS, CONVERTED_LATER_MONTH, CONVERSION_RATE) AS (
  SELECT TO_DATE(COLUMN1), COLUMN2, COLUMN3, COLUMN4, COLUMN5 FROM VALUES      -- [E04 16]
    ('2023-01-01', 1325, 212, 102, 0.160000),
    ('2023-02-01', 2825, 427, 204, 0.151150),
    ('2023-03-01', 6229, 914, 320, 0.146733),
    ('2023-04-01', 5748, 880, 298, 0.153097),
    ('2023-05-01', 5188, 771, 258, 0.148612),
    ('2023-06-01', 7491, 1137, 432, 0.151782),
    ('2023-07-01', 7779, 1220, 379, 0.156832),
    ('2023-08-01', 9024, 1377, 535, 0.152593),
    ('2023-09-01', 10771, 1604, 549, 0.148918),
    ('2023-10-01', 10930, 1648, 543, 0.150778),
    ('2023-11-01', 10526, 1575, 536, 0.149629),
    ('2023-12-01', 9713, 1471, 457, 0.151447),
    ('2024-01-01', 6493, 975, 274, 0.150162),
    ('2024-02-01', 5638, 882, 362, 0.156438),
    ('2024-03-01', 7576, 1172, 471, 0.154699),
    ('2024-04-01', 10413, 1588, 635, 0.152502),
    ('2024-05-01', 8898, 1332, 417, 0.149697),
    ('2024-06-01', 5954, 918, 300, 0.154182),
    ('2024-07-01', 5895, 879, 318, 0.149109),
    ('2024-08-01', 10718, 1607, 609, 0.149935),
    ('2024-09-01', 11825, 1779, 608, 0.150444),
    ('2024-10-01', 11683, 1771, 549, 0.151588),
    ('2024-11-01', 10557, 1588, 558, 0.150422),
    ('2024-12-01', 11721, 1831, 631, 0.156215),
    ('2025-01-01', 10136, 1557, 489, 0.153611),
    ('2025-02-01', 6308, 930, 303, 0.147432),
    ('2025-03-01', 7226, 1099, 341, 0.152090),
    ('2025-04-01', 6504, 1036, 408, 0.159287),
    ('2025-05-01', 7506, 1113, 338, 0.148281),
    ('2025-06-01', 6371, 996, 363, 0.156333),
    ('2025-07-01', 7710, 1156, 418, 0.149935),
    ('2025-08-01', 7339, 1109, 337, 0.151111),
    ('2025-09-01', 3680, 513, 150, 0.139402),
    ('2025-10-01', 2826, 445, 133, 0.157466),
    ('2025-11-01', 1093, 173, 50, 0.158280),
    ('2025-12-01', 65, 11, 0, 0.169231)
),
cohort AS (
  SELECT s.STATE, SUM(c.SUM_DAYS_TO_CONVERT) AS SUM_DAYS, SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(c.CONVERTED_LATER_MONTH) AS LATER_MONTH
  FROM states s
  JOIN MART_MONTHLY_COHORT c
    ON c.COHORT_MONTH BETWEEN s.DATE_FROM AND s.DATE_TO AND (s.CHANNEL_FILTER IS NULL OR c.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE
),
after_end AS (
  SELECT s.STATE, SUM(a.CONVERSIONS) AS CONVERSIONS
  FROM states s
  JOIN FCT_CAMPAIGN_DAILY_ACTIVITY a
    ON a.ACTIVITY_DATE BETWEEN s.DATE_FROM AND s.DATE_TO AND (s.CHANNEL_FILTER IS NULL OR a.CHANNEL = s.CHANNEL_FILTER)
   AND a.IS_IN_FLIGHT = 0
  GROUP BY s.STATE
),
dash AS (
  SELECT s.STATE, s.STATE_NO, c.SUM_DAYS::NUMBER(32,18) / NULLIF(c.CONVERTED_LEADS, 0) AS MEAN_DAYS,
         c.LATER_MONTH::NUMBER(32,18) / NULLIF(c.CONVERTED_LEADS, 0) AS LATER_SHARE, a.CONVERSIONS AS AFTER_END
  FROM states s
  LEFT JOIN cohort c ON c.STATE = s.STATE
  LEFT JOIN after_end a ON a.STATE = s.STATE
),
stg_conv AS (               -- [STG] one row per conversion: channel, dates, lag, later month, after the campaign's end
  SELECT c.CHANNEL, l.CREATED_DATE, v.CONVERTED_DATE,
         DATEDIFF('day', l.CREATED_DATE, v.CONVERTED_DATE) AS DAYS,
         IFF(DATE_TRUNC('month', v.CONVERTED_DATE) > DATE_TRUNC('month', l.CREATED_DATE), 1, 0) AS LATER_MONTH,
         IFF(v.CONVERTED_DATE > c.END_DATE, 1, 0) AS AFTER_END
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
),
stg_years AS (
  SELECT y.YEAR,
         SUM(IFF(YEAR(s.CREATED_DATE) = y.YEAR, s.DAYS, 0))::NUMBER(32,18) / COUNT_IF(YEAR(s.CREATED_DATE) = y.YEAR) AS MEAN_DAYS,
         SUM(IFF(YEAR(s.CONVERTED_DATE) = y.YEAR, s.AFTER_END, 0)) AS AFTER_END
  FROM (SELECT 2024 AS YEAR UNION ALL SELECT 2025) y CROSS JOIN stg_conv s
  GROUP BY y.YEAR
),
cohort_years AS (           -- [E04 16] per year
  SELECT YEAR(COHORT_MONTH) AS YEAR, SUM(CONVERTED_LATER_MONTH)::NUMBER(32,18) / SUM(CONVERTED_LEADS) AS LATER_SHARE
  FROM e04_cohort GROUP BY 1
),
seed AS (
  SELECT MAX(IFF(METRIC = 'conversions_later_month', VALUE, NULL)) AS LATER_MONTH,
         MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERTED_LEADS,
         MAX(IFF(METRIC = 'conversions_after_campaign_end', VALUE, NULL)) AS AFTER_END
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
ref (STATE, MEAN_DAYS, LATER_SHARE, AFTER_END) AS (
  SELECT 'default', e.MEAN_DAYS, s.LATER_MONTH::NUMBER(32,18) / s.CONVERTED_LEADS, s.AFTER_END
  FROM seed s JOIN e04_lag e ON e.GROUP_VALUE = 'all'
  UNION ALL
  SELECT 'video', e.MEAN_DAYS, v.LATER_SHARE, e.AFTER_CAMPAIGN_END
  FROM e04_lag e
  CROSS JOIN (SELECT SUM(LATER_MONTH)::NUMBER(32,18) / COUNT(*) AS LATER_SHARE FROM stg_conv WHERE CHANNEL = 'video') v
  WHERE e.GROUP_VALUE = 'video'
  UNION ALL
  SELECT TO_VARCHAR(g.YEAR), g.MEAN_DAYS, h.LATER_SHARE, g.AFTER_END
  FROM stg_years g JOIN cohort_years h ON h.YEAR = g.YEAR
),
card_rows AS (
  SELECT k.ID, d.STATE, d.STATE_NO, k.COMPONENT, k.FIELD, k.KIND, k.DP,
         (CASE k.ID WHEN 'P2-10' THEN d.MEAN_DAYS WHEN 'P2-11' THEN d.LATER_SHARE ELSE d.AFTER_END END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P2-10' THEN r.MEAN_DAYS WHEN 'P2-11' THEN r.LATER_SHARE ELSE r.AFTER_END END)::NUMBER(38,18) AS R,
         CASE WHEN d.STATE = 'default' AND k.ID = 'P2-10' THEN 'E04 [18] all'
              WHEN d.STATE = 'default' THEN 'SEED EXPECTED_TOTALS'
              WHEN d.STATE = 'video' AND k.ID = 'P2-11' THEN 'STG video conversions'
              WHEN d.STATE = 'video' THEN 'E04 [18] video'
              WHEN k.ID = 'P2-11' THEN 'E04 [16] sum of the ' || d.STATE || ' cohorts'
              WHEN k.ID = 'P2-10' THEN 'STG leads created in ' || d.STATE
              ELSE 'STG converted in ' || d.STATE || ', after end' END AS REF_SOURCE
  FROM dash d
  JOIN ref r ON r.STATE = d.STATE
  CROSS JOIN kpis k
)
SELECT ID, STATE, COMPONENT, FIELD,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM card_rows
ORDER BY ID, STATE_NO;


-- =============================================================================
-- PAGE 3: LEAD QUALITY & CRM
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 11. P3-01..P3-05 KPI cards on LQ, states default / video. State 2024 is not computed: LQ
--     has no date column (block 0b), so the page does not follow the date range and the cards
--     keep their default values; a 2024 row here could only repeat the default check.
--     Expected: default [SEED EXPECTED_TOTALS] (leads, sum_lead_score, converted_leads,
--       purchases), mean lag [E04 18] all; video [SEED EXPECTED_CAMPAIGN_KPI] (leads, converted,
--       purchases), average score [E05 10] (4 dp), mean lag [E04 18] video.
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER) AS (
  SELECT * FROM VALUES ('default', 1, NULL), ('video', 2, 'video')
),
kpis (ID, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P3-01', 'Total leads',          'LQ: SUM(LEADS)',                      'count', 0),
    ('P3-02', 'Average lead score',   'LQ: SUM(SUM_LEAD_SCORE)/SUM(LEADS)',  'num',   4),
    ('P3-03', 'Lead conversion rate', 'LQ: SUM(CONVERTED_LEADS)/SUM(LEADS)', 'pct',   6),
    ('P3-04', 'Purchase rate',        'LQ: SUM(PURCHASES)/SUM(LEADS)',       'pct',   6),
    ('P3-05', 'Mean days to convert', 'LQ: Mean days to convert',            'num',   4)
),
e04_lag (GROUP_VALUE, CONVERSIONS, MEAN_DAYS, AFTER_CAMPAIGN_END) AS (
  SELECT * FROM VALUES                    -- [E04 18]
    ('all', 39696, 10.5056, 4716),
    ('affiliate', 10352, 10.4954, 1263),
    ('display', 6744, 10.5101, 777),
    ('paid_search', 10019, 10.5017, 1108),
    ('paid_social', 8648, 10.5774, 1162),
    ('video', 3933, 10.3766, 406)
),
e05_channel (CHANNEL, LEADS, AVG_SCORE, CONVERSION_RATE, SHARE_LOW, SHARE_MEDIUM, SHARE_HIGH) AS (
  SELECT * FROM VALUES                    -- [E05 10]
    ('affiliate', 67849, 50.5620, 0.152574, 0.398842, 0.301832, 0.299326),
    ('display', 45149, 50.5366, 0.149372, 0.398680, 0.301889, 0.299431),
    ('paid_search', 65268, 50.6614, 0.153506, 0.395967, 0.302476, 0.301557),
    ('paid_social', 57619, 50.4742, 0.150089, 0.401413, 0.297818, 0.300769),
    ('video', 25799, 50.6429, 0.152448, 0.395791, 0.304314, 0.299895),
    ('All channels', 261684, 50.5711, 0.151694, 0.398362, 0.301363, 0.300274)
),
dash AS (
  SELECT s.STATE, s.STATE_NO, SUM(q.LEADS) AS LEADS, SUM(q.SUM_LEAD_SCORE) AS SUM_LEAD_SCORE,
         SUM(q.CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(q.PURCHASES) AS PURCHASES, SUM(q.SUM_DAYS_TO_CONVERT) AS SUM_DAYS
  FROM states s
  JOIN MART_LEAD_QUALITY q ON (s.CHANNEL_FILTER IS NULL OR q.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE, s.STATE_NO
),
seed_totals AS (
  SELECT MAX(IFF(METRIC = 'leads', VALUE, NULL)) AS LEADS, MAX(IFF(METRIC = 'sum_lead_score', VALUE, NULL)) AS SUM_LEAD_SCORE,
         MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERTED_LEADS, MAX(IFF(METRIC = 'purchases', VALUE, NULL)) AS PURCHASES
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
ref AS (
  SELECT 'default' AS STATE, t.LEADS, t.SUM_LEAD_SCORE::NUMBER(32,18) / t.LEADS AS AVG_SCORE, t.CONVERTED_LEADS, t.PURCHASES,
         e.MEAN_DAYS
  FROM seed_totals t JOIN e04_lag e ON e.GROUP_VALUE = 'all'
  UNION ALL
  SELECT 'video', SUM(k.LEADS), (SELECT AVG_SCORE FROM e05_channel WHERE CHANNEL = 'video'), SUM(k.CONVERTED_LEADS),
         SUM(k.PURCHASES), (SELECT MEAN_DAYS FROM e04_lag WHERE GROUP_VALUE = 'video')
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI k WHERE k.CHANNEL = 'video'
),
card_rows AS (
  SELECT k.ID, d.STATE, d.STATE_NO, k.COMPONENT, k.FIELD, k.KIND, k.DP,
         (CASE k.ID WHEN 'P3-01' THEN d.LEADS
                    WHEN 'P3-02' THEN d.SUM_LEAD_SCORE::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P3-03' THEN d.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P3-04' THEN d.PURCHASES::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P3-05' THEN d.SUM_DAYS::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0) END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P3-01' THEN r.LEADS
                    WHEN 'P3-02' THEN r.AVG_SCORE
                    WHEN 'P3-03' THEN r.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(r.LEADS, 0)
                    WHEN 'P3-04' THEN r.PURCHASES::NUMBER(32,18) / NULLIF(r.LEADS, 0)
                    WHEN 'P3-05' THEN r.MEAN_DAYS END)::NUMBER(38,18) AS R,
         CASE WHEN k.ID = 'P3-05' AND d.STATE = 'video' THEN 'E04 [18] video'
              WHEN k.ID = 'P3-05'                       THEN 'E04 [18] all'
              WHEN k.ID = 'P3-02' AND d.STATE = 'video' THEN 'E05 [10] video'
              WHEN d.STATE = 'video'                    THEN 'SEED EXPECTED_CAMPAIGN_KPI, video'
              ELSE 'SEED EXPECTED_TOTALS' END AS REF_SOURCE
  FROM dash d
  JOIN ref r ON r.STATE = d.STATE
  CROSS JOIN kpis k
)
SELECT ID, STATE, COMPONENT, FIELD,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       CASE WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000 THEN TO_VARCHAR(ROUND(V / 1000, 1), 'FM999,990.0') || 'K'
            ELSE '' END AS COMPACT,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM card_rows
ORDER BY ID, STATE_NO;


-- -----------------------------------------------------------------------------
-- 12. P3-06 conversion by score segment (column chart) and P3-07 segment table, on LQ:
--     dimension LEAD_SCORE_SEGMENT sorted by SCORE_BAND_MIN (Min, ascending: Low, Medium,
--     High). P3-07 columns: LEADS, Share of leads (LEADS with the comparison calculation
--     "Percent of total"), CONVERTED_LEADS, Lead conversion rate, Purchase rate, Average lead
--     score, Mean days to convert, and its summary row. State video: VID_LCR_PCT (P3-06);
--     state 2024: unchanged (no date field).
--     CAVEAT: association only; how the score is produced is undocumented.
--     Expected: leads and converted [SEED EXPECTED_TOTALS leads_low ... converted_high]; share,
--       rate and purchase rate [E05 6]; average score [E02cT 24]; mean lag [E05 13]; video rate
--       [E05 11]; summary row [SEED] totals.
-- -----------------------------------------------------------------------------
WITH e05_segments (SEGMENT, LEAD_SHARE, CONVERSION_RATE, PURCHASE_RATE) AS (
  SELECT * FROM VALUES                    -- [E05 6]
    ('Low', 0.398362, 0.091179, 0.038035),
    ('Medium', 0.301363, 0.161776, 0.067789),
    ('High', 0.300274, 0.221859, 0.093921)
),
e05_rates (SEGMENT, VIDEO_RATE, ALL_RATE) AS (
  SELECT * FROM VALUES                    -- [E05 11]
    ('Low', 0.089511, 0.091179),
    ('Medium', 0.163673, 0.161776),
    ('High', 0.224118, 0.221859),
    ('All leads', 0.152448, 0.151694)
),
e05_lag (SEGMENT, CONVERSIONS, AVG_LAG) AS (
  SELECT * FROM VALUES                    -- [E05 13]
    ('Low', 9505, 10.6084),
    ('Medium', 12758, 10.4609),
    ('High', 17433, 10.4822)
),
e02ct_score (SEGMENT, AVG_LEAD_SCORE) AS (
  SELECT * FROM VALUES                    -- [E02cT 24]
    ('Low', 20.4796),
    ('Medium', 55.5244),
    ('High', 85.5210)
),
dash AS (
  SELECT IFF(GROUPING(LEAD_SCORE_SEGMENT) = 1, 'summary', LEAD_SCORE_SEGMENT) AS SEGMENT,
         IFF(GROUPING(LEAD_SCORE_SEGMENT) = 1, 999, MIN(SCORE_BAND_MIN)) AS SORT_KEY, GROUPING(LEAD_SCORE_SEGMENT) AS IS_SUMMARY,
         SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(PURCHASES) AS PURCHASES,
         SUM(SUM_LEAD_SCORE) AS SUM_LEAD_SCORE, SUM(SUM_DAYS_TO_CONVERT) AS SUM_DAYS,
         SUM(IFF(CHANNEL = 'video', LEADS, 0)) AS VID_LEADS,
         SUM(IFF(CHANNEL = 'video', CONVERTED_LEADS, 0)) AS VID_CONVERTED_LEADS
  FROM MART_LEAD_QUALITY
  GROUP BY GROUPING SETS ((LEAD_SCORE_SEGMENT), ())
),
shares AS (                 -- "Percent of total" over the segment rows shown
  SELECT d.*, d.LEADS::NUMBER(32,18) / SUM(IFF(d.IS_SUMMARY = 0, d.LEADS, 0)) OVER () AS LEAD_SHARE
  FROM dash d
),
seed AS (                   -- [SEED] per segment, and the all-lead totals for the summary row
  SELECT INITCAP(SPLIT_PART(METRIC, '_', 2)) AS SEGMENT,
         MAX(IFF(STARTSWITH(METRIC, 'leads_'), VALUE, NULL)) AS LEADS,
         MAX(IFF(STARTSWITH(METRIC, 'converted_'), VALUE, NULL)) AS CONVERTED_LEADS
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
  WHERE METRIC IN ('leads_low', 'leads_medium', 'leads_high', 'converted_low', 'converted_medium', 'converted_high')
  GROUP BY 1
  UNION ALL
  SELECT 'summary', MAX(IFF(METRIC = 'leads', VALUE, NULL)), MAX(IFF(METRIC = 'converted_leads', VALUE, NULL))
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
)
SELECT d.SEGMENT, d.SORT_KEY, d.LEADS,
       ROUND(d.LEAD_SHARE * 100, 2)                                                     AS SHARE_OF_LEADS_PCT,
       d.CONVERTED_LEADS,
       ROUND((d.CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)          AS LCR_PCT,
       ROUND((d.PURCHASES * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)                AS PURCHASE_RATE_PCT,
       ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)                   AS AVG_SCORE,
       ROUND(d.SUM_DAYS::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0), 2)               AS MEAN_DAYS,
       ROUND((d.VID_CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.VID_LEADS, 0), 2)  AS VID_LCR_PCT,
       IFF(d.LEADS = s.LEADS AND d.CONVERTED_LEADS = s.CONVERTED_LEADS
           AND (d.IS_SUMMARY = 1 OR (
                 ROUND(d.LEAD_SHARE, 6) = g.LEAD_SHARE
             AND ROUND(d.CONVERTED_LEADS::NUMBER(32,18) / d.LEADS, 6) = g.CONVERSION_RATE
             AND ROUND(d.PURCHASES::NUMBER(32,18) / d.LEADS, 6) = g.PURCHASE_RATE
             AND ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / d.LEADS, 4) = c.AVG_LEAD_SCORE
             AND ROUND(d.SUM_DAYS::NUMBER(32,18) / d.CONVERTED_LEADS, 4) = l.AVG_LAG
             AND ROUND(d.VID_CONVERTED_LEADS::NUMBER(32,18) / d.VID_LEADS, 6) = r.VIDEO_RATE)), 'yes', 'NO') AS EQUALS_REFERENCES,
       IFF(EQUALS_REFERENCES = 'yes', 'PASS', 'FAIL') AS STATUS
FROM shares d
LEFT JOIN seed s         ON s.SEGMENT = d.SEGMENT
LEFT JOIN e05_segments g ON g.SEGMENT = d.SEGMENT
LEFT JOIN e05_rates r    ON r.SEGMENT = d.SEGMENT
LEFT JOIN e05_lag l      ON l.SEGMENT = d.SEGMENT
LEFT JOIN e02ct_score c  ON c.SEGMENT = d.SEGMENT
ORDER BY d.SORT_KEY;


-- -----------------------------------------------------------------------------
-- 13. P3-08 leads and conversion by 10-point score band: combo chart on LQ, dimension
--     SCORE_BAND (zero-padded text, sorted ascending), bars SUM(LEADS), line Lead conversion
--     rate. STATES: default; video (VID_ columns); 2024 unchanged (no date field).
--     Expected: all channels [E05 8] (leads, converted, rate 6 dp, average score 4 dp); video
--       [STG] (STG_LEADS of video campaigns by band FLOOR((score - 1) / 10) x 10 + 1, and their
--       conversions).
-- -----------------------------------------------------------------------------
WITH e05_bands (SCORE_BAND, LEADS, AVG_SCORE, CONVERTED_LEADS, CONVERSION_RATE) AS (
  SELECT * FROM VALUES                    -- [E05 8], band rows
    ('01-10', 26193, 5.4830, 1642, 0.062689),
    ('11-20', 26058, 15.4779, 2072, 0.079515),
    ('21-30', 25748, 25.4824, 2624, 0.101911),
    ('31-40', 26246, 35.5038, 3167, 0.120666),
    ('41-50', 26293, 45.5333, 3724, 0.141635),
    ('51-60', 26173, 55.4918, 4195, 0.160280),
    ('61-70', 26396, 65.5088, 4839, 0.183323),
    ('71-80', 26184, 75.4955, 5316, 0.203025),
    ('81-90', 26068, 85.5061, 5795, 0.222303),
    ('91-100', 26325, 95.5075, 6322, 0.240152)
),
dash AS (
  SELECT SCORE_BAND, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(SUM_LEAD_SCORE) AS SUM_LEAD_SCORE,
         SUM(IFF(CHANNEL = 'video', LEADS, 0)) AS VID_LEADS,
         SUM(IFF(CHANNEL = 'video', CONVERTED_LEADS, 0)) AS VID_CONVERTED_LEADS
  FROM MART_LEAD_QUALITY
  GROUP BY SCORE_BAND
),
stg_leads AS (
  SELECT LPAD(TO_VARCHAR((FLOOR((l.LEAD_SCORE - 1) / 10) * 10 + 1)::INTEGER), 2, '0') || '-'
           || TO_VARCHAR((FLOOR((l.LEAD_SCORE - 1) / 10) * 10 + 10)::INTEGER) AS SCORE_BAND,
         IFF(v.LEAD_ID IS NOT NULL, 1, 0) AS IS_CONVERTED
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID AND c.CHANNEL = 'video'
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID
),
stg AS (SELECT SCORE_BAND, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS FROM stg_leads GROUP BY SCORE_BAND)
SELECT COALESCE(d.SCORE_BAND, e.SCORE_BAND) AS SCORE_BAND, d.LEADS, d.CONVERTED_LEADS,
       ROUND((d.CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)          AS LCR_PCT,
       ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)                   AS AVG_SCORE,
       d.VID_LEADS, d.VID_CONVERTED_LEADS,
       ROUND((d.VID_CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.VID_LEADS, 0), 2)  AS VID_LCR_PCT,
       IFF(d.LEADS = e.LEADS AND d.CONVERTED_LEADS = e.CONVERTED_LEADS
           AND ROUND(d.CONVERTED_LEADS::NUMBER(32,18) / d.LEADS, 6) = e.CONVERSION_RATE
           AND ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / d.LEADS, 4) = e.AVG_SCORE, 'yes', 'NO') AS ALL_EQUALS_E05,
       IFF(d.VID_LEADS = s.LEADS AND d.VID_CONVERTED_LEADS = s.CONVERTED_LEADS, 'yes', 'NO') AS VID_EQUALS_STG,
       IFF(ALL_EQUALS_E05 = 'yes' AND VID_EQUALS_STG = 'yes', 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN e05_bands e ON e.SCORE_BAND = d.SCORE_BAND
LEFT JOIN stg s ON s.SCORE_BAND = COALESCE(d.SCORE_BAND, e.SCORE_BAND)
ORDER BY SCORE_BAND;


-- -----------------------------------------------------------------------------
-- 14. The channel charts of page 3, all on LQ by CHANNEL:
--       P3-09 days to convert by channel  bar, Mean days to convert, sorted by CHANNEL
--       P3-10 channel lead quality        table sorted by LEADS desc: LEADS, Average lead score,
--                                         Lead conversion rate, Purchase rate; summary row
--       P3-11 score mix by channel        stacked bars, LEADS by LEAD_SCORE_SEGMENT, as the
--                                         share of the channel's leads (100% stacking)
--     State video: the video row; state 2024: unchanged (no date field).
--     CAVEAT: channel differences in conversion are within sampling noise (chi-square p 0.26,
--       sql/04 block 2.2); the score mix is about 40/30/30 everywhere.
--     Expected: leads, converted, purchases [SEED EXPECTED_CAMPAIGN_KPI]; average score, rate and
--       segment shares [E05 10]; mean lag [E04 18].
-- -----------------------------------------------------------------------------
WITH e05_channel (CHANNEL, LEADS, AVG_SCORE, CONVERSION_RATE, SHARE_LOW, SHARE_MEDIUM, SHARE_HIGH) AS (
  SELECT * FROM VALUES                    -- [E05 10]
    ('affiliate', 67849, 50.5620, 0.152574, 0.398842, 0.301832, 0.299326),
    ('display', 45149, 50.5366, 0.149372, 0.398680, 0.301889, 0.299431),
    ('paid_search', 65268, 50.6614, 0.153506, 0.395967, 0.302476, 0.301557),
    ('paid_social', 57619, 50.4742, 0.150089, 0.401413, 0.297818, 0.300769),
    ('video', 25799, 50.6429, 0.152448, 0.395791, 0.304314, 0.299895),
    ('All channels', 261684, 50.5711, 0.151694, 0.398362, 0.301363, 0.300274)
),
e04_lag (GROUP_VALUE, CONVERSIONS, MEAN_DAYS, AFTER_CAMPAIGN_END) AS (
  SELECT * FROM VALUES                    -- [E04 18]
    ('all', 39696, 10.5056, 4716),
    ('affiliate', 10352, 10.4954, 1263),
    ('display', 6744, 10.5101, 777),
    ('paid_search', 10019, 10.5017, 1108),
    ('paid_social', 8648, 10.5774, 1162),
    ('video', 3933, 10.3766, 406)
),
dash AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'summary', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_SUMMARY,
         SUM(LEADS) AS LEADS, SUM(SUM_LEAD_SCORE) AS SUM_LEAD_SCORE, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(PURCHASES) AS PURCHASES, SUM(SUM_DAYS_TO_CONVERT) AS SUM_DAYS,
         SUM(IFF(LEAD_SCORE_SEGMENT = 'Low', LEADS, 0)) AS LEADS_LOW,
         SUM(IFF(LEAD_SCORE_SEGMENT = 'Medium', LEADS, 0)) AS LEADS_MEDIUM,
         SUM(IFF(LEAD_SCORE_SEGMENT = 'High', LEADS, 0)) AS LEADS_HIGH
  FROM MART_LEAD_QUALITY
  GROUP BY GROUPING SETS ((CHANNEL), ())
),
seed AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'summary', CHANNEL) AS CHANNEL,
         SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(PURCHASES) AS PURCHASES
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI
  GROUP BY GROUPING SETS ((CHANNEL), ())
)
SELECT COALESCE(d.CHANNEL, s.CHANNEL) AS CHANNEL, d.LEADS,
       ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)              AS AVG_SCORE,
       ROUND((d.CONVERTED_LEADS * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)     AS LCR_PCT,
       ROUND((d.PURCHASES * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)           AS PURCHASE_RATE_PCT,
       ROUND(d.SUM_DAYS::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0), 2)          AS MEAN_DAYS,
       ROUND((d.LEADS_LOW * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)           AS LOW_PCT,
       ROUND((d.LEADS_MEDIUM * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)        AS MEDIUM_PCT,
       ROUND((d.LEADS_HIGH * 100)::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)          AS HIGH_PCT,
       IFF(d.LEADS = s.LEADS AND d.CONVERTED_LEADS = s.CONVERTED_LEADS AND d.PURCHASES = s.PURCHASES
           AND ROUND(d.SUM_LEAD_SCORE::NUMBER(32,18) / d.LEADS, 4) = e.AVG_SCORE
           AND ROUND(d.CONVERTED_LEADS::NUMBER(32,18) / d.LEADS, 6) = e.CONVERSION_RATE
           AND ROUND(d.LEADS_LOW::NUMBER(32,18) / d.LEADS, 6) = e.SHARE_LOW
           AND ROUND(d.LEADS_MEDIUM::NUMBER(32,18) / d.LEADS, 6) = e.SHARE_MEDIUM
           AND ROUND(d.LEADS_HIGH::NUMBER(32,18) / d.LEADS, 6) = e.SHARE_HIGH
           AND ROUND(d.SUM_DAYS::NUMBER(32,18) / d.CONVERTED_LEADS, 4) = g.MEAN_DAYS, 'yes', 'NO') AS EQUALS_REFERENCES,
       IFF(EQUALS_REFERENCES = 'yes', 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN seed s ON s.CHANNEL = d.CHANNEL
LEFT JOIN e05_channel e ON e.CHANNEL = IFF(COALESCE(d.CHANNEL, s.CHANNEL) = 'summary', 'All channels', COALESCE(d.CHANNEL, s.CHANNEL))
LEFT JOIN e04_lag g     ON g.GROUP_VALUE = IFF(COALESCE(d.CHANNEL, s.CHANNEL) = 'summary', 'all', COALESCE(d.CHANNEL, s.CHANNEL))
ORDER BY d.IS_SUMMARY, d.LEADS DESC;


-- =============================================================================
-- PAGE 4: MARKETING EFFICIENCY & ROAS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 15. P4-01..P4-06 KPI cards on CH (whole campaigns, full range), states default / video.
--     State 2024 is not computed: CH has no date column (block 0b), so the cards keep their
--     default values (only P4-07 on this page follows the date range); a 2024 row here could
--     only repeat the default check.
--     CAVEAT: ROAS is last-touch attributed revenue / spend, not the causal return.
--     Expected: default [SEED EXPECTED_TOTALS]; video [PUB] (spend, revenue) and [SEED
--       EXPECTED_CAMPAIGN_KPI] (leads, converted, budget).
-- -----------------------------------------------------------------------------
WITH states (STATE, STATE_NO, CHANNEL_FILTER) AS (
  SELECT * FROM VALUES ('default', 1, NULL), ('video', 2, 'video')
),
kpis (ID, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    ('P4-01', 'Total spend',          'CH: SUM(SPEND)',                      'money', 2),
    ('P4-02', 'Attributed revenue',   'CH: SUM(REVENUE)',                    'money', 2),
    ('P4-03', 'ROAS (attributed)',    'CH: SUM(REVENUE)/SUM(SPEND)',         'num',   6),
    ('P4-04', 'Cost per lead',        'CH: SUM(SPEND)/SUM(LEADS)',           'num',   4),
    ('P4-05', 'Cost per conversion',  'CH: SUM(SPEND)/SUM(CONVERTED_LEADS)', 'num',   4),
    ('P4-06', 'Budget utilisation',   'CH: SUM(SPEND)/SUM(BUDGET)',          'pct',   6)
),
dash AS (
  SELECT s.STATE, s.STATE_NO, SUM(c.SPEND) AS SPEND, SUM(c.REVENUE) AS REVENUE, SUM(c.LEADS) AS LEADS,
         SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(c.BUDGET) AS BUDGET
  FROM states s
  JOIN MART_CHANNEL_PERFORMANCE c ON (s.CHANNEL_FILTER IS NULL OR c.CHANNEL = s.CHANNEL_FILTER)
  GROUP BY s.STATE, s.STATE_NO
),
seed_totals AS (
  SELECT MAX(IFF(METRIC = 'spend', VALUE, NULL)) AS SPEND, MAX(IFF(METRIC = 'revenue', VALUE, NULL)) AS REVENUE,
         MAX(IFF(METRIC = 'leads', VALUE, NULL)) AS LEADS, MAX(IFF(METRIC = 'converted_leads', VALUE, NULL)) AS CONVERTED_LEADS,
         MAX(IFF(METRIC = 'budget', VALUE, NULL)) AS BUDGET
  FROM MARKETING_CRM.STAGING.EXPECTED_TOTALS
),
ref AS (
  SELECT 'default' AS STATE, SPEND, REVENUE, LEADS, CONVERTED_LEADS, BUDGET FROM seed_totals
  UNION ALL
  SELECT 'video', p.SPEND, p.ATTRIBUTED_REVENUE, k.LEADS, k.CONVERTED_LEADS, k.BUDGET
  FROM MARKETING_CRM.STAGING.PUBLISHER_CHANNEL_REFERENCE p
  CROSS JOIN (SELECT SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(BUDGET) AS BUDGET
              FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CHANNEL = 'video') k
  WHERE p.CHANNEL = 'video'
),
card_rows AS (
  SELECT k.ID, d.STATE, d.STATE_NO, k.COMPONENT, k.FIELD, k.KIND, k.DP,
         (CASE k.ID WHEN 'P4-01' THEN d.SPEND
                    WHEN 'P4-02' THEN d.REVENUE
                    WHEN 'P4-03' THEN d.REVENUE::NUMBER(32,18) / NULLIF(d.SPEND, 0)
                    WHEN 'P4-04' THEN d.SPEND::NUMBER(32,18) / NULLIF(d.LEADS, 0)
                    WHEN 'P4-05' THEN d.SPEND::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0)
                    WHEN 'P4-06' THEN d.SPEND::NUMBER(32,18) / NULLIF(d.BUDGET, 0) END)::NUMBER(38,18) AS V,
         (CASE k.ID WHEN 'P4-01' THEN r.SPEND
                    WHEN 'P4-02' THEN r.REVENUE
                    WHEN 'P4-03' THEN r.REVENUE::NUMBER(32,18) / NULLIF(r.SPEND, 0)
                    WHEN 'P4-04' THEN r.SPEND::NUMBER(32,18) / NULLIF(r.LEADS, 0)
                    WHEN 'P4-05' THEN r.SPEND::NUMBER(32,18) / NULLIF(r.CONVERTED_LEADS, 0)
                    WHEN 'P4-06' THEN r.SPEND::NUMBER(32,18) / NULLIF(r.BUDGET, 0) END)::NUMBER(38,18) AS R,
         CASE WHEN d.STATE = 'default' THEN 'SEED EXPECTED_TOTALS'
              WHEN d.STATE = 'video' AND k.ID IN ('P4-01', 'P4-02', 'P4-03') THEN 'PUB video'
              ELSE 'PUB spend / SEED video' END AS REF_SOURCE
  FROM dash d
  JOIN ref r ON r.STATE = d.STATE
  CROSS JOIN kpis k
)
SELECT ID, STATE, COMPONENT, FIELD,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       CASE WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000000 THEN TO_VARCHAR(ROUND(V / 1000000, 1), 'FM999,990.0') || 'M'
            WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000    THEN TO_VARCHAR(ROUND(V / 1000, 1), 'FM999,990.0') || 'K'
            ELSE '' END AS COMPACT,
       CASE WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000000 THEN TO_VARCHAR(ROUND(V / 1000000, 2), 'FM999,990.00') || 'M'
            WHEN KIND IN ('count', 'money') AND ABS(V) >= 1000    THEN TO_VARCHAR(ROUND(V / 1000, 2), 'FM999,990.00') || 'K'
            ELSE '' END AS COMPACT_2DP,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM card_rows
ORDER BY ID, STATE_NO;


-- -----------------------------------------------------------------------------
-- 16. P4-08 channel efficiency comparison (table on CH, sorted by ROAS (attributed) desc, with
--     summary row: BUDGET, SPEND, REVENUE, ROAS, Cost per lead, Cost per conversion, Cost per
--     purchase, Budget utilisation) and P4-09 spend share vs revenue share (columns of the
--     STORED SPEND_SHARE and REVENUE_SHARE, Percent, sorted by REVENUE_SHARE desc). The stored
--     shares are shares of all five channels, so with the channel control on video they stay
--     18.31% / 9.68%, while a "Percent of total" comparison of SUM(SPEND) would show 100.00%.
--     State 2024: unchanged (no date field).
--     CAVEAT: budget utilisation is SPEND / BUDGET of whole campaigns only, never by month.
--     Expected: spend and revenue [PUB]; leads, converted, purchases, budget [SEED
--       EXPECTED_CAMPAIGN_KPI]; stored shares = the seed shares at 6 dp.
-- -----------------------------------------------------------------------------
WITH dash AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'summary', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_SUMMARY,
         SUM(BUDGET) AS BUDGET, SUM(SPEND) AS SPEND, SUM(REVENUE) AS REVENUE, SUM(LEADS) AS LEADS,
         SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(PURCHASES) AS PURCHASES,
         SUM(SPEND_SHARE) AS SPEND_SHARE, SUM(REVENUE_SHARE) AS REVENUE_SHARE
  FROM MART_CHANNEL_PERFORMANCE
  GROUP BY GROUPING SETS ((CHANNEL), ())
),
seed AS (
  SELECT IFF(GROUPING(k.CHANNEL) = 1, 'summary', k.CHANNEL) AS CHANNEL,
         SUM(k.BUDGET) AS BUDGET, SUM(k.LEADS) AS LEADS, SUM(k.CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(k.PURCHASES) AS PURCHASES,
         SUM(k.SPEND) AS SEED_SPEND, SUM(k.REVENUE) AS SEED_REVENUE
  FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI k
  GROUP BY GROUPING SETS ((k.CHANNEL), ())
),
pub AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'summary', CHANNEL) AS CHANNEL, SUM(SPEND) AS SPEND, SUM(ATTRIBUTED_REVENUE) AS REVENUE
  FROM MARKETING_CRM.STAGING.PUBLISHER_CHANNEL_REFERENCE
  GROUP BY GROUPING SETS ((CHANNEL), ())
),
seed_shares AS (            -- shares of the seed's channel totals over all five channels
  SELECT CHANNEL,
         ROUND(SEED_SPEND::NUMBER(32,18) / SUM(SEED_SPEND) OVER (), 6) AS SPEND_SHARE,
         ROUND(SEED_REVENUE::NUMBER(32,18) / SUM(SEED_REVENUE) OVER (), 6) AS REVENUE_SHARE
  FROM seed WHERE CHANNEL <> 'summary'
)
SELECT COALESCE(d.CHANNEL, s.CHANNEL) AS CHANNEL, d.BUDGET, d.SPEND, d.REVENUE,
       ROUND(d.REVENUE::NUMBER(32,18) / NULLIF(d.SPEND, 0), 2)                  AS ROAS,
       ROUND(d.SPEND::NUMBER(32,18) / NULLIF(d.LEADS, 0), 2)                    AS CPL,
       ROUND(d.SPEND::NUMBER(32,18) / NULLIF(d.CONVERTED_LEADS, 0), 2)          AS COST_PER_CONVERSION,
       ROUND(d.SPEND::NUMBER(32,18) / NULLIF(d.PURCHASES, 0), 2)                AS COST_PER_PURCHASE,
       ROUND((d.SPEND * 100)::NUMBER(32,18) / NULLIF(d.BUDGET, 0), 2)           AS UTIL_PCT,
       ROUND(d.SPEND_SHARE * 100, 2)                                            AS SPEND_SHARE_PCT,
       ROUND(d.REVENUE_SHARE * 100, 2)                                          AS REVENUE_SHARE_PCT,
       IFF(d.SPEND = p.SPEND AND d.REVENUE = p.REVENUE AND d.BUDGET = s.BUDGET AND d.LEADS = s.LEADS
           AND d.CONVERTED_LEADS = s.CONVERTED_LEADS AND d.PURCHASES = s.PURCHASES
           AND (d.IS_SUMMARY = 1 OR (d.SPEND_SHARE = h.SPEND_SHARE AND d.REVENUE_SHARE = h.REVENUE_SHARE)), 'yes', 'NO') AS EQUALS_REFERENCES,
       IFF(EQUALS_REFERENCES = 'yes', 'PASS', 'FAIL') AS STATUS
FROM dash d
FULL OUTER JOIN seed s ON s.CHANNEL = d.CHANNEL
LEFT JOIN pub p ON p.CHANNEL = COALESCE(d.CHANNEL, s.CHANNEL)
LEFT JOIN seed_shares h ON h.CHANNEL = COALESCE(d.CHANNEL, s.CHANNEL)
ORDER BY d.IS_SUMMARY, d.REVENUE::NUMBER(32,18) / NULLIF(d.SPEND, 0) DESC;


-- =============================================================================
-- EXTRAS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 17. Campaign drop-down (P1-12, P2-13, P4-10) set to "Affiliate 2024 080" (CMP0080, the top
--     ROAS campaign). The control is on CAMPAIGN_NAME, which only CAMP has (spec D6): the
--     campaign charts of the page (P1-11; P2-14; P4-11, P4-12) show this one campaign, and
--     their summary row equals it; every other component keeps its default value.
--     Expected: [SEED EXPECTED_CAMPAIGN_KPI] row CMP0080 (bases and budget).
-- -----------------------------------------------------------------------------
WITH items (ITEM_NO, COMPONENT, FIELD, KIND, DP) AS (
  SELECT * FROM VALUES
    (1,  'SPEND',                 'CAMP: SUM(SPEND)',                      'money', 2),
    (2,  'LEADS',                 'CAMP: SUM(LEADS)',                      'count', 0),
    (3,  'CONVERTED_LEADS',       'CAMP: SUM(CONVERTED_LEADS)',            'count', 0),
    (4,  'PURCHASES',             'CAMP: SUM(PURCHASES)',                  'count', 0),
    (5,  'REVENUE',               'CAMP: SUM(REVENUE)',                    'money', 2),
    (6,  'BUDGET',                'CAMP: SUM(BUDGET)',                     'money', 2),
    (7,  'Cost per lead',         'CAMP: SUM(SPEND)/SUM(LEADS)',           'num',   4),
    (8,  'Lead conversion rate',  'CAMP: SUM(CONVERTED_LEADS)/SUM(LEADS)', 'pct',   6),
    (9,  'ROAS (attributed)',     'CAMP: SUM(REVENUE)/SUM(SPEND)',         'num',   6),
    (10, 'Cost per purchase',     'CAMP: SUM(SPEND)/SUM(PURCHASES)',       'num',   4),
    (11, 'Budget utilisation',    'CAMP: SUM(SPEND)/SUM(BUDGET)',          'pct',   6)
),
c AS (SELECT * FROM MART_CAMPAIGN_PERFORMANCE WHERE CAMPAIGN_NAME = 'Affiliate 2024 080'),
k AS (SELECT * FROM MARKETING_CRM.STAGING.EXPECTED_CAMPAIGN_KPI WHERE CAMPAIGN_ID = 'CMP0080'),
item_rows AS (
  SELECT i.ITEM_NO, i.COMPONENT, i.FIELD, i.KIND, i.DP, c.CAMPAIGN_ID,
         (CASE i.ITEM_NO WHEN 1 THEN c.SPEND WHEN 2 THEN c.LEADS WHEN 3 THEN c.CONVERTED_LEADS WHEN 4 THEN c.PURCHASES
                         WHEN 5 THEN c.REVENUE WHEN 6 THEN c.BUDGET
                         WHEN 7 THEN c.SPEND::NUMBER(32,18) / c.LEADS WHEN 8 THEN c.CONVERTED_LEADS::NUMBER(32,18) / c.LEADS
                         WHEN 9 THEN c.REVENUE::NUMBER(32,18) / c.SPEND WHEN 10 THEN c.SPEND::NUMBER(32,18) / c.PURCHASES
                         WHEN 11 THEN c.SPEND::NUMBER(32,18) / c.BUDGET END)::NUMBER(38,18) AS V,
         (CASE i.ITEM_NO WHEN 1 THEN k.SPEND WHEN 2 THEN k.LEADS WHEN 3 THEN k.CONVERTED_LEADS WHEN 4 THEN k.PURCHASES
                         WHEN 5 THEN k.REVENUE WHEN 6 THEN k.BUDGET
                         WHEN 7 THEN k.SPEND::NUMBER(32,18) / k.LEADS WHEN 8 THEN k.CONVERTED_LEADS::NUMBER(32,18) / k.LEADS
                         WHEN 9 THEN k.REVENUE::NUMBER(32,18) / k.SPEND WHEN 10 THEN k.SPEND::NUMBER(32,18) / k.PURCHASES
                         WHEN 11 THEN k.SPEND::NUMBER(32,18) / k.BUDGET END)::NUMBER(38,18) AS R
  FROM items i CROSS JOIN c CROSS JOIN k
)
SELECT COMPONENT, FIELD, CAMPAIGN_ID,
       ROUND(V, 6)::NUMBER(38,6) AS VALUE,
       CASE KIND WHEN 'count' THEN TO_VARCHAR(ROUND(V, 0), 'FM999,999,999,990')
                 WHEN 'pct'   THEN TO_VARCHAR(ROUND(V * 100, 2), 'FM999,990.00') || '%'
                 ELSE              TO_VARCHAR(ROUND(V, 2), 'FM999,999,999,990.00') END AS SHOWN,
       ROUND(R, 6)::NUMBER(38,6) AS REFERENCE, 'SEED EXPECTED_CAMPAIGN_KPI CMP0080' AS REF_SOURCE,
       IFF(KIND <> 'count' AND ABS(MOD(ABS(V) * IFF(KIND = 'pct', 10000, 100), 1) - 0.5) < 0.000000001, 'yes', '') AS NEAR_HALF,
       IFF(COALESCE(CASE DP WHEN 0 THEN ROUND(V, 0) = ROUND(R, 0) WHEN 2 THEN ROUND(V, 2) = ROUND(R, 2)
                            WHEN 4 THEN ROUND(V, 4) = ROUND(R, 4) ELSE ROUND(V, 6) = ROUND(R, 6) END, FALSE),
           'PASS', 'FAIL') AS STATUS
FROM item_rows
ORDER BY ITEM_NO;


-- -----------------------------------------------------------------------------
-- 18. Display rounding guard over the chart and table cells of blocks 3-16 (the cards carry
--     their own NEAR_HALF column). Data Studio rounds binary floating point; this file rounds
--     exact decimals half away from zero. The two can differ in the last shown digit only when
--     the exact value sits on a midpoint (x.xx5 for 2 dp; a percent of x.xx5% for Percent
--     fields): the nearest binary double of such a value is often just below it, so Data
--     Studio may then show the last digit 1 lower. Each family counts the cells checked ([C] by
--     construction) and the cells within 1e-9 of a midpoint. STATUS is PASS for 0 and NOTE
--     (not a failure) otherwise, listing the cells; dashboard_validation.md accepts either
--     rounding for them.
-- -----------------------------------------------------------------------------
WITH cells (FAMILY, ITEM, V, SCALE) AS (
  -- campaign charts (block 5): every campaign, the ratios shown (2 dp; percent 2 dp)
  SELECT 'campaign: CPL, ROAS, CPP (2 dp)', CAMPAIGN_ID || ' CPL', SPEND::NUMBER(32,18) / LEADS, 100 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'campaign: CPL, ROAS, CPP (2 dp)', CAMPAIGN_ID || ' ROAS', REVENUE::NUMBER(32,18) / SPEND, 100 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'campaign: CPL, ROAS, CPP (2 dp)', CAMPAIGN_ID || ' CPP', SPEND::NUMBER(32,18) / PURCHASES, 100 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'campaign: LCR, utilisation (%)', CAMPAIGN_ID || ' LCR', CONVERTED_LEADS::NUMBER(32,18) / LEADS, 10000 FROM MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'campaign: LCR, utilisation (%)', CAMPAIGN_ID || ' UTIL', SPEND::NUMBER(32,18) / BUDGET, 10000 FROM MART_CAMPAIGN_PERFORMANCE
  -- channel charts on CH (blocks 8, 16): per channel
  UNION ALL SELECT 'CH channel: money ratios (2 dp)', CHANNEL || ' ROAS', REVENUE::NUMBER(32,18) / SPEND, 100 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: money ratios (2 dp)', CHANNEL || ' CPL', SPEND::NUMBER(32,18) / LEADS, 100 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: money ratios (2 dp)', CHANNEL || ' CPConv', SPEND::NUMBER(32,18) / CONVERTED_LEADS, 100 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: money ratios (2 dp)', CHANNEL || ' CPP', SPEND::NUMBER(32,18) / PURCHASES, 100 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: percents', CHANNEL || ' CTR', CLICKS::NUMBER(32,18) / IMPRESSIONS, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: percents', CHANNEL || ' CTL', LEADS::NUMBER(32,18) / CLICKS, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: percents', CHANNEL || ' LCR', CONVERTED_LEADS::NUMBER(32,18) / LEADS, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: percents', CHANNEL || ' UTIL', SPEND::NUMBER(32,18) / BUDGET, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: stored percents', CHANNEL || ' CI_LOW', LCR_CI_LOW, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: stored percents', CHANNEL || ' CI_HIGH', LCR_CI_HIGH, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: stored percents', CHANNEL || ' SPEND_SH', SPEND_SHARE, 10000 FROM MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'CH channel: stored percents', CHANNEL || ' REV_SH', REVENUE_SHARE, 10000 FROM MART_CHANNEL_PERFORMANCE
  -- channel charts on LQ (block 14)
  UNION ALL SELECT 'LQ channel: score, days (2 dp)', CHANNEL || ' SCORE', SUM(SUM_LEAD_SCORE)::NUMBER(32,18) / SUM(LEADS), 100
            FROM MART_LEAD_QUALITY GROUP BY CHANNEL
  UNION ALL SELECT 'LQ channel: score, days (2 dp)', CHANNEL || ' DAYS', SUM(SUM_DAYS_TO_CONVERT)::NUMBER(32,18) / SUM(CONVERTED_LEADS), 100
            FROM MART_LEAD_QUALITY GROUP BY CHANNEL
  UNION ALL SELECT 'LQ channel: percents', CHANNEL || ' PRATE', SUM(PURCHASES)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_LEAD_QUALITY GROUP BY CHANNEL
  UNION ALL SELECT 'LQ channel: percents', CHANNEL || ' ' || LEAD_SCORE_SEGMENT,
            SUM(LEADS)::NUMBER(32,18) / SUM(SUM(LEADS)) OVER (PARTITION BY CHANNEL), 10000
            FROM MART_LEAD_QUALITY GROUP BY CHANNEL, LEAD_SCORE_SEGMENT
  -- monthly cohort rate (block 9): all channels and video (NULL for a month without leads)
  UNION ALL SELECT 'cohort month: LCR (%)', TO_VARCHAR(COHORT_MONTH, 'YYYY-MM') || ' all', SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_MONTHLY_COHORT GROUP BY COHORT_MONTH
  UNION ALL SELECT 'cohort month: LCR (%)', TO_VARCHAR(COHORT_MONTH, 'YYYY-MM') || ' video', CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0), 10000
            FROM MART_MONTHLY_COHORT WHERE CHANNEL = 'video'
  -- score segments and bands (blocks 12-13): all channels and video
  UNION ALL SELECT 'score: segment and band (%)', LEAD_SCORE_SEGMENT || ' LCR', SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL SELECT 'score: segment and band (%)', LEAD_SCORE_SEGMENT || ' PRATE', SUM(PURCHASES)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL SELECT 'score: segment and band (%)', LEAD_SCORE_SEGMENT || ' SHARE', SUM(LEADS)::NUMBER(32,18) / SUM(SUM(LEADS)) OVER (), 10000
            FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL SELECT 'score: segment and band (%)', LEAD_SCORE_SEGMENT || ' video', SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_LEAD_QUALITY WHERE CHANNEL = 'video' GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL SELECT 'score: segment and band (%)', SCORE_BAND || ' all', SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS), 10000
            FROM MART_LEAD_QUALITY GROUP BY SCORE_BAND
  UNION ALL SELECT 'score: segment and band (%)', SCORE_BAND || ' video', CONVERTED_LEADS::NUMBER(32,18) / LEADS, 10000
            FROM MART_LEAD_QUALITY WHERE CHANNEL = 'video'
  UNION ALL SELECT 'score: segment score, days (2 dp)', LEAD_SCORE_SEGMENT || ' SCORE', SUM(SUM_LEAD_SCORE)::NUMBER(32,18) / SUM(LEADS), 100
            FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  UNION ALL SELECT 'score: segment score, days (2 dp)', LEAD_SCORE_SEGMENT || ' DAYS', SUM(SUM_DAYS_TO_CONVERT)::NUMBER(32,18) / SUM(CONVERTED_LEADS), 100
            FROM MART_LEAD_QUALITY GROUP BY LEAD_SCORE_SEGMENT
  -- funnel labels and stage table (block 7): % of previous and % of impressions, all channels and video
  UNION ALL SELECT 'funnel: percents', STAGE || ' prev', SUM(STAGE_VALUE)::NUMBER(32,18) / SUM(PREV_STAGE_VALUE), 10000
            FROM MART_CONVERSION_FUNNEL WHERE STAGE_ORDER > 1 GROUP BY STAGE
  UNION ALL SELECT 'funnel: percents', STAGE || ' top', SUM(STAGE_VALUE)::NUMBER(32,18) / SUM(TOP_OF_FUNNEL_VALUE), 10000
            FROM MART_CONVERSION_FUNNEL GROUP BY STAGE
  UNION ALL SELECT 'funnel: percents', STAGE || ' video prev', STAGE_VALUE::NUMBER(32,18) / PREV_STAGE_VALUE, 10000
            FROM MART_CONVERSION_FUNNEL WHERE CHANNEL = 'video' AND STAGE_ORDER > 1
),
expected (FAMILY, EXPECTED_CELLS) AS (     -- [C] cells per family
  SELECT * FROM VALUES
    ('campaign: CPL, ROAS, CPP (2 dp)', 360), ('campaign: LCR, utilisation (%)', 240),
    ('CH channel: money ratios (2 dp)', 20), ('CH channel: percents', 20), ('CH channel: stored percents', 20),
    ('LQ channel: score, days (2 dp)', 10), ('LQ channel: percents', 20), ('cohort month: LCR (%)', 72),
    ('score: segment and band (%)', 32), ('score: segment score, days (2 dp)', 6), ('funnel: percents', 13)
),
flagged AS (
  SELECT FAMILY, COUNT(*) AS CELLS,
         COUNT_IF(ABS(MOD(ABS(V) * SCALE, 1) - 0.5) < 0.000000001) AS NEAR_MIDPOINT,
         LISTAGG(IFF(ABS(MOD(ABS(V) * SCALE, 1) - 0.5) < 0.000000001, ITEM, NULL), '; ') AS MIDPOINT_CELLS
  FROM cells GROUP BY FAMILY
)
SELECT e.FAMILY, f.CELLS, e.EXPECTED_CELLS, f.NEAR_MIDPOINT, COALESCE(f.MIDPOINT_CELLS, '') AS MIDPOINT_CELLS,
       IFF(f.CELLS = e.EXPECTED_CELLS, IFF(f.NEAR_MIDPOINT = 0, 'PASS', 'NOTE'), 'FAIL') AS STATUS
FROM expected e
LEFT JOIN flagged f ON f.FAMILY = e.FAMILY
ORDER BY e.FAMILY;
