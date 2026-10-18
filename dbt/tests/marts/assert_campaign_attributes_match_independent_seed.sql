{#-
    Every campaign attribute in MART equals the independent per-campaign baseline (seed
    expected_campaign_kpi: CHANNEL and OBJECTIVE read from campaigns.csv by
    scripts/independent_check.py, no Snowflake, no SQL under test):
      - DIM_CAMPAIGN, the canonical channel dimension, in both directions (a campaign missing
        from the dimension fails too);
      - every row of the three facts that carry the attributes: FCT_DAILY_SPEND and
        FCT_CAMPAIGN_DAILY_ACTIVITY (which copy them from DIM_CAMPAIGN) and FCT_LEAD_CONVERSIONS
        (which takes them from stg_campaigns through int_lead_conversions).
    Comparing with the seed, not with DIM_CAMPAIGN, keeps the check independent of the models:
    re-joining DIM_CAMPAIGN on the key that the facts were built from could not fail. Together
    the branches also prove the column comments "from DIM_CAMPAIGN" (fact = seed = dimension).
    A fact row whose campaign is unknown (NULL attributes, or a key the seed lacks) fails.
    The facts are reduced to their distinct (campaign, channel, objective) combinations first;
    returns one row per wrong combination, with the number of rows that carry it.
-#}
{%- set models = ['dim_campaign', 'fct_daily_spend', 'fct_lead_conversions', 'fct_campaign_daily_activity'] -%}
WITH expected AS (
  SELECT CAMPAIGN_ID, CHANNEL, OBJECTIVE FROM {{ ref('expected_campaign_kpi') }}
),
attributes AS (   -- each model's distinct (campaign, channel, objective) combinations
{%- for model_name in models %}
  {{ 'SELECT' if loop.first else 'UNION ALL SELECT' }} '{{ model_name }}' AS MODEL_NAME, CAMPAIGN_ID, CHANNEL, OBJECTIVE, COUNT(*) AS N_ROWS
  FROM {{ ref(model_name) }}
  GROUP BY CAMPAIGN_ID, CHANNEL, OBJECTIVE
{%- endfor %}
)
SELECT a.MODEL_NAME, a.CAMPAIGN_ID, a.CHANNEL, a.OBJECTIVE, a.N_ROWS,
       e.CHANNEL AS EXPECTED_CHANNEL, e.OBJECTIVE AS EXPECTED_OBJECTIVE
FROM attributes a
LEFT JOIN expected e ON e.CAMPAIGN_ID = a.CAMPAIGN_ID
WHERE e.CAMPAIGN_ID IS NULL
   OR NOT (EQUAL_NULL(a.CHANNEL, e.CHANNEL) AND EQUAL_NULL(a.OBJECTIVE, e.OBJECTIVE))
UNION ALL
SELECT 'dim_campaign: campaign missing', e.CAMPAIGN_ID, NULL, NULL, 0, e.CHANNEL, e.OBJECTIVE
FROM expected e
LEFT JOIN {{ ref('dim_campaign') }} d ON d.CAMPAIGN_ID = e.CAMPAIGN_ID
WHERE d.CAMPAIGN_ID IS NULL
