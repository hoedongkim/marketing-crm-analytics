#!/usr/bin/env bash
# Generate the two RSA 2048 key pairs (PKCS#8) used for Snowflake key-pair auth:
#
#   svc_crm_pipeline.p8 / .pub   SVC_CRM_PIPELINE: Python loader, checks, dbt
#   svc_crm_bi.p8       / .pub   SVC_CRM_BI: Google Data Studio connector
#
#   KEY_DIR=$HOME/.snowflake/keys ENCRYPT_PIPELINE_KEY=0 bash scripts/generate_keys.sh
#
# - Both private keys are unencrypted by default (openssl pkcs8 -nocrypt).
# - ENCRYPT_PIPELINE_KEY=1 encrypts the pipeline key with AES-256 (-v2 aes-256-cbc).
#   openssl asks for the passphrase twice, or reads it from SNOWFLAKE_PRIVATE_KEY_PASSPHRASE
#   if that variable is set. Put the same value in .env.
# - The BI key is ALWAYS unencrypted: the Data Studio connector rejects encrypted keys.
#   Treat that file like a password.
# - The script never overwrites an existing key file, and never prints private keys.
# - The SHA-256 fingerprint printed for each public key is the value that
#   DESC USER shows as RSA_PUBLIC_KEY_FP (after the "SHA256:" prefix).
# Commands follow https://docs.snowflake.com/en/user-guide/key-pair-auth (checked 2026-10-13).
# Written for macOS /bin/bash 3.2.
set -euo pipefail

KEY_DIR="${KEY_DIR:-$HOME/.snowflake/keys}"
ENCRYPT_PIPELINE_KEY="${ENCRYPT_PIPELINE_KEY:-0}"
NAMES="svc_crm_pipeline svc_crm_bi"

