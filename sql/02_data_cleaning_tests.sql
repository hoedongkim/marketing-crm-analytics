-- =============================================================================
-- Phase 3 / 02 tests: read-only tests of the 8 STAGING views
-- -----------------------------------------------------------------------------
-- Purpose
--   Prove that STAGING is analysis-ready and that the cleaning rules of 02_data_cleaning.sql
--   are right.
--   (0) All 8 views, blocks 0-2b: the contract (names, order, types), the rule unit tests on
--       edge-case inputs, and a check that the deployed views run exactly those rules.
--   (a) Clean views (STG_CAMPAIGNS, STG_DAILY_SPEND, STG_LEADS, STG_CONVERSIONS), blocks 3-14:
--       every RAW row is kept; the rows are typed and valid; keys, domains, relationships and
--       business rules hold; the control totals equal Phase 2 to the cent.
--   (b) Challenge views (STG_CHALLENGE_*), blocks 15-19: the 4 duplicates are collapsed;
--       exactly the 15 defects that Phase 2 located are flagged, and each gets the value
--       Phase 2 argued for; the rows reproduce the clean views except for the 2 blank dates
--       that no evidence can recover.
--   These are the Phase 5 dbt tests written as SQL: unique, not_null, accepted_values,
--   relationships, expression tests, and a reconciliation test.
-- Read-only
--   Only USE and SELECT/WITH statements. Nothing is created or changed.
-- How to run
--   From the repository root, after sql/02_data_cleaning.sql:
--     .venv/bin/python scripts/run_sql.py --role CRM_TRANSFORMER --max-rows 200 sql/02_data_cleaning_tests.sql
--   run_sql.py prints every result and exits 1 if any row has STATUS = 'FAIL'. 25
--   statements, under a minute on the X-Small MARKETING_WH. Output of the last run:
--   docs/evidence/02_data_cleaning_tests.txt.
-- Role
--   CRM_TRANSFORMER, which owns the STAGING views and can SELECT the RAW tables.
-- Reading the results
--   STATUS = PASS means the view reproduced the expected value exactly. One row, block 14
--   (lead_source vs campaign channel), says WARN instead of FAIL when it does not hold: that
--   is drift to watch, not a broken pipeline. run_sql.py fails only on 'FAIL'.
--   No vacuous passes. Every block that compares groups with an expected list uses a FULL
--   OUTER JOIN, so a missing or unexpected group (view, column, rule text, value, defect,
--   cell) shows up as its own FAIL row. In blocks 4, 5, 6 and 9 each zero count sits next to
--   the number of rows it was evaluated on (block 9: rows whose inputs are not NULL), and
--   that number is checked too, so an empty or all-NULL view cannot pass those rows. The
--   zero counts of blocks 8, 11 and 17 carry no such guard on their own row; an empty view
--   would pass them, but it fails the row counts of blocks 3 and 15 in the same run, and
--   NULL values fail block 6 (clean views) or blocks 15 and 18 (challenge views). So the
--   suite as a whole cannot pass on an empty or NULL-filled view.
--   (Totals of mixed measures share one NUMBER column, so counts print as e.g. 16691.00.)
-- Where the expected values come from (never from the object under test)
--   [C]    The Phase 3 STAGING contract: view and column names, order, types and the rules /
--          DQ codes, as specified for Phase 3 and written in the header of 02_data_cleaning.sql.
--   [E01]  docs/evidence/01_data_profiling.txt, the Phase 2 profile of clean RAW
--          (statement number in brackets).
--   [E01b] docs/evidence/01b_challenge_profiling.txt, the Phase 2 profile of the challenge RAW
--          tables (block id).
--   [D01b] The Phase 2 conventions in the header of sql/01b_challenge_profiling.sql: year-first
--          slash dates are recognised by [0-9]{4}/[0-9]{1,2}/[0-9]{1,2}, parsed with
--          'YYYY/MM/DD' (TRY_TO_DATE('2023/7/4', 'YYYY/MM/DD') = 2023-07-04), and Phase 3 is to
--          use the same gate.
--   [P1]   The local profile "table integrity" (2026-10-13, DuckDB + Python): sum of
--          lead_score 13,233,637.
--   [P3]   The local profile "KPI reconciliation" (2026-10-13; DuckDB and Python csv +
--          Decimal agree): control totals and channel bases. Spend and attributed revenue by
--          channel also equal the publisher's reference output [PUB].
--   All of these were computed from the source CSV files before STAGING existed, and every
--   Phase 2 value was reproduced exactly in Snowflake (424 PASS rows).
-- Statement map (index printed by run_sql.py -> block)
--   [1-4] context   [5] 0 who/where   [6] 1 contract (8 views)   [7] 2 rule unit tests
--   [8] 2b rule texts in the deployed views
--   clean:     [9] 3 row counts   [10] 4 DQ flags   [11] 5 keys   [12] 6 not null
--              [13] 7 accepted values   [14] 8 relationships   [15] 9 business rules
--              [16] 10 date coverage   [17] 11 windows + CAMPAIGN_DAYS   [18] 12 control totals
--              [19] 13 channel summary (aggregate first)   [20] 14 lead_source WARN
--   challenge: [21] 15 de-duplication   [22] 16 the 15 defects   [23] 17 keys in clean
--              [24] 18 reconciliation by row   [25] 19 reconciliation by cell
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.STAGING;


-- -----------------------------------------------------------------------------
-- 0. Who ran this, where and when. Expect role CRM_TRANSFORMER with no secondary roles on
--    MARKETING_WH, schema MARKETING_CRM.STAGING.
-- -----------------------------------------------------------------------------
SELECT CURRENT_USER() AS USER_NAME, CURRENT_ROLE() AS ROLE_NAME, CURRENT_SECONDARY_ROLES() AS SECONDARY_ROLES,
       CURRENT_WAREHOUSE() AS WAREHOUSE_NAME, CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() AS SCHEMA_NAME,
       TO_VARCHAR(SYSDATE(), 'YYYY-MM-DD HH24:MI') || ' UTC' AS RUN_AT,
       IFF(CURRENT_ROLE() = 'CRM_TRANSFORMER' AND CURRENT_WAREHOUSE() = 'MARKETING_WH'
           AND CURRENT_DATABASE() = 'MARKETING_CRM' AND CURRENT_SCHEMA() = 'STAGING'
           AND PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles::STRING = '', 'PASS', 'FAIL') AS STATUS;


-- -----------------------------------------------------------------------------
-- 1. Contract: the 8 objects in STAGING are views with exactly the contract columns, in
--    contract order, with contract types
--    Question: can MART (Phase 3-4) and the dbt port (Phase 5) rely on these names and types?
--    Why: MART selects these columns by name. A renamed column, a NUMBER(10,0) where
--      NUMBER(38,0) was promised, or a missing DQ column would break MART or quietly change
--      it. The contract is built from three parts: the business columns of each clean view,
--      the five trailing columns that every view shares, and the fill column that each of
--      two challenge views appends. A challenge view's first columns therefore line up with
--      its clean view position by position. Any other object in STAGING appears as its own
--      FAIL row, except the three dbt seed tables of Phase 5 (EXPECTED_CAMPAIGN_KPI,
--      EXPECTED_TOTALS, PUBLISHER_CHANNEL_REFERENCE): test inputs, not part of this contract.
--      Each one that exists gets its own row, which passes when it is a table; they are absent
--      after a pure SQL build.
--    Expected [C]: 13 / 11 / 10 / 10 columns (clean), 14 / 12 / 10 / 10 (challenge), 0 problems;
--      after a dbt build also the 3 seed tables, each a BASE TABLE.
-- -----------------------------------------------------------------------------
WITH business_columns (BASE_VIEW, ORDINAL, COLUMN_NAME, DATA_TYPE) AS (   -- [C] business columns of the clean views
  SELECT * FROM VALUES
    ('STG_CAMPAIGNS',   1, 'CAMPAIGN_ID',     'TEXT'),         ('STG_CAMPAIGNS',   2, 'CAMPAIGN_NAME',   'TEXT'),
    ('STG_CAMPAIGNS',   3, 'CHANNEL',         'TEXT'),         ('STG_CAMPAIGNS',   4, 'OBJECTIVE',       'TEXT'),
    ('STG_CAMPAIGNS',   5, 'START_DATE',      'DATE'),         ('STG_CAMPAIGNS',   6, 'END_DATE',        'DATE'),
    ('STG_CAMPAIGNS',   7, 'BUDGET',          'NUMBER(12,2)'), ('STG_CAMPAIGNS',   8, 'CAMPAIGN_DAYS',   'NUMBER(38,0)'),
    ('STG_DAILY_SPEND', 1, 'SPEND_ID',        'TEXT'),         ('STG_DAILY_SPEND', 2, 'CAMPAIGN_ID',     'TEXT'),
    ('STG_DAILY_SPEND', 3, 'SPEND_DATE',      'DATE'),         ('STG_DAILY_SPEND', 4, 'IMPRESSIONS',     'NUMBER(38,0)'),
    ('STG_DAILY_SPEND', 5, 'CLICKS',          'NUMBER(38,0)'), ('STG_DAILY_SPEND', 6, 'SPEND',           'NUMBER(12,2)'),
    ('STG_LEADS',       1, 'LEAD_ID',         'TEXT'),         ('STG_LEADS',       2, 'CAMPAIGN_ID',     'TEXT'),
    ('STG_LEADS',       3, 'CREATED_DATE',    'DATE'),         ('STG_LEADS',       4, 'LEAD_SOURCE',     'TEXT'),
    ('STG_LEADS',       5, 'LEAD_SCORE',      'NUMBER(3,0)'),
    ('STG_CONVERSIONS', 1, 'CONVERSION_ID',   'TEXT'),         ('STG_CONVERSIONS', 2, 'LEAD_ID',         'TEXT'),
    ('STG_CONVERSIONS', 3, 'CONVERTED_DATE',  'DATE'),         ('STG_CONVERSIONS', 4, 'CONVERSION_TYPE', 'TEXT'),
    ('STG_CONVERSIONS', 5, 'REVENUE',         'NUMBER(12,2)')
),
common_columns (POSITION_AFTER, COLUMN_NAME, DATA_TYPE) AS (   -- [C] the same five trailing columns in every view
  SELECT * FROM VALUES
    (1, 'DQ_ISSUES', 'ARRAY'), (2, 'DQ_IS_VALID', 'BOOLEAN'), (3, '_SOURCE_FILE', 'TEXT'),
    (4, '_SOURCE_ROW_NUMBER', 'NUMBER(38,0)'), (5, '_LOADED_AT', 'TIMESTAMP_LTZ')
),
clean_contract AS (
  SELECT BASE_VIEW AS VIEW_NAME, ORDINAL, COLUMN_NAME, DATA_TYPE FROM business_columns
  UNION ALL
  SELECT b.BASE_VIEW, b.N_BUSINESS + c.POSITION_AFTER, c.COLUMN_NAME, c.DATA_TYPE
  FROM (SELECT BASE_VIEW, MAX(ORDINAL) AS N_BUSINESS FROM business_columns GROUP BY BASE_VIEW) b
  CROSS JOIN common_columns c
),
contract AS (   -- challenge views = the clean column list, then the fill column appended at the end
  SELECT VIEW_NAME, ORDINAL, COLUMN_NAME, DATA_TYPE FROM clean_contract
  UNION ALL
  SELECT REPLACE(VIEW_NAME, 'STG_', 'STG_CHALLENGE_'), ORDINAL, COLUMN_NAME, DATA_TYPE FROM clean_contract
  UNION ALL
  SELECT * FROM VALUES ('STG_CHALLENGE_CAMPAIGNS', 14, 'CAMPAIGN_NAME_FILLED', 'TEXT'),
                       ('STG_CHALLENGE_DAILY_SPEND', 12, 'SPEND_DATE_FILLED', 'DATE')
),
non_contract_objects (VIEW_NAME) AS (   -- Phase 5 dbt seeds (test inputs): allowed, columns not checked
  SELECT * FROM VALUES ('EXPECTED_CAMPAIGN_KPI'), ('EXPECTED_TOTALS'), ('PUBLISHER_CHANNEL_REFERENCE')
),
actual AS (
  SELECT TABLE_NAME AS VIEW_NAME, ORDINAL_POSITION AS ORDINAL, COLUMN_NAME,
         IFF(DATA_TYPE = 'NUMBER', 'NUMBER(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')', DATA_TYPE) AS DATA_TYPE
  FROM MARKETING_CRM.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'STAGING'
    AND TABLE_NAME NOT IN (SELECT VIEW_NAME FROM non_contract_objects)
),
objects AS (
  SELECT TABLE_NAME AS VIEW_NAME, TABLE_TYPE FROM MARKETING_CRM.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'STAGING'
),
compared AS (
  SELECT COALESCE(k.VIEW_NAME, a.VIEW_NAME) AS VIEW_NAME, k.ORDINAL AS CONTRACT_ORDINAL, a.ORDINAL AS ACTUAL_ORDINAL,
         CASE WHEN a.COLUMN_NAME IS NULL       THEN 'missing ' || k.COLUMN_NAME
              WHEN k.COLUMN_NAME IS NULL       THEN 'unexpected ' || a.COLUMN_NAME
              WHEN a.ORDINAL <> k.ORDINAL      THEN k.COLUMN_NAME || ' at position ' || a.ORDINAL
              WHEN a.DATA_TYPE <> k.DATA_TYPE  THEN k.COLUMN_NAME || ' is ' || a.DATA_TYPE
         END AS PROBLEM
  FROM contract k
  FULL OUTER JOIN actual a ON a.VIEW_NAME = k.VIEW_NAME AND a.COLUMN_NAME = k.COLUMN_NAME
),
contract_rows AS (
  SELECT c.VIEW_NAME, MAX(o.TABLE_TYPE) AS OBJECT_TYPE,
         COUNT(c.CONTRACT_ORDINAL) AS CONTRACT_COLUMNS, COUNT(c.ACTUAL_ORDINAL) AS ACTUAL_COLUMNS,
         COUNT(c.PROBLEM) AS PROBLEMS,
         COALESCE(LISTAGG(c.PROBLEM, '; ') WITHIN GROUP (ORDER BY c.PROBLEM), '') AS PROBLEM_LIST,
         IFF(MAX(o.TABLE_TYPE) = 'VIEW' AND COUNT(c.CONTRACT_ORDINAL) > 0 AND COUNT(c.PROBLEM) = 0, 'PASS', 'FAIL') AS STATUS
  FROM compared c
  LEFT JOIN objects o ON o.VIEW_NAME = c.VIEW_NAME
  GROUP BY c.VIEW_NAME
),
non_contract_rows AS (   -- one row per seed table that exists; it must be a table
  SELECT o.VIEW_NAME, o.TABLE_TYPE AS OBJECT_TYPE, 0 AS CONTRACT_COLUMNS, 0 AS ACTUAL_COLUMNS, 0 AS PROBLEMS,
         'dbt seed (test input), not part of the contract' AS PROBLEM_LIST,
         IFF(o.TABLE_TYPE = 'BASE TABLE', 'PASS', 'FAIL') AS STATUS
  FROM objects o
  JOIN non_contract_objects n ON n.VIEW_NAME = o.VIEW_NAME
)
SELECT VIEW_NAME, OBJECT_TYPE, CONTRACT_COLUMNS, ACTUAL_COLUMNS, PROBLEMS, PROBLEM_LIST, STATUS
FROM (SELECT *, 0 AS IS_SEED FROM contract_rows UNION ALL SELECT *, 1 FROM non_contract_rows)
ORDER BY IS_SEED, STARTSWITH(VIEW_NAME, 'STG_CHALLENGE_'),
         DECODE(REPLACE(VIEW_NAME, 'STG_CHALLENGE_', 'STG_'), 'STG_CAMPAIGNS', 1, 'STG_DAILY_SPEND', 2, 'STG_LEADS', 3, 4),
         VIEW_NAME;


