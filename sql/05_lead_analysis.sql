-- =============================================================================
-- Phase 4 / 05: lead quality and lead conversion time (Dashboard 3 "Lead Quality & CRM")
-- -----------------------------------------------------------------------------
-- Purpose
--   Answer business questions 4 and 5 with read-only Snowflake SQL, and produce the tables that
--   the Lead Quality & CRM dashboard page is built from:
--     BQ4  How does the conversion rate change with lead score, and does any channel deliver
--          higher-scored leads?                          plan analysis #6, blocks 1, 2, 3 and 5
--     BQ5  How long does it take a lead to convert?      plan analysis #7, block 4
--   Blocks and the SQL technique each one showcases
--     1  Lead score segments          CASE WHEN, GROUP BY ROLLUP, Wilson 95% interval, chi-square
--                                     test of independence with window sums (SUM() OVER PARTITION BY)
--     2  Score quantiles              NTILE(4) / NTILE(10) with a deterministic tie-breaker, LAG / LEAD
--                                     for tile-to-tile steps, REGR_SLOPE / REGR_R2 / CORR, MIN_BY / MAX_BY
--     3  Channel lead quality         PERCENTILE_CONT, GROUP BY CUBE + PIVOT, score-mix standardisation,
--                                     chi-square tests across channels
--     4  Conversion time              DATEDIFF, AVG, PERCENTILE_CONT, GROUPING SETS, a GENERATOR day
--                                     spine, running total SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING)
--     5  Campaign ranking             ROW_NUMBER, RANK, PERCENT_RANK, RANK() OVER (PARTITION BY),
--                                     QUALIFY, NTILE over campaigns
-- Results of the last run (2026-10-14; each number is a row of docs/evidence/05_lead.txt)
--   BQ4  Conversion rate rises with the score: Low (1-40) 9.12%, Medium (41-70) 16.18%, High
--        (71-100) 22.19% of leads converted (Wilson 95%: 8.94-9.29%, 15.92-16.44%, 21.90-22.48%),
--        2.43x Low. Chi-square 6,035.02 on 2 df (critical 5.991, p about 10^-1310); Cramer's V
--        0.152, a small effect for a single lead (rule of thumb: 0.1 small, 0.3 medium; lead-level
--        correlation 0.161): the segments differ clearly, yet most leads of every segment never
--        convert.
--        Deciles rise in 9 of 9 steps (6.25% -> 23.99%), about +2.0 points of conversion rate per
--        10 score points (REGR_SLOPE over the 100 scores, R^2 0.986); single scores are noisy
--        (42 of 99 score-to-score steps go down). Revenue per lead follows the purchase rate
--        (48.69 / 87.60 / 121.89); revenue per purchase is almost flat (1,280 / 1,292 / 1,298).
--        No channel delivers higher-scored leads: mean score 50.47-50.66, High share 29.93-30.16%,
--        chi-square 7.00 on 8 df (p 0.537). Within each segment no channel converts detectably
--        differently (spread 0.43-0.74 points, p 0.44-0.52). Channel conversion rates are within
--        1.5% of what their (practically identical) score mixes predict (observed / mix-expected
--        0.985-1.010), which is also within 1.5% of the all-lead rate (0.985-1.012): neither
--        score mix nor channel accounts for a meaningful difference between channels.
--   BQ5  Conversion takes 0-21 days: median 10, p25 5, p75 16, p90 19, mean 10.51. 36.2% of
--        conversions happen within 7 days, half by day 10, 90% by day 19. The daily counts are
--        consistent with a flat lag over days 0-21 (chi-square vs uniform 13.98 on 21 df,
--        critical 32.671), and the lag shows no detectable difference by conversion type,
--        channel or score segment (means 10.38-10.61, within 0.23 days; one-way ANOVA F 0.0068 /
--        0.6944 / 1.6899, all below their 5% critical values, p 0.93 / 0.60 / 0.18).
--        4,716 conversions (11.88%; 2,532,266.74 of revenue, 11.74%) happen after the campaign
--        ended.
--   Campaigns: High share ranges 25.38% (CMP0039) to 33.83% (CMP0018); the extremes are small
--        campaigns, 9 of 120 Wilson intervals exclude the all-lead 30.03% (about 6 expected by
--        chance). Across the 120 campaigns, High share and conversion rate correlate at -0.072
--        (95% noise band about +/-0.18). The score mix alone would imply only about +0.15, so
--        the campaign view is too noisy to confirm or refute the lead-level association of 1a
--        (5c; between the top and bottom High-share quartiles of campaigns the score mix
--        predicts only a 0.27-point gap, under two standard errors of 0.21 points, 5b).
--   What this does NOT show: how the score is produced is undocumented, and the data is
--   synthetic. Everything here is association within this dataset; it is not evidence that the
--   score predicts conversion elsewhere, or that raising a lead's score would raise its chance
--   to convert.
-- Analytical guard rails (the user plan), as they apply here
--   G1 Grain. Every rate is computed from FCT_LEAD_CONVERSIONS (one row per lead) or from marts
--      that aggregate it. No fact is joined to another fact. Block 5 aggregates leads to one row
--      per campaign before ranking; block 4 joins the lead fact to DIM_CAMPAIGN (n:1) only to
--      read END_DATE.
--   G2 Aggregate funnel. A lead converts at most once, to a trial OR a purchase: trials and
--      purchases are parallel outcomes, not stages. PURCHASE_RATE = purchases / leads, never
--      purchases / trials; nothing here follows a trial to a purchase.
--   G3 Lead-cohort basis only. Every rate is "of the leads in this group, how many converted,
--      ever (within the observed 0-21 days)". No month axis is used, so activity and cohort
--      series cannot be mixed. All 261,684 leads are mature at the assumed as-of date
--      2025-12-31 (block 4d), so, under that assumption, no rate is understated by
--      right-censoring. On the observed data alone (the last conversion is on 2025-12-21), the
--      65 leads created 2025-12-01/02 have not had their full 21 days; 54 of them have not
--      converted, so the all-lead rate could be understated by at most 54 / 261,684 = 0.021
--      points (4d).
--   G4 Revenue is last-touch attributed revenue (REVENUE of the conversion row). Revenue per lead
--      or per purchase describes attribution, not the causal value of a lead.
--   G5 Lead score: association only. How the score is produced is undocumented; nothing here
--      validates it as a predictor, and "conversion rises with the score" is not "the score
--      causes conversion". The chi-square tests measure sampling noise only, assuming
--      independent leads.
--   G6 Synthetic data. Regular patterns are generator artefacts, not market facts: the score is
--      near-uniform on 1-100 (2,508-2,728 leads per score), the conversion rate is almost a
--      straight line in the score (R^2 0.986), the daily lag counts are consistent with a
--      uniform 0-21 days, and channels show no detectable difference in score mix or in
--      conversion within a segment.
--   G7 Volume by active campaigns. Not applicable: no figure here is a volume over time.
-- Read-only
--   Only USE and SELECT / WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02c_analysis_marts.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 300 sql/05_lead_analysis.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 19 statements,
--   well under a minute on the X-Small MARKETING_WH (every query reads at most the 261,684-row
--   lead fact). Output of the last run: docs/evidence/05_lead.txt.
-- Role
--   CRM_TRANSFORMER, which owns and reads the MART tables. Every table read here is in MART.
-- Reading the results
--   Analysis tables carry a STATUS column: PASS means every checked value of the row equals the
--   expected value exactly (rates and shares 6 dp, money and lifts 4 dp, test statistics 4 dp).
--   Summary blocks (2b, 4d, 5c) are check lists: CHECK_NAME, ACTUAL, EXPECTED, STATUS.
--   - Expected lists are FULL OUTER JOINed, so a missing or an unexpected group is its own FAIL.
--   - No result is compared with itself. Expected values come from the sources below. Where a
--     result is compared with a MART table, it is a different path: the analysis recomputes
--     from FCT_LEAD_CONVERSIONS with its own CASE WHEN, the dashboard marts were built in 02c
--     (MART_LEAD_QUALITY from 10-point bands, MART_CHANNEL_PERFORMANCE from channel sums).
--   - Rounding: rates divide a dividend cast to NUMBER(32,18), so ROUND is the only rounding
--     (the NUMBER(p,2) / NUMBER gotcha rounds to 8 dp first). Wilson bounds, chi-square and F
--     statistics, p-values, correlations, standard deviations, the regression slope and
--     observed / expected ratios need SQRT, LN, POWER or statistical aggregates and are
--     computed in FLOAT, then rounded once. Every such value lies at least 6 x 10^-9 from a
--     rounding midpoint in the exact 60-digit Python computation [D5], far beyond
--     double-precision error. AVG returns NUMBER(19,6), so
--     ROUND(AVG(..), 4) rounds twice; every mean lag lies at least 3.3 x 10^-6 from a 4-dp
--     midpoint, so the 6-dp intermediate cannot change the 4th decimal (block 4a).
--   (Check lists put mixed measures in one NUMBER(38,6) column, so counts print as 120.000000.)
-- Where the expected values come from (never from the query under check)
--   [K]   Known totals, Phase 3 tests (docs/evidence/02b_core_models_tests.txt): 261,684 leads,
--         39,696 converted leads (23,005 trials, 16,691 purchases), revenue 21,561,839.01.
--   [P3]  The local pre-load profile "KPI reconciliation" (2026-10-13), section
--         lead_score_segments: leads, converted leads, purchases, revenue and conversion rate of
--         Low / Medium / High (carried inline in 02b_core_models_tests.sql block 11).
--   [E01] docs/evidence/01_data_profiling.txt (Phase 2, RAW): [18] leads per 10-point band,
--         [24] the 4,716 conversions after their campaign ended, [25] lag percentiles and means
--         by conversion type and channel, [26] the last conversion date 2025-12-21 and the 65
--         leads whose 21-day window passes it.
--   [D]   02c_analysis_marts_tests.sql [D]: converted leads and conversion rate per 10-point band.
--   [D5]  Python 3 csv + decimal + fractions (60-digit precision, ROUND_HALF_UP), 2026-10-14,
--         outside Snowflake, from data/raw/source/campaigns.csv, leads.csv and conversions.csv:
--         segment trials, purchase rates, revenue per lead / purchase and Wilson bounds; the
--         chi-square statistics, p-values and Cramer's V (exact rational arithmetic); NTILE
--         quartiles and deciles (sorted by score, then LEAD_ID; earlier tiles take the extra
--         row); per-score steps, regression slope and R^2, lead-level correlation; channel score
--         distribution, Wilson bounds, mix-expected rates, segment x channel rates; lag by score
--         segment, share within 7 / 14 days, the one-way ANOVA F of the lag by type, channel and
--         segment (exact rational arithmetic), the day-by-day curve, the uniformity test,
--         after-end buckets, the 54 unconverted leads of the 65; campaign High shares, ranks,
--         Wilson bounds, quartiles, mix-expected rates and summary statistics. Where noted,
--         p-values and F critical values come from scipy.stats, and the 5c noise ranges from
--         numpy: 20,000 shuffles of campaign conversion rates, and 20,000 binomial draws of
--         every campaign's conversions at its segments' all-lead rates (seed 20261014).
--   [T]   Chi-square critical values at 5% from a standard table, each re-derived in [D5] (upper
--         tail 0.0500 at the 3-dp value): df 2 5.991, df 4 9.488, df 8 15.507, df 21 32.671,
--         df 119 145.461. For even df the p-value has a closed form, used in SQL:
--         P(X2 > x) = EXP(-x/2) x SUM_{i < df/2} (x/2)^i / i!.
--         F critical values at 5% (a table's df2 = infinity row: 3.84, 3.00, 2.37), computed to
--         3 dp in [D5] for the actual df: F(1, 39694) 3.842, F(2, 39693) 2.996, F(4, 39691) 2.372.
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where
--   [6] 1a segment scorecard   [7] 1b chi-square across segments
--   [8] 2a quartiles, deciles, bands   [9] 2b single scores and the trend
--   [10] 3a channel score profile   [11] 3b segment x channel conversion   [12] 3c chi-square across channels
--   [13] 4a lag distribution   [14] 4b cumulative conversion curve   [15] 4c after campaign end
--   [16] 4d timing summary
--   [17] 5a campaign ranking   [18] 5b campaign quartiles   [19] 5c ranking summary
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
-- 1a. Lead score segments: the scorecard (plan analysis #6; dashboard table)
--    BUSINESS QUESTION (BQ4): how do the plan's Low / Medium / High lead score segments differ
--      in conversion, purchase and attributed revenue?
--    METHOD: CASE WHEN assigns each lead to Low (1-40), Medium (41-70) or High (71-100) from
--      LEAD_SCORE; GROUP BY ROLLUP adds the all-leads row. Rates are ratios of sums. The Wilson
--      95% interval (z = 1.959964, the formula of MART_CHANNEL_PERFORMANCE) gives the sampling
--      noise of each rate:
--        centre = (p + z^2/2n) / (1 + z^2/n),  half = z / (1 + z^2/n) x SQRT(p(1-p)/n + z^2/4n^2).
--      CONVERSION_LIFT = segment rate / all-lead rate.
--    HOW TO READ: CONVERSION_RATE = converted leads (trial or purchase) / leads. PURCHASE_RATE =
--      purchases / leads. REVENUE_PER_LEAD = attributed revenue / leads; REVENUE_PER_PURCHASE =
--      revenue / purchases (trials carry 0.00, so per purchase is the price-like measure).
--      Result: 9.12% / 16.18% / 22.19% converted (lift 0.60 / 1.07 / 1.46), intervals far
--      apart; revenue per lead 48.69 / 87.60 / 121.89 rises with the purchase rate, while revenue
--      per purchase stays near 1,280-1,298: the score goes with WHETHER a lead buys, hardly with
--      how much (all association, G5).
--    CAVEATS: segment cut-offs are the plan's, not data-driven. The interval covers sampling
--      noise only (independent leads); it says nothing about bias, attribution or the synthetic
--      generator. The dashboard page reads the same numbers from MART_LEAD_QUALITY grouped by
--      LEAD_SCORE_SEGMENT (SUM / SUM); the STATUS also requires that path to agree. The
--      intervals have no mart column (a Phase 6 decision).
--    Checks: leads, converted, purchases, revenue, conversion rate [P3]; trials, purchase rate,
--      Wilson bounds, revenue per lead / purchase [D5]; the all-leads row [K] and [D5]; score
--      ranges [plan]; 0 leads whose CASE WHEN segment differs from the Phase 3 column
--      LEAD_SCORE_SEGMENT; MART_LEAD_QUALITY gives the same leads, converted, purchases, revenue.
-- -----------------------------------------------------------------------------
WITH segmented AS (         -- one row per lead; the plan's segments derived here with CASE WHEN
  SELECT LEAD_SCORE, IS_CONVERTED, IS_TRIAL, IS_PURCHASE, REVENUE,
         LEAD_SCORE_SEGMENT AS PHASE3_SEGMENT,                          -- the Phase 3 column, cross-check only
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High'
         END AS SEGMENT                                                 -- NULL for a missing or out-of-range score
  FROM FCT_LEAD_CONVERSIONS
),
by_segment AS (             -- GROUP BY ROLLUP: one row per segment, plus the all-leads row
  SELECT IFF(GROUPING(SEGMENT) = 1, 'All leads', SEGMENT) AS SEGMENT_NAME,
         MIN(LEAD_SCORE) AS MIN_SCORE, MAX(LEAD_SCORE) AS MAX_SCORE,
         COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS, SUM(IS_TRIAL) AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES, SUM(REVENUE) AS REVENUE,
         COUNT_IF(SEGMENT IS DISTINCT FROM PHASE3_SEGMENT) AS SEGMENT_MISMATCHES
  FROM segmented
  GROUP BY ROLLUP (SEGMENT)
),
inputs AS (                 -- all-lead totals (window over the 4 rows) and the FLOAT inputs of the Wilson interval
  SELECT b.*,
         MAX(IFF(b.SEGMENT_NAME = 'All leads', b.LEADS, NULL))           OVER () AS ALL_LEADS,
         MAX(IFF(b.SEGMENT_NAME = 'All leads', b.CONVERTED_LEADS, NULL)) OVER () AS ALL_CONVERTED,
         b.LEADS::FLOAT                     AS N,
         b.CONVERTED_LEADS::FLOAT / b.LEADS AS P_CONV,
         b.PURCHASES::FLOAT / b.LEADS       AS P_PURCH,
         1.959964::FLOAT                    AS Z
  FROM by_segment b
),
scorecard AS (
  SELECT SEGMENT_NAME AS SEGMENT, MIN_SCORE, MAX_SCORE, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES,
         REVENUE::NUMBER(18,2) AS REVENUE, SEGMENT_MISMATCHES,
         ROUND(LEADS::NUMBER(32,18)           / ALL_LEADS, 6)::NUMBER(18,6)        AS LEAD_SHARE,
         ROUND(CONVERTED_LEADS::NUMBER(32,18) / LEADS, 6)::NUMBER(18,6)            AS CONVERSION_RATE,
         ROUND((P_CONV + Z * Z / (2 * N) - Z * SQRT(P_CONV * (1 - P_CONV) / N + Z * Z / (4 * N * N)))
               / (1 + Z * Z / N), 6)::NUMBER(18,6)                                  AS CR_CI_LOW,
         ROUND((P_CONV + Z * Z / (2 * N) + Z * SQRT(P_CONV * (1 - P_CONV) / N + Z * Z / (4 * N * N)))
               / (1 + Z * Z / N), 6)::NUMBER(18,6)                                  AS CR_CI_HIGH,
         ROUND(PURCHASES::NUMBER(32,18)       / LEADS, 6)::NUMBER(18,6)            AS PURCHASE_RATE,
         ROUND((P_PURCH + Z * Z / (2 * N) - Z * SQRT(P_PURCH * (1 - P_PURCH) / N + Z * Z / (4 * N * N)))
               / (1 + Z * Z / N), 6)::NUMBER(18,6)                                  AS PR_CI_LOW,
         ROUND((P_PURCH + Z * Z / (2 * N) + Z * SQRT(P_PURCH * (1 - P_PURCH) / N + Z * Z / (4 * N * N)))
               / (1 + Z * Z / N), 6)::NUMBER(18,6)                                  AS PR_CI_HIGH,
         ROUND(REVENUE::NUMBER(32,18) / LEADS, 4)::NUMBER(18,4)                    AS REVENUE_PER_LEAD,
         ROUND(REVENUE::NUMBER(32,18) / NULLIF(PURCHASES, 0), 4)::NUMBER(18,4)     AS REVENUE_PER_PURCHASE,
         ROUND((CONVERTED_LEADS * ALL_LEADS)::NUMBER(32,18) / NULLIF(LEADS * ALL_CONVERTED, 0), 4)::NUMBER(18,4)
                                                                                    AS CONVERSION_LIFT
  FROM inputs
),
dashboard_source AS (       -- the same roll-up from MART_LEAD_QUALITY (02c), the table the dashboard reads
  SELECT IFF(GROUPING(LEAD_SCORE_SEGMENT) = 1, 'All leads', LEAD_SCORE_SEGMENT) AS SEGMENT_NAME,
         SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(PURCHASES) AS PURCHASES,
         SUM(REVENUE) AS REVENUE
  FROM MART_LEAD_QUALITY
  GROUP BY ROLLUP (LEAD_SCORE_SEGMENT)
),
expected (SEGMENT, ORD, MIN_SCORE, MAX_SCORE, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE, CONVERSION_RATE,
          CR_CI_LOW, CR_CI_HIGH, PURCHASE_RATE, PR_CI_LOW, PR_CI_HIGH, REVENUE_PER_LEAD, REVENUE_PER_PURCHASE) AS (
  SELECT * FROM VALUES   -- counts, revenue, conversion rate [P3] / [K]; the rest [D5]; score ranges [plan]
    ('Low',        1,  1,  40, 104245,  9505,  5540,  3965,  5075916.10, 0.091179, 0.089447, 0.092942,
                   0.038035, 0.036891, 0.039214,  48.6922, 1280.1806),
    ('Medium',     2, 41,  70,  78862, 12758,  7412,  5346,  6908346.48, 0.161776, 0.159223, 0.164363,
                   0.067789, 0.066056, 0.069565,  87.6004, 1292.2459),
    ('High',       3, 71, 100,  78577, 17433, 10053,  7380,  9577576.43, 0.221859, 0.218967, 0.224778,
                   0.093921, 0.091901, 0.095980, 121.8878, 1297.7746),
    ('All leads',  4,  1, 100, 261684, 39696, 23005, 16691, 21561839.01, 0.151694, 0.150325, 0.153074,
                   0.063783, 0.062853, 0.064726,  82.3965, 1291.8243)
)
SELECT COALESCE(s.SEGMENT, e.SEGMENT) AS SEGMENT, s.MIN_SCORE || '-' || s.MAX_SCORE AS SCORE_RANGE,
       s.LEADS, s.LEAD_SHARE, s.CONVERTED_LEADS, s.TRIALS, s.PURCHASES,
       s.CONVERSION_RATE, s.CR_CI_LOW, s.CR_CI_HIGH, s.CONVERSION_LIFT,
       s.PURCHASE_RATE, s.PR_CI_LOW, s.PR_CI_HIGH,
       s.REVENUE, s.REVENUE_PER_LEAD, s.REVENUE_PER_PURCHASE,
       IFF(s.MIN_SCORE = e.MIN_SCORE AND s.MAX_SCORE = e.MAX_SCORE AND s.LEADS = e.LEADS
           AND s.CONVERTED_LEADS = e.CONVERTED_LEADS AND s.TRIALS = e.TRIALS AND s.PURCHASES = e.PURCHASES
           AND s.REVENUE = e.REVENUE AND s.CONVERSION_RATE = e.CONVERSION_RATE
           AND s.CR_CI_LOW = e.CR_CI_LOW AND s.CR_CI_HIGH = e.CR_CI_HIGH
           AND s.PURCHASE_RATE = e.PURCHASE_RATE AND s.PR_CI_LOW = e.PR_CI_LOW AND s.PR_CI_HIGH = e.PR_CI_HIGH
           AND s.REVENUE_PER_LEAD = e.REVENUE_PER_LEAD AND s.REVENUE_PER_PURCHASE = e.REVENUE_PER_PURCHASE
           AND s.SEGMENT_MISMATCHES = 0
           AND d.LEADS = s.LEADS AND d.CONVERTED_LEADS = s.CONVERTED_LEADS AND d.PURCHASES = s.PURCHASES
           AND d.REVENUE = s.REVENUE, 'PASS', 'FAIL') AS STATUS
FROM scorecard s
FULL OUTER JOIN expected e ON e.SEGMENT = s.SEGMENT
LEFT JOIN dashboard_source d ON d.SEGMENT_NAME = COALESCE(s.SEGMENT, e.SEGMENT)
ORDER BY e.ORD NULLS LAST, 1;


-- -----------------------------------------------------------------------------
-- 1b. Lead score segments: is the difference more than sampling noise? (chi-square test)
--    BUSINESS QUESTION (BQ4): are conversion and purchase independent of the score segment?
--    METHOD: chi-square test of independence on the 3 x 2 tables segment x converted (yes / no)
--      and segment x purchased (yes / no), written as plain SQL:
--        1. the tables in long form, one row per cell (TEST, ROW_KEY, COL_KEY, OBSERVED);
--        2. expected count E = row total x column total / table total, each total a window sum
--           (SUM(OBSERVED) OVER (PARTITION BY TEST, ROW_KEY) etc.);
--        3. X2 = SUM((O - E)^2 / E), df = (rows - 1) x (columns - 1) = 2, critical value 5.991 [T];
--        4. p-value for df = 2: EXP(-X2 / 2) [T]; it underflows FLOAT here, so LOG10_P_VALUE
--           (= -X2 / (2 ln 10)) carries it;
--        5. effect size Cramer's V = SQRT(X2 / (N x (min(rows, columns) - 1))): 0 = no
--           association, 1 = the segment determines the outcome. With 261,684 leads any real
--           difference is "significant"; V says how strong it is.
--    HOW TO READ: X2 6,035.02 for conversion (V 0.152) and 2,373.68 for purchase (V 0.095),
--      against a critical 5.991: independence is rejected by a huge margin, but the effect is
--      small for a single lead (rule of thumb for V on a table with a yes / no outcome: 0.1
--      small, 0.3 medium, 0.5 large): 78% of High leads still do not convert.
--      CONTRIBUTION_BY_SEGMENT shows where X2 comes from: Low (fewer conversions than expected)
--      and High (more); Medium is close to the all-lead rate.
--    CAVEATS: the test assumes independent leads with one probability per segment; it measures
--      sampling noise, not causation (G5) and not whether the score would rank leads elsewhere.
--    Checks: X2, df, LOG10_P_VALUE, Cramer's V [D5, exact rational arithmetic]; N = 261,684 [K].
-- -----------------------------------------------------------------------------
WITH by_segment AS (
  SELECT CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT,
         COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED, SUM(IS_PURCHASE) AS PURCHASED
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY 1
),
cells (TEST, ROW_KEY, COL_KEY, OBSERVED) AS (      -- 1. the contingency tables in long form, zeros kept
  SELECT 'segment x converted', SEGMENT, 'yes', CONVERTED         FROM by_segment UNION ALL
  SELECT 'segment x converted', SEGMENT, 'no',  LEADS - CONVERTED FROM by_segment UNION ALL
  SELECT 'segment x purchased', SEGMENT, 'yes', PURCHASED         FROM by_segment UNION ALL
  SELECT 'segment x purchased', SEGMENT, 'no',  LEADS - PURCHASED FROM by_segment
),
with_expected AS (          -- 2. E = row total x column total / table total, all three window sums
  SELECT TEST, ROW_KEY, COL_KEY, OBSERVED::FLOAT AS O,
         (SUM(OBSERVED) OVER (PARTITION BY TEST, ROW_KEY))::FLOAT
         * (SUM(OBSERVED) OVER (PARTITION BY TEST, COL_KEY))::FLOAT
         / (SUM(OBSERVED) OVER (PARTITION BY TEST))::FLOAT AS E
  FROM cells
),
by_row AS (                 -- each segment's share of X2
  SELECT TEST, ROW_KEY, SUM(POWER(O - E, 2) / E) AS CONTRIBUTION
  FROM with_expected
  GROUP BY TEST, ROW_KEY
),
tests AS (                  -- 3. statistic, degrees of freedom, effect-size denominator
  SELECT TEST, SUM(O) AS N, SUM(POWER(O - E, 2) / E) AS X2,
         (COUNT(DISTINCT ROW_KEY) - 1) * (COUNT(DISTINCT COL_KEY) - 1) AS DF,
         LEAST(COUNT(DISTINCT ROW_KEY), COUNT(DISTINCT COL_KEY)) - 1     AS K
  FROM with_expected
  GROUP BY TEST
),
contributions AS (          -- the per-segment shares as one text cell per test
  SELECT TEST, LISTAGG(ROW_KEY || ' ' || TO_VARCHAR(ROUND(CONTRIBUTION, 1)), '; ')
                 WITHIN GROUP (ORDER BY CONTRIBUTION DESC) AS CONTRIBUTION_BY_SEGMENT
  FROM by_row
  GROUP BY TEST
),
critical (DF, CRITICAL_5PCT) AS (SELECT * FROM VALUES (2, 5.991)),   -- [T]
expected (TEST, X2, DF, LOG10_P_VALUE, CRAMERS_V) AS (
  SELECT * FROM VALUES   -- [D5]
    ('segment x converted', 6035.0180, 2, -1310.4875, 0.151863),
    ('segment x purchased', 2373.6750, 2,  -515.4370, 0.095241)
),
results AS (
  SELECT t.TEST, t.N::NUMBER(38,0) AS N, t.DF, ROUND(t.X2, 4)::NUMBER(18,4) AS X2, c.CRITICAL_5PCT,
         ROUND(-t.X2 / 2 / LN(10), 4)::NUMBER(18,4)            AS LOG10_P_VALUE,   -- 4. df = 2: p = EXP(-X2/2)
         ROUND(EXP(-t.X2 / 2), 6)::NUMBER(18,6)                AS P_VALUE,
         ROUND(SQRT(t.X2 / (t.N * t.K)), 6)::NUMBER(18,6)       AS CRAMERS_V,        -- 5.
         IFF(t.X2 > c.CRITICAL_5PCT, 'reject independence (5%)', 'no evidence of association') AS DECISION,
         k.CONTRIBUTION_BY_SEGMENT
  FROM tests t
  LEFT JOIN critical c      ON c.DF = t.DF
  LEFT JOIN contributions k ON k.TEST = t.TEST                 -- 1:1
)
SELECT COALESCE(r.TEST, e.TEST) AS TEST, r.N, r.DF, r.X2, r.CRITICAL_5PCT, r.LOG10_P_VALUE, r.P_VALUE, r.CRAMERS_V,
       r.DECISION, r.CONTRIBUTION_BY_SEGMENT,
       IFF(r.X2 = e.X2 AND r.DF = e.DF AND r.LOG10_P_VALUE = e.LOG10_P_VALUE AND r.CRAMERS_V = e.CRAMERS_V
           AND r.N = 261684, 'PASS', 'FAIL') AS STATUS
FROM results r
FULL OUTER JOIN expected e ON e.TEST = r.TEST
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 2a. Score quantiles: NTILE(4), NTILE(10) and the 10-point bands (plan analysis #6)
--    BUSINESS QUESTION (BQ4): does the conversion rate rise steadily across the whole score
--      range, or only between the coarse segments?
--    METHOD: three ways to cut the score, side by side:
--      - quartiles and deciles: NTILE(4) / NTILE(10) OVER (ORDER BY LEAD_SCORE, LEAD_ID). Equal
--        numbers of leads per tile (261,684 / 4 = 65,421; / 10 = 26,168.4, so tiles 1-4 hold
--        26,169 and 5-10 hold 26,168). The score has only 100 values, so a tile boundary cuts
--        through one score value; LEAD_ID decides which of its leads go to the lower tile, which
--        makes the result deterministic (without it, reruns could move leads between tiles).
--      - 10-point bands: MART_LEAD_QUALITY (02c), the table the dashboard charts. Bands follow
--        score values, so their sizes vary (25,748-26,396) and they never split a score.
--      LAG(rate) OVER (PARTITION BY CUT ORDER BY GRP) gives the step from the previous group;
--      LEAD(MIN_SCORE) shows whether a group shares its top score with the next one.
--    HOW TO READ: every cut rises at every step: quartiles 7.65% -> 22.68% (3 of 3 steps up),
--      deciles 6.25% -> 23.99% (9 of 9), bands 6.27% -> 24.02% (9 of 9). Each decile step is
--      +1.7 to +2.3 points, i.e. close to linear. LIFT = group rate / all-lead rate: the top
--      decile converts at 1.58x the average, the bottom at 0.41x (3.84x between them).
--    CAVEATS: deciles and bands are not the same groups (SHARES_SCORE_WITH_NEXT): decile 2
--      runs 10-21, band 2 runs 11-20. Use bands for the dashboard (stable edges, additive);
--      deciles answer "the top 10% of leads by score". Association only (G5).
--    Checks: quartiles and deciles - leads, score range, converted, rate [D5]; bands - leads
--      [E01 18], converted and rate [D].
-- -----------------------------------------------------------------------------
WITH tiled AS (             -- every lead with its quartile and decile; LEAD_ID breaks score ties deterministically
  SELECT LEAD_SCORE, IS_CONVERTED,
         NTILE(4)  OVER (ORDER BY LEAD_SCORE, LEAD_ID) AS QUARTILE,
         NTILE(10) OVER (ORDER BY LEAD_SCORE, LEAD_ID) AS DECILE
  FROM FCT_LEAD_CONVERSIONS
),
groups AS (                 -- one row per group of each cut
  SELECT 'quartile (NTILE 4)' AS CUT, QUARTILE AS GRP, COUNT(*) AS LEADS, MIN(LEAD_SCORE) AS MIN_SCORE,
         MAX(LEAD_SCORE) AS MAX_SCORE, SUM(LEAD_SCORE) AS SUM_SCORE, SUM(IS_CONVERTED) AS CONVERTED_LEADS
  FROM tiled GROUP BY QUARTILE
  UNION ALL
  SELECT 'decile (NTILE 10)', DECILE, COUNT(*), MIN(LEAD_SCORE), MAX(LEAD_SCORE), SUM(LEAD_SCORE), SUM(IS_CONVERTED)
  FROM tiled GROUP BY DECILE
  UNION ALL                 -- the dashboard's 10-point bands, rolled up over the 5 channels
  SELECT 'band (MART_LEAD_QUALITY)', FLOOR(SCORE_BAND_MIN / 10)::NUMBER(2,0) + 1, SUM(LEADS), MIN(SCORE_BAND_MIN),
         MAX(SCORE_BAND_MAX), SUM(SUM_LEAD_SCORE), SUM(CONVERTED_LEADS)
  FROM MART_LEAD_QUALITY GROUP BY SCORE_BAND_MIN
),
rated AS (                  -- unrounded rates (18 dp), the cut's totals, Wilson inputs
  SELECT g.*,
         g.CONVERTED_LEADS::NUMBER(32,18) / g.LEADS        AS RATE,
         SUM(g.LEADS)           OVER (PARTITION BY g.CUT)  AS CUT_LEADS,
         SUM(g.CONVERTED_LEADS) OVER (PARTITION BY g.CUT)  AS CUT_CONVERTED,
         g.LEADS::FLOAT AS N, g.CONVERTED_LEADS::FLOAT / g.LEADS AS P, 1.959964::FLOAT AS Z
  FROM groups g
),
stepped AS (                -- LAG: step from the previous group; LEAD: does the next group start at my top score?
  SELECT r.*,
         r.RATE - LAG(r.RATE) OVER (PARTITION BY r.CUT ORDER BY r.GRP)            AS STEP,   -- NULL for group 1
         r.MAX_SCORE = LEAD(r.MIN_SCORE) OVER (PARTITION BY r.CUT ORDER BY r.GRP)  AS SHARES_SCORE_WITH_NEXT
  FROM rated r
),
final AS (
  SELECT CUT, GRP, MIN_SCORE, MAX_SCORE, LEADS, CONVERTED_LEADS, SHARES_SCORE_WITH_NEXT,
         ROUND(SUM_SCORE::NUMBER(32,18) / LEADS, 4)::NUMBER(18,4)                                AS AVG_SCORE,
         ROUND(RATE, 6)::NUMBER(18,6)                                                            AS CONVERSION_RATE,
         ROUND((P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS CI_LOW,
         ROUND((P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS CI_HIGH,
         ROUND(STEP, 6)::NUMBER(18,6)                                                            AS STEP_VS_PREVIOUS,
         SUM(IFF(STEP > 0, 1, 0)) OVER (PARTITION BY CUT) || ' of ' || COUNT(STEP) OVER (PARTITION BY CUT) AS STEPS_UP_IN_CUT,
         ROUND((CONVERTED_LEADS * CUT_LEADS)::NUMBER(32,18) / (LEADS * CUT_CONVERTED), 4)::NUMBER(18,4) AS LIFT
  FROM stepped
),
expected (CUT, GRP, LEADS, MIN_SCORE, MAX_SCORE, CONVERTED_LEADS, CONVERSION_RATE) AS (
  SELECT * FROM VALUES   -- quartiles and deciles [D5]; bands: leads [E01 18], converted and rate [D]
    ('quartile (NTILE 4)',  1, 65421,  1,  26,  5003, 0.076474), ('quartile (NTILE 4)',  2, 65421, 26,  51,  8270, 0.126412),
    ('quartile (NTILE 4)',  3, 65421, 51,  76, 11584, 0.177069), ('quartile (NTILE 4)',  4, 65421, 76, 100, 14839, 0.226823),
    ('decile (NTILE 10)',   1, 26169,  1,  10,  1636, 0.062517), ('decile (NTILE 10)',   2, 26169, 10,  21,  2088, 0.079789),
    ('decile (NTILE 10)',   3, 26169, 21,  31,  2661, 0.101685), ('decile (NTILE 10)',   4, 26169, 31,  41,  3185, 0.121709),
    ('decile (NTILE 10)',   5, 26168, 41,  51,  3704, 0.141547), ('decile (NTILE 10)',   6, 26168, 51,  61,  4197, 0.160387),
    ('decile (NTILE 10)',   7, 26168, 61,  71,  4803, 0.183545), ('decile (NTILE 10)',   8, 26168, 71,  81,  5312, 0.202996),
    ('decile (NTILE 10)',   9, 26168, 81,  91,  5832, 0.222868), ('decile (NTILE 10)',  10, 26168, 91, 100,  6278, 0.239911),
    ('band (MART_LEAD_QUALITY)',  1, 26193,  1,  10, 1642, 0.062689), ('band (MART_LEAD_QUALITY)',  2, 26058, 11,  20, 2072, 0.079515),
    ('band (MART_LEAD_QUALITY)',  3, 25748, 21,  30, 2624, 0.101911), ('band (MART_LEAD_QUALITY)',  4, 26246, 31,  40, 3167, 0.120666),
    ('band (MART_LEAD_QUALITY)',  5, 26293, 41,  50, 3724, 0.141635), ('band (MART_LEAD_QUALITY)',  6, 26173, 51,  60, 4195, 0.160280),
    ('band (MART_LEAD_QUALITY)',  7, 26396, 61,  70, 4839, 0.183323), ('band (MART_LEAD_QUALITY)',  8, 26184, 71,  80, 5316, 0.203025),
    ('band (MART_LEAD_QUALITY)',  9, 26068, 81,  90, 5795, 0.222303), ('band (MART_LEAD_QUALITY)', 10, 26325, 91, 100, 6322, 0.240152)
)
SELECT COALESCE(f.CUT, e.CUT) AS CUT, COALESCE(f.GRP, e.GRP) AS GRP, f.MIN_SCORE || '-' || f.MAX_SCORE AS SCORE_RANGE,
       f.SHARES_SCORE_WITH_NEXT, f.LEADS, f.AVG_SCORE, f.CONVERTED_LEADS, f.CONVERSION_RATE, f.CI_LOW, f.CI_HIGH,
       f.STEP_VS_PREVIOUS, f.STEPS_UP_IN_CUT, f.LIFT,
       IFF(f.LEADS = e.LEADS AND f.MIN_SCORE = e.MIN_SCORE AND f.MAX_SCORE = e.MAX_SCORE
           AND f.CONVERTED_LEADS = e.CONVERTED_LEADS AND f.CONVERSION_RATE = e.CONVERSION_RATE, 'PASS', 'FAIL') AS STATUS
FROM final f
FULL OUTER JOIN expected e ON e.CUT = f.CUT AND e.GRP = f.GRP
ORDER BY DECODE(COALESCE(f.CUT, e.CUT), 'quartile (NTILE 4)', 1, 'decile (NTILE 10)', 2, 3), 2;


-- -----------------------------------------------------------------------------
-- 2b. Single scores and the trend: how noisy is one score value, how steep is the rise?
--    BUSINESS QUESTION (BQ4): is "a higher score converts better" true point by point, and how
--      much does each score point add?
--    METHOD: one row per score value (1..100, 2,508-2,728 leads each), LAG(rate) OVER (ORDER BY
--      LEAD_SCORE) for the 99 score-to-score steps, MIN_BY / MAX_BY for where the largest drop
--      and rise happen; REGR_SLOPE / REGR_R2 of the per-score rate on the score (an unweighted
--      line through 100 points; the near-equal lead counts make weighting immaterial); CORR of
--      LEAD_SCORE with the 0/1 IS_CONVERTED over all leads (the point-biserial correlation).
--    HOW TO READ: 57 steps go up and 42 go down: one score point moves the expected rate by only
--      about 0.2 points, while the sampling noise of a single score's rate is about 0.7 points
--      (SQRT(0.15 x 0.85 / 2,600)), so single scores zigzag. Grouped into bands or deciles the
--      rise is monotonic (2a). The line fits the 100 rates closely (R^2 0.986): +2.00 points of
--      conversion rate per 10 score points, from 5.52% at score 1 to 25.36% at score 100. The
--      lead-level correlation is only 0.161 because the 0/1 outcome varies mostly within every
--      score: even at score 100, three leads in four do not convert.
--    CAVEATS: a near-perfect straight line is what a synthetic generator with a linear
--      probability would produce (G6); real scores are rarely this well behaved. Association
--      only (G5).
--    Checks: every value [D5].
-- -----------------------------------------------------------------------------
WITH per_score AS (         -- one row per score value
  SELECT LEAD_SCORE, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS,
         SUM(IS_CONVERTED)::NUMBER(32,18) / COUNT(*) AS RATE                     -- unrounded (18 dp)
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY LEAD_SCORE
),
stepped AS (
  SELECT LEAD_SCORE, LEADS, RATE, RATE - LAG(RATE) OVER (ORDER BY LEAD_SCORE) AS STEP   -- NULL for score 1
  FROM per_score
),
summary AS (
  SELECT COUNT(*) AS SCORES, MIN(LEADS) AS MIN_LEADS, MAX(LEADS) AS MAX_LEADS,
         COUNT(STEP) AS STEPS, COUNT_IF(STEP > 0) AS STEPS_UP, COUNT_IF(STEP < 0) AS STEPS_DOWN,
         MIN(STEP) AS LARGEST_DROP, MIN_BY(LEAD_SCORE, STEP) AS LARGEST_DROP_AT,
         MAX(STEP) AS LARGEST_RISE, MAX_BY(LEAD_SCORE, STEP) AS LARGEST_RISE_AT,
         MAX(IFF(LEAD_SCORE = 1, RATE, NULL))   AS RATE_SCORE_1,
         MAX(IFF(LEAD_SCORE = 100, RATE, NULL)) AS RATE_SCORE_100,
         REGR_SLOPE(RATE, LEAD_SCORE) * 10      AS SLOPE_PER_10_POINTS,             -- y = rate, x = score
         REGR_R2(RATE, LEAD_SCORE)              AS R2
  FROM stepped
),
lead_level AS (             -- point-biserial correlation over all 261,684 leads
  SELECT CORR(LEAD_SCORE, IS_CONVERTED) AS R FROM FCT_LEAD_CONVERSIONS
),
checks (ORD, CHECK_NAME, ACTUAL, EXPECTED) AS (
  SELECT  1, 'score values',                       SCORES,                                    100      FROM summary UNION ALL
  SELECT  2, 'leads per score, min',               MIN_LEADS,                                 2508     FROM summary UNION ALL
  SELECT  3, 'leads per score, max',               MAX_LEADS,                                 2728     FROM summary UNION ALL
  SELECT  4, 'score-to-score steps',               STEPS,                                     99       FROM summary UNION ALL
  SELECT  5, 'steps up',                           STEPS_UP,                                  57       FROM summary UNION ALL
  SELECT  6, 'steps down',                         STEPS_DOWN,                                42       FROM summary UNION ALL
  SELECT  7, 'largest drop (rate step)',           ROUND(LARGEST_DROP, 6),                    -0.026702 FROM summary UNION ALL
  SELECT  8, 'largest drop at score',              LARGEST_DROP_AT,                           48       FROM summary UNION ALL
  SELECT  9, 'largest rise (rate step)',           ROUND(LARGEST_RISE, 6),                    0.024679 FROM summary UNION ALL
  SELECT 10, 'largest rise at score',              LARGEST_RISE_AT,                           97       FROM summary UNION ALL
  SELECT 11, 'conversion rate at score 1',         ROUND(RATE_SCORE_1, 6),                    0.055244 FROM summary UNION ALL
  SELECT 12, 'conversion rate at score 100',       ROUND(RATE_SCORE_100, 6),                  0.253581 FROM summary UNION ALL
  SELECT 13, 'REGR_SLOPE x 10 (rate per 10 pts)',  ROUND(SLOPE_PER_10_POINTS, 6)::NUMBER(18,6), 0.020034 FROM summary UNION ALL
  SELECT 14, 'REGR_R2 (100 score rates)',          ROUND(R2, 6)::NUMBER(18,6),                0.985549 FROM summary UNION ALL
  SELECT 15, 'CORR(score, converted), all leads',  ROUND(R, 6)::NUMBER(18,6),                 0.161215 FROM lead_level
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM checks
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 3a. Channel lead quality: does any channel deliver higher-scored leads?
--    BUSINESS QUESTION (BQ4, second half): do some channels bring better-scored leads, and does
--      a channel's score mix explain its conversion rate?
--    METHOD: per channel (GROUP BY ROLLUP adds all channels): mean score (SUM / COUNT with an
--      18-dp dividend, one rounding), quartiles with PERCENTILE_CONT (linear interpolation), the
--      share of each CASE WHEN segment, the conversion rate with its Wilson interval. Then a
--      score-mix standardisation (indirect standardisation):
--        MIX_EXPECTED_RATE = SUM over segments (channel leads in segment x all-channel segment
--                            rate) / channel leads,
--      i.e. the rate the channel would have if each of its leads converted at the all-channel
--      rate of its segment. OBSERVED_TO_EXPECTED = actual / mix-expected conversions.
--      CONVERSION_LIFT = channel rate / all-lead rate: the same comparison with no score at all.
--    HOW TO READ: the channels are interchangeable on score: mean 50.47-50.66, median 50-51,
--      High share 29.93-30.16% (chi-square 7.00 on 8 df, p 0.537, block 3c). Mix-expected rates
--      are therefore all 15.15-15.19%, within 0.03 points of the all-lead 15.17%, and observed /
--      expected is 0.985 (display) to 1.010 (paid_search). Ignoring the score fits just as
--      well: CONVERSION_LIFT is 0.985 (display) to 1.012 (paid_search). Channel rates are within
--      1.5% of what their (practically identical) score mix predicts, which is also within 1.5%
--      of the all-lead rate: the standardisation explains essentially none of the small channel
--      differences, and neither score mix nor channel accounts for a meaningful difference.
--    CAVEATS: "no detectable difference" is within this synthetic data (G6), and the score is
--      undocumented (G5). The Data Studio page shows the mean score as SUM(SUM_LEAD_SCORE) /
--      SUM(LEADS) of MART_LEAD_QUALITY; medians and quartiles are not additive, so they live here
--      only.
--    Checks: every value [D5]; LEADS, CONVERSION_RATE and the Wilson bounds also equal
--      MART_CHANNEL_PERFORMANCE (02c, built from channel sums, its interval checked there).
-- -----------------------------------------------------------------------------
WITH leads AS (
  SELECT CHANNEL, LEAD_SCORE, IS_CONVERTED,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT
  FROM FCT_LEAD_CONVERSIONS
),
profile AS (                -- one row per channel + the all-channel row
  SELECT IFF(GROUPING(CHANNEL) = 1, 'All channels', CHANNEL)                        AS CHANNEL_NAME,
         COUNT(*)                                                                    AS LEADS,
         ROUND(SUM(LEAD_SCORE)::NUMBER(32,18) / COUNT(*), 4)::NUMBER(18,4)           AS AVG_SCORE,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY LEAD_SCORE)                    AS P25_SCORE,
         PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY LEAD_SCORE)                    AS MEDIAN_SCORE,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY LEAD_SCORE)                    AS P75_SCORE,
         ROUND(COUNT_IF(SEGMENT = 'Low')::NUMBER(32,18)    / COUNT(*), 6)::NUMBER(18,6) AS SHARE_LOW,
         ROUND(COUNT_IF(SEGMENT = 'Medium')::NUMBER(32,18) / COUNT(*), 6)::NUMBER(18,6) AS SHARE_MEDIUM,
         ROUND(COUNT_IF(SEGMENT = 'High')::NUMBER(32,18)   / COUNT(*), 6)::NUMBER(18,6) AS SHARE_HIGH,
         SUM(IS_CONVERTED)                                                           AS CONVERTED_LEADS
  FROM leads
  GROUP BY ROLLUP (CHANNEL)
),
segment_rates AS (          -- all-channel conversion counts per segment
  SELECT SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS
  FROM leads GROUP BY SEGMENT
),
mix_expected AS (           -- conversions each channel would have at the all-channel segment rates
  SELECT IFF(GROUPING(cs.CHANNEL) = 1, 'All channels', cs.CHANNEL) AS CHANNEL_NAME,
         SUM((cs.LEADS * s.CONVERTED_LEADS)::NUMBER(32,18) / s.LEADS) AS EXPECTED_CONVERTED
  FROM (SELECT CHANNEL, SEGMENT, COUNT(*) AS LEADS FROM leads GROUP BY CHANNEL, SEGMENT) cs
  JOIN segment_rates s ON s.SEGMENT = cs.SEGMENT                          -- n:1
  GROUP BY ROLLUP (cs.CHANNEL)
),
inputs AS (                 -- all-channel totals (window over the 6 rows) and the FLOAT inputs of the Wilson interval
  SELECT p.*, m.EXPECTED_CONVERTED,
         MAX(IFF(p.CHANNEL_NAME = 'All channels', p.LEADS, NULL))           OVER () AS ALL_LEADS,
         MAX(IFF(p.CHANNEL_NAME = 'All channels', p.CONVERTED_LEADS, NULL)) OVER () AS ALL_CONVERTED,
         p.LEADS::FLOAT AS N, p.CONVERTED_LEADS::FLOAT / p.LEADS AS P, 1.959964::FLOAT AS Z
  FROM profile p
  JOIN mix_expected m ON m.CHANNEL_NAME = p.CHANNEL_NAME                             -- 1:1
),
final AS (
  SELECT i.*,
         ROUND(CONVERTED_LEADS::NUMBER(32,18) / LEADS, 6)::NUMBER(18,6)            AS CONVERSION_RATE,
         ROUND((P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS CR_CI_LOW,
         ROUND((P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS CR_CI_HIGH,
         ROUND((CONVERTED_LEADS * ALL_LEADS)::NUMBER(32,18) / (LEADS * ALL_CONVERTED), 4)::NUMBER(18,4) AS CONVERSION_LIFT,  -- no score
         ROUND(EXPECTED_CONVERTED / LEADS, 6)::NUMBER(18,6)                          AS MIX_EXPECTED_RATE,
         ROUND(CONVERTED_LEADS::FLOAT / EXPECTED_CONVERTED::FLOAT, 4)::NUMBER(18,4)  AS OBSERVED_TO_EXPECTED  -- FLOAT: 18-dp / 18-dp
  FROM inputs i
),
expected (CHANNEL, ORD, LEADS, AVG_SCORE, P25_SCORE, MEDIAN_SCORE, P75_SCORE, SHARE_LOW, SHARE_MEDIUM, SHARE_HIGH,
          CONVERSION_RATE, CR_CI_LOW, CR_CI_HIGH, CONVERSION_LIFT, MIX_EXPECTED_RATE, OBSERVED_TO_EXPECTED) AS (
  SELECT * FROM VALUES   -- [D5]
    ('affiliate',    1,  67849, 50.5620, 26, 50, 75, 0.398842, 0.301832, 0.299326,
                     0.152574, 0.149888, 0.155299, 1.0058, 0.151604, 1.0064),
    ('display',      2,  45149, 50.5366, 25, 51, 76, 0.398680, 0.301889, 0.299431,
                     0.149372, 0.146114, 0.152690, 0.9847, 0.151621, 0.9852),
    ('paid_search',  3,  65268, 50.6614, 26, 51, 76, 0.395967, 0.302476, 0.301557,
                     0.153506, 0.150760, 0.156291, 1.0119, 0.151941, 1.0103),
    ('paid_social',  4,  57619, 50.4742, 25, 51, 75, 0.401413, 0.297818, 0.300769,
                     0.150089, 0.147196, 0.153029, 0.9894, 0.151509, 0.9906),
    ('video',        5,  25799, 50.6429, 26, 51, 76, 0.395791, 0.304314, 0.299895,
                     0.152448, 0.148113, 0.156886, 1.0050, 0.151853, 1.0039),
    ('All channels', 6, 261684, 50.5711, 26, 51, 76, 0.398362, 0.301363, 0.300274,
                     0.151694, 0.150325, 0.153074, 1.0000, 0.151694, 1.0000)
)
SELECT COALESCE(f.CHANNEL_NAME, e.CHANNEL) AS CHANNEL, f.LEADS, f.AVG_SCORE, f.P25_SCORE, f.MEDIAN_SCORE, f.P75_SCORE,
       f.SHARE_LOW, f.SHARE_MEDIUM, f.SHARE_HIGH, f.CONVERSION_RATE, f.CR_CI_LOW, f.CR_CI_HIGH, f.CONVERSION_LIFT,
       f.MIX_EXPECTED_RATE, f.OBSERVED_TO_EXPECTED,
       IFF(f.LEADS = e.LEADS AND f.AVG_SCORE = e.AVG_SCORE AND f.P25_SCORE = e.P25_SCORE
           AND f.MEDIAN_SCORE = e.MEDIAN_SCORE AND f.P75_SCORE = e.P75_SCORE AND f.SHARE_LOW = e.SHARE_LOW
           AND f.SHARE_MEDIUM = e.SHARE_MEDIUM AND f.SHARE_HIGH = e.SHARE_HIGH
           AND f.CONVERSION_RATE = e.CONVERSION_RATE AND f.CR_CI_LOW = e.CR_CI_LOW AND f.CR_CI_HIGH = e.CR_CI_HIGH
           AND f.CONVERSION_LIFT = e.CONVERSION_LIFT AND f.MIX_EXPECTED_RATE = e.MIX_EXPECTED_RATE
           AND f.OBSERVED_TO_EXPECTED = e.OBSERVED_TO_EXPECTED
           AND (f.CHANNEL_NAME = 'All channels'                       -- the channel mart has no all-channel row
                OR (c.LEADS = f.LEADS AND c.LEAD_CONVERSION_RATE = f.CONVERSION_RATE
                    AND c.LCR_CI_LOW = f.CR_CI_LOW AND c.LCR_CI_HIGH = f.CR_CI_HIGH)), 'PASS', 'FAIL') AS STATUS
FROM final f
FULL OUTER JOIN expected e ON e.CHANNEL = f.CHANNEL_NAME
LEFT JOIN MART_CHANNEL_PERFORMANCE c ON c.CHANNEL = f.CHANNEL_NAME
ORDER BY e.ORD NULLS LAST, 1;


-- -----------------------------------------------------------------------------
-- 3b. Segment x channel conversion rates (dashboard heatmap)
--    BUSINESS QUESTION (BQ4): within the same score segment, does any channel convert better?
--    METHOD: one GROUP BY CUBE (SEGMENT, CHANNEL) gives every segment x channel rate and both
--      margins (all channels, all leads) in one pass; PIVOT turns the channels into columns.
--      CHANNEL_SPREAD = highest minus lowest channel rate in the row (GREATEST - LEAST).
--    HOW TO READ: read across a row. The score segment moves the rate from about 9% to 22%; the
--      channel moves it by at most 0.43 (Low), 0.59 (Medium) and 0.74 (High) points, and none of
--      these spreads is beyond sampling noise (block 3c). The score, not the channel, is what
--      goes with conversion here.
--    CAVEATS: rates of a cell rest on 7,737-27,061 leads. Data Studio builds the same heatmap
--      from MART_LEAD_QUALITY (CHANNEL x LEAD_SCORE_SEGMENT, SUM(CONVERTED_LEADS) /
--      SUM(LEADS)). Association only (G5); synthetic data (G6).
--    Checks: all 24 rates and the 4 spreads [D5] (the all-leads row holds the channel rates that
--      3a also checks against MART_CHANNEL_PERFORMANCE).
-- -----------------------------------------------------------------------------
WITH leads AS (
  SELECT CHANNEL, IS_CONVERTED,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT
  FROM FCT_LEAD_CONVERSIONS
),
cells AS (                  -- CUBE: segment x channel, segment x all, all x channel, all x all
  SELECT IFF(GROUPING(SEGMENT) = 1, 'All leads', SEGMENT) AS SEGMENT_NAME,
         IFF(GROUPING(CHANNEL) = 1, 'all', CHANNEL)       AS CHANNEL_NAME,
         ROUND(SUM(IS_CONVERTED)::NUMBER(32,18) / COUNT(*), 6)::NUMBER(18,6) AS RATE
  FROM leads
  GROUP BY CUBE (SEGMENT, CHANNEL)
),
pivoted AS (
  SELECT *
  FROM cells
    PIVOT (MAX(RATE) FOR CHANNEL_NAME IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video', 'all'))
    AS p (SEGMENT, AFFILIATE, DISPLAY, PAID_SEARCH, PAID_SOCIAL, VIDEO, ALL_CHANNELS)
),
expected (SEGMENT, ORD, AFFILIATE, DISPLAY, PAID_SEARCH, PAID_SOCIAL, VIDEO, ALL_CHANNELS, CHANNEL_SPREAD) AS (
  SELECT * FROM VALUES   -- [D5]
    ('Low',       1, 0.093345, 0.090778, 0.091743, 0.089066, 0.089511, 0.091179, 0.004279),
    ('Medium',    2, 0.159041, 0.159134, 0.164928, 0.162646, 0.163673, 0.161776, 0.005887),
    ('High',      3, 0.224974, 0.217546, 0.223148, 0.219100, 0.224118, 0.221859, 0.007428),
    ('All leads', 4, 0.152574, 0.149372, 0.153506, 0.150089, 0.152448, 0.151694, 0.004134)
)
SELECT COALESCE(p.SEGMENT, e.SEGMENT) AS SEGMENT, p.AFFILIATE, p.DISPLAY, p.PAID_SEARCH, p.PAID_SOCIAL, p.VIDEO,
       p.ALL_CHANNELS,
       GREATEST(p.AFFILIATE, p.DISPLAY, p.PAID_SEARCH, p.PAID_SOCIAL, p.VIDEO)
         - LEAST(p.AFFILIATE, p.DISPLAY, p.PAID_SEARCH, p.PAID_SOCIAL, p.VIDEO) AS CHANNEL_SPREAD,
       IFF(p.AFFILIATE = e.AFFILIATE AND p.DISPLAY = e.DISPLAY AND p.PAID_SEARCH = e.PAID_SEARCH
           AND p.PAID_SOCIAL = e.PAID_SOCIAL AND p.VIDEO = e.VIDEO AND p.ALL_CHANNELS = e.ALL_CHANNELS
           AND GREATEST(p.AFFILIATE, p.DISPLAY, p.PAID_SEARCH, p.PAID_SOCIAL, p.VIDEO)
               - LEAST(p.AFFILIATE, p.DISPLAY, p.PAID_SEARCH, p.PAID_SOCIAL, p.VIDEO) = e.CHANNEL_SPREAD,
           'PASS', 'FAIL') AS STATUS
FROM pivoted p
FULL OUTER JOIN expected e ON e.SEGMENT = p.SEGMENT
ORDER BY e.ORD NULLS LAST, 1;


-- -----------------------------------------------------------------------------
-- 3c. Channels: chi-square tests of score mix and of conversion within each segment
--    BUSINESS QUESTION (BQ4): are the small channel differences of 3a and 3b more than noise?
--    METHOD: the chi-square machinery of 1b on five tables:
--      channel x segment (5 x 3, df 8): does the score mix differ by channel?
--      channel x converted within Low, Medium, High (5 x 2, df 4 each), and over all leads.
--      Cells are aggregated per (TEST, ROW_KEY, COL_KEY) first, so the all-leads table sums the
--      three segments correctly. p-value from the closed form for even df [T]:
--        df 4: EXP(-x/2) x (1 + x/2);  df 8: EXP(-x/2) x (1 + h + h^2/2 + h^3/6), h = x/2.
--    HOW TO READ: every X2 is below its 5% critical value (p 0.26-0.54) and Cramer's V is at most
--      0.007: no evidence that channels differ in score mix or, within a segment, in conversion.
--      Contrast 1b: X2 6,035 between segments. For BQ4 this means the score segment, not the
--      channel, is the axis along which conversion varies in this data.
--    CAVEATS: "no evidence of a difference" is not proof of equality, but with 25,799-67,849 leads
--      per channel the tests would detect differences far smaller than the segment gaps. Leads
--      are assumed independent (leads of one campaign may not be). Synthetic data (G6).
--    Checks: X2, df, LOG10_P_VALUE, P_VALUE, Cramer's V [D5]; N of each table: 261,684 [K] or the
--      segment size [P3].
-- -----------------------------------------------------------------------------
WITH by_channel_segment AS (
  SELECT CHANNEL,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT,
         COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY 1, 2
),
cells AS (                  -- the five contingency tables in long form, aggregated to one row per cell
  SELECT TEST, ROW_KEY, COL_KEY, SUM(OBSERVED) AS OBSERVED
  FROM (
    SELECT 'channel x segment' AS TEST, CHANNEL AS ROW_KEY, SEGMENT AS COL_KEY, LEADS AS OBSERVED FROM by_channel_segment
    UNION ALL SELECT 'channel x converted | ' || SEGMENT, CHANNEL, 'yes', CONVERTED         FROM by_channel_segment
    UNION ALL SELECT 'channel x converted | ' || SEGMENT, CHANNEL, 'no',  LEADS - CONVERTED FROM by_channel_segment
    UNION ALL SELECT 'channel x converted | all leads',  CHANNEL, 'yes', CONVERTED         FROM by_channel_segment
    UNION ALL SELECT 'channel x converted | all leads',  CHANNEL, 'no',  LEADS - CONVERTED FROM by_channel_segment
  )
  GROUP BY TEST, ROW_KEY, COL_KEY
),
with_expected AS (          -- E = row total x column total / table total (window sums)
  SELECT TEST, ROW_KEY, COL_KEY, OBSERVED::FLOAT AS O,
         (SUM(OBSERVED) OVER (PARTITION BY TEST, ROW_KEY))::FLOAT
         * (SUM(OBSERVED) OVER (PARTITION BY TEST, COL_KEY))::FLOAT
         / (SUM(OBSERVED) OVER (PARTITION BY TEST))::FLOAT AS E
  FROM cells
),
tests AS (
  SELECT TEST, SUM(O) AS N, SUM(POWER(O - E, 2) / E) AS X2, SUM(POWER(O - E, 2) / E) / 2 AS H,
         (COUNT(DISTINCT ROW_KEY) - 1) * (COUNT(DISTINCT COL_KEY) - 1) AS DF,
         LEAST(COUNT(DISTINCT ROW_KEY), COUNT(DISTINCT COL_KEY)) - 1     AS K
  FROM with_expected
  GROUP BY TEST
),
critical (DF, CRITICAL_5PCT) AS (SELECT * FROM VALUES (4, 9.488), (8, 15.507)),   -- [T]
results AS (
  SELECT t.TEST, t.N::NUMBER(38,0) AS N, t.DF, ROUND(t.X2, 4)::NUMBER(18,4) AS X2, c.CRITICAL_5PCT,
         -- log10 of the even-df p-value EXP(-h) x SUM_{i < df/2} h^i / i!  (only df 4 and 8 occur here)
         (-t.H + LN(CASE t.DF WHEN 4 THEN 1 + t.H
                              WHEN 8 THEN 1 + t.H + POWER(t.H, 2) / 2 + POWER(t.H, 3) / 6 END)) / LN(10) AS LOG10_P,
         ROUND(SQRT(t.X2 / (t.N * t.K)), 6)::NUMBER(18,6) AS CRAMERS_V,
         IFF(t.X2 > c.CRITICAL_5PCT, 'reject independence (5%)', 'no evidence of association') AS DECISION
  FROM tests t
  LEFT JOIN critical c ON c.DF = t.DF
),
expected (TEST, ORD, N, X2, DF, LOG10_P_VALUE, P_VALUE, CRAMERS_V) AS (
  SELECT * FROM VALUES   -- N [K] / [P3]; the rest [D5]
    ('channel x segment',                1, 261684, 6.9982, 8, -0.2702, 0.536825, 0.003657),
    ('channel x converted | Low',        2, 104245, 3.2550, 4, -0.2873, 0.516096, 0.005588),
    ('channel x converted | Medium',     3,  78862, 3.5813, 4, -0.3320, 0.465625, 0.006739),
    ('channel x converted | High',       4,  78577, 3.7808, 4, -0.3600, 0.436476, 0.006937),
    ('channel x converted | all leads',  5, 261684, 5.2312, 4, -0.5778, 0.264383, 0.004471)
)
SELECT COALESCE(r.TEST, e.TEST) AS TEST, r.N, r.DF, r.X2, r.CRITICAL_5PCT,
       ROUND(r.LOG10_P, 4)::NUMBER(18,4) AS LOG10_P_VALUE, ROUND(POWER(10, r.LOG10_P), 6)::NUMBER(18,6) AS P_VALUE,
       r.CRAMERS_V, r.DECISION,
       IFF(r.X2 = e.X2 AND r.DF = e.DF AND ROUND(r.LOG10_P, 4) = e.LOG10_P_VALUE
           AND ROUND(POWER(10, r.LOG10_P), 6) = e.P_VALUE AND r.CRAMERS_V = e.CRAMERS_V AND r.N = e.N,
           'PASS', 'FAIL') AS STATUS
FROM results r
FULL OUTER JOIN expected e ON e.TEST = r.TEST
ORDER BY e.ORD NULLS LAST, 1;


-- -----------------------------------------------------------------------------
-- 4a. Conversion time: the lag distribution (plan analysis #7)
--    BUSINESS QUESTION (BQ5): how long does a lead take to convert, and does it differ by
--      conversion type, channel or score segment?
--    METHOD: DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) per converted lead; MIN, PERCENTILE_CONT
--      (0.25 / 0.5 / 0.75 / 0.9, linear interpolation), MAX and AVG; the share converting within
--      7 days. GROUP BY GROUPING SETS ((), type, channel, segment) computes all four splits in one
--      pass over the 39,696 converted leads.
--    HOW TO READ: lag runs 0-21 days with median 10 (p25 5, p75 16, p90 19) and mean 10.51; 36.2%
--      of conversions happen within a week. Trials and purchases, the five channels and the
--      three segments show no detectable difference: group means within 0.23 days of each other
--      (10.38-10.61), every p25 / p75 / p90 identical, only the median 10 or 11. The one-way
--      ANOVA of 4d agrees: F 0.0068 by type, 0.6944 by channel, 1.6899 by segment, each below
--      its 5% critical value (p 0.93 / 0.60 / 0.18 [D5]). High-score leads are not detectably
--      faster (mean 10.48 days vs 10.61 for Low).
--    CAVEATS: lag is measured on converted leads only (the 221,988 others never converted within
--      the data); it is the time to conversion, not a probability. Identical percentiles in every
--      group are a generator artefact (G6). AVG returns NUMBER(19,6) and is rounded again to
--      4 dp; every mean is at least 3.3 x 10^-6 from a 4-dp midpoint [D5], so the double
--      rounding cannot change a digit. The dashboard's mean lag is SUM(SUM_DAYS_TO_CONVERT) /
--      SUM(CONVERTED_LEADS) of MART_LEAD_QUALITY.
--    Checks: all / type / channel [E01 25]; segments and the 7-day shares [D5]; the segment means
--      also equal the MART_LEAD_QUALITY formula; DATEDIFF equals the Phase 3 column
--      DAYS_TO_CONVERT on every converted lead.
-- -----------------------------------------------------------------------------
WITH converted AS (         -- one row per converted lead; the lag computed here with DATEDIFF
  SELECT CONVERSION_TYPE, CHANNEL,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT,
         DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) AS LAG_DAYS,
         DAYS_TO_CONVERT                                                    -- the Phase 3 column, cross-check only
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
),
lag_profile AS (
  SELECT CASE WHEN GROUPING(CONVERSION_TYPE) = 0 THEN 'conversion_type'
              WHEN GROUPING(CHANNEL) = 0         THEN 'channel'
              WHEN GROUPING(SEGMENT) = 0         THEN 'score_segment'
              ELSE 'all' END                                                AS SPLIT_BY,
         COALESCE(CONVERSION_TYPE, CHANNEL, SEGMENT, 'all')                 AS GROUP_VALUE,
         COUNT(*)                                                           AS CONVERSIONS,
         MIN(LAG_DAYS)                                                      AS MIN_LAG,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY LAG_DAYS)             AS P25,
         PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY LAG_DAYS)             AS MEDIAN,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY LAG_DAYS)             AS P75,
         PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY LAG_DAYS)             AS P90,
         MAX(LAG_DAYS)                                                      AS MAX_LAG,
         ROUND(AVG(LAG_DAYS), 4)                                            AS AVG_LAG,
         ROUND(COUNT_IF(LAG_DAYS <= 7)::NUMBER(32,18) / COUNT(*), 6)::NUMBER(18,6) AS SHARE_WITHIN_7_DAYS,
         COUNT_IF(LAG_DAYS IS DISTINCT FROM DAYS_TO_CONVERT)                AS LAG_MISMATCHES
  FROM converted
  GROUP BY GROUPING SETS ((), (CONVERSION_TYPE), (CHANNEL), (SEGMENT))
),
dashboard_source AS (       -- the dashboard's mean lag per segment, from MART_LEAD_QUALITY sums
  SELECT LEAD_SCORE_SEGMENT, ROUND(SUM(SUM_DAYS_TO_CONVERT)::NUMBER(32,18) / SUM(CONVERTED_LEADS), 4) AS MEAN_LAG
  FROM MART_LEAD_QUALITY
  GROUP BY LEAD_SCORE_SEGMENT
),
expected (SPLIT_BY, GROUP_VALUE, ORD, CONVERSIONS, MIN_LAG, P25, MEDIAN, P75, P90, MAX_LAG, AVG_LAG, SHARE_WITHIN_7_DAYS) AS (
  SELECT * FROM VALUES   -- [E01 25] except segments and the 7-day shares [D5]
    ('all',             'all',          1, 39696, 0, 5, 10, 16, 19, 21, 10.5056, 0.362228),
    ('conversion_type', 'purchase',     2, 16691, 0, 5, 10, 16, 19, 21, 10.5025, 0.361752),
    ('conversion_type', 'trial',        3, 23005, 0, 5, 11, 16, 19, 21, 10.5078, 0.362573),
    ('channel',         'affiliate',    4, 10352, 0, 5, 10, 16, 19, 21, 10.4954, 0.362635),
    ('channel',         'display',      5,  6744, 0, 5, 10, 16, 19, 21, 10.5101, 0.364917),
    ('channel',         'paid_search',  6, 10019, 0, 5, 11, 16, 19, 21, 10.5017, 0.364807),
    ('channel',         'paid_social',  7,  8648, 0, 5, 11, 16, 19, 21, 10.5774, 0.353377),
    ('channel',         'video',        8,  3933, 0, 5, 10, 16, 19, 21, 10.3766, 0.369438),
    ('score_segment',   'Low',          9,  9505, 0, 5, 11, 16, 19, 21, 10.6084, 0.356128),
    ('score_segment',   'Medium',      10, 12758, 0, 5, 10, 16, 19, 21, 10.4609, 0.367064),
    ('score_segment',   'High',        11, 17433, 0, 5, 10, 16, 19, 21, 10.4822, 0.362015)
)
SELECT COALESCE(a.SPLIT_BY, e.SPLIT_BY) AS SPLIT_BY, COALESCE(a.GROUP_VALUE, e.GROUP_VALUE) AS GROUP_VALUE,
       a.CONVERSIONS, a.MIN_LAG, a.P25, a.MEDIAN, a.P75, a.P90, a.MAX_LAG, a.AVG_LAG, a.SHARE_WITHIN_7_DAYS,
       a.LAG_MISMATCHES,
       IFF(a.CONVERSIONS = e.CONVERSIONS AND a.MIN_LAG = e.MIN_LAG AND a.P25 = e.P25 AND a.MEDIAN = e.MEDIAN
           AND a.P75 = e.P75 AND a.P90 = e.P90 AND a.MAX_LAG = e.MAX_LAG AND a.AVG_LAG = e.AVG_LAG
           AND a.SHARE_WITHIN_7_DAYS = e.SHARE_WITHIN_7_DAYS AND a.LAG_MISMATCHES = 0
           AND IFF(a.SPLIT_BY = 'score_segment', d.MEAN_LAG = a.AVG_LAG, TRUE), 'PASS', 'FAIL') AS STATUS
FROM lag_profile a
FULL OUTER JOIN expected e ON e.SPLIT_BY = a.SPLIT_BY AND e.GROUP_VALUE = a.GROUP_VALUE
LEFT JOIN dashboard_source d ON d.LEAD_SCORE_SEGMENT = a.GROUP_VALUE AND a.SPLIT_BY = 'score_segment'
ORDER BY e.ORD NULLS LAST, 1, 2;


-- -----------------------------------------------------------------------------
-- 4b. Cumulative conversion curve, day 0..21 (dashboard chart)
--    BUSINESS QUESTION (BQ5): by day N after a lead is created, what share of the eventual
--      conversions has happened?
--    METHOD: a gap-free spine of lag days 0..21 from TABLE(GENERATOR(ROWCOUNT => 22)) with
--      ROW_NUMBER() - 1, LEFT JOINed to conversions per lag day (a day without conversions would
--      show 0, not disappear). The running total is SUM(..) OVER (ORDER BY LAG_DAYS ROWS BETWEEN
--      UNBOUNDED PRECEDING AND CURRENT ROW).
--      CUM_SHARE_OF_CONVERSIONS = running conversions / 39,696 (the curve);
--      CUM_CONVERSION_RATE      = running conversions / 261,684 leads (share of all leads
--                                 converted by day N; it ends at the 15.17% conversion rate);
--      UNIFORM_CUM_SHARE        = (N + 1) / 22, the curve if every day had the same count.
--    HOW TO READ: about 4.5% of conversions land on each day (1,740-1,861), so the curve is a
--      straight line: 36.2% by day 7, 50.07% by day 10, 68.3% by day 14, 90.99% by day 19, all by
--      day 21. A reporting window shorter than three weeks misses conversions roughly in
--      proportion to the days it cuts (a 14-day window sees 68.3% of them).
--    CAVEATS: a flat daily lag is a generator artefact (G6): real lags usually front-load. The
--      curve is over converted leads; it says when, not whether. No dashboard mart holds lag by
--      day yet (MART_LEAD_QUALITY keeps only SUM_DAYS_TO_CONVERT): this 22-row output is the
--      candidate source for the chart.
--    Checks: conversions per day and the cumulative share [D5]; the curve ends at 39,696 [K].
-- -----------------------------------------------------------------------------
WITH days AS (              -- gap-free spine of lag days 0..21 (21 = the observed maximum lag)
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS LAG_DAYS
  FROM TABLE(GENERATOR(ROWCOUNT => 22))
),
by_day AS (
  SELECT DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) AS LAG_DAYS, COUNT(*) AS CONVERSIONS
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
  GROUP BY 1
),
totals AS (
  SELECT COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS FROM FCT_LEAD_CONVERSIONS
),
curve AS (
  SELECT d.LAG_DAYS, COALESCE(b.CONVERSIONS, 0) AS CONVERSIONS,
         SUM(COALESCE(b.CONVERSIONS, 0)) OVER (ORDER BY d.LAG_DAYS ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           AS CUM_CONVERSIONS
  FROM days d
  LEFT JOIN by_day b ON b.LAG_DAYS = d.LAG_DAYS
),
expected (LAG_DAYS, CONVERSIONS, CUM_SHARE) AS (
  SELECT * FROM VALUES   -- [D5]
    ( 0, 1811, 0.045622), ( 1, 1796, 0.090866), ( 2, 1757, 0.135127), ( 3, 1740, 0.178960), ( 4, 1849, 0.225539),
    ( 5, 1792, 0.270682), ( 6, 1809, 0.316254), ( 7, 1825, 0.362228), ( 8, 1861, 0.409109), ( 9, 1855, 0.455839),
    (10, 1781, 0.500705), (11, 1800, 0.546050), (12, 1798, 0.591344), (13, 1796, 0.636588), (14, 1835, 0.682814),
    (15, 1792, 0.727957), (16, 1812, 0.773604), (17, 1745, 0.817563), (18, 1827, 0.863588), (19, 1840, 0.909941),
    (20, 1751, 0.954051), (21, 1824, 1.000000)
)
SELECT COALESCE(c.LAG_DAYS, e.LAG_DAYS) AS LAG_DAYS, c.CONVERSIONS,
       ROUND(c.CONVERSIONS::NUMBER(32,18)     / t.CONVERTED_LEADS, 6)::NUMBER(18,6) AS SHARE_OF_CONVERSIONS,
       c.CUM_CONVERSIONS,
       ROUND(c.CUM_CONVERSIONS::NUMBER(32,18) / t.CONVERTED_LEADS, 6)::NUMBER(18,6) AS CUM_SHARE_OF_CONVERSIONS,
       ROUND((c.LAG_DAYS + 1)::NUMBER(32,18)  / 22, 6)::NUMBER(18,6)                AS UNIFORM_CUM_SHARE,
       ROUND(c.CUM_CONVERSIONS::NUMBER(32,18) / t.LEADS, 6)::NUMBER(18,6)           AS CUM_CONVERSION_RATE,
       IFF(c.CONVERSIONS = e.CONVERSIONS
           AND ROUND(c.CUM_CONVERSIONS::NUMBER(32,18) / t.CONVERTED_LEADS, 6) = e.CUM_SHARE
           AND (c.LAG_DAYS < 21 OR c.CUM_CONVERSIONS = 39696), 'PASS', 'FAIL') AS STATUS
FROM curve c
CROSS JOIN totals t
FULL OUTER JOIN expected e ON e.LAG_DAYS = c.LAG_DAYS
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 4c. Conversions after the campaign ended
--    BUSINESS QUESTION (BQ5): how many conversions arrive after the campaign that generated the
--      lead has stopped, and how late?
--    METHOD: the lead fact joined n:1 to DIM_CAMPAIGN for END_DATE; DAYS_AFTER_END =
--      DATEDIFF('day', END_DATE, CONVERTED_DATE) (> 0 means after the end); counted in 7-day
--      buckets; GROUP BY ROLLUP (CONVERSION_TYPE) adds the total.
--    HOW TO READ: 4,716 conversions (11.88%) and 2,532,266.74 of attributed revenue (11.74%)
--      arrive 1-21 days after the campaign ended: 2,583 in the first week, 1,568 in the second,
--      565 in the third. A campaign report closed on its end date understates its conversions
--      by about one in eight; this is why the activity spine of 02c runs to END_DATE + 21.
--    CAVEATS: attributed revenue (last touch, G4). The share depends on campaign length (a lead
--      created near the end has most of its 21-day window after it).
--    Checks: counts, shares, revenue and maximum [E01 24]; the buckets [D5]; 0 rows where
--      DAYS_AFTER_END > 0 disagrees with the Phase 3 flag CONVERTED_AFTER_CAMPAIGN_END.
-- -----------------------------------------------------------------------------
WITH converted AS (
  SELECT f.CONVERSION_TYPE, f.REVENUE, f.CONVERTED_AFTER_CAMPAIGN_END,
         DATEDIFF('day', c.END_DATE, f.CONVERTED_DATE) AS DAYS_AFTER_END
  FROM FCT_LEAD_CONVERSIONS f
  JOIN DIM_CAMPAIGN c ON c.CAMPAIGN_ID = f.CAMPAIGN_ID          -- n:1: the lead's campaign, for END_DATE only
  WHERE f.IS_CONVERTED = 1
),
after_end AS (
  SELECT IFF(GROUPING(CONVERSION_TYPE) = 1, 'all', CONVERSION_TYPE) AS CONVERSION_TYPE_NAME,
         COUNT(*)                                     AS CONVERSIONS,
         COUNT_IF(DAYS_AFTER_END > 0)                 AS AFTER_CAMPAIGN_END,
         SUM(REVENUE)                                 AS REVENUE,
         SUM(IFF(DAYS_AFTER_END > 0, REVENUE, 0))     AS AFTER_END_REVENUE,
         COUNT_IF(DAYS_AFTER_END BETWEEN  1 AND  7)   AS DAYS_1_7,
         COUNT_IF(DAYS_AFTER_END BETWEEN  8 AND 14)   AS DAYS_8_14,
         COUNT_IF(DAYS_AFTER_END BETWEEN 15 AND 21)   AS DAYS_15_21,
         MAX(DAYS_AFTER_END)                          AS MAX_DAYS_AFTER_END,
         COUNT_IF((DAYS_AFTER_END > 0) <> (CONVERTED_AFTER_CAMPAIGN_END = 1)) AS FLAG_MISMATCHES
  FROM converted
  GROUP BY ROLLUP (CONVERSION_TYPE)
),
expected (CONVERSION_TYPE, ORD, CONVERSIONS, AFTER_CAMPAIGN_END, AFTER_END_SHARE, REVENUE, AFTER_END_REVENUE,
          AFTER_END_REVENUE_SHARE, DAYS_1_7, DAYS_8_14, DAYS_15_21, MAX_DAYS_AFTER_END) AS (
  SELECT * FROM VALUES   -- [E01 24]; revenue share and buckets [D5]
    ('purchase', 1, 16691, 1951, 0.116889, 21561839.01, 2532266.74, 0.117442, 1071,  636, 244, 21),
    ('trial',    2, 23005, 2765, 0.120191,        0.00,       0.00,     NULL, 1512,  932, 321, 21),
    ('all',      3, 39696, 4716, 0.118803, 21561839.01, 2532266.74, 0.117442, 2583, 1568, 565, 21)
)
SELECT COALESCE(a.CONVERSION_TYPE_NAME, e.CONVERSION_TYPE) AS CONVERSION_TYPE, a.CONVERSIONS, a.AFTER_CAMPAIGN_END,
       ROUND(a.AFTER_CAMPAIGN_END::NUMBER(32,18) / a.CONVERSIONS, 6)::NUMBER(18,6)        AS AFTER_END_SHARE,
       a.REVENUE, a.AFTER_END_REVENUE,
       ROUND(a.AFTER_END_REVENUE::NUMBER(32,18) / NULLIF(a.REVENUE, 0), 6)::NUMBER(18,6)  AS AFTER_END_REVENUE_SHARE,
       a.DAYS_1_7, a.DAYS_8_14, a.DAYS_15_21, a.MAX_DAYS_AFTER_END, a.FLAG_MISMATCHES,
       IFF(a.CONVERSIONS = e.CONVERSIONS AND a.AFTER_CAMPAIGN_END = e.AFTER_CAMPAIGN_END
           AND ROUND(a.AFTER_CAMPAIGN_END::NUMBER(32,18) / a.CONVERSIONS, 6) = e.AFTER_END_SHARE
           AND a.REVENUE = e.REVENUE AND a.AFTER_END_REVENUE = e.AFTER_END_REVENUE
           AND EQUAL_NULL(ROUND(a.AFTER_END_REVENUE::NUMBER(32,18) / NULLIF(a.REVENUE, 0), 6), e.AFTER_END_REVENUE_SHARE)
           AND a.DAYS_1_7 = e.DAYS_1_7 AND a.DAYS_8_14 = e.DAYS_8_14 AND a.DAYS_15_21 = e.DAYS_15_21
           AND a.MAX_DAYS_AFTER_END = e.MAX_DAYS_AFTER_END AND a.FLAG_MISMATCHES = 0, 'PASS', 'FAIL') AS STATUS
FROM after_end a
FULL OUTER JOIN expected e ON e.CONVERSION_TYPE = a.CONVERSION_TYPE_NAME
ORDER BY e.ORD NULLS LAST, 1;


-- -----------------------------------------------------------------------------
-- 4d. Timing summary: the BQ5 headline numbers, the uniform-lag test, group differences, maturity
--    BUSINESS QUESTION (BQ5): the answer in a few numbers; does the lag differ by conversion
--      type, channel or score segment; and can the conversion rates of this file be understated
--      by leads that have not had time to convert?
--    METHOD: first day on which the running share reaches 50% / 90% (MIN over the running
--      total); chi-square goodness of fit of the 22 daily counts to a uniform lag (E = 39,696 /
--      22 per day, df 21, critical 32.671 [T]); a one-way ANOVA of LAG_DAYS for each split of
--      4a, built from COUNT / SUM / SUM of squares per group (GROUP BY GROUPING SETS):
--        SSB = SUM_g (S_g^2 / n_g) - S^2 / N,  SSW = SUM(lag^2) - SUM_g (S_g^2 / n_g),
--        F = (SSB / (k - 1)) / (SSW / (N - k)), critical value at 5% [T];
--      IS_MATURE of every lead (created at least 21 days before the assumed as-of date
--      2025-12-31), and the leads whose 21-day window runs past the last observed conversion.
--    HOW TO READ: half of the conversions happen by day 10 and 90% by day 19; the daily counts
--      are consistent with a flat lag (X2 13.98 < 32.671). F is 0.0068 by conversion type,
--      0.6944 by channel and 1.6899 by score segment, all below their 5% critical values
--      (p 0.93 / 0.60 / 0.18 [D5]): no detectable difference in lag between the groups.
--      Every lead is mature, so every conversion rate in this file is complete under the as-of
--      assumption.
--    CAVEATS: the as-of date is an assumption of Phase 3. The observed data end on 2025-12-21
--      (the last conversion), and the 65 leads created 2025-12-01/02 have not had their full 21
--      days by then; 54 of them have not converted, so on the observed data alone the all-lead
--      rate could be understated by at most 54 / 261,684 = 0.021 points. ANOVA compares means and
--      assumes independent lags; with 3,933-23,005 conversions per group and a lag standard
--      deviation of about 6.3 days, a group mean has a standard error of 0.04-0.10 days, so a
--      difference of a few tenths of a day would show. "No detectable difference" is not proof
--      of equality. Synthetic data (G6).
--    Checks: [D5]; 261,684 leads [K]; 0 conversions outside 0..21 days [E01 24, 25]; the last
--      conversion date and the 65 leads [E01 26]; F only when k and N are as expected (otherwise
--      ACTUAL is NULL and the row FAILs); F critical values [T].
-- -----------------------------------------------------------------------------
WITH lags AS (
  SELECT DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) AS LAG_DAYS, CONVERSION_TYPE, CHANNEL,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT
  FROM FCT_LEAD_CONVERSIONS
  WHERE IS_CONVERTED = 1
),
days AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS LAG_DAYS FROM TABLE(GENERATOR(ROWCOUNT => 22))
),
by_day AS (                 -- counts on the 0..21 spine (FULL OUTER JOIN keeps a lag outside the spine visible)
  SELECT COALESCE(d.LAG_DAYS, l.LAG_DAYS) AS LAG_DAYS, d.LAG_DAYS IS NOT NULL AS ON_SPINE, COALESCE(l.N, 0) AS N
  FROM days d
  FULL OUTER JOIN (SELECT LAG_DAYS, COUNT(*) AS N FROM lags GROUP BY LAG_DAYS) l ON l.LAG_DAYS = d.LAG_DAYS
),
running AS (
  SELECT LAG_DAYS, ON_SPINE, N,
         (SUM(N) OVER (ORDER BY LAG_DAYS ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))::NUMBER(32,18)
           / SUM(N) OVER () AS CUM_SHARE,
         (SUM(N) OVER ())::FLOAT / 22 AS E_UNIFORM                        -- expected count per day if the lag were uniform
  FROM by_day
),
summary AS (
  SELECT MAX(IFF(N > 0, LAG_DAYS, NULL))                     AS MAX_LAG,
         SUM(IFF(ON_SPINE, 0, N))                            AS OUTSIDE_SPINE,
         MIN(IFF(CUM_SHARE >= 0.5, LAG_DAYS, NULL))          AS DAY_50PCT,
         MIN(IFF(CUM_SHARE >= 0.9, LAG_DAYS, NULL))          AS DAY_90PCT,
         MAX(IFF(LAG_DAYS = 7, CUM_SHARE, NULL))             AS WITHIN_7,
         MAX(IFF(LAG_DAYS = 14, CUM_SHARE, NULL))            AS WITHIN_14,
         SUM(IFF(ON_SPINE, POWER(N - E_UNIFORM, 2) / E_UNIFORM, NULL)) AS X2_UNIFORM
  FROM running
),
lag_groups AS (             -- n, sum and sum of squares of the lag per group of each split of 4a
  SELECT CASE WHEN GROUPING(CONVERSION_TYPE) = 0 THEN 'conversion_type'
              WHEN GROUPING(CHANNEL) = 0         THEN 'channel'
              ELSE 'score_segment' END                          AS SPLIT_BY,
         COUNT(*) AS N_G, SUM(LAG_DAYS) AS S_G, SUM(LAG_DAYS * LAG_DAYS) AS SQ_G
  FROM lags
  GROUP BY GROUPING SETS ((CONVERSION_TYPE), (CHANNEL), (SEGMENT))
),
anova AS (                  -- one-way ANOVA per split; S_g^2 / n_g with an 18-dp dividend, exact to 18 dp
  SELECT SPLIT_BY, COUNT(*) AS K, SUM(N_G) AS N,
         SUM((S_G * S_G)::NUMBER(32,18) / N_G)
           - (SUM(S_G) * SUM(S_G))::NUMBER(32,18) / SUM(N_G)              AS SSB,      -- between groups
         SUM(SQ_G) - SUM((S_G * S_G)::NUMBER(32,18) / N_G)                AS SSW       -- within groups
  FROM lag_groups
  GROUP BY SPLIT_BY
),
f_tests AS (
  SELECT a.SPLIT_BY, a.K, a.N, (a.SSB::FLOAT / (a.K - 1)) / (a.SSW::FLOAT / (a.N - a.K)) AS F, c.CRITICAL_5PCT
  FROM anova a
  LEFT JOIN (SELECT * FROM VALUES ('conversion_type', 3.842), ('channel', 2.372), ('score_segment', 2.996))
              AS c (SPLIT_BY, CRITICAL_5PCT) ON c.SPLIT_BY = a.SPLIT_BY                      -- [T]
),
data_end AS (               -- the last observed conversion
  SELECT MAX(CONVERTED_DATE) AS LAST_CONVERSION FROM FCT_LEAD_CONVERSIONS
),
maturity AS (
  SELECT COUNT(*) AS LEADS, COUNT_IF(f.IS_MATURE = 0) AS NOT_MATURE,
         MAX(DATEDIFF('day', '2025-12-21'::DATE, d.LAST_CONVERSION))                     AS LAST_CONVERSION_OFFSET,
         COUNT_IF(DATEADD('day', 21, f.CREATED_DATE) > d.LAST_CONVERSION)                AS WINDOW_PAST_DATA,
         COUNT_IF(DATEADD('day', 21, f.CREATED_DATE) > d.LAST_CONVERSION AND f.IS_CONVERTED = 0) AS WINDOW_PAST_DATA_UNCONVERTED
  FROM FCT_LEAD_CONVERSIONS f
  CROSS JOIN data_end d
),
checks (ORD, CHECK_NAME, ACTUAL, EXPECTED) AS (
  SELECT  1, 'max lag, days',                         MAX_LAG,                              21       FROM summary UNION ALL
  SELECT  2, 'conversions outside lag days 0-21',     OUTSIDE_SPINE,                        0        FROM summary UNION ALL
  SELECT  3, 'first day with >= 50% of conversions',  DAY_50PCT,                            10       FROM summary UNION ALL
  SELECT  4, 'first day with >= 90% of conversions',  DAY_90PCT,                            19       FROM summary UNION ALL
  SELECT  5, 'share converted within 7 days',         ROUND(WITHIN_7, 6),                   0.362228 FROM summary UNION ALL
  SELECT  6, 'share converted within 14 days',        ROUND(WITHIN_14, 6),                  0.682814 FROM summary UNION ALL
  SELECT  7, 'X2 lag vs uniform 0-21 (df 21)',        ROUND(X2_UNIFORM, 4)::NUMBER(18,4),   13.9823  FROM summary UNION ALL
  SELECT  8, 'X2 above critical 32.671 (1 = yes)',    IFF(X2_UNIFORM > 32.671, 1, 0),       0        FROM summary UNION ALL
  -- F rows: one row even if a split is missing; ACTUAL is NULL (FAIL) unless the split exists with the expected k and N
  SELECT  9, 'F lag by conversion type (df 1, 39694)',
             MAX(IFF(SPLIT_BY = 'conversion_type' AND K = 2 AND N = 39696, ROUND(F, 4), NULL))::NUMBER(18,4), 0.0068 FROM f_tests UNION ALL
  SELECT 10, 'F lag by channel (df 4, 39691)',
             MAX(IFF(SPLIT_BY = 'channel'         AND K = 5 AND N = 39696, ROUND(F, 4), NULL))::NUMBER(18,4), 0.6944 FROM f_tests UNION ALL
  SELECT 11, 'F lag by score segment (df 2, 39693)',
             MAX(IFF(SPLIT_BY = 'score_segment'   AND K = 3 AND N = 39696, ROUND(F, 4), NULL))::NUMBER(18,4), 1.6899 FROM f_tests UNION ALL
  SELECT 12, 'splits with F above 5% critical value',    COUNT_IF(F > CRITICAL_5PCT) + COUNT_IF(CRITICAL_5PCT IS NULL), 0
                                                      FROM f_tests UNION ALL
  SELECT 13, 'leads checked for maturity',            LEADS,                                261684   FROM maturity UNION ALL
  SELECT 14, 'leads not mature at as-of 2025-12-31',  NOT_MATURE,                           0        FROM maturity UNION ALL
  SELECT 15, 'last conversion, days after 2025-12-21', LAST_CONVERSION_OFFSET,              0        FROM maturity UNION ALL
  SELECT 16, 'leads with window past last conversion', WINDOW_PAST_DATA,                    65       FROM maturity UNION ALL
  SELECT 17, 'of those 65, leads not converted',      WINDOW_PAST_DATA_UNCONVERTED,         54       FROM maturity
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM checks
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 5a. Campaign ranking by High-segment share (window functions)
--    BUSINESS QUESTION (BQ4, campaign view): which campaigns bring the largest share of
--      High-score leads, and do they convert better?
--    METHOD: leads aggregated to one row per campaign first (G1); HIGH_SHARE = leads scored
--      71-100 / leads, ranked on its unrounded 18-dp value:
--        ROW_NUMBER()   OVER (ORDER BY HIGH_SHARE DESC, CAMPAIGN_ID)  unique position (tie-breaker)
--        RANK()         OVER (ORDER BY HIGH_SHARE DESC)               ties share a rank (none here)
--        PERCENT_RANK() OVER (ORDER BY HIGH_SHARE DESC)               (rank - 1) / (120 - 1)
--        RANK()         OVER (PARTITION BY CHANNEL ORDER BY ...)      rank within the channel's 24
--        RANK()         OVER (ORDER BY CONVERSION_RATE DESC)          the same campaign by conversion
--      QUALIFY keeps the top 10 and the bottom 5 after every window was computed over all 120.
--      HS_CI_LOW / HS_CI_HIGH: Wilson 95% interval of the High share.
--    HOW TO READ: High shares run from 25.38% (CMP0039) to 33.83% (CMP0018) around 30.03% for all
--      leads. The extremes are small campaigns (CMP0018 has 334 leads; the bottom 5 are all video
--      campaigns, 459-1,325 leads) with wide intervals, so the ranking at both ends is mostly
--      sampling noise (5c). Conversion ranks of single small campaigns are noise too: CMP0018
--      ranks 108th of 120 on conversion and CMP0054 (116th on High share) ranks 1st. A
--      334-lead campaign's conversion rate has a standard error of about 1.9 points [D5], twice
--      the 0.95-point standard deviation of campaign conversion rates (5c). The pooled view is
--      5b / 5c.
--    CAVEATS: a ranking of ratios rewards small denominators; read it with LEADS and the interval.
--      The High share has no campaign mart column (MART_CAMPAIGN_PERFORMANCE carries no score):
--      analysis only. Association only (G5).
--    Checks: every shown value [D5].
-- -----------------------------------------------------------------------------
WITH by_campaign AS (       -- lead fact -> one row per campaign (aggregate first, G1)
  SELECT CAMPAIGN_ID, CHANNEL,
         COUNT(*)                                AS LEADS,
         COUNT_IF(LEAD_SCORE BETWEEN 71 AND 100) AS HIGH_LEADS,          -- the plan's High segment
         SUM(IS_CONVERTED)                       AS CONVERTED_LEADS
  FROM FCT_LEAD_CONVERSIONS
  GROUP BY CAMPAIGN_ID, CHANNEL
),
shares AS (
  SELECT b.*,
         b.HIGH_LEADS::NUMBER(32,18)      / b.LEADS AS HIGH_SHARE_EXACT,          -- unrounded: distinct shares stay distinct
         b.CONVERTED_LEADS::NUMBER(32,18) / b.LEADS AS CONVERSION_RATE_EXACT,
         b.LEADS::FLOAT AS N, b.HIGH_LEADS::FLOAT / b.LEADS AS P, 1.959964::FLOAT AS Z
  FROM by_campaign b
),
ranked AS (
  SELECT s.*,
         ROW_NUMBER()   OVER (ORDER BY HIGH_SHARE_EXACT DESC, CAMPAIGN_ID)            AS ROW_NUM,
         RANK()         OVER (ORDER BY HIGH_SHARE_EXACT DESC)                         AS HIGH_SHARE_RANK,
         PERCENT_RANK() OVER (ORDER BY HIGH_SHARE_EXACT DESC)                         AS PCT_RANK,
         RANK()         OVER (PARTITION BY CHANNEL ORDER BY HIGH_SHARE_EXACT DESC)    AS RANK_IN_CHANNEL,
         RANK()         OVER (ORDER BY CONVERSION_RATE_EXACT DESC)                    AS CONVERSION_RATE_RANK
  FROM shares s
  QUALIFY ROW_NUM <= 10                                                                -- top 10 ...
       OR ROW_NUMBER() OVER (ORDER BY HIGH_SHARE_EXACT ASC, CAMPAIGN_ID DESC) <= 5     -- ... and bottom 5
),
final AS (
  SELECT ROW_NUM, HIGH_SHARE_RANK, CAMPAIGN_ID, CHANNEL, LEADS, HIGH_LEADS,
         ROUND(HIGH_SHARE_EXACT, 6)::NUMBER(18,6)                                               AS HIGH_SHARE,
         ROUND((P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS HS_CI_LOW,
         ROUND((P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N), 6)::NUMBER(18,6) AS HS_CI_HIGH,
         ROUND(PCT_RANK, 4)::NUMBER(18,4)                                                        AS PCT_RANK,
         RANK_IN_CHANNEL,
         ROUND(CONVERSION_RATE_EXACT, 6)::NUMBER(18,6)                                          AS CONVERSION_RATE,
         CONVERSION_RATE_RANK
  FROM ranked
),
expected (CAMPAIGN_ID, ROW_NUM, CHANNEL, LEADS, HIGH_LEADS, HIGH_SHARE, HS_CI_LOW, HS_CI_HIGH, PCT_RANK, RANK_IN_CHANNEL,
          CONVERSION_RATE, CONVERSION_RATE_RANK) AS (
  SELECT * FROM VALUES   -- [D5]
    ('CMP0018',   1, 'display',      334, 113, 0.338323, 0.289676, 0.390647, 0.0000,  1, 0.143713, 108),
    ('CMP0044',   2, 'video',        344, 114, 0.331395, 0.283755, 0.382759, 0.0084,  1, 0.154070,  51),
    ('CMP0089',   3, 'video',       1374, 455, 0.331150, 0.306766, 0.356475, 0.0168,  2, 0.160844,  14),
    ('CMP0045',   4, 'affiliate',   1430, 463, 0.323776, 0.300024, 0.348472, 0.0252,  1, 0.149650,  74),
    ('CMP0046',   5, 'paid_search', 1184, 382, 0.322635, 0.296618, 0.349800, 0.0336,  1, 0.160473,  18),
    ('CMP0019',   6, 'video',        684, 220, 0.321637, 0.287712, 0.357555, 0.0420,  3, 0.153509,  56),
    ('CMP0006',   7, 'paid_search', 3235, 1040, 0.321484, 0.305609, 0.337782, 0.0504, 2, 0.157651,  28),
    ('CMP0035',   8, 'affiliate',   2218, 713, 0.321461, 0.302347, 0.341192, 0.0588,  2, 0.153742,  53),
    ('CMP0016',   9, 'paid_search', 1560, 500, 0.320513, 0.297820, 0.344087, 0.0672,  3, 0.155769,  38),
    ('CMP0009',  10, 'video',       1720, 550, 0.319767, 0.298149, 0.342189, 0.0756,  4, 0.151163,  63),
    ('CMP0054', 116, 'video',        459, 127, 0.276688, 0.237744, 0.319340, 0.9664, 20, 0.187364,   1),
    ('CMP0074', 117, 'video',        934, 257, 0.275161, 0.247484, 0.304679, 0.9748, 21, 0.127409, 119),
    ('CMP0014', 118, 'video',       1325, 357, 0.269434, 0.246237, 0.293964, 0.9832, 22, 0.160755,  15),
    ('CMP0004', 119, 'video',        803, 204, 0.254047, 0.225158, 0.285279, 0.9916, 23, 0.154421,  49),
    ('CMP0039', 120, 'video',        733, 186, 0.253752, 0.223589, 0.286482, 1.0000, 24, 0.155525,  40)
)
SELECT COALESCE(f.ROW_NUM, e.ROW_NUM) AS ROW_NUM, f.HIGH_SHARE_RANK, COALESCE(f.CAMPAIGN_ID, e.CAMPAIGN_ID) AS CAMPAIGN_ID,
       f.CHANNEL, f.LEADS, f.HIGH_LEADS, f.HIGH_SHARE, f.HS_CI_LOW, f.HS_CI_HIGH, f.PCT_RANK, f.RANK_IN_CHANNEL,
       f.CONVERSION_RATE, f.CONVERSION_RATE_RANK,
       IFF(f.ROW_NUM = e.ROW_NUM AND f.HIGH_SHARE_RANK = e.ROW_NUM AND f.CHANNEL = e.CHANNEL AND f.LEADS = e.LEADS
           AND f.HIGH_LEADS = e.HIGH_LEADS AND f.HIGH_SHARE = e.HIGH_SHARE AND f.HS_CI_LOW = e.HS_CI_LOW
           AND f.HS_CI_HIGH = e.HS_CI_HIGH AND f.PCT_RANK = e.PCT_RANK AND f.RANK_IN_CHANNEL = e.RANK_IN_CHANNEL
           AND f.CONVERSION_RATE = e.CONVERSION_RATE AND f.CONVERSION_RATE_RANK = e.CONVERSION_RATE_RANK,
           'PASS', 'FAIL') AS STATUS
FROM final f
FULL OUTER JOIN expected e ON e.CAMPAIGN_ID = f.CAMPAIGN_ID
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 5b. Campaign quartiles by High share: do campaigns with more High leads convert better?
--    BUSINESS QUESTION (BQ4, campaign view): pooled over many campaigns, does a higher High
--      share go with a higher campaign conversion rate, as the segment rates of 1a would predict?
--    METHOD: NTILE(4) OVER (ORDER BY HIGH_SHARE DESC, CAMPAIGN_ID) over the 120 campaigns (30
--      each), then pooled ratios of sums per quartile (never an average of campaign ratios).
--      MIX_EXPECTED_RATE is the score-mix standardisation of 3a at campaign level: the rate the
--      quartile would have if each of its leads converted at the all-lead rate of its segment.
--    HOW TO READ: the pooled High share falls from 31.59% (Q1) to 28.68% (Q4). The score mix
--      alone predicts 15.31% for Q1 and 15.04% for Q4, a 0.27-point gap; observed are 15.30%
--      and 15.23%, a 0.07-point gap. The binomial standard error of a Q1 - Q4 difference is
--      about 0.21 points (before any campaign-to-campaign variation), so neither gap can be
--      told apart from noise: campaigns differ too little in score mix for it to show in their
--      conversion rates. Q1 and Q4 have the fewest leads per campaign: the extreme High shares
--      sit in smaller campaigns (5a, 5c).
--    CAVEATS: campaigns differ in channel, objective and timing, none of which is controlled
--      here; association only (G5); synthetic data (G6).
--    Checks: every value [D5] (LEADS_PER_CAMPAIGN = LEADS / CAMPAIGNS, 2 dp).
-- -----------------------------------------------------------------------------
WITH leads AS (
  SELECT CAMPAIGN_ID, IS_CONVERTED,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT
  FROM FCT_LEAD_CONVERSIONS
),
segment_rates AS (          -- all-lead conversion counts per segment
  SELECT SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS FROM leads GROUP BY SEGMENT
),
by_campaign AS (            -- lead -> campaign x segment -> campaign (aggregate first, G1)
  SELECT c.CAMPAIGN_ID, SUM(c.LEADS) AS LEADS, SUM(IFF(c.SEGMENT = 'High', c.LEADS, 0)) AS HIGH_LEADS,
         SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM((c.LEADS * s.CONVERTED_LEADS)::NUMBER(32,18) / s.LEADS) AS MIX_EXPECTED_CONVERTED
  FROM (SELECT CAMPAIGN_ID, SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS
        FROM leads GROUP BY CAMPAIGN_ID, SEGMENT) c
  JOIN segment_rates s ON s.SEGMENT = c.SEGMENT                                  -- n:1
  GROUP BY c.CAMPAIGN_ID
),
quartiled AS (
  SELECT b.*, b.HIGH_LEADS::NUMBER(32,18) / b.LEADS AS HIGH_SHARE_EXACT,
         NTILE(4) OVER (ORDER BY b.HIGH_LEADS::NUMBER(32,18) / b.LEADS DESC, b.CAMPAIGN_ID) AS HIGH_SHARE_QUARTILE
  FROM by_campaign b
),
final AS (
  SELECT HIGH_SHARE_QUARTILE, COUNT(*) AS CAMPAIGNS, SUM(LEADS) AS LEADS,
         ROUND(SUM(LEADS)::NUMBER(32,18) / COUNT(*), 2)::NUMBER(18,2)                  AS LEADS_PER_CAMPAIGN,
         ROUND(MIN(HIGH_SHARE_EXACT), 6)::NUMBER(18,6)                                 AS MIN_HIGH_SHARE,
         ROUND(MAX(HIGH_SHARE_EXACT), 6)::NUMBER(18,6)                                 AS MAX_HIGH_SHARE,
         ROUND(SUM(HIGH_LEADS)::NUMBER(32,18) / SUM(LEADS), 6)::NUMBER(18,6)           AS POOLED_HIGH_SHARE,
         SUM(CONVERTED_LEADS)                                                          AS CONVERTED_LEADS,
         ROUND(SUM(CONVERTED_LEADS)::NUMBER(32,18) / SUM(LEADS), 6)::NUMBER(18,6)      AS POOLED_CONVERSION_RATE,
         ROUND(SUM(MIX_EXPECTED_CONVERTED) / SUM(LEADS), 6)::NUMBER(18,6)              AS MIX_EXPECTED_RATE,
         ROUND(SUM(CONVERTED_LEADS)::FLOAT / SUM(MIX_EXPECTED_CONVERTED)::FLOAT, 4)::NUMBER(18,4) AS OBSERVED_TO_EXPECTED
  FROM quartiled
  GROUP BY HIGH_SHARE_QUARTILE
),
expected (HIGH_SHARE_QUARTILE, CAMPAIGNS, LEADS, LEADS_PER_CAMPAIGN, MIN_HIGH_SHARE, MAX_HIGH_SHARE, POOLED_HIGH_SHARE,
          CONVERTED_LEADS, POOLED_CONVERSION_RATE, MIX_EXPECTED_RATE, OBSERVED_TO_EXPECTED) AS (
  SELECT * FROM VALUES   -- [D5]
    (1, 30, 52652, 1755.07, 0.308683, 0.338323, 0.315942,  8056, 0.153005, 0.153125, 0.9992),
    (2, 30, 66672, 2222.40, 0.300703, 0.308571, 0.305031, 10014, 0.150198, 0.152111, 0.9874),
    (3, 30, 78802, 2626.73, 0.293103, 0.300638, 0.296655, 11943, 0.151557, 0.151438, 1.0008),
    (4, 30, 63558, 2118.60, 0.253752, 0.292425, 0.286793,  9683, 0.152349, 0.150390, 1.0130)
)
SELECT COALESCE(f.HIGH_SHARE_QUARTILE, e.HIGH_SHARE_QUARTILE) AS HIGH_SHARE_QUARTILE, f.CAMPAIGNS, f.LEADS,
       f.LEADS_PER_CAMPAIGN, f.MIN_HIGH_SHARE, f.MAX_HIGH_SHARE, f.POOLED_HIGH_SHARE, f.CONVERTED_LEADS,
       f.POOLED_CONVERSION_RATE, f.MIX_EXPECTED_RATE, f.OBSERVED_TO_EXPECTED,
       IFF(f.CAMPAIGNS = e.CAMPAIGNS AND f.LEADS = e.LEADS AND f.LEADS_PER_CAMPAIGN = e.LEADS_PER_CAMPAIGN
           AND f.MIN_HIGH_SHARE = e.MIN_HIGH_SHARE
           AND f.MAX_HIGH_SHARE = e.MAX_HIGH_SHARE AND f.POOLED_HIGH_SHARE = e.POOLED_HIGH_SHARE
           AND f.CONVERTED_LEADS = e.CONVERTED_LEADS AND f.POOLED_CONVERSION_RATE = e.POOLED_CONVERSION_RATE
           AND f.MIX_EXPECTED_RATE = e.MIX_EXPECTED_RATE AND f.OBSERVED_TO_EXPECTED = e.OBSERVED_TO_EXPECTED,
           'PASS', 'FAIL') AS STATUS
FROM final f
FULL OUTER JOIN expected e ON e.HIGH_SHARE_QUARTILE = f.HIGH_SHARE_QUARTILE
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 5c. Campaign ranking summary: how much of the spread is noise?
--    BUSINESS QUESTION (BQ4, campaign view): do campaigns really differ in the share of High
--      leads they deliver, and does that share go with conversion?
--    METHOD: over all 120 campaigns: ties (ROW_NUMBER <> RANK), the range of the High share,
--      campaigns whose Wilson 95% interval lies entirely above / below the all-lead share, a
--      chi-square test of homogeneity (k x 2 table: X2 = SUM((H - n p)^2 / (n p (1 - p))) with
--      p the all-lead share, df 119, critical 145.461 [T]), the correlation of High share with
--      conversion rate across campaigns, and the size of the campaigns at the two ends.
--      What the score mix alone would produce: each campaign's mix-expected rate (the rate if
--      each of its leads converted at the all-lead rate of its segment, as in 5b), and the
--      correlation that implies, COVAR_SAMP(HS, MIX) / (STDDEV_SAMP(HS) x STDDEV_SAMP(CR)): if
--      CR = MIX + binomial noise unrelated to HS, CORR(HS, CR) is about CORR(HS, MIX) x
--      STDDEV(MIX) / STDDEV(CR).
--    HOW TO READ: 9 of 120 intervals exclude the all-lead share, against about 6 (5%) if every
--      campaign had the same underlying share; X2 153.39 is just above the critical 145.461
--      (p about 0.018 [D5]): a little more spread than pure noise, but small in size (most
--      campaigns sit within a few points of 30%). The correlation with conversion rate is
--      -0.072. That is not evidence of no association. High share tracks the mix-expected rate
--      closely (0.843), but mix-expected rates spread only 0.16 points across campaigns against
--      0.95 points for conversion rates, so the score mix alone would give only about +0.146.
--      -0.072 is inside the noise of both cases: shuffling conversion rates across campaigns
--      gives a 95% range of about +/-0.18 around 0, and binomial draws at the segment rates
--      give about -0.08 to +0.35 around +0.14 ([D5]; -0.072 is near its low end, reached or
--      undercut in 3% of draws). So the
--      campaign view is too noisy to confirm or refute the lead-level association of 1a; if
--      anything it is weaker than the score mix implies. The top 10 average 1,408 leads and
--      the bottom 5 851, against a median of 1,947.5: small campaigns produce the extreme ratios.
--    CAVEATS: 120 campaigns are few for a correlation, and campaigns differ in channel and
--      timing. The correlation weights every campaign equally; the lead-weighted view is 5b.
--      Synthetic data (G6), association only (G5).
--    Checks: every value [D5]; the overall High share and 120 campaigns also follow from [P3] /
--      [K] (78,577 / 261,684).
-- -----------------------------------------------------------------------------
WITH leads AS (
  SELECT CAMPAIGN_ID, IS_CONVERTED,
         CASE WHEN LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
              WHEN LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
              WHEN LEAD_SCORE BETWEEN 71 AND 100 THEN 'High' END AS SEGMENT
  FROM FCT_LEAD_CONVERSIONS
),
segment_rates AS (          -- all-lead conversion counts per segment
  SELECT SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS FROM leads GROUP BY SEGMENT
),
by_campaign AS (            -- lead -> campaign x segment -> campaign (aggregate first, G1)
  SELECT c.CAMPAIGN_ID, SUM(c.LEADS) AS LEADS, SUM(IFF(c.SEGMENT = 'High', c.LEADS, 0)) AS HIGH_LEADS,
         SUM(c.CONVERTED_LEADS) AS CONVERTED_LEADS,
         SUM((c.LEADS * s.CONVERTED_LEADS)::NUMBER(32,18) / s.LEADS) AS MIX_EXPECTED_CONVERTED
  FROM (SELECT CAMPAIGN_ID, SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED_LEADS
        FROM leads GROUP BY CAMPAIGN_ID, SEGMENT) c
  JOIN segment_rates s ON s.SEGMENT = c.SEGMENT                                  -- n:1
  GROUP BY c.CAMPAIGN_ID
),
overall AS (
  SELECT SUM(HIGH_LEADS)::NUMBER(32,18) / SUM(LEADS) AS SHARE, SUM(HIGH_LEADS)::FLOAT / SUM(LEADS) AS SHARE_F
  FROM by_campaign
),
ranked AS (
  SELECT b.*, o.SHARE_F,
         b.HIGH_LEADS::NUMBER(32,18)      / b.LEADS AS HIGH_SHARE_EXACT,
         b.CONVERTED_LEADS::NUMBER(32,18) / b.LEADS AS CONVERSION_RATE_EXACT,
         b.MIX_EXPECTED_CONVERTED         / b.LEADS AS MIX_EXPECTED_RATE_EXACT,
         ROW_NUMBER() OVER (ORDER BY b.HIGH_LEADS::NUMBER(32,18) / b.LEADS DESC, b.CAMPAIGN_ID) AS ROW_NUM,
         RANK()       OVER (ORDER BY b.HIGH_LEADS::NUMBER(32,18) / b.LEADS DESC)                AS RNK,
         COUNT(*)     OVER ()                                                                     AS CAMPAIGNS,
         b.LEADS::FLOAT AS N, b.HIGH_LEADS::FLOAT / b.LEADS AS P, 1.959964::FLOAT AS Z
  FROM by_campaign b
  CROSS JOIN overall o
),
bounds AS (
  SELECT r.*,
         (P + Z * Z / (2 * N) - Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N) AS CI_LOW,
         (P + Z * Z / (2 * N) + Z * SQRT(P * (1 - P) / N + Z * Z / (4 * N * N))) / (1 + Z * Z / N) AS CI_HIGH,
         POWER(HIGH_LEADS - N * SHARE_F, 2) / (N * SHARE_F * (1 - SHARE_F))                      AS X2_CONTRIBUTION
  FROM ranked r
),
summary AS (
  SELECT MAX(CAMPAIGNS) AS CAMPAIGNS, COUNT_IF(ROW_NUM <> RNK) AS TIED,
         MIN(HIGH_SHARE_EXACT) AS MIN_SHARE, MAX(HIGH_SHARE_EXACT) AS MAX_SHARE,
         COUNT_IF(CI_LOW > SHARE_F) AS ABOVE, COUNT_IF(CI_HIGH < SHARE_F) AS BELOW,
         SUM(X2_CONTRIBUTION) AS X2,
         CORR(HIGH_SHARE_EXACT, CONVERSION_RATE_EXACT) AS R,
         CORR(HIGH_SHARE_EXACT, MIX_EXPECTED_RATE_EXACT) AS R_MIX,                     -- score mix only
         STDDEV_SAMP(MIX_EXPECTED_RATE_EXACT::FLOAT) AS SD_MIX,
         STDDEV_SAMP(CONVERSION_RATE_EXACT::FLOAT)   AS SD_CR,
         COVAR_SAMP(HIGH_SHARE_EXACT::FLOAT, MIX_EXPECTED_RATE_EXACT::FLOAT)
           / (STDDEV_SAMP(HIGH_SHARE_EXACT::FLOAT) * STDDEV_SAMP(CONVERSION_RATE_EXACT::FLOAT)) AS R_IMPLIED,
         AVG(IFF(ROW_NUM <= 10, LEADS, NULL)) AS AVG_LEADS_TOP10,
         AVG(IFF(ROW_NUM > CAMPAIGNS - 5, LEADS, NULL)) AS AVG_LEADS_BOTTOM5,
         MEDIAN(LEADS) AS MEDIAN_LEADS
  FROM bounds
),
checks (ORD, CHECK_NAME, ACTUAL, EXPECTED) AS (
  SELECT  1, 'campaigns ranked',                        CAMPAIGNS,                       120       FROM summary UNION ALL
  SELECT  2, 'campaigns tied on High share',            TIED,                            0         FROM summary UNION ALL
  SELECT  3, 'lowest High share',                       ROUND(MIN_SHARE, 6),             0.253752  FROM summary UNION ALL
  SELECT  4, 'highest High share',                      ROUND(MAX_SHARE, 6),             0.338323  FROM summary UNION ALL
  SELECT  5, 'High share, all leads',                   ROUND(SHARE, 6),                 0.300274  FROM overall UNION ALL
  SELECT  6, 'Wilson CI above the all-lead share',      ABOVE,                           4         FROM summary UNION ALL
  SELECT  7, 'Wilson CI below the all-lead share',      BELOW,                           5         FROM summary UNION ALL
  SELECT  8, 'X2 campaign x High (df 119)',             ROUND(X2, 4)::NUMBER(18,4),      153.3869  FROM summary UNION ALL
  SELECT  9, 'X2 above critical 145.461 (1 = yes)',     IFF(X2 > 145.461, 1, 0),         1         FROM summary UNION ALL
  SELECT 10, 'CORR(High share, conversion rate)',       ROUND(R, 6)::NUMBER(18,6),       -0.071858 FROM summary UNION ALL
  SELECT 11, 'CORR(High share, mix-expected rate)',     ROUND(R_MIX, 6)::NUMBER(18,6),   0.842855  FROM summary UNION ALL
  SELECT 12, 'STDDEV_SAMP, mix-expected rates',         ROUND(SD_MIX, 6)::NUMBER(18,6),  0.001642  FROM summary UNION ALL
  SELECT 13, 'STDDEV_SAMP, conversion rates',           ROUND(SD_CR, 6)::NUMBER(18,6),   0.009471  FROM summary UNION ALL
  SELECT 14, 'CORR implied by the score mix alone',     ROUND(R_IMPLIED, 6)::NUMBER(18,6), 0.146086 FROM summary UNION ALL
  SELECT 15, 'avg leads, top-10 campaigns',             ROUND(AVG_LEADS_TOP10, 2),       1408.30   FROM summary UNION ALL
  SELECT 16, 'avg leads, bottom-5 campaigns',           ROUND(AVG_LEADS_BOTTOM5, 2),     850.80    FROM summary UNION ALL
  SELECT 17, 'median leads, all campaigns',             MEDIAN_LEADS,                    1947.50   FROM summary
)
SELECT CHECK_NAME, ACTUAL::NUMBER(38,6) AS ACTUAL, EXPECTED::NUMBER(38,6) AS EXPECTED,
       IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM checks
ORDER BY ORD;
