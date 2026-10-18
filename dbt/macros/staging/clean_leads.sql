{#-
  clean_leads(source_relation)

  The cleaning rules for a leads extract, shared by stg_leads (clean release) and
  stg_challenge_leads (cleaning-challenge extract). Ported unchanged from
  sql/02_data_cleaning.sql blocks 3 and 7; the steps are those of clean_campaigns.
  CREATED_AT is renamed CREATED_DATE (the values are dates), and its codes say created_date.
  LEAD_SCORE is cast to NUMBER(3,0): a score of 1000 would overflow and become NULL with an
  unparseable code instead of breaking the view. No fill: a blank created date cannot be proven
  (2 candidate dates in the challenge extract), so it stays NULL.
-#}
{% macro clean_leads(source_relation) -%}
WITH source AS (
  SELECT * FROM {{ source_relation }}
),
trimmed AS (
  SELECT LEAD_ID     AS RAW_LEAD_ID,     NULLIF(TRIM(LEAD_ID,     ' \t\r\n'), '') AS T_LEAD_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         CREATED_AT  AS RAW_CREATED_AT,  NULLIF(TRIM(CREATED_AT,  ' \t\r\n'), '') AS T_CREATED_AT,
         LEAD_SOURCE AS RAW_LEAD_SOURCE, NULLIF(TRIM(LEAD_SOURCE, ' \t\r\n'), '') AS T_LEAD_SOURCE,
         LEAD_SCORE  AS RAW_LEAD_SCORE,  NULLIF(TRIM(LEAD_SCORE,  ' \t\r\n'), '') AS T_LEAD_SCORE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (
  SELECT *,
         UPPER(T_LEAD_ID)     AS LEAD_ID,
         UPPER(T_CAMPAIGN_ID) AS CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(T_CREATED_AT, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_CREATED_AT, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_CREATED_AT, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_CREATED_AT, 'YYYY/MM/DD')
         END                  AS CREATED_DATE,
         LOWER(T_LEAD_SOURCE) AS LEAD_SOURCE,
         CASE WHEN REGEXP_LIKE(T_LEAD_SCORE, '^[0-9]+$') THEN TRY_TO_NUMBER(T_LEAD_SCORE, 3, 0) END AS LEAD_SCORE
  FROM trimmed
),
flagged AS (
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_LEAD_ID IS NULL,                              'lead_id:missing',           NULL),
           IFF(RAW_LEAD_ID <> T_LEAD_ID,                       'lead_id:untrimmed',         NULL),
           IFF(T_LEAD_ID <> LEAD_ID,                           'lead_id:recased',           NULL),
           IFF(NOT REGEXP_LIKE(LEAD_ID, '^L[0-9]{8}$'),        'lead_id:nonconforming',     NULL),
           IFF(T_CAMPAIGN_ID IS NULL,                          'campaign_id:missing',       NULL),
           IFF(RAW_CAMPAIGN_ID <> T_CAMPAIGN_ID,               'campaign_id:untrimmed',     NULL),
           IFF(T_CAMPAIGN_ID <> CAMPAIGN_ID,                   'campaign_id:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_ID, '^CMP[0-9]{4}$'),  'campaign_id:nonconforming', NULL),
           IFF(T_CREATED_AT IS NULL,                           'created_date:missing',      NULL),
           IFF(RAW_CREATED_AT <> T_CREATED_AT,                 'created_date:untrimmed',    NULL),
           IFF(REGEXP_LIKE(T_CREATED_AT, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND CREATED_DATE IS NOT NULL,
                                                               'created_date:slash_ymd',    NULL),
           IFF(T_CREATED_AT IS NOT NULL AND CREATED_DATE IS NULL, 'created_date:unparseable', NULL),
           IFF(T_LEAD_SOURCE IS NULL,                          'lead_source:missing',       NULL),
           IFF(RAW_LEAD_SOURCE <> T_LEAD_SOURCE,               'lead_source:untrimmed',     NULL),
           IFF(T_LEAD_SOURCE <> LEAD_SOURCE,                   'lead_source:recased',       NULL),
           IFF(NOT REGEXP_LIKE(LEAD_SOURCE, '^[a-z]+(_[a-z]+)*$'), 'lead_source:nonconforming', NULL),
           IFF(T_LEAD_SCORE IS NULL,                           'lead_score:missing',        NULL),
           IFF(RAW_LEAD_SCORE <> T_LEAD_SCORE,                 'lead_score:untrimmed',      NULL),
           IFF(T_LEAD_SCORE IS NOT NULL AND LEAD_SCORE IS NULL, 'lead_score:unparseable',   NULL)
         ) AS CELL_ISSUES,
         IFF(LEAD_ID IS NULL, 1, 0) + IFF(CAMPAIGN_ID IS NULL, 1, 0) + IFF(CREATED_DATE IS NULL, 1, 0)
           + IFF(LEAD_SOURCE IS NULL, 1, 0) + IFF(LEAD_SCORE IS NULL, 1, 0)                  AS N_NULL_FIELDS,
         HASH(LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE)                   AS ROW_HASH,
         COALESCE(LEAD_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER) AS DEDUP_KEY
  FROM typed
),
deduped AS (
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
)
SELECT LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
FROM deduped
{%- endmacro %}
