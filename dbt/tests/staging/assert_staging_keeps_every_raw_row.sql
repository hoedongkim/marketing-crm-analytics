{#-
    STAGING flags problems instead of dropping rows, and the clean release has no duplicates, so
    each clean view has exactly one row per RAW row (120 / 11,240 / 261,684 / 39,696; the
    independent counts of seed expected_totals). The dbt port of
    sql/02_data_cleaning_tests.sql block 3. Returns one row per view whose count differs.
-#}
WITH counts AS (
            SELECT 'stg_campaigns' AS MODEL_NAME, 'campaigns' AS METRIC,
                   (SELECT COUNT(*) FROM {{ ref('stg_campaigns') }}) AS STG_ROWS,
                   (SELECT COUNT(*) FROM {{ source('raw', 'campaigns') }}) AS RAW_ROWS
  UNION ALL SELECT 'stg_daily_spend', 'spend_rows',
                   (SELECT COUNT(*) FROM {{ ref('stg_daily_spend') }}), (SELECT COUNT(*) FROM {{ source('raw', 'daily_spend') }})
  UNION ALL SELECT 'stg_leads', 'leads',
                   (SELECT COUNT(*) FROM {{ ref('stg_leads') }}), (SELECT COUNT(*) FROM {{ source('raw', 'leads') }})
  UNION ALL SELECT 'stg_conversions', 'converted_leads',
                   (SELECT COUNT(*) FROM {{ ref('stg_conversions') }}), (SELECT COUNT(*) FROM {{ source('raw', 'conversions') }})
)
SELECT c.MODEL_NAME, c.STG_ROWS, c.RAW_ROWS, e.VALUE AS EXPECTED
FROM counts c
LEFT JOIN {{ ref('expected_totals') }} e ON e.METRIC = c.METRIC
WHERE c.STG_ROWS IS DISTINCT FROM e.VALUE OR c.RAW_ROWS IS DISTINCT FROM e.VALUE
