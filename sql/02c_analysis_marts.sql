-- =============================================================================
-- Phase 4 / 02c: analysis marts (daily activity spine, monthly, channel, lead quality)
-- -----------------------------------------------------------------------------
-- Purpose
--   Build the five analysis tables that the Phase 4 analyses and the Phase 6 dashboard read,
--   on top of the clean STAGING views and the Phase 3 MART core (sql/02b_core_models.sql):
--     FCT_CAMPAIGN_DAILY_ACTIVITY  campaign x date, START_DATE .. END_DATE + 21 (activity basis)  13,760 rows
--     MART_MONTHLY_MARKETING       channel x month, activity basis (36 months x 5 channels)        180 rows
--     MART_MONTHLY_COHORT          channel x lead cohort month (36 x 5)                             180 rows
--     MART_CHANNEL_PERFORMANCE     channel: bases, channel-grain KPIs, shares, Wilson interval        5 rows
--     MART_LEAD_QUALITY            channel x 10-point lead score band (5 x 10)                       50 rows
--   Every table ships its additive bases (counts, money, sums), so a dashboard can re-aggregate
--   them correctly. Ratio columns exist only where the ratio is valid at the table grain
--   (MART_CHANNEL_PERFORMANCE). Phase 5 ports them to dbt models with the same names.
-- Analytical guard rails (the user plan), and where each is applied
--   G1 Grain. A fact is never joined row by row to a fact of another grain: the naive
--      daily_spend x leads join on CAMPAIGN_ID inflates spend 2,495x (4.52 M -> 11.3 B,
--      docs/data_profile.md "The grain trap"). Every input here is aggregated to the target
--      grain in its own CTE first and only then joined 1:1 onto a spine. The spines are
--      dimension x dimension (DIM_CAMPAIGN x DIM_DATE, months x channels, channels x score
--      bands), never fact x fact. 02c_analysis_marts_tests.sql proves it: every table adds up
--      to the Phase 3 totals (spend 4,523,050.02, revenue 21,561,839.01, ...).
--   G2 The funnel is an aggregate campaign funnel. IMPRESSIONS -> CLICKS -> LEADS ->
--      CONVERTED_LEADS count different units (ad impressions, clicks, people who left their
--      details, leads that converted). It is not one person's journey: a lead converts at most
--      once, to a trial OR a purchase, so TRIALS and PURCHASES are two parallel outcomes, not
--      two stages, and no table can follow a trial to a purchase.
--   G3 Activity basis and lead-cohort basis are separate tables. MART_MONTHLY_MARKETING counts
--      spend by spend date, leads by created date and conversions by converted date (what
--      happened in the month). MART_MONTHLY_COHORT counts what the leads created in a month
--      later did. 13,675 of 39,696 conversions (34.45%, local pre-load baseline, reproduced by
--      the tests) land in a later month than their lead, so the two differ month by month.
--      They are never blended on one date axis, and CONVERSIONS / LEADS of the activity table
--      is not a conversion rate (it swings from 8.3% to 93.8% by month).
--   G4 ROAS = last-touch attributed REVENUE / SPEND. It describes attributed revenue, not the
--      causal effect of the spend.
--   G5 Lead score. How the score is produced is undocumented. MART_LEAD_QUALITY shows how
--      conversion varies with the score in this data (association only). It does not validate
--      the score as a predictor.
--   G6 The data is synthetic. Regular patterns are generator artefacts, not market facts: e.g.
--      the channel CPMs are near-round numbers (6.5000 to 18.0004, MART_CHANNEL_PERFORMANCE.CPM),
--      the lag percentiles are the same in every channel except the median (10 or 11), and the
--      score is near-uniform on 1-100.
--   G7 Volume follows the number of running campaigns. 22 campaigns started in 2025 vs 50 in
--      2024 (35 active in 2025 vs 60 in 2024), so 2025 totals fall. MART_MONTHLY_MARKETING
--      ships ACTIVE_CAMPAIGNS next to every volume, so trends are read per active campaign.
-- Why tables
--   As in 02b: Data Studio queries MART repeatedly; tables are small and pre-joined, and
--   CREATE OR REPLACE TABLE ... AS rebuilds each one in seconds, so the file is idempotent.
--   The marts are snapshots of the Phase 3 tables: after a re-run of 02b_core_models.sql, re-run
--   this file too.
-- How to run
--   From the repository root, after sql/02b_core_models.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/02c_analysis_marts.sql
--   Then the tests:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/02c_analysis_marts_tests.sql
--   15 statements, a few seconds on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02c_analysis_marts.txt.
-- Role
--   CRM_TRANSFORMER: SELECT on STAGING and MART, CREATE TABLE in MART; it owns the tables.
--   CRM_REPORTER reads them through the future grant on MART tables (no GRANT needed here).
-- Inputs / outputs
--   in   MARKETING_CRM.MART.DIM_DATE, DIM_CAMPAIGN, FCT_DAILY_SPEND, FCT_LEAD_CONVERSIONS (Phase 3
--        core, built from the clean STG_* views only; never STG_CHALLENGE_*). The marts read the
--        core tables rather than STAGING so that every Phase 4 number shares the tested Phase 3
--        definitions (CHANNEL from DIM_CAMPAIGN, BUDGET_PRORATED, the 0/1 flags, DAYS_TO_CONVERT).
--   out  MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY  CAMPAIGN_ID + ACTIVITY_DATE (grain key), ACTIVITY_MONTH,
--                                                       CHANNEL, OBJECTIVE, IS_IN_FLIGHT, IMPRESSIONS, CLICKS,
--                                                       SPEND, BUDGET_PRORATED, LEADS, CONVERSIONS, TRIALS,
--                                                       PURCHASES, REVENUE
--        MARKETING_CRM.MART.MART_MONTHLY_MARKETING       MONTH_START + CHANNEL (grain key), ACTIVE_CAMPAIGNS, SPEND,
--                                                       IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, TRIALS, PURCHASES,
--                                                       REVENUE, BUDGET_PRORATED
--        MARKETING_CRM.MART.MART_MONTHLY_COHORT          COHORT_MONTH + CHANNEL (grain key), LEADS, CONVERTED_LEADS,
--                                                       TRIALS, PURCHASES, REVENUE, CONVERTED_SAME_MONTH,
--                                                       CONVERTED_LATER_MONTH, SUM_DAYS_TO_CONVERT, MATURE_LEADS
--        MARKETING_CRM.MART.MART_CHANNEL_PERFORMANCE     CHANNEL (PK), CAMPAIGNS, BUDGET, SPEND, IMPRESSIONS, CLICKS,
--                                                       LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, CTR,
--                                                       CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_RATE,
--                                                       COST_PER_LEAD, COST_PER_CONVERSION, COST_PER_PURCHASE, ROAS,
--                                                       BUDGET_UTILIZATION, CPC, CPM, SPEND_SHARE, LEADS_SHARE,
--                                                       REVENUE_SHARE, LCR_CI_LOW, LCR_CI_HIGH
--        MARKETING_CRM.MART.MART_LEAD_QUALITY            CHANNEL + SCORE_BAND (grain key), SCORE_BAND_MIN,
--                                                       SCORE_BAND_MAX, LEAD_SCORE_SEGMENT, LEADS, SUM_LEAD_SCORE,
--                                                       CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE,
--                                                       SUM_DAYS_TO_CONVERT
--   Every table and column has a COMMENT; blocks 1-5 set the table comment, blocks 6-10 the
--   column comments.
-- Conventions (as in 02b_core_models.sql, plus three for aggregated tables)
--   Names       UPPERCASE ASCII; months are DATEs (first day of the month).
--   Types       counts and sums of counts NUMBER(38,0); 0/1 flags NUMBER(1,0); money NUMBER(18,2)
--               (every money column here is a SUM over source rows); BUDGET_PRORATED
--               NUMBER(18,6); rates, ROAS, shares and interval bounds NUMBER(18,6); cost per
--               unit (CPL, CPC, CPM, ...) NUMBER(18,4); score band edges NUMBER(3,0).
--   Zeros       Each spine lists every member of the grain, and COALESCE turns "nothing
--               happened" into 0. A day after a campaign ended has SPEND 0, a channel-month
--               without leads has LEADS 0: the row exists, so a time axis shows the gap as 0.
--   Additive    Counts, money and the SUM_* columns add up across rows. Averages are derived,
--               never stored: AVG lead score = SUM(SUM_LEAD_SCORE) / SUM(LEADS), mean lag =
--               SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS). Exceptions, stated on the
--               column: ACTIVE_CAMPAIGNS (a distinct count, additive across channels within a
--               month, not across months) and BUDGET (whole campaigns only).
--   Ratios      Only MART_CHANNEL_PERFORMANCE stores ratios, valid at channel grain (5 rows,
--               full date range). Every other ratio is computed in Data Studio as SUM / SUM of
--               the base columns (architecture decision 9).
--   Rounding    As in 02b ("Rounding"): every division casts its dividend to NUMBER(32,18), so
--               ROUND to the stored scale is the only rounding (rates 6 dp, cost 4 dp). The
--               one exception is the Wilson interval (block 4): SQRT needs FLOAT, so it is
--               computed in double precision and rounded once to 6 dp.
-- Assumptions
--   POST_WINDOW_DAYS = 21: the observed maximum lead-to-conversion lag (0..21 days, Phase 2;
--   0 conversions over 21 days). Every lead falls inside its campaign window, so every
--   conversion lands on or before END_DATE + 21: the spine catches all 39,696 conversions,
--   including the 4,716 that land after their campaign ended (tests block 4).
--   COVERAGE_END = 2025-12-31, the documented coverage end and the end of DIM_DATE. The spine
--   is clipped there; the latest END_DATE + 21 is 2025-12-23, so no day is clipped today.
--   AS_OF_DATE / IS_MATURE come from FCT_LEAD_CONVERSIONS (2025-12-31, an assumption).
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] 0 context   [5] 1 FCT_CAMPAIGN_DAILY_ACTIVITY   [6] 2 MART_MONTHLY_MARKETING
--   [7] 3 MART_MONTHLY_COHORT   [8] 4 MART_CHANNEL_PERFORMANCE   [9] 5 MART_LEAD_QUALITY
--   [10-14] 6-10 column comments   [15] 11 build summary
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Context: the transformer role only, no secondary roles (no accidental writes elsewhere)
-- -----------------------------------------------------------------------------
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.MART;


