-- =============================================================================
-- Phase 4 / 06: marketing efficiency and ROAS (Dashboard 4), analyses #8 and #9
-- -----------------------------------------------------------------------------
-- Purpose
--   Answer the efficiency questions of the plan with read-only SQL over the tested MART tables,
--   and give Dashboard 4 "Marketing Efficiency & ROAS" its reference numbers:
--     BQ6  Which channels and campaigns have the highest ROAS?                 Parts A and B
--     BQ3  Which campaigns acquire customers most cost-efficiently?            Part B, block 7
--     BQ7  Which channels should the marketing budget be allocated to first?   Part E
--   plus the budget-utilisation and monthly ROAS views of the page (Parts C and D).
--   Plan analyses: #9 Marketing ROAS Analysis (multiple CTEs, aggregation, SUM() OVER ()) and
--   #8 Campaign Performance Ranking (RANK, DENSE_RANK).
-- Parts and blocks (the SQL technique each one shows)
--   A  #9 ROAS analysis        1  ROAS by channel: a spend CTE and a revenue CTE joined at channel grain
--                              2  what drives the channel gap: ROAS = purchase rate x revenue per
--                                 purchase / cost per lead (UNPIVOT, MIN_BY / MAX_BY)
--                              3  ROAS by objective within channel (SUM() OVER (PARTITION BY ...))
--                              4  ROAS by channel x year, activity and acquisition-year basis side by
--                                 side (RANK per year, LAG on unrounded ratios)
--   B  #8 campaign ranking     5  top 10 / bottom 10 by ROAS (RANK, DENSE_RANK, PARTITION BY, QUALIFY)
--                              6  best and worst campaign of each channel
--                              7  cost per purchase (BQ3)
--                              8  ties: RANK vs DENSE_RANK vs ROW_NUMBER on equal purchase counts
--                              9  what a "top N" filter returns under ties
--   C  budget utilisation      10 by channel: ratio of sums and distribution (GROUPING SETS,
--                                 PERCENTILE_CONT, CORR)
--                              11 histogram (WIDTH_BUCKET over a GENERATOR spine)
--                              12 the 5 lowest and 5 highest campaigns
--   D  monthly ROAS            13 spend vs revenue by activity month: rolling and cumulative ROAS
--                                 (SUM() OVER (ORDER BY ... ROWS ...))
--   E  budget allocation (BQ7) 14 share of spend vs share of revenue (SUM() OVER ())
--                              15 diminishing-returns check: ROAS by spend tercile (NTILE(3)), CORR
--                              16 why: the data's supply mechanics (a 35-lead daily ceiling, fixed CPM;
--                                 NTILE(5) of daily spend)
--                              17 allocation scorecard, and the recommendation (a hypothesis to test)
-- Analytical guard rails (the user plan), and where each is applied
--   G1 Grain. Facts of different grains are never joined row by row: the naive daily_spend x
--      leads join inflates spend 2,495x (docs/data_profile.md, "The grain trap"). Blocks 1, 3,
--      4, 13, 15, 16 and 17 aggregate each fact to the target grain in its own CTE and only
--      then join 1:1. Campaign rankings (Part B) and utilisation (Part C) read MART_CAMPAIGN_PERFORMANCE,
--      whose ratio columns are valid at its grain, the campaign. Every aggregated ratio here is
--      a ratio of sums, never an average of row-level ratios.
--   G2 The funnel is an aggregate campaign funnel. Block 2 decomposes ROAS into channel-level
--      ratios of sums (leads per spend, purchases per lead, revenue per purchase). None of them
--      follows a person; a lead converts once, to a trial OR a purchase.
--   G3 Activity basis vs lead-cohort basis. Block 13 is ACTIVITY basis (spend by spend date,
--      revenue by converted date) and says so in its column names. Block 4 prints the activity
--      basis and the ACQUISITION-YEAR basis (the spend of a year vs the later revenue of the
--      leads created in that year, a lead-cohort outcome) in separately named columns, to show
--      how far they differ by year; its year-over-year change uses the acquisition-year basis
--      only, because the activity basis is lopsided at the data edges. The two are never
--      charted on one axis. Block 16 uses an acquisition-day basis (the spend of a campaign-day
--      vs the later revenue of the leads created that day); it is not a time series and never
--      goes on a date axis. The full-range views (blocks 1-3, 5-12, 14, 15, 17) do not depend
--      on the basis: over the whole range both bases count the same revenue (21,561,839.01),
--      also per channel and per campaign.
--   G4 ROAS = last-touch attributed REVENUE / SPEND. It ranks attributed revenue per unit of
--      spend. It is not the causal return of the spend, and an average ROAS is not the return
--      of the next unit of spend (blocks 15-17).
--   G5 Lead score is not used in this file.
--   G6 The data is synthetic. Block 16 shows two generator mechanics that shape every
--      efficiency number: CPM is fixed per channel, and no campaign gets more than 35 leads on
--      a day. Block 2 shows that conversion and revenue per purchase barely differ by channel.
--      Recommendations built on these patterns are hypotheses about this data, not market facts.
--   G7 Volume follows the number of running campaigns (22 started in 2025 vs 50 in 2024).
--      Blocks 4 and 13 print ACTIVE_CAMPAIGNS next to every volume.
--   Ranks over a ratio that is NULL when spend is 0 (blocks 1, 3, 4, 17) order DESC NULLS
--   LAST: Snowflake sorts NULL first in a descending order by default, so a channel without
--   spend would otherwise rank 1. No current row has zero spend.
--   Budget utilisation is SPEND / BUDGET of whole campaigns only (architecture decision 9):
--   Part C never divides by a prorated monthly budget.
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02c_analysis_marts.sql (and its tests):
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/06_marketing_efficiency.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 40 statements,
--   well under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/06_efficiency.txt.
-- Role
--   CRM_TRANSFORMER, which owns the MART tables. (CRM_REPORTER can read the same tables.)
-- Inputs
--   MARKETING_CRM.MART: DIM_DATE, DIM_CAMPAIGN, FCT_DAILY_SPEND, FCT_LEAD_CONVERSIONS,
--   MART_CAMPAIGN_PERFORMANCE (Phase 3 core, sql/02b_core_models.sql) and
--   FCT_CAMPAIGN_DAILY_ACTIVITY, MART_MONTHLY_MARKETING, MART_CHANNEL_PERFORMANCE (Phase 4 marts,
--   sql/02c_analysis_marts.sql). Block 0 checks their row counts first.
-- Reading the results: every analysis query is followed by its check
--   Each analysis query prints its result. The statement right after it is a check that reads
--   exactly those printed rows with RESULT_SCAN(LAST_QUERY_ID()) and compares them with
--   independent expected values; its rows carry STATUS = PASS or FAIL. Why this pattern: the
--   check tests the rows as printed, without a second copy of the query (a copy compared with
--   itself would be a tautology). So run the file top to bottom (run_sql.py, or Run All in
--   Snowsight); a check run on its own reads whichever query ran last, and fails.
--   Every check compares a full expected list with a FULL OUTER JOIN and counts the rows equal
--   in every compared column, next to the number of rows printed, so a missing, extra or wrong
--   row is a FAIL and DETAIL names it. (Mixed measures share one NUMBER column in the checks, so
--   counts print as e.g. 5.000000.)
--   Rounding: as in 02b_core_models.sql ("Rounding"), every division casts its dividend to
--   NUMBER(32,18), so the one ROUND to the printed scale is the only rounding (ROAS, rates and
--   shares 6 dp; cost per unit and indexes 4 dp; money per unit 2 dp). Values derived from
--   ratios are taken from the unrounded ratios: block 4's year-over-year change is a
--   difference of unrounded ROAS, block 10's quartiles interpolate the unrounded campaign
--   utilisation. CORR returns FLOAT; it is rounded once to 4 dp (blocks 10 and 15 correlate
--   the stored 6-dp campaign columns; [D] finds the same 4 dp from the unrounded ratios).
-- Where the expected values come from (never from the query under test)
--   [KT]   Known totals, reproduced to the cent by the Phase 3 and Phase 4 tests
--          (02b_core_models_tests.sql block 9, 02c_analysis_marts_tests.sql block 5): spend
--          4,523,050.02; revenue 21,561,839.01; leads 261,684; purchases 16,691; campaigns
--          120; budget 5,418,642.16; flight days 11,240; 1,096 calendar days of DIM_DATE;
--          13,760 / 180 / 5 rows of the marts.
--   [PUB]  The publisher's reference output: spend and attributed revenue by channel.
--   [P3]   The local KPI reconciliation (2026-10-13, before Snowflake existed), as carried by
--          02b_core_models_tests.sql: kpi_channel_ratios (ROAS, COST_PER_LEAD, PURCHASE_RATE,
--          COST_PER_PURCHASE by channel; block 14 there) and campaign_top10_roas /
--          campaign_bottom10_roas (block 16 there).
--   [E02c] docs/evidence/02c_analysis_marts_tests.txt, statement number in brackets: [14] the
--          36 activity months (active campaigns, spend, revenue), [18] the three years,
--          [20] the channel ratios (BUDGET_UTILIZATION), [21] the channel spend and revenue
--          shares.
--   [D]    Python 3 csv + decimal (ROUND_HALF_UP, 60-digit precision), 2026-10-14, outside
--          Snowflake, from data/raw/source/campaigns.csv, daily_spend.csv, leads.csv and
--          conversions.csv: every other value (it also reproduces every [KT], [PUB], [P3] and
--          [E02c] value used here). Ranks follow the same order and tie rules as the SQL.
--          Percentiles interpolate linearly, like PERCENTILE_CONT. Correlations are exact
--          Pearson coefficients. No exact value lies within 10^-9 of a rounding midpoint,
--          except video's cost per lead on ceiling days (block 16), which is exactly
--          28,886.76 / 1,120 = 25.79175 and rounds half away from zero to 25.7918 in both.
-- Dashboard 4 (Phase 6): which block gives the reference numbers of which chart
--   channel ROAS bars (SUM(REVENUE) / SUM(SPEND) of MART_CHANNEL_PERFORMANCE): block 1;
--   campaign ranking tables (MART_CAMPAIGN_PERFORMANCE at campaign grain): blocks 5 and 7;
--   budget utilisation: blocks 10-11; monthly spend vs revenue with cumulative ROAS
--   (MART_MONTHLY_MARKETING): block 13; spend share vs revenue share: block 14; allocation
--   scorecard: block 17.
-- Statement map (index printed by run_sql.py -> block; c = the check of the block)
--   [1-4] context   [5] 0a who/where   [6] 0b inputs
--   [7-8] 1, 1c   [9-10] 2, 2c   [11-12] 3, 3c   [13-14] 4, 4c
--   [15-16] 5, 5c   [17-18] 6, 6c   [19-20] 7, 7c   [21-22] 8, 8c   [23-24] 9, 9c
--   [25-26] 10, 10c   [27-28] 11, 11c   [29-30] 12, 12c
--   [31-32] 13, 13c
--   [33-34] 14, 14c   [35-36] 15, 15c   [37-38] 16, 16c   [39-40] 17, 17c
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
-- 0b. Inputs: the eight MART tables this file reads exist with their tested row counts
--    Why: every number below assumes the tested Phase 3 / Phase 4 tables. A missing or
--      rebuilt-but-untested table fails here, before any analysis is read.
--    Expected [KT]: 1,096 / 120 / 11,240 / 261,684 / 120 / 13,760 / 180 / 5 rows.
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, ROW_COUNT, EXPECTED_ROWS, IFF(ROW_COUNT = EXPECTED_ROWS, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'DIM_DATE' AS TABLE_NAME, (SELECT COUNT(*) FROM DIM_DATE) AS ROW_COUNT, 1096 AS EXPECTED_ROWS
  UNION ALL SELECT 2, 'DIM_CAMPAIGN',                (SELECT COUNT(*) FROM DIM_CAMPAIGN),                120
  UNION ALL SELECT 3, 'FCT_DAILY_SPEND',             (SELECT COUNT(*) FROM FCT_DAILY_SPEND),             11240
  UNION ALL SELECT 4, 'FCT_LEAD_CONVERSIONS',        (SELECT COUNT(*) FROM FCT_LEAD_CONVERSIONS),        261684
  UNION ALL SELECT 5, 'MART_CAMPAIGN_PERFORMANCE',   (SELECT COUNT(*) FROM MART_CAMPAIGN_PERFORMANCE),   120
  UNION ALL SELECT 6, 'FCT_CAMPAIGN_DAILY_ACTIVITY', (SELECT COUNT(*) FROM FCT_CAMPAIGN_DAILY_ACTIVITY), 13760
  UNION ALL SELECT 7, 'MART_MONTHLY_MARKETING',      (SELECT COUNT(*) FROM MART_MONTHLY_MARKETING),      180
  UNION ALL SELECT 8, 'MART_CHANNEL_PERFORMANCE',    (SELECT COUNT(*) FROM MART_CHANNEL_PERFORMANCE),    5
)
ORDER BY ORD;


-- =============================================================================
-- PART A. Analysis #9, Marketing ROAS: which channels return the most revenue per unit of spend?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. ROAS by channel: a spend CTE and a revenue CTE, joined at channel grain
--    BUSINESS QUESTION  BQ6: which channels have the highest ROAS?
--    METHOD  Multiple CTEs + aggregation (plan #9). Each fact is aggregated to one row per
--      channel ON ITS OWN: campaigns from DIM_CAMPAIGN, spend from FCT_DAILY_SPEND (campaign x
--      day), leads, purchases and revenue from FCT_LEAD_CONVERSIONS (one row per lead). Only
--      then are the three joined 1:1 on CHANNEL (G1). ROAS = SUM(REVENUE) / SUM(SPEND), a
--      ratio of sums; RANK() OVER (ORDER BY ROAS DESC) orders the channels. The last four
--      columns decompose it exactly (block 2 measures how much each factor varies):
--        ROAS = (LEADS / SPEND) x (PURCHASES / LEADS) x (REVENUE / PURCHASES)
--             = PURCHASE_RATE x REVENUE_PER_PURCHASE / COST_PER_LEAD
--      and COST_PER_PURCHASE = SPEND / PURCHASES is the channel answer to BQ3.
--    HOW TO READ  affiliate returns 6.540536 of attributed revenue per unit of spend, then
--      paid_search 6.063294, paid_social 4.762857, display 3.908855 and video 2.520913
--      (portfolio 21,561,839.01 / 4,523,050.02 = 4.767102, block 13). Cost per purchase runs
--      the other way, 198.0229 (affiliate) to 505.5522 (video).
--    CAVEATS  Last-touch attributed revenue, not the causal effect of the spend (G4): channels
--      that work earlier in a journey (often video and display) can look worse than their
--      contribution, because last-touch credits only the final touch. Full range
--      2023-01-01..2025-12-31; every channel has 24 campaigns. Synthetic data (G6).
-- -----------------------------------------------------------------------------
WITH campaigns_by_channel AS (    -- CTE 1: campaign -> channel
  SELECT CHANNEL, COUNT(*) AS CAMPAIGNS
  FROM DIM_CAMPAIGN
  GROUP BY CHANNEL
),
spend_by_channel AS (             -- CTE 2, the spend side: campaign x day -> channel
  SELECT CHANNEL, SUM(SPEND) AS SPEND
  FROM FCT_DAILY_SPEND
  GROUP BY CHANNEL
),
revenue_by_channel AS (           -- CTE 3, the revenue side: lead -> channel
  SELECT CHANNEL, COUNT(*) AS LEADS, SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL
),
channel_grain AS (                -- one row per channel on every side: 1:1 joins, nothing repeated
  SELECT c.CHANNEL, c.CAMPAIGNS,
         COALESCE(s.SPEND, 0)     AS SPEND,
         COALESCE(r.LEADS, 0)     AS LEADS,
         COALESCE(r.PURCHASES, 0) AS PURCHASES,
         COALESCE(r.REVENUE, 0)   AS REVENUE
  FROM campaigns_by_channel c
  LEFT JOIN spend_by_channel   s ON s.CHANNEL = c.CHANNEL
  LEFT JOIN revenue_by_channel r ON r.CHANNEL = c.CHANNEL
)
SELECT CHANNEL, CAMPAIGNS, SPEND, LEADS, PURCHASES, REVENUE,
       ROUND(REVENUE::NUMBER(32,18)   / NULLIF(SPEND, 0), 6)                  AS ROAS,
       RANK() OVER (ORDER BY REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0) DESC NULLS LAST) AS ROAS_RANK,
       ROUND(SPEND::NUMBER(32,18)     / NULLIF(LEADS, 0), 4)                  AS COST_PER_LEAD,
       ROUND(PURCHASES::NUMBER(32,18) / NULLIF(LEADS, 0), 6)                  AS PURCHASE_RATE,
       ROUND(REVENUE::NUMBER(32,18)   / NULLIF(PURCHASES, 0), 2)              AS REVENUE_PER_PURCHASE,
       ROUND(SPEND::NUMBER(32,18)     / NULLIF(PURCHASES, 0), 4)              AS COST_PER_PURCHASE
FROM channel_grain
ORDER BY ROAS_RANK;

