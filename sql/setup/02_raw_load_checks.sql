-- =============================================================================
-- RAW load checks: the same reconciliation as `make load`, as plain SQL for a human
-- -----------------------------------------------------------------------------
-- Run in a Snowsight worksheet after `make load` and `make load-challenge`, as
-- CRM_LOADER (it owns the RAW tables; INFORMATION_SCHEMA.COPY_HISTORY returns rows for
-- a role with USAGE on the database and schema and any privilege on the table).
-- Blocks 1, 2, 3, 3b and 5 return STATUS = PASS/FAIL rows. Block 4 has no STATUS: it
-- must return exactly the 11 rows listed in its comment. Block 6 shows COPY_HISTORY,
-- whose STATUS is Snowflake's load status (expect Loaded, ERROR_COUNT 0), not PASS/FAIL.
-- `scripts/run_sql.py --role CRM_LOADER` on this file exits 1 if any row says FAIL; it
-- cannot judge blocks 4 and 6, so read those yourself.
-- Expected values: local profiling of the CSVs on 2026-10-13 (two independent methods,
-- DuckDB and csv + Decimal, agreed exactly), row counts as in the publisher README.
-- Run the blocks one at a time (select a block, then Run) to see each result.
-- =============================================================================
USE ROLE CRM_LOADER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.RAW;


-- -----------------------------------------------------------------------------
-- 1. Row counts per RAW table
--    Clean release: 120 / 11,240 / 261,684 / 39,696.
--    Challenge extracts: 121 / 2,001 / 2,001 / 2,001 (each repeats its first data row
--    as the last line, so 1 exact duplicate per table).
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, ROW_COUNT, EXPECTED, IFF(ROW_COUNT = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 'CAMPAIGNS'             AS TABLE_NAME, COUNT(*) AS ROW_COUNT, 120    AS EXPECTED FROM RAW.CAMPAIGNS
  UNION ALL SELECT 'DAILY_SPEND',                         COUNT(*),              11240              FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'LEADS',                               COUNT(*),              261684             FROM RAW.LEADS
  UNION ALL SELECT 'CONVERSIONS',                         COUNT(*),              39696              FROM RAW.CONVERSIONS
  UNION ALL SELECT 'CHALLENGE_CAMPAIGNS',                 COUNT(*),              121                FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND',               COUNT(*),              2001               FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'CHALLENGE_LEADS',                     COUNT(*),              2001               FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS',               COUNT(*),              2001               FROM RAW.CHALLENGE_CONVERSIONS
)
ORDER BY TABLE_NAME;


-- -----------------------------------------------------------------------------
-- 2. Control totals of the clean release (exact, cast from the VARCHAR columns)
-- -----------------------------------------------------------------------------
SELECT METRIC, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 'campaigns: distinct campaign_id'       AS METRIC, COUNT(DISTINCT CAMPAIGN_ID)::NUMBER(38,2)   AS ACTUAL, 120::NUMBER(38,2)         AS EXPECTED FROM RAW.CAMPAIGNS
  UNION ALL SELECT 'campaigns: sum(budget)',                  SUM(TO_NUMBER(BUDGET, 12, 2)),                     5418642.16                FROM RAW.CAMPAIGNS
  UNION ALL SELECT 'daily_spend: distinct spend_id',          COUNT(DISTINCT SPEND_ID),                          11240                     FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'daily_spend: sum(spend)',                 SUM(TO_NUMBER(SPEND, 12, 2)),                      4523050.02                FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'daily_spend: sum(impressions)',           SUM(TO_NUMBER(IMPRESSIONS)),                       436844819                 FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'daily_spend: sum(clicks)',                SUM(TO_NUMBER(CLICKS)),                            7102319                   FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'leads: distinct lead_id',                 COUNT(DISTINCT LEAD_ID),                           261684                    FROM RAW.LEADS
  UNION ALL SELECT 'leads: sum(lead_score)',                  SUM(TO_NUMBER(LEAD_SCORE)),                        13233637                  FROM RAW.LEADS
  UNION ALL SELECT 'conversions: distinct conversion_id',     COUNT(DISTINCT CONVERSION_ID),                     39696                     FROM RAW.CONVERSIONS
  UNION ALL SELECT 'conversions: distinct lead_id (1:1)',     COUNT(DISTINCT LEAD_ID),                           39696                     FROM RAW.CONVERSIONS
  UNION ALL SELECT 'conversions: sum(revenue)',               SUM(TO_NUMBER(REVENUE, 12, 2)),                    21561839.01               FROM RAW.CONVERSIONS
  UNION ALL SELECT 'conversions: purchases',                  COUNT_IF(CONVERSION_TYPE = 'purchase'),            16691                     FROM RAW.CONVERSIONS
  UNION ALL SELECT 'conversions: trials',                     COUNT_IF(CONVERSION_TYPE = 'trial'),               23005                     FROM RAW.CONVERSIONS
  UNION ALL SELECT 'conversions: trial revenue',              SUM(IFF(CONVERSION_TYPE = 'trial', TO_NUMBER(REVENUE, 12, 2), 0)), 0.00     FROM RAW.CONVERSIONS
);