-- -----------------------------------------------------------------------------
-- 1. FCT_CAMPAIGN_DAILY_ACTIVITY: one row per campaign per day, START_DATE .. END_DATE + 21
--    What: the activity fact. For each campaign and each day of its flight plus the 21 days
--      after it, what happened on that day: delivery (impressions, clicks, spend), the
--      prorated budget, leads created, and conversions and revenue booked.
--    Why a spine to END_DATE + 21: FCT_DAILY_SPEND has rows only for flight days. 4,716
--      conversions (2,532,266.74 of revenue) land up to 21 days after their campaign ended; a
--      fact keyed on spend rows, or a "within the campaign window" filter, would drop them.
--      The spine keeps them on IS_IN_FLIGHT = 0 rows.
--    How (G1, aggregate first):
--      STEP 1  The spine: DIM_CAMPAIGN x DIM_DATE, each campaign joined to the dates of its
--              range START_DATE .. LEAST(END_DATE + 21, 2025-12-31). DATE_DAY is unique in
--              DIM_DATE, so each (campaign, date) appears once: 11,240 flight days + 120 x 21
--              post-flight days = 13,760 rows.
--      STEP 2  Each input aggregated to campaign x date ON ITS OWN:
--                spend_by_day        FCT_DAILY_SPEND by SPEND_DATE (already that grain; the
--                                    GROUP BY guarantees one row per key whatever happens upstream)
--                leads_by_day        FCT_LEAD_CONVERSIONS by CREATED_DATE
--                conversions_by_day  FCT_LEAD_CONVERSIONS (converted leads) by CONVERTED_DATE
--      STEP 3  LEFT JOIN each to the spine on (CAMPAIGN_ID, date): 1:1, so nothing is repeated;
--              COALESCE turns a day without spend, leads or conversions into 0.
--      A conversion is counted on the day it happened, under the campaign of its lead. The
--      LEFT JOINs start from the spine, so an input row outside the spine would be silently
--      lost; the tests count such rows (0) and check every total.
--    BUDGET_PRORATED comes from FCT_DAILY_SPEND (BUDGET / CAMPAIGN_DAYS per flight day), so it is
--      0 after the flight: SUM by month or year gives the planned budget of that period.
--    Expected: 13,760 rows (11,240 in flight); SUM(SPEND) 4,523,050.02; SUM(CONVERSIONS) 39,696,
--      of which 4,716 on IS_IN_FLIGHT = 0 rows; each campaign rolls up to MART_CAMPAIGN_PERFORMANCE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY
  COMMENT = 'Activity fact. Grain: one row per CAMPAIGN_ID x ACTIVITY_DATE on a spine from START_DATE to END_DATE + 21 days (the observed maximum lag), clipped at 2025-12-31 (13,760 rows: 11,240 flight days + 120 x 21 post-flight days). Delivery and budget by spend date, leads by created date, conversions and revenue by converted date: each aggregated to campaign x date first, then joined 1:1 to the spine. IS_IN_FLIGHT = 0 rows carry the 4,716 conversions after a campaign ended, and 0 spend. Activity basis: never divide CONVERSIONS by LEADS here (use MART_MONTHLY_COHORT for conversion rates). Ratios as SUM / SUM. Built by sql/02c_analysis_marts.sql.'
AS
WITH params AS (            -- the two documented bounds of the spine, in one place
  SELECT 21 AS POST_WINDOW_DAYS,              -- observed maximum lag (0..21 days)
         '2025-12-31'::DATE AS COVERAGE_END   -- documented coverage end = last DIM_DATE day
),
spine AS (                  -- STEP 1: one row per campaign x day of START_DATE .. END_DATE + 21
  SELECT c.CAMPAIGN_ID, c.CHANNEL, c.OBJECTIVE,
         d.DATE_DAY    AS ACTIVITY_DATE,
         d.MONTH_START AS ACTIVITY_MONTH,
         IFF(d.DATE_DAY BETWEEN c.START_DATE AND c.END_DATE, 1, 0) AS IS_IN_FLIGHT
  FROM MARKETING_CRM.MART.DIM_CAMPAIGN c
  CROSS JOIN params p                                                   -- one row
  JOIN MARKETING_CRM.MART.DIM_DATE d                                    -- a dimension, unique on DATE_DAY
    ON d.DATE_DAY BETWEEN c.START_DATE
                      AND LEAST(DATEADD('day', p.POST_WINDOW_DAYS, c.END_DATE), p.COVERAGE_END)
),
spend_by_day AS (           -- STEP 2a: delivery and budget, campaign x spend date
  SELECT CAMPAIGN_ID, SPEND_DATE AS ACTIVITY_DATE,
         SUM(IMPRESSIONS)     AS IMPRESSIONS,
         SUM(CLICKS)          AS CLICKS,
         SUM(SPEND)           AS SPEND,
         SUM(BUDGET_PRORATED) AS BUDGET_PRORATED
  FROM MARKETING_CRM.MART.FCT_DAILY_SPEND
  GROUP BY CAMPAIGN_ID, SPEND_DATE
),
leads_by_day AS (           -- STEP 2b: leads, campaign x created date
  SELECT CAMPAIGN_ID, CREATED_DATE AS ACTIVITY_DATE,
         COUNT(*) AS LEADS
  FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  GROUP BY CAMPAIGN_ID, CREATED_DATE
),
conversions_by_day AS (     -- STEP 2c: conversions, campaign (of the lead) x converted date
  SELECT CAMPAIGN_ID, CONVERTED_DATE AS ACTIVITY_DATE,
         COUNT(*)         AS CONVERSIONS,
         SUM(IS_TRIAL)    AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES,
         SUM(REVENUE)     AS REVENUE
  FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
  GROUP BY CAMPAIGN_ID, CONVERTED_DATE
)
SELECT s.CAMPAIGN_ID,
       s.ACTIVITY_DATE,
       s.ACTIVITY_MONTH,
       s.CHANNEL,
       s.OBJECTIVE,
       s.IS_IN_FLIGHT::NUMBER(1,0)                          AS IS_IN_FLIGHT,
       COALESCE(sp.IMPRESSIONS, 0)::NUMBER(38,0)            AS IMPRESSIONS,
       COALESCE(sp.CLICKS, 0)::NUMBER(38,0)                 AS CLICKS,
       COALESCE(sp.SPEND, 0)::NUMBER(18,2)                  AS SPEND,
       COALESCE(sp.BUDGET_PRORATED, 0)::NUMBER(18,6)        AS BUDGET_PRORATED,   -- 0 after the flight
       COALESCE(l.LEADS, 0)::NUMBER(38,0)                   AS LEADS,
       COALESCE(v.CONVERSIONS, 0)::NUMBER(38,0)             AS CONVERSIONS,
       COALESCE(v.TRIALS, 0)::NUMBER(38,0)                  AS TRIALS,
       COALESCE(v.PURCHASES, 0)::NUMBER(38,0)               AS PURCHASES,
       COALESCE(v.REVENUE, 0)::NUMBER(18,2)                 AS REVENUE
