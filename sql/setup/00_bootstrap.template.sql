-- =============================================================================
-- MARKETING_CRM: one-time Snowflake bootstrap (Phase 1)
-- -----------------------------------------------------------------------------
-- TEMPLATE. Do not run this file directly: `make bootstrap-sql` renders it into
-- build/snowflake_bootstrap.sql with the two public keys filled in.
--
-- Who runs it: the human admin (the user that holds ACCOUNTADMIN), ONCE, in a
-- Snowsight SQL worksheet: paste the whole rendered file, then "Run All".
-- Safe to re-run: CREATE ... IF NOT EXISTS, ALTER ... SET and GRANT are idempotent,
-- so a second run converges the account to this file instead of failing. That
-- includes the resource monitors: they are created only if missing and then ALTERed
-- in place, so a re-run neither resets their usage count nor lifts a suspension.
--
-- Ownership model (Snowflake access-control best practice):
--   SYSADMIN      owns the warehouse, database and schemas
--   USERADMIN     owns the custom roles and the service users
--   SECURITYADMIN issues the FUTURE grants (they need MANAGE GRANTS)
--   ACCOUNTADMIN  owns the resource monitors (only it can create and assign them)
-- The three custom roles roll up to SYSADMIN, so the admin keeps full visibility.
--
-- Checked against docs.snowflake.com on 2026-10-13 (CREATE/ALTER WAREHOUSE,
-- CREATE USER, GRANT, CREATE RESOURCE MONITOR, key-pair auth, BCR bundles
-- 2026_03 and 2026_06). Nothing here has been executed yet: the first run is
-- the real test (docs/setup_snowflake.md has the troubleshooting notes).
-- =============================================================================


-- =============================================================================
-- 1. Compute and storage (SYSADMIN)
-- =============================================================================
USE ROLE SYSADMIN;

-- X-Small, Gen1, single cluster. Notes on the non-default settings:
--   GENERATION = '1'       Gen2 is the default for new standard warehouses since the
--                          2026_03 bundle, bills a higher credit rate, and turns Query
--                          Acceleration on. Gen1 X-Small = 1 credit per running hour.
--   AUTO_SUSPEND = 60      seconds. Billing is per second with a 60-second minimum per
--                          resume, so a lower value saves nothing.
--   INITIALLY_SUSPENDED    the default (FALSE) starts billing at creation.
--   STATEMENT_TIMEOUT      15 minutes caps any runaway query (nothing in this project
--                          should take more than a minute on X-Small).
CREATE WAREHOUSE IF NOT EXISTS MARKETING_WH WITH
  WAREHOUSE_SIZE = XSMALL
  WAREHOUSE_TYPE = STANDARD
  GENERATION = '1'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Marketing CRM portfolio: RAW loads, dbt builds, Data Studio queries. X-Small Gen1.'
  STATEMENT_TIMEOUT_IN_SECONDS = 900;

-- Re-assert the same settings so a re-run repairs drift (CREATE ... IF NOT EXISTS does
-- nothing when the warehouse exists). INITIALLY_SUSPENDED is create-only. Per the
-- ALTER WAREHOUSE docs, no property change requires a suspended warehouse, and
-- changing these on a suspended warehouse does not resume it.
ALTER WAREHOUSE MARKETING_WH SET
  WAREHOUSE_SIZE = XSMALL
  WAREHOUSE_TYPE = STANDARD
  GENERATION = '1'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  COMMENT = 'Marketing CRM portfolio: RAW loads, dbt builds, Data Studio queries. X-Small Gen1.'
  STATEMENT_TIMEOUT_IN_SECONDS = 900;

-- Query Acceleration (QAS) off. Since the 2026_06 bundle (BCR-2373, enabled by default
-- from release 10.32) QAS is ON by default for ALL new standard warehouses, Gen1
-- included, with max scale factor 8. QAS credits are serverless: resource monitors do
-- not cap them. QAS exists only on Enterprise edition and above, and the docs do not
-- say whether setting it on Standard edition errors or is silently accepted, so the
-- ALTER runs inside a block that reports instead of failing (otherwise "Run All" would
-- stop here if Standard refuses it). Either message is fine; neither proves the edition.
-- The block may need a running warehouse; MARKETING_WH resumes for at most ~1 minute.
USE WAREHOUSE MARKETING_WH;
EXECUTE IMMEDIATE $$
BEGIN
  ALTER WAREHOUSE MARKETING_WH SET ENABLE_QUERY_ACCELERATION = FALSE;
  RETURN 'MARKETING_WH: ENABLE_QUERY_ACCELERATION = FALSE accepted (this message does not reveal the edition)';
