{#-
    Every campaign of MART_CAMPAIGN_PERFORMANCE equals the independent per-campaign baseline
    (seed expected_campaign_kpi: Python csv + decimal from the CSV files) in every base column:
    channel, objective, budget, spend days, spend, impressions, clicks, leads, converted leads,
    trials, purchases, revenue.
    FULL OUTER JOIN: a campaign missing on either side is its own failing row. Returns one row
    per campaign with at least one differing column, naming the columns.
-#}
{%- set columns = ['channel', 'objective', 'budget', 'spend_days', 'spend', 'impressions', 'clicks',
                   'leads', 'converted_leads', 'trials', 'purchases', 'revenue'] -%}
WITH compared AS (
  SELECT COALESCE(m.CAMPAIGN_ID, e.CAMPAIGN_ID) AS CAMPAIGN_ID,
         m.CAMPAIGN_ID IS NULL AS MISSING_IN_MART,
         e.CAMPAIGN_ID IS NULL AS MISSING_IN_SEED,
         ARRAY_CONSTRUCT_COMPACT(
         {%- for c in columns %}
           IFF(EQUAL_NULL(m.{{ c }}, e.{{ c }}), NULL, '{{ c }}'){{ ',' if not loop.last }}
         {%- endfor %}
         ) AS DIFFERING_COLUMNS
  FROM {{ ref('mart_campaign_performance') }} m
  FULL OUTER JOIN {{ ref('expected_campaign_kpi') }} e ON e.CAMPAIGN_ID = m.CAMPAIGN_ID
)
SELECT *
FROM compared
WHERE MISSING_IN_MART OR MISSING_IN_SEED OR ARRAY_SIZE(DIFFERING_COLUMNS) > 0
