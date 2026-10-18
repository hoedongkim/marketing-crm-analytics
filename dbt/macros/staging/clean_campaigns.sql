{#-
  clean_campaigns(source_relation, fill_campaign_name=false)

  The cleaning rules for a campaigns extract, shared by stg_campaigns (clean release) and
  stg_challenge_campaigns (cleaning-challenge extract). Ported unchanged from
  sql/02_data_cleaning.sql blocks 1 and 5: the same CTE steps, expressions, DQ codes and output
  column order, so both views keep the Phase 3 contract.

  Steps (one CTE each; the rule header of sql/02_data_cleaning.sql explains every choice):
    source   the RAW table, untouched
    trimmed  step 1: NULLIF(TRIM(x, space/tab/CR/LF), '') per column; the raw value is kept
             next to the trimmed one, so step 3 can say what changed
    typed    step 2: ids upper-cased, codes lower-cased, the name INITCAP'd; dates routed by
             SHAPE (ISO, or year-first slash read as Y/M/D), numbers cast only behind a pattern
    flagged  step 3: one '<column>:<issue>' code per problem cell
    deduped  step 4: one row per key; the most complete copy wins, then the first in the file
    final    DQ_ISSUES = cell codes + row codes; DQ_IS_VALID = no code

  fill_campaign_name (challenge track only) appends CAMPAIGN_NAME_FILLED: the provable fill of a
  blank name by the naming rule '<Channel words> <start year> <last 3 id digits>', kept apart
  from CAMPAIGN_NAME (02_data_cleaning.sql block 5).

  Comments stay in Jinja on purpose: the deployed view text must contain exactly the rule
  texts that sql/02_data_cleaning_tests.sql block 2b counts, and nothing else.
-#}
{% macro clean_campaigns(source_relation, fill_campaign_name=false) -%}
WITH source AS (
  SELECT * FROM {{ source_relation }}
),
trimmed AS (
  SELECT CAMPAIGN_ID   AS RAW_CAMPAIGN_ID,   NULLIF(TRIM(CAMPAIGN_ID,   ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         CAMPAIGN_NAME AS RAW_CAMPAIGN_NAME, NULLIF(TRIM(CAMPAIGN_NAME, ' \t\r\n'), '') AS T_CAMPAIGN_NAME,
         CHANNEL       AS RAW_CHANNEL,       NULLIF(TRIM(CHANNEL,       ' \t\r\n'), '') AS T_CHANNEL,
         OBJECTIVE     AS RAW_OBJECTIVE,     NULLIF(TRIM(OBJECTIVE,     ' \t\r\n'), '') AS T_OBJECTIVE,
         START_DATE    AS RAW_START_DATE,    NULLIF(TRIM(START_DATE,    ' \t\r\n'), '') AS T_START_DATE,
         END_DATE      AS RAW_END_DATE,      NULLIF(TRIM(END_DATE,      ' \t\r\n'), '') AS T_END_DATE,
         BUDGET        AS RAW_BUDGET,        NULLIF(TRIM(BUDGET,        ' \t\r\n'), '') AS T_BUDGET,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (
  SELECT *,
         UPPER(T_CAMPAIGN_ID)     AS CAMPAIGN_ID,
         INITCAP(T_CAMPAIGN_NAME) AS CAMPAIGN_NAME,
         LOWER(T_CHANNEL)         AS CHANNEL,
         LOWER(T_OBJECTIVE)       AS OBJECTIVE,
         CASE WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_START_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_START_DATE, 'YYYY/MM/DD')
         END                      AS START_DATE,
         CASE WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')       THEN TRY_TO_DATE(T_END_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$')   THEN TRY_TO_DATE(T_END_DATE, 'YYYY/MM/DD')
         END                      AS END_DATE,
         CASE WHEN REGEXP_LIKE(T_BUDGET, '^[0-9]+[.][0-9]{2}$') THEN TRY_TO_NUMBER(T_BUDGET, 12, 2)
         END                      AS BUDGET
  FROM trimmed
),
flagged AS (
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_CAMPAIGN_ID IS NULL,                         'campaign_id:missing',         NULL),
           IFF(RAW_CAMPAIGN_ID <> T_CAMPAIGN_ID,              'campaign_id:untrimmed',       NULL),
           IFF(T_CAMPAIGN_ID <> CAMPAIGN_ID,                  'campaign_id:recased',         NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_ID, '^CMP[0-9]{4}$'), 'campaign_id:nonconforming',   NULL),
           IFF(T_CAMPAIGN_NAME IS NULL,                       'campaign_name:missing',       NULL),
           IFF(RAW_CAMPAIGN_NAME <> T_CAMPAIGN_NAME,          'campaign_name:untrimmed',     NULL),
           IFF(T_CAMPAIGN_NAME <> CAMPAIGN_NAME,              'campaign_name:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_NAME, '^[A-Z][a-z]+( [A-Z][a-z]+)* [0-9]{4} [0-9]{3}$'),
                                                              'campaign_name:nonconforming', NULL),
           IFF(T_CHANNEL IS NULL,                             'channel:missing',             NULL),
           IFF(RAW_CHANNEL <> T_CHANNEL,                      'channel:untrimmed',           NULL),
           IFF(T_CHANNEL <> CHANNEL,                          'channel:recased',             NULL),
           IFF(NOT REGEXP_LIKE(CHANNEL, '^[a-z]+(_[a-z]+)*$'),  'channel:nonconforming',     NULL),
           IFF(T_OBJECTIVE IS NULL,                           'objective:missing',           NULL),
           IFF(RAW_OBJECTIVE <> T_OBJECTIVE,                  'objective:untrimmed',         NULL),
           IFF(T_OBJECTIVE <> OBJECTIVE,                      'objective:recased',           NULL),
           IFF(NOT REGEXP_LIKE(OBJECTIVE, '^[a-z]+(_[a-z]+)*$'), 'objective:nonconforming',  NULL),
           IFF(T_START_DATE IS NULL,                          'start_date:missing',          NULL),
           IFF(RAW_START_DATE <> T_START_DATE,                'start_date:untrimmed',        NULL),
           IFF(REGEXP_LIKE(T_START_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND START_DATE IS NOT NULL,
                                                              'start_date:slash_ymd',        NULL),
           IFF(T_START_DATE IS NOT NULL AND START_DATE IS NULL, 'start_date:unparseable',    NULL),
           IFF(T_END_DATE IS NULL,                            'end_date:missing',            NULL),
           IFF(RAW_END_DATE <> T_END_DATE,                    'end_date:untrimmed',          NULL),
           IFF(REGEXP_LIKE(T_END_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND END_DATE IS NOT NULL,
                                                              'end_date:slash_ymd',          NULL),
           IFF(T_END_DATE IS NOT NULL AND END_DATE IS NULL,   'end_date:unparseable',        NULL),
           IFF(T_BUDGET IS NULL,                              'budget:missing',              NULL),
           IFF(RAW_BUDGET <> T_BUDGET,                        'budget:untrimmed',            NULL),
           IFF(T_BUDGET IS NOT NULL AND BUDGET IS NULL,       'budget:unparseable',          NULL)
         ) AS CELL_ISSUES,
         IFF(CAMPAIGN_ID IS NULL, 1, 0) + IFF(CAMPAIGN_NAME IS NULL, 1, 0) + IFF(CHANNEL IS NULL, 1, 0)
           + IFF(OBJECTIVE IS NULL, 1, 0) + IFF(START_DATE IS NULL, 1, 0) + IFF(END_DATE IS NULL, 1, 0)
           + IFF(BUDGET IS NULL, 1, 0)                                                     AS N_NULL_FIELDS,
         HASH(CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET) AS ROW_HASH,
         COALESCE(CAMPAIGN_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER) AS DEDUP_KEY
  FROM typed
),
deduped AS (
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
)
SELECT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET,
       (DATEDIFF('day', START_DATE, END_DATE) + 1)::NUMBER(38,0) AS CAMPAIGN_DAYS,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
{%- if fill_campaign_name %},
       COALESCE(CAMPAIGN_NAME,
                INITCAP(REPLACE(CHANNEL, '_', ' ')) || ' ' || YEAR(START_DATE) || ' ' || RIGHT(CAMPAIGN_ID, 3))
                                                                    AS CAMPAIGN_NAME_FILLED
{%- endif %}
FROM deduped
{%- endmacro %}
