-- =============================================================================
-- Phase 2 (EDA) / 01b: profiling of the dirty cleaning-challenge extracts (RAW.CHALLENGE_*)
-- -----------------------------------------------------------------------------
-- What this is
--   The publisher's cleaning-challenge files contain injected defects. KNOWN_ISSUES.md names
--   only the classes (duplicated records, casing/whitespace, slash-delimited dates, blank
--   required values) and asks for the affected rows to be discovered with code. This file
--   does that in Snowflake SQL before Phase 3 cleans anything: it finds every defect, argues
--   each date reading and each possible fill from evidence, and previews the Phase 3
--   reconciliation against the clean release.
-- Read-only
--   Only USE and SELECT/WITH statements: nothing is created, changed or loaded. RAW stays
--   all-VARCHAR, so every cast happens inside a query (TRY_TO_DATE, TRY_TO_NUMBER). Phase 3
--   turns the rules previewed here into STAGING models with tests.
-- How to run
--   .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/01b_challenge_profiling.sql
--   The runner prints every result and exits 1 if any row has STATUS = 'FAIL'. It prints
--   only the first SQL line of each statement, so the first column of every result (BLOCK)
--   names the block below. Results without a STATUS column are listings: their comment
--   states the rows to expect. The output of the last run is in
--   docs/evidence/01b_challenge_profiling.txt. In Snowsight, select one block and Run it.
-- Evidence rule
--   Sections 2-7 use only the challenge files. The clean release (RAW.CAMPAIGNS etc.) appears
--   only in section 1 (is each extract a subset of it?) and section 8 (does the cleaned
--   extract reproduce it?), as a test and never as an input to a fix. The publisher calls
--   the clean files "the reference, not a row-by-row answer key".
-- Conventions
--   A defect is one bad cell or one surplus copy of a row. Expected total: 15 = 4 duplicate
--   rows + 3 casing/whitespace cells + 4 slash dates + 4 blank cells (section 7).
--   _SOURCE_ROW_NUMBER is the data row in the file (1 = first row after the header), so the
--   file line is _SOURCE_ROW_NUMBER + 1. Blank cells are '' and never NULL, because the load
--   used EMPTY_FIELD_AS_NULL = FALSE and NULL_IF = () (sql/setup/01_raw_objects.sql).
--   "Blank" (1f, 4a, 4b, 5a, 7) means empty after removing spaces, tabs, LF, CR and NBSP:
--   TRIM(x, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) = ''. Snowflake's TRIM without a
--   character list removes only the space character, so the list is spelled out. Any other
--   character outside ASCII space..tilde is caught by the non-printable check of 3a, which
--   finds none; that is also why the cleaning rules of section 8 can use plain TRIM.
--   Year-first slash dates are recognised by one pattern everywhere, [0-9]{4}/[0-9]{1,2}/[0-9]{1,2},
--   and parsed with 'YYYY/MM/DD', which also reads one-digit parts (TRY_TO_DATE('2023/7/4',
--   'YYYY/MM/DD') = 2023-07-04). So every cell that 4a and 7 count as a slash date is one the
--   parse paths read. Phase 3's date parsing is to use the same gate.
--   "De-duplicated" means QUALIFY ROW_NUMBER() OVER (PARTITION BY <key> ORDER BY
--   _SOURCE_ROW_NUMBER) = 1: the first copy is kept (block 2a shows both copies are identical).
--   Table order in every result: campaigns, daily_spend, leads, conversions.
-- Expected values
--   Every EXPECTED below comes from the local profiling of the same CSVs on 2026-10-13 (DuckDB,
--   before the Snowflake account existed). The few it did not compute (the challenge-only
--   invariants of 4c, blocks 3e and 5d, the 118 of 5b and the N_EVALUATED counts of 6b) come
--   from an independent Python recomputation (csv + Decimal) of the same files, which also
--   reproduced every DuckDB figure. Snowflake must match them exactly.
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.RAW;


-- -----------------------------------------------------------------------------
-- 0. Context: who ran this, where and when. Expect role CRM_TRANSFORMER with no secondary
--    roles, warehouse MARKETING_WH and schema MARKETING_CRM.RAW.
-- -----------------------------------------------------------------------------
SELECT '0' AS BLOCK, CURRENT_USER() AS USER_NAME, CURRENT_ROLE() AS ROLE_NAME,
       CURRENT_SECONDARY_ROLES() AS SECONDARY_ROLES, CURRENT_WAREHOUSE() AS WAREHOUSE_NAME,
       CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() AS SCHEMA_NAME, CURRENT_REGION() AS REGION,
       CURRENT_VERSION() AS SNOWFLAKE_VERSION, TO_VARCHAR(SYSDATE(), 'YYYY-MM-DD HH24:MI') || ' UTC' AS RUN_AT,
       IFF(CURRENT_ROLE() = 'CRM_TRANSFORMER' AND CURRENT_WAREHOUSE() = 'MARKETING_WH'
           AND CURRENT_DATABASE() = 'MARKETING_CRM' AND CURRENT_SCHEMA() = 'RAW'
           AND PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles::STRING = '', 'PASS', 'FAIL') AS STATUS;


-- =============================================================================
-- 1. SHAPE: size, keys, relationship to the clean release, declared and intended types
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1a. Rows versus distinct keys, and the lineage of each extract.
--     Expect 121 / 2,001 / 2,001 / 2,001 rows over 120 / 2,000 / 2,000 / 2,000 keys: exactly
--     one surplus row per table. One source file per table, row numbers 1..N without gaps.
-- -----------------------------------------------------------------------------
SELECT '1a' AS BLOCK, TABLE_NAME, ROW_COUNT, DISTINCT_KEYS, ROW_COUNT - DISTINCT_KEYS AS SURPLUS_ROWS,
       MIN_KEY, MAX_KEY, SOURCE_FILE, FIRST_ROW, LAST_ROW, LOADED_AT, EXPECTED_ROWS, EXPECTED_KEYS,
       IFF(ROW_COUNT = EXPECTED_ROWS AND DISTINCT_KEYS = EXPECTED_KEYS AND N_FILES = 1
           AND FIRST_ROW = 1 AND LAST_ROW = ROW_COUNT, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT,
                   COUNT(DISTINCT CAMPAIGN_ID) AS DISTINCT_KEYS, MIN(CAMPAIGN_ID) AS MIN_KEY, MAX(CAMPAIGN_ID) AS MAX_KEY,
                   MIN(_SOURCE_FILE) AS SOURCE_FILE, COUNT(DISTINCT _SOURCE_FILE) AS N_FILES,
                   MIN(_SOURCE_ROW_NUMBER) AS FIRST_ROW, MAX(_SOURCE_ROW_NUMBER) AS LAST_ROW,
                   MAX(_LOADED_AT) AS LOADED_AT, 121 AS EXPECTED_ROWS, 120 AS EXPECTED_KEYS
            FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', COUNT(*), COUNT(DISTINCT SPEND_ID), MIN(SPEND_ID), MAX(SPEND_ID),
                   MIN(_SOURCE_FILE), COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER),
                   MAX(_LOADED_AT), 2001, 2000
            FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', COUNT(*), COUNT(DISTINCT LEAD_ID), MIN(LEAD_ID), MAX(LEAD_ID),
                   MIN(_SOURCE_FILE), COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER),
                   MAX(_LOADED_AT), 2001, 2000
            FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', COUNT(*), COUNT(DISTINCT CONVERSION_ID), MIN(CONVERSION_ID), MAX(CONVERSION_ID),
                   MIN(_SOURCE_FILE), COUNT(DISTINCT _SOURCE_FILE), MIN(_SOURCE_ROW_NUMBER), MAX(_SOURCE_ROW_NUMBER),
                   MAX(_LOADED_AT), 2001, 2000
            FROM RAW.CHALLENGE_CONVERSIONS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 1b. Is each extract a subset of the clean release, and a contiguous prefix of it?
--     Subset: no extract key is missing from the clean table (NOT EXISTS). Prefix: every
--     clean key up to the extract's highest key is in the extract, and both start at the
--     same key. The prefix test compares VARCHAR keys with <=, which is numeric order only
--     when every key has one prefix and one width: block 1f proves that for the extracts, and
--     CLEAN_KEYS_OFF_PATTERN (keys not matching CMP[0-9]{4}, DSP[0-9]{7}, L[0-9]{8},
--     CV[0-9]{7}; also block 2.1 of 01_data_profiling.sql) proves it for the clean release.
--     Expect 0 / 0 / 0 everywhere: the extracts are the first 120 / 2,000 / 2,000 / 2,000 keys
--     of a 120 / 11,240 / 261,684 / 39,696-row release.
-- -----------------------------------------------------------------------------
SELECT '1b' AS BLOCK, TABLE_NAME, CHALLENGE_KEYS, KEYS_NOT_IN_CLEAN, CLEAN_ROWS, CLEAN_KEYS_OFF_PATTERN, CLEAN_KEYS_UP_TO_MAX,
       CLEAN_KEYS_MISSING_UP_TO_MAX, MIN_KEY_CHALLENGE, MIN_KEY_CLEAN, EXPECTED_CLEAN_ROWS,
       IFF(KEYS_NOT_IN_CLEAN = 0 AND CLEAN_KEYS_OFF_PATTERN = 0 AND CLEAN_KEYS_MISSING_UP_TO_MAX = 0
           AND CLEAN_KEYS_UP_TO_MAX = CHALLENGE_KEYS AND MIN_KEY_CHALLENGE = MIN_KEY_CLEAN
           AND CLEAN_ROWS = EXPECTED_CLEAN_ROWS, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME,
         (SELECT COUNT(DISTINCT CAMPAIGN_ID) FROM RAW.CHALLENGE_CAMPAIGNS) AS CHALLENGE_KEYS,
         (SELECT COUNT(DISTINCT x.CAMPAIGN_ID) FROM RAW.CHALLENGE_CAMPAIGNS x
           WHERE NOT EXISTS (SELECT 1 FROM RAW.CAMPAIGNS r WHERE r.CAMPAIGN_ID = x.CAMPAIGN_ID)) AS KEYS_NOT_IN_CLEAN,
         (SELECT COUNT(*) FROM RAW.CAMPAIGNS) AS CLEAN_ROWS,
         (SELECT COUNT_IF(NOT REGEXP_LIKE(COALESCE(CAMPAIGN_ID, ''), 'CMP[0-9]{4}')) FROM RAW.CAMPAIGNS) AS CLEAN_KEYS_OFF_PATTERN,
         (SELECT COUNT(*) FROM RAW.CAMPAIGNS r
           WHERE r.CAMPAIGN_ID <= (SELECT MAX(CAMPAIGN_ID) FROM RAW.CHALLENGE_CAMPAIGNS)) AS CLEAN_KEYS_UP_TO_MAX,
         (SELECT COUNT(*) FROM RAW.CAMPAIGNS r
           WHERE r.CAMPAIGN_ID <= (SELECT MAX(CAMPAIGN_ID) FROM RAW.CHALLENGE_CAMPAIGNS)
             AND NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_CAMPAIGNS x WHERE x.CAMPAIGN_ID = r.CAMPAIGN_ID)) AS CLEAN_KEYS_MISSING_UP_TO_MAX,
         (SELECT MIN(CAMPAIGN_ID) FROM RAW.CHALLENGE_CAMPAIGNS) AS MIN_KEY_CHALLENGE,
         (SELECT MIN(CAMPAIGN_ID) FROM RAW.CAMPAIGNS) AS MIN_KEY_CLEAN,
         120 AS EXPECTED_CLEAN_ROWS
  UNION ALL
  SELECT 2, 'CHALLENGE_DAILY_SPEND',
         (SELECT COUNT(DISTINCT SPEND_ID) FROM RAW.CHALLENGE_DAILY_SPEND),
         (SELECT COUNT(DISTINCT x.SPEND_ID) FROM RAW.CHALLENGE_DAILY_SPEND x
           WHERE NOT EXISTS (SELECT 1 FROM RAW.DAILY_SPEND r WHERE r.SPEND_ID = x.SPEND_ID)),
         (SELECT COUNT(*) FROM RAW.DAILY_SPEND),
         (SELECT COUNT_IF(NOT REGEXP_LIKE(COALESCE(SPEND_ID, ''), 'DSP[0-9]{7}')) FROM RAW.DAILY_SPEND),
         (SELECT COUNT(*) FROM RAW.DAILY_SPEND r
           WHERE r.SPEND_ID <= (SELECT MAX(SPEND_ID) FROM RAW.CHALLENGE_DAILY_SPEND)),
         (SELECT COUNT(*) FROM RAW.DAILY_SPEND r
           WHERE r.SPEND_ID <= (SELECT MAX(SPEND_ID) FROM RAW.CHALLENGE_DAILY_SPEND)
             AND NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_DAILY_SPEND x WHERE x.SPEND_ID = r.SPEND_ID)),
         (SELECT MIN(SPEND_ID) FROM RAW.CHALLENGE_DAILY_SPEND),
         (SELECT MIN(SPEND_ID) FROM RAW.DAILY_SPEND),
         11240
  UNION ALL
  SELECT 3, 'CHALLENGE_LEADS',
         (SELECT COUNT(DISTINCT LEAD_ID) FROM RAW.CHALLENGE_LEADS),
         (SELECT COUNT(DISTINCT x.LEAD_ID) FROM RAW.CHALLENGE_LEADS x
           WHERE NOT EXISTS (SELECT 1 FROM RAW.LEADS r WHERE r.LEAD_ID = x.LEAD_ID)),
         (SELECT COUNT(*) FROM RAW.LEADS),
         (SELECT COUNT_IF(NOT REGEXP_LIKE(COALESCE(LEAD_ID, ''), 'L[0-9]{8}')) FROM RAW.LEADS),
         (SELECT COUNT(*) FROM RAW.LEADS r
           WHERE r.LEAD_ID <= (SELECT MAX(LEAD_ID) FROM RAW.CHALLENGE_LEADS)),
         (SELECT COUNT(*) FROM RAW.LEADS r
           WHERE r.LEAD_ID <= (SELECT MAX(LEAD_ID) FROM RAW.CHALLENGE_LEADS)
             AND NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_LEADS x WHERE x.LEAD_ID = r.LEAD_ID)),
         (SELECT MIN(LEAD_ID) FROM RAW.CHALLENGE_LEADS),
         (SELECT MIN(LEAD_ID) FROM RAW.LEADS),
         261684
  UNION ALL
  SELECT 4, 'CHALLENGE_CONVERSIONS',
         (SELECT COUNT(DISTINCT CONVERSION_ID) FROM RAW.CHALLENGE_CONVERSIONS),
         (SELECT COUNT(DISTINCT x.CONVERSION_ID) FROM RAW.CHALLENGE_CONVERSIONS x
           WHERE NOT EXISTS (SELECT 1 FROM RAW.CONVERSIONS r WHERE r.CONVERSION_ID = x.CONVERSION_ID)),
         (SELECT COUNT(*) FROM RAW.CONVERSIONS),
         (SELECT COUNT_IF(NOT REGEXP_LIKE(COALESCE(CONVERSION_ID, ''), 'CV[0-9]{7}')) FROM RAW.CONVERSIONS),
         (SELECT COUNT(*) FROM RAW.CONVERSIONS r
           WHERE r.CONVERSION_ID <= (SELECT MAX(CONVERSION_ID) FROM RAW.CHALLENGE_CONVERSIONS)),
         (SELECT COUNT(*) FROM RAW.CONVERSIONS r
           WHERE r.CONVERSION_ID <= (SELECT MAX(CONVERSION_ID) FROM RAW.CHALLENGE_CONVERSIONS)
             AND NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_CONVERSIONS x WHERE x.CONVERSION_ID = r.CONVERSION_ID)),
         (SELECT MIN(CONVERSION_ID) FROM RAW.CHALLENGE_CONVERSIONS),
         (SELECT MIN(CONVERSION_ID) FROM RAW.CONVERSIONS),
         39696
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 1c. Relationships between the extracts (distinct keys, so the duplicates do not count twice).
--     Every spend row and lead points to a campaign in the extract. Conversions are cut by
--     conversion_id and leads by lead_id, so 1,687 of the 2,000 conversions point to leads
--     outside the leads extract BY CONSTRUCTION (all exist in the clean release). That is a
--     property of how the extracts were cut, not an injected defect: Phase 3 tests the
--     conversions -> leads relationship against the clean leads, not the challenge leads.
-- -----------------------------------------------------------------------------
SELECT '1c' AS BLOCK, CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'spend rows: campaign not in extract' AS CHECK_NAME, COUNT(DISTINCT d.SPEND_ID) AS ACTUAL, 0 AS EXPECTED
            FROM RAW.CHALLENGE_DAILY_SPEND d
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_CAMPAIGNS c WHERE c.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 2, 'leads: campaign not in extract', COUNT(DISTINCT l.LEAD_ID), 0
            FROM RAW.CHALLENGE_LEADS l
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_CAMPAIGNS c WHERE c.CAMPAIGN_ID = l.CAMPAIGN_ID)
  UNION ALL SELECT 3, 'conversions: lead not in extract', COUNT(DISTINCT v.CONVERSION_ID), 1687
            FROM RAW.CHALLENGE_CONVERSIONS v
            WHERE NOT EXISTS (SELECT 1 FROM RAW.CHALLENGE_LEADS l WHERE l.LEAD_ID = v.LEAD_ID)
  UNION ALL SELECT 4, 'conversions: lead not in clean leads', COUNT(DISTINCT v.CONVERSION_ID), 0
            FROM RAW.CHALLENGE_CONVERSIONS v
            WHERE NOT EXISTS (SELECT 1 FROM RAW.LEADS l WHERE l.LEAD_ID = v.LEAD_ID)
  UNION ALL SELECT 5, 'extract leads with an extract conversion', COUNT(DISTINCT l.LEAD_ID), 313
            FROM RAW.CHALLENGE_LEADS l
            WHERE EXISTS (SELECT 1 FROM RAW.CHALLENGE_CONVERSIONS v WHERE v.LEAD_ID = l.LEAD_ID)
  UNION ALL SELECT 6, 'clean conversions of extract leads', COUNT(*), 313
            FROM RAW.CONVERSIONS v
            WHERE EXISTS (SELECT 1 FROM RAW.CHALLENGE_LEADS l WHERE l.LEAD_ID = v.LEAD_ID)
  UNION ALL SELECT 7, 'campaigns with spend rows in extract', COUNT(DISTINCT CAMPAIGN_ID), 23 FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 8, 'campaigns with leads in extract', COUNT(DISTINCT CAMPAIGN_ID), 2 FROM RAW.CHALLENGE_LEADS
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 1d. How complete each fact extract is per campaign, compared with the clean release
--     (conversions are mapped to campaigns through the clean leads, see 1c).
--     Expect daily_spend: 22 complete campaigns (CMP0001..CMP0022) + CMP0023 27/97;
--     leads: CMP0001 complete + CMP0002 626/1849; conversions: 7 complete (CMP0001..CMP0007)
--     + CMP0008 32/462. CMP0001 is the only campaign complete in all three, which is why the
--     aggregate check in 8c uses it. Funnel KPIs cannot be computed from the extracts.
-- -----------------------------------------------------------------------------
WITH ds  AS (SELECT CAMPAIGN_ID, COUNT(DISTINCT SPEND_ID) AS N FROM RAW.CHALLENGE_DAILY_SPEND GROUP BY CAMPAIGN_ID),
     rds AS (SELECT CAMPAIGN_ID, COUNT(*) AS N FROM RAW.DAILY_SPEND GROUP BY CAMPAIGN_ID),
     ld  AS (SELECT CAMPAIGN_ID, COUNT(DISTINCT LEAD_ID) AS N FROM RAW.CHALLENGE_LEADS GROUP BY CAMPAIGN_ID),
     rld AS (SELECT CAMPAIGN_ID, COUNT(*) AS N FROM RAW.LEADS GROUP BY CAMPAIGN_ID),
     cv  AS (SELECT l.CAMPAIGN_ID, COUNT(DISTINCT v.CONVERSION_ID) AS N
             FROM RAW.CHALLENGE_CONVERSIONS v JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID GROUP BY l.CAMPAIGN_ID),
     rcv AS (SELECT l.CAMPAIGN_ID, COUNT(*) AS N
             FROM RAW.CONVERSIONS v JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID GROUP BY l.CAMPAIGN_ID),
     per_campaign AS (
                 SELECT 1 AS ORD, 'CHALLENGE_DAILY_SPEND' AS TABLE_NAME, x.CAMPAIGN_ID, x.N AS N_EXTRACT, r.N AS N_CLEAN
                 FROM ds x JOIN rds r ON r.CAMPAIGN_ID = x.CAMPAIGN_ID
       UNION ALL SELECT 2, 'CHALLENGE_LEADS', x.CAMPAIGN_ID, x.N, r.N FROM ld x JOIN rld r ON r.CAMPAIGN_ID = x.CAMPAIGN_ID
       UNION ALL SELECT 3, 'CHALLENGE_CONVERSIONS', x.CAMPAIGN_ID, x.N, r.N FROM cv x JOIN rcv r ON r.CAMPAIGN_ID = x.CAMPAIGN_ID),
     summary AS (
       SELECT ORD, TABLE_NAME, COUNT(*) AS CAMPAIGNS_PRESENT, COUNT_IF(N_EXTRACT = N_CLEAN) AS COMPLETE_CAMPAIGNS,
              MIN(IFF(N_EXTRACT = N_CLEAN, CAMPAIGN_ID, NULL)) || '..' || MAX(IFF(N_EXTRACT = N_CLEAN, CAMPAIGN_ID, NULL)) AS COMPLETE_RANGE,
              LISTAGG(IFF(N_EXTRACT < N_CLEAN, CAMPAIGN_ID || ' ' || N_EXTRACT || '/' || N_CLEAN, NULL), ', ')
                WITHIN GROUP (ORDER BY CAMPAIGN_ID) AS PARTIAL_CAMPAIGNS,
              COUNT_IF(N_EXTRACT > N_CLEAN) AS MORE_THAN_CLEAN
       FROM per_campaign GROUP BY ORD, TABLE_NAME)
