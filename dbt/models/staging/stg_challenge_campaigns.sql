{#-
    STG_CHALLENGE_CAMPAIGNS: the dirty RAW.CHALLENGE_CAMPAIGNS extract through the same
    rules as STG_CAMPAIGNS (121 RAW rows, 120 after de-duplication), plus
    CAMPAIGN_NAME_FILLED. Reconciliation only; MART never reads it. The rules live in
    macros/staging/clean_campaigns.sql (shared by the clean and the challenge track);
    descriptions and tests are in _staging.yml.
-#}
{{ clean_campaigns(source('raw', 'challenge_campaigns'), fill_campaign_name=true) }}
