{#-
    The cleaning challenge's own acceptance test (the dbt port of
    sql/02_data_cleaning_tests.sql blocks 15-16). On the publisher's dirty extracts the staging
    rules must flag EXACTLY the 15 defects that Phase 2 located, with exactly these 18 codes,
    and give each defective cell the value Phase 2 argued for:
      4 duplicate rows      one row kept per key, duplicate_copies=2
      3 casing/whitespace   normalised, untrimmed + recased (2 codes each)
      4 year-first slashes  parsed as Y/M/D, slash_ymd
      4 blank values        NULL, missing; 2 of them provably filled in the *_FILLED column
    Returns every unexpected or missing code (FULL OUTER JOIN) and every defective cell whose
    cleaned or filled value is not the expected one.
-#}
{%- set views = [('stg_challenge_campaigns', 'campaign_id'), ('stg_challenge_daily_spend', 'spend_id'),
                 ('stg_challenge_leads', 'lead_id'), ('stg_challenge_conversions', 'conversion_id')] -%}
WITH chg_rows AS (
{%- for model_name, key in views %}
  {{ 'SELECT' if loop.first else 'UNION ALL SELECT' }} '{{ model_name }}' AS MODEL_NAME, {{ key }} AS KEY_VALUE, DQ_ISSUES,
         OBJECT_CONSTRUCT_KEEP_NULL(*) AS ROW_OBJ
  FROM {{ ref(model_name) }}
{%- endfor %}
),
actual_codes AS (
  SELECT r.MODEL_NAME, r.KEY_VALUE, f.VALUE::STRING AS CODE
  FROM chg_rows r, LATERAL FLATTEN(INPUT => r.DQ_ISSUES) f
),
expected_codes (MODEL_NAME, KEY_VALUE, CODE) AS (
  SELECT * FROM VALUES
    ('stg_challenge_campaigns',   'CMP0001',    'row:duplicate_copies=2'),
    ('stg_challenge_daily_spend', 'DSP0000001', 'row:duplicate_copies=2'),
    ('stg_challenge_leads',       'L00000001',  'row:duplicate_copies=2'),
    ('stg_challenge_conversions', 'CV0000001',  'row:duplicate_copies=2'),
    ('stg_challenge_campaigns',   'CMP0008',    'campaign_name:untrimmed'),
    ('stg_challenge_campaigns',   'CMP0008',    'campaign_name:recased'),
    ('stg_challenge_leads',       'L00000008',  'lead_source:untrimmed'),
    ('stg_challenge_leads',       'L00000008',  'lead_source:recased'),
    ('stg_challenge_conversions', 'CV0000008',  'conversion_type:untrimmed'),
    ('stg_challenge_conversions', 'CV0000008',  'conversion_type:recased'),
    ('stg_challenge_campaigns',   'CMP0018',    'start_date:slash_ymd'),
    ('stg_challenge_daily_spend', 'DSP0000018', 'spend_date:slash_ymd'),
    ('stg_challenge_leads',       'L00000018',  'created_date:slash_ymd'),
    ('stg_challenge_conversions', 'CV0000018',  'converted_date:slash_ymd'),
    ('stg_challenge_campaigns',   'CMP0030',    'campaign_name:missing'),
    ('stg_challenge_daily_spend', 'DSP0000030', 'spend_date:missing'),
    ('stg_challenge_leads',       'L00000030',  'created_date:missing'),
    ('stg_challenge_conversions', 'CV0000030',  'converted_date:missing')
),
expected_values (MODEL_NAME, KEY_VALUE, COLUMN_NAME, EXPECTED_VALUE, EXPECTED_FILLED) AS (
  SELECT * FROM VALUES
    ('stg_challenge_campaigns',   'CMP0008',    'CAMPAIGN_NAME',   'Display 2023 008', NULL),
    ('stg_challenge_leads',       'L00000008',  'LEAD_SOURCE',     'paid_search',      NULL),
    ('stg_challenge_conversions', 'CV0000008',  'CONVERSION_TYPE', 'trial',            NULL),
    ('stg_challenge_campaigns',   'CMP0018',    'START_DATE',      '2023-05-15',       NULL),
    ('stg_challenge_daily_spend', 'DSP0000018', 'SPEND_DATE',      '2023-07-04',       NULL),
    ('stg_challenge_leads',       'L00000018',  'CREATED_DATE',    '2023-06-17',       NULL),
    ('stg_challenge_conversions', 'CV0000018',  'CONVERTED_DATE',  '2023-07-05',       NULL),
    ('stg_challenge_campaigns',   'CMP0030',    'CAMPAIGN_NAME',   NULL,               'Affiliate 2024 030'),
    ('stg_challenge_daily_spend', 'DSP0000030', 'SPEND_DATE',      NULL,               '2023-07-16'),
    ('stg_challenge_leads',       'L00000030',  'CREATED_DATE',    NULL,               NULL),
    ('stg_challenge_conversions', 'CV0000030',  'CONVERTED_DATE',  NULL,               NULL)
),
code_mismatches AS (
  SELECT COALESCE(a.MODEL_NAME, e.MODEL_NAME) AS MODEL_NAME, COALESCE(a.KEY_VALUE, e.KEY_VALUE) AS KEY_VALUE,
         COALESCE(a.CODE, e.CODE) AS DETAIL,
         IFF(a.CODE IS NULL, 'expected code missing', 'unexpected code') AS PROBLEM
  FROM actual_codes a
  FULL OUTER JOIN expected_codes e
    ON e.MODEL_NAME = a.MODEL_NAME AND e.KEY_VALUE = a.KEY_VALUE AND e.CODE = a.CODE
  WHERE a.CODE IS NULL OR e.CODE IS NULL
),
value_mismatches AS (
  SELECT e.MODEL_NAME, e.KEY_VALUE,
         e.COLUMN_NAME || ' = ' || COALESCE(GET(r.ROW_OBJ, e.COLUMN_NAME)::STRING, 'NULL')
           || ', filled ' || COALESCE(GET(r.ROW_OBJ, e.COLUMN_NAME || '_FILLED')::STRING, 'NULL') AS DETAIL,
         'wrong cleaned or filled value' AS PROBLEM
  FROM expected_values e
  LEFT JOIN chg_rows r ON r.MODEL_NAME = e.MODEL_NAME AND r.KEY_VALUE = e.KEY_VALUE
  WHERE r.KEY_VALUE IS NULL
     OR NOT EQUAL_NULL(GET(r.ROW_OBJ, e.COLUMN_NAME)::STRING, e.EXPECTED_VALUE)
     OR (e.EXPECTED_FILLED IS NOT NULL
         AND NOT EQUAL_NULL(GET(r.ROW_OBJ, e.COLUMN_NAME || '_FILLED')::STRING, e.EXPECTED_FILLED))
)
SELECT * FROM code_mismatches
UNION ALL
SELECT * FROM value_mismatches