SELECT '1d' AS BLOCK, TABLE_NAME, CAMPAIGNS_PRESENT, COMPLETE_CAMPAIGNS, COMPLETE_RANGE, PARTIAL_CAMPAIGNS, MORE_THAN_CLEAN,
       EXPECTED_COMPLETE, EXPECTED_PARTIAL,
       IFF(COMPLETE_CAMPAIGNS = EXPECTED_COMPLETE AND PARTIAL_CAMPAIGNS = EXPECTED_PARTIAL AND MORE_THAN_CLEAN = 0
           AND CAMPAIGNS_PRESENT = EXPECTED_COMPLETE + 1, 'PASS', 'FAIL') AS STATUS
FROM (SELECT s.*,
             DECODE(TABLE_NAME, 'CHALLENGE_DAILY_SPEND', 22, 'CHALLENGE_LEADS', 1, 'CHALLENGE_CONVERSIONS', 7) AS EXPECTED_COMPLETE,
             DECODE(TABLE_NAME, 'CHALLENGE_DAILY_SPEND', 'CMP0023 27/97', 'CHALLENGE_LEADS', 'CMP0002 626/1849',
                    'CHALLENGE_CONVERSIONS', 'CMP0008 32/462') AS EXPECTED_PARTIAL
      FROM summary s)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 1e. Declared types: every business column is TEXT (lossless landing), plus the three
--     lineage columns (_SOURCE_FILE TEXT, _SOURCE_ROW_NUMBER NUMBER, _LOADED_AT TIMESTAMP_LTZ).
--     Expect 7 / 6 / 5 / 5 business columns, all TEXT.
-- -----------------------------------------------------------------------------
SELECT '1e' AS BLOCK, TABLE_NAME, N_COLUMNS, BUSINESS_COLUMNS, BUSINESS_COLUMNS_TEXT, LINEAGE_COLUMNS_OK,
       EXPECTED_BUSINESS_COLUMNS,
       IFF(BUSINESS_COLUMNS = EXPECTED_BUSINESS_COLUMNS AND BUSINESS_COLUMNS_TEXT = BUSINESS_COLUMNS
           AND LINEAGE_COLUMNS_OK = 3 AND N_COLUMNS = BUSINESS_COLUMNS + 3, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT TABLE_NAME, COUNT(*) AS N_COLUMNS,
         COUNT_IF(LEFT(COLUMN_NAME, 1) <> '_') AS BUSINESS_COLUMNS,
         COUNT_IF(LEFT(COLUMN_NAME, 1) <> '_' AND DATA_TYPE = 'TEXT') AS BUSINESS_COLUMNS_TEXT,
         COUNT_IF((COLUMN_NAME = '_SOURCE_FILE' AND DATA_TYPE = 'TEXT')
               OR (COLUMN_NAME = '_SOURCE_ROW_NUMBER' AND DATA_TYPE = 'NUMBER')
               OR (COLUMN_NAME = '_LOADED_AT' AND DATA_TYPE = 'TIMESTAMP_LTZ')) AS LINEAGE_COLUMNS_OK,
         DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 7, 'CHALLENGE_DAILY_SPEND', 6, 5) AS EXPECTED_BUSINESS_COLUMNS,
         DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4) AS ORD
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'RAW'
    AND TABLE_NAME IN ('CHALLENGE_CAMPAIGNS', 'CHALLENGE_DAILY_SPEND', 'CHALLENGE_LEADS', 'CHALLENGE_CONVERSIONS')
  GROUP BY TABLE_NAME
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 1f. Does every cell conform to its intended type? One row per business column (23 rows).
--     Intended types, from the publisher's DATA_DICTIONARY.md (codes and the 1..100 score) and
--     the ID patterns of the release:
--       id       CMP[0-9]{4}, DSP[0-9]{7}, L[0-9]{8}, CV[0-9]{7}
--       code     channel / lead_source in (affiliate, display, paid_search, paid_social, video),
--                objective in (awareness, lead_gen, acquisition), conversion_type in (trial, purchase)
--       name     "<Channel words> <YYYY> <NNN>", e.g. Paid Search 2023 001
--       date     YYYY-MM-DD that is a real calendar date
--       integer  digits only        decimal(12,2)  digits, a dot, two digits
--     Blank = empty after removing spaces, tabs, LF, CR and NBSP (see Conventions).
--     Expect 0 NULLs, 4 blank cells (campaign_name, spend_date, created_at, converted_at) and
--     7 non-blank nonconforming cells (campaign_name, start_date, spend_date, created_at,
--     lead_source, converted_at, conversion_type), 1 each. Sections 3-5 classify them.
-- -----------------------------------------------------------------------------
WITH cells AS (   -- every business cell of the four extracts, one row each (INCLUDE NULLS keeps NULLs)
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
                         START_DATE, END_DATE, BUDGET FROM RAW.CHALLENGE_CAMPAIGNS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT SPEND_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND
                  FROM RAW.CHALLENGE_DAILY_SPEND)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL SELECT 'CHALLENGE_LEADS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT LEAD_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE
                  FROM RAW.CHALLENGE_LEADS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CONVERSION_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE
                  FROM RAW.CHALLENGE_CONVERSIONS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
judged AS (
  SELECT c.*,
         CASE WHEN COLUMN_NAME IN ('CAMPAIGN_ID', 'SPEND_ID', 'LEAD_ID', 'CONVERSION_ID') THEN 'id'
              WHEN COLUMN_NAME IN ('CHANNEL', 'OBJECTIVE', 'LEAD_SOURCE', 'CONVERSION_TYPE') THEN 'code'
              WHEN COLUMN_NAME = 'CAMPAIGN_NAME' THEN 'name'
              WHEN COLUMN_NAME IN ('START_DATE', 'END_DATE', 'SPEND_DATE', 'CREATED_AT', 'CONVERTED_AT') THEN 'date'
              WHEN COLUMN_NAME IN ('IMPRESSIONS', 'CLICKS', 'LEAD_SCORE') THEN 'integer'
              ELSE 'decimal(12,2)' END AS INTENDED_TYPE,
         CASE WHEN COLUMN_NAME = 'CAMPAIGN_ID'     THEN REGEXP_LIKE(V, 'CMP[0-9]{4}')
              WHEN COLUMN_NAME = 'SPEND_ID'        THEN REGEXP_LIKE(V, 'DSP[0-9]{7}')
              WHEN COLUMN_NAME = 'LEAD_ID'         THEN REGEXP_LIKE(V, 'L[0-9]{8}')
              WHEN COLUMN_NAME = 'CONVERSION_ID'   THEN REGEXP_LIKE(V, 'CV[0-9]{7}')
              WHEN COLUMN_NAME = 'CAMPAIGN_NAME'   THEN REGEXP_LIKE(V, '[A-Z][a-z]+( [A-Z][a-z]+)? [0-9]{4} [0-9]{3}')
              WHEN COLUMN_NAME IN ('CHANNEL', 'LEAD_SOURCE') THEN V IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video')
              WHEN COLUMN_NAME = 'OBJECTIVE'       THEN V IN ('awareness', 'lead_gen', 'acquisition')
              WHEN COLUMN_NAME = 'CONVERSION_TYPE' THEN V IN ('trial', 'purchase')
              WHEN COLUMN_NAME IN ('START_DATE', 'END_DATE', 'SPEND_DATE', 'CREATED_AT', 'CONVERTED_AT')
                   THEN REGEXP_LIKE(V, '[0-9]{4}-[0-9]{2}-[0-9]{2}') AND TRY_TO_DATE(V, 'YYYY-MM-DD') IS NOT NULL
              WHEN COLUMN_NAME IN ('IMPRESSIONS', 'CLICKS', 'LEAD_SCORE')
                   THEN REGEXP_LIKE(V, '[0-9]+') AND TRY_TO_NUMBER(V) IS NOT NULL
              ELSE REGEXP_LIKE(V, '[0-9]+[.][0-9]{2}') AND TRY_TO_NUMBER(V, 12, 2) IS NOT NULL END AS CONFORMS
  FROM cells c),
per_column AS (
  SELECT TABLE_NAME, COLUMN_NAME, ANY_VALUE(INTENDED_TYPE) AS INTENDED_TYPE, COUNT(*) AS N_CELLS,
         COUNT_IF(CONFORMS) AS N_CONFORMING, COUNT_IF(TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) = '') AS N_BLANK, COUNT_IF(V IS NULL) AS N_NULL,
         COUNT_IF(TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) <> '' AND NOT CONFORMS) AS N_NONCONFORMING
  FROM judged GROUP BY TABLE_NAME, COLUMN_NAME)
SELECT '1f' AS BLOCK, TABLE_NAME, COLUMN_NAME, INTENDED_TYPE, N_CELLS, N_CONFORMING, N_BLANK, N_NULL, N_NONCONFORMING,
       EXPECTED_BLANK, EXPECTED_NONCONFORMING,
       IFF(N_NULL = 0 AND N_BLANK = EXPECTED_BLANK AND N_NONCONFORMING = EXPECTED_NONCONFORMING
           AND N_CONFORMING + N_BLANK + N_NONCONFORMING = N_CELLS, 'PASS', 'FAIL') AS STATUS
FROM (SELECT p.*,
             IFF(TABLE_NAME || '.' || COLUMN_NAME IN ('CHALLENGE_CAMPAIGNS.CAMPAIGN_NAME', 'CHALLENGE_DAILY_SPEND.SPEND_DATE',
                                                      'CHALLENGE_LEADS.CREATED_AT', 'CHALLENGE_CONVERSIONS.CONVERTED_AT'), 1, 0) AS EXPECTED_BLANK,
             IFF(TABLE_NAME || '.' || COLUMN_NAME IN ('CHALLENGE_CAMPAIGNS.CAMPAIGN_NAME', 'CHALLENGE_CAMPAIGNS.START_DATE',
                                                      'CHALLENGE_DAILY_SPEND.SPEND_DATE', 'CHALLENGE_LEADS.CREATED_AT',
                                                      'CHALLENGE_LEADS.LEAD_SOURCE', 'CHALLENGE_CONVERSIONS.CONVERTED_AT',
                                                      'CHALLENGE_CONVERSIONS.CONVERSION_TYPE'), 1, 0) AS EXPECTED_NONCONFORMING,
             DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4) AS ORD
      FROM per_column p)
ORDER BY ORD, COLUMN_NAME;


-- =============================================================================
-- 2. DUPLICATES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2a. Exact duplicates (GROUP BY every business column HAVING COUNT(*) > 1) versus key
--     duplicates whose copies differ, raw and after TRIM/LOWER of every column.
--     Expect per table: 1 key with 2 copies, 1 exact-duplicate group, 1 surplus copy,
--     0 keys whose copies differ (raw or normalized). So every duplicate is a byte-identical
--     copy and "which copy wins" does not matter.
-- -----------------------------------------------------------------------------
WITH exact_groups AS (
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, COUNT(*) AS N_COPIES
            FROM RAW.CHALLENGE_CAMPAIGNS
            GROUP BY CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET HAVING COUNT(*) > 1
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', COUNT(*)
            FROM RAW.CHALLENGE_DAILY_SPEND
            GROUP BY SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND HAVING COUNT(*) > 1
  UNION ALL SELECT 'CHALLENGE_LEADS', COUNT(*)
            FROM RAW.CHALLENGE_LEADS
            GROUP BY LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE HAVING COUNT(*) > 1
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', COUNT(*)
            FROM RAW.CHALLENGE_CONVERSIONS
            GROUP BY CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE HAVING COUNT(*) > 1),
key_versions AS (   -- one row per key: copies, and distinct payloads raw and after TRIM/LOWER (HASH is NULL-safe)
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, COUNT(*) AS N_ROWS,
                   COUNT(DISTINCT HASH(CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET)) AS N_VERSIONS,
                   COUNT(DISTINCT HASH(LOWER(TRIM(CAMPAIGN_NAME)), LOWER(TRIM(CHANNEL)), LOWER(TRIM(OBJECTIVE)),
                                       TRIM(START_DATE), TRIM(END_DATE), TRIM(BUDGET))) AS N_VERSIONS_NORMALIZED
            FROM RAW.CHALLENGE_CAMPAIGNS GROUP BY CAMPAIGN_ID
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', SPEND_ID, COUNT(*),
                   COUNT(DISTINCT HASH(CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND)),
                   COUNT(DISTINCT HASH(UPPER(TRIM(CAMPAIGN_ID)), TRIM(SPEND_DATE), TRIM(IMPRESSIONS), TRIM(CLICKS), TRIM(SPEND)))
            FROM RAW.CHALLENGE_DAILY_SPEND GROUP BY SPEND_ID
  UNION ALL SELECT 'CHALLENGE_LEADS', LEAD_ID, COUNT(*),
                   COUNT(DISTINCT HASH(CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE)),
                   COUNT(DISTINCT HASH(UPPER(TRIM(CAMPAIGN_ID)), TRIM(CREATED_AT), LOWER(TRIM(LEAD_SOURCE)), TRIM(LEAD_SCORE)))
            FROM RAW.CHALLENGE_LEADS GROUP BY LEAD_ID
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', CONVERSION_ID, COUNT(*),
                   COUNT(DISTINCT HASH(LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE)),
                   COUNT(DISTINCT HASH(UPPER(TRIM(LEAD_ID)), TRIM(CONVERTED_AT), LOWER(TRIM(CONVERSION_TYPE)), TRIM(REVENUE)))
            FROM RAW.CHALLENGE_CONVERSIONS GROUP BY CONVERSION_ID),
per_table AS (
  SELECT k.TABLE_NAME, SUM(k.N_ROWS) AS ROW_COUNT, COUNT(*) AS DISTINCT_KEYS, COUNT_IF(k.N_ROWS > 1) AS KEYS_WITH_COPIES,
         COUNT_IF(k.N_VERSIONS > 1) AS KEYS_COPIES_DIFFER, COUNT_IF(k.N_VERSIONS_NORMALIZED > 1) AS KEYS_DIFFER_NORMALIZED
  FROM key_versions k GROUP BY k.TABLE_NAME),
exact AS (SELECT TABLE_NAME, COUNT(*) AS EXACT_DUP_GROUPS, SUM(N_COPIES - 1) AS SURPLUS_EXACT_COPIES FROM exact_groups GROUP BY TABLE_NAME)
SELECT '2a' AS BLOCK, p.TABLE_NAME, p.ROW_COUNT, p.DISTINCT_KEYS, p.KEYS_WITH_COPIES,
       COALESCE(e.EXACT_DUP_GROUPS, 0) AS EXACT_DUP_GROUPS, COALESCE(e.SURPLUS_EXACT_COPIES, 0) AS SURPLUS_EXACT_COPIES,
       p.KEYS_COPIES_DIFFER, p.KEYS_DIFFER_NORMALIZED, 1 AS EXPECTED_SURPLUS,
       IFF(p.KEYS_WITH_COPIES = 1 AND COALESCE(e.EXACT_DUP_GROUPS, 0) = 1 AND COALESCE(e.SURPLUS_EXACT_COPIES, 0) = 1
           AND p.ROW_COUNT - p.DISTINCT_KEYS = 1 AND p.KEYS_COPIES_DIFFER = 0 AND p.KEYS_DIFFER_NORMALIZED = 0,
           'PASS', 'FAIL') AS STATUS
FROM per_table p LEFT JOIN exact e ON e.TABLE_NAME = p.TABLE_NAME
ORDER BY DECODE(p.TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4);


-- -----------------------------------------------------------------------------
-- 2b. Every copy of every duplicated key, located by source row
--     (QUALIFY COUNT(*) OVER (PARTITION BY key) > 1). Expect 8 rows: CMP0001 rows 1 and 121,
--     DSP0000001, L00000001 and CV0000001 rows 1 and 2001, i.e. the first data row repeated as
--     the last line of each file. STATUS only on the later copies (COPY_NO > 1): PASS when the
--     copy's ROW_HASH equals the first copy's. The first copy is the reference and has no STATUS
--     (comparing it with itself could not fail). 4 STATUS rows expected. Block 2a asserts exactly
--     one duplicated key per table, so this block cannot pass by returning no rows.
-- -----------------------------------------------------------------------------
SELECT '2b' AS BLOCK, TABLE_NAME, KEY_VALUE, COPY_NO, N_COPIES, _SOURCE_ROW_NUMBER AS SOURCE_ROW,
       _SOURCE_ROW_NUMBER + 1 AS FILE_LINE, ROW_HASH,
       IFF(COPY_NO = 1, NULL,
           IFF(ROW_HASH = FIRST_VALUE(ROW_HASH) OVER (PARTITION BY TABLE_NAME, KEY_VALUE ORDER BY _SOURCE_ROW_NUMBER),
               'PASS', 'FAIL')) AS STATUS
