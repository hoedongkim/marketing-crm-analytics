-- =============================================================================
-- Phase 3 / 02b: core MART models (dimensions, facts, campaign KPI table)
-- -----------------------------------------------------------------------------
-- Purpose
--   Build the first, grain-safe MART layer on top of the clean STAGING views:
--     DIM_DATE                   one row per calendar day, 2023-01-01..2025-12-31     1,096 rows
--     DIM_CAMPAIGN               one row per campaign; the canonical CHANNEL            120 rows
--     FCT_DAILY_SPEND            one row per campaign x active day (delivery + budget) 11,240 rows
--     FCT_LEAD_CONVERSIONS       one row per lead: the lead-cohort fact               261,684 rows
--     MART_CAMPAIGN_PERFORMANCE  one row per campaign: every funnel base + KPIs         120 rows
--   These are the core models. Phase 4 adds the analysis marts on top of them (channel, lead
--   quality, monthly, and a daily activity spine to END_DATE + 21). Phase 5 ports every model
--   to dbt Core with the same names (dim_date, dim_campaign, fct_daily_spend,
--   fct_lead_conversions, mart_campaign_performance), so MART and the dbt project share one
--   contract.
-- The grain rule (architecture decision 6), and where each model applies it
--   daily_spend is one row per campaign x day; leads is one row per lead. A row-level join of
--   the two on CAMPAIGN_ID repeats every spend row once per lead of its campaign and inflates
--   spend 2,495x (4.52 M -> 11.3 B); adding the date to the join still inflates it 27x
--   (docs/data_profile.md, "The grain trap"). So in this file:
--     - A fact is only ever joined to something with ONE row per join key on the other side:
--       a fact to a dimension (n:1), or two inputs that were each aggregated to the same grain
--       first (1:1). Two facts are never joined row by row.
--     - FCT_DAILY_SPEND and FCT_LEAD_CONVERSIONS take CHANNEL / OBJECTIVE from DIM_CAMPAIGN
--       (n:1, one campaign row per key): the row count and every measure stay unchanged.
--     - FCT_LEAD_CONVERSIONS joins conversions to leads 1:0..1 (LEAD_ID is unique in
--       STG_CONVERSIONS), so a lead never appears twice.
--     - MART_CAMPAIGN_PERFORMANCE (block 5) is the plan's pattern: spend, leads and
--       conversions are each aggregated to one row per campaign in their own CTE, and only
--       then joined 1:1 to DIM_CAMPAIGN.
--     - Budget is one amount per campaign. It is never repeated on daily rows (SUM would count
--       it once per window day). FCT_DAILY_SPEND carries BUDGET_PRORATED instead.
--   02b_core_models_tests.sql proves it: total spend is 4,523,050.02 in every table that
--   carries spend, and every campaign reproduces the Phase 2 baseline exactly.
-- Why tables
--   MART is what Data Studio queries, repeatedly and live during the build. Tables are read
--   without recomputing the joins and aggregations on every chart refresh, and they are small.
--   CREATE OR REPLACE TABLE ... AS rebuilds each one from STAGING in seconds, so the file is
--   idempotent. In Phase 5 these become dbt models with materialized = 'table'.
-- How to run
--   From the repository root, after sql/02_data_cleaning.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02b_core_models.sql
--   Then run the tests:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02b_core_models_tests.sql
--   15 statements, a few seconds on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02b_core_models.txt.
-- Role
--   CRM_TRANSFORMER: SELECT on the STAGING views, CREATE TABLE in MART. It owns the tables.
--   CRM_REPORTER (the Data Studio service user) reads them through the future grant on MART
--   tables from the bootstrap. CREATE OR REPLACE creates a new table, and the future grant
--   applies to it again, so no GRANT statement is needed here. MART.CONNECTION_TEST (Phase 1)
--   is left untouched; Phase 6 drops it.
-- Inputs / outputs
--   in   MARKETING_CRM.STAGING.STG_CAMPAIGNS, STG_DAILY_SPEND, STG_LEADS, STG_CONVERSIONS (the clean
--        release only). Never STG_CHALLENGE_*: every challenge key also exists in the clean
--        release, so using them would double-count (architecture decision 5).
--   out  MARKETING_CRM.MART.DIM_DATE                  DATE_DAY (PK), YEAR, QUARTER, MONTH_START, MONTH_NAME,
--                                                     WEEK_START, DAY_OF_WEEK_ISO, DAY_NAME, IS_WEEKEND
--        MARKETING_CRM.MART.DIM_CAMPAIGN              CAMPAIGN_ID (PK), CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
--                                                     START_DATE, END_DATE, CAMPAIGN_DAYS, BUDGET, START_YEAR,
--                                                     START_MONTH
--        MARKETING_CRM.MART.FCT_DAILY_SPEND           SPEND_ID (PK), CAMPAIGN_ID, SPEND_DATE, SPEND_MONTH, CHANNEL,
--                                                     OBJECTIVE, IMPRESSIONS, CLICKS, SPEND, BUDGET_PRORATED
--        MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS      LEAD_ID (PK), CAMPAIGN_ID, CHANNEL, OBJECTIVE, CREATED_DATE,
--                                                     CREATED_MONTH, LEAD_SOURCE, LEAD_SCORE, LEAD_SCORE_SEGMENT,
--                                                     CONVERSION_ID, CONVERTED_DATE, CONVERTED_MONTH,
--                                                     CONVERSION_TYPE, IS_CONVERTED, IS_TRIAL, IS_PURCHASE, REVENUE,
--                                                     DAYS_TO_CONVERT, CONVERTED_AFTER_CAMPAIGN_END, AS_OF_DATE,
--                                                     IS_MATURE
--        MARKETING_CRM.MART.MART_CAMPAIGN_PERFORMANCE CAMPAIGN_ID (PK) + the DIM_CAMPAIGN attributes, BUDGET,
--                                                     SPEND_DAYS, IMPRESSIONS, CLICKS, SPEND, LEADS,
--                                                     CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, CTR,
--                                                     CLICK_TO_LEAD_RATE, LEAD_CONVERSION_RATE, PURCHASE_RATE,
--                                                     COST_PER_LEAD, COST_PER_CONVERSION, COST_PER_PURCHASE,
--                                                     ROAS, BUDGET_UTILIZATION
--   Every table and column has a COMMENT (grain, meaning, KPI formula); blocks 1-5 set the
--   table comment, blocks 6-10 the column comments.
-- Conventions
--   Names       UPPERCASE ASCII column names, because Data Studio shows them as field names
--               and the Sheets snapshot (architecture decision 8) keeps them.
--   Types       Every column has an explicit type, so the contract test can check it:
--               ids, names, codes TEXT; dates DATE; months DATE (first day of the month, from
--               DATE_TRUNC), so Data Studio treats them as dates; counts NUMBER(38,0); 0/1 flags
--               NUMBER(1,0); money NUMBER(12,2) per row and NUMBER(18,2) per campaign; rates
--               and ROAS NUMBER(18,6); cost per unit NUMBER(18,4).
--   Flags       Fact flags (IS_CONVERTED, IS_TRIAL, IS_PURCHASE, CONVERTED_AFTER_CAMPAIGN_END,
--               IS_MATURE) are 0/1 integers, so Data Studio can SUM them: SUM(IS_CONVERTED) is
--               the number of converted leads and SUM / COUNT the conversion rate. The one
--               BOOLEAN, DIM_DATE.IS_WEEKEND, is a filter attribute, never a measure.
--   NULLs       COALESCE turns "no row on the other side" into 0 where 0 is the true value: a
--               lead without a conversion has REVENUE 0.00, a campaign without leads would have
--               LEADS 0. A value that does not exist stays NULL: the conversion date of an
--               unconverted lead, DAYS_TO_CONVERT, and a ratio whose denominator is 0
--               (NULLIF(denominator, 0), never a division error or a fake 0).
--   Ratios      Additive numerator and denominator columns always ship next to a ratio
--               (architecture decision 9). The ratio columns of MART_CAMPAIGN_PERFORMANCE are
--               valid only at campaign grain, e.g. in a campaign ranking table. Any chart that
--               aggregates campaigns (a channel, a month, a scorecard) must use a ratio of sums,
--               e.g. SUM(REVENUE) / SUM(SPEND), never SUM or AVG of the ratio column.
--   Rounding    Rates, ROAS and BUDGET_PRORATED are stored at 6 dp, cost per unit at 4 dp. Each
--               is rounded ONCE, half away from zero, from the exact quotient: the convention of
--               the Phase 2 baseline [P3]. Snowflake does not do that by itself. It rounds a
--               fixed-point quotient to max(s1, min(s1 + 6, 12)) decimals, where s1 is the scale
--               of the dividend: 6 dp for COUNT / COUNT, but 8 dp for a 2-dp amount. So
--               ROUND(SPEND / LEADS, 4) rounds twice (to 8 dp, then to 4 dp) and can be one unit
--               off in the last stored digit. Probed in this account on 2026-10-14:
--               ROUND(12345499.95 / 10000000, 4) = 1.2346 (exact 1.234549995 -> 1.2345), and
--               (BUDGET / CAMPAIGN_DAYS)::NUMBER(18,6) of CMP0050 gave 298.288032 (exact
--               37,882.58 / 127 = 298.28803149... -> 298.288031).
--               The rule: every division casts its dividend to NUMBER(32,18) first, so the
--               quotient keeps 18 dp and the ROUND to the stored scale is the only rounding that
--               matters. Why 18 dp is enough: with a dividend of at most 2 dp and a divisor of
--               D units (a count, or an amount in cents), an exact quotient that is not itself a
--               rounding midpoint is at least 1 / (2 x 10^8 x D) away from one, and the 18-dp
--               error (at most 5 x 10^-19) cannot cross that gap for any D below 10^10, i.e.
--               any count, or any amount up to 100 million. NUMBER(32,18) leaves 14 integer
--               digits, and the quotient types are NUMBER(32,18) / NUMBER(34,18): no overflow.
--   Data checks MART takes every STAGING row and never filters on DQ_IS_VALID. Dropping a
--               flagged spend or revenue row would silently break the control totals; instead,
--               the STAGING tests (02_data_cleaning_tests.sql block 4) and block 2 of
--               02b_core_models_tests.sql fail if any input row is flagged.
-- Assumptions (documented in docs/data_profile.md, "Time")
--   AS_OF_DATE = 2025-12-31, the end of the documented coverage. The data alone cannot prove
--   that the youngest cohorts are complete; if the extract is complete to 2025-12-31, every
--   lead has had at least 29 days, more than the observed maximum lag of 21 days, so IS_MATURE
--   is 1 for every lead.
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] 0 context   [5] 1 DIM_DATE   [6] 2 DIM_CAMPAIGN   [7] 3 FCT_DAILY_SPEND
--   [8] 4 FCT_LEAD_CONVERSIONS   [9] 5 MART_CAMPAIGN_PERFORMANCE   [10-14] 6-10 column comments
--   [15] 11 build summary
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Context: the transformer role only, no secondary roles (no accidental writes elsewhere)
-- -----------------------------------------------------------------------------
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.MART;


