{#-
    The activity spine of FCT_CAMPAIGN_DAILY_ACTIVITY (START_DATE .. END_DATE + 21):
    - it has exactly the independent number of rows (seed activity_spine_rows, 13,760), of which
      the in-flight rows are the spend rows (seed spend_rows, 11,240);
    - the conversions after a campaign ended land on IS_IN_FLIGHT = 0 rows: their count and
      revenue equal the independent values (seed conversions_after_campaign_end 4,716 and
      revenue_after_campaign_end 2,532,266.74), and FCT_LEAD_CONVERSIONS flags the same 4,716;
    - no lag exceeds the spine's 21 days (seed max_days_to_convert), so no conversion falls off.
    Returns one row per failed check.
-#}
WITH activity AS (
  SELECT COUNT(*)                                  AS SPINE_ROWS,
         SUM(IS_IN_FLIGHT)                         AS FLIGHT_ROWS,
         SUM(IFF(IS_IN_FLIGHT = 0, CONVERSIONS, 0)) AS POST_FLIGHT_CONVERSIONS,
         SUM(IFF(IS_IN_FLIGHT = 0, REVENUE, 0))     AS POST_FLIGHT_REVENUE
  FROM {{ ref('fct_campaign_daily_activity') }}
),
leads AS (
  SELECT SUM(CONVERTED_AFTER_CAMPAIGN_END) AS FLAGGED_AFTER_END, MAX(DAYS_TO_CONVERT) AS MAX_LAG
  FROM {{ ref('fct_lead_conversions') }}
),
expected AS (
  SELECT METRIC, VALUE FROM {{ ref('expected_totals') }}
),
checks AS (
            SELECT 'activity_spine_rows' AS METRIC, (SELECT SPINE_ROWS FROM activity) AS ACTUAL
  UNION ALL SELECT 'spend_rows',                     (SELECT FLIGHT_ROWS FROM activity)
  UNION ALL SELECT 'conversions_after_campaign_end', (SELECT POST_FLIGHT_CONVERSIONS FROM activity)
  UNION ALL SELECT 'revenue_after_campaign_end',     (SELECT POST_FLIGHT_REVENUE FROM activity)
  UNION ALL SELECT 'conversions_after_campaign_end', (SELECT FLAGGED_AFTER_END FROM leads)
  UNION ALL SELECT 'max_days_to_convert',            (SELECT MAX_LAG FROM leads)
)
SELECT c.METRIC, c.ACTUAL, e.VALUE AS EXPECTED
FROM checks c
LEFT JOIN expected e ON e.METRIC = c.METRIC
WHERE c.ACTUAL IS DISTINCT FROM e.VALUE
