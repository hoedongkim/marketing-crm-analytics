-- =============================================================================
-- Phase 2 EDA: profile the clean RAW release in Snowflake SQL
-- -----------------------------------------------------------------------------
-- Purpose
--   Understand the structure and quality of the four clean RAW tables before any STAGING
--   model exists: documented types, keys and grain, NULLs and blanks, categorical domains,
--   numeric ranges and outliers, relationships, time logic, and a first grain-safe look at
--   the funnel by channel. Each block says what its result means for Phase 3 (STAGING
--   casts and tests) and for the MART grain.
--   Scope: the clean v1.0.0 release (RAW.CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS). The
--   RAW.CHALLENGE_* extracts appear only in the inventory (block 1); the Phase 3 cleaning
--   track profiles them.
-- Read-only
--   Only USE and SELECT statements. RAW stays all-VARCHAR (lossless landing); values are
--   cast inside the queries with TRY_TO_DATE(x, 'YYYY-MM-DD') and TRY_TO_NUMBER(x[, 12, 2]).
-- How to run
--   From the repository root:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/01_data_profiling.sql
--   run_sql.py prints every result (statement index + first SQL line, then the rows) and
--   exits 1 if any row has STATUS = 'FAIL'. In a Snowsight worksheet, run one numbered
--   block at a time. 32 statements, well under a minute on the X-Small MARKETING_WH.
--   Output of the last full run: docs/evidence/01_data_profiling.txt.
-- Role
--   CRM_TRANSFORMER: SELECT on every RAW table, no write access to RAW.
-- Reading the results
--   STATUS = PASS means Snowflake reproduced the expected value exactly. It says the data is
--   as profiled, not that it is "good": 4,716 conversions after their campaign ended is an
--   expected value, and a design input. Results without a STATUS column are descriptive, and
--   columns that a block calls diagnostic are shown but not part of its STATUS. Every block
--   that compares groups with an expected list uses a FULL OUTER JOIN, so a missing or an
--   unexpected group shows up as its own FAIL row instead of disappearing; each block is
--   complete on its own.
-- Where the expected values come from (all computed locally from the same CSV files,
--   independently of Snowflake: [P1]-[P3] before the account existed, [L2] during Phase 2)
--   [P1]  local profile "table integrity", 2026-10-13: types, keys, NULLs, domains, ranges,
--         date coverage (DuckDB, plus a byte-level Python scan of the files).
--   [P2]  local profile "relationships and time", 2026-10-13 (DuckDB): orphans, campaign
--         windows, conversion lag, censoring, totals by year and month.
--   [P3]  local profile "KPI reconciliation", 2026-10-13: channel bases and the fan-out,
--         computed twice (DuckDB, and Python csv + Decimal): 1,650 values, 0 mismatches.
--   [PUB] the publisher's reference output of its starter query (spend and attributed
--         revenue by channel), reproduced to the cent in [P3].
--   [L2]  Phase 2 local recompute, 2026-10-13 (Python csv + Decimal): quartiles, sample
--         standard deviations, IQR fences and outlier counts, average lead score by source,
--         campaigns by start/end year, same-day conversions by type, campaigns active /
--         started / ended per month, leads whose 21-day conversion window ends after the
--         last observed conversion.
--   Row counts also match the publisher README.
-- Percentiles
--   PERCENTILE_CONT and MEDIAN interpolate linearly between neighbouring values, like
--   DuckDB's quantile_cont and the [L2] recompute, so they match to the last digit.
--   (PERCENTILE_DISC would return an actual data value instead.) STDDEV is the sample
--   standard deviation and returns FLOAT, so it is compared at 4 decimal places.
-- Regex patterns use [0-9] (= \d) so that no backslash escaping is needed in SQL strings.
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] 0 context      [5] 1 inventory          [6-7] 2 data types     [8-9] 3 keys
--   [10] 4 NULLs/blanks  [11-13] 5 domains        [14-18] 6 numerics     [19-21] 7 relationships
--   [22-28] 8 time       [29] 9 grain (fan-out)   [30-32] 10 first look
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Context: the transformer role only, no secondary roles (no accidental writes)
-- -----------------------------------------------------------------------------
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.RAW;


-- -----------------------------------------------------------------------------
-- 1. Inventory: tables, row counts, columns
--    Question: are all eight RAW tables there, with the expected rows and columns?
--    Why: every later block assumes this shape. The column list must equal the CSV header
--      plus the three lineage columns, in that order, so no column can have shifted in the
--      load; every business column must be TEXT (lossless landing, architecture decision 1).
--    Expected: rows 120 / 11,240 / 261,684 / 39,696 (clean) and 121 / 2,001 / 2,001 / 2,001
--      (challenge, 1 exact duplicate each) [P1, publisher README]; 7 / 6 / 5 / 5 business
--      columns + 3 lineage columns; 0 non-TEXT business columns. ROW_COUNT is table
--      metadata, so this block scans no data.
-- -----------------------------------------------------------------------------
WITH expected_rows (TABLE_NAME, EXPECTED_ROWS) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS', 120), ('DAILY_SPEND', 11240), ('LEADS', 261684), ('CONVERSIONS', 39696),
    ('CHALLENGE_CAMPAIGNS', 121), ('CHALLENGE_DAILY_SPEND', 2001),
    ('CHALLENGE_LEADS', 2001), ('CHALLENGE_CONVERSIONS', 2001)
),
source_headers (SOURCE_TABLE, CSV_HEADER) AS (   -- the CSV header lines, upper-cased
  SELECT * FROM VALUES
    ('CAMPAIGNS',   'CAMPAIGN_ID,CAMPAIGN_NAME,CHANNEL,OBJECTIVE,START_DATE,END_DATE,BUDGET'),
    ('DAILY_SPEND', 'SPEND_ID,CAMPAIGN_ID,SPEND_DATE,IMPRESSIONS,CLICKS,SPEND'),
    ('LEADS',       'LEAD_ID,CAMPAIGN_ID,CREATED_AT,LEAD_SOURCE,LEAD_SCORE'),
    ('CONVERSIONS', 'CONVERSION_ID,LEAD_ID,CONVERTED_AT,CONVERSION_TYPE,REVENUE')
),
actual_tables AS (
  SELECT TABLE_NAME, ROW_COUNT
  FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES
  WHERE TABLE_SCHEMA = 'RAW' AND TABLE_TYPE = 'BASE TABLE'
),
actual_columns AS (
  SELECT TABLE_NAME,
         COUNT_IF(NOT STARTSWITH(COLUMN_NAME, '_'))                         AS BUSINESS_COLUMNS,
         COUNT_IF(STARTSWITH(COLUMN_NAME, '_'))                             AS LINEAGE_COLUMNS,
         COUNT_IF(NOT STARTSWITH(COLUMN_NAME, '_') AND DATA_TYPE <> 'TEXT') AS NON_TEXT_BUSINESS_COLUMNS,
         LISTAGG(COLUMN_NAME, ',') WITHIN GROUP (ORDER BY ORDINAL_POSITION) AS COLUMN_LIST
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'RAW'
  GROUP BY TABLE_NAME
),
inventory AS (
  SELECT COALESCE(e.TABLE_NAME, t.TABLE_NAME) AS TABLE_NAME,
         t.ROW_COUNT, e.EXPECTED_ROWS,
         c.BUSINESS_COLUMNS, c.LINEAGE_COLUMNS, c.NON_TEXT_BUSINESS_COLUMNS,
         c.COLUMN_LIST = (h.CSV_HEADER || ',_SOURCE_FILE,_SOURCE_ROW_NUMBER,_LOADED_AT') AS COLUMNS_MATCH_HEADER
  FROM expected_rows e
  FULL OUTER JOIN actual_tables t ON t.TABLE_NAME = e.TABLE_NAME
  LEFT JOIN actual_columns c ON c.TABLE_NAME = COALESCE(e.TABLE_NAME, t.TABLE_NAME)
  LEFT JOIN source_headers h ON h.SOURCE_TABLE = REGEXP_REPLACE(COALESCE(e.TABLE_NAME, t.TABLE_NAME), '^CHALLENGE_', '')
)
SELECT TABLE_NAME, ROW_COUNT, EXPECTED_ROWS, BUSINESS_COLUMNS, LINEAGE_COLUMNS,
       NON_TEXT_BUSINESS_COLUMNS, COLUMNS_MATCH_HEADER,
       IFF(ROW_COUNT = EXPECTED_ROWS AND NON_TEXT_BUSINESS_COLUMNS = 0 AND LINEAGE_COLUMNS = 3
           AND COLUMNS_MATCH_HEADER, 'PASS', 'FAIL') AS STATUS
FROM inventory
ORDER BY STARTSWITH(TABLE_NAME, 'CHALLENGE_'),
         DECODE(REGEXP_REPLACE(TABLE_NAME, '^CHALLENGE_', ''), 'CAMPAIGNS', 1, 'DAILY_SPEND', 2, 'LEADS', 3, 4);