EXCEPTION
  WHEN STATEMENT_ERROR THEN
    RETURN 'MARKETING_WH: QAS setting refused, skipped (possible on Standard edition, which has no QAS): ' || SQLERRM;
END;
$$;

CREATE DATABASE IF NOT EXISTS MARKETING_CRM
  COMMENT = 'Marketing CRM & Conversion Funnel Analytics (portfolio). Synthetic data, CC BY 4.0 (Analytics Engineering).';

CREATE SCHEMA IF NOT EXISTS MARKETING_CRM.RAW
  COMMENT = 'Landing zone: lossless all-VARCHAR copies of the source CSVs plus lineage columns. Written only by CRM_LOADER.';
CREATE SCHEMA IF NOT EXISTS MARKETING_CRM.STAGING
  COMMENT = 'Typed, cleaned 1:1 models of RAW (Phase 3 and dbt in Phase 5). Built by CRM_TRANSFORMER.';
CREATE SCHEMA IF NOT EXISTS MARKETING_CRM.MART
  COMMENT = 'Grain-safe facts, dimensions and KPI tables for analysis and Data Studio. Built by CRM_TRANSFORMER, read by CRM_REPORTER.';


-- =============================================================================
-- 2. Custom roles (USERADMIN), rolled up to SYSADMIN
-- =============================================================================
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS CRM_LOADER
  COMMENT = 'Writes RAW: creates RAW tables, stage and file format; PUT + COPY.';
CREATE ROLE IF NOT EXISTS CRM_TRANSFORMER
  COMMENT = 'Reads RAW, builds STAGING and MART (SQL scripts and dbt).';
CREATE ROLE IF NOT EXISTS CRM_REPORTER
  COMMENT = 'Read-only on MART for Google Data Studio. Cannot see RAW or STAGING.';

GRANT ROLE CRM_LOADER      TO ROLE SYSADMIN;
GRANT ROLE CRM_TRANSFORMER TO ROLE SYSADMIN;
GRANT ROLE CRM_REPORTER    TO ROLE SYSADMIN;


-- =============================================================================
-- 3. Object privileges (SYSADMIN owns the objects, so it grants on them)
-- =============================================================================
USE ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE MARKETING_WH TO ROLE CRM_LOADER;
GRANT USAGE ON WAREHOUSE MARKETING_WH TO ROLE CRM_TRANSFORMER;
GRANT USAGE ON WAREHOUSE MARKETING_WH TO ROLE CRM_REPORTER;

GRANT USAGE ON DATABASE MARKETING_CRM TO ROLE CRM_LOADER;
GRANT USAGE ON DATABASE MARKETING_CRM TO ROLE CRM_TRANSFORMER;
GRANT USAGE ON DATABASE MARKETING_CRM TO ROLE CRM_REPORTER;

-- Loader: owns everything it creates in RAW (tables, stage, file format), so it can
-- TRUNCATE and COPY without further grants.
GRANT USAGE, CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT
  ON SCHEMA MARKETING_CRM.RAW TO ROLE CRM_LOADER;

-- Transformer: reads RAW (SELECT comes from the future grants in section 4) and
-- builds STAGING and MART. No CREATE SCHEMA: dbt must write to exactly these schemas
-- (a generate_schema_name override arrives with the dbt project in Phase 5).
GRANT USAGE ON SCHEMA MARKETING_CRM.RAW TO ROLE CRM_TRANSFORMER;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON SCHEMA MARKETING_CRM.STAGING TO ROLE CRM_TRANSFORMER;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON SCHEMA MARKETING_CRM.MART    TO ROLE CRM_TRANSFORMER;

-- Reporter: MART only.
GRANT USAGE ON SCHEMA MARKETING_CRM.MART TO ROLE CRM_REPORTER;


