-- =============================================================================
-- MARKETING_CRM.RAW: file format, stage and landing tables
-- -----------------------------------------------------------------------------
-- Run as CRM_LOADER. `make load` / `make load-challenge` run this file on every load
-- (scripts/load_raw.py); it is idempotent, so it can also be run by hand in Snowsight.
--
-- Why RAW is all VARCHAR
--   RAW is a lossless landing zone: every business column is VARCHAR in source column
--   order, so the COPY can never fail or silently coerce a value ('2023/05/15',
--   ' TRIAL ', '' all land exactly as written). Typing, trimming, de-duplication and
--   date repair happen in STAGING (the dbt models in dbt/models/staging), where every rule is
--   versioned SQL with tests. Declared VARCHAR length has no storage or performance
--   cost in Snowflake, so the columns are unbounded.
-- Lineage columns (filled by the COPY from the stage metadata)
--   _SOURCE_FILE        METADATA$FILENAME, e.g. source/leads.csv.gz
--   _SOURCE_ROW_NUMBER  METADATA$FILE_ROW_NUMBER, the record's row number in that file
--                       (whether the skipped header line is counted is not documented;
--                       make load reports the first value so it is known after day 1)
--   _LOADED_AT          METADATA$START_SCAN_TIME (TIMESTAMP_LTZ) of the load
-- Two tracks, never unioned
--   CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS: the clean v1.0.0 release (the only
--     reconciliation target; MART and the dashboard are built from it).
--   CHALLENGE_*: the publisher's intentionally dirty extracts (duplicates, blanks,
--     casing/whitespace, slash dates) for the Phase 3 cleaning track. Every challenge
--     key also exists in the clean release, so a union would double-count.
-- Re-running: CREATE TABLE IF NOT EXISTS (not OR REPLACE) keeps each table, and with it
-- the table's INFORMATION_SCHEMA.COPY_HISTORY, which a re-created table would lose. To
-- change a RAW table definition, DROP it explicitly first.
-- =============================================================================
USE ROLE CRM_LOADER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.RAW;

-- Lossless CSV parsing. Every non-default option guards against a silent change:
--   EMPTY_FIELD_AS_NULL = FALSE      ,, stays '' (default TRUE would turn it into NULL)
--   NULL_IF = ()                     no string becomes NULL (default ('\\N') would)
--   ESCAPE_UNENCLOSED_FIELD = NONE   backslashes stay data (default '\\' consumes them)
--   TRIM_SPACE = FALSE               leading/trailing spaces survive (the default; explicit)
--   ERROR_ON_COLUMN_COUNT_MISMATCH   TRUE is the default and is enforced by a plain COPY,
--                                    but it is IGNORED by a COPY with a SELECT transform,
--                                    which is what the loader uses to add lineage
--                                    columns. load_raw.py therefore pre-checks the field
--                                    count of every staged record (see that script).
--   SKIP_BLANK_LINES = FALSE         a blank line is an error, not a skipped record
--   REPLACE_INVALID_CHARACTERS = FALSE  invalid UTF-8 fails the load instead of becoming U+FFFD
-- The files themselves were profiled on 2026-10-13: comma-delimited, LF line endings,
-- UTF-8 without BOM, no quote characters, header row first.
-- OR REPLACE so that option changes in this file take effect on the next load (the
-- stage refers to the format by name; the COPY names it explicitly as well).
CREATE OR REPLACE FILE FORMAT MARKETING_CRM.RAW.FF_CSV_LOSSLESS
  TYPE = CSV
  FIELD_DELIMITER = ','
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ESCAPE = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE
  TRIM_SPACE = FALSE
  EMPTY_FIELD_AS_NULL = FALSE
  NULL_IF = ()
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
  SKIP_BLANK_LINES = FALSE
  ENCODING = 'UTF8'
  SKIP_BYTE_ORDER_MARK = TRUE
  REPLACE_INVALID_CHARACTERS = FALSE
  COMPRESSION = AUTO
  COMMENT = 'Lossless CSV: header skipped, nothing trimmed, empty stays empty, no NULL_IF, no escapes.';

-- Named internal stage (PUT target). Files go under source/ and challenge/ prefixes.
CREATE STAGE IF NOT EXISTS MARKETING_CRM.RAW.CRM_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'MARKETING_CRM.RAW.FF_CSV_LOSSLESS')
  COMMENT = 'Internal stage for the dataset CSVs: source/ (clean v1.0.0) and challenge/ (dirty extracts). Uploaded by scripts/load_raw.py.';