-- -----------------------------------------------------------------------------
-- 3. Lossless landing: no NULLs anywhere (NULL_IF = (), EMPTY_FIELD_AS_NULL = FALSE),
--    empty strings only where the files have them (clean: 0; challenge: 1 row per
--    table, data row 30), and one source file per table with contiguous row numbers.
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, ROWS_WITH_NULL, ROWS_WITH_EMPTY, EXPECTED_EMPTY, SOURCE_FILES,
       FIRST_ROW_NUMBER, LAST_ROW_NUMBER, ROW_COUNT, LOADED_AT,
       IFF(ROWS_WITH_NULL = 0 AND ROWS_WITH_EMPTY = EXPECTED_EMPTY AND SOURCE_FILES = 1
           AND LAST_ROW_NUMBER - FIRST_ROW_NUMBER + 1 = ROW_COUNT, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT 'CAMPAIGNS' AS TABLE_NAME,
         COUNT_IF(CAMPAIGN_ID IS NULL OR CAMPAIGN_NAME IS NULL OR CHANNEL IS NULL OR OBJECTIVE IS NULL
                  OR START_DATE IS NULL OR END_DATE IS NULL OR BUDGET IS NULL) AS ROWS_WITH_NULL,
         COUNT_IF(CAMPAIGN_ID = '' OR CAMPAIGN_NAME = '' OR CHANNEL = '' OR OBJECTIVE = ''
                  OR START_DATE = '' OR END_DATE = '' OR BUDGET = '') AS ROWS_WITH_EMPTY,
         0 AS EXPECTED_EMPTY,
         COUNT(DISTINCT _SOURCE_FILE) AS SOURCE_FILES, MIN(_SOURCE_ROW_NUMBER) AS FIRST_ROW_NUMBER,
         MAX(_SOURCE_ROW_NUMBER) AS LAST_ROW_NUMBER, COUNT(*) AS ROW_COUNT, MAX(_LOADED_AT) AS LOADED_AT
  FROM RAW.CAMPAIGNS
  UNION ALL
  SELECT 'DAILY_SPEND',
         COUNT_IF(SPEND_ID IS NULL OR CAMPAIGN_ID IS NULL OR SPEND_DATE IS NULL OR IMPRESSIONS IS NULL
                  OR CLICKS IS NULL OR SPEND IS NULL),
         COUNT_IF(SPEND_ID = '' OR CAMPAIGN_ID = '' OR SPEND_DATE = '' OR IMPRESSIONS = ''
                  OR CLICKS = '' OR SPEND = ''),
         0, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.DAILY_SPEND
  UNION ALL
  SELECT 'LEADS',
         COUNT_IF(LEAD_ID IS NULL OR CAMPAIGN_ID IS NULL OR CREATED_AT IS NULL OR LEAD_SOURCE IS NULL
                  OR LEAD_SCORE IS NULL),
         COUNT_IF(LEAD_ID = '' OR CAMPAIGN_ID = '' OR CREATED_AT = '' OR LEAD_SOURCE = '' OR LEAD_SCORE = ''),
         0, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.LEADS
  UNION ALL
  SELECT 'CONVERSIONS',
         COUNT_IF(CONVERSION_ID IS NULL OR LEAD_ID IS NULL OR CONVERTED_AT IS NULL
                  OR CONVERSION_TYPE IS NULL OR REVENUE IS NULL),
         COUNT_IF(CONVERSION_ID = '' OR LEAD_ID = '' OR CONVERTED_AT = '' OR CONVERSION_TYPE = '' OR REVENUE = ''),
         0, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.CONVERSIONS
  UNION ALL
  SELECT 'CHALLENGE_CAMPAIGNS',
         COUNT_IF(CAMPAIGN_ID IS NULL OR CAMPAIGN_NAME IS NULL OR CHANNEL IS NULL OR OBJECTIVE IS NULL
                  OR START_DATE IS NULL OR END_DATE IS NULL OR BUDGET IS NULL),
         COUNT_IF(CAMPAIGN_ID = '' OR CAMPAIGN_NAME = '' OR CHANNEL = '' OR OBJECTIVE = ''
                  OR START_DATE = '' OR END_DATE = '' OR BUDGET = ''),
         1, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL
  SELECT 'CHALLENGE_DAILY_SPEND',
         COUNT_IF(SPEND_ID IS NULL OR CAMPAIGN_ID IS NULL OR SPEND_DATE IS NULL OR IMPRESSIONS IS NULL
                  OR CLICKS IS NULL OR SPEND IS NULL),
         COUNT_IF(SPEND_ID = '' OR CAMPAIGN_ID = '' OR SPEND_DATE = '' OR IMPRESSIONS = ''
                  OR CLICKS = '' OR SPEND = ''),
         1, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL
  SELECT 'CHALLENGE_LEADS',
         COUNT_IF(LEAD_ID IS NULL OR CAMPAIGN_ID IS NULL OR CREATED_AT IS NULL OR LEAD_SOURCE IS NULL
                  OR LEAD_SCORE IS NULL),
         COUNT_IF(LEAD_ID = '' OR CAMPAIGN_ID = '' OR CREATED_AT = '' OR LEAD_SOURCE = '' OR LEAD_SCORE = ''),
         1, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.CHALLENGE_LEADS
  UNION ALL
  SELECT 'CHALLENGE_CONVERSIONS',
         COUNT_IF(CONVERSION_ID IS NULL OR LEAD_ID IS NULL OR CONVERTED_AT IS NULL
                  OR CONVERSION_TYPE IS NULL OR REVENUE IS NULL),
         COUNT_IF(CONVERSION_ID = '' OR LEAD_ID = '' OR CONVERTED_AT = '' OR CONVERSION_TYPE = '' OR REVENUE = ''),
         1, COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER), COUNT(*), MAX(_LOADED_AT)
  FROM RAW.CHALLENGE_CONVERSIONS
)
ORDER BY TABLE_NAME;


