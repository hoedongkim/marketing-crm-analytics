{#-
    MART_LEAD_QUALITY: one row per channel x 10-point lead score band (5 x 10 = 50 rows).
    Ported from sql/02c_analysis_marts.sql block 5.
    - The bands are an explicit 10-row list (edges and plan segment in one place); the spine is
      5 channels x 10 bands, so a band without leads shows as 0.
    - Each lead goes to the band SCORE_BAND_MIN = FLOOR((LEAD_SCORE - 1) / 10) x 10 + 1; a NULL or
      out-of-range score would find no band and drop out (the tests check all 261,684 arrive).
    - Bands align with the segment cut-offs 40 and 70, so the table rolls up to segment, band
      or channel with SUM. Association only: the score's method is undocumented.
-#}
WITH bands (SCORE_BAND, SCORE_BAND_MIN, SCORE_BAND_MAX, LEAD_SCORE_SEGMENT) AS (   -- the 10 bands and their plan segment
  SELECT * FROM VALUES
    ('01-10',   1,  10, 'Low'),    ('11-20',  11,  20, 'Low'),    ('21-30',  21,  30, 'Low'),
    ('31-40',  31,  40, 'Low'),    ('41-50',  41,  50, 'Medium'), ('51-60',  51,  60, 'Medium'),
    ('61-70',  61,  70, 'Medium'), ('71-80',  71,  80, 'High'),   ('81-90',  81,  90, 'High'),
    ('91-100', 91, 100, 'High')
),
channels AS (               -- the canonical channels
  SELECT DISTINCT CHANNEL FROM {{ ref('dim_campaign') }}
),
leads_by_band AS (          -- one row per lead -> one row per channel x band
  SELECT CHANNEL,
         FLOOR((LEAD_SCORE - 1) / 10) * 10 + 1 AS SCORE_BAND_MIN,   -- 1, 11, ..., 91
         COUNT(*)             AS LEADS,
         SUM(LEAD_SCORE)      AS SUM_LEAD_SCORE,
         SUM(IS_CONVERTED)    AS CONVERTED_LEADS,
         SUM(IS_TRIAL)        AS TRIALS,
         SUM(IS_PURCHASE)     AS PURCHASES,
         SUM(REVENUE)         AS REVENUE,
         SUM(DAYS_TO_CONVERT) AS SUM_DAYS_TO_CONVERT                -- NULL lags (unconverted) are skipped
  FROM {{ ref('fct_lead_conversions') }}
  GROUP BY CHANNEL, FLOOR((LEAD_SCORE - 1) / 10) * 10 + 1
)
SELECT ch.CHANNEL,
       b.SCORE_BAND::VARCHAR                              AS SCORE_BAND,
       b.SCORE_BAND_MIN::NUMBER(3,0)                      AS SCORE_BAND_MIN,
       b.SCORE_BAND_MAX::NUMBER(3,0)                      AS SCORE_BAND_MAX,
       b.LEAD_SCORE_SEGMENT::VARCHAR                      AS LEAD_SCORE_SEGMENT,
       COALESCE(l.LEADS, 0)::NUMBER(38,0)                 AS LEADS,
       COALESCE(l.SUM_LEAD_SCORE, 0)::NUMBER(38,0)        AS SUM_LEAD_SCORE,
       COALESCE(l.CONVERTED_LEADS, 0)::NUMBER(38,0)       AS CONVERTED_LEADS,
       COALESCE(l.TRIALS, 0)::NUMBER(38,0)                AS TRIALS,
       COALESCE(l.PURCHASES, 0)::NUMBER(38,0)             AS PURCHASES,
       COALESCE(l.REVENUE, 0)::NUMBER(18,2)               AS REVENUE,
       COALESCE(l.SUM_DAYS_TO_CONVERT, 0)::NUMBER(38,0)   AS SUM_DAYS_TO_CONVERT
FROM channels ch
CROSS JOIN bands b                                                   -- the spine: 5 x 10 dimension members
LEFT JOIN leads_by_band l ON l.CHANNEL = ch.CHANNEL AND l.SCORE_BAND_MIN = b.SCORE_BAND_MIN   -- 1:1
ORDER BY ch.CHANNEL, b.SCORE_BAND_MIN
