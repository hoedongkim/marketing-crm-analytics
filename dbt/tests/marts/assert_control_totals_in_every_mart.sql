{#-
    Every other additive base adds up to its independent total (seed expected_totals,
    scripts/independent_check.py) in every model that carries it: campaigns, budget (whole
    campaigns only), spend rows, impressions, clicks, leads, the sum of lead scores, converted
    leads (conversions), trials, purchases and revenue, and the mature leads of the maturity
    assumption (IS_MATURE; every lead today, so a wrong predicate, e.g. a flipped comparison that
    gives 0 everywhere, fails here). Spend has its own test (assert_total_spend_in_every_mart).
    Returns one row per (model, metric) that differs. A metric missing from the seed gives a
    NULL expected value and fails too (IS DISTINCT FROM), so nothing passes vacuously.
-#}
{%- set checks = [
    ('stg_daily_spend',             'spend_rows',      'COUNT(*)'),
    ('stg_daily_spend',             'impressions',     'SUM(IMPRESSIONS)'),
    ('stg_daily_spend',             'clicks',          'SUM(CLICKS)'),
    ('stg_campaigns',               'campaigns',       'COUNT(*)'),
    ('stg_campaigns',               'budget',          'SUM(BUDGET)'),
    ('stg_leads',                   'leads',           'COUNT(*)'),
    ('stg_leads',                   'sum_lead_score',  'SUM(LEAD_SCORE)'),
    ('stg_conversions',             'converted_leads', 'COUNT(*)'),
    ('stg_conversions',             'revenue',         'SUM(REVENUE)'),
    ('dim_campaign',                'campaigns',       'COUNT(*)'),
    ('dim_campaign',                'budget',          'SUM(BUDGET)'),
    ('fct_daily_spend',             'spend_rows',      'COUNT(*)'),
    ('fct_daily_spend',             'impressions',     'SUM(IMPRESSIONS)'),
    ('fct_daily_spend',             'clicks',          'SUM(CLICKS)'),
    ('fct_lead_conversions',        'leads',           'COUNT(*)'),
    ('fct_lead_conversions',        'sum_lead_score',  'SUM(LEAD_SCORE)'),
    ('fct_lead_conversions',        'converted_leads', 'SUM(IS_CONVERTED)'),
    ('fct_lead_conversions',        'trials',          'SUM(IS_TRIAL)'),
    ('fct_lead_conversions',        'purchases',       'SUM(IS_PURCHASE)'),
    ('fct_lead_conversions',        'revenue',         'SUM(REVENUE)'),
    ('fct_lead_conversions',        'mature_leads',    'SUM(IS_MATURE)'),
    ('mart_campaign_performance',   'campaigns',       'COUNT(*)'),
    ('mart_campaign_performance',   'budget',          'SUM(BUDGET)'),
    ('mart_campaign_performance',   'spend_rows',      'SUM(SPEND_DAYS)'),
    ('mart_campaign_performance',   'impressions',     'SUM(IMPRESSIONS)'),
    ('mart_campaign_performance',   'clicks',          'SUM(CLICKS)'),
    ('mart_campaign_performance',   'leads',           'SUM(LEADS)'),
    ('mart_campaign_performance',   'converted_leads', 'SUM(CONVERTED_LEADS)'),
    ('mart_campaign_performance',   'trials',          'SUM(TRIALS)'),
    ('mart_campaign_performance',   'purchases',       'SUM(PURCHASES)'),
    ('mart_campaign_performance',   'revenue',         'SUM(REVENUE)'),
    ('fct_campaign_daily_activity', 'spend_rows',      'SUM(IS_IN_FLIGHT)'),
    ('fct_campaign_daily_activity', 'impressions',     'SUM(IMPRESSIONS)'),
    ('fct_campaign_daily_activity', 'clicks',          'SUM(CLICKS)'),
    ('fct_campaign_daily_activity', 'leads',           'SUM(LEADS)'),
    ('fct_campaign_daily_activity', 'converted_leads', 'SUM(CONVERSIONS)'),
    ('fct_campaign_daily_activity', 'trials',          'SUM(TRIALS)'),
    ('fct_campaign_daily_activity', 'purchases',       'SUM(PURCHASES)'),
    ('fct_campaign_daily_activity', 'revenue',         'SUM(REVENUE)'),
    ('mart_monthly_marketing',      'impressions',     'SUM(IMPRESSIONS)'),
    ('mart_monthly_marketing',      'clicks',          'SUM(CLICKS)'),
    ('mart_monthly_marketing',      'leads',           'SUM(LEADS)'),
    ('mart_monthly_marketing',      'converted_leads', 'SUM(CONVERSIONS)'),
    ('mart_monthly_marketing',      'trials',          'SUM(TRIALS)'),
    ('mart_monthly_marketing',      'purchases',       'SUM(PURCHASES)'),
    ('mart_monthly_marketing',      'revenue',         'SUM(REVENUE)'),
    ('mart_monthly_cohort',         'leads',           'SUM(LEADS)'),
    ('mart_monthly_cohort',         'converted_leads', 'SUM(CONVERTED_LEADS)'),
    ('mart_monthly_cohort',         'trials',          'SUM(TRIALS)'),
    ('mart_monthly_cohort',         'purchases',       'SUM(PURCHASES)'),
    ('mart_monthly_cohort',         'revenue',         'SUM(REVENUE)'),
    ('mart_monthly_cohort',         'mature_leads',    'SUM(MATURE_LEADS)'),
    ('mart_channel_performance',    'campaigns',       'SUM(CAMPAIGNS)'),
    ('mart_channel_performance',    'budget',          'SUM(BUDGET)'),
    ('mart_channel_performance',    'impressions',     'SUM(IMPRESSIONS)'),
    ('mart_channel_performance',    'clicks',          'SUM(CLICKS)'),
    ('mart_channel_performance',    'leads',           'SUM(LEADS)'),
    ('mart_channel_performance',    'converted_leads', 'SUM(CONVERTED_LEADS)'),
    ('mart_channel_performance',    'trials',          'SUM(TRIALS)'),
    ('mart_channel_performance',    'purchases',       'SUM(PURCHASES)'),
    ('mart_channel_performance',    'revenue',         'SUM(REVENUE)'),
    ('mart_lead_quality',           'leads',           'SUM(LEADS)'),
    ('mart_lead_quality',           'sum_lead_score',  'SUM(SUM_LEAD_SCORE)'),
    ('mart_lead_quality',           'converted_leads', 'SUM(CONVERTED_LEADS)'),
    ('mart_lead_quality',           'trials',          'SUM(TRIALS)'),
    ('mart_lead_quality',           'purchases',       'SUM(PURCHASES)'),
    ('mart_lead_quality',           'revenue',         'SUM(REVENUE)'),
] -%}
WITH actual AS (
{%- for model_name, metric, expression in checks %}
  {{ 'SELECT   ' if loop.first else 'UNION ALL SELECT' }} '{{ model_name }}' AS MODEL_NAME, '{{ metric }}' AS METRIC, {{ expression }} AS ACTUAL_VALUE FROM {{ ref(model_name) }}
{%- endfor %}
),
expected AS (
  SELECT METRIC, VALUE AS EXPECTED_VALUE FROM {{ ref('expected_totals') }}
)
SELECT a.MODEL_NAME, a.METRIC, a.ACTUAL_VALUE, e.EXPECTED_VALUE
FROM actual a
LEFT JOIN expected e ON e.METRIC = a.METRIC
WHERE a.ACTUAL_VALUE IS DISTINCT FROM e.EXPECTED_VALUE
