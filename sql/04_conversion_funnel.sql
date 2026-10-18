-- =============================================================================
-- Phase 4 / 04: Conversion funnel (Dashboard 2) - analyses #3, #4 and #5
-- -----------------------------------------------------------------------------
-- Purpose
--   Answer business question 2, "Which channels have the highest lead-to-conversion rate?",
--   and produce every number of Dashboard 2, "Conversion Funnel", with the SQL techniques the
--   plan names for its analyses:
--     section 1  #3 Marketing Conversion Funnel   conditional aggregation over stacked stage rows
--     section 2  #4 Lead Conversion Rate          COUNT(DISTINCT) on a LEFT JOIN, NULLIF; Wilson
--                                                 interval and chi-square test, both in SQL
--     section 3  #5 Cost per Lead / Conversion    SUM(CASE WHEN ...), NULLIF on zero-lead days
--     section 4  monthly conversion trend         activity basis vs lead-cohort basis, 36 months
--     section 5  time to convert                  GROUPING SETS, percentiles, running share
--   The file is READ-ONLY (USE and SELECT/WITH only). It reads the clean STAGING views and the
--   Phase 3/4 MART tables, creates nothing, and prints its results with reconciliation rows.
-- Analytical guard rails (the user plan), and where each one shows up
--   G1 Grain. Facts of different grains are never joined row by row (the naive daily_spend x
--      leads join inflates spend 2,495x, docs/data_profile.md "The grain trap"). Two grain-safe
--      patterns are used: STACK the facts (UNION ALL, block 1.1: rows are only ever summed,
--      never multiplied), or AGGREGATE each fact to the common grain first and then join 1:1
--      (blocks 3.1-3.3, 4.1). Every block that joins prints a total that would expose a fan-out.
--   G2 Aggregate funnel. Impressions -> clicks -> leads -> converted leads -> purchases counts
--      different units (ad impressions, clicks, people, outcomes). It is a campaign-level
--      funnel, not one person's journey: a lead converts at most once, to a trial OR a purchase,
--      so "converted leads -> purchases" is the purchase share of the outcomes, not a trial
--      that later became a purchase. No query here can follow a person from trial to purchase.
--   G3 Two time bases. Activity figures count each event in the month it happened (leads by
--      created date, conversions by converted date); lead-cohort figures count what the leads
--      created in month M later did. They answer different questions and are never mixed on one
--      axis: section 4 prints them side by side only to show why the activity ratio is not a
--      conversion rate.
--   G4 ROAS is last-touch attributed revenue / spend, not causal (not used in this file; see
--      06_marketing_efficiency.sql). Cost per purchase here is spend / attributed purchases.
--   G5 Lead score is not assumed to be predictive (lead quality is 05_lead_analysis.sql).
--   G6 SYNTHETIC data. Regular patterns are generator artefacts, not market facts: the channel
--      CPMs are near-round numbers (block 3.1 prints them), the lag is flat over 0-21 days
--      (block 5.2), and the conversion rate shows no detectable difference by channel,
--      objective, campaign or month (sections 2, 4).
--   G7 2025 volume falls because fewer campaigns ran (22 started in 2025 vs 50 in 2024,
--      docs/evidence/03_overview.txt [12]). Block 4.1 prints ACTIVE_CAMPAIGNS next to every
--      monthly volume.
-- Statistics, computed in SQL
--   Wilson 95% interval for a proportion p = k / n (z = 1.959964, as in MART_CHANNEL_PERFORMANCE):
--     centre = (p + z^2 / (2n)) / (1 + z^2 / n)
--     half   = z / (1 + z^2 / n) x SQRT(p (1 - p) / n + z^2 / (4 n^2))
--   Chi-square test of independence (outcome converted / not converted vs group):
--     expected count E = row total x column total / grand total; statistic = SUM((O - E)^2 / E)
--     over all cells; df = (groups - 1) x (2 - 1). Snowflake has no chi-square distribution
--     function, so the upper 5% critical values are constants [Q], and the p-value is computed
--     in SQL only where it has a closed form (even df): df 2 -> EXP(-x/2), df 4 -> EXP(-x/2)(1 + x/2).
--   What they assume: every lead is an independent trial with the same probability inside its
--   group. Leads of one campaign may share unobserved factors, so these tests describe sampling
--   noise only; they say nothing about attribution, bias or the synthetic generator.
--   Not rejecting is not proof of equal rates. Where a block says what its test could have
--   detected, the figure is the power of that same test at alpha 0.05 against the effect it
--   states (for example one group's rate 1 point off, the other groups at the test's pooled
--   rate) [PW].
--   SQRT, EXP and POWER need FLOAT, so the statistics are the one computation in double
--   precision, rounded once to 6 dp. Every exact value behind them (60-digit [D]) lies at least
--   4 x 10^-9 away from a rounding midpoint at 6 dp, far beyond double-precision error.
-- Rounding
--   As in 02b_core_models.sql ("Rounding"): every exact division casts its dividend to
--   NUMBER(32,18), so ROUND to the printed scale is the only rounding (rates 6 dp, costs 4 dp).
-- Where the expected values come from (never from the query under test)
--   [P3]   The local "KPI reconciliation" profile (2026-10-13, DuckDB and Python Decimal, before
--          Snowflake existed), carried inline in 02b_core_models_tests.sql: channel bases
--          (block 13), channel ratios (block 14), the 36 monthly bases (block 17).
--   [PUB]  The publisher reference output: spend and attributed revenue by channel.
--   [E01]  docs/evidence/01_data_profiling.txt: [23] 7 spend rows with zero leads, [24] 4,716
--          conversions after their campaign ended (1,951 purchases, 2,765 trials) and 1,811
--          same-day conversions, [25] the lag percentiles and means, [28] active campaigns per
--          month.
--   [E02c] docs/evidence/02c_analysis_marts_tests.txt: [14] conversions of each cohort that land
--          in a later month, [16] 13,675 later-month and 26,021 same-month conversions (34.4493%),
--          [21] the channel Wilson bounds.
--   [PL]   docs/architecture.md decision 7 (local pre-load profiling): 13,675 conversions, 34.45%,
--          land in a later calendar month than their lead.
--   [D]    Python 3 csv + decimal / fractions (ROUND_HALF_UP) and mpmath (60 digits),
--          2026-10-14, outside Snowflake, from data/raw/source/*.csv: purchase share of
--          conversions and the biggest drop per channel; expected counts, chi-square statistics,
--          p-values and Cramer's V; the objective-within-channel table; campaign rates with
--          Wilson bounds (highest / lowest 10), campaign chi-square, the largest campaign
--          (5,104 leads) and the intervals that exclude the pooled rate; channel CPM, CPC,
--          impressions and clicks per lead; campaign cost per purchase (cheapest / most
--          expensive 10) and the unique 7-purchase minimum (CMP0084); the 7 zero-lead days
--          (spend 303.34, all CMP0084) and the mean of daily CPL; monthly naive and cohort
--          ratios, Wilson bounds and the 36-month chi-square; the lag histogram, shares within
--          7 / 14 / 21 days, same-day and after-end counts by channel.
--   [Q]    Upper 5% quantiles of the chi-square distribution, scipy.stats.chi2.ppf(0.95, df),
--          outside Snowflake: df 2 = 5.991465, df 4 = 9.487729, df 35 = 49.801850,
--          df 119 = 145.460740 (the textbook df 4 value is 9.488).
--   [PW]   Power of a chi-square test, scipy.stats.ncx2.sf(critical value, df, lambda), outside
--          Snowflake, 2026-10-14, with lambda = SUM(n_i (p_i - p_bar)^2) / (p_bar (1 - p_bar))
--          over the groups' printed lead counts n_i; comments quote it rounded to whole percent.
--   [C]    By construction: the shape of the table (cells, degrees of freedom).
-- Dashboard 2 "Conversion Funnel": which table each chart reads (Phase 6), and its block here
--   funnel by channel        MART_CHANNEL_PERFORMANCE bases, rates as SUM / SUM        1.1, 1.2
--   conversion rate + 95% CI MART_CHANNEL_PERFORMANCE.LEAD_CONVERSION_RATE, LCR_CI_*   2.1, 2.2
--   cost per lead / purchase MART_CHANNEL_PERFORMANCE, MART_CAMPAIGN_PERFORMANCE       3.1, 3.3
--   monthly conversion rate  MART_MONTHLY_COHORT, SUM(CONVERTED_LEADS) / SUM(LEADS)    4.1, 4.2
--   time to convert          FCT_LEAD_CONVERSIONS.DAYS_TO_CONVERT                      5.1, 5.2
--   The blocks recompute each figure from STAGING (or from the Phase 3 facts) and reconcile it
--   with those tables, so the dashboard and this file cannot silently disagree.
-- How to run
--   From the repository root, after sql/02c_analysis_marts.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/04_conversion_funnel.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 19 statements,
--   well under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/04_funnel.txt.
-- Reading the results
--   STATUS = PASS means the query reproduced the expected value exactly. Group comparisons with
--   an expected list use a FULL OUTER JOIN, so a missing or unexpected group is its own FAIL
--   row. Rows labelled "WRONG on purpose", and columns whose name starts with WRONG_, compute a
--   misleading number so that it is never charted. (Check rows of mixed measures share one
--   NUMBER column: counts print as 7.000000.)
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where
--   [6] 1.1 funnel by channel (wide)   [7] 1.2 funnel stages (long, dashboard)
--   [8] 2.1 lead conversion rate by channel   [9] 2.2 chi-square test across channels
--   [10] 2.3 objective within channel   [11] 2.4 campaigns, highest / lowest 10   [12] 2.5 campaign spread
--   [13] 3.1 cost per lead / conversion / purchase by channel, with CPM and CPC
--   [14] 3.2 zero-lead days, campaign check
--   [15] 3.3 campaigns, cheapest / most expensive 10 per purchase
--   [16] 4.1 monthly activity vs cohort, 36 months   [17] 4.2 monthly ranges and cross-month share
--   [18] 5.1 time to convert, summary   [19] 5.2 time to convert, distribution
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


-- =============================================================================
-- SECTION 1. #3 Marketing Conversion Funnel (conditional aggregation)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 The aggregate funnel by channel: stage counts and stage-to-stage rates
--    BUSINESS QUESTION  How many impressions, clicks, leads, converted leads and purchases does
--      each channel produce, and at which step does its funnel narrow the most?
--    METHOD  Conditional aggregation over stacked stage rows (plan #3).
--      STEP 1  funnel_events stacks the sources with UNION ALL, each at its own grain and tagged
--              with its stage: one row per campaign-day weighted by its impressions, one per
--              campaign-day weighted by its clicks, one per lead, one per converted lead tagged
--              'trial' or 'purchase'. Stacking never multiplies a row (G1).
--      STEP 2  One GROUP BY ROLLUP (CHANNEL) turns the stack into one row per channel plus a
--              TOTAL row: SUM(CASE WHEN STAGE = ... THEN UNITS ELSE 0 END) per stage.
--      STEP 3  Stage-to-stage rates as ratios of the sums: CTR = clicks / impressions,
--              click-to-lead = leads / clicks, lead conversion = converted leads / leads,
--              purchase share = purchases / converted leads. The step with the lowest
--              pass-through rate is the biggest relative drop (drop = 1 - rate).
--      Source: STAGING; reconciled with MART_CHANNEL_PERFORMANCE (built from the Phase 3 facts).
--    HOW TO READ  Each rate is the share of the previous stage's units that reach the next one.
--      RESULT: impressions -> clicks has the lowest pass-through in every channel (drop
--      0.965080 for paid_search up to 0.994013 for display) and overall (0.983742). In two
--      channels it is a near-tie with clicks -> leads (RELATIVE_DROP in 1.2): affiliate 0.974958
--      vs 0.971574, paid_search 0.965080 vs 0.962496, about 0.3 points apart. Downstream the
--      channels look alike: lead conversion 0.149372-0.153506, purchase share of conversions
--      0.416476-0.425712. They differ upstream: CTR 0.005987 (display) to 0.034920
--      (paid_search), click-to-lead 0.028426 (affiliate) to 0.052385 (video).
--    CAVEATS  Aggregate funnel (G2): the stages count different units (an impression is not a
--      person, a click is not a lead), so ranking the steps by their drop is descriptive only;
--      it does not say where people are lost. Purchases are not a stage after trials: a lead
--      converts once, to one of the two. Synthetic data (G6).
--    EXPECTED  Bases [P3]/[PUB]; CTR, click-to-lead and lead conversion rate [P3]; purchase share
--      and biggest drop [D]; every channel equal to MART_CHANNEL_PERFORMANCE.
-- -----------------------------------------------------------------------------
WITH funnel_events (CHANNEL, STAGE, UNITS) AS (   -- STEP 1: stacked, never joined to each other
  SELECT c.CHANNEL, 'impressions', s.IMPRESSIONS                 -- one row per campaign-day
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND s
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID         -- n:1 channel lookup
  UNION ALL
  SELECT c.CHANNEL, 'clicks', s.CLICKS                           -- one row per campaign-day
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND s
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID
  UNION ALL
  SELECT c.CHANNEL, 'lead', 1                                    -- one row per lead
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  UNION ALL
  SELECT c.CHANNEL, v.CONVERSION_TYPE, 1                         -- one row per converted lead: 'trial' OR 'purchase'
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l     ON l.LEAD_ID = v.LEAD_ID               -- 1:1, adds the campaign
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
),
funnel AS (                                       -- STEP 2: conditional aggregation, one pass, + TOTAL row
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL)                          AS CHANNEL,
         GROUPING(CHANNEL)                                                     AS IS_TOTAL,
         SUM(CASE WHEN STAGE = 'impressions'          THEN UNITS ELSE 0 END)   AS IMPRESSIONS,
         SUM(CASE WHEN STAGE = 'clicks'               THEN UNITS ELSE 0 END)   AS CLICKS,
         SUM(CASE WHEN STAGE = 'lead'                 THEN UNITS ELSE 0 END)   AS LEADS,
         SUM(CASE WHEN STAGE IN ('trial', 'purchase') THEN UNITS ELSE 0 END)   AS CONVERTED_LEADS,
         SUM(CASE WHEN STAGE = 'purchase'             THEN UNITS ELSE 0 END)   AS PURCHASES
  FROM funnel_events
  GROUP BY ROLLUP (CHANNEL)
),
rated AS (                                        -- STEP 3: ratios of the sums, rounded once
  SELECT f.*,
         ROUND(CLICKS::NUMBER(32,18)          / NULLIF(IMPRESSIONS, 0), 6)     AS CTR,
         ROUND(LEADS::NUMBER(32,18)           / NULLIF(CLICKS, 0), 6)          AS CLICK_TO_LEAD_RATE,
         ROUND(CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0), 6)           AS LEAD_CONVERSION_RATE,
         ROUND(PURCHASES::NUMBER(32,18)       / NULLIF(CONVERTED_LEADS, 0), 6) AS PURCHASE_SHARE
  FROM funnel f
),
stepped AS (                                      -- the lowest pass-through rate = the biggest relative drop
  SELECT r.*,
         LEAST(CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_SHARE) AS LOWEST_RATE,
         CASE LEAST(CTR, CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_SHARE)
              WHEN CTR                  THEN 'impressions -> clicks'
              WHEN CLICK_TO_LEAD_RATE   THEN 'clicks -> leads'
              WHEN LEAD_CONVERSION_RATE THEN 'leads -> converted leads'
              ELSE                           'converted -> purchases'
         END                                                                AS BIGGEST_DROP_STEP
  FROM rated r
),
expected (CHANNEL, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, PURCHASES, CTR, CLICK_TO_LEAD_RATE,
          LEAD_CONVERSION_RATE, PURCHASE_SHARE, BIGGEST_DROP_STEP, BIGGEST_DROP) AS (
  SELECT * FROM VALUES   -- bases [P3]/[PUB]; CTR, click-to-lead, lead conversion [P3]; purchase share, drop [D]
    ('affiliate',    95314042, 2386856,  67849, 10352,  4332, 0.025042, 0.028426, 0.152574, 0.418470, 'impressions -> clicks', 0.974958),
    ('display',     146967688,  879874,  45149,  6744,  2871, 0.005987, 0.051313, 0.149372, 0.425712, 'impressions -> clicks', 0.994013),
    ('paid_search',  49837405, 1740314,  65268, 10019,  4204, 0.034920, 0.037504, 0.153506, 0.419603, 'impressions -> clicks', 0.965080),
    ('paid_social',  89520215, 1602785,  57619,  8648,  3646, 0.017904, 0.035949, 0.150089, 0.421600, 'impressions -> clicks', 0.982096),
    ('video',        55205469,  492490,  25799,  3933,  1638, 0.008921, 0.052385, 0.152448, 0.416476, 'impressions -> clicks', 0.991079),
    ('TOTAL',       436844819, 7102319, 261684, 39696, 16691, 0.016258, 0.036845, 0.151694, 0.420471, 'impressions -> clicks', 0.983742)
)
SELECT COALESCE(s.CHANNEL, e.CHANNEL) AS CHANNEL, s.IMPRESSIONS, s.CLICKS, s.LEADS, s.CONVERTED_LEADS, s.PURCHASES,
       s.CTR, s.CLICK_TO_LEAD_RATE, s.LEAD_CONVERSION_RATE, s.PURCHASE_SHARE, s.BIGGEST_DROP_STEP,
       1 - s.LOWEST_RATE AS BIGGEST_DROP,
       CASE WHEN s.IS_TOTAL = 1 THEN 'n/a'
            WHEN m.IMPRESSIONS = s.IMPRESSIONS AND m.CLICKS = s.CLICKS AND m.LEADS = s.LEADS
                 AND m.CONVERTED_LEADS = s.CONVERTED_LEADS AND m.PURCHASES = s.PURCHASES AND m.CTR = s.CTR
                 AND m.CLICK_TO_LEAD_RATE = s.CLICK_TO_LEAD_RATE AND m.LEAD_CONVERSION_RATE = s.LEAD_CONVERSION_RATE
                 THEN 'yes' ELSE 'NO' END AS EQUALS_CHANNEL_MART,
       IFF(s.IMPRESSIONS = e.IMPRESSIONS AND s.CLICKS = e.CLICKS AND s.LEADS = e.LEADS
           AND s.CONVERTED_LEADS = e.CONVERTED_LEADS AND s.PURCHASES = e.PURCHASES AND s.CTR = e.CTR
           AND s.CLICK_TO_LEAD_RATE = e.CLICK_TO_LEAD_RATE AND s.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE
           AND s.PURCHASE_SHARE = e.PURCHASE_SHARE AND s.BIGGEST_DROP_STEP = e.BIGGEST_DROP_STEP
           AND 1 - s.LOWEST_RATE = e.BIGGEST_DROP
           AND (s.IS_TOTAL = 1 OR EQUALS_CHANNEL_MART = 'yes'), 'PASS', 'FAIL') AS STATUS
FROM stepped s
LEFT JOIN MART_CHANNEL_PERFORMANCE m ON m.CHANNEL = s.CHANNEL     -- 1:1; the TOTAL row has no mart row
FULL OUTER JOIN expected e ON e.CHANNEL = s.CHANNEL
ORDER BY s.IS_TOTAL, s.LEAD_CONVERSION_RATE DESC;


-- -----------------------------------------------------------------------------
-- 1.2 Funnel stages in long form (dashboard table: 6 funnels x 5 stages = 30 rows)
--    BUSINESS QUESTION  Same as 1.1, in the shape a funnel chart needs: one row per stage.
--    METHOD  A UNION of stage rows, each stage aggregated to the channel on its own from the
--      Phase 3 facts (FCT_DAILY_SPEND for delivery, FCT_LEAD_CONVERSIONS for people, with
--      conditional counts COUNT_IF / SUM(CASE WHEN) for the outcomes); a TOTAL funnel as the SUM
--      of the channel rows per stage; LAG() over the stage order for the pass-through rate; a
--      MIN() window flags the biggest relative drop in each funnel.
--    HOW TO READ  PASS_THROUGH_RATE = UNITS / UNITS of the previous stage; RELATIVE_DROP = 1 - it.
--      BIGGEST_DROP = yes marks the step with the lowest pass-through in the funnel.
--      RESULT: as in 1.1; the flag sits on impressions -> clicks in all six funnels.
--    CAVEATS  As 1.1 (G2, G6). In Data Studio, chart the UNITS of one funnel at a time: summing
--      UNITS across stages adds impressions to people and means nothing.
--    EXPECTED  Units [P3]/[PUB]; the flag on stage 2 (clicks) in every funnel [D]; 5 stages per funnel.
-- -----------------------------------------------------------------------------
WITH stage_rows (CHANNEL, STAGE_NO, STAGE, UNITS) AS (   -- each stage aggregated on its own, then stacked
  SELECT CHANNEL, 1, 'impressions',     SUM(IMPRESSIONS)                                     FROM FCT_DAILY_SPEND      GROUP BY CHANNEL
  UNION ALL
  SELECT CHANNEL, 2, 'clicks',          SUM(CLICKS)                                          FROM FCT_DAILY_SPEND      GROUP BY CHANNEL
  UNION ALL
  SELECT CHANNEL, 3, 'leads',           COUNT(*)                                             FROM FCT_LEAD_CONVERSIONS GROUP BY CHANNEL
  UNION ALL
  SELECT CHANNEL, 4, 'converted leads', COUNT_IF(IS_CONVERTED = 1)                           FROM FCT_LEAD_CONVERSIONS GROUP BY CHANNEL
  UNION ALL
  SELECT CHANNEL, 5, 'purchases',       SUM(CASE WHEN CONVERSION_TYPE = 'purchase' THEN 1 ELSE 0 END) FROM FCT_LEAD_CONVERSIONS GROUP BY CHANNEL
),
funnels AS (                                   -- the five channel funnels + the TOTAL funnel (counts are additive)
  SELECT CHANNEL, STAGE_NO, STAGE, UNITS FROM stage_rows
  UNION ALL
  SELECT 'TOTAL', STAGE_NO, STAGE, SUM(UNITS) FROM stage_rows GROUP BY STAGE_NO, STAGE
),
stepped AS (                                   -- pass-through from the previous stage of the same funnel
  SELECT CHANNEL, STAGE_NO, STAGE, UNITS,
         LAG(STAGE) OVER (PARTITION BY CHANNEL ORDER BY STAGE_NO) || ' -> ' || STAGE                AS STEP,
         ROUND(UNITS::NUMBER(32,18)
               / NULLIF(LAG(UNITS) OVER (PARTITION BY CHANNEL ORDER BY STAGE_NO), 0), 6)            AS PASS_THROUGH_RATE,
         COUNT(*) OVER (PARTITION BY CHANNEL)                                                       AS STAGES
  FROM funnels
),
flagged AS (                                   -- MIN() ignores the NULL rate of stage 1
  SELECT t.*, IFF(PASS_THROUGH_RATE = MIN(PASS_THROUGH_RATE) OVER (PARTITION BY CHANNEL), 'yes', '') AS BIGGEST_DROP
  FROM stepped t
),
expected (CHANNEL, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, PURCHASES) AS (
  SELECT * FROM VALUES   -- [P3]/[PUB]
    ('affiliate',    95314042, 2386856,  67849, 10352,  4332),
    ('display',     146967688,  879874,  45149,  6744,  2871),
    ('paid_search',  49837405, 1740314,  65268, 10019,  4204),
    ('paid_social',  89520215, 1602785,  57619,  8648,  3646),
    ('video',        55205469,  492490,  25799,  3933,  1638),
    ('TOTAL',       436844819, 7102319, 261684, 39696, 16691)
)
SELECT COALESCE(f.CHANNEL, e.CHANNEL) AS CHANNEL, f.STAGE_NO, f.STAGE, f.UNITS, f.STEP, f.PASS_THROUGH_RATE,
       1 - f.PASS_THROUGH_RATE AS RELATIVE_DROP, f.BIGGEST_DROP,
       IFF(f.STAGES = 5
           AND f.UNITS = DECODE(f.STAGE_NO, 1, e.IMPRESSIONS, 2, e.CLICKS, 3, e.LEADS, 4, e.CONVERTED_LEADS, 5, e.PURCHASES)
           AND (f.BIGGEST_DROP = 'yes') = (f.STAGE_NO = 2), 'PASS', 'FAIL') AS STATUS
FROM flagged f
FULL OUTER JOIN expected e ON e.CHANNEL = f.CHANNEL
ORDER BY IFF(COALESCE(f.CHANNEL, e.CHANNEL) = 'TOTAL', 1, 0), 1, f.STAGE_NO;


-- =============================================================================
-- SECTION 2. #4 Lead Conversion Rate (COUNT DISTINCT, NULLIF) - business question 2
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Lead conversion rate by channel, with a Wilson 95% interval
--    BUSINESS QUESTION  Which channel has the highest lead-to-conversion rate (question 2)?
--    METHOD  COUNT(DISTINCT) on a LEFT JOIN, NULLIF on the denominator (plan #4):
--        COUNT(DISTINCT v.LEAD_ID) / NULLIF(COUNT(DISTINCT l.LEAD_ID), 0)
--      over STG_LEADS LEFT JOIN STG_CONVERSIONS. The LEFT JOIN keeps the 221,988 leads that never
--      converted in the denominator (an INNER JOIN would make every rate 100%). Their v.LEAD_ID
--      is NULL, and COUNT ignores NULL, so the numerator counts converted leads only. DISTINCT
--      makes the rate robust to a fan-out: if a lead ever had two conversion rows, it would
--      still count once; JOINED_ROWS = LEADS shows there is no fan-out today. ROLLUP adds the
--      pooled TOTAL rate. The Wilson interval and the expected count under independence
--      (LEADS x pooled rate) feed the chi-square test of 2.2; the TOTAL row of
--      CHI_SQUARE_CONTRIBUTION is the test statistic.
--    HOW TO READ  RESULT: paid_search ranks first, 0.153506 (10,019 / 65,268; 95% interval
--      0.150760-0.156291), then affiliate 0.152574, video 0.152448, paid_social 0.150089 and
--      display 0.149372. The spread between first and last is 0.004134 (0.41 points), and every
--      channel interval contains the pooled rate 0.151694: the test of 2.2 cannot tell the
--      channels apart at this sample size, so the ranking is not a finding.
--    CAVEATS  A conversion is a trial OR a purchase; the purchase rate is in 1.1 (purchase share)
--      and 3.1. Last-touch attribution decides which channel a lead belongs to. Synthetic (G6).
--    EXPECTED  Rates [P3]; Wilson bounds [E02c 21] (TOTAL [D]); expected counts and
--      contributions [D]; every channel equal to MART_CHANNEL_PERFORMANCE (a different path).
-- -----------------------------------------------------------------------------
WITH lead_outcomes AS (     -- one row per lead; CONVERTED_LEAD_ID is NULL when the lead never converted
  SELECT c.CHANNEL, l.LEAD_ID, v.LEAD_ID AS CONVERTED_LEAD_ID
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1, keeps unconverted leads
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c        ON c.CAMPAIGN_ID = l.CAMPAIGN_ID  -- n:1
),
by_channel AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL)                                  AS CHANNEL,
         GROUPING(CHANNEL)                                                             AS IS_TOTAL,
         COUNT(*)                                                                      AS JOINED_ROWS,
         COUNT(DISTINCT LEAD_ID)                                                       AS LEADS,
         COUNT(DISTINCT CONVERTED_LEAD_ID)                                             AS CONVERTED_LEADS,
         ROUND(COUNT(DISTINCT CONVERTED_LEAD_ID)::NUMBER(32,18)
               / NULLIF(COUNT(DISTINCT LEAD_ID), 0), 6)                                AS LEAD_CONVERSION_RATE
  FROM lead_outcomes
  GROUP BY ROLLUP (CHANNEL)
),
with_pooled AS (            -- FLOAT inputs of the Wilson interval; the pooled margins from the TOTAL row
  SELECT b.*,
         CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)                    AS P,
         NULLIF(LEADS, 0)::FLOAT                                      AS N,
         1.959964::FLOAT                                              AS Z,
         MAX(IFF(IS_TOTAL = 1, CONVERTED_LEADS, NULL)) OVER ()        AS ALL_CONVERTED,
         MAX(IFF(IS_TOTAL = 1, LEADS, NULL)) OVER ()                  AS ALL_LEADS
  FROM by_channel b
),
cells AS (                  -- expected counts if conversion were independent of channel
  SELECT w.*,
         (LEADS * ALL_CONVERTED)::NUMBER(32,18) / ALL_LEADS           AS E_CONVERTED,
         POWER(CONVERTED_LEADS - LEADS::FLOAT * ALL_CONVERTED / ALL_LEADS, 2)
           / (LEADS::FLOAT * ALL_CONVERTED / ALL_LEADS)
         + POWER((LEADS - CONVERTED_LEADS) - LEADS::FLOAT * (ALL_LEADS - ALL_CONVERTED) / ALL_LEADS, 2)
           / (LEADS::FLOAT * (ALL_LEADS - ALL_CONVERTED) / ALL_LEADS)  AS CONTRIBUTION
  FROM with_pooled w
),
result AS (
  SELECT CHANNEL, IS_TOTAL, JOINED_ROWS, LEADS, CONVERTED_LEADS, LEAD_CONVERSION_RATE,
         ROUND((P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS LCR_CI_LOW,
         ROUND((P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS LCR_CI_HIGH,
         IFF(IS_TOTAL = 1, NULL, RANK() OVER (PARTITION BY IS_TOTAL ORDER BY LEAD_CONVERSION_RATE DESC)) AS RANK_BY_RATE,
         ROUND(E_CONVERTED, 6)                                                                         AS EXPECTED_CONVERTED,
         ROUND(IFF(IS_TOTAL = 1, SUM(IFF(IS_TOTAL = 0, CONTRIBUTION, 0)) OVER (), CONTRIBUTION), 6)::NUMBER(18,6) AS CHI_SQUARE_CONTRIBUTION
  FROM cells
),
expected (CHANNEL, LEADS, CONVERTED_LEADS, LEAD_CONVERSION_RATE, LCR_CI_LOW, LCR_CI_HIGH, EXPECTED_CONVERTED,
          CHI_SQUARE_CONTRIBUTION) AS (
  SELECT * FROM VALUES   -- rate [P3]; bounds [E02c 21], TOTAL [D]; expected count and contribution [D]
    ('affiliate',    67849, 10352, 0.152574, 0.149888, 0.155299, 10292.314028, 0.408018),
    ('display',      45149,  6744, 0.149372, 0.146114, 0.152690,  6848.850919, 1.892232),
    ('paid_search',  65268, 10019, 0.153506, 0.150760, 0.156291,  9900.790755, 1.663722),
    ('paid_social',  57619,  8648, 0.150089, 0.147196, 0.153029,  8740.480213, 1.153480),
    ('video',        25799,  3933, 0.152448, 0.148113, 0.156886,  3913.564085, 0.113785),
    ('TOTAL',       261684, 39696, 0.151694, 0.150325, 0.153074, 39696.000000, 5.231237)
)
SELECT COALESCE(r.CHANNEL, e.CHANNEL) AS CHANNEL, r.RANK_BY_RATE, r.LEADS, r.CONVERTED_LEADS, r.LEAD_CONVERSION_RATE,
       r.LCR_CI_LOW, r.LCR_CI_HIGH, r.EXPECTED_CONVERTED, r.CHI_SQUARE_CONTRIBUTION, r.JOINED_ROWS,
       CASE WHEN r.IS_TOTAL = 1 THEN 'n/a'
            WHEN m.LEADS = r.LEADS AND m.CONVERTED_LEADS = r.CONVERTED_LEADS AND m.LEAD_CONVERSION_RATE = r.LEAD_CONVERSION_RATE
                 AND m.LCR_CI_LOW = r.LCR_CI_LOW AND m.LCR_CI_HIGH = r.LCR_CI_HIGH THEN 'yes' ELSE 'NO' END AS EQUALS_CHANNEL_MART,
       IFF(r.JOINED_ROWS = r.LEADS AND r.LEADS = e.LEADS AND r.CONVERTED_LEADS = e.CONVERTED_LEADS
           AND r.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE AND r.LCR_CI_LOW = e.LCR_CI_LOW AND r.LCR_CI_HIGH = e.LCR_CI_HIGH
           AND r.EXPECTED_CONVERTED = e.EXPECTED_CONVERTED AND r.CHI_SQUARE_CONTRIBUTION = e.CHI_SQUARE_CONTRIBUTION
           AND (r.IS_TOTAL = 1 OR EQUALS_CHANNEL_MART = 'yes'), 'PASS', 'FAIL') AS STATUS
FROM result r
LEFT JOIN MART_CHANNEL_PERFORMANCE m ON m.CHANNEL = r.CHANNEL     -- 1:1; no mart row for TOTAL
FULL OUTER JOIN expected e ON e.CHANNEL = r.CHANNEL
ORDER BY r.IS_TOTAL, r.LEAD_CONVERSION_RATE DESC;


-- -----------------------------------------------------------------------------
-- 2.2 Chi-square test of independence: is the channel difference more than noise?
--    BUSINESS QUESTION  Are the channel conversion rates of 2.1 really different, or could a
--      0.41-point spread arise by chance with these sample sizes?
--    METHOD  The 5 x 2 contingency table (channel x converted / not converted) as 10 cell rows,
--      read from MART_CHANNEL_PERFORMANCE (LEADS, CONVERTED_LEADS: the same counts 2.1 rebuilt
--      from STAGING). Window sums give each cell its expected count under independence, row
--      total x column total / grand total; the statistic is SUM((O - E)^2 / E) over the 10
--      cells with df = (5 - 1) x (2 - 1) = 4. The p-value uses the closed form for df 4,
--      EXP(-x/2)(1 + x/2); the critical value 9.487729 at alpha 0.05 is a constant [Q].
--      Cramer's V = SQRT(statistic / N) measures the strength of the association (0 = none).
--    HOW TO READ  RESULT: statistic 5.231237 < 9.487729, p = 0.264383: independence is not
--      rejected. A spread at least this large would appear about one time in four if all five
--      channels converted at the same rate. Cramer's V 0.004471 says the association is
--      negligible even as a point estimate. Plainly: the channel differences in lead-to-
--      conversion rate are NOT distinguishable from noise at this sample size. On this evidence
--      the channels differ in how cheaply they produce leads (section 3), and no difference in
--      how well their leads convert is detectable.
--    CAVEATS  Assumes independent leads (header, "Statistics"). Not rejecting is not proof of
--      equal rates. With 25,799-67,849 leads per channel, one channel 1 point off the others
--      would be flagged 94% (video) to over 99% (affiliate) of the time, a 0.1-point gap only
--      6-7% of the time [PW]: a channel gap of a point would very likely have shown up, gaps of
--      a few tenths of a point would not, so they cannot be ruled out. Synthetic data (G6).
--    EXPECTED  Statistic, smallest expected count, p-value, Cramer's V [D]; df and verdict [C:
--      a 5 x 2 table; D: 5.231237 < 9.487729].
-- -----------------------------------------------------------------------------
WITH observed (CHANNEL, OUTCOME, OBSERVED) AS (   -- the 5 x 2 table, one row per cell
  SELECT CHANNEL, 'converted', CONVERTED_LEADS FROM MART_CHANNEL_PERFORMANCE
  UNION ALL
  SELECT CHANNEL, 'not converted', LEADS - CONVERTED_LEADS FROM MART_CHANNEL_PERFORMANCE
),
cells AS (                  -- E = row total x column total / grand total
  SELECT CHANNEL, OUTCOME, OBSERVED,
         SUM(OBSERVED) OVER (PARTITION BY CHANNEL)::FLOAT * SUM(OBSERVED) OVER (PARTITION BY OUTCOME)
           / SUM(OBSERVED) OVER ()                                            AS EXPECTED
  FROM observed
),
test AS (
  SELECT COUNT(*)                                                             AS CELLS,
         SUM(OBSERVED)                                                        AS N,
         MIN(EXPECTED)                                                        AS MIN_EXPECTED,
         SUM(POWER(OBSERVED - EXPECTED, 2) / EXPECTED)                        AS CHI_SQUARE,
         (COUNT(DISTINCT CHANNEL) - 1) * (COUNT(DISTINCT OUTCOME) - 1)        AS DF
  FROM cells
),
stats AS (
  SELECT t.*,
         IFF(DF = 4, EXP(-CHI_SQUARE / 2) * (1 + CHI_SQUARE / 2), NULL)       AS P_VALUE,   -- closed form, df 4 only
         SQRT(CHI_SQUARE / N)                                                 AS CRAMERS_V,  -- min(5, 2) - 1 = 1
         9.487729                                                             AS CRITICAL_05 -- [Q] chi-square(4), upper 5%
  FROM test t
)
SELECT ITEM, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL::NUMBER(38,6) = EXPECTED, 'PASS', 'FAIL') AS STATUS, READING
FROM (
            SELECT 1 AS ORD, 'cells (5 channels x 2 outcomes)' AS ITEM, CELLS AS ACTUAL, 10 AS EXPECTED,
                   'each lead sits in exactly one cell' AS READING FROM stats
  UNION ALL SELECT 2, 'leads in the table (N)', N, 261684, 'the 261,684 leads of 2.1' FROM stats
  UNION ALL SELECT 3, 'smallest expected cell count', ROUND(MIN_EXPECTED, 6), 3913.564085,
                   'video x converted; the test needs E >= 5' FROM stats
  UNION ALL SELECT 4, 'chi-square statistic, SUM((O-E)^2 / E)', ROUND(CHI_SQUARE, 6), 5.231237,
                   '= TOTAL row of 2.1, last column' FROM stats
  UNION ALL SELECT 5, 'degrees of freedom, (5-1) x (2-1)', DF, 4, 'critical value at alpha 0.05: 9.487729' FROM stats
  UNION ALL SELECT 6, 'p-value, EXP(-x/2)(1 + x/2) for df 4', ROUND(P_VALUE, 6), 0.264383,
                   'P(spread this large | equal rates)' FROM stats
  UNION ALL SELECT 7, 'Cramer''s V, SQRT(statistic / N)', ROUND(CRAMERS_V, 6), 0.004471,
                   'association: 0 = none, 1 = complete' FROM stats
  UNION ALL SELECT 8, 'reject independence at 0.05? (1 = yes)', IFF(CHI_SQUARE > CRITICAL_05, 1, 0), 0,
                   IFF(CHI_SQUARE > CRITICAL_05, 'YES: ', 'NO: ') || TO_VARCHAR(ROUND(CHI_SQUARE, 6))
                   || IFF(CHI_SQUARE > CRITICAL_05, ' > ', ' < ') || '9.487729: '
                   || IFF(CHI_SQUARE > CRITICAL_05, 'channels differ', 'within noise') FROM stats
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 2.3 Lead conversion rate by objective WITHIN each channel (15 cells), and a test per channel
--    BUSINESS QUESTION  Inside a channel, does the campaign objective (acquisition, awareness,
--      lead_gen) change how well leads convert?
--    METHOD  The COUNT(DISTINCT) / NULLIF rate of 2.1 at channel x objective grain, with
--      COUNT(DISTINCT CAMPAIGN_ID) to show how many campaigns stand behind each cell. Window
--      sums over PARTITION BY CHANNEL give each channel's own margins, so each channel gets its
--      own 3 x 2 chi-square test (df 2, p-value EXP(-x/2), critical value 5.991465 [Q]).
--      Objectives are compared within a channel, never across channels, because the two are
--      partly confounded: 17 of display's 24 campaigns are lead_gen, and display is 17 of the
--      41 lead_gen campaigns (CAMPAIGNS column; docs/data_profile.md).
--    HOW TO READ  RESULT: the largest within-channel gap is 0.003418 (affiliate: acquisition
--      0.154275 vs lead_gen 0.150857); no channel rejects independence (statistics 0.001199 to
--      0.958212, p-values 0.619337 to 0.999400). No association between objective and
--      conversion is detectable in any channel; that is not proof that there is none.
--    CAVEATS  Five tests at alpha 0.05 would give about 0.25 false alarms by chance; none
--      occurs, so no correction changes the verdict. The tests are weak where cells are small:
--      display acquisition (3 campaigns, 2,842 leads, interval 0.135550-0.161670) converting 1
--      point above display's other objectives would be flagged only about 23% of the time
--      [PW], so effects of about a point inside small cells cannot be ruled out. Independence
--      assumed (header).
--    EXPECTED  Every column [D]; channel rates [P3].
-- -----------------------------------------------------------------------------
WITH lead_outcomes AS (
  SELECT c.CHANNEL, c.OBJECTIVE, c.CAMPAIGN_ID, l.LEAD_ID, v.LEAD_ID AS CONVERTED_LEAD_ID
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c        ON c.CAMPAIGN_ID = l.CAMPAIGN_ID  -- n:1
),
cells AS (
  SELECT CHANNEL, OBJECTIVE,
         COUNT(DISTINCT CAMPAIGN_ID)                                                   AS CAMPAIGNS,
         COUNT(DISTINCT LEAD_ID)                                                       AS LEADS,
         COUNT(DISTINCT CONVERTED_LEAD_ID)                                             AS CONVERTED_LEADS,
         ROUND(COUNT(DISTINCT CONVERTED_LEAD_ID)::NUMBER(32,18)
               / NULLIF(COUNT(DISTINCT LEAD_ID), 0), 6)                                AS LEAD_CONVERSION_RATE
  FROM lead_outcomes
  GROUP BY CHANNEL, OBJECTIVE
),
margins AS (                -- the channel's own totals: the test is within the channel
  SELECT c.*,
         SUM(LEADS) OVER (PARTITION BY CHANNEL)            AS CHANNEL_LEADS,
         SUM(CONVERTED_LEADS) OVER (PARTITION BY CHANNEL)  AS CHANNEL_CONVERTED,
         CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)         AS P,
         NULLIF(LEADS, 0)::FLOAT                           AS N,
         1.959964::FLOAT                                   AS Z
  FROM cells c
),
contributions AS (          -- (O - E)^2 / E for the converted and the not-converted cell
  SELECT m.*,
         POWER(CONVERTED_LEADS - N * CHANNEL_CONVERTED / CHANNEL_LEADS, 2) / (N * CHANNEL_CONVERTED / CHANNEL_LEADS)
         + POWER((LEADS - CONVERTED_LEADS) - N * (CHANNEL_LEADS - CHANNEL_CONVERTED) / CHANNEL_LEADS, 2)
           / (N * (CHANNEL_LEADS - CHANNEL_CONVERTED) / CHANNEL_LEADS)                 AS CONTRIBUTION
  FROM margins m
),
result AS (
  SELECT CHANNEL, OBJECTIVE, CAMPAIGNS, LEADS, CONVERTED_LEADS, LEAD_CONVERSION_RATE,
         ROUND((P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS LCR_CI_LOW,
         ROUND((P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS LCR_CI_HIGH,
         ROUND(CHANNEL_CONVERTED::NUMBER(32,18) / NULLIF(CHANNEL_LEADS, 0), 6)                         AS CHANNEL_RATE,
         SUM(CONTRIBUTION) OVER (PARTITION BY CHANNEL)                                                 AS CHI_SQUARE,
         COUNT(*) OVER (PARTITION BY CHANNEL) - 1                                                      AS DF
  FROM contributions
),
expected (CHANNEL, OBJECTIVE, CAMPAIGNS, LEADS, CONVERTED_LEADS, LEAD_CONVERSION_RATE, LCR_CI_LOW, LCR_CI_HIGH,
          CHANNEL_RATE, CHI_SQUARE, P_VALUE) AS (
  SELECT * FROM VALUES   -- [D]; CHANNEL_RATE [P3]
    ('affiliate',   'acquisition',  8, 24573, 3791, 0.154275, 0.149813, 0.158845, 0.152574, 0.958212, 0.619337),
    ('affiliate',   'awareness',   11, 28686, 4360, 0.151991, 0.147883, 0.156192, 0.152574, 0.958212, 0.619337),
    ('affiliate',   'lead_gen',     5, 14590, 2201, 0.150857, 0.145141, 0.156756, 0.152574, 0.958212, 0.619337),
    ('display',     'acquisition',  3,  2842,  421, 0.148135, 0.135550, 0.161670, 0.149372, 0.267347, 0.874876),
    ('display',     'awareness',    4, 10956, 1622, 0.148047, 0.141520, 0.154820, 0.149372, 0.267347, 0.874876),
    ('display',     'lead_gen',    17, 31351, 4701, 0.149947, 0.146038, 0.153942, 0.149372, 0.267347, 0.874876),
    ('paid_search', 'acquisition',  9, 26662, 4121, 0.154565, 0.150275, 0.158953, 0.153506, 0.524872, 0.769176),
    ('paid_search', 'awareness',    7, 17922, 2725, 0.152048, 0.146865, 0.157379, 0.153506, 0.524872, 0.769176),
    ('paid_search', 'lead_gen',     8, 20684, 3173, 0.153404, 0.148557, 0.158379, 0.153506, 0.524872, 0.769176),
    ('paid_social', 'acquisition',  7, 13040, 1956, 0.150000, 0.143974, 0.156232, 0.150089, 0.001199, 0.999400),
    ('paid_social', 'awareness',   10, 26356, 3956, 0.150099, 0.145838, 0.154462, 0.150089, 0.001199, 0.999400),
    ('paid_social', 'lead_gen',     7, 18223, 2736, 0.150140, 0.145027, 0.155400, 0.150089, 0.001199, 0.999400),
    ('video',       'acquisition',  8,  7177, 1103, 0.153685, 0.145527, 0.162214, 0.152448, 0.118209, 0.942608),
    ('video',       'awareness',   12, 11677, 1775, 0.152008, 0.145611, 0.158635, 0.152448, 0.118209, 0.942608),
    ('video',       'lead_gen',     4,  6945, 1055, 0.151908, 0.143659, 0.160542, 0.152448, 0.118209, 0.942608)
)
SELECT COALESCE(r.CHANNEL, e.CHANNEL) AS CHANNEL, COALESCE(r.OBJECTIVE, e.OBJECTIVE) AS OBJECTIVE, r.CAMPAIGNS, r.LEADS,
       r.CONVERTED_LEADS, r.LEAD_CONVERSION_RATE, r.LCR_CI_LOW, r.LCR_CI_HIGH, r.CHANNEL_RATE,
       ROUND(r.CHI_SQUARE, 6)::NUMBER(18,6) AS CHI_SQUARE_IN_CHANNEL, r.DF,
       ROUND(IFF(r.DF = 2, EXP(-r.CHI_SQUARE / 2), NULL), 6)::NUMBER(18,6) AS P_VALUE,          -- closed form, df 2 only
       IFF(r.CHI_SQUARE > 5.991465, 'yes', 'no') AS DIFFERS_AT_05,                -- [Q] chi-square(2), upper 5%
       IFF(r.CAMPAIGNS = e.CAMPAIGNS AND r.LEADS = e.LEADS AND r.CONVERTED_LEADS = e.CONVERTED_LEADS
           AND r.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE AND r.LCR_CI_LOW = e.LCR_CI_LOW
           AND r.LCR_CI_HIGH = e.LCR_CI_HIGH AND r.CHANNEL_RATE = e.CHANNEL_RATE AND r.DF = 2
           AND ROUND(r.CHI_SQUARE, 6) = e.CHI_SQUARE AND ROUND(EXP(-r.CHI_SQUARE / 2), 6) = e.P_VALUE
           AND DIFFERS_AT_05 = 'no', 'PASS', 'FAIL') AS STATUS
FROM result r
FULL OUTER JOIN expected e ON e.CHANNEL = r.CHANNEL AND e.OBJECTIVE = r.OBJECTIVE
ORDER BY 1, 2;


-- -----------------------------------------------------------------------------
-- 2.4 Campaigns with the highest and the lowest lead conversion rate (10 + 10)
--    BUSINESS QUESTION  Which campaigns convert their leads best and worst, and is the gap real?
--    METHOD  The COUNT(DISTINCT) / NULLIF rate at campaign grain (120 campaigns); ROW_NUMBER()
--      with QUALIFY keeps the top and bottom 10 (ties broken by CAMPAIGN_ID; there are none at
--      6 dp); the Wilson interval of each campaign and whether it contains the pooled rate.
--    HOW TO READ  RESULT: the rates run from 0.096552 (CMP0084, video, 14 of 145 leads) to
--      0.187364 (CMP0054, video, 86 of 459 leads). Both extremes are small campaigns, and 16 of
--      these 20 intervals still contain the pooled 0.151694: wide intervals, not better or
--      worse campaigns. 2.5 tests all 120 at once.
--    CAVEATS  A top-10 list of 120 noisy rates selects lucky and unlucky campaigns (regression
--      to the mean): expect the next flight of a "best" campaign to convert closer to 15%.
--      Independence assumed (header). Synthetic data (G6).
--    EXPECTED  All 20 rows [D].
-- -----------------------------------------------------------------------------
WITH by_campaign AS (
  SELECT c.CAMPAIGN_ID, c.CAMPAIGN_NAME, c.CHANNEL, c.OBJECTIVE,
         COUNT(DISTINCT l.LEAD_ID)                                                     AS LEADS,
         COUNT(DISTINCT v.LEAD_ID)                                                     AS CONVERTED_LEADS,
         ROUND(COUNT(DISTINCT v.LEAD_ID)::NUMBER(32,18) / NULLIF(COUNT(DISTINCT l.LEAD_ID), 0), 6) AS LEAD_CONVERSION_RATE
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c        ON c.CAMPAIGN_ID = l.CAMPAIGN_ID  -- n:1
  GROUP BY c.CAMPAIGN_ID, c.CAMPAIGN_NAME, c.CHANNEL, c.OBJECTIVE
),
pooled AS (
  SELECT SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS) AS POOLED_RATE FROM by_campaign
),
ranked AS (
  SELECT 'highest 10' AS RANKING, ROW_NUMBER() OVER (ORDER BY LEAD_CONVERSION_RATE DESC, CAMPAIGN_ID) AS RANK_IN_LIST, b.*
  FROM by_campaign b
  QUALIFY ROW_NUMBER() OVER (ORDER BY LEAD_CONVERSION_RATE DESC, CAMPAIGN_ID) <= 10
  UNION ALL
  SELECT 'lowest 10', ROW_NUMBER() OVER (ORDER BY LEAD_CONVERSION_RATE ASC, CAMPAIGN_ID), b.*
  FROM by_campaign b
  QUALIFY ROW_NUMBER() OVER (ORDER BY LEAD_CONVERSION_RATE ASC, CAMPAIGN_ID) <= 10
),
with_ci AS (
  SELECT r.*, p.POOLED_RATE,
         ROUND((r.CONVERTED_LEADS::FLOAT / r.LEADS + POWER(1.959964::FLOAT, 2) / (2 * r.LEADS)
                - 1.959964::FLOAT * SQRT(r.CONVERTED_LEADS::FLOAT / r.LEADS * (1 - r.CONVERTED_LEADS::FLOAT / r.LEADS) / r.LEADS
                                         + POWER(1.959964::FLOAT, 2) / (4 * r.LEADS * r.LEADS)))
               / (1 + POWER(1.959964::FLOAT, 2) / r.LEADS), 6)::NUMBER(18,6) AS LCR_CI_LOW,
         ROUND((r.CONVERTED_LEADS::FLOAT / r.LEADS + POWER(1.959964::FLOAT, 2) / (2 * r.LEADS)
                + 1.959964::FLOAT * SQRT(r.CONVERTED_LEADS::FLOAT / r.LEADS * (1 - r.CONVERTED_LEADS::FLOAT / r.LEADS) / r.LEADS
                                         + POWER(1.959964::FLOAT, 2) / (4 * r.LEADS * r.LEADS)))
               / (1 + POWER(1.959964::FLOAT, 2) / r.LEADS), 6)::NUMBER(18,6) AS LCR_CI_HIGH
  FROM ranked r
  CROSS JOIN pooled p                                                -- one row
),
expected (RANKING, RANK_IN_LIST, CAMPAIGN_ID, LEADS, CONVERTED_LEADS, LEAD_CONVERSION_RATE, LCR_CI_LOW, LCR_CI_HIGH) AS (
  SELECT * FROM VALUES   -- [D]
    ('highest 10',  1, 'CMP0054',  459,  86, 0.187364, 0.154315, 0.225602),
    ('highest 10',  2, 'CMP0029', 1142, 201, 0.176007, 0.155016, 0.199170),
    ('highest 10',  3, 'CMP0030', 2205, 366, 0.165986, 0.151040, 0.182094),
    ('highest 10',  4, 'CMP0086', 1277, 211, 0.165231, 0.145871, 0.186599),
    ('highest 10',  5, 'CMP0058', 1246, 203, 0.162921, 0.143458, 0.184457),
    ('highest 10',  6, 'CMP0115', 1925, 313, 0.162597, 0.146788, 0.179750),
    ('highest 10',  7, 'CMP0061', 4239, 688, 0.162302, 0.151509, 0.173707),
    ('highest 10',  8, 'CMP0002', 1849, 300, 0.162250, 0.146148, 0.179752),
    ('highest 10',  9, 'CMP0028',  272,  44, 0.161765, 0.122765, 0.210185),
    ('highest 10', 10, 'CMP0026', 3653, 590, 0.161511, 0.149934, 0.173799),
    ('lowest 10',   1, 'CMP0084',  145,  14, 0.096552, 0.058387, 0.155541),
    ('lowest 10',   2, 'CMP0074',  934, 119, 0.127409, 0.107541, 0.150329),
    ('lowest 10',   3, 'CMP0034', 1044, 140, 0.134100, 0.114765, 0.156117),
    ('lowest 10',   4, 'CMP0083', 2404, 329, 0.136855, 0.123694, 0.151175),
    ('lowest 10',   5, 'CMP0068', 2854, 396, 0.138753, 0.126555, 0.151922),
    ('lowest 10',   6, 'CMP0007', 1699, 237, 0.139494, 0.123831, 0.156783),
    ('lowest 10',   7, 'CMP0108', 2461, 344, 0.139781, 0.126641, 0.154043),
    ('lowest 10',   8, 'CMP0098', 1619, 227, 0.140210, 0.124148, 0.157976),
    ('lowest 10',   9, 'CMP0032', 2300, 323, 0.140435, 0.126834, 0.155234),
    ('lowest 10',  10, 'CMP0042', 1785, 251, 0.140616, 0.125260, 0.157516)
)
SELECT COALESCE(w.RANKING, e.RANKING) AS RANKING, COALESCE(w.RANK_IN_LIST, e.RANK_IN_LIST) AS RANK_IN_LIST,
       w.CAMPAIGN_ID, w.CAMPAIGN_NAME, w.CHANNEL, w.OBJECTIVE, w.LEADS, w.CONVERTED_LEADS, w.LEAD_CONVERSION_RATE,
       w.LCR_CI_LOW, w.LCR_CI_HIGH,
       IFF(w.POOLED_RATE BETWEEN w.LCR_CI_LOW AND w.LCR_CI_HIGH, 'yes', 'NO') AS CI_CONTAINS_POOLED_RATE,
       IFF(w.CAMPAIGN_ID = e.CAMPAIGN_ID AND w.LEADS = e.LEADS AND w.CONVERTED_LEADS = e.CONVERTED_LEADS
           AND w.LEAD_CONVERSION_RATE = e.LEAD_CONVERSION_RATE AND w.LCR_CI_LOW = e.LCR_CI_LOW
           AND w.LCR_CI_HIGH = e.LCR_CI_HIGH, 'PASS', 'FAIL') AS STATUS
FROM with_ci w
FULL OUTER JOIN expected e ON e.RANKING = w.RANKING AND e.RANK_IN_LIST = w.RANK_IN_LIST
ORDER BY 1, 2;


-- -----------------------------------------------------------------------------
-- 2.5 Campaign spread vs noise: all 120 campaigns at once
--    BUSINESS QUESTION  Do campaigns differ in lead conversion more than chance allows?
--    METHOD  The campaign rates of 2.4 for all 120 campaigns, reconciled with
--      MART_CAMPAIGN_PERFORMANCE.LEAD_CONVERSION_RATE; two noise yardsticks:
--      - Wilson 95% intervals that exclude the pooled rate: with no real differences, about
--        5% of 120 = 6 would by chance;
--      - the chi-square test over the 120 x 2 table (df 119, critical value 145.460740 [Q];
--        df is odd, so there is no closed-form p-value in SQL).
--    HOW TO READ  RESULT: 4 of 120 intervals exclude the pooled rate (fewer than the 6 expected
--      by chance), and the statistic 98.971941 is far below 145.460740. The spread from 9.7% to
--      18.7% is consistent with 120 samples of 145 to 5,104 leads (checks 5, 6) drawn at one
--      common rate: there is no evidence that any campaign converts its leads better or worse.
--      That is not proof of equal rates: a single small campaign has an interval several points
--      wide (2.4: CMP0054, 459 leads, 0.154315-0.225602), so a gap of a point or two in one
--      campaign could not be detected.
--    CAVEATS  Independence assumed (header). Cost differences between campaigns are large
--      (3.3); conversion differences are not detectable. Synthetic data (G6).
--    EXPECTED  [D]; df [C: a 120 x 2 table].
-- -----------------------------------------------------------------------------
WITH by_campaign AS (
  SELECT l.CAMPAIGN_ID,
         COUNT(DISTINCT l.LEAD_ID)                                                     AS LEADS,
         COUNT(DISTINCT v.LEAD_ID)                                                     AS CONVERTED_LEADS,
         ROUND(COUNT(DISTINCT v.LEAD_ID)::NUMBER(32,18) / NULLIF(COUNT(DISTINCT l.LEAD_ID), 0), 6) AS LEAD_CONVERSION_RATE
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1
  GROUP BY l.CAMPAIGN_ID
),
pooled AS (
  SELECT SUM(CONVERTED_LEADS)::FLOAT / SUM(LEADS) AS P0 FROM by_campaign
),
tested AS (                 -- Wilson bounds and the two chi-square cells of each campaign, in FLOAT
  SELECT b.*, p.P0,
         (CONVERTED_LEADS::FLOAT / LEADS + POWER(1.959964::FLOAT, 2) / (2 * LEADS)
          - 1.959964::FLOAT * SQRT(CONVERTED_LEADS::FLOAT / LEADS * (1 - CONVERTED_LEADS::FLOAT / LEADS) / LEADS
                                   + POWER(1.959964::FLOAT, 2) / (4 * LEADS * LEADS)))
         / (1 + POWER(1.959964::FLOAT, 2) / LEADS)                                    AS CI_LOW,
         (CONVERTED_LEADS::FLOAT / LEADS + POWER(1.959964::FLOAT, 2) / (2 * LEADS)
          + 1.959964::FLOAT * SQRT(CONVERTED_LEADS::FLOAT / LEADS * (1 - CONVERTED_LEADS::FLOAT / LEADS) / LEADS
                                   + POWER(1.959964::FLOAT, 2) / (4 * LEADS * LEADS)))
         / (1 + POWER(1.959964::FLOAT, 2) / LEADS)                                    AS CI_HIGH,
         POWER(CONVERTED_LEADS - LEADS * p.P0, 2) / (LEADS * p.P0)
         + POWER((LEADS - CONVERTED_LEADS) - LEADS * (1 - p.P0), 2) / (LEADS * (1 - p.P0)) AS CONTRIBUTION
  FROM by_campaign b
  CROSS JOIN pooled p                                                -- one row
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL::NUMBER(38,6) = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'campaigns' AS CHECK_NAME, COUNT(*) AS ACTUAL, 120 AS EXPECTED FROM tested
  UNION ALL SELECT 2, 'rates = MART_CAMPAIGN_PERFORMANCE', COUNT(*), 120
            FROM tested t JOIN MART_CAMPAIGN_PERFORMANCE m
              ON m.CAMPAIGN_ID = t.CAMPAIGN_ID AND m.LEADS = t.LEADS AND m.CONVERTED_LEADS = t.CONVERTED_LEADS
             AND m.LEAD_CONVERSION_RATE = t.LEAD_CONVERSION_RATE
  UNION ALL SELECT 3, 'lowest rate (CMP0084, 145 leads)', MIN(LEAD_CONVERSION_RATE), 0.096552 FROM tested
  UNION ALL SELECT 4, 'highest rate (CMP0054, 459 leads)', MAX(LEAD_CONVERSION_RATE), 0.187364 FROM tested
  UNION ALL SELECT 5, 'fewest leads of a campaign', MIN(LEADS), 145 FROM tested
  UNION ALL SELECT 6, 'most leads of a campaign', MAX(LEADS), 5104 FROM tested
  UNION ALL SELECT 7, 'smallest expected conversions (>= 5)', ROUND(MIN(LEADS * P0), 6), 21.995689 FROM tested
  UNION ALL SELECT 8, 'CIs excluding pooled rate (chance: ~6)',
                   COUNT_IF(P0 NOT BETWEEN CI_LOW AND CI_HIGH), 4 FROM tested
  UNION ALL SELECT 9, 'chi-square, 120 campaigns x 2 outcomes', ROUND(SUM(CONTRIBUTION), 6), 98.971941 FROM tested
  UNION ALL SELECT 10, 'degrees of freedom, (120 - 1) x (2 - 1)', COUNT(*) - 1, 119 FROM tested
  UNION ALL SELECT 11, 'reject at 0.05? (> 145.460740; 1 = yes)',
                   IFF(SUM(CONTRIBUTION) > 145.460740, 1, 0), 0 FROM tested
)
ORDER BY ORD;


-- =============================================================================
-- SECTION 3. #5 Cost per Lead / Conversion (SUM, CASE WHEN, NULLIF)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Cost per lead, per conversion and per purchase by channel
--    BUSINESS QUESTION  What does a lead, a converted lead and a purchase cost in each channel?
--    METHOD  SUM and CASE WHEN (plan #5), aggregate first, then join (G1):
--      STEP 1  spend, impressions and clicks per channel from the delivery fact (campaign x day);
--      STEP 2  the outcomes per channel from the lead fact in one pass with conditional sums,
--              SUM(CASE WHEN v.CONVERSION_TYPE = 'purchase' THEN 1 ELSE 0 END) AS PURCHASES, ...;
--      STEP 3  join the two 1:1 on CHANNEL; ROLLUP adds the TOTAL as sums of the bases; every
--              cost is SUM(SPEND) / NULLIF(SUM(units), 0). The upstream drivers decompose the
--              cost per lead: CPL = CPC / click-to-lead rate = CPC x CLICKS_PER_LEAD, and
--              CPC = CPM / (1,000 x CTR); RANK_CPC_CPL_CPP prints the channel's rank (1 =
--              cheapest) by cost per click / per lead / per purchase.
--    HOW TO READ  RESULT: affiliate is the cheapest channel at every step (CPL 12.6433, cost per
--      purchase 198.0229), video the most expensive (32.0979, 505.5522): 505.5522 / 198.0229 =
--      2.55x per purchase. The channel order of CPL is the order of the cost per click (CPC
--      0.3594 affiliate to 1.6814 video; RANK_CPC_CPL_CPP runs 1/1/1 to 5/5/5). CPC combines
--      the channel's near-round CPM (6.5000 to 18.0004, a generator constant, G6) with its CTR
--      (1.1). The order is NOT explained by how many impressions or clicks a lead needs: clicks
--      per lead run in nearly the opposite order (affiliate 35.1789, the most; video 19.0895,
--      the fewest), and paid_search needs the fewest impressions per lead (763.5810) yet ranks
--      second, because its CPM (18.0004) is the highest. The order then holds at all three
--      steps because the lead conversion rate (0.149372-0.153506, 2.2) and the purchase share
--      (0.416476-0.425712, 1.1) barely differ by channel: the cost gap is made upstream, by the
--      price of a click, not by lead quality.
--    CAVEATS  Cost per purchase divides ALL spend by last-touch attributed purchases: it is not
--      a causal acquisition cost, and trials that might become purchases later are not
--      observed. The cost structure (near-round CPMs per channel) is a generator artefact (G6),
--      so the CPC ranking describes this data set, not media prices in a real market.
--    EXPECTED  Bases and costs [P3]/[PUB]; CPM, CPC, impressions and clicks per lead [D]; every
--      channel equal to MART_CHANNEL_PERFORMANCE (CPM and CPC included).
-- -----------------------------------------------------------------------------
WITH spend_by_channel AS (            -- STEP 1: campaign x day -> channel
  SELECT c.CHANNEL, SUM(s.SPEND) AS SPEND, SUM(s.IMPRESSIONS) AS IMPRESSIONS, SUM(s.CLICKS) AS CLICKS
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND s
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID          -- n:1
  GROUP BY c.CHANNEL
),
outcomes_by_channel AS (              -- STEP 2: lead (1:0..1 conversion) -> channel, one pass
  SELECT c.CHANNEL,
         COUNT(*)                                                          AS LEADS,
         SUM(CASE WHEN v.LEAD_ID IS NOT NULL         THEN 1 ELSE 0 END)    AS CONVERTED_LEADS,
         SUM(CASE WHEN v.CONVERSION_TYPE = 'trial'    THEN 1 ELSE 0 END)   AS TRIALS,
         SUM(CASE WHEN v.CONVERSION_TYPE = 'purchase' THEN 1 ELSE 0 END)   AS PURCHASES
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID           -- 1:0..1
  JOIN MARKETING_CRM.STAGING.STG_CAMPAIGNS c        ON c.CAMPAIGN_ID = l.CAMPAIGN_ID   -- n:1
  GROUP BY c.CHANNEL
),
channel_grain AS (                    -- STEP 3: one row per channel on both sides -> 1:1; + TOTAL
  SELECT IFF(GROUPING(s.CHANNEL) = 1, 'TOTAL', s.CHANNEL) AS CHANNEL, GROUPING(s.CHANNEL) AS IS_TOTAL,
         SUM(s.SPEND) AS SPEND, SUM(s.IMPRESSIONS) AS IMPRESSIONS, SUM(s.CLICKS) AS CLICKS,
         SUM(o.LEADS) AS LEADS, SUM(o.CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(o.TRIALS) AS TRIALS, SUM(o.PURCHASES) AS PURCHASES
  FROM spend_by_channel s
  JOIN outcomes_by_channel o ON o.CHANNEL = s.CHANNEL
  GROUP BY ROLLUP (s.CHANNEL)
),
costs AS (
  SELECT g.*,
         ROUND(SPEND::NUMBER(32,18) * 1000 / NULLIF(IMPRESSIONS, 0), 4) AS CPM,          -- upstream drivers
         ROUND(SPEND::NUMBER(32,18) / NULLIF(CLICKS, 0), 4)             AS CPC,
         ROUND(IMPRESSIONS::NUMBER(32,18) / NULLIF(LEADS, 0), 4)        AS IMPRESSIONS_PER_LEAD,
         ROUND(CLICKS::NUMBER(32,18) / NULLIF(LEADS, 0), 4)             AS CLICKS_PER_LEAD,
         ROUND(SPEND::NUMBER(32,18) / NULLIF(LEADS, 0), 4)              AS COST_PER_LEAD,  -- costs per outcome
         ROUND(SPEND::NUMBER(32,18) / NULLIF(CONVERTED_LEADS, 0), 4)    AS COST_PER_CONVERSION,
         ROUND(SPEND::NUMBER(32,18) / NULLIF(PURCHASES, 0), 4)          AS COST_PER_PURCHASE
  FROM channel_grain g
),
ranked AS (                           -- 1 = cheapest; the TOTAL row is ranked on its own and not printed
  SELECT k.*,
         RANK() OVER (PARTITION BY IS_TOTAL ORDER BY CPC)               AS RANK_CPC,
         RANK() OVER (PARTITION BY IS_TOTAL ORDER BY COST_PER_LEAD)     AS RANK_CPL,
         RANK() OVER (PARTITION BY IS_TOTAL ORDER BY COST_PER_PURCHASE) AS RANK_CPP
  FROM costs k
),
expected (CHANNEL, SPEND, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, COST_PER_LEAD, COST_PER_CONVERSION, COST_PER_PURCHASE,
          CPM, CPC, IMPRESSIONS_PER_LEAD, CLICKS_PER_LEAD) AS (
  SELECT * FROM VALUES   -- [P3]/[PUB]; CPM, CPC, impressions and clicks per lead [D]
    ('affiliate',    857835.07,  67849, 10352,  6020,  4332, 12.6433,  82.8666, 198.0229,  9.0001, 0.3594, 1404.7966, 35.1789),
    ('display',      955297.00,  45149,  6744,  3873,  2871, 21.1588, 141.6514, 332.7402,  6.5000, 1.0857, 3255.1704, 19.4882),
    ('paid_search',  897091.53,  65268, 10019,  5815,  4204, 13.7447,  89.5390, 213.3900, 18.0004, 0.5155,  763.5810, 26.6641),
    ('paid_social',  984731.88,  57619,  8648,  5002,  3646, 17.0904, 113.8682, 270.0855, 11.0001, 0.6144, 1553.6579, 27.8170),
    ('video',        828094.54,  25799,  3933,  2295,  1638, 32.0979, 210.5504, 505.5522, 15.0002, 1.6814, 2139.8298, 19.0895),
    ('TOTAL',       4523050.02, 261684, 39696, 23005, 16691, 17.2844, 113.9422, 270.9874, 10.3539, 0.6368, 1669.3601, 27.1408)
)
SELECT COALESCE(c.CHANNEL, e.CHANNEL) AS CHANNEL, c.SPEND, c.LEADS, c.CONVERTED_LEADS, c.TRIALS, c.PURCHASES,
       c.CPM, c.CPC, c.IMPRESSIONS_PER_LEAD, c.CLICKS_PER_LEAD,
       c.COST_PER_LEAD, c.COST_PER_CONVERSION, c.COST_PER_PURCHASE,
       IFF(c.IS_TOTAL = 1, 'n/a', c.RANK_CPC || '/' || c.RANK_CPL || '/' || c.RANK_CPP) AS RANK_CPC_CPL_CPP,
       CASE WHEN c.IS_TOTAL = 1 THEN 'n/a'
            WHEN m.SPEND = c.SPEND AND m.CPM = c.CPM AND m.CPC = c.CPC AND m.COST_PER_LEAD = c.COST_PER_LEAD
                 AND m.COST_PER_CONVERSION = c.COST_PER_CONVERSION AND m.COST_PER_PURCHASE = c.COST_PER_PURCHASE
                 THEN 'yes' ELSE 'NO' END AS EQUALS_CHANNEL_MART,
       IFF(c.SPEND = e.SPEND AND c.LEADS = e.LEADS AND c.CONVERTED_LEADS = e.CONVERTED_LEADS AND c.TRIALS = e.TRIALS
           AND c.PURCHASES = e.PURCHASES AND c.COST_PER_LEAD = e.COST_PER_LEAD
           AND c.COST_PER_CONVERSION = e.COST_PER_CONVERSION AND c.COST_PER_PURCHASE = e.COST_PER_PURCHASE
           AND c.CPM = e.CPM AND c.CPC = e.CPC AND c.IMPRESSIONS_PER_LEAD = e.IMPRESSIONS_PER_LEAD
           AND c.CLICKS_PER_LEAD = e.CLICKS_PER_LEAD
           -- the reading of HOW TO READ: the CPC order is the CPL order and the cost-per-purchase order
           AND (c.IS_TOTAL = 1 OR (c.RANK_CPC = c.RANK_CPL AND c.RANK_CPL = c.RANK_CPP))
           AND (c.IS_TOTAL = 1 OR EQUALS_CHANNEL_MART = 'yes'), 'PASS', 'FAIL') AS STATUS
FROM ranked c
LEFT JOIN MART_CHANNEL_PERFORMANCE m ON m.CHANNEL = c.CHANNEL     -- 1:1; no mart row for TOTAL
FULL OUTER JOIN expected e ON e.CHANNEL = c.CHANNEL
ORDER BY c.IS_TOTAL, c.COST_PER_PURCHASE;


-- -----------------------------------------------------------------------------
-- 3.2 The zero-lead spend days (NULLIF) and the campaign-grain reconciliation
--    BUSINESS QUESTION  What does cost per lead do on a day that bought no lead, and does the
--      campaign cost table hold for all 120 campaigns?
--    METHOD  Leads are aggregated to campaign x created date FIRST, then LEFT JOINed 1:1 to the
--      spend days (G1); SPEND / NULLIF(LEADS, 0) returns NULL on a 0-lead day instead of a
--      division-by-zero error or a fake 0. The campaign table adds conversions by campaign
--      with SUM(CASE WHEN) and is compared with MART_CAMPAIGN_PERFORMANCE.
--    HOW TO READ  RESULT: 7 spend days have no lead; all 7 belong to CMP0084 (video; checks 9,
--      10), together 303.34 of spend. Their daily CPL is NULL. Averaging the daily CPLs (WRONG
--      on purpose) gives 20.8479: it drops those 7 days' spend and weights every day equally,
--      whatever its spend (37.14 to 1,478.36 a day, checks 4, 5). The correct CPL is the ratio
--      of sums, 17.2844.
--    CAVEATS  NULLIF keeps the spend of a 0-lead day in every SUM(SPEND); only the per-day ratio
--      is undefined. Cost per purchase of a small campaign rests on few purchases: CMP0084 has
--      7, the fewest of any campaign and the only one with so few (checks 15-17).
--    EXPECTED  [E01 23] 7 days; [E01 14] the daily spend range; [D] their spend, campaign, the
--      mean of daily CPL and the purchase minimum; [P3] the totals and the ratio of sums;
--      MART_CAMPAIGN_PERFORMANCE for the 120 campaigns.
-- -----------------------------------------------------------------------------
WITH leads_by_day AS (                -- leads -> one row per campaign x created date
  SELECT CAMPAIGN_ID, CREATED_DATE, COUNT(*) AS LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS
  GROUP BY CAMPAIGN_ID, CREATED_DATE
),
daily AS (                            -- one row per spend day; the leads side is unique per key -> 1:1
  SELECT s.CAMPAIGN_ID, s.SPEND_DATE, s.SPEND, COALESCE(d.LEADS, 0) AS LEADS,
         s.SPEND::NUMBER(32,18) / NULLIF(COALESCE(d.LEADS, 0), 0) AS DAILY_CPL   -- NULL, not an error, on a 0-lead day
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND s
  LEFT JOIN leads_by_day d ON d.CAMPAIGN_ID = s.CAMPAIGN_ID AND d.CREATED_DATE = s.SPEND_DATE
),
conversions_by_campaign AS (          -- converted lead -> campaign (the lead join is 1:1)
  SELECT l.CAMPAIGN_ID,
         COUNT(*)                                                         AS CONVERTED_LEADS,
         SUM(CASE WHEN v.CONVERSION_TYPE = 'purchase' THEN 1 ELSE 0 END)  AS PURCHASES
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  GROUP BY l.CAMPAIGN_ID
),
campaign_costs AS (                   -- daily rows -> campaign, then 1:1 with the conversions
  SELECT d.CAMPAIGN_ID, SUM(d.SPEND) AS SPEND, SUM(d.LEADS) AS LEADS,
         MAX(v.CONVERTED_LEADS) AS CONVERTED_LEADS, MAX(v.PURCHASES) AS PURCHASES,   -- one value per campaign
         ROUND(SUM(d.SPEND)::NUMBER(32,18) / NULLIF(SUM(d.LEADS), 0), 4)            AS COST_PER_LEAD,
         ROUND(SUM(d.SPEND)::NUMBER(32,18) / NULLIF(MAX(v.CONVERTED_LEADS), 0), 4)  AS COST_PER_CONVERSION,
         ROUND(SUM(d.SPEND)::NUMBER(32,18) / NULLIF(MAX(v.PURCHASES), 0), 4)        AS COST_PER_PURCHASE
  FROM daily d
  LEFT JOIN conversions_by_campaign v ON v.CAMPAIGN_ID = d.CAMPAIGN_ID              -- n:1 (one row per campaign)
  GROUP BY d.CAMPAIGN_ID
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL::NUMBER(38,6) = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'spend days (rows after the 1:1 join)' AS CHECK_NAME, COUNT(*) AS ACTUAL, 11240 AS EXPECTED FROM daily
  UNION ALL SELECT 2, 'SUM(SPEND) after the join (no fan-out)', SUM(SPEND), 4523050.02 FROM daily
  UNION ALL SELECT 3, 'SUM(LEADS) after the join', SUM(LEADS), 261684 FROM daily
  UNION ALL SELECT 4, 'lowest daily spend', MIN(SPEND), 37.14 FROM daily
  UNION ALL SELECT 5, 'highest daily spend', MAX(SPEND), 1478.36 FROM daily
  UNION ALL SELECT 6, 'spend days with 0 leads', COUNT_IF(LEADS = 0), 7 FROM daily
  UNION ALL SELECT 7, '... of which DAILY_CPL is NULL (NULLIF)', COUNT_IF(LEADS = 0 AND DAILY_CPL IS NULL), 7 FROM daily
  UNION ALL SELECT 8, '... their spend', SUM(IFF(LEADS = 0, SPEND, 0)), 303.34 FROM daily
  UNION ALL SELECT 9, '... distinct campaigns among them', COUNT(DISTINCT IFF(LEADS = 0, CAMPAIGN_ID, NULL)), 1 FROM daily
  UNION ALL SELECT 10, '... of them in CMP0084', COUNT_IF(LEADS = 0 AND CAMPAIGN_ID = 'CMP0084'), 7 FROM daily
  UNION ALL SELECT 11, 'spend days with a defined daily CPL', COUNT(DAILY_CPL), 11233 FROM daily
  UNION ALL SELECT 12, 'WRONG on purpose: AVG(daily CPL)', ROUND(AVG(DAILY_CPL), 4), 20.8479 FROM daily
  UNION ALL SELECT 13, 'cost per lead, SUM(SPEND) / SUM(LEADS)', ROUND(SUM(SPEND)::NUMBER(32,18) / NULLIF(SUM(LEADS), 0), 4),
                   17.2844 FROM daily
  UNION ALL SELECT 14, 'costs = MART_CAMPAIGN_PERFORMANCE', COUNT(*), 120
            FROM campaign_costs c JOIN MART_CAMPAIGN_PERFORMANCE m
              ON m.CAMPAIGN_ID = c.CAMPAIGN_ID AND m.SPEND = c.SPEND AND m.LEADS = c.LEADS
             AND m.COST_PER_LEAD = c.COST_PER_LEAD AND m.COST_PER_CONVERSION = c.COST_PER_CONVERSION
             AND m.COST_PER_PURCHASE = c.COST_PER_PURCHASE
  UNION ALL SELECT 15, 'fewest purchases of a campaign', MIN(COALESCE(PURCHASES, 0)), 7 FROM campaign_costs
  UNION ALL SELECT 16, '... purchases of CMP0084', MAX(IFF(CAMPAIGN_ID = 'CMP0084', PURCHASES, NULL)), 7 FROM campaign_costs
  UNION ALL SELECT 17, '... campaigns with <= 7 (only CMP0084)', COUNT_IF(COALESCE(PURCHASES, 0) <= 7), 1 FROM campaign_costs
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 3.3 Campaigns with the cheapest and the most expensive purchase (10 + 10)
--    BUSINESS QUESTION  Which campaigns acquire purchasing customers most and least cheaply
--      (question 3, on the cost side; ROAS is in 06_marketing_efficiency.sql)?
--    METHOD  Spend aggregated per campaign, outcomes per campaign with SUM(CASE WHEN ...), each
--      in its own CTE and joined 1:1 to STG_CAMPAIGNS; costs with NULLIF; ROW_NUMBER() with
--      QUALIFY for both ends of the ranking (ties broken by CAMPAIGN_ID; none at 4 dp).
--    HOW TO READ  RESULT: 9 of the 10 cheapest campaigns per purchase are affiliate (CMP0040
--      cheapest at 102.1979, then CMP0070 and CMP0080), the other is paid_search CMP0086;
--      9 of the 10 most expensive are video (CMP0084 at 872.1900 on 7 purchases), the other is
--      display CMP0018. The campaign ranking mirrors the channel cost order of 3.1.
--    CAVEATS  Cost per purchase is spend / last-touch attributed purchases, not causal (G4).
--      Small campaigns are noisy: CMP0084 has 7 purchases, CMP0018 11. Synthetic data (G6).
--    EXPECTED  All 20 rows [D].
-- -----------------------------------------------------------------------------
WITH spend_by_campaign AS (
  SELECT CAMPAIGN_ID, SUM(SPEND) AS SPEND
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND
  GROUP BY CAMPAIGN_ID
),
outcomes_by_campaign AS (
  SELECT l.CAMPAIGN_ID,
         COUNT(*)                                                         AS LEADS,
         SUM(CASE WHEN v.LEAD_ID IS NOT NULL THEN 1 ELSE 0 END)           AS CONVERTED_LEADS,
         SUM(CASE WHEN v.CONVERSION_TYPE = 'purchase' THEN 1 ELSE 0 END)  AS PURCHASES
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID           -- 1:0..1
  GROUP BY l.CAMPAIGN_ID
),
campaign_costs AS (                   -- 1:1 joins: each input has one row per campaign
  SELECT c.CAMPAIGN_ID, c.CAMPAIGN_NAME, c.CHANNEL, c.OBJECTIVE, s.SPEND, o.LEADS, o.CONVERTED_LEADS, o.PURCHASES,
         ROUND(s.SPEND::NUMBER(32,18) / NULLIF(o.LEADS, 0), 4)            AS COST_PER_LEAD,
         ROUND(s.SPEND::NUMBER(32,18) / NULLIF(o.CONVERTED_LEADS, 0), 4)  AS COST_PER_CONVERSION,
         ROUND(s.SPEND::NUMBER(32,18) / NULLIF(o.PURCHASES, 0), 4)        AS COST_PER_PURCHASE
  FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS c
  LEFT JOIN spend_by_campaign s    ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
  LEFT JOIN outcomes_by_campaign o ON o.CAMPAIGN_ID = c.CAMPAIGN_ID
),
ranked AS (
  SELECT 'cheapest 10' AS RANKING, ROW_NUMBER() OVER (ORDER BY COST_PER_PURCHASE ASC, CAMPAIGN_ID) AS RANK_IN_LIST, k.*
  FROM campaign_costs k
  QUALIFY ROW_NUMBER() OVER (ORDER BY COST_PER_PURCHASE ASC, CAMPAIGN_ID) <= 10
  UNION ALL
  SELECT 'most expensive 10', ROW_NUMBER() OVER (ORDER BY COST_PER_PURCHASE DESC, CAMPAIGN_ID), k.*
  FROM campaign_costs k
  QUALIFY ROW_NUMBER() OVER (ORDER BY COST_PER_PURCHASE DESC, CAMPAIGN_ID) <= 10
),
expected (RANKING, RANK_IN_LIST, CAMPAIGN_ID, SPEND, LEADS, CONVERTED_LEADS, PURCHASES, COST_PER_LEAD,
          COST_PER_CONVERSION, COST_PER_PURCHASE) AS (
  SELECT * FROM VALUES   -- [D]
    ('cheapest 10',        1, 'CMP0040', 14920.90, 2064, 321, 146,  7.2291,  46.4826, 102.1979),
    ('cheapest 10',        2, 'CMP0070', 17318.50, 2587, 381, 167,  6.6944,  45.4554, 103.7036),
    ('cheapest 10',        3, 'CMP0080', 17904.18, 2644, 394, 172,  6.7716,  45.4421, 104.0941),
    ('cheapest 10',        4, 'CMP0095', 17881.69, 2639, 385, 166,  6.7759,  46.4459, 107.7210),
    ('cheapest 10',        5, 'CMP0035', 15913.35, 2218, 341, 142,  7.1746,  46.6667, 112.0658),
    ('cheapest 10',        6, 'CMP0086', 11691.91, 1277, 211, 101,  9.1558,  55.4119, 115.7615),
    ('cheapest 10',        7, 'CMP0050', 35219.40, 4086, 659, 299,  8.6195,  53.4437, 117.7906),
    ('cheapest 10',        8, 'CMP0110', 30384.26, 4123, 640, 257,  7.3695,  47.4754, 118.2267),
    ('cheapest 10',        9, 'CMP0005', 17057.46, 2239, 344, 143,  7.6183,  49.5856, 119.2829),
    ('cheapest 10',       10, 'CMP0045', 10543.72, 1430, 214,  88,  7.3732,  49.2697, 119.8150),
    ('most expensive 10',  1, 'CMP0084',  6105.33,  145,  14,   7, 42.1057, 436.0950, 872.1900),
    ('most expensive 10',  2, 'CMP0018',  7405.03,  334,  48,  11, 22.1707, 154.2715, 673.1845),
    ('most expensive 10',  3, 'CMP0099',  9348.40,  242,  35,  15, 38.6298, 267.0971, 623.2267),
    ('most expensive 10',  4, 'CMP0039', 24066.86,  733, 114,  39, 32.8334, 211.1128, 617.0990),
    ('most expensive 10',  5, 'CMP0034', 34180.02, 1044, 140,  57, 32.7395, 244.1430, 599.6495),
    ('most expensive 10',  6, 'CMP0064', 55178.97, 1687, 247,  94, 32.7083, 223.3966, 587.0103),
    ('most expensive 10',  7, 'CMP0049', 25032.55,  745, 110,  44, 33.6007, 227.5686, 568.9216),
    ('most expensive 10',  8, 'CMP0074', 26109.81,  934, 119,  46, 27.9548, 219.4102, 567.6046),
    ('most expensive 10',  9, 'CMP0079', 62230.93, 1932, 292, 110, 32.2106, 213.1196, 565.7357),
    ('most expensive 10', 10, 'CMP0119', 16825.46,  499,  71,  30, 33.7184, 236.9783, 560.8487)
)
SELECT COALESCE(r.RANKING, e.RANKING) AS RANKING, COALESCE(r.RANK_IN_LIST, e.RANK_IN_LIST) AS RANK_IN_LIST,
       r.CAMPAIGN_ID, r.CAMPAIGN_NAME, r.CHANNEL, r.OBJECTIVE, r.SPEND, r.LEADS, r.CONVERTED_LEADS, r.PURCHASES,
       r.COST_PER_LEAD, r.COST_PER_CONVERSION, r.COST_PER_PURCHASE,
       IFF(r.CAMPAIGN_ID = e.CAMPAIGN_ID AND r.SPEND = e.SPEND AND r.LEADS = e.LEADS
           AND r.CONVERTED_LEADS = e.CONVERTED_LEADS AND r.PURCHASES = e.PURCHASES AND r.COST_PER_LEAD = e.COST_PER_LEAD
           AND r.COST_PER_CONVERSION = e.COST_PER_CONVERSION AND r.COST_PER_PURCHASE = e.COST_PER_PURCHASE,
           'PASS', 'FAIL') AS STATUS
FROM ranked r
FULL OUTER JOIN expected e ON e.RANKING = r.RANKING AND e.RANK_IN_LIST = r.RANK_IN_LIST
ORDER BY 1, 2;


-- =============================================================================
-- SECTION 4. Monthly conversion trend on both time bases (G3)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 36 months side by side: the activity ratio (WRONG) vs the lead-cohort rate (only the
--     COH_ columns feed the dashboard)
--    BUSINESS QUESTION  Is the lead conversion rate changing over time?
--    METHOD  Each measure aggregated to the month ON ITS OWN, then joined 1:1 to the 36-month
--      spine of DIM_DATE (G1). The printed columns carry their time basis in their name:
--        LEADS                      leads by CREATED month (the denominator of both ratios)
--        ACT_CONVERSIONS            ACTIVITY basis: conversions by the month they HAPPENED
--                                   (converted month) ...
--        ACT_FROM_EARLIER_COHORTS   ... of which the lead was created in an earlier month
--        COH_CONVERTED_LEADS        COHORT basis: of the leads CREATED in the month, how many
--                                   EVER converted (STG_LEADS LEFT JOIN STG_CONVERSIONS,
--                                   COUNT(DISTINCT v.LEAD_ID)) ...
--        COH_CONVERTED_LATER_MONTH  ... of which the conversion landed in a later month
--        ACTIVE_CAMPAIGNS           campaigns whose window overlaps the month (DIM_CAMPAIGN x months)
--      So MONTH means the converted month for the ACT_ columns and the created month for LEADS
--      and the COH_ columns.
--      WRONG_NAIVE_ACT_RATIO = ACT_CONVERSIONS / LEADS: two bases in one ratio, WRONG on purpose.
--      COH_CONVERSION_RATE = COH_CONVERTED_LEADS / LEADS, with its Wilson 95% interval
--      (COH_CI_LOW, COH_CI_HIGH): the dashboard's monthly conversion rate.
--    HOW TO READ  Only the cohort rate is a conversion rate: its numerator is a subset of its
--      denominator (the same leads). The naive ratio's numerator mixes this month's leads that
--      convert in the same month with earlier months' leads that convert now
--      (ACT_FROM_EARLIER_COHORTS), and it leaves out this month's leads that convert next month
--      (COH_CONVERTED_LATER_MONTH). So it is not a share of its denominator, and it moves with
--      the previous month's volume. RESULT: the naive ratio swings from 0.083019 (2023-01:
--      nothing to inherit, while 102 of the month's 212 converting leads convert in February)
--      to 0.938462 (2025-12: 61 conversions, 50 of them from November leads, over 65 new
--      leads); the cohort rate stays between 0.139402 (2025-09) and 0.169231 (2025-12), with
--      no detectable change over time (4.2). ACT_FROM_EARLIER_COHORTS always equals the
--      previous month's COH_CONVERTED_LATER_MONTH (4.2 checks it with LAG): with a lag of at
--      most 21 days, every cross-month conversion lands in the very next month.
--    CAVEATS  Read volumes next to ACTIVE_CAMPAIGNS (G7): Oct-Dec 2025 have 5 / 3 / 1 campaigns,
--      so their rates rest on few leads (2025-12: 65 leads, interval 0.097212-0.278164). Cohort
--      rates assume the last cohorts are complete (AS_OF_DATE 2025-12-31, an assumption).
--      On the dashboard the two bases are separate charts, never one axis; this table puts
--      them side by side only to show why the ACT_ ratio is not a conversion rate (G3).
--    EXPECTED  Leads and both conversion counts [P3]; later-month counts [E02c 14]; active
--      campaigns [E01 28]; both ratios and the Wilson bounds [D].
-- -----------------------------------------------------------------------------
WITH months AS (                      -- the spine: 36 months
  SELECT DISTINCT MONTH_START FROM DIM_DATE
),
active_by_month AS (                  -- dimension x spine (no fact): campaign windows overlapping the month
  SELECT m.MONTH_START, COUNT(c.CAMPAIGN_ID) AS ACTIVE_CAMPAIGNS
  FROM months m
  LEFT JOIN DIM_CAMPAIGN c ON c.START_DATE <= LAST_DAY(m.MONTH_START) AND c.END_DATE >= m.MONTH_START
  GROUP BY m.MONTH_START
),
leads_by_month AS (                   -- leads by created month
  SELECT DATE_TRUNC('month', CREATED_DATE) AS MONTH_START, COUNT(*) AS LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS
  GROUP BY 1
),
activity_by_month AS (                -- ACTIVITY: conversions by the month they happened
  SELECT DATE_TRUNC('month', v.CONVERTED_DATE)                                                     AS MONTH_START,
         COUNT(*)                                                                                  AS ACTIVITY_CONVERSIONS,
         COUNT_IF(DATE_TRUNC('month', l.CREATED_DATE) < DATE_TRUNC('month', v.CONVERTED_DATE))     AS FROM_EARLIER_COHORTS
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID                    -- 1:1
  GROUP BY 1
),
cohort_by_month AS (                  -- COHORT: what the leads created in the month later did
  SELECT DATE_TRUNC('month', l.CREATED_DATE)                                                       AS MONTH_START,
         COUNT(DISTINCT v.LEAD_ID)                                                                 AS COHORT_CONVERTED_LEADS,
         COUNT_IF(DATE_TRUNC('month', v.CONVERTED_DATE) > DATE_TRUNC('month', l.CREATED_DATE))     AS CONVERTED_LATER_MONTH
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1
  GROUP BY 1
),
monthly AS (                          -- every input has one row per month: 1:1 joins to the spine
  SELECT m.MONTH_START, a.ACTIVE_CAMPAIGNS,
         COALESCE(l.LEADS, 0)                  AS LEADS,
         COALESCE(x.ACTIVITY_CONVERSIONS, 0)   AS ACTIVITY_CONVERSIONS,
         COALESCE(x.FROM_EARLIER_COHORTS, 0)   AS FROM_EARLIER_COHORTS,
         COALESCE(c.COHORT_CONVERTED_LEADS, 0) AS COHORT_CONVERTED_LEADS,
         COALESCE(c.CONVERTED_LATER_MONTH, 0)  AS CONVERTED_LATER_MONTH
  FROM months m
  LEFT JOIN active_by_month a   ON a.MONTH_START = m.MONTH_START
  LEFT JOIN leads_by_month l    ON l.MONTH_START = m.MONTH_START
  LEFT JOIN activity_by_month x ON x.MONTH_START = m.MONTH_START
  LEFT JOIN cohort_by_month c   ON c.MONTH_START = m.MONTH_START
),
rates AS (
  SELECT t.*,
         ROUND(ACTIVITY_CONVERSIONS::NUMBER(32,18)   / NULLIF(LEADS, 0), 6)  AS NAIVE_ACTIVITY_RATIO,
         ROUND(COHORT_CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0), 6)  AS COHORT_CONVERSION_RATE,
         COHORT_CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)                    AS P,
         NULLIF(LEADS, 0)::FLOAT                                             AS N,
         1.959964::FLOAT                                                     AS Z
  FROM monthly t
),
expected (MONTH_START, ACTIVE_CAMPAIGNS, LEADS, ACTIVITY_CONVERSIONS, COHORT_CONVERTED_LEADS, CONVERTED_LATER_MONTH,
          NAIVE_ACTIVITY_RATIO, COHORT_CONVERSION_RATE, CI_LOW, CI_HIGH) AS (
  SELECT * FROM VALUES   -- active [E01 28]; leads and conversions [P3]; later month [E02c 14]; ratios and bounds [D]
    ('2023-01-01'::DATE,  3,  1325,  110,  212, 102, 0.083019, 0.160000, 0.141247, 0.180718),
    ('2023-02-01'::DATE,  5,  2825,  325,  427, 204, 0.115044, 0.151150, 0.138416, 0.164832),
    ('2023-03-01'::DATE, 10,  6229,  798,  914, 320, 0.128110, 0.146733, 0.138164, 0.155738),
    ('2023-04-01'::DATE, 11,  5748,  902,  880, 298, 0.156924, 0.153097, 0.144020, 0.162637),
    ('2023-05-01'::DATE, 14,  5188,  811,  771, 258, 0.156322, 0.148612, 0.139193, 0.158551),
    ('2023-06-01'::DATE, 18,  7491,  963, 1137, 432, 0.128554, 0.151782, 0.143835, 0.160086),
    ('2023-07-01'::DATE, 16,  7779, 1273, 1220, 379, 0.163646, 0.156832, 0.148921, 0.165083),
    ('2023-08-01'::DATE, 18,  9024, 1221, 1377, 535, 0.135306, 0.152593, 0.145322, 0.160160),
    ('2023-09-01'::DATE, 18, 10771, 1590, 1604, 549, 0.147619, 0.148918, 0.142320, 0.155767),
    ('2023-10-01'::DATE, 19, 10930, 1654, 1648, 543, 0.151327, 0.150778, 0.144192, 0.157609),
    ('2023-11-01'::DATE, 16, 10526, 1582, 1575, 536, 0.150295, 0.149629, 0.142943, 0.156572),
    ('2023-12-01'::DATE, 17,  9713, 1550, 1471, 457, 0.159580, 0.151447, 0.144455, 0.158713),
    ('2024-01-01'::DATE, 12,  6493, 1158,  975, 274, 0.178346, 0.150162, 0.141680, 0.159058),
    ('2024-02-01'::DATE, 11,  5638,  794,  882, 362, 0.140830, 0.156438, 0.147190, 0.166154),
    ('2024-03-01'::DATE, 16,  7576, 1063, 1172, 471, 0.140312, 0.154699, 0.146731, 0.163017),
    ('2024-04-01'::DATE, 19, 10413, 1424, 1588, 635, 0.136752, 0.152502, 0.145725, 0.159535),
    ('2024-05-01'::DATE, 17,  8898, 1550, 1332, 417, 0.174196, 0.149697, 0.142435, 0.157261),
    ('2024-06-01'::DATE, 13,  5954, 1035,  918, 300, 0.173833, 0.154182, 0.145233, 0.163578),
    ('2024-07-01'::DATE, 13,  5895,  861,  879, 318, 0.146056, 0.149109, 0.140245, 0.158431),
    ('2024-08-01'::DATE, 18, 10718, 1316, 1607, 609, 0.122784, 0.149935, 0.143301, 0.156819),
    ('2024-09-01'::DATE, 20, 11825, 1780, 1779, 608, 0.150529, 0.150444, 0.144114, 0.157001),
    ('2024-10-01'::DATE, 18, 11683, 1830, 1771, 549, 0.156638, 0.151588, 0.145199, 0.158205),
    ('2024-11-01'::DATE, 19, 10557, 1579, 1588, 558, 0.149569, 0.150422, 0.143730, 0.157368),
    ('2024-12-01'::DATE, 18, 11721, 1758, 1831, 631, 0.149987, 0.156215, 0.149755, 0.162901),
    ('2025-01-01'::DATE, 16, 10136, 1699, 1557, 489, 0.167620, 0.153611, 0.146723, 0.160762),
    ('2025-02-01'::DATE, 13,  6308, 1116,  930, 303, 0.176918, 0.147432, 0.138897, 0.156395),
    ('2025-03-01'::DATE, 12,  7226, 1061, 1099, 341, 0.146831, 0.152090, 0.143995, 0.160554),
    ('2025-04-01'::DATE, 13,  6504,  969, 1036, 408, 0.148985, 0.159287, 0.150595, 0.168381),
    ('2025-05-01'::DATE, 14,  7506, 1183, 1113, 338, 0.157607, 0.148281, 0.140422, 0.156501),
    ('2025-06-01'::DATE, 14,  6371,  971,  996, 363, 0.152409, 0.156333, 0.147623, 0.165458),
    ('2025-07-01'::DATE, 15,  7710, 1101, 1156, 418, 0.142802, 0.149935, 0.142141, 0.158078),
    ('2025-08-01'::DATE, 14,  7339, 1190, 1109, 337, 0.162147, 0.151111, 0.143099, 0.159487),
    ('2025-09-01'::DATE, 11,  3680,  700,  513, 150, 0.190217, 0.139402, 0.128587, 0.150969),
    ('2025-10-01'::DATE,  5,  2826,  462,  445, 133, 0.163482, 0.157466, 0.144503, 0.171359),
    ('2025-11-01'::DATE,  3,  1093,  256,  173,  50, 0.234218, 0.158280, 0.137843, 0.181111),
    ('2025-12-01'::DATE,  1,    65,   61,   11,   0, 0.938462, 0.169231, 0.097212, 0.278164)
)
SELECT TO_CHAR(COALESCE(r.MONTH_START, e.MONTH_START), 'YYYY-MM') AS MONTH, r.ACTIVE_CAMPAIGNS, r.LEADS,
       -- ACTIVITY basis (MONTH = converted month); the ratio mixes two bases: WRONG on purpose
       r.ACTIVITY_CONVERSIONS AS ACT_CONVERSIONS, r.FROM_EARLIER_COHORTS AS ACT_FROM_EARLIER_COHORTS,
       r.NAIVE_ACTIVITY_RATIO AS WRONG_NAIVE_ACT_RATIO,
       -- COHORT basis (MONTH = created month): the dashboard's monthly conversion rate
       r.COHORT_CONVERTED_LEADS AS COH_CONVERTED_LEADS, r.CONVERTED_LATER_MONTH AS COH_CONVERTED_LATER_MONTH,
       r.COHORT_CONVERSION_RATE AS COH_CONVERSION_RATE,
       ROUND((r.P + r.Z * r.Z / (2 * r.N) - r.Z * SQRT(r.P * (1 - r.P) / r.N + r.Z * r.Z / (4 * r.N * r.N)))
             / (1 + r.Z * r.Z / r.N), 6)::NUMBER(18,6) AS COH_CI_LOW,
       ROUND((r.P + r.Z * r.Z / (2 * r.N) + r.Z * SQRT(r.P * (1 - r.P) / r.N + r.Z * r.Z / (4 * r.N * r.N)))
             / (1 + r.Z * r.Z / r.N), 6)::NUMBER(18,6) AS COH_CI_HIGH,
       IFF(r.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND r.LEADS = e.LEADS AND r.ACTIVITY_CONVERSIONS = e.ACTIVITY_CONVERSIONS
           -- conversions in the month = the month's own leads converting in it + leads of earlier months
           AND r.FROM_EARLIER_COHORTS = e.ACTIVITY_CONVERSIONS - (e.COHORT_CONVERTED_LEADS - e.CONVERTED_LATER_MONTH)
           AND r.COHORT_CONVERTED_LEADS = e.COHORT_CONVERTED_LEADS AND r.CONVERTED_LATER_MONTH = e.CONVERTED_LATER_MONTH
           AND r.NAIVE_ACTIVITY_RATIO = e.NAIVE_ACTIVITY_RATIO AND r.COHORT_CONVERSION_RATE = e.COHORT_CONVERSION_RATE
           AND COH_CI_LOW = e.CI_LOW AND COH_CI_HIGH = e.CI_HIGH, 'PASS', 'FAIL') AS STATUS
FROM rates r
FULL OUTER JOIN expected e ON e.MONTH_START = r.MONTH_START
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 4.2 Monthly ranges, the cross-month share, and whether the cohort rate moves over time
--    BUSINESS QUESTION  How far apart are the two monthly series, why, and does the real
--      (cohort) conversion rate change from month to month?
--    METHOD  The same month-grain inputs as 4.1; MIN_BY / MAX_BY return the month of each
--      extreme; the cross-month share = conversions landing in a later month than their lead /
--      all conversions; a chi-square test over the 36 x 2 table (cohort month x converted / not,
--      df 35, critical value 49.801850 [Q]); Wilson intervals that exclude the pooled rate (by
--      chance alone about 5% of 36 = 1.8); LAG() checks that the conversions a month inherits
--      are exactly the previous month's later-month conversions. The STAGING path is reconciled
--      with the two monthly marts (MART_MONTHLY_MARKETING, activity; MART_MONTHLY_COHORT, cohort).
--    HOW TO READ  RESULT: 13,675 of 39,696 conversions (0.344493) land in a later calendar month
--      than their lead, which is why the bases differ in every month. The naive ratio spans
--      0.855443 (0.083019 to 0.938462) and lies outside the whole cohort range in 14 of 36
--      months; the cohort rate spans 0.029829. The cohort chi-square, 21.684675, is far below
--      49.801850, and only 1 month (2025-09, checks 22, 23) has an interval excluding the
--      pooled rate, against about 1.8 by chance: there is no evidence that the monthly cohort
--      rate changes over the three years. That is not proof of a constant rate: a single month
--      of 11,825 leads (the largest, 2024-09, checks 25, 26) running 1 point off would be
--      flagged only about 26% of the time [PW]. A sustained 1-point drop over all twelve 2025
--      months would be flagged about 96% of the time [PW], so the 2025 decline is a volume
--      decline (fewer campaigns, G7), not a conversion decline of a point or more.
--    CAVEATS  Independence assumed (header). Synthetic data: a monthly rate with no detectable
--      movement over three years is consistent with a generator that draws every lead at one
--      rate (G6); it is not evidence about real marketing.
--    EXPECTED  [P3], [PL], [E02c 16] and [D]; the marts and the LAG identity hold in all 36 months.
-- -----------------------------------------------------------------------------
WITH months AS (
  SELECT DISTINCT MONTH_START FROM DIM_DATE
),
leads_by_month AS (
  SELECT DATE_TRUNC('month', CREATED_DATE) AS MONTH_START, COUNT(*) AS LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS
  GROUP BY 1
),
activity_by_month AS (
  SELECT DATE_TRUNC('month', v.CONVERTED_DATE)                                                     AS MONTH_START,
         COUNT(*)                                                                                  AS ACTIVITY_CONVERSIONS,
         COUNT_IF(DATE_TRUNC('month', l.CREATED_DATE) < DATE_TRUNC('month', v.CONVERTED_DATE))     AS FROM_EARLIER_COHORTS
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID                    -- 1:1
  GROUP BY 1
),
cohort_by_month AS (
  SELECT DATE_TRUNC('month', l.CREATED_DATE)                                                       AS MONTH_START,
         COUNT(DISTINCT v.LEAD_ID)                                                                 AS COHORT_CONVERTED_LEADS,
         COUNT_IF(DATE_TRUNC('month', v.CONVERTED_DATE) = DATE_TRUNC('month', l.CREATED_DATE))     AS CONVERTED_SAME_MONTH,
         COUNT_IF(DATE_TRUNC('month', v.CONVERTED_DATE) > DATE_TRUNC('month', l.CREATED_DATE))     AS CONVERTED_LATER_MONTH
  FROM MARKETING_CRM.STAGING.STG_LEADS l
  LEFT JOIN MARKETING_CRM.STAGING.STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID          -- 1:0..1
  GROUP BY 1
),
mart_activity AS (                    -- the activity mart, summed over its 5 channels per month
  SELECT MONTH_START, SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS
  FROM MART_MONTHLY_MARKETING GROUP BY MONTH_START
),
mart_cohort AS (                      -- the cohort mart, summed over its 5 channels per month
  SELECT COHORT_MONTH AS MONTH_START, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM(CONVERTED_LATER_MONTH) AS CONVERTED_LATER_MONTH
  FROM MART_MONTHLY_COHORT GROUP BY COHORT_MONTH
),
monthly AS (                          -- 1:1 joins to the 36-month spine
  SELECT m.MONTH_START, COALESCE(l.LEADS, 0) AS LEADS, COALESCE(x.ACTIVITY_CONVERSIONS, 0) AS ACTIVITY_CONVERSIONS,
         COALESCE(x.FROM_EARLIER_COHORTS, 0) AS FROM_EARLIER_COHORTS,
         COALESCE(c.COHORT_CONVERTED_LEADS, 0) AS COHORT_CONVERTED_LEADS,
         COALESCE(c.CONVERTED_SAME_MONTH, 0) AS CONVERTED_SAME_MONTH,
         COALESCE(c.CONVERTED_LATER_MONTH, 0) AS CONVERTED_LATER_MONTH,
         IFF(ma.LEADS = l.LEADS AND ma.CONVERSIONS = x.ACTIVITY_CONVERSIONS AND mc.LEADS = l.LEADS
             AND mc.CONVERTED_LEADS = c.COHORT_CONVERTED_LEADS AND mc.CONVERTED_LATER_MONTH = c.CONVERTED_LATER_MONTH,
             1, 0) AS EQUALS_MARTS
  FROM months m
  LEFT JOIN leads_by_month l    ON l.MONTH_START = m.MONTH_START
  LEFT JOIN activity_by_month x ON x.MONTH_START = m.MONTH_START
  LEFT JOIN cohort_by_month c   ON c.MONTH_START = m.MONTH_START
  LEFT JOIN mart_activity ma    ON ma.MONTH_START = m.MONTH_START
  LEFT JOIN mart_cohort mc      ON mc.MONTH_START = m.MONTH_START
),
tested AS (                           -- both ratios, and the cohort test inputs in FLOAT
  SELECT t.*,
         ROUND(ACTIVITY_CONVERSIONS::NUMBER(32,18)   / NULLIF(LEADS, 0), 6)  AS NAIVE_RATIO,
         ROUND(COHORT_CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0), 6)  AS COHORT_RATE,
         SUM(COHORT_CONVERTED_LEADS) OVER ()::FLOAT / SUM(LEADS) OVER ()     AS P0,
         COHORT_CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)                    AS P,
         NULLIF(LEADS, 0)::FLOAT                                             AS N,
         1.959964::FLOAT                                                     AS Z
  FROM monthly t
),
with_ci AS (
  SELECT t.*,
         (P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N) AS CI_LOW,
         (P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N) AS CI_HIGH,
         POWER(COHORT_CONVERTED_LEADS - N * P0, 2) / (N * P0)
         + POWER((LEADS - COHORT_CONVERTED_LEADS) - N * (1 - P0), 2) / (N * (1 - P0))           AS CONTRIBUTION,
         -- the previous month's leads that converted in a later month (LAG; 0 before the first month)
         COALESCE(LAG(CONVERTED_LATER_MONTH) OVER (ORDER BY MONTH_START), 0)                     AS PREVIOUS_LATER_MONTH,
         MIN(COHORT_RATE) OVER ()                                                                AS COHORT_MIN,
         MAX(COHORT_RATE) OVER ()                                                                AS COHORT_MAX
  FROM tested t
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL::NUMBER(38,6) = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'months' AS CHECK_NAME, COUNT(*) AS ACTUAL, 36 AS EXPECTED FROM with_ci
  UNION ALL SELECT 2, 'months equal to both monthly marts', SUM(EQUALS_MARTS), 36 FROM with_ci
  UNION ALL SELECT 3, 'leads, all months', SUM(LEADS), 261684 FROM with_ci
  UNION ALL SELECT 4, 'conversions, activity basis', SUM(ACTIVITY_CONVERSIONS), 39696 FROM with_ci
  UNION ALL SELECT 5, 'converted leads, cohort basis', SUM(COHORT_CONVERTED_LEADS), 39696 FROM with_ci
  UNION ALL SELECT 6, '... in the same month as the lead', SUM(CONVERTED_SAME_MONTH), 26021 FROM with_ci
  UNION ALL SELECT 7, '... in a later month than the lead', SUM(CONVERTED_LATER_MONTH), 13675 FROM with_ci
  UNION ALL SELECT 8, 'cross-month share (later / all)',
                   ROUND(SUM(CONVERTED_LATER_MONTH)::NUMBER(32,18) / NULLIF(SUM(COHORT_CONVERTED_LEADS), 0), 6), 0.344493 FROM with_ci
  UNION ALL SELECT 9, 'WRONG on purpose: naive ratio, lowest', MIN(NAIVE_RATIO), 0.083019 FROM with_ci
  UNION ALL SELECT 10, '... month of the lowest (YYYYMM)', TO_NUMBER(TO_CHAR(MIN_BY(MONTH_START, NAIVE_RATIO), 'YYYYMM')), 202301 FROM with_ci
  UNION ALL SELECT 11, 'WRONG on purpose: naive ratio, highest', MAX(NAIVE_RATIO), 0.938462 FROM with_ci
  UNION ALL SELECT 12, '... month of the highest (YYYYMM)', TO_NUMBER(TO_CHAR(MAX_BY(MONTH_START, NAIVE_RATIO), 'YYYYMM')), 202512 FROM with_ci
  UNION ALL SELECT 13, 'cohort conversion rate, lowest', MIN(COHORT_RATE), 0.139402 FROM with_ci
  UNION ALL SELECT 14, '... month of the lowest (YYYYMM)', TO_NUMBER(TO_CHAR(MIN_BY(MONTH_START, COHORT_RATE), 'YYYYMM')), 202509 FROM with_ci
  UNION ALL SELECT 15, 'cohort conversion rate, highest', MAX(COHORT_RATE), 0.169231 FROM with_ci
  UNION ALL SELECT 16, '... month of the highest (YYYYMM)', TO_NUMBER(TO_CHAR(MAX_BY(MONTH_START, COHORT_RATE), 'YYYYMM')), 202512 FROM with_ci
  UNION ALL SELECT 17, 'range of the naive ratio (max - min)', MAX(NAIVE_RATIO) - MIN(NAIVE_RATIO), 0.855443 FROM with_ci
  UNION ALL SELECT 18, 'range of the cohort rate (max - min)', MAX(COHORT_RATE) - MIN(COHORT_RATE), 0.029829 FROM with_ci
  UNION ALL SELECT 19, 'months: naive ratio outside cohort range',
                   COUNT_IF(NAIVE_RATIO NOT BETWEEN COHORT_MIN AND COHORT_MAX),
                   14 FROM with_ci
  UNION ALL SELECT 20, 'cohort chi-square, 36 months (df 35)', ROUND(SUM(CONTRIBUTION), 6), 21.684675 FROM with_ci
  UNION ALL SELECT 21, 'reject equal rates? (> 49.801850; 1=yes)',
                   IFF(SUM(CONTRIBUTION) > 49.801850, 1, 0), 0 FROM with_ci
  UNION ALL SELECT 22, 'CIs excluding pooled rate (chance: ~1.8)',
                   COUNT_IF(P0 NOT BETWEEN CI_LOW AND CI_HIGH), 1 FROM with_ci
  UNION ALL SELECT 23, '... that month (YYYYMM)',
                   TO_NUMBER(TO_CHAR(MAX(IFF(P0 NOT BETWEEN CI_LOW AND CI_HIGH, MONTH_START, NULL)), 'YYYYMM')), 202509 FROM with_ci
  UNION ALL SELECT 24, 'months: inherited = LAG(later month)', COUNT_IF(FROM_EARLIER_COHORTS = PREVIOUS_LATER_MONTH), 36
            FROM with_ci
  UNION ALL SELECT 25, 'most leads in a month', MAX(LEADS), 11825 FROM with_ci
  UNION ALL SELECT 26, '... that month (YYYYMM)', TO_NUMBER(TO_CHAR(MAX_BY(MONTH_START, LEADS), 'YYYYMM')), 202409 FROM with_ci
)
ORDER BY ORD;


-- =============================================================================
-- SECTION 5. Time to convert (business question 5, for the funnel page)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 Days from lead to conversion: overall, by conversion type, by channel
--    BUSINESS QUESTION  How long does a lead take to convert, and does it depend on the
--      outcome or the channel?
--    METHOD  GROUPING SETS ((), (CONVERSION_TYPE), (CHANNEL)) computes the three splits in one
--      pass over the converted leads of FCT_LEAD_CONVERSIONS. Mean = SUM / COUNT (exact);
--      MEDIAN and PERCENTILE_CONT interpolate linearly; the shares within 7 / 14 / 21 days count
--      DAYS_TO_CONVERT <= 7 / 14 / 21 (day 0 = the lead's own day) with COUNT_IF.
--    HOW TO READ  RESULT: median 10 days, mean 10.5056, half of the conversions between day 5
--      and day 16; 0.362228 within 7 days, 0.682814 within 14, all within 21. Every split looks
--      the same (means 10.3766-10.5774, medians 10 or 11). 4,716 conversions (11.9%) land after
--      their campaign ended: a dashboard filter on the campaign window would drop them.
--    CAVEATS  21 days is the observed maximum; the last cohorts are assumed complete
--      (AS_OF_DATE 2025-12-31). Identical percentiles across splits are a generator artefact
--      (G6), not a behavioural finding.
--    EXPECTED  [E01 24] same-day and after-end totals; [E01 25] means and percentiles; [D] the
--      shares, and the same-day and after-end counts by channel.
-- -----------------------------------------------------------------------------
WITH conversions AS (                 -- converted leads only (DAYS_TO_CONVERT is NULL for the others)
  SELECT CHANNEL, CONVERSION_TYPE, DAYS_TO_CONVERT, CONVERTED_AFTER_CAMPAIGN_END
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
),
summary AS (
  SELECT CASE WHEN GROUPING(CONVERSION_TYPE) = 0 THEN 'conversion_type'
              WHEN GROUPING(CHANNEL) = 0         THEN 'channel'
              ELSE 'all' END                                                       AS SPLIT_BY,
         COALESCE(CONVERSION_TYPE, CHANNEL, 'all')                                 AS GROUP_VALUE,
         COUNT(*)                                                                  AS CONVERSIONS,
         ROUND(SUM(DAYS_TO_CONVERT)::NUMBER(32,18) / COUNT(*), 4)                  AS MEAN_DAYS,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY DAYS_TO_CONVERT)             AS P25_DAYS,
         MEDIAN(DAYS_TO_CONVERT)                                                   AS MEDIAN_DAYS,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY DAYS_TO_CONVERT)             AS P75_DAYS,
         PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY DAYS_TO_CONVERT)             AS P90_DAYS,
         MAX(DAYS_TO_CONVERT)                                                      AS MAX_DAYS,
         COUNT_IF(DAYS_TO_CONVERT = 0)                                             AS SAME_DAY,
         ROUND(COUNT_IF(DAYS_TO_CONVERT <= 7)::NUMBER(32,18)  / COUNT(*), 6)       AS SHARE_WITHIN_7_DAYS,
         ROUND(COUNT_IF(DAYS_TO_CONVERT <= 14)::NUMBER(32,18) / COUNT(*), 6)       AS SHARE_WITHIN_14_DAYS,
         ROUND(COUNT_IF(DAYS_TO_CONVERT <= 21)::NUMBER(32,18) / COUNT(*), 6)       AS SHARE_WITHIN_21_DAYS,
         COUNT_IF(CONVERTED_AFTER_CAMPAIGN_END = 1)                                AS AFTER_CAMPAIGN_END
  FROM conversions
  GROUP BY GROUPING SETS ((), (CONVERSION_TYPE), (CHANNEL))
),
expected (SPLIT_BY, GROUP_VALUE, CONVERSIONS, MEAN_DAYS, MEDIAN_DAYS, SAME_DAY, SHARE_WITHIN_7_DAYS,
          SHARE_WITHIN_14_DAYS, AFTER_CAMPAIGN_END) AS (
  SELECT * FROM VALUES   -- count, mean, median [E01 25]; same day, after end [E01 24] / [D]; shares [D]
    ('all',             'all',         39696, 10.5056, 10, 1811, 0.362228, 0.682814, 4716),
    ('conversion_type', 'purchase',    16691, 10.5025, 10,  770, 0.361752, 0.683063, 1951),
    ('conversion_type', 'trial',       23005, 10.5078, 11, 1041, 0.362573, 0.682634, 2765),
    ('channel',         'affiliate',   10352, 10.4954, 10,  469, 0.362635, 0.682767, 1263),
    ('channel',         'display',      6744, 10.5101, 10,  290, 0.364917, 0.680308,  777),
    ('channel',         'paid_search', 10019, 10.5017, 11,  474, 0.364807, 0.683801, 1108),
    ('channel',         'paid_social',  8648, 10.5774, 11,  380, 0.353377, 0.681776, 1162),
    ('channel',         'video',        3933, 10.3766, 10,  198, 0.369438, 0.687007,  406)
)
SELECT COALESCE(s.SPLIT_BY, e.SPLIT_BY) AS SPLIT_BY, COALESCE(s.GROUP_VALUE, e.GROUP_VALUE) AS GROUP_VALUE,
       s.CONVERSIONS, s.MEAN_DAYS, s.P25_DAYS, s.MEDIAN_DAYS, s.P75_DAYS, s.P90_DAYS, s.MAX_DAYS, s.SAME_DAY,
       s.SHARE_WITHIN_7_DAYS, s.SHARE_WITHIN_14_DAYS, s.SHARE_WITHIN_21_DAYS, s.AFTER_CAMPAIGN_END,
       -- p25 5, p75 16, p90 19 and max 21 in every split [E01 25]; all conversions within 21 days
       IFF(s.CONVERSIONS = e.CONVERSIONS AND s.MEAN_DAYS = e.MEAN_DAYS AND s.MEDIAN_DAYS = e.MEDIAN_DAYS
           AND s.P25_DAYS = 5 AND s.P75_DAYS = 16 AND s.P90_DAYS = 19 AND s.MAX_DAYS = 21 AND s.SAME_DAY = e.SAME_DAY
           AND s.SHARE_WITHIN_7_DAYS = e.SHARE_WITHIN_7_DAYS AND s.SHARE_WITHIN_14_DAYS = e.SHARE_WITHIN_14_DAYS
           AND s.SHARE_WITHIN_21_DAYS = 1 AND s.AFTER_CAMPAIGN_END = e.AFTER_CAMPAIGN_END, 'PASS', 'FAIL') AS STATUS
FROM summary s
FULL OUTER JOIN expected e ON e.SPLIT_BY = s.SPLIT_BY AND e.GROUP_VALUE = s.GROUP_VALUE
ORDER BY DECODE(COALESCE(s.SPLIT_BY, e.SPLIT_BY), 'all', 1, 'conversion_type', 2, 3), 2;


-- -----------------------------------------------------------------------------
-- 5.2 Distribution of days to convert, 0-21, with the running share (dashboard table)
--    BUSINESS QUESTION  By which day after the lead have most conversions happened?
--    METHOD  A 22-row spine of lag days (GENERATOR + ROW_NUMBER, so a day without conversions
--      would show as 0), the conversions per lag day LEFT JOINed 1:1, and a running total with
--      SUM() OVER (ORDER BY DAYS_TO_CONVERT ROWS UNBOUNDED PRECEDING) for the cumulative share.
--    HOW TO READ  RESULT: every day from 0 to 21 holds 0.043833-0.046881 of the conversions
--      (1,740 to 1,861), so the cumulative share climbs in a straight line: 0.500705 by day 10,
--      0.682814 by day 14, 1.000000 by day 21.
--    CAVEATS  A flat lag distribution with a hard stop at 21 days is a property of the synthetic
--      generator (G6); real conversion lags are usually front-loaded with a long tail, so do not
--      carry this shape into attribution windows or forecasts.
--    EXPECTED  All 22 rows [D]; the spine catches all 39,696 conversions ([E01 25]: lag 0-21).
-- -----------------------------------------------------------------------------
WITH lag_days AS (                    -- 0..21, gap-free: ROW_NUMBER() over GENERATOR
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS DAYS_TO_CONVERT
  FROM TABLE(GENERATOR(ROWCOUNT => 22))
),
by_day AS (                           -- converted leads -> one row per lag day
  SELECT DAYS_TO_CONVERT, COUNT(*) AS CONVERSIONS
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
  GROUP BY DAYS_TO_CONVERT
),
histogram AS (
  SELECT d.DAYS_TO_CONVERT, COALESCE(b.CONVERSIONS, 0) AS CONVERSIONS,
         SUM(COALESCE(b.CONVERSIONS, 0)) OVER (ORDER BY d.DAYS_TO_CONVERT
                                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUMULATIVE_CONVERSIONS,
         SUM(COALESCE(b.CONVERSIONS, 0)) OVER ()                                                 AS SPINE_CONVERSIONS
  FROM lag_days d
  LEFT JOIN by_day b ON b.DAYS_TO_CONVERT = d.DAYS_TO_CONVERT                          -- 1:1
),
expected (DAYS_TO_CONVERT, CONVERSIONS, CUMULATIVE_SHARE) AS (
  SELECT * FROM VALUES   -- [D]
    ( 0, 1811, 0.045622), ( 1, 1796, 0.090866), ( 2, 1757, 0.135127), ( 3, 1740, 0.178960),
    ( 4, 1849, 0.225539), ( 5, 1792, 0.270682), ( 6, 1809, 0.316254), ( 7, 1825, 0.362228),
    ( 8, 1861, 0.409109), ( 9, 1855, 0.455839), (10, 1781, 0.500705), (11, 1800, 0.546050),
    (12, 1798, 0.591344), (13, 1796, 0.636588), (14, 1835, 0.682814), (15, 1792, 0.727957),
    (16, 1812, 0.773604), (17, 1745, 0.817563), (18, 1827, 0.863588), (19, 1840, 0.909941),
    (20, 1751, 0.954051), (21, 1824, 1.000000)
)
SELECT COALESCE(h.DAYS_TO_CONVERT, e.DAYS_TO_CONVERT) AS DAYS_TO_CONVERT, h.CONVERSIONS,
       ROUND(h.CONVERSIONS::NUMBER(32,18) / NULLIF(h.SPINE_CONVERSIONS, 0), 6)            AS SHARE,
       h.CUMULATIVE_CONVERSIONS,
       ROUND(h.CUMULATIVE_CONVERSIONS::NUMBER(32,18) / NULLIF(h.SPINE_CONVERSIONS, 0), 6) AS CUMULATIVE_SHARE,
       IFF(h.SPINE_CONVERSIONS = 39696 AND h.CONVERSIONS = e.CONVERSIONS AND CUMULATIVE_SHARE = e.CUMULATIVE_SHARE,
           'PASS', 'FAIL') AS STATUS
FROM histogram h
FULL OUTER JOIN expected e ON e.DAYS_TO_CONVERT = h.DAYS_TO_CONVERT
ORDER BY 1;
