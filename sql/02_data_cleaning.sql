-- =============================================================================
-- Phase 3 / 02: data cleaning -> the STAGING layer (8 views)
-- -----------------------------------------------------------------------------
-- Purpose
--   Turn the all-VARCHAR RAW landing tables into analysis-ready, typed STAGING views. One
--   view per RAW table, at the RAW table's grain after de-duplication. Every row is kept:
--   problems are flagged in DQ_ISSUES, never silently dropped or "fixed" in place.
--     Clean track      RAW.CAMPAIGNS / DAILY_SPEND / LEADS / CONVERSIONS
--                      -> STAGING.STG_CAMPAIGNS / STG_DAILY_SPEND / STG_LEADS / STG_CONVERSIONS
--                      The only input of MART and of the dashboard.
--     Challenge track  RAW.CHALLENGE_* -> STAGING.STG_CHALLENGE_* (blocks 5-8)
--                      The same rules, plus the two provable fills in separate *_FILLED
--                      columns. 02_data_cleaning_tests.sql reconciles these views with the
--                      clean views. MART never reads them, because every challenge key also
--                      exists in the clean release (architecture decision 5).
-- Why views
--   This follows the dbt staging convention. A view is always in sync with RAW, stores
--   nothing and needs no refresh step. Phase 5 ports these 8 views to dbt models with the
--   same names (MARKETING_CRM.STAGING.STG_*), so MART and the dbt project share one
--   contract.
-- How to run
--   From the repository root:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02_data_cleaning.sql
--   Then run the tests:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02_data_cleaning_tests.sql
--   The file is idempotent: CREATE OR REPLACE VIEW, no data is copied, and RAW is only read.
--   13 statements, a few seconds on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02_data_cleaning.txt.
-- Role
--   CRM_TRANSFORMER: SELECT on every RAW table, CREATE VIEW in STAGING. It owns the views.
--   It has no CREATE FUNCTION privilege, so every rule is written inline instead of as a UDF.
--   CRM_REPORTER (Data Studio) cannot see STAGING.
-- Inputs / outputs
--   in   MARKETING_CRM.RAW.{CAMPAIGNS, DAILY_SPEND, LEADS, CONVERSIONS} and RAW.CHALLENGE_*
--        (all business columns VARCHAR, plus _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT)
--   out  MARKETING_CRM.STAGING.STG_CAMPAIGNS            CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE,
--                                                       START_DATE, END_DATE, BUDGET, CAMPAIGN_DAYS
--        MARKETING_CRM.STAGING.STG_DAILY_SPEND          SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS,
--                                                       CLICKS, SPEND
--        MARKETING_CRM.STAGING.STG_LEADS                LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE,
--                                                       LEAD_SCORE
--        MARKETING_CRM.STAGING.STG_CONVERSIONS          CONVERSION_ID, LEAD_ID, CONVERTED_DATE,
--                                                       CONVERSION_TYPE, REVENUE
--        every view also has   DQ_ISSUES ARRAY, DQ_IS_VALID BOOLEAN, _SOURCE_FILE,
--                              _SOURCE_ROW_NUMBER, _LOADED_AT (lineage of the row that was kept)
--        MARKETING_CRM.STAGING.STG_CHALLENGE_*: the same columns in the same order, then
--          CAMPAIGN_NAME_FILLED (campaigns) and SPEND_DATE_FILLED (daily spend) appended at the
--          end, so that the first columns line up with the clean view position by position.
--   Types: ids, names and codes VARCHAR; dates DATE; IMPRESSIONS, CLICKS and CAMPAIGN_DAYS
--   NUMBER(38,0); LEAD_SCORE NUMBER(3,0); BUDGET, SPEND and REVENUE NUMBER(12,2). The tests
--   check these names, positions and types against the contract.
--   Renames: CREATED_AT -> CREATED_DATE and CONVERTED_AT -> CONVERTED_DATE, because the values
--   are dates, not timestamps.
-- The cleaning steps (one CTE per step, identical in all 8 views)
--   source   SELECT * from the RAW table, untouched.
--   trimmed  step 1, NULL handling: NULLIF(TRIM(x, ' \t\r\n'), '') per column. The edges are
--            trimmed of space, tab, CR and LF; plain TRIM(x) removes only spaces. A no-break
--            space (NBSP, CHR(160)) is not trimmed (see "Whitespace" below). A blank ('' or
--            whitespace only) becomes NULL. RAW keeps empty strings as '' because the load
--            used EMPTY_FIELD_AS_NULL = FALSE. The raw value is kept next to the trimmed one,
--            so step 3 can say what changed.
--   typed    step 2, type each column by the kind of column it is. Every rule reads the
--            trimmed value (T below), never the raw one:
--              id       UPPER(T)                        e.g. ' cmp0001' -> 'CMP0001'
--              code     LOWER(T)                        channel, objective, lead_source,
--                                                       conversion_type: ' TRIAL ' -> 'trial'
--              name     INITCAP(T)                      campaign_name only. INITCAP treats '_'
--                                                       as a word break ('paid_search' ->
--                                                       'Paid_Search'), so it never touches codes
--              date     routed by SHAPE, never by AUTO detection:
--                         'YYYY-MM-DD', 2-digit parts   -> TRY_TO_DATE(T, 'YYYY-MM-DD')
--                         year-first 'YYYY/M/D', with   -> TRY_TO_DATE(T, 'YYYY/MM/DD'), read as
--                         1- or 2-digit month and day      Y/M/D (01b block 4d: Y/D/M fits none)
--                         anything else, or an impossible date such as 2023-02-29 -> NULL
--              integer  '^[0-9]+$' AND TRY_TO_NUMBER(T, 38, 0); LEAD_SCORE TRY_TO_NUMBER(T, 3, 0)
--              money    '^[0-9]+[.][0-9]{2}$' AND TRY_TO_NUMBER(T, 12, 2)
--            Every date and number needs the pattern AND the cast. Phase 2 (01 block 2.2)
--            showed that the TRY_ casts are lenient on their own: TRY_TO_DATE('2023-1-5',
--            'YYYY-MM-DD') is 2023-01-05, TRY_TO_NUMBER('42.0') is 42, and
--            TRY_TO_NUMBER('1250.405', 12, 2) rounds to 1250.41. A pattern alone would accept
--            2023-02-29. The pattern rejects the first three, and the cast rejects the last.
--            Why the two date shapes differ. 'YYYY-MM-DD' is the documented source format, so
--            a deviation such as '2023-1-5' is format drift; Phase 2 decided to reject it
--            (01 block 2.2), and it becomes NULL + 'unparseable'. The slash route is a recovery
--            rule for one known defect class. Phase 2 defined that class by the pattern
--            [0-9]{4}/[0-9]{1,2}/[0-9]{1,2} and asked Phase 3 to parse with the same gate
--            (01b header, "Conventions"), so every cell that the defect census counts as a
--            slash date is read, not dropped: '2023/7/4' -> 2023-07-04 + 'slash_ymd'. Both
--            cells are flagged, so neither is accepted silently. The 4 slash dates in the
--            extracts all have 2-digit parts.
--            Whitespace. A padded number or date (' 42', '42' + LF, ' 2023-05-15 ') keeps its
--            value and gets '<column>:untrimmed', exactly like a padded id or code. Trimming
--            loses no information, the row still fails DQ_IS_VALID, and the 01b section 8
--            preview also cast TRY_TO_NUMBER(TRIM(x)). What 01 block 2.2 warned about is a
--            cast that accepts ' 42' silently; here it is reported. An NBSP is neither trimmed
--            nor accepted: '42' + NBSP fails the integer pattern -> NULL + 'unparseable', and a
--            code or id containing one is 'nonconforming'.
--   flagged  step 3, DQ_ISSUES: one code per problem cell, '<column>:<issue>'. The column is
--            the STAGING column name in lower case. ARRAY_CONSTRUCT_COMPACT drops the NULLs,
--            so a clean row has an empty array.
--              missing        blank or NULL in RAW -> NULL in STAGING
--              untrimmed      leading/trailing whitespace was removed
--              recased        the letter case was changed (id upper, code lower, name initcap)
--              slash_ymd      a year-first slash date that was parsed as Y/M/D
--              unparseable    date/number text that fits no accepted shape or fails the cast;
--                             the value becomes NULL
--              nonconforming  an id, code or name that is kept, but does not fit its documented
--                             shape (CMP0000, DSP0000000, L00000000, CV0000000, snake_case code,
--                             '<Channel Words> <yyyy> <nnn>' name)
--            Business rules (clicks <= impressions, trial => revenue 0.00, ...) are not
--            flags. They are tests, in 02_data_cleaning_tests.sql.
--   deduped  step 4, de-duplication. The view keeps one row per key:
--              QUALIFY ROW_NUMBER() OVER (PARTITION BY <key>
--                                         ORDER BY <NULL business fields> ASC, _SOURCE_ROW_NUMBER ASC) = 1
--            So the most complete copy wins, then the first one in the file.
--            COUNT(*) OVER (PARTITION BY <key>) records the number of copies on the kept row
--            as 'row:duplicate_copies=N'. If the copies disagree after cleaning, the row also
--            gets 'row:duplicate_copies_differ', so a conflicting copy is never dropped
--            without trace. A row whose key is missing is never collapsed with another one:
--            its partition key falls back to its own source file and row number (COALESCE).
--   final    DQ_ISSUES = cell codes + row codes; DQ_IS_VALID = ARRAY_SIZE(DQ_ISSUES) = 0.
-- Where the rules come from
--   Every rule was previewed read-only in Phase 2: sql/01_data_profiling.sql blocks 2.1-2.2
--   (type gates) and 4 (blanks), and sql/01b_challenge_profiling.sql section 8 (the cleaning
--   preview), 4d (slash dates are Y/M/D), 5b-5d (the two provable fills) and 2a-2b
--   (duplicates are byte-identical copies). docs/data_profile.md, "Implications for Phase 3
--   and Phase 4", lists them. This file refines the 01b section 8 preview in four deliberate
--   ways. None of them changes a value on this data: 02_data_cleaning_tests.sql blocks 15-19
--   still reproduce the Phase 2 results.
--     de-dup order  The preview kept the first copy (ORDER BY _SOURCE_ROW_NUMBER). The views
--                   keep the copy with the fewest NULL fields first, then the first one in the
--                   file, so a copy with a blank never wins over a complete one. The 4
--                   duplicated keys have byte-identical copies (01b 2a), so source row 1 is
--                   kept either way.
--     trim          The preview used plain TRIM (spaces only). That was enough for these files,
--                   because 01b 3a finds no tab, NBSP or other non-printable character. The
--                   views also trim tab, CR and LF.
--     numbers       The preview cast with TRY_TO_NUMBER(TRIM(x)) alone. The views put the
--                   integer and money patterns of 01 blocks 2.1-2.2 in front of the cast and
--                   give every cast an explicit precision.
--     ids           The preview left a blank id as ''. The views turn it into NULL +
--                   '<column>:missing', like every other column.
-- Regex escaping (probed in this account on 2026-10-14, role CRM_TRANSFORMER)
--   In a single-quoted SQL string a backslash is an escape character, and Snowflake drops a
--   backslash that starts no known escape. So '^[0-9]+\.[0-9]{2}$' reaches the regex engine
--   as '^[0-9]+.[0-9]{2}$', where '.' matches any character: REGEXP_LIKE('1234x56', that
--   literal) returned TRUE. '\\.' and '[.]' both return FALSE for '1234x56' and TRUE for
--   '1234.56'. This file therefore writes a literal dot as [.] and a digit as [0-9] (as
--   Phase 2 did), so no pattern needs a backslash. The only escapes are '\t\r\n' in the TRIM
--   character list, where they are meant: LENGTH(' \t\r\n') = 4. REGEXP_LIKE is implicitly
--   anchored to the whole string, but ^...$ is written anyway for readability.
--   02_data_cleaning_tests.sql block 2 runs these rules on edge-case inputs, and block 2b
--   checks that the deployed views contain exactly these rule texts.
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] 0 context   [5] 1 STG_CAMPAIGNS     [6] 2 STG_DAILY_SPEND   [7] 3 STG_LEADS
--   [8] 4 STG_CONVERSIONS   [9] 5 STG_CHALLENGE_CAMPAIGNS   [10] 6 STG_CHALLENGE_DAILY_SPEND
--   [11] 7 STG_CHALLENGE_LEADS   [12] 8 STG_CHALLENGE_CONVERSIONS   [13] 9 build summary
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Context: the transformer role only, no secondary roles (no accidental writes elsewhere)
-- -----------------------------------------------------------------------------
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.STAGING;


