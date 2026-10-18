{#-
    FCT_LEAD_CONVERSIONS: one row per lead (261,684 rows), the lead-cohort fact. Ported from
    sql/02b_core_models.sql block 4. The joins (lead LEFT JOIN conversion, 1:0..1, and the
    campaign attributes, n:1) are in the ephemeral int_lead_conversions; this model adds the
    derived columns:
    - CREATED_MONTH (cohort month) and CONVERTED_MONTH (activity month): 34% of conversions land
      in a later month than their lead, so the two must never share one date axis.
    - LEAD_SCORE_SEGMENT: the plan's bands Low 1-40 / Medium 41-70 / High 71-100; a missing or
      out-of-range score stays NULL instead of being guessed into a band.
    - IS_CONVERTED / IS_TRIAL / IS_PURCHASE and the other flags are 0/1 integers, so they SUM.
    - REVENUE is COALESCE(revenue, 0): 0.00 for trials and unconverted leads.
    - DAYS_TO_CONVERT is NULL for an unconverted lead, so AVG covers converted leads only.
    - AS_OF_DATE (var as_of_date, 2025-12-31) and IS_MATURE (var maturity_days, 21) are the
      documented assumptions.
-#}
WITH lead_conversions AS (   -- one row per lead (ephemeral int_lead_conversions)
  SELECT * FROM {{ ref('int_lead_conversions') }}
),
params AS (                  -- the documented maturity assumption, in one place
  SELECT '{{ var("as_of_date") }}'::DATE AS AS_OF_DATE, {{ var('maturity_days') }} AS MATURITY_DAYS
)
SELECT l.LEAD_ID,
       l.CAMPAIGN_ID,
       l.CHANNEL,
       l.OBJECTIVE,
       l.CREATED_DATE,
       DATE_TRUNC('month', l.CREATED_DATE)                                AS CREATED_MONTH,     -- cohort month
       l.LEAD_SOURCE,
       l.LEAD_SCORE,
       CASE WHEN l.LEAD_SCORE BETWEEN  1 AND  40 THEN 'Low'
            WHEN l.LEAD_SCORE BETWEEN 41 AND  70 THEN 'Medium'
            WHEN l.LEAD_SCORE BETWEEN 71 AND 100 THEN 'High'
       END::VARCHAR                                                       AS LEAD_SCORE_SEGMENT, -- no band is guessed for NULL
       l.CONVERSION_ID,                                                                         -- NULL when not converted
       l.CONVERTED_DATE,
       DATE_TRUNC('month', l.CONVERTED_DATE)                              AS CONVERTED_MONTH,   -- activity month
       l.CONVERSION_TYPE,
       IFF(l.HAS_CONVERSION, 1, 0)::NUMBER(1,0)                           AS IS_CONVERTED,      -- the LEFT JOIN found a row
       IFF(l.CONVERSION_TYPE = 'trial', 1, 0)::NUMBER(1,0)                AS IS_TRIAL,
       IFF(l.CONVERSION_TYPE = 'purchase', 1, 0)::NUMBER(1,0)             AS IS_PURCHASE,
       COALESCE(l.REVENUE, 0)::NUMBER(12,2)                               AS REVENUE,           -- 0.00, not NULL, so it sums
       DATEDIFF('day', l.CREATED_DATE, l.CONVERTED_DATE)::NUMBER(38,0)    AS DAYS_TO_CONVERT,   -- NULL when not converted
       IFF(l.CONVERTED_DATE > l.CAMPAIGN_END_DATE, 1, 0)::NUMBER(1,0)     AS CONVERTED_AFTER_CAMPAIGN_END,
       p.AS_OF_DATE,
       IFF(l.CREATED_DATE <= DATEADD('day', -p.MATURITY_DAYS, p.AS_OF_DATE), 1, 0)::NUMBER(1,0) AS IS_MATURE
FROM lead_conversions l
CROSS JOIN params     p                                    -- one row
ORDER BY l.CREATED_DATE, l.LEAD_ID
