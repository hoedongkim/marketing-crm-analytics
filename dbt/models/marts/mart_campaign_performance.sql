{#-
    MART_CAMPAIGN_PERFORMANCE: one row per campaign (120 rows), every funnel base and the
    campaign KPIs, built with the plan's grain-safe pattern:
      STEP 1  aggregate each fact ON ITS OWN to one row per campaign (spend, leads, and
              conversions via their lead: conversions JOIN leads ON LEAD_ID is 1:1, so it only
              adds the campaign);
      STEP 2  join the three campaign-grain results 1:1 to DIM_CAMPAIGN (COALESCE: a campaign
              without leads gets LEADS 0 and keeps its spend);
      STEP 3  ratios of the campaign sums, NULLIF(denominator, 0) so a zero denominator gives
              NULL, never an error or a fake 0; each dividend cast to NUMBER(32,18) so ROUND is
              the only rounding (rates and ROAS 6 dp, cost per unit 4 dp).
    The anti-pattern this replaces, daily_spend JOIN leads ON campaign_id, inflates spend
    2,495x (4,523,050.02 -> 11,286,380,144.15). Ratio columns are valid at campaign grain only.
-#}
WITH spend_by_campaign AS (          -- STEP 1a: campaign x day -> one row per campaign
  SELECT CAMPAIGN_ID,
         COUNT(*)         AS SPEND_DAYS,
         SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS)      AS CLICKS,
         SUM(SPEND)       AS SPEND
  FROM {{ ref('stg_daily_spend') }}
  GROUP BY CAMPAIGN_ID
),
leads_by_campaign AS (              -- STEP 1b: lead -> one row per campaign
  SELECT CAMPAIGN_ID,
         COUNT(*) AS LEADS
  FROM {{ ref('stg_leads') }}
  GROUP BY CAMPAIGN_ID
),
conversions_by_campaign AS (        -- STEP 1c: converted lead -> one row per campaign (the lead join is 1:1)
  SELECT l.CAMPAIGN_ID,
         COUNT(*)                                  AS CONVERTED_LEADS,
         COUNT_IF(v.CONVERSION_TYPE = 'trial')     AS TRIALS,
         COUNT_IF(v.CONVERSION_TYPE = 'purchase')  AS PURCHASES,
         SUM(v.REVENUE)                            AS REVENUE
  FROM {{ ref('stg_conversions') }} v
  JOIN {{ ref('stg_leads') }} l ON l.LEAD_ID = v.LEAD_ID   -- 1:1: only adds the campaign
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
  FROM {{ ref('dim_campaign') }} d
  LEFT JOIN spend_by_campaign       s ON s.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
  LEFT JOIN leads_by_campaign       l ON l.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
  LEFT JOIN conversions_by_campaign v ON v.CAMPAIGN_ID = d.CAMPAIGN_ID   -- 1:1
)
SELECT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, CAMPAIGN_DAYS,
       START_YEAR, START_MONTH,
       BUDGET, SPEND_DAYS, IMPRESSIONS, CLICKS, SPEND, LEADS, CONVERTED_LEADS, TRIALS, PURCHASES, REVENUE,
       -- STEP 3: campaign-grain ratios of the sums above; NULL (not an error) when a denominator is 0.
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
ORDER BY CAMPAIGN_ID