-- =============================================================================
-- CLEAN TRACK (input of MART and the dashboard)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. STG_CAMPAIGNS: RAW.CAMPAIGNS, one row per campaign
--    What: ids upper-cased, channel and objective lower-cased, campaign_name INITCAP'd,
--      start/end dates routed by shape, budget cast to NUMBER(12,2). The new CAMPAIGN_DAYS
--      is the inclusive window length (END_DATE - START_DATE + 1). MART divides by it to
--      prorate budget to months and to measure pacing.
--    Why: campaigns is the dimension that every fact joins to, so its key must be unique and
--      typed before any join.
--    Expected: 120 rows, all DQ_IS_VALID. Phase 2 found 0 defects in the clean release
--      (01 blocks 2.1, 3.1, 4), so the rules change no value here; they guard the pipeline.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CAMPAIGNS
  COMMENT = 'Typed, cleaned campaigns (clean release). Grain: one row per CAMPAIGN_ID (120 rows). Source: RAW.CAMPAIGNS. CAMPAIGN_DAYS = END_DATE - START_DATE + 1. DQ_ISSUES lists <column>:<issue> codes (empty when clean). Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CAMPAIGNS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
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
typed AS (   -- step 2: normalise text, route each date by its shape, cast numbers only behind a pattern
  SELECT *,
         UPPER(T_CAMPAIGN_ID)     AS CAMPAIGN_ID,
         INITCAP(T_CAMPAIGN_NAME) AS CAMPAIGN_NAME,       -- a name: INITCAP is safe here, never on codes
         LOWER(T_CHANNEL)         AS CHANNEL,
         LOWER(T_OBJECTIVE)       AS OBJECTIVE,
         CASE WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_START_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_START_DATE, 'YYYY/MM/DD')
         END                      AS START_DATE,          -- any other shape, or an impossible date: NULL
         CASE WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')       THEN TRY_TO_DATE(T_END_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$')   THEN TRY_TO_DATE(T_END_DATE, 'YYYY/MM/DD')
         END                      AS END_DATE,
         CASE WHEN REGEXP_LIKE(T_BUDGET, '^[0-9]+[.][0-9]{2}$') THEN TRY_TO_NUMBER(T_BUDGET, 12, 2)
         END                      AS BUDGET
  FROM trimmed
),
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell; ARRAY_CONSTRUCT_COMPACT drops the NULLs
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
FROM deduped;