-- -----------------------------------------------------------------------------
-- 1. DIM_DATE: one row per calendar day, 2023-01-01..2025-12-31
--    What: a gap-free date spine with the calendar attributes the dashboard filters and groups
--      by. Week attributes follow ISO 8601 (weeks start on Monday).
--    Why: the dataset's documented coverage is 1,096 days, but only 1,064 of them have spend
--      (32 days have none, docs/data_profile.md "Time"). Facts alone would make those days
--      vanish from a time axis; the spine keeps them, so they show as 0. The fixed range also
--      matches the dashboard's fixed date range (architecture decision 9).
--    How:
--      - ROW_NUMBER() over GENERATOR numbers the rows 1..1,096 without gaps. SEQ4() alone
--        does not guarantee a gap-free sequence, so it only orders the rows here.
--      - ROWCOUNT 1,096 = DATEDIFF('day', '2023-01-01', '2025-12-31') + 1. The WHERE clause
--        keeps the end bound explicit, and the tests check both bounds and the count.
--      - WEEK_START is computed from DAYOFWEEKISO, so it is always the Monday of the ISO week.
--        DATE_TRUNC('week') would depend on the WEEK_START session parameter.
--      - DAYNAME() returns 'Mon'; DECODE gives the full name. TO_CHAR(d, 'MMMM') gives the
--        full month name.
--    Expected: 1,096 rows; first 2023-01-01 (a Sunday, DAY_OF_WEEK_ISO 7), last 2025-12-31.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.DIM_DATE
  COMMENT = 'Calendar dimension. Grain: one row per DATE_DAY, gap-free 2023-01-01..2025-12-31 = the documented dataset coverage (1,096 days, incl. 32 days without spend). ISO weeks start on Monday. Built by sql/02b_core_models.sql.'