-- 1c. Check of block 1: 5 channels equal [PUB] (spend, revenue), [P3] (ROAS, cost per lead,
--     purchase rate, cost per purchase) and [D] (all columns); the printed rows add up to [KT].
WITH printed_1 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, CAMPAIGNS, SPEND, LEADS, PURCHASES, REVENUE, ROAS, ROAS_RANK, COST_PER_LEAD, PURCHASE_RATE,
          REVENUE_PER_PURCHASE, COST_PER_PURCHASE) AS (
  SELECT * FROM VALUES
    ('affiliate',   24, 857835.07, 67849, 4332, 5610700.73, 6.540536, 1, 12.6433, 0.063848, 1295.18, 198.0229),
    ('paid_search', 24, 897091.53, 65268, 4204, 5439329.35, 6.063294, 2, 13.7447, 0.064411, 1293.85, 213.3900),
    ('paid_social', 24, 984731.88, 57619, 3646, 4690137.28, 4.762857, 3, 17.0904, 0.063278, 1286.38, 270.0855),
    ('display',     24, 955297.00, 45149, 2871, 3734117.43, 3.908855, 4, 21.1588, 0.063589, 1300.63, 332.7402),
    ('video',       24, 828094.54, 25799, 1638, 2087554.22, 2.520913, 5, 32.0979, 0.063491, 1274.45, 505.5522)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) AS ROW_KEY,
         p.CAMPAIGNS = e.CAMPAIGNS AND p.SPEND = e.SPEND AND p.LEADS = e.LEADS AND p.PURCHASES = e.PURCHASES
         AND p.REVENUE = e.REVENUE AND p.ROAS = e.ROAS AND p.ROAS_RANK = e.ROAS_RANK AND p.COST_PER_LEAD = e.COST_PER_LEAD
         AND p.PURCHASE_RATE = e.PURCHASE_RATE AND p.REVENUE_PER_PURCHASE = e.REVENUE_PER_PURCHASE
         AND p.COST_PER_PURCHASE = e.COST_PER_PURCHASE AS IS_EQUAL
  FROM printed_1 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_1)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (12 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(CAMPAIGNS) [KT]', (SELECT SUM(CAMPAIGNS) FROM printed_1), 120, ''
  UNION ALL SELECT 4, 'SUM(SPEND) [KT]',     (SELECT SUM(SPEND) FROM printed_1), 4523050.02, ''
  UNION ALL SELECT 5, 'SUM(LEADS) [KT]',     (SELECT SUM(LEADS) FROM printed_1), 261684, ''
  UNION ALL SELECT 6, 'SUM(PURCHASES) [KT]', (SELECT SUM(PURCHASES) FROM printed_1), 16691, ''
  UNION ALL SELECT 7, 'SUM(REVENUE) [KT]',   (SELECT SUM(REVENUE) FROM printed_1), 21561839.01, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 2. What drives the channel ROAS gap: the spread of each factor across the five channels
--    BUSINESS QUESTION  Do the best channels win on cheaper leads, better-converting leads or
--      bigger purchases?
--    METHOD  The three factors of block 1 and ROAS itself, computed to 18 dp from the
--      channel bases of MART_CHANNEL_PERFORMANCE, turned into one row per channel x factor with
--      UNPIVOT, then per factor: MIN_BY / MAX_BY name the channel at each end, and
--      MAX_OVER_MIN = MAX / MIN is the spread. Values at 6 dp, the spread at 3 dp.
--    HOW TO READ  ROAS varies 2.595x across channels (video 2.520913 to affiliate 6.540536) and
--      cost per lead 2.539x (affiliate 12.643297 to video 32.097932), while the purchase rate
--      varies only 1.018x and revenue per purchase 1.021x. Because ROAS = purchase rate x
--      revenue per purchase / cost per lead, the channel ranking is almost entirely a
--      cost-per-lead ranking: the channels differ in what a lead costs, not in what a lead is
--      worth.
--    CAVEATS  Aggregate funnel ratios (G2): purchases / leads counts converted leads of the
--      channel, not a person's path. Near-identical conversion and revenue per purchase in every
--      channel is a property of the synthetic generator (G6), not evidence that real channels
--      bring equally valuable leads.
-- -----------------------------------------------------------------------------
WITH channel_factors AS (         -- exact factors per channel (18 dp; the one rounding is below)
  SELECT CHANNEL,
         (REVENUE::NUMBER(32,18)   / NULLIF(SPEND, 0))::NUMBER(38,18)     AS ROAS,
         (SPEND::NUMBER(32,18)     / NULLIF(LEADS, 0))::NUMBER(38,18)     AS COST_PER_LEAD,
         (PURCHASES::NUMBER(32,18) / NULLIF(LEADS, 0))::NUMBER(38,18)     AS PURCHASE_RATE,
         (REVENUE::NUMBER(32,18)   / NULLIF(PURCHASES, 0))::NUMBER(38,18) AS REVENUE_PER_PURCHASE
  FROM MART_CHANNEL_PERFORMANCE
),
factor_values AS (                -- one row per channel x factor
  SELECT CHANNEL, FACTOR, FACTOR_VALUE
  FROM channel_factors
  UNPIVOT (FACTOR_VALUE FOR FACTOR IN (ROAS, COST_PER_LEAD, PURCHASE_RATE, REVENUE_PER_PURCHASE))
)
SELECT FACTOR,
       MIN_BY(CHANNEL, FACTOR_VALUE)                                         AS CHANNEL_AT_MIN,
       ROUND(MIN(FACTOR_VALUE), 6)                                           AS MIN_VALUE,
       MAX_BY(CHANNEL, FACTOR_VALUE)                                         AS CHANNEL_AT_MAX,
       ROUND(MAX(FACTOR_VALUE), 6)                                           AS MAX_VALUE,
       ROUND(MAX(FACTOR_VALUE)::NUMBER(32,18) / NULLIF(MIN(FACTOR_VALUE), 0), 3) AS MAX_OVER_MIN
FROM factor_values
GROUP BY FACTOR
ORDER BY DECODE(FACTOR, 'ROAS', 1, 'COST_PER_LEAD', 2, 'PURCHASE_RATE', 3, 4);

-- 2c. Check of block 2: the 4 factors equal [D].
WITH printed_2 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (FACTOR, CHANNEL_AT_MIN, MIN_VALUE, CHANNEL_AT_MAX, MAX_VALUE, MAX_OVER_MIN) AS (
  SELECT * FROM VALUES
    ('ROAS',                 'video',       2.520913,    'affiliate',   6.540536,    2.595),
    ('COST_PER_LEAD',        'affiliate',   12.643297,   'video',       32.097932,   2.539),
    ('PURCHASE_RATE',        'paid_social', 0.063278,    'paid_search', 0.064411,    1.018),
    ('REVENUE_PER_PURCHASE', 'video',       1274.453126, 'display',     1300.633030, 1.021)
),
compared AS (
  SELECT COALESCE(p.FACTOR, e.FACTOR) AS ROW_KEY,
         p.CHANNEL_AT_MIN = e.CHANNEL_AT_MIN AND p.MIN_VALUE = e.MIN_VALUE AND p.CHANNEL_AT_MAX = e.CHANNEL_AT_MAX
         AND p.MAX_VALUE = e.MAX_VALUE AND p.MAX_OVER_MIN = e.MAX_OVER_MIN AS IS_EQUAL
  FROM printed_2 p
  FULL OUTER JOIN expected e ON e.FACTOR = p.FACTOR
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_2)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (6 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 3. ROAS by objective within channel
--    BUSINESS QUESTION  Does the campaign objective (acquisition, awareness, lead_gen) change
--      ROAS once the channel is held fixed?
--    METHOD  The block 1 pattern at channel x objective grain: campaign, spend and revenue
--      CTEs, each aggregated to the cell on its own, joined 1:1. Window aggregates then put
--      three views on one row: RANK() OVER (PARTITION BY CHANNEL) ranks the objectives inside
--      their channel; SUM(REVENUE) OVER (PARTITION BY CHANNEL) / SUM(SPEND) OVER (PARTITION BY
--      CHANNEL) is the channel ROAS, and the same with PARTITION BY OBJECTIVE is the objective
--      ROAS pooled over all channels (both ratios of sums).
--    HOW TO READ  Pooled over channels, acquisition (5.138426) beats awareness (4.776849) and
--      lead_gen (4.491290). Within a channel the order is not consistent: acquisition ranks
--      first in affiliate, paid_search and video, awareness in display, lead_gen in paid_social
--      (6.173294 vs 3.668935 for its acquisition campaigns). The channel matters more than the
--      objective: every objective of affiliate (lowest 4.918439) and paid_search (lowest
--      5.591099) beats every objective of display (highest 4.021415) and video (highest
--      2.626224).
--    CAVEATS  Small cells: 3 to 17 campaigns, e.g. 3 display acquisition campaigns, 4 video
--      lead_gen. Channel and objective are partly confounded (display holds 17 of the 41
--      lead_gen campaigns), so the pooled objective ROAS partly re-measures the channel mix.
--      Last-touch; synthetic.
-- -----------------------------------------------------------------------------
WITH campaigns_by_cell AS (       -- campaign -> channel x objective
  SELECT CHANNEL, OBJECTIVE, COUNT(*) AS CAMPAIGNS
  FROM DIM_CAMPAIGN
  GROUP BY CHANNEL, OBJECTIVE
),
spend_by_cell AS (                -- spend side
  SELECT CHANNEL, OBJECTIVE, SUM(SPEND) AS SPEND
  FROM FCT_DAILY_SPEND
  GROUP BY CHANNEL, OBJECTIVE
),
revenue_by_cell AS (              -- revenue side
  SELECT CHANNEL, OBJECTIVE, SUM(REVENUE) AS REVENUE
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL, OBJECTIVE
),
cell_grain AS (                   -- 1:1 joins at channel x objective
  SELECT c.CHANNEL, c.OBJECTIVE, c.CAMPAIGNS,
         COALESCE(s.SPEND, 0)   AS SPEND,
         COALESCE(r.REVENUE, 0) AS REVENUE
  FROM campaigns_by_cell c
  LEFT JOIN spend_by_cell   s ON s.CHANNEL = c.CHANNEL AND s.OBJECTIVE = c.OBJECTIVE
  LEFT JOIN revenue_by_cell r ON r.CHANNEL = c.CHANNEL AND r.OBJECTIVE = c.OBJECTIVE
)
SELECT CHANNEL, OBJECTIVE, CAMPAIGNS, SPEND, REVENUE,
       ROUND(REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0), 6)                                         AS ROAS,
       RANK() OVER (PARTITION BY CHANNEL
                    ORDER BY REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0) DESC NULLS LAST)                   AS ROAS_RANK_IN_CHANNEL,
       ROUND(SUM(REVENUE) OVER (PARTITION BY CHANNEL)::NUMBER(32,18)
             / NULLIF(SUM(SPEND) OVER (PARTITION BY CHANNEL), 0), 6)                              AS CHANNEL_ROAS,
       ROUND(SUM(REVENUE) OVER (PARTITION BY OBJECTIVE)::NUMBER(32,18)
             / NULLIF(SUM(SPEND) OVER (PARTITION BY OBJECTIVE), 0), 6)                            AS OBJECTIVE_ROAS_ALL_CHANNELS
FROM cell_grain
ORDER BY CHANNEL_ROAS DESC NULLS LAST, ROAS_RANK_IN_CHANNEL;

-- 3c. Check of block 3: 15 cells equal [D]; they add up to [KT].
WITH printed_3 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, OBJECTIVE, CAMPAIGNS, SPEND, REVENUE, ROAS, ROAS_RANK_IN_CHANNEL, CHANNEL_ROAS, OBJECTIVE_ROAS_ALL_CHANNELS) AS (
  SELECT * FROM VALUES
    ('affiliate',   'acquisition',  8, 266566.50, 2020489.36, 7.579682, 1, 6.540536, 5.138426),
    ('affiliate',   'awareness',   11, 356332.26, 2434691.40, 6.832644, 2, 6.540536, 4.776849),
    ('affiliate',   'lead_gen',     5, 234936.31, 1155519.97, 4.918439, 3, 6.540536, 4.491290),
    ('paid_search', 'acquisition',  9, 342535.00, 2229025.00, 6.507437, 1, 6.063294, 5.138426),
    ('paid_search', 'awareness',    7, 252858.06, 1523478.38, 6.025034, 2, 6.063294, 4.776849),
    ('paid_search', 'lead_gen',     8, 301698.47, 1686825.97, 5.591099, 3, 6.063294, 4.491290),
    ('paid_social', 'lead_gen',     7, 247216.30, 1526138.82, 6.173294, 1, 4.762857, 4.491290),
    ('paid_social', 'awareness',   10, 445827.81, 2093815.01, 4.696466, 2, 4.762857, 4.776849),
    ('paid_social', 'acquisition',  7, 291687.77, 1070183.45, 3.668935, 3, 4.762857, 5.138426),
    ('display',     'awareness',    4, 228529.10,  919010.44, 4.021415, 1, 3.908855, 4.776849),
    ('display',     'lead_gen',    17, 664339.11, 2598298.33, 3.911102, 2, 3.908855, 4.491290),
    ('display',     'acquisition',  3,  62428.79,  216808.66, 3.472895, 3, 3.908855, 5.138426),
    ('video',       'acquisition',  8, 233692.27,  613728.26, 2.626224, 1, 2.520913, 5.138426),
    ('video',       'awareness',   12, 372666.30,  940487.05, 2.523671, 2, 2.520913, 4.776849),
    ('video',       'lead_gen',     4, 221735.97,  533338.91, 2.405288, 3, 2.520913, 4.491290)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) || ' / ' || COALESCE(p.OBJECTIVE, e.OBJECTIVE) AS ROW_KEY,
         p.CAMPAIGNS = e.CAMPAIGNS AND p.SPEND = e.SPEND AND p.REVENUE = e.REVENUE AND p.ROAS = e.ROAS
         AND p.ROAS_RANK_IN_CHANNEL = e.ROAS_RANK_IN_CHANNEL AND p.CHANNEL_ROAS = e.CHANNEL_ROAS
         AND p.OBJECTIVE_ROAS_ALL_CHANNELS = e.OBJECTIVE_ROAS_ALL_CHANNELS AS IS_EQUAL
  FROM printed_3 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL AND e.OBJECTIVE = p.OBJECTIVE
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_3)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (9 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(CAMPAIGNS) [KT]', (SELECT SUM(CAMPAIGNS) FROM printed_3), 120, ''
  UNION ALL SELECT 4, 'SUM(SPEND) [KT]',     (SELECT SUM(SPEND) FROM printed_3), 4523050.02, ''
  UNION ALL SELECT 5, 'SUM(REVENUE) [KT]',   (SELECT SUM(REVENUE) FROM printed_3), 21561839.01, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4. ROAS by channel x year: activity basis and acquisition-year basis side by side
--    BUSINESS QUESTION  Is the channel ranking of block 1 stable over time, or driven by one
--      year? And did the return on a channel's spend change against the prior year?
--    METHOD  Three CTEs, each aggregated to channel x calendar year on its own, and a 5 x 3
--      spine of channels x years (two dimensions, not facts) that takes all three with 1:1
--      LEFT JOINs (G1):
--        spend by SPEND_DATE, with ACTIVE_CAMPAIGNS = campaigns with a flight day in the
--          year (G7);
--        ACTIVITY basis: revenue BOOKED by CONVERTED_DATE, and the part of it that comes from
--          leads created in the prior year (REVENUE_FROM_PRIOR_YEAR_LEADS);
--        ACQUISITION-YEAR basis: the revenue of the leads CREATED in the year, whenever it was
--          booked, i.e. the later last-touch return of the year's spend (block 16 does the
--          same per campaign-day).
--      RANK() OVER (PARTITION BY YEAR) ranks the channels within each year by activity ROAS;
--      SUM(SPEND) OVER (PARTITION BY YEAR) gives the channel's share of the year's spend;
--      LAG() OVER (PARTITION BY CHANNEL ORDER BY YEAR) gives the change of the
--      ACQUISITION-YEAR ROAS against the prior year, taken from the unrounded ratios and
--      rounded once.
--      Why the change is not taken on the activity basis: at the data edges that basis is
--      lopsided. 2023 receives no revenue from earlier leads (there are none) but passes
--      263,127.73 of its leads' revenue on to 2024; 2025 receives 340,831.37 from 2024's leads
--      and passes nothing on (the last lead was created 2025-12-02, the last conversion was
--      booked 2025-12-21). So an activity-basis change between two years is partly
--      carry-over across the year boundary, not a change in performance.
--    HOW TO READ  Ranks 3 to 5 are the same in every year: paid_social, display, video. The top
--      two swap once: affiliate leads in 2023 (6.692512) and 2024 (6.023310), paid_search in
--      2025 (7.306610 vs 7.180052). The acquisition-year column gives the same order in every
--      year (2025: paid_search 7.012011, affiliate 6.838595). On the activity basis display
--      stays between 3.848074 and 3.978249, video between 2.417133 and 2.581932.
--      The two bases part most on the change between years. Every 2023 activity value is below
--      its acquisition-year value (affiliate 6.692512 vs 7.114730), because 2023 gets no
--      carry-in. paid_social's activity ROAS rises from 4.273831 in 2024 to 5.247262 in 2025,
--      but 139,172.12 of its 2025 booked revenue came from 2024 leads; on the acquisition-year
--      basis it is flat (4.585577 -> 4.554426, change -0.031151). display's 2024 change flips
--      sign: activity 3.848074 -> 3.908208, acquisition-year 4.044786 -> 3.804136 (-0.240650).
--      On the acquisition-year basis every channel except video (+0.005426) returns less in
--      2024 than in 2023, and affiliate and paid_search return more in 2025 (+0.783601 and
--      +1.620833; paid_search's 2025 comes from only 5 campaigns).
--    CAVEATS  ROAS_ACTIVITY is revenue BOOKED in the year over spend in the year: not the
--      return of that year's spend, and its change between years is not a performance trend.
--      ROAS_ACQUISITION_YEAR assumes every lead's outcome is in the data: the check below finds
--      no lead created after 2025-12-10, so with the longest observed lag of 21 days every
--      lead's window closes inside the range (the coverage assumption of AS_OF_DATE,
--      docs/data_dictionary.md). The two ROAS columns answer different questions: one per
--      chart axis, labelled with its basis. Read every year next to its active campaigns (G7):
--      2025 has 35, paid_search only 5 of them. Last-touch; synthetic.
-- -----------------------------------------------------------------------------
WITH channels AS (                -- the 5 channels
  SELECT DISTINCT CHANNEL FROM DIM_CAMPAIGN
),
years AS (                        -- 2023, 2024, 2025
  SELECT DISTINCT YEAR FROM DIM_DATE
),
spend_by_year AS (                -- spend side: by spend date; a spend row exists on every flight day
  SELECT CHANNEL, YEAR(SPEND_DATE) AS YEAR,
         COUNT(DISTINCT CAMPAIGN_ID) AS ACTIVE_CAMPAIGNS,
         SUM(SPEND)                  AS SPEND
  FROM FCT_DAILY_SPEND
  GROUP BY CHANNEL, YEAR(SPEND_DATE)
),
booked_by_year AS (               -- ACTIVITY basis: revenue booked by converted date, and its carry-in
  SELECT CHANNEL, YEAR(CONVERTED_DATE) AS YEAR,
         SUM(REVENUE)                                                    AS REVENUE_BOOKED,
         SUM(IFF(YEAR(CREATED_DATE) < YEAR(CONVERTED_DATE), REVENUE, 0)) AS REVENUE_FROM_PRIOR_YEAR_LEADS
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
  GROUP BY CHANNEL, YEAR(CONVERTED_DATE)
),
revenue_by_lead_year AS (         -- ACQUISITION-YEAR basis: revenue of the leads created in the year, whenever booked
  SELECT CHANNEL, YEAR(CREATED_DATE) AS YEAR, SUM(REVENUE) AS REVENUE_OF_YEAR_LEADS
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL, YEAR(CREATED_DATE)
),
channel_year AS (                 -- spine x three sides, 1:1; the ratios stay unrounded here
  SELECT ch.CHANNEL, y.YEAR,
         COALESCE(s.ACTIVE_CAMPAIGNS, 0)              AS ACTIVE_CAMPAIGNS,
         COALESCE(s.SPEND, 0)                         AS SPEND,
         COALESCE(b.REVENUE_BOOKED, 0)                AS REVENUE_BOOKED,
         COALESCE(b.REVENUE_FROM_PRIOR_YEAR_LEADS, 0) AS REVENUE_FROM_PRIOR_YEAR_LEADS,
         COALESCE(l.REVENUE_OF_YEAR_LEADS, 0)         AS REVENUE_OF_YEAR_LEADS,
         COALESCE(b.REVENUE_BOOKED, 0)::NUMBER(32,18)        / NULLIF(s.SPEND, 0) AS ROAS_ACTIVITY_EXACT,
         COALESCE(l.REVENUE_OF_YEAR_LEADS, 0)::NUMBER(32,18) / NULLIF(s.SPEND, 0) AS ROAS_ACQUISITION_EXACT
  FROM channels ch
  CROSS JOIN years y
  LEFT JOIN spend_by_year        s ON s.CHANNEL = ch.CHANNEL AND s.YEAR = y.YEAR
  LEFT JOIN booked_by_year       b ON b.CHANNEL = ch.CHANNEL AND b.YEAR = y.YEAR
  LEFT JOIN revenue_by_lead_year l ON l.CHANNEL = ch.CHANNEL AND l.YEAR = y.YEAR
)
SELECT YEAR, CHANNEL, ACTIVE_CAMPAIGNS, SPEND,
       ROUND(SPEND::NUMBER(32,18) / NULLIF(SUM(SPEND) OVER (PARTITION BY YEAR), 0), 6)       AS SPEND_SHARE_IN_YEAR,
       REVENUE_BOOKED, REVENUE_FROM_PRIOR_YEAR_LEADS,
       ROUND(ROAS_ACTIVITY_EXACT, 6)                                                          AS ROAS_ACTIVITY,
       RANK() OVER (PARTITION BY YEAR ORDER BY ROAS_ACTIVITY_EXACT DESC NULLS LAST)          AS ROAS_RANK_IN_YEAR,
       REVENUE_OF_YEAR_LEADS,
       ROUND(ROAS_ACQUISITION_EXACT, 6)                                                       AS ROAS_ACQUISITION_YEAR,
       ROUND(ROAS_ACQUISITION_EXACT
             - LAG(ROAS_ACQUISITION_EXACT) OVER (PARTITION BY CHANNEL ORDER BY YEAR), 6)     AS ROAS_ACQ_CHANGE_VS_PRIOR_YEAR
