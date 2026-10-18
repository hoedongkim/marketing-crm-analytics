{#-
  clean_conversions(source_relation)

  The cleaning rules for a conversions extract, shared by stg_conversions (clean release) and
  stg_challenge_conversions (cleaning-challenge extract). Ported unchanged from
  sql/02_data_cleaning.sql blocks 4 and 8; the steps are those of clean_campaigns.
  CONVERTED_AT is renamed CONVERTED_DATE, and its codes say converted_date. No fill: a blank
  converted date cannot be proven (22 candidate dates in the challenge extract), so it stays NULL.
-#}
{% macro clean_conversions(source_relation) -%}
WITH source AS (
  SELECT * FROM {{ source_relation }}
),
trimmed AS (
  SELECT CONVERSION_ID   AS RAW_CONVERSION_ID,   NULLIF(TRIM(CONVERSION_ID,   ' \t\r\n'), '') AS T_CONVERSION_ID,
         LEAD_ID         AS RAW_LEAD_ID,         NULLIF(TRIM(LEAD_ID,         ' \t\r\n'), '') AS T_LEAD_ID,
         CONVERTED_AT    AS RAW_CONVERTED_AT,    NULLIF(TRIM(CONVERTED_AT,    ' \t\r\n'), '') AS T_CONVERTED_AT,
         CONVERSION_TYPE AS RAW_CONVERSION_TYPE, NULLIF(TRIM(CONVERSION_TYPE, ' \t\r\n'), '') AS T_CONVERSION_TYPE,
         REVENUE         AS RAW_REVENUE,         NULLIF(TRIM(REVENUE,         ' \t\r\n'), '') AS T_REVENUE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (
  SELECT *,
         UPPER(T_CONVERSION_ID)   AS CONVERSION_ID,
         UPPER(T_LEAD_ID)         AS LEAD_ID,
         CASE WHEN REGEXP_LIKE(T_CONVERTED_AT, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_CONVERTED_AT, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_CONVERTED_AT, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_CONVERTED_AT, 'YYYY/MM/DD')
         END                      AS CONVERTED_DATE,
         LOWER(T_CONVERSION_TYPE) AS CONVERSION_TYPE,
         CASE WHEN REGEXP_LIKE(T_REVENUE, '^[0-9]+[.][0-9]{2}$') THEN TRY_TO_NUMBER(T_REVENUE, 12, 2) END AS REVENUE
  FROM trimmed
),
flagged AS (
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_CONVERSION_ID IS NULL,                        'conversion_id:missing',         NULL),
           IFF(RAW_CONVERSION_ID <> T_CONVERSION_ID,           'conversion_id:untrimmed',       NULL),
           IFF(T_CONVERSION_ID <> CONVERSION_ID,               'conversion_id:recased',         NULL),
           IFF(NOT REGEXP_LIKE(CONVERSION_ID, '^CV[0-9]{7}$'), 'conversion_id:nonconforming',   NULL),
           IFF(T_LEAD_ID IS NULL,                              'lead_id:missing',               NULL),
           IFF(RAW_LEAD_ID <> T_LEAD_ID,                       'lead_id:untrimmed',             NULL),
           IFF(T_LEAD_ID <> LEAD_ID,                           'lead_id:recased',               NULL),
           IFF(NOT REGEXP_LIKE(LEAD_ID, '^L[0-9]{8}$'),        'lead_id:nonconforming',         NULL),
           IFF(T_CONVERTED_AT IS NULL,                         'converted_date:missing',        NULL),
           IFF(RAW_CONVERTED_AT <> T_CONVERTED_AT,             'converted_date:untrimmed',      NULL),
           IFF(REGEXP_LIKE(T_CONVERTED_AT, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND CONVERTED_DATE IS NOT NULL,
                                                               'converted_date:slash_ymd',      NULL),
           IFF(T_CONVERTED_AT IS NOT NULL AND CONVERTED_DATE IS NULL, 'converted_date:unparseable', NULL),
           IFF(T_CONVERSION_TYPE IS NULL,                      'conversion_type:missing',       NULL),
           IFF(RAW_CONVERSION_TYPE <> T_CONVERSION_TYPE,       'conversion_type:untrimmed',     NULL),
           IFF(T_CONVERSION_TYPE <> CONVERSION_TYPE,           'conversion_type:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CONVERSION_TYPE, '^[a-z]+(_[a-z]+)*$'), 'conversion_type:nonconforming', NULL),
           IFF(T_REVENUE IS NULL,                              'revenue:missing',               NULL),
           IFF(RAW_REVENUE <> T_REVENUE,                       'revenue:untrimmed',             NULL),
           IFF(T_REVENUE IS NOT NULL AND REVENUE IS NULL,      'revenue:unparseable',           NULL)
         ) AS CELL_ISSUES,
         IFF(CONVERSION_ID IS NULL, 1, 0) + IFF(LEAD_ID IS NULL, 1, 0) + IFF(CONVERTED_DATE IS NULL, 1, 0)
           + IFF(CONVERSION_TYPE IS NULL, 1, 0) + IFF(REVENUE IS NULL, 1, 0)                     AS N_NULL_FIELDS,
         HASH(CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE)                  AS ROW_HASH,
         COALESCE(CONVERSION_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER) AS DEDUP_KEY
  FROM typed
),
deduped AS (
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
)
SELECT CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
FROM deduped
{%- endmacro %}