AS
WITH spine AS (   -- gap-free: ROW_NUMBER() is 1..N with no gaps; SEQ4() only orders the generated rows
  SELECT DATEADD('day', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2023-01-01'::DATE) AS DATE_DAY
  FROM TABLE(GENERATOR(ROWCOUNT => 1096))   -- 1,096 = DATEDIFF('day', '2023-01-01', '2025-12-31') + 1
)
SELECT DATE_DAY,
       YEAR(DATE_DAY)::NUMBER(4,0)                             AS YEAR,
       QUARTER(DATE_DAY)::NUMBER(1,0)                          AS QUARTER,
       DATE_TRUNC('month', DATE_DAY)                           AS MONTH_START,
       TO_CHAR(DATE_DAY, 'MMMM')::VARCHAR                      AS MONTH_NAME,
       DATEADD('day', 1 - DAYOFWEEKISO(DATE_DAY), DATE_DAY)    AS WEEK_START,        -- Monday, whatever WEEK_START says
       DAYOFWEEKISO(DATE_DAY)::NUMBER(1,0)                     AS DAY_OF_WEEK_ISO,   -- 1 = Monday ... 7 = Sunday
       DECODE(DAYOFWEEKISO(DATE_DAY), 1, 'Monday', 2, 'Tuesday', 3, 'Wednesday', 4, 'Thursday',
                                      5, 'Friday', 6, 'Saturday', 7, 'Sunday')::VARCHAR AS DAY_NAME,
       DAYOFWEEKISO(DATE_DAY) IN (6, 7)                        AS IS_WEEKEND
FROM spine
WHERE DATE_DAY <= '2025-12-31'::DATE
ORDER BY DATE_DAY;


-- -----------------------------------------------------------------------------
-- 2. DIM_CAMPAIGN: one row per campaign
--    What: the campaign attributes from STG_CAMPAIGNS, plus START_YEAR and START_MONTH for
--      grouping campaigns by when they started.
--    Why: every fact takes CHANNEL and OBJECTIVE from here. CHANNEL is the canonical channel
--      dimension: LEAD_SOURCE duplicates it today (0 mismatches over 261,684 leads), but the
--      challenge extract shows that the source column can drift (' PAID_SEARCH ').
--      STG_CAMPAIGNS is already unique on CAMPAIGN_ID (de-duplicated and tested in STAGING), so
--      a join from any fact to this table is n:1 and cannot fan out.
--    Expected: 120 rows, 24 per channel; SUM(BUDGET) 5,418,642.16.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.DIM_CAMPAIGN
  COMMENT = 'Campaign dimension. Grain: one row per CAMPAIGN_ID (120 rows). Source: STAGING.STG_CAMPAIGNS (clean release). CHANNEL here is the canonical channel dimension. BUDGET is per campaign window: additive across campaigns, not across dates. Built by sql/02b_core_models.sql.'
AS
SELECT CAMPAIGN_ID,
       CAMPAIGN_NAME,
       CHANNEL,
       OBJECTIVE,
       START_DATE,
       END_DATE,
       CAMPAIGN_DAYS,                                -- END_DATE - START_DATE + 1, from STAGING
       BUDGET,
       YEAR(START_DATE)::NUMBER(4,0)  AS START_YEAR,
       DATE_TRUNC('month', START_DATE) AS START_MONTH
FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS
ORDER BY CAMPAIGN_ID;


-- -----------------------------------------------------------------------------
-- 3. FCT_DAILY_SPEND: one row per campaign per active day (the delivery fact)
--    What: impressions, clicks and spend per campaign x day, with the activity month, the
--      campaign's channel and objective, and the campaign budget spread over its window days.
--    Why the join is safe: each spend row looks up its ONE campaign row in DIM_CAMPAIGN (n:1).
--      The row count stays 11,240 and no measure is repeated. The LEFT JOIN keeps a spend row
--      even if its campaign were missing (CHANNEL would then be NULL and the tests fail), so
--      spend can never disappear here.
--    Why BUDGET_PRORATED instead of BUDGET: budget is one amount for the whole window. Repeated
--      on every daily row, SUM(BUDGET) would count each campaign budget once per window day,
--      the grain trap again. BUDGET / CAMPAIGN_DAYS spreads it evenly over the window days, so
--      SUM(BUDGET_PRORATED) by month or year gives the budget planned for that period; 23
--      campaigns cross a year boundary, so a plain campaign budget cannot be put into one year.
--      It works because every window day has exactly one spend row (CAMPAIGN_DAYS = spend rows
--      per campaign, 02_data_cleaning_tests.sql block 11).
--    Rounding: BUDGET is cast to NUMBER(32,18) before the division (header, "Rounding"), so
--      the 6-dp share is rounded once from the exact quotient. The error is at most 0.0000005
--      per row and CAMPAIGN_DAYS x 0.0000005 <= 150 x 0.0000005 = 0.000075 per campaign (the
--      largest today is 0.000067), so each campaign sums back to its budget within 0.01.
--    Not a utilisation base: an even spread is an assumption (a planned daily budget), not
--      observed pacing. SPEND / BUDGET_PRORATED below whole campaigns measures pacing against
--      that assumption: by campaign x month it exceeds 1 in 4 of 490 campaign-months (up to
--      1.1294) although no campaign is over budget (largest utilisation 0.986811). Budget
--      utilisation is computed only at campaign grain (architecture decision 9;
--      MART_CAMPAIGN_PERFORMANCE.BUDGET_UTILIZATION).
--    Expected: 11,240 rows, unique on (CAMPAIGN_ID, SPEND_DATE); SUM(SPEND) 4,523,050.02.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.FCT_DAILY_SPEND
  COMMENT = 'Delivery fact. Grain: one row per campaign per active day = SPEND_ID (11,240 rows), unique on (CAMPAIGN_ID, SPEND_DATE). Source: STAGING.STG_DAILY_SPEND + DIM_CAMPAIGN (n:1). Additive: IMPRESSIONS, CLICKS, SPEND, BUDGET_PRORATED (= BUDGET / CAMPAIGN_DAYS, rounded once to 6 dp; a planned budget, not a utilisation base below whole campaigns). Ratios must be SUM / SUM. Built by sql/02b_core_models.sql.'
AS
SELECT s.SPEND_ID,
       s.CAMPAIGN_ID,
       s.SPEND_DATE,
       DATE_TRUNC('month', s.SPEND_DATE)                     AS SPEND_MONTH,       -- activity month
       c.CHANNEL,                                                                  -- n:1 from DIM_CAMPAIGN
       c.OBJECTIVE,
       s.IMPRESSIONS,
       s.CLICKS,
       s.SPEND,
       -- never the raw BUDGET on a daily row; the 18-dp dividend makes ROUND the only rounding (header, "Rounding")
       ROUND(c.BUDGET::NUMBER(32,18) / NULLIF(c.CAMPAIGN_DAYS, 0), 6)::NUMBER(18,6) AS BUDGET_PRORATED
FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND s
LEFT JOIN MARKETING_CRM.MART.DIM_CAMPAIGN c
       ON c.CAMPAIGN_ID = s.CAMPAIGN_ID      -- many spend rows -> one campaign: no fan-out
ORDER BY s.SPEND_DATE, s.CAMPAIGN_ID;


-- -----------------------------------------------------------------------------
-- 4. FCT_LEAD_CONVERSIONS: one row per lead (the lead-cohort fact)
--    What: every lead with its campaign attributes, its score segment and, if it converted,
--      its conversion (date, month, type, revenue, lag), plus the maturity flag.
--    Why the joins are safe:
--      - leads -> conversions is LEFT JOIN on LEAD_ID. LEAD_ID is unique in STG_CONVERSIONS
--        (one conversion per lead, tested in STAGING), so a lead matches 0 or 1 conversion
--        rows: 261,684 leads in, 261,684 rows out. 221,988 leads never convert, so an INNER
--        JOIN would drop 85% of the denominator of every conversion rate.
--      - leads -> DIM_CAMPAIGN is n:1, as in block 3.
--    Why a lead-cohort fact: 34% of conversions land in a later calendar month than their
--      lead. Dividing "conversions this month" by "leads this month" swings from 8% to 94%,
--      while the cohort rate stays between 14% and 17% (architecture decision 7). This table
--      carries both months: CREATED_MONTH for cohort KPIs (conversions of the leads created in
--      the month) and CONVERTED_MONTH for activity counts. They must never share one date
--      axis in a chart.
--    Column rules:
--      - LEAD_SCORE_SEGMENT uses the plan's analytical bands Low 1-40 / Medium 41-70 /
--        High 71-100. A missing or out-of-range score stays NULL instead of being guessed into
--        a band (STAGING guarantees 1..100 today).
--      - IS_CONVERTED / IS_TRIAL / IS_PURCHASE are 0/1 integers, so they SUM.
--      - REVENUE is COALESCE(revenue, 0): 0.00 for trials and unconverted leads, so SUM and
--        AVG (revenue per lead) need no NULL handling downstream.
--      - DAYS_TO_CONVERT = DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) is NULL for an
--        unconverted lead, so AVG(DAYS_TO_CONVERT) is the mean lag of converted leads only.
--      - CONVERTED_AFTER_CAMPAIGN_END flags the 4,716 conversions that land after the
--        campaign's END_DATE: a filter on the campaign window would drop them.
--      - AS_OF_DATE and IS_MATURE: see "Assumptions" in the header. The 21-day window is the
--        observed maximum lag (0..21 days).
--    Expected: 261,684 rows; SUM(IS_CONVERTED) 39,696; SUM(REVENUE) 21,561,839.01.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  COMMENT = 'Lead-cohort fact. Grain: one row per LEAD_ID (261,684 rows). Source: STAGING.STG_LEADS LEFT JOIN STG_CONVERSIONS (1:0..1 on LEAD_ID) + DIM_CAMPAIGN (n:1). Cohort KPIs group by CREATED_MONTH; CONVERTED_MONTH is the activity month; never mix the two on one axis. Flags are 0/1 so they SUM; REVENUE is 0.00 when not converted. AS_OF_DATE 2025-12-31 is an assumption. Built by sql/02b_core_models.sql.'
AS
WITH leads AS (              -- one row per lead
  SELECT LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE
  FROM MARKETING_CRM.STAGING.STG_LEADS
),
conversions AS (            -- one row per converted lead: LEAD_ID is unique here
  SELECT CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS
),
campaigns AS (              -- one row per campaign
  SELECT CAMPAIGN_ID, CHANNEL, OBJECTIVE, END_DATE
  FROM MARKETING_CRM.MART.DIM_CAMPAIGN
),
params AS (                 -- the documented maturity assumption, in one place
  SELECT '2025-12-31'::DATE AS AS_OF_DATE, 21 AS MATURITY_DAYS
)
SELECT l.LEAD_ID,
       l.CAMPAIGN_ID,
       c.CHANNEL,
       c.OBJECTIVE,
       l.CREATED_DATE,
       DATE_TRUNC('month', l.CREATED_DATE)                                AS CREATED_MONTH,     -- cohort month
       l.LEAD_SOURCE,
       l.LEAD_SCORE,
       CASE WHEN l.LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
            WHEN l.LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
            WHEN l.LEAD_SCORE BETWEEN 71 AND 100 THEN 'High'
       END::VARCHAR                                                       AS LEAD_SCORE_SEGMENT, -- no band is guessed for NULL
       v.CONVERSION_ID,                                                                         -- NULL when not converted
       v.CONVERTED_DATE,
       DATE_TRUNC('month', v.CONVERTED_DATE)                              AS CONVERTED_MONTH,   -- activity month
       v.CONVERSION_TYPE,
       IFF(v.LEAD_ID IS NOT NULL, 1, 0)::NUMBER(1,0)                      AS IS_CONVERTED,      -- the LEFT JOIN found a row
       IFF(v.CONVERSION_TYPE = 'trial', 1, 0)::NUMBER(1,0)                AS IS_TRIAL,
       IFF(v.CONVERSION_TYPE = 'purchase', 1, 0)::NUMBER(1,0)             AS IS_PURCHASE,
       COALESCE(v.REVENUE, 0)::NUMBER(12,2)                               AS REVENUE,           -- 0.00, not NULL, so it sums
       DATEDIFF('day', l.CREATED_DATE, v.CONVERTED_DATE)::NUMBER(38,0)    AS DAYS_TO_CONVERT,   -- NULL when not converted
       IFF(v.CONVERTED_DATE > c.END_DATE, 1, 0)::NUMBER(1,0)              AS CONVERTED_AFTER_CAMPAIGN_END,
       p.AS_OF_DATE,
       IFF(l.CREATED_DATE <= DATEADD('day', -p.MATURITY_DAYS, p.AS_OF_DATE), 1, 0)::NUMBER(1,0) AS IS_MATURE
