{#-
    MART_CONVERSION_FUNNEL reconciles with independent values, and its two helper columns hold
    what the Data Studio stage ratios assume. Four checks, each returning its violating rows:
      stage_total      per stage, STAGE_VALUE summed over the channels equals the independent
                       total (seed expected_totals: impressions 436,844,819, clicks 7,102,319,
                       leads 261,684, converted_leads 39,696, purchases 16,691); a stage missing
                       on either side fails (FULL OUTER JOIN), a metric missing from the seed
                       gives NULL and fails (IS DISTINCT FROM);
      channel_stage    per channel and stage, STAGE_VALUE and the STAGE name equal the per-campaign
                       seed expected_campaign_kpi rolled up to the channel (Python csv + decimal,
                       no SQL under test): 25 cells, a missing or an extra channel x stage fails;
      prev_stage       PREV_STAGE_VALUE equals STAGE_VALUE of stage STAGE_ORDER - 1 of the same
                       channel, and is NULL exactly where no previous stage exists (stage 1);
      top_of_funnel    TOP_OF_FUNNEL_VALUE equals the stage-1 (impressions) STAGE_VALUE of the
                       same channel on every row.
-#}
WITH funnel AS (
  SELECT CHANNEL, STAGE_ORDER, STAGE, STAGE_VALUE, PREV_STAGE_VALUE, TOP_OF_FUNNEL_VALUE
  FROM {{ ref('mart_conversion_funnel') }}
),
stage_metric (STAGE_ORDER, STAGE, METRIC) AS (   -- the expected stage list and its seed metric name
  SELECT * FROM VALUES
    (1, 'Impressions', 'impressions'), (2, 'Clicks', 'clicks'), (3, 'Leads', 'leads'),
    (4, 'Converted leads', 'converted_leads'), (5, 'Purchases', 'purchases')
),
stage_total_expected AS (
  SELECT m.STAGE_ORDER, e.VALUE AS EXPECTED_VALUE
  FROM stage_metric m
  LEFT JOIN {{ ref('expected_totals') }} e ON e.METRIC = m.METRIC
),
stage_total_actual AS (
  SELECT STAGE_ORDER, SUM(STAGE_VALUE) AS ACTUAL_VALUE
  FROM funnel
  GROUP BY STAGE_ORDER
),
seed_by_channel AS (   -- 120 campaigns -> 5 channels, from the independent seed
  SELECT CHANNEL, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS, SUM(LEADS) AS LEADS,
         SUM(CONVERTED_LEADS) AS CONVERTED_LEADS, SUM(PURCHASES) AS PURCHASES
  FROM {{ ref('expected_campaign_kpi') }}
  GROUP BY CHANNEL
),
channel_stage_expected AS (
  SELECT s.CHANNEL, m.STAGE_ORDER, m.STAGE,
         CASE m.METRIC
           WHEN 'impressions'     THEN s.IMPRESSIONS
           WHEN 'clicks'          THEN s.CLICKS
           WHEN 'leads'           THEN s.LEADS
           WHEN 'converted_leads' THEN s.CONVERTED_LEADS
           WHEN 'purchases'       THEN s.PURCHASES
         END AS EXPECTED_VALUE
  FROM seed_by_channel s
  CROSS JOIN stage_metric m
)
SELECT 'stage_total' AS CHECK_NAME, NULL AS CHANNEL, COALESCE(e.STAGE_ORDER, a.STAGE_ORDER) AS STAGE_ORDER,
       NULL AS STAGE, a.ACTUAL_VALUE, e.EXPECTED_VALUE
FROM stage_total_expected e
FULL OUTER JOIN stage_total_actual a ON a.STAGE_ORDER = e.STAGE_ORDER
WHERE a.ACTUAL_VALUE IS DISTINCT FROM e.EXPECTED_VALUE

UNION ALL
SELECT 'channel_stage', COALESCE(e.CHANNEL, f.CHANNEL), COALESCE(e.STAGE_ORDER, f.STAGE_ORDER),
       f.STAGE, f.STAGE_VALUE, e.EXPECTED_VALUE
FROM channel_stage_expected e
FULL OUTER JOIN funnel f ON f.CHANNEL = e.CHANNEL AND f.STAGE_ORDER = e.STAGE_ORDER
WHERE f.STAGE_VALUE IS DISTINCT FROM e.EXPECTED_VALUE
   OR f.STAGE IS DISTINCT FROM e.STAGE

UNION ALL
SELECT 'prev_stage', f.CHANNEL, f.STAGE_ORDER, f.STAGE, f.PREV_STAGE_VALUE, p.STAGE_VALUE
FROM funnel f
LEFT JOIN funnel p ON p.CHANNEL = f.CHANNEL AND p.STAGE_ORDER = f.STAGE_ORDER - 1
WHERE f.PREV_STAGE_VALUE IS DISTINCT FROM p.STAGE_VALUE

UNION ALL
SELECT 'top_of_funnel', f.CHANNEL, f.STAGE_ORDER, f.STAGE, f.TOP_OF_FUNNEL_VALUE, t.STAGE_VALUE
FROM funnel f
LEFT JOIN funnel t ON t.CHANNEL = f.CHANNEL AND t.STAGE_ORDER = 1
WHERE f.TOP_OF_FUNNEL_VALUE IS DISTINCT FROM t.STAGE_VALUE