-- -----------------------------------------------------------------------------
-- Clean release v1.0.0
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CAMPAIGNS (
  CAMPAIGN_ID        VARCHAR COMMENT 'Stable campaign key, e.g. CMP0001 (PK in the source).',
  CAMPAIGN_NAME      VARCHAR COMMENT 'Display name.',
  CHANNEL            VARCHAR COMMENT 'Paid media channel: affiliate, display, paid_search, paid_social, video.',
  OBJECTIVE          VARCHAR COMMENT 'awareness, lead_gen or acquisition.',
  START_DATE         VARCHAR COMMENT 'First active date, text YYYY-MM-DD.',
  END_DATE           VARCHAR COMMENT 'Last active date (inclusive), text YYYY-MM-DD.',
  BUDGET             VARCHAR COMMENT 'Planned campaign budget, decimal text with 2 dp.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW clean release v1.0.0 campaigns.csv. Grain: one row per campaign (120 rows). All business columns VARCHAR, exactly as in the file.';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.DAILY_SPEND (
  SPEND_ID           VARCHAR COMMENT 'Stable delivery key, e.g. DSP0000001 (PK in the source).',
  CAMPAIGN_ID        VARCHAR COMMENT 'Delivered campaign (FK to CAMPAIGNS).',
  SPEND_DATE         VARCHAR COMMENT 'Delivery date, text YYYY-MM-DD.',
  IMPRESSIONS        VARCHAR COMMENT 'Served impressions, integer text.',
  CLICKS             VARCHAR COMMENT 'Recorded clicks, integer text.',
  SPEND              VARCHAR COMMENT 'Media cost, decimal text with 2 dp.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW clean release v1.0.0 daily_spend.csv. Grain: one row per campaign per active date (11,240 rows). Never join to LEADS at row level: aggregate both to a common grain first.';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.LEADS (
  LEAD_ID            VARCHAR COMMENT 'Stable lead key, e.g. L00000001 (PK in the source).',
  CAMPAIGN_ID        VARCHAR COMMENT 'Attributed campaign (FK to CAMPAIGNS).',
  CREATED_AT         VARCHAR COMMENT 'Lead creation date, text YYYY-MM-DD.',
  LEAD_SOURCE        VARCHAR COMMENT 'Attributed source channel (equals the campaign channel in v1.0.0).',
  LEAD_SCORE         VARCHAR COMMENT 'Qualification score 1-100, integer text.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW clean release v1.0.0 leads.csv. Grain: one row per lead (261,684 rows).';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CONVERSIONS (
  CONVERSION_ID      VARCHAR COMMENT 'Stable conversion key, e.g. CV0000001 (PK in the source).',
  LEAD_ID            VARCHAR COMMENT 'Converted lead (FK to LEADS, one-to-one).',
  CONVERTED_AT       VARCHAR COMMENT 'Conversion date, text YYYY-MM-DD.',
  CONVERSION_TYPE    VARCHAR COMMENT 'trial or purchase.',
  REVENUE            VARCHAR COMMENT 'Attributed revenue (last touch), decimal text with 2 dp; 0.00 for trials.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW clean release v1.0.0 conversions.csv. Grain: one row per converted lead (39,696 rows).';


-- -----------------------------------------------------------------------------
-- Cleaning-challenge extracts (dirty on purpose; separate track, never unioned)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CHALLENGE_CAMPAIGNS (
  CAMPAIGN_ID        VARCHAR COMMENT 'Campaign key as written in the dirty extract.',
  CAMPAIGN_NAME      VARCHAR COMMENT 'Display name; may have casing/whitespace defects or be blank.',
  CHANNEL            VARCHAR COMMENT 'Channel as written.',
  OBJECTIVE          VARCHAR COMMENT 'Objective as written.',
  START_DATE         VARCHAR COMMENT 'Date text; may be YYYY/MM/DD instead of ISO.',
  END_DATE           VARCHAR COMMENT 'Date text as written.',
  BUDGET             VARCHAR COMMENT 'Decimal text as written.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW cleaning-challenge campaigns.csv (dirty extract, 121 rows incl. 1 exact duplicate). Intended grain: one row per campaign. Phase 3 cleaning track only; never union with RAW.CAMPAIGNS.';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CHALLENGE_DAILY_SPEND (
  SPEND_ID           VARCHAR COMMENT 'Delivery key as written.',
  CAMPAIGN_ID        VARCHAR COMMENT 'Campaign key as written.',
  SPEND_DATE         VARCHAR COMMENT 'Date text; may be YYYY/MM/DD or blank.',
  IMPRESSIONS        VARCHAR COMMENT 'Integer text as written.',
  CLICKS             VARCHAR COMMENT 'Integer text as written.',
  SPEND              VARCHAR COMMENT 'Decimal text as written.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW cleaning-challenge daily_spend.csv (dirty extract, 2,001 rows incl. 1 exact duplicate). Intended grain: one row per campaign per date. Phase 3 cleaning track only; never union with RAW.DAILY_SPEND.';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CHALLENGE_LEADS (
  LEAD_ID            VARCHAR COMMENT 'Lead key as written.',
  CAMPAIGN_ID        VARCHAR COMMENT 'Campaign key as written.',
  CREATED_AT         VARCHAR COMMENT 'Date text; may be YYYY/MM/DD or blank.',
  LEAD_SOURCE        VARCHAR COMMENT 'Source channel; may have casing/whitespace defects.',
  LEAD_SCORE         VARCHAR COMMENT 'Integer text as written.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW cleaning-challenge leads.csv (dirty extract, 2,001 rows incl. 1 exact duplicate). Intended grain: one row per lead. Phase 3 cleaning track only; never union with RAW.LEADS.';

CREATE TABLE IF NOT EXISTS MARKETING_CRM.RAW.CHALLENGE_CONVERSIONS (
  CONVERSION_ID      VARCHAR COMMENT 'Conversion key as written.',
  LEAD_ID            VARCHAR COMMENT 'Lead key as written (most point to leads outside the challenge leads extract).',
  CONVERTED_AT       VARCHAR COMMENT 'Date text; may be YYYY/MM/DD or blank.',
  CONVERSION_TYPE    VARCHAR COMMENT 'trial or purchase; may have casing/whitespace defects.',
  REVENUE            VARCHAR COMMENT 'Decimal text as written.',
  _SOURCE_FILE       VARCHAR       COMMENT 'Lineage: staged file (METADATA$FILENAME).',
  _SOURCE_ROW_NUMBER NUMBER(38,0)  COMMENT 'Lineage: row number in the staged file (METADATA$FILE_ROW_NUMBER).',
  _LOADED_AT         TIMESTAMP_LTZ COMMENT 'Lineage: load start time (METADATA$START_SCAN_TIME).'
)
COMMENT = 'RAW cleaning-challenge conversions.csv (dirty extract, 2,001 rows incl. 1 exact duplicate). Intended grain: one row per converted lead. Phase 3 cleaning track only; never union with RAW.CONVERSIONS.';