FROM channel_year
ORDER BY YEAR, ROAS_RANK_IN_YEAR;

-- 4c. Check of block 4: 15 channel-years equal [D]; each year adds up to [E02c 18] (spend,
--     revenue booked, active campaigns: 48 / 60 / 35) and to [D] (revenue from prior-year
--     leads, revenue of the year's leads); both revenue columns add up to [KT]; no lead was
--     created after 2025-12-10 and the longest lag is 21 days [D], so every lead's window
--     closes inside the range.
WITH printed_4 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (YEAR, CHANNEL, ACTIVE_CAMPAIGNS, SPEND, SPEND_SHARE_IN_YEAR, REVENUE_BOOKED, REVENUE_FROM_PRIOR_YEAR_LEADS, ROAS_ACTIVITY,
          ROAS_RANK_IN_YEAR, REVENUE_OF_YEAR_LEADS, ROAS_ACQUISITION_YEAR, ROAS_ACQ_CHANGE_VS_PRIOR_YEAR) AS (
  SELECT * FROM VALUES
    (2023, 'affiliate',    7, 191203.31, 0.131117, 1279630.45,      0.00, 6.692512, 1, 1360359.91, 7.114730,      NULL),
    (2023, 'paid_search', 10, 300163.09, 0.205836, 1896544.12,      0.00, 6.318379, 2, 1962597.64, 6.538438,      NULL),
    (2023, 'paid_social', 10, 396556.03, 0.271937, 1980837.05,      0.00, 4.995100, 3, 1999269.18, 5.041581,      NULL),
    (2023, 'display',     13, 375255.15, 0.257330, 1444009.62,      0.00, 3.848074, 4, 1517826.65, 4.044786,      NULL),
    (2023, 'video',        8, 195084.83, 0.133779,  474461.11,      0.00, 2.432076, 5,  498556.70, 2.555589,      NULL),
    (2024, 'affiliate',   14, 393675.01, 0.199714, 2371226.62,  80729.46, 6.023310, 1, 2383700.05, 6.054995, -1.059735),
    (2024, 'paid_search', 14, 437390.55, 0.221891, 2377104.14,  66053.52, 5.434741, 2, 2358050.28, 5.391178, -1.147260),
    (2024, 'paid_social', 11, 387302.85, 0.196481, 1655266.92,  18432.13, 4.273831, 3, 1776006.91, 4.585577, -0.456004),
    (2024, 'display',      9, 249038.96, 0.126339,  973295.94,  73817.03, 3.908208, 4,  947377.96, 3.804136, -0.240650),
    (2024, 'video',       12, 503790.97, 0.255576, 1300754.20,  24095.59, 2.581932, 5, 1290216.26, 2.561015,  0.005426),
    (2025, 'paid_search',  5, 159537.89, 0.145885, 1165681.09,  46999.66, 7.306610, 1, 1118681.43, 7.012011,  1.620833),
    (2025, 'affiliate',    8, 272956.75, 0.249597, 1959843.66,  93202.89, 7.180052, 2, 1866640.77, 6.838595,  0.783601),
    (2025, 'paid_social',  6, 200873.00, 0.183682, 1054033.31, 139172.12, 5.247262, 3,  914861.19, 4.554426, -0.031151),
    (2025, 'display',      8, 331002.89, 0.302676, 1316811.87,  47899.05, 3.978249, 4, 1268912.82, 3.833540,  0.029404),
    (2025, 'video',        8, 129218.74, 0.118160,  312338.91,  13557.65, 2.417133, 5,  298781.26, 2.312213, -0.248802)
),
expected_years (YEAR, SPEND, REVENUE_BOOKED, ACTIVE_CAMPAIGNS, REVENUE_FROM_PRIOR_YEAR_LEADS, REVENUE_OF_YEAR_LEADS) AS (
  SELECT * FROM VALUES                                    -- [E02c 18] for the first three, [D] for the last two
    (2023, 1458262.41, 7075482.35, 48,      0.00, 7338610.08),
    (2024, 1971198.34, 8677647.82, 60, 263127.73, 8755351.46),
    (2025, 1093589.27, 5808708.84, 35, 340831.37, 5467877.47)
),
compared AS (
  SELECT COALESCE(p.YEAR, e.YEAR) || ' ' || COALESCE(p.CHANNEL, e.CHANNEL) AS ROW_KEY,
         p.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND p.SPEND = e.SPEND AND p.SPEND_SHARE_IN_YEAR = e.SPEND_SHARE_IN_YEAR
         AND p.REVENUE_BOOKED = e.REVENUE_BOOKED AND p.REVENUE_FROM_PRIOR_YEAR_LEADS = e.REVENUE_FROM_PRIOR_YEAR_LEADS
         AND p.ROAS_ACTIVITY = e.ROAS_ACTIVITY AND p.ROAS_RANK_IN_YEAR = e.ROAS_RANK_IN_YEAR
         AND p.REVENUE_OF_YEAR_LEADS = e.REVENUE_OF_YEAR_LEADS AND p.ROAS_ACQUISITION_YEAR = e.ROAS_ACQUISITION_YEAR
         AND EQUAL_NULL(p.ROAS_ACQ_CHANGE_VS_PRIOR_YEAR, e.ROAS_ACQ_CHANGE_VS_PRIOR_YEAR) AS IS_EQUAL
  FROM printed_4 p
  FULL OUTER JOIN expected e ON e.YEAR = p.YEAR AND e.CHANNEL = p.CHANNEL
),
compared_years AS (
  SELECT TO_VARCHAR(COALESCE(p.YEAR, e.YEAR)) AS ROW_KEY,
         p.SPEND = e.SPEND AND p.REVENUE_BOOKED = e.REVENUE_BOOKED AND p.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS
         AND p.REVENUE_FROM_PRIOR_YEAR_LEADS = e.REVENUE_FROM_PRIOR_YEAR_LEADS
         AND p.REVENUE_OF_YEAR_LEADS = e.REVENUE_OF_YEAR_LEADS AS IS_EQUAL
  FROM (SELECT YEAR, SUM(SPEND) AS SPEND, SUM(REVENUE_BOOKED) AS REVENUE_BOOKED, SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS,
               SUM(REVENUE_FROM_PRIOR_YEAR_LEADS) AS REVENUE_FROM_PRIOR_YEAR_LEADS, SUM(REVENUE_OF_YEAR_LEADS) AS REVENUE_OF_YEAR_LEADS
        FROM printed_4 GROUP BY YEAR) p
  FULL OUTER JOIN expected_years e ON e.YEAR = p.YEAR
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_4)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (12 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'years add up to [E02c 18], [D] (5 sums)', COUNT_IF(IS_EQUAL),
                   (SELECT COUNT(*) FROM expected_years),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared_years
  UNION ALL SELECT 4, 'SUM(SPEND) [KT]',                 (SELECT SUM(SPEND) FROM printed_4), 4523050.02, ''
  UNION ALL SELECT 5, 'SUM(REVENUE_BOOKED) [KT]',        (SELECT SUM(REVENUE_BOOKED) FROM printed_4), 21561839.01, ''
  UNION ALL SELECT 6, 'SUM(REVENUE_OF_YEAR_LEADS) [KT]', (SELECT SUM(REVENUE_OF_YEAR_LEADS) FROM printed_4), 21561839.01, ''
  UNION ALL SELECT 7, 'leads created after 2025-12-10 [D]',
                   (SELECT COUNT_IF(CREATED_DATE > '2025-12-10'::DATE) FROM FCT_LEAD_CONVERSIONS), 0, ''
  UNION ALL SELECT 8, 'MAX(DAYS_TO_CONVERT) [D]',
                   (SELECT MAX(DAYS_TO_CONVERT) FROM FCT_LEAD_CONVERSIONS), 21, ''
)
ORDER BY ORD;


-- =============================================================================
-- PART B. Analysis #8, Campaign Performance Ranking (RANK, DENSE_RANK)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5. The 10 best and the 10 worst campaigns by ROAS, overall and within their channel
--    BUSINESS QUESTION  BQ6: which campaigns have the highest ROAS, and is a campaign good for
--      its channel or only in a good channel?
--    METHOD  MART_CAMPAIGN_PERFORMANCE is one row per campaign, so its ROAS column (REVENUE /
--      SPEND of the campaign, 6 dp) is valid here. RANK() and DENSE_RANK() OVER (ORDER BY ROAS
--      DESC) rank all 120 campaigns; RANK() OVER (PARTITION BY CHANNEL ORDER BY ROAS DESC)
--      ranks each campaign among the 24 of its channel. QUALIFY keeps the 10 best and, with a
--      second ascending RANK, the 10 worst, without a subquery.
--    HOW TO READ  9 of the 10 best campaigns are affiliate (CMP0080 first at 13.013216); the
--      tenth is CMP0086, the best paid_search campaign (10.849844). 9 of the 10 worst are video
--      (CMP0084 last at 1.823364); the other is display's worst, CMP0018 (2.174672). The
--      overall ranking largely restates the channel ranking, so a campaign manager should read
--      ROAS_RANK_IN_CHANNEL (block 6).
--      RANK and DENSE_RANK agree on every row: at 6 dp the 120 ROAS values are all distinct,
--      so there are no ties to treat differently (block 8 shows ties).
--    CAVEATS  Last-touch attributed revenue (G4). Small campaigns have noisy ratios: CMP0084
--      has 7 purchases, CMP0018 11. Synthetic.
-- -----------------------------------------------------------------------------
SELECT RANK()       OVER (ORDER BY ROAS DESC)                      AS ROAS_RANK,
       DENSE_RANK() OVER (ORDER BY ROAS DESC)                      AS ROAS_DENSE_RANK,
       RANK()       OVER (PARTITION BY CHANNEL ORDER BY ROAS DESC) AS ROAS_RANK_IN_CHANNEL,
       CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, SPEND, PURCHASES, REVENUE, ROAS, COST_PER_PURCHASE
FROM MART_CAMPAIGN_PERFORMANCE
QUALIFY ROAS_RANK <= 10                                  -- the 10 best
     OR RANK() OVER (ORDER BY ROAS ASC) <= 10            -- the 10 worst
ORDER BY ROAS_RANK;

-- 5c. Check of block 5: rank, campaign and ROAS of all 20 rows equal [P3] (campaign_top10_roas,
--     campaign_bottom10_roas); dense rank, rank in channel, purchases and cost per purchase
--     equal [D]; the 120 stored ROAS values are distinct [D]; 9 affiliate in the top 10 and 9
--     video in the bottom 10 [D].
WITH printed_5 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (ROAS_RANK, ROAS_DENSE_RANK, ROAS_RANK_IN_CHANNEL, CAMPAIGN_ID, CHANNEL, PURCHASES, ROAS, COST_PER_PURCHASE) AS (
  SELECT * FROM VALUES
    (  1,   1,  1, 'CMP0080', 'affiliate',   172, 13.013216, 104.0941),
    (  2,   2,  2, 'CMP0070', 'affiliate',   167, 12.609300, 103.7036),
    (  3,   3,  3, 'CMP0040', 'affiliate',   146, 12.274784, 102.1979),
    (  4,   4,  4, 'CMP0035', 'affiliate',   142, 12.007766, 112.0658),
    (  5,   5,  5, 'CMP0045', 'affiliate',    88, 11.390125, 119.8150),
    (  6,   6,  6, 'CMP0095', 'affiliate',   166, 11.375832, 107.7210),
    (  7,   7,  7, 'CMP0005', 'affiliate',   143, 11.133811, 119.2829),
    (  8,   8,  8, 'CMP0050', 'affiliate',   299, 11.042774, 117.7906),
    (  9,   9,  9, 'CMP0110', 'affiliate',   257, 10.879181, 118.2267),
    ( 10,  10,  1, 'CMP0086', 'paid_search', 101, 10.849844, 115.7615),
    (111, 111, 16, 'CMP0064', 'video',        94,  2.323173, 587.0103),
    (112, 112, 17, 'CMP0099', 'video',        15,  2.267776, 623.2267),
    (113, 113, 18, 'CMP0079', 'video',       110,  2.213323, 565.7357),
    (114, 114, 19, 'CMP0009', 'video',       102,  2.202279, 537.1239),
    (115, 115, 20, 'CMP0074', 'video',        46,  2.177704, 567.6046),
    (116, 116, 24, 'CMP0018', 'display',      11,  2.174672, 673.1845),
    (117, 117, 21, 'CMP0119', 'video',        30,  2.173423, 560.8487),
    (118, 118, 22, 'CMP0039', 'video',        39,  2.131284, 617.0990),
    (119, 119, 23, 'CMP0034', 'video',        57,  1.978327, 599.6495),
    (120, 120, 24, 'CMP0084', 'video',         7,  1.823364, 872.1900)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.ROAS_RANK, e.ROAS_RANK)) AS ROW_KEY,
         p.CAMPAIGN_ID = e.CAMPAIGN_ID AND p.ROAS = e.ROAS AND p.ROAS_DENSE_RANK = e.ROAS_DENSE_RANK
         AND p.ROAS_RANK_IN_CHANNEL = e.ROAS_RANK_IN_CHANNEL AND p.CHANNEL = e.CHANNEL AND p.PURCHASES = e.PURCHASES
         AND p.COST_PER_PURCHASE = e.COST_PER_PURCHASE AS IS_EQUAL
  FROM printed_5 p
  FULL OUTER JOIN expected e ON e.ROAS_RANK = p.ROAS_RANK
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_5)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'ranks equal to expected (8 columns)', COUNT_IF(IS_EQUAL),
                   (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'distinct ROAS values (RANK = DENSE_RANK)',
                   (SELECT COUNT(DISTINCT ROAS) FROM MART_CAMPAIGN_PERFORMANCE), 120, ''
  UNION ALL SELECT 4, 'affiliate campaigns in the top 10',
                   (SELECT COUNT_IF(CHANNEL = 'affiliate') FROM printed_5 WHERE ROAS_RANK <= 10), 9, ''
  UNION ALL SELECT 5, 'video campaigns in the bottom 10',
                   (SELECT COUNT_IF(CHANNEL = 'video') FROM printed_5 WHERE ROAS_RANK > 110), 9, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6. The best and the worst campaign of each channel
--    BUSINESS QUESTION  How far apart are campaigns inside one channel, and do the channel
--      ranges overlap?
--    METHOD  Window functions over all 120 campaigns first, then a filter: RANK() OVER
--      (PARTITION BY CHANNEL ORDER BY ROAS DESC) = 1 is the best of the channel and the
--      ascending rank = 1 the worst; RANK() OVER (ORDER BY ROAS DESC) is the overall rank;
--      the channel ROAS is SUM(REVENUE) OVER (PARTITION BY CHANNEL) / SUM(SPEND) OVER
--      (PARTITION BY CHANNEL), and BEST_OVER_WORST = MAX(ROAS) / MIN(ROAS) in the channel.
--      The windows run before the WHERE, so the ranks and channel totals cover all campaigns.
--    HOW TO READ  Inside affiliate the best campaign returns 4.27x the worst (13.013216 vs
--      3.046811), inside paid_search 4.09x, video 1.91x. The ranges overlap: the worst
--      affiliate campaign (CMP0085, rank 92 of 120) returns less than the best video campaign
--      (CMP0054, rank 85) and the best display campaign (CMP0028, rank 51). Channel explains a
--      lot, not everything. In the three channels where returns fall with size (block 15), the
--      best campaign is a small one (11,691.91 to 17,904.18 of spend) and the worst a large one
--      (51,639.87 to 66,691.10). display's best and worst are both small (22 and 11
--      purchases), the noisiest kind of extreme.
--    CAVEATS  Extremes of 24 campaigns are the noisiest points of a distribution. Last-touch;
--      synthetic.
-- -----------------------------------------------------------------------------
WITH ranked AS (
  SELECT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, SPEND, PURCHASES, ROAS,
         RANK() OVER (ORDER BY ROAS DESC)                      AS ROAS_RANK_OVERALL,
         RANK() OVER (PARTITION BY CHANNEL ORDER BY ROAS DESC) AS RANK_BEST_FIRST,
         RANK() OVER (PARTITION BY CHANNEL ORDER BY ROAS ASC)  AS RANK_WORST_FIRST,
         ROUND(SUM(REVENUE) OVER (PARTITION BY CHANNEL)::NUMBER(32,18)
               / NULLIF(SUM(SPEND) OVER (PARTITION BY CHANNEL), 0), 6) AS CHANNEL_ROAS,
         ROUND(MAX(ROAS) OVER (PARTITION BY CHANNEL)::NUMBER(32,18)
               / NULLIF(MIN(ROAS) OVER (PARTITION BY CHANNEL), 0), 2)  AS BEST_OVER_WORST
  FROM MART_CAMPAIGN_PERFORMANCE
)
SELECT CHANNEL, IFF(RANK_BEST_FIRST = 1, 'best', 'worst') AS POSITION_IN_CHANNEL,
       CAMPAIGN_ID, CAMPAIGN_NAME, OBJECTIVE, SPEND, PURCHASES, ROAS, ROAS_RANK_OVERALL, CHANNEL_ROAS, BEST_OVER_WORST