FROM leads l
LEFT JOIN conversions v ON v.LEAD_ID = l.LEAD_ID           -- 1:0..1, keeps the 221,988 unconverted leads
LEFT JOIN campaigns   c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID   -- n:1
CROSS JOIN params     p                                    -- one row
ORDER BY l.CREATED_DATE, l.LEAD_ID;


-- -----------------------------------------------------------------------------
-- 5. MART_CAMPAIGN_PERFORMANCE: one row per campaign, every funnel base and the campaign KPIs
--    This is the plan's grain-safe pattern, step by step:
--      STEP 1  Aggregate each fact ON ITS OWN to one row per campaign:
--                1a spend_by_campaign        STG_DAILY_SPEND  (campaign x day)   -> campaign
--                1b leads_by_campaign        STG_LEADS        (lead)             -> campaign
--                1c conversions_by_campaign  STG_CONVERSIONS  (converted lead)   -> campaign,
--                   via the lead's campaign: conversions JOIN leads ON LEAD_ID is 1:1
--                   (LEAD_ID is unique on both sides), so it adds the campaign without
--                   repeating a conversion.
--      STEP 2  Join the three campaign-grain results to DIM_CAMPAIGN. Every input now has
--              exactly one row per CAMPAIGN_ID, so every join is 1:1: spend cannot be counted
--              twice, and a campaign without leads would get LEADS 0 (COALESCE), not lose its
--              spend.
--      STEP 3  Compute the ratios from the campaign sums, with NULLIF(denominator, 0). Each
--              dividend is cast to NUMBER(32,18) first, so ROUND is the only rounding (header,
--              "Rounding"). It matters for the money ratios: SPEND / LEADS would otherwise be
--              rounded to 8 dp and then to 4 dp. A COUNT / COUNT rate would be rounded once
--              anyway; it gets the same cast so that one rule covers every ratio.
--    The anti-pattern this replaces: FROM daily_spend JOIN leads ON campaign_id, then SUM(spend)
--      = 11,286,380,144.15 instead of 4,523,050.02 (2,495x).
--    Date columns: START_DATE, END_DATE, START_YEAR and START_MONTH are campaign attributes,
--      not activity dates. A Data Studio date-range control, a year filter or a time axis on
--      them puts a whole campaign (its spend, leads and revenue) at its start: spend by
--      START_YEAR is 1,670,021.84 / 2,053,734.61 / 799,293.57 for 2023 / 2024 / 2025, but by
--      activity date (FCT_DAILY_SPEND.SPEND_DATE) it is 1,458,262.41 / 1,971,198.34 /
--      1,093,589.27, because 23 campaigns cross a year boundary. So this table is for campaign
--      rankings and channel roll-ups over the fixed full range, without a date-range
--      dimension. Time series come from FCT_DAILY_SPEND.SPEND_MONTH and FCT_LEAD_CONVERSIONS
--      (and the Phase 4 monthly mart).
--    KPI definitions (campaign grain; rates and ROAS at 6 dp, cost per unit at 4 dp):
--      CTR                  CLICKS / IMPRESSIONS
--      CLICK_TO_LEAD_RATE   LEADS / CLICKS
--      LEAD_CONVERSION_RATE CONVERTED_LEADS / LEADS        (trial or purchase)
--      PURCHASE_RATE        PURCHASES / LEADS
--      COST_PER_LEAD        SPEND / LEADS
--      COST_PER_CONVERSION  SPEND / CONVERTED_LEADS
--      COST_PER_PURCHASE    SPEND / PURCHASES
--      ROAS                 REVENUE / SPEND                (last-touch attributed revenue)
--      BUDGET_UTILIZATION   SPEND / BUDGET
--    The ratio columns are valid only at campaign grain. Data Studio must compute any
--    aggregated ratio as SUM(numerator) / SUM(denominator) from the base columns next to them.
--    Expected: 120 rows that reproduce the Phase 2 campaign baseline [P3] for every base
--      column; SUM(SPEND) 4,523,050.02, SUM(REVENUE) 21,561,839.01.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MARKETING_CRM.MART.MART_CAMPAIGN_PERFORMANCE
  COMMENT = 'Campaign KPI table. Grain: one row per CAMPAIGN_ID (120 rows). Spend (STG_DAILY_SPEND), leads (STG_LEADS) and conversions (STG_CONVERSIONS via their lead) are each aggregated to the campaign FIRST, then joined 1:1 to DIM_CAMPAIGN, so nothing is double counted. Ratio columns are valid only at campaign grain; aggregate with SUM(numerator) / SUM(denominator) of the base columns. The date columns (START_*, END_DATE) are campaign attributes, not activity dates: a date-range control, year filter or time axis on them puts a whole campaign at its start. Use this table without a date-range dimension (fixed full range); time series come from FCT_DAILY_SPEND and FCT_LEAD_CONVERSIONS. Built by sql/02b_core_models.sql.'