FROM (
            SELECT * FROM (
              SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER,
                     HASH(CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET) AS ROW_HASH,
                     COUNT(*) OVER (PARTITION BY CAMPAIGN_ID) AS N_COPIES,
                     ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) AS COPY_NO
              FROM RAW.CHALLENGE_CAMPAIGNS
              QUALIFY COUNT(*) OVER (PARTITION BY CAMPAIGN_ID) > 1)
  UNION ALL SELECT * FROM (
              SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, _SOURCE_ROW_NUMBER,
                     HASH(SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND),
                     COUNT(*) OVER (PARTITION BY SPEND_ID),
                     ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER)
              FROM RAW.CHALLENGE_DAILY_SPEND
              QUALIFY COUNT(*) OVER (PARTITION BY SPEND_ID) > 1)
  UNION ALL SELECT * FROM (
              SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, _SOURCE_ROW_NUMBER,
                     HASH(LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE),
                     COUNT(*) OVER (PARTITION BY LEAD_ID),
                     ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER)
              FROM RAW.CHALLENGE_LEADS
              QUALIFY COUNT(*) OVER (PARTITION BY LEAD_ID) > 1)
  UNION ALL SELECT * FROM (
              SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, _SOURCE_ROW_NUMBER,
                     HASH(CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE),
                     COUNT(*) OVER (PARTITION BY CONVERSION_ID),
                     ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER)
              FROM RAW.CHALLENGE_CONVERSIONS
              QUALIFY COUNT(*) OVER (PARTITION BY CONVERSION_ID) > 1)
)
ORDER BY ORD, KEY_VALUE, COPY_NO;


-- -----------------------------------------------------------------------------
-- 2c. Natural keys after de-duplication (dates read as in block 4d: YYYY-MM-DD or year-first
--     YYYY/M/D, see Conventions).
--     Expect 0 repeats of (campaign_id, spend_date) and of conversions.lead_id (one conversion
--     per lead), and 0 repeated non-blank campaign names.
-- -----------------------------------------------------------------------------
WITH spend AS (
  SELECT CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
conv AS (
  SELECT LEAD_ID FROM RAW.CHALLENGE_CONVERSIONS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
camp AS (
  SELECT INITCAP(NULLIF(TRIM(CAMPAIGN_NAME), '')) AS CAMPAIGN_NAME FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1)
SELECT '2c' AS BLOCK, CHECK_NAME, N_EVALUATED, REPEATED_KEYS, EXPECTED, IFF(REPEATED_KEYS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'daily_spend (campaign_id, spend_date)' AS CHECK_NAME,
                   (SELECT COUNT(*) FROM spend WHERE SPEND_DATE IS NOT NULL) AS N_EVALUATED,
                   (SELECT COUNT(*) FROM (SELECT CAMPAIGN_ID, SPEND_DATE FROM spend WHERE SPEND_DATE IS NOT NULL
                                          GROUP BY CAMPAIGN_ID, SPEND_DATE HAVING COUNT(*) > 1)) AS REPEATED_KEYS,
                   0 AS EXPECTED
  UNION ALL SELECT 2, 'conversions lead_id (1:1)', (SELECT COUNT(*) FROM conv),
                   (SELECT COUNT(*) FROM (SELECT LEAD_ID FROM conv GROUP BY LEAD_ID HAVING COUNT(*) > 1)), 0
  UNION ALL SELECT 3, 'campaigns campaign_name (non-blank)', (SELECT COUNT(CAMPAIGN_NAME) FROM camp),
                   (SELECT COUNT(*) FROM (SELECT CAMPAIGN_NAME FROM camp WHERE CAMPAIGN_NAME IS NOT NULL
                                          GROUP BY CAMPAIGN_NAME HAVING COUNT(*) > 1)), 0
)
ORDER BY ORD;


-- =============================================================================
-- 3. CASING AND WHITESPACE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3a. Per business column (23 rows): leading/trailing spaces (x <> TRIM(x)), double spaces,
--     non-printable characters (outside ASCII space..tilde, e.g. tabs or non-breaking spaces),
--     codes that are not lowercase (x <> LOWER(x)) and names that are not Initcap.
--     Expect exactly 1 cell in each of campaigns.CAMPAIGN_NAME, leads.LEAD_SOURCE and
--     conversions.CONVERSION_TYPE (edge spaces plus wrong casing), 0 everywhere else.
--     daily_spend has no descriptive text column and therefore no such defect.
-- -----------------------------------------------------------------------------
WITH cells AS (   -- every business cell of the four extracts, one row each (INCLUDE NULLS keeps NULLs)
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
                         START_DATE, END_DATE, BUDGET FROM RAW.CHALLENGE_CAMPAIGNS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT SPEND_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND
                  FROM RAW.CHALLENGE_DAILY_SPEND)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL SELECT 'CHALLENGE_LEADS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT LEAD_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE
                  FROM RAW.CHALLENGE_LEADS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CONVERSION_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE
                  FROM RAW.CHALLENGE_CONVERSIONS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
flags AS (
  SELECT TABLE_NAME, COLUMN_NAME,
         V <> TRIM(V) AS EDGE_SPACES,
         CONTAINS(V, '  ') AS DOUBLE_SPACE,
         REGEXP_COUNT(V, '[^ -~]') > 0 AS NON_PRINTABLE,
         COLUMN_NAME IN ('CHANNEL', 'OBJECTIVE', 'LEAD_SOURCE', 'CONVERSION_TYPE') AND V <> LOWER(V) AS NOT_LOWERCASE,
         COLUMN_NAME = 'CAMPAIGN_NAME' AND TRIM(V) <> '' AND TRIM(V) <> INITCAP(TRIM(V)) AS NOT_INITCAP
  FROM cells),
per_column AS (
  SELECT TABLE_NAME, COLUMN_NAME, COUNT(*) AS N_CELLS,
         COUNT_IF(EDGE_SPACES) AS N_EDGE_SPACES, COUNT_IF(DOUBLE_SPACE) AS N_DOUBLE_SPACES,
         COUNT_IF(NON_PRINTABLE) AS N_NON_PRINTABLE, COUNT_IF(NOT_LOWERCASE) AS N_NOT_LOWERCASE,
         COUNT_IF(NOT_INITCAP) AS N_NOT_INITCAP,
         COUNT_IF(EDGE_SPACES OR DOUBLE_SPACE OR NON_PRINTABLE OR NOT_LOWERCASE OR NOT_INITCAP) AS N_DEFECT_CELLS
  FROM flags GROUP BY TABLE_NAME, COLUMN_NAME)
SELECT '3a' AS BLOCK, TABLE_NAME, COLUMN_NAME, N_CELLS, N_EDGE_SPACES, N_DOUBLE_SPACES, N_NON_PRINTABLE,
       N_NOT_LOWERCASE, N_NOT_INITCAP, N_DEFECT_CELLS, EXPECTED_DEFECT_CELLS,
       IFF(N_DEFECT_CELLS = EXPECTED_DEFECT_CELLS AND N_EDGE_SPACES = EXPECTED_DEFECT_CELLS
           AND N_NOT_LOWERCASE + N_NOT_INITCAP = EXPECTED_DEFECT_CELLS
           AND N_DOUBLE_SPACES = 0 AND N_NON_PRINTABLE = 0, 'PASS', 'FAIL') AS STATUS
FROM (SELECT p.*,
             IFF(TABLE_NAME || '.' || COLUMN_NAME IN ('CHALLENGE_CAMPAIGNS.CAMPAIGN_NAME', 'CHALLENGE_LEADS.LEAD_SOURCE',
                                                      'CHALLENGE_CONVERSIONS.CONVERSION_TYPE'), 1, 0) AS EXPECTED_DEFECT_CELLS,
             DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4) AS ORD
      FROM per_column p)
ORDER BY ORD, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 3b. Distinct raw variants of every descriptive text column, with counts (raw rows, so the
--     duplicate copy is counted). Brackets make spaces visible. Campaign names are reduced to
--     their stem ("<YYYY> <NNN>" replaces only the year and number digits, so leading and
--     trailing spaces stay inside the brackets). No STATUS: expect these 21 rows:
--       channel          [affiliate] 24, [display] 24, [paid_search] 25, [paid_social] 24, [video] 24
--       objective        [acquisition] 35, [awareness] 45, [lead_gen] 41
--       lead_source      [ PAID_SEARCH ] 1, [paid_search] 1374, [paid_social] 626
--       conversion_type  [ TRIAL ] 1, [purchase] 868, [trial] 1132
--       name stem        [] 1, [ DISPLAY <YYYY> <NNN> ] 1, Affiliate 23, Display 23, Paid Search 25,
--                        Paid Social 24, Video 24
-- -----------------------------------------------------------------------------
SELECT '3b' AS BLOCK, COLUMN_REF, RAW_VALUE_BRACKETED, N_ROWS, NORMALIZED_VALUE, IS_CANONICAL
FROM (
            SELECT 1 AS ORD, 'campaigns.channel' AS COLUMN_REF, '[' || CHANNEL || ']' AS RAW_VALUE_BRACKETED,
                   COUNT(*) AS N_ROWS, LOWER(TRIM(CHANNEL)) AS NORMALIZED_VALUE,
                   CHANNEL = LOWER(TRIM(CHANNEL)) AND CHANNEL <> '' AS IS_CANONICAL
            FROM RAW.CHALLENGE_CAMPAIGNS GROUP BY CHANNEL
  UNION ALL SELECT 2, 'campaigns.objective', '[' || OBJECTIVE || ']', COUNT(*), LOWER(TRIM(OBJECTIVE)),
                   OBJECTIVE = LOWER(TRIM(OBJECTIVE)) AND OBJECTIVE <> ''
            FROM RAW.CHALLENGE_CAMPAIGNS GROUP BY OBJECTIVE
  UNION ALL SELECT 3, 'leads.lead_source', '[' || LEAD_SOURCE || ']', COUNT(*), LOWER(TRIM(LEAD_SOURCE)),
                   LEAD_SOURCE = LOWER(TRIM(LEAD_SOURCE)) AND LEAD_SOURCE <> ''
            FROM RAW.CHALLENGE_LEADS GROUP BY LEAD_SOURCE
  UNION ALL SELECT 4, 'conversions.conversion_type', '[' || CONVERSION_TYPE || ']', COUNT(*), LOWER(TRIM(CONVERSION_TYPE)),
                   CONVERSION_TYPE = LOWER(TRIM(CONVERSION_TYPE)) AND CONVERSION_TYPE <> ''
            FROM RAW.CHALLENGE_CONVERSIONS GROUP BY CONVERSION_TYPE
  UNION ALL SELECT 5, 'campaigns.campaign_name stem', '[' || STEM || ']', COUNT(*), NORMALIZED_STEM,
                   STEM = NORMALIZED_STEM AND STEM <> ''
            FROM (SELECT REGEXP_REPLACE(CAMPAIGN_NAME, '[0-9]{4} [0-9]{3}', '<YYYY> <NNN>') AS STEM,
                         REGEXP_REPLACE(INITCAP(TRIM(CAMPAIGN_NAME)), '[0-9]{4} [0-9]{3}', '<YYYY> <NNN>') AS NORMALIZED_STEM
                  FROM RAW.CHALLENGE_CAMPAIGNS)
            GROUP BY STEM, NORMALIZED_STEM
)
ORDER BY ORD, RAW_VALUE_BRACKETED;


-- -----------------------------------------------------------------------------
-- 3c. Accepted values after the obvious rule LOWER(TRIM(code)), on de-duplicated rows.
--     Driven by the 12 expected (column, value, count) rows below, FULL OUTER JOINed to the
--     normalized counts: an expected value that is missing shows N_ROWS 0 and FAILs, a value
--     that is not expected has no EXPECTED_ROWS and FAILs, so the result must be exactly these
--     12 rows. Expect channel 24 each; objective acquisition 35, awareness 44, lead_gen 41;
--     lead_source paid_search 1374, paid_social 626 (only two channels have leads in the
--     extract, 1c); conversion_type purchase 868, trial 1132. IS_ACCEPTED is the documented
--     domain (DATA_DICTIONARY.md), tested separately from the expected list.
-- -----------------------------------------------------------------------------
WITH camp AS (SELECT * FROM RAW.CHALLENGE_CAMPAIGNS
              QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     leads AS (SELECT * FROM RAW.CHALLENGE_LEADS
               QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     conv AS (SELECT * FROM RAW.CHALLENGE_CONVERSIONS
              QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     normalized AS (
                 SELECT 'campaigns.channel' AS COLUMN_REF, LOWER(TRIM(CHANNEL)) AS NORMALIZED_VALUE, COUNT(*) AS N_ROWS
                 FROM camp GROUP BY LOWER(TRIM(CHANNEL))
       UNION ALL SELECT 'campaigns.objective', LOWER(TRIM(OBJECTIVE)), COUNT(*) FROM camp GROUP BY LOWER(TRIM(OBJECTIVE))
       UNION ALL SELECT 'leads.lead_source', LOWER(TRIM(LEAD_SOURCE)), COUNT(*) FROM leads GROUP BY LOWER(TRIM(LEAD_SOURCE))
       UNION ALL SELECT 'conversions.conversion_type', LOWER(TRIM(CONVERSION_TYPE)), COUNT(*) FROM conv GROUP BY LOWER(TRIM(CONVERSION_TYPE))),
     expected AS (
       SELECT * FROM (VALUES
         ('campaigns.channel', 'affiliate', 24), ('campaigns.channel', 'display', 24), ('campaigns.channel', 'paid_search', 24),
         ('campaigns.channel', 'paid_social', 24), ('campaigns.channel', 'video', 24),
         ('campaigns.objective', 'acquisition', 35), ('campaigns.objective', 'awareness', 44), ('campaigns.objective', 'lead_gen', 41),
         ('leads.lead_source', 'paid_search', 1374), ('leads.lead_source', 'paid_social', 626),
         ('conversions.conversion_type', 'purchase', 868), ('conversions.conversion_type', 'trial', 1132))
         AS e (COLUMN_REF, NORMALIZED_VALUE, EXPECTED_ROWS)),
     joined AS (
       SELECT COALESCE(e.COLUMN_REF, n.COLUMN_REF) AS COLUMN_REF, COALESCE(e.NORMALIZED_VALUE, n.NORMALIZED_VALUE) AS NORMALIZED_VALUE,
              COALESCE(n.N_ROWS, 0) AS N_ROWS, e.EXPECTED_ROWS
       FROM expected e
       FULL OUTER JOIN normalized n ON n.COLUMN_REF = e.COLUMN_REF AND n.NORMALIZED_VALUE = e.NORMALIZED_VALUE)
SELECT '3c' AS BLOCK, COLUMN_REF, NORMALIZED_VALUE, N_ROWS, IS_ACCEPTED, EXPECTED_ROWS,
       IFF(IS_ACCEPTED AND N_ROWS = EXPECTED_ROWS, 'PASS', 'FAIL') AS STATUS
FROM (SELECT j.*,
             CASE COLUMN_REF
               WHEN 'campaigns.objective'         THEN NORMALIZED_VALUE IN ('awareness', 'lead_gen', 'acquisition')
               WHEN 'conversions.conversion_type' THEN NORMALIZED_VALUE IN ('trial', 'purchase')
               ELSE NORMALIZED_VALUE IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video') END AS IS_ACCEPTED,
             DECODE(COLUMN_REF, 'campaigns.channel', 1, 'campaigns.objective', 2, 'leads.lead_source', 3, 4) AS ORD
      FROM joined j)
ORDER BY ORD, NORMALIZED_VALUE;


-- -----------------------------------------------------------------------------
-- 3d. The casing/whitespace cells themselves, with the value the obvious rule gives
--     (INITCAP(TRIM()) for the name, LOWER(TRIM()) for codes; INITCAP is never applied to
--     codes because it treats '_' as a word break: paid_search -> Paid_Search).
--     Expect 3 rows, all in data row 8 (file line 9): CMP0008 [ DISPLAY 2023 008 ] ->
--     Display 2023 008, L00000008 [ PAID_SEARCH ] -> paid_search, CV0000008 [ TRIAL ] -> trial.
--     STATUS: the normalized value conforms to the intended type of block 1f.
-- -----------------------------------------------------------------------------
WITH text_cells AS (
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CAMPAIGN_NAME, CHANNEL, OBJECTIVE FROM RAW.CHALLENGE_CAMPAIGNS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CAMPAIGN_NAME, CHANNEL, OBJECTIVE))
  UNION ALL SELECT 'CHALLENGE_LEADS', LEAD_ID, _SOURCE_ROW_NUMBER, 'LEAD_SOURCE', LEAD_SOURCE FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', CONVERSION_ID, _SOURCE_ROW_NUMBER, 'CONVERSION_TYPE', CONVERSION_TYPE
            FROM RAW.CHALLENGE_CONVERSIONS),
found AS (
  SELECT TABLE_NAME, KEY_VALUE, COLUMN_NAME, V, _SOURCE_ROW_NUMBER,
         IFF(COLUMN_NAME = 'CAMPAIGN_NAME', INITCAP(TRIM(V)), LOWER(TRIM(V))) AS NORMALIZED_VALUE
  FROM text_cells
  WHERE V <> TRIM(V) OR CONTAINS(V, '  ') OR REGEXP_COUNT(V, '[^ -~]') > 0
     OR (COLUMN_NAME <> 'CAMPAIGN_NAME' AND V <> LOWER(V))
     OR (COLUMN_NAME = 'CAMPAIGN_NAME' AND TRIM(V) <> '' AND TRIM(V) <> INITCAP(TRIM(V))))
SELECT '3d' AS BLOCK, TABLE_NAME, KEY_VALUE, COLUMN_NAME, '[' || V || ']' AS RAW_VALUE_BRACKETED, NORMALIZED_VALUE,
       _SOURCE_ROW_NUMBER AS SOURCE_ROW, _SOURCE_ROW_NUMBER + 1 AS FILE_LINE,
       IFF(CASE COLUMN_NAME
             WHEN 'CAMPAIGN_NAME'   THEN REGEXP_LIKE(NORMALIZED_VALUE, '[A-Z][a-z]+( [A-Z][a-z]+)? [0-9]{4} [0-9]{3}')
             WHEN 'OBJECTIVE'       THEN NORMALIZED_VALUE IN ('awareness', 'lead_gen', 'acquisition')
             WHEN 'CONVERSION_TYPE' THEN NORMALIZED_VALUE IN ('trial', 'purchase')
             ELSE NORMALIZED_VALUE IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video') END,
           'PASS', 'FAIL') AS STATUS
FROM found
ORDER BY DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4), KEY_VALUE, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 3e. Why it matters: the Phase 2 plan's starter query (leads and average lead score per
--     lead_source) on the dirty extract as loaded, and after TRIM/LOWER plus de-duplication.
--     Raw: 3 groups, [ PAID_SEARCH ] 1 lead (score 73.00), [paid_search] 1,374 (49.68),
--     [paid_social] 626 (48.31). Cleaned: paid_search 1,374 (49.72), paid_social 626 (48.31).
--     The raw paid_search count looks right only by coincidence: it includes the duplicate
--     of L00000001 and misses L00000008, so its average is wrong.
-- -----------------------------------------------------------------------------
SELECT '3e' AS BLOCK, VERSION, LEAD_SOURCE, TOTAL_LEADS, AVG_LEAD_SCORE, EXPECTED_LEADS, EXPECTED_AVG,
       IFF(TOTAL_LEADS = EXPECTED_LEADS AND AVG_LEAD_SCORE = EXPECTED_AVG, 'PASS', 'FAIL') AS STATUS
