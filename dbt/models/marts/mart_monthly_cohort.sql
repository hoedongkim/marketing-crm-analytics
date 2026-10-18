{#-
    MART_MONTHLY_COHORT: one row per channel x lead cohort month, LEAD-COHORT basis (36 x 5 =
    180 rows). Ported from sql/02c_analysis_marts.sql block 3. For the leads created in each
    month: how many converted (whenever), to what, with what revenue, in the cohort month or a
    later one, the summed lag, and how many have had their full 21-day window by AS_OF_DATE.
    FCT_LEAD_CONVERSIONS aggregated to CREATED_MONTH x CHANNEL in one CTE, then joined 1:1 to the
    same spine as MART_MONTHLY_MARKETING. The cohort conversion rate SUM(CONVERTED_LEADS) /
    SUM(LEADS) stays between 13.9% and 16.9% in every month, while the activity ratio swings from
    8.3% to 93.8%: the two bases are never blended on one date axis.
-#}
WITH month_channel AS (     -- the spine: 36 months x 5 channels
  SELECT m.MONTH_START AS COHORT_MONTH, ch.CHANNEL
  FROM (SELECT DISTINCT MONTH_START FROM {{ ref('dim_date') }}) m
  CROSS JOIN (SELECT DISTINCT CHANNEL FROM {{ ref('dim_campaign') }}) ch
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
  FROM {{ ref('fct_lead_conversions') }}
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
ORDER BY s.COHORT_MONTH, s.CHANNEL
