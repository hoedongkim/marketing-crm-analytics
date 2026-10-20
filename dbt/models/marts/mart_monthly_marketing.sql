{#-
    MART_MONTHLY_MARKETING: one row per channel x month, ACTIVITY basis (36 months x 5 channels
    = 180 rows).
    - The spine is every month of DIM_DATE x every channel of DIM_CAMPAIGN (two small
      dimensions, not facts), so a channel-month without activity shows as 0.
    - The measures are the daily activity fact rolled up to channel x month in one CTE, then
      joined 1:1 to the spine: each daily row has one campaign, one channel and one month.
    - ACTIVE_CAMPAIGNS: campaigns with at least one in-flight day in the month (distinct count);
      additive across channels within a month, NOT across months.
    No ratio columns: CONVERSIONS / LEADS of the same month is not a conversion rate (that is
    MART_MONTHLY_COHORT).
-#}
WITH month_channel AS (     -- the spine: 36 months x 5 channels, so empty channel-months show as 0
  SELECT m.MONTH_START, ch.CHANNEL
  FROM (SELECT DISTINCT MONTH_START FROM {{ ref('dim_date') }}) m
  CROSS JOIN (SELECT DISTINCT CHANNEL FROM {{ ref('dim_campaign') }}) ch
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
  FROM {{ ref('fct_campaign_daily_activity') }}
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
ORDER BY s.MONTH_START, s.CHANNEL
