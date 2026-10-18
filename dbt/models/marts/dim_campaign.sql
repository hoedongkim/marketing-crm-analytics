{#-
    DIM_CAMPAIGN: one row per campaign (120 rows). Ported from sql/02b_core_models.sql block 2.
    Every fact takes CHANNEL and OBJECTIVE from here: CHANNEL is the canonical channel
    dimension (LEAD_SOURCE only duplicates it). stg_campaigns is unique on CAMPAIGN_ID (tested),
    so a join from any fact to this table is n:1 and cannot fan out.
-#}
SELECT CAMPAIGN_ID,
       CAMPAIGN_NAME,
       CHANNEL,
       OBJECTIVE,
       START_DATE,
       END_DATE,
       CAMPAIGN_DAYS,                                -- END_DATE - START_DATE + 1, from STAGING
       BUDGET,
       YEAR(START_DATE)::NUMBER(4,0)  AS START_YEAR,
       DATE_TRUNC('month', START_DATE) AS START_MONTH
FROM {{ ref('stg_campaigns') }}
ORDER BY CAMPAIGN_ID