-- =============================================================================
-- 4. Read grants on current AND future objects (SECURITYADMIN)
-- =============================================================================
-- FUTURE grants in a regular (non-managed) schema need the global MANAGE GRANTS
-- privilege, which SECURITYADMIN has and SYSADMIN does not. Schema-level only: if
-- database-level future grants also existed, the schema-level ones would win.
-- Future grants also cover tables re-created with CREATE OR REPLACE (dbt, CTAS).
USE ROLE SECURITYADMIN;

GRANT SELECT ON ALL TABLES    IN SCHEMA MARKETING_CRM.RAW  TO ROLE CRM_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MARKETING_CRM.RAW  TO ROLE CRM_TRANSFORMER;

GRANT SELECT ON ALL TABLES    IN SCHEMA MARKETING_CRM.MART TO ROLE CRM_REPORTER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MARKETING_CRM.MART TO ROLE CRM_REPORTER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA MARKETING_CRM.MART TO ROLE CRM_REPORTER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA MARKETING_CRM.MART TO ROLE CRM_REPORTER;


-- =============================================================================
-- 5. Service users (USERADMIN): TYPE = SERVICE, key-pair only
-- =============================================================================
-- TYPE = SERVICE users cannot have a password, cannot log in to Snowsight and cannot
-- enrol in MFA: they authenticate only with the RSA key pair. Trial accounts are exempt
-- from the single-factor password deprecation, but this setup does not depend on that
-- exemption, so it keeps working if the account is ever converted to paid.
--
-- DEFAULT_ROLE = CRM_LOADER for the pipeline user: the first tools that use it
-- (make sf-check, make load) run as the loader, it matches DEFAULT_NAMESPACE RAW, and
-- every script and the dbt profile set their role explicitly anyway, so the default only
-- matters for an ad-hoc client. CRM_LOADER can only write RAW; a client that forgets
-- its role cannot rebuild STAGING or MART by accident.
-- DEFAULT_SECONDARY_ROLES = (): only the requested role is active in a session (the
-- default since the 2024_08 bundle is ('ALL'), which would merge LOADER and TRANSFORMER
-- privileges into every session).
--
-- Keys use the legacy RSA_PUBLIC_KEY property, not the named key pairs
-- (ALTER USER ... ADD KEY PAIR, July 2026) that the docs now recommend. Named key pairs
-- add ROLE_RESTRICTION and expiry, but with ROLE_RESTRICTION authentication succeeds
-- only if the client puts that role in its JWT, and nobody documents whether the
-- Google Data Studio connector does. RSA_PUBLIC_KEY works with every client.
-- Rotation later: SET RSA_PUBLIC_KEY_2 = '<new>', switch the clients, UNSET RSA_PUBLIC_KEY.
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS SVC_CRM_PIPELINE
  TYPE = SERVICE
  DEFAULT_ROLE = CRM_LOADER
  DEFAULT_WAREHOUSE = MARKETING_WH
  DEFAULT_NAMESPACE = MARKETING_CRM.RAW
  DEFAULT_SECONDARY_ROLES = ()
  COMMENT = 'Pipeline service user: Python loader (CRM_LOADER), dbt Core (CRM_TRANSFORMER). Key-pair only.';

-- ALTER (not CREATE) carries the key, so a re-run with a new key file updates it.
ALTER USER SVC_CRM_PIPELINE SET
  DEFAULT_ROLE = CRM_LOADER
  DEFAULT_WAREHOUSE = MARKETING_WH
  DEFAULT_NAMESPACE = MARKETING_CRM.RAW
  DEFAULT_SECONDARY_ROLES = ()
  RSA_PUBLIC_KEY = '{{PIPELINE_PUBLIC_KEY}}';

CREATE USER IF NOT EXISTS SVC_CRM_BI
  TYPE = SERVICE
  DEFAULT_ROLE = CRM_REPORTER
  DEFAULT_WAREHOUSE = MARKETING_WH
  DEFAULT_NAMESPACE = MARKETING_CRM.MART
  DEFAULT_SECONDARY_ROLES = ()
  COMMENT = 'BI service user for the Google Data Studio Snowflake connector. Reads MART only. Unencrypted key (connector requirement).';

