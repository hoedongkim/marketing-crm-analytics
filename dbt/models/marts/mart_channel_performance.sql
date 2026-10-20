{#-
    MART_CHANNEL_PERFORMANCE: one row per channel (5 rows), full date range, no date dimension.
      STEP 1  each source aggregated to one row per channel ON ITS OWN: campaigns and budget
              (DIM_CAMPAIGN, whole campaigns), delivery and spend (FCT_DAILY_SPEND), leads,
              conversions and revenue (FCT_LEAD_CONVERSIONS);
      STEP 2  the three joined 1:1 on CHANNEL;
      STEP 3  channel-grain ratios (dividend cast to NUMBER(32,18), NULLIF on every
              denominator), shares of the 5-channel total, and the Wilson 95% interval of
              LEAD_CONVERSION_RATE.
    This path does not read MART_CAMPAIGN_PERFORMANCE, so the tests can compare the two
    independently. Wilson interval, p = CONVERTED_LEADS / LEADS, n = LEADS, z = 1.959964:
      centre = (p + z^2 / (2n)) / (1 + z^2 / n)
      half   = z / (1 + z^2 / n) x SQRT(p (1 - p) / n + z^2 / (4 n^2))
    SQRT needs FLOAT, so this is the one computation in double precision, rounded once to 6 dp
    (none of the exact bounds lies within 4 x 10^-8 of a rounding midpoint).
-#}
WITH campaigns_by_channel AS (   -- STEP 1a: campaign -> channel
  SELECT CHANNEL,
         COUNT(*)    AS CAMPAIGNS,
         SUM(BUDGET) AS BUDGET
  FROM {{ ref('dim_campaign') }}
  GROUP BY CHANNEL
),
spend_by_channel AS (            -- STEP 1b: campaign x day -> channel
  SELECT CHANNEL,
         SUM(IMPRESSIONS) AS IMPRESSIONS,
         SUM(CLICKS)      AS CLICKS,
         SUM(SPEND)       AS SPEND
  FROM {{ ref('fct_daily_spend') }}
  GROUP BY CHANNEL
),
leads_by_channel AS (            -- STEP 1c: lead -> channel
  SELECT CHANNEL,
         COUNT(*)         AS LEADS,
         SUM(IS_CONVERTED) AS CONVERTED_LEADS,
         SUM(IS_TRIAL)    AS TRIALS,
         SUM(IS_PURCHASE) AS PURCHASES,
         SUM(REVENUE)     AS REVENUE
  FROM {{ ref('fct_lead_conversions') }}
  GROUP BY CHANNEL
),
channel_grain AS (               -- STEP 2: one row per channel on every side -> 1:1 joins
  SELECT c.CHANNEL,
         c.CAMPAIGNS::NUMBER(38,0)                    AS CAMPAIGNS,
         c.BUDGET::NUMBER(18,2)                       AS BUDGET,
         COALESCE(s.SPEND, 0)::NUMBER(18,2)           AS SPEND,
         COALESCE(s.IMPRESSIONS, 0)::NUMBER(38,0)     AS IMPRESSIONS,
         COALESCE(s.CLICKS, 0)::NUMBER(38,0)          AS CLICKS,
         COALESCE(l.LEADS, 0)::NUMBER(38,0)           AS LEADS,
         COALESCE(l.CONVERTED_LEADS, 0)::NUMBER(38,0) AS CONVERTED_LEADS,
         COALESCE(l.TRIALS, 0)::NUMBER(38,0)          AS TRIALS,
         COALESCE(l.PURCHASES, 0)::NUMBER(38,0)       AS PURCHASES,
         COALESCE(l.REVENUE, 0)::NUMBER(18,2)         AS REVENUE
  FROM campaigns_by_channel c
  LEFT JOIN spend_by_channel s ON s.CHANNEL = c.CHANNEL   -- 1:1
  LEFT JOIN leads_by_channel l ON l.CHANNEL = c.CHANNEL   -- 1:1
),
wilson_inputs AS (               -- FLOAT inputs of the Wilson interval; NULL n (no leads) gives NULL bounds
  SELECT CHANNEL,
         CONVERTED_LEADS::FLOAT / NULLIF(LEADS, 0)::FLOAT AS P,
         NULLIF(LEADS, 0)::FLOAT                          AS N,
         1.959964::FLOAT                                  AS Z
  FROM channel_grain
)
SELECT g.CHANNEL, g.CAMPAIGNS, g.BUDGET, g.SPEND, g.IMPRESSIONS, g.CLICKS, g.LEADS, g.CONVERTED_LEADS, g.TRIALS,
       g.PURCHASES, g.REVENUE,
       -- STEP 3: channel-grain ratios of the sums; the 18-dp dividend makes ROUND the only rounding
       ROUND(g.CLICKS::NUMBER(32,18)          / NULLIF(g.IMPRESSIONS, 0),     6)::NUMBER(18,6) AS CTR,
       ROUND(g.LEADS::NUMBER(32,18)           / NULLIF(g.CLICKS, 0),          6)::NUMBER(18,6) AS CLICK_TO_LEAD_RATE,
       ROUND(g.CONVERTED_LEADS::NUMBER(32,18) / NULLIF(g.LEADS, 0),           6)::NUMBER(18,6) AS LEAD_CONVERSION_RATE,
       ROUND(g.PURCHASES::NUMBER(32,18)       / NULLIF(g.LEADS, 0),           6)::NUMBER(18,6) AS PURCHASE_RATE,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.LEADS, 0),           4)::NUMBER(18,4) AS COST_PER_LEAD,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.CONVERTED_LEADS, 0), 4)::NUMBER(18,4) AS COST_PER_CONVERSION,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.PURCHASES, 0),       4)::NUMBER(18,4) AS COST_PER_PURCHASE,
       ROUND(g.REVENUE::NUMBER(32,18)         / NULLIF(g.SPEND, 0),           6)::NUMBER(18,6) AS ROAS,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.BUDGET, 0),          6)::NUMBER(18,6) AS BUDGET_UTILIZATION,
       ROUND(g.SPEND::NUMBER(32,18)           / NULLIF(g.CLICKS, 0),          4)::NUMBER(18,4) AS CPC,
       ROUND((g.SPEND * 1000)::NUMBER(32,18)  / NULLIF(g.IMPRESSIONS, 0),     4)::NUMBER(18,4) AS CPM,
       -- shares of the 5-channel total; SUM() OVER () is the total over all rows of channel_grain
       ROUND(g.SPEND::NUMBER(32,18)   / NULLIF(SUM(g.SPEND)   OVER (), 0), 6)::NUMBER(18,6)      AS SPEND_SHARE,
       ROUND(g.LEADS::NUMBER(32,18)   / NULLIF(SUM(g.LEADS)   OVER (), 0), 6)::NUMBER(18,6)      AS LEADS_SHARE,
       ROUND(g.REVENUE::NUMBER(32,18) / NULLIF(SUM(g.REVENUE) OVER (), 0), 6)::NUMBER(18,6)      AS REVENUE_SHARE,
       -- Wilson 95% interval of LEAD_CONVERSION_RATE (formula in the header), in FLOAT, rounded once
       ROUND((w.P + w.Z * w.Z / (2 * w.N)
              - w.Z * SQRT(w.P * (1 - w.P) / w.N + w.Z * w.Z / (4 * w.N * w.N)))
             / (1 + w.Z * w.Z / w.N), 6)::NUMBER(18,6)                                           AS LCR_CI_LOW,
       ROUND((w.P + w.Z * w.Z / (2 * w.N)
              + w.Z * SQRT(w.P * (1 - w.P) / w.N + w.Z * w.Z / (4 * w.N * w.N)))
             / (1 + w.Z * w.Z / w.N), 6)::NUMBER(18,6)                                           AS LCR_CI_HIGH
FROM channel_grain g
JOIN wilson_inputs w ON w.CHANNEL = g.CHANNEL   -- 1:1 (both one row per channel)
ORDER BY g.CHANNEL
