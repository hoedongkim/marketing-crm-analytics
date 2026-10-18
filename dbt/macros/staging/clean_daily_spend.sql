{#-
  clean_daily_spend(source_relation, fill_spend_date=false)

  The cleaning rules for a daily-spend extract, shared by stg_daily_spend (clean release) and
  stg_challenge_daily_spend (cleaning-challenge extract). Ported unchanged from
  sql/02_data_cleaning.sql blocks 2 and 6; the steps are those of clean_campaigns.

  fill_spend_date (challenge track only) appends SPEND_DATE_FILLED: a blank spend date is filled
  with the previous date + 1 day only when that also equals the next date - 1 day (LAG / LEAD in
  spend_id order within the campaign), i.e. exactly one day fits between the neighbours. The fill
  runs after de-duplication, so LAG / LEAD see one row per spend_id (02_data_cleaning.sql block 6).
-#}
{% macro clean_daily_spend(source_relation, fill_spend_date=false) -%}
WITH source AS (
  SELECT * FROM {{ source_relation }}
),
trimmed AS (
  SELECT SPEND_ID    AS RAW_SPEND_ID,    NULLIF(TRIM(SPEND_ID,    ' \t\r\n'), '') AS T_SPEND_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         SPEND_DATE  AS RAW_SPEND_DATE,  NULLIF(TRIM(SPEND_DATE,  ' \t\r\n'), '') AS T_SPEND_DATE,
         IMPRESSIONS AS RAW_IMPRESSIONS, NULLIF(TRIM(IMPRESSIONS, ' \t\r\n'), '') AS T_IMPRESSIONS,
         CLICKS      AS RAW_CLICKS,      NULLIF(TRIM(CLICKS,      ' \t\r\n'), '') AS T_CLICKS,
         SPEND       AS RAW_SPEND,       NULLIF(TRIM(SPEND,       ' \t\r\n'), '') AS T_SPEND,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (
  SELECT *,
         UPPER(T_SPEND_ID)    AS SPEND_ID,
         UPPER(T_CAMPAIGN_ID) AS CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY/MM/DD')
         END                  AS SPEND_DATE,
         CASE WHEN REGEXP_LIKE(T_IMPRESSIONS, '^[0-9]+$')        THEN TRY_TO_NUMBER(T_IMPRESSIONS, 38, 0) END AS IMPRESSIONS,
         CASE WHEN REGEXP_LIKE(T_CLICKS, '^[0-9]+$')             THEN TRY_TO_NUMBER(T_CLICKS, 38, 0)      END AS CLICKS,
         CASE WHEN REGEXP_LIKE(T_SPEND, '^[0-9]+[.][0-9]{2}$')   THEN TRY_TO_NUMBER(T_SPEND, 12, 2)       END AS SPEND
  FROM trimmed
),
flagged AS (
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_SPEND_ID IS NULL,                             'spend_id:missing',          NULL),
           IFF(RAW_SPEND_ID <> T_SPEND_ID,                     'spend_id:untrimmed',        NULL),
           IFF(T_SPEND_ID <> SPEND_ID,                         'spend_id:recased',          NULL),
           IFF(NOT REGEXP_LIKE(SPEND_ID, '^DSP[0-9]{7}$'),     'spend_id:nonconforming',    NULL),
           IFF(T_CAMPAIGN_ID IS NULL,                          'campaign_id:missing',       NULL),
           IFF(RAW_CAMPAIGN_ID <> T_CAMPAIGN_ID,               'campaign_id:untrimmed',     NULL),
           IFF(T_CAMPAIGN_ID <> CAMPAIGN_ID,                   'campaign_id:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_ID, '^CMP[0-9]{4}$'),  'campaign_id:nonconforming', NULL),
           IFF(T_SPEND_DATE IS NULL,                           'spend_date:missing',        NULL),
           IFF(RAW_SPEND_DATE <> T_SPEND_DATE,                 'spend_date:untrimmed',      NULL),
           IFF(REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND SPEND_DATE IS NOT NULL,
                                                               'spend_date:slash_ymd',      NULL),
           IFF(T_SPEND_DATE IS NOT NULL AND SPEND_DATE IS NULL, 'spend_date:unparseable',   NULL),
           IFF(T_IMPRESSIONS IS NULL,                          'impressions:missing',       NULL),
           IFF(RAW_IMPRESSIONS <> T_IMPRESSIONS,               'impressions:untrimmed',     NULL),
           IFF(T_IMPRESSIONS IS NOT NULL AND IMPRESSIONS IS NULL, 'impressions:unparseable', NULL),
           IFF(T_CLICKS IS NULL,                               'clicks:missing',            NULL),
           IFF(RAW_CLICKS <> T_CLICKS,                         'clicks:untrimmed',          NULL),
           IFF(T_CLICKS IS NOT NULL AND CLICKS IS NULL,        'clicks:unparseable',        NULL),
           IFF(T_SPEND IS NULL,                                'spend:missing',             NULL),
           IFF(RAW_SPEND <> T_SPEND,                           'spend:untrimmed',           NULL),
           IFF(T_SPEND IS NOT NULL AND SPEND IS NULL,          'spend:unparseable',         NULL)
         ) AS CELL_ISSUES,
         IFF(SPEND_ID IS NULL, 1, 0) + IFF(CAMPAIGN_ID IS NULL, 1, 0) + IFF(SPEND_DATE IS NULL, 1, 0)
           + IFF(IMPRESSIONS IS NULL, 1, 0) + IFF(CLICKS IS NULL, 1, 0) + IFF(SPEND IS NULL, 1, 0) AS N_NULL_FIELDS,
         HASH(SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND)                       AS ROW_HASH,
         COALESCE(SPEND_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER)      AS DEDUP_KEY
  FROM typed
),
deduped AS (
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
)
{%- if fill_spend_date %},
neighbours AS (
  SELECT *,
         LAG(SPEND_DATE)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_SPEND_DATE,
         LEAD(SPEND_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_SPEND_DATE
  FROM deduped
)
{%- endif %}
SELECT SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
{%- if fill_spend_date %},
       COALESCE(SPEND_DATE,
                CASE WHEN DATEADD('day', 1, PREV_SPEND_DATE) = DATEADD('day', -1, NEXT_SPEND_DATE)
                     THEN DATEADD('day', 1, PREV_SPEND_DATE)
                END)                                                AS SPEND_DATE_FILLED
FROM neighbours
{%- else %}
FROM deduped
{%- endif %}
{%- endmacro %}