die() { echo "error: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl is required."
case "$KEY_DIR" in
  /*) ;;
  *) die "KEY_DIR must be an absolute path (got '$KEY_DIR'); .env and dbt need absolute key paths." ;;
esac
case "$ENCRYPT_PIPELINE_KEY" in
  0|1) ;;
  *) die "ENCRYPT_PIPELINE_KEY must be 0 or 1 (got '$ENCRYPT_PIPELINE_KEY')." ;;
esac

# The lists below hold bare FILE NAMES (fixed, no spaces or glob characters), never full
# paths, so they can be split safely; every path is built as "$KEY_DIR/$f" in quotes.
# KEY_DIR itself may contain spaces.

# Refuse up front if any target file exists, so a run never leaves a half-replaced set.
existing=""
for name in $NAMES; do
  for ext in p8 pub; do
    if [ -e "$KEY_DIR/$name.$ext" ]; then existing="$existing $name.$ext"; fi
  done
done
if [ -n "$existing" ]; then
  echo "error: refusing to overwrite existing key files:" >&2
  for f in $existing; do echo "  $KEY_DIR/$f" >&2; done
  echo "Keys that are already registered in Snowflake must stay as they are. To rotate, move" >&2
  echo "these files somewhere safe first (or use another KEY_DIR), then run make keys again." >&2
  exit 1
fi

# Remove only the files this run created if it fails half-way (e.g. Ctrl-C at a prompt).
created=""
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ -n "$created" ]; then
    left=""
    for f in $created; do
      rm -f -- "$KEY_DIR/$f"
      if [ -e "$KEY_DIR/$f" ]; then left="$left $f"; fi
    done
    if [ -z "$left" ]; then
      echo "Removed the partial key files from this failed run." >&2
    else
      echo "error: could not remove partial key files:$left (in $KEY_DIR); delete them by hand." >&2
    fi
  fi
}
trap cleanup EXIT

umask 077
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

echo "OpenSSL: $(openssl version)"
echo "Key directory: $KEY_DIR (mode 700)"

# gen_key NAME ENCRYPT(0|1)
gen_key() {
  local name="$1" encrypt="$2" p8="$KEY_DIR/$1.p8" pub="$KEY_DIR/$1.pub" pem
  # Generate once and keep the unencrypted PEM only in this shell's memory (printf is a
  # builtin, so it never appears in a process list), then write the PKCS#8 file and
  # derive the public key from the same PEM.
  pem="$(openssl genrsa 2048 2>/dev/null)"
  created="$created $name.p8"
  if [ "$encrypt" = 1 ]; then
    if [ -n "${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}" ]; then
      printf '%s\n' "$pem" | openssl pkcs8 -topk8 -v2 aes-256-cbc -inform PEM -out "$p8" \
        -passout env:SNOWFLAKE_PRIVATE_KEY_PASSPHRASE
    else
      echo "Choose a passphrase for $name.p8 (asked twice). Store it in .env as SNOWFLAKE_PRIVATE_KEY_PASSPHRASE."
      printf '%s\n' "$pem" | openssl pkcs8 -topk8 -v2 aes-256-cbc -inform PEM -out "$p8"
    fi
  else
    printf '%s\n' "$pem" | openssl pkcs8 -topk8 -inform PEM -out "$p8" -nocrypt
  fi
  created="$created $name.pub"
  printf '%s\n' "$pem" | openssl rsa -pubout -out "$pub" 2>/dev/null
  pem=""
  chmod 600 "$p8"
  chmod 644 "$pub"

  # Sanity checks on what was written (headers only; key material is never printed).
  local want_header="-----BEGIN PRIVATE KEY-----"
  if [ "$encrypt" = 1 ]; then want_header="-----BEGIN ENCRYPTED PRIVATE KEY-----"; fi
  [ "$(head -n 1 "$p8")" = "$want_header" ] || die "$p8 does not start with '$want_header'."
  [ "$(head -n 1 "$pub")" = "-----BEGIN PUBLIC KEY-----" ] || die "$pub is not a PEM public key."
  # grep without -q reads all input, so openssl never hits SIGPIPE under pipefail.
  openssl rsa -pubin -in "$pub" -noout -text 2>/dev/null | grep "2048 bit" >/dev/null \
    || die "$pub is not a 2048-bit RSA public key."
}

fingerprint() {
  openssl rsa -pubin -in "$1" -outform DER 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64
}

gen_key svc_crm_pipeline "$ENCRYPT_PIPELINE_KEY"
gen_key svc_crm_bi 0
created=""   # success: nothing to clean up

pipeline_kind="unencrypted"
if [ "$ENCRYPT_PIPELINE_KEY" = 1 ]; then pipeline_kind="encrypted, AES-256"; fi

echo
echo "Created (private keys mode 600, public keys mode 644):"
echo "  $KEY_DIR/svc_crm_pipeline.p8  ($pipeline_kind)"
echo "  $KEY_DIR/svc_crm_pipeline.pub"
echo "  $KEY_DIR/svc_crm_bi.p8        (unencrypted: required by the Data Studio connector)"
echo "  $KEY_DIR/svc_crm_bi.pub"
echo
echo "Public key fingerprints (compare with RSA_PUBLIC_KEY_FP from DESC USER after the bootstrap):"
echo "  SVC_CRM_PIPELINE  SHA256:$(fingerprint "$KEY_DIR/svc_crm_pipeline.pub")"
echo "  SVC_CRM_BI        SHA256:$(fingerprint "$KEY_DIR/svc_crm_bi.pub")"
echo
echo "Next: make bootstrap-sql KEY_DIR='$KEY_DIR'"
echo "Later, in .env (absolute paths, no ~):"
echo "  SNOWFLAKE_PRIVATE_KEY_PATH=$KEY_DIR/svc_crm_pipeline.p8"
echo "  SNOWFLAKE_BI_PRIVATE_KEY_PATH=$KEY_DIR/svc_crm_bi.p8"
echo "Back up the .p8 files somewhere private (a password manager). Never commit them."