AS
WITH spend_by_campaign AS (          -- STEP 1a: campaign x day -> one row per campaign
  SELECT CAMPAIGN_ID,
         COUNT(*)         AS SPEND_DAYS,
         SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS)      AS CLICKS,
         SUM(SPEND)       AS SPEND
  FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND
  GROUP BY CAMPAIGN_ID
),
leads_by_campaign AS (              -- STEP 1b: lead -> one row per campaign
  SELECT CAMPAIGN_ID,
         COUNT(*) AS LEADS
  FROM MARKETING_CRM.STAGING.STG_LEADS
  GROUP BY CAMPAIGN_ID
),
conversions_by_campaign AS (        -- STEP 1c: converted lead -> one row per campaign (the lead join is 1:1)
  SELECT l.CAMPAIGN_ID,
         COUNT(*)                                  AS CONVERTED_LEADS,
         COUNT_IF(v.CONVERSION_TYPE = 'trial')     AS TRIALS,
         COUNT_IF(v.CONVERSION_TYPE = 'purchase')  AS PURCHASES,
         SUM(v.REVENUE)                            AS REVENUE
  FROM MARKETING_CRM.STAGING.STG_CONVERSIONS v
  JOIN MARKETING_CRM.STAGING.STG_LEADS l ON l.LEAD_ID = v.LEAD_ID   -- 1:1: only adds the campaign
  GROUP BY l.CAMPAIGN_ID
),
campaign_grain AS (                 -- STEP 2: every input has one row per campaign now -> 1:1 joins
  SELECT d.CAMPAIGN_ID, d.CAMPAIGN_NAME, d.CHANNEL, d.OBJECTIVE, d.START_DATE, d.END_DATE,
         d.CAMPAIGN_DAYS, d.START_YEAR, d.START_MONTH, d.BUDGET,
         COALESCE(s.SPEND_DAYS, 0)::NUMBER(38,0)      AS SPEND_DAYS,
         COALESCE(s.IMPRESSIONS, 0)::NUMBER(38,0)     AS IMPRESSIONS,
         COALESCE(s.CLICKS, 0)::NUMBER(38,0)          AS CLICKS,
         COALESCE(s.SPEND, 0)::NUMBER(18,2)           AS SPEND,
         COALESCE(l.LEADS, 0)::NUMBER(38,0)           AS LEADS,
         COALESCE(v.CONVERTED_LEADS, 0)::NUMBER(38,0) AS CONVERTED_LEADS,
         COALESCE(v.TRIALS, 0)::NUMBER(38,0)          AS TRIALS,
         COALESCE(v.PURCHASES, 0)::NUMBER(38,0)       AS PURCHASES,
         COALESCE(v.REVENUE, 0)::NUMBER(18,2)         AS REVENUE
  FROM MARKETING_CRM.MART.DIM_CAMPAIGN d
  LEFT JOIN spend_by_campaign       s ON s.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
  LEFT JOIN leads_by_campaign       l ON l.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
  LEFT JOIN conversions_by_campaign v ON v.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
)
SELECT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, CAMPAIGN_DAYS,
       START_YEAR, START_MONTH,
       BUDGET, SPEND_DAYS, IMPRESSIONS, CLICKS, SPEND, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE,
       -- STEP 3: campaign-grain ratios of the sums above; NULL (not an error) when a denominator is 0.
       --         The 18-dp dividend makes ROUND the only rounding (header, "Rounding").
       ROUND(CLICKS::NUMBER(32,18)          / NULLIF(IMPRESSIONS, 0),     6)::NUMBER(18,6) AS CTR,
       ROUND(LEADS::NUMBER(32,18)           / NULLIF(CLICKS, 0),          6)::NUMBER(18,6) AS CLICK_TO_LEAD_RATE,
       ROUND(CONVERTED_LEADS::NUMBER(32,18) / NULLIF(LEADS, 0),           6)::NUMBER(18,6) AS LEAD_CONVERSION_RATE,
       ROUND(PURCHASES::NUMBER(32,18)       / NULLIF(LEADS, 0),           6)::NUMBER(18,6) AS PURCHASE_RATE,
       ROUND(SPEND::NUMBER(32,18)           / NULLIF(LEADS, 0),           4)::NUMBER(18,4) AS COST_PER_LEAD,
       ROUND(SPEND::NUMBER(32,18)           / NULLIF(CONVERTED_LEADS, 0), 4)::NUMBER(18,4) AS COST_PER_CONVERSION,
       ROUND(SPEND::NUMBER(32,18)           / NULLIF(PURCHASES, 0),       4)::NUMBER(18,4) AS COST_PER_PURCHASE,
       ROUND(REVENUE::NUMBER(32,18)         / NULLIF(SPEND, 0),           6)::NUMBER(18,6) AS ROAS,
       ROUND(SPEND::NUMBER(32,18)           / NULLIF(BUDGET, 0),          6)::NUMBER(18,6) AS BUDGET_UTILIZATION