ALTER USER SVC_CRM_BI SET
  DEFAULT_ROLE = CRM_REPORTER
  DEFAULT_WAREHOUSE = MARKETING_WH
  DEFAULT_NAMESPACE = MARKETING_CRM.MART
  DEFAULT_SECONDARY_ROLES = ()
  RSA_PUBLIC_KEY = '{{BI_PUBLIC_KEY}}';

-- DEFAULT_ROLE does not grant anything: the roles must be granted explicitly.
GRANT ROLE CRM_LOADER      TO USER SVC_CRM_PIPELINE;
GRANT ROLE CRM_TRANSFORMER TO USER SVC_CRM_PIPELINE;
GRANT ROLE CRM_REPORTER    TO USER SVC_CRM_BI;

-- Key check: RSA_PUBLIC_KEY_FP must equal 'SHA256:' + the fingerprint that `make keys`
-- and `make bootstrap-sql` printed. The query IDs are kept so the final statement of
-- this file can show both fingerprints in one result row.
DESC USER SVC_CRM_PIPELINE;
SET PIPELINE_DESC_QID = LAST_QUERY_ID();
DESC USER SVC_CRM_BI;
SET BI_DESC_QID = LAST_QUERY_ID();


-- =============================================================================
-- 6. Cost guardrails (ACCOUNTADMIN only: creating AND assigning resource monitors)
-- =============================================================================
-- Budget reasoning: the trial includes $400 of usage. At ~$2-3 per credit (Standard or
-- Enterprise on AWS US East, third-party list prices) that is ~130-200 credits; Snowflake
-- University's FAQ quotes "about $5" per credit, i.e. ~80 credits. This project needs
-- very little: loading ~13 MB of CSV and building models over ~300k rows takes minutes
-- of X-Small time (1 credit per hour on Gen1).
--   RM_MARKETING_WH   20 credits per month on MARKETING_WH (= 20 running hours): even at
--                     $5/credit that is <= $100 a month, and any month that reaches it
--                     means something is wrong. Notify at 50% and 75%, suspend at 90%
--                     (lets running queries finish), suspend immediately at 100%
--                     (suspension is not instant, hence 90%).
--   RM_ACCOUNT_DAILY  4 credits per day across ALL warehouses (also the trial's
--                     SNOWFLAKE_LEARNING_WH / COMPUTE_WH): a backstop that stops a
--                     runaway within one day. Notify at 75%, suspend at 100%.
--                     It started at 2 credits/day and was raised to 4 on 2026-10-14: the
--                     2-credit cap tripped during legitimate parallel build work (Phase 5)
--                     when the whole project had used 2.19 credits on MARKETING_WH and $5
--                     of the $400 balance. MARKETING_WH stays bounded by RM_MARKETING_WH
--                     (20 credits/month), so the daily cap only has to stop a runaway on
--                     the other warehouses. It does not cap serverless features, QAS or
--                     storage (see below).
-- Facts that matter here:
--   * Usage resets at 00:00 UTC (8 PM New York time in summer) whatever START_TIMESTAMP says.
--   * Quotas count cloud-services credits too (even the unbilled part), so a monitor can
--     trip slightly before warehouse runtime alone would suggest.
--   * Monitors cover warehouses only: serverless features, QAS and storage are not capped
--     (QAS is turned off above; storage for this project is a few MB).
--   * Notifications are OFF until each admin verifies an email address and enables
--     resource-monitor notifications in their Snowsight profile. NOTIFY_USERS is omitted:
--     account administrators are notified once they opt in, and an account-level monitor
--     must have NOTIFY_USERS null.
--   * Idempotent on purpose. CREATE OR REPLACE would drop and re-create the monitor: the
--     new object starts a fresh usage count, and dropping a monitor lets any warehouse it
--     had suspended resume. So each monitor is created only if missing, then ALTERed in
--     place: SET CREDIT_QUOTA plus TRIGGERS (TRIGGERS replaces all existing triggers;
--     re-stating a threshold that is already passed can re-send its notification).
--     FREQUENCY and START_TIMESTAMP are deliberately left out of the ALTER so the current
--     period is not restarted; if they ever need to change, do it by hand.
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_MARKETING_WH WITH
  CREDIT_QUOTA = 20
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50 PERCENT DO NOTIFY
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER RESOURCE MONITOR RM_MARKETING_WH
  SET CREDIT_QUOTA = 20
  TRIGGERS
    ON 50 PERCENT DO NOTIFY
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE MARKETING_WH SET RESOURCE_MONITOR = RM_MARKETING_WH;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT_DAILY WITH
  CREDIT_QUOTA = 4
  FREQUENCY = DAILY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER RESOURCE MONITOR RM_ACCOUNT_DAILY
  SET CREDIT_QUOTA = 4
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_DAILY;

