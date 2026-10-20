{#-
    FCT_DAILY_SPEND: one row per campaign per active day (11,240 rows), the delivery fact.
    - Each spend row looks up its ONE campaign row in DIM_CAMPAIGN (n:1): the row count stays
      11,240 and no measure is repeated. The LEFT JOIN keeps a spend row even if its campaign
      were missing (CHANNEL would be NULL and the tests fail), so spend never disappears.
    - BUDGET_PRORATED = BUDGET / CAMPAIGN_DAYS instead of BUDGET: the campaign budget repeated on
      every daily row would be counted once per window day by SUM (the grain trap). The dividend
      is cast to NUMBER(32,18) so the 6-dp ROUND is the only rounding (why: the "Rounding" note
      of the earlier plain-SQL version,
      https://github.com/hoedongkim/marketing-crm-analytics/blob/dbe41f7/sql/02b_core_models.sql#L100-L117).
-#}
SELECT s.SPEND_ID,
       s.CAMPAIGN_ID,
       s.SPEND_DATE,
       DATE_TRUNC('month', s.SPEND_DATE)                     AS SPEND_MONTH,       -- activity month
       c.CHANNEL,                                                                  -- n:1 from DIM_CAMPAIGN
       c.OBJECTIVE,
       s.IMPRESSIONS,
       s.CLICKS,
       s.SPEND,
       ROUND(c.BUDGET::NUMBER(32,18) / NULLIF(c.CAMPAIGN_DAYS, 0), 6)::NUMBER(18,6) AS BUDGET_PRORATED
FROM {{ ref('stg_daily_spend') }} s
LEFT JOIN {{ ref('dim_campaign') }} c
       ON c.CAMPAIGN_ID = s.CAMPAIGN_ID      -- many spend rows -> one campaign: no fan-out
ORDER BY s.SPEND_DATE, s.CAMPAIGN_ID
