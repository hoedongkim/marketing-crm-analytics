-- =============================================================================
-- MARKETING_CRM.MART.CONNECTION_TEST: tiny table for the Phase 1 Data Studio test
-- -----------------------------------------------------------------------------
-- Run as CRM_TRANSFORMER after `make load`:  make connection-test-table
-- (or paste into a Snowsight worksheet; the USE ROLE below switches role).
--
-- Exists ONLY so the Google Data Studio connector can be tested on day 1
-- (docs/phase1_connection_test.md). It is not part of the data model and will be
-- dropped in Phase 6, when the real MART tables feed the dashboard.
--
-- Grain: one row per CHANNEL x SPEND_MONTH. Each RAW.DAILY_SPEND row joins to exactly
-- one RAW.CAMPAIGNS row (many-to-one on CAMPAIGN_ID), so the join cannot fan out and
-- the totals equal the RAW totals. Column names are UPPERCASE ASCII (the connector
-- requires ASCII headers), types are explicit so Data Studio maps them to
-- Date / Text / Number.
-- Expected (computed locally from the CSVs): 159 rows (36 months, 5 channels;
-- not every channel is active every month), SUM(SPEND) = 4523050.02,
-- SUM(IMPRESSIONS) = 436844819, SUM(CLICKS) = 7102319.
-- The CRM_REPORTER role reads it through the MART future grants (bootstrap section 4).
-- =============================================================================
USE ROLE CRM_TRANSFORMER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE MARKETING_WH;
USE SCHEMA MARKETING_CRM.MART;

CREATE OR REPLACE TABLE MARKETING_CRM.MART.CONNECTION_TEST
  COMMENT = 'Phase 1 Data Studio connection test only (channel x month spend). Not part of the model; dropped in Phase 6.'
AS
SELECT
    DATE_TRUNC('MONTH', TO_DATE(d.SPEND_DATE, 'YYYY-MM-DD'))::DATE AS SPEND_MONTH,
    c.CHANNEL::VARCHAR                                             AS CHANNEL,
    SUM(TO_NUMBER(d.SPEND, 12, 2))::NUMBER(12,2)                   AS SPEND,
    SUM(TO_NUMBER(d.IMPRESSIONS))::NUMBER(38,0)                    AS IMPRESSIONS,
    SUM(TO_NUMBER(d.CLICKS))::NUMBER(38,0)                         AS CLICKS
FROM MARKETING_CRM.RAW.DAILY_SPEND AS d
JOIN MARKETING_CRM.RAW.CAMPAIGNS   AS c
  ON c.CAMPAIGN_ID = d.CAMPAIGN_ID
GROUP BY 1, 2
ORDER BY 1, 2;

-- Check: expect 159 | 4523050.02 | 436844819 | 7102319 | 2023-01-01 | 2025-12-01 | PASS.
-- STATUS = FAIL on any mismatch; `make connection-test-table` (run_sql.py) then exits 1.
SELECT
    N_ROWS, TOTAL_SPEND, TOTAL_IMPRESSIONS, TOTAL_CLICKS, FIRST_MONTH, LAST_MONTH,
    IFF(N_ROWS = 159
        AND TOTAL_SPEND = 4523050.02
        AND TOTAL_IMPRESSIONS = 436844819
        AND TOTAL_CLICKS = 7102319
        AND FIRST_MONTH = '2023-01-01'::DATE
        AND LAST_MONTH = '2025-12-01'::DATE, 'PASS', 'FAIL') AS STATUS
FROM (
    SELECT
        COUNT(*)         AS N_ROWS,
        SUM(SPEND)       AS TOTAL_SPEND,
        SUM(IMPRESSIONS) AS TOTAL_IMPRESSIONS,
        SUM(CLICKS)      AS TOTAL_CLICKS,
        MIN(SPEND_MONTH) AS FIRST_MONTH,
        MAX(SPEND_MONTH) AS LAST_MONTH
    FROM MARKETING_CRM.MART.CONNECTION_TEST
);
