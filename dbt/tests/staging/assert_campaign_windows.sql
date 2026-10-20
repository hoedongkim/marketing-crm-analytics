{#-
    The time logic MART builds on:
    - every campaign has exactly one spend row per window day (spend rows = distinct spend
      dates = CAMPAIGN_DAYS), which is what makes BUDGET / CAMPAIGN_DAYS a valid daily share;
    - no spend row and no lead falls outside its campaign window;
    - every conversion lands 0 to 21 days after its lead (the post-window of the activity spine).
    Returns one row per violating campaign, spend row, lead or conversion.
-#}
WITH spend_vs_window AS (
  SELECT c.CAMPAIGN_ID, c.CAMPAIGN_DAYS, COUNT(s.SPEND_ID) AS SPEND_ROWS, COUNT(DISTINCT s.SPEND_DATE) AS SPEND_DATES
  FROM {{ ref('stg_campaigns') }} c
  LEFT JOIN {{ ref('stg_daily_spend') }} s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
  GROUP BY c.CAMPAIGN_ID, c.CAMPAIGN_DAYS
)
SELECT 'campaign: spend rows <> CAMPAIGN_DAYS' AS PROBLEM, CAMPAIGN_ID AS ROW_KEY
FROM spend_vs_window
WHERE SPEND_ROWS <> CAMPAIGN_DAYS OR SPEND_DATES <> CAMPAIGN_DAYS
UNION ALL
SELECT 'spend row outside the campaign window', s.SPEND_ID
FROM {{ ref('stg_daily_spend') }} s
JOIN {{ ref('stg_campaigns') }} c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID
WHERE s.SPEND_DATE NOT BETWEEN c.START_DATE AND c.END_DATE
UNION ALL
SELECT 'lead outside the campaign window', l.LEAD_ID
FROM {{ ref('stg_leads') }} l
JOIN {{ ref('stg_campaigns') }} c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
WHERE l.CREATED_DATE NOT BETWEEN c.START_DATE AND c.END_DATE
UNION ALL
SELECT 'conversion not 0..{{ var("post_window_days") }} days after its lead', v.CONVERSION_ID
FROM {{ ref('stg_conversions') }} v
JOIN {{ ref('stg_leads') }} l ON l.LEAD_ID = v.LEAD_ID
WHERE DATEDIFF('day', l.CREATED_DATE, v.CONVERTED_DATE) NOT BETWEEN 0 AND {{ var('post_window_days') }}