-- -----------------------------------------------------------------------------
-- 2. Data types: does every value fit its documented type?
-- -----------------------------------------------------------------------------
-- 2.1 Non-conforming values per table and documented type (one row per group)
--    Question: would a strict cast to the documented type lose or change any value?
--    Why: STAGING casts every column (DATE, NUMBER(12,2), NUMBER(38,0)); this block proves
--      the casts are lossless for the clean release, and its rules become the STAGING
--      tests. A value is conforming only if it matches the pattern AND the TRY_ cast
--      succeeds (2.2 shows why one of the two is not enough):
--        date      ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ and TRY_TO_DATE(x, 'YYYY-MM-DD') not null
--        integer   ^[0-9]+$ and TRY_TO_NUMBER(x) not null
--        money     ^[0-9]+[.][0-9]{2}$ and TRY_TO_NUMBER(x, 12, 2) not null
--        category  lower-case snake_case; name: '<Channel In Title Case> <yyyy> <nnn>'
--        keys      fixed-width IDs: CMP0000, DSP0000000, L00000000, CV0000000
--      A NULL counts as non-conforming (block 4 says why it would be there).
--    Expected: 0 non-conforming values in all 20 groups [P1 s2, P3 F0].
-- -----------------------------------------------------------------------------
WITH documented_types (TABLE_NAME, COLUMN_NAME, ORDINAL, DOC_TYPE) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS',   'CAMPAIGN_ID',     1, 'key CMP0000'),
    ('CAMPAIGNS',   'CAMPAIGN_NAME',   2, 'name'),
    ('CAMPAIGNS',   'CHANNEL',         3, 'category'),
    ('CAMPAIGNS',   'OBJECTIVE',       4, 'category'),
    ('CAMPAIGNS',   'START_DATE',      5, 'date'),
    ('CAMPAIGNS',   'END_DATE',        6, 'date'),
    ('CAMPAIGNS',   'BUDGET',          7, 'money'),
    ('DAILY_SPEND', 'SPEND_ID',        1, 'key DSP0000000'),
    ('DAILY_SPEND', 'CAMPAIGN_ID',     2, 'key CMP0000'),
    ('DAILY_SPEND', 'SPEND_DATE',      3, 'date'),
    ('DAILY_SPEND', 'IMPRESSIONS',     4, 'integer'),
    ('DAILY_SPEND', 'CLICKS',          5, 'integer'),
    ('DAILY_SPEND', 'SPEND',           6, 'money'),
    ('LEADS',       'LEAD_ID',         1, 'key L00000000'),
    ('LEADS',       'CAMPAIGN_ID',     2, 'key CMP0000'),
    ('LEADS',       'CREATED_AT',      3, 'date'),
    ('LEADS',       'LEAD_SOURCE',     4, 'category'),
    ('LEADS',       'LEAD_SCORE',      5, 'integer'),
    ('CONVERSIONS', 'CONVERSION_ID',   1, 'key CV0000000'),
    ('CONVERSIONS', 'LEAD_ID',         2, 'key L00000000'),
    ('CONVERSIONS', 'CONVERTED_AT',    3, 'date'),
    ('CONVERSIONS', 'CONVERSION_TYPE', 4, 'category'),
    ('CONVERSIONS', 'REVENUE',         5, 'money')
),
raw_values AS (   -- one row per (table, column, value): the four tables unpivoted, NULLs kept
  SELECT 'CAMPAIGNS' AS TABLE_NAME, COLUMN_NAME, VAL
  FROM RAW.CAMPAIGNS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL
  SELECT 'DAILY_SPEND', COLUMN_NAME, VAL
  FROM RAW.DAILY_SPEND UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL
  SELECT 'LEADS', COLUMN_NAME, VAL
  FROM RAW.LEADS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL
  SELECT 'CONVERSIONS', COLUMN_NAME, VAL
  FROM RAW.CONVERSIONS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
checked AS (
  SELECT d.TABLE_NAME, d.COLUMN_NAME, d.ORDINAL, d.DOC_TYPE,
         COALESCE(CASE d.DOC_TYPE
           WHEN 'date'           THEN REGEXP_LIKE(v.VAL, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
                                      AND TRY_TO_DATE(v.VAL, 'YYYY-MM-DD') IS NOT NULL
           WHEN 'integer'        THEN REGEXP_LIKE(v.VAL, '^[0-9]+$')
                                      AND TRY_TO_NUMBER(v.VAL) IS NOT NULL
           WHEN 'money'          THEN REGEXP_LIKE(v.VAL, '^[0-9]+[.][0-9]{2}$')
                                      AND TRY_TO_NUMBER(v.VAL, 12, 2) IS NOT NULL
           WHEN 'category'       THEN REGEXP_LIKE(v.VAL, '^[a-z]+(_[a-z]+)*$')
           WHEN 'name'           THEN REGEXP_LIKE(v.VAL, '^[A-Z][a-z]+( [A-Z][a-z]+)* [0-9]{4} [0-9]{3}$')
           WHEN 'key CMP0000'    THEN REGEXP_LIKE(v.VAL, '^CMP[0-9]{4}$')
           WHEN 'key DSP0000000' THEN REGEXP_LIKE(v.VAL, '^DSP[0-9]{7}$')
           WHEN 'key L00000000'  THEN REGEXP_LIKE(v.VAL, '^L[0-9]{8}$')
           WHEN 'key CV0000000'  THEN REGEXP_LIKE(v.VAL, '^CV[0-9]{7}$')
         END, FALSE) AS CONFORMS
  FROM documented_types d
  LEFT JOIN raw_values v ON v.TABLE_NAME = d.TABLE_NAME AND v.COLUMN_NAME = d.COLUMN_NAME
),
per_column AS (
  SELECT TABLE_NAME, COLUMN_NAME, ORDINAL, DOC_TYPE,
         COUNT(*) AS VALUES_CHECKED, COUNT_IF(NOT CONFORMS) AS NON_CONFORMING
  FROM checked
  GROUP BY TABLE_NAME, COLUMN_NAME, ORDINAL, DOC_TYPE
)
SELECT TABLE_NAME, DOC_TYPE,
       LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY ORDINAL) AS COLUMNS_CHECKED,
       SUM(VALUES_CHECKED) AS VALUES_CHECKED,
       SUM(NON_CONFORMING) AS NON_CONFORMING,
       0 AS EXPECTED,
       IFF(SUM(NON_CONFORMING) = 0, 'PASS', 'FAIL') AS STATUS
FROM per_column
GROUP BY TABLE_NAME, DOC_TYPE
ORDER BY DECODE(TABLE_NAME, 'CAMPAIGNS', 1, 'DAILY_SPEND', 2, 'LEADS', 3, 4), MIN(ORDINAL);


-- -----------------------------------------------------------------------------
-- 2.2 Why STAGING needs both the pattern and the TRY_ cast (a test of the rule itself)
--    Question: what do Snowflake's TRY_ casts do with slightly malformed text?
--    Why: they are lenient. TRY_TO_DATE('2023-1-5', 'YYYY-MM-DD') returns 2023-01-05,
--      TRY_TO_NUMBER(' 42') returns 42, and TRY_TO_NUMBER('1250.405', 12, 2) silently
--      rounds to 1250.41. A cast alone would hide format drift (and a third decimal place
--      in money); a pattern alone would accept 2023-02-29. The dirty challenge extracts
--      contain exactly this kind of value (2023/05/15, ' TRIAL '), so the STAGING tests
--      use the combined rule from 2.1.
--    Expected: CONFORMS = EXPECTED_CONFORMS for all 10 inputs (brackets show spaces).
-- -----------------------------------------------------------------------------
WITH inputs (RAW_INPUT, DOC_TYPE, EXPECTED_CONFORMS) AS (
  SELECT * FROM VALUES
    ('2023-01-05', 'date',    TRUE),
    ('2023-1-5',   'date',    FALSE),   -- cast accepts it, pattern rejects it
    ('2023/05/15', 'date',    FALSE),   -- the challenge extracts' slash format
    ('2023-02-29', 'date',    FALSE),   -- pattern accepts it, cast rejects it
    ('1250.40',    'money',   TRUE),
    ('1250.405',   'money',   FALSE),   -- cast rounds it to 1250.41
    ('1250.4',     'money',   FALSE),   -- cast pads it to 1250.40
    ('42',         'integer', TRUE),
    (' 42',        'integer', FALSE),   -- cast trims it
    ('42.0',       'integer', FALSE)    -- cast drops the decimal part
),
evaluated AS (
  SELECT RAW_INPUT, DOC_TYPE, EXPECTED_CONFORMS,
         CASE DOC_TYPE
           WHEN 'date'    THEN TO_VARCHAR(TRY_TO_DATE(RAW_INPUT, 'YYYY-MM-DD'))
           WHEN 'money'   THEN TO_VARCHAR(TRY_TO_NUMBER(RAW_INPUT, 12, 2))
           WHEN 'integer' THEN TO_VARCHAR(TRY_TO_NUMBER(RAW_INPUT))
         END AS TRY_CAST_RESULT,
         CASE DOC_TYPE
           WHEN 'date'    THEN REGEXP_LIKE(RAW_INPUT, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
           WHEN 'money'   THEN REGEXP_LIKE(RAW_INPUT, '^[0-9]+[.][0-9]{2}$')
           WHEN 'integer' THEN REGEXP_LIKE(RAW_INPUT, '^[0-9]+$')
         END AS MATCHES_PATTERN
  FROM inputs
),
judged AS (
  SELECT RAW_INPUT, DOC_TYPE, TRY_CAST_RESULT, MATCHES_PATTERN, EXPECTED_CONFORMS,
         COALESCE(MATCHES_PATTERN AND TRY_CAST_RESULT IS NOT NULL, FALSE) AS CONFORMS
  FROM evaluated
)
SELECT '[' || RAW_INPUT || ']' AS INPUT_TEXT, DOC_TYPE, TRY_CAST_RESULT, MATCHES_PATTERN,
       CONFORMS, EXPECTED_CONFORMS,
       IFF(CONFORMS = EXPECTED_CONFORMS, 'PASS', 'FAIL') AS STATUS
FROM judged
ORDER BY DECODE(DOC_TYPE, 'date', 1, 'money', 2, 3), EXPECTED_CONFORMS DESC, RAW_INPUT;


-- -----------------------------------------------------------------------------
-- 3. Primary keys and grain
-- -----------------------------------------------------------------------------
-- 3.1 Keys: rows vs distinct key values, and exact duplicate rows
--    Question: is every declared key unique, and is each table at its documented grain?
--    Why: Snowflake does not enforce PRIMARY KEY or UNIQUE constraints, so nothing stops a
--      duplicate from landing. A duplicated key fans out every join that uses it; MART
--      grain (dim_campaign 120 rows, campaign x date activity, one row per lead) depends on
--      these keys. CONVERSIONS.LEAD_ID unique means LEADS -> CONVERSIONS is 1:0..1, so a
--      LEFT JOIN from leads to conversions can never duplicate a lead. Each key row becomes
--      a dbt unique / unique_combination_of_columns test in Phase 5.
--      The "exact duplicate rows" lines are diagnostic: they include the PK, so they cannot
--      be non-zero while the PK line passes. They matter on the CHALLENGE_* extracts, where
--      they tell an exact repeated row apart from two different rows that share a key. They
--      count rows with SELECT DISTINCT, which treats NULLs as equal; a multi-column
--      COUNT(DISTINCT a, b, ...) would skip every row with a NULL in any column and so
--      report a NULL as a duplicate. On the key lines that same skip is intended: a NULL
--      key is a key violation too, and block 4 reports NULLs on their own.
--    Expected: 0 duplicates in all 11 rows [P1 s5, s6; P3 F0].
-- -----------------------------------------------------------------------------
SELECT TABLE_NAME, KEY_COLUMNS, ROW_COUNT, DISTINCT_KEYS,
       ROW_COUNT - DISTINCT_KEYS AS DUPLICATES,
       0 AS EXPECTED,
       IFF(ROW_COUNT - DISTINCT_KEYS = 0, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'CAMPAIGNS' AS TABLE_NAME, 'CAMPAIGN_ID (PK)' AS KEY_COLUMNS,
                   COUNT(*) AS ROW_COUNT, COUNT(DISTINCT CAMPAIGN_ID) AS DISTINCT_KEYS
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'CAMPAIGNS', 'CAMPAIGN_NAME (alternate key)',
                   COUNT(*), COUNT(DISTINCT CAMPAIGN_NAME)
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 3, 'CAMPAIGNS', 'all 7 columns (exact duplicate rows)',
                   COUNT(*), (SELECT COUNT(*) FROM (SELECT DISTINCT CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL,
                                                      OBJECTIVE, START_DATE, END_DATE, BUDGET
                                                    FROM RAW.CAMPAIGNS))
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 4, 'DAILY_SPEND', 'SPEND_ID (PK)',
                   COUNT(*), COUNT(DISTINCT SPEND_ID)
            FROM RAW.DAILY_SPEND
  UNION ALL SELECT 5, 'DAILY_SPEND', 'CAMPAIGN_ID + SPEND_DATE (grain)',
                   COUNT(*), COUNT(DISTINCT CAMPAIGN_ID, SPEND_DATE)
            FROM RAW.DAILY_SPEND
  UNION ALL SELECT 6, 'DAILY_SPEND', 'all 6 columns (exact duplicate rows)',
                   COUNT(*), (SELECT COUNT(*) FROM (SELECT DISTINCT SPEND_ID, CAMPAIGN_ID, SPEND_DATE,
                                                      IMPRESSIONS, CLICKS, SPEND
                                                    FROM RAW.DAILY_SPEND))
            FROM RAW.DAILY_SPEND
  UNION ALL SELECT 7, 'LEADS', 'LEAD_ID (PK)',
                   COUNT(*), COUNT(DISTINCT LEAD_ID)
            FROM RAW.LEADS
  UNION ALL SELECT 8, 'LEADS', 'all 5 columns (exact duplicate rows)',
                   COUNT(*), (SELECT COUNT(*) FROM (SELECT DISTINCT LEAD_ID, CAMPAIGN_ID, CREATED_AT,
                                                      LEAD_SOURCE, LEAD_SCORE
                                                    FROM RAW.LEADS))
            FROM RAW.LEADS
  UNION ALL SELECT 9, 'CONVERSIONS', 'CONVERSION_ID (PK)',
                   COUNT(*), COUNT(DISTINCT CONVERSION_ID)
            FROM RAW.CONVERSIONS
  UNION ALL SELECT 10, 'CONVERSIONS', 'LEAD_ID (1 conversion per lead)',
                   COUNT(*), COUNT(DISTINCT LEAD_ID)
            FROM RAW.CONVERSIONS
  UNION ALL SELECT 11, 'CONVERSIONS', 'all 5 columns (exact duplicate rows)',
                   COUNT(*), (SELECT COUNT(*) FROM (SELECT DISTINCT CONVERSION_ID, LEAD_ID, CONVERTED_AT,
                                                      CONVERSION_TYPE, REVENUE
                                                    FROM RAW.CONVERSIONS))
            FROM RAW.CONVERSIONS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 3.2 Key sequences: are the IDs gap-free surrogate numbers 1..N?
--    Question: does the numeric part of each key run from 1 to the row count?
--    Why: the keys are surrogates with no business meaning (campaign_id order does not
--      follow start dates: in 54 of the 119 adjacent campaign_id pairs, the second campaign
--      starts earlier than the first [P1 s8a3, which says "of 120"; 120 campaigns form 119
--      pairs]). A gap-free 1..N sequence plus 3.1 shows that nothing was dropped between
--      the publisher's export and RAW. ID order must never be used as a proxy for time.
--    Expected: first 1, last = rows, 0 missing numbers in all four tables [P1 s5b].
-- -----------------------------------------------------------------------------
WITH key_numbers AS (   -- the numeric part of each key
            SELECT 1 AS ORD, 'CAMPAIGNS' AS TABLE_NAME, 'CAMPAIGN_ID' AS KEY_COLUMN,
                   TO_NUMBER(REGEXP_SUBSTR(CAMPAIGN_ID, '[0-9]+$')) AS K FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'DAILY_SPEND', 'SPEND_ID',
                   TO_NUMBER(REGEXP_SUBSTR(SPEND_ID, '[0-9]+$')) FROM RAW.DAILY_SPEND
  UNION ALL SELECT 3, 'LEADS', 'LEAD_ID',
                   TO_NUMBER(REGEXP_SUBSTR(LEAD_ID, '[0-9]+$')) FROM RAW.LEADS
  UNION ALL SELECT 4, 'CONVERSIONS', 'CONVERSION_ID',
                   TO_NUMBER(REGEXP_SUBSTR(CONVERSION_ID, '[0-9]+$')) FROM RAW.CONVERSIONS
)
SELECT TABLE_NAME, KEY_COLUMN,
       MIN(K) AS FIRST_NUMBER, MAX(K) AS LAST_NUMBER, COUNT(*) AS ROW_COUNT,
       MAX(K) - MIN(K) + 1 - COUNT(DISTINCT K) AS MISSING_NUMBERS,
       IFF(MIN(K) = 1 AND MAX(K) = COUNT(*) AND COUNT(DISTINCT K) = COUNT(*), 'PASS', 'FAIL') AS STATUS
FROM key_numbers
GROUP BY ORD, TABLE_NAME, KEY_COLUMN
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4. NULLs, blanks, whitespace and null-like tokens, per column
--    Question: is any value missing, blank, padded, a placeholder such as 'N/A', or
--      outside printable ASCII?
--    Why: RAW keeps empty strings as '' and never converts text to NULL (EMPTY_FIELD_AS_NULL
--      = FALSE, NULL_IF = ()), so "missing" can only show up as one of these patterns. On the
--      clean release every count must be 0, which means STAGING's NULLIF(TRIM(x), '') guard
--      changes nothing here and only matters for the challenge extracts (4 blank required
--      values, ' PAID_SEARCH ', ' TRIAL '). TRIM here strips space, tab, CR and LF.
--      DISTINCT_VALUES and the lengths are descriptive (VARCHAR sizing, cardinality).
--    Expected: 0 in every problem column for all 23 business columns [P1 s2]; distinct
--      values and lengths as in [P1 s2] (e.g. LEAD_SCORE 100 distinct, length 1-3).
-- -----------------------------------------------------------------------------
WITH raw_values AS (   -- same unpivot as block 2.1
  SELECT 'CAMPAIGNS' AS TABLE_NAME, COLUMN_NAME, VAL
  FROM RAW.CAMPAIGNS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL
  SELECT 'DAILY_SPEND', COLUMN_NAME, VAL
  FROM RAW.DAILY_SPEND UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL
  SELECT 'LEADS', COLUMN_NAME, VAL
  FROM RAW.LEADS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL
  SELECT 'CONVERSIONS', COLUMN_NAME, VAL
  FROM RAW.CONVERSIONS UNPIVOT INCLUDE NULLS (VAL FOR COLUMN_NAME IN
       (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
profile AS (
  SELECT TABLE_NAME, COLUMN_NAME,
         COUNT(*)                                                    AS ROW_COUNT,
         COUNT_IF(VAL IS NULL)                                       AS NULLS,
         COUNT_IF(VAL = '')                                          AS EMPTY_STRINGS,
         COUNT_IF(VAL <> '' AND TRIM(VAL, ' \t\r\n') = '')           AS WHITESPACE_ONLY,
         COUNT_IF(VAL <> TRIM(VAL, ' \t\r\n'))                       AS UNTRIMMED,
         COUNT_IF(UPPER(TRIM(VAL, ' \t\r\n')) IN ('NULL', 'NA', 'N/A', 'NONE', 'NAN', 'NIL',
                                                   '-', '?', 'UNKNOWN', '#N/A')) AS NULL_TOKENS,
         COUNT_IF(REGEXP_LIKE(VAL, '.*[^ -~].*', 's'))               AS NON_PRINTABLE,
         COUNT(DISTINCT VAL)                                         AS DISTINCT_VALUES,
         MIN(LENGTH(VAL))                                            AS MIN_LENGTH,
         MAX(LENGTH(VAL))                                            AS MAX_LENGTH
  FROM raw_values
  GROUP BY TABLE_NAME, COLUMN_NAME
)
SELECT p.TABLE_NAME, p.COLUMN_NAME, p.ROW_COUNT, p.NULLS, p.EMPTY_STRINGS, p.WHITESPACE_ONLY,
       p.UNTRIMMED, p.NULL_TOKENS, p.NON_PRINTABLE, p.DISTINCT_VALUES, p.MIN_LENGTH, p.MAX_LENGTH,
       IFF(p.NULLS + p.EMPTY_STRINGS + p.WHITESPACE_ONLY + p.UNTRIMMED + p.NULL_TOKENS
           + p.NON_PRINTABLE = 0, 'PASS', 'FAIL') AS STATUS
FROM profile p
JOIN MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS c
  ON c.TABLE_SCHEMA = 'RAW' AND c.TABLE_NAME = p.TABLE_NAME AND c.COLUMN_NAME = p.COLUMN_NAME
ORDER BY DECODE(p.TABLE_NAME, 'CAMPAIGNS', 1, 'DAILY_SPEND', 2, 'LEADS', 3, 4), c.ORDINAL_POSITION;


-- -----------------------------------------------------------------------------
-- 5. Categorical domains
-- -----------------------------------------------------------------------------
-- 5.1 Value counts per categorical column, against the profiled counts
--    Question: which values occur, how often, and is there any value nobody expected?
--    Why: these are the dimension members of every dashboard filter. The FULL OUTER JOIN
--      makes an unexpected value (a new channel, 'Paid_Search', ' trial ') show up as its
--      own FAIL row instead of disappearing into a total. Channel is balanced (24 campaigns
--      each) but lead volume is not: video has 25,799 leads, affiliate 67,849.
--    Expected: the 15 values and counts below [P1 s7a, s7b, s7d, s7e].
-- -----------------------------------------------------------------------------
WITH expected (COLUMN_NAME, DOMAIN_VALUE, EXPECTED_ROWS) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS.CHANNEL', 'affiliate', 24), ('CAMPAIGNS.CHANNEL', 'display', 24),
    ('CAMPAIGNS.CHANNEL', 'paid_search', 24), ('CAMPAIGNS.CHANNEL', 'paid_social', 24),
    ('CAMPAIGNS.CHANNEL', 'video', 24),
    ('CAMPAIGNS.OBJECTIVE', 'acquisition', 35), ('CAMPAIGNS.OBJECTIVE', 'awareness', 44),
    ('CAMPAIGNS.OBJECTIVE', 'lead_gen', 41),
    ('LEADS.LEAD_SOURCE', 'affiliate', 67849), ('LEADS.LEAD_SOURCE', 'display', 45149),
    ('LEADS.LEAD_SOURCE', 'paid_search', 65268), ('LEADS.LEAD_SOURCE', 'paid_social', 57619),
    ('LEADS.LEAD_SOURCE', 'video', 25799),
    ('CONVERSIONS.CONVERSION_TYPE', 'purchase', 16691), ('CONVERSIONS.CONVERSION_TYPE', 'trial', 23005)
),
actual AS (
            SELECT 'CAMPAIGNS.CHANNEL' AS COLUMN_NAME, CHANNEL AS DOMAIN_VALUE, COUNT(*) AS ROW_COUNT
            FROM RAW.CAMPAIGNS GROUP BY CHANNEL
  UNION ALL SELECT 'CAMPAIGNS.OBJECTIVE', OBJECTIVE, COUNT(*) FROM RAW.CAMPAIGNS GROUP BY OBJECTIVE
  UNION ALL SELECT 'LEADS.LEAD_SOURCE', LEAD_SOURCE, COUNT(*) FROM RAW.LEADS GROUP BY LEAD_SOURCE
  UNION ALL SELECT 'CONVERSIONS.CONVERSION_TYPE', CONVERSION_TYPE, COUNT(*)
            FROM RAW.CONVERSIONS GROUP BY CONVERSION_TYPE
),
joined AS (
  SELECT COALESCE(a.COLUMN_NAME, e.COLUMN_NAME)   AS COLUMN_NAME,
         COALESCE(a.DOMAIN_VALUE, e.DOMAIN_VALUE) AS DOMAIN_VALUE,
         a.ROW_COUNT, e.EXPECTED_ROWS
  FROM actual a
  FULL OUTER JOIN expected e ON e.COLUMN_NAME = a.COLUMN_NAME AND e.DOMAIN_VALUE = a.DOMAIN_VALUE
)
SELECT COLUMN_NAME, DOMAIN_VALUE, ROW_COUNT,
       ROUND(ROW_COUNT / SUM(ROW_COUNT) OVER (PARTITION BY COLUMN_NAME), 4) AS SHARE,
       EXPECTED_ROWS,
       IFF(ROW_COUNT = EXPECTED_ROWS, 'PASS', 'FAIL') AS STATUS
FROM joined
ORDER BY DECODE(SPLIT_PART(COLUMN_NAME, '.', 1), 'CAMPAIGNS', 1, 'LEADS', 2, 3), COLUMN_NAME, DOMAIN_VALUE;


-- -----------------------------------------------------------------------------
-- 5.2 Channel x objective matrix (campaign counts; descriptive)
--    Question: is every objective run on every channel in similar numbers?
--    Why: no. Display is mostly lead_gen (17 of 24). Awareness is the largest objective for
--      affiliate (11 of 24) and video (12 of 24), but a majority for neither; paid search and
--      paid social are spread more evenly. Channel and objective are confounded, so a later "objective" comparison that ignores
--      channel would mostly re-measure channel differences. Phase 4 compares objectives
--      within a channel, or says so.
--    Expected: the matrix in [P1 s7c]; 35 / 44 / 41 objectives, 120 campaigns.
-- -----------------------------------------------------------------------------
SELECT IFF(GROUPING(c.CHANNEL) = 1, 'TOTAL', c.CHANNEL) AS CHANNEL,
       COUNT_IF(c.OBJECTIVE = 'acquisition') AS ACQUISITION,
       COUNT_IF(c.OBJECTIVE = 'awareness')   AS AWARENESS,
       COUNT_IF(c.OBJECTIVE = 'lead_gen')    AS LEAD_GEN,
       COUNT(*)                              AS CAMPAIGNS
FROM RAW.CAMPAIGNS c
GROUP BY ROLLUP (c.CHANNEL)
ORDER BY GROUPING(c.CHANNEL), c.CHANNEL;


-- -----------------------------------------------------------------------------
-- 5.3 Accepted values (the dbt accepted_values test, written as SQL)
--    Question: does any row fall outside the accepted set, and are there case or
--      whitespace variants of one value?
--    Why: this is the exact form of the Phase 5 tests. CASE_OR_WHITESPACE_VARIANTS counts
--      values that collapse into another one under LOWER(TRIM(x, ' \t\r\n')), the same TRIM
--      as block 4 (the default TRIM strips only blanks, not tabs). It is a diagnostic for
--      the challenge track (' PAID_SEARCH ', ' TRIAL ') and not part of STATUS: every
--      accepted value is lower-case and unpadded, so once ROWS_OUTSIDE_ACCEPTED is 0 the
--      variant count is 0 by construction and adds no failure mode.
--    Expected: 0 rows outside; 5 / 3 / 5 / 2 distinct values [P1 s7f]; 0 variants.
-- -----------------------------------------------------------------------------
SELECT COLUMN_NAME, ROW_COUNT, ROWS_OUTSIDE_ACCEPTED, DISTINCT_VALUES, EXPECTED_DISTINCT,
       CASE_OR_WHITESPACE_VARIANTS,
       IFF(ROWS_OUTSIDE_ACCEPTED = 0 AND DISTINCT_VALUES = EXPECTED_DISTINCT, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'CAMPAIGNS.CHANNEL' AS COLUMN_NAME, COUNT(*) AS ROW_COUNT,
                   COUNT_IF(CHANNEL IS NULL
                            OR CHANNEL NOT IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video'))
                     AS ROWS_OUTSIDE_ACCEPTED,
                   COUNT(DISTINCT CHANNEL) AS DISTINCT_VALUES, 5 AS EXPECTED_DISTINCT,
                   COUNT(DISTINCT CHANNEL) - COUNT(DISTINCT LOWER(TRIM(CHANNEL, ' \t\r\n')))
                     AS CASE_OR_WHITESPACE_VARIANTS   -- diagnostic
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'CAMPAIGNS.OBJECTIVE', COUNT(*),
                   COUNT_IF(OBJECTIVE IS NULL OR OBJECTIVE NOT IN ('acquisition', 'awareness', 'lead_gen')),
                   COUNT(DISTINCT OBJECTIVE), 3,
                   COUNT(DISTINCT OBJECTIVE) - COUNT(DISTINCT LOWER(TRIM(OBJECTIVE, ' \t\r\n')))
            FROM RAW.CAMPAIGNS
  UNION ALL SELECT 3, 'LEADS.LEAD_SOURCE', COUNT(*),
                   COUNT_IF(LEAD_SOURCE IS NULL
                            OR LEAD_SOURCE NOT IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video')),
                   COUNT(DISTINCT LEAD_SOURCE), 5,
                   COUNT(DISTINCT LEAD_SOURCE) - COUNT(DISTINCT LOWER(TRIM(LEAD_SOURCE, ' \t\r\n')))
            FROM RAW.LEADS
  UNION ALL SELECT 4, 'CONVERSIONS.CONVERSION_TYPE', COUNT(*),
                   COUNT_IF(CONVERSION_TYPE IS NULL OR CONVERSION_TYPE NOT IN ('purchase', 'trial')),
                   COUNT(DISTINCT CONVERSION_TYPE), 2,
                   COUNT(DISTINCT CONVERSION_TYPE) - COUNT(DISTINCT LOWER(TRIM(CONVERSION_TYPE, ' \t\r\n')))
            FROM RAW.CONVERSIONS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6. Numeric distributions, outliers and business rules
-- -----------------------------------------------------------------------------
-- 6.1 Distribution of every measure
--    Question: what range, centre and spread does each measure have?
--    Why: sets the types (all money fits NUMBER(12,2)), the axis ranges of the dashboard,
--      and shows the shape: impressions and clicks are right-skewed (mean > median),
--      lead_score is near-uniform on 1-100 (mean 50.57, sd 28.87, the sd of a uniform
--      1-100 is 28.87), and revenue has two populations: trials are always 0.00, so the
--      median of "all" revenue is 0 and any revenue average must say whether it is per
--      conversion or per purchase.
--    Expected: N, MIN, MEDIAN, MAX, AVG from [P1 s3, s8h]; P25, P75, STDDEV from [L2].
--    (All measures share one NUMBER(38,2) column in the UNION, so counts print as 2565.00.)
-- -----------------------------------------------------------------------------
WITH measures AS (
            SELECT 1 AS ORD, 'CAMPAIGNS.BUDGET' AS MEASURE, TRY_TO_NUMBER(BUDGET, 12, 2) AS V FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'DAILY_SPEND.IMPRESSIONS',      TRY_TO_NUMBER(IMPRESSIONS)    FROM RAW.DAILY_SPEND
  UNION ALL SELECT 3, 'DAILY_SPEND.CLICKS',           TRY_TO_NUMBER(CLICKS)         FROM RAW.DAILY_SPEND
  UNION ALL SELECT 4, 'DAILY_SPEND.SPEND',            TRY_TO_NUMBER(SPEND, 12, 2)   FROM RAW.DAILY_SPEND
  UNION ALL SELECT 5, 'LEADS.LEAD_SCORE',             TRY_TO_NUMBER(LEAD_SCORE)     FROM RAW.LEADS
  UNION ALL SELECT 6, 'CONVERSIONS.REVENUE purchase', TRY_TO_NUMBER(REVENUE, 12, 2) FROM RAW.CONVERSIONS
            WHERE CONVERSION_TYPE = 'purchase'
  UNION ALL SELECT 7, 'CONVERSIONS.REVENUE all',      TRY_TO_NUMBER(REVENUE, 12, 2) FROM RAW.CONVERSIONS
),
distribution AS (
  SELECT ORD, MEASURE,
         COUNT(V)                                                 AS N,
         MIN(V)                                                   AS MIN_VALUE,
         ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY V), 4) AS P25,
         ROUND(MEDIAN(V), 4)                                      AS MEDIAN,
         ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY V), 4) AS P75,
         MAX(V)                                                   AS MAX_VALUE,
         ROUND(AVG(V), 6)                                         AS AVG_VALUE,
         ROUND(STDDEV(V), 4)                                      AS STDDEV_VALUE
  FROM measures
  GROUP BY ORD, MEASURE
),
expected (MEASURE, N, MIN_VALUE, P25, MEDIAN, P75, MAX_VALUE, AVG_VALUE, STDDEV_VALUE) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS.BUDGET',               120, 8102.32, 27094.5925, 48059.12,   61425.745, 79884.92,  45155.351333, 20913.6146),
    ('DAILY_SPEND.IMPRESSIONS',      11240,    2565,   17993.75,    31236,    54272.75,   175793,  38865.197420, 27384.1313),
    ('DAILY_SPEND.CLICKS',           11240,      17,     242.75,      492,         842,     4126,    631.878915,   542.2532),
    ('DAILY_SPEND.SPEND',            11240,   37.14,    236.375,   369.53,    524.3475,  1478.36,    402.406585,   231.1227),
    ('LEADS.LEAD_SCORE',            261684,       1,         26,       51,          76,      100,     50.571059,    28.8690),
    ('CONVERSIONS.REVENUE purchase', 16691,   99.11,     682.25,  1292.95,     1893.32,  2498.92,   1291.824277,   695.2246),
    ('CONVERSIONS.REVENUE all',      39696,    0.00,          0,        0,   1057.0475,  2498.92,    543.174098,   780.9479)
)
SELECT COALESCE(d.MEASURE, e.MEASURE) AS MEASURE,
       d.N, d.MIN_VALUE, d.P25, d.MEDIAN, d.P75, d.MAX_VALUE, d.AVG_VALUE, d.STDDEV_VALUE,
       IFF(d.N = e.N AND d.MIN_VALUE = e.MIN_VALUE AND d.P25 = e.P25 AND d.MEDIAN = e.MEDIAN
           AND d.P75 = e.P75 AND d.MAX_VALUE = e.MAX_VALUE AND d.AVG_VALUE = e.AVG_VALUE
           AND d.STDDEV_VALUE = e.STDDEV_VALUE, 'PASS', 'FAIL') AS STATUS
FROM distribution d
FULL OUTER JOIN expected e ON e.MEASURE = d.MEASURE
ORDER BY d.ORD;


-- -----------------------------------------------------------------------------
-- 6.2 Outliers by the 1.5 x IQR rule (Tukey fences on the pooled distribution)
--    Question: how many values lie beyond Q1 - 1.5*IQR or Q3 + 1.5*IQR?
--    Why: a high count here is not an error. There are no low outliers at all; the high
--      ones are the right tail of the delivery measures (2.7% to 5.0% of spend rows), and
--      6.3 shows they come from the channel mix. They pass every business rule (6.4), so
--      STAGING keeps every row (no trimming or winsorising), and MART compares channels
--      with ratios of sums, which are not distorted by a long tail. Budget, lead score and
--      revenue have no outliers by this rule.
--    Expected: low 0 everywhere; high 301 impressions, 559 clicks, 303 spend, otherwise 0 [L2].
-- -----------------------------------------------------------------------------
WITH measures AS (   -- same measures as 6.1
            SELECT 1 AS ORD, 'CAMPAIGNS.BUDGET' AS MEASURE, TRY_TO_NUMBER(BUDGET, 12, 2) AS V FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'DAILY_SPEND.IMPRESSIONS',      TRY_TO_NUMBER(IMPRESSIONS)    FROM RAW.DAILY_SPEND
  UNION ALL SELECT 3, 'DAILY_SPEND.CLICKS',           TRY_TO_NUMBER(CLICKS)         FROM RAW.DAILY_SPEND
  UNION ALL SELECT 4, 'DAILY_SPEND.SPEND',            TRY_TO_NUMBER(SPEND, 12, 2)   FROM RAW.DAILY_SPEND
  UNION ALL SELECT 5, 'LEADS.LEAD_SCORE',             TRY_TO_NUMBER(LEAD_SCORE)     FROM RAW.LEADS
  UNION ALL SELECT 6, 'CONVERSIONS.REVENUE purchase', TRY_TO_NUMBER(REVENUE, 12, 2) FROM RAW.CONVERSIONS
            WHERE CONVERSION_TYPE = 'purchase'
  UNION ALL SELECT 7, 'CONVERSIONS.REVENUE all',      TRY_TO_NUMBER(REVENUE, 12, 2) FROM RAW.CONVERSIONS
),
fences AS (
  SELECT MEASURE, Q1, Q3, Q3 - Q1 AS IQR,
         Q1 - 1.5 * (Q3 - Q1) AS LOWER_FENCE,
         Q3 + 1.5 * (Q3 - Q1) AS UPPER_FENCE
  FROM (SELECT MEASURE,
               PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY V) AS Q1,
               PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY V) AS Q3
        FROM measures GROUP BY MEASURE)
),
outliers AS (
  SELECT m.ORD, m.MEASURE, COUNT(*) AS N,
         ROUND(ANY_VALUE(f.IQR), 4) AS IQR,
         ROUND(ANY_VALUE(f.LOWER_FENCE), 4) AS LOWER_FENCE,
         ROUND(ANY_VALUE(f.UPPER_FENCE), 4) AS UPPER_FENCE,
         COUNT_IF(m.V < f.LOWER_FENCE) AS LOW_OUTLIERS,
         COUNT_IF(m.V > f.UPPER_FENCE) AS HIGH_OUTLIERS
  FROM measures m
  JOIN fences f ON f.MEASURE = m.MEASURE
  GROUP BY m.ORD, m.MEASURE
),
expected (MEASURE, EXPECTED_HIGH) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS.BUDGET', 0), ('DAILY_SPEND.IMPRESSIONS', 301), ('DAILY_SPEND.CLICKS', 559),
    ('DAILY_SPEND.SPEND', 303), ('LEADS.LEAD_SCORE', 0), ('CONVERSIONS.REVENUE purchase', 0),
    ('CONVERSIONS.REVENUE all', 0)
)
SELECT COALESCE(o.MEASURE, e.MEASURE) AS MEASURE,
       o.N, o.IQR, o.LOWER_FENCE, o.UPPER_FENCE, o.LOW_OUTLIERS, o.HIGH_OUTLIERS,
       ROUND((o.LOW_OUTLIERS + o.HIGH_OUTLIERS) / o.N, 4) AS OUTLIER_SHARE,
       e.EXPECTED_HIGH,
       IFF(o.LOW_OUTLIERS = 0 AND o.HIGH_OUTLIERS = e.EXPECTED_HIGH, 'PASS', 'FAIL') AS STATUS