FROM spine s
LEFT JOIN spend_by_day       sp ON sp.CAMPAIGN_ID = s.CAMPAIGN_ID AND sp.ACTIVITY_DATE = s.ACTIVITY_DATE   -- STEP 3: 1:1
LEFT JOIN leads_by_day       l  ON l.CAMPAIGN_ID  = s.CAMPAIGN_ID AND l.ACTIVITY_DATE  = s.ACTIVITY_DATE   -- 1:1
LEFT JOIN conversions_by_day v  ON v.CAMPAIGN_ID  = s.CAMPAIGN_ID AND v.ACTIVITY_DATE  = s.ACTIVITY_DATE   -- 1:1
ORDER BY s.ACTIVITY_DATE, s.CAMPAIGN_ID;


-- -----------------------------------------------------------------------------
-- 2. MART_MONTHLY_MARKETING: one row per channel x month, ACTIVITY basis
--    What: what happened in each calendar month, per channel: spend, delivery, leads created,
--      conversions and revenue booked, the prorated budget of the month, and the number of
--      campaigns in flight.
--    Why: the Marketing Overview time series. Every measure is counted in the month it
--      happened, so the table answers "what did we spend and book in March?". It does not
--      answer "how well did March leads convert?": that is MART_MONTHLY_COHORT (G3). A
--      conversion in April of a lead created in March counts in April here.
--    How:
--      - The spine is every month of DIM_DATE (36) x every channel of DIM_CAMPAIGN (5): 180
--        rows. A CROSS JOIN of two small dimensions (36 x 5), not of facts. Months in which a
--        channel had no activity at all appear with zeros instead of disappearing.
--      - The measures are the daily activity fact (block 1) rolled up to channel x month in
--        one CTE, then joined 1:1 to the spine. Each daily row has one campaign, one channel
--        and one month, so the roll-up cannot double count.
--      - ACTIVE_CAMPAIGNS = campaigns with at least one in-flight day in the month (distinct
--        count). It is additive across channels within a month (a campaign has one channel),
--        but NOT across months: a campaign running for three months is active in each of
--        them. Over the 180 rows it sums to campaign-months, not campaigns.
--    G7: monthly volumes rise and fall with ACTIVE_CAMPAIGNS (1 to 20 per month; 3 / 1 in
--      2025-11 / 2025-12), so trends are read next to it, e.g. spend per active campaign as
--      SUM(SPEND) / SUM(ACTIVE_CAMPAIGNS) within one month.
--    No ratio columns: every chart on this table aggregates rows (months, channels, a date
--      range). CTR, CPL, ROAS, ... are SUM / SUM in Data Studio. ROAS here is revenue booked in
--      the period / spend in the period (activity basis): meaningful over longer ranges, not
--      at the edges (2025-12 books revenue of earlier leads on almost no spend).
--    Expected: 180 rows; totals as block 1; the 36 monthly totals reproduce the Phase 2 baseline
--      (spend, leads, conversions and revenue by activity month).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.MART_MONTHLY_MARKETING
  COMMENT = 'Monthly activity mart. Grain: one row per MONTH_START x CHANNEL, all 36 months (2023-01..2025-12) x 5 channels = 180 rows, zeros where nothing happened. ACTIVITY basis: spend by spend date, leads by created date, conversions and revenue by converted date (a conversion counts in the month it happened). Never blend with MART_MONTHLY_COHORT on one date axis, and never divide CONVERSIONS by LEADS here (not a conversion rate). ACTIVE_CAMPAIGNS = campaigns in flight on at least 1 day of the month: additive across channels, not across months. Additive bases only; ratios as SUM / SUM. Built by sql/02c_analysis_marts.sql.'
AS
WITH month_channel AS (     -- the spine: 36 months x 5 channels, so empty channel-months show as 0
  SELECT m.MONTH_START, ch.CHANNEL
  FROM (SELECT DISTINCT MONTH_START FROM MARKETING_CRM.MART.DIM_DATE) m
  CROSS JOIN (SELECT DISTINCT CHANNEL FROM MARKETING_CRM.MART.DIM_CAMPAIGN) ch
),
activity_by_month AS (      -- the daily activity fact rolled up to channel x month on its own
  SELECT ACTIVITY_MONTH AS MONTH_START, CHANNEL,
         COUNT(DISTINCT IFF(IS_IN_FLIGHT = 1, CAMPAIGN_ID, NULL)) AS ACTIVE_CAMPAIGNS,   -- NULLs are not counted
         SUM(SPEND)           AS SPEND,
         SUM(IMPRESSIONS)     AS IMPRESSIONS,
         SUM(CLICKS)          AS CLICKS,
         SUM(LEADS)           AS LEADS,
         SUM(CONVERSIONS)     AS CONVERSIONS,
         SUM(TRIALS)          AS TRIALS,
         SUM(PURCHASES)       AS PURCHASES,
         SUM(REVENUE)         AS REVENUE,
         SUM(BUDGET_PRORATED) AS BUDGET_PRORATED
  FROM MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY
  GROUP BY ACTIVITY_MONTH, CHANNEL
)
SELECT s.MONTH_START,
       s.CHANNEL,
       COALESCE(a.ACTIVE_CAMPAIGNS, 0)::NUMBER(38,0)  AS ACTIVE_CAMPAIGNS,
       COALESCE(a.SPEND, 0)::NUMBER(18,2)             AS SPEND,
       COALESCE(a.IMPRESSIONS, 0)::NUMBER(38,0)       AS IMPRESSIONS,
       COALESCE(a.CLICKS, 0)::NUMBER(38,0)            AS CLICKS,
       COALESCE(a.LEADS, 0)::NUMBER(38,0)             AS LEADS,
       COALESCE(a.CONVERSIONS, 0)::NUMBER(38,0)       AS CONVERSIONS,
       COALESCE(a.TRIALS, 0)::NUMBER(38,0)            AS TRIALS,
       COALESCE(a.PURCHASES, 0)::NUMBER(38,0)         AS PURCHASES,
       COALESCE(a.REVENUE, 0)::NUMBER(18,2)           AS REVENUE,
       COALESCE(a.BUDGET_PRORATED, 0)::NUMBER(18,6)   AS BUDGET_PRORATED