FROM ranked
WHERE RANK_BEST_FIRST = 1 OR RANK_WORST_FIRST = 1
ORDER BY CHANNEL_ROAS DESC, POSITION_IN_CHANNEL;

-- 6c. Check of block 6: 10 rows equal [D].
WITH printed_6 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, POSITION_IN_CHANNEL, CAMPAIGN_ID, ROAS, ROAS_RANK_OVERALL, CHANNEL_ROAS, BEST_OVER_WORST) AS (
  SELECT * FROM VALUES
    ('affiliate',   'best',  'CMP0080', 13.013216,   1, 6.540536, 4.27),
    ('affiliate',   'worst', 'CMP0085',  3.046811,  92, 6.540536, 4.27),
    ('paid_search', 'best',  'CMP0086', 10.849844,  10, 6.063294, 4.09),
    ('paid_search', 'worst', 'CMP0041',  2.650154, 103, 6.063294, 4.09),
    ('paid_social', 'best',  'CMP0017',  6.926556,  27, 4.762857, 2.79),
    ('paid_social', 'worst', 'CMP0067',  2.484971, 106, 4.762857, 2.79),
    ('display',     'best',  'CMP0028',  4.860810,  51, 3.908855, 2.24),
    ('display',     'worst', 'CMP0018',  2.174672, 116, 3.908855, 2.24),
    ('video',       'best',  'CMP0054',  3.486709,  85, 2.520913, 1.91),
    ('video',       'worst', 'CMP0084',  1.823364, 120, 2.520913, 1.91)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) || ' ' || COALESCE(p.POSITION_IN_CHANNEL, e.POSITION_IN_CHANNEL) AS ROW_KEY,
         p.CAMPAIGN_ID = e.CAMPAIGN_ID AND p.ROAS = e.ROAS AND p.ROAS_RANK_OVERALL = e.ROAS_RANK_OVERALL
         AND p.CHANNEL_ROAS = e.CHANNEL_ROAS AND p.BEST_OVER_WORST = e.BEST_OVER_WORST AS IS_EQUAL
  FROM printed_6 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL AND e.POSITION_IN_CHANNEL = p.POSITION_IN_CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_6)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (7 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 7. Cost per purchase: which campaigns acquire customers most cost-efficiently?
--    BUSINESS QUESTION  BQ3. A customer here is a purchase: a trial is a conversion but no
--      revenue (0.00), so cost per purchase = SPEND / PURCHASES is the cost of a paying
--      customer.
--    METHOD  RANK() OVER (ORDER BY COST_PER_PURCHASE ASC), lowest = best, over all 120
--      campaigns, plus the rank inside the channel (PARTITION BY CHANNEL) and the ROAS rank of
--      block 5 for comparison; QUALIFY keeps the 10 cheapest and the 10 most expensive.
--      COST_PER_PURCHASE is the campaign-grain column of MART_CAMPAIGN_PERFORMANCE (4 dp, 120
--      distinct values).
--    HOW TO READ  The cheapest customer comes from CMP0040 (Affiliate 2023 040) at 102.1979 per
--      purchase; 9 of the 10 cheapest are affiliate, plus paid_search's CMP0086 (115.7615).
--      The most expensive are video and one display campaign, up to 872.1900 (CMP0084). At
--      channel grain (block 1) a purchase costs 198.0229 in affiliate and 505.5522 in video.
--      The CPP ranking nearly repeats the ROAS ranking because revenue per purchase is almost
--      the same everywhere (block 2); it is not identical (CMP0040 is CPP rank 1, ROAS rank 3).
--    CAVEATS  Volume: the three most expensive campaigns have 7, 11 and 15 purchases (CMP0084,
--      CMP0018, CMP0099), so one purchase more or less moves their cost a lot; read
--      PURCHASES next to the cost. Last-touch attribution decides which campaign a purchase is
--      credited to. Synthetic.
-- -----------------------------------------------------------------------------
SELECT RANK() OVER (ORDER BY COST_PER_PURCHASE ASC)                      AS CPP_RANK,
       RANK() OVER (PARTITION BY CHANNEL ORDER BY COST_PER_PURCHASE ASC) AS CPP_RANK_IN_CHANNEL,
       CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, SPEND, PURCHASES, COST_PER_PURCHASE,
       RANK() OVER (ORDER BY ROAS DESC)                                  AS ROAS_RANK
FROM MART_CAMPAIGN_PERFORMANCE
QUALIFY CPP_RANK <= 10                                         -- the 10 cheapest customers
     OR RANK() OVER (ORDER BY COST_PER_PURCHASE DESC) <= 10    -- the 10 most expensive
ORDER BY CPP_RANK;

-- 7c. Check of block 7: 20 rows equal [D]; the 120 stored cost-per-purchase values are distinct.
WITH printed_7 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CPP_RANK, CPP_RANK_IN_CHANNEL, CAMPAIGN_ID, CHANNEL, SPEND, PURCHASES, COST_PER_PURCHASE, ROAS_RANK) AS (
  SELECT * FROM VALUES
    (  1,  1, 'CMP0040', 'affiliate',   14920.90, 146, 102.1979,   3),
    (  2,  2, 'CMP0070', 'affiliate',   17318.50, 167, 103.7036,   2),
    (  3,  3, 'CMP0080', 'affiliate',   17904.18, 172, 104.0941,   1),
    (  4,  4, 'CMP0095', 'affiliate',   17881.69, 166, 107.7210,   6),
    (  5,  5, 'CMP0035', 'affiliate',   15913.35, 142, 112.0658,   4),
    (  6,  1, 'CMP0086', 'paid_search', 11691.91, 101, 115.7615,  10),
    (  7,  6, 'CMP0050', 'affiliate',   35219.40, 299, 117.7906,   8),
    (  8,  7, 'CMP0110', 'affiliate',   30384.26, 257, 118.2267,   9),
    (  9,  8, 'CMP0005', 'affiliate',   17057.46, 143, 119.2829,   7),
    ( 10,  9, 'CMP0045', 'affiliate',   10543.72,  88, 119.8150,   5),
    (111, 16, 'CMP0119', 'video',       16825.46,  30, 560.8487, 117),
    (112, 17, 'CMP0079', 'video',       62230.93, 110, 565.7357, 113),
    (113, 18, 'CMP0074', 'video',       26109.81,  46, 567.6046, 115),
    (114, 19, 'CMP0049', 'video',       25032.55,  44, 568.9216, 107),
    (115, 20, 'CMP0064', 'video',       55178.97,  94, 587.0103, 111),
    (116, 21, 'CMP0034', 'video',       34180.02,  57, 599.6495, 119),
    (117, 22, 'CMP0039', 'video',       24066.86,  39, 617.0990, 118),
    (118, 23, 'CMP0099', 'video',        9348.40,  15, 623.2267, 112),
    (119, 24, 'CMP0018', 'display',      7405.03,  11, 673.1845, 116),
    (120, 24, 'CMP0084', 'video',        6105.33,   7, 872.1900, 120)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.CPP_RANK, e.CPP_RANK)) AS ROW_KEY,
         p.CPP_RANK_IN_CHANNEL = e.CPP_RANK_IN_CHANNEL AND p.CAMPAIGN_ID = e.CAMPAIGN_ID AND p.CHANNEL = e.CHANNEL
         AND p.SPEND = e.SPEND AND p.PURCHASES = e.PURCHASES AND p.COST_PER_PURCHASE = e.COST_PER_PURCHASE
         AND p.ROAS_RANK = e.ROAS_RANK AS IS_EQUAL
  FROM printed_7 p
  FULL OUTER JOIN expected e ON e.CPP_RANK = p.CPP_RANK
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_7)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'ranks equal to expected (8 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'distinct COST_PER_PURCHASE values',
                   (SELECT COUNT(DISTINCT COST_PER_PURCHASE) FROM MART_CAMPAIGN_PERFORMANCE), 120, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 8. Ties: RANK vs DENSE_RANK vs ROW_NUMBER on equal purchase counts
--    BUSINESS QUESTION  Which campaigns brought the most paying customers, and how should a
--      ranking report two campaigns with the same count?
--    METHOD  The three ranking functions over the same ORDER BY PURCHASES DESC, on the top 25:
--      ROW_NUMBER() numbers the rows 1, 2, 3, ... and must break ties somehow: without a
--                   tie-breaker the order inside a tie is arbitrary and can change between runs,
--                   so it gets one here (CAMPAIGN_ID);
--      RANK()       gives tied rows the same rank and then skips (19, 19, 21);
--      DENSE_RANK() gives tied rows the same rank and does not skip (19, 19, 20).
--      COUNT(*) OVER (PARTITION BY PURCHASES) shows the size of each tie.
--    HOW TO READ  The top 18 have distinct counts, so the three functions agree. Then CMP0055
--      and CMP0105 both have 219 purchases (ROW_NUMBER 19 and 20, RANK 19 and 19, DENSE_RANK 19
--      and 19), and CMP0006 and CMP0111 both 217 (ROW_NUMBER 21, 22; RANK 21, 21; DENSE_RANK
--      20, 20). From there DENSE_RANK runs two behind ROW_NUMBER (row 25 has DENSE_RANK 23).
--      Which to use: RANK for "position in the league table" (ties share a place, the next
--      place counts the tied rows), DENSE_RANK for "how many distinct levels are above",
--      ROW_NUMBER only when exactly N rows are needed and the tie-breaker is stated.
--    CAVEATS  Purchase counts grow with campaign size and duration; this is a volume ranking,
--      not an efficiency ranking (that is block 7).
-- -----------------------------------------------------------------------------
SELECT ROW_NUMBER() OVER (ORDER BY PURCHASES DESC, CAMPAIGN_ID) AS PURCHASES_ROW_NUMBER,
       RANK()       OVER (ORDER BY PURCHASES DESC)              AS PURCHASES_RANK,
       DENSE_RANK() OVER (ORDER BY PURCHASES DESC)              AS PURCHASES_DENSE_RANK,
       CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, PURCHASES,
       COUNT(*)     OVER (PARTITION BY PURCHASES)               AS CAMPAIGNS_WITH_SAME_PURCHASES
FROM MART_CAMPAIGN_PERFORMANCE
QUALIFY PURCHASES_ROW_NUMBER <= 25
ORDER BY PURCHASES_ROW_NUMBER;

-- 8c. Check of block 8: 25 rows equal [D].
WITH printed_8 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (PURCHASES_ROW_NUMBER, PURCHASES_RANK, PURCHASES_DENSE_RANK, CAMPAIGN_ID, PURCHASES, CAMPAIGNS_WITH_SAME_PURCHASES) AS (
  SELECT * FROM VALUES
    ( 1,  1,  1, 'CMP0060', 326, 1), ( 2,  2,  2, 'CMP0050', 299, 1), ( 3,  3,  3, 'CMP0021', 291, 1),
    ( 4,  4,  4, 'CMP0061', 283, 1), ( 5,  5,  5, 'CMP0020', 282, 1), ( 6,  6,  6, 'CMP0081', 278, 1),
    ( 7,  7,  7, 'CMP0110', 257, 1), ( 8,  8,  8, 'CMP0057', 248, 1), ( 9,  9,  9, 'CMP0062', 246, 1),
    (10, 10, 10, 'CMP0015', 244, 1), (11, 11, 11, 'CMP0117', 242, 1), (12, 12, 12, 'CMP0107', 238, 1),
    (13, 13, 13, 'CMP0056', 237, 1), (14, 14, 14, 'CMP0116', 233, 1), (15, 15, 15, 'CMP0073', 232, 1),
    (16, 16, 16, 'CMP0102', 231, 1), (17, 17, 17, 'CMP0026', 228, 1), (18, 18, 18, 'CMP0092', 224, 1),
    (19, 19, 19, 'CMP0055', 219, 2), (20, 19, 19, 'CMP0105', 219, 2), (21, 21, 20, 'CMP0006', 217, 2),
    (22, 21, 20, 'CMP0111', 217, 2), (23, 23, 21, 'CMP0010', 215, 1), (24, 24, 22, 'CMP0093', 198, 1),
    (25, 25, 23, 'CMP0008', 189, 1)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.PURCHASES_ROW_NUMBER, e.PURCHASES_ROW_NUMBER)) AS ROW_KEY,
         p.PURCHASES_RANK = e.PURCHASES_RANK AND p.PURCHASES_DENSE_RANK = e.PURCHASES_DENSE_RANK
         AND p.CAMPAIGN_ID = e.CAMPAIGN_ID AND p.PURCHASES = e.PURCHASES
         AND p.CAMPAIGNS_WITH_SAME_PURCHASES = e.CAMPAIGNS_WITH_SAME_PURCHASES AS IS_EQUAL
  FROM printed_8 p
  FULL OUTER JOIN expected e ON e.PURCHASES_ROW_NUMBER = p.PURCHASES_ROW_NUMBER
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_8)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (6 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'rows where RANK <> ROW_NUMBER',
                   (SELECT COUNT_IF(PURCHASES_RANK <> PURCHASES_ROW_NUMBER) FROM printed_8), 2, ''
  UNION ALL SELECT 4, 'rows where DENSE_RANK <> RANK',
                   (SELECT COUNT_IF(PURCHASES_DENSE_RANK <> PURCHASES_RANK) FROM printed_8), 5, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 9. What a "top N" filter returns under ties
--    BUSINESS QUESTION  A dashboard asks for "the top 20 campaigns by purchases". How many rows
--      does it get?
--    METHOD  The three functions of block 8, and for each cut-off N the number of campaigns
--      with ROW_NUMBER <= N, RANK <= N and DENSE_RANK <= N. The cut-offs are a 3-row VALUES
--      list cross joined to the 120 campaigns (a parameter list, not a second fact).
--    HOW TO READ  With no tie at the cut (N = 10) all three return 10 rows. At N = 19 the cut
--      falls inside the 219-purchase tie: ROW_NUMBER returns 19 rows and silently drops one of
--      two equal campaigns (which one depends only on the tie-breaker), RANK and DENSE_RANK
--      return both (20). At N = 20, RANK returns 20 and DENSE_RANK 22, because DENSE_RANK 20
--      is the 217-purchase pair.
--    CAVEATS  None beyond block 8: this is the mechanics of the functions on real ties.
-- -----------------------------------------------------------------------------
WITH ranked AS (
  SELECT ROW_NUMBER() OVER (ORDER BY PURCHASES DESC, CAMPAIGN_ID) AS RN,
         RANK()       OVER (ORDER BY PURCHASES DESC)              AS RNK,
         DENSE_RANK() OVER (ORDER BY PURCHASES DESC)              AS DENSE_RNK
  FROM MART_CAMPAIGN_PERFORMANCE
),
cutoffs (TOP_N) AS (
  SELECT * FROM VALUES (10), (19), (20)
)
SELECT c.TOP_N,
       COUNT_IF(r.RN        <= c.TOP_N) AS ROWS_WITH_ROW_NUMBER,
       COUNT_IF(r.RNK       <= c.TOP_N) AS ROWS_WITH_RANK,
       COUNT_IF(r.DENSE_RNK <= c.TOP_N) AS ROWS_WITH_DENSE_RANK
FROM cutoffs c
CROSS JOIN ranked r            -- 3 cut-offs x 120 campaigns
GROUP BY c.TOP_N
ORDER BY c.TOP_N;

-- 9c. Check of block 9: 3 rows equal [D].
WITH printed_9 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (TOP_N, ROWS_WITH_ROW_NUMBER, ROWS_WITH_RANK, ROWS_WITH_DENSE_RANK) AS (
  SELECT * FROM VALUES (10, 10, 10, 10), (19, 19, 20, 20), (20, 20, 20, 22)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.TOP_N, e.TOP_N)) AS ROW_KEY,
         p.ROWS_WITH_ROW_NUMBER = e.ROWS_WITH_ROW_NUMBER AND p.ROWS_WITH_RANK = e.ROWS_WITH_RANK
         AND p.ROWS_WITH_DENSE_RANK = e.ROWS_WITH_DENSE_RANK AS IS_EQUAL
  FROM printed_9 p
  FULL OUTER JOIN expected e ON e.TOP_N = p.TOP_N
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_9)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'cut-offs equal to expected (4 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
)
ORDER BY ORD;


