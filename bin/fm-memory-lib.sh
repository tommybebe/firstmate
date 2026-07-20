#!/usr/bin/env bash
# fm-memory-lib.sh - shared helpers for the R2 persistent-memory sync scripts.
#
# Sourced by fm-memory-push.sh and fm-memory-pull.sh; not an entry point.
# Provides the R2 credential presence check, the rclone availability check,
# and a wrapper that runs rclone against the bucket using environment-only
# configuration (no config file, no secrets on the command line or in output).
#
# Required environment (values are never printed by any helper here):
#   R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
# Optional:
#   FM_MEMORY_PREFIX  object-key prefix inside the bucket (default: memory)
#
# TLS through the CCR agent proxy: rclone's S3 backend cannot consume the
# AWS_CA_BUNDLE env var this environment pre-sets (LoadCustomCABundleError:
# unsupported transport, *fshttp.Transport - verified 2026-07-19 against
# rclone 1.60.1), so the wrapper strips AWS_CA_BUNDLE from rclone's
# environment and passes the same CA bundle via rclone's own RCLONE_CA_CERT,
# keeping TLS verification on. See docs/r2-memory.md.

# fm_memory_require_env: fail loudly (exit 1) naming every missing R2_* var.
# Prints names only, never values.
fm_memory_require_env() {
  local missing="" var
  for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
    [ -n "${!var:-}" ] || missing="$missing $var"
  done
  if [ -n "$missing" ]; then
    printf 'memory-sync: missing required environment variable(s):%s\n' "$missing" >&2
    printf 'memory-sync: set them (R2 S3 credentials, endpoint URL, bucket name) and retry\n' >&2
    return 1
  fi
}

# fm_memory_require_rclone: fail loudly (exit 1) when rclone is unavailable.
fm_memory_require_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    printf 'memory-sync: rclone not found on PATH (install: apt-get install rclone)\n' >&2
    return 1
  fi
}

# fm_memory_prefix: echo the active object-key prefix (no trailing slash).
fm_memory_prefix() {
  printf '%s\n' "${FM_MEMORY_PREFIX:-memory}"
}

# fm_memory_rclone <args...>: run rclone configured for the R2 bucket purely
# via environment variables. The remote is named "fmmem", so callers address
# paths as fmmem:$R2_BUCKET/....
# Secrets travel only in the child process environment, never in argv.
fm_memory_rclone() {
  local ca_args=()
  if [ -n "${RCLONE_CA_CERT:-}" ]; then
    : # caller already chose a CA bundle; leave it in place
  elif [ -n "${SSL_CERT_FILE:-}" ] && [ -f "${SSL_CERT_FILE:-}" ]; then
    ca_args=(RCLONE_CA_CERT="$SSL_CERT_FILE")
  fi
  env -u AWS_CA_BUNDLE \
    "${ca_args[@]}" \
    RCLONE_CONFIG_FMMEM_TYPE=s3 \
    RCLONE_CONFIG_FMMEM_PROVIDER=Cloudflare \
    RCLONE_CONFIG_FMMEM_NO_CHECK_BUCKET=true \
    RCLONE_CONFIG_FMMEM_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    RCLONE_CONFIG_FMMEM_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_FMMEM_ENDPOINT="$R2_ENDPOINT" \
    rclone "$@"
}
