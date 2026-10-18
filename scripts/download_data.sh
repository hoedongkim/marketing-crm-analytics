#!/usr/bin/env bash
# Download the Analytics Engineering "Marketing Campaigns & Conversions Dataset v1.0.0"
# (CC BY 4.0, synthetic), verify pinned SHA-256 checksums, and extract it safely.
#
#   DATA_DIR=data/raw bash scripts/download_data.sh      (what `make data` runs)
#
# - A zip that is already present is verified, never re-downloaded.
# - Zip members are checked for absolute paths, '..' components, backslashes and
#   symlinks before anything is extracted.
# - Extraction goes to a temporary directory first; it is moved into place only after
#   every CSV matches its pinned SHA-256.
# - An existing extract that does not match is reported, never deleted.
# Written for macOS /bin/bash 3.2 (no bash 4 features).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-data/raw}"
case "$DATA_DIR" in
  /*) ;;
  *) DATA_DIR="$REPO_ROOT/$DATA_DIR" ;;
esac

BASE_URL="https://uhzz8xwe8uih5iol.public.blob.vercel-storage.com/datasets/marketing-campaigns/v1.0.0"

SOURCE_ZIP="marketing-campaigns-v1.0.0-source-csv.zip"
SOURCE_ZIP_SHA256="a69a8b189270f4292f4c8efe35c61353363b9e1de0cf8dc432c64b7aa7319f69"
CHALLENGE_ZIP="marketing-campaigns-v1.0.0-cleaning-challenge.zip"
CHALLENGE_ZIP_SHA256="8cb1761ba89fc452b45c84275c1449fbf460e8c6e3a9100140fefeae2f4f1190"

# Per-CSV SHA-256. The publisher's manifest.json is not inside the zips, so these are
# a local baseline: the 4 source CSVs from the 2026-10-13 profiling (byte-level scan),
# the 4 challenge CSVs computed from the checksum-verified challenge zip.
SOURCE_CSVS="
campaigns.csv ee8a5e842a3a100c303a4a3b40ecef3b9f3c80d8b803cc84a30e8f3ac5cd638a
daily_spend.csv e653b309c2209a876ca8590b41f7c8ef79e73d020594541342eba72341a7d8b5
leads.csv b8e48b0317f1110abe65272c9a92e98dc744d5e5179bde806dc568bdfa692761
conversions.csv 04816bfcfa48aa15ff1198f6f19ac509022a3657cd122771d855b54d14d83598
"
CHALLENGE_CSVS="
raw/campaigns.csv 55eccd8a78ee6481d16cbb62f3c64d464bceb7aacaa80142a36b543ece5b05db
raw/daily_spend.csv 25450222d97d0d0d469d72629504a42e3310a17944dd85aedaad5a155db1cc43
raw/leads.csv 700278cb58930eb5f335c2de3493bd6ad78070fe39a272cb98ab3ccdb888176f
raw/conversions.csv ccf2deff63314e5b27f616020176c4dceb755adecd0dc6779c4e879c0078a03a
"

die() { echo "error: $*" >&2; exit 1; }

for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed."
done
if command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
  die "need shasum or sha256sum to verify checksums."
fi

# fetch_zip NAME SHA256: verify an existing zip, or download it to NAME.part, verify, rename.
fetch_zip() {
  local name="$1" want="$2" dest="$DATA_DIR/$1" got tmp
  if [ -f "$dest" ]; then
    got="$(sha256_of "$dest")"
    if [ "$got" = "$want" ]; then
      echo "ok     $name already present, SHA-256 verified (not re-downloaded)"
      return 0
    fi
    die "$dest exists but its SHA-256 is $got (expected $want). Move it away and run 'make data' again."
  fi
  tmp="$dest.part"
  echo "fetch  $name"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    --output "$tmp" "$BASE_URL/$name?download=1"
  got="$(sha256_of "$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    die "downloaded $name has SHA-256 $got (expected $want); discarded it."
  fi
  mv "$tmp" "$dest"
  echo "ok     $name downloaded, SHA-256 verified"
}

# check_members ZIP: refuse archives whose member names could escape the target directory.
check_members() {
  local zip="$1" member
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    case "$member" in
      /*) die "$zip: absolute member path '$member'" ;;
      *\\*) die "$zip: backslash in member path '$member'" ;;
    esac
    case "/$member/" in
      */../*) die "$zip: '..' in member path '$member'" ;;
    esac
  done <<EOF
$(unzip -Z1 "$zip")
EOF
  # zipinfo's long listing starts symlink entries with 'l' (e.g. lrwxrwxrwx).
  if unzip -Z "$zip" | awk 'substr($1, 1, 1) == "l" && length($1) == 10 { found = 1 } END { exit !found }'; then
    die "$zip contains a symbolic link; refusing to extract."
  fi
}

# verify_csvs DIR LIST: every "relpath sha256" line in LIST must match under DIR.
verify_csvs() {
  local dir="$1" list="$2" rel want got status=0
  while read -r rel want; do
    [ -n "$rel" ] || continue
    if [ ! -f "$dir/$rel" ]; then
      echo "  MISSING  $rel" >&2; status=1; continue
    fi
    got="$(sha256_of "$dir/$rel")"
    if [ "$got" = "$want" ]; then
      echo "  ok       $rel  sha256 ${got:0:16}..."
    else
      echo "  MISMATCH $rel  sha256 $got (expected $want)" >&2; status=1
    fi
  done <<EOF
$list
EOF
  return $status
}

# extract ZIP TARGET_DIR CSV_LIST
extract() {
  local zip="$DATA_DIR/$1" target="$DATA_DIR/$2" list="$3" tmp
  if [ -e "$target" ]; then
    echo "check  $2/ (already extracted)"
    verify_csvs "$target" "$list" || die "$target does not match $1. Move it away and run 'make data' again."
    return 0
  fi
  check_members "$zip"
  tmp="$(mktemp -d "$DATA_DIR/.extract.XXXXXX")"
  unzip -q "$zip" -d "$tmp"
  echo "check  $2/ (fresh extract)"
  if ! verify_csvs "$tmp" "$list"; then
    rm -rf "$tmp"   # our own temporary extract, never user data
    die "extracted files from $1 failed verification; nothing was moved into place."
  fi
  chmod 755 "$tmp"
  mv "$tmp" "$target"
  echo "ok     extracted $1 -> ${target#"$REPO_ROOT"/}/"
}

mkdir -p "$DATA_DIR"
echo "Dataset: Analytics Engineering, \"Marketing Campaigns & Conversions Dataset v1.0.0\" (CC BY 4.0)"
echo "Target:  $DATA_DIR"
fetch_zip "$SOURCE_ZIP" "$SOURCE_ZIP_SHA256"
fetch_zip "$CHALLENGE_ZIP" "$CHALLENGE_ZIP_SHA256"
extract "$SOURCE_ZIP" "source" "$SOURCE_CSVS"
extract "$CHALLENGE_ZIP" "cleaning-challenge" "$CHALLENGE_CSVS"
echo "Data ready: source CSVs in ${DATA_DIR#"$REPO_ROOT"/}/source, dirty extracts in ${DATA_DIR#"$REPO_ROOT"/}/cleaning-challenge/raw"
