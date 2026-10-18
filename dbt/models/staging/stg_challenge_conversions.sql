{#-
    STG_CHALLENGE_CONVERSIONS: the dirty RAW.CHALLENGE_CONVERSIONS extract through the same
    rules as STG_CONVERSIONS (2,001 RAW rows, 2,000 after de-duplication). Reconciliation
    only; MART never reads it. The rules live in macros/staging/clean_conversions.sql
    (shared by the clean and the challenge track); descriptions and tests are in
    _staging.yml.
-#}
{{ clean_conversions(source('raw', 'challenge_conversions')) }}
