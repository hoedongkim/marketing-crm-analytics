{#-
    No fan-out: total spend is the independent total (4,523,050.02, seed expected_totals) in
    every model that carries spend. A join that repeated a spend row (the grain trap: a naive
    daily_spend x leads join inflates spend 2,495x) changes the total here.
    Returns one row per model whose total differs; a missing seed value fails every row
    (LEFT JOIN, IS DISTINCT FROM), so the test cannot pass vacuously.
-#}
WITH expected AS (
  SELECT VALUE AS EXPECTED_SPEND FROM {{ ref('expected_totals') }} WHERE METRIC = 'spend'
),
actual AS (
            SELECT 'stg_daily_spend' AS MODEL_NAME, SUM(SPEND) AS TOTAL_SPEND FROM {{ ref('stg_daily_spend') }}
  UNION ALL SELECT 'fct_daily_spend',             SUM(SPEND) FROM {{ ref('fct_daily_spend') }}
  UNION ALL SELECT 'mart_campaign_performance',   SUM(SPEND) FROM {{ ref('mart_campaign_performance') }}
  UNION ALL SELECT 'fct_campaign_daily_activity', SUM(SPEND) FROM {{ ref('fct_campaign_daily_activity') }}
  UNION ALL SELECT 'mart_monthly_marketing',      SUM(SPEND) FROM {{ ref('mart_monthly_marketing') }}
  UNION ALL SELECT 'mart_channel_performance',    SUM(SPEND) FROM {{ ref('mart_channel_performance') }}
)
SELECT a.MODEL_NAME, a.TOTAL_SPEND, e.EXPECTED_SPEND
FROM actual a
LEFT JOIN expected e ON TRUE
WHERE a.TOTAL_SPEND IS DISTINCT FROM e.EXPECTED_SPEND