-- -----------------------------------------------------------------------------
-- 3b. Total characters per table, all business columns (whitespace and empty strings
--     preserved: a trimmed space or a NULLed field changes these). Expected values are
--     the local totals that `make load-dry-run` prints.
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, TOTAL_CHARACTERS, EXPECTED, IFF(TOTAL_CHARACTERS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 'CAMPAIGNS' AS TABLE_NAME,
                   SUM(LENGTH(CAMPAIGN_ID) + LENGTH(CAMPAIGN_NAME) + LENGTH(CHANNEL) + LENGTH(OBJECTIVE)
                       + LENGTH(START_DATE) + LENGTH(END_DATE) + LENGTH(BUDGET)) AS TOTAL_CHARACTERS,
                   8450 AS EXPECTED
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 'DAILY_SPEND',
                   SUM(LENGTH(SPEND_ID) + LENGTH(CAMPAIGN_ID) + LENGTH(SPEND_DATE) + LENGTH(IMPRESSIONS)
                       + LENGTH(CLICKS) + LENGTH(SPEND)), 461210
            FROM RAW.DAILY_SPEND
  UNION ALL SELECT 'LEADS',
                   SUM(LENGTH(LEAD_ID) + LENGTH(CAMPAIGN_ID) + LENGTH(CREATED_AT) + LENGTH(LEAD_SOURCE)
                       + LENGTH(LEAD_SCORE)), 9713610
            FROM RAW.LEADS
  UNION ALL SELECT 'CONVERSIONS',
                   SUM(LENGTH(CONVERSION_ID) + LENGTH(LEAD_ID) + LENGTH(CONVERTED_AT) + LENGTH(CONVERSION_TYPE)
                       + LENGTH(REVENUE)), 1562496
            FROM RAW.CONVERSIONS
  UNION ALL SELECT 'CHALLENGE_CAMPAIGNS',
                   SUM(LENGTH(CAMPAIGN_ID) + LENGTH(CAMPAIGN_NAME) + LENGTH(CHANNEL) + LENGTH(OBJECTIVE)
                       + LENGTH(START_DATE) + LENGTH(END_DATE) + LENGTH(BUDGET)), 8509
            FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND',
                   SUM(LENGTH(SPEND_ID) + LENGTH(CAMPAIGN_ID) + LENGTH(SPEND_DATE) + LENGTH(IMPRESSIONS)
                       + LENGTH(CLICKS) + LENGTH(SPEND)), 82300
            FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'CHALLENGE_LEADS',
                   SUM(LENGTH(LEAD_ID) + LENGTH(CAMPAIGN_ID) + LENGTH(CREATED_AT) + LENGTH(LEAD_SOURCE)
                       + LENGTH(LEAD_SCORE)), 77861
            FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS',
                   SUM(LENGTH(CONVERSION_ID) + LENGTH(LEAD_ID) + LENGTH(CONVERTED_AT) + LENGTH(CONVERSION_TYPE)
                       + LENGTH(REVENUE)), 78923
            FROM RAW.CHALLENGE_CONVERSIONS
)
ORDER BY TABLE_NAME;