FROM (
  SELECT VERSION, LEAD_SOURCE, TOTAL_LEADS, AVG_LEAD_SCORE,
         DECODE(VERSION || ':' || LEAD_SOURCE, 'raw:[ PAID_SEARCH ]', 1, 'raw:[paid_search]', 1374, 'raw:[paid_social]', 626,
                'cleaned:paid_search', 1374, 'cleaned:paid_social', 626, -1) AS EXPECTED_LEADS,
         DECODE(VERSION || ':' || LEAD_SOURCE, 'raw:[ PAID_SEARCH ]', 73.00, 'raw:[paid_search]', 49.68, 'raw:[paid_social]', 48.31,
                'cleaned:paid_search', 49.72, 'cleaned:paid_social', 48.31, -1) AS EXPECTED_AVG
  FROM (
              SELECT 'raw' AS VERSION, '[' || LEAD_SOURCE || ']' AS LEAD_SOURCE, COUNT(*) AS TOTAL_LEADS,
                     ROUND(AVG(TRY_TO_NUMBER(LEAD_SCORE)), 2) AS AVG_LEAD_SCORE
              FROM MARKETING_CRM.RAW.CHALLENGE_LEADS
              GROUP BY LEAD_SOURCE
    UNION ALL SELECT 'cleaned', LOWER(TRIM(LEAD_SOURCE)), COUNT(*), ROUND(AVG(TRY_TO_NUMBER(TRIM(LEAD_SCORE))), 2)
              FROM (SELECT * FROM MARKETING_CRM.RAW.CHALLENGE_LEADS
                    QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1)
              GROUP BY LOWER(TRIM(LEAD_SOURCE))
  )
)
ORDER BY VERSION DESC, LEAD_SOURCE;