-- Trial accounts come with warehouses of their own: SNOWFLAKE_LEARNING_WH (X-Small,
-- owned by ACCOUNTADMIN, created for trials since May 2025) and sometimes COMPUTE_WH.
-- Cap their idle billing too. ALTER WAREHOUSE supports IF EXISTS, so a missing one is
-- skipped. Check SHOW WAREHOUSES for any others the trial created.
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH SET AUTO_SUSPEND = 60;

-- Trial provisioning also grants SNOWFLAKE_LEARNING_ROLE to PUBLIC (seen on the first
-- real run, 2026-10-13: SHOW GRANTS OF ROLE SNOWFLAKE_LEARNING_ROLE -> ROLE PUBLIC).
-- Every user inherits PUBLIC, so both service users could USE ROLE SNOWFLAKE_LEARNING_ROLE
-- and run queries on SNOWFLAKE_LEARNING_WH (Gen2, Query Acceleration on) or create
-- schemas in SNOWFLAKE_LEARNING_DB; `make sf-check-bi` fails on it. Least privilege:
-- grant the role directly to the admin running this file (the trial tutorials keep
-- working), revoke it from PUBLIC, and turn QAS off on SNOWFLAKE_LEARNING_WH (QAS credits
-- are serverless, so the resource monitors do not cap them). An account without the
-- learning environment just reports "skipped".
EXECUTE IMMEDIATE $$
BEGIN
  LET grant_stmt VARCHAR := 'GRANT ROLE SNOWFLAKE_LEARNING_ROLE TO USER "' || REPLACE(CURRENT_USER(), '"', '""') || '"';
  EXECUTE IMMEDIATE :grant_stmt;
  REVOKE ROLE SNOWFLAKE_LEARNING_ROLE FROM ROLE PUBLIC;
  ALTER WAREHOUSE IF EXISTS SNOWFLAKE_LEARNING_WH SET ENABLE_QUERY_ACCELERATION = FALSE;
  RETURN 'SNOWFLAKE_LEARNING_ROLE: granted to ' || CURRENT_USER() || ', revoked from PUBLIC; QAS off on SNOWFLAKE_LEARNING_WH';
EXCEPTION
  WHEN STATEMENT_ERROR THEN
    RETURN 'Trial learning-environment step skipped: ' || SQLERRM;
END;
$$;


-- =============================================================================
-- 7. Result: what goes into .env, and the key check
-- =============================================================================
-- Expect one row: size X-Small, auto_suspend 60, auto_resume true,
-- resource_monitor RM_MARKETING_WH (and a generation / resource_constraint column
-- showing Gen1 / STANDARD_GEN_1 where those columns exist).
SHOW WAREHOUSES LIKE 'MARKETING_WH';

-- "Run All" shows only the LAST result, so this one row has everything to copy:
--   SNOWFLAKE_ACCOUNT  -> .env SNOWFLAKE_ACCOUNT (org-account form, no domain)
--   *_KEY_FP           -> must equal the fingerprints printed by `make keys`
SELECT
  CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS SNOWFLAKE_ACCOUNT,
  (SELECT "value" FROM TABLE(RESULT_SCAN($PIPELINE_DESC_QID))
    WHERE "property" = 'RSA_PUBLIC_KEY_FP') AS SVC_CRM_PIPELINE_KEY_FP,
  (SELECT "value" FROM TABLE(RESULT_SCAN($BI_DESC_QID))
    WHERE "property" = 'RSA_PUBLIC_KEY_FP') AS SVC_CRM_BI_KEY_FP;