FROM campaign_grain
ORDER BY CAMPAIGN_ID;


-- -----------------------------------------------------------------------------
-- 6-10. Column comments: meaning, grain role and KPI formula of every column
--    Why: the comments travel with the tables into Snowsight, INFORMATION_SCHEMA and the dbt
--      docs (Phase 5), so a dashboard author sees which columns are additive and how each
--      ratio must be aggregated. One ALTER TABLE per table; the test file checks that no
--      column is left without a comment.
-- -----------------------------------------------------------------------------
ALTER TABLE MARKETING_CRM.MART.DIM_DATE MODIFY
  COLUMN DATE_DAY        COMMENT 'Calendar day (PK). Gap-free 2023-01-01..2025-12-31, the documented dataset coverage. Join key for SPEND_DATE, CREATED_DATE, CONVERTED_DATE.',
  COLUMN YEAR            COMMENT 'Calendar year of DATE_DAY.',
  COLUMN QUARTER         COMMENT 'Calendar quarter of DATE_DAY, 1-4.',
  COLUMN MONTH_START     COMMENT 'First day of the month of DATE_DAY. Join key for the month columns SPEND_MONTH, CREATED_MONTH, CONVERTED_MONTH.',
  COLUMN MONTH_NAME      COMMENT 'Full English month name, e.g. January.',
  COLUMN WEEK_START      COMMENT 'Monday of the ISO week of DATE_DAY (from DAYOFWEEKISO, independent of the WEEK_START session parameter). The first week starts 2022-12-26, before the spine.',
  COLUMN DAY_OF_WEEK_ISO COMMENT 'ISO day of week: 1 = Monday ... 7 = Sunday.',
  COLUMN DAY_NAME        COMMENT 'Full English day name, e.g. Monday.',
  COLUMN IS_WEEKEND      COMMENT 'TRUE on Saturday and Sunday (DAY_OF_WEEK_ISO 6 or 7). A filter attribute, not a measure.';

