{#-
    The outside check: spend and attributed revenue per channel equal the publisher's own
    reference output (seed publisher_channel_reference, typed in from the dataset page) to the
    cent, both as the channel roll-up of MART_CAMPAIGN_PERFORMANCE (how the dashboard aggregates
    it) and in MART_CHANNEL_PERFORMANCE (built on a separate path, from the facts).
    FULL OUTER JOIN: a missing or unexpected channel is its own failing row.
-#}
WITH campaign_rollup AS (
  SELECT CHANNEL, SUM(SPEND) AS SPEND, SUM(REVENUE) AS REVENUE
  FROM {{ ref('mart_campaign_performance') }}
  GROUP BY CHANNEL
),
channel_mart AS (
  SELECT CHANNEL, SPEND, REVENUE FROM {{ ref('mart_channel_performance') }}
),
reference AS (
  SELECT CHANNEL, SPEND, ATTRIBUTED_REVENUE FROM {{ ref('publisher_channel_reference') }}
)
SELECT COALESCE(r.CHANNEL, c.CHANNEL, m.CHANNEL) AS CHANNEL,
       r.SPEND AS PUBLISHED_SPEND, c.SPEND AS CAMPAIGN_ROLLUP_SPEND, m.SPEND AS CHANNEL_MART_SPEND,
       r.ATTRIBUTED_REVENUE AS PUBLISHED_REVENUE, c.REVENUE AS CAMPAIGN_ROLLUP_REVENUE, m.REVENUE AS CHANNEL_MART_REVENUE
FROM reference r
FULL OUTER JOIN campaign_rollup c ON c.CHANNEL = r.CHANNEL
FULL OUTER JOIN channel_mart    m ON m.CHANNEL = COALESCE(r.CHANNEL, c.CHANNEL)
WHERE NOT (EQUAL_NULL(r.SPEND, c.SPEND) AND EQUAL_NULL(r.SPEND, m.SPEND)
           AND EQUAL_NULL(r.ATTRIBUTED_REVENUE, c.REVENUE) AND EQUAL_NULL(r.ATTRIBUTED_REVENUE, m.REVENUE))
   OR r.CHANNEL IS NULL
