-- =============================================================================
-- Phase 4 / 03: Marketing Overview (dashboard page 1) and analyses #1, #2, #10
-- -----------------------------------------------------------------------------
-- Purpose
--   The read-only analysis SQL behind page 1 of the dashboard, "Marketing Overview", and
--   three of the plan's ten analyses, each showing the SQL technique the plan names for it:
--     scorecards                        one row per fact, CROSS JOIN of 1-row aggregates, UNPIVOT    block 1
--     #1  Monthly Marketing Performance DATE_TRUNC + GROUP BY, each fact on its own date column      block 2
--     #2  Channel Performance Analysis  one CTE per fact, 1:1 JOINs, RANK, shares with SUM() OVER () blocks 3-4
--     #10 Monthly Trend & Growth        LAG(1) / LAG(12), AVG over a 3-row frame, running SUM,
--                                       LAG within a PARTITION BY, a growth decomposition            blocks 5-8
--     campaign table                    ROW_NUMBER, RANK ... PARTITION BY, running share             blocks 9-10
--   Business question answered here: 1, "Which marketing channels generate the most leads?"
--   (block 3; per unit of spend too; year by year in block 4). Questions 2-7 are answered in
--   04_conversion_funnel.sql, 05_lead_analysis.sql and 06_marketing_efficiency.sql.
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02c_analysis_marts.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/03_marketing_overview.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 15 statements,
--   seconds on the X-Small MARKETING_WH. Output of the last run: docs/evidence/03_overview.txt.
-- Role
--   CRM_TRANSFORMER (reads MART). Every table read here is in MART, so CRM_REPORTER, the
--   dashboard's role, can run the same queries.
-- Inputs
--   MARKETING_CRM.MART: DIM_DATE, DIM_CAMPAIGN, FCT_DAILY_SPEND, FCT_LEAD_CONVERSIONS,
--   MART_CAMPAIGN_PERFORMANCE (Phase 3, sql/02b_core_models.sql); FCT_CAMPAIGN_DAILY_ACTIVITY,
--   MART_MONTHLY_MARKETING, MART_CHANNEL_PERFORMANCE (Phase 4, sql/02c_analysis_marts.sql).
-- Guard rails (the user plan; numbered as in 02c_analysis_marts.sql) and where they show
--   G1 Grain. A fact is never joined row by row to a fact of another grain: the naive
--      daily_spend x leads join on CAMPAIGN_ID inflates spend 2,495x (4.52 M -> 11.3 B,
--      docs/data_profile.md "The grain trap"). Blocks 1-3 aggregate every fact to the target
--      grain in its own CTE and only then join (1:1, or a CROSS JOIN of 1-row results).
--   G2 The funnel impressions -> clicks -> leads -> converted leads is an AGGREGATE campaign
--      funnel of different units (block 1). It is not one person's journey, and TRIALS and
--      PURCHASES are parallel outcomes: no query here follows a trial to a purchase.
--   G3 Activity basis only. Every time series here counts spend by spend date, leads by
--      created date and conversions by converted date (what happened in the month or year).
--      None of them divides conversions by the leads of the same period: that ratio is not a
--      conversion rate (8.3% to 93.8% by month). Lead-cohort rates are in 04_conversion_funnel.sql.
--   G4 ROAS = last-touch attributed revenue / spend (blocks 1 and 9): attribution, not the
--      causal return of the spend.
--   G5 Lead score: not used on this page (05_lead_analysis.sql; association only).
--   G6 Synthetic data. Regular patterns (e.g. near-round CPMs per channel, leads that track
--      spend with a correlation of 0.97) are properties of the generator, not market facts.
--   G7 Volume follows the number of running campaigns. 22 campaigns started in 2025 against
--      50 in 2024, so ACTIVE_CAMPAIGNS stands next to every month (blocks 2 and 5), and blocks
--      7-8 split each year's change into volume (campaign-days), intensity (spend per
--      campaign-day) and efficiency (leads per unit of spend).
-- Reading the results
--   Every analysis query carries its own reconciliation, so the numbers a reader quotes are
--   the numbers that were checked:
--     - STATUS = PASS means the row reproduced its expected value exactly, and, where a
--       dashboard table holds the same figure, that the analysis path and the dashboard table
--       agree (EQUALS_DASHBOARD_MART). No tolerance anywhere.
--     - Comparisons with an expected list are FULL OUTER JOINs: a missing or an extra month,
--       channel or KPI is its own FAIL row.
--     - No tautologies: expected values never come from the query under test or from the
--       tables it reads; they come from the sources below. EQUALS_DASHBOARD_MART is an extra,
--       weaker check, that the table a dashboard page reads shows the same figure as the
--       analysis query. In block 2 it is an independent path (MART_MONTHLY_MARKETING is built
--       from the daily activity spine, block 2 truncates the Phase 3 facts' own dates); in
--       blocks 1 and 3 MART_CHANNEL_PERFORMANCE aggregates the same Phase 3 facts, so there it
--       is a consistency check only.
--     - Ratios: every dividend is cast to NUMBER(32,18) before dividing, so ROUND to the
--       printed scale is the only rounding (no double rounding). Rates, ROAS and shares 6 dp,
--       cost per unit and leads per 1,000 spend 4 dp, growth rates 4 dp as a fraction
--       (0.1208 = +12.08%), per-campaign averages 2 dp.
--   (Totals of mixed measures share one NUMBER column, so counts print as e.g. 120.000000.)
-- Where the expected values come from (never from the query under test)
--   [P3]   The local pre-load KPI profile (2026-10-13, DuckDB and Python Decimal, before any
--          Snowflake object existed), carried inline by the 02b and 02c tests:
--          kpi_channel_bases, kpi_channel_ratios (incl. the TOTAL row), the 36 rows of
--          monthly_activity_vs_cohort, campaign_top10_roas / campaign_bottom10_roas.
--   [PUB]  The publisher's reference output: spend and attributed revenue by channel and in total.
--   [E01]  docs/evidence/01_data_profiling.txt (statement in brackets): [22] rows per year of
--          spend_date, created_at, converted_at; [27] campaigns started and active per year;
--          [28] campaigns active per month.
--   [D]    Python 3 csv + decimal (ROUND_HALF_UP, 60-digit precision), 2026-10-14, outside
--          Snowflake, from data/raw/source/campaigns.csv, daily_spend.csv, leads.csv and
--          conversions.csv: monthly impressions, clicks and purchases; CPC and leads per 1,000
--          spend; the channel shares, ranks, cumulative leads and spend shares and leads per
--          1,000 spend; the 15 year x channel rows; the window-function spot values (MoM, YoY,
--          3-month average, running spend), the 2025 month counts, the direction agreement of
--          leads and active campaigns YoY and CORR over the 36 months and over the 31 months
--          with at least 10 active campaigns; yearly campaign-days and growth factors; the
--          channel-mix CPLs in both orders; the campaign-table extremes.
--   [C]    By construction from a fact stated elsewhere: 36 gap-free months (DIM_DATE,
--          2023-01-01..2025-12-31) give 35 rows with a previous month, 24 with the same month a
--          year before (24 YoY values) and 34 with a full 3-month frame; 24 campaigns per
--          channel [P3] with no two CPLs tied at 4 dp [D] give CPL ranks exactly 1..24.
-- What a reader MAY conclude (each number is printed and checked by the block named)
--   - Over 2023-2025, 4,523,050.02 was spent, and 261,684 leads are attributed (last touch) to
--     the campaigns, 17.2844 of spend per attributed lead; 39,696 of them converted
--     (15.1694%) with 21,561,839.01 of attributed revenue (block 1).
--   - Business question 1: affiliate generates the most (last-touch attributed) leads, 67,849
--     (25.93%), ahead of paid_search 65,268 and paid_social 57,619; video the fewest, 25,799.
--     Per 1,000 of spend the order is the same: affiliate 79.09 leads, video 31.15 (block 3).
--     The per-spend order is identical in 2023, 2024 and 2025; the volume order is not (block 4).
--   - Monthly leads move with the number of running campaigns (CORR 0.9403 over 36 months,
--     0.8734 without the 5 months with fewer than 10 campaigns), and most of the 2025 fall in
--     leads (-37.82%) is fewer campaign-days (-32.19%) (blocks 5-8).
-- What a reader may NOT conclude
--   - That more spend on affiliate would buy leads at 79.09 per 1,000: these are averages over
--     the campaigns that ran, not marginal returns, and the data is synthetic.
--   - That the channel with the most leads is the best channel: lead volume is not lead value
--     (conversion, revenue and ROAS by channel are questions 2 and 6).
--   - That 2025 simply "performed worse" or "better": volume fell with the portfolio, and the
--     per-unit answer depends on the denominator: leads per unit of spend +12.08% (partly
--     channel mix), leads per campaign-day -8.30% (block 8). Nor that anything caused the
--     change: the data records what ran, not why.
--   - A conversion rate by month from these tables (G3).
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where   [6] 1 scorecards   [7] 2 #1 monthly performance
--   [8] 3 #2 channels and business question 1   [9] 4 #2 channels by year
--   [10] 5 #10 monthly trend   [11] 6 #10 window checks   [12] 7 #10 yearly comparison
--   [13] 8 #10 volume, intensity, efficiency   [14] 9 campaign table   [15] 10 campaign table checks
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
-- 1. Scorecards: the whole program in 19 numbers, reconciled to the known totals
--    BUSINESS QUESTION: how large was the marketing program over 2023-2025, and what does its
--      aggregate funnel look like? (The KPI cards at the top of the Marketing Overview page.)
--    METHOD: each fact is aggregated to ONE row on its own (DIM_CAMPAIGN, FCT_DAILY_SPEND,
--      FCT_LEAD_CONVERSIONS), then the 1-row results are CROSS JOINed: 1 x 1 x 1 rows cannot
--      fan out (G1). The same bases are summed a second way from MART_CHANNEL_PERFORMANCE,
--      the table the Data Studio scorecards read. Ratios are ratios of the sums, never
--      averages of campaign ratios. UNPIVOT turns each path's scorecard row into one row per
--      KPI, and conditional aggregation puts the two paths side by side.
--    HOW TO READ: KPI_VALUE (facts) and DASHBOARD_MART (mart) must both equal EXPECTED.
--      4,523,050.02 of spend delivered 436,844,819 impressions and 7,102,319 clicks (CTR
--      1.6258%). 261,684 leads are attributed (last touch) to the campaigns: a count equal to
--      3.6845% of the clicks, 17.2844 of spend per attributed lead, 57.8557 per 1,000 of spend.
--      39,696 leads converted (15.1694%): 23,005 to a trial and 16,691 to a purchase, with
--      21,561,839.01 of attributed revenue (ROAS 4.767102). 83.4720% of the 5,418,642.16
--      budget was spent.
--    CAVEATS: the four funnel counts are different units (impressions, clicks, people who left
--      their details, leads that converted): CLICK_TO_LEAD_RATE is a ratio of two aggregates,
--      not the probability that a person who clicked became a lead (G2). Each lead converts at
--      most once, so TRIALS + PURCHASES = CONVERTED_LEADS; trial -> purchase cannot be
--      followed. LEAD_CONVERSION_RATE is valid here because the range is complete (every lead
--      and its conversion are inside it); for one month it needs the cohort basis (G3). ROAS is
--      last-touch attributed revenue / spend, not the causal return (G4).
--    Expected: bases [P3 kpi_channel_bases TOTAL; PUB for spend and revenue]; rates, CPL, ROAS and
--      utilisation [P3 kpi_channel_ratios TOTAL]; CPC and leads per 1,000 spend [D].
-- -----------------------------------------------------------------------------
WITH bases AS (             -- the same bases by two paths (the facts; the dashboard's channel table), one row each
  SELECT 'facts' AS SOURCE, c.CAMPAIGNS, c.BUDGET, d.SPEND, d.IMPRESSIONS, d.CLICKS,
         o.LEADS, o.CONVERTED_LEADS, o.TRIALS, o.PURCHASES, o.REVENUE
  FROM       (SELECT COUNT(*) AS CAMPAIGNS, SUM(BUDGET) AS BUDGET
              FROM DIM_CAMPAIGN) c                                            -- campaign       -> 1 row
  CROSS JOIN (SELECT SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS
              FROM FCT_DAILY_SPEND) d                                         -- campaign x day -> 1 row
  CROSS JOIN (SELECT COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS, SUM(IS_TRIAL) AS TRIALS,
                     SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE
              FROM FCT_LEAD_CONVERSIONS) o                                    -- lead           -> 1 row
  UNION ALL
  SELECT 'dashboard mart', SUM(CAMPAIGNS), SUM(BUDGET), SUM(SPEND), SUM(IMPRESSIONS), SUM(CLICKS),
         SUM(LEADS), SUM(CONVERTED_LEADS), SUM(TRIALS), SUM(PURCHASES), SUM(REVENUE)
  FROM MART_CHANNEL_PERFORMANCE                                               -- 5 channels     -> 1 row
),
scorecards AS (             -- one scorecard row per path: bases, then ratios of the sums (one type for UNPIVOT)
  SELECT SOURCE,
         CAMPAIGNS::NUMBER(38,6)       AS CAMPAIGNS,       BUDGET::NUMBER(38,6)          AS BUDGET,
         SPEND::NUMBER(38,6)           AS SPEND,           IMPRESSIONS::NUMBER(38,6)     AS IMPRESSIONS,
         CLICKS::NUMBER(38,6)          AS CLICKS,          LEADS::NUMBER(38,6)           AS LEADS,
         CONVERTED_LEADS::NUMBER(38,6) AS CONVERTED_LEADS, TRIALS::NUMBER(38,6)          AS TRIALS,
         PURCHASES::NUMBER(38,6)       AS PURCHASES,       REVENUE::NUMBER(38,6)         AS REVENUE,
         ROUND(CLICKS::NUMBER(32,18)          / NULLIF(IMPRESSIONS, 0), 6)::NUMBER(38,6) AS CTR,
         ROUND(SPEND::NUMBER(32,18)           / NULLIF(CLICKS, 0), 4)::NUMBER(38,6)      AS CPC,
         ROUND(LEADS::NUMBER(32,18)           / NULLIF(CLICKS, 0), 6)::NUMBER(38,6)      AS CLICK_TO_LEAD_RATE,
         ROUND(CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0), 6)::NUMBER(38,6)       AS LEAD_CONVERSION_RATE,
         ROUND(PURCHASES::NUMBER(32,18)       / NULLIF(LEADS, 0), 6)::NUMBER(38,6)       AS PURCHASE_RATE,
         ROUND(SPEND::NUMBER(32,18)           / NULLIF(LEADS, 0), 4)::NUMBER(38,6)       AS COST_PER_LEAD,
         ROUND((LEADS * 1000)::NUMBER(32,18)  / NULLIF(SPEND, 0), 4)::NUMBER(38,6)       AS LEADS_PER_1000_SPEND,
         ROUND(REVENUE::NUMBER(32,18)         / NULLIF(SPEND, 0), 6)::NUMBER(38,6)       AS ROAS,
         ROUND(SPEND::NUMBER(32,18)           / NULLIF(BUDGET, 0), 6)::NUMBER(38,6)      AS BUDGET_UTILIZATION
  FROM bases
),
by_kpi AS (                 -- UNPIVOT: one row per path x KPI; then one column per path
  SELECT KPI,
         MAX(IFF(SOURCE = 'facts', KPI_VALUE, NULL))          AS KPI_VALUE,
         MAX(IFF(SOURCE = 'dashboard mart', KPI_VALUE, NULL)) AS DASHBOARD_MART
  FROM scorecards
  UNPIVOT (KPI_VALUE FOR KPI IN (CAMPAIGNS, BUDGET, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, TRIALS,
                                 PURCHASES, REVENUE, CTR, CPC, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE,
                                 PURCHASE_RATE, COST_PER_LEAD, LEADS_PER_1000_SPEND, ROAS, BUDGET_UTILIZATION))
  GROUP BY KPI
),
expected (ORD, KPI, DEFINITION, EXPECTED) AS (   -- [P3] bases and ratios (TOTAL rows); [PUB] spend, revenue; [D] CPC, leads/1,000
  SELECT * FROM VALUES
    ( 1, 'CAMPAIGNS',            'campaigns run',                            120),
    ( 2, 'BUDGET',               'sum of whole-campaign budgets',            5418642.16),
    ( 3, 'SPEND',                'media spend',                              4523050.02),
    ( 4, 'IMPRESSIONS',          'ad impressions',                           436844819),
    ( 5, 'CLICKS',               'ad clicks',                                7102319),
    ( 6, 'LEADS',                'leads created',                            261684),
    ( 7, 'CONVERTED_LEADS',      'leads converted (trial or purchase)',      39696),
    ( 8, 'TRIALS',               'leads converted to a trial',               23005),
    ( 9, 'PURCHASES',            'leads converted to a purchase',            16691),
    (10, 'REVENUE',              'last-touch attributed revenue',            21561839.01),
    (11, 'CTR',                  'CLICKS / IMPRESSIONS',                     0.016258),
    (12, 'CPC',                  'SPEND / CLICKS',                           0.6368),
    (13, 'CLICK_TO_LEAD_RATE',   'LEADS / CLICKS (aggregate units)',         0.036845),
    (14, 'LEAD_CONVERSION_RATE', 'CONVERTED_LEADS / LEADS',                  0.151694),
    (15, 'PURCHASE_RATE',        'PURCHASES / LEADS',                        0.063783),
    (16, 'COST_PER_LEAD',        'SPEND / LEADS',                            17.2844),
    (17, 'LEADS_PER_1000_SPEND', 'LEADS x 1000 / SPEND',                     57.8557),
    (18, 'ROAS',                 'REVENUE / SPEND (attributed)',             4.767102),
    (19, 'BUDGET_UTILIZATION',   'SPEND / BUDGET (whole campaigns)',         0.834720)
)
SELECT COALESCE(e.KPI, k.KPI) AS KPI, e.DEFINITION, k.KPI_VALUE, k.DASHBOARD_MART, e.EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(k.KPI_VALUE = e.EXPECTED AND k.DASHBOARD_MART = e.EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM by_kpi k
FULL OUTER JOIN expected e ON e.KPI = k.KPI
ORDER BY e.ORD NULLS LAST;


-- -----------------------------------------------------------------------------
-- 2. Analysis #1, Monthly Marketing Performance: 36 months, activity basis
--    BUSINESS QUESTION: how much did we spend and deliver each month, how many leads and
--      conversions did each month bring, and how many campaigns were running?
--    METHOD: DATE_TRUNC('month', <date>) + GROUP BY, each fact on ITS OWN date column and in
--      its own CTE: spend, impressions and clicks by SPEND_DATE; leads by CREATED_DATE;
--      conversions, purchases and revenue by CONVERTED_DATE (G3, activity basis). Each monthly
--      CTE is LEFT JOINed 1:1 onto a 36-month spine from DIM_DATE, so a month without activity
--      would show 0 instead of disappearing. ACTIVE_CAMPAIGNS comes from a range join of two
--      dimensions: the campaigns whose START_DATE..END_DATE window overlaps the month. The
--      same 36 months are then read from MART_MONTHLY_MARKETING, the dashboard's monthly table
--      (built from the daily activity spine, 02c), and both must equal the baseline.
--    HOW TO READ: one row per calendar month. Spend peaks in 2024-10 (219,378.73), leads in
--      2024-09 (11,825), the month with the most campaigns in flight (20). The ends of the
--      range are thin because few campaigns ran: 3 in 2023-01, and 11 / 5 / 3 / 1 in
--      2025-09..2025-12 (2025-12: one campaign, 807.04 of spend). CTR, CPC and CPL are
--      ratios of the month's sums; CPL stays between 14.3447 (2025-03) and 21.7941 (2024-06)
--      except in 2025-12 (12.4160 on 65 leads of a single campaign).
--    CAVEATS: CONVERSIONS and REVENUE are booked in the month they happened, partly for leads of
--      earlier months (2025-12 books 61 conversions on 65 new leads), so CONVERSIONS / LEADS of
--      a row is NOT a conversion rate (G3; cohort rates: 04). Read volumes next to
--      ACTIVE_CAMPAIGNS (G7). A campaign active for one day counts like one active all month.
--    Expected: ACTIVE_CAMPAIGNS [E01 28]; SPEND, LEADS, CONVERSIONS, REVENUE [P3
--      monthly_activity_vs_cohort]; IMPRESSIONS, CLICKS, PURCHASES [D]. STATUS needs the
--      DATE_TRUNC path to equal the baseline AND the dashboard table (EQUALS_DASHBOARD_MART).
-- -----------------------------------------------------------------------------
WITH months AS (            -- the spine: DIM_DATE is gap-free 2023-01-01..2025-12-31 -> 36 months
  SELECT DISTINCT MONTH_START FROM DIM_DATE
),
active_by_month AS (        -- campaign windows overlapping the month (dimension x dimension range join)
  SELECT m.MONTH_START, COUNT(c.CAMPAIGN_ID) AS ACTIVE_CAMPAIGNS
  FROM months m
  LEFT JOIN DIM_CAMPAIGN c
         ON c.START_DATE <= LAST_DAY(m.MONTH_START) AND c.END_DATE >= m.MONTH_START
  GROUP BY m.MONTH_START
),
delivery_by_month AS (      -- campaign x day -> spend month
  SELECT DATE_TRUNC('month', SPEND_DATE) AS MONTH_START,
         SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS
  FROM FCT_DAILY_SPEND
  GROUP BY DATE_TRUNC('month', SPEND_DATE)
),
leads_by_month AS (         -- lead -> month the lead was created
  SELECT DATE_TRUNC('month', CREATED_DATE) AS MONTH_START, COUNT(*) AS LEADS
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY DATE_TRUNC('month', CREATED_DATE)
),
conversions_by_month AS (   -- converted lead -> month the conversion happened
  SELECT DATE_TRUNC('month', CONVERTED_DATE) AS MONTH_START,
         COUNT(*) AS CONVERSIONS, SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
  GROUP BY DATE_TRUNC('month', CONVERTED_DATE)
),
monthly AS (                -- every input 1:1 on the month; COALESCE: an empty month is 0, not missing
  SELECT m.MONTH_START, a.ACTIVE_CAMPAIGNS,
         COALESCE(d.SPEND, 0)       AS SPEND,       COALESCE(d.IMPRESSIONS, 0) AS IMPRESSIONS,
         COALESCE(d.CLICKS, 0)      AS CLICKS,      COALESCE(l.LEADS, 0)       AS LEADS,
         COALESCE(v.CONVERSIONS, 0) AS CONVERSIONS, COALESCE(v.PURCHASES, 0)   AS PURCHASES,
         COALESCE(v.REVENUE, 0)     AS REVENUE
  FROM months m
  JOIN      active_by_month      a ON a.MONTH_START = m.MONTH_START
  LEFT JOIN delivery_by_month    d ON d.MONTH_START = m.MONTH_START
  LEFT JOIN leads_by_month       l ON l.MONTH_START = m.MONTH_START
  LEFT JOIN conversions_by_month v ON v.MONTH_START = m.MONTH_START
),
dashboard AS (              -- the dashboard table (channel x month) rolled up to the month
  SELECT MONTH_START, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS,   -- valid within a month: a campaign has one channel
         SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS,
         SUM(CONVERSIONS) AS CONVERSIONS, SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM MART_MONTHLY_MARKETING
  GROUP BY MONTH_START
),
expected (MONTH_START, ACTIVE_CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT * FROM VALUES     -- [E01 28] active; [P3] spend, leads, conversions, revenue; [D] impressions, clicks, purchases
    ('2023-01-01'::DATE,  3,   23686.55,   3236794,  26846,  1325,  110,  48,   52800.58),
    ('2023-02-01'::DATE,  5,   49461.61,   4866080,  73735,  2825,  325, 138,  170806.55),
    ('2023-03-01'::DATE, 10,  104283.65,   9813887, 175460,  6229,  798, 319,  393351.94),
    ('2023-04-01'::DATE, 11,  104393.90,   9572073, 161209,  5748,  902, 390,  474970.42),
    ('2023-05-01'::DATE, 14,   97734.10,  10047414, 120442,  5188,  811, 340,  435288.12),
    ('2023-06-01'::DATE, 18,  123064.68,  12269872, 155305,  7491,  963, 416,  569578.22),
    ('2023-07-01'::DATE, 16,  116810.98,  10016789, 164873,  7779, 1273, 541,  699206.04),
    ('2023-08-01'::DATE, 18,  134065.09,  11592470, 199287,  9024, 1221, 523,  672633.67),
    ('2023-09-01'::DATE, 18,  155294.61,  15617704, 258284, 10771, 1590, 677,  884815.77),
    ('2023-10-01'::DATE, 19,  171832.62,  17486983, 279402, 10930, 1654, 716,  939852.38),
    ('2023-11-01'::DATE, 16,  191171.25,  20749569, 305434, 10526, 1582, 697,  904954.17),
    ('2023-12-01'::DATE, 17,  186463.37,  19437016, 306843,  9713, 1550, 661,  877224.49),
    ('2024-01-01'::DATE, 12,  122943.61,  13104007, 165184,  6493, 1158, 485,  618809.35),
    ('2024-02-01'::DATE, 11,  100601.92,  10406404, 141705,  5638,  794, 350,  441376.15),
    ('2024-03-01'::DATE, 16,  130497.60,  11125570, 220466,  7576, 1063, 446,  568388.08),
    ('2024-04-01'::DATE, 19,  196892.88,  14608167, 294204, 10413, 1424, 635,  795905.02),
    ('2024-05-01'::DATE, 17,  177398.24,  13236736, 231211,  8898, 1550, 629,  813289.19),
    ('2024-06-01'::DATE, 13,  129762.16,  11178475, 134643,  5954, 1035, 445,  581296.94),
    ('2024-07-01'::DATE, 13,  115762.43,  10712011, 144079,  5895,  861, 365,  468529.67),
    ('2024-08-01'::DATE, 18,  185052.08,  16908939, 346907, 10718, 1316, 537,  687143.69),
    ('2024-09-01'::DATE, 20,  205363.34,  17869193, 402727, 11825, 1780, 738,  950923.18),
    ('2024-10-01'::DATE, 18,  219378.73,  19061854, 376815, 11683, 1830, 749,  961348.25),
    ('2024-11-01'::DATE, 19,  181790.58,  16211254, 284218, 10557, 1579, 655,  857423.40),
    ('2024-12-01'::DATE, 18,  205754.77,  20725796, 349890, 11721, 1758, 712,  933214.90),
    ('2025-01-01'::DATE, 16,  189821.49,  19580708, 319963, 10136, 1699, 723,  926132.23),
    ('2025-02-01'::DATE, 13,   97550.77,   9704557, 178946,  6308, 1116, 480,  619062.19),
    ('2025-03-01'::DATE, 12,  103654.48,  11850554, 164981,  7226, 1061, 449,  598344.60),
    ('2025-04-01'::DATE, 13,   95842.28,  10640020, 145638,  6504,  969, 406,  544558.36),
    ('2025-05-01'::DATE, 14,  109131.26,  11261990, 181634,  7506, 1183, 489,  629458.15),
    ('2025-06-01'::DATE, 14,   94604.52,  10184559, 149656,  6371,  971, 380,  515898.62),
    ('2025-07-01'::DATE, 15,  132922.32,  14172264, 221074,  7710, 1101, 462,  601132.60),
    ('2025-08-01'::DATE, 14,  138359.57,  14979140, 236728,  7339, 1190, 476,  596182.42),
    ('2025-09-01'::DATE, 11,   65610.05,   7477070,  89094,  3680,  700, 301,  381379.89),
    ('2025-10-01'::DATE,  5,   48774.54,   5545040,  67223,  2826,  462, 182,  228041.53),
    ('2025-11-01'::DATE,  3,   16510.95,   1520494,  26975,  1093,  256, 109,  137433.25),
    ('2025-12-01'::DATE,  1,     807.04,     73366,   1238,    65,   61,  22,   31085.00)
)
SELECT TO_CHAR(COALESCE(r.MONTH_START, d.MONTH_START, e.MONTH_START), 'YYYY-MM') AS MONTH,
       r.ACTIVE_CAMPAIGNS, r.SPEND, r.IMPRESSIONS, r.CLICKS, r.LEADS, r.CONVERSIONS, r.PURCHASES, r.REVENUE,
       ROUND(r.CLICKS::NUMBER(32,18) / NULLIF(r.IMPRESSIONS, 0), 6) AS CTR,
       ROUND(r.SPEND::NUMBER(32,18)  / NULLIF(r.CLICKS, 0), 4)      AS CPC,
       ROUND(r.SPEND::NUMBER(32,18)  / NULLIF(r.LEADS, 0), 4)       AS CPL,
       IFF(r.ACTIVE_CAMPAIGNS = d.ACTIVE_CAMPAIGNS AND r.SPEND = d.SPEND AND r.IMPRESSIONS = d.IMPRESSIONS
           AND r.CLICKS = d.CLICKS AND r.LEADS = d.LEADS AND r.CONVERSIONS = d.CONVERSIONS
           AND r.PURCHASES = d.PURCHASES AND r.REVENUE = d.REVENUE, 'yes', 'NO') AS EQUALS_DASHBOARD_MART,
       IFF(r.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND r.SPEND = e.SPEND AND r.IMPRESSIONS = e.IMPRESSIONS
           AND r.CLICKS = e.CLICKS AND r.LEADS = e.LEADS AND r.CONVERSIONS = e.CONVERSIONS
           AND r.PURCHASES = e.PURCHASES AND r.REVENUE = e.REVENUE
           AND r.ACTIVE_CAMPAIGNS = d.ACTIVE_CAMPAIGNS AND r.SPEND = d.SPEND AND r.IMPRESSIONS = d.IMPRESSIONS
           AND r.CLICKS = d.CLICKS AND r.LEADS = d.LEADS AND r.CONVERSIONS = d.CONVERSIONS
           AND r.PURCHASES = d.PURCHASES AND r.REVENUE = d.REVENUE, 'PASS', 'FAIL') AS STATUS
FROM monthly r
FULL OUTER JOIN dashboard d ON d.MONTH_START = r.MONTH_START
FULL OUTER JOIN expected  e ON e.MONTH_START = COALESCE(r.MONTH_START, d.MONTH_START)
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 3. Analysis #2, Channel Performance: which channels generate the most leads? (question 1)
--    BUSINESS QUESTION: which marketing channels generate the most leads, in total and per
--      unit of spend?
--    METHOD: the plan's CTE + JOIN pattern. Three CTEs, one per source, each aggregated to one
--      row per channel on its own (campaigns from DIM_CAMPAIGN, spend from FCT_DAILY_SPEND,
--      leads from FCT_LEAD_CONVERSIONS), then JOINed 1:1 on CHANNEL (G1). Window functions
--      over the 5 channel rows add the ranking and the shares: RANK() OVER (ORDER BY ...),
--      x / SUM(x) OVER () for a share of the total, and a running SUM ... ROWS BETWEEN
--      UNBOUNDED PRECEDING AND CURRENT ROW for the cumulative shares of leads and of spend,
--      both in the leads order (a Pareto view). Every share is computed from the unrounded
--      sums, never by adding rounded shares.
--      LEADS_PER_1000_SPEND = LEADS x 1000 / SPEND, the inverse of cost per lead.
--    HOW TO READ (the answer to question 1): affiliate generates the most leads, 67,849 of
--      261,684 (25.9278%), then paid_search 65,268 (24.9415%), paid_social 57,619, display
--      45,149 and video 25,799 (9.8588%). Affiliate and paid_search together account for
--      50.8694% of the leads and 38.7996% of the spend (the two cumulative shares at rank 2).
--      Every channel ran 24 campaigns and spent between 18.31% and 21.77% of the total, so
--      over the full range the ranking does not come from one channel simply running more
--      (affiliate spent the second-least): per 1,000 of spend affiliate has 79.0933 attributed
--      leads, paid_search 72.7551, paid_social 58.5124, display 47.2617 and video 31.1547
--      (overall 57.8557, block 1): the same order, with a 2.5x spread between the first and
--      the last.
--    CAVEATS: a lead is credited to one channel by last-touch attribution, the dataset's only
--      attribution. Leads per 1,000 of spend is an AVERAGE over the campaigns that ran, not
--      what the next 1,000 would buy (no marginal or saturation effect can be estimated from
--      this data). Lead volume is not lead value: conversion rates are within 14.94%-15.35% for
--      all channels (question 2, 04) and revenue per lead differs (question 6, 06). Synthetic
--      data (G6).
--    Expected: CAMPAIGNS, SPEND, LEADS [P3 kpi_channel_bases; PUB for spend]; COST_PER_LEAD [P3
--      kpi_channel_ratios]; shares, ranks, cumulative shares, leads per campaign and per 1,000
--      spend [D]. EQUALS_DASHBOARD_MART compares SPEND, LEADS, both shares and COST_PER_LEAD
--      with MART_CHANNEL_PERFORMANCE.
-- -----------------------------------------------------------------------------
WITH campaigns_by_channel AS (   -- campaign -> channel
  SELECT CHANNEL, COUNT(*) AS CAMPAIGNS
  FROM DIM_CAMPAIGN
  GROUP BY CHANNEL
),
spend_by_channel AS (            -- campaign x day -> channel
  SELECT CHANNEL, SUM(SPEND) AS SPEND
  FROM FCT_DAILY_SPEND
  GROUP BY CHANNEL
),
leads_by_channel AS (            -- lead -> channel
  SELECT CHANNEL, COUNT(*) AS LEADS
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL
),
channels AS (                    -- one row per channel on every side: 1:1 JOINs, no fan-out
  SELECT c.CHANNEL, c.CAMPAIGNS, s.SPEND, l.LEADS
  FROM campaigns_by_channel c
  JOIN spend_by_channel s ON s.CHANNEL = c.CHANNEL
  JOIN leads_by_channel l ON l.CHANNEL = c.CHANNEL
),
ranked AS (                      -- window functions over the 5 channel rows
  SELECT CHANNEL, CAMPAIGNS, SPEND, LEADS,
         ROUND(SPEND::NUMBER(32,18) / SUM(SPEND) OVER (), 6)                  AS SPEND_SHARE,
         ROUND(LEADS::NUMBER(32,18) / SUM(LEADS) OVER (), 6)                  AS LEADS_SHARE,
         RANK() OVER (ORDER BY LEADS DESC)                                    AS LEADS_RANK,
         ROUND((SUM(LEADS) OVER (ORDER BY LEADS DESC, CHANNEL
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))::NUMBER(32,18)
               / SUM(LEADS) OVER (), 6)                                       AS CUMULATIVE_LEADS_SHARE,
         ROUND((SUM(SPEND) OVER (ORDER BY LEADS DESC, CHANNEL               -- same order as the leads share
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))::NUMBER(32,18)
               / SUM(SPEND) OVER (), 6)                                       AS CUMULATIVE_SPEND_SHARE,
         ROUND(LEADS::NUMBER(32,18) / NULLIF(CAMPAIGNS, 0), 2)                AS LEADS_PER_CAMPAIGN,
         ROUND((LEADS * 1000)::NUMBER(32,18) / NULLIF(SPEND, 0), 4)           AS LEADS_PER_1000_SPEND,
         RANK() OVER (ORDER BY LEADS::NUMBER(32,18) / NULLIF(SPEND, 0) DESC)  AS LEADS_PER_SPEND_RANK,
         ROUND(SPEND::NUMBER(32,18) / NULLIF(LEADS, 0), 4)                    AS COST_PER_LEAD
  FROM channels
),
expected (CHANNEL, CAMPAIGNS, SPEND, SPEND_SHARE, LEADS, LEADS_SHARE, LEADS_RANK, CUMULATIVE_LEADS_SHARE,
          CUMULATIVE_SPEND_SHARE, LEADS_PER_CAMPAIGN, LEADS_PER_1000_SPEND, LEADS_PER_SPEND_RANK, COST_PER_LEAD) AS (
  SELECT * FROM VALUES     -- [P3] campaigns, spend, leads, CPL; [D] shares, ranks, cumulative shares, per campaign, per 1,000
    ('affiliate',   24, 857835.07, 0.189659, 67849, 0.259278, 1, 0.259278, 0.189659, 2827.04, 79.0933, 1, 12.6433),
    ('paid_search', 24, 897091.53, 0.198338, 65268, 0.249415, 2, 0.508694, 0.387996, 2719.50, 72.7551, 2, 13.7447),
    ('paid_social', 24, 984731.88, 0.217714, 57619, 0.220185, 3, 0.728879, 0.605710, 2400.79, 58.5124, 3, 17.0904),
    ('display',     24, 955297.00, 0.211206, 45149, 0.172533, 4, 0.901412, 0.816917, 1881.21, 47.2617, 4, 21.1588),
    ('video',       24, 828094.54, 0.183083, 25799, 0.098588, 5, 1.000000, 1.000000, 1074.96, 31.1547, 5, 32.0979)
)
SELECT COALESCE(r.CHANNEL, e.CHANNEL) AS CHANNEL, r.CAMPAIGNS, r.SPEND, r.SPEND_SHARE, r.LEADS, r.LEADS_SHARE,
       r.LEADS_RANK, r.CUMULATIVE_LEADS_SHARE, r.CUMULATIVE_SPEND_SHARE, r.LEADS_PER_CAMPAIGN, r.LEADS_PER_1000_SPEND,
       r.LEADS_PER_SPEND_RANK, r.COST_PER_LEAD,
       IFF(r.SPEND = m.SPEND AND r.LEADS = m.LEADS AND r.SPEND_SHARE = m.SPEND_SHARE AND r.LEADS_SHARE = m.LEADS_SHARE
           AND r.COST_PER_LEAD = m.COST_PER_LEAD, 'yes', 'NO') AS EQUALS_DASHBOARD_MART,
       IFF(r.CAMPAIGNS = e.CAMPAIGNS AND r.SPEND = e.SPEND AND r.SPEND_SHARE = e.SPEND_SHARE AND r.LEADS = e.LEADS
           AND r.LEADS_SHARE = e.LEADS_SHARE AND r.LEADS_RANK = e.LEADS_RANK
           AND r.CUMULATIVE_LEADS_SHARE = e.CUMULATIVE_LEADS_SHARE
           AND r.CUMULATIVE_SPEND_SHARE = e.CUMULATIVE_SPEND_SHARE AND r.LEADS_PER_CAMPAIGN = e.LEADS_PER_CAMPAIGN
           AND r.LEADS_PER_1000_SPEND = e.LEADS_PER_1000_SPEND AND r.LEADS_PER_SPEND_RANK = e.LEADS_PER_SPEND_RANK
           AND r.COST_PER_LEAD = e.COST_PER_LEAD
           AND r.SPEND = m.SPEND AND r.LEADS = m.LEADS AND r.SPEND_SHARE = m.SPEND_SHARE
           AND r.LEADS_SHARE = m.LEADS_SHARE AND r.COST_PER_LEAD = m.COST_PER_LEAD, 'PASS', 'FAIL') AS STATUS
FROM ranked r
FULL OUTER JOIN expected e ON e.CHANNEL = r.CHANNEL
LEFT JOIN MART_CHANNEL_PERFORMANCE m ON m.CHANNEL = COALESCE(r.CHANNEL, e.CHANNEL)
ORDER BY COALESCE(r.LEADS_RANK, e.LEADS_RANK), 1;


-- -----------------------------------------------------------------------------
-- 4. Analysis #2, continued: is the channel answer the same in every year?
--    BUSINESS QUESTION: does the answer to question 1 hold in 2023, 2024 and 2025, or does it
--      depend on the year?
--    METHOD: the daily activity fact (FCT_CAMPAIGN_DAILY_ACTIVITY: one campaign x day per row,
--      spend by spend date, leads by created date, IS_IN_FLIGHT = 1 on flight days) grouped
--      by YEAR x CHANNEL in one CTE (a single fact, so no join is needed). Window functions
--      with PARTITION BY YEAR rank the channels and compute the share within each year.
--      CAMPAIGN_DAYS (flight days) measures how much each channel ran that year.
--    HOW TO READ: the channel with the most leads changes every year: paid_social in 2023
--      (24,520), paid_search in 2024 (29,566), affiliate in 2025 (22,733). Volume depends on how
--      much each channel ran that year as well as on its leads per unit of spend: affiliate was
--      4th by volume in 2023 with the fewest campaign-days (494), and video ran the most in 2024
--      (1,204 campaign-days, 503,790.97 of spend) and was still only 4th. The per-spend order
--      never changes: affiliate 1st, paid_search 2nd, paid_social 3rd, display 4th, video 5th in
--      all three years (affiliate 85.7150 / 72.9714 / 83.2843 leads per 1,000 of spend; video
--      31.6631 / 31.2292 / 30.0963). So "most leads" in a period is partly a matter of which
--      campaigns ran that year (the data records what ran, not the decisions behind it). The
--      unchanged per-spend order is a regularity of this synthetic data, likely a property of
--      the generator (G6), not an established channel trait: the values still move within a
--      channel (paid_search 75.4623 / 67.5963 / 81.8050), and in 2025 the first two are close
--      (affiliate 83.2843, paid_search 81.8050 on 401 campaign-days).
--    CAVEATS: activity basis (G3): a year counts the spend and leads dated in it, so a campaign
--      that crosses a year boundary is split between years. 15 cells of a synthetic dataset,
--      some small (2025 paid_search: 401 campaign-days); no statistical test is implied.
--    Expected: all 15 rows [D]; their sums by year equal the yearly figures of block 7.
-- -----------------------------------------------------------------------------
WITH year_channel AS (           -- campaign x day -> year x channel, on one fact
  SELECT YEAR(ACTIVITY_DATE) AS YEAR, CHANNEL,
         SUM(IS_IN_FLIGHT) AS CAMPAIGN_DAYS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  GROUP BY YEAR(ACTIVITY_DATE), CHANNEL
),
ranked AS (                      -- rank and share WITHIN each year
  SELECT YEAR, CHANNEL, CAMPAIGN_DAYS, SPEND, LEADS,
         RANK() OVER (PARTITION BY YEAR ORDER BY LEADS DESC)                                   AS LEADS_RANK_IN_YEAR,
         ROUND(LEADS::NUMBER(32,18) / SUM(LEADS) OVER (PARTITION BY YEAR), 6)                  AS LEADS_SHARE_IN_YEAR,
         ROUND((LEADS * 1000)::NUMBER(32,18) / NULLIF(SPEND, 0), 4)                            AS LEADS_PER_1000_SPEND,
         RANK() OVER (PARTITION BY YEAR ORDER BY LEADS::NUMBER(32,18) / NULLIF(SPEND, 0) DESC) AS LEADS_PER_SPEND_RANK_IN_YEAR
  FROM year_channel
),
expected (YEAR, CHANNEL, CAMPAIGN_DAYS, SPEND, LEADS, LEADS_RANK_IN_YEAR, LEADS_SHARE_IN_YEAR, LEADS_PER_1000_SPEND,
          LEADS_PER_SPEND_RANK_IN_YEAR) AS (
  SELECT * FROM VALUES     -- [D]
    (2023, 'paid_social',  826, 396556.03, 24520, 1, 0.280072, 61.8324, 3),
    (2023, 'paid_search',  869, 300163.09, 22651, 2, 0.258724, 75.4623, 2),
    (2023, 'display',      988, 375255.15, 17812, 3, 0.203452, 47.4664, 4),
    (2023, 'affiliate',    494, 191203.31, 16389, 4, 0.187198, 85.7150, 1),
    (2023, 'video',        671, 195084.83,  6177, 5, 0.070555, 31.6631, 5),
    (2024, 'paid_search', 1037, 437390.55, 29566, 1, 0.275363, 67.5963, 2),
    (2024, 'affiliate',    933, 393675.01, 28727, 2, 0.267549, 72.9714, 1),
    (2024, 'paid_social',  649, 387302.85, 21435, 3, 0.199635, 55.3443, 3),
    (2024, 'video',       1204, 503790.97, 15733, 4, 0.146529, 31.2292, 5),
    (2024, 'display',      582, 249038.96, 11910, 5, 0.110924, 47.8238, 4),
    (2025, 'affiliate',    723, 272956.75, 22733, 1, 0.340498, 83.2843, 1),
    (2025, 'display',      797, 331002.89, 15427, 2, 0.231068, 46.6068, 4),
    (2025, 'paid_search',  401, 159537.89, 13051, 3, 0.195480, 81.8050, 2),
    (2025, 'paid_social',  431, 200873.00, 11664, 4, 0.174705, 58.0665, 3),
    (2025, 'video',        635, 129218.74,  3889, 5, 0.058250, 30.0963, 5)
)
SELECT COALESCE(r.YEAR, e.YEAR) AS YEAR, COALESCE(r.CHANNEL, e.CHANNEL) AS CHANNEL, r.CAMPAIGN_DAYS, r.SPEND, r.LEADS,
       r.LEADS_RANK_IN_YEAR, r.LEADS_SHARE_IN_YEAR, r.LEADS_PER_1000_SPEND, r.LEADS_PER_SPEND_RANK_IN_YEAR,
       IFF(r.CAMPAIGN_DAYS = e.CAMPAIGN_DAYS AND r.SPEND = e.SPEND AND r.LEADS = e.LEADS
           AND r.LEADS_RANK_IN_YEAR = e.LEADS_RANK_IN_YEAR AND r.LEADS_SHARE_IN_YEAR = e.LEADS_SHARE_IN_YEAR
           AND r.LEADS_PER_1000_SPEND = e.LEADS_PER_1000_SPEND
           AND r.LEADS_PER_SPEND_RANK_IN_YEAR = e.LEADS_PER_SPEND_RANK_IN_YEAR, 'PASS', 'FAIL') AS STATUS
FROM ranked r
FULL OUTER JOIN expected e ON e.YEAR = r.YEAR AND e.CHANNEL = r.CHANNEL
ORDER BY 1, COALESCE(r.LEADS_RANK_IN_YEAR, e.LEADS_RANK_IN_YEAR);


-- -----------------------------------------------------------------------------
-- 5. Analysis #10, Monthly Trend & Growth: month over month, year over year, smoothed, cumulative
--    BUSINESS QUESTION: is marketing volume growing or shrinking, and how much of the movement
--      is simply more or fewer campaigns running?
--    METHOD: the dashboard's monthly activity table rolled up to the month, then window
--      functions ordered by month:
--        LAG(x, 1)  = the previous month       -> month-over-month change  (x - prev) / prev
--        LAG(x, 12) = the same month last year -> year-over-year change    (removes seasonality)
--        AVG(LEADS) OVER (ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) -> 3-month moving average,
--          shown only where the frame holds 3 rows (COUNT(*) over the same frame); block 6
--          checks that those 3 rows are the 3 calendar months to date
--        SUM(SPEND) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) -> cumulative spend
--      LAG counts ROWS, not months: it means "previous month" only because the series has one
--      row for each of the 36 months with no gap. Block 6 checks that row offset = calendar
--      offset. Growth per active campaign compares LEADS / ACTIVE_CAMPAIGNS with the same ratio
--      12 months earlier, computed from the unrounded counts.
--    HOW TO READ: growth is a fraction (0.5611 = +56.11%). 2024-01 spend shows +419.04% YoY
--      because 2023-01 had only 3 campaigns (a base effect, not a boom). In 2025 leads were
--      below the same month of 2024 in 8 of 12 months, exactly the 8 months with fewer active
--      campaigns than a year before (block 6). The 3-month average of leads peaks at 11,408.67
--      (2024-08..2024-10).
--      Cumulative spend reaches 1,458,262.41 at the end of 2023, 3,429,460.75 at the end of 2024
--      and 4,523,050.02 at the end of 2025.
--    CAVEATS: the edges are dominated by base effects (2023-01: 3 campaigns; 2025-12: 1, so
--      2025-12 YoY is -99.45% for leads): read growth with ACTIVE_CAMPAIGNS beside it (G7).
--      LEADS_PER_ACTIVE_CAMPAIGN counts a campaign active one day like one active all month,
--      so it is a coarse normaliser; block 8 uses campaign-days instead. Activity basis only
--      (G3). Conversions are left out to keep this view to spend and lead volume. Their
--      activity-basis growth would be valid as a count of what was booked in a month (block 7
--      shows it by year), but it is not a conversion-rate trend (G3).
--    Expected: the spot values and properties in block 6 [D]; the monthly bases are block 2.
-- -----------------------------------------------------------------------------
WITH monthly AS (           -- MART_MONTHLY_MARKETING (channel x month) rolled up to the month: 36 rows
  SELECT MONTH_START, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS
  FROM MART_MONTHLY_MARKETING
  GROUP BY MONTH_START
),
windowed AS (               -- every window ordered by the month
  SELECT MONTH_START, ACTIVE_CAMPAIGNS, SPEND, LEADS,
         LAG(SPEND, 1)             OVER (ORDER BY MONTH_START)                                         AS SPEND_PREV_MONTH,
         LAG(SPEND, 12)            OVER (ORDER BY MONTH_START)                                         AS SPEND_PREV_YEAR,
         LAG(LEADS, 1)             OVER (ORDER BY MONTH_START)                                         AS LEADS_PREV_MONTH,
         LAG(LEADS, 12)            OVER (ORDER BY MONTH_START)                                         AS LEADS_PREV_YEAR,
         LAG(ACTIVE_CAMPAIGNS, 12) OVER (ORDER BY MONTH_START)                                         AS ACTIVE_PREV_YEAR,
         AVG(LEADS)                OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS LEADS_AVG_FRAME,
         COUNT(*)                  OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS ROWS_IN_FRAME,
         SUM(SPEND)                OVER (ORDER BY MONTH_START ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUMULATIVE_SPEND
  FROM monthly
)
SELECT TO_CHAR(MONTH_START, 'YYYY-MM')                                                              AS MONTH,
       ACTIVE_CAMPAIGNS,
       ROUND((ACTIVE_CAMPAIGNS - ACTIVE_PREV_YEAR)::NUMBER(32,18) / NULLIF(ACTIVE_PREV_YEAR, 0), 4)  AS ACTIVE_YOY,
       SPEND,
       ROUND((SPEND - SPEND_PREV_MONTH)::NUMBER(32,18) / NULLIF(SPEND_PREV_MONTH, 0), 4)            AS SPEND_MOM,
       ROUND((SPEND - SPEND_PREV_YEAR)::NUMBER(32,18)  / NULLIF(SPEND_PREV_YEAR, 0), 4)             AS SPEND_YOY,
       CUMULATIVE_SPEND,
       LEADS,
       ROUND((LEADS - LEADS_PREV_MONTH)::NUMBER(32,18) / NULLIF(LEADS_PREV_MONTH, 0), 4)            AS LEADS_MOM,
       ROUND((LEADS - LEADS_PREV_YEAR)::NUMBER(32,18)  / NULLIF(LEADS_PREV_YEAR, 0), 4)             AS LEADS_YOY,
       IFF(ROWS_IN_FRAME = 3, ROUND(LEADS_AVG_FRAME, 2), NULL)                                      AS LEADS_3M_AVG,
       ROUND(LEADS::NUMBER(32,18) / NULLIF(ACTIVE_CAMPAIGNS, 0), 2)                                 AS LEADS_PER_ACTIVE_CAMPAIGN,
       ROUND((LEADS * ACTIVE_PREV_YEAR)::NUMBER(32,18)
             / NULLIF(ACTIVE_CAMPAIGNS * LEADS_PREV_YEAR, 0) - 1, 4)                                AS LEADS_PER_ACTIVE_CAMPAIGN_YOY
FROM windowed
ORDER BY MONTH_START;


-- -----------------------------------------------------------------------------
-- 6. Analysis #10: checks of the window functions in block 5
--    Question: do the LAG offsets mean calendar months, and do the window results equal values
--      computed outside Snowflake?
--    Why: a missing month would silently turn LAG(x, 12) into "11 months ago"; a frame over a
--      gap would average 3 rows that are not the last 3 months. Check 2 gives the row offsets
--      their calendar meaning (each row's previous row is the calendar month before). Checks 3
--      and 4 test the two windows block 5 relies on directly, LAG(x, 12) and the 3-row frame
--      (its first month must be 2 calendar months back); they follow from check 2 when it
--      passes, but would catch a gap on their own. Checks 5-7 compare the running spend with
--      [P3]; checks 8-19 compare spot values and counts with [D]; check 20 counts the YoY
--      months; checks 21-25 measure how closely monthly leads follow the campaign count and the
--      spend (G7), over all 36 months and without the 5 thin months. The CTEs repeat block 5's
--      expressions.
--    HOW TO READ: in 22 of the 24 months with a YoY value, leads and active campaigns moved in
--      the same direction (the exceptions: 2024-08, same campaign count and more leads;
--      2024-10, one campaign fewer and more leads); in 2025 the 8 months with fewer leads than
--      a year before (Mar-May and Aug-Dec, check 14) are exactly the 8 months with fewer
--      campaigns (check 15). Check 16 also counts 8 months, but not the same ones: leads per
--      active campaign fell YoY in Feb, Apr, Jun and Aug-Dec 2025, and only 6 of those months
--      also had fewer leads (check 17), so per active campaign 2025 is mixed month by month.
--      CORR(ACTIVE_CAMPAIGNS, LEADS) = 0.9403 and CORR(SPEND, LEADS) = 0.9693 over the 36
--      months: monthly leads move together with the campaign count and the spend. A linear
--      correlation is not proportionality, and part of it comes from the thin months at the
--      ends of the range: without the 5 months with fewer than 10 active campaigns (2023-01,
--      2023-02, 2025-10..2025-12) the two are 0.8734 and 0.9352. Leads per active campaign
--      still range from 334.55 to 657.88 by month (65.00 in 2025-12, block 5) and CPL from
--      14.3447 to 21.7941 (12.4160 in 2025-12, block 2). A correlation describes co-movement,
--      not cause, and its closeness is partly a property of the generator (G6).
--    Expected: 36 / 35 / 24 / 34 rows and 24 YoY months [C]; cumulative spend by year end [P3
--      by year, 02c tests block 13]; spot values, counts and correlations [D].
-- -----------------------------------------------------------------------------
WITH monthly AS (
  SELECT MONTH_START, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS
  FROM MART_MONTHLY_MARKETING
  GROUP BY MONTH_START
),
windowed AS (               -- the windows of block 5, plus the months that LAG reaches
  SELECT MONTH_START, ACTIVE_CAMPAIGNS, SPEND, LEADS,
         LAG(MONTH_START, 1)  OVER (ORDER BY MONTH_START) AS MONTH_LAG_1,
         LAG(MONTH_START, 12) OVER (ORDER BY MONTH_START) AS MONTH_LAG_12,
         ROUND((SPEND - LAG(SPEND, 12) OVER (ORDER BY MONTH_START))::NUMBER(32,18)
               / NULLIF(LAG(SPEND, 12) OVER (ORDER BY MONTH_START), 0), 4)                        AS SPEND_YOY,
         ROUND((LEADS - LAG(LEADS, 1) OVER (ORDER BY MONTH_START))::NUMBER(32,18)
               / NULLIF(LAG(LEADS, 1) OVER (ORDER BY MONTH_START), 0), 4)                         AS LEADS_MOM,
         ROUND((LEADS - LAG(LEADS, 12) OVER (ORDER BY MONTH_START))::NUMBER(32,18)
               / NULLIF(LAG(LEADS, 12) OVER (ORDER BY MONTH_START), 0), 4)                        AS LEADS_YOY,
         ROUND((ACTIVE_CAMPAIGNS - LAG(ACTIVE_CAMPAIGNS, 12) OVER (ORDER BY MONTH_START))::NUMBER(32,18)
               / NULLIF(LAG(ACTIVE_CAMPAIGNS, 12) OVER (ORDER BY MONTH_START), 0), 4)             AS ACTIVE_YOY,
         ROUND((LEADS * LAG(ACTIVE_CAMPAIGNS, 12) OVER (ORDER BY MONTH_START))::NUMBER(32,18)
               / NULLIF(ACTIVE_CAMPAIGNS * LAG(LEADS, 12) OVER (ORDER BY MONTH_START), 0) - 1, 4) AS LEADS_PER_ACTIVE_CAMPAIGN_YOY,
         COUNT(*)   OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)          AS ROWS_IN_FRAME,
         MIN(MONTH_START) OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)    AS FRAME_FIRST_MONTH,
         IFF(COUNT(*) OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) = 3,
             ROUND(AVG(LEADS) OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2),
             NULL)                                                                                AS LEADS_3M_AVG,
         SUM(SPEND) OVER (ORDER BY MONTH_START ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUMULATIVE_SPEND
  FROM monthly
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'months in the series' AS CHECK_NAME, COUNT(*) AS ACTUAL, 36 AS EXPECTED FROM windowed
  UNION ALL SELECT 2, 'LAG(MONTH_START, 1) = calendar month before',
                   COUNT_IF(MONTH_LAG_1 = DATEADD('month', -1, MONTH_START)), 35 FROM windowed
  UNION ALL SELECT 3, 'LAG(MONTH_START, 12) = same month a year before',
                   COUNT_IF(MONTH_LAG_12 = DATEADD('month', -12, MONTH_START)), 24 FROM windowed
  UNION ALL SELECT 4, '3-row frame = 3 calendar months to date',
                   COUNT_IF(ROWS_IN_FRAME = 3 AND FRAME_FIRST_MONTH = DATEADD('month', -2, MONTH_START)), 34 FROM windowed
  UNION ALL SELECT 5, 'CUMULATIVE_SPEND at 2023-12',
                   MAX(IFF(MONTH_START = '2023-12-01'::DATE, CUMULATIVE_SPEND, NULL)), 1458262.41 FROM windowed
  UNION ALL SELECT 6, 'CUMULATIVE_SPEND at 2024-12',
                   MAX(IFF(MONTH_START = '2024-12-01'::DATE, CUMULATIVE_SPEND, NULL)), 3429460.75 FROM windowed
  UNION ALL SELECT 7, 'CUMULATIVE_SPEND at 2025-12 (= total spend)',
                   MAX(IFF(MONTH_START = '2025-12-01'::DATE, CUMULATIVE_SPEND, NULL)), 4523050.02 FROM windowed
  UNION ALL SELECT 8, 'SPEND_YOY 2024-01 (base: 3 campaigns)',
                   MAX(IFF(MONTH_START = '2024-01-01'::DATE, SPEND_YOY, NULL)), 4.1904 FROM windowed
  UNION ALL SELECT 9, 'LEADS_MOM, largest rise (2023-03)', MAX(LEADS_MOM), 1.2050 FROM windowed
  UNION ALL SELECT 10, '... its month (YYYYMM)', MAX_BY(TO_NUMBER(TO_CHAR(MONTH_START, 'YYYYMM')), LEADS_MOM), 202303 FROM windowed
  UNION ALL SELECT 11, 'LEADS_MOM, largest fall (2025-12)', MIN(LEADS_MOM), -0.9405 FROM windowed
  UNION ALL SELECT 12, 'LEADS_3M_AVG 2023-03 (first full frame)',
                   MAX(IFF(MONTH_START = '2023-03-01'::DATE, LEADS_3M_AVG, NULL)), 3459.67 FROM windowed
  UNION ALL SELECT 13, 'LEADS_3M_AVG, highest (2024-10)', MAX(LEADS_3M_AVG), 11408.67 FROM windowed
  UNION ALL SELECT 14, '2025 months with LEADS_YOY < 0',
                   COUNT_IF(YEAR(MONTH_START) = 2025 AND LEADS_YOY < 0), 8 FROM windowed
  UNION ALL SELECT 15, '2025 months with ACTIVE_YOY < 0',
                   COUNT_IF(YEAR(MONTH_START) = 2025 AND ACTIVE_YOY < 0), 8 FROM windowed
  UNION ALL SELECT 16, '2025 months, leads/active campaign YoY<0',
                   COUNT_IF(YEAR(MONTH_START) = 2025 AND LEADS_PER_ACTIVE_CAMPAIGN_YOY < 0), 8 FROM windowed
  UNION ALL SELECT 17, '... of them also with LEADS_YOY < 0',
                   COUNT_IF(YEAR(MONTH_START) = 2025 AND LEADS_PER_ACTIVE_CAMPAIGN_YOY < 0 AND LEADS_YOY < 0), 6 FROM windowed
  UNION ALL SELECT 18, 'YoY months: SIGN(LEADS_YOY) = SIGN(ACTIVE_YOY)',
                   COUNT_IF(SIGN(LEADS_YOY) = SIGN(ACTIVE_YOY)), 22 FROM windowed
  UNION ALL SELECT 19, '... of them in 2025 (of 12)',
                   COUNT_IF(YEAR(MONTH_START) = 2025 AND SIGN(LEADS_YOY) = SIGN(ACTIVE_YOY)), 12 FROM windowed
  UNION ALL SELECT 20, 'months with a YoY value', COUNT(LEADS_YOY), 24 FROM windowed
  UNION ALL SELECT 21, 'CORR(ACTIVE_CAMPAIGNS, LEADS), 36 months',
                   ROUND(CORR(ACTIVE_CAMPAIGNS, LEADS), 4)::NUMBER(10,4), 0.9403 FROM windowed
  UNION ALL SELECT 22, 'CORR(SPEND, LEADS), 36 months',
                   ROUND(CORR(SPEND, LEADS), 4)::NUMBER(10,4), 0.9693 FROM windowed
  UNION ALL SELECT 23, 'months with >= 10 active campaigns', COUNT(*), 31 FROM windowed WHERE ACTIVE_CAMPAIGNS >= 10
  UNION ALL SELECT 24, 'CORR(ACTIVE, LEADS), months >= 10 active',
                   ROUND(CORR(ACTIVE_CAMPAIGNS, LEADS), 4)::NUMBER(10,4), 0.8734 FROM windowed WHERE ACTIVE_CAMPAIGNS >= 10
  UNION ALL SELECT 25, 'CORR(SPEND, LEADS), months >= 10 active',
                   ROUND(CORR(SPEND, LEADS), 4)::NUMBER(10,4), 0.9352 FROM windowed WHERE ACTIVE_CAMPAIGNS >= 10
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 7. Analysis #10: the three years side by side
--    BUSINESS QUESTION: how do 2023, 2024 and 2025 compare, and how many campaigns ran in each?
--    METHOD: each source aggregated to the year on its own, then joined 1:1 on YEAR:
--      campaigns started (DIM_CAMPAIGN by START_YEAR), campaigns active (a range join: the
--      windows that overlap the year), and from the daily activity fact the campaign-days in
--      flight (SUM(IS_IN_FLIGHT)), spend, leads, conversions and revenue by their own dates.
--      LAG(x) OVER (ORDER BY YEAR) gives the previous year for the YoY change.
--    HOW TO READ: 2024 was the largest year (50 campaigns started, 60 active, 4,405
--      campaign-days, 1,971,198.34 of spend, 107,371 leads). In 2025, 22 campaigns started and
--      35 were active; campaign-days fell 32.19% (block 8), spend 44.52%, leads 37.82%,
--      conversions 33.31% and attributed revenue 33.06%. CPL fell from 18.3588 to 16.3799.
--    CAVEATS: ACTIVE counts a campaign in every year it touches (23 cross a year boundary, so 48
--      + 60 + 35 = 143 for 120 campaigns): not additive across years. CONVERSIONS and REVENUE are
--      dated by conversion, so 2025 includes conversions of late-2024 leads (activity basis, G3);
--      CONVERSIONS / LEADS of a year is not a conversion rate. 2025 has no campaign start after
--      2025-08, so its last months are thin.
--    Expected: started, active [E01 27]; campaign-days = spend rows per year, leads, conversions
--      [E01 22]; spend, revenue [P3 by year; 02c tests block 13]; YoY changes and CPL [D].
-- -----------------------------------------------------------------------------
WITH started AS (           -- campaign -> start year
  SELECT START_YEAR AS YEAR, COUNT(*) AS CAMPAIGNS_STARTED
  FROM DIM_CAMPAIGN
  GROUP BY START_YEAR
),
active AS (                 -- campaign windows overlapping the year (dimension x dimension range join)
  SELECT y.YEAR, COUNT(c.CAMPAIGN_ID) AS CAMPAIGNS_ACTIVE
  FROM (SELECT DISTINCT YEAR FROM DIM_DATE) y
  LEFT JOIN DIM_CAMPAIGN c
         ON c.START_DATE <= DATE_FROM_PARTS(y.YEAR, 12, 31) AND c.END_DATE >= DATE_FROM_PARTS(y.YEAR, 1, 1)
  GROUP BY y.YEAR
),
activity AS (               -- campaign x day -> year, each measure on its own date (built into the fact)
  SELECT YEAR(ACTIVITY_DATE) AS YEAR, SUM(IS_IN_FLIGHT) AS CAMPAIGN_DAYS, SUM(SPEND) AS SPEND,
         SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(REVENUE) AS REVENUE
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  GROUP BY YEAR(ACTIVITY_DATE)
),
yearly AS (                 -- 1:1 on YEAR, then LAG for the previous year
  SELECT a.YEAR, s.CAMPAIGNS_STARTED, c.CAMPAIGNS_ACTIVE, a.CAMPAIGN_DAYS, a.SPEND, a.LEADS, a.CONVERSIONS, a.REVENUE,
         LAG(a.SPEND)       OVER (ORDER BY a.YEAR) AS SPEND_PREV,
         LAG(a.LEADS)       OVER (ORDER BY a.YEAR) AS LEADS_PREV,
         LAG(a.CONVERSIONS) OVER (ORDER BY a.YEAR) AS CONVERSIONS_PREV,
         LAG(a.REVENUE)     OVER (ORDER BY a.YEAR) AS REVENUE_PREV
  FROM activity a
  JOIN started s ON s.YEAR = a.YEAR
  JOIN active  c ON c.YEAR = a.YEAR
),
growth AS (
  SELECT YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, CAMPAIGN_DAYS, SPEND, LEADS, CONVERSIONS, REVENUE,
         ROUND((SPEND - SPEND_PREV)::NUMBER(32,18)             / NULLIF(SPEND_PREV, 0), 4)       AS SPEND_YOY,
         ROUND((LEADS - LEADS_PREV)::NUMBER(32,18)             / NULLIF(LEADS_PREV, 0), 4)       AS LEADS_YOY,
         ROUND((CONVERSIONS - CONVERSIONS_PREV)::NUMBER(32,18) / NULLIF(CONVERSIONS_PREV, 0), 4) AS CONVERSIONS_YOY,
         ROUND((REVENUE - REVENUE_PREV)::NUMBER(32,18)         / NULLIF(REVENUE_PREV, 0), 4)     AS REVENUE_YOY,
         ROUND(SPEND::NUMBER(32,18) / NULLIF(LEADS, 0), 4)                                       AS COST_PER_LEAD
  FROM yearly
),
expected (YEAR, CAMPAIGNS_STARTED, CAMPAIGNS_ACTIVE, CAMPAIGN_DAYS, SPEND, SPEND_YOY, LEADS, LEADS_YOY, CONVERSIONS,
          CONVERSIONS_YOY, REVENUE, REVENUE_YOY, COST_PER_LEAD) AS (
  SELECT * FROM VALUES     -- [E01 27, 22]; [P3]; [D]
    (2023, 48, 48, 3848, 1458262.41,    NULL,  87549,    NULL, 12779,    NULL, 7075482.35,    NULL, 16.6565),
    (2024, 50, 60, 4405, 1971198.34,  0.3517, 107371,  0.2264, 16148,  0.2636, 8677647.82,  0.2264, 18.3588),
    (2025, 22, 35, 2987, 1093589.27, -0.4452,  66764, -0.3782, 10769, -0.3331, 5808708.84, -0.3306, 16.3799)
)
SELECT COALESCE(g.YEAR, e.YEAR) AS YEAR, g.CAMPAIGNS_STARTED, g.CAMPAIGNS_ACTIVE, g.CAMPAIGN_DAYS, g.SPEND, g.SPEND_YOY,
       g.LEADS, g.LEADS_YOY, g.CONVERSIONS, g.CONVERSIONS_YOY, g.REVENUE, g.REVENUE_YOY, g.COST_PER_LEAD,
       IFF(g.CAMPAIGNS_STARTED = e.CAMPAIGNS_STARTED AND g.CAMPAIGNS_ACTIVE = e.CAMPAIGNS_ACTIVE
           AND g.CAMPAIGN_DAYS = e.CAMPAIGN_DAYS AND g.SPEND = e.SPEND AND EQUAL_NULL(g.SPEND_YOY, e.SPEND_YOY)
           AND g.LEADS = e.LEADS AND EQUAL_NULL(g.LEADS_YOY, e.LEADS_YOY) AND g.CONVERSIONS = e.CONVERSIONS
           AND EQUAL_NULL(g.CONVERSIONS_YOY, e.CONVERSIONS_YOY) AND g.REVENUE = e.REVENUE
           AND EQUAL_NULL(g.REVENUE_YOY, e.REVENUE_YOY) AND g.COST_PER_LEAD = e.COST_PER_LEAD, 'PASS', 'FAIL') AS STATUS
FROM growth g
FULL OUTER JOIN expected e ON e.YEAR = g.YEAR
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 8. Analysis #10: volume, intensity or efficiency? Decomposing each year's change in leads
--    BUSINESS QUESTION: when leads fall (2025) or rise (2024), is it because fewer or more
--      campaigns ran (volume), because the running campaigns spent less or more per day
--      (intensity), or because each unit of spend brought fewer or more leads (efficiency)?
--    METHOD: an exact identity on yearly totals,
--        LEADS = CAMPAIGN_DAYS x (SPEND / CAMPAIGN_DAYS) x (LEADS / SPEND)
--      so 1 + LEADS_YOY = (1 + CAMPAIGN_DAYS_YOY) x (1 + SPEND_PER_DAY_YOY) x (1 + LEADS_PER_SPEND_YOY).
--      Each factor's YoY is a ratio of ratios computed from the unrounded yearly sums and the
--      previous year's sums (LAG ... OVER (ORDER BY YEAR)). The change in CPL is then split
--      into channel mix and within-channel change. Such a split is not unique: it depends on
--      which change is applied first, so both orders are printed, with the channel rates taken
--      by LAG ... OVER (PARTITION BY CHANNEL ORDER BY YEAR):
--        CPL_AT_PRIOR_CHANNEL_CPL          this year's spend per channel at the channel's
--                                          previous-year leads per unit of spend (mix first)
--        PRIOR_CPL_AT_CURRENT_CHANNEL_CPL  the previous year's spend per channel at the
--                                          channel's leads per unit of spend this year (rates first)
--      For comparison, the plan's per-active-campaign view: leads per active campaign and per
--      campaign-day, YoY.
--    HOW TO READ:
--      2025 vs 2024: leads -37.82% = campaign-days -32.19% (volume: 22 starts instead of 50)
--        x spend per campaign-day -18.18% (intensity) x leads per unit of spend +12.08%
--        (efficiency): 0.6781 x 0.8182 x 1.1208 = 0.6218. Volume is the largest factor.
--        CPL fell from 18.3588 to 16.3799 (-10.78%). Mix first: the 2025 channel mix at 2024's
--        channel CPLs gives 17.7287, so mix -3.43% (17.7287 / 18.3588 - 1) and within channels
--        -7.61% (16.3799 / 17.7287 - 1). Rates first: the 2024 mix at 2025's channel CPLs gives
--        16.7297, so within channels -8.87% (16.7297 / 18.3588 - 1) and mix -2.09% (16.3799 /
--        16.7297 - 1). Between about a fifth and a third of the fall is mix, depending on the
--        order; the rest is within channels. The mix moved both ways: video, the dearest
--        channel per lead, fell from 503,790.97 to 129,218.74 of spend, while display, the
--        second dearest, rose from 249,038.96 to 331,002.89 (block 4).
--      2024 vs 2023: leads +22.64% = campaign-days +14.48% x spend per day +18.08% x leads
--        per spend -9.27%; CPL rose from 16.6565 to 18.3588 (+10.22%), almost all within
--        channels in either order: mix first, the mix-only CPL 16.6387 is 0.11% below 2023's;
--        rates first, 18.1765 is +9.13% within channels (18.1765 / 16.6565 - 1) and the mix
--        adds +1.00% (18.3588 / 18.1765 - 1).
--      The two per-campaign views point in opposite directions in 2025: leads per active
--        campaign +6.60% (the plan's measure), leads per campaign-day -8.30%. Active campaigns
--        fell 41.67% (60 -> 35, block 7) but campaign-days only 32.19%, because a campaign
--        counts as active in a year whether it runs 1 or 150 days of it: the 2025 actives ran
--        2,987 / 35 = 85.3 days of the year on average, the 2024 actives 4,405 / 60 = 73.4.
--        Campaign-days measure exposure directly, so the volume factor above uses them. Whether
--        2025 did better or worse per unit therefore depends on the denominator: per unit of
--        spend +12.08% (partly channel mix), per campaign-day -8.30%.
--    CAVEATS: an accounting decomposition, not a causal one: it says which ratio moved, not why
--      (the data records what ran, not the decisions behind it). Leads per unit of spend is an
--      average across the campaigns that ran. Activity basis (G3). Synthetic data (G6).
--    Expected: all values [D] (2023 has no previous year: NULL growth and mix CPLs).
-- -----------------------------------------------------------------------------
WITH year_channel AS (      -- campaign x day -> year x channel (one fact)
  SELECT YEAR(ACTIVITY_DATE) AS YEAR, CHANNEL,
         SUM(IS_IN_FLIGHT) AS CAMPAIGN_DAYS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  GROUP BY YEAR(ACTIVITY_DATE), CHANNEL
),
mix AS (                    -- channel spend x channel leads per unit of spend, in both orders (2023: NULL)
  SELECT YEAR,
         SUM((SPEND * PRIOR_LEADS)::NUMBER(32,18) / NULLIF(PRIOR_SPEND, 0)) AS LEADS_AT_PRIOR_CHANNEL_RATES,   -- this year's spend, last year's rates
         SUM((PRIOR_SPEND * LEADS)::NUMBER(32,18) / NULLIF(SPEND, 0))       AS PRIOR_LEADS_AT_CURRENT_RATES    -- last year's spend, this year's rates
  FROM (SELECT YEAR, CHANNEL, SPEND, LEADS,
               LAG(LEADS) OVER (PARTITION BY CHANNEL ORDER BY YEAR) AS PRIOR_LEADS,
               LAG(SPEND) OVER (PARTITION BY CHANNEL ORDER BY YEAR) AS PRIOR_SPEND
        FROM year_channel)
  GROUP BY YEAR
),
active AS (                 -- campaign windows overlapping the year, as in block 7
  SELECT y.YEAR, COUNT(c.CAMPAIGN_ID) AS CAMPAIGNS_ACTIVE
  FROM (SELECT DISTINCT YEAR FROM DIM_DATE) y
  LEFT JOIN DIM_CAMPAIGN c
         ON c.START_DATE <= DATE_FROM_PARTS(y.YEAR, 12, 31) AND c.END_DATE >= DATE_FROM_PARTS(y.YEAR, 1, 1)
  GROUP BY y.YEAR
),
yearly AS (                 -- year totals, 1:1 joins on YEAR, previous year by LAG
  SELECT t.YEAR, t.CAMPAIGN_DAYS, t.SPEND, t.LEADS, a.CAMPAIGNS_ACTIVE, m.LEADS_AT_PRIOR_CHANNEL_RATES,
         m.PRIOR_LEADS_AT_CURRENT_RATES,
         LAG(t.CAMPAIGN_DAYS)    OVER (ORDER BY t.YEAR) AS DAYS_PREV,
         LAG(t.SPEND)            OVER (ORDER BY t.YEAR) AS SPEND_PREV,
         LAG(t.LEADS)            OVER (ORDER BY t.YEAR) AS LEADS_PREV,
         LAG(a.CAMPAIGNS_ACTIVE) OVER (ORDER BY t.YEAR) AS ACTIVE_PREV
  FROM (SELECT YEAR, SUM(CAMPAIGN_DAYS) AS CAMPAIGN_DAYS, SUM(SPEND) AS SPEND, SUM(LEADS) AS LEADS
        FROM year_channel GROUP BY YEAR) t
  JOIN active a ON a.YEAR = t.YEAR
  JOIN mix    m ON m.YEAR = t.YEAR
),
decomposed AS (
  SELECT YEAR,
         ROUND(LEADS::NUMBER(32,18)                   / NULLIF(LEADS_PREV, 0) - 1, 4)                   AS LEADS_YOY,
         ROUND(CAMPAIGN_DAYS::NUMBER(32,18)           / NULLIF(DAYS_PREV, 0) - 1, 4)                    AS CAMPAIGN_DAYS_YOY,
         ROUND((SPEND * DAYS_PREV)::NUMBER(32,18)     / NULLIF(CAMPAIGN_DAYS * SPEND_PREV, 0) - 1, 4)   AS SPEND_PER_DAY_YOY,
         ROUND((LEADS * SPEND_PREV)::NUMBER(32,18)    / NULLIF(SPEND * LEADS_PREV, 0) - 1, 4)           AS LEADS_PER_SPEND_YOY,
         ROUND((LEADS * ACTIVE_PREV)::NUMBER(32,18)   / NULLIF(CAMPAIGNS_ACTIVE * LEADS_PREV, 0) - 1, 4) AS LEADS_PER_ACTIVE_CAMPAIGN_YOY,
         ROUND((LEADS * DAYS_PREV)::NUMBER(32,18)     / NULLIF(CAMPAIGN_DAYS * LEADS_PREV, 0) - 1, 4)   AS LEADS_PER_CAMPAIGN_DAY_YOY,
         ROUND(SPEND::NUMBER(32,18)                   / NULLIF(LEADS, 0), 4)                            AS COST_PER_LEAD,
         ROUND(SPEND::NUMBER(32,18)                   / NULLIF(LEADS_AT_PRIOR_CHANNEL_RATES, 0), 4)     AS CPL_AT_PRIOR_CHANNEL_CPL,
         ROUND(SPEND_PREV::NUMBER(32,18)              / NULLIF(PRIOR_LEADS_AT_CURRENT_RATES, 0), 4)     AS PRIOR_CPL_AT_CURRENT_CHANNEL_CPL
  FROM yearly
),
expected (YEAR, LEADS_YOY, CAMPAIGN_DAYS_YOY, SPEND_PER_DAY_YOY, LEADS_PER_SPEND_YOY, LEADS_PER_ACTIVE_CAMPAIGN_YOY,
          LEADS_PER_CAMPAIGN_DAY_YOY, COST_PER_LEAD, CPL_AT_PRIOR_CHANNEL_CPL, PRIOR_CPL_AT_CURRENT_CHANNEL_CPL) AS (
  SELECT * FROM VALUES     -- [D]
    (2023,    NULL,    NULL,    NULL,    NULL,    NULL,    NULL, 16.6565,    NULL,    NULL),
    (2024,  0.2264,  0.1448,  0.1808, -0.0927, -0.0189,  0.0713, 18.3588, 16.6387, 18.1765),
    (2025, -0.3782, -0.3219, -0.1818,  0.1208,  0.0660, -0.0830, 16.3799, 17.7287, 16.7297)
)
SELECT COALESCE(d.YEAR, e.YEAR) AS YEAR, d.LEADS_YOY, d.CAMPAIGN_DAYS_YOY, d.SPEND_PER_DAY_YOY, d.LEADS_PER_SPEND_YOY,
       d.LEADS_PER_ACTIVE_CAMPAIGN_YOY, d.LEADS_PER_CAMPAIGN_DAY_YOY, d.COST_PER_LEAD, d.CPL_AT_PRIOR_CHANNEL_CPL,
       d.PRIOR_CPL_AT_CURRENT_CHANNEL_CPL,
       IFF(EQUAL_NULL(d.LEADS_YOY, e.LEADS_YOY) AND EQUAL_NULL(d.CAMPAIGN_DAYS_YOY, e.CAMPAIGN_DAYS_YOY)
           AND EQUAL_NULL(d.SPEND_PER_DAY_YOY, e.SPEND_PER_DAY_YOY) AND EQUAL_NULL(d.LEADS_PER_SPEND_YOY, e.LEADS_PER_SPEND_YOY)
           AND EQUAL_NULL(d.LEADS_PER_ACTIVE_CAMPAIGN_YOY, e.LEADS_PER_ACTIVE_CAMPAIGN_YOY)
           AND EQUAL_NULL(d.LEADS_PER_CAMPAIGN_DAY_YOY, e.LEADS_PER_CAMPAIGN_DAY_YOY)
           AND d.COST_PER_LEAD = e.COST_PER_LEAD AND EQUAL_NULL(d.CPL_AT_PRIOR_CHANNEL_CPL, e.CPL_AT_PRIOR_CHANNEL_CPL)
           AND EQUAL_NULL(d.PRIOR_CPL_AT_CURRENT_CHANNEL_CPL, e.PRIOR_CPL_AT_CURRENT_CHANNEL_CPL)
           AND d.YEAR IS NOT NULL AND e.YEAR IS NOT NULL, 'PASS', 'FAIL') AS STATUS
FROM decomposed d
FULL OUTER JOIN expected e ON e.YEAR = d.YEAR
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 9. Campaign performance table (the dashboard's campaign list): all 120 campaigns
--    BUSINESS QUESTION: where did the money go, campaign by campaign, and what did each
--      campaign return?
--    METHOD: MART_CAMPAIGN_PERFORMANCE is already one row per campaign, with spend, leads and
--      conversions aggregated per campaign before they were joined (02b), and its ratio
--      columns are valid at exactly this grain. Window functions add the rankings:
--      ROW_NUMBER() by spend (ties broken by CAMPAIGN_ID, so the order is deterministic), a
--      running SUM of spend over that order for the cumulative share, RANK() OVER (PARTITION
--      BY CHANNEL ORDER BY COST_PER_LEAD) to compare a campaign with its own channel, and
--      RANK() OVER (ORDER BY ROAS DESC) across all campaigns. Sorted by spend, largest first.
--    HOW TO READ: the largest campaign, CMP0093 (Display 2024 093), spent 72,153.85; the 10
--      largest together spent 14.6968% of the total, so spend is spread across many campaigns.
--      CPL_RANK_IN_CHANNEL 1 is the cheapest lead source within its channel (overall the cheapest
--      is CMP0070, affiliate, 6.6944 per lead; the dearest CMP0084, video, 42.1057). ROAS_RANK 1
--      is CMP0080 (13.013216), rank 120 CMP0084 (1.823364).
--    CAVEATS: the ratio columns and ranks are valid only on this full 120-row set: a dashboard
--      filter does not re-rank, and summing or averaging a ratio column across campaigns is
--      wrong (aggregate as SUM / SUM of the base columns). Campaigns differ in length (46 to 150
--      days), budget and year, so totals favour long campaigns. ROAS is last-touch attributed
--      revenue / spend, not causal (G4). Which campaigns are most cost-efficient (question 3)
--      and the ROAS ranking (question 6) are analysed in 06_marketing_efficiency.sql.
--    Expected: the checks in block 10.
-- -----------------------------------------------------------------------------
SELECT ROW_NUMBER() OVER (ORDER BY SPEND DESC, CAMPAIGN_ID)                                     AS SPEND_RANK,
       CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, SPEND,
       ROUND((SUM(SPEND) OVER (ORDER BY SPEND DESC, CAMPAIGN_ID
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))::NUMBER(32,18)
             / SUM(SPEND) OVER (), 6)                                                          AS CUMULATIVE_SPEND_SHARE,
       LEADS, CONVERTED_LEADS, REVENUE, COST_PER_LEAD,
       RANK() OVER (PARTITION BY CHANNEL ORDER BY COST_PER_LEAD)                               AS CPL_RANK_IN_CHANNEL,
       LEAD_CONVERSION_RATE, ROAS,
       RANK() OVER (ORDER BY ROAS DESC)                                                        AS ROAS_RANK,
       BUDGET_UTILIZATION
FROM MART_CAMPAIGN_PERFORMANCE
ORDER BY SPEND_RANK;


-- -----------------------------------------------------------------------------
-- 10. Campaign table: checks of block 9
--    Question: does the campaign table hold every campaign once, add up to the known totals,
--      and put the expected campaigns at the top and bottom of each ranking?
--    Why: the dashboard table is read row by row; a duplicated or missing campaign, or a
--      ranking that ties or skips, would be visible only here. The query repeats block 9's
--      window expressions over the same table. Campaign IDs are compared as numbers
--      (CMP0093 -> 93), because ACTUAL is numeric.
--    Expected: totals [P3; PUB]; ROAS ranks 1 and 120 [P3 campaign_top10_roas,
--      campaign_bottom10_roas]; spend rank 1, the top-10 share and the CPL extremes [D]; ranks
--      1..24 in each channel [C: 24 campaigns per channel (P3), no two CPLs tied at 4 dp (D)].
-- -----------------------------------------------------------------------------
WITH campaign_table AS (
  SELECT CAMPAIGN_ID, CHANNEL, SPEND, LEADS, CONVERTED_LEADS, REVENUE, COST_PER_LEAD, ROAS,
         TO_NUMBER(SUBSTR(CAMPAIGN_ID, 4))                                                     AS CAMPAIGN_NUMBER,
         ROW_NUMBER() OVER (ORDER BY SPEND DESC, CAMPAIGN_ID)                                  AS SPEND_RANK,
         ROUND((SUM(SPEND) OVER (ORDER BY SPEND DESC, CAMPAIGN_ID
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))::NUMBER(32,18)
               / SUM(SPEND) OVER (), 6)                                                        AS CUMULATIVE_SPEND_SHARE,
         RANK() OVER (PARTITION BY CHANNEL ORDER BY COST_PER_LEAD)                             AS CPL_RANK_IN_CHANNEL,
         RANK() OVER (ORDER BY ROAS DESC)                                                      AS ROAS_RANK
  FROM MART_CAMPAIGN_PERFORMANCE
),
per_channel AS (            -- a complete ranking 1..24 per channel: 24 distinct ranks, the highest 24
  SELECT CHANNEL, COUNT(*) AS CAMPAIGNS, COUNT(DISTINCT CPL_RANK_IN_CHANNEL) AS DISTINCT_RANKS,
         MAX(CPL_RANK_IN_CHANNEL) AS MAX_RANK
  FROM campaign_table
  GROUP BY CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows (campaigns)' AS CHECK_NAME, COUNT(*) AS ACTUAL, 120 AS EXPECTED FROM campaign_table
  UNION ALL SELECT 2, 'distinct CAMPAIGN_ID', COUNT(DISTINCT CAMPAIGN_ID), 120 FROM campaign_table
  UNION ALL SELECT 3, 'SUM(SPEND)', SUM(SPEND), 4523050.02 FROM campaign_table
  UNION ALL SELECT 4, 'SUM(LEADS)', SUM(LEADS), 261684 FROM campaign_table
  UNION ALL SELECT 5, 'SUM(CONVERTED_LEADS)', SUM(CONVERTED_LEADS), 39696 FROM campaign_table
  UNION ALL SELECT 6, 'SUM(REVENUE)', SUM(REVENUE), 21561839.01 FROM campaign_table
  UNION ALL SELECT 7, 'SPEND_RANK 1: campaign number (CMP0093)',
                   MAX(IFF(SPEND_RANK = 1, CAMPAIGN_NUMBER, NULL)), 93 FROM campaign_table
  UNION ALL SELECT 8, 'SPEND_RANK 1: SPEND', MAX(IFF(SPEND_RANK = 1, SPEND, NULL)), 72153.85 FROM campaign_table
  UNION ALL SELECT 9, 'CUMULATIVE_SPEND_SHARE at SPEND_RANK 10',
                   MAX(IFF(SPEND_RANK = 10, CUMULATIVE_SPEND_SHARE, NULL)), 0.146968 FROM campaign_table
  UNION ALL SELECT 10, 'CUMULATIVE_SPEND_SHARE at SPEND_RANK 120',
                   MAX(IFF(SPEND_RANK = 120, CUMULATIVE_SPEND_SHARE, NULL)), 1.000000 FROM campaign_table
  UNION ALL SELECT 11, 'ROAS_RANK 1: campaign number (CMP0080)',
                   MAX(IFF(ROAS_RANK = 1, CAMPAIGN_NUMBER, NULL)), 80 FROM campaign_table
  UNION ALL SELECT 12, 'ROAS_RANK 1: ROAS', MAX(IFF(ROAS_RANK = 1, ROAS, NULL)), 13.013216 FROM campaign_table
  UNION ALL SELECT 13, 'ROAS_RANK 120: campaign number (CMP0084)',
                   MAX(IFF(ROAS_RANK = 120, CAMPAIGN_NUMBER, NULL)), 84 FROM campaign_table
  UNION ALL SELECT 14, 'ROAS_RANK 120: ROAS', MAX(IFF(ROAS_RANK = 120, ROAS, NULL)), 1.823364 FROM campaign_table
  UNION ALL SELECT 15, 'lowest COST_PER_LEAD (CMP0070, affiliate)', MIN(COST_PER_LEAD), 6.6944 FROM campaign_table
  UNION ALL SELECT 16, 'its campaign number', MIN_BY(CAMPAIGN_NUMBER, COST_PER_LEAD), 70 FROM campaign_table
  UNION ALL SELECT 17, 'highest COST_PER_LEAD (CMP0084, video)', MAX(COST_PER_LEAD), 42.1057 FROM campaign_table
  UNION ALL SELECT 18, 'its campaign number', MAX_BY(CAMPAIGN_NUMBER, COST_PER_LEAD), 84 FROM campaign_table
  UNION ALL SELECT 19, 'channels with CPL ranks exactly 1..24',
                   COUNT_IF(CAMPAIGNS = 24 AND DISTINCT_RANKS = 24 AND MAX_RANK = 24), 5 FROM per_channel
)
ORDER BY ORD;