ALTER TABLE MARKETING_CRM.MART.DIM_CAMPAIGN MODIFY
  COLUMN CAMPAIGN_ID     COMMENT 'Campaign key (PK), e.g. CMP0001.',
  COLUMN CAMPAIGN_NAME   COMMENT 'Campaign name, unique (alternate key), e.g. Paid Search 2023 001.',
  COLUMN CHANNEL         COMMENT 'Marketing channel: affiliate, display, paid_search, paid_social, video. The canonical channel dimension of every MART table (leads.lead_source only duplicates it).',
  COLUMN OBJECTIVE       COMMENT 'Campaign objective: acquisition, awareness, lead_gen. Partly confounded with channel (display is 17 of 24 lead_gen), so compare objectives within a channel.',
  COLUMN START_DATE      COMMENT 'First day of the campaign window.',
  COLUMN END_DATE        COMMENT 'Last day of the campaign window. Conversions of its leads can land up to 21 days later.',
  COLUMN CAMPAIGN_DAYS   COMMENT 'Window length in days, END_DATE - START_DATE + 1; equals the number of spend rows of the campaign.',
  COLUMN BUDGET          COMMENT 'Budget for the whole campaign window. Additive across campaigns, not across dates: for budget totals by month or year use FCT_DAILY_SPEND.BUDGET_PRORATED.',
  COLUMN START_YEAR      COMMENT 'Year of START_DATE (campaigns can run into the next year).',
  COLUMN START_MONTH     COMMENT 'First day of the month of START_DATE.';

ALTER TABLE MARKETING_CRM.MART.FCT_DAILY_SPEND MODIFY
  COLUMN SPEND_ID        COMMENT 'Spend row key (PK). One row per campaign per active day; (CAMPAIGN_ID, SPEND_DATE) is unique.',
  COLUMN CAMPAIGN_ID     COMMENT 'Campaign (FK to DIM_CAMPAIGN).',
  COLUMN SPEND_DATE      COMMENT 'Activity date (FK to DIM_DATE.DATE_DAY).',
  COLUMN SPEND_MONTH     COMMENT 'Activity month: first day of the month of SPEND_DATE.',
  COLUMN CHANNEL         COMMENT 'Channel of the campaign, copied from DIM_CAMPAIGN (many rows to one campaign: no fan-out).',
  COLUMN OBJECTIVE       COMMENT 'Objective of the campaign, copied from DIM_CAMPAIGN.',
  COLUMN IMPRESSIONS     COMMENT 'Impressions delivered on the day. Additive.',
  COLUMN CLICKS          COMMENT 'Clicks on the day. Additive. CTR = SUM(CLICKS) / SUM(IMPRESSIONS).',
  COLUMN SPEND           COMMENT 'Media spend on the day. Additive; total 4,523,050.02. CPC = SUM(SPEND) / SUM(CLICKS).',
  COLUMN BUDGET_PRORATED COMMENT 'Campaign BUDGET / CAMPAIGN_DAYS, rounded once to 6 dp: the budget spread evenly over the window days. For budget totals by month or year only; sums back to each campaign budget within 0.01. An even spread is an assumption, not observed pacing: do not report SPEND / BUDGET_PRORATED below whole campaigns as budget utilisation (by campaign x month it exceeds 1 although no campaign overspends). Use MART_CAMPAIGN_PERFORMANCE.BUDGET_UTILIZATION, or SUM(SPEND) / SUM(BUDGET) over whole campaigns.';

ALTER TABLE MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS MODIFY
  COLUMN LEAD_ID         COMMENT 'Lead key (PK). One row per lead, converted or not.',
  COLUMN CAMPAIGN_ID     COMMENT 'Campaign the lead is attributed to (FK to DIM_CAMPAIGN).',
  COLUMN CHANNEL         COMMENT 'Channel of the campaign, from DIM_CAMPAIGN. Use this, not LEAD_SOURCE.',
  COLUMN OBJECTIVE       COMMENT 'Objective of the campaign, from DIM_CAMPAIGN.',
  COLUMN CREATED_DATE    COMMENT 'Date the lead was created (FK to DIM_DATE.DATE_DAY). The first date column, so Data Studio may use it as the default date-range dimension: a date-range control then filters leads by cohort (creation date), also on a chart of CONVERTED_MONTH. To count conversions by when they happened in a date range, set the date-range dimension to CONVERTED_DATE.',
  COLUMN CREATED_MONTH   COMMENT 'Lead cohort month: first day of the month of CREATED_DATE. Cohort KPIs (conversion rate of the leads created in a month) group by this.',
  COLUMN LEAD_SOURCE     COMMENT 'Lead source as delivered by the source system; equals CHANNEL for every lead today. Kept for lineage; use CHANNEL.',
  COLUMN LEAD_SCORE      COMMENT 'Lead score 1-100. How it is produced is undocumented; it is not assumed to predict conversion.',
  COLUMN LEAD_SCORE_SEGMENT COMMENT 'Score band: Low (1-40), Medium (41-70), High (71-100).',
  COLUMN CONVERSION_ID   COMMENT 'Conversion key; NULL if the lead never converted (a lead converts at most once).',
  COLUMN CONVERTED_DATE  COMMENT 'Conversion date (FK to DIM_DATE.DATE_DAY); NULL if not converted.',
  COLUMN CONVERTED_MONTH COMMENT 'Activity month of the conversion; NULL if not converted. Never put it on one axis with CREATED_MONTH.',
  COLUMN CONVERSION_TYPE COMMENT 'trial or purchase; NULL if not converted.',
  COLUMN IS_CONVERTED    COMMENT '1 if the lead converted (trial or purchase), else 0. SUM = converted leads; SUM / COUNT(LEAD_ID) = lead conversion rate.',
  COLUMN IS_TRIAL        COMMENT '1 if the lead converted to a trial, else 0.',
  COLUMN IS_PURCHASE     COMMENT '1 if the lead converted to a purchase, else 0. SUM / COUNT(LEAD_ID) = purchase rate.',
  COLUMN REVENUE         COMMENT 'Last-touch attributed revenue; 0.00 for trials and unconverted leads, so it sums. SUM / COUNT(LEAD_ID) = revenue per lead.',
  COLUMN DAYS_TO_CONVERT COMMENT 'DATEDIFF(day, CREATED_DATE, CONVERTED_DATE), 0-21; NULL if not converted, so AVG covers converted leads only.',
  COLUMN CONVERTED_AFTER_CAMPAIGN_END COMMENT '1 if CONVERTED_DATE is after the campaign END_DATE (up to 21 days), else 0. A campaign-window filter would drop these conversions.',
  COLUMN AS_OF_DATE      COMMENT 'Assumed as-of date, 2025-12-31 (end of the documented coverage). An assumption: the data alone does not prove the youngest cohorts complete.',
  COLUMN IS_MATURE       COMMENT '1 if CREATED_DATE <= AS_OF_DATE - 21 days (the observed maximum lag), i.e. the lead has had its full conversion window; else 0.';

