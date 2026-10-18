{#-
    STG_CHALLENGE_DAILY_SPEND: the dirty RAW.CHALLENGE_DAILY_SPEND extract through the same
    rules as STG_DAILY_SPEND (2,001 RAW rows, 2,000 after de-duplication), plus
    SPEND_DATE_FILLED. Reconciliation only; MART never reads it. The rules live in
    macros/staging/clean_daily_spend.sql (shared by the clean and the challenge track);
    descriptions and tests are in _staging.yml.
-#}
{{ clean_daily_spend(source('raw', 'challenge_daily_spend'), fill_spend_date=true) }}
