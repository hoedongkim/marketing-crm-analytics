{#-
    FCT_CAMPAIGN_DAILY_ACTIVITY: one row per campaign per day, START_DATE .. END_DATE + 21
    (13,760 rows: 11,240 flight days + 120 x 21 post-flight days), the activity fact. Ported from
    sql/02c_analysis_marts.sql block 1.
      STEP 1  the spine: DIM_CAMPAIGN x DIM_DATE, each campaign joined to the dates of
              START_DATE .. LEAST(END_DATE + post_window_days, coverage_end). DATE_DAY is unique
              in DIM_DATE, so each (campaign, date) appears once.
      STEP 2  each input aggregated to campaign x date ON ITS OWN: spend by SPEND_DATE, leads by
              CREATED_DATE, conversions (under the campaign of their lead) by CONVERTED_DATE.
      STEP 3  LEFT JOIN each to the spine 1:1; COALESCE turns a day without activity into 0.
    The 4,716 conversions that land after their campaign ended sit on IS_IN_FLIGHT = 0 rows; a
    fact keyed on spend rows would drop them. Vars: post_window_days (21, the observed maximum
    lag) and coverage_end (2025-12-31; the latest END_DATE + 21 is 2025-12-23, nothing is clipped).
-#}
WITH params AS (            -- the two documented bounds of the spine, in one place
  SELECT {{ var('post_window_days') }} AS POST_WINDOW_DAYS,              -- observed maximum lag (0..21 days)
         '{{ var("coverage_end") }}'::DATE AS COVERAGE_END   -- documented coverage end = last DIM_DATE day
),
spine AS (                  -- STEP 1: one row per campaign x day of START_DATE .. END_DATE + 21
  SELECT c.CAMPAIGN_ID, c.CHANNEL, c.OBJECTIVE,
         d.DATE_DAY    AS ACTIVITY_DATE,
         d.MONTH_START AS ACTIVITY_MONTH,
         IFF(d.DATE_DAY BETWEEN c.START_DATE AND c.END_DATE, 1, 0) AS IS_IN_FLIGHT
  FROM {{ ref('dim_campaign') }} c
  CROSS JOIN params p                                                   -- one row
  JOIN {{ ref('dim_date') }} d                                          -- a dimension, unique on DATE_DAY
    ON d.DATE_DAY BETWEEN c.START_DATE
                      AND LEAST(DATEADD('day', p.POST_WINDOW_DAYS, c.END_DATE), p.COVERAGE_END)
),
spend_by_day AS (           -- STEP 2a: delivery and budget, campaign x spend date
  SELECT CAMPAIGN_ID, SPEND_DATE AS ACTIVITY_DATE,
         SUM(IMPRESSIONS)     AS IMPRESSIONS,
         SUM(CLICKS)          AS CLICKS,
         SUM(SPEND)           AS SPEND,
         SUM(BUDGET_PRORATED) AS BUDGET_PRORATED
  FROM {{ ref('fct_daily_spend') }}
  GROUP BY CAMPAIGN_ID, SPEND_DATE
),
leads_by_day AS (           -- STEP 2b: leads, campaign x created date
  SELECT CAMPAIGN_ID, CREATED_DATE AS ACTIVITY_DATE,
         COUNT(*) AS LEADS
  FROM {{ ref('fct_lead_conversions') }}
  GROUP BY CAMPAIGN_ID, CREATED_DATE
),
conversions_by_day AS (     -- STEP 2c: conversions, campaign (of the lead) x converted date
  SELECT CAMPAIGN_ID, CONVERTED_DATE AS ACTIVITY_DATE,
         COUNT(*)         AS CONVERSIONS,
         SUM(IS_TRIAL)    AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES,
         SUM(REVENUE)     AS REVENUE
  FROM {{ ref('fct_lead_conversions') }}
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
ORDER BY s.ACTIVITY_DATE, s.CAMPAIGN_ID