-- -----------------------------------------------------------------------------
-- 2. STG_DAILY_SPEND: RAW.DAILY_SPEND, one row per spend_id = one campaign on one day
--    What: ids upper-cased, spend_date routed by shape, impressions and clicks cast to
--      NUMBER(38,0), spend to NUMBER(12,2).
--    Why: this is the only source of spend, impressions and clicks. MART sums it to the
--      campaign (or campaign x date) grain BEFORE joining any other fact. A row-level join
--      to leads inflates spend 2,495x (docs/data_profile.md, "The grain trap").
--    Expected: 11,240 rows, all DQ_IS_VALID; (campaign_id, spend_date) unique (01 block 3.1).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_DAILY_SPEND
  COMMENT = 'Typed, cleaned daily delivery (clean release). Grain: one row per SPEND_ID, i.e. one campaign on one active date (11,240 rows); unique on (CAMPAIGN_ID, SPEND_DATE). Source: RAW.DAILY_SPEND. Aggregate to campaign or campaign x date before joining other facts. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.DAILY_SPEND
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT SPEND_ID    AS RAW_SPEND_ID,    NULLIF(TRIM(SPEND_ID,    ' \t\r\n'), '') AS T_SPEND_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         SPEND_DATE  AS RAW_SPEND_DATE,  NULLIF(TRIM(SPEND_DATE,  ' \t\r\n'), '') AS T_SPEND_DATE,
         IMPRESSIONS AS RAW_IMPRESSIONS, NULLIF(TRIM(IMPRESSIONS, ' \t\r\n'), '') AS T_IMPRESSIONS,
         CLICKS      AS RAW_CLICKS,      NULLIF(TRIM(CLICKS,      ' \t\r\n'), '') AS T_CLICKS,
         SPEND       AS RAW_SPEND,       NULLIF(TRIM(SPEND,       ' \t\r\n'), '') AS T_SPEND,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids, route the date by its shape, cast numbers only behind a pattern
  SELECT *,
         UPPER(T_SPEND_ID)    AS SPEND_ID,
         UPPER(T_CAMPAIGN_ID) AS CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY/MM/DD')
         END                  AS SPEND_DATE,
         CASE WHEN REGEXP_LIKE(T_IMPRESSIONS, '^[0-9]+$')        THEN TRY_TO_NUMBER(T_IMPRESSIONS, 38, 0) END AS IMPRESSIONS,
         CASE WHEN REGEXP_LIKE(T_CLICKS, '^[0-9]+$')             THEN TRY_TO_NUMBER(T_CLICKS, 38, 0)      END AS CLICKS,
         CASE WHEN REGEXP_LIKE(T_SPEND, '^[0-9]+[.][0-9]{2}$')   THEN TRY_TO_NUMBER(T_SPEND, 12, 2)       END AS SPEND
  FROM trimmed
),
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_SPEND_ID IS NULL,                             'spend_id:missing',          NULL),
           IFF(RAW_SPEND_ID <> T_SPEND_ID,                     'spend_id:untrimmed',        NULL),
           IFF(T_SPEND_ID <> SPEND_ID,                         'spend_id:recased',          NULL),
           IFF(NOT REGEXP_LIKE(SPEND_ID, '^DSP[0-9]{7}$'),     'spend_id:nonconforming',    NULL),
           IFF(T_CAMPAIGN_ID IS NULL,                          'campaign_id:missing',       NULL),
           IFF(RAW_CAMPAIGN_ID <> T_CAMPAIGN_ID,               'campaign_id:untrimmed',     NULL),
           IFF(T_CAMPAIGN_ID <> CAMPAIGN_ID,                   'campaign_id:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_ID, '^CMP[0-9]{4}$'),  'campaign_id:nonconforming', NULL),
           IFF(T_SPEND_DATE IS NULL,                           'spend_date:missing',        NULL),
           IFF(RAW_SPEND_DATE <> T_SPEND_DATE,                 'spend_date:untrimmed',      NULL),
           IFF(REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND SPEND_DATE IS NOT NULL,
                                                               'spend_date:slash_ymd',      NULL),
           IFF(T_SPEND_DATE IS NOT NULL AND SPEND_DATE IS NULL, 'spend_date:unparseable',   NULL),
           IFF(T_IMPRESSIONS IS NULL,                          'impressions:missing',       NULL),
           IFF(RAW_IMPRESSIONS <> T_IMPRESSIONS,               'impressions:untrimmed',     NULL),
           IFF(T_IMPRESSIONS IS NOT NULL AND IMPRESSIONS IS NULL, 'impressions:unparseable', NULL),
           IFF(T_CLICKS IS NULL,                               'clicks:missing',            NULL),
           IFF(RAW_CLICKS <> T_CLICKS,                         'clicks:untrimmed',          NULL),
           IFF(T_CLICKS IS NOT NULL AND CLICKS IS NULL,        'clicks:unparseable',        NULL),
           IFF(T_SPEND IS NULL,                                'spend:missing',             NULL),
           IFF(RAW_SPEND <> T_SPEND,                           'spend:untrimmed',           NULL),
           IFF(T_SPEND IS NOT NULL AND SPEND IS NULL,          'spend:unparseable',         NULL)
         ) AS CELL_ISSUES,
         IFF(SPEND_ID IS NULL, 1, 0) + IFF(CAMPAIGN_ID IS NULL, 1, 0) + IFF(SPEND_DATE IS NULL, 1, 0)
           + IFF(IMPRESSIONS IS NULL, 1, 0) + IFF(CLICKS IS NULL, 1, 0) + IFF(SPEND IS NULL, 1, 0) AS N_NULL_FIELDS,
         HASH(SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND)                       AS ROW_HASH,
         COALESCE(SPEND_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER)      AS DEDUP_KEY
  FROM typed
),
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
)
SELECT SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
FROM deduped;


