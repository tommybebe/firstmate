#!/usr/bin/env bash
# Push this firstmate home's persistent memory (data/ and config/) to R2.
# Usage: fm-memory-push.sh [--dry-run] [--help]
#
# Mirrors data/ and config/ up to the R2 bucket under the memory/ prefix
# (rclone sync per directory: remote copy converges to the local state,
# including deletions). state/ and projects/ are deliberately not pushed:
# state/ is volatile runtime signal and projects/ is re-clonable.
# A directory that does not exist locally is skipped with a note and its
# remote copy is left untouched.
#
# Requires R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, and R2_BUCKET
# in the environment; fails loudly naming any that are missing, and never
# prints their values. FM_MEMORY_PREFIX overrides the memory/ prefix.
set -u

usage() {
  cat <<'EOF'
Usage: fm-memory-push.sh [--dry-run] [--help]

Sync this firstmate home's data/ and config/ directories up to the R2 bucket
under the memory/ prefix, as a persistent backup for ephemeral environments.

  --dry-run   show what would change without transferring anything

Per directory this is a mirror (rclone sync): files deleted locally are also
deleted from the remote copy. state/ and projects/ are never pushed.

Required environment (values are never printed):
  R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
Optional:
  FM_MEMORY_PREFIX  object-key prefix inside the bucket (default: memory)
  FM_HOME           active firstmate home (default: this repo root)
EOF
}

DRY_RUN=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY_RUN=--dry-run ;;
  "") ;;
  *) echo "usage: fm-memory-push.sh [--dry-run] [--help]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-memory-lib.sh
. "$SCRIPT_DIR/fm-memory-lib.sh"

fm_memory_require_env || exit 1
fm_memory_require_rclone || exit 1

prefix=$(fm_memory_prefix)
pushed=0
errors=0
for dir in data config; do
  src="$FM_HOME/$dir"
  dst="fmmem:$R2_BUCKET/$prefix/$dir"
  if [ ! -d "$src" ]; then
    printf 'memory-push: %s/: skipped - no local directory\n' "$dir"
    continue
  fi
  printf 'memory-push: %s/ -> %s/%s/%s\n' "$dir" "$R2_BUCKET" "$prefix" "$dir"
  if fm_memory_rclone sync "$src" "$dst" ${DRY_RUN:+"$DRY_RUN"}; then
    pushed=$((pushed + 1))
  else
    printf 'memory-push: %s/: FAILED (see rclone errors above)\n' "$dir" >&2
    errors=1
  fi
done

if [ "$errors" -ne 0 ]; then
  echo "memory-push: finished with errors" >&2
  exit 1
fi
if [ "$pushed" -eq 0 ]; then
  echo "memory-push: nothing to push (no data/ or config/ in this home)"
else
  echo "memory-push: done${DRY_RUN:+ (dry run - nothing transferred)}"
fi
