{{ config(severity='warn') }}
{#-
    LEAD_SOURCE (as delivered on the lead) equals the CHANNEL of the lead's campaign for every
    lead today (0 mismatches over 261,684 leads). MART never relies on it: every fact takes the
    channel from DIM_CAMPAIGN. So a mismatch is drift in the source system to look at, not a
    broken pipeline, and this test only WARNS (sql/02_data_cleaning_tests.sql block 14 is the
    same WARN-level check). Returns the mismatching leads.
-#}
SELECT l.LEAD_ID, l.CAMPAIGN_ID, l.LEAD_SOURCE, c.CHANNEL
FROM {{ ref('stg_leads') }} l
JOIN {{ ref('stg_campaigns') }} c ON c.CAMPAIGN_ID = l.CAMPAIGN_ID
WHERE l.LEAD_SOURCE IS DISTINCT FROM c.CHANNEL