-- -----------------------------------------------------------------------------
-- 3. STG_LEADS: RAW.LEADS, one row per lead
--    What: ids upper-cased, created_at routed by shape and renamed CREATED_DATE (it is a
--      date), lead_source lower-cased, lead_score cast to NUMBER(3,0). A score of 1000 would
--      overflow (3,0) and become NULL + 'lead_score:unparseable' instead of breaking the view.
--    Why: leads carry the funnel's middle step. LEAD_SOURCE is kept as delivered; it equals
--      the campaign channel for every lead (01 block 7.3), so MART takes the channel from
--      STG_CAMPAIGNS, and the tests check the equality as a warning.
--    Expected: 261,684 rows, all DQ_IS_VALID.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_LEADS
  COMMENT = 'Typed, cleaned leads (clean release). Grain: one row per LEAD_ID (261,684 rows). Source: RAW.LEADS; CREATED_AT renamed CREATED_DATE. Channel comes from STG_CAMPAIGNS (LEAD_SOURCE duplicates it). Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.LEADS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT LEAD_ID     AS RAW_LEAD_ID,     NULLIF(TRIM(LEAD_ID,     ' \t\r\n'), '') AS T_LEAD_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         CREATED_AT  AS RAW_CREATED_AT,  NULLIF(TRIM(CREATED_AT,  ' \t\r\n'), '') AS T_CREATED_AT,
         LEAD_SOURCE AS RAW_LEAD_SOURCE, NULLIF(TRIM(LEAD_SOURCE, ' \t\r\n'), '') AS T_LEAD_SOURCE,
         LEAD_SCORE  AS RAW_LEAD_SCORE,  NULLIF(TRIM(LEAD_SCORE,  ' \t\r\n'), '') AS T_LEAD_SCORE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids and the code, route the date by its shape, cast the score behind a pattern
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
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell (created_at is reported as created_date)
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
FROM deduped;