FROM outliers o
FULL OUTER JOIN expected e ON e.MEASURE = o.MEASURE
ORDER BY o.ORD;


-- -----------------------------------------------------------------------------
-- 6.3 Where the delivery outliers come from: high outliers per channel
--    Question: are the 6.2 outliers spread evenly, or concentrated in some channels?
--    Why: concentrated. Display (cheap impressions, CPM about 6.50) owns most impression
--      outliers, affiliate most click outliers, and video has none of either. Fences on the
--      pooled distribution mostly re-discover channel differences, so outlier review in
--      later phases is done within a channel. The fences are the pooled ones from 6.2.
--    Expected: the counts below [L2]; spend rows per channel as in [P3 F3] (2,150 / 2,367 /
--      2,307 / 1,906 / 2,510).
-- -----------------------------------------------------------------------------
WITH spend AS (
  SELECT c.CHANNEL,
         TRY_TO_NUMBER(d.IMPRESSIONS)  AS IMPRESSIONS,
         TRY_TO_NUMBER(d.CLICKS)       AS CLICKS,
         TRY_TO_NUMBER(d.SPEND, 12, 2) AS SPEND
  FROM RAW.DAILY_SPEND d
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = d.CAMPAIGN_ID   -- many-to-one: no fan-out
),
fences AS (
  SELECT Q3_IMPRESSIONS + 1.5 * (Q3_IMPRESSIONS - Q1_IMPRESSIONS) AS UPPER_IMPRESSIONS,
         Q3_CLICKS      + 1.5 * (Q3_CLICKS - Q1_CLICKS)           AS UPPER_CLICKS,
         Q3_SPEND       + 1.5 * (Q3_SPEND - Q1_SPEND)             AS UPPER_SPEND
  FROM (SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY IMPRESSIONS) AS Q1_IMPRESSIONS,
               PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY IMPRESSIONS) AS Q3_IMPRESSIONS,
               PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY CLICKS)      AS Q1_CLICKS,
               PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY CLICKS)      AS Q3_CLICKS,
               PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY SPEND)       AS Q1_SPEND,
               PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY SPEND)       AS Q3_SPEND
        FROM spend)
),
by_channel AS (
  SELECT IFF(GROUPING(s.CHANNEL) = 1, 'TOTAL', s.CHANNEL) AS CHANNEL,
         GROUPING(s.CHANNEL) AS IS_TOTAL,
         COUNT(*) AS SPEND_ROWS,
         COUNT_IF(s.IMPRESSIONS > f.UPPER_IMPRESSIONS) AS HIGH_IMPRESSIONS,
         COUNT_IF(s.CLICKS > f.UPPER_CLICKS)           AS HIGH_CLICKS,
         COUNT_IF(s.SPEND > f.UPPER_SPEND)             AS HIGH_SPEND
  FROM spend s
  CROSS JOIN fences f
  GROUP BY ROLLUP (s.CHANNEL)
),
expected (CHANNEL, SPEND_ROWS, HIGH_IMPRESSIONS, HIGH_CLICKS, HIGH_SPEND) AS (
  SELECT * FROM VALUES
    ('affiliate',   2150,  78, 370,  82),
    ('display',     2367, 189,   0,  24),
    ('paid_search', 2307,   0, 119,  88),
    ('paid_social', 1906,  34,  70,  89),
    ('video',       2510,   0,   0,  20),
    ('TOTAL',      11240, 301, 559, 303)
)
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL,
       b.SPEND_ROWS, b.HIGH_IMPRESSIONS, b.HIGH_CLICKS, b.HIGH_SPEND,
       IFF(b.SPEND_ROWS = e.SPEND_ROWS AND b.HIGH_IMPRESSIONS = e.HIGH_IMPRESSIONS
           AND b.HIGH_CLICKS = e.HIGH_CLICKS AND b.HIGH_SPEND = e.HIGH_SPEND, 'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY b.IS_TOTAL, COALESCE(b.CHANNEL, e.CHANNEL);


-- -----------------------------------------------------------------------------
-- 6.4 Business rules: values that are well-typed but impossible
--    Question: does any row break a rule of the business (more clicks than impressions,
--      zero spend, a trial with revenue, a campaign over budget)?
--    Why: these become dbt expression tests and decide which NULLIF(denominator, 0) guards
--      MART needs. The two cross-table rules show the grain rule in action: spend is first
--      summed to the campaign before comparing it with the budget, and leads are first
--      counted per campaign x date before comparing them with that day's clicks; joining the
--      raw rows instead would compare fanned-out totals (block 9).
--      Rows whose cast fails (none, see 2.1) would not be counted here.
--    Expected: 0 violations for all 10 rules [P1 s8a, s8c, s8e, s8h; P2 4f, 7a; P3 F0].
-- -----------------------------------------------------------------------------
WITH spend AS (
  SELECT CAMPAIGN_ID, SPEND_DATE,
         TRY_TO_NUMBER(IMPRESSIONS)  AS IMPRESSIONS,
         TRY_TO_NUMBER(CLICKS)       AS CLICKS,
         TRY_TO_NUMBER(SPEND, 12, 2) AS SPEND
  FROM RAW.DAILY_SPEND
),
spend_per_campaign AS (
  SELECT CAMPAIGN_ID, SUM(SPEND) AS SPEND FROM spend GROUP BY CAMPAIGN_ID
),
leads_per_campaign_day AS (   -- leads aggregated to the daily_spend grain first
  SELECT CAMPAIGN_ID, CREATED_AT AS SPEND_DATE, COUNT(*) AS LEADS
  FROM RAW.LEADS GROUP BY CAMPAIGN_ID, CREATED_AT
)
SELECT TABLE_NAME, RULE_NAME, VIOLATIONS, 0 AS EXPECTED,
       IFF(VIOLATIONS = 0, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'DAILY_SPEND' AS TABLE_NAME, 'clicks <= impressions' AS RULE_NAME,
                   COUNT_IF(CLICKS > IMPRESSIONS) AS VIOLATIONS FROM spend
  UNION ALL SELECT 2, 'DAILY_SPEND', 'impressions > 0', COUNT_IF(IMPRESSIONS <= 0) FROM spend
  UNION ALL SELECT 3, 'DAILY_SPEND', 'clicks > 0',      COUNT_IF(CLICKS <= 0)      FROM spend
  UNION ALL SELECT 4, 'DAILY_SPEND', 'spend > 0',       COUNT_IF(SPEND <= 0)       FROM spend
  UNION ALL SELECT 5, 'CAMPAIGNS', 'budget > 0',
                   COUNT_IF(TRY_TO_NUMBER(BUDGET, 12, 2) <= 0) FROM RAW.CAMPAIGNS
  UNION ALL SELECT 6, 'LEADS', 'lead_score between 1 and 100',
                   COUNT_IF(TRY_TO_NUMBER(LEAD_SCORE) NOT BETWEEN 1 AND 100) FROM RAW.LEADS
  UNION ALL SELECT 7, 'CONVERSIONS', 'trial => revenue = 0.00',
                   COUNT_IF(CONVERSION_TYPE = 'trial' AND TRY_TO_NUMBER(REVENUE, 12, 2) <> 0) FROM RAW.CONVERSIONS
  UNION ALL SELECT 8, 'CONVERSIONS', 'purchase => revenue > 0',
                   COUNT_IF(CONVERSION_TYPE = 'purchase' AND TRY_TO_NUMBER(REVENUE, 12, 2) <= 0) FROM RAW.CONVERSIONS
  UNION ALL SELECT 9, 'CAMPAIGNS', 'total spend <= budget (campaign grain)', COUNT(*)
            FROM RAW.CAMPAIGNS c JOIN spend_per_campaign s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
            WHERE s.SPEND > TRY_TO_NUMBER(c.BUDGET, 12, 2)
  UNION ALL SELECT 10, 'DAILY_SPEND', 'leads <= clicks (campaign x date grain)', COUNT(*)
            FROM spend s JOIN leads_per_campaign_day l
              ON l.CAMPAIGN_ID = s.CAMPAIGN_ID AND l.SPEND_DATE = s.SPEND_DATE
            WHERE l.LEADS > s.CLICKS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6.5 Lead score distribution in 10-point bands
--    Question: how are scores spread, and how large are the Low / Medium / High segments?
--    Why: the bands are almost equal (25,748 - 26,396 leads each), i.e. the score is close
--      to uniform on 1-100. The dashboard segments (Low 1-40, Medium 41-70, High 71-100)
--      line up with band edges, so they hold 104,245 / 78,862 / 78,577 leads. A uniform
--      score says nothing yet about whether it predicts conversion; that is business
--      question 4 (Phase 4), and the score is not assumed to be predictive.
--    Expected: band counts [P1 s8f]; segment sizes [P3 F4].
-- -----------------------------------------------------------------------------
WITH bands AS (
  SELECT FLOOR((TRY_TO_NUMBER(LEAD_SCORE) - 1) / 10) AS BAND_INDEX, COUNT(*) AS LEADS
  FROM RAW.LEADS
  GROUP BY 1
),
expected (BAND_INDEX, EXPECTED_LEADS) AS (
  SELECT * FROM VALUES
    (0, 26193), (1, 26058), (2, 25748), (3, 26246), (4, 26293),
    (5, 26173), (6, 26396), (7, 26184), (8, 26068), (9, 26325)
),
labelled AS (
  SELECT COALESCE(b.BAND_INDEX, e.BAND_INDEX) AS BAND_INDEX, b.LEADS, e.EXPECTED_LEADS,
         CASE WHEN COALESCE(b.BAND_INDEX, e.BAND_INDEX) <= 3 THEN 'Low (1-40)'
              WHEN COALESCE(b.BAND_INDEX, e.BAND_INDEX) <= 6 THEN 'Medium (41-70)'
              ELSE 'High (71-100)' END AS SEGMENT
  FROM bands b
  FULL OUTER JOIN expected e ON e.BAND_INDEX = b.BAND_INDEX
)
SELECT (BAND_INDEX * 10 + 1) || '-' || (BAND_INDEX * 10 + 10) AS SCORE_BAND,
       SEGMENT, LEADS,
       ROUND(LEADS / SUM(LEADS) OVER (), 4) AS SHARE,
       SUM(LEADS) OVER (PARTITION BY SEGMENT) AS SEGMENT_LEADS,
       EXPECTED_LEADS,
       IFF(LEADS = EXPECTED_LEADS, 'PASS', 'FAIL') AS STATUS
FROM labelled
ORDER BY BAND_INDEX;


-- -----------------------------------------------------------------------------
-- 7. Relationships between the tables
-- -----------------------------------------------------------------------------
-- 7.1 Orphan keys in every direction (NOT EXISTS)
--    Question: does every foreign key find its parent, and does every campaign have
--      children in each fact table?
--    Why: Snowflake does not enforce FOREIGN KEY constraints. An orphan disappears from an
--      INNER JOIN (spend or revenue silently lost) and shows up as an "unknown" member
--      after a LEFT JOIN. NOT EXISTS is used because, unlike NOT IN, it stays correct if a
--      key is NULL. Unconverted leads are the one expected non-zero: 84.8% of leads never
--      convert, so every lead-level model must LEFT JOIN conversions.
--    Expected: 0 orphans in all six directions; 221,988 unconverted leads [P2 2a, 2b].
-- -----------------------------------------------------------------------------
SELECT RELATIONSHIP, ORPHAN_ROWS, EXPECTED, IFF(ORPHAN_ROWS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'DAILY_SPEND.CAMPAIGN_ID -> CAMPAIGNS' AS RELATIONSHIP,
                   COUNT(*) AS ORPHAN_ROWS, 0 AS EXPECTED
            FROM RAW.DAILY_SPEND d
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CAMPAIGNS c WHERE c.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 2, 'LEADS.CAMPAIGN_ID -> CAMPAIGNS', COUNT(*), 0
            FROM RAW.LEADS l
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CAMPAIGNS c WHERE c.CAMPAIGN_ID = l.CAMPAIGN_ID)
  UNION ALL SELECT 3, 'CONVERSIONS.LEAD_ID -> LEADS', COUNT(*), 0
            FROM RAW.CONVERSIONS v
            WHERE NOT EXISTS (SELECT 1 FROM RAW.LEADS l WHERE l.LEAD_ID = v.LEAD_ID)
  UNION ALL SELECT 4, 'CAMPAIGNS without DAILY_SPEND rows', COUNT(*), 0
            FROM RAW.CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM RAW.DAILY_SPEND d WHERE d.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 5, 'CAMPAIGNS without LEADS', COUNT(*), 0
            FROM RAW.CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM RAW.LEADS l WHERE l.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 6, 'CAMPAIGNS without CONVERSIONS', COUNT(*), 0
            FROM RAW.CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM RAW.LEADS l JOIN RAW.CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID
                              WHERE l.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 7, 'LEADS without a CONVERSION (expected)', COUNT(*), 221988
            FROM RAW.LEADS l
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CONVERSIONS v WHERE v.LEAD_ID = l.LEAD_ID)
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 7.2 Conversions per lead
--    Question: how many conversions does a lead have: 0, 1, or more?
--    Why: confirms the 1:0..1 relationship from the other side (3.1 checked uniqueness of
--      CONVERSIONS.LEAD_ID). A lead converts at most once, to a trial or to a purchase,
--      never both, so the funnel cannot follow a lead from trial to purchase: "trial" and
--      "purchase" are parallel outcomes, and the funnel is an aggregate campaign funnel,
--      not an individual journey.
--    Expected: 221,988 leads with 0 (share 0.848306) and 39,696 with 1 (0.151694); no row
--      for 2 or more [P2 2b, 2c].
-- -----------------------------------------------------------------------------
WITH per_lead AS (
  SELECT l.LEAD_ID, COUNT(v.CONVERSION_ID) AS CONVERSIONS
  FROM RAW.LEADS l
  LEFT JOIN RAW.CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID
  GROUP BY l.LEAD_ID
),
distribution AS (
  SELECT CONVERSIONS AS CONVERSIONS_PER_LEAD, COUNT(*) AS LEADS
  FROM per_lead GROUP BY CONVERSIONS
),
expected (CONVERSIONS_PER_LEAD, EXPECTED_LEADS) AS (
  SELECT * FROM VALUES (0, 221988), (1, 39696)
)
SELECT COALESCE(d.CONVERSIONS_PER_LEAD, e.CONVERSIONS_PER_LEAD) AS CONVERSIONS_PER_LEAD,
       d.LEADS,
       ROUND(d.LEADS / SUM(d.LEADS) OVER (), 6) AS SHARE,
       e.EXPECTED_LEADS,
       IFF(d.LEADS = e.EXPECTED_LEADS, 'PASS', 'FAIL') AS STATUS
FROM distribution d
FULL OUTER JOIN expected e ON e.CONVERSIONS_PER_LEAD = d.CONVERSIONS_PER_LEAD
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 7.3 LEADS.LEAD_SOURCE vs the campaign's CHANNEL
--    Question: is a lead's source always the channel of the campaign it is attributed to?
--    Why: yes, for all 261,684 leads, so LEAD_SOURCE carries no extra information. MART
--      exposes one channel dimension, taken from dim_campaign (campaigns.channel); STAGING
--      keeps lead_source plus a warning test, because the challenge extract shows that the
--      column can drift (' PAID_SEARCH ').
--    Expected: 0 mismatches; leads per channel as in [P2 3a, 3b].
-- -----------------------------------------------------------------------------
WITH by_channel AS (
  SELECT c.CHANNEL,
         COUNT(*)                                          AS LEADS,
         COUNT_IF(l.LEAD_SOURCE = c.CHANNEL)               AS SOURCE_EQUALS_CHANNEL,
         COUNT_IF(l.LEAD_SOURCE IS DISTINCT FROM c.CHANNEL) AS MISMATCHES
  FROM RAW.LEADS l
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY c.CHANNEL
),
expected (CHANNEL, EXPECTED_LEADS) AS (
  SELECT * FROM VALUES
    ('affiliate', 67849), ('display', 45149), ('paid_search', 65268),
    ('paid_social', 57619), ('video', 25799)
)
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL, b.LEADS, b.SOURCE_EQUALS_CHANNEL, b.MISMATCHES,
       e.EXPECTED_LEADS,
       IFF(b.LEADS = e.EXPECTED_LEADS AND b.MISMATCHES = 0, 'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 8. Time coverage and time logic
-- -----------------------------------------------------------------------------
-- 8.1 Coverage of every date column
--    Question: which dates does each column cover, and how is activity split by year?
--    Why: the documented coverage is 2023-01-01 to 2025-12-31, but activity runs only from
--      2023-01-04 to 2025-12-02, with conversions to 2025-12-21. Dashboards therefore use a
--      fixed date range (relative ranges such as "last 28 days" are empty today), and
--      dim_date must still span the documented 1,096 days so that empty days show as 0.
--      Spend dates are contiguous (1,064 distinct dates over a 1,064-day span).
--    Expected: min / max / distinct / per-year rows [P1 s4]; 0 dates outside the coverage.
-- -----------------------------------------------------------------------------
WITH dates AS (
            SELECT 1 AS ORD, 'CAMPAIGNS.START_DATE' AS DATE_COLUMN,
                   TRY_TO_DATE(START_DATE, 'YYYY-MM-DD') AS D                     FROM RAW.CAMPAIGNS
  UNION ALL SELECT 2, 'CAMPAIGNS.END_DATE',       TRY_TO_DATE(END_DATE, 'YYYY-MM-DD')     FROM RAW.CAMPAIGNS
  UNION ALL SELECT 3, 'DAILY_SPEND.SPEND_DATE',   TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD')   FROM RAW.DAILY_SPEND
  UNION ALL SELECT 4, 'LEADS.CREATED_AT',         TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD')   FROM RAW.LEADS
  UNION ALL SELECT 5, 'CONVERSIONS.CONVERTED_AT', TRY_TO_DATE(CONVERTED_AT, 'YYYY-MM-DD') FROM RAW.CONVERSIONS
),
coverage AS (
  SELECT ORD, DATE_COLUMN,
         MIN(D) AS MIN_DATE, MAX(D) AS MAX_DATE, COUNT(DISTINCT D) AS DISTINCT_DATES,
         DATEDIFF('day', MIN(D), MAX(D)) + 1 AS SPAN_DAYS,
         COUNT_IF(YEAR(D) = 2023) AS ROWS_2023,
         COUNT_IF(YEAR(D) = 2024) AS ROWS_2024,
         COUNT_IF(YEAR(D) = 2025) AS ROWS_2025,
         COUNT_IF(D IS NULL OR D NOT BETWEEN '2023-01-01'::DATE AND '2025-12-31'::DATE) AS OUTSIDE_COVERAGE
  FROM dates
  GROUP BY ORD, DATE_COLUMN
),
expected (DATE_COLUMN, MIN_DATE, MAX_DATE, DISTINCT_DATES, ROWS_2023, ROWS_2024, ROWS_2025) AS (
  SELECT * FROM VALUES
    ('CAMPAIGNS.START_DATE',     '2023-01-04', '2025-08-28',  110,    48,     50,    22),
    ('CAMPAIGNS.END_DATE',       '2023-03-14', '2025-12-02',  116,    38,     47,    35),
    ('DAILY_SPEND.SPEND_DATE',   '2023-01-04', '2025-12-02', 1064,  3848,   4405,  2987),
    ('LEADS.CREATED_AT',         '2023-01-04', '2025-12-02', 1064, 87549, 107371, 66764),
    ('CONVERSIONS.CONVERTED_AT', '2023-01-05', '2025-12-21', 1080, 12779,  16148, 10769)
)
SELECT COALESCE(c.DATE_COLUMN, e.DATE_COLUMN) AS DATE_COLUMN,
       c.MIN_DATE, c.MAX_DATE, c.DISTINCT_DATES, c.SPAN_DAYS,
       c.ROWS_2023, c.ROWS_2024, c.ROWS_2025, c.OUTSIDE_COVERAGE,
       IFF(c.MIN_DATE = TO_DATE(e.MIN_DATE) AND c.MAX_DATE = TO_DATE(e.MAX_DATE)
           AND c.DISTINCT_DATES = e.DISTINCT_DATES AND c.ROWS_2023 = e.ROWS_2023
           AND c.ROWS_2024 = e.ROWS_2024 AND c.ROWS_2025 = e.ROWS_2025
           AND c.OUTSIDE_COVERAGE = 0, 'PASS', 'FAIL') AS STATUS
FROM coverage c
FULL OUTER JOIN expected e ON e.DATE_COLUMN = c.DATE_COLUMN
ORDER BY c.ORD;


-- -----------------------------------------------------------------------------
-- 8.2 Spend and leads inside the campaign window
--    Question: does all activity fall between START_DATE and END_DATE (inclusive), with
--      exactly one spend row per window day?
--    Why: if spend rows cover every window day with no gaps or extras, DAILY_SPEND itself
--      is a complete campaign x date spine for spend and leads, and window days per
--      campaign equal its spend rows. Seven spend days have no lead at all (all CMP0084,
--      video), so a daily cost per lead is undefined there and MART divides with
--      NULLIF(leads, 0). The 32 days of the documented coverage with no spend row are
--      2023-01-01..03 and 2025-12-03..31: no campaign was running.
--    Expected: the values below [P2 4a-4g, 9b, 9c; P1 s8a].
-- -----------------------------------------------------------------------------
WITH campaigns AS (
  SELECT CAMPAIGN_ID,
         TRY_TO_DATE(START_DATE, 'YYYY-MM-DD') AS START_D,
         TRY_TO_DATE(END_DATE, 'YYYY-MM-DD')   AS END_D
  FROM RAW.CAMPAIGNS
),
spend AS (
  SELECT CAMPAIGN_ID, TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD') AS D FROM RAW.DAILY_SPEND
),
lead_days AS (   -- leads aggregated to the spend grain (campaign x date) first
  SELECT CAMPAIGN_ID, TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD') AS D, COUNT(*) AS LEADS
  FROM RAW.LEADS GROUP BY 1, 2
),
spend_vs_window AS (
  SELECT c.CAMPAIGN_ID,
         DATEDIFF('day', c.START_D, c.END_D) + 1             AS WINDOW_DAYS,
         COUNT_IF(s.D BETWEEN c.START_D AND c.END_D)         AS SPEND_DAYS_IN_WINDOW,
         COUNT_IF(s.D NOT BETWEEN c.START_D AND c.END_D)     AS SPEND_DAYS_OUTSIDE
  FROM campaigns c
  LEFT JOIN spend s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
  GROUP BY c.CAMPAIGN_ID, c.START_D, c.END_D
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'campaigns with end_date < start_date' AS CHECK_NAME,
                   COUNT_IF(END_D < START_D) AS ACTUAL, 0 AS EXPECTED
            FROM campaigns
  UNION ALL SELECT 2, 'spend rows outside the campaign window',
                   SUM(SPEND_DAYS_OUTSIDE), 0 FROM spend_vs_window
  UNION ALL SELECT 3, 'campaigns with a gap in daily spend',
                   COUNT_IF(SPEND_DAYS_IN_WINDOW < WINDOW_DAYS), 0 FROM spend_vs_window
  UNION ALL SELECT 4, 'window days, all campaigns (= rows)',
                   SUM(WINDOW_DAYS), 11240 FROM spend_vs_window
  UNION ALL SELECT 5, 'shortest campaign window (days)',
                   MIN(WINDOW_DAYS), 46 FROM spend_vs_window
  UNION ALL SELECT 6, 'longest campaign window (days)',
                   MAX(WINDOW_DAYS), 150 FROM spend_vs_window
  UNION ALL SELECT 7, 'leads outside the campaign window',
                   COALESCE(SUM(l.LEADS), 0), 0
            FROM lead_days l JOIN campaigns c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
            WHERE l.D NOT BETWEEN c.START_D AND c.END_D
  UNION ALL SELECT 8, 'leads on a day without a spend row',
                   COALESCE(SUM(l.LEADS), 0), 0
            FROM lead_days l
            WHERE NOT EXISTS (SELECT 1 FROM spend s WHERE s.CAMPAIGN_ID = l.CAMPAIGN_ID AND s.D = l.D)
  UNION ALL SELECT 9, 'spend rows with zero leads',
                   COUNT(*), 7
            FROM spend s
            WHERE NOT EXISTS (SELECT 1 FROM lead_days l WHERE l.CAMPAIGN_ID = s.CAMPAIGN_ID AND l.D = s.D)
  UNION ALL SELECT 10, 'coverage days without any spend row',
                   DATEDIFF('day', '2023-01-01'::DATE, '2025-12-31'::DATE) + 1 - COUNT(DISTINCT D), 32
            FROM spend
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 8.3 Conversion timing relative to the lead and to the campaign window
--    Question: can a conversion precede its lead, how many happen on the lead's first day,
--      and how many land after the campaign has ended?
--    Why: a conversion before its lead would be a data error (there are none). 4,716
--      conversions (11.9%, with 2,532,266.74 of revenue) happen after their campaign's
--      END_DATE, up to 21 days later. A MART activity fact built only on DAILY_SPEND dates
--      would silently drop that revenue, so the campaign x date spine runs from START_DATE
--      to END_DATE + 21, and a "within the campaign window" filter in the dashboard would
--      understate revenue.
--    Expected: the values below [P2 5a, 9f; same-day split by type from L2].
-- -----------------------------------------------------------------------------
WITH conv AS (
  SELECT v.CONVERSION_TYPE,
         TRY_TO_DATE(v.CONVERTED_AT, 'YYYY-MM-DD') AS CONVERTED_D,
         TRY_TO_DATE(l.CREATED_AT, 'YYYY-MM-DD')   AS CREATED_D,
         TRY_TO_DATE(c.END_DATE, 'YYYY-MM-DD')     AS CAMPAIGN_END_D,
         TRY_TO_NUMBER(v.REVENUE, 12, 2)           AS REVENUE
  FROM RAW.CONVERSIONS v
  JOIN RAW.LEADS l     ON l.LEAD_ID = v.LEAD_ID           -- 1:1 (block 3), no fan-out
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID   -- many-to-one
),
timing AS (
  SELECT IFF(GROUPING(x.CONVERSION_TYPE) = 1, 'all', x.CONVERSION_TYPE) AS CONVERSION_TYPE,
         GROUPING(x.CONVERSION_TYPE)                                AS IS_TOTAL,
         COUNT(*)                                                   AS CONVERSIONS,
         COUNT_IF(CONVERTED_D < CREATED_D)                          AS BEFORE_LEAD,
         COUNT_IF(CONVERTED_D = CREATED_D)                          AS SAME_DAY,
         COUNT_IF(DATEDIFF('day', CREATED_D, CONVERTED_D) > 21)     AS OVER_21_DAYS,
         COUNT_IF(CONVERTED_D > CAMPAIGN_END_D)                     AS AFTER_CAMPAIGN_END,
         SUM(IFF(CONVERTED_D > CAMPAIGN_END_D, REVENUE, 0))         AS AFTER_END_REVENUE,
         MAX(DATEDIFF('day', CAMPAIGN_END_D, CONVERTED_D))          AS MAX_DAYS_AFTER_END,
         COUNT_IF(CONVERTED_D > '2025-12-31'::DATE)                 AS AFTER_COVERAGE
  FROM conv x
  GROUP BY ROLLUP (x.CONVERSION_TYPE)
),
expected (CONVERSION_TYPE, CONVERSIONS, SAME_DAY, AFTER_CAMPAIGN_END, AFTER_END_REVENUE) AS (
  SELECT * FROM VALUES
    ('purchase', 16691,  770, 1951, 2532266.74),
    ('trial',    23005, 1041, 2765,       0.00),
    ('all',      39696, 1811, 4716, 2532266.74)
)
SELECT COALESCE(t.CONVERSION_TYPE, e.CONVERSION_TYPE) AS CONVERSION_TYPE,
       t.CONVERSIONS, t.BEFORE_LEAD, t.SAME_DAY, t.OVER_21_DAYS,
       t.AFTER_CAMPAIGN_END,
       ROUND(t.AFTER_CAMPAIGN_END / t.CONVERSIONS, 6) AS AFTER_END_SHARE,
       t.AFTER_END_REVENUE, t.MAX_DAYS_AFTER_END, t.AFTER_COVERAGE,
       IFF(t.CONVERSIONS = e.CONVERSIONS AND t.BEFORE_LEAD = 0 AND t.SAME_DAY = e.SAME_DAY
           AND t.OVER_21_DAYS = 0 AND t.AFTER_CAMPAIGN_END = e.AFTER_CAMPAIGN_END
           AND t.AFTER_END_REVENUE = e.AFTER_END_REVENUE AND t.MAX_DAYS_AFTER_END = 21
           AND t.AFTER_COVERAGE = 0, 'PASS', 'FAIL') AS STATUS
FROM timing t
FULL OUTER JOIN expected e ON e.CONVERSION_TYPE = t.CONVERSION_TYPE
ORDER BY t.IS_TOTAL, COALESCE(t.CONVERSION_TYPE, e.CONVERSION_TYPE);


-- -----------------------------------------------------------------------------
-- 8.4 Conversion lag: DATEDIFF('day', created_at, converted_at)
--    Question: how long does a lead take to convert, overall, by type and by channel?
--    Why: lag runs from 0 to 21 days and is spread almost evenly (median 10-11, p90 19) with
--      no difference by type or channel. Two design consequences: 34.4% of conversions land
--      in a later calendar month than their lead [P2 8f], so activity-month and
--      lead-cohort-month series differ (10.3); and 21 days is the maturity window for the
--      lead-cohort fact.
--      Lag needs no dashboard page of its own: one cumulative curve is enough.
--    Expected: N, quartiles, p90, max and mean (4 dp) per group [P2 5b, 5c, 5d].
-- -----------------------------------------------------------------------------
WITH lagged AS (
  SELECT v.CONVERSION_TYPE, c.CHANNEL,
         DATEDIFF('day', TRY_TO_DATE(l.CREATED_AT, 'YYYY-MM-DD'),
                         TRY_TO_DATE(v.CONVERTED_AT, 'YYYY-MM-DD')) AS LAG_DAYS
  FROM RAW.CONVERSIONS v
  JOIN RAW.LEADS l     ON l.LEAD_ID = v.LEAD_ID
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
),
lag_profile AS (
  SELECT CASE WHEN GROUPING(CONVERSION_TYPE) = 0 THEN 'conversion_type'
              WHEN GROUPING(CHANNEL) = 0         THEN 'channel'
              ELSE 'all' END                                       AS SPLIT_BY,
         COALESCE(CONVERSION_TYPE, CHANNEL, 'all')                 AS GROUP_VALUE,
         COUNT(*)                                                  AS CONVERSIONS,
         MIN(LAG_DAYS)                                             AS MIN_LAG,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY LAG_DAYS)    AS P25,
         MEDIAN(LAG_DAYS)                                          AS MEDIAN,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY LAG_DAYS)    AS P75,
         PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY LAG_DAYS)    AS P90,
         MAX(LAG_DAYS)                                             AS MAX_LAG,
         ROUND(AVG(LAG_DAYS), 4)                                   AS AVG_LAG
  FROM lagged
  GROUP BY GROUPING SETS ((), (CONVERSION_TYPE), (CHANNEL))
),
expected (GROUP_VALUE, CONVERSIONS, MEDIAN, AVG_LAG) AS (
  SELECT * FROM VALUES
    ('all',         39696, 10, 10.5056),
    ('purchase',    16691, 10, 10.5025), ('trial',       23005, 11, 10.5078),
    ('affiliate',   10352, 10, 10.4954), ('display',      6744, 10, 10.5101),
    ('paid_search', 10019, 11, 10.5017), ('paid_social',  8648, 11, 10.5774),
    ('video',        3933, 10, 10.3766)
)
SELECT p.SPLIT_BY, COALESCE(p.GROUP_VALUE, e.GROUP_VALUE) AS GROUP_VALUE,
       p.CONVERSIONS, p.MIN_LAG, p.P25, p.MEDIAN, p.P75, p.P90, p.MAX_LAG, p.AVG_LAG,
       IFF(p.CONVERSIONS = e.CONVERSIONS AND p.MIN_LAG = 0 AND p.P25 = 5 AND p.MEDIAN = e.MEDIAN
           AND p.P75 = 16 AND p.P90 = 19 AND p.MAX_LAG = 21 AND p.AVG_LAG = e.AVG_LAG,
           'PASS', 'FAIL') AS STATUS
