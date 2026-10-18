{#-
    BUDGET_PRORATED (campaign BUDGET / CAMPAIGN_DAYS, rounded once to 6 dp per spend row):
    - its table total is the independent value 5,418,642.159820 (seed budget_prorated: the same
      rounding done per spend row in Python decimal) in all three tables that carry it;
    - it sums back to each campaign's budget within 0.01 (the contract tolerance: at most
      150 days x 0.0000005 of rounding per campaign), budget taken from the independent
      seed expected_campaign_kpi, not from the model.
    Returns one row per failed check.
-#}
WITH expected AS (
  SELECT VALUE AS BUDGET_PRORATED FROM {{ ref('expected_totals') }} WHERE METRIC = 'budget_prorated'
),
totals AS (
            SELECT 'fct_daily_spend' AS MODEL_NAME, SUM(BUDGET_PRORATED) AS TOTAL FROM {{ ref('fct_daily_spend') }}
  UNION ALL SELECT 'fct_campaign_daily_activity', SUM(BUDGET_PRORATED) FROM {{ ref('fct_campaign_daily_activity') }}
  UNION ALL SELECT 'mart_monthly_marketing',      SUM(BUDGET_PRORATED) FROM {{ ref('mart_monthly_marketing') }}
),
per_campaign AS (
  SELECT e.CAMPAIGN_ID, e.BUDGET, SUM(f.BUDGET_PRORATED) AS PRORATED_SUM
  FROM {{ ref('expected_campaign_kpi') }} e
  LEFT JOIN {{ ref('fct_daily_spend') }} f ON f.CAMPAIGN_ID = e.CAMPAIGN_ID
  GROUP BY e.CAMPAIGN_ID, e.BUDGET
)
SELECT 'table total: ' || t.MODEL_NAME AS CHECK_NAME, t.TOTAL AS ACTUAL, x.BUDGET_PRORATED AS EXPECTED
FROM totals t
LEFT JOIN expected x ON TRUE
WHERE t.TOTAL IS DISTINCT FROM x.BUDGET_PRORATED
UNION ALL
SELECT 'campaign sums back to its budget within 0.01: ' || CAMPAIGN_ID, PRORATED_SUM, BUDGET
FROM per_campaign
WHERE PRORATED_SUM IS NULL OR ABS(PRORATED_SUM - BUDGET) > 0.01