-- -----------------------------------------------------------------------------
-- 4. STG_CONVERSIONS: RAW.CONVERSIONS, one row per conversion = one converted lead
--    What: ids upper-cased, converted_at routed by shape and renamed CONVERTED_DATE,
--      conversion_type lower-cased, revenue cast to NUMBER(12,2).
--    Why: a lead converts at most once (LEAD_ID is unique here, 01 block 3.1), to a trial
--      or a purchase, so lead-level models LEFT JOIN this view on LEAD_ID without fan-out.
--    Expected: 39,696 rows, all DQ_IS_VALID.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CONVERSIONS
  COMMENT = 'Typed, cleaned conversions (clean release). Grain: one row per CONVERSION_ID (39,696 rows); LEAD_ID is unique (1:0..1 from leads). Source: RAW.CONVERSIONS; CONVERTED_AT renamed CONVERTED_DATE. Revenue is last-touch attributed. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CONVERSIONS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT CONVERSION_ID   AS RAW_CONVERSION_ID,   NULLIF(TRIM(CONVERSION_ID,   ' \t\r\n'), '') AS T_CONVERSION_ID,
         LEAD_ID         AS RAW_LEAD_ID,         NULLIF(TRIM(LEAD_ID,         ' \t\r\n'), '') AS T_LEAD_ID,
         CONVERTED_AT    AS RAW_CONVERTED_AT,    NULLIF(TRIM(CONVERTED_AT,    ' \t\r\n'), '') AS T_CONVERTED_AT,
         CONVERSION_TYPE AS RAW_CONVERSION_TYPE, NULLIF(TRIM(CONVERSION_TYPE, ' \t\r\n'), '') AS T_CONVERSION_TYPE,
         REVENUE         AS RAW_REVENUE,         NULLIF(TRIM(REVENUE,         ' \t\r\n'), '') AS T_REVENUE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids and the code, route the date by its shape, cast revenue behind a pattern
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
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell (converted_at is reported as converted_date)
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
FROM deduped;


-- =============================================================================
-- CLEANING-CHALLENGE TRACK (reconciled with the clean views; never used by MART)
-- -----------------------------------------------------------------------------
--   Blocks 5-8 repeat blocks 1-4 CTE for CTE. Only the source table differs, plus the fill
--   columns. Plain SQL has no macros, and this role cannot create UDFs. In Phase 5 each
--   pair becomes one dbt model calling a shared cleaning macro.
--   The 15 defects of the extracts (01b block 7) and what these views do with them:
--     4 duplicate rows      -> collapsed to 1 row each, 'row:duplicate_copies=2'
--     3 casing/whitespace   -> normalised, '<column>:untrimmed' + '<column>:recased'
--     4 year-first slashes  -> parsed as Y/M/D, '<column>:slash_ymd'
--     4 blank values        -> NULL, '<column>:missing'. Two of them are provably recoverable,
--                              and their values go into separate *_FILLED columns:
--         CAMPAIGN_NAME_FILLED  COALESCE(campaign_name, naming rule). The rule
--                               '<Channel words> <start year> <last 3 id digits>' holds for
--                               119 of the 119 named campaigns (01b 5b) and gives exactly one
--                               candidate for CMP0030 (01b 5c).
--         SPEND_DATE_FILLED     COALESCE(spend_date, previous + 1 day) only when the previous
--                               date + 1 = the next date - 1 (LAG/LEAD in spend_id order within
--                               the campaign). In the extract the next spend_id is always the
--                               next day (01b 4c I2, 1,973 of 1,973 pairs). CMP0001's date spine
--                               confirms the one missing day, 2023-07-16, without relying on
--                               id order (01b 5d).
--       CREATED_DATE and CONVERTED_DATE blanks stay NULL: the evidence leaves 2 and 22
--       candidate dates (01b 5c), so no value can be proven.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5. STG_CHALLENGE_CAMPAIGNS: RAW.CHALLENGE_CAMPAIGNS, block 1 + CAMPAIGN_NAME_FILLED
--    Expected: 121 RAW rows -> 120 rows; CMP0001 'row:duplicate_copies=2'; CMP0008
--      'campaign_name:untrimmed' + 'campaign_name:recased' -> 'Display 2023 008'; CMP0018
--      'start_date:slash_ymd' -> 2023-05-15; CMP0030 'campaign_name:missing', NULL, filled
--      'Affiliate 2024 030' (01b blocks 2b, 3d, 4d, 5c).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CHALLENGE_CAMPAIGNS
  COMMENT = 'Cleaning-challenge track: RAW.CHALLENGE_CAMPAIGNS through the same rules as STG_CAMPAIGNS (120 rows after de-duplication), plus CAMPAIGN_NAME_FILLED (naming-rule fill of a blank name). Reconciliation only; never used by MART. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CHALLENGE_CAMPAIGNS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
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
typed AS (   -- step 2: normalise text, route each date by its shape, cast numbers only behind a pattern
  SELECT *,
         UPPER(T_CAMPAIGN_ID)     AS CAMPAIGN_ID,
         INITCAP(T_CAMPAIGN_NAME) AS CAMPAIGN_NAME,       -- a name: INITCAP is safe here, never on codes
         LOWER(T_CHANNEL)         AS CHANNEL,
         LOWER(T_OBJECTIVE)       AS OBJECTIVE,
         CASE WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_START_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_START_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_START_DATE, 'YYYY/MM/DD')
         END                      AS START_DATE,          -- any other shape, or an impossible date: NULL
         CASE WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')       THEN TRY_TO_DATE(T_END_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_END_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$')   THEN TRY_TO_DATE(T_END_DATE, 'YYYY/MM/DD')
         END                      AS END_DATE,
         CASE WHEN REGEXP_LIKE(T_BUDGET, '^[0-9]+[.][0-9]{2}$') THEN TRY_TO_NUMBER(T_BUDGET, 12, 2)
         END                      AS BUDGET
  FROM trimmed
),
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell; ARRAY_CONSTRUCT_COMPACT drops the NULLs
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT,
       -- provable fill, kept apart from CAMPAIGN_NAME: '<Channel words> <start year> <id[-3:]>'.
       -- INITCAP builds a name from the code after '_' -> ' ', so 'paid_search' -> 'Paid Search'.
       COALESCE(CAMPAIGN_NAME,
                INITCAP(REPLACE(CHANNEL, '_', ' ')) || ' ' || YEAR(START_DATE) || ' ' || RIGHT(CAMPAIGN_ID, 3))
                                                                    AS CAMPAIGN_NAME_FILLED