-- =============================================================================
-- PART C. Budget utilisation (SPEND / BUDGET of whole campaigns only)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 10. Budget utilisation by channel: the ratio of sums and the campaign distribution
--    BUSINESS QUESTION  How much of the planned budget was spent, by channel and by campaign,
--      and is underspending linked to weak ROAS?
--    METHOD  Campaign grain only (architecture decision 9): a budget is one amount for a whole
--      campaign window, so utilisation is computed from whole campaigns, never per month.
--      GROUP BY GROUPING SETS ((CHANNEL), ()) gives the five channels and the all-channel
--      total in one pass (GROUPING(CHANNEL) = 1 marks the total row). BUDGET_UTILIZATION is
--      SUM(SPEND) / SUM(BUDGET), a ratio of sums (budget-weighted). The campaign distribution:
--      MIN and MAX of the stored campaign-grain column (6 dp; rounding does not change which
--      campaign is lowest or highest); PERCENTILE_CONT(0.25), MEDIAN and PERCENTILE_CONT(0.75)
--      of the UNROUNDED campaign utilisation SPEND / BUDGET, rounded once to 6 dp (they
--      interpolate linearly between two campaigns, and interpolating the rounded column would
--      print digits it does not have); the count of campaigns with SPEND > BUDGET; and
--      CORR(BUDGET_UTILIZATION, ROAS) across the campaigns (stored columns, see "Rounding").
--    HOW TO READ  4,523,050.02 of 5,418,642.16 was spent: 0.834720, leaving 895,592.14 unspent.
--      The five channels sit within 0.831179-0.839336, and every campaign between 0.698798 and
--      0.986811 (median 0.843463): no campaign reached its budget. Utilisation is not linked
--      to ROAS: the correlation is 0.0895 overall and between -0.1556 and 0.1721 inside the
--      channels (24 campaigns each, i.e. noise).
--    CAVEATS  Utilisation says how much of a plan was spent, not whether the plan was right:
--      unspent budget is not lost revenue. Why campaigns underspend (delivery limits, pacing,
--      planning slack) is not in the data. The narrow band (0.698798 to 0.986811 over all
--      120 campaigns) may be a generator setting (G6).
-- -----------------------------------------------------------------------------
SELECT IFF(GROUPING(CHANNEL) = 1, 'ALL CHANNELS', CHANNEL)             AS CHANNEL_GROUP,
       COUNT(*)                                                         AS CAMPAIGNS,
       SUM(BUDGET)                                                      AS BUDGET,
       SUM(SPEND)                                                       AS SPEND,
       SUM(BUDGET) - SUM(SPEND)                                         AS UNSPENT_BUDGET,
       ROUND(SUM(SPEND)::NUMBER(32,18) / NULLIF(SUM(BUDGET), 0), 6)     AS BUDGET_UTILIZATION,
       MIN(BUDGET_UTILIZATION)                                          AS MIN_CAMPAIGN,
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY SPEND::NUMBER(32,18) / NULLIF(BUDGET, 0)), 6)::NUMBER(10,6)
                                                                        AS P25_CAMPAIGN,
       ROUND(MEDIAN(SPEND::NUMBER(32,18) / NULLIF(BUDGET, 0)), 6)::NUMBER(10,6)
                                                                        AS MEDIAN_CAMPAIGN,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY SPEND::NUMBER(32,18) / NULLIF(BUDGET, 0)), 6)::NUMBER(10,6)
                                                                        AS P75_CAMPAIGN,
       MAX(BUDGET_UTILIZATION)                                          AS MAX_CAMPAIGN,
       COUNT_IF(SPEND > BUDGET)                                         AS CAMPAIGNS_OVER_BUDGET,
       ROUND(CORR(BUDGET_UTILIZATION, ROAS), 4)::NUMBER(10,4)           AS CORR_UTILIZATION_ROAS
FROM MART_CAMPAIGN_PERFORMANCE
GROUP BY GROUPING SETS ((CHANNEL), ())
ORDER BY GROUPING(CHANNEL), CHANNEL;

-- 10c. Check of block 10: 6 rows equal [D] (the channel utilisations also equal
--      MART_CHANNEL_PERFORMANCE.BUDGET_UTILIZATION, [E02c 20]); the total row equals [KT].
WITH printed_10 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL_GROUP, CAMPAIGNS, BUDGET, SPEND, UNSPENT_BUDGET, BUDGET_UTILIZATION, MIN_CAMPAIGN, P25_CAMPAIGN,
          MEDIAN_CAMPAIGN, P75_CAMPAIGN, MAX_CAMPAIGN, CAMPAIGNS_OVER_BUDGET, CORR_UTILIZATION_ROAS) AS (
  SELECT * FROM VALUES
    ('affiliate',     24, 1025491.41,  857835.07, 167656.34, 0.836511, 0.698798, 0.779961, 0.853895, 0.916607, 0.986811, 0,  0.1154),
    ('display',       24, 1138158.37,  955297.00, 182861.37, 0.839336, 0.745782, 0.785435, 0.836901, 0.878455, 0.977479, 0, -0.0297),
    ('paid_search',   24, 1079299.66,  897091.53, 182208.13, 0.831179, 0.705829, 0.775343, 0.842583, 0.892200, 0.971502, 0,  0.1721),
    ('paid_social',   24, 1180823.70,  984731.88, 196091.82, 0.833936, 0.714609, 0.771573, 0.841316, 0.890922, 0.951822, 0, -0.1556),
    ('video',         24,  994869.02,  828094.54, 166774.48, 0.832365, 0.721211, 0.777772, 0.846692, 0.885632, 0.928071, 0,  0.1686),
    ('ALL CHANNELS', 120, 5418642.16, 4523050.02, 895592.14, 0.834720, 0.698798, 0.776925, 0.843463, 0.893718, 0.986811, 0,  0.0895)
),
compared AS (
  SELECT COALESCE(p.CHANNEL_GROUP, e.CHANNEL_GROUP) AS ROW_KEY,
         p.CAMPAIGNS = e.CAMPAIGNS AND p.BUDGET = e.BUDGET AND p.SPEND = e.SPEND AND p.UNSPENT_BUDGET = e.UNSPENT_BUDGET
         AND p.BUDGET_UTILIZATION = e.BUDGET_UTILIZATION AND p.MIN_CAMPAIGN = e.MIN_CAMPAIGN
         AND p.P25_CAMPAIGN = e.P25_CAMPAIGN AND p.MEDIAN_CAMPAIGN = e.MEDIAN_CAMPAIGN AND p.P75_CAMPAIGN = e.P75_CAMPAIGN
         AND p.MAX_CAMPAIGN = e.MAX_CAMPAIGN AND p.CAMPAIGNS_OVER_BUDGET = e.CAMPAIGNS_OVER_BUDGET
         AND p.CORR_UTILIZATION_ROAS = e.CORR_UTILIZATION_ROAS AS IS_EQUAL
  FROM printed_10 p
  FULL OUTER JOIN expected e ON e.CHANNEL_GROUP = p.CHANNEL_GROUP
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_10)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (13 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'ALL CHANNELS: BUDGET [KT]', (SELECT BUDGET FROM printed_10 WHERE CHANNEL_GROUP = 'ALL CHANNELS'), 5418642.16, ''
  UNION ALL SELECT 4, 'ALL CHANNELS: SPEND [KT]',  (SELECT SPEND FROM printed_10 WHERE CHANNEL_GROUP = 'ALL CHANNELS'), 4523050.02, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 11. Budget utilisation histogram, by channel
--    BUSINESS QUESTION  How are the 120 campaigns spread over utilisation levels?
--    METHOD  WIDTH_BUCKET(BUDGET_UTILIZATION, 0.65, 1.00, 7) puts each campaign into one of 7
--      bins of 0.05 on [0.65, 1.00); it returns 0 below 0.65 and 8 at or above 1.00. A
--      GENERATOR spine of the bins 0..8 is the left side of the join, so empty bins print as
--      0 instead of disappearing, including bin 8 (= at or over budget). COUNT_IF pivots the
--      channels into columns.
--    HOW TO READ  Campaigns fill every bin from 0.65 to 1.00 (1, 15, 29, 18, 31, 19, 7); none is
--      below 0.65 or at/over budget. Every channel spreads across the range; video has no
--      campaign above 0.95.
--    CAVEATS  As block 10. Bins of 24 campaigns per channel are small.
-- -----------------------------------------------------------------------------
WITH bins AS (                    -- 0 = below 0.65, 1..7 = the 0.05 bins, 8 = at or above 1.00
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS BIN
  FROM TABLE(GENERATOR(ROWCOUNT => 9))
),
binned AS (                       -- one row per campaign with its bin
  SELECT CHANNEL, WIDTH_BUCKET(BUDGET_UTILIZATION, 0.65, 1.00, 7) AS BIN
  FROM MART_CAMPAIGN_PERFORMANCE
)
SELECT b.BIN,
       CASE WHEN b.BIN = 0 THEN 'below 0.65'
            WHEN b.BIN = 8 THEN '1.00 or more'
            ELSE TO_VARCHAR((0.65 + (b.BIN - 1) * 0.05)::NUMBER(3,2)) || '-' || TO_VARCHAR((0.65 + b.BIN * 0.05)::NUMBER(3,2))
       END                                AS UTILIZATION_RANGE,
       COUNT(x.BIN)                       AS CAMPAIGNS,
       COUNT_IF(x.CHANNEL = 'affiliate')   AS AFFILIATE,
       COUNT_IF(x.CHANNEL = 'display')     AS DISPLAY,
       COUNT_IF(x.CHANNEL = 'paid_search') AS PAID_SEARCH,
       COUNT_IF(x.CHANNEL = 'paid_social') AS PAID_SOCIAL,
       COUNT_IF(x.CHANNEL = 'video')       AS VIDEO
FROM bins b
LEFT JOIN binned x ON x.BIN = b.BIN
GROUP BY b.BIN
ORDER BY b.BIN;

-- 11c. Check of block 11: 9 bins equal [D]; the bins hold all 120 campaigns, 24 per channel.
WITH printed_11 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (BIN, UTILIZATION_RANGE, CAMPAIGNS, AFFILIATE, DISPLAY, PAID_SEARCH, PAID_SOCIAL, VIDEO) AS (
  SELECT * FROM VALUES
    (0, 'below 0.65',    0, 0, 0, 0, 0, 0),
    (1, '0.65-0.70',     1, 1, 0, 0, 0, 0),
    (2, '0.70-0.75',    15, 2, 1, 3, 4, 5),
    (3, '0.75-0.80',    29, 5, 8, 6, 6, 4),
    (4, '0.80-0.85',    18, 3, 4, 4, 4, 3),
    (5, '0.85-0.90',    31, 4, 6, 7, 5, 9),
    (6, '0.90-0.95',    19, 7, 3, 2, 4, 3),
    (7, '0.95-1.00',     7, 2, 2, 2, 1, 0),
    (8, '1.00 or more',  0, 0, 0, 0, 0, 0)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.BIN, e.BIN)) AS ROW_KEY,
         p.UTILIZATION_RANGE = e.UTILIZATION_RANGE AND p.CAMPAIGNS = e.CAMPAIGNS AND p.AFFILIATE = e.AFFILIATE
         AND p.DISPLAY = e.DISPLAY AND p.PAID_SEARCH = e.PAID_SEARCH AND p.PAID_SOCIAL = e.PAID_SOCIAL
         AND p.VIDEO = e.VIDEO AS IS_EQUAL
  FROM printed_11 p
  FULL OUTER JOIN expected e ON e.BIN = p.BIN
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_11)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'bins equal to expected (8 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(CAMPAIGNS) [KT]', (SELECT SUM(CAMPAIGNS) FROM printed_11), 120, ''
  UNION ALL SELECT 4, 'channels with 24 campaigns in the bins',
                   (SELECT (IFF(SUM(AFFILIATE) = 24, 1, 0) + IFF(SUM(DISPLAY) = 24, 1, 0) + IFF(SUM(PAID_SEARCH) = 24, 1, 0)
                            + IFF(SUM(PAID_SOCIAL) = 24, 1, 0) + IFF(SUM(VIDEO) = 24, 1, 0)) FROM printed_11), 5, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 12. The 5 campaigns that used the least and the most of their budget
--    BUSINESS QUESTION  Which campaigns left the most of their plan unspent, and which ran
--      closest to it?
--    METHOD  RANK() OVER (ORDER BY BUDGET_UTILIZATION ASC) at campaign grain; QUALIFY keeps the
--      5 lowest and, with a descending RANK, the 5 highest. UNSPENT_BUDGET = BUDGET - SPEND.
--    HOW TO READ  CMP0100 (affiliate) spent 0.698798 of its budget and left 18,606.60; CMP0115
--      (affiliate) spent 0.986811 and left 708.23. Both ends mix channels and ROAS levels
--      (CMP0035 underspent with ROAS 12.007766, CMP0101 with 2.960100), as the weak correlation
--      of block 10 says.
--    CAVEATS  As block 10.
-- -----------------------------------------------------------------------------
SELECT RANK() OVER (ORDER BY BUDGET_UTILIZATION ASC) AS UTILIZATION_RANK,
       CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, BUDGET, SPEND,
       BUDGET - SPEND                                AS UNSPENT_BUDGET,
       BUDGET_UTILIZATION, ROAS
FROM MART_CAMPAIGN_PERFORMANCE
QUALIFY UTILIZATION_RANK <= 5                                    -- the 5 lowest
     OR RANK() OVER (ORDER BY BUDGET_UTILIZATION DESC) <= 5      -- the 5 highest
ORDER BY UTILIZATION_RANK;

-- 12c. Check of block 12: 10 rows equal [D]; the 120 stored utilisation values are distinct.
WITH printed_12 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (UTILIZATION_RANK, CAMPAIGN_ID, CHANNEL, BUDGET, SPEND, UNSPENT_BUDGET, BUDGET_UTILIZATION, ROAS) AS (
  SELECT * FROM VALUES
    (  1, 'CMP0100', 'affiliate',   61774.40, 43167.80, 18606.60, 0.698798,  3.940222),
    (  2, 'CMP0101', 'paid_search', 74445.68, 52545.91, 21899.77, 0.705829,  2.960100),
    (  3, 'CMP0006', 'paid_search', 50135.67, 35513.84, 14621.83, 0.708355,  8.126586),
    (  4, 'CMP0035', 'affiliate',   22324.72, 15913.35,  6411.37, 0.712813, 12.007766),
    (  5, 'CMP0032', 'paid_social', 61445.05, 43909.18, 17535.87, 0.714609,  4.053278),
    (116, 'CMP0061', 'paid_search', 50880.95, 48907.03,  1973.92, 0.961205,  7.561897),
    (117, 'CMP0015', 'affiliate',   60983.68, 58887.07,  2096.61, 0.965620,  5.421631),
    (118, 'CMP0091', 'paid_search', 33046.33, 32104.58,   941.75, 0.971502,  7.673270),
    (119, 'CMP0063', 'display',     58760.38, 57437.04,  1323.34, 0.977479,  3.227940),
    (120, 'CMP0115', 'affiliate',   53698.12, 52989.89,   708.23, 0.986811,  3.471060)
),
compared AS (
  SELECT TO_VARCHAR(COALESCE(p.UTILIZATION_RANK, e.UTILIZATION_RANK)) AS ROW_KEY,
         p.CAMPAIGN_ID = e.CAMPAIGN_ID AND p.CHANNEL = e.CHANNEL AND p.BUDGET = e.BUDGET AND p.SPEND = e.SPEND
         AND p.UNSPENT_BUDGET = e.UNSPENT_BUDGET AND p.BUDGET_UTILIZATION = e.BUDGET_UTILIZATION AND p.ROAS = e.ROAS AS IS_EQUAL
  FROM printed_12 p
  FULL OUTER JOIN expected e ON e.UTILIZATION_RANK = p.UTILIZATION_RANK
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_12)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'ranks equal to expected (8 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'distinct BUDGET_UTILIZATION values',
                   (SELECT COUNT(DISTINCT BUDGET_UTILIZATION) FROM MART_CAMPAIGN_PERFORMANCE), 120, ''
)
ORDER BY ORD;


