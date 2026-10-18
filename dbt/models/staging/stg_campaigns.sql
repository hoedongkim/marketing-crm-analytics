{#-
    STG_CAMPAIGNS: RAW.CAMPAIGNS typed and cleaned, one row per campaign (120 rows). Clean
    release: an input of MART. The rules live in macros/staging/clean_campaigns.sql (shared
    by the clean and the challenge track); descriptions and tests are in _staging.yml.
-#}
{{ clean_campaigns(source('raw', 'campaigns')) }}