FROM deduped;


-- -----------------------------------------------------------------------------
-- 6. STG_CHALLENGE_DAILY_SPEND: RAW.CHALLENGE_DAILY_SPEND, block 2 + SPEND_DATE_FILLED
--    Expected: 2,001 RAW rows -> 2,000 rows; DSP0000001 'row:duplicate_copies=2';
--      DSP0000018 'spend_date:slash_ymd' -> 2023-07-04; DSP0000030 'spend_date:missing',
--      NULL, filled 2023-07-16 (01b blocks 2b, 4d, 5c, 5d).
--    The fill runs after de-duplication: LAG/LEAD must see one row per spend_id.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CHALLENGE_DAILY_SPEND
  COMMENT = 'Cleaning-challenge track: RAW.CHALLENGE_DAILY_SPEND through the same rules as STG_DAILY_SPEND (2,000 rows after de-duplication), plus SPEND_DATE_FILLED (previous + 1 day when it also equals next - 1 day, in spend_id order within the campaign). Reconciliation only; never used by MART. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CHALLENGE_DAILY_SPEND
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT SPEND_ID    AS RAW_SPEND_ID,    NULLIF(TRIM(SPEND_ID,    ' \t\r\n'), '') AS T_SPEND_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         SPEND_DATE  AS RAW_SPEND_DATE,  NULLIF(TRIM(SPEND_DATE,  ' \t\r\n'), '') AS T_SPEND_DATE,
         IMPRESSIONS AS RAW_IMPRESSIONS, NULLIF(TRIM(IMPRESSIONS, ' \t\r\n'), '') AS T_IMPRESSIONS,
         CLICKS      AS RAW_CLICKS,      NULLIF(TRIM(CLICKS,      ' \t\r\n'), '') AS T_CLICKS,
         SPEND       AS RAW_SPEND,       NULLIF(TRIM(SPEND,       ' \t\r\n'), '') AS T_SPEND,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids, route the date by its shape, cast numbers only behind a pattern
  SELECT *,
         UPPER(T_SPEND_ID)    AS SPEND_ID,
         UPPER(T_CAMPAIGN_ID) AS CAMPAIGN_ID,
         CASE WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY-MM-DD')
              WHEN REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T_SPEND_DATE, 'YYYY/MM/DD')
         END                  AS SPEND_DATE,
         CASE WHEN REGEXP_LIKE(T_IMPRESSIONS, '^[0-9]+$')        THEN TRY_TO_NUMBER(T_IMPRESSIONS, 38, 0) END AS IMPRESSIONS,
         CASE WHEN REGEXP_LIKE(T_CLICKS, '^[0-9]+$')             THEN TRY_TO_NUMBER(T_CLICKS, 38, 0)      END AS CLICKS,
         CASE WHEN REGEXP_LIKE(T_SPEND, '^[0-9]+[.][0-9]{2}$')   THEN TRY_TO_NUMBER(T_SPEND, 12, 2)       END AS SPEND
  FROM trimmed
),
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell
  SELECT *,
         ARRAY_CONSTRUCT_COMPACT(
           IFF(T_SPEND_ID IS NULL,                             'spend_id:missing',          NULL),
           IFF(RAW_SPEND_ID <> T_SPEND_ID,                     'spend_id:untrimmed',        NULL),
           IFF(T_SPEND_ID <> SPEND_ID,                         'spend_id:recased',          NULL),
           IFF(NOT REGEXP_LIKE(SPEND_ID, '^DSP[0-9]{7}$'),     'spend_id:nonconforming',    NULL),
           IFF(T_CAMPAIGN_ID IS NULL,                          'campaign_id:missing',       NULL),
           IFF(RAW_CAMPAIGN_ID <> T_CAMPAIGN_ID,               'campaign_id:untrimmed',     NULL),
           IFF(T_CAMPAIGN_ID <> CAMPAIGN_ID,                   'campaign_id:recased',       NULL),
           IFF(NOT REGEXP_LIKE(CAMPAIGN_ID, '^CMP[0-9]{4}$'),  'campaign_id:nonconforming', NULL),
           IFF(T_SPEND_DATE IS NULL,                           'spend_date:missing',        NULL),
           IFF(RAW_SPEND_DATE <> T_SPEND_DATE,                 'spend_date:untrimmed',      NULL),
           IFF(REGEXP_LIKE(T_SPEND_DATE, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND SPEND_DATE IS NOT NULL,
                                                               'spend_date:slash_ymd',      NULL),
           IFF(T_SPEND_DATE IS NOT NULL AND SPEND_DATE IS NULL, 'spend_date:unparseable',   NULL),
           IFF(T_IMPRESSIONS IS NULL,                          'impressions:missing',       NULL),
           IFF(RAW_IMPRESSIONS <> T_IMPRESSIONS,               'impressions:untrimmed',     NULL),
           IFF(T_IMPRESSIONS IS NOT NULL AND IMPRESSIONS IS NULL, 'impressions:unparseable', NULL),
           IFF(T_CLICKS IS NULL,                               'clicks:missing',            NULL),
           IFF(RAW_CLICKS <> T_CLICKS,                         'clicks:untrimmed',          NULL),
           IFF(T_CLICKS IS NOT NULL AND CLICKS IS NULL,        'clicks:unparseable',        NULL),
           IFF(T_SPEND IS NULL,                                'spend:missing',             NULL),
           IFF(RAW_SPEND <> T_SPEND,                           'spend:untrimmed',           NULL),
           IFF(T_SPEND IS NOT NULL AND SPEND IS NULL,          'spend:unparseable',         NULL)
         ) AS CELL_ISSUES,
         IFF(SPEND_ID IS NULL, 1, 0) + IFF(CAMPAIGN_ID IS NULL, 1, 0) + IFF(SPEND_DATE IS NULL, 1, 0)
           + IFF(IMPRESSIONS IS NULL, 1, 0) + IFF(CLICKS IS NULL, 1, 0) + IFF(SPEND IS NULL, 1, 0) AS N_NULL_FIELDS,
         HASH(SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND)                       AS ROW_HASH,
         COALESCE(SPEND_ID, 'missing key: ' || _SOURCE_FILE || ' row ' || _SOURCE_ROW_NUMBER)      AS DEDUP_KEY
  FROM typed
),
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
  SELECT *,
         COUNT(*) OVER (PARTITION BY DEDUP_KEY) AS N_COPIES,
         MIN(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) <> MAX(ROW_HASH) OVER (PARTITION BY DEDUP_KEY) AS COPIES_DIFFER
  FROM flagged
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1
),
neighbours AS (   -- fill evidence: the spend dates of the previous and next spend_id in the same campaign
  SELECT *,
         LAG(SPEND_DATE)  OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS PREV_SPEND_DATE,
         LEAD(SPEND_DATE) OVER (PARTITION BY CAMPAIGN_ID ORDER BY SPEND_ID) AS NEXT_SPEND_DATE
  FROM deduped
)
SELECT SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND,
       ARRAY_CAT(CELL_ISSUES, ARRAY_CONSTRUCT_COMPACT(
         IFF(N_COPIES > 1, 'row:duplicate_copies=' || N_COPIES, NULL),
         IFF(COPIES_DIFFER, 'row:duplicate_copies_differ', NULL)))  AS DQ_ISSUES,
       ARRAY_SIZE(DQ_ISSUES) = 0                                    AS DQ_IS_VALID,
       _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT,
       -- provable fill, kept apart from SPEND_DATE: only when exactly one day fits between the neighbours
       COALESCE(SPEND_DATE,
                CASE WHEN DATEADD('day', 1, PREV_SPEND_DATE) = DATEADD('day', -1, NEXT_SPEND_DATE)
                     THEN DATEADD('day', 1, PREV_SPEND_DATE)
                END)                                                AS SPEND_DATE_FILLED