FROM month_channel s
LEFT JOIN activity_by_month a ON a.MONTH_START = s.MONTH_START AND a.CHANNEL = s.CHANNEL   -- 1:1
ORDER BY s.MONTH_START, s.CHANNEL;


-- -----------------------------------------------------------------------------
-- 3. MART_MONTHLY_COHORT: one row per channel x lead cohort month, LEAD-COHORT basis
--    What: for the leads created in each month (the cohort), per channel: how many there were,
--      how many converted (ever, within the observed 0-21 day lag), to what, with what revenue,
--      whether the conversion landed in the cohort month or a later one, the summed lag, and
--      how many leads have had their full 21-day window by the as-of date.
--    Why: the conversion rate of a month must compare a cohort with its own outcomes:
--      SUM(CONVERTED_LEADS) / SUM(LEADS) stays between 13.9% and 16.9% in every month, while
--      the activity "conversions this month / leads this month" swings from 8.3% to 93.8%
--      (G3, architecture decision 7). CONVERTED_SAME_MONTH and CONVERTED_LATER_MONTH show how
--      much of the difference comes from conversions crossing a month boundary.
--    How: FCT_LEAD_CONVERSIONS (one row per lead) aggregated to CREATED_MONTH x CHANNEL in one
--      CTE, then joined 1:1 to the same 36 x 5 spine as block 2. Every converted lead is in
--      its own cohort month, so SUM(CONVERTED_LEADS) over all rows is 39,696, the same total as
--      the activity table, but the months differ.
--      - CONVERTED_SAME_MONTH + CONVERTED_LATER_MONTH = CONVERTED_LEADS (no conversion precedes
--        its lead).
--      - SUM_DAYS_TO_CONVERT is the additive form of the lag: mean lag of any group =
--        SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS).
--      - MATURE_LEADS = SUM(IS_MATURE): leads created at least 21 days before the as-of date
--        (2025-12-31, an assumption). Under it every lead is mature (MATURE_LEADS = LEADS);
--        if the as-of date moved earlier, cohorts with MATURE_LEADS < LEADS would still be
--        filling up and their conversion rate would be understated.
--    Expected: 180 rows; 261,684 leads, 39,696 converted leads, 13,675 of them in a later month
--      than their lead (34.45%).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.MART_MONTHLY_COHORT
  COMMENT = 'Monthly lead-cohort mart. Grain: one row per COHORT_MONTH x CHANNEL, all 36 months x 5 channels = 180 rows, zeros where no leads were created. LEAD-COHORT basis: the leads created in COHORT_MONTH and what they later did (conversions are counted in the month their lead was created, wherever they landed). Never blend with MART_MONTHLY_MARKETING (activity basis) on one date axis. Cohort conversion rate = SUM(CONVERTED_LEADS) / SUM(LEADS); mean lag = SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS); cross-month share = SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS). Additive bases only. Built by sql/02c_analysis_marts.sql.'
AS
WITH month_channel AS (     -- the spine: 36 months x 5 channels
  SELECT m.MONTH_START AS COHORT_MONTH, ch.CHANNEL
  FROM (SELECT DISTINCT MONTH_START FROM MARKETING_CRM.MART.DIM_DATE) m
  CROSS JOIN (SELECT DISTINCT CHANNEL FROM MARKETING_CRM.MART.DIM_CAMPAIGN) ch
),
cohort_by_month AS (        -- one row per lead -> one row per cohort month x channel
  SELECT CREATED_MONTH AS COHORT_MONTH, CHANNEL,
         COUNT(*)                                                         AS LEADS,
         SUM(IS_CONVERTED)                                                AS CONVERTED_LEADS,
         SUM(IS_TRIAL)                                                    AS TRIALS,
         SUM(IS_PURCHASE)                                                 AS PURCHASES,
         SUM(REVENUE)                                                     AS REVENUE,
         COUNT_IF(IS_CONVERTED = 1 AND CONVERTED_MONTH = CREATED_MONTH)   AS CONVERTED_SAME_MONTH,
         COUNT_IF(IS_CONVERTED = 1 AND CONVERTED_MONTH > CREATED_MONTH)   AS CONVERTED_LATER_MONTH,
         SUM(DAYS_TO_CONVERT)                                             AS SUM_DAYS_TO_CONVERT,   -- NULL lags (unconverted) are skipped
         SUM(IS_MATURE)                                                   AS MATURE_LEADS
  FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  GROUP BY CREATED_MONTH, CHANNEL
)
SELECT s.COHORT_MONTH,
       s.CHANNEL,
       COALESCE(c.LEADS, 0)::NUMBER(38,0)                  AS LEADS,
       COALESCE(c.CONVERTED_LEADS, 0)::NUMBER(38,0)        AS CONVERTED_LEADS,
       COALESCE(c.TRIALS, 0)::NUMBER(38,0)                 AS TRIALS,
       COALESCE(c.PURCHASES, 0)::NUMBER(38,0)              AS PURCHASES,
       COALESCE(c.REVENUE, 0)::NUMBER(18,2)                AS REVENUE,
       COALESCE(c.CONVERTED_SAME_MONTH, 0)::NUMBER(38,0)   AS CONVERTED_SAME_MONTH,
       COALESCE(c.CONVERTED_LATER_MONTH, 0)::NUMBER(38,0)  AS CONVERTED_LATER_MONTH,
       COALESCE(c.SUM_DAYS_TO_CONVERT, 0)::NUMBER(38,0)    AS SUM_DAYS_TO_CONVERT,
       COALESCE(c.MATURE_LEADS, 0)::NUMBER(38,0)           AS MATURE_LEADS
FROM month_channel s
LEFT JOIN cohort_by_month c ON c.COHORT_MONTH = s.COHORT_MONTH AND c.CHANNEL = s.CHANNEL   -- 1:1
ORDER BY s.COHORT_MONTH, s.CHANNEL;


