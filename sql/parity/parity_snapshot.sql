-- =============================================================================
-- Phase 5 parity snapshot: a fingerprint of every STAGING and MART object
-- -----------------------------------------------------------------------------
-- Purpose
--   Phase 5 replaces the hand-built STAGING views and MART tables (sql/02_data_cleaning.sql,
--   sql/02b_core_models.sql, sql/02c_analysis_marts.sql) in place with dbt-built objects of
--   the same names. This file records what each object holds and how it is shaped, so a run
--   before the dbt build and a run after it can be diffed line by line:
--     [5] objects  type, transient flag, owner, and the length + MD5 of the relation comment
--     [6] data     COUNT(*) and HASH_AGG(*) of every row of every object (order-independent)
--     [7] columns  ordinal, name, full type (length / precision / scale), nullability, and the
--                  length + MD5 of every column comment
--   Equal COUNT and HASH_AGG mean the same multiset of rows in every column, including the
--   DQ arrays and the lineage columns of the views. Comments are fingerprinted (MD5) because
--   run_sql.py prints at most 40 characters per cell; an MD5 difference names the comment
--   that changed, and its text can then be compared with the source that set it.
-- Scope
--   The 8 STAGING views and the 10 MART tables of Phases 3-4. MART.CONNECTION_TEST (Phase 1)
--   is out of scope: no build file of Phases 3-5 touches it. Block [5] and [7] list every
--   object of the two schemas (except CONNECTION_TEST), so an object that appears or
--   disappears, such as a dbt seed table, shows up in the diff; block [6] fingerprints the
--   18 Phase 3-4 objects by name.
-- Read-only
--   USE, SELECT and WITH only. Nothing is created or changed.
-- How to run (from the repository root)
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 1000 \
--         sql/parity/parity_snapshot.sql > build/parity_before.txt     # or parity_after.txt
--   then: diff build/parity_before.txt build/parity_after.txt. Nothing here reads the clock
--   or the creation time, so two runs over unchanged objects print identical files; the
--   only lines that may differ are the rows of objects or comments that changed on purpose.
--   About 20 seconds on the X-Small MARKETING_WH: HASH_AGG reads every row of STG_LEADS
--   (a view, so the cleaning runs) and FCT_LEAD_CONVERSIONS (261,684 rows each).
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE DATABASE MARKETING_CRM;


-- [5] Objects: type, transient flag, owner, relation comment fingerprint
SELECT TABLE_SCHEMA || '.' || TABLE_NAME                      AS OBJECT_NAME,
       TABLE_TYPE,
       COALESCE(IS_TRANSIENT, '-')                            AS IS_TRANSIENT,
       TABLE_OWNER,
       COALESCE(LENGTH(COMMENT), 0)                           AS COMMENT_LEN,
       COALESCE(MD5(COMMENT), '(none)')                       AS COMMENT_MD5
FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA IN ('STAGING', 'MART')
  AND NOT (TABLE_SCHEMA = 'MART' AND TABLE_NAME = 'CONNECTION_TEST')
ORDER BY TABLE_SCHEMA DESC, TABLE_NAME;


-- [6] Data: row count and an order-independent hash of every row (all columns)
SELECT OBJECT_NAME, N_ROWS, ROWS_HASH
FROM (
            SELECT 'STAGING.STG_CAMPAIGNS' AS OBJECT_NAME, COUNT(*) AS N_ROWS, HASH_AGG(*) AS ROWS_HASH
            FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS
  UNION ALL SELECT 'STAGING.STG_DAILY_SPEND', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND
  UNION ALL SELECT 'STAGING.STG_LEADS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_LEADS
  UNION ALL SELECT 'STAGING.STG_CONVERSIONS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_CONVERSIONS
  UNION ALL SELECT 'STAGING.STG_CHALLENGE_CAMPAIGNS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'STAGING.STG_CHALLENGE_DAILY_SPEND', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'STAGING.STG_CHALLENGE_LEADS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_CHALLENGE_LEADS
  UNION ALL SELECT 'STAGING.STG_CHALLENGE_CONVERSIONS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.STAGING.STG_CHALLENGE_CONVERSIONS
  UNION ALL SELECT 'MART.DIM_DATE', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.DIM_DATE
  UNION ALL SELECT 'MART.DIM_CAMPAIGN', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.DIM_CAMPAIGN
  UNION ALL SELECT 'MART.FCT_DAILY_SPEND', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.FCT_DAILY_SPEND
  UNION ALL SELECT 'MART.FCT_LEAD_CONVERSIONS', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.FCT_LEAD_CONVERSIONS
  UNION ALL SELECT 'MART.MART_CAMPAIGN_PERFORMANCE', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.MART_CAMPAIGN_PERFORMANCE
  UNION ALL SELECT 'MART.FCT_CAMPAIGN_DAILY_ACTIVITY', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.FCT_CAMPAIGN_DAILY_ACTIVITY
  UNION ALL SELECT 'MART.MART_MONTHLY_MARKETING', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.MART_MONTHLY_MARKETING
  UNION ALL SELECT 'MART.MART_MONTHLY_COHORT', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.MART_MONTHLY_COHORT
  UNION ALL SELECT 'MART.MART_CHANNEL_PERFORMANCE', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.MART_CHANNEL_PERFORMANCE
  UNION ALL SELECT 'MART.MART_LEAD_QUALITY', COUNT(*), HASH_AGG(*) FROM MARKETING_CRM.MART.MART_LEAD_QUALITY
)
ORDER BY STARTSWITH(OBJECT_NAME, 'MART.'), OBJECT_NAME;


-- [7] Columns: ordinal, name, full type, nullability, column comment fingerprint
SELECT TABLE_SCHEMA || '.' || TABLE_NAME                      AS OBJECT_NAME,
       ORDINAL_POSITION                                       AS ORD,
       COLUMN_NAME,
       CASE WHEN DATA_TYPE = 'NUMBER' THEN 'NUMBER(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')'
            WHEN DATA_TYPE = 'TEXT'   THEN 'TEXT(' || CHARACTER_MAXIMUM_LENGTH || ')'
            WHEN DATETIME_PRECISION IS NOT NULL AND DATA_TYPE LIKE 'TIMESTAMP%'
                                      THEN DATA_TYPE || '(' || DATETIME_PRECISION || ')'
            ELSE DATA_TYPE
       END                                                    AS FULL_TYPE,
       IS_NULLABLE,
       COALESCE(LENGTH(COMMENT), 0)                           AS COMMENT_LEN,
       COALESCE(MD5(COMMENT), '(none)')                       AS COMMENT_MD5
FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA IN ('STAGING', 'MART')
  AND NOT (TABLE_SCHEMA = 'MART' AND TABLE_NAME = 'CONNECTION_TEST')
ORDER BY TABLE_SCHEMA DESC, TABLE_NAME, ORDINAL_POSITION;