FROM neighbours;


-- -----------------------------------------------------------------------------
-- 7. STG_CHALLENGE_LEADS: RAW.CHALLENGE_LEADS, block 3 (no fill)
--    Expected: 2,001 RAW rows -> 2,000 rows; L00000001 'row:duplicate_copies=2'; L00000008
--      'lead_source:untrimmed' + 'lead_source:recased' -> 'paid_search'; L00000018
--      'created_date:slash_ymd' -> 2023-06-17; L00000030 'created_date:missing' -> NULL. The
--      lead_id neighbours allow 2023-06-17 or 2023-06-18 (01b 5c), so it stays NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CHALLENGE_LEADS
  COMMENT = 'Cleaning-challenge track: RAW.CHALLENGE_LEADS through the same rules as STG_LEADS (2,000 rows after de-duplication). The blank created date stays NULL (2 candidate dates, not provable). Reconciliation only; never used by MART. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CHALLENGE_LEADS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT LEAD_ID     AS RAW_LEAD_ID,     NULLIF(TRIM(LEAD_ID,     ' \t\r\n'), '') AS T_LEAD_ID,
         CAMPAIGN_ID AS RAW_CAMPAIGN_ID, NULLIF(TRIM(CAMPAIGN_ID, ' \t\r\n'), '') AS T_CAMPAIGN_ID,
         CREATED_AT  AS RAW_CREATED_AT,  NULLIF(TRIM(CREATED_AT,  ' \t\r\n'), '') AS T_CREATED_AT,
         LEAD_SOURCE AS RAW_LEAD_SOURCE, NULLIF(TRIM(LEAD_SOURCE, ' \t\r\n'), '') AS T_LEAD_SOURCE,
         LEAD_SCORE  AS RAW_LEAD_SCORE,  NULLIF(TRIM(LEAD_SCORE,  ' \t\r\n'), '') AS T_LEAD_SCORE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids and the code, route the date by its shape, cast the score behind a pattern
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
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell (created_at is reported as created_date)
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
FROM deduped;