-- -----------------------------------------------------------------------------
-- 4. MART_CHANNEL_PERFORMANCE: one row per channel, full date range
--    What: the channel scorecard: the funnel bases, budget, the channel-grain KPIs, each
--      channel's share of total spend, leads and revenue, and a 95% interval for its lead
--      conversion rate.
--    How (G1, the plan's pattern at channel grain):
--      STEP 1  Each source aggregated to one row per channel ON ITS OWN:
--                campaigns_by_channel  DIM_CAMPAIGN          campaigns, BUDGET (whole campaigns)
--                spend_by_channel      FCT_DAILY_SPEND       impressions, clicks, spend
--                leads_by_channel      FCT_LEAD_CONVERSIONS  leads, converted, trials, purchases, revenue
--      STEP 2  The three joined 1:1 on CHANNEL.
--      STEP 3  Ratios from the channel sums (each dividend cast to NUMBER(32,18), NULLIF on
--              every denominator). This path does not read MART_CAMPAIGN_PERFORMANCE, so the
--              tests can compare the two independently: the channel roll-up of the campaign
--              table must give the same bases and ratios.
--    KPI definitions (channel grain; rates, ROAS and shares 6 dp, cost per unit 4 dp):
--      CTR                  CLICKS / IMPRESSIONS
--      CLICK_TO_LEAD_RATE   LEADS / CLICKS
--      LEAD_CONVERSION_RATE CONVERTED_LEADS / LEADS        (trial or purchase)
--      PURCHASE_RATE        PURCHASES / LEADS
--      COST_PER_LEAD        SPEND / LEADS
--      COST_PER_CONVERSION  SPEND / CONVERTED_LEADS
--      COST_PER_PURCHASE    SPEND / PURCHASES
--      ROAS                 REVENUE / SPEND                (last-touch attributed revenue, not causal: G4)
--      BUDGET_UTILIZATION   SPEND / BUDGET                 (valid: a channel holds whole campaigns)
--      CPC                  SPEND / CLICKS
--      CPM                  SPEND x 1000 / IMPRESSIONS     (near-round per channel: a generator artefact, G6)
--      SPEND_SHARE          SPEND / SUM(SPEND) OVER ()     (likewise LEADS_SHARE, REVENUE_SHARE)
--    The shares are rounded per row, so they need not add up to exactly 1.000000.
--    Wilson 95% interval for LEAD_CONVERSION_RATE (LCR_CI_LOW, LCR_CI_HIGH):
--      p = CONVERTED_LEADS / LEADS, n = LEADS, z = 1.959964 (two-sided 95% normal quantile)
--      centre = (p + z^2 / (2n)) / (1 + z^2 / n)
--      half   = z / (1 + z^2 / n) x SQRT(p (1 - p) / n + z^2 / (4 n^2))
--      LCR_CI_LOW = centre - half, LCR_CI_HIGH = centre + half
--      Why Wilson rather than p +/- z x SE: it stays inside 0..1 and keeps its coverage for
--      small n or p near 0 or 1, so the same formula also works for a campaign or a score band.
--      What it means: sampling noise only, treating each lead as an independent trial with the
--      same probability. It says nothing about attribution, bias or the synthetic generator,
--      and overlapping intervals are not a formal test of a difference.
--      SQRT needs FLOAT, so this is the one computation in double precision. An independent
--      60-digit Python computation [D in the tests] gives the same 6-dp bounds, and none of
--      the exact bounds lies within 4 x 10^-8 of a rounding midpoint, far beyond the error
--      of double precision.
--    No date dimension: the table covers the full range 2023-01-01..2025-12-31 (fixed dashboard
--      range). Channel trends over time come from MART_MONTHLY_MARKETING / MART_MONTHLY_COHORT.
--    Expected: 5 rows; spend and revenue per channel = the publisher reference to the cent;
--      bases and KPIs = the channel roll-up of MART_CAMPAIGN_PERFORMANCE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.MART_CHANNEL_PERFORMANCE
  COMMENT = 'Channel scorecard. Grain: one row per CHANNEL (5 rows), full date range 2023-01-01..2025-12-31, no date dimension. Campaigns/budget (DIM_CAMPAIGN), delivery and spend (FCT_DAILY_SPEND) and leads/conversions/revenue (FCT_LEAD_CONVERSIONS) are each aggregated to the channel first, then joined 1:1. Ratio columns are valid at channel grain only (aggregate across channels as SUM / SUM of the bases). ROAS is last-touch attributed revenue / spend, not causal. LCR_CI_LOW / LCR_CI_HIGH: Wilson 95% interval of LEAD_CONVERSION_RATE (sampling noise only). The funnel is an aggregate campaign funnel, not a person journey. Synthetic data. Built by sql/02c_analysis_marts.sql.'
AS
WITH campaigns_by_channel AS (   -- STEP 1a: campaign -> channel
  SELECT CHANNEL,
         COUNT(*)    AS CAMPAIGNS,
         SUM(BUDGET) AS BUDGET
  FROM MARKETING_CRM.MART.DIM_CAMPAIGN
  GROUP BY CHANNEL
),
spend_by_channel AS (            -- STEP 1b: campaign x day -> channel
  SELECT CHANNEL,
         SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS)      AS CLICKS,
         SUM(SPEND)       AS SPEND
  FROM MARKETING_CRM.MART.FCT_DAILY_SPEND
  GROUP BY CHANNEL
),
leads_by_channel AS (            -- STEP 1c: lead -> channel
  SELECT CHANNEL,
         COUNT(*)         AS LEADS,
         SUM(IS_CONVERTED) AS CONVERTED_LEADS,
         SUM(IS_TRIAL)    AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES,
         SUM(REVENUE)     AS REVENUE
  FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL
),
channel_grain AS (               -- STEP 2: one row per channel on every side -> 1:1 joins
  SELECT c.CHANNEL,
         c.CAMPAIGNS::NUMBER(38,0)                    AS CAMPAIGNS,
         c.BUDGET::NUMBER(18,2)                       AS BUDGET,
         COALESCE(s.SPEND, 0)::NUMBER(18,2)           AS SPEND,
         COALESCE(s.IMPRESSIONS, 0)::NUMBER(38,0)     AS IMPRESSIONS,
         COALESCE(s.CLICKS, 0)::NUMBER(38,0)          AS CLICKS,
         COALESCE(l.LEADS, 0)::NUMBER(38,0)           AS LEADS,
         COALESCE(l.CONVERTED_LEADS, 0)::NUMBER(38,0) AS CONVERTED_LEADS,
         COALESCE(l.TRIALS, 0)::NUMBER(38,0)          AS TRIALS,
         COALESCE(l.PURCHASES, 0)::NUMBER(38,0)       AS PURCHASES,
         COALESCE(l.REVENUE, 0)::NUMBER(18,2)         AS REVENUE
  FROM campaigns_by_channel c
  LEFT JOIN spend_by_channel s ON s.CHANNEL = c.CHANNEL   -- 1:1
  LEFT JOIN leads_by_channel l ON l.CHANNEL = c.CHANNEL   -- 1:1
),
wilson_inputs AS (               -- FLOAT inputs of the Wilson interval; NULL n (no leads) gives NULL bounds
  SELECT CHANNEL,
         CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)::FLOAT AS P,
         NULLIF(LEADS, 0)::FLOAT                          AS N,
         1.959964::FLOAT                                  AS Z
  FROM channel_grain
)
SELECT g.CHANNEL, g.CAMPAIGNS, g.BUDGET, g.SPEND, g.IMPRESSIONS, g.CLICKS, g.LEADS, g.CONVERTED_LEADS, g.TRIALS,
       g.PURCHASES, g.REVENUE,
       -- STEP 3: channel-grain ratios of the sums; the 18-dp dividend makes ROUND the only rounding
       ROUND(g.CLICKS::NUMBER(32,18)          / NULLIF(g.IMPRESSIONS, 0),     6)::NUMBER(18,6) AS CTR,
       ROUND(g.LEADS::NUMBER(32,18)           / NULLIF(g.CLICKS, 0),          6)::NUMBER(18,6) AS CLICK_TO_LEAD_RATE,
       ROUND(g.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(g.LEADS, 0),           6)::NUMBER(18,6) AS LEAD_CONVERSION_RATE,
       ROUND(g.PURCHASES::NUMBER(32,18)       / NULLIF(g.LEADS, 0),           6)::NUMBER(18,6) AS PURCHASE_RATE,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.LEADS, 0),           4)::NUMBER(18,4) AS COST_PER_LEAD,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.CONVERTED_LEADS, 0), 4)::NUMBER(18,4) AS COST_PER_CONVERSION,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.PURCHASES, 0),       4)::NUMBER(18,4) AS COST_PER_PURCHASE,
       ROUND(g.REVENUE::NUMBER(32,18)         / NULLIF(g.SPEND, 0),           6)::NUMBER(18,6) AS ROAS,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.BUDGET, 0),          6)::NUMBER(18,6) AS BUDGET_UTILIZATION,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.CLICKS, 0),          4)::NUMBER(18,4) AS CPC,
       ROUND((g.SPEND * 1000)::NUMBER(32,18)  / NULLIF(g.IMPRESSIONS, 0),     4)::NUMBER(18,4) AS CPM,
       -- shares of the 5-channel total; SUM() OVER () is the total over all rows of channel_grain
       ROUND(g.SPEND::NUMBER(32,18)   / NULLIF(SUM(g.SPEND)   OVER (), 0), 6)::NUMBER(18,6)      AS SPEND_SHARE,
       ROUND(g.LEADS::NUMBER(32,18)   / NULLIF(SUM(g.LEADS)   OVER (), 0), 6)::NUMBER(18,6)      AS LEADS_SHARE,
       ROUND(g.REVENUE::NUMBER(32,18) / NULLIF(SUM(g.REVENUE) OVER (), 0), 6)::NUMBER(18,6)      AS REVENUE_SHARE,
       -- Wilson 95% interval of LEAD_CONVERSION_RATE (formula in the block comment), in FLOAT, rounded once
       ROUND((w.P + w.Z * w.Z / (2 * w.N)
              - w.Z * SQRT(w.P * (1 - w.P) / w.N + w.Z * w.Z / (4 * w.N * w.N)))
             / (1 + w.Z * w.Z / w.N), 6)::NUMBER(18,6)                                           AS LCR_CI_LOW,
       ROUND((w.P + w.Z * w.Z / (2 * w.N)
              + w.Z * SQRT(w.P * (1 - w.P) / w.N + w.Z * w.Z / (4 * w.N * w.N)))
             / (1 + w.Z * w.Z / w.N), 6)::NUMBER(18,6)                                           AS LCR_CI_HIGH