FROM lag_profile p
FULL OUTER JOIN expected e ON e.GROUP_VALUE = p.GROUP_VALUE
ORDER BY DECODE(p.SPLIT_BY, 'all', 1, 'conversion_type', 2, 'channel', 3, 4),
         COALESCE(p.GROUP_VALUE, e.GROUP_VALUE);


-- -----------------------------------------------------------------------------
-- 8.5 Right-censoring: did the youngest leads have enough time to convert?
--    Question: does last lead date + maximum lag fall inside the observed data, and if not,
--      on what assumption are the youngest cohorts complete?
--    Why: if the youngest cohorts had fewer days than the maximum lag, their conversion
--      rates would look artificially low (right-censoring) and a late-2025 "decline" would
--      be an artefact. The maximum lag is 21 days even for 2023 leads, which had 700+ days
--      to convert, so 21 is the real maximum and not itself censored.
--      The data alone does not prove that the youngest cohorts are complete. The latest
--      possible conversion (2025-12-23) is after the last observed conversion (2025-12-21),
--      so the 65 leads of 2025-12-01/02 could have converted on 12-22 or 12-23 without the
--      extract showing it (11 of them converted by 12-21). Completeness rests on an
--      assumption, kept here as the named parameter AS_OF_DATE: the publisher documents
--      coverage through 2025-12-31, while observed activity ends 2025-12-21. Assuming the
--      extract is complete through 2025-12-31, the youngest lead had 29 days (more than 21)
--      and every lead cohort is mature. The lead-cohort fact therefore takes as_of_date as
--      a parameter and flags maturity (created_at <= as_of_date - 21), so the rule still
--      holds if newer data arrives or the assumption changes.
--    Expected: 2025-12-02, 21, 21, 2025-12-23, 2025-12-21 [P2 6a-6d]; 65 leads whose window
--      ends after the last observed conversion [P2 8e, L2]; 29 days to the assumed
--      AS_OF_DATE. COMPLETE_BY_OBSERVED_DATA = False and MATURE_IF_COMPLETE_TO_AS_OF = True
--      follow from those values.
-- -----------------------------------------------------------------------------
WITH params AS (   -- ASSUMPTION, not derived from the data: the documented coverage end
  SELECT '2025-12-31'::DATE AS AS_OF_DATE
),
lagged AS (
  SELECT TRY_TO_DATE(l.CREATED_AT, 'YYYY-MM-DD')   AS CREATED_D,
         TRY_TO_DATE(v.CONVERTED_AT, 'YYYY-MM-DD') AS CONVERTED_D
  FROM RAW.CONVERSIONS v
  JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID
),
facts AS (
  SELECT (SELECT MAX(TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD')) FROM RAW.LEADS)  AS LAST_LEAD_DATE,
         MAX(DATEDIFF('day', CREATED_D, CONVERTED_D))                      AS MAX_LAG_DAYS,
         MAX(IFF(YEAR(CREATED_D) = 2023, DATEDIFF('day', CREATED_D, CONVERTED_D), NULL)) AS MAX_LAG_2023_LEADS,
         MAX(CONVERTED_D)                                                  AS LAST_CONVERSION_DATE
  FROM lagged
),
unobserved AS (   -- leads whose maximum-lag window ends after the last observed conversion
  SELECT COUNT(*) AS LEADS_WINDOW_PAST_DATA
  FROM RAW.LEADS l
  CROSS JOIN facts f
  WHERE DATEADD('day', f.MAX_LAG_DAYS, TRY_TO_DATE(l.CREATED_AT, 'YYYY-MM-DD')) > f.LAST_CONVERSION_DATE
)
SELECT f.LAST_LEAD_DATE, f.MAX_LAG_DAYS, f.MAX_LAG_2023_LEADS,
       DATEADD('day', f.MAX_LAG_DAYS, f.LAST_LEAD_DATE)                       AS LATEST_POSSIBLE_CONVERSION,
       f.LAST_CONVERSION_DATE,
       u.LEADS_WINDOW_PAST_DATA,
       DATEADD('day', f.MAX_LAG_DAYS, f.LAST_LEAD_DATE) <= f.LAST_CONVERSION_DATE AS COMPLETE_BY_OBSERVED_DATA,
       p.AS_OF_DATE                                                           AS ASSUMED_AS_OF_DATE,
       DATEDIFF('day', f.LAST_LEAD_DATE, p.AS_OF_DATE)                        AS DAYS_TO_AS_OF_YOUNGEST_LEAD,
       DATEADD('day', f.MAX_LAG_DAYS, f.LAST_LEAD_DATE) <= p.AS_OF_DATE       AS MATURE_IF_COMPLETE_TO_AS_OF,
       IFF(f.LAST_LEAD_DATE = '2025-12-02'::DATE AND f.MAX_LAG_DAYS = 21 AND f.MAX_LAG_2023_LEADS = 21
           AND DATEADD('day', f.MAX_LAG_DAYS, f.LAST_LEAD_DATE) = '2025-12-23'::DATE
           AND f.LAST_CONVERSION_DATE = '2025-12-21'::DATE AND u.LEADS_WINDOW_PAST_DATA = 65
           AND DATEDIFF('day', f.LAST_LEAD_DATE, p.AS_OF_DATE) = 29, 'PASS', 'FAIL') AS STATUS
FROM facts f
CROSS JOIN unobserved u
CROSS JOIN params p;


-- -----------------------------------------------------------------------------
-- 8.6 Campaign starts per year, and campaigns that cross a year boundary
--    Question: how many campaigns start each year, how many run into the next year, and
--      how many are active in each year?
--    Why: 23 of 120 campaigns cross a year boundary, so "active campaigns per year" sums to
--      143, not 120, and budget (a campaign-level amount) cannot be assigned to one year:
--      yearly budget charts need budget prorated by window days, or they miscount those
--      23 campaigns. The 2025 drop (22 starts vs 50 in 2024) is a smaller portfolio, not
--      missing data: compare years together with the active-campaign count.
--    Expected: starts 48 / 50 / 22, crossings 10 / 13 / 0 (23), active 48 / 60 / 35, budget
--      by start year [P1 s8b, s8d; P2 8a, 8d; split of the starts from L2].
-- -----------------------------------------------------------------------------
WITH campaigns AS (
  SELECT YEAR(TRY_TO_DATE(START_DATE, 'YYYY-MM-DD')) AS START_YEAR,
         YEAR(TRY_TO_DATE(END_DATE, 'YYYY-MM-DD'))   AS END_YEAR,
         TRY_TO_NUMBER(BUDGET, 12, 2)                AS BUDGET
  FROM RAW.CAMPAIGNS
),
starts AS (
  SELECT IFF(GROUPING(START_YEAR) = 1, 'TOTAL', TO_VARCHAR(START_YEAR)) AS YEAR_LABEL,
         GROUPING(START_YEAR)                    AS IS_TOTAL,
         COUNT(*)                                AS CAMPAIGNS_STARTED,
         COUNT_IF(END_YEAR = START_YEAR)         AS ENDED_SAME_YEAR,
         COUNT_IF(END_YEAR = START_YEAR + 1)     AS CROSSED_INTO_NEXT_YEAR,
         COUNT_IF(END_YEAR > START_YEAR + 1)     AS SPAN_3_PLUS_YEARS,
         SUM(BUDGET)                             AS BUDGET_OF_STARTS
  FROM campaigns
  GROUP BY ROLLUP (START_YEAR)
),
years (YR) AS (
  SELECT * FROM VALUES (2023), (2024), (2025)
),
active AS (   -- campaigns whose window overlaps the year (a campaign counts in each year it runs)
  SELECT TO_VARCHAR(y.YR) AS YEAR_LABEL, COUNT(*) AS ACTIVE_IN_YEAR
  FROM years y
  JOIN campaigns c ON y.YR BETWEEN c.START_YEAR AND c.END_YEAR
  GROUP BY y.YR
),
active_with_total AS (
  SELECT YEAR_LABEL, ACTIVE_IN_YEAR FROM active
  UNION ALL
  SELECT 'TOTAL', SUM(ACTIVE_IN_YEAR) FROM active
),
expected (YEAR_LABEL, CAMPAIGNS_STARTED, ENDED_SAME_YEAR, CROSSED_INTO_NEXT_YEAR, ACTIVE_IN_YEAR, BUDGET_OF_STARTS) AS (
  SELECT * FROM VALUES
    ('2023',   48, 38, 10,  48, 2011992.51),
    ('2024',   50, 37, 13,  60, 2458235.85),
    ('2025',   22, 22,  0,  35,  948413.80),
    ('TOTAL', 120, 97, 23, 143, 5418642.16)
)
SELECT COALESCE(s.YEAR_LABEL, e.YEAR_LABEL) AS START_YEAR,
       s.CAMPAIGNS_STARTED, s.ENDED_SAME_YEAR, s.CROSSED_INTO_NEXT_YEAR,
       s.SPAN_3_PLUS_YEARS, a.ACTIVE_IN_YEAR, s.BUDGET_OF_STARTS,
       IFF(s.CAMPAIGNS_STARTED = e.CAMPAIGNS_STARTED AND s.ENDED_SAME_YEAR = e.ENDED_SAME_YEAR
           AND s.CROSSED_INTO_NEXT_YEAR = e.CROSSED_INTO_NEXT_YEAR AND s.SPAN_3_PLUS_YEARS = 0
           AND a.ACTIVE_IN_YEAR = e.ACTIVE_IN_YEAR AND s.BUDGET_OF_STARTS = e.BUDGET_OF_STARTS,
           'PASS', 'FAIL') AS STATUS
FROM starts s
FULL OUTER JOIN expected e ON e.YEAR_LABEL = s.YEAR_LABEL
LEFT JOIN active_with_total a ON a.YEAR_LABEL = COALESCE(s.YEAR_LABEL, e.YEAR_LABEL)
ORDER BY COALESCE(s.YEAR_LABEL, e.YEAR_LABEL);   -- '2023' < '2024' < '2025' < 'TOTAL'


-- -----------------------------------------------------------------------------
-- 8.7 Active campaigns per month (36 months)
--    Question: how many campaigns run in each month, and how many start and end?
--    Why: the denominator for every monthly comparison. The portfolio peaks at 18-20
--      campaigns and winds down to 5 / 3 / 1 in Oct-Dec 2025, so late-2025 totals fall
--      because fewer campaigns ran, not because performance dropped. 2025-12 is a partial
--      month (one campaign, ending 2025-12-02). The month spine comes from GENERATOR with
--      ROW_NUMBER() (SEQ4() alone may have gaps).
--    STATUS checks two things: active / started / ended equal the expected list below, and
--      campaigns active by their window = campaigns with a spend row in that month (a
--      consistency check of 8.2; both sides come from Snowflake, so only the expected list
--      would catch the same shift in CAMPAIGNS and DAILY_SPEND).
--    Expected: active per month [P2 8e]; active, started and ended per month [L2]; started
--      and ended each sum to 120.
-- -----------------------------------------------------------------------------
WITH months AS (
  SELECT DATEADD('month', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2023-01-01'::DATE) AS MONTH_START
  FROM TABLE(GENERATOR(ROWCOUNT => 36))
),
campaigns AS (
  SELECT CAMPAIGN_ID,
         TRY_TO_DATE(START_DATE, 'YYYY-MM-DD') AS START_D,
         TRY_TO_DATE(END_DATE, 'YYYY-MM-DD')   AS END_D
  FROM RAW.CAMPAIGNS
),
spend_months AS (
  SELECT DATE_TRUNC('month', TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD')) AS MONTH_START,
         COUNT(DISTINCT CAMPAIGN_ID) AS CAMPAIGNS_WITH_SPEND
  FROM RAW.DAILY_SPEND
  GROUP BY 1
),
per_month AS (
  SELECT m.MONTH_START,
         COUNT_IF(c.START_D <= LAST_DAY(m.MONTH_START) AND c.END_D >= m.MONTH_START) AS ACTIVE_CAMPAIGNS,
         COUNT_IF(DATE_TRUNC('month', c.START_D) = m.MONTH_START)                  AS STARTED,
         COUNT_IF(DATE_TRUNC('month', c.END_D) = m.MONTH_START)                    AS ENDED
  FROM months m
  CROSS JOIN campaigns c
  GROUP BY m.MONTH_START
),
expected (CALENDAR_MONTH, ACTIVE_CAMPAIGNS, STARTED, ENDED) AS (
  SELECT * FROM VALUES
    ('2023-01',  3, 3, 0), ('2023-02',  5, 2, 0), ('2023-03', 10, 5, 3), ('2023-04', 11, 4, 1),
    ('2023-05', 14, 4, 3), ('2023-06', 18, 7, 3), ('2023-07', 16, 1, 4), ('2023-08', 18, 6, 3),
    ('2023-09', 18, 3, 5), ('2023-10', 19, 6, 6), ('2023-11', 16, 3, 3), ('2023-12', 17, 4, 7),
    ('2024-01', 12, 2, 3), ('2024-02', 11, 2, 2), ('2024-03', 16, 7, 3), ('2024-04', 19, 6, 4),
    ('2024-05', 17, 2, 5), ('2024-06', 13, 1, 4), ('2024-07', 13, 4, 4), ('2024-08', 18, 9, 2),
    ('2024-09', 20, 4, 5), ('2024-10', 18, 3, 4), ('2024-11', 19, 5, 6), ('2024-12', 18, 5, 5),
    ('2025-01', 16, 3, 4), ('2025-02', 13, 1, 5), ('2025-03', 12, 4, 2), ('2025-04', 13, 3, 2),
    ('2025-05', 14, 3, 4), ('2025-06', 14, 4, 2), ('2025-07', 15, 3, 2), ('2025-08', 14, 1, 3),
    ('2025-09', 11, 0, 6), ('2025-10',  5, 0, 2), ('2025-11',  3, 0, 2), ('2025-12',  1, 0, 1)
)
SELECT COALESCE(TO_CHAR(p.MONTH_START, 'YYYY-MM'), e.CALENDAR_MONTH) AS CALENDAR_MONTH,
       p.ACTIVE_CAMPAIGNS, p.STARTED, p.ENDED,
       COALESCE(s.CAMPAIGNS_WITH_SPEND, 0) AS CAMPAIGNS_WITH_SPEND,
       IFF(p.ACTIVE_CAMPAIGNS = e.ACTIVE_CAMPAIGNS AND p.STARTED = e.STARTED AND p.ENDED = e.ENDED
           AND p.ACTIVE_CAMPAIGNS = COALESCE(s.CAMPAIGNS_WITH_SPEND, 0), 'PASS', 'FAIL') AS STATUS
FROM per_month p
FULL OUTER JOIN expected e ON e.CALENDAR_MONTH = TO_CHAR(p.MONTH_START, 'YYYY-MM')
LEFT JOIN spend_months s ON s.MONTH_START = p.MONTH_START
ORDER BY COALESCE(TO_CHAR(p.MONTH_START, 'YYYY-MM'), e.CALENDAR_MONTH);


-- -----------------------------------------------------------------------------
-- 9. Grain demonstration: why facts are aggregated BEFORE they are joined
--    Question: what happens to total spend if DAILY_SPEND is joined to LEADS row by row?
--    Why: DAILY_SPEND is one row per campaign x day, LEADS one row per lead. Joining them on
--      CAMPAIGN_ID repeats every spend row once per lead of that campaign, so spend is
--      multiplied by the campaign's lead count: 4.52 M becomes 11.3 B (2,495x). Adding the
--      date to the join key still inflates spend 27x, because each lead copies its day's
--      spend. Rows 2 and 3 are the ANTI-PATTERN, shown only to prove the rule: every MART
--      fact aggregates spend, leads and conversions separately to a common grain (campaign,
--      or campaign x date) and joins the aggregates 1:1. A dbt test will fail the build if
--      total spend in any MART table differs from 4,523,050.02.
--    STATUS: PASS means the numbers are exactly as documented (the anti-pattern reproduces
--      its inflation), not that the anti-pattern is acceptable.
--    Expected: [P3 F2], architecture decision 6.
-- -----------------------------------------------------------------------------
WITH correct AS (
  SELECT COUNT(*) AS JOINED_ROWS, SUM(TRY_TO_NUMBER(SPEND, 12, 2)) AS TOTAL_SPEND
  FROM RAW.DAILY_SPEND
),
wrong_campaign_join AS (   -- ANTI-PATTERN: two facts of different grain joined row by row
  SELECT COUNT(*) AS JOINED_ROWS, SUM(TRY_TO_NUMBER(d.SPEND, 12, 2)) AS TOTAL_SPEND
  FROM RAW.DAILY_SPEND d
  JOIN RAW.LEADS l ON l.CAMPAIGN_ID = d.CAMPAIGN_ID
),
wrong_campaign_day_join AS (   -- ANTI-PATTERN: same mistake with the date in the key
  SELECT COUNT(*) AS JOINED_ROWS, SUM(TRY_TO_NUMBER(d.SPEND, 12, 2)) AS TOTAL_SPEND
  FROM RAW.DAILY_SPEND d
  JOIN RAW.LEADS l ON l.CAMPAIGN_ID = d.CAMPAIGN_ID AND l.CREATED_AT = d.SPEND_DATE  -- ISO text on both sides (block 2)
),
methods AS (
            SELECT 1 AS ORD, 'correct: SUM(spend) over DAILY_SPEND' AS METHOD, JOINED_ROWS, TOTAL_SPEND,
                   11240 AS EXPECTED_ROWS, 4523050.02 AS EXPECTED_SPEND FROM correct
  UNION ALL SELECT 2, 'WRONG: JOIN LEADS ON campaign_id', JOINED_ROWS, TOTAL_SPEND,
                   25941510, 11286380144.15 FROM wrong_campaign_join
  UNION ALL SELECT 3, 'WRONG: JOIN LEADS ON campaign + date', JOINED_ROWS, TOTAL_SPEND,
                   261684, 123557885.18 FROM wrong_campaign_day_join
)
SELECT METHOD, JOINED_ROWS, TOTAL_SPEND,
       ROUND(TOTAL_SPEND / (SELECT TOTAL_SPEND FROM correct), 6) AS INFLATION_FACTOR,
       EXPECTED_SPEND,
       IFF(JOINED_ROWS = EXPECTED_ROWS AND TOTAL_SPEND = EXPECTED_SPEND, 'PASS', 'FAIL') AS STATUS
FROM methods
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 10. First look: basic SQL analysis (still EDA; the Phase 4 analyses come later)
-- -----------------------------------------------------------------------------
-- 10.1 The plan's starter query: leads and average lead score by lead source
--    Question: which sources bring the most leads, and do their scores differ?
--    Why: LEAD_SCORE is VARCHAR in RAW. The plan's uncast AVG(LEAD_SCORE) does run, but only
--      through implicit VARCHAR -> FLOAT coercion: it returns a binary FLOAT
--      (50.56201270468246 for affiliate) and aborts the whole query on any non-numeric
--      value ("Numeric value 'x' is not recognized") instead of skipping it.
--      TRY_TO_NUMBER makes the type an explicit NUMBER and turns a bad value into NULL.
--      AVG then skips that NULL and silently uses a smaller denominator than TOTAL_LEADS,
--      so SCORED_LEADS = COUNT(TRY_TO_NUMBER(LEAD_SCORE)) is shown next to it. Here every
--      score is numeric (block 2.1), so SCORED_LEADS = TOTAL_LEADS and both averages agree
--      at 4 dp (checked in Snowflake, 2026-10-13).
--      Affiliate and paid search bring the most leads, video the fewest, but every source
--      averages about 50.5. Average score is only one summary, so this is not yet a
--      statement about lead quality by source; Phase 4 compares conversion by score segment
--      and channel properly.
--    Expected: leads per source [P1 s7d] (scored leads the same, [P1 s2]); averages [L2].
-- -----------------------------------------------------------------------------
WITH starter AS (
  SELECT LEAD_SOURCE,
         COUNT(*)                         AS TOTAL_LEADS,
         COUNT(TRY_TO_NUMBER(LEAD_SCORE)) AS SCORED_LEADS,   -- the denominator AVG really uses
         AVG(TRY_TO_NUMBER(LEAD_SCORE))   AS AVG_LEAD_SCORE
  FROM MARKETING_CRM.RAW.LEADS
  GROUP BY LEAD_SOURCE
),
expected (LEAD_SOURCE, EXPECTED_LEADS, EXPECTED_AVG_SCORE) AS (
  SELECT * FROM VALUES
    ('affiliate', 67849, 50.5620), ('paid_search', 65268, 50.6614), ('paid_social', 57619, 50.4742),
    ('display',   45149, 50.5366), ('video',       25799, 50.6429)
)
SELECT COALESCE(s.LEAD_SOURCE, e.LEAD_SOURCE) AS LEAD_SOURCE,
       s.TOTAL_LEADS, s.SCORED_LEADS, ROUND(s.AVG_LEAD_SCORE, 4) AS AVG_LEAD_SCORE,
       IFF(s.TOTAL_LEADS = e.EXPECTED_LEADS AND s.SCORED_LEADS = e.EXPECTED_LEADS
           AND ROUND(s.AVG_LEAD_SCORE, 4) = e.EXPECTED_AVG_SCORE, 'PASS', 'FAIL') AS STATUS
FROM starter s
FULL OUTER JOIN expected e ON e.LEAD_SOURCE = s.LEAD_SOURCE
ORDER BY s.TOTAL_LEADS DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 10.2 Grain-safe channel summary (each fact aggregated to channel separately, then joined)
--    Question: per channel, how many campaigns, how much spend and delivery, how many
--      leads, conversions and purchases, and how much attributed revenue?
--    Why: this is the pattern every MART table follows. Spend, leads and conversions are
--      each aggregated to the channel on their own (each fact joins only its many-to-one
--      parents: DAILY_SPEND -> CAMPAIGNS, CONVERSIONS -> LEADS -> CAMPAIGNS), and the five
--      one-row-per-channel results are then joined 1:1. Spend and revenue reproduce the
--      publisher's reference output to the cent (a check on the load and on the join pattern).
--      Revenue is last-touch attributed revenue, not causal impact. CONVERSIONS counts
--      converted leads of either type; PURCHASES only purchases. Ratios (CTR, CPL, ROAS)
--      are Phase 4 and are always ratios of these sums.
--    Expected: spend / revenue [PUB, P3 F1]; the other bases [P3 F3].
-- -----------------------------------------------------------------------------
WITH campaigns_by_channel AS (
  SELECT CHANNEL, COUNT(*) AS CAMPAIGNS
  FROM RAW.CAMPAIGNS GROUP BY CHANNEL
),
spend_by_channel AS (
  SELECT c.CHANNEL,
         SUM(TRY_TO_NUMBER(d.SPEND, 12, 2)) AS SPEND,
         SUM(TRY_TO_NUMBER(d.IMPRESSIONS))  AS IMPRESSIONS,
         SUM(TRY_TO_NUMBER(d.CLICKS))       AS CLICKS
  FROM RAW.DAILY_SPEND d
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = d.CAMPAIGN_ID
  GROUP BY c.CHANNEL
),
leads_by_channel AS (
  SELECT c.CHANNEL, COUNT(*) AS LEADS
  FROM RAW.LEADS l
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY c.CHANNEL
),
conversions_by_channel AS (
  SELECT c.CHANNEL,
         COUNT(*)                                AS CONVERSIONS,
         COUNT_IF(v.CONVERSION_TYPE = 'purchase') AS PURCHASES,
         SUM(TRY_TO_NUMBER(v.REVENUE, 12, 2))    AS REVENUE
  FROM RAW.CONVERSIONS v
  JOIN RAW.LEADS l     ON l.LEAD_ID = v.LEAD_ID
  JOIN RAW.CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  GROUP BY c.CHANNEL
),
summary AS (
  SELECT k.CHANNEL, k.CAMPAIGNS, s.SPEND, s.IMPRESSIONS, s.CLICKS, l.LEADS,
         v.CONVERSIONS, v.PURCHASES, v.REVENUE
  FROM campaigns_by_channel k
  LEFT JOIN spend_by_channel s       ON s.CHANNEL = k.CHANNEL
  LEFT JOIN leads_by_channel l       ON l.CHANNEL = k.CHANNEL
  LEFT JOIN conversions_by_channel v ON v.CHANNEL = k.CHANNEL
),
summary_with_total AS (
  SELECT 0 AS IS_TOTAL, CHANNEL, CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS,
         CONVERSIONS, PURCHASES, REVENUE
  FROM summary
  UNION ALL
  SELECT 1, 'TOTAL', SUM(CAMPAIGNS), SUM(SPEND), SUM(IMPRESSIONS), SUM(CLICKS), SUM(LEADS),
         SUM(CONVERSIONS), SUM(PURCHASES), SUM(REVENUE)
  FROM summary
),
expected (CHANNEL, CAMPAIGNS, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, PURCHASES, REVENUE) AS (
  SELECT * FROM VALUES
    ('affiliate',    24,  857835.07,  95314042, 2386856,  67849, 10352,  4332,  5610700.73),
    ('paid_search',  24,  897091.53,  49837405, 1740314,  65268, 10019,  4204,  5439329.35),
    ('paid_social',  24,  984731.88,  89520215, 1602785,  57619,  8648,  3646,  4690137.28),
    ('display',      24,  955297.00, 146967688,  879874,  45149,  6744,  2871,  3734117.43),
    ('video',        24,  828094.54,  55205469,  492490,  25799,  3933,  1638,  2087554.22),
    ('TOTAL',       120, 4523050.02, 436844819, 7102319, 261684, 39696, 16691, 21561839.01)
)
SELECT COALESCE(t.CHANNEL, e.CHANNEL) AS CHANNEL,
       t.CAMPAIGNS, t.SPEND, t.IMPRESSIONS, t.CLICKS, t.LEADS, t.CONVERSIONS,
       t.PURCHASES, t.REVENUE AS ATTRIBUTED_REVENUE,
       IFF(t.CAMPAIGNS = e.CAMPAIGNS AND t.SPEND = e.SPEND AND t.IMPRESSIONS = e.IMPRESSIONS
           AND t.CLICKS = e.CLICKS AND t.LEADS = e.LEADS AND t.CONVERSIONS = e.CONVERSIONS
           AND t.PURCHASES = e.PURCHASES AND t.REVENUE = e.REVENUE, 'PASS', 'FAIL') AS STATUS
FROM summary_with_total t
FULL OUTER JOIN expected e ON e.CHANNEL = t.CHANNEL
ORDER BY t.IS_TOTAL, t.REVENUE DESC;


-- -----------------------------------------------------------------------------
-- 10.3 Monthly activity: the first and the last six months
--    Question: how do spend (by spend month), leads (by created month) and conversions (by
--      converted month) move at the edges of the data?
--    Why: each fact is aggregated to the month on its own and then joined on the month.
--      The two conversion columns answer different questions: CONVERSIONS_IN_MONTH is
--      activity-based (when the conversion happened), CONVERSIONS_OF_MONTH_LEADS is
--      lead-cohort-based (conversions of the leads created that month). They differ most
--      at the edges: 2025-12 has 65 leads and 61 conversions, but only 11 of those 65
--      leads converted. Dividing activity conversions by the same month's leads would give
--      a meaningless 94% "conversion rate", so MART keeps an activity fact and a lead-cohort
--      fact and never mixes them on one date axis. 2023-01 and 2025-12 are partial months.
--    Expected: [P2 8e; P3 F5].
-- -----------------------------------------------------------------------------
WITH spend_by_month AS (
  SELECT DATE_TRUNC('month', TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD')) AS MONTH_START,
         SUM(TRY_TO_NUMBER(SPEND, 12, 2)) AS SPEND
  FROM RAW.DAILY_SPEND GROUP BY 1
),
leads_by_month AS (
  SELECT DATE_TRUNC('month', TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD')) AS MONTH_START,
         COUNT(*) AS LEADS
  FROM RAW.LEADS GROUP BY 1
),
conversions_by_month AS (   -- activity basis: the month the conversion happened
  SELECT DATE_TRUNC('month', TRY_TO_DATE(CONVERTED_AT, 'YYYY-MM-DD')) AS MONTH_START,
         COUNT(*) AS CONVERSIONS
  FROM RAW.CONVERSIONS GROUP BY 1
),
cohort_conversions_by_month AS (   -- lead-cohort basis: the month the converting lead was created
  SELECT DATE_TRUNC('month', TRY_TO_DATE(l.CREATED_AT, 'YYYY-MM-DD')) AS MONTH_START,
         COUNT(*) AS CONVERSIONS
  FROM RAW.CONVERSIONS v
  JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID
  GROUP BY 1
),
months AS (
  SELECT MONTH_START FROM spend_by_month
  UNION SELECT MONTH_START FROM leads_by_month
  UNION SELECT MONTH_START FROM conversions_by_month
),
edge_months AS (
  SELECT m.MONTH_START, s.SPEND, l.LEADS,
         c.CONVERSIONS AS CONVERSIONS_IN_MONTH,
         h.CONVERSIONS AS CONVERSIONS_OF_MONTH_LEADS
  FROM months m
  LEFT JOIN spend_by_month s              ON s.MONTH_START = m.MONTH_START
  LEFT JOIN leads_by_month l              ON l.MONTH_START = m.MONTH_START
  LEFT JOIN conversions_by_month c        ON c.MONTH_START = m.MONTH_START
  LEFT JOIN cohort_conversions_by_month h ON h.MONTH_START = m.MONTH_START
  QUALIFY ROW_NUMBER() OVER (ORDER BY m.MONTH_START) <= 6
       OR ROW_NUMBER() OVER (ORDER BY m.MONTH_START DESC) <= 6
),
expected (CALENDAR_MONTH, SPEND, LEADS, CONVERSIONS_IN_MONTH, CONVERSIONS_OF_MONTH_LEADS) AS (
  SELECT * FROM VALUES
    ('2023-01',  23686.55, 1325,  110,  212),
    ('2023-02',  49461.61, 2825,  325,  427),
    ('2023-03', 104283.65, 6229,  798,  914),
    ('2023-04', 104393.90, 5748,  902,  880),
    ('2023-05',  97734.10, 5188,  811,  771),
    ('2023-06', 123064.68, 7491,  963, 1137),
    ('2025-07', 132922.32, 7710, 1101, 1156),
    ('2025-08', 138359.57, 7339, 1190, 1109),
    ('2025-09',  65610.05, 3680,  700,  513),
    ('2025-10',  48774.54, 2826,  462,  445),
    ('2025-11',  16510.95, 1093,  256,  173),
    ('2025-12',    807.04,   65,   61,   11)
)
SELECT COALESCE(TO_CHAR(m.MONTH_START, 'YYYY-MM'), e.CALENDAR_MONTH) AS CALENDAR_MONTH,
       m.SPEND, m.LEADS, m.CONVERSIONS_IN_MONTH, m.CONVERSIONS_OF_MONTH_LEADS,
       IFF(m.SPEND = e.SPEND AND m.LEADS = e.LEADS AND m.CONVERSIONS_IN_MONTH = e.CONVERSIONS_IN_MONTH
           AND m.CONVERSIONS_OF_MONTH_LEADS = e.CONVERSIONS_OF_MONTH_LEADS, 'PASS', 'FAIL') AS STATUS
FROM edge_months m
FULL OUTER JOIN expected e ON e.CALENDAR_MONTH = TO_CHAR(m.MONTH_START, 'YYYY-MM')
ORDER BY COALESCE(TO_CHAR(m.MONTH_START, 'YYYY-MM'), e.CALENDAR_MONTH);