-- -----------------------------------------------------------------------------
-- 8. STG_CHALLENGE_CONVERSIONS: RAW.CHALLENGE_CONVERSIONS, block 4 (no fill)
--    Expected: 2,001 RAW rows -> 2,000 rows; CV0000001 'row:duplicate_copies=2'; CV0000008
--      'conversion_type:untrimmed' + 'conversion_type:recased' -> 'trial'; CV0000018
--      'converted_date:slash_ymd' -> 2023-07-05; CV0000030 'converted_date:missing' -> NULL.
--      Its lead's created date + 0..21 days leaves 22 candidates (01b 5c), so it stays NULL.
--    1,687 of these conversions point to leads outside the leads extract. That comes from
--      how the extracts were cut (01b 1c); every such lead exists in STG_LEADS.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW MARKETING_CRM.STAGING.STG_CHALLENGE_CONVERSIONS
  COMMENT = 'Cleaning-challenge track: RAW.CHALLENGE_CONVERSIONS through the same rules as STG_CONVERSIONS (2,000 rows after de-duplication). The blank converted date stays NULL (22 candidate dates, not provable). Reconciliation only; never used by MART. Rules: sql/02_data_cleaning.sql.'
AS
WITH source AS (
  SELECT * FROM MARKETING_CRM.RAW.CHALLENGE_CONVERSIONS
),
trimmed AS (   -- step 1: TRIM space/tab/CR/LF, then NULLIF(..., '') turns a blank into NULL
  SELECT CONVERSION_ID   AS RAW_CONVERSION_ID,   NULLIF(TRIM(CONVERSION_ID,   ' \t\r\n'), '') AS T_CONVERSION_ID,
         LEAD_ID         AS RAW_LEAD_ID,         NULLIF(TRIM(LEAD_ID,         ' \t\r\n'), '') AS T_LEAD_ID,
         CONVERTED_AT    AS RAW_CONVERTED_AT,    NULLIF(TRIM(CONVERTED_AT,    ' \t\r\n'), '') AS T_CONVERTED_AT,
         CONVERSION_TYPE AS RAW_CONVERSION_TYPE, NULLIF(TRIM(CONVERSION_TYPE, ' \t\r\n'), '') AS T_CONVERSION_TYPE,
         REVENUE         AS RAW_REVENUE,         NULLIF(TRIM(REVENUE,         ' \t\r\n'), '') AS T_REVENUE,
         _SOURCE_FILE, _SOURCE_ROW_NUMBER, _LOADED_AT
  FROM source
),
typed AS (   -- step 2: normalise ids and the code, route the date by its shape, cast revenue behind a pattern
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
flagged AS (   -- step 3: one '<column>:<issue>' code per problem cell (converted_at is reported as converted_date)
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
deduped AS (   -- step 4: one row per key; the most complete copy wins, then the first one in the file
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
FROM deduped;


-- -----------------------------------------------------------------------------
-- 9. Build summary (descriptive; every check is in 02_data_cleaning_tests.sql)
--    One row per (view, issue code): the view's rows, its rows with at least one issue, and
--    how many rows carry the code ('(none)' when the view is clean). Expected: the clean views
--    have 120 / 11,240 / 261,684 / 39,696 rows and no code. The challenge views have
--    120 / 2,000 / 2,000 / 2,000 rows, with 4 / 3 / 4 / 4 rows flagged, because the 15 defects
--    of 01b block 7 sit on 15 distinct rows. Their 18 codes include the two codes
--    (untrimmed + recased) that each casing/whitespace cell carries.
-- -----------------------------------------------------------------------------
WITH all_views AS (
            SELECT 1 AS ORD, 'STG_CAMPAIGNS' AS VIEW_NAME, DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CAMPAIGNS
  UNION ALL SELECT 2, 'STG_DAILY_SPEND',           DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_DAILY_SPEND
  UNION ALL SELECT 3, 'STG_LEADS',                 DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_LEADS
  UNION ALL SELECT 4, 'STG_CONVERSIONS',           DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CONVERSIONS
  UNION ALL SELECT 5, 'STG_CHALLENGE_CAMPAIGNS',   DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 6, 'STG_CHALLENGE_DAILY_SPEND', DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 7, 'STG_CHALLENGE_LEADS',       DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CHALLENGE_LEADS
  UNION ALL SELECT 8, 'STG_CHALLENGE_CONVERSIONS', DQ_IS_VALID, DQ_ISSUES FROM MARKETING_CRM.STAGING.STG_CHALLENGE_CONVERSIONS
),
per_view AS (
  SELECT ORD, VIEW_NAME, COUNT(*) AS N_ROWS, COUNT_IF(NOT DQ_IS_VALID) AS ROWS_WITH_ISSUES
  FROM all_views
  GROUP BY ORD, VIEW_NAME
),
codes AS (   -- distinct issue codes per view, with how many rows carry each
  SELECT a.ORD, f.VALUE::STRING AS CODE, COUNT(*) AS N
  FROM all_views a, LATERAL FLATTEN(INPUT => a.DQ_ISSUES) f
  GROUP BY a.ORD, f.VALUE::STRING
)
SELECT p.VIEW_NAME, p.N_ROWS, p.ROWS_WITH_ISSUES,
       COALESCE(c.CODE, '(none)') AS ISSUE_CODE, COALESCE(c.N, 0) AS ROWS_WITH_CODE
FROM per_view p
LEFT JOIN codes c ON c.ORD = p.ORD
ORDER BY p.ORD, c.CODE;