-- -----------------------------------------------------------------------------
-- 2. Rule unit tests: edge-case inputs through the step 1-3 expressions of 02_data_cleaning.sql
--    Question: does each type gate route, cast and flag exactly as the contract says, also on
--      values that the data does not contain?
--    Why: the clean release exercises only the happy path, and the challenge extracts only 4
--      defect classes. This block feeds the same expressions (trim + NULLIF, UPPER / LOWER /
--      INITCAP, the date router, the integer and money gates, the issue codes) one value at a
--      time and checks the typed value and the codes. Phase 5 replaces it with dbt unit tests
--      on the models.
--      TRAP_GATE shows why every pattern writes a dot as [.]. It is the money gate as a naive
--      single-quoted literal '^[0-9]+\.[0-9]{2}$': Snowflake drops the unknown escape '\.',
--      so the regex sees '.', which matches any character. It accepts '1250x40', and worse
--      '125040', which the cast would turn into 125040.00.
--      This block copies the rule expressions; block 2b checks that the deployed views contain
--      the same texts, so a change to a view's rule cannot leave this block passing unnoticed.
--      Inputs: '\t', '\n' and '\u00A0' are tab, LF and NBSP (Snowflake string escapes);
--      INPUT_TEXT prints them as \t, \n and <nbsp>.
--    Expected: VALUE, CODES and TRAP_GATE as listed (codes sorted, '' = clean). Sources:
--      [C] the step 1-3 rules in the header of 02_data_cleaning.sql, including its two
--          documented choices: a padded number keeps its value and is flagged 'untrimmed'
--          ("Whitespace"), and an NBSP is not trimmed;
--      [E01 7] the lenient casts that the patterns must stop ('2023-1-5', '42.0', '1250.405');
--      [D01b] and [E01b 4d] year-first slash dates use the pattern [0-9]{4}/[0-9]{1,2}/[0-9]{1,2}
--          and are read as Y/M/D, so '2023/7/4' -> 2023-07-04.
-- -----------------------------------------------------------------------------
WITH cases (KIND, RAW_INPUT, EXPECTED_VALUE, EXPECTED_CODES, EXPECTED_TRAP) AS (
  SELECT * FROM VALUES
    ('date',       '2023-05-15',         '2023-05-15',       '',                      NULL::BOOLEAN),
    ('date',       ' 2023-05-15 ',       '2023-05-15',       'untrimmed',             NULL),
    ('date',       '2023/05/15',         '2023-05-15',       'slash_ymd',             NULL),
    ('date',       '2023/7/4',           '2023-07-04',       'slash_ymd',             NULL),   -- [D01b] 1-digit parts are read
    ('date',       '2023-1-5',           NULL,               'unparseable',           NULL),   -- [E01 7] TRY_TO_DATE alone accepts it
    ('date',       '2023-02-29',         NULL,               'unparseable',           NULL),   -- the pattern alone accepts it
    ('date',       '2023/15/05',         NULL,               'unparseable',           NULL),   -- never re-read as Y/D/M
    ('date',       '05/15/2023',         NULL,               'unparseable',           NULL),   -- not year-first
    ('date',       '',                   NULL,               'missing',               NULL),
    ('date',       ' \t ',               NULL,               'missing',               NULL),   -- whitespace only (tab)
    ('integer',    '42',                 '42',               '',                      NULL),
    ('integer',    ' 42',                '42',               'untrimmed',             NULL),   -- [C] padded: value kept, flagged
    ('integer',    '42 ',                '42',               'untrimmed',             NULL),
    ('integer',    '\t42',               '42',               'untrimmed',             NULL),
    ('integer',    '42\n',               '42',               'untrimmed',             NULL),
    ('integer',    '42\u00A0',           NULL,               'unparseable',           NULL),   -- [C] NBSP is not trimmed
    ('integer',    '42.0',               NULL,               'unparseable',           NULL),   -- [E01 7] TRY_TO_NUMBER alone gives 42
    ('integer',    '-5',                 NULL,               'unparseable',           NULL),
    ('lead_score', '1000',               NULL,               'unparseable',           NULL),   -- overflows NUMBER(3,0)
    ('money',      '1250.40',            '1250.40',          '',                      TRUE),
    ('money',      ' 1250.40',           '1250.40',          'untrimmed',             TRUE),   -- [C] padded: value kept, flagged
    ('money',      '1250.405',           NULL,               'unparseable',           FALSE),  -- [E01 7] the cast alone rounds to 1250.41
    ('money',      '1250.4',             NULL,               'unparseable',           FALSE),  -- the cast alone pads to 1250.40
    ('money',      '1250x40',            NULL,               'unparseable',           TRUE),   -- accepted by the naive '\.'
    ('money',      '125040',             NULL,               'unparseable',           TRUE),   -- accepted by the naive '\.'
    ('code',       ' TRIAL ',            'trial',            'recased,untrimmed',     NULL),
    ('code',       'paid-search',        'paid-search',      'nonconforming',         NULL),
    ('name',       ' DISPLAY 2023 008 ', 'Display 2023 008', 'recased,untrimmed',     NULL),
    ('id',         ' cmp0001',           'CMP0001',          'recased,untrimmed',     NULL),
    ('id',         'CMP001',             'CMP001',           'nonconforming',         NULL)
),
trimmed AS (   -- step 1
  SELECT *, NULLIF(TRIM(RAW_INPUT, ' \t\r\n'), '') AS T FROM cases
),
typed AS (     -- step 2, one branch per kind of column
  SELECT *,
         CASE KIND
           WHEN 'date'       THEN TO_VARCHAR(CASE WHEN REGEXP_LIKE(T, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')     THEN TRY_TO_DATE(T, 'YYYY-MM-DD')
                                                  WHEN REGEXP_LIKE(T, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') THEN TRY_TO_DATE(T, 'YYYY/MM/DD') END,
                                             'YYYY-MM-DD')
           WHEN 'integer'    THEN TO_VARCHAR(CASE WHEN REGEXP_LIKE(T, '^[0-9]+$') THEN TRY_TO_NUMBER(T, 38, 0) END)
           WHEN 'lead_score' THEN TO_VARCHAR(CASE WHEN REGEXP_LIKE(T, '^[0-9]+$') THEN TRY_TO_NUMBER(T, 3, 0) END)
           WHEN 'money'      THEN TO_VARCHAR(CASE WHEN REGEXP_LIKE(T, '^[0-9]+[.][0-9]{2}$') THEN TRY_TO_NUMBER(T, 12, 2) END)
           WHEN 'code'       THEN LOWER(T)
           WHEN 'name'       THEN INITCAP(T)
           WHEN 'id'         THEN UPPER(T)
         END AS VALUE
  FROM trimmed
),
coded AS (     -- step 3, the issue codes without the column prefix
  SELECT *,
         ARRAY_TO_STRING(ARRAY_SORT(ARRAY_CONSTRUCT_COMPACT(
           IFF(T IS NULL,                                                         'missing',       NULL),
           IFF(RAW_INPUT <> T,                                                    'untrimmed',     NULL),
           IFF(KIND IN ('code', 'name', 'id') AND T <> VALUE,                     'recased',       NULL),
           IFF(KIND = 'id'   AND NOT REGEXP_LIKE(VALUE, '^CMP[0-9]{4}$'),         'nonconforming', NULL),
           IFF(KIND = 'code' AND NOT REGEXP_LIKE(VALUE, '^[a-z]+(_[a-z]+)*$'),    'nonconforming', NULL),
           IFF(KIND = 'name' AND NOT REGEXP_LIKE(VALUE, '^[A-Z][a-z]+( [A-Z][a-z]+)* [0-9]{4} [0-9]{3}$'),
                                                                                  'nonconforming', NULL),
           IFF(KIND = 'date' AND REGEXP_LIKE(T, '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$') AND VALUE IS NOT NULL,
                                                                                  'slash_ymd',     NULL),
           IFF(KIND IN ('date', 'integer', 'lead_score', 'money') AND T IS NOT NULL AND VALUE IS NULL,
                                                                                  'unparseable',   NULL))), ',') AS CODES,
         IFF(KIND = 'money', REGEXP_LIKE(T, '^[0-9]+\.[0-9]{2}$'), NULL) AS TRAP_GATE   -- the naive literal, on purpose
  FROM typed
)
SELECT KIND, '[' || REPLACE(REPLACE(REPLACE(RAW_INPUT, '\t', '\\t'), '\n', '\\n'), '\u00A0', '<nbsp>') || ']' AS INPUT_TEXT,
       VALUE, EXPECTED_VALUE, CODES, EXPECTED_CODES,
       TRAP_GATE, EXPECTED_TRAP,
       IFF(EQUAL_NULL(VALUE, EXPECTED_VALUE) AND EQUAL_NULL(CODES, EXPECTED_CODES) AND EQUAL_NULL(TRAP_GATE, EXPECTED_TRAP),
           'PASS', 'FAIL') AS STATUS
FROM coded
ORDER BY DECODE(KIND, 'date', 1, 'integer', 2, 'lead_score', 3, 'money', 4, 'code', 5, 'name', 6, 7), EXPECTED_CODES, RAW_INPUT;


-- -----------------------------------------------------------------------------
-- 2b. Rule texts in the deployed views: the views run the expressions that block 2 tests
--    Question: does each deployed view contain exactly the rule texts of block 2, once per
--      column that needs them, and none of the constructs the rules exist to avoid?
--    Why: block 2 runs copies of the rule expressions on a VALUES list, because this role
--      cannot create UDFs and a view's expressions cannot be called on test inputs. Without
--      this block, a view could switch to the naive '\.' literal, an AUTO date cast, INITCAP
--      on a code or another de-dup order while block 2 still passed. The check reads
--      INFORMATION_SCHEMA.VIEWS.VIEW_DEFINITION, the text Snowflake stores for each view.
--      run_sql.py strips SQL comments before sending a statement, so a comment cannot match.
--      A text is counted with LENGTH and REPLACE, not with a regex, so no escaping is
--      involved; dollar quotes keep each backslash as written.
--      The expected counts follow from the column kinds of the contract (block 1), never
--      from the view text. Per view:
--        trim + NULLIF, ':missing', ':untrimmed'       once per business column
--        UPPER( / LOWER( / INITCAP(                     once per id / code / name, plus one
--                                                       INITCAP( for CAMPAIGN_NAME_FILLED
--        ':recased', ':nonconforming'                   once per id, code and name
--        ISO gate, ISO mask, slash mask, ':slash_ymd'   once per date
--        slash gate, TRY_TO_DATE(                       twice per date (slash gate: route +
--                                                       flag; TRY_TO_DATE: one per route)
--        integer gate                                   once per integer or score column
--        money gate, cast (12, 2)                       once per money column
--        cast (38, 0) / cast (3, 0)                     once per integer / score column
--        TRY_TO_NUMBER(, ':unparseable'                 once per number column (and per date
--                                                       for ':unparseable')
--        de-dup QUALIFY, the two row codes              once
--        naive backslash-dot, 'AUTO', '::DATE'          never
--      'TO_DATE(' and 'TO_NUMBER(' also match inside TRY_TO_DATE( and TRY_TO_NUMBER(, so equal
--      counts prove there is no bare TO_DATE or TO_NUMBER, which would fail on a bad value.
--      The FULL OUTER JOIN makes a missing view, or an unexpected one, its own FAIL row, and a
--      view whose text cannot be read fails on every text.
--    Expected [C]: 0 problems in all 8 views. Column kinds: campaigns 1 id, 1 name, 2 codes,
--      2 dates, 1 money; daily spend 2 ids, 1 date, 2 integers, 1 money; leads 2 ids,
--      1 date, 1 code, 1 score; conversions 2 ids, 1 date, 1 code, 1 money. Each challenge
--      view has the kinds of its clean view.
-- -----------------------------------------------------------------------------
WITH rule_texts (TEXT_NAME, RULE_TEXT) AS (   -- the texts of block 2's expressions, verbatim
  SELECT * FROM VALUES
    ('trim + NULLIF',       $$' \t\r\n'), '')$$),
    ('UPPER(',              'UPPER('),
    ('LOWER(',              'LOWER('),
    ('INITCAP(',            'INITCAP('),
    ('ISO date gate',       $$'^[0-9]{4}-[0-9]{2}-[0-9]{2}$'$$),
    ('ISO date mask',       $$, 'YYYY-MM-DD')$$),
    ('slash date gate',     $$'^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'$$),
    ('slash date mask',     $$, 'YYYY/MM/DD')$$),
    ('TRY_TO_DATE(',        'TRY_TO_DATE('),
    ('TO_DATE(',            'TO_DATE('),
    ('integer gate',        $$'^[0-9]+$'$$),
    ('money gate',          $$'^[0-9]+[.][0-9]{2}$'$$),
    ('cast (38, 0)',        ', 38, 0)'),
    ('cast (3, 0)',         ', 3, 0)'),
    ('cast (12, 2)',        ', 12, 2)'),
    ('TRY_TO_NUMBER(',      'TRY_TO_NUMBER('),
    ('TO_NUMBER(',          'TO_NUMBER('),
    ('code :missing',       $$:missing'$$),
    ('code :untrimmed',     $$:untrimmed'$$),
    ('code :recased',       $$:recased'$$),
    ('code :nonconforming', $$:nonconforming'$$),
    ('code :slash_ymd',     $$:slash_ymd'$$),
    ('code :unparseable',   $$:unparseable'$$),
    ('code row:copies=N',   $$'row:duplicate_copies='$$),
    ('code row:differ',     $$'row:duplicate_copies_differ'$$),
    ('de-dup QUALIFY',      'QUALIFY ROW_NUMBER() OVER (PARTITION BY DEDUP_KEY ORDER BY N_NULL_FIELDS ASC, _SOURCE_ROW_NUMBER ASC) = 1'),
    ('naive backslash-dot', $$\.$$),
    ('AUTO',                'AUTO'),
    ('::DATE',              '::DATE')
),
clean_kinds (VIEW_NAME, IDS, NAMES, CODES, DATES, INTEGERS, SCORES, MONEY) AS (   -- [C] column kinds
  SELECT * FROM VALUES
    ('STG_CAMPAIGNS',   1, 1, 2, 2, 0, 0, 1),
    ('STG_DAILY_SPEND', 2, 0, 0, 1, 2, 0, 1),
    ('STG_LEADS',       2, 0, 1, 1, 0, 1, 0),
    ('STG_CONVERSIONS', 2, 0, 1, 1, 0, 0, 1)
),
column_kinds AS (   -- each challenge view has its clean view's kinds; only STG_CHALLENGE_CAMPAIGNS has a name fill
  SELECT *, 0 AS NAME_FILLS FROM clean_kinds
  UNION ALL
  SELECT REPLACE(VIEW_NAME, 'STG_', 'STG_CHALLENGE_'), IDS, NAMES, CODES, DATES, INTEGERS, SCORES, MONEY,
         IFF(VIEW_NAME = 'STG_CAMPAIGNS', 1, 0)
  FROM clean_kinds
),
expected AS (
  SELECT k.VIEW_NAME, t.TEXT_NAME,
         CASE t.TEXT_NAME
           WHEN 'trim + NULLIF'       THEN k.IDS + k.NAMES + k.CODES + k.DATES + k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'code :missing'       THEN k.IDS + k.NAMES + k.CODES + k.DATES + k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'code :untrimmed'     THEN k.IDS + k.NAMES + k.CODES + k.DATES + k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'UPPER('              THEN k.IDS
           WHEN 'LOWER('              THEN k.CODES
           WHEN 'INITCAP('            THEN k.NAMES + k.NAME_FILLS
           WHEN 'code :recased'       THEN k.IDS + k.NAMES + k.CODES
           WHEN 'code :nonconforming' THEN k.IDS + k.NAMES + k.CODES
           WHEN 'ISO date gate'       THEN k.DATES
           WHEN 'ISO date mask'       THEN k.DATES
           WHEN 'slash date mask'     THEN k.DATES
           WHEN 'code :slash_ymd'     THEN k.DATES
           WHEN 'slash date gate'     THEN 2 * k.DATES
           WHEN 'TRY_TO_DATE('        THEN 2 * k.DATES
           WHEN 'TO_DATE('            THEN 2 * k.DATES
           WHEN 'integer gate'        THEN k.INTEGERS + k.SCORES
           WHEN 'money gate'          THEN k.MONEY
           WHEN 'cast (38, 0)'        THEN k.INTEGERS
           WHEN 'cast (3, 0)'         THEN k.SCORES
           WHEN 'cast (12, 2)'        THEN k.MONEY
           WHEN 'TRY_TO_NUMBER('      THEN k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'TO_NUMBER('          THEN k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'code :unparseable'   THEN k.DATES + k.INTEGERS + k.SCORES + k.MONEY
           WHEN 'code row:copies=N'   THEN 1
           WHEN 'code row:differ'     THEN 1
           WHEN 'de-dup QUALIFY'      THEN 1
           ELSE 0                                         -- naive backslash-dot, AUTO, ::DATE
         END AS N_EXPECTED
  FROM column_kinds k CROSS JOIN rule_texts t
),
actual AS (   -- occurrences of each text in each view's stored definition
  SELECT v.TABLE_NAME AS VIEW_NAME, t.TEXT_NAME,
         ((LENGTH(v.VIEW_DEFINITION) - LENGTH(REPLACE(v.VIEW_DEFINITION, t.RULE_TEXT, ''))) / LENGTH(t.RULE_TEXT))::NUMBER(10,0)
           AS N_FOUND
  FROM MARKETING_CRM.INFORMATION_SCHEMA.VIEWS v CROSS JOIN rule_texts t
  WHERE v.TABLE_SCHEMA = 'STAGING'
),
compared AS (
  SELECT COALESCE(e.VIEW_NAME, a.VIEW_NAME) AS VIEW_NAME, e.TEXT_NAME AS EXPECTED_TEXT, e.N_EXPECTED, a.N_FOUND,
         CASE WHEN a.VIEW_NAME IS NULL                    THEN 'view missing'
              WHEN e.VIEW_NAME IS NULL                    THEN 'unexpected view'
              WHEN a.N_FOUND IS NULL                      THEN e.TEXT_NAME || ' unreadable'
              WHEN a.N_FOUND <> e.N_EXPECTED              THEN e.TEXT_NAME || ' ' || a.N_FOUND || 'x (expected ' || e.N_EXPECTED || ')'
         END AS PROBLEM
  FROM expected e
  FULL OUTER JOIN actual a ON a.VIEW_NAME = e.VIEW_NAME AND a.TEXT_NAME = e.TEXT_NAME
)
SELECT VIEW_NAME, COUNT(EXPECTED_TEXT) AS TEXTS_CHECKED,
       SUM(IFF(N_EXPECTED > 0, N_FOUND, 0)) AS RULE_TEXTS_FOUND, SUM(N_EXPECTED) AS RULE_TEXTS_EXPECTED,
       SUM(IFF(N_EXPECTED = 0, N_FOUND, 0)) AS UNEXPECTED_FOUND,   -- texts this view must not contain
       COUNT(PROBLEM) AS PROBLEMS,
       COALESCE(LISTAGG(DISTINCT PROBLEM, '; ') WITHIN GROUP (ORDER BY PROBLEM), '') AS PROBLEM_LIST,
       IFF(COUNT(EXPECTED_TEXT) > 0 AND COUNT(PROBLEM) = 0, 'PASS', 'FAIL') AS STATUS
FROM compared
GROUP BY VIEW_NAME
ORDER BY STARTSWITH(VIEW_NAME, 'STG_CHALLENGE_'),
         DECODE(REPLACE(VIEW_NAME, 'STG_CHALLENGE_', 'STG_'), 'STG_CAMPAIGNS', 1, 'STG_DAILY_SPEND', 2, 'STG_LEADS', 3, 4);


-- =============================================================================
-- A. CLEAN STAGING (input of MART and the dashboard)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3. Row counts: every RAW row reaches STAGING
--    Question: does each clean view have exactly one row per RAW row?
--    Why: STAGING flags problems instead of dropping rows. The clean release has no
--      duplicates, so de-duplication must remove nothing; a lower count would mean a lost
--      row, and a higher one a fan-out.
--    Expected: 120 / 11,240 / 261,684 / 39,696 in RAW and in STAGING [E01 5; publisher README].
-- -----------------------------------------------------------------------------
SELECT VIEW_NAME, STG_ROWS, RAW_TABLE, RAW_ROWS, EXPECTED,
       IFF(STG_ROWS = EXPECTED AND RAW_ROWS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'STG_CAMPAIGNS' AS VIEW_NAME, (SELECT COUNT(*) FROM STG_CAMPAIGNS) AS STG_ROWS,
                   'RAW.CAMPAIGNS' AS RAW_TABLE, (SELECT COUNT(*) FROM RAW.CAMPAIGNS) AS RAW_ROWS, 120 AS EXPECTED
  UNION ALL SELECT 2, 'STG_DAILY_SPEND', (SELECT COUNT(*) FROM STG_DAILY_SPEND),
                   'RAW.DAILY_SPEND', (SELECT COUNT(*) FROM RAW.DAILY_SPEND), 11240
  UNION ALL SELECT 3, 'STG_LEADS', (SELECT COUNT(*) FROM STG_LEADS),
                   'RAW.LEADS', (SELECT COUNT(*) FROM RAW.LEADS), 261684
  UNION ALL SELECT 4, 'STG_CONVERSIONS', (SELECT COUNT(*) FROM STG_CONVERSIONS),
                   'RAW.CONVERSIONS', (SELECT COUNT(*) FROM RAW.CONVERSIONS), 39696
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 4. DQ flags: no row of the clean release carries an issue
--    Question: is DQ_IS_VALID true for every clean row?
--    Why: Phase 2 found 0 non-conforming, blank, untrimmed or duplicate values in the clean
--      release [E01 6, 8, 10]. So every rule of 02_data_cleaning.sql must pass every row,
--      and any code here means the rules or RAW changed. VALID_ROWS = N_ROWS also catches a
--      NULL flag.
--    Expected: 0 invalid rows and 0 issue codes in all 4 views; rows as in block 3.
-- -----------------------------------------------------------------------------
WITH flags AS (
            SELECT 1 AS ORD, 'STG_CAMPAIGNS' AS VIEW_NAME, 120 AS EXPECTED_ROWS, DQ_IS_VALID, DQ_ISSUES FROM STG_CAMPAIGNS
  UNION ALL SELECT 2, 'STG_DAILY_SPEND', 11240,  DQ_IS_VALID, DQ_ISSUES FROM STG_DAILY_SPEND
  UNION ALL SELECT 3, 'STG_LEADS',       261684, DQ_IS_VALID, DQ_ISSUES FROM STG_LEADS
  UNION ALL SELECT 4, 'STG_CONVERSIONS', 39696,  DQ_IS_VALID, DQ_ISSUES FROM STG_CONVERSIONS
)
SELECT VIEW_NAME, COUNT(*) AS N_ROWS, COUNT_IF(DQ_IS_VALID) AS VALID_ROWS, COUNT_IF(NOT DQ_IS_VALID) AS INVALID_ROWS,
       SUM(ARRAY_SIZE(DQ_ISSUES)) AS ISSUE_CODES, EXPECTED_ROWS, 0 AS EXPECTED_INVALID,
       IFF(COUNT(*) = EXPECTED_ROWS AND COUNT_IF(DQ_IS_VALID) = COUNT(*) AND SUM(ARRAY_SIZE(DQ_ISSUES)) = 0,
           'PASS', 'FAIL') AS STATUS
FROM flags
GROUP BY ORD, VIEW_NAME, EXPECTED_ROWS
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 5. Keys: unique and not null (GROUP BY ... HAVING COUNT(*) > 1)
--    Question: does every declared key identify exactly one row?
--    Why: Snowflake does not enforce PRIMARY KEY or UNIQUE. A duplicated campaign_id would
--      double every fact joined to it, and a duplicated (campaign_id, spend_date) would
--      double a day's spend. A duplicated conversions.lead_id would break the 1:0..1 rule
--      that lets lead-level models LEFT JOIN conversions without fan-out. DUPLICATED_KEYS
--      counts the key values that GROUP BY ... HAVING COUNT(*) > 1 returns.
--    Expected: 0 NULL keys and 0 duplicated keys for all 7 keys [E01 8]; rows as in block 3.
-- -----------------------------------------------------------------------------
WITH duplicated_keys AS (   -- one row per key value that occurs more than once
            SELECT 1 AS ORD FROM STG_CAMPAIGNS   GROUP BY CAMPAIGN_ID              HAVING COUNT(*) > 1
  UNION ALL SELECT 2        FROM STG_CAMPAIGNS   GROUP BY CAMPAIGN_NAME            HAVING COUNT(*) > 1
  UNION ALL SELECT 3        FROM STG_DAILY_SPEND GROUP BY SPEND_ID                 HAVING COUNT(*) > 1
  UNION ALL SELECT 4        FROM STG_DAILY_SPEND GROUP BY CAMPAIGN_ID, SPEND_DATE  HAVING COUNT(*) > 1
  UNION ALL SELECT 5        FROM STG_LEADS       GROUP BY LEAD_ID                  HAVING COUNT(*) > 1
  UNION ALL SELECT 6        FROM STG_CONVERSIONS GROUP BY CONVERSION_ID            HAVING COUNT(*) > 1
  UNION ALL SELECT 7        FROM STG_CONVERSIONS GROUP BY LEAD_ID                  HAVING COUNT(*) > 1
),
keys AS (   -- rows and NULL keys per key
            SELECT 1 AS ORD, 'STG_CAMPAIGNS' AS VIEW_NAME, 'CAMPAIGN_ID (primary key)' AS KEY_COLUMNS,
                   COUNT(*) AS ROW_COUNT, COUNT_IF(CAMPAIGN_ID IS NULL) AS NULL_KEYS, 120 AS EXPECTED_ROWS FROM STG_CAMPAIGNS
  UNION ALL SELECT 2, 'STG_CAMPAIGNS', 'CAMPAIGN_NAME (alternate key)',
                   COUNT(*), COUNT_IF(CAMPAIGN_NAME IS NULL), 120 FROM STG_CAMPAIGNS
  UNION ALL SELECT 3, 'STG_DAILY_SPEND', 'SPEND_ID (primary key)',
                   COUNT(*), COUNT_IF(SPEND_ID IS NULL), 11240 FROM STG_DAILY_SPEND
  UNION ALL SELECT 4, 'STG_DAILY_SPEND', 'CAMPAIGN_ID + SPEND_DATE (grain)',
                   COUNT(*), COUNT_IF(CAMPAIGN_ID IS NULL OR SPEND_DATE IS NULL), 11240 FROM STG_DAILY_SPEND
  UNION ALL SELECT 5, 'STG_LEADS', 'LEAD_ID (primary key)',
                   COUNT(*), COUNT_IF(LEAD_ID IS NULL), 261684 FROM STG_LEADS
  UNION ALL SELECT 6, 'STG_CONVERSIONS', 'CONVERSION_ID (primary key)',
                   COUNT(*), COUNT_IF(CONVERSION_ID IS NULL), 39696 FROM STG_CONVERSIONS
  UNION ALL SELECT 7, 'STG_CONVERSIONS', 'LEAD_ID (one conversion per lead)',
                   COUNT(*), COUNT_IF(LEAD_ID IS NULL), 39696 FROM STG_CONVERSIONS
)
SELECT k.VIEW_NAME, k.KEY_COLUMNS, k.ROW_COUNT, k.NULL_KEYS, COUNT(d.ORD) AS DUPLICATED_KEYS, 0 AS EXPECTED,
       IFF(k.ROW_COUNT = k.EXPECTED_ROWS AND k.NULL_KEYS = 0 AND COUNT(d.ORD) = 0, 'PASS', 'FAIL') AS STATUS
FROM keys k
LEFT JOIN duplicated_keys d ON d.ORD = k.ORD
GROUP BY k.ORD, k.VIEW_NAME, k.KEY_COLUMNS, k.ROW_COUNT, k.NULL_KEYS, k.EXPECTED_ROWS
ORDER BY k.ORD;


-- -----------------------------------------------------------------------------
-- 6. Not null: every business column and CAMPAIGN_DAYS, one row per column
--    Question: did any typed value come out NULL?
--    Why: every source column is required ("Nullable: no" in the publisher's data
--      dictionary). In STAGING a NULL means that a blank was found or a value failed its
--      type gate. Block 4 already says no row is flagged; this block names the column.
--    Expected: 0 NULL cells in all 24 columns [E01 10]; rows as in block 3.
-- -----------------------------------------------------------------------------
WITH null_cells AS (
  SELECT 1 AS ORD, 'STG_CAMPAIGNS' AS VIEW_NAME, 120 AS EXPECTED_ROWS, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID, COUNT_IF(CAMPAIGN_NAME IS NULL) AS CAMPAIGN_NAME,
               COUNT_IF(CHANNEL IS NULL) AS CHANNEL, COUNT_IF(OBJECTIVE IS NULL) AS OBJECTIVE,
               COUNT_IF(START_DATE IS NULL) AS START_DATE, COUNT_IF(END_DATE IS NULL) AS END_DATE,
               COUNT_IF(BUDGET IS NULL) AS BUDGET, COUNT_IF(CAMPAIGN_DAYS IS NULL) AS CAMPAIGN_DAYS
        FROM STG_CAMPAIGNS)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE,
                                          BUDGET, CAMPAIGN_DAYS))
  UNION ALL
  SELECT 2, 'STG_DAILY_SPEND', 11240, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(SPEND_ID IS NULL) AS SPEND_ID, COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID,
               COUNT_IF(SPEND_DATE IS NULL) AS SPEND_DATE, COUNT_IF(IMPRESSIONS IS NULL) AS IMPRESSIONS,
               COUNT_IF(CLICKS IS NULL) AS CLICKS, COUNT_IF(SPEND IS NULL) AS SPEND
        FROM STG_DAILY_SPEND)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL
  SELECT 3, 'STG_LEADS', 261684, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(LEAD_ID IS NULL) AS LEAD_ID, COUNT_IF(CAMPAIGN_ID IS NULL) AS CAMPAIGN_ID,
               COUNT_IF(CREATED_DATE IS NULL) AS CREATED_DATE, COUNT_IF(LEAD_SOURCE IS NULL) AS LEAD_SOURCE,
               COUNT_IF(LEAD_SCORE IS NULL) AS LEAD_SCORE
        FROM STG_LEADS)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL
  SELECT 4, 'STG_CONVERSIONS', 39696, ROW_COUNT, COLUMN_NAME, NULL_CELLS
  FROM (SELECT COUNT(*) AS ROW_COUNT,
               COUNT_IF(CONVERSION_ID IS NULL) AS CONVERSION_ID, COUNT_IF(LEAD_ID IS NULL) AS LEAD_ID,
               COUNT_IF(CONVERTED_DATE IS NULL) AS CONVERTED_DATE, COUNT_IF(CONVERSION_TYPE IS NULL) AS CONVERSION_TYPE,
               COUNT_IF(REVENUE IS NULL) AS REVENUE
        FROM STG_CONVERSIONS)
  UNPIVOT (NULL_CELLS FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE))
)
SELECT VIEW_NAME, COLUMN_NAME, ROW_COUNT, NULL_CELLS, 0 AS EXPECTED,
       IFF(ROW_COUNT = EXPECTED_ROWS AND NULL_CELLS = 0, 'PASS', 'FAIL') AS STATUS
FROM null_cells
ORDER BY ORD, COLUMN_NAME;


-- -----------------------------------------------------------------------------
-- 7. Accepted values of the four code columns, with their row counts
--    Question: does each code column hold exactly the accepted values, as often as profiled?
--    Why: these are the dimension members of every dashboard filter. This is the dbt
--      accepted_values test, made stricter by the counts. The FULL OUTER JOIN makes an
--      unexpected value ('Paid_Search', ' trial ', NULL) its own FAIL row.
--    Expected: the 15 values and counts of [E01 11].
-- -----------------------------------------------------------------------------
WITH expected (COLUMN_NAME, DOMAIN_VALUE, EXPECTED_ROWS) AS (
  SELECT * FROM VALUES
    ('STG_CAMPAIGNS.CHANNEL', 'affiliate', 24), ('STG_CAMPAIGNS.CHANNEL', 'display', 24),
    ('STG_CAMPAIGNS.CHANNEL', 'paid_search', 24), ('STG_CAMPAIGNS.CHANNEL', 'paid_social', 24),
    ('STG_CAMPAIGNS.CHANNEL', 'video', 24),
    ('STG_CAMPAIGNS.OBJECTIVE', 'acquisition', 35), ('STG_CAMPAIGNS.OBJECTIVE', 'awareness', 44),
    ('STG_CAMPAIGNS.OBJECTIVE', 'lead_gen', 41),
    ('STG_LEADS.LEAD_SOURCE', 'affiliate', 67849), ('STG_LEADS.LEAD_SOURCE', 'display', 45149),
    ('STG_LEADS.LEAD_SOURCE', 'paid_search', 65268), ('STG_LEADS.LEAD_SOURCE', 'paid_social', 57619),
    ('STG_LEADS.LEAD_SOURCE', 'video', 25799),
    ('STG_CONVERSIONS.CONVERSION_TYPE', 'purchase', 16691), ('STG_CONVERSIONS.CONVERSION_TYPE', 'trial', 23005)
),
actual AS (
            SELECT 'STG_CAMPAIGNS.CHANNEL' AS COLUMN_NAME, CHANNEL AS DOMAIN_VALUE, COUNT(*) AS ROW_COUNT
            FROM STG_CAMPAIGNS GROUP BY CHANNEL
  UNION ALL SELECT 'STG_CAMPAIGNS.OBJECTIVE', OBJECTIVE, COUNT(*) FROM STG_CAMPAIGNS GROUP BY OBJECTIVE
  UNION ALL SELECT 'STG_LEADS.LEAD_SOURCE', LEAD_SOURCE, COUNT(*) FROM STG_LEADS GROUP BY LEAD_SOURCE
  UNION ALL SELECT 'STG_CONVERSIONS.CONVERSION_TYPE', CONVERSION_TYPE, COUNT(*) FROM STG_CONVERSIONS GROUP BY CONVERSION_TYPE
)
SELECT COALESCE(a.COLUMN_NAME, e.COLUMN_NAME) AS COLUMN_NAME,
       COALESCE(a.DOMAIN_VALUE, e.DOMAIN_VALUE, 'NULL') AS DOMAIN_VALUE,
       a.ROW_COUNT, e.EXPECTED_ROWS,
       IFF(a.ROW_COUNT = e.EXPECTED_ROWS, 'PASS', 'FAIL') AS STATUS
FROM actual a
FULL OUTER JOIN expected e ON e.COLUMN_NAME = a.COLUMN_NAME AND e.DOMAIN_VALUE = a.DOMAIN_VALUE
ORDER BY DECODE(SPLIT_PART(COALESCE(a.COLUMN_NAME, e.COLUMN_NAME), '.', 1), 'STG_CAMPAIGNS', 1, 'STG_LEADS', 2, 3),
         1, 2;


-- -----------------------------------------------------------------------------
-- 8. Relationships (NOT EXISTS), in both directions
--    Question: does every foreign key find its parent, and does every campaign have children
--      in every fact view?
--    Why: Snowflake does not enforce FOREIGN KEY. An orphan silently disappears from an INNER
--      JOIN (spend or revenue lost) and becomes an "unknown" member after a LEFT JOIN. NOT
--      EXISTS stays correct when a key is NULL, unlike NOT IN. Unconverted leads are the one
--      expected non-zero: lead-level models must LEFT JOIN conversions.
--    Expected: 0 orphans in all six directions; 221,988 leads without a conversion [E01 19].
-- -----------------------------------------------------------------------------
SELECT RELATIONSHIP, ORPHAN_ROWS, EXPECTED, IFF(ORPHAN_ROWS = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'STG_DAILY_SPEND.CAMPAIGN_ID -> STG_CAMPAIGNS' AS RELATIONSHIP, COUNT(*) AS ORPHAN_ROWS, 0 AS EXPECTED
            FROM STG_DAILY_SPEND d
            WHERE NOT EXISTS (SELECT 1 FROM STG_CAMPAIGNS c WHERE c.CAMPAIGN_ID = d.CAMPAIGN_ID)
  UNION ALL SELECT 2, 'STG_LEADS.CAMPAIGN_ID -> STG_CAMPAIGNS', COUNT(*), 0
            FROM STG_LEADS l
            WHERE NOT EXISTS (SELECT 1 FROM STG_CAMPAIGNS c WHERE c.CAMPAIGN_ID = l.CAMPAIGN_ID)
  UNION ALL SELECT 3, 'STG_CONVERSIONS.LEAD_ID -> STG_LEADS', COUNT(*), 0
            FROM STG_CONVERSIONS v
            WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS l WHERE l.LEAD_ID = v.LEAD_ID)
  UNION ALL SELECT 4, 'STG_CAMPAIGNS without STG_DAILY_SPEND rows', COUNT(*), 0
            FROM STG_CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM STG_DAILY_SPEND d WHERE d.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 5, 'STG_CAMPAIGNS without STG_LEADS', COUNT(*), 0
            FROM STG_CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS l WHERE l.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 6, 'STG_CAMPAIGNS without STG_CONVERSIONS', COUNT(*), 0
            FROM STG_CAMPAIGNS c
            WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS l JOIN STG_CONVERSIONS v ON v.LEAD_ID = l.LEAD_ID
                              WHERE l.CAMPAIGN_ID = c.CAMPAIGN_ID)
  UNION ALL SELECT 7, 'STG_LEADS without a conversion (expected)', COUNT(*), 221988
            FROM STG_LEADS l
            WHERE NOT EXISTS (SELECT 1 FROM STG_CONVERSIONS v WHERE v.LEAD_ID = l.LEAD_ID)
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 9. The 10 Phase 2 business rules, on the typed columns
--    Question: is any well-typed value impossible for the business?
--    Why: these become dbt expression tests, and they decide which NULLIF(denominator, 0)
--      guards MART needs. The two cross-table rules are evaluated at the right grain:
--        rule 9  spend is summed per campaign FIRST (GROUP BY campaign), then compared with
--                the budget. The join is many spend rows to one campaign, and BUDGET is a
--                GROUP BY key, never summed. SUM(c.BUDGET) in this query would be the grain
--                trap: the budget counted once per spend day.
--        rule 10 leads are counted per (campaign, day) FIRST, then joined 1:1 to the day's
--                spend row. Joining raw lead rows to spend rows would compare fanned-out totals.
--      ROWS_EVALUATED counts only the rows whose inputs are all not NULL, so a rule cannot
--      pass on nothing: a NULL comparison is neither a violation nor an evaluated row. Rule 9
--      evaluates a campaign only when its budget is not NULL and none of its spend rows is
--      NULL (a partial sum would understate spend). Rule 10 evaluates a campaign-day only
--      when its clicks are not NULL (its lead count comes from COUNT(*)). 11,233 campaign-days
--      have leads: 11,240 spend rows minus the 7 with zero leads [E01 23], and no lead falls
--      on a day without a spend row.
--    Expected: 0 violations for all 10 rules [E01 17]; rows evaluated as listed [E01 5, 11, 23].
-- -----------------------------------------------------------------------------
WITH campaign_spend AS (   -- campaign grain: each campaign's budget next to its summed spend
  SELECT c.CAMPAIGN_ID, c.BUDGET, SUM(s.SPEND) AS SPEND, COUNT_IF(s.SPEND IS NULL) AS NULL_SPEND_ROWS
  FROM STG_CAMPAIGNS c
  JOIN STG_DAILY_SPEND s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID   -- many spend rows -> one campaign
  GROUP BY c.CAMPAIGN_ID, c.BUDGET                          -- budget grouped, never summed
),
leads_per_campaign_day AS (   -- leads aggregated to the daily_spend grain FIRST
  SELECT CAMPAIGN_ID, CREATED_DATE, COUNT(*) AS LEADS
  FROM STG_LEADS
  GROUP BY CAMPAIGN_ID, CREATED_DATE
),
rules AS (
            SELECT 1 AS ORD, 'STG_DAILY_SPEND' AS VIEW_NAME, 'clicks <= impressions' AS RULE_NAME,
                   COUNT_IF(CLICKS IS NOT NULL AND IMPRESSIONS IS NOT NULL) AS ROWS_EVALUATED,
                   COUNT_IF(CLICKS > IMPRESSIONS) AS VIOLATIONS, 11240 AS EXPECTED_EVALUATED
            FROM STG_DAILY_SPEND
  UNION ALL SELECT 2, 'STG_DAILY_SPEND', 'impressions > 0', COUNT(IMPRESSIONS), COUNT_IF(IMPRESSIONS <= 0), 11240 FROM STG_DAILY_SPEND
  UNION ALL SELECT 3, 'STG_DAILY_SPEND', 'clicks > 0',      COUNT(CLICKS),      COUNT_IF(CLICKS <= 0),      11240 FROM STG_DAILY_SPEND
  UNION ALL SELECT 4, 'STG_DAILY_SPEND', 'spend > 0',       COUNT(SPEND),       COUNT_IF(SPEND <= 0),       11240 FROM STG_DAILY_SPEND
  UNION ALL SELECT 5, 'STG_CAMPAIGNS',   'budget > 0',      COUNT(BUDGET),      COUNT_IF(BUDGET <= 0),      120   FROM STG_CAMPAIGNS
  UNION ALL SELECT 6, 'STG_LEADS', 'lead_score between 1 and 100',
                   COUNT(LEAD_SCORE), COUNT_IF(LEAD_SCORE NOT BETWEEN 1 AND 100), 261684 FROM STG_LEADS
  UNION ALL SELECT 7, 'STG_CONVERSIONS', 'trial => revenue = 0.00',
                   COUNT_IF(CONVERSION_TYPE = 'trial' AND REVENUE IS NOT NULL),
                   COUNT_IF(CONVERSION_TYPE = 'trial' AND REVENUE <> 0), 23005 FROM STG_CONVERSIONS
  UNION ALL SELECT 8, 'STG_CONVERSIONS', 'purchase => revenue > 0',
                   COUNT_IF(CONVERSION_TYPE = 'purchase' AND REVENUE IS NOT NULL),
                   COUNT_IF(CONVERSION_TYPE = 'purchase' AND REVENUE <= 0), 16691 FROM STG_CONVERSIONS
  UNION ALL SELECT 9, 'STG_CAMPAIGNS', 'total spend <= budget (campaign grain)',
                   COUNT_IF(BUDGET IS NOT NULL AND NULL_SPEND_ROWS = 0), COUNT_IF(SPEND > BUDGET), 120
            FROM campaign_spend
  UNION ALL SELECT 10, 'STG_DAILY_SPEND', 'leads <= clicks (campaign x date grain)',
                   COUNT_IF(s.CLICKS IS NOT NULL), COUNT_IF(l.LEADS > s.CLICKS), 11233
            FROM leads_per_campaign_day l
            JOIN STG_DAILY_SPEND s ON s.CAMPAIGN_ID = l.CAMPAIGN_ID AND s.SPEND_DATE = l.CREATED_DATE   -- 1:1 now
)
SELECT VIEW_NAME, RULE_NAME, ROWS_EVALUATED, EXPECTED_EVALUATED, VIOLATIONS, 0 AS EXPECTED,
       IFF(ROWS_EVALUATED = EXPECTED_EVALUATED AND VIOLATIONS = 0, 'PASS', 'FAIL') AS STATUS
FROM rules
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 10. Typed dates: coverage of every date column
--    Question: did the date conversion keep every date, with nothing shifted or lost?
--    Why: a wrong format mask (MM/DD swapped, a two-digit year) still produces dates, but
--      different ones. Matching min, max, distinct dates and the rows per year of the Phase 2
--      profile proves the TO_DATE routing end to end. SPAN_DAYS = DATEDIFF + 1.
--    Expected: the 5 rows of [E01 22]; 0 dates outside the documented 2023-01-01..2025-12-31.
-- -----------------------------------------------------------------------------
WITH dates AS (
            SELECT 1 AS ORD, 'STG_CAMPAIGNS.START_DATE' AS DATE_COLUMN, START_DATE AS D FROM STG_CAMPAIGNS
  UNION ALL SELECT 2, 'STG_CAMPAIGNS.END_DATE',         END_DATE       FROM STG_CAMPAIGNS
  UNION ALL SELECT 3, 'STG_DAILY_SPEND.SPEND_DATE',     SPEND_DATE     FROM STG_DAILY_SPEND
  UNION ALL SELECT 4, 'STG_LEADS.CREATED_DATE',         CREATED_DATE   FROM STG_LEADS
  UNION ALL SELECT 5, 'STG_CONVERSIONS.CONVERTED_DATE', CONVERTED_DATE FROM STG_CONVERSIONS
),
coverage AS (
  SELECT ORD, DATE_COLUMN, MIN(D) AS MIN_DATE, MAX(D) AS MAX_DATE, COUNT(DISTINCT D) AS DISTINCT_DATES,
         DATEDIFF('day', MIN(D), MAX(D)) + 1 AS SPAN_DAYS,
         COUNT_IF(YEAR(D) = 2023) AS ROWS_2023, COUNT_IF(YEAR(D) = 2024) AS ROWS_2024, COUNT_IF(YEAR(D) = 2025) AS ROWS_2025,
         COUNT_IF(D NOT BETWEEN '2023-01-01'::DATE AND '2025-12-31'::DATE OR D IS NULL) AS OUTSIDE_COVERAGE
  FROM dates
  GROUP BY ORD, DATE_COLUMN
),
expected (DATE_COLUMN, MIN_DATE, MAX_DATE, DISTINCT_DATES, SPAN_DAYS, ROWS_2023, ROWS_2024, ROWS_2025) AS (
  SELECT * FROM VALUES
    ('STG_CAMPAIGNS.START_DATE',       '2023-01-04'::DATE, '2025-08-28'::DATE,  110,  968,    48,     50,    22),
    ('STG_CAMPAIGNS.END_DATE',         '2023-03-14'::DATE, '2025-12-02'::DATE,  116,  995,    38,     47,    35),
    ('STG_DAILY_SPEND.SPEND_DATE',     '2023-01-04'::DATE, '2025-12-02'::DATE, 1064, 1064,  3848,   4405,  2987),
    ('STG_LEADS.CREATED_DATE',         '2023-01-04'::DATE, '2025-12-02'::DATE, 1064, 1064, 87549, 107371, 66764),
    ('STG_CONVERSIONS.CONVERTED_DATE', '2023-01-05'::DATE, '2025-12-21'::DATE, 1080, 1082, 12779,  16148, 10769)
)
SELECT COALESCE(c.DATE_COLUMN, e.DATE_COLUMN) AS DATE_COLUMN, c.MIN_DATE, c.MAX_DATE, c.DISTINCT_DATES, c.SPAN_DAYS,
       c.ROWS_2023, c.ROWS_2024, c.ROWS_2025, c.OUTSIDE_COVERAGE,
       IFF(c.MIN_DATE = e.MIN_DATE AND c.MAX_DATE = e.MAX_DATE AND c.DISTINCT_DATES = e.DISTINCT_DATES
           AND c.SPAN_DAYS = e.SPAN_DAYS AND c.ROWS_2023 = e.ROWS_2023 AND c.ROWS_2024 = e.ROWS_2024
           AND c.ROWS_2025 = e.ROWS_2025 AND c.OUTSIDE_COVERAGE = 0, 'PASS', 'FAIL') AS STATUS
FROM coverage c
FULL OUTER JOIN expected e ON e.DATE_COLUMN = c.DATE_COLUMN
ORDER BY c.ORD;


-- -----------------------------------------------------------------------------
-- 11. Campaign windows and CAMPAIGN_DAYS: the time logic MART builds on
--    Question: does the derived CAMPAIGN_DAYS describe each campaign's spend rows exactly, and
--      do leads and conversions sit where Phase 2 found them relative to the window?
--    Why: MART uses CAMPAIGN_DAYS to prorate budget across months, and a date spine that runs
--      to END_DATE + 21. CAMPAIGN_DAYS is correct only if every campaign has exactly one spend
--      row per window day (checked by GROUP BY ... HAVING). The 4,716 conversions after
--      the end date are the reason the spine extends past END_DATE.
--    Expected [E01 23, 24]: 0 / 11,240 / 46 / 150 / 0 / 0 / 0 / 0 / 7 / 0 / 0 / 4,716.
-- -----------------------------------------------------------------------------
WITH spend_vs_window AS (   -- campaigns whose spend rows do not cover their window exactly once
  SELECT c.CAMPAIGN_ID
  FROM STG_CAMPAIGNS c
  LEFT JOIN STG_DAILY_SPEND s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
  GROUP BY c.CAMPAIGN_ID, c.CAMPAIGN_DAYS
  HAVING COUNT(s.SPEND_ID) <> c.CAMPAIGN_DAYS OR COUNT(DISTINCT s.SPEND_DATE) <> c.CAMPAIGN_DAYS
),
conversion_lag AS (   -- conversions with their lead's date and campaign window (each join is n:1)
  SELECT v.CONVERTED_DATE, l.CREATED_DATE, c.END_DATE
  FROM STG_CONVERSIONS v
  JOIN STG_LEADS l     ON l.LEAD_ID = v.LEAD_ID
  JOIN STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
)
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'campaigns with END_DATE < START_DATE' AS CHECK_NAME,
                   (SELECT COUNT_IF(END_DATE < START_DATE) FROM STG_CAMPAIGNS) AS ACTUAL, 0 AS EXPECTED
  UNION ALL SELECT 2, 'SUM(CAMPAIGN_DAYS) = window days, all campaigns', (SELECT SUM(CAMPAIGN_DAYS) FROM STG_CAMPAIGNS), 11240
  UNION ALL SELECT 3, 'shortest CAMPAIGN_DAYS', (SELECT MIN(CAMPAIGN_DAYS) FROM STG_CAMPAIGNS), 46
  UNION ALL SELECT 4, 'longest CAMPAIGN_DAYS',  (SELECT MAX(CAMPAIGN_DAYS) FROM STG_CAMPAIGNS), 150
  UNION ALL SELECT 5, 'campaigns: spend rows <> CAMPAIGN_DAYS', (SELECT COUNT(*) FROM spend_vs_window), 0
  UNION ALL SELECT 6, 'spend rows outside the campaign window',
                   (SELECT COUNT(*) FROM STG_DAILY_SPEND s JOIN STG_CAMPAIGNS c ON c.CAMPAIGN_ID = s.CAMPAIGN_ID
                    WHERE s.SPEND_DATE NOT BETWEEN c.START_DATE AND c.END_DATE), 0
  UNION ALL SELECT 7, 'leads outside the campaign window',
                   (SELECT COUNT(*) FROM STG_LEADS l JOIN STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
                    WHERE l.CREATED_DATE NOT BETWEEN c.START_DATE AND c.END_DATE), 0
  UNION ALL SELECT 8, 'leads on a day without a spend row',
                   (SELECT COUNT(*) FROM STG_LEADS l
                    WHERE NOT EXISTS (SELECT 1 FROM STG_DAILY_SPEND s
                                      WHERE s.CAMPAIGN_ID = l.CAMPAIGN_ID AND s.SPEND_DATE = l.CREATED_DATE)), 0
  UNION ALL SELECT 9, 'spend rows with zero leads',
                   (SELECT COUNT(*) FROM STG_DAILY_SPEND s
                    WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS l
                                      WHERE l.CAMPAIGN_ID = s.CAMPAIGN_ID AND l.CREATED_DATE = s.SPEND_DATE)), 7
  UNION ALL SELECT 10, 'conversions before their lead',
                   (SELECT COUNT_IF(CONVERTED_DATE < CREATED_DATE) FROM conversion_lag), 0
  UNION ALL SELECT 11, 'conversions > 21 days after their lead',
                   (SELECT COUNT_IF(DATEDIFF('day', CREATED_DATE, CONVERTED_DATE) > 21) FROM conversion_lag), 0
  UNION ALL SELECT 12, 'conversions after the campaign END_DATE',
                   (SELECT COUNT_IF(CONVERTED_DATE > END_DATE) FROM conversion_lag), 4716
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 12. Exact control totals on the typed columns
--    Question: do the typed measures add up to the Phase 2 totals, to the cent?
--    Why: this is the end-to-end proof that the casts (NUMBER(12,2), NUMBER(38,0),
--      NUMBER(3,0)) lost or rounded nothing. Each fact is summed on its own, with no join,
--      so no grain can inflate it. MART must reproduce the same spend (4,523,050.02) and
--      revenue (21,561,839.01) in every table that carries them.
--    Expected: budget 5,418,642.16, spend 4,523,050.02, impressions 436,844,819, clicks
--      7,102,319 [P3; E01 27, 31]; lead_score sum 13,233,637 [P1]; revenue 21,561,839.01,
--      purchases 16,691, trials 23,005 [P3; E01 11, 31].
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'STG_CAMPAIGNS: SUM(BUDGET)' AS CHECK_NAME, (SELECT SUM(BUDGET) FROM STG_CAMPAIGNS) AS ACTUAL,
                   5418642.16 AS EXPECTED
  UNION ALL SELECT 2, 'STG_DAILY_SPEND: SUM(SPEND)',       (SELECT SUM(SPEND) FROM STG_DAILY_SPEND),       4523050.02
  UNION ALL SELECT 3, 'STG_DAILY_SPEND: SUM(IMPRESSIONS)', (SELECT SUM(IMPRESSIONS) FROM STG_DAILY_SPEND), 436844819
  UNION ALL SELECT 4, 'STG_DAILY_SPEND: SUM(CLICKS)',      (SELECT SUM(CLICKS) FROM STG_DAILY_SPEND),      7102319
  UNION ALL SELECT 5, 'STG_LEADS: SUM(LEAD_SCORE)',        (SELECT SUM(LEAD_SCORE) FROM STG_LEADS),        13233637
  UNION ALL SELECT 6, 'STG_CONVERSIONS: SUM(REVENUE)',     (SELECT SUM(REVENUE) FROM STG_CONVERSIONS),     21561839.01
  UNION ALL SELECT 7, 'STG_CONVERSIONS: purchases',
                   (SELECT COUNT_IF(CONVERSION_TYPE = 'purchase') FROM STG_CONVERSIONS), 16691
  UNION ALL SELECT 8, 'STG_CONVERSIONS: trials',
                   (SELECT COUNT_IF(CONVERSION_TYPE = 'trial') FROM STG_CONVERSIONS), 23005
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 13. Grain-safe channel summary: aggregate every fact to the campaign FIRST, then join
--    Question: do the typed views reproduce the funnel bases per channel when they are
--      combined the way MART will combine them?
--    Why: this is the project's most important rule, applied to STAGING. Spend, impressions
--      and clicks are summed per campaign, leads are counted per campaign, and conversions
--      are counted and summed per campaign (via their lead: a 1:1 join, LEAD_ID being unique
--      on both sides). Only then are the three campaign-grain results joined to
--      STG_CAMPAIGNS. Every join is 1:1, so spend cannot be counted twice. A row-level join
--      of spend to leads would give 11.3 billion instead of 4.5 million (docs/data_profile.md,
--      "The grain trap").
--    Expected: the 6 rows of [E01 31] = [P3]; spend and revenue per channel also equal the
--      publisher's reference output [PUB].
-- -----------------------------------------------------------------------------
WITH spend_by_campaign AS (          -- STG_DAILY_SPEND -> one row per campaign
  SELECT CAMPAIGN_ID, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS
  FROM STG_DAILY_SPEND GROUP BY CAMPAIGN_ID
),
leads_by_campaign AS (              -- STG_LEADS -> one row per campaign
  SELECT CAMPAIGN_ID, COUNT(*) AS LEADS FROM STG_LEADS GROUP BY CAMPAIGN_ID
),
conversions_by_campaign AS (        -- STG_CONVERSIONS -> one row per campaign (via its lead, 1:1)
  SELECT l.CAMPAIGN_ID, COUNT(*) AS CONVERSIONS, COUNT_IF(v.CONVERSION_TYPE = 'purchase') AS PURCHASES,
         SUM(v.REVENUE) AS REVENUE
  FROM STG_CONVERSIONS v JOIN STG_LEADS l ON l.LEAD_ID = v.LEAD_ID
  GROUP BY l.CAMPAIGN_ID
),
campaign_grain AS (                 -- now every input has one row per campaign: the joins are 1:1
  SELECT c.CAMPAIGN_ID, c.CHANNEL, s.SPEND, s.IMPRESSIONS, s.CLICKS, l.LEADS, v.CONVERSIONS, v.PURCHASES, v.REVENUE
  FROM STG_CAMPAIGNS c
  LEFT JOIN spend_by_campaign       s ON s.CAMPAIGN_ID = c.CAMPAIGN_ID
  LEFT JOIN leads_by_campaign       l ON l.CAMPAIGN_ID = c.CAMPAIGN_ID
  LEFT JOIN conversions_by_campaign v ON v.CAMPAIGN_ID = c.CAMPAIGN_ID
),
by_channel AS (
  SELECT IFF(GROUPING(CHANNEL) = 1, 'TOTAL', CHANNEL) AS CHANNEL, GROUPING(CHANNEL) AS IS_TOTAL,
         COUNT(*) AS CAMPAIGNS, SUM(SPEND) AS SPEND, SUM(IMPRESSIONS) AS IMPRESSIONS, SUM(CLICKS) AS CLICKS,
         SUM(LEADS) AS LEADS, SUM(CONVERSIONS) AS CONVERSIONS, SUM(PURCHASES) AS PURCHASES, SUM(REVENUE) AS REVENUE
  FROM campaign_grain
  GROUP BY ROLLUP (CHANNEL)
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
SELECT COALESCE(b.CHANNEL, e.CHANNEL) AS CHANNEL, b.CAMPAIGNS, b.SPEND, b.IMPRESSIONS, b.CLICKS, b.LEADS,
       b.CONVERSIONS, b.PURCHASES, b.REVENUE,
       IFF(b.CAMPAIGNS = e.CAMPAIGNS AND b.SPEND = e.SPEND AND b.IMPRESSIONS = e.IMPRESSIONS AND b.CLICKS = e.CLICKS
           AND b.LEADS = e.LEADS AND b.CONVERSIONS = e.CONVERSIONS AND b.PURCHASES = e.PURCHASES
           AND b.REVENUE = e.REVENUE, 'PASS', 'FAIL') AS STATUS
FROM by_channel b
FULL OUTER JOIN expected e ON e.CHANNEL = b.CHANNEL
ORDER BY b.IS_TOTAL, b.LEADS DESC;


-- -----------------------------------------------------------------------------
-- 14. LEAD_SOURCE vs the campaign's CHANNEL (warning level: STATUS is PASS or WARN, never FAIL)
--    Question: does each lead's source still equal the channel of its campaign?
--    Why: it does today, for every lead, so LEAD_SOURCE carries no extra information and
--      MART takes the channel from STG_CAMPAIGNS only. A mismatch would not break STAGING;
--      it would mean the source system started recording something different, which
--      somebody should look at. Hence WARN. The challenge row shows that the cleaning keeps
--      the equality: ' PAID_SEARCH ' becomes 'paid_search'. The LEFT JOIN counts a lead
--      without a campaign as a mismatch.
--    Expected: 0 mismatches over 261,684 leads [E01 21] and over 2,000 challenge leads [E01b 6b].
-- -----------------------------------------------------------------------------
SELECT SCOPE, LEADS, MISMATCHES, EXPECTED_LEADS, 0 AS EXPECTED_MISMATCHES,
       IFF(LEADS = EXPECTED_LEADS AND MISMATCHES = 0, 'PASS', 'WARN') AS STATUS
FROM (
            SELECT 1 AS ORD, 'clean: STG_LEADS vs STG_CAMPAIGNS' AS SCOPE, COUNT(*) AS LEADS,
                   COUNT_IF(l.LEAD_SOURCE IS DISTINCT FROM c.CHANNEL) AS MISMATCHES, 261684 AS EXPECTED_LEADS
            FROM STG_LEADS l LEFT JOIN STG_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
  UNION ALL SELECT 2, 'challenge: STG_CHALLENGE_LEADS vs STG_CHALLENGE_CAMPAIGNS', COUNT(*),
                   COUNT_IF(l.LEAD_SOURCE IS DISTINCT FROM c.CHANNEL), 2000
            FROM STG_CHALLENGE_LEADS l LEFT JOIN STG_CHALLENGE_CAMPAIGNS c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
)
ORDER BY ORD;


-- =============================================================================
-- B. CLEANING-CHALLENGE STAGING (reconciled with the clean views; never used by MART)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 15. De-duplication: 4 surplus copies collapsed, nothing else lost
--    Question: does each challenge view keep one row per key, with the collapsed copy
--      recorded on the row that was kept?
--    Why: each extract holds one byte-identical copy of its first row [E01b 2a, 2b]. QUALIFY
--      ROW_NUMBER() must remove exactly that copy, and COUNT(*) OVER must leave
--      'row:duplicate_copies=2' on the kept row. The 15 defects sit on 15 distinct rows
--      [E01b 7], so 4 / 3 / 4 / 4 rows are invalid. Daily spend has no casing defect.
--    Expected: RAW 121 / 2,001 / 2,001 / 2,001 -> 120 / 2,000 / 2,000 / 2,000 distinct
--      non-NULL keys [E01b 1a]; 1 collapsed copy and 1 flagged key per view, 4 in total;
--      4 / 3 / 4 / 4 = 15 invalid rows.
-- -----------------------------------------------------------------------------
WITH per_view AS (
            SELECT 1 AS ORD, 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME,
                   (SELECT COUNT(*) FROM RAW.CHALLENGE_CAMPAIGNS) AS RAW_ROWS,
                   COUNT(*) AS STG_ROWS, COUNT(DISTINCT CAMPAIGN_ID) AS DISTINCT_KEYS, COUNT_IF(CAMPAIGN_ID IS NULL) AS NULL_KEYS,
                   COUNT_IF(CONTAINS(ARRAY_TO_STRING(DQ_ISSUES, '|'), 'row:duplicate_copies=')) AS DUPLICATE_KEYS_FLAGGED,
                   COUNT_IF(NOT DQ_IS_VALID) AS INVALID_ROWS,
                   121 AS EXPECTED_RAW, 120 AS EXPECTED_ROWS, 4 AS EXPECTED_INVALID
            FROM STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 2, 'STG_CHALLENGE_DAILY_SPEND', (SELECT COUNT(*) FROM RAW.CHALLENGE_DAILY_SPEND),
                   COUNT(*), COUNT(DISTINCT SPEND_ID), COUNT_IF(SPEND_ID IS NULL),
                   COUNT_IF(CONTAINS(ARRAY_TO_STRING(DQ_ISSUES, '|'), 'row:duplicate_copies=')),
                   COUNT_IF(NOT DQ_IS_VALID), 2001, 2000, 3
            FROM STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 3, 'STG_CHALLENGE_LEADS', (SELECT COUNT(*) FROM RAW.CHALLENGE_LEADS),
                   COUNT(*), COUNT(DISTINCT LEAD_ID), COUNT_IF(LEAD_ID IS NULL),
                   COUNT_IF(CONTAINS(ARRAY_TO_STRING(DQ_ISSUES, '|'), 'row:duplicate_copies=')),
                   COUNT_IF(NOT DQ_IS_VALID), 2001, 2000, 4
            FROM STG_CHALLENGE_LEADS
  UNION ALL SELECT 4, 'STG_CHALLENGE_CONVERSIONS', (SELECT COUNT(*) FROM RAW.CHALLENGE_CONVERSIONS),
                   COUNT(*), COUNT(DISTINCT CONVERSION_ID), COUNT_IF(CONVERSION_ID IS NULL),
                   COUNT_IF(CONTAINS(ARRAY_TO_STRING(DQ_ISSUES, '|'), 'row:duplicate_copies=')),
                   COUNT_IF(NOT DQ_IS_VALID), 2001, 2000, 4
            FROM STG_CHALLENGE_CONVERSIONS
),
with_total AS (
  SELECT ORD, VIEW_NAME, RAW_ROWS, STG_ROWS, DISTINCT_KEYS, NULL_KEYS, RAW_ROWS - STG_ROWS AS COPIES_COLLAPSED,
         DUPLICATE_KEYS_FLAGGED, INVALID_ROWS, EXPECTED_RAW, EXPECTED_ROWS, 1 AS EXPECTED_COLLAPSED, EXPECTED_INVALID
  FROM per_view
  UNION ALL
  SELECT 5, 'TOTAL', SUM(RAW_ROWS), SUM(STG_ROWS), SUM(DISTINCT_KEYS), SUM(NULL_KEYS), SUM(RAW_ROWS - STG_ROWS),
         SUM(DUPLICATE_KEYS_FLAGGED), SUM(INVALID_ROWS), 6124, 6120, 4, 15
  FROM per_view
)
SELECT VIEW_NAME, RAW_ROWS, STG_ROWS, DISTINCT_KEYS, NULL_KEYS, COPIES_COLLAPSED, DUPLICATE_KEYS_FLAGGED,
       INVALID_ROWS, EXPECTED_ROWS, EXPECTED_COLLAPSED, EXPECTED_INVALID,
       IFF(RAW_ROWS = EXPECTED_RAW AND STG_ROWS = EXPECTED_ROWS AND DISTINCT_KEYS = EXPECTED_ROWS AND NULL_KEYS = 0
           AND COPIES_COLLAPSED = EXPECTED_COLLAPSED AND DUPLICATE_KEYS_FLAGGED = EXPECTED_COLLAPSED
           AND INVALID_ROWS = EXPECTED_INVALID, 'PASS', 'FAIL') AS STATUS
FROM with_total
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 16. The 15 defects: located by DQ_ISSUES, each with the value Phase 2 argued for
--    Question: do the issue codes of the challenge views mark exactly the 15 defective cells
--      that Phase 2 found, and does each defective cell hold the right value?
--    Why: this is the cleaning challenge's own test. Phase 2 located the defects with
--      generic rules on the dirty files and argued each resolution from evidence inside them
--      [E01b 3d, 4d, 5b-5d, 7]. Here the codes come from the STAGING rules instead, and must
--      land on the same cells:
--        casing/whitespace  normalised value ('Display 2023 008', 'paid_search', 'trial')
--        slash date         parsed as Y/M/D (2023-05-15, 2023-07-04, 2023-06-17, 2023-07-05)
--        blank              NULL in the column. FILLED_VALUE is the *_FILLED column:
--                           'Affiliate 2024 030' and 2023-07-16, and none for the two
--                           unrecoverable dates
--        duplicate row      whole row ('(row)'), code 'row:duplicate_copies=2'
--      A cell carries one class, and STATUS checks its exact codes too (ISSUES, sorted and
--      joined with '+'). Each casing/whitespace cell has two codes, because each raw value has
--      edge spaces AND the wrong case ('[ DISPLAY 2023 008 ]', '[ PAID_SEARCH ]', '[ TRIAL ]'
--      [E01b 3d]): 'recased+untrimmed'. So a rule change that dropped one of the two codes
--      fails here even though the cell count would not move. Each row is looked up by column
--      name from OBJECT_CONSTRUCT_KEEP_NULL(*), so the same SQL serves all four views. A code
--      outside the four classes (e.g. 'unparseable') becomes its own 'other: ...' class and
--      fails. Column names are the STAGING names (CREATED_DATE, not CREATED_AT).
--    Expected: the 15 defect rows numbered as in [E01b 7], each with its codes ([C] code names
--      for the defect that [E01b 3d, 7] describes); class totals 4 / 3 / 4 / 4; 15 cells in
--      total, carrying 18 codes (4 + 3 x 2 + 4 + 4).
-- -----------------------------------------------------------------------------
WITH chg_rows AS (   -- every challenge row, plus the row as an OBJECT so a flagged column can be looked up by name
            SELECT 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME, CAMPAIGN_ID AS KEY_VALUE, DQ_ISSUES,
                   OBJECT_CONSTRUCT_KEEP_NULL(*) AS ROW_OBJ FROM STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'STG_CHALLENGE_DAILY_SPEND', SPEND_ID, DQ_ISSUES, OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'STG_CHALLENGE_LEADS', LEAD_ID, DQ_ISSUES, OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_LEADS
  UNION ALL SELECT 'STG_CHALLENGE_CONVERSIONS', CONVERSION_ID, DQ_ISSUES, OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_CONVERSIONS
),
codes AS (   -- one row per issue code '<column>:<issue>'
  SELECT r.VIEW_NAME, r.KEY_VALUE, SPLIT_PART(f.VALUE::STRING, ':', 2) AS ISSUE,
         IFF(SPLIT_PART(f.VALUE::STRING, ':', 1) = 'row', '(row)', UPPER(SPLIT_PART(f.VALUE::STRING, ':', 1))) AS COLUMN_NAME,
         GET(r.ROW_OBJ, COLUMN_NAME)::STRING              AS STG_VALUE,
         GET(r.ROW_OBJ, COLUMN_NAME || '_FILLED')::STRING AS FILLED_VALUE
  FROM chg_rows r, LATERAL FLATTEN(INPUT => r.DQ_ISSUES) f
),
cells AS (   -- one row per flagged cell and class
  SELECT VIEW_NAME, KEY_VALUE, COLUMN_NAME,
         CASE WHEN ISSUE = 'missing'                       THEN 'blank required value'
              WHEN ISSUE IN ('untrimmed', 'recased')       THEN 'casing/whitespace'
              WHEN ISSUE = 'slash_ymd'                     THEN 'slash date (year first)'
              WHEN STARTSWITH(ISSUE, 'duplicate_copies=')  THEN 'duplicate row'
              ELSE 'other: ' || ISSUE
         END AS DEFECT_CLASS,
         LISTAGG(ISSUE, '+') WITHIN GROUP (ORDER BY ISSUE) AS ISSUES,
         ANY_VALUE(STG_VALUE) AS STG_VALUE,
         IFF(DEFECT_CLASS = 'blank required value', ANY_VALUE(FILLED_VALUE), NULL) AS FILLED_VALUE
  FROM codes
  GROUP BY VIEW_NAME, KEY_VALUE, COLUMN_NAME, DEFECT_CLASS
),
expected (DEFECT_NO, VIEW_NAME, KEY_VALUE, COLUMN_NAME, DEFECT_CLASS, EXPECTED_ISSUES, EXPECTED_VALUE, EXPECTED_FILLED) AS (   -- [E01b 3d, 7]
  SELECT * FROM VALUES
    ( 1, 'STG_CHALLENGE_CAMPAIGNS',   'CMP0001',    '(row)',           'duplicate row',           'duplicate_copies=2', NULL::VARCHAR,      NULL::VARCHAR),
    ( 2, 'STG_CHALLENGE_DAILY_SPEND', 'DSP0000001', '(row)',           'duplicate row',           'duplicate_copies=2', NULL,               NULL),
    ( 3, 'STG_CHALLENGE_LEADS',       'L00000001',  '(row)',           'duplicate row',           'duplicate_copies=2', NULL,               NULL),
    ( 4, 'STG_CHALLENGE_CONVERSIONS', 'CV0000001',  '(row)',           'duplicate row',           'duplicate_copies=2', NULL,               NULL),
    ( 5, 'STG_CHALLENGE_CAMPAIGNS',   'CMP0008',    'CAMPAIGN_NAME',   'casing/whitespace',       'recased+untrimmed',  'Display 2023 008', NULL),
    ( 6, 'STG_CHALLENGE_LEADS',       'L00000008',  'LEAD_SOURCE',     'casing/whitespace',       'recased+untrimmed',  'paid_search',      NULL),
    ( 7, 'STG_CHALLENGE_CONVERSIONS', 'CV0000008',  'CONVERSION_TYPE', 'casing/whitespace',       'recased+untrimmed',  'trial',            NULL),
    ( 8, 'STG_CHALLENGE_CAMPAIGNS',   'CMP0018',    'START_DATE',      'slash date (year first)', 'slash_ymd',          '2023-05-15',       NULL),
    ( 9, 'STG_CHALLENGE_DAILY_SPEND', 'DSP0000018', 'SPEND_DATE',      'slash date (year first)', 'slash_ymd',          '2023-07-04',       NULL),
    (10, 'STG_CHALLENGE_LEADS',       'L00000018',  'CREATED_DATE',    'slash date (year first)', 'slash_ymd',          '2023-06-17',       NULL),
    (11, 'STG_CHALLENGE_CONVERSIONS', 'CV0000018',  'CONVERTED_DATE',  'slash date (year first)', 'slash_ymd',          '2023-07-05',       NULL),
    (12, 'STG_CHALLENGE_CAMPAIGNS',   'CMP0030',    'CAMPAIGN_NAME',   'blank required value',    'missing',            NULL,               'Affiliate 2024 030'),
    (13, 'STG_CHALLENGE_DAILY_SPEND', 'DSP0000030', 'SPEND_DATE',      'blank required value',    'missing',            NULL,               '2023-07-16'),
    (14, 'STG_CHALLENGE_LEADS',       'L00000030',  'CREATED_DATE',    'blank required value',    'missing',            NULL,               NULL),
    (15, 'STG_CHALLENGE_CONVERSIONS', 'CV0000030',  'CONVERTED_DATE',  'blank required value',    'missing',            NULL,               NULL)
),
defect_rows AS (
  SELECT e.DEFECT_NO, COALESCE(a.DEFECT_CLASS, e.DEFECT_CLASS) AS DEFECT_CLASS,
         COALESCE(a.VIEW_NAME, e.VIEW_NAME) AS VIEW_NAME, COALESCE(a.KEY_VALUE, e.KEY_VALUE) AS KEY_VALUE,
         COALESCE(a.COLUMN_NAME, e.COLUMN_NAME) AS COLUMN_NAME, a.ISSUES, e.EXPECTED_ISSUES,
         a.STG_VALUE, e.EXPECTED_VALUE, a.FILLED_VALUE, e.EXPECTED_FILLED,
         IFF(a.KEY_VALUE IS NOT NULL AND e.KEY_VALUE IS NOT NULL AND EQUAL_NULL(a.ISSUES, e.EXPECTED_ISSUES)
             AND EQUAL_NULL(a.STG_VALUE, e.EXPECTED_VALUE) AND EQUAL_NULL(a.FILLED_VALUE, e.EXPECTED_FILLED),
             'PASS', 'FAIL') AS STATUS
  FROM cells a
  FULL OUTER JOIN expected e
    ON e.VIEW_NAME = a.VIEW_NAME AND e.KEY_VALUE = a.KEY_VALUE AND e.COLUMN_NAME = a.COLUMN_NAME
   AND e.DEFECT_CLASS = a.DEFECT_CLASS
),
class_totals AS (
  SELECT COALESCE(e.DEFECT_CLASS, a.DEFECT_CLASS) AS DEFECT_CLASS, COALESCE(a.N_CELLS, 0) AS N_CELLS,
         COALESCE(e.EXPECTED, 0) AS EXPECTED
  FROM (SELECT * FROM VALUES ('duplicate row', 4), ('casing/whitespace', 3), ('slash date (year first)', 4),
                             ('blank required value', 4) AS v (DEFECT_CLASS, EXPECTED)) e
  FULL OUTER JOIN (SELECT DEFECT_CLASS, COUNT(*) AS N_CELLS FROM cells GROUP BY DEFECT_CLASS) a
    ON a.DEFECT_CLASS = e.DEFECT_CLASS
)
SELECT ROW_TYPE, DEFECT_NO, DEFECT_CLASS, VIEW_NAME, KEY_VALUE, COLUMN_NAME, ISSUES, EXPECTED_ISSUES, STG_VALUE,
       EXPECTED_VALUE, FILLED_VALUE, EXPECTED_FILLED, N_CELLS, EXPECTED, STATUS
FROM (
            SELECT 1 AS TYPE_ORD, 'defect' AS ROW_TYPE, DEFECT_NO, DEFECT_CLASS, VIEW_NAME, KEY_VALUE, COLUMN_NAME, ISSUES,
                   EXPECTED_ISSUES, STG_VALUE, EXPECTED_VALUE, FILLED_VALUE, EXPECTED_FILLED, NULL::NUMBER AS N_CELLS,
                   NULL::NUMBER AS EXPECTED, STATUS
            FROM defect_rows
  UNION ALL SELECT 2, 'class total', NULL, DEFECT_CLASS, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   N_CELLS, EXPECTED, IFF(N_CELLS = EXPECTED, 'PASS', 'FAIL')
            FROM class_totals
  UNION ALL SELECT 3, 'grand total', NULL, 'all classes: cells', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   (SELECT COUNT(*) FROM cells), 15, IFF((SELECT COUNT(*) FROM cells) = 15, 'PASS', 'FAIL')
  UNION ALL SELECT 4, 'grand total', NULL, 'all classes: codes', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   (SELECT COUNT(*) FROM codes), 18, IFF((SELECT COUNT(*) FROM codes) = 18, 'PASS', 'FAIL')
)
ORDER BY TYPE_ORD, DEFECT_NO NULLS LAST, DECODE(DEFECT_CLASS, 'duplicate row', 1, 'casing/whitespace', 2,
                                                'slash date (year first)', 3, 'blank required value', 4, 5);


-- -----------------------------------------------------------------------------
-- 17. Challenge keys exist in the clean views; relationships inside the challenge track
--    Question: can every challenge row be reconciled with a clean row, and do the challenge
--      foreign keys behave as Phase 2 described?
--    Why: the reconciliation (blocks 18-19) joins on the key, so a challenge key that is
--      missing from the clean view would only show up as a mismatch there. This block names
--      it directly. Each extract is the first N keys of the clean release [E01b 1b]. 1,687
--      challenge conversions point to leads outside the leads extract; that comes from how
--      the extracts were cut, and every one of those leads exists in STG_LEADS [E01b 1c].
--    Expected: 0 / 0 / 0 / 0 keys missing; 0 / 0 orphans; 1,687 by construction; 0.
-- -----------------------------------------------------------------------------
SELECT CHECK_NAME, ACTUAL, EXPECTED, IFF(ACTUAL = EXPECTED, 'PASS', 'FAIL') AS STATUS
FROM (
            SELECT 1 AS ORD, 'STG_CHALLENGE_CAMPAIGNS keys not in STG_CAMPAIGNS' AS CHECK_NAME, COUNT(*) AS ACTUAL, 0 AS EXPECTED
            FROM STG_CHALLENGE_CAMPAIGNS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_CAMPAIGNS c WHERE c.CAMPAIGN_ID = x.CAMPAIGN_ID)
  UNION ALL SELECT 2, 'STG_CHALLENGE_DAILY_SPEND keys not in STG_DAILY_SPEND', COUNT(*), 0
            FROM STG_CHALLENGE_DAILY_SPEND x
            WHERE NOT EXISTS (SELECT 1 FROM STG_DAILY_SPEND c WHERE c.SPEND_ID = x.SPEND_ID)
  UNION ALL SELECT 3, 'STG_CHALLENGE_LEADS keys not in STG_LEADS', COUNT(*), 0
            FROM STG_CHALLENGE_LEADS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS c WHERE c.LEAD_ID = x.LEAD_ID)
  UNION ALL SELECT 4, 'STG_CHALLENGE_CONVERSIONS keys not in STG_CONVERSIONS', COUNT(*), 0
            FROM STG_CHALLENGE_CONVERSIONS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_CONVERSIONS c WHERE c.CONVERSION_ID = x.CONVERSION_ID)
  UNION ALL SELECT 5, 'challenge spend: CAMPAIGN_ID not in challenge campaigns', COUNT(*), 0
            FROM STG_CHALLENGE_DAILY_SPEND x
            WHERE NOT EXISTS (SELECT 1 FROM STG_CHALLENGE_CAMPAIGNS c WHERE c.CAMPAIGN_ID = x.CAMPAIGN_ID)
  UNION ALL SELECT 6, 'challenge leads: CAMPAIGN_ID not in challenge campaigns', COUNT(*), 0
            FROM STG_CHALLENGE_LEADS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_CHALLENGE_CAMPAIGNS c WHERE c.CAMPAIGN_ID = x.CAMPAIGN_ID)
  UNION ALL SELECT 7, 'challenge conversions: LEAD_ID not in challenge leads', COUNT(*), 1687
            FROM STG_CHALLENGE_CONVERSIONS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_CHALLENGE_LEADS l WHERE l.LEAD_ID = x.LEAD_ID)
  UNION ALL SELECT 8, 'challenge conversions: LEAD_ID not in STG_LEADS', COUNT(*), 0
            FROM STG_CHALLENGE_CONVERSIONS x
            WHERE NOT EXISTS (SELECT 1 FROM STG_LEADS l WHERE l.LEAD_ID = x.LEAD_ID)
)
ORDER BY ORD;


-- -----------------------------------------------------------------------------
-- 18. Reconciliation by row: the cleaned challenge rows against the clean views
--    Question: after cleaning, how many challenge rows equal their clean-release row in
--      every contract column?
--    Why: the extracts are dirty copies of the clean release, so a correct set of rules must
--      turn each one back into its clean row. Each row is compared twice, by key and with
--      EQUAL_NULL on every contract column (NULL = NULL counts as equal):
--        'blanks NULL'  the challenge view as it is
--        'with fills'   CAMPAIGN_NAME_FILLED and SPEND_DATE_FILLED in place of the column
--      DQ and lineage columns are not compared: they describe the source, not the data.
--      The FULL OUTER JOIN with the expected per-view results makes a missing view a FAIL.
--    Expected [E01b 8a]: blanks NULL 119 / 1,999 / 1,999 / 1,999 = 6,116 of 6,120; with fills
--      120 / 2,000 / 1,999 / 1,999 = 6,118 of 6,120 (architecture decision 5).
-- -----------------------------------------------------------------------------
WITH chg_campaigns AS (   -- each challenge row twice: blanks NULL, and with the provable fill
            SELECT 'blanks NULL' AS VERSION, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET,
                   CAMPAIGN_DAYS FROM STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'with fills', CAMPAIGN_ID, CAMPAIGN_NAME_FILLED, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET,
                   CAMPAIGN_DAYS FROM STG_CHALLENGE_CAMPAIGNS
),
chg_spend AS (
            SELECT 'blanks NULL' AS VERSION, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND FROM STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'with fills', SPEND_ID, CAMPAIGN_ID, SPEND_DATE_FILLED, IMPRESSIONS, CLICKS, SPEND FROM STG_CHALLENGE_DAILY_SPEND
),
chg_leads AS (   -- no fill column: both versions are the view as it is
            SELECT 'blanks NULL' AS VERSION, LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE FROM STG_CHALLENGE_LEADS
  UNION ALL SELECT 'with fills', LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE FROM STG_CHALLENGE_LEADS
),
chg_conversions AS (
            SELECT 'blanks NULL' AS VERSION, CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
            FROM STG_CHALLENGE_CONVERSIONS
  UNION ALL SELECT 'with fills', CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
            FROM STG_CHALLENGE_CONVERSIONS
),
cells AS (   -- one row per (version, view, key, contract column): EQUAL_NULL against the clean view, unpivoted
  SELECT VERSION, 1 AS ORD, 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME, KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.CAMPAIGN_ID AS KEY_VALUE,
               EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID, EQUAL_NULL(v.CAMPAIGN_NAME, s.CAMPAIGN_NAME) AS CAMPAIGN_NAME,
               EQUAL_NULL(v.CHANNEL, s.CHANNEL) AS CHANNEL, EQUAL_NULL(v.OBJECTIVE, s.OBJECTIVE) AS OBJECTIVE,
               EQUAL_NULL(v.START_DATE, s.START_DATE) AS START_DATE, EQUAL_NULL(v.END_DATE, s.END_DATE) AS END_DATE,
               EQUAL_NULL(v.BUDGET, s.BUDGET) AS BUDGET, EQUAL_NULL(v.CAMPAIGN_DAYS, s.CAMPAIGN_DAYS) AS CAMPAIGN_DAYS
        FROM chg_campaigns v LEFT JOIN STG_CAMPAIGNS s ON s.CAMPAIGN_ID = v.CAMPAIGN_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET, CAMPAIGN_DAYS))
  UNION ALL
  SELECT VERSION, 2, 'STG_CHALLENGE_DAILY_SPEND', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.SPEND_ID AS KEY_VALUE,
               EQUAL_NULL(v.SPEND_ID, s.SPEND_ID) AS SPEND_ID, EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID,
               EQUAL_NULL(v.SPEND_DATE, s.SPEND_DATE) AS SPEND_DATE, EQUAL_NULL(v.IMPRESSIONS, s.IMPRESSIONS) AS IMPRESSIONS,
               EQUAL_NULL(v.CLICKS, s.CLICKS) AS CLICKS, EQUAL_NULL(v.SPEND, s.SPEND) AS SPEND
        FROM chg_spend v LEFT JOIN STG_DAILY_SPEND s ON s.SPEND_ID = v.SPEND_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL
  SELECT VERSION, 3, 'STG_CHALLENGE_LEADS', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.LEAD_ID AS KEY_VALUE,
               EQUAL_NULL(v.LEAD_ID, s.LEAD_ID) AS LEAD_ID, EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID,
               EQUAL_NULL(v.CREATED_DATE, s.CREATED_DATE) AS CREATED_DATE, EQUAL_NULL(v.LEAD_SOURCE, s.LEAD_SOURCE) AS LEAD_SOURCE,
               EQUAL_NULL(v.LEAD_SCORE, s.LEAD_SCORE) AS LEAD_SCORE
        FROM chg_leads v LEFT JOIN STG_LEADS s ON s.LEAD_ID = v.LEAD_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL
  SELECT VERSION, 4, 'STG_CHALLENGE_CONVERSIONS', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.CONVERSION_ID AS KEY_VALUE,
               EQUAL_NULL(v.CONVERSION_ID, s.CONVERSION_ID) AS CONVERSION_ID, EQUAL_NULL(v.LEAD_ID, s.LEAD_ID) AS LEAD_ID,
               EQUAL_NULL(v.CONVERTED_DATE, s.CONVERTED_DATE) AS CONVERTED_DATE,
               EQUAL_NULL(v.CONVERSION_TYPE, s.CONVERSION_TYPE) AS CONVERSION_TYPE, EQUAL_NULL(v.REVENUE, s.REVENUE) AS REVENUE
        FROM chg_conversions v LEFT JOIN STG_CONVERSIONS s ON s.CONVERSION_ID = v.CONVERSION_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE))
),
per_row AS (   -- a row matches when every one of its contract columns matches
  SELECT VERSION, ORD, VIEW_NAME, KEY_VALUE, BOOLAND_AGG(IS_EQUAL) AS ROW_MATCHES
  FROM cells
  GROUP BY VERSION, ORD, VIEW_NAME, KEY_VALUE
),
per_view AS (
  SELECT ORD, VIEW_NAME,
         COUNT_IF(VERSION = 'blanks NULL')                     AS N_ROWS,
         COUNT_IF(VERSION = 'blanks NULL' AND ROW_MATCHES)     AS MATCH_BLANKS_NULL,
         COUNT_IF(VERSION = 'with fills' AND ROW_MATCHES)      AS MATCH_WITH_FILLS,
         COALESCE(LISTAGG(IFF(VERSION = 'blanks NULL' AND NOT ROW_MATCHES, KEY_VALUE, NULL), ', ')
                    WITHIN GROUP (ORDER BY KEY_VALUE), '')     AS NOT_MATCHING_BLANKS_NULL,
         COALESCE(LISTAGG(IFF(VERSION = 'with fills' AND NOT ROW_MATCHES, KEY_VALUE, NULL), ', ')
                    WITHIN GROUP (ORDER BY KEY_VALUE), '')     AS NOT_MATCHING_WITH_FILLS
  FROM per_row
  GROUP BY ORD, VIEW_NAME
),
with_total AS (
  SELECT ORD, VIEW_NAME, N_ROWS, MATCH_BLANKS_NULL, MATCH_WITH_FILLS, NOT_MATCHING_BLANKS_NULL, NOT_MATCHING_WITH_FILLS
  FROM per_view
  UNION ALL
  SELECT 5, 'TOTAL', SUM(N_ROWS), SUM(MATCH_BLANKS_NULL), SUM(MATCH_WITH_FILLS), NULL, NULL FROM per_view
),
expected (VIEW_NAME, EXPECTED_ROWS, EXPECTED_BLANKS_NULL, EXPECTED_WITH_FILLS) AS (   -- [E01b 8a]
  SELECT * FROM VALUES
    ('STG_CHALLENGE_CAMPAIGNS',    120,  119,  120),
    ('STG_CHALLENGE_DAILY_SPEND', 2000, 1999, 2000),
    ('STG_CHALLENGE_LEADS',       2000, 1999, 1999),
    ('STG_CHALLENGE_CONVERSIONS', 2000, 1999, 1999),
    ('TOTAL',                     6120, 6116, 6118)
)
SELECT COALESCE(w.VIEW_NAME, e.VIEW_NAME) AS VIEW_NAME, w.N_ROWS, w.MATCH_BLANKS_NULL, e.EXPECTED_BLANKS_NULL,
       w.NOT_MATCHING_BLANKS_NULL, w.MATCH_WITH_FILLS, e.EXPECTED_WITH_FILLS, w.NOT_MATCHING_WITH_FILLS,
       IFF(w.N_ROWS = e.EXPECTED_ROWS AND w.MATCH_BLANKS_NULL = e.EXPECTED_BLANKS_NULL
           AND w.MATCH_WITH_FILLS = e.EXPECTED_WITH_FILLS, 'PASS', 'FAIL') AS STATUS