ALTER TABLE MARKETING_CRM.MART.MART_CAMPAIGN_PERFORMANCE MODIFY
  COLUMN CAMPAIGN_ID     COMMENT 'Campaign key (PK).',
  COLUMN CAMPAIGN_NAME   COMMENT 'Campaign name (from DIM_CAMPAIGN).',
  COLUMN CHANNEL         COMMENT 'Canonical channel (from DIM_CAMPAIGN).',
  COLUMN OBJECTIVE       COMMENT 'Campaign objective (from DIM_CAMPAIGN).',
  COLUMN START_DATE      COMMENT 'First day of the campaign window. A campaign attribute, not an activity date: filtering or grouping by it puts the whole campaign at its start. Leave the date-range dimension of this table unset; for time series use FCT_DAILY_SPEND.SPEND_MONTH / FCT_LEAD_CONVERSIONS.',
  COLUMN END_DATE        COMMENT 'Last day of the campaign window. A campaign attribute, not an activity date (see START_DATE).',
  COLUMN CAMPAIGN_DAYS   COMMENT 'Window length in days, END_DATE - START_DATE + 1.',
  COLUMN START_YEAR      COMMENT 'Year of START_DATE. A campaign attribute, not an activity year: filtering by it assigns a whole campaign (spend, leads, revenue) to its start year, and 23 campaigns run into the next year. For activity by year use FCT_DAILY_SPEND.SPEND_DATE / FCT_LEAD_CONVERSIONS.',
  COLUMN START_MONTH     COMMENT 'First day of the month of START_DATE. A campaign attribute, not an activity month: a time axis on it puts a whole campaign at its start. For time series use FCT_DAILY_SPEND.SPEND_MONTH / FCT_LEAD_CONVERSIONS.',
  COLUMN BUDGET          COMMENT 'Campaign budget for the whole window. Additive across campaigns.',
  COLUMN SPEND_DAYS      COMMENT 'Number of spend rows (active days) of the campaign. Additive.',
  COLUMN IMPRESSIONS     COMMENT 'Sum of daily impressions. Additive.',
  COLUMN CLICKS          COMMENT 'Sum of daily clicks. Additive.',
  COLUMN SPEND           COMMENT 'Sum of daily spend. Additive; total 4,523,050.02.',
  COLUMN LEADS           COMMENT 'Number of leads attributed to the campaign. Additive.',
  COLUMN CONVERTED_LEADS COMMENT 'Leads that converted (trial or purchase). Additive.',
  COLUMN TRIALS          COMMENT 'Leads that converted to a trial. Additive.',
  COLUMN PURCHASES       COMMENT 'Leads that converted to a purchase. Additive.',
  COLUMN REVENUE         COMMENT 'Last-touch attributed revenue of the campaign leads. Additive; total 21,561,839.01.',
  COLUMN CTR             COMMENT 'CLICKS / IMPRESSIONS, campaign grain only (6 dp). Aggregate as SUM(CLICKS) / SUM(IMPRESSIONS).',
  COLUMN CLICK_TO_LEAD_RATE   COMMENT 'LEADS / CLICKS, campaign grain only (6 dp). Aggregate as SUM(LEADS) / SUM(CLICKS).',
  COLUMN LEAD_CONVERSION_RATE COMMENT 'CONVERTED_LEADS / LEADS, campaign grain only (6 dp). Aggregate as SUM(CONVERTED_LEADS) / SUM(LEADS).',
  COLUMN PURCHASE_RATE   COMMENT 'PURCHASES / LEADS, campaign grain only (6 dp). Aggregate as SUM(PURCHASES) / SUM(LEADS).',
  COLUMN COST_PER_LEAD   COMMENT 'SPEND / LEADS, campaign grain only (4 dp). Aggregate as SUM(SPEND) / SUM(LEADS).',
  COLUMN COST_PER_CONVERSION COMMENT 'SPEND / CONVERTED_LEADS, campaign grain only (4 dp). Aggregate as SUM(SPEND) / SUM(CONVERTED_LEADS).',
  COLUMN COST_PER_PURCHASE COMMENT 'SPEND / PURCHASES, campaign grain only (4 dp). Aggregate as SUM(SPEND) / SUM(PURCHASES).',
  COLUMN ROAS            COMMENT 'REVENUE / SPEND (attributed, not causal), campaign grain only (6 dp). Aggregate as SUM(REVENUE) / SUM(SPEND).',
  COLUMN BUDGET_UTILIZATION COMMENT 'SPEND / BUDGET, campaign grain only (6 dp). Aggregate as SUM(SPEND) / SUM(BUDGET) over whole campaigns only.';


-- -----------------------------------------------------------------------------
-- 11. Build summary (descriptive; every check is in 02b_core_models_tests.sql)
--    One row per MART table: type, rows and bytes (table metadata, no scan), columns, and
--    columns with a comment. Expected: DIM_DATE 1,096, DIM_CAMPAIGN 120, FCT_DAILY_SPEND
--    11,240, FCT_LEAD_CONVERSIONS 261,684, MART_CAMPAIGN_PERFORMANCE 120 rows, every column
--    commented; CONNECTION_TEST (Phase 1, 159 rows) unchanged.
-- -----------------------------------------------------------------------------
SELECT t.TABLE_NAME, t.TABLE_TYPE, t.ROW_COUNT, t.BYTES, COUNT(c.COLUMN_NAME) AS N_COLUMNS,
       COUNT(c.COMMENT) AS COLUMNS_WITH_COMMENT, t.TABLE_OWNER, t.CREATED
FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES t
LEFT JOIN MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS c
       ON c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = 'MART'
GROUP BY t.TABLE_NAME, t.TABLE_TYPE, t.ROW_COUNT, t.BYTES, t.TABLE_OWNER, t.CREATED
ORDER BY DECODE(t.TABLE_NAME, 'DIM_DATE', 1, 'DIM_CAMPAIGN', 2, 'FCT_DAILY_SPEND', 3, 'FCT_LEAD_CONVERSIONS', 4,
                'MART_CAMPAIGN_PERFORMANCE', 5, 6), t.TABLE_NAME;