-- =============================================================================
-- 4. DATE FORMATS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4a. Shape of every date cell, per date column: iso YYYY-MM-DD (and whether it is a real
--     calendar date), slash year-first YYYY/M/D, slash year-last M/D/YYYY or D/M/YYYY,
--     blank, NULL, other. Expect start_date 120 iso + 1 slash, end_date 121 iso, and
--     spend_date / created_at / converted_at 1,999 iso + 1 slash + 1 blank each. 0 invalid ISO
--     dates, 0 year-last slashes, 0 other shapes, and all ISO dates inside the documented
--     coverage 2023-01-01..2025-12-31.
-- -----------------------------------------------------------------------------
WITH dates AS (
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, 'START_DATE' AS COLUMN_NAME, START_DATE AS V FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 2, 'CHALLENGE_CAMPAIGNS', 'END_DATE', END_DATE FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 3, 'CHALLENGE_DAILY_SPEND', 'SPEND_DATE', SPEND_DATE FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 4, 'CHALLENGE_LEADS', 'CREATED_AT', CREATED_AT FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 5, 'CHALLENGE_CONVERSIONS', 'CONVERTED_AT', CONVERTED_AT FROM RAW.CHALLENGE_CONVERSIONS),
shaped AS (
  SELECT d.*,
         CASE WHEN V IS NULL THEN 'null'
              WHEN TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) = '' THEN 'blank'
              WHEN REGEXP_LIKE(V, '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN 'iso'
              WHEN REGEXP_LIKE(V, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN 'slash_year_first'
              WHEN REGEXP_LIKE(V, '[0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4}') THEN 'slash_year_last'
              ELSE 'other' END AS SHAPE
  FROM dates d),
per_column AS (
  SELECT ORD, TABLE_NAME, COLUMN_NAME, COUNT(*) AS N_CELLS,
         COUNT_IF(SHAPE = 'iso') AS N_ISO,
         COUNT_IF(SHAPE = 'iso' AND TRY_TO_DATE(V, 'YYYY-MM-DD') IS NULL) AS N_ISO_INVALID,
         COUNT_IF(SHAPE = 'slash_year_first') AS N_SLASH_YEAR_FIRST,
         COUNT_IF(SHAPE = 'slash_year_last') AS N_SLASH_YEAR_LAST,
         COUNT_IF(SHAPE = 'blank') AS N_BLANK, COUNT_IF(SHAPE = 'null') AS N_NULL, COUNT_IF(SHAPE = 'other') AS N_OTHER,
         MIN(IFF(SHAPE = 'iso', TRY_TO_DATE(V, 'YYYY-MM-DD'), NULL)) AS MIN_ISO_DATE,
         MAX(IFF(SHAPE = 'iso', TRY_TO_DATE(V, 'YYYY-MM-DD'), NULL)) AS MAX_ISO_DATE
  FROM shaped GROUP BY ORD, TABLE_NAME, COLUMN_NAME)
SELECT '4a' AS BLOCK, TABLE_NAME, COLUMN_NAME, N_CELLS, N_ISO, N_ISO_INVALID, N_SLASH_YEAR_FIRST, N_SLASH_YEAR_LAST,
       N_BLANK, N_NULL, N_OTHER, MIN_ISO_DATE, MAX_ISO_DATE, EXPECTED_ISO, EXPECTED_SLASH, EXPECTED_BLANK,
       IFF(N_ISO = EXPECTED_ISO AND N_SLASH_YEAR_FIRST = EXPECTED_SLASH AND N_BLANK = EXPECTED_BLANK
           AND N_ISO_INVALID = 0 AND N_SLASH_YEAR_LAST = 0 AND N_NULL = 0 AND N_OTHER = 0
           AND MIN_ISO_DATE >= DATE '2023-01-01' AND MAX_ISO_DATE <= DATE '2025-12-31', 'PASS', 'FAIL') AS STATUS
FROM (SELECT p.*,
             DECODE(COLUMN_NAME, 'START_DATE', 120, 'END_DATE', 121, 1999) AS EXPECTED_ISO,
             DECODE(COLUMN_NAME, 'END_DATE', 0, 1) AS EXPECTED_SLASH,
             DECODE(COLUMN_NAME, 'START_DATE', 0, 'END_DATE', 0, 1) AS EXPECTED_BLANK
      FROM per_column p)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4b. Every non-blank, non-ISO date cell (blanks are section 5). Expect 4 rows, all
--     slash_year_first in data row 18 (file line 19): CMP0018 start_date 2023/05/15,
--     DSP0000018 spend_date 2023/07/04, L00000018 created_at 2023/06/17,
--     CV0000018 converted_at 2023/07/05. No STATUS: block 4a checks the counts.
-- -----------------------------------------------------------------------------
WITH dates AS (
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, 'START_DATE' AS COLUMN_NAME,
                   START_DATE AS V, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'END_DATE', END_DATE, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'SPEND_DATE', SPEND_DATE, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'CREATED_AT', CREATED_AT, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERTED_AT', CONVERTED_AT, _SOURCE_ROW_NUMBER FROM RAW.CHALLENGE_CONVERSIONS)
SELECT '4b' AS BLOCK, TABLE_NAME, KEY_VALUE, COLUMN_NAME, '[' || V || ']' AS RAW_VALUE_BRACKETED,
       CASE WHEN REGEXP_LIKE(V, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN 'slash_year_first'
            WHEN REGEXP_LIKE(V, '[0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4}') THEN 'slash_year_last'
            ELSE 'other' END AS SHAPE,
       _SOURCE_ROW_NUMBER AS SOURCE_ROW, _SOURCE_ROW_NUMBER + 1 AS FILE_LINE
FROM dates
WHERE TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) <> '' AND NOT REGEXP_LIKE(V, '[0-9]{4}-[0-9]{2}-[0-9]{2}')
ORDER BY ORD, KEY_VALUE;


-- -----------------------------------------------------------------------------
-- 4c. Invariants inside the challenge files that 4d and 5c use as evidence. Only ISO cells
--     are used (a slash or blank cell never serves as evidence for itself or its neighbours),
--     on de-duplicated rows. "Neighbours" are adjacent keys (LAG/LEAD): within the campaign for
--     spend and leads (I2, I4), and across the whole extract in conversion_id order for
--     conversions (I7, I8), which have no campaign column.
--       I1 start_date = first spend_date of the campaign     22 campaigns with an ISO start
--       I2 next spend_id of a campaign is the next day       1,973 neighbour pairs
--       I3 spend_date inside the campaign window             1,923 rows
--       I4 next lead_id of a campaign is not earlier         1,994 neighbour pairs
--       I5 created_at inside the campaign window             1,998 rows
--       I6 conversion lag (converted_at - lead created_at)   310 pairs, all >= 0, range 0..21
--       I7 next conversion_id is not earlier                 does NOT hold (1,078 of 1,995)
--       I8 next conversion_id has a higher lead_id           1,999 pairs: ids follow leads
--     I7/I8: conversion ids follow lead order, not time, so conversion neighbours do not
--     bound a conversion date (5c).
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID,
         IFF(REGEXP_LIKE(START_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(START_DATE, 'YYYY-MM-DD'), NULL) AS START_ISO,
         IFF(REGEXP_LIKE(END_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(END_DATE, 'YYYY-MM-DD'), NULL) AS END_ISO
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend AS (
  SELECT SPEND_ID, CAMPAIGN_ID,
         IFF(REGEXP_LIKE(SPEND_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend_nb AS (
  SELECT s.*, LEAD(ISO_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_DATE FROM spend s),
leads AS (
  SELECT LEAD_ID, CAMPAIGN_ID,
         IFF(REGEXP_LIKE(CREATED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_LEADS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
leads_nb AS (
  SELECT l.*, LEAD(ISO_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS NEXT_DATE FROM leads l),
conv AS (
  SELECT CONVERSION_ID, LEAD_ID,
         IFF(REGEXP_LIKE(CONVERTED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(CONVERTED_AT, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_CONVERSIONS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
conv_nb AS (
  SELECT c.*, LEAD(ISO_DATE) OVER (ORDER BY CONVERSION_ID) AS NEXT_DATE,
         LEAD(LEAD_ID) OVER (ORDER BY CONVERSION_ID) AS NEXT_LEAD_ID FROM conv c),
lags AS (
  SELECT DATEDIFF(DAY, l.ISO_DATE, c.ISO_DATE) AS LAG_DAYS
  FROM conv c JOIN leads l ON l.LEAD_ID = c.LEAD_ID
  WHERE c.ISO_DATE IS NOT NULL AND l.ISO_DATE IS NOT NULL),
first_spend AS (SELECT CAMPAIGN_ID, MIN(ISO_DATE) AS FIRST_SPEND_DATE FROM spend GROUP BY CAMPAIGN_ID),
checks AS (
            SELECT 'I1' AS ID, 'start_date = first spend_date' AS INVARIANT, COUNT(*) AS N_EVALUATED,
                   COUNT_IF(c.START_ISO = f.FIRST_SPEND_DATE) AS N_HOLDS, NULL::NUMBER AS MIN_VALUE, NULL::NUMBER AS MAX_VALUE,
                   22 AS EXPECTED_EVALUATED, 'holds for all' AS EXPECTATION, NULL::VARCHAR AS EXPECTED_RANGE
            FROM camp c JOIN first_spend f ON f.CAMPAIGN_ID = c.CAMPAIGN_ID
            WHERE c.START_ISO IS NOT NULL AND f.FIRST_SPEND_DATE IS NOT NULL
  UNION ALL SELECT 'I2', 'next spend_id = next day', COUNT(*), COUNT_IF(DATEDIFF(DAY, ISO_DATE, NEXT_DATE) = 1),
                   MIN(DATEDIFF(DAY, ISO_DATE, NEXT_DATE)), MAX(DATEDIFF(DAY, ISO_DATE, NEXT_DATE)), 1973, 'holds for all', '1..1'
            FROM spend_nb WHERE ISO_DATE IS NOT NULL AND NEXT_DATE IS NOT NULL
  UNION ALL SELECT 'I3', 'spend_date inside campaign window', COUNT(*),
                   COUNT_IF(s.ISO_DATE BETWEEN c.START_ISO AND c.END_ISO), NULL, NULL, 1923, 'holds for all', NULL
            FROM spend s JOIN camp c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID
            WHERE s.ISO_DATE IS NOT NULL AND c.START_ISO IS NOT NULL AND c.END_ISO IS NOT NULL
  UNION ALL SELECT 'I4', 'next lead_id: created_at not earlier', COUNT(*), COUNT_IF(NEXT_DATE >= ISO_DATE),
                   MIN(DATEDIFF(DAY, ISO_DATE, NEXT_DATE)), MAX(DATEDIFF(DAY, ISO_DATE, NEXT_DATE)), 1994, 'holds for all', NULL
            FROM leads_nb WHERE ISO_DATE IS NOT NULL AND NEXT_DATE IS NOT NULL
  UNION ALL SELECT 'I5', 'created_at inside campaign window', COUNT(*),
                   COUNT_IF(l.ISO_DATE BETWEEN c.START_ISO AND c.END_ISO), NULL, NULL, 1998, 'holds for all', NULL
            FROM leads l JOIN camp c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
            WHERE l.ISO_DATE IS NOT NULL AND c.START_ISO IS NOT NULL AND c.END_ISO IS NOT NULL
  UNION ALL SELECT 'I6', 'conversion lag days >= 0', COUNT(*), COUNT_IF(LAG_DAYS >= 0),
                   MIN(LAG_DAYS), MAX(LAG_DAYS), 310, 'holds for all', '0..21'
            FROM lags
  UNION ALL SELECT 'I7', 'next conversion_id: date not earlier', COUNT(*), COUNT_IF(NEXT_DATE >= ISO_DATE),
                   NULL, NULL, 1995, 'does not hold', NULL
            FROM conv_nb WHERE ISO_DATE IS NOT NULL AND NEXT_DATE IS NOT NULL
  UNION ALL SELECT 'I8', 'next conversion_id: higher lead_id', COUNT(*), COUNT_IF(NEXT_LEAD_ID > LEAD_ID),
                   NULL, NULL, 1999, 'holds for all', NULL
            FROM conv_nb WHERE NEXT_LEAD_ID IS NOT NULL)
SELECT '4c' AS BLOCK, ID, INVARIANT, N_EVALUATED, N_HOLDS, MIN_VALUE, MAX_VALUE, EXPECTATION, EXPECTED_EVALUATED, EXPECTED_RANGE,
       IFF(N_EVALUATED = EXPECTED_EVALUATED
           AND IFF(EXPECTATION = 'holds for all', N_HOLDS = N_EVALUATED, N_HOLDS < N_EVALUATED)
           AND (EXPECTED_RANGE IS NULL OR MIN_VALUE || '..' || MAX_VALUE = EXPECTED_RANGE), 'PASS', 'FAIL') AS STATUS
FROM checks
ORDER BY ID;


-- -----------------------------------------------------------------------------
-- 4d. Disambiguation of every slash date: Y/M/D versus Y/D/M (a year-first slash date is
--     never M/D or D/M, 4a). A part > 12 settles it syntactically. Otherwise each reading is
--     tested against evidence from the challenge files only (4c):
--       start_date    must equal the campaign's first spend_date (I1), before its end_date
--       spend_date    must sit between its spend_id neighbours, one day after the previous and
--                     one day before the next (I2), inside the campaign window (I3)
--       created_at    must sit between its lead_id neighbours (I4), inside the window (I5)
--       converted_at  must be lead created_at + 0..21 days (I6)
--     LOWER_BOUND..UPPER_BOUND is the range the evidence allows. STATUS: exactly one reading
--     fits and it is Y/M/D. Expect 4 rows: CMP0018 and L00000018 settled by syntax (15 and 17
--     cannot be months) and confirmed by evidence; DSP0000018 and CV0000018 ambiguous by
--     syntax and settled by evidence (Y/D/M would give 2023-04-07, outside CMP0001's window
--     2023-06-17..2023-08-17, and 2023-05-07, 46 days before the lead was created).
--     The two unambiguous cells fix the file's convention as Y/M/D, and both ambiguous cells
--     agree with it.
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID, START_DATE AS START_RAW,
         IFF(REGEXP_LIKE(START_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(START_DATE, 'YYYY-MM-DD'), NULL) AS START_ISO,
         IFF(REGEXP_LIKE(END_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(END_DATE, 'YYYY-MM-DD'), NULL) AS END_ISO
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend AS (
  SELECT SPEND_ID, CAMPAIGN_ID, SPEND_DATE AS RAW_VALUE,
         IFF(REGEXP_LIKE(SPEND_DATE, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(SPEND_DATE, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend_nb AS (
  SELECT s.*,
         LAG(SPEND_ID)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_KEY,
         LAG(ISO_DATE)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_DATE,
         LEAD(SPEND_ID) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_KEY,
         LEAD(ISO_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_DATE
  FROM spend s),
leads AS (
  SELECT LEAD_ID, CAMPAIGN_ID, CREATED_AT AS RAW_VALUE,
         IFF(REGEXP_LIKE(CREATED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(CREATED_AT, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_LEADS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
leads_nb AS (
  SELECT l.*,
         LAG(LEAD_ID)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS PREV_KEY,
         LAG(ISO_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS PREV_DATE,
         LEAD(LEAD_ID) OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS NEXT_KEY,
         LEAD(ISO_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS NEXT_DATE
  FROM leads l),
conv AS (
  SELECT CONVERSION_ID, LEAD_ID, CONVERTED_AT AS RAW_VALUE,
         IFF(REGEXP_LIKE(CONVERTED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}'), TRY_TO_DATE(CONVERTED_AT, 'YYYY-MM-DD'), NULL) AS ISO_DATE
  FROM RAW.CHALLENGE_CONVERSIONS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
lag_range AS (   -- I6
  SELECT MIN(DATEDIFF(DAY, l.ISO_DATE, c.ISO_DATE)) AS MIN_LAG, MAX(DATEDIFF(DAY, l.ISO_DATE, c.ISO_DATE)) AS MAX_LAG
  FROM conv c JOIN leads l ON l.LEAD_ID = c.LEAD_ID
  WHERE c.ISO_DATE IS NOT NULL AND l.ISO_DATE IS NOT NULL),
first_spend AS (SELECT CAMPAIGN_ID, MIN(ISO_DATE) AS FIRST_SPEND_DATE FROM spend GROUP BY CAMPAIGN_ID),
slash_cells AS (   -- end_date has no slash dates (4a), so it needs no rule here
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, c.CAMPAIGN_ID AS KEY_VALUE, 'START_DATE' AS COLUMN_NAME,
                   c.START_RAW AS RAW_VALUE, 'start = first spend_date (I1)' AS EVIDENCE,
                   c.CAMPAIGN_ID || ' spend rows' AS EVIDENCE_ROWS,
                   f.FIRST_SPEND_DATE AS LOWER_BOUND, f.FIRST_SPEND_DATE AS UPPER_BOUND,
                   NULL::DATE AS WINDOW_START, c.END_ISO AS WINDOW_END
            FROM camp c LEFT JOIN first_spend f ON f.CAMPAIGN_ID = c.CAMPAIGN_ID
            WHERE REGEXP_LIKE(c.START_RAW, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}')
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', s.SPEND_ID, 'SPEND_DATE', s.RAW_VALUE, 'spend_id neighbours +-1 day (I2)',
                   s.PREV_KEY || ' / ' || s.NEXT_KEY, DATEADD(DAY, 1, s.PREV_DATE), DATEADD(DAY, -1, s.NEXT_DATE),
                   c.START_ISO, c.END_ISO
            FROM spend_nb s JOIN camp c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID
            WHERE REGEXP_LIKE(s.RAW_VALUE, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}')
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', l.LEAD_ID, 'CREATED_AT', l.RAW_VALUE, 'lead_id neighbours, monotone (I4)',
                   l.PREV_KEY || ' / ' || l.NEXT_KEY, l.PREV_DATE, l.NEXT_DATE, c.START_ISO, c.END_ISO
            FROM leads_nb l JOIN camp c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
            WHERE REGEXP_LIKE(l.RAW_VALUE, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}')
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', v.CONVERSION_ID, 'CONVERTED_AT', v.RAW_VALUE, 'lead created_at + lag range (I6)',
                   'lead ' || v.LEAD_ID, DATEADD(DAY, r.MIN_LAG, l.ISO_DATE), DATEADD(DAY, r.MAX_LAG, l.ISO_DATE),
                   NULL, NULL
            FROM conv v LEFT JOIN leads l ON l.LEAD_ID = v.LEAD_ID CROSS JOIN lag_range r
            WHERE REGEXP_LIKE(v.RAW_VALUE, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}')),
readings AS (
  SELECT s.*,
         TRY_TO_NUMBER(SPLIT_PART(RAW_VALUE, '/', 2)) AS PART2,
         TRY_TO_NUMBER(SPLIT_PART(RAW_VALUE, '/', 3)) AS PART3,
         TRY_TO_DATE(RAW_VALUE, 'YYYY/MM/DD') AS AS_YMD,
         TRY_TO_DATE(RAW_VALUE, 'YYYY/DD/MM') AS AS_YDM
  FROM slash_cells s),
judged AS (
  SELECT r.*,
         CASE WHEN PART2 > 12 AND PART3 > 12 THEN 'not a date either way'
              WHEN PART3 > 12 THEN 'only Y/M/D is a date'
              WHEN PART2 > 12 THEN 'only Y/D/M is a date'
              WHEN PART2 = PART3 THEN 'same date either way'
              ELSE 'ambiguous: both are dates' END AS SYNTAX_VERDICT,
         COALESCE(AS_YMD BETWEEN LOWER_BOUND AND UPPER_BOUND
                  AND AS_YMD BETWEEN COALESCE(WINDOW_START, AS_YMD) AND COALESCE(WINDOW_END, AS_YMD), FALSE) AS YMD_FITS,
         COALESCE(AS_YDM BETWEEN LOWER_BOUND AND UPPER_BOUND
                  AND AS_YDM BETWEEN COALESCE(WINDOW_START, AS_YDM) AND COALESCE(WINDOW_END, AS_YDM), FALSE) AS YDM_FITS
  FROM readings r)
SELECT '4d' AS BLOCK, TABLE_NAME, KEY_VALUE, COLUMN_NAME, RAW_VALUE, PART2, PART3, SYNTAX_VERDICT, AS_YMD, AS_YDM,
       EVIDENCE, EVIDENCE_ROWS, LOWER_BOUND, UPPER_BOUND, WINDOW_START, WINDOW_END, YMD_FITS, YDM_FITS,
       CASE WHEN YMD_FITS AND NOT YDM_FITS THEN AS_YMD WHEN YDM_FITS AND NOT YMD_FITS THEN AS_YDM END AS RESOLVED_DATE,
       IFF(YMD_FITS AND NOT YDM_FITS, 'PASS', 'FAIL') AS STATUS
FROM judged
ORDER BY ORD, KEY_VALUE;


-- =============================================================================
-- 5. BLANK REQUIRED VALUES (every column is required: "Nullable: no" in DATA_DICTIONARY.md)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5a. Per business column (23 rows): exact empty strings, whitespace-only values (spaces, tabs,
--     LF, CR or NBSP only; plain TRIM would see only spaces, see Conventions), NULLs and
--     NULL-like tokens (NULL, NA, N/A, NaN, None, -, ?). Expect 1 empty string in each of
--     campaigns.CAMPAIGN_NAME, daily_spend.SPEND_DATE, leads.CREATED_AT and
--     conversions.CONVERTED_AT (all in data row 30, file line 31), 0 everywhere else, and
--     0 NULLs anywhere (the load keeps '' as '').
-- -----------------------------------------------------------------------------
WITH cells AS (   -- every business cell of the four extracts, one row each (INCLUDE NULLS keeps NULLs)
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
                         START_DATE, END_DATE, BUDGET FROM RAW.CHALLENGE_CAMPAIGNS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT SPEND_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND
                  FROM RAW.CHALLENGE_DAILY_SPEND)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL SELECT 'CHALLENGE_LEADS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT LEAD_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE
                  FROM RAW.CHALLENGE_LEADS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CONVERSION_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE
                  FROM RAW.CHALLENGE_CONVERSIONS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
per_column AS (
  SELECT TABLE_NAME, COLUMN_NAME, COUNT(*) AS N_CELLS,
         COUNT_IF(V = '') AS N_EMPTY,
         COUNT_IF(V <> '' AND TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) = '') AS N_WHITESPACE_ONLY,
         COUNT_IF(V IS NULL) AS N_NULL,
         COUNT_IF(UPPER(TRIM(V)) IN ('NULL', 'NA', 'N/A', 'NAN', 'NONE', '-', '?')) AS N_NULL_TOKEN,
         LISTAGG(IFF(V = '', KEY_VALUE || ' (row ' || _SOURCE_ROW_NUMBER || ')', NULL), ', ')
           WITHIN GROUP (ORDER BY KEY_VALUE) AS EMPTY_CELLS
  FROM cells GROUP BY TABLE_NAME, COLUMN_NAME)
SELECT '5a' AS BLOCK, TABLE_NAME, COLUMN_NAME, N_CELLS, N_EMPTY, N_WHITESPACE_ONLY, N_NULL, N_NULL_TOKEN, EMPTY_CELLS,
       EXPECTED_EMPTY,
       IFF(N_EMPTY = EXPECTED_EMPTY AND N_WHITESPACE_ONLY = 0 AND N_NULL = 0 AND N_NULL_TOKEN = 0, 'PASS', 'FAIL') AS STATUS
FROM (SELECT p.*,
             IFF(TABLE_NAME || '.' || COLUMN_NAME IN ('CHALLENGE_CAMPAIGNS.CAMPAIGN_NAME', 'CHALLENGE_DAILY_SPEND.SPEND_DATE',
                                                      'CHALLENGE_LEADS.CREATED_AT', 'CHALLENGE_CONVERSIONS.CONVERTED_AT'), 1, 0) AS EXPECTED_EMPTY,
             DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4) AS ORD
      FROM per_column p)
ORDER BY ORD, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 5b. The campaign naming rule, proved on the challenge rows that have a name:
--       campaign_name = INITCAP(REPLACE(channel, '_', ' ')) || ' ' || YEAR(start_date) || ' ' || RIGHT(campaign_id, 3)
--     (start_date read as in 4d). Expect 120 campaigns, 119 named: 118 equal the rule as
--     written and all 119 after INITCAP(TRIM()) (CMP0008 is the casing cell of 3d). So the
--     one blank name, CMP0030, can be derived (5c).
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID, CAMPAIGN_NAME, LOWER(TRIM(CHANNEL)) AS CHANNEL,
         CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
ruled AS (
  SELECT c.*, INITCAP(REPLACE(CHANNEL, '_', ' ')) || ' ' || YEAR(START_DATE) || ' ' || RIGHT(CAMPAIGN_ID, 3) AS RULE_NAME
  FROM camp c),
counts AS (
  SELECT COUNT(*) AS N_CAMPAIGNS,
         COUNT_IF(NULLIF(TRIM(CAMPAIGN_NAME), '') IS NOT NULL) AS N_NAMED,
         COUNT_IF(CAMPAIGN_NAME = RULE_NAME) AS N_RAW_EQUALS_RULE,
         COUNT_IF(INITCAP(TRIM(CAMPAIGN_NAME)) = RULE_NAME) AS N_NORMALIZED_EQUALS_RULE,
         LISTAGG(IFF(NULLIF(TRIM(CAMPAIGN_NAME), '') IS NOT NULL AND INITCAP(TRIM(CAMPAIGN_NAME)) <> RULE_NAME, CAMPAIGN_ID, NULL), ', ')
           AS NAMED_BUT_RULE_FAILS,
         LISTAGG(IFF(NULLIF(TRIM(CAMPAIGN_NAME), '') IS NULL, CAMPAIGN_ID || ' -> ' || RULE_NAME, NULL), ', ') AS BLANK_NAME_DERIVED
  FROM ruled)
SELECT '5b' AS BLOCK, 'name = channel + year(start) + id[-3:]' AS RULE, N_CAMPAIGNS, N_NAMED, N_RAW_EQUALS_RULE,
       N_NORMALIZED_EQUALS_RULE, NAMED_BUT_RULE_FAILS, BLANK_NAME_DERIVED, 119 AS EXPECTED_NAMED,
       IFF(N_CAMPAIGNS = 120 AND N_NAMED = 119 AND N_NORMALIZED_EQUALS_RULE = N_NAMED AND N_RAW_EQUALS_RULE = 118,
           'PASS', 'FAIL') AS STATUS
FROM counts;


-- -----------------------------------------------------------------------------
-- 5c. Can each blank be recovered from evidence inside the files? (De-duplicated rows, dates
--     read as in 4d.) N_CANDIDATES is the number of values the evidence allows:
--       CMP0030 campaign_name  naming rule, recomputed here on the de-duplicated rows: 1 only if
--                              it reproduces every non-blank name (119/119, as in 5b), else 0
--                                                                      -> 1: Affiliate 2024 030
--       DSP0000030 spend_date  spend_id neighbours 2023-07-15 and 2023-07-17. I2 (consecutive
--                              spend_ids are exactly one day apart) allows a fill only when
--                              previous + 1 = next - 1, i.e. the neighbours are 2 days apart:
--                              then 1 candidate, otherwise 0 (any other gap contradicts I2);
--                              5d confirms with the campaign's date spine -> 1: 2023-07-16
--       L00000030 created_at   lead_id neighbours 2023-06-17 and 2023-06-18, dates only never
--                              decrease (I4)                           -> 2: NOT recoverable
--       CV0000030 converted_at lead L00000199 created 2023-06-26 + lag 0..21 days (I6); conversion
--                              neighbours do not help (I7)             -> 22: NOT recoverable
--     STATUS: N_CANDIDATES equals the expected count (1 / 1 / 2 / 22). Phase 3 keeps the strict
--     column NULL with a missing-value flag and puts only the two unique fills in *_filled columns.
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID, CAMPAIGN_NAME, LOWER(TRIM(CHANNEL)) AS CHANNEL, _SOURCE_ROW_NUMBER,
         CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend AS (
  SELECT SPEND_ID, CAMPAIGN_ID, _SOURCE_ROW_NUMBER,
         CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend_nb AS (
  SELECT s.*,
         LAG(SPEND_ID)    OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_KEY,
         LAG(SPEND_DATE)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_DATE,
         LEAD(SPEND_ID)   OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_KEY,
         LEAD(SPEND_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_DATE
  FROM spend s),
leads AS (
  SELECT LEAD_ID, CAMPAIGN_ID, _SOURCE_ROW_NUMBER,
         CASE WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY/MM/DD') END AS CREATED_AT
  FROM RAW.CHALLENGE_LEADS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
leads_nb AS (
  SELECT l.*,
         LAG(LEAD_ID)     OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS PREV_KEY,
         LAG(CREATED_AT)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS PREV_DATE,
         LEAD(LEAD_ID)    OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS NEXT_KEY,
         LEAD(CREATED_AT) OVER (PARTITION BY CAMPAIGN_ID ORDER BY LEAD_ID) AS NEXT_DATE
  FROM leads l),
conv AS (
  SELECT CONVERSION_ID, LEAD_ID, _SOURCE_ROW_NUMBER,
         CASE WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY/MM/DD') END AS CONVERTED_AT
  FROM RAW.CHALLENGE_CONVERSIONS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
name_rule AS (   -- 5b on the same rows: how many non-blank names the naming rule reproduces after INITCAP(TRIM())
  SELECT COUNT_IF(NULLIF(TRIM(CAMPAIGN_NAME), '') IS NOT NULL) AS N_NAMED,
         COUNT_IF(NULLIF(TRIM(CAMPAIGN_NAME), '') IS NOT NULL
                  AND INITCAP(TRIM(CAMPAIGN_NAME)) = INITCAP(REPLACE(CHANNEL, '_', ' ')) || ' ' || YEAR(START_DATE) || ' '
                                                     || RIGHT(CAMPAIGN_ID, 3)) AS N_RULE_HOLDS
  FROM camp),
lag_range AS (   -- I6, recomputed on pairs whose two dates are ISO (duplicates cannot move a MIN or MAX)
  SELECT MIN(DATEDIFF(DAY, TRY_TO_DATE(y.CREATED_AT, 'YYYY-MM-DD'), TRY_TO_DATE(x.CONVERTED_AT, 'YYYY-MM-DD'))) AS MIN_LAG,
         MAX(DATEDIFF(DAY, TRY_TO_DATE(y.CREATED_AT, 'YYYY-MM-DD'), TRY_TO_DATE(x.CONVERTED_AT, 'YYYY-MM-DD'))) AS MAX_LAG
  FROM RAW.CHALLENGE_CONVERSIONS x JOIN RAW.CHALLENGE_LEADS y ON y.LEAD_ID = x.LEAD_ID
  WHERE REGEXP_LIKE(x.CONVERTED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}') AND REGEXP_LIKE(y.CREATED_AT, '[0-9]{4}-[0-9]{2}-[0-9]{2}')),
blank_cells AS (
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, c.CAMPAIGN_ID AS KEY_VALUE, 'CAMPAIGN_NAME' AS COLUMN_NAME,
                   c._SOURCE_ROW_NUMBER AS SOURCE_ROW, 'naming rule (5b)' AS EVIDENCE,
                   'rule holds for ' || r.N_RULE_HOLDS || '/' || r.N_NAMED || ' named' AS EVIDENCE_ROWS,
                   INITCAP(REPLACE(c.CHANNEL, '_', ' ')) || ' ' || YEAR(c.START_DATE) || ' ' || RIGHT(c.CAMPAIGN_ID, 3) AS CANDIDATE_FROM,
                   INITCAP(REPLACE(c.CHANNEL, '_', ' ')) || ' ' || YEAR(c.START_DATE) || ' ' || RIGHT(c.CAMPAIGN_ID, 3) AS CANDIDATE_TO,
                   IFF(r.N_NAMED > 0 AND r.N_RULE_HOLDS = r.N_NAMED AND c.CHANNEL IS NOT NULL AND c.START_DATE IS NOT NULL,
                       1, 0) AS N_CANDIDATES
            FROM camp c CROSS JOIN name_rule r WHERE NULLIF(TRIM(c.CAMPAIGN_NAME), '') IS NULL
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'SPEND_DATE', _SOURCE_ROW_NUMBER, 'spend_id neighbours +-1 day (I2)',
                   PREV_KEY || ' / ' || NEXT_KEY,
                   TO_VARCHAR(DATEADD(DAY, 1, PREV_DATE), 'YYYY-MM-DD'), TO_VARCHAR(DATEADD(DAY, -1, NEXT_DATE), 'YYYY-MM-DD'),
                   IFF(DATEDIFF(DAY, PREV_DATE, NEXT_DATE) = 2, 1, 0)   -- the I2 rule; same as SPEND_DATE_FILLED in 8a
            FROM spend_nb WHERE SPEND_DATE IS NULL
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'CREATED_AT', _SOURCE_ROW_NUMBER, 'lead_id neighbours, monotone (I4)',
                   PREV_KEY || ' / ' || NEXT_KEY,
                   TO_VARCHAR(PREV_DATE, 'YYYY-MM-DD'), TO_VARCHAR(NEXT_DATE, 'YYYY-MM-DD'),
                   DATEDIFF(DAY, PREV_DATE, NEXT_DATE) + 1
            FROM leads_nb WHERE CREATED_AT IS NULL
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', v.CONVERSION_ID, 'CONVERTED_AT', v._SOURCE_ROW_NUMBER,
                   'lead created_at + lag range (I6)', 'lead ' || v.LEAD_ID || ' ' || TO_VARCHAR(l.CREATED_AT, 'YYYY-MM-DD'),
                   TO_VARCHAR(DATEADD(DAY, r.MIN_LAG, l.CREATED_AT), 'YYYY-MM-DD'),
                   TO_VARCHAR(DATEADD(DAY, r.MAX_LAG, l.CREATED_AT), 'YYYY-MM-DD'),
                   r.MAX_LAG - r.MIN_LAG + 1
            FROM conv v LEFT JOIN leads l ON l.LEAD_ID = v.LEAD_ID CROSS JOIN lag_range r
            WHERE v.CONVERTED_AT IS NULL)
SELECT '5c' AS BLOCK, TABLE_NAME, KEY_VALUE, COLUMN_NAME, SOURCE_ROW, EVIDENCE, EVIDENCE_ROWS, CANDIDATE_FROM, CANDIDATE_TO,
       N_CANDIDATES, IFF(N_CANDIDATES = 1, 'yes, unique', 'no') AS RECOVERABLE,
       IFF(N_CANDIDATES = 1, CANDIDATE_FROM, NULL) AS PROPOSED_FILL, EXPECTED_CANDIDATES,
       IFF(N_CANDIDATES = EXPECTED_CANDIDATES, 'PASS', 'FAIL') AS STATUS
FROM (SELECT b.*, DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 1, 'CHALLENGE_LEADS', 2, 22) AS EXPECTED_CANDIDATES
      FROM blank_cells b)
ORDER BY ORD, KEY_VALUE;


-- -----------------------------------------------------------------------------
-- 5d. Second, order-free proof for the blank spend_date: the date spine of each campaign
--     that has one. Expect CMP0001 (2023-06-17..2023-08-17): 62 window days, 62 spend rows,
--     61 dated rows on 61 different days, and exactly one window day without a row,
--     2023-07-16. Every spend row lies inside its window (I3) and no campaign day repeats (2c),
--     so the undated row can only be that day.
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE,
         CASE WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY/MM/DD') END AS END_DATE
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend AS (
  SELECT SPEND_ID, CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
gap_campaigns AS (SELECT DISTINCT CAMPAIGN_ID FROM spend WHERE SPEND_DATE IS NULL),
day_offsets AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS N FROM TABLE(GENERATOR(ROWCOUNT => 1000))),
spine AS (
  SELECT c.CAMPAIGN_ID, DATEADD(DAY, o.N, c.START_DATE) AS D
  FROM camp c JOIN gap_campaigns g ON g.CAMPAIGN_ID = c.CAMPAIGN_ID
  JOIN day_offsets o ON o.N <= DATEDIFF(DAY, c.START_DATE, c.END_DATE)),
stats AS (
  SELECT CAMPAIGN_ID, COUNT(*) AS SPEND_ROWS, COUNT(SPEND_DATE) AS DATED_ROWS, COUNT(DISTINCT SPEND_DATE) AS DISTINCT_DATES
  FROM spend GROUP BY CAMPAIGN_ID),
missing AS (
  SELECT sp.CAMPAIGN_ID, COUNT(*) AS N_DAYS_WITHOUT_ROW,
         LISTAGG(TO_VARCHAR(sp.D, 'YYYY-MM-DD'), ', ') WITHIN GROUP (ORDER BY sp.D) AS DAYS_WITHOUT_ROW
  FROM spine sp LEFT JOIN spend s ON s.CAMPAIGN_ID = sp.CAMPAIGN_ID AND s.SPEND_DATE = sp.D
  WHERE s.SPEND_ID IS NULL GROUP BY sp.CAMPAIGN_ID)
SELECT '5d' AS BLOCK, CAMPAIGN_ID, START_DATE, END_DATE, WINDOW_DAYS, SPEND_ROWS, DATED_ROWS, DISTINCT_DATES,
       N_DAYS_WITHOUT_ROW, DAYS_WITHOUT_ROW,
       IFF(WINDOW_DAYS = SPEND_ROWS AND DISTINCT_DATES = DATED_ROWS AND N_DAYS_WITHOUT_ROW = SPEND_ROWS - DATED_ROWS
           AND N_DAYS_WITHOUT_ROW = 1, 'PASS', 'FAIL') AS STATUS
FROM (SELECT c.CAMPAIGN_ID, c.START_DATE, c.END_DATE, DATEDIFF(DAY, c.START_DATE, c.END_DATE) + 1 AS WINDOW_DAYS,
             st.SPEND_ROWS, st.DATED_ROWS, st.DISTINCT_DATES,
             COALESCE(m.N_DAYS_WITHOUT_ROW, 0) AS N_DAYS_WITHOUT_ROW, m.DAYS_WITHOUT_ROW
      FROM camp c
      JOIN gap_campaigns g ON g.CAMPAIGN_ID = c.CAMPAIGN_ID
      JOIN stats st ON st.CAMPAIGN_ID = c.CAMPAIGN_ID
      LEFT JOIN missing m ON m.CAMPAIGN_ID = c.CAMPAIGN_ID)
ORDER BY CAMPAIGN_ID;


-- =============================================================================
-- 6. OTHER RULES ON THE CAST VALUES (no defects expected: KNOWN_ISSUES lists none)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6a. Numeric columns, de-duplicated rows: non-standard text, failed casts, negatives,
--     zeros and range. Expect 0 non-standard, 0 failed, 0 negative, 0 zero except revenue
--     (1,132 zeros = the trials, see 6b), and the ranges budget 8102.32..79884.92,
--     impressions 4417..113847, clicks 47..2390, spend 71.55..1087.81, lead_score 1..100,
--     revenue 0.00..2496.07.
-- -----------------------------------------------------------------------------
WITH camp AS (SELECT * FROM RAW.CHALLENGE_CAMPAIGNS
              QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     spend AS (SELECT * FROM RAW.CHALLENGE_DAILY_SPEND
               QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     leads AS (SELECT * FROM RAW.CHALLENGE_LEADS
               QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     conv AS (SELECT * FROM RAW.CHALLENGE_CONVERSIONS
              QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
     profile AS (
                 SELECT 1 AS ORD, 'campaigns.budget' AS COLUMN_REF, COUNT(*) AS N_VALUES,
                        COUNT_IF(NOT REGEXP_LIKE(BUDGET, '[0-9]+[.][0-9]{2}')) AS N_NONSTANDARD,
                        COUNT_IF(TRY_TO_NUMBER(BUDGET, 12, 2) IS NULL) AS N_CAST_FAILED,
                        COUNT_IF(TRY_TO_NUMBER(BUDGET, 12, 2) < 0) AS N_NEGATIVE,
                        COUNT_IF(TRY_TO_NUMBER(BUDGET, 12, 2) = 0) AS N_ZERO,
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(BUDGET, 12, 2))) AS MIN_VALUE,
                        TO_VARCHAR(MAX(TRY_TO_NUMBER(BUDGET, 12, 2))) AS MAX_VALUE,
                        MIN(TRY_TO_NUMBER(BUDGET, 12, 2)) = 8102.32 AND MAX(TRY_TO_NUMBER(BUDGET, 12, 2)) = 79884.92 AS RANGE_OK,
                        '8102.32..79884.92' AS EXPECTED_RANGE, 0 AS EXPECTED_ZERO
                 FROM camp
       UNION ALL SELECT 2, 'daily_spend.impressions', COUNT(*), COUNT_IF(NOT REGEXP_LIKE(IMPRESSIONS, '[0-9]+')),
                        COUNT_IF(TRY_TO_NUMBER(IMPRESSIONS) IS NULL), COUNT_IF(TRY_TO_NUMBER(IMPRESSIONS) < 0),
                        COUNT_IF(TRY_TO_NUMBER(IMPRESSIONS) = 0),
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(IMPRESSIONS))), TO_VARCHAR(MAX(TRY_TO_NUMBER(IMPRESSIONS))),
                        MIN(TRY_TO_NUMBER(IMPRESSIONS)) = 4417 AND MAX(TRY_TO_NUMBER(IMPRESSIONS)) = 113847, '4417..113847', 0
                 FROM spend
       UNION ALL SELECT 3, 'daily_spend.clicks', COUNT(*), COUNT_IF(NOT REGEXP_LIKE(CLICKS, '[0-9]+')),
                        COUNT_IF(TRY_TO_NUMBER(CLICKS) IS NULL), COUNT_IF(TRY_TO_NUMBER(CLICKS) < 0),
                        COUNT_IF(TRY_TO_NUMBER(CLICKS) = 0),
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(CLICKS))), TO_VARCHAR(MAX(TRY_TO_NUMBER(CLICKS))),
                        MIN(TRY_TO_NUMBER(CLICKS)) = 47 AND MAX(TRY_TO_NUMBER(CLICKS)) = 2390, '47..2390', 0
                 FROM spend
       UNION ALL SELECT 4, 'daily_spend.spend', COUNT(*), COUNT_IF(NOT REGEXP_LIKE(SPEND, '[0-9]+[.][0-9]{2}')),
                        COUNT_IF(TRY_TO_NUMBER(SPEND, 12, 2) IS NULL), COUNT_IF(TRY_TO_NUMBER(SPEND, 12, 2) < 0),
                        COUNT_IF(TRY_TO_NUMBER(SPEND, 12, 2) = 0),
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(SPEND, 12, 2))), TO_VARCHAR(MAX(TRY_TO_NUMBER(SPEND, 12, 2))),
                        MIN(TRY_TO_NUMBER(SPEND, 12, 2)) = 71.55 AND MAX(TRY_TO_NUMBER(SPEND, 12, 2)) = 1087.81, '71.55..1087.81', 0
                 FROM spend
       UNION ALL SELECT 5, 'leads.lead_score', COUNT(*), COUNT_IF(NOT REGEXP_LIKE(LEAD_SCORE, '[0-9]+')),
                        COUNT_IF(TRY_TO_NUMBER(LEAD_SCORE) IS NULL), COUNT_IF(TRY_TO_NUMBER(LEAD_SCORE) < 0),
                        COUNT_IF(TRY_TO_NUMBER(LEAD_SCORE) = 0),
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(LEAD_SCORE))), TO_VARCHAR(MAX(TRY_TO_NUMBER(LEAD_SCORE))),
                        MIN(TRY_TO_NUMBER(LEAD_SCORE)) = 1 AND MAX(TRY_TO_NUMBER(LEAD_SCORE)) = 100, '1..100', 0
                 FROM leads
       UNION ALL SELECT 6, 'conversions.revenue', COUNT(*), COUNT_IF(NOT REGEXP_LIKE(REVENUE, '[0-9]+[.][0-9]{2}')),
                        COUNT_IF(TRY_TO_NUMBER(REVENUE, 12, 2) IS NULL), COUNT_IF(TRY_TO_NUMBER(REVENUE, 12, 2) < 0),
                        COUNT_IF(TRY_TO_NUMBER(REVENUE, 12, 2) = 0),
                        TO_VARCHAR(MIN(TRY_TO_NUMBER(REVENUE, 12, 2))), TO_VARCHAR(MAX(TRY_TO_NUMBER(REVENUE, 12, 2))),
                        MIN(TRY_TO_NUMBER(REVENUE, 12, 2)) = 0 AND MAX(TRY_TO_NUMBER(REVENUE, 12, 2)) = 2496.07, '0.00..2496.07', 1132
                 FROM conv)
SELECT '6a' AS BLOCK, COLUMN_REF, N_VALUES, N_NONSTANDARD, N_CAST_FAILED, N_NEGATIVE, N_ZERO, MIN_VALUE, MAX_VALUE,
       EXPECTED_RANGE, EXPECTED_ZERO,
       IFF(N_NONSTANDARD = 0 AND N_CAST_FAILED = 0 AND N_NEGATIVE = 0 AND N_ZERO = EXPECTED_ZERO AND RANGE_OK,
           'PASS', 'FAIL') AS STATUS
FROM profile
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 6b. Business rules across columns and tables, on de-duplicated, normalized and typed rows
--     (codes LOWER(TRIM()), dates read as in 4d). N_EVALUATED is below the row count where a
--     rule needs a date that is blank (NULL after typing) or a row from another extract:
--       rule 5 can only be checked for the 313 conversions whose lead is in the leads extract
--       (1c), minus CV0000030 whose converted_at is blank: 312. The other 1,687 conversions
--       cannot be evaluated from the challenge files alone (their leads are only in the
--       clean release; Phase 3 tests them there).
--       rules 7 and 8 lose the one blank spend_date / created_at: 1,999 each.
--       rule 9 counts the non-NULL dates: 120 + 120 + 3 x 1,999 = 6,237.
--     Expect 0 violations of every rule. lead_source equals the
--     campaign channel on every lead of the extract (the local profiling found the same for
--     all 261,684 clean leads), so lead_source carries no information of its own.
-- -----------------------------------------------------------------------------
WITH camp AS (
  SELECT CAMPAIGN_ID, LOWER(TRIM(CHANNEL)) AS CHANNEL,
         CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE,
         CASE WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY/MM/DD') END AS END_DATE
  FROM RAW.CHALLENGE_CAMPAIGNS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
spend AS (
  SELECT SPEND_ID, CAMPAIGN_ID, TRY_TO_NUMBER(IMPRESSIONS) AS IMPRESSIONS, TRY_TO_NUMBER(CLICKS) AS CLICKS,
         CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE
  FROM RAW.CHALLENGE_DAILY_SPEND
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
leads AS (
  SELECT LEAD_ID, CAMPAIGN_ID, LOWER(TRIM(LEAD_SOURCE)) AS LEAD_SOURCE, TRY_TO_NUMBER(LEAD_SCORE) AS LEAD_SCORE,
         CASE WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY/MM/DD') END AS CREATED_AT
  FROM RAW.CHALLENGE_LEADS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
conv AS (
  SELECT CONVERSION_ID, LEAD_ID, LOWER(TRIM(CONVERSION_TYPE)) AS CONVERSION_TYPE, TRY_TO_NUMBER(REVENUE, 12, 2) AS REVENUE,
         CASE WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY/MM/DD') END AS CONVERTED_AT
  FROM RAW.CHALLENGE_CONVERSIONS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
all_dates AS (
            SELECT START_DATE AS D FROM camp UNION ALL SELECT END_DATE FROM camp
  UNION ALL SELECT SPEND_DATE FROM spend UNION ALL SELECT CREATED_AT FROM leads UNION ALL SELECT CONVERTED_AT FROM conv)
SELECT '6b' AS BLOCK, RULE_NAME, N_EVALUATED, N_VIOLATIONS, EXPECTED_EVALUATED,
       IFF(N_VIOLATIONS = 0 AND N_EVALUATED = EXPECTED_EVALUATED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'clicks > impressions' AS RULE_NAME, COUNT(*) AS N_EVALUATED,
                   COUNT_IF(CLICKS > IMPRESSIONS) AS N_VIOLATIONS, 2000 AS EXPECTED_EVALUATED FROM spend
  UNION ALL SELECT 2, 'lead_score outside 1..100', COUNT(*), COUNT_IF(LEAD_SCORE NOT BETWEEN 1 AND 100), 2000 FROM leads
  UNION ALL SELECT 3, 'trial with revenue <> 0', COUNT(*), COUNT_IF(REVENUE <> 0), 1132 FROM conv WHERE CONVERSION_TYPE = 'trial'
  UNION ALL SELECT 4, 'purchase with revenue <= 0', COUNT(*), COUNT_IF(REVENUE <= 0), 868 FROM conv WHERE CONVERSION_TYPE = 'purchase'
  UNION ALL SELECT 5, 'conversion before its lead', COUNT(*), COUNT_IF(v.CONVERTED_AT < l.CREATED_AT), 312
            FROM conv v JOIN leads l ON l.LEAD_ID = v.LEAD_ID
            WHERE v.CONVERTED_AT IS NOT NULL AND l.CREATED_AT IS NOT NULL
  UNION ALL SELECT 6, 'campaign end_date before start_date', COUNT(*), COUNT_IF(END_DATE < START_DATE), 120 FROM camp
  UNION ALL SELECT 7, 'spend_date outside campaign window', COUNT(*),
                   COUNT_IF(s.SPEND_DATE NOT BETWEEN c.START_DATE AND c.END_DATE), 1999
            FROM spend s JOIN camp c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID WHERE s.SPEND_DATE IS NOT NULL
  UNION ALL SELECT 8, 'created_at outside campaign window', COUNT(*),
                   COUNT_IF(l.CREATED_AT NOT BETWEEN c.START_DATE AND c.END_DATE), 1999
            FROM leads l JOIN camp c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID WHERE l.CREATED_AT IS NOT NULL
  UNION ALL SELECT 9, 'date outside 2023-01-01..2025-12-31', COUNT(*),
                   COUNT_IF(D NOT BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'), 6237
            FROM all_dates WHERE D IS NOT NULL
  UNION ALL SELECT 10, 'lead_source <> campaign channel', COUNT(*), COUNT_IF(l.LEAD_SOURCE <> c.CHANNEL), 2000
            FROM leads l JOIN camp c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
)
ORDER BY ORD;


-- =============================================================================
-- 7. DEFECT SUMMARY: every defect found by the generic rules above, in one result
-- -----------------------------------------------------------------------------
--    Classification of each cell, first match wins:
--      blank required value     NULL, or empty after removing spaces/tabs/LF/CR/NBSP
--      slash date (year first)  date column shaped YYYY/M/D
--      other date defect        date column that is not a real YYYY-MM-DD date
--      casing/whitespace        edge or double spaces, non-printable characters, a code that
--                               is not lowercase, a name that is not Initcap
--      other nonconforming      fails its intended type of 1f even after TRIM/LOWER/INITCAP
--    plus one 'duplicate row' per surplus copy of an identical row. Rows: 15 'defect' rows,
--    then one 'class total' row per class and a 'grand total', each with STATUS. Expect
--    4 duplicate rows + 3 casing/whitespace + 4 slash dates + 4 blanks = 15, and 0 in the
--    other two classes. In file terms: data rows 8, 18 and 30, and row 1 repeated at the end.
-- =============================================================================
WITH cells AS (   -- every business cell of the four extracts, one row each (INCLUDE NULLS keeps NULLs)
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
                         START_DATE, END_DATE, BUDGET FROM RAW.CHALLENGE_CAMPAIGNS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET))
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT SPEND_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND
                  FROM RAW.CHALLENGE_DAILY_SPEND)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL SELECT 'CHALLENGE_LEADS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT LEAD_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE
                  FROM RAW.CHALLENGE_LEADS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', KEY_VALUE, _SOURCE_ROW_NUMBER, COLUMN_NAME, V
            FROM (SELECT CONVERSION_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER, CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE
                  FROM RAW.CHALLENGE_CONVERSIONS)
                 UNPIVOT INCLUDE NULLS (V FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE))
),
cell_defects AS (
  SELECT TABLE_NAME, KEY_VALUE, COLUMN_NAME, '[' || COALESCE(V, 'NULL') || ']' AS RAW_VALUE, _SOURCE_ROW_NUMBER AS SOURCE_ROW,
         CASE
           WHEN V IS NULL OR TRIM(V, ' ' || CHR(9) || CHR(10) || CHR(13) || CHR(160)) = '' THEN 'blank required value'
           WHEN COLUMN_NAME IN ('START_DATE', 'END_DATE', 'SPEND_DATE', 'CREATED_AT', 'CONVERTED_AT')
                AND REGEXP_LIKE(V, '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN 'slash date (year first)'
           WHEN COLUMN_NAME IN ('START_DATE', 'END_DATE', 'SPEND_DATE', 'CREATED_AT', 'CONVERTED_AT')
                AND NOT (REGEXP_LIKE(V, '[0-9]{4}-[0-9]{2}-[0-9]{2}') AND TRY_TO_DATE(V, 'YYYY-MM-DD') IS NOT NULL) THEN 'other date defect'
           WHEN V <> TRIM(V) OR CONTAINS(V, '  ') OR REGEXP_COUNT(V, '[^ -~]') > 0
                OR (COLUMN_NAME IN ('CHANNEL', 'OBJECTIVE', 'LEAD_SOURCE', 'CONVERSION_TYPE') AND V <> LOWER(V))
                OR (COLUMN_NAME = 'CAMPAIGN_NAME' AND V <> INITCAP(V)) THEN 'casing/whitespace'
           WHEN CASE WHEN COLUMN_NAME = 'CAMPAIGN_ID'   THEN NOT REGEXP_LIKE(V, 'CMP[0-9]{4}')
                     WHEN COLUMN_NAME = 'SPEND_ID'      THEN NOT REGEXP_LIKE(V, 'DSP[0-9]{7}')
                     WHEN COLUMN_NAME = 'LEAD_ID'       THEN NOT REGEXP_LIKE(V, 'L[0-9]{8}')
                     WHEN COLUMN_NAME = 'CONVERSION_ID' THEN NOT REGEXP_LIKE(V, 'CV[0-9]{7}')
                     WHEN COLUMN_NAME = 'CAMPAIGN_NAME'
                          THEN NOT REGEXP_LIKE(INITCAP(TRIM(V)), '[A-Z][a-z]+( [A-Z][a-z]+)? [0-9]{4} [0-9]{3}')
                     WHEN COLUMN_NAME IN ('CHANNEL', 'LEAD_SOURCE')
                          THEN LOWER(TRIM(V)) NOT IN ('affiliate', 'display', 'paid_search', 'paid_social', 'video')
                     WHEN COLUMN_NAME = 'OBJECTIVE' THEN LOWER(TRIM(V)) NOT IN ('awareness', 'lead_gen', 'acquisition')
                     WHEN COLUMN_NAME = 'CONVERSION_TYPE' THEN LOWER(TRIM(V)) NOT IN ('trial', 'purchase')
                     WHEN COLUMN_NAME IN ('IMPRESSIONS', 'CLICKS', 'LEAD_SCORE') THEN NOT REGEXP_LIKE(V, '[0-9]+')
                     WHEN COLUMN_NAME IN ('BUDGET', 'SPEND', 'REVENUE') THEN NOT REGEXP_LIKE(V, '[0-9]+[.][0-9]{2}')
                     ELSE FALSE END THEN 'other nonconforming'
         END AS DEFECT_CLASS
  FROM cells),
row_copies AS (   -- first source row of each group of identical rows
            SELECT 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, _SOURCE_ROW_NUMBER,
                   MIN(_SOURCE_ROW_NUMBER) OVER (PARTITION BY CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET) AS FIRST_ROW
            FROM RAW.CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'CHALLENGE_DAILY_SPEND', SPEND_ID, _SOURCE_ROW_NUMBER,
                   MIN(_SOURCE_ROW_NUMBER) OVER (PARTITION BY SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND)
            FROM RAW.CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'CHALLENGE_LEADS', LEAD_ID, _SOURCE_ROW_NUMBER,
                   MIN(_SOURCE_ROW_NUMBER) OVER (PARTITION BY LEAD_ID, CAMPAIGN_ID, CREATED_AT, LEAD_SOURCE, LEAD_SCORE)
            FROM RAW.CHALLENGE_LEADS
  UNION ALL SELECT 'CHALLENGE_CONVERSIONS', CONVERSION_ID, _SOURCE_ROW_NUMBER,
                   MIN(_SOURCE_ROW_NUMBER) OVER (PARTITION BY CONVERSION_ID, LEAD_ID, CONVERTED_AT, CONVERSION_TYPE, REVENUE)
            FROM RAW.CHALLENGE_CONVERSIONS),
defects AS (
            SELECT TABLE_NAME, KEY_VALUE, '(whole row)' AS COLUMN_NAME, 'identical to row ' || FIRST_ROW AS RAW_VALUE,
                   _SOURCE_ROW_NUMBER AS SOURCE_ROW, 'duplicate row' AS DEFECT_CLASS
            FROM row_copies WHERE _SOURCE_ROW_NUMBER > FIRST_ROW
  UNION ALL SELECT TABLE_NAME, KEY_VALUE, COLUMN_NAME, RAW_VALUE, SOURCE_ROW, DEFECT_CLASS
            FROM cell_defects WHERE DEFECT_CLASS IS NOT NULL),
numbered AS (
  SELECT d.*,
         DECODE(DEFECT_CLASS, 'duplicate row', 1, 'casing/whitespace', 2, 'slash date (year first)', 3,
                'blank required value', 4, 5) AS CLASS_ORD,
         ROW_NUMBER() OVER (ORDER BY DECODE(DEFECT_CLASS, 'duplicate row', 1, 'casing/whitespace', 2, 'slash date (year first)', 3,
                                            'blank required value', 4, 5),
                                     DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 1, 'CHALLENGE_DAILY_SPEND', 2, 'CHALLENGE_LEADS', 3, 4),
                                     KEY_VALUE, COLUMN_NAME) AS DEFECT_NO
  FROM defects d),
expected AS (
  SELECT * FROM (VALUES ('duplicate row', 4, 1), ('casing/whitespace', 3, 2), ('slash date (year first)', 4, 3),
                        ('blank required value', 4, 4), ('other date defect', 0, 5), ('other nonconforming', 0, 6))
         AS e (DEFECT_CLASS, EXPECTED, CLASS_ORD)),
class_totals AS (
  SELECT COALESCE(e.DEFECT_CLASS, a.DEFECT_CLASS) AS DEFECT_CLASS, COALESCE(a.N_DEFECTS, 0) AS N_DEFECTS,
         COALESCE(e.EXPECTED, 0) AS EXPECTED, COALESCE(e.CLASS_ORD, 9) AS CLASS_ORD
  FROM expected e
  FULL OUTER JOIN (SELECT DEFECT_CLASS, COUNT(*) AS N_DEFECTS FROM defects GROUP BY DEFECT_CLASS) a
    ON a.DEFECT_CLASS = e.DEFECT_CLASS)
SELECT BLOCK, ROW_TYPE, DEFECT_NO, DEFECT_CLASS, TABLE_NAME, KEY_VALUE, COLUMN_NAME, RAW_VALUE, SOURCE_ROW, FILE_LINE,
       N_DEFECTS, EXPECTED, STATUS
FROM (
            SELECT '7' AS BLOCK, 'defect' AS ROW_TYPE, 1 AS TYPE_ORD, DEFECT_NO, CLASS_ORD, DEFECT_CLASS, TABLE_NAME, KEY_VALUE,
                   COLUMN_NAME, RAW_VALUE, SOURCE_ROW, SOURCE_ROW + 1 AS FILE_LINE,
                   NULL::NUMBER AS N_DEFECTS, NULL::NUMBER AS EXPECTED, NULL::VARCHAR AS STATUS
            FROM numbered
  UNION ALL SELECT '7', 'class total', 2, NULL, CLASS_ORD, DEFECT_CLASS, NULL, NULL, NULL, NULL, NULL, NULL,
                   N_DEFECTS, EXPECTED, IFF(N_DEFECTS = EXPECTED, 'PASS', 'FAIL')
            FROM class_totals
  UNION ALL SELECT '7', 'grand total', 3, NULL, 99, 'all classes', NULL, NULL, NULL, NULL, NULL, NULL,
                   (SELECT COUNT(*) FROM defects), 15, IFF((SELECT COUNT(*) FROM defects) = 15, 'PASS', 'FAIL')
)
ORDER BY TYPE_ORD, DEFECT_NO, CLASS_ORD;


-- =============================================================================
-- 8. PREVIEW OF THE PHASE 3 RECONCILIATION (read-only)
-- -----------------------------------------------------------------------------
--    PREVIEW ONLY. The dbt models STAGING.STG_CHALLENGE_* implement these rules (macros in
--    dbt/macros/staging/clean_*.sql), and dbt/tests/challenge/assert_challenge_reconciliation.sql
--    tests this reconciliation; here the rules run inline, so it can be seen without any model.
--    Rules applied to the challenge extracts (only those found above):
--      ids        UPPER(TRIM())          codes   LOWER(NULLIF(TRIM(), ''))
--      name       INITCAP(NULLIF(TRIM(), '')), never on codes (3d)
--      dates      routed by shape: YYYY-MM-DD, else year-first YYYY/M/D read as Y/M/D (4d);
--                 blank -> NULL
--      numbers    TRY_TO_NUMBER(TRIM()), decimals with (12, 2)
--      duplicates QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY _SOURCE_ROW_NUMBER) = 1
--      fills      only the two unique ones of 5c, in separate *_FILLED columns:
--                 campaign_name by the naming rule (5b), spend_date = previous + 1 day when it
--                 also equals next - 1 day (I2)
--    Comparison: every column, typed, with EQUAL_NULL (NULL = NULL counts as equal), joined to
--    the clean release on the key. Clean-release columns are cast with TO_DATE / TO_NUMBER.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 8a. Rows that reproduce the clean release exactly, per table and in total.
--     Blanks left NULL: 119/120 campaigns and 1,999/2,000 for each of the other three tables,
--     6,116 of 6,120 in total. With the two provable fills: 120 + 2,000 + 1,999 + 1,999 =
--     6,118 of 6,120 (the figure in docs/architecture.md, decision 5). The 2 rows that never
--     match are the 2 unrecoverable blank dates, L00000030 and CV0000030.
-- -----------------------------------------------------------------------------
WITH cln_campaigns AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID, INITCAP(NULLIF(TRIM(CAMPAIGN_NAME), '')) AS CAMPAIGN_NAME,
           LOWER(NULLIF(TRIM(CHANNEL), '')) AS CHANNEL, LOWER(NULLIF(TRIM(OBJECTIVE), '')) AS OBJECTIVE,
           CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE,
           CASE WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY/MM/DD') END AS END_DATE,
           TRY_TO_NUMBER(TRIM(BUDGET), 12, 2) AS BUDGET, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_CAMPAIGNS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_spend AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(SPEND_ID)) AS SPEND_ID, UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID,
           CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE,
           TRY_TO_NUMBER(TRIM(IMPRESSIONS)) AS IMPRESSIONS, TRY_TO_NUMBER(TRIM(CLICKS)) AS CLICKS,
           TRY_TO_NUMBER(TRIM(SPEND), 12, 2) AS SPEND, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_DAILY_SPEND)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_leads AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(LEAD_ID)) AS LEAD_ID, UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID,
           CASE WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY/MM/DD') END AS CREATED_AT,
           LOWER(NULLIF(TRIM(LEAD_SOURCE), '')) AS LEAD_SOURCE, TRY_TO_NUMBER(TRIM(LEAD_SCORE)) AS LEAD_SCORE, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_LEADS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_conversions AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(CONVERSION_ID)) AS CONVERSION_ID, UPPER(TRIM(LEAD_ID)) AS LEAD_ID,
           CASE WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY/MM/DD') END AS CONVERTED_AT,
           LOWER(NULLIF(TRIM(CONVERSION_TYPE), '')) AS CONVERSION_TYPE, TRY_TO_NUMBER(TRIM(REVENUE), 12, 2) AS REVENUE, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_CONVERSIONS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
j_campaigns AS (
  SELECT c.*, COALESCE(c.CAMPAIGN_NAME, INITCAP(REPLACE(c.CHANNEL, '_', ' ')) || ' ' || YEAR(c.START_DATE) || ' '
                                        || RIGHT(c.CAMPAIGN_ID, 3)) AS CAMPAIGN_NAME_FILLED,
         r.CAMPAIGN_ID AS R_CAMPAIGN_ID, r.CAMPAIGN_NAME AS R_CAMPAIGN_NAME, r.CHANNEL AS R_CHANNEL, r.OBJECTIVE AS R_OBJECTIVE,
         TO_DATE(r.START_DATE, 'YYYY-MM-DD') AS R_START_DATE, TO_DATE(r.END_DATE, 'YYYY-MM-DD') AS R_END_DATE,
         TO_NUMBER(r.BUDGET, 12, 2) AS R_BUDGET
  FROM cln_campaigns c LEFT JOIN RAW.CAMPAIGNS r ON r.CAMPAIGN_ID = c.CAMPAIGN_ID),
j_spend AS (
  SELECT c.*, COALESCE(c.SPEND_DATE,
                IFF(DATEADD(DAY, 1, LAG(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID))
                      = DATEADD(DAY, -1, LEAD(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID)),
                    DATEADD(DAY, 1, LAG(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID)), NULL)) AS SPEND_DATE_FILLED,
         r.SPEND_ID AS R_SPEND_ID, r.CAMPAIGN_ID AS R_CAMPAIGN_ID, TO_DATE(r.SPEND_DATE, 'YYYY-MM-DD') AS R_SPEND_DATE,
         TO_NUMBER(r.IMPRESSIONS) AS R_IMPRESSIONS, TO_NUMBER(r.CLICKS) AS R_CLICKS, TO_NUMBER(r.SPEND, 12, 2) AS R_SPEND
  FROM cln_spend c LEFT JOIN RAW.DAILY_SPEND r ON r.SPEND_ID = c.SPEND_ID),
j_leads AS (
  SELECT c.*, r.LEAD_ID AS R_LEAD_ID, r.CAMPAIGN_ID AS R_CAMPAIGN_ID, TO_DATE(r.CREATED_AT, 'YYYY-MM-DD') AS R_CREATED_AT,
         r.LEAD_SOURCE AS R_LEAD_SOURCE, TO_NUMBER(r.LEAD_SCORE) AS R_LEAD_SCORE
  FROM cln_leads c LEFT JOIN RAW.LEADS r ON r.LEAD_ID = c.LEAD_ID),
j_conversions AS (
  SELECT c.*, r.CONVERSION_ID AS R_CONVERSION_ID, r.LEAD_ID AS R_LEAD_ID, TO_DATE(r.CONVERTED_AT, 'YYYY-MM-DD') AS R_CONVERTED_AT,
         r.CONVERSION_TYPE AS R_CONVERSION_TYPE, TO_NUMBER(r.REVENUE, 12, 2) AS R_REVENUE
  FROM cln_conversions c LEFT JOIN RAW.CONVERSIONS r ON r.CONVERSION_ID = c.CONVERSION_ID),
per_key AS (   -- one row per cleaned row: does it match on every column, blanks NULL / with fills?
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE,
                   EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) AND EQUAL_NULL(CHANNEL, R_CHANNEL) AND EQUAL_NULL(OBJECTIVE, R_OBJECTIVE)
                   AND EQUAL_NULL(START_DATE, R_START_DATE) AND EQUAL_NULL(END_DATE, R_END_DATE) AND EQUAL_NULL(BUDGET, R_BUDGET)
                   AS SAME_OTHER_COLUMNS,
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CAMPAIGN_NAME, R_CAMPAIGN_NAME) AS MATCH_BLANKS_NULL,
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CAMPAIGN_NAME_FILLED, R_CAMPAIGN_NAME) AS MATCH_WITH_FILLS
            FROM j_campaigns
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID,
                   EQUAL_NULL(SPEND_ID, R_SPEND_ID) AND EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) AND EQUAL_NULL(IMPRESSIONS, R_IMPRESSIONS)
                   AND EQUAL_NULL(CLICKS, R_CLICKS) AND EQUAL_NULL(SPEND, R_SPEND) AS SAME_OTHER_COLUMNS,
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(SPEND_DATE, R_SPEND_DATE),
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(SPEND_DATE_FILLED, R_SPEND_DATE)
            FROM j_spend
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID,
                   EQUAL_NULL(LEAD_ID, R_LEAD_ID) AND EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) AND EQUAL_NULL(LEAD_SOURCE, R_LEAD_SOURCE)
                   AND EQUAL_NULL(LEAD_SCORE, R_LEAD_SCORE) AS SAME_OTHER_COLUMNS,
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CREATED_AT, R_CREATED_AT),
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CREATED_AT, R_CREATED_AT)
            FROM j_leads
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID,
                   EQUAL_NULL(CONVERSION_ID, R_CONVERSION_ID) AND EQUAL_NULL(LEAD_ID, R_LEAD_ID)
                   AND EQUAL_NULL(CONVERSION_TYPE, R_CONVERSION_TYPE) AND EQUAL_NULL(REVENUE, R_REVENUE) AS SAME_OTHER_COLUMNS,
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CONVERTED_AT, R_CONVERTED_AT),
                   SAME_OTHER_COLUMNS AND EQUAL_NULL(CONVERTED_AT, R_CONVERTED_AT)
            FROM j_conversions),
per_table AS (
  SELECT ORD, TABLE_NAME, COUNT(*) AS N_ROWS, COUNT_IF(MATCH_BLANKS_NULL) AS MATCH_BLANKS_NULL,
         COUNT_IF(MATCH_WITH_FILLS) AS MATCH_WITH_FILLS,
         LISTAGG(IFF(MATCH_BLANKS_NULL, NULL, KEY_VALUE), ', ') WITHIN GROUP (ORDER BY KEY_VALUE) AS NOT_MATCHING_BLANKS_NULL,
         LISTAGG(IFF(MATCH_WITH_FILLS, NULL, KEY_VALUE), ', ') WITHIN GROUP (ORDER BY KEY_VALUE) AS NOT_MATCHING_WITH_FILLS
  FROM per_key GROUP BY ORD, TABLE_NAME),
with_totals AS (
            SELECT ORD, TABLE_NAME, N_ROWS, MATCH_BLANKS_NULL, MATCH_WITH_FILLS, NOT_MATCHING_BLANKS_NULL, NOT_MATCHING_WITH_FILLS,
                   DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 120, 2000) AS EXPECTED_ROWS,
                   DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 119, 1999) AS EXPECTED_BLANKS_NULL,
                   DECODE(TABLE_NAME, 'CHALLENGE_CAMPAIGNS', 120, 'CHALLENGE_DAILY_SPEND', 2000, 1999) AS EXPECTED_WITH_FILLS
            FROM per_table
  UNION ALL SELECT 5, 'TOTAL', SUM(N_ROWS), SUM(MATCH_BLANKS_NULL), SUM(MATCH_WITH_FILLS), NULL, NULL, 6120, 6116, 6118
            FROM per_table)
SELECT '8a' AS BLOCK, TABLE_NAME, N_ROWS, MATCH_BLANKS_NULL, EXPECTED_BLANKS_NULL, NOT_MATCHING_BLANKS_NULL,
       MATCH_WITH_FILLS, EXPECTED_WITH_FILLS, NOT_MATCHING_WITH_FILLS,
       IFF(N_ROWS = EXPECTED_ROWS AND MATCH_BLANKS_NULL = EXPECTED_BLANKS_NULL AND MATCH_WITH_FILLS = EXPECTED_WITH_FILLS,
           'PASS', 'FAIL') AS STATUS
FROM with_totals
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 8b. The mismatching cells themselves, one row per (key, column): the cleaned value with
--     blanks NULL, the value after the provable fills, and the clean release. Expect 4 rows:
--       CMP0030    CAMPAIGN_NAME  NULL  Affiliate 2024 030  Affiliate 2024 030  fixed by fill
--       DSP0000030 SPEND_DATE     NULL  2023-07-16          2023-07-16          fixed by fill
--       L00000030  CREATED_AT     NULL  NULL                2023-06-18          stays NULL
--       CV0000030  CONVERTED_AT   NULL  NULL                2023-07-13          stays NULL
--     STATUS: every residual mismatch is a NULL left by a blank, never a wrong non-NULL value.
-- -----------------------------------------------------------------------------
WITH cln_campaigns AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID, INITCAP(NULLIF(TRIM(CAMPAIGN_NAME), '')) AS CAMPAIGN_NAME,
           LOWER(NULLIF(TRIM(CHANNEL), '')) AS CHANNEL, LOWER(NULLIF(TRIM(OBJECTIVE), '')) AS OBJECTIVE,
           CASE WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(START_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(START_DATE), 'YYYY/MM/DD') END AS START_DATE,
           CASE WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(END_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(END_DATE), 'YYYY/MM/DD') END AS END_DATE,
           TRY_TO_NUMBER(TRIM(BUDGET), 12, 2) AS BUDGET, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_CAMPAIGNS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_spend AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(SPEND_ID)) AS SPEND_ID, UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID,
           CASE WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(SPEND_DATE), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(SPEND_DATE), 'YYYY/MM/DD') END AS SPEND_DATE,
           TRY_TO_NUMBER(TRIM(IMPRESSIONS)) AS IMPRESSIONS, TRY_TO_NUMBER(TRIM(CLICKS)) AS CLICKS,
           TRY_TO_NUMBER(TRIM(SPEND), 12, 2) AS SPEND, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_DAILY_SPEND)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_leads AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(LEAD_ID)) AS LEAD_ID, UPPER(TRIM(CAMPAIGN_ID)) AS CAMPAIGN_ID,
           CASE WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(CREATED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CREATED_AT), 'YYYY/MM/DD') END AS CREATED_AT,
           LOWER(NULLIF(TRIM(LEAD_SOURCE), '')) AS LEAD_SOURCE, TRY_TO_NUMBER(TRIM(LEAD_SCORE)) AS LEAD_SCORE, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_LEADS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
cln_conversions AS (
  SELECT * FROM (
    SELECT UPPER(TRIM(CONVERSION_ID)) AS CONVERSION_ID, UPPER(TRIM(LEAD_ID)) AS LEAD_ID,
           CASE WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}-[0-9]{2}-[0-9]{2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY-MM-DD')
                WHEN REGEXP_LIKE(TRIM(CONVERTED_AT), '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}') THEN TRY_TO_DATE(TRIM(CONVERTED_AT), 'YYYY/MM/DD') END AS CONVERTED_AT,
           LOWER(NULLIF(TRIM(CONVERSION_TYPE), '')) AS CONVERSION_TYPE, TRY_TO_NUMBER(TRIM(REVENUE), 12, 2) AS REVENUE, _SOURCE_ROW_NUMBER
    FROM RAW.CHALLENGE_CONVERSIONS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
j_campaigns AS (
  SELECT c.*, COALESCE(c.CAMPAIGN_NAME, INITCAP(REPLACE(c.CHANNEL, '_', ' ')) || ' ' || YEAR(c.START_DATE) || ' '
                                        || RIGHT(c.CAMPAIGN_ID, 3)) AS CAMPAIGN_NAME_FILLED,
         r.CAMPAIGN_ID AS R_CAMPAIGN_ID, r.CAMPAIGN_NAME AS R_CAMPAIGN_NAME, r.CHANNEL AS R_CHANNEL, r.OBJECTIVE AS R_OBJECTIVE,
         TO_DATE(r.START_DATE, 'YYYY-MM-DD') AS R_START_DATE, TO_DATE(r.END_DATE, 'YYYY-MM-DD') AS R_END_DATE,
         TO_NUMBER(r.BUDGET, 12, 2) AS R_BUDGET
  FROM cln_campaigns c LEFT JOIN RAW.CAMPAIGNS r ON r.CAMPAIGN_ID = c.CAMPAIGN_ID),
j_spend AS (
  SELECT c.*, COALESCE(c.SPEND_DATE,
                IFF(DATEADD(DAY, 1, LAG(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID))
                      = DATEADD(DAY, -1, LEAD(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID)),
                    DATEADD(DAY, 1, LAG(c.SPEND_DATE) OVER (PARTITION BY c.CAMPAIGN_ID ORDER BY c.SPEND_ID)), NULL)) AS SPEND_DATE_FILLED,
         r.SPEND_ID AS R_SPEND_ID, r.CAMPAIGN_ID AS R_CAMPAIGN_ID, TO_DATE(r.SPEND_DATE, 'YYYY-MM-DD') AS R_SPEND_DATE,
         TO_NUMBER(r.IMPRESSIONS) AS R_IMPRESSIONS, TO_NUMBER(r.CLICKS) AS R_CLICKS, TO_NUMBER(r.SPEND, 12, 2) AS R_SPEND
  FROM cln_spend c LEFT JOIN RAW.DAILY_SPEND r ON r.SPEND_ID = c.SPEND_ID),
j_leads AS (
  SELECT c.*, r.LEAD_ID AS R_LEAD_ID, r.CAMPAIGN_ID AS R_CAMPAIGN_ID, TO_DATE(r.CREATED_AT, 'YYYY-MM-DD') AS R_CREATED_AT,
         r.LEAD_SOURCE AS R_LEAD_SOURCE, TO_NUMBER(r.LEAD_SCORE) AS R_LEAD_SCORE
  FROM cln_leads c LEFT JOIN RAW.LEADS r ON r.LEAD_ID = c.LEAD_ID),
j_conversions AS (
  SELECT c.*, r.CONVERSION_ID AS R_CONVERSION_ID, r.LEAD_ID AS R_LEAD_ID, TO_DATE(r.CONVERTED_AT, 'YYYY-MM-DD') AS R_CONVERTED_AT,
         r.CONVERSION_TYPE AS R_CONVERSION_TYPE, TO_NUMBER(r.REVENUE, 12, 2) AS R_REVENUE
  FROM cln_conversions c LEFT JOIN RAW.CONVERSIONS r ON r.CONVERSION_ID = c.CONVERSION_ID),
cells AS (   -- one row per (key, column): cleaned, after fills, clean release (as text), typed equality
            SELECT 1 AS ORD, 'CHALLENGE_CAMPAIGNS' AS TABLE_NAME, CAMPAIGN_ID AS KEY_VALUE, 'CAMPAIGN_ID' AS COLUMN_NAME,
                   CAMPAIGN_ID AS CLEANED, CAMPAIGN_ID AS FILLED, R_CAMPAIGN_ID AS CLEAN_RELEASE,
                   EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) AS EQ_BLANKS_NULL, EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) AS EQ_WITH_FILLS
            FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'CAMPAIGN_NAME', CAMPAIGN_NAME, CAMPAIGN_NAME_FILLED, R_CAMPAIGN_NAME,
                   EQUAL_NULL(CAMPAIGN_NAME, R_CAMPAIGN_NAME), EQUAL_NULL(CAMPAIGN_NAME_FILLED, R_CAMPAIGN_NAME) FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'CHANNEL', CHANNEL, CHANNEL, R_CHANNEL,
                   EQUAL_NULL(CHANNEL, R_CHANNEL), EQUAL_NULL(CHANNEL, R_CHANNEL) FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'OBJECTIVE', OBJECTIVE, OBJECTIVE, R_OBJECTIVE,
                   EQUAL_NULL(OBJECTIVE, R_OBJECTIVE), EQUAL_NULL(OBJECTIVE, R_OBJECTIVE) FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'START_DATE', TO_VARCHAR(START_DATE, 'YYYY-MM-DD'),
                   TO_VARCHAR(START_DATE, 'YYYY-MM-DD'), TO_VARCHAR(R_START_DATE, 'YYYY-MM-DD'),
                   EQUAL_NULL(START_DATE, R_START_DATE), EQUAL_NULL(START_DATE, R_START_DATE) FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'END_DATE', TO_VARCHAR(END_DATE, 'YYYY-MM-DD'),
                   TO_VARCHAR(END_DATE, 'YYYY-MM-DD'), TO_VARCHAR(R_END_DATE, 'YYYY-MM-DD'),
                   EQUAL_NULL(END_DATE, R_END_DATE), EQUAL_NULL(END_DATE, R_END_DATE) FROM j_campaigns
  UNION ALL SELECT 1, 'CHALLENGE_CAMPAIGNS', CAMPAIGN_ID, 'BUDGET', TO_VARCHAR(BUDGET), TO_VARCHAR(BUDGET), TO_VARCHAR(R_BUDGET),
                   EQUAL_NULL(BUDGET, R_BUDGET), EQUAL_NULL(BUDGET, R_BUDGET) FROM j_campaigns
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'SPEND_ID', SPEND_ID, SPEND_ID, R_SPEND_ID,
                   EQUAL_NULL(SPEND_ID, R_SPEND_ID), EQUAL_NULL(SPEND_ID, R_SPEND_ID) FROM j_spend
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'CAMPAIGN_ID', CAMPAIGN_ID, CAMPAIGN_ID, R_CAMPAIGN_ID,
                   EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID), EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) FROM j_spend
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'SPEND_DATE', TO_VARCHAR(SPEND_DATE, 'YYYY-MM-DD'),
                   TO_VARCHAR(SPEND_DATE_FILLED, 'YYYY-MM-DD'), TO_VARCHAR(R_SPEND_DATE, 'YYYY-MM-DD'),
                   EQUAL_NULL(SPEND_DATE, R_SPEND_DATE), EQUAL_NULL(SPEND_DATE_FILLED, R_SPEND_DATE) FROM j_spend
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'IMPRESSIONS', TO_VARCHAR(IMPRESSIONS), TO_VARCHAR(IMPRESSIONS),
                   TO_VARCHAR(R_IMPRESSIONS), EQUAL_NULL(IMPRESSIONS, R_IMPRESSIONS), EQUAL_NULL(IMPRESSIONS, R_IMPRESSIONS) FROM j_spend
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'CLICKS', TO_VARCHAR(CLICKS), TO_VARCHAR(CLICKS), TO_VARCHAR(R_CLICKS),
                   EQUAL_NULL(CLICKS, R_CLICKS), EQUAL_NULL(CLICKS, R_CLICKS) FROM j_spend
  UNION ALL SELECT 2, 'CHALLENGE_DAILY_SPEND', SPEND_ID, 'SPEND', TO_VARCHAR(SPEND), TO_VARCHAR(SPEND), TO_VARCHAR(R_SPEND),
                   EQUAL_NULL(SPEND, R_SPEND), EQUAL_NULL(SPEND, R_SPEND) FROM j_spend
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'LEAD_ID', LEAD_ID, LEAD_ID, R_LEAD_ID,
                   EQUAL_NULL(LEAD_ID, R_LEAD_ID), EQUAL_NULL(LEAD_ID, R_LEAD_ID) FROM j_leads
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'CAMPAIGN_ID', CAMPAIGN_ID, CAMPAIGN_ID, R_CAMPAIGN_ID,
                   EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID), EQUAL_NULL(CAMPAIGN_ID, R_CAMPAIGN_ID) FROM j_leads
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'CREATED_AT', TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD'),
                   TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(R_CREATED_AT, 'YYYY-MM-DD'),
                   EQUAL_NULL(CREATED_AT, R_CREATED_AT), EQUAL_NULL(CREATED_AT, R_CREATED_AT) FROM j_leads
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'LEAD_SOURCE', LEAD_SOURCE, LEAD_SOURCE, R_LEAD_SOURCE,
                   EQUAL_NULL(LEAD_SOURCE, R_LEAD_SOURCE), EQUAL_NULL(LEAD_SOURCE, R_LEAD_SOURCE) FROM j_leads
  UNION ALL SELECT 3, 'CHALLENGE_LEADS', LEAD_ID, 'LEAD_SCORE', TO_VARCHAR(LEAD_SCORE), TO_VARCHAR(LEAD_SCORE),
                   TO_VARCHAR(R_LEAD_SCORE), EQUAL_NULL(LEAD_SCORE, R_LEAD_SCORE), EQUAL_NULL(LEAD_SCORE, R_LEAD_SCORE) FROM j_leads
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERSION_ID', CONVERSION_ID, CONVERSION_ID, R_CONVERSION_ID,
                   EQUAL_NULL(CONVERSION_ID, R_CONVERSION_ID), EQUAL_NULL(CONVERSION_ID, R_CONVERSION_ID) FROM j_conversions
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'LEAD_ID', LEAD_ID, LEAD_ID, R_LEAD_ID,
                   EQUAL_NULL(LEAD_ID, R_LEAD_ID), EQUAL_NULL(LEAD_ID, R_LEAD_ID) FROM j_conversions
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERTED_AT', TO_VARCHAR(CONVERTED_AT, 'YYYY-MM-DD'),
                   TO_VARCHAR(CONVERTED_AT, 'YYYY-MM-DD'), TO_VARCHAR(R_CONVERTED_AT, 'YYYY-MM-DD'),
                   EQUAL_NULL(CONVERTED_AT, R_CONVERTED_AT), EQUAL_NULL(CONVERTED_AT, R_CONVERTED_AT) FROM j_conversions
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'CONVERSION_TYPE', CONVERSION_TYPE, CONVERSION_TYPE, R_CONVERSION_TYPE,
                   EQUAL_NULL(CONVERSION_TYPE, R_CONVERSION_TYPE), EQUAL_NULL(CONVERSION_TYPE, R_CONVERSION_TYPE) FROM j_conversions
  UNION ALL SELECT 4, 'CHALLENGE_CONVERSIONS', CONVERSION_ID, 'REVENUE', TO_VARCHAR(REVENUE), TO_VARCHAR(REVENUE),
                   TO_VARCHAR(R_REVENUE), EQUAL_NULL(REVENUE, R_REVENUE), EQUAL_NULL(REVENUE, R_REVENUE) FROM j_conversions)
SELECT '8b' AS BLOCK, TABLE_NAME, KEY_VALUE, COLUMN_NAME, COALESCE(CLEANED, 'NULL') AS CLEANED_BLANKS_NULL,
       COALESCE(FILLED, 'NULL') AS AFTER_FILLS, COALESCE(CLEAN_RELEASE, 'NULL') AS CLEAN_RELEASE,
       IFF(EQ_WITH_FILLS, 'fixed by fill', 'stays NULL') AS OUTCOME,
       IFF(CLEANED IS NULL AND CLEAN_RELEASE IS NOT NULL AND (EQ_WITH_FILLS OR FILLED IS NULL), 'PASS', 'FAIL') AS STATUS
FROM cells
WHERE NOT EQ_BLANKS_NULL OR NOT EQ_WITH_FILLS
ORDER BY ORD, KEY_VALUE, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 8c. The same reconciliation at aggregate level, on CMP0001, the only campaign complete in
--     all three fact extracts (1d), plus total budget over all campaigns. Each metric is
--     aggregated separately (grain rule: never join spend rows to lead rows).
--     Expect raw extract: spend 13,899.32, impressions 772,156, clicks 26,562, leads 1,375,
--     conversions 214, revenue 105,014.02, budget 5,433,509.32 (the duplicates add one spend
--     day of 219.93, one lead, one 0.00 trial and CMP0001's budget of 14,867.16).
--     De-duplicated extract = clean release: 13,679.39 / 759,938 / 26,014 / 1,374 / 213 /
--     105,014.02 / 5,418,642.16.
-- -----------------------------------------------------------------------------
WITH d_spend AS (SELECT * FROM RAW.CHALLENGE_DAILY_SPEND
            QUALIFY ROW_NUMBER() OVER (PARTITION BY SPEND_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
d_leads AS (SELECT * FROM RAW.CHALLENGE_LEADS
            QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
d_conv AS (SELECT * FROM RAW.CHALLENGE_CONVERSIONS
           QUALIFY ROW_NUMBER() OVER (PARTITION BY CONVERSION_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
d_camp AS (SELECT * FROM RAW.CHALLENGE_CAMPAIGNS
           QUALIFY ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY _SOURCE_ROW_NUMBER) = 1),
lead_campaign AS (SELECT DISTINCT LEAD_ID, CAMPAIGN_ID FROM RAW.CHALLENGE_LEADS),   -- one row per lead, so a join cannot fan out
versions AS (
  SELECT 1 AS ORD, 'raw extract (as loaded)' AS VERSION,
         (SELECT SUM(TRY_TO_NUMBER(SPEND, 12, 2)) FROM RAW.CHALLENGE_DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001') AS SPEND,
         (SELECT SUM(TRY_TO_NUMBER(IMPRESSIONS)) FROM RAW.CHALLENGE_DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001') AS IMPRESSIONS,
         (SELECT SUM(TRY_TO_NUMBER(CLICKS)) FROM RAW.CHALLENGE_DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001') AS CLICKS,
         (SELECT COUNT(*) FROM RAW.CHALLENGE_LEADS WHERE CAMPAIGN_ID = 'CMP0001') AS LEADS,
         (SELECT COUNT(*) FROM RAW.CHALLENGE_CONVERSIONS v JOIN lead_campaign l ON l.LEAD_ID = v.LEAD_ID
           WHERE l.CAMPAIGN_ID = 'CMP0001') AS CONVERSIONS,
         (SELECT SUM(TRY_TO_NUMBER(v.REVENUE, 12, 2)) FROM RAW.CHALLENGE_CONVERSIONS v JOIN lead_campaign l ON l.LEAD_ID = v.LEAD_ID
           WHERE l.CAMPAIGN_ID = 'CMP0001') AS REVENUE,
         (SELECT SUM(TRY_TO_NUMBER(BUDGET, 12, 2)) FROM RAW.CHALLENGE_CAMPAIGNS) AS BUDGET_ALL_CAMPAIGNS
  UNION ALL
  SELECT 2, 'extract de-duplicated',
         (SELECT SUM(TRY_TO_NUMBER(SPEND, 12, 2)) FROM d_spend WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TRY_TO_NUMBER(IMPRESSIONS)) FROM d_spend WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TRY_TO_NUMBER(CLICKS)) FROM d_spend WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT COUNT(*) FROM d_leads WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT COUNT(*) FROM d_conv v JOIN lead_campaign l ON l.LEAD_ID = v.LEAD_ID WHERE l.CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TRY_TO_NUMBER(v.REVENUE, 12, 2)) FROM d_conv v JOIN lead_campaign l ON l.LEAD_ID = v.LEAD_ID
           WHERE l.CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TRY_TO_NUMBER(BUDGET, 12, 2)) FROM d_camp)
  UNION ALL
  SELECT 3, 'clean release',
         (SELECT SUM(TO_NUMBER(SPEND, 12, 2)) FROM RAW.DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TO_NUMBER(IMPRESSIONS)) FROM RAW.DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TO_NUMBER(CLICKS)) FROM RAW.DAILY_SPEND WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT COUNT(*) FROM RAW.LEADS WHERE CAMPAIGN_ID = 'CMP0001'),
         (SELECT COUNT(*) FROM RAW.CONVERSIONS v JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID WHERE l.CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TO_NUMBER(v.REVENUE, 12, 2)) FROM RAW.CONVERSIONS v JOIN RAW.LEADS l ON l.LEAD_ID = v.LEAD_ID
           WHERE l.CAMPAIGN_ID = 'CMP0001'),
         (SELECT SUM(TO_NUMBER(BUDGET, 12, 2)) FROM RAW.CAMPAIGNS))
SELECT '8c' AS BLOCK, VERSION, SPEND, IMPRESSIONS, CLICKS, LEADS, CONVERSIONS, REVENUE, BUDGET_ALL_CAMPAIGNS,
       IFF(ORD = 1,
           SPEND = 13899.32 AND IMPRESSIONS = 772156 AND CLICKS = 26562 AND LEADS = 1375 AND CONVERSIONS = 214
             AND REVENUE = 105014.02 AND BUDGET_ALL_CAMPAIGNS = 5433509.32,
           SPEND = 13679.39 AND IMPRESSIONS = 759938 AND CLICKS = 26014 AND LEADS = 1374 AND CONVERSIONS = 213
             AND REVENUE = 105014.02 AND BUDGET_ALL_CAMPAIGNS = 5418642.16) AS MATCHES_EXPECTED,
       IFF(MATCHES_EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM versions
ORDER BY ORD;
