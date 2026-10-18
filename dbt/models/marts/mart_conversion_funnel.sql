{#-
    MART_CONVERSION_FUNNEL: the funnel in long format, one row per channel x stage
    (5 channels x 5 stages = 25 rows), full date range 2023-01-01..2025-12-31, no date dimension.
    Added in Phase 6 (dbt only, no hand-written SQL twin): the plan's mart_conversion_funnel, the
    source a Data Studio funnel or bar chart needs (one dimension STAGE, one metric STAGE_VALUE).
      STEP 1  the five funnel bases of each channel, read from MART_CHANNEL_PERFORMANCE (each
              fact aggregated to the channel on its own there), so every value equals the
              channel table and the known totals exactly;
      STEP 2  cross join with the 5-row stage list, one stage value per row;
      STEP 3  PREV_STAGE_VALUE (the previous stage of the same channel, NULL on stage 1) and
              TOP_OF_FUNNEL_VALUE (the channel's impressions) on every row.
    PREV_STAGE_VALUE and TOP_OF_FUNNEL_VALUE are additive across channels, so with STAGE as the
    chart dimension SUM(STAGE_VALUE) / SUM(PREV_STAGE_VALUE) is the stage conversion and
    SUM(STAGE_VALUE) / SUM(TOP_OF_FUNNEL_VALUE) the share of the top of the funnel, for any set
    of channels a filter leaves. No ratio is stored and there is no 'ALL' channel row: a total
    row would double count every SUM.
    An aggregate campaign funnel, not a per-person journey: the stages are different units
    (an impression is not a person). Converted leads = trials + purchases (a lead converts at
    most once); Purchases is the subset of converted leads that converted to a purchase, not a
    later step taken by the same person after a trial.
-#}
WITH channel_bases AS (   -- STEP 1: one row per channel, the five additive funnel bases
  SELECT CHANNEL, IMPRESSIONS, CLICKS, LEADS, CONVERTED_LEADS, PURCHASES
  FROM {{ ref('mart_channel_performance') }}
),
stages (STAGE_ORDER, STAGE) AS (   -- the five stages, in funnel order
  SELECT * FROM VALUES
    (1, 'Impressions'), (2, 'Clicks'), (3, 'Leads'), (4, 'Converted leads'), (5, 'Purchases')
),
channel_stage AS (        -- STEP 2: channel x stage, the stage's base as STAGE_VALUE
  SELECT c.CHANNEL, s.STAGE_ORDER, s.STAGE,
         CASE s.STAGE_ORDER
           WHEN 1 THEN c.IMPRESSIONS
           WHEN 2 THEN c.CLICKS
           WHEN 3 THEN c.LEADS
           WHEN 4 THEN c.CONVERTED_LEADS
           WHEN 5 THEN c.PURCHASES
         END           AS STAGE_VALUE,
         c.IMPRESSIONS AS TOP_OF_FUNNEL_VALUE
  FROM channel_bases c
  CROSS JOIN stages s   -- 5 x 5; each channel row repeats once per stage, each with a different base
)
SELECT CHANNEL::VARCHAR                                                                AS CHANNEL,
       STAGE_ORDER::NUMBER(1,0)                                                        AS STAGE_ORDER,
       STAGE::VARCHAR                                                                  AS STAGE,
       STAGE_VALUE::NUMBER(38,0)                                                       AS STAGE_VALUE,
       -- STEP 3: the previous stage of the same channel; NULL on stage 1 (nothing before impressions)
       LAG(STAGE_VALUE) OVER (PARTITION BY CHANNEL ORDER BY STAGE_ORDER)::NUMBER(38,0) AS PREV_STAGE_VALUE,
       TOP_OF_FUNNEL_VALUE::NUMBER(38,0)                                               AS TOP_OF_FUNNEL_VALUE
FROM channel_stage
ORDER BY CHANNEL, STAGE_ORDER