FROM with_total w
FULL OUTER JOIN expected e ON e.VIEW_NAME = w.VIEW_NAME
ORDER BY w.ORD;


-- -----------------------------------------------------------------------------
-- 19. Reconciliation by cell: exactly which cells still differ, and why
--    Question: which (key, column) cells differ from the clean views, in either version?
--    Why: block 18 counts rows; this block names the cells. Two blanks are fixed by their
--      provable fill. The 2 residual mismatches must be exactly the two blank dates that no
--      evidence can recover: L00000030.CREATED_DATE (2 candidate dates) and
--      CV0000030.CONVERTED_DATE (22 candidates) [E01b 5c]. Any other differing cell (e.g. a
--      fill that breaks a match) is an unexpected FAIL row. The values are looked up by
--      column name, as in block 16. STATUS also requires that each differing cell was a
--      blank (CHALLENGE_VALUE NULL) and that a residual stays NULL after the fills, so no
--      mismatch is a wrong non-NULL value.
--      The CTEs up to "cells" repeat block 18 exactly.
--    Expected [E01b 8b]: CMP0030.CAMPAIGN_NAME (clean 'Affiliate 2024 030') and
--      DSP0000030.SPEND_DATE (2023-07-16) 'fixed by fill'; L00000030.CREATED_DATE (clean
--      2023-06-18) and CV0000030.CONVERTED_DATE (2023-07-13) 'residual mismatch'; nothing else.
-- -----------------------------------------------------------------------------
WITH chg_campaigns AS (   -- each challenge row twice: blanks NULL, and with the provable fill
            SELECT 'blanks NULL' AS VERSION, CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET,
                   CAMPAIGN_DAYS FROM STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'with fills', CAMPAIGN_ID, CAMPAIGN_NAME_FILLED, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET,
                   CAMPAIGN_DAYS FROM STG_CHALLENGE_CAMPAIGNS
),
chg_spend AS (
            SELECT 'blanks NULL' AS VERSION, SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND FROM STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'with fills', SPEND_ID, CAMPAIGN_ID, SPEND_DATE_FILLED, IMPRESSIONS, CLICKS, SPEND FROM STG_CHALLENGE_DAILY_SPEND
),
chg_leads AS (   -- no fill column: both versions are the view as it is
            SELECT 'blanks NULL' AS VERSION, LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE FROM STG_CHALLENGE_LEADS
  UNION ALL SELECT 'with fills', LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE FROM STG_CHALLENGE_LEADS
),
chg_conversions AS (
            SELECT 'blanks NULL' AS VERSION, CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
            FROM STG_CHALLENGE_CONVERSIONS
  UNION ALL SELECT 'with fills', CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE
            FROM STG_CHALLENGE_CONVERSIONS
),
cells AS (   -- one row per (version, view, key, contract column): EQUAL_NULL against the clean view, unpivoted
  SELECT VERSION, 1 AS ORD, 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME, KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.CAMPAIGN_ID AS KEY_VALUE,
               EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID, EQUAL_NULL(v.CAMPAIGN_NAME, s.CAMPAIGN_NAME) AS CAMPAIGN_NAME,
               EQUAL_NULL(v.CHANNEL, s.CHANNEL) AS CHANNEL, EQUAL_NULL(v.OBJECTIVE, s.OBJECTIVE) AS OBJECTIVE,
               EQUAL_NULL(v.START_DATE, s.START_DATE) AS START_DATE, EQUAL_NULL(v.END_DATE, s.END_DATE) AS END_DATE,
               EQUAL_NULL(v.BUDGET, s.BUDGET) AS BUDGET, EQUAL_NULL(v.CAMPAIGN_DAYS, s.CAMPAIGN_DAYS) AS CAMPAIGN_DAYS
        FROM chg_campaigns v LEFT JOIN STG_CAMPAIGNS s ON s.CAMPAIGN_ID = v.CAMPAIGN_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (CAMPAIGN_ID, CAMPAIGN_NAME, CHANNEL, OBJECTIVE, START_DATE, END_DATE, BUDGET, CAMPAIGN_DAYS))
  UNION ALL
  SELECT VERSION, 2, 'STG_CHALLENGE_DAILY_SPEND', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.SPEND_ID AS KEY_VALUE,
               EQUAL_NULL(v.SPEND_ID, s.SPEND_ID) AS SPEND_ID, EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID,
               EQUAL_NULL(v.SPEND_DATE, s.SPEND_DATE) AS SPEND_DATE, EQUAL_NULL(v.IMPRESSIONS, s.IMPRESSIONS) AS IMPRESSIONS,
               EQUAL_NULL(v.CLICKS, s.CLICKS) AS CLICKS, EQUAL_NULL(v.SPEND, s.SPEND) AS SPEND
        FROM chg_spend v LEFT JOIN STG_DAILY_SPEND s ON s.SPEND_ID = v.SPEND_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (SPEND_ID, CAMPAIGN_ID, SPEND_DATE, IMPRESSIONS, CLICKS, SPEND))
  UNION ALL
  SELECT VERSION, 3, 'STG_CHALLENGE_LEADS', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.LEAD_ID AS KEY_VALUE,
               EQUAL_NULL(v.LEAD_ID, s.LEAD_ID) AS LEAD_ID, EQUAL_NULL(v.CAMPAIGN_ID, s.CAMPAIGN_ID) AS CAMPAIGN_ID,
               EQUAL_NULL(v.CREATED_DATE, s.CREATED_DATE) AS CREATED_DATE, EQUAL_NULL(v.LEAD_SOURCE, s.LEAD_SOURCE) AS LEAD_SOURCE,
               EQUAL_NULL(v.LEAD_SCORE, s.LEAD_SCORE) AS LEAD_SCORE
        FROM chg_leads v LEFT JOIN STG_LEADS s ON s.LEAD_ID = v.LEAD_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (LEAD_ID, CAMPAIGN_ID, CREATED_DATE, LEAD_SOURCE, LEAD_SCORE))
  UNION ALL
  SELECT VERSION, 4, 'STG_CHALLENGE_CONVERSIONS', KEY_VALUE, COLUMN_NAME, IS_EQUAL
  FROM (SELECT v.VERSION, v.CONVERSION_ID AS KEY_VALUE,
               EQUAL_NULL(v.CONVERSION_ID, s.CONVERSION_ID) AS CONVERSION_ID, EQUAL_NULL(v.LEAD_ID, s.LEAD_ID) AS LEAD_ID,
               EQUAL_NULL(v.CONVERTED_DATE, s.CONVERTED_DATE) AS CONVERTED_DATE,
               EQUAL_NULL(v.CONVERSION_TYPE, s.CONVERSION_TYPE) AS CONVERSION_TYPE, EQUAL_NULL(v.REVENUE, s.REVENUE) AS REVENUE
        FROM chg_conversions v LEFT JOIN STG_CONVERSIONS s ON s.CONVERSION_ID = v.CONVERSION_ID)
  UNPIVOT (IS_EQUAL FOR COLUMN_NAME IN (CONVERSION_ID, LEAD_ID, CONVERTED_DATE, CONVERSION_TYPE, REVENUE))
),
per_cell AS (   -- both versions of each cell side by side
  SELECT ORD, VIEW_NAME, KEY_VALUE, COLUMN_NAME,
         BOOLAND_AGG(IFF(VERSION = 'blanks NULL', IS_EQUAL, NULL)) AS EQUAL_BLANKS_NULL,
         BOOLAND_AGG(IFF(VERSION = 'with fills', IS_EQUAL, NULL))  AS EQUAL_WITH_FILLS
  FROM cells
  GROUP BY ORD, VIEW_NAME, KEY_VALUE, COLUMN_NAME
),
mismatches AS (
  SELECT ORD, VIEW_NAME, KEY_VALUE, COLUMN_NAME, EQUAL_BLANKS_NULL, EQUAL_WITH_FILLS,
         CASE WHEN NOT EQUAL_BLANKS_NULL AND EQUAL_WITH_FILLS     THEN 'fixed by fill'
              WHEN NOT EQUAL_BLANKS_NULL AND NOT EQUAL_WITH_FILLS THEN 'residual mismatch'
              ELSE 'broken by fill'
         END AS OUTCOME
  FROM per_cell
  WHERE NOT (EQUAL_BLANKS_NULL AND EQUAL_WITH_FILLS)
),
chg_objects AS (     -- challenge rows as OBJECTs, to show the values of the differing cells
            SELECT 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME, CAMPAIGN_ID AS KEY_VALUE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS OBJ
            FROM STG_CHALLENGE_CAMPAIGNS
  UNION ALL SELECT 'STG_CHALLENGE_DAILY_SPEND', SPEND_ID,      OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_DAILY_SPEND
  UNION ALL SELECT 'STG_CHALLENGE_LEADS',       LEAD_ID,       OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_LEADS
  UNION ALL SELECT 'STG_CHALLENGE_CONVERSIONS', CONVERSION_ID, OBJECT_CONSTRUCT_KEEP_NULL(*) FROM STG_CHALLENGE_CONVERSIONS
),
clean_objects AS (   -- the clean rows with the same keys
            SELECT 'STG_CHALLENGE_CAMPAIGNS' AS VIEW_NAME, CAMPAIGN_ID AS KEY_VALUE, OBJECT_CONSTRUCT_KEEP_NULL(*) AS OBJ
            FROM STG_CAMPAIGNS WHERE CAMPAIGN_ID IN (SELECT KEY_VALUE FROM mismatches)
  UNION ALL SELECT 'STG_CHALLENGE_DAILY_SPEND', SPEND_ID, OBJECT_CONSTRUCT_KEEP_NULL(*)
            FROM STG_DAILY_SPEND WHERE SPEND_ID IN (SELECT KEY_VALUE FROM mismatches)
  UNION ALL SELECT 'STG_CHALLENGE_LEADS', LEAD_ID, OBJECT_CONSTRUCT_KEEP_NULL(*)
            FROM STG_LEADS WHERE LEAD_ID IN (SELECT KEY_VALUE FROM mismatches)
  UNION ALL SELECT 'STG_CHALLENGE_CONVERSIONS', CONVERSION_ID, OBJECT_CONSTRUCT_KEEP_NULL(*)
            FROM STG_CONVERSIONS WHERE CONVERSION_ID IN (SELECT KEY_VALUE FROM mismatches)
),
valued AS (   -- the cell's value as cleaned, after the fills (the *_FILLED column where one exists), and in the clean view
  SELECT m.*,
         GET(co.OBJ, m.COLUMN_NAME)::STRING AS CHALLENGE_VALUE,
         COALESCE(GET(co.OBJ, m.COLUMN_NAME || '_FILLED')::STRING, GET(co.OBJ, m.COLUMN_NAME)::STRING) AS AFTER_FILLS,
         GET(cl.OBJ, m.COLUMN_NAME)::STRING AS CLEAN_VALUE
  FROM mismatches m
  LEFT JOIN chg_objects   co ON co.VIEW_NAME = m.VIEW_NAME AND co.KEY_VALUE = m.KEY_VALUE
  LEFT JOIN clean_objects cl ON cl.VIEW_NAME = m.VIEW_NAME AND cl.KEY_VALUE = m.KEY_VALUE
),
expected (VIEW_NAME, KEY_VALUE, COLUMN_NAME, EXPECTED_OUTCOME, EXPECTED_CLEAN_VALUE) AS (   -- [E01b 8b]
  SELECT * FROM VALUES
    ('STG_CHALLENGE_CAMPAIGNS',   'CMP0030',    'CAMPAIGN_NAME',  'fixed by fill',     'Affiliate 2024 030'),
    ('STG_CHALLENGE_DAILY_SPEND', 'DSP0000030', 'SPEND_DATE',     'fixed by fill',     '2023-07-16'),
    ('STG_CHALLENGE_LEADS',       'L00000030',  'CREATED_DATE',   'residual mismatch', '2023-06-18'),
    ('STG_CHALLENGE_CONVERSIONS', 'CV0000030',  'CONVERTED_DATE', 'residual mismatch', '2023-07-13')
)
SELECT COALESCE(v.VIEW_NAME, e.VIEW_NAME) AS VIEW_NAME, COALESCE(v.KEY_VALUE, e.KEY_VALUE) AS KEY_VALUE,
       COALESCE(v.COLUMN_NAME, e.COLUMN_NAME) AS COLUMN_NAME, v.EQUAL_BLANKS_NULL, v.EQUAL_WITH_FILLS,
       COALESCE(v.CHALLENGE_VALUE, 'NULL') AS CHALLENGE_VALUE, COALESCE(v.AFTER_FILLS, 'NULL') AS AFTER_FILLS,
       v.CLEAN_VALUE, e.EXPECTED_CLEAN_VALUE, v.OUTCOME, e.EXPECTED_OUTCOME,
       IFF(v.OUTCOME = e.EXPECTED_OUTCOME AND v.CLEAN_VALUE = e.EXPECTED_CLEAN_VALUE AND v.CHALLENGE_VALUE IS NULL
           AND (v.OUTCOME = 'fixed by fill' OR v.AFTER_FILLS IS NULL), 'PASS', 'FAIL') AS STATUS
FROM valued v
FULL OUTER JOIN expected e ON e.VIEW_NAME = v.VIEW_NAME AND e.KEY_VALUE = v.KEY_VALUE AND e.COLUMN_NAME = v.COLUMN_NAME
ORDER BY COALESCE(v.ORD, 9), 2;
