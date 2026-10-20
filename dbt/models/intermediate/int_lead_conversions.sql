{#-
    int_lead_conversions (ephemeral): one row per lead with its conversion, if any, and the
    attributes of its campaign. The plan's named intermediate model; it feeds
    fct_lead_conversions, which adds the derived columns (months, score segment, 0/1 flags,
    lag, maturity). Ephemeral: dbt compiles it into fct_lead_conversions as a CTE, so it creates
    no object in Snowflake.

    The two joins:
      - leads -> conversions is a LEFT JOIN on LEAD_ID. LEAD_ID is unique in stg_conversions
        (a lead converts at most once, tested), so each lead matches 0 or 1 conversion rows:
        261,684 leads in, 261,684 rows out, the 221,988 unconverted leads included.
      - leads -> campaigns is n:1 (CAMPAIGN_ID is unique in stg_campaigns, tested). The
        attributes are those of DIM_CAMPAIGN, which copies stg_campaigns 1:1; reading
        stg_campaigns keeps the layers in order (staging -> intermediate -> marts), and
        tests/marts/assert_campaign_attributes_match_independent_seed.sql proves that the facts
        and DIM_CAMPAIGN both carry the attributes of campaigns.csv (the independent seed).
-#}
WITH leads AS (
  SELECT LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE
  FROM {{ ref('stg_leads') }}
),
conversions AS (
  SELECT CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
  FROM {{ ref('stg_conversions') }}
),
campaigns AS (
  SELECT CAMPAIGN_ID, CHANNEL, OBJECTIVE, END_DATE
  FROM {{ ref('stg_campaigns') }}
)
SELECT l.LEAD_ID,
       l.CAMPAIGN_ID,
       c.CHANNEL,
       c.OBJECTIVE,
       c.END_DATE                AS CAMPAIGN_END_DATE,
       l.CREATED_DATE,
       l.LEAD_SOURCE,
       l.LEAD_SCORE,
       v.LEAD_ID IS NOT NULL     AS HAS_CONVERSION,      -- the LEFT JOIN found a conversion row
       v.CONVERSION_ID,
       v.CONVERTED_DATE,
       v.CONVERSION_TYPE,
       v.REVENUE                                         -- NULL when not converted
FROM leads l
-- 1:0..1 on LEAD_ID: keeps the 221,988 unconverted leads; n:1 on CAMPAIGN_ID: no fan-out
LEFT JOIN conversions v ON v.LEAD_ID = l.LEAD_ID
LEFT JOIN campaigns   c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
