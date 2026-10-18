{#-
    STG_CONVERSIONS: RAW.CONVERSIONS typed and cleaned, one row per converted lead (39,696
    rows). Clean release: an input of MART. The rules live in
    macros/staging/clean_conversions.sql (shared by the clean and the challenge track);
    descriptions and tests are in _staging.yml.
-#}
{{ clean_conversions(source('raw', 'conversions')) }}
