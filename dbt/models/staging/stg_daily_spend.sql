{#-
    STG_DAILY_SPEND: RAW.DAILY_SPEND typed and cleaned, one row per campaign per active day
    (11,240 rows). Clean release: an input of MART. The rules live in
    macros/staging/clean_daily_spend.sql (shared by the clean and the challenge track);
    descriptions and tests are in _staging.yml.
-#}
{{ clean_daily_spend(source('raw', 'daily_spend')) }}