-- =============================================================================
-- PART D. Monthly spend vs revenue, ACTIVITY basis, with rolling and cumulative ROAS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 13. Spend and revenue booked by activity month, ROAS of the month, of 3 months and to date
--    BUSINESS QUESTION  How does ROAS move over time, and where does the portfolio stand
--      cumulatively?
--    METHOD  ACTIVITY BASIS (G3), from MART_MONTHLY_MARKETING: spend by spend date, revenue
--      booked by converted date, the five channels summed per month (additive bases; active
--      campaigns are additive across channels within a month). A second CTE, aggregated to the
--      month on its own and joined 1:1, splits the booked revenue by lead age:
--      REVENUE_FROM_EARLIER_MONTH_LEADS is the part booked from leads created in an earlier
--      month (FCT_LEAD_CONVERSIONS, CREATED_MONTH < CONVERTED_MONTH; still activity basis).
--      Then window frames over the 36 months:
--        SUM(...) OVER (ORDER BY MONTH_START ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
--          running totals -> ROAS_ACTIVITY_CUMULATIVE = cumulative revenue / cumulative spend;
--        SUM(...) OVER (ORDER BY MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
--          -> ROAS_ACTIVITY_ROLLING_3M (2023-01 and 2023-02 cover 1 and 2 months).
--      Each ROAS is a ratio of two sums, never an average of monthly ROAS values.
--    HOW TO READ  The cumulative ROAS settles within the first half-year: from 2023-07 on it
--      stays between 4.513790 (2023-07) and 4.898360 (2023-10) (4.851995 after 2023, 4.593471
--      after 2024, 4.767102 at the end, the portfolio ROAS of block 1). The monthly value
--      swings at the edges, and the carry-in column shows why. 2023-01 (2.229138) is the only
--      month with no revenue from earlier-month leads (there are none), and part of its own
--      leads' revenue lands in 2023-02: all 51,988.70 that 2023-02 books from earlier-month
--      leads comes from January's leads, the only earlier ones (against 52,800.58 booked in
--      2023-01 itself; lag up to 21 days). 2025-12 (38.517298) has 1 active campaign that spent
--      807.04 while 31,085.00 was booked, 26,941.67 of it from leads created before December.
--      The 3-month view stays between 3.056907 (2023-02) and 5.931593 (2025-04) from 2023-02 to
--      2025-10.
--    CAVEATS  Activity basis: a month's ROAS is revenue BOOKED in the month over spend IN the
--      month, not the return of that month's spend (conversions lag 0-21 days). Never put
--      these months on one axis with lead-cohort months (MART_MONTHLY_COHORT). Read the
--      edges with ACTIVE_CAMPAIGNS (G7): 11, 5, 3 and 1 in 2025-09 to 2025-12.
-- -----------------------------------------------------------------------------
WITH monthly AS (                 -- channel x month -> month; additive bases only
  SELECT MONTH_START,
         SUM(ACTIVE_CAMPAIGNS) AS ACTIVE_CAMPAIGNS,
         SUM(SPEND)            AS SPEND,
         SUM(REVENUE)          AS REVENUE_BOOKED
  FROM MART_MONTHLY_MARKETING
  GROUP BY MONTH_START
),
carry_in AS (                     -- lead -> month booked: revenue of leads created in an earlier month
  SELECT CONVERTED_MONTH AS MONTH_START, SUM(REVENUE) AS REVENUE_FROM_EARLIER_MONTH_LEADS
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1 AND CREATED_MONTH < CONVERTED_MONTH
  GROUP BY CONVERTED_MONTH
),
running AS (                      -- 1:1 on the month, then window frames over the 36 months
  SELECT m.MONTH_START, m.ACTIVE_CAMPAIGNS, m.SPEND, m.REVENUE_BOOKED,
         COALESCE(c.REVENUE_FROM_EARLIER_MONTH_LEADS, 0) AS REVENUE_FROM_EARLIER_MONTH_LEADS,
         SUM(m.SPEND)          OVER (ORDER BY m.MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)         AS SPEND_3M,
         SUM(m.REVENUE_BOOKED) OVER (ORDER BY m.MONTH_START ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)         AS REVENUE_3M,
         SUM(m.SPEND)          OVER (ORDER BY m.MONTH_START ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUM_SPEND,
         SUM(m.REVENUE_BOOKED) OVER (ORDER BY m.MONTH_START ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUM_REVENUE_BOOKED
  FROM monthly m
  LEFT JOIN carry_in c ON c.MONTH_START = m.MONTH_START
)
SELECT TO_CHAR(MONTH_START, 'YYYY-MM')                                          AS ACTIVITY_MONTH,
       ACTIVE_CAMPAIGNS, SPEND, REVENUE_BOOKED, REVENUE_FROM_EARLIER_MONTH_LEADS,
       ROUND(REVENUE_BOOKED::NUMBER(32,18) / NULLIF(SPEND, 0), 6)                 AS ROAS_ACTIVITY,
       ROUND(REVENUE_3M::NUMBER(32,18) / NULLIF(SPEND_3M, 0), 6)                  AS ROAS_ACTIVITY_ROLLING_3M,
       CUM_SPEND, CUM_REVENUE_BOOKED,
       ROUND(CUM_REVENUE_BOOKED::NUMBER(32,18) / NULLIF(CUM_SPEND, 0), 6)         AS ROAS_ACTIVITY_CUMULATIVE
FROM running
ORDER BY MONTH_START;

-- 13c. Check of block 13: 36 months equal [E02c 14] (active campaigns, spend, revenue booked)
--      and [D] (revenue from earlier-month leads, the three ROAS columns and the running
--      totals); the last running totals equal [KT], the last cumulative ROAS equals block 1's
--      portfolio (4.767102), and the revenue from earlier-month leads adds up to [D].
WITH printed_13 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (ACTIVITY_MONTH, ACTIVE_CAMPAIGNS, SPEND, REVENUE_BOOKED, REVENUE_FROM_EARLIER_MONTH_LEADS, ROAS_ACTIVITY,
          ROAS_ACTIVITY_ROLLING_3M, CUM_SPEND, CUM_REVENUE_BOOKED, ROAS_ACTIVITY_CUMULATIVE) AS (
  SELECT * FROM VALUES
    ('2023-01',  3,  23686.55,  52800.58,      0.00,  2.229138, 2.229138,   23686.55,    52800.58, 2.229138),
    ('2023-02',  5,  49461.61, 170806.55,  51988.70,  3.453316, 3.056907,   73148.16,   223607.13, 3.056907),
    ('2023-03', 10, 104283.65, 393351.94,  84684.07,  3.771943, 3.477162,  177431.81,   616959.07, 3.477162),
    ('2023-04', 11, 104393.90, 474970.42, 150968.25,  4.549791, 4.025460,  281825.71,  1091929.49, 3.874485),
    ('2023-05', 14,  97734.10, 435288.12, 143057.14,  4.453800, 4.254442,  379559.81,  1527217.61, 4.023655),
    ('2023-06', 18, 123064.68, 569578.22, 140865.73,  4.628283, 4.550646,  502624.49,  2096795.83, 4.171695),
    ('2023-07', 16, 116810.98, 699206.04, 228581.86,  5.985790, 5.047462,  619435.47,  2796001.87, 4.513790),
    ('2023-08', 18, 134065.09, 672633.67, 217690.73,  5.017217, 5.191780,  753500.56,  3468635.54, 4.603362),
    ('2023-09', 18, 155294.61, 884815.77, 303005.03,  5.697659, 5.555929,  908795.17,  4353451.31, 4.790355),
    ('2023-10', 19, 171832.62, 939852.38, 291476.05,  5.469581, 5.414882, 1080627.79,  5293303.69, 4.898360),
    ('2023-11', 16, 191171.25, 904954.17, 334515.54,  4.733736, 5.266507, 1271799.04,  6198257.86, 4.873614),
    ('2023-12', 17, 186463.37, 877224.49, 326122.47,  4.704541, 4.953946, 1458262.41,  7075482.35, 4.851995),
    ('2024-01', 12, 122943.61, 618809.35, 263127.73,  5.033278, 4.796429, 1581206.02,  7694291.70, 4.866091),
    ('2024-02', 11, 100601.92, 441376.15, 149841.17,  4.387353, 4.725288, 1681807.94,  8135667.85, 4.837454),
    ('2024-03', 16, 130497.60, 568388.08, 198536.47,  4.355544, 4.599930, 1812305.54,  8704055.93, 4.802753),
    ('2024-04', 19, 196892.88, 795905.02, 270085.89,  4.042325, 4.218928, 2009198.42,  9499960.95, 4.728234),
    ('2024-05', 17, 177398.24, 813289.19, 300696.45,  4.584539, 4.313849, 2186596.66, 10313250.14, 4.716576),
    ('2024-06', 13, 129762.16, 581296.94, 247375.86,  4.479711, 4.345753, 2316358.82, 10894547.08, 4.703307),
    ('2024-07', 13, 115762.43, 468529.67, 157718.68,  4.047338, 4.405333, 2432121.25, 11363076.75, 4.672085),
    ('2024-08', 18, 185052.08, 687143.69, 158895.99,  3.713245, 4.034056, 2617173.33, 12050220.44, 4.604288),
    ('2024-09', 20, 205363.34, 950923.18, 316954.01,  4.630443, 4.161771, 2822536.67, 13001143.62, 4.606191),
    ('2024-10', 18, 219378.73, 961348.25, 308915.82,  4.382140, 4.262775, 3041915.40, 13962491.87, 4.590033),
    ('2024-11', 19, 181790.58, 857423.40, 285806.86,  4.716545, 4.566440, 3223705.98, 14819915.27, 4.597167),
    ('2024-12', 18, 205754.77, 933214.90, 293436.38,  4.535569, 4.534318, 3429460.75, 15753130.17, 4.593471),
    ('2025-01', 16, 189821.49, 926132.23, 340831.37,  4.878964, 4.705450, 3619282.24, 16679262.40, 4.608445),
    ('2025-02', 13,  97550.77, 619062.19, 282222.74,  6.346051, 5.025904, 3716833.01, 17298324.59, 4.654049),
    ('2025-03', 12, 103654.48, 598344.60, 165145.31,  5.772491, 5.481822, 3820487.49, 17896669.19, 4.684394),
    ('2025-04', 13,  95842.28, 544558.36, 188752.80,  5.681818, 5.931593, 3916329.77, 18441227.55, 4.708804),
    ('2025-05', 14, 109131.26, 629458.15, 222086.54,  5.767900, 5.742710, 4025461.03, 19070685.70, 4.737516),
    ('2025-06', 14,  94604.52, 515898.62, 158604.10,  5.453213, 5.640984, 4120065.55, 19586584.32, 4.753950),
    ('2025-07', 15, 132922.32, 601132.60, 197242.48,  4.522435, 5.187724, 4252987.87, 20187716.92, 4.746714),
    ('2025-08', 14, 138359.57, 596182.42, 199667.62,  4.308935, 4.682365, 4391347.44, 20783899.34, 4.732921),
    ('2025-09', 11,  65610.05, 381379.89, 189704.90,  5.812827, 4.686057, 4456957.49, 21165279.23, 4.748818),
    ('2025-10',  5,  48774.54, 228041.53,  73443.02,  4.675421, 4.770056, 4505732.03, 21393320.76, 4.748023),
    ('2025-11',  3,  16510.95, 137433.25,  67971.96,  8.323764, 5.705730, 4522242.98, 21530754.01, 4.761079),
    ('2025-12',  1,    807.04,  31085.00,  26941.67, 38.517298, 6.000070, 4523050.02, 21561839.01, 4.767102)
),
compared AS (
  SELECT COALESCE(p.ACTIVITY_MONTH, e.ACTIVITY_MONTH) AS ROW_KEY,
         p.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND p.SPEND = e.SPEND AND p.REVENUE_BOOKED = e.REVENUE_BOOKED
         AND p.REVENUE_FROM_EARLIER_MONTH_LEADS = e.REVENUE_FROM_EARLIER_MONTH_LEADS
         AND p.ROAS_ACTIVITY = e.ROAS_ACTIVITY AND p.ROAS_ACTIVITY_ROLLING_3M = e.ROAS_ACTIVITY_ROLLING_3M
         AND p.CUM_SPEND = e.CUM_SPEND AND p.CUM_REVENUE_BOOKED = e.CUM_REVENUE_BOOKED
         AND p.ROAS_ACTIVITY_CUMULATIVE = e.ROAS_ACTIVITY_CUMULATIVE AS IS_EQUAL
  FROM printed_13 p
  FULL OUTER JOIN expected e ON e.ACTIVITY_MONTH = p.ACTIVITY_MONTH
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed (36 months)' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_13)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'months equal to expected (10 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'last CUM_SPEND [KT]',          (SELECT MAX_BY(CUM_SPEND, ACTIVITY_MONTH) FROM printed_13), 4523050.02, ''
  UNION ALL SELECT 4, 'last CUM_REVENUE_BOOKED [KT]', (SELECT MAX_BY(CUM_REVENUE_BOOKED, ACTIVITY_MONTH) FROM printed_13), 21561839.01, ''
  UNION ALL SELECT 5, 'last cumulative ROAS = portfolio [D]',
                   (SELECT MAX_BY(ROAS_ACTIVITY_CUMULATIVE, ACTIVITY_MONTH) FROM printed_13), 4.767102, ''
  UNION ALL SELECT 6, 'total from earlier-month leads [D]',
                   (SELECT SUM(REVENUE_FROM_EARLIER_MONTH_LEADS) FROM printed_13), 7336961.39, ''
)
ORDER BY ORD;


-- =============================================================================
-- PART E. Budget allocation (BQ7): which channels should get the budget first?
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 14. Share of spend vs share of revenue by channel
--    BUSINESS QUESTION  BQ7, first view: which channels earn a larger share of the revenue
--      than the share of the budget they get?
--    METHOD  SUM() OVER () over the five channel rows is the portfolio total on every row, so
--      each share is one division: SPEND / SUM(SPEND) OVER (), likewise for purchases and
--      revenue. REVENUE_SHARE_MINUS_SPEND_SHARE > 0 means the channel earns more than its
--      budget share. REVENUE_PER_1000_SPEND (= 1,000 x ROAS) and PURCHASES_PER_1000_SPEND are
--      the dashboard units; ROAS_INDEX = channel ROAS / portfolio ROAS (= revenue share /
--      spend share). Read from MART_CHANNEL_PERFORMANCE, the tested channel bases.
--    HOW TO READ  affiliate gets 0.189659 of the spend and earns 0.260214 of the revenue
--      (+0.070556), paid_search 0.198338 vs 0.252266 (+0.053929). paid_social breaks even
--      (index 0.9991). display (-0.038025) and video (-0.086266) earn less than their share;
--      video gets 0.183083 of the spend for 0.096817 of the revenue. Per 1,000 of spend:
--      6,540.54 of revenue and 5.0499 purchases in affiliate, 2,520.91 and 1.9780 in video.
--    CAVEATS  Average, last-touch, full range: it says where attributed revenue per unit of
--      spend has been highest, not what the next unit of spend would return (blocks 15-16)
--      nor what a channel adds causally (G4).
-- -----------------------------------------------------------------------------
WITH channel_bases AS (           -- channel grain, full range (tested bases)
  SELECT CHANNEL, SPEND, PURCHASES, REVENUE
  FROM MART_CHANNEL_PERFORMANCE
)
SELECT CHANNEL, SPEND, PURCHASES, REVENUE,
       ROUND(SPEND::NUMBER(32,18)     / NULLIF(SUM(SPEND)     OVER (), 0), 6)        AS SPEND_SHARE,
       ROUND(PURCHASES::NUMBER(32,18) / NULLIF(SUM(PURCHASES) OVER (), 0), 6)        AS PURCHASE_SHARE,
       ROUND(REVENUE::NUMBER(32,18)   / NULLIF(SUM(REVENUE)   OVER (), 0), 6)        AS REVENUE_SHARE,
       ROUND(REVENUE::NUMBER(32,18)   / NULLIF(SUM(REVENUE)   OVER (), 0)
             - SPEND::NUMBER(32,18)   / NULLIF(SUM(SPEND)     OVER (), 0), 6)        AS REVENUE_SHARE_MINUS_SPEND_SHARE,
       ROUND((REVENUE * 1000)::NUMBER(32,18)   / NULLIF(SPEND, 0), 2)                AS REVENUE_PER_1000_SPEND,
       ROUND((PURCHASES * 1000)::NUMBER(32,18) / NULLIF(SPEND, 0), 4)                AS PURCHASES_PER_1000_SPEND,
       ROUND((REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0))
             / NULLIF(SUM(REVENUE) OVER ()::NUMBER(32,18) / NULLIF(SUM(SPEND) OVER (), 0), 0), 4) AS ROAS_INDEX
FROM channel_bases
ORDER BY REVENUE_PER_1000_SPEND DESC NULLS LAST;

-- 14c. Check of block 14: 5 channels equal [D] (spend and revenue shares also [E02c 21]); the
--      printed bases add up to [KT].
WITH printed_14 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, SPEND_SHARE, PURCHASE_SHARE, REVENUE_SHARE, REVENUE_SHARE_MINUS_SPEND_SHARE, REVENUE_PER_1000_SPEND,
          PURCHASES_PER_1000_SPEND, ROAS_INDEX) AS (
  SELECT * FROM VALUES
    ('affiliate',   0.189659, 0.259541, 0.260214,  0.070556, 6540.54, 5.0499, 1.3720),
    ('paid_search', 0.198338, 0.251872, 0.252266,  0.053929, 6063.29, 4.6863, 1.2719),
    ('paid_social', 0.217714, 0.218441, 0.217520, -0.000194, 4762.86, 3.7025, 0.9991),
    ('display',     0.211206, 0.172009, 0.173182, -0.038025, 3908.85, 3.0053, 0.8200),
    ('video',       0.183083, 0.098137, 0.096817, -0.086266, 2520.91, 1.9780, 0.5288)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) AS ROW_KEY,
         p.SPEND_SHARE = e.SPEND_SHARE AND p.PURCHASE_SHARE = e.PURCHASE_SHARE AND p.REVENUE_SHARE = e.REVENUE_SHARE
         AND p.REVENUE_SHARE_MINUS_SPEND_SHARE = e.REVENUE_SHARE_MINUS_SPEND_SHARE
         AND p.REVENUE_PER_1000_SPEND = e.REVENUE_PER_1000_SPEND AND p.PURCHASES_PER_1000_SPEND = e.PURCHASES_PER_1000_SPEND
         AND p.ROAS_INDEX = e.ROAS_INDEX AS IS_EQUAL
  FROM printed_14 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_14)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (8 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(SPEND) [KT]',     (SELECT SUM(SPEND) FROM printed_14), 4523050.02, ''
  UNION ALL SELECT 4, 'SUM(PURCHASES) [KT]', (SELECT SUM(PURCHASES) FROM printed_14), 16691, ''
  UNION ALL SELECT 5, 'SUM(REVENUE) [KT]',   (SELECT SUM(REVENUE) FROM printed_14), 21561839.01, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 15. Diminishing-returns check: ROAS by spend tercile within each channel, and CORR(SPEND, ROAS)
--    BUSINESS QUESTION  Does a channel's ROAS hold up for its biggest campaigns? An average
--      ROAS is only a good guide to where the next unit of budget goes if returns do not fall
--      with scale.
--    METHOD  NTILE(3) OVER (PARTITION BY CHANNEL ORDER BY SPEND, CAMPAIGN_ID) splits the 24
--      campaigns of each channel into spend terciles of 8 (1 = the smallest campaigns; the
--      CAMPAIGN_ID tie-breaker makes NTILE deterministic). Each tercile's ROAS is a ratio of
--      sums. CORR(SPEND, ROAS) OVER (PARTITION BY CHANNEL) is the Pearson correlation between
--      campaign spend and campaign ROAS over the 24 campaigns, computed before the GROUP BY and
--      carried with ANY_VALUE (the same value on the three rows of a channel). Two columns
--      prepare block 16: spend per flight day, and the share of flight days on which the
--      campaign got the most leads any campaign ever gets in a day (the "lead ceiling", 35).
--      They come from a campaign-grain CTE over FCT_CAMPAIGN_DAILY_ACTIVITY, joined 1:1 to
--      MART_CAMPAIGN_PERFORMANCE on CAMPAIGN_ID (G1).
--    HOW TO READ  In affiliate ROAS falls from 11.641415 (smallest campaigns) to 6.932542 to
--      4.859721 (largest), correlation -0.8235; paid_search 8.084848 -> 6.521346 -> 5.027759
--      (-0.7502); paid_social 5.474721 -> 4.477259 -> 4.717755 (-0.5517). display (-0.0055) and
--      video (0.0861) are flat. So the two channels with the best average ROAS are the ones
--      whose return falls most with campaign size: their largest campaigns return less per
--      unit of spend than their smallest. That is an association across campaigns; it
--      suggests, but does not measure, that extra spend there would return less than the
--      average. Even so, their largest-spend tercile (4.859721 and 5.027759) still beats the
--      largest tercile of display (3.988662) and video (2.518050).
--      The last two columns are consistent with the lead ceiling of block 16. Larger campaigns
--      spend more per day (affiliate 191.67 -> 586.66 per flight day) and sit at the ceiling
--      on more of their days (affiliate 0.267356 -> 0.975610, paid_search 0.196524 ->
--      0.755306). In paid_social the middle tercile has both the highest ceiling share
--      (0.789565) and the lowest ROAS (4.477259). display and video rarely reach the ceiling
--      (at most 0.187166 and 0.029768) and their ROAS does not fall. Block 16 looks at the
--      same pattern day by day.
--    CAVEATS  This compares different campaigns, not more and less spend on the same campaign:
--      large and small campaigns differ in duration, timing and objective, so it is an
--      association, not a measured marginal return. 8 campaigns per tercile. A correlation of
--      24 points with |r| below about 0.4 is indistinguishable from 0. The ceiling is a
--      generator mechanic (G6). Last-touch; synthetic.
-- -----------------------------------------------------------------------------
WITH ceiling_days AS (            -- campaign grain: flight days, and days at the lead ceiling (block 16)
  SELECT CAMPAIGN_ID,
         COUNT(*)                       AS FLIGHT_DAYS,
         COUNT_IF(LEADS = LEAD_CEILING) AS DAYS_AT_CEILING
  FROM (SELECT CAMPAIGN_ID, LEADS, MAX(LEADS) OVER () AS LEAD_CEILING   -- the most leads any campaign got on any day
        FROM FCT_CAMPAIGN_DAILY_ACTIVITY
        WHERE IS_IN_FLIGHT = 1)
  GROUP BY CAMPAIGN_ID
),
campaigns AS (                    -- campaign grain; the window functions see all 24 campaigns of a channel
  SELECT m.CHANNEL, m.CAMPAIGN_ID, m.SPEND, m.REVENUE, m.ROAS, d.FLIGHT_DAYS, d.DAYS_AT_CEILING,
         NTILE(3) OVER (PARTITION BY m.CHANNEL ORDER BY m.SPEND, m.CAMPAIGN_ID) AS SPEND_TERCILE,
         CORR(m.SPEND, m.ROAS) OVER (PARTITION BY m.CHANNEL)                   AS CORR_SPEND_ROAS
  FROM MART_CAMPAIGN_PERFORMANCE m
  LEFT JOIN ceiling_days d ON d.CAMPAIGN_ID = m.CAMPAIGN_ID   -- 1:1, both one row per campaign
)
SELECT CHANNEL, SPEND_TERCILE,
       COUNT(*)                                                                AS CAMPAIGNS,
       MIN(SPEND)                                                              AS MIN_CAMPAIGN_SPEND,
       MAX(SPEND)                                                              AS MAX_CAMPAIGN_SPEND,
       SUM(SPEND)                                                              AS SPEND,
       SUM(REVENUE)                                                            AS REVENUE,
       ROUND(SUM(REVENUE)::NUMBER(32,18) / NULLIF(SUM(SPEND), 0), 6)           AS ROAS,
       ROUND(ANY_VALUE(CORR_SPEND_ROAS), 4)::NUMBER(10,4)                      AS CORR_SPEND_ROAS_IN_CHANNEL,
       ROUND(SUM(SPEND)::NUMBER(32,18) / NULLIF(SUM(FLIGHT_DAYS), 0), 2)       AS SPEND_PER_FLIGHT_DAY,
       ROUND(SUM(DAYS_AT_CEILING)::NUMBER(32,18) / NULLIF(SUM(FLIGHT_DAYS), 0), 6) AS SHARE_OF_DAYS_AT_LEAD_CEILING
FROM campaigns
GROUP BY CHANNEL, SPEND_TERCILE
ORDER BY CHANNEL, SPEND_TERCILE;

-- 15c. Check of block 15: 15 channel-terciles equal [D]; 8 campaigns in every tercile; the
--      printed rows add up to [KT].
WITH printed_15 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, SPEND_TERCILE, CAMPAIGNS, MIN_CAMPAIGN_SPEND, MAX_CAMPAIGN_SPEND, SPEND, REVENUE, ROAS,
          CORR_SPEND_ROAS_IN_CHANNEL, SPEND_PER_FLIGHT_DAY, SHARE_OF_DAYS_AT_LEAD_CEILING) AS (
  SELECT * FROM VALUES
    ('affiliate',   1, 8, 10543.72, 18220.92, 129760.72, 1510598.36, 11.641415, -0.8235, 191.67, 0.267356),
    ('affiliate',   2, 8, 18328.31, 51492.57, 271062.53, 1879152.31,  6.932542, -0.8235, 390.58, 0.753602),
    ('affiliate',   3, 8, 51639.87, 62309.32, 457011.82, 2220950.06,  4.859721, -0.8235, 586.66, 0.975610),
    ('display',     1, 8,  6701.48, 28256.07, 154010.87,  615955.30,  3.999427, -0.0055, 211.84, 0.015131),
    ('display',     2, 8, 30895.96, 48391.76, 324052.67, 1214639.36,  3.748278, -0.0055, 459.65, 0.130496),
    ('display',     3, 8, 48553.90, 72153.85, 477233.46, 1903522.77,  3.988662, -0.0055, 510.41, 0.187166),
    ('paid_search', 1, 8, 11529.48, 32104.58, 156217.52, 1262994.97,  8.084848, -0.7502, 208.85, 0.196524),
    ('paid_search', 2, 8, 33985.21, 41140.87, 302224.34, 1970909.50,  6.521346, -0.7502, 398.71, 0.571240),
    ('paid_search', 3, 8, 41412.64, 71337.50, 438649.67, 2205424.88,  5.027759, -0.7502, 547.63, 0.755306),
    ('paid_social', 1, 8, 10152.69, 34977.43, 171110.70,  936783.38,  5.474721, -0.5517, 331.61, 0.296512),
    ('paid_social', 2, 8, 37097.85, 48945.75, 353899.86, 1584501.27,  4.477259, -0.5517, 615.48, 0.789565),
    ('paid_social', 3, 8, 49872.48, 67070.47, 459721.32, 2168852.63,  4.717755, -0.5517, 564.08, 0.738650),
    ('video',       1, 8,  6105.33, 23146.07, 121784.55,  316042.66,  2.595097,  0.0861, 163.03, 0.000000),
    ('video',       2, 8, 24066.86, 43162.47, 259138.94,  645512.28,  2.490989,  0.0861, 302.73, 0.005841),
    ('video',       3, 8, 49539.43, 66524.17, 447171.05, 1125999.28,  2.518050,  0.0861, 493.02, 0.029768)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) || ' T' || COALESCE(p.SPEND_TERCILE, e.SPEND_TERCILE) AS ROW_KEY,
         p.CAMPAIGNS = e.CAMPAIGNS AND p.MIN_CAMPAIGN_SPEND = e.MIN_CAMPAIGN_SPEND AND p.MAX_CAMPAIGN_SPEND = e.MAX_CAMPAIGN_SPEND
         AND p.SPEND = e.SPEND AND p.REVENUE = e.REVENUE AND p.ROAS = e.ROAS
         AND p.CORR_SPEND_ROAS_IN_CHANNEL = e.CORR_SPEND_ROAS_IN_CHANNEL AND p.SPEND_PER_FLIGHT_DAY = e.SPEND_PER_FLIGHT_DAY
         AND p.SHARE_OF_DAYS_AT_LEAD_CEILING = e.SHARE_OF_DAYS_AT_LEAD_CEILING AS IS_EQUAL
  FROM printed_15 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL AND e.SPEND_TERCILE = p.SPEND_TERCILE
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_15)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (11 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(CAMPAIGNS) [KT]', (SELECT SUM(CAMPAIGNS) FROM printed_15), 120, ''
  UNION ALL SELECT 4, 'SUM(SPEND) [KT]',     (SELECT SUM(SPEND) FROM printed_15), 4523050.02, ''
  UNION ALL SELECT 5, 'SUM(REVENUE) [KT]',   (SELECT SUM(REVENUE) FROM printed_15), 21561839.01, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 16. Why returns fall in some channels: the data's supply mechanics
--    BUSINESS QUESTION  What makes ROAS fall with campaign size in affiliate, paid_search and
--      paid_social, and not in display and video?
--    METHOD  Campaign-day grain. The flight days of FCT_CAMPAIGN_DAILY_ACTIVITY carry spend (by
--      spend date) and leads (by created date) for one campaign on one day, already joined 1:1
--      there. A second CTE aggregates the revenue of the leads created on each campaign-day
--      (FCT_LEAD_CONVERSIONS by CAMPAIGN_ID, CREATED_DATE) and joins 1:1 (G1). MAX(LEADS) OVER
--      () finds the largest number of leads any campaign got on any day (the ceiling, from the
--      data, not typed in). The days of each channel are then split two ways:
--        by the OUTCOME: "at the ceiling" when the day's leads equal it, else "below";
--        by an INPUT: NTILE(5) OVER (PARTITION BY CHANNEL ORDER BY SPEND, CAMPAIGN_ID,
--          ACTIVITY_DATE) cuts the channel's flight days into fifths by daily spend (the full
--          key makes the order of equal spends deterministic); the lowest and the highest
--          fifth are printed.
--      Per side and per fifth: cost per lead = SUM(SPEND) / SUM(LEADS), and ROAS on an
--      ACQUISITION-DAY basis = later revenue of the day's leads / the day's spend (a
--      lead-cohort outcome per day of acquisition: not a time series, never on a date axis,
--      G3). The daily CPM range (SPEND x 1,000 / IMPRESSIONS) shows the price of reach.
--    HOW TO READ  No campaign ever gets more than 35 leads on a day, in any channel, and 4,168
--      of the 11,240 campaign-days sit exactly at 35: 0.680930 of affiliate's days, 0.634313
--      of paid_social's, 0.513654 of paid_search's, but 0.117448 of display's and 0.012749 of
--      video's. CPM is fixed per channel (every day within 9.0000-9.0008 for affiliate,
--      6.5000-6.5010 display, 18.0000-18.0034 paid_search, 11.0000-11.0012 paid_social,
--      15.0000-15.0039 video): the price of reach never rises with volume.
--      Split by daily spend (an input, so the days are not selected on their outcome), the
--      three channels where the ceiling binds on most days pay 2.1 to 3.3 times as much per
--      lead on their highest-spend fifth of days as on their lowest: affiliate 6.7360 ->
--      22.3294, paid_search 9.5667 -> 21.8814, paid_social 11.9126 -> 24.7676; their
--      acquisition-day ROAS falls from 12.739994 to 3.580868, 9.229117 to 3.660564 and
--      6.963150 to 3.312808. In video the cost per lead falls a little instead (35.5769 ->
--      31.4530; ROAS 2.368337 -> 2.495889), and display sits in between (21.9488 -> 23.1664;
--      ROAS 4.022302 -> 3.451811). This is block 15's pattern at day grain, and it reads like
--      a cap on leads per day at a fixed price of reach: past the cap, more spend buys reach
--      and clicks but no more leads.
--      Split by the outcome, affiliate's cost per lead is 14.1699 on days at the ceiling vs
--      7.9335 below it (acquisition-day ROAS 5.810505 vs 10.563176), and paid_search and
--      paid_social look alike. In display and video the days at the ceiling are CHEAPER per
--      lead (20.2816 vs 21.3997, 25.7918 vs 32.3841): where 35 leads are rare, the days that
--      reach them are selected on a good draw (more clicks per unit of spend or more leads per
--      click than usual). The outcome split mixes the cap with that selection, so the spend
--      fifths are the cleaner reading; the affiliate outcome split is an illustration only.
--    CAVEATS  Both splits are associations in this data, not a measured cost of extra spend:
--      high-spend days also belong to other campaigns and periods than low-spend days. The cap
--      and the constant CPM are synthetic-generator mechanics (G6). A real market has rising
--      auction prices and gradual saturation instead; whether the ceiling stands for a real
--      limit (a form or sales-capacity cap) cannot be told from the data. What carries over is
--      the method: returns at scale must be measured, not read off an average ROAS.
--      Last-touch.
-- -----------------------------------------------------------------------------
WITH campaign_days AS (           -- flight days: spend and leads of one campaign on one day (1:1 in the mart)
  SELECT CAMPAIGN_ID, ACTIVITY_DATE, CHANNEL, IMPRESSIONS, SPEND, LEADS,
         MAX(LEADS) OVER () AS LEAD_CEILING,      -- the most leads any campaign got on any day
         NTILE(5) OVER (PARTITION BY CHANNEL ORDER BY SPEND, CAMPAIGN_ID, ACTIVITY_DATE) AS SPEND_FIFTH   -- 1 = lowest daily spend
  FROM FCT_CAMPAIGN_DAILY_ACTIVITY
  WHERE IS_IN_FLIGHT = 1
),
lead_revenue_by_day AS (          -- later revenue of the leads created on the day, campaign x created date
  SELECT CAMPAIGN_ID, CREATED_DATE AS ACTIVITY_DATE, SUM(REVENUE) AS LEAD_REVENUE
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CAMPAIGN_ID, CREATED_DATE
),
days AS (                         -- 1:1 on (campaign, day)
  SELECT d.CHANNEL, d.IMPRESSIONS, d.SPEND, d.LEADS, d.SPEND_FIFTH,
         COALESCE(r.LEAD_REVENUE, 0)          AS LEAD_REVENUE,
         IFF(d.LEADS = d.LEAD_CEILING, 1, 0)  AS AT_CEILING
  FROM campaign_days d
  LEFT JOIN lead_revenue_by_day r ON r.CAMPAIGN_ID = d.CAMPAIGN_ID AND r.ACTIVITY_DATE = d.ACTIVITY_DATE
)
SELECT CHANNEL,
       COUNT(*)                                                                         AS FLIGHT_DAYS,
       MAX(LEADS)                                                                       AS MAX_LEADS_ON_A_CAMPAIGN_DAY,
       SUM(AT_CEILING)                                                                  AS DAYS_AT_CEILING,
       ROUND(SUM(AT_CEILING)::NUMBER(32,18) / COUNT(*), 6)                              AS SHARE_OF_DAYS_AT_CEILING,
       -- split by the outcome: days at the ceiling vs below it
       ROUND(SUM(IFF(AT_CEILING = 0, SPEND, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(AT_CEILING = 0, LEADS, 0)), 0), 4)                        AS CPL_BELOW_CEILING,
       ROUND(SUM(IFF(AT_CEILING = 1, SPEND, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(AT_CEILING = 1, LEADS, 0)), 0), 4)                        AS CPL_AT_CEILING,
       ROUND(SUM(IFF(AT_CEILING = 0, LEAD_REVENUE, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(AT_CEILING = 0, SPEND, 0)), 0), 6)                        AS ROAS_BELOW_CEILING,
       ROUND(SUM(IFF(AT_CEILING = 1, LEAD_REVENUE, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(AT_CEILING = 1, SPEND, 0)), 0), 6)                        AS ROAS_AT_CEILING,
       -- split by an input: the lowest vs the highest fifth of the channel's days by daily spend
       ROUND(SUM(IFF(SPEND_FIFTH = 1, SPEND, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(SPEND_FIFTH = 1, LEADS, 0)), 0), 4)                       AS CPL_LOWEST_SPEND_FIFTH,
       ROUND(SUM(IFF(SPEND_FIFTH = 5, SPEND, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(SPEND_FIFTH = 5, LEADS, 0)), 0), 4)                       AS CPL_HIGHEST_SPEND_FIFTH,
       ROUND(SUM(IFF(SPEND_FIFTH = 1, LEAD_REVENUE, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(SPEND_FIFTH = 1, SPEND, 0)), 0), 6)                       AS ROAS_LOWEST_SPEND_FIFTH,
       ROUND(SUM(IFF(SPEND_FIFTH = 5, LEAD_REVENUE, 0))::NUMBER(32,18)
             / NULLIF(SUM(IFF(SPEND_FIFTH = 5, SPEND, 0)), 0), 6)                       AS ROAS_HIGHEST_SPEND_FIFTH,
       ROUND(MIN((SPEND * 1000)::NUMBER(32,18) / NULLIF(IMPRESSIONS, 0)), 4)            AS MIN_DAILY_CPM,
       ROUND(MAX((SPEND * 1000)::NUMBER(32,18) / NULLIF(IMPRESSIONS, 0)), 4)            AS MAX_DAILY_CPM