-- -----------------------------------------------------------------------------
-- 4. The dirty values survived byte for byte (RAW must not have "fixed" anything).
--    Expect exactly these 11 rows (brackets make the spaces visible):
--      CHALLENGE_CAMPAIGNS    CMP0008    CAMPAIGN_NAME    [ DISPLAY 2023 008 ]
--      CHALLENGE_CAMPAIGNS    CMP0018    START_DATE       [2023/05/15]
--      CHALLENGE_CAMPAIGNS    CMP0030    CAMPAIGN_NAME    []
--      CHALLENGE_DAILY_SPEND  DSP0000018 SPEND_DATE       [2023/07/04]
--      CHALLENGE_DAILY_SPEND  DSP0000030 SPEND_DATE       []
--      CHALLENGE_LEADS        L00000008  LEAD_SOURCE      [ PAID_SEARCH ]
--      CHALLENGE_LEADS        L00000018  CREATED_AT       [2023/06/17]
--      CHALLENGE_LEADS        L00000030  CREATED_AT       []
--      CHALLENGE_CONVERSIONS  CV0000008  CONVERSION_TYPE  [ TRIAL ]
--      CHALLENGE_CONVERSIONS  CV0000018  CONVERTED_AT     [2023/07/05]
--      CHALLENGE_CONVERSIONS  CV0000030  CONVERTED_AT     []
--    and no rows from the clean tables (they have no such values).
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, KEY_VALUE, COLUMN_NAME, '[' || RAW_VALUE || ']' AS RAW_VALUE_BRACKETED, _SOURCE_ROW_NUMBER
FROM (
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, 'CAMPAIGN_NAME' AS COLUMN_NAME, CAMPAIGN_NAME AS RAW_VALUE, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CAMPAIGNS WHERE CAMPAIGN_NAME = '' OR CAMPAIGN_NAME <> TRIM(CAMPAIGN_NAME)
  UNION ALL SELECT 'CHALLENGE_CAMPAIGNS',   CAMPAIGN_ID,   'START_DATE',      START_DATE,      _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CAMPAIGNS   WHERE START_DATE LIKE '%/%'
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', SPEND_ID,      'SPEND_DATE',      SPEND_DATE,      _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_DAILY_SPEND WHERE SPEND_DATE = '' OR SPEND_DATE LIKE '%/%'
  UNION ALL SELECT 'CHALLENGE_LEADS',       LEAD_ID,       'LEAD_SOURCE',     LEAD_SOURCE,     _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_LEADS       WHERE LEAD_SOURCE <> TRIM(LEAD_SOURCE)
  UNION ALL SELECT 'CHALLENGE_LEADS',       LEAD_ID,       'CREATED_AT',      CREATED_AT,      _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_LEADS       WHERE CREATED_AT = '' OR CREATED_AT LIKE '%/%'
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERSION_TYPE', CONVERSION_TYPE, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CONVERSIONS WHERE CONVERSION_TYPE <> TRIM(CONVERSION_TYPE)
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERTED_AT',    CONVERTED_AT,    _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CONVERSIONS WHERE CONVERTED_AT = '' OR CONVERTED_AT LIKE '%/%'
  UNION ALL SELECT 'CAMPAIGNS',             CAMPAIGN_ID,   'CAMPAIGN_NAME',   CAMPAIGN_NAME,   _SOURCE_ROW_NUMBER FROM RAW.CAMPAIGNS             WHERE CAMPAIGN_NAME = '' OR CAMPAIGN_NAME <> TRIM(CAMPAIGN_NAME)
  UNION ALL SELECT 'LEADS',                 LEAD_ID,       'CREATED_AT',      CREATED_AT,      _SOURCE_ROW_NUMBER FROM RAW.LEADS                 WHERE CREATED_AT = '' OR CREATED_AT LIKE '%/%'
)
ORDER BY TABLE_NAME, KEY_VALUE, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 5. Exact duplicate rows (all business columns equal). Expect 0 for the clean tables
--    and 1 per challenge table (first data row repeated as the last line).
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, DUPLICATE_ROWS, EXPECTED, IFF(DUPLICATE_ROWS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT 'CAMPAIGNS' AS TABLE_NAME,
         (SELECT COUNT(*) FROM RAW.CAMPAIGNS)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET
                                  FROM RAW.CAMPAIGNS)) AS DUPLICATE_ROWS,
         0 AS EXPECTED
  UNION ALL
  SELECT 'CHALLENGE_CAMPAIGNS',
         (SELECT COUNT(*) FROM RAW.CHALLENGE_CAMPAIGNS)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET
                                  FROM RAW.CHALLENGE_CAMPAIGNS)),
         1
  UNION ALL
  SELECT 'CHALLENGE_DAILY_SPEND',
         (SELECT COUNT(*) FROM RAW.CHALLENGE_DAILY_SPEND)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND
                                  FROM RAW.CHALLENGE_DAILY_SPEND)),
         1
  UNION ALL
  SELECT 'CHALLENGE_LEADS',
         (SELECT COUNT(*) FROM RAW.CHALLENGE_LEADS)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE
                                  FROM RAW.CHALLENGE_LEADS)),
         1
  UNION ALL
  SELECT 'CHALLENGE_CONVERSIONS',
         (SELECT COUNT(*) FROM RAW.CHALLENGE_CONVERSIONS)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE
                                  FROM RAW.CHALLENGE_CONVERSIONS)),
         1
)
ORDER BY TABLE_NAME;


-- -----------------------------------------------------------------------------
-- 6. Load history (last 13 days; the INFORMATION_SCHEMA function covers 14 days at most,
--    and loses a table's history if the table is dropped or re-created).
--    Expect one LOADED row per file of the latest load, ROW_COUNT = ROW_PARSED, ERROR_COUNT 0.
--    TABLE_NAME is resolved in the current schema (USE SCHEMA above).
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, FILE_NAME, STATUS, ROW_PARSED, ROW_COUNT, ERROR_COUNT, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM (
            SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CAMPAIGNS',             START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'DAILY_SPEND',           START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'LEADS',                 START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CONVERSIONS',           START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CHALLENGE_CAMPAIGNS',   START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CHALLENGE_DAILY_SPEND', START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CHALLENGE_LEADS',       START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
  UNION ALL SELECT * FROM TABLE(MARKETING_CRM.INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'CHALLENGE_CONVERSIONS', START_TIME => DATEADD(DAY, -13, CURRENT_TIMESTAMP())))
)
ORDER BY LAST_LOAD_TIME DESC, TABLE_NAME;
