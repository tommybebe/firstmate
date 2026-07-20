#!/usr/bin/env bash
# Restore this firstmate home's persistent memory (data/ and config/) from R2.
# Usage: fm-memory-pull.sh [--dry-run] [--force] [--help]
#
# Copies the bucket's memory/ prefix back into data/ and config/. Safe on a
# fresh clone: missing local directories are created, local-only files are
# never deleted, and by default a local file newer than its remote copy is
# never overwritten - it is skipped and reported loudly, with --force offered
# as the explicit overwrite path. A directory with no remote snapshot is
# skipped with a note.
#
# Requires R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, and R2_BUCKET
# in the environment; fails loudly naming any that are missing, and never
# prints their values. FM_MEMORY_PREFIX overrides the memory/ prefix.
set -u

usage() {
  cat <<'EOF'
Usage: fm-memory-pull.sh [--dry-run] [--force] [--help]

Restore this firstmate home's data/ and config/ directories from the R2
bucket's memory/ prefix (written by fm-memory-push.sh).

  --dry-run   show what would change without transferring anything
  --force     overwrite local files even when they are newer than the remote

Default behavior is additive and conservative: local-only files are never
deleted, and local files newer than their remote copy are skipped and listed
so nothing is silently lost.

Required environment (values are never printed):
  R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
Optional:
  FM_MEMORY_PREFIX  object-key prefix inside the bucket (default: memory)
  FM_HOME           active firstmate home (default: this repo root)
EOF
}

DRY_RUN=""
FORCE=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=--dry-run ;;
    --force) FORCE=1 ;;
    *) echo "usage: fm-memory-pull.sh [--dry-run] [--force] [--help]" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-memory-lib.sh
. "$SCRIPT_DIR/fm-memory-lib.sh"

fm_memory_require_env || exit 1
fm_memory_require_rclone || exit 1

prefix=$(fm_memory_prefix)
log=$(mktemp "${TMPDIR:-/tmp}/fm-memory-pull.XXXXXX") || exit 1
trap 'rm -f "$log"' EXIT

restored=0
errors=0
skipped_newer=""
for dir in data config; do
  src="fmmem:$R2_BUCKET/$prefix/$dir"
  dst="$FM_HOME/$dir"
  if ! listing=$(fm_memory_rclone lsf "$src" --max-depth 1 2>"$log"); then
    printf 'memory-pull: %s/: FAILED listing remote snapshot\n' "$dir" >&2
    cat "$log" >&2
    errors=1
    continue
  fi
  if [ -z "$listing" ]; then
    printf 'memory-pull: %s/: skipped - no remote snapshot at %s/%s/%s\n' \
      "$dir" "$R2_BUCKET" "$prefix" "$dir"
    continue
  fi
  printf 'memory-pull: %s/%s/%s -> %s/\n' "$R2_BUCKET" "$prefix" "$dir" "$dir"
  update_flag=--update
  [ -n "$FORCE" ] && update_flag=""
  : > "$log"
  if fm_memory_rclone copy "$src" "$dst" \
      ${update_flag:+"$update_flag"} ${DRY_RUN:+"$DRY_RUN"} \
      -vv --log-file "$log"; then
    restored=$((restored + 1))
  else
    printf 'memory-pull: %s/: FAILED\n' "$dir" >&2
    cat "$log" >&2
    errors=1
    continue
  fi
  if [ -n "$DRY_RUN" ]; then
    grep -E ': (Copied|Skipped copy)' "$log" | sed 's/^/  /' || true
  fi
  # rclone logs this skip at DEBUG in 1.60 and INFO in newer releases
  # (verified 2026-07-20 against rclone 1.60.1 and a real R2 bucket).
  newer=$(sed -n 's/^[0-9/]* [0-9:]* [A-Z]* *: \(.*\): Destination is newer than source, skipping$/\1/p' "$log")
  if [ -n "$newer" ]; then
    while IFS= read -r f; do
      skipped_newer="$skipped_newer$dir/$f"$'\n'
    done <<< "$newer"
  fi
done

if [ "$errors" -ne 0 ]; then
  echo "memory-pull: finished with errors" >&2
  exit 1
fi
if [ -n "$skipped_newer" ]; then
  echo "memory-pull: ============================================================"
  echo "memory-pull: NOT overwritten (local file is newer than remote snapshot):"
  printf '%s' "$skipped_newer" | sed 's/^/memory-pull:   /'
  echo "memory-pull: re-run with --force to overwrite them from the snapshot"
  echo "memory-pull: ============================================================"
fi
if [ "$restored" -eq 0 ]; then
  echo "memory-pull: nothing restored (no remote snapshot found)"
else
  echo "memory-pull: done${DRY_RUN:+ (dry run - nothing transferred)}"
fi
