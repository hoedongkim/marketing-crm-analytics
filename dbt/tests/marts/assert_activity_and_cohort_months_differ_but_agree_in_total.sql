{#-
    The two time bases (architecture decision 7): MART_MONTHLY_MARKETING counts a conversion in
    the month it happened (activity), MART_MONTHLY_COHORT in the month its lead was created
    (cohort). Both must add up to the same 39,696 converted leads (seed converted_leads), but they
    must DIFFER month by month, because 13,675 conversions (seed conversions_later_month) land in
    a later month than their lead. Equal monthly series would mean that one table was built on
    the wrong date. Returns one row per failed check.
-#}
WITH activity AS (
  SELECT MONTH_START, SUM(CONVERSIONS) AS CONVERSIONS
  FROM {{ ref('mart_monthly_marketing') }}
  GROUP BY MONTH_START
),
cohort AS (
  SELECT COHORT_MONTH, SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(CONVERTED_LATER_MONTH) AS CONVERTED_LATER_MONTH
  FROM {{ ref('mart_monthly_cohort') }}
  GROUP BY COHORT_MONTH
),
months AS (
  SELECT COALESCE(a.MONTH_START, c.COHORT_MONTH) AS MONTH_START, a.CONVERSIONS, c.CONVERTED_LEADS, c.CONVERTED_LATER_MONTH
  FROM activity a
  FULL OUTER JOIN cohort c ON c.COHORT_MONTH = a.MONTH_START
),
expected AS (
  SELECT MAX(IFF(METRIC = 'converted_leads', VALUE, NULL))         AS CONVERTED_LEADS,
         MAX(IFF(METRIC = 'conversions_later_month', VALUE, NULL)) AS CONVERSIONS_LATER_MONTH
  FROM {{ ref('expected_totals') }}
),
checks AS (
  SELECT 'activity conversions = independent total' AS CHECK_NAME,
         (SELECT SUM(CONVERSIONS) FROM months) AS ACTUAL, (SELECT CONVERTED_LEADS FROM expected) AS EXPECTED
  UNION ALL
  SELECT 'cohort converted leads = independent total',
         (SELECT SUM(CONVERTED_LEADS) FROM months), (SELECT CONVERTED_LEADS FROM expected)
  UNION ALL
  SELECT 'cohort conversions landing in a later month = independent count',
         (SELECT SUM(CONVERTED_LATER_MONTH) FROM months), (SELECT CONVERSIONS_LATER_MONTH FROM expected)
  UNION ALL
  SELECT 'months present in both tables (36)',
         (SELECT COUNT_IF(CONVERSIONS IS NOT NULL AND CONVERTED_LEADS IS NOT NULL) FROM months), 36
)
SELECT CHECK_NAME, ACTUAL, EXPECTED
FROM checks
WHERE ACTUAL IS DISTINCT FROM EXPECTED
UNION ALL
SELECT 'activity and cohort series must differ in some month', COUNT_IF(CONVERSIONS <> CONVERTED_LEADS), NULL
FROM months
HAVING COUNT_IF(CONVERSIONS <> CONVERTED_LEADS) = 0