FROM days
GROUP BY CHANNEL
ORDER BY SHARE_OF_DAYS_AT_CEILING DESC;

-- 16c. Check of block 16: 5 channels equal [D]; the flight days add up to [KT] and the days at
--      the ceiling to 4,168 [D].
WITH printed_16 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, FLIGHT_DAYS, MAX_LEADS_ON_A_CAMPAIGN_DAY, DAYS_AT_CEILING, SHARE_OF_DAYS_AT_CEILING, CPL_BELOW_CEILING,
          CPL_AT_CEILING, ROAS_BELOW_CEILING, ROAS_AT_CEILING, CPL_LOWEST_SPEND_FIFTH, CPL_HIGHEST_SPEND_FIFTH,
          ROAS_LOWEST_SPEND_FIFTH, ROAS_HIGHEST_SPEND_FIFTH, MIN_DAILY_CPM, MAX_DAILY_CPM) AS (
  SELECT * FROM VALUES
    ('affiliate',   2150, 35, 1464, 0.680930,  7.9335, 14.1699, 10.563176, 5.810505,  6.7360, 22.3294, 12.739994, 3.580868,  9.0000,  9.0008),
    ('paid_social', 1906, 35, 1209, 0.634313, 14.7270, 17.9452,  5.559997, 4.526259, 11.9126, 24.7676,  6.963150, 3.312808, 11.0000, 11.0012),
    ('paid_search', 2307, 35, 1185, 0.513654, 11.3423, 15.1229,  7.189339, 5.578803,  9.5667, 21.8814,  9.229117, 3.660564, 18.0000, 18.0034),
    ('display',     2367, 35,  278, 0.117448, 21.3997, 20.2816,  3.895634, 3.959635, 21.9488, 23.1664,  4.022302, 3.451811,  6.5000,  6.5010),
    ('video',       2510, 35,   32, 0.012749, 32.3841, 25.7918,  2.501912, 3.046600, 35.5769, 31.4530,  2.368337, 2.495889, 15.0000, 15.0039)
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) AS ROW_KEY,
         p.FLIGHT_DAYS = e.FLIGHT_DAYS AND p.MAX_LEADS_ON_A_CAMPAIGN_DAY = e.MAX_LEADS_ON_A_CAMPAIGN_DAY
         AND p.DAYS_AT_CEILING = e.DAYS_AT_CEILING AND p.SHARE_OF_DAYS_AT_CEILING = e.SHARE_OF_DAYS_AT_CEILING
         AND p.CPL_BELOW_CEILING = e.CPL_BELOW_CEILING AND p.CPL_AT_CEILING = e.CPL_AT_CEILING
         AND p.ROAS_BELOW_CEILING = e.ROAS_BELOW_CEILING AND p.ROAS_AT_CEILING = e.ROAS_AT_CEILING
         AND p.CPL_LOWEST_SPEND_FIFTH = e.CPL_LOWEST_SPEND_FIFTH AND p.CPL_HIGHEST_SPEND_FIFTH = e.CPL_HIGHEST_SPEND_FIFTH
         AND p.ROAS_LOWEST_SPEND_FIFTH = e.ROAS_LOWEST_SPEND_FIFTH AND p.ROAS_HIGHEST_SPEND_FIFTH = e.ROAS_HIGHEST_SPEND_FIFTH
         AND p.MIN_DAILY_CPM = e.MIN_DAILY_CPM AND p.MAX_DAILY_CPM = e.MAX_DAILY_CPM AS IS_EQUAL
  FROM printed_16 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_16)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (15 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
  UNION ALL SELECT 3, 'SUM(FLIGHT_DAYS) [KT]',  (SELECT SUM(FLIGHT_DAYS) FROM printed_16), 11240, ''
  UNION ALL SELECT 4, 'SUM(DAYS_AT_CEILING) [D]', (SELECT SUM(DAYS_AT_CEILING) FROM printed_16), 4168, ''
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 17. Allocation scorecard: one row per channel, and the recommendation
--    BUSINESS QUESTION  BQ7: which channels should the marketing budget go to first?
--    METHOD  Three channel-grain inputs, each computed on its own and joined 1:1 (G1): the
--      channel ROAS and the spend and revenue shares (SUM() OVER ()) from
--      MART_CHANNEL_PERFORMANCE; the ROAS of the channel's largest-spend tercile (NTILE(3) as
--      in block 15: the 8 biggest campaigns, the closest this data gets to "return at
--      scale"); the share of flight days at the lead ceiling (block 16). Two rankings, RANK()
--      by average ROAS and RANK() by largest-tercile ROAS. ALLOCATION_HYPOTHESIS labels a
--      channel only where both rankings agree: both in the top 2 -> 'increase (test)', both in
--      the bottom 2 -> 'decrease (test)', otherwise 'hold'.
--    HOW TO READ  The two rankings differ at the top (average: affiliate then paid_search; at
--      scale: paid_search 5.027759 then affiliate 4.859721) but agree on the set: affiliate
--      and paid_search are the top two, paid_social third, display and video the bottom two.
--      Labels: increase (test) affiliate and paid_search, hold paid_social, decrease (test)
--      display and video.
--    CAVEATS  The label is a rule over descriptive ranks, not an optimisation: it does not say
--      how much to move. See the recommendation below.
-- -----------------------------------------------------------------------------
WITH channel AS (                 -- channel grain: average ROAS and shares
  SELECT CHANNEL,
         REVENUE::NUMBER(32,18) / NULLIF(SPEND, 0)                   AS ROAS_EXACT,
         ROUND(SPEND::NUMBER(32,18)   / NULLIF(SUM(SPEND)   OVER (), 0), 6) AS SPEND_SHARE,
         ROUND(REVENUE::NUMBER(32,18) / NULLIF(SUM(REVENUE) OVER (), 0), 6) AS REVENUE_SHARE
  FROM MART_CHANNEL_PERFORMANCE
),
largest_tercile AS (              -- channel grain: ROAS of the 8 largest-spend campaigns (block 15, tercile 3)
  SELECT CHANNEL, SUM(REVENUE)::NUMBER(32,18) / NULLIF(SUM(SPEND), 0) AS ROAS_AT_SCALE_EXACT
  FROM (SELECT CHANNEL, SPEND, REVENUE,
               NTILE(3) OVER (PARTITION BY CHANNEL ORDER BY SPEND, CAMPAIGN_ID) AS SPEND_TERCILE
        FROM MART_CAMPAIGN_PERFORMANCE)
  WHERE SPEND_TERCILE = 3
  GROUP BY CHANNEL
),
ceiling AS (                      -- channel grain: share of flight days at the lead ceiling (block 16)
  SELECT CHANNEL, SUM(IFF(LEADS = LEAD_CEILING, 1, 0))::NUMBER(32,18) / COUNT(*) AS SHARE_AT_CEILING
  FROM (SELECT CHANNEL, LEADS, MAX(LEADS) OVER () AS LEAD_CEILING
        FROM FCT_CAMPAIGN_DAILY_ACTIVITY
        WHERE IS_IN_FLIGHT = 1)
  GROUP BY CHANNEL
),
scored AS (                       -- 1:1:1 on CHANNEL, then the two rankings
  SELECT c.CHANNEL, c.ROAS_EXACT, t.ROAS_AT_SCALE_EXACT, k.SHARE_AT_CEILING, c.SPEND_SHARE, c.REVENUE_SHARE,
         RANK() OVER (ORDER BY c.ROAS_EXACT DESC NULLS LAST)          AS ROAS_RANK,
         RANK() OVER (ORDER BY t.ROAS_AT_SCALE_EXACT DESC NULLS LAST) AS ROAS_RANK_AT_SCALE
  FROM channel c
  JOIN largest_tercile t ON t.CHANNEL = c.CHANNEL
  JOIN ceiling         k ON k.CHANNEL = c.CHANNEL
)
SELECT CHANNEL,
       ROUND(ROAS_EXACT, 6)                 AS ROAS,
       ROAS_RANK,
       ROUND(ROAS_AT_SCALE_EXACT, 6)        AS ROAS_LARGEST_SPEND_TERCILE,
       ROAS_RANK_AT_SCALE,
       ROUND(SHARE_AT_CEILING, 6)           AS SHARE_OF_DAYS_AT_LEAD_CEILING,
       SPEND_SHARE, REVENUE_SHARE,
       CASE WHEN ROAS_RANK <= 2 AND ROAS_RANK_AT_SCALE <= 2 THEN 'increase (test)'
            WHEN ROAS_RANK >= 4 AND ROAS_RANK_AT_SCALE >= 4 THEN 'decrease (test)'
            ELSE 'hold'
       END                                  AS ALLOCATION_HYPOTHESIS
FROM scored
ORDER BY ROAS_RANK;

-- 17c. Check of block 17: 5 channels equal [D] (each value also printed by blocks 1, 14, 15, 16
--      through a different query).
WITH printed_17 AS (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))),
expected (CHANNEL, ROAS, ROAS_RANK, ROAS_LARGEST_SPEND_TERCILE, ROAS_RANK_AT_SCALE, SHARE_OF_DAYS_AT_LEAD_CEILING,
          SPEND_SHARE, REVENUE_SHARE, ALLOCATION_HYPOTHESIS) AS (
  SELECT * FROM VALUES
    ('affiliate',   6.540536, 1, 4.859721, 2, 0.680930, 0.189659, 0.260214, 'increase (test)'),
    ('paid_search', 6.063294, 2, 5.027759, 1, 0.513654, 0.198338, 0.252266, 'increase (test)'),
    ('paid_social', 4.762857, 3, 4.717755, 3, 0.634313, 0.217714, 0.217520, 'hold'),
    ('display',     3.908855, 4, 3.988662, 4, 0.117448, 0.211206, 0.173182, 'decrease (test)'),
    ('video',       2.520913, 5, 2.518050, 5, 0.012749, 0.183083, 0.096817, 'decrease (test)')
),
compared AS (
  SELECT COALESCE(p.CHANNEL, e.CHANNEL) AS ROW_KEY,
         p.ROAS = e.ROAS AND p.ROAS_RANK = e.ROAS_RANK AND p.ROAS_LARGEST_SPEND_TERCILE = e.ROAS_LARGEST_SPEND_TERCILE
         AND p.ROAS_RANK_AT_SCALE = e.ROAS_RANK_AT_SCALE AND p.SHARE_OF_DAYS_AT_LEAD_CEILING = e.SHARE_OF_DAYS_AT_LEAD_CEILING
         AND p.SPEND_SHARE = e.SPEND_SHARE AND p.REVENUE_SHARE = e.REVENUE_SHARE
         AND p.ALLOCATION_HYPOTHESIS = e.ALLOCATION_HYPOTHESIS AS IS_EQUAL
  FROM printed_17 p
  FULL OUTER JOIN expected e ON e.CHANNEL = p.CHANNEL
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, DETAIL, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'rows printed' AS CHECK_NAME, (SELECT COUNT(*) FROM printed_17)::NUMBER(38,6) AS ACTUAL,
                   (SELECT COUNT(*) FROM expected)::NUMBER(38,6) AS EXPECTED, '' AS DETAIL
  UNION ALL SELECT 2, 'rows equal to expected (9 columns)', COUNT_IF(IS_EQUAL), (SELECT COUNT(*) FROM expected),
                   COALESCE(LISTAGG(IFF(IS_EQUAL, NULL, ROW_KEY), ', ') WITHIN GROUP (ORDER BY ROW_KEY), '') FROM compared
)
ORDER BY ORD;

