{#-
    The lead score segments Low 1-40 / Medium 41-70 / High 71-100: leads and converted leads per
    segment equal the independent counts (seed leads_low .. converted_high: 104,245 / 78,862 /
    78,577 leads, 9,505 / 12,758 / 17,433 converted), both in FCT_LEAD_CONVERSIONS
    (LEAD_SCORE_SEGMENT) and in MART_LEAD_QUALITY (10-point bands rolled up to segments).
    Returns one row per (model, metric) that differs, or that is missing on either side.
-#}
WITH fct AS (
  SELECT LOWER(LEAD_SCORE_SEGMENT) AS SEGMENT, COUNT(*) AS LEADS, SUM(IS_CONVERTED) AS CONVERTED
  FROM {{ ref('fct_lead_conversions') }}
  GROUP BY LEAD_SCORE_SEGMENT
),
lq AS (
  SELECT LOWER(LEAD_SCORE_SEGMENT) AS SEGMENT, SUM(LEADS) AS LEADS, SUM(CONVERTED_LEADS) AS CONVERTED
  FROM {{ ref('mart_lead_quality') }}
  GROUP BY LEAD_SCORE_SEGMENT
),
actual AS (
            SELECT 'fct_lead_conversions' AS MODEL_NAME, 'leads_' || SEGMENT AS METRIC, LEADS AS ACTUAL_VALUE FROM fct
  UNION ALL SELECT 'fct_lead_conversions', 'converted_' || SEGMENT, CONVERTED FROM fct
  UNION ALL SELECT 'mart_lead_quality',    'leads_' || SEGMENT, LEADS FROM lq
  UNION ALL SELECT 'mart_lead_quality',    'converted_' || SEGMENT, CONVERTED FROM lq
),
expected AS (
  SELECT m.MODEL_NAME, e.METRIC, e.VALUE
  FROM {{ ref('expected_totals') }} e
  CROSS JOIN (SELECT 'fct_lead_conversions' AS MODEL_NAME UNION ALL SELECT 'mart_lead_quality') m
  WHERE e.METRIC IN ('leads_low', 'leads_medium', 'leads_high', 'converted_low', 'converted_medium', 'converted_high')
)
SELECT COALESCE(a.MODEL_NAME, e.MODEL_NAME) AS MODEL_NAME, COALESCE(a.METRIC, e.METRIC) AS METRIC,
       a.ACTUAL_VALUE, e.VALUE AS EXPECTED_VALUE
FROM actual a
FULL OUTER JOIN expected e ON e.MODEL_NAME = a.MODEL_NAME AND e.METRIC = a.METRIC
WHERE a.ACTUAL_VALUE IS DISTINCT FROM e.VALUE
