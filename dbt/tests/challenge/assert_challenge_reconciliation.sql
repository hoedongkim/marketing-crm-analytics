{#-
    Reconciliation of the cleaning-challenge track with the clean release (the dbt port of
    sql/02_data_cleaning_tests.sql blocks 18-19). The extracts are dirty copies of the first
    keys of the clean release, so after cleaning each row must equal its clean row in every
    contract column (EQUAL_NULL), compared twice:
      blanks NULL  the challenge view as it is                      6,116 of 6,120 rows match
      with fills   CAMPAIGN_NAME_FILLED / SPEND_DATE_FILLED used    6,118 of 6,120 rows match
    The cells that still differ after the fills must be EXACTLY the 2 blank dates that no
    evidence can recover (L00000030.CREATED_DATE, CV0000030.CONVERTED_DATE), and both must be
    NULL, never a wrong value. Expected counts: Phase 2 acceptance criteria [E01b 8a-8b].
    Returns one row per failed count and per unexpected or missing differing cell.
-#}
{%- set views = [
    ('stg_challenge_campaigns', 'stg_campaigns', 'campaign_id',
     ['campaign_id', 'campaign_name', 'channel', 'objective', 'start_date', 'end_date', 'budget', 'campaign_days'],
     {'campaign_name': 'campaign_name_filled'}),
    ('stg_challenge_daily_spend', 'stg_daily_spend', 'spend_id',
     ['spend_id', 'campaign_id', 'spend_date', 'impressions', 'clicks', 'spend'],
     {'spend_date': 'spend_date_filled'}),
    ('stg_challenge_leads', 'stg_leads', 'lead_id',
     ['lead_id', 'campaign_id', 'created_date', 'lead_source', 'lead_score'], {}),
    ('stg_challenge_conversions', 'stg_conversions', 'conversion_id',
     ['conversion_id', 'lead_id', 'converted_date', 'conversion_type', 'revenue'], {}),
] -%}
WITH compared_rows AS (   -- one row per challenge row: per contract column [equal as is, equal with fills, challenge value NULL]
{%- for chg, clean, key, cols, fills in views %}
  {{ 'SELECT' if loop.first else 'UNION ALL SELECT' }} '{{ chg }}' AS MODEL_NAME, x.{{ key }} AS KEY_VALUE,
         OBJECT_CONSTRUCT(
         {%- for col in cols %}
           '{{ col }}', ARRAY_CONSTRUCT(EQUAL_NULL(x.{{ col }}, c.{{ col }}),
                                        EQUAL_NULL(x.{{ fills.get(col, col) }}, c.{{ col }}),
                                        x.{{ fills.get(col, col) }} IS NULL){{ ',' if not loop.last }}
         {%- endfor %}
         ) AS CELLS
  FROM {{ ref(chg) }} x
  LEFT JOIN {{ ref(clean) }} c ON c.{{ key }} = x.{{ key }}
{%- endfor %}
),
cells AS (
  SELECT r.MODEL_NAME, r.KEY_VALUE, f.KEY AS COLUMN_NAME,
         f.VALUE[0]::BOOLEAN AS EQUAL_BLANKS_NULL,
         f.VALUE[1]::BOOLEAN AS EQUAL_WITH_FILLS,
         f.VALUE[2]::BOOLEAN AS VALUE_IS_NULL_AFTER_FILLS
  FROM compared_rows r, LATERAL FLATTEN(INPUT => r.CELLS) f
),
per_row AS (
  SELECT MODEL_NAME, KEY_VALUE, BOOLAND_AGG(EQUAL_BLANKS_NULL) AS MATCH_BLANKS_NULL,
         BOOLAND_AGG(EQUAL_WITH_FILLS) AS MATCH_WITH_FILLS
  FROM cells
  GROUP BY MODEL_NAME, KEY_VALUE
),
count_checks AS (
  SELECT 'challenge rows' AS CHECK_NAME, COUNT(*) AS ACTUAL, 6120 AS EXPECTED FROM per_row
  UNION ALL
  SELECT 'rows equal to the clean release, blanks NULL', COUNT_IF(MATCH_BLANKS_NULL), 6116 FROM per_row
  UNION ALL
  SELECT 'rows equal to the clean release, with fills', COUNT_IF(MATCH_WITH_FILLS), 6118 FROM per_row
),
residuals (MODEL_NAME, KEY_VALUE, COLUMN_NAME) AS (   -- the 2 blank dates no evidence can recover
  SELECT * FROM VALUES
    ('stg_challenge_leads',       'L00000030',  'created_date'),
    ('stg_challenge_conversions', 'CV0000030',  'converted_date')
),
differing_after_fills AS (
  SELECT * FROM cells WHERE NOT EQUAL_WITH_FILLS
)
SELECT CHECK_NAME AS PROBLEM, NULL AS MODEL_NAME, NULL AS KEY_VALUE, NULL AS COLUMN_NAME, ACTUAL, EXPECTED
FROM count_checks
WHERE ACTUAL <> EXPECTED
UNION ALL
SELECT IFF(d.KEY_VALUE IS NULL, 'expected residual cell matches (or is missing)',
           IFF(r.KEY_VALUE IS NULL, 'unexpected differing cell after the fills', 'residual cell is not NULL')),
       COALESCE(d.MODEL_NAME, r.MODEL_NAME), COALESCE(d.KEY_VALUE, r.KEY_VALUE), COALESCE(d.COLUMN_NAME, r.COLUMN_NAME),
       NULL, NULL
FROM differing_after_fills d
FULL OUTER JOIN residuals r
  ON r.MODEL_NAME = d.MODEL_NAME AND r.KEY_VALUE = d.KEY_VALUE AND r.COLUMN_NAME = d.COLUMN_NAME
WHERE d.KEY_VALUE IS NULL OR r.KEY_VALUE IS NULL OR NOT d.VALUE_IS_NULL_AFTER_FILLS