FROM channel_grain g
JOIN wilson_inputs w ON w.CHANNEL = g.CHANNEL   -- 1:1 (both one row per channel)
ORDER BY g.CHANNEL;


-- -----------------------------------------------------------------------------
-- 5. MART_LEAD_QUALITY: one row per channel x 10-point lead score band
--    What: leads, conversions, revenue and lag per channel and score band ('01-10' .. '91-100'),
--      each band labelled with its plan segment, Low (1-40) / Medium (41-70) / High (71-100).
--    Why: the Lead Quality page and business question 4 ("how does the conversion rate change
--      with lead score?"). Bands of 10 points align with the segment cut-offs 40 and 70, so
--      the same table rolls up to segments (SUM by LEAD_SCORE_SEGMENT), to bands (SUM by
--      SCORE_BAND) or to channels, always as SUM / SUM. It reports association only: how
--      the score is produced is undocumented, and nothing here shows that it predicts or
--      causes conversion (G5). The score is near-uniform on 1-100 (about 26,000 leads per
--      band), a property of the synthetic data (G6).
--    How:
--      - The bands are an explicit 10-row list (edges and segment in one place, reviewable).
--        The spine is 5 channels x 10 bands = 50 rows, so a band without leads shows as 0.
--      - Each lead is assigned to its band by SCORE_BAND_MIN = FLOOR((LEAD_SCORE - 1) / 10) x 10
--        + 1 (1-10 -> 1, 11-20 -> 11, ..., 91-100 -> 91), aggregated to channel x band in one
--        CTE, then joined 1:1 to the spine. A lead with a NULL or out-of-range score would
--        find no band and drop out; the tests check that all 261,684 leads arrive.
--      - SCORE_BAND is zero-padded ('01-10') so that it also sorts correctly as text.
--      - SUM_LEAD_SCORE and SUM_DAYS_TO_CONVERT are the additive forms of the average score
--        and the mean lag.
--    Expected: 50 rows; segment sizes 104,245 / 78,862 / 78,577 leads with 9,505 / 12,758 /
--      17,433 converted leads; band sizes 25,748 .. 26,396 leads.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.MART_LEAD_QUALITY
  COMMENT = 'Lead quality mart. Grain: one row per CHANNEL x SCORE_BAND, 5 channels x 10 bands of 10 score points (01-10 .. 91-100) = 50 rows. Bands align with the segments Low 1-40 / Medium 41-70 / High 71-100 (LEAD_SCORE_SEGMENT), so the table rolls up to segment, band or channel with SUM. Conversion rate = SUM(CONVERTED_LEADS) / SUM(LEADS); average score = SUM(SUM_LEAD_SCORE) / SUM(LEADS); mean lag = SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS). Association only: how the score is produced is undocumented, and it is not assumed to predict conversion. Built by sql/02c_analysis_marts.sql.'
AS
WITH bands (SCORE_BAND, SCORE_BAND_MIN, SCORE_BAND_MAX, LEAD_SCORE_SEGMENT) AS (   -- the 10 bands and their plan segment
  SELECT * FROM VALUES
    ('01-10',   1,  10, 'Low'),    ('11-20',  11,  20, 'Low'),    ('21-30',  21,  30, 'Low'),
    ('31-40',  31,  40, 'Low'),    ('41-50',  41,  50, 'Medium'), ('51-60',  51,  60, 'Medium'),
    ('61-70',  61,  70, 'Medium'), ('71-80',  71,  80, 'High'),   ('81-90',  81,  90, 'High'),
    ('91-100', 91, 100, 'High')
),
channels AS (               -- the canonical channels
  SELECT DISTINCT CHANNEL FROM MARKETING_CRM.MART.DIM_CAMPAIGN
),
leads_by_band AS (          -- one row per lead -> one row per channel x band
  SELECT CHANNEL,
         FLOOR((LEAD_SCORE - 1) / 10) * 10 + 1 AS SCORE_BAND_MIN,   -- 1, 11, ..., 91
         COUNT(*)             AS LEADS,
         SUM(LEAD_SCORE)      AS SUM_LEAD_SCORE,
         SUM(IS_CONVERTED)    AS CONVERTED_LEADS,
         SUM(IS_TRIAL)        AS TRIALS,
         SUM(IS_PURCHASE)     AS PURCHASES,
         SUM(REVENUE)         AS REVENUE,
         SUM(DAYS_TO_CONVERT) AS SUM_DAYS_TO_CONVERT                -- NULL lags (unconverted) are skipped
  FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  GROUP BY CHANNEL, FLOOR((LEAD_SCORE - 1) / 10) * 10 + 1
)
SELECT ch.CHANNEL,
       b.SCORE_BAND::VARCHAR                              AS SCORE_BAND,
       b.SCORE_BAND_MIN::NUMBER(3,0)                      AS SCORE_BAND_MIN,
       b.SCORE_BAND_MAX::NUMBER(3,0)                      AS SCORE_BAND_MAX,
       b.LEAD_SCORE_SEGMENT::VARCHAR                      AS LEAD_SCORE_SEGMENT,
       COALESCE(l.LEADS, 0)::NUMBER(38,0)                 AS LEADS,
       COALESCE(l.SUM_LEAD_SCORE, 0)::NUMBER(38,0)        AS SUM_LEAD_SCORE,
       COALESCE(l.CONVERTED_LEADS, 0)::NUMBER(38,0)       AS CONVERTED_LEADS,
       COALESCE(l.TRIALS, 0)::NUMBER(38,0)                AS TRIALS,
       COALESCE(l.PURCHASES, 0)::NUMBER(38,0)             AS PURCHASES,
       COALESCE(l.REVENUE, 0)::NUMBER(18,2)               AS REVENUE,
       COALESCE(l.SUM_DAYS_TO_CONVERT, 0)::NUMBER(38,0)   AS SUM_DAYS_TO_CONVERT
FROM channels ch
CROSS JOIN bands b                                                   -- the spine: 5 x 10 dimension members
LEFT JOIN leads_by_band l ON l.CHANNEL = ch.CHANNEL AND l.SCORE_BAND_MIN = b.SCORE_BAND_MIN   -- 1:1
ORDER BY ch.CHANNEL, b.SCORE_BAND_MIN;


-- -----------------------------------------------------------------------------
-- 6-10. Column comments: meaning, basis, additivity and formula of every column
--    Why: as in 02b, the comments travel with the tables into Snowsight, INFORMATION_SCHEMA and
--      the dbt docs (Phase 5); the contract test fails if a column has none.
-- -----------------------------------------------------------------------------
ALTER TABLE MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY MODIFY
  COLUMN CAMPAIGN_ID     COMMENT 'Campaign (FK to DIM_CAMPAIGN). Grain key with ACTIVITY_DATE.',
  COLUMN ACTIVITY_DATE   COMMENT 'Calendar day (FK to DIM_DATE.DATE_DAY), from START_DATE to END_DATE + 21 days of the campaign (clipped at 2025-12-31; nothing is clipped today). Grain key with CAMPAIGN_ID.',
  COLUMN ACTIVITY_MONTH  COMMENT 'Activity month: first day of the month of ACTIVITY_DATE.',
  COLUMN CHANNEL         COMMENT 'Channel of the campaign, from DIM_CAMPAIGN.',
  COLUMN OBJECTIVE       COMMENT 'Objective of the campaign, from DIM_CAMPAIGN.',
  COLUMN IS_IN_FLIGHT    COMMENT '1 if START_DATE <= ACTIVITY_DATE <= END_DATE (a flight day, which always has a spend row), 0 for the 21 days after the flight. 0/1, so SUM = flight days.',
  COLUMN IMPRESSIONS     COMMENT 'Impressions delivered on the day (by spend date); 0 after the flight. Additive.',
  COLUMN CLICKS          COMMENT 'Clicks on the day (by spend date); 0 after the flight. Additive. CTR = SUM(CLICKS) / SUM(IMPRESSIONS).',
  COLUMN SPEND           COMMENT 'Media spend on the day (by spend date); 0 after the flight. Additive; total 4,523,050.02.',
  COLUMN BUDGET_PRORATED COMMENT 'FCT_DAILY_SPEND.BUDGET_PRORATED (campaign BUDGET / CAMPAIGN_DAYS, 6 dp) on flight days, 0 after the flight: the planned budget of the day. Additive across days and campaigns; total 5,418,642.159820. An even spread is an assumption, not observed pacing: not a utilisation base below whole campaigns.',
  COLUMN LEADS           COMMENT 'Leads created on the day for the campaign (by created date). Additive.',
  COLUMN CONVERSIONS     COMMENT 'Conversions (trial or purchase) booked on the day (by converted date) for leads of the campaign; they can land up to 21 days after the flight. Additive. Activity basis: a conversion rate must come from MART_MONTHLY_COHORT, not from CONVERSIONS / LEADS of the same days.',
  COLUMN TRIALS          COMMENT 'Conversions to a trial booked on the day. Additive. A parallel outcome to PURCHASES, not a funnel stage before it.',
  COLUMN PURCHASES       COMMENT 'Conversions to a purchase booked on the day. Additive.',
  COLUMN REVENUE         COMMENT 'Last-touch attributed revenue booked on the day (by converted date); 0.00 for trials. Additive; total 21,561,839.01. ROAS = SUM(REVENUE) / SUM(SPEND), attributed, not causal.';

ALTER TABLE MARKETING_CRM.MART.MART_MONTHLY_MARKETING MODIFY
  COLUMN MONTH_START      COMMENT 'Activity month (first day of the month), 2023-01-01..2025-12-01; FK to DIM_DATE.MONTH_START. Grain key with CHANNEL. Never put on one axis with MART_MONTHLY_COHORT.COHORT_MONTH.',
  COLUMN CHANNEL          COMMENT 'Canonical channel (from DIM_CAMPAIGN). Grain key with MONTH_START.',
  COLUMN ACTIVE_CAMPAIGNS COMMENT 'Campaigns of the channel in flight on at least 1 day of the month (distinct count). Additive across channels within a month, NOT across months (a campaign counts in every month it runs): SUM over months gives campaign-months. Read every volume next to it.',
  COLUMN SPEND            COMMENT 'Spend in the month (by spend date). Additive; total 4,523,050.02.',
  COLUMN IMPRESSIONS      COMMENT 'Impressions in the month (by spend date). Additive.',
  COLUMN CLICKS           COMMENT 'Clicks in the month (by spend date). Additive. CTR = SUM(CLICKS) / SUM(IMPRESSIONS), CPC = SUM(SPEND) / SUM(CLICKS).',
  COLUMN LEADS            COMMENT 'Leads created in the month (by created date). Additive. CPL = SUM(SPEND) / SUM(LEADS).',
  COLUMN CONVERSIONS      COMMENT 'Conversions (trial or purchase) that happened in the month (by converted date), whenever their lead was created. Additive; total 39,696. NOT a numerator for LEADS of the same month: for conversion rates use MART_MONTHLY_COHORT.',
  COLUMN TRIALS           COMMENT 'Conversions to a trial in the month (by converted date). Additive.',
  COLUMN PURCHASES        COMMENT 'Conversions to a purchase in the month (by converted date). Additive.',
  COLUMN REVENUE          COMMENT 'Last-touch attributed revenue booked in the month (by converted date). Additive; total 21,561,839.01. SUM(REVENUE) / SUM(SPEND) is activity-basis ROAS (attributed, not causal).',
  COLUMN BUDGET_PRORATED  COMMENT 'Planned budget of the month: SUM of FCT_DAILY_SPEND.BUDGET_PRORATED over its flight days. Additive across months and channels; total 5,418,642.159820. An even spread is an assumption: SPEND / BUDGET_PRORATED of a month is pacing against that assumption, not budget utilisation.';

ALTER TABLE MARKETING_CRM.MART.MART_MONTHLY_COHORT MODIFY
  COLUMN COHORT_MONTH          COMMENT 'Lead cohort month: the month the leads were created (FCT_LEAD_CONVERSIONS.CREATED_MONTH), 2023-01-01..2025-12-01. Grain key with CHANNEL. Never put on one axis with MART_MONTHLY_MARKETING.MONTH_START.',
  COLUMN CHANNEL               COMMENT 'Canonical channel (from DIM_CAMPAIGN). Grain key with COHORT_MONTH.',
  COLUMN LEADS                 COMMENT 'Leads created in the cohort month. Additive; total 261,684. The denominator of the cohort conversion rate.',
  COLUMN CONVERTED_LEADS       COMMENT 'Leads of the cohort that converted (trial or purchase), whenever the conversion happened. Additive; total 39,696. Cohort conversion rate = SUM(CONVERTED_LEADS) / SUM(LEADS).',
  COLUMN TRIALS                COMMENT 'Leads of the cohort that converted to a trial. Additive.',
  COLUMN PURCHASES             COMMENT 'Leads of the cohort that converted to a purchase. Additive. Purchase rate = SUM(PURCHASES) / SUM(LEADS).',
  COLUMN REVENUE               COMMENT 'Last-touch attributed revenue of the leads of the cohort. Additive; total 21,561,839.01. Revenue per lead = SUM(REVENUE) / SUM(LEADS).',
  COLUMN CONVERTED_SAME_MONTH  COMMENT 'Converted leads of the cohort whose conversion landed in the cohort month. Additive. CONVERTED_SAME_MONTH + CONVERTED_LATER_MONTH = CONVERTED_LEADS.',
  COLUMN CONVERTED_LATER_MONTH COMMENT 'Converted leads of the cohort whose conversion landed in a later month (13,675 in total). Additive. Cross-month share = SUM(CONVERTED_LATER_MONTH) / SUM(CONVERTED_LEADS): the reason activity and cohort months differ.',
  COLUMN SUM_DAYS_TO_CONVERT   COMMENT 'Sum of DAYS_TO_CONVERT over the converted leads of the cohort (0 if none). Additive. Mean lag = SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS).',
  COLUMN MATURE_LEADS          COMMENT 'Leads of the cohort created at least 21 days before the assumed as-of date 2025-12-31 (SUM of FCT_LEAD_CONVERSIONS.IS_MATURE). Equals LEADS in every row under the assumption; a cohort with MATURE_LEADS < LEADS would still be converting.';

ALTER TABLE MARKETING_CRM.MART.MART_CHANNEL_PERFORMANCE MODIFY
  COLUMN CHANNEL              COMMENT 'Canonical channel (PK): affiliate, display, paid_search, paid_social, video.',
  COLUMN CAMPAIGNS            COMMENT 'Campaigns of the channel (24 each). Additive.',
  COLUMN BUDGET               COMMENT 'Sum of the campaign budgets of the channel (whole campaigns). Additive across channels.',
  COLUMN SPEND                COMMENT 'Spend, full range. Additive; equals the publisher reference per channel.',
  COLUMN IMPRESSIONS          COMMENT 'Impressions, full range. Additive.',
  COLUMN CLICKS               COMMENT 'Clicks, full range. Additive.',
  COLUMN LEADS                COMMENT 'Leads, full range. Additive.',
  COLUMN CONVERTED_LEADS      COMMENT 'Leads that converted (trial or purchase). Additive. TRIALS + PURCHASES = CONVERTED_LEADS.',
  COLUMN TRIALS               COMMENT 'Leads that converted to a trial. Additive. Parallel to PURCHASES, not a stage before it (a lead converts once).',
  COLUMN PURCHASES            COMMENT 'Leads that converted to a purchase. Additive.',
  COLUMN REVENUE              COMMENT 'Last-touch attributed revenue, full range. Additive; equals the publisher reference per channel.',
  COLUMN CTR                  COMMENT 'CLICKS / IMPRESSIONS, channel grain only (6 dp). Across channels: SUM(CLICKS) / SUM(IMPRESSIONS).',
  COLUMN CLICK_TO_LEAD_RATE   COMMENT 'LEADS / CLICKS, channel grain only (6 dp). Aggregate funnel ratio of two different units, not a per-person probability.',
  COLUMN LEAD_CONVERSION_RATE COMMENT 'CONVERTED_LEADS / LEADS, channel grain only (6 dp). Across channels: SUM(CONVERTED_LEADS) / SUM(LEADS). Interval: LCR_CI_LOW .. LCR_CI_HIGH.',
  COLUMN PURCHASE_RATE        COMMENT 'PURCHASES / LEADS, channel grain only (6 dp).',
  COLUMN COST_PER_LEAD        COMMENT 'SPEND / LEADS, channel grain only (4 dp). Across channels: SUM(SPEND) / SUM(LEADS).',
  COLUMN COST_PER_CONVERSION  COMMENT 'SPEND / CONVERTED_LEADS, channel grain only (4 dp).',
  COLUMN COST_PER_PURCHASE    COMMENT 'SPEND / PURCHASES, channel grain only (4 dp).',
  COLUMN ROAS                 COMMENT 'REVENUE / SPEND, channel grain only (6 dp). Last-touch attributed revenue per unit of spend: describes attribution, not the causal return of the spend.',
  COLUMN BUDGET_UTILIZATION   COMMENT 'SPEND / BUDGET, channel grain only (6 dp); valid because a channel holds whole campaigns over the full range.',
  COLUMN CPC                  COMMENT 'Cost per click, SPEND / CLICKS, channel grain only (4 dp).',
  COLUMN CPM                  COMMENT 'Cost per 1,000 impressions, SPEND x 1000 / IMPRESSIONS, channel grain only (4 dp). Near-round per channel: a property of the synthetic generator, not a market price.',
  COLUMN SPEND_SHARE          COMMENT 'SPEND / total SPEND of the 5 channels (6 dp, rounded per row, so the shares need not sum to exactly 1).',
  COLUMN LEADS_SHARE          COMMENT 'LEADS / total LEADS of the 5 channels (6 dp, rounded per row).',
  COLUMN REVENUE_SHARE        COMMENT 'REVENUE / total REVENUE of the 5 channels (6 dp, rounded per row). Attributed revenue.',
  COLUMN LCR_CI_LOW           COMMENT 'Lower bound of the Wilson 95% interval of LEAD_CONVERSION_RATE (z = 1.959964, 6 dp). Channel grain only; not additive, never SUM or AVG across channels (recompute the interval from SUM(CONVERTED_LEADS), SUM(LEADS)). Sampling noise only, assuming independent leads; overlapping intervals are not a formal test.',
  COLUMN LCR_CI_HIGH          COMMENT 'Upper bound of the Wilson 95% interval of LEAD_CONVERSION_RATE (z = 1.959964, 6 dp). Channel grain only; not additive, never SUM or AVG across channels (recompute the interval from SUM(CONVERTED_LEADS), SUM(LEADS)).';

ALTER TABLE MARKETING_CRM.MART.MART_LEAD_QUALITY MODIFY
  COLUMN CHANNEL             COMMENT 'Canonical channel (from DIM_CAMPAIGN). Grain key with SCORE_BAND.',
  COLUMN SCORE_BAND          COMMENT 'Lead score band of 10 points, zero-padded so it sorts as text: 01-10, 11-20, ..., 91-100. Grain key with CHANNEL.',
  COLUMN SCORE_BAND_MIN      COMMENT 'Lowest score of the band (1, 11, ..., 91). Attribute: group or sort by it, never SUM (a numeric field defaults to SUM in Data Studio; over 5 channels that shows 5 x the edge).',
  COLUMN SCORE_BAND_MAX      COMMENT 'Highest score of the band (10, 20, ..., 100). Attribute: group or sort by it, never SUM (a numeric field defaults to SUM in Data Studio).',
  COLUMN LEAD_SCORE_SEGMENT  COMMENT 'Plan segment of the band: Low (1-40), Medium (41-70), High (71-100); bands never straddle a cut-off, so SUM by segment is exact.',
  COLUMN LEADS               COMMENT 'Leads of the channel with a score in the band. Additive; total 261,684.',
  COLUMN SUM_LEAD_SCORE      COMMENT 'Sum of LEAD_SCORE of those leads. Additive. Average score = SUM(SUM_LEAD_SCORE) / SUM(LEADS).',
  COLUMN CONVERTED_LEADS     COMMENT 'Leads of the band that converted (trial or purchase). Additive. Conversion rate = SUM(CONVERTED_LEADS) / SUM(LEADS): association with the score, not evidence that the score predicts conversion.',
  COLUMN TRIALS              COMMENT 'Leads of the band that converted to a trial. Additive.',
  COLUMN PURCHASES           COMMENT 'Leads of the band that converted to a purchase. Additive.',
  COLUMN REVENUE             COMMENT 'Last-touch attributed revenue of the leads of the band. Additive.',
  COLUMN SUM_DAYS_TO_CONVERT COMMENT 'Sum of DAYS_TO_CONVERT over the converted leads of the band (0 if none). Additive. Mean lag = SUM(SUM_DAYS_TO_CONVERT) / SUM(CONVERTED_LEADS).';


-- -----------------------------------------------------------------------------
-- 11. Build summary (descriptive; every check is in 02c_analysis_marts_tests.sql)
--    One row per MART table: type, rows and bytes (table metadata, no scan), columns, and
--    columns with a comment. Expected: the five analysis marts with 13,760 / 180 / 180 / 5 / 50
--    rows and every column commented, next to the Phase 3 core tables and CONNECTION_TEST.
-- -----------------------------------------------------------------------------
SELECT t.TABLE_NAME, t.TABLE_TYPE, t.ROW_COUNT, t.BYTES, COUNT(c.COLUMN_NAME) AS N_COLUMNS,
       COUNT(c.COMMENT) AS COLUMNS_WITH_COMMENT, t.TABLE_OWNER, t.CREATED
FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES t
LEFT JOIN MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS c
       ON c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = 'MART'
GROUP BY t.TABLE_NAME, t.TABLE_TYPE, t.ROW_COUNT, t.BYTES, t.TABLE_OWNER, t.CREATED
ORDER BY DECODE(t.TABLE_NAME, 'FCT_CAMPAIGN_DAILY_ACTIVITY', 1, 'MART_MONTHLY_MARKETING', 2, 'MART_MONTHLY_COHORT', 3,
                'MART_CHANNEL_PERFORMANCE', 4, 'MART_LEAD_QUALITY', 5, 6), t.TABLE_NAME;