-- -----------------------------------------------------------------------------
-- RECOMMENDATION for BQ7 (a hypothesis to test, not a finding of this data)
--   What the data shows (descriptive, last-touch):
--     - The channel-level views put affiliate and paid_search on top and display and video at
--       the bottom: average ROAS 6.540536 / 6.063294 vs 3.908855 / 2.520913 (block 1); the
--       same order in each year, on both bases, except that the top two swap in 2025 (block
--       4); the same top two and bottom two in every spend tercile (block 15) and among each
--       channel's largest campaigns (block 17). One exception below channel level: among
--       lead_gen campaigns paid_social has the highest ROAS (6.173294) and affiliate is third
--       (4.918439, block 3). display and video are the bottom two in every view.
--     - The gap is a cost-per-lead gap: purchase rate and revenue per purchase differ by about
--       2% across channels, cost per lead by 2.539x (block 2).
--     - video takes 0.183083 of the spend for 0.096817 of the attributed revenue; affiliate
--       0.189659 for 0.260214 (block 14).
--   What the data suggests but does not measure:
--     - In the two best channels the return is lower at scale: their largest campaigns return
--       less per unit of spend than their smallest (affiliate 11.641415 -> 4.859721,
--       paid_search 8.084848 -> 5.027759; block 15), and their highest-spend days less than
--       their lowest-spend days (block 16), where most campaign-days sit at the 35-lead daily
--       ceiling. These are associations across campaigns and days, consistent with the
--       ceiling, which is a generator mechanic (G6); they suggest that extra spend there
--       would return less than the average ROAS, without measuring by how much.
--   Hypothesis: moving budget from video (and then display) to paid_search and affiliate
--   raises revenue per unit of spend; keep paid_social. Add the budget as more campaigns or
--   campaign-days in the receiving channels, not as more daily spend per campaign-day
--   (affiliate's cost per lead is 22.3294 on its highest-spend fifth of days vs 6.7360 on
--   its lowest, block 16).
--   Why only a hypothesis:
--     1. Attribution: last-touch credits only the final touch. Upper-funnel channels may
--        assist conversions that are credited to other channels, but this data has one
--        attributed campaign per lead and no touch history, so assists can be neither shown
--        nor ruled out; cutting video or display could lower the receivers' revenue too.
--     2. No experiment: spend was never varied at random, so neither the average ROAS nor the
--        tercile comparison identifies the causal or marginal return of a reallocated unit.
--     3. Synthetic mechanics: fixed CPM per channel, a hard 35-lead daily ceiling and
--        near-identical conversion across channels are generator settings (G6); a real
--        market would show rising prices and gradual saturation instead.
--   How to test it before moving the budget: a geo (matched-market) or holdout experiment.
--   For example, in a set of treated regions cut video spend and add the same amount to new
--   paid_search and affiliate campaigns, keep matched control regions unchanged, and compare
--   TOTAL revenue (not last-touch revenue) over the campaign window plus the 21-day conversion
--   lag; or hold out video in a random subset of regions to measure its incremental revenue
--   directly.
-- -----------------------------------------------------------------------------
