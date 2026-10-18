{#-
    DIM_DATE is the gap-free calendar of the documented coverage: as many rows and weekend days
    as the independent calendar (seed calendar_days 1,096 and calendar_weekend_days 313, Python
    datetime), first day 2023-01-01 and last day 2025-12-31, no gap (distinct days = span), and
    WEEK_START always a Monday. Returns one row per failed check.
    The two bounds are literals, the dataset's documented coverage (data/README.md), on purpose
    NOT the vars coverage_start / coverage_end that dim_date.sql is built from: a test that read
    the same vars would pass whatever they were set to. Changing the coverage therefore means
    changing this test and scripts/independent_check.py too.
-#}
WITH d AS (
  SELECT COUNT(*) AS N_DAYS, COUNT(DISTINCT DATE_DAY) AS N_DISTINCT,
         MIN(DATE_DAY) AS FIRST_DAY, MAX(DATE_DAY) AS LAST_DAY,
         DATEDIFF('day', MIN(DATE_DAY), MAX(DATE_DAY)) + 1 AS SPAN_DAYS,
         COUNT_IF(IS_WEEKEND) AS N_WEEKEND,
         COUNT_IF(DAYOFWEEKISO(WEEK_START) <> 1) AS NOT_MONDAY_WEEK_STARTS
  FROM {{ ref('dim_date') }}
),
e AS (
  SELECT MAX(IFF(METRIC = 'calendar_days', VALUE, NULL)) AS N_DAYS,
         MAX(IFF(METRIC = 'calendar_weekend_days', VALUE, NULL)) AS N_WEEKEND
  FROM {{ ref('expected_totals') }}
)
SELECT 'rows = independent calendar days' AS CHECK_NAME, d.N_DAYS::VARCHAR AS ACTUAL, e.N_DAYS::VARCHAR AS EXPECTED
FROM d, e WHERE d.N_DAYS IS DISTINCT FROM e.N_DAYS
UNION ALL
SELECT 'weekend days = independent count', d.N_WEEKEND::VARCHAR, e.N_WEEKEND::VARCHAR
FROM d, e WHERE d.N_WEEKEND IS DISTINCT FROM e.N_WEEKEND
UNION ALL
SELECT 'first day = documented coverage start', d.FIRST_DAY::VARCHAR, '2023-01-01'
FROM d WHERE d.FIRST_DAY IS DISTINCT FROM '2023-01-01'::DATE
UNION ALL
SELECT 'last day = documented coverage end', d.LAST_DAY::VARCHAR, '2025-12-31'
FROM d WHERE d.LAST_DAY IS DISTINCT FROM '2025-12-31'::DATE
UNION ALL
SELECT 'gap-free: distinct days = rows = span', d.N_DISTINCT || ' / ' || d.N_DAYS || ' / ' || d.SPAN_DAYS, 'all equal'
FROM d WHERE NOT (d.N_DISTINCT = d.N_DAYS AND d.N_DAYS = d.SPAN_DAYS)
UNION ALL
SELECT 'WEEK_START is a Monday', d.NOT_MONDAY_WEEK_STARTS::VARCHAR, '0'
FROM d WHERE d.NOT_MONDAY_WEEK_STARTS <> 0
