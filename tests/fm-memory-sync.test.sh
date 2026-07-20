#!/usr/bin/env bash
# fm-memory-sync.test.sh - R2 persistent-memory sync tests for
# bin/fm-memory-push.sh and bin/fm-memory-pull.sh.
#
# Unit tests run against a fake rclone that records argv and environment, so
# they need no network and no credentials: loud missing-variable failures,
# no-secret-leak guarantees, sync/copy argument shapes, state//projects/
# exclusion, --dry-run and --force passthrough, newer-local skip reporting,
# and the AWS_CA_BUNDLE strip for rclone's S3 backend.
#
# A final real-bucket end-to-end test (push, wipe, pull, diff, newer-local
# skip, --force overwrite) runs only when the four R2_* variables are set,
# real rclone is installed, and the bucket answers; otherwise it self-skips.
# It works under a throwaway FM_MEMORY_PREFIX and purges it afterwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-memory-sync)

# --- fake rclone -------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/rclone" <<'SH'
#!/usr/bin/env bash
{ printf 'rclone'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$FAKE_RCLONE_CMDLOG"
printf 'aws_ca=%s ak_set=%s sk_in_argv=no\n' \
  "${AWS_CA_BUNDLE:-unset}" "${RCLONE_CONFIG_FMMEM_ACCESS_KEY_ID:+yes}" >> "$FAKE_RCLONE_ENVLOG"
sub=${1:-}
case "$sub" in
  lsf)
    [ -n "${FAKE_RCLONE_LSF_EMPTY:-}" ] && exit 0
    echo "somefile.md"
    ;;
  copy)
    log="" prev=""
    for a in "$@"; do
      [ "$prev" = "--log-file" ] && log=$a
      prev=$a
    done
    if [ -n "${FAKE_RCLONE_NEWER:-}" ] && [ -n "$log" ]; then
      printf '2026/07/20 00:00:00 DEBUG : %s: Destination is newer than source, skipping\n' \
        "$FAKE_RCLONE_NEWER" >> "$log"
    fi
    ;;
  sync)
    [ -n "${FAKE_RCLONE_FAIL_SYNC:-}" ] && exit 1
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/rclone"

# Fake-credential environment for every unit test; the sentinel secret must
# never appear in any script output or recorded argv.
SENTINEL='fakesecret-sentinel-do-not-print'
fake_env() {
  env R2_ACCESS_KEY_ID=fakekey R2_SECRET_ACCESS_KEY="$SENTINEL" \
    R2_ENDPOINT=https://example.invalid R2_BUCKET=testbucket \
    AWS_CA_BUNDLE=/nonexistent/ca-bundle.crt \
    FAKE_RCLONE_CMDLOG="$CMDLOG" FAKE_RCLONE_ENVLOG="$ENVLOG" \
    PATH="$FAKEBIN:$PATH" "$@"
}

new_logs() {
  CMDLOG="$TMP/cmd.$1.log" ENVLOG="$TMP/env.$1.log"
  : > "$CMDLOG"; : > "$ENVLOG"
}

new_home() {
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/projects"
  printf 'captain prefs\n' > "$HOME_DIR/data/captain.md"
  printf 'default\n' > "$HOME_DIR/config/crew-harness"
  printf 'volatile\n' > "$HOME_DIR/state/task.status"
  printf 'clone\n' > "$HOME_DIR/projects/readme.txt"
}

# --- missing-variable failures ----------------------------------------------

for script in fm-memory-push.sh fm-memory-pull.sh; do
  out=$(env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY -u R2_ENDPOINT -u R2_BUCKET \
    "$ROOT/bin/$script" 2>&1); code=$?
  expect_code 1 "$code" "$script with no R2 vars"
  for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
    assert_contains "$out" "$var" "$script names missing $var"
  done
done
pass "push and pull fail loudly naming all missing R2 variables"

out=$(env -u R2_BUCKET R2_ACCESS_KEY_ID=k R2_SECRET_ACCESS_KEY=s \
  R2_ENDPOINT=https://e.invalid "$ROOT/bin/fm-memory-push.sh" 2>&1); code=$?
expect_code 1 "$code" "push with only R2_BUCKET missing"
assert_contains "$out" "R2_BUCKET" "push names R2_BUCKET"
assert_not_contains "$out" "R2_ENDPOINT" "push does not name present vars"
pass "missing-variable report names only the absent variables"

# --- rclone missing ----------------------------------------------------------

TOOLBIN="$TMP/toolbin"
mkdir -p "$TOOLBIN"
for t in bash mktemp sed grep cat env dirname; do
  ln -s "$(command -v "$t")" "$TOOLBIN/$t"
done
out=$(env R2_ACCESS_KEY_ID=k R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=https://e.invalid \
  R2_BUCKET=b PATH="$TOOLBIN" "$ROOT/bin/fm-memory-push.sh" 2>&1); code=$?
expect_code 1 "$code" "push without rclone on PATH"
assert_contains "$out" "rclone not found" "push reports missing rclone with install hint"
pass "push fails loudly when rclone is unavailable"

# --- push happy path ---------------------------------------------------------

new_logs push; new_home
out=$(fake_env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-memory-push.sh" 2>&1); code=$?
expect_code 0 "$code" "push happy path"
assert_grep "rclone sync $HOME_DIR/data fmmem:testbucket/memory/data" "$CMDLOG" \
  "push syncs data/ to the memory/ prefix"
assert_grep "rclone sync $HOME_DIR/config fmmem:testbucket/memory/config" "$CMDLOG" \
  "push syncs config/ to the memory/ prefix"
assert_no_grep "state" "$CMDLOG" "push never references state/"
assert_no_grep "projects" "$CMDLOG" "push never references projects/"
assert_contains "$out" "memory-push: done" "push reports done"
pass "push mirrors data/ and config/ only, excluding state/ and projects/"

assert_not_contains "$out" "$SENTINEL" "push output leaks no secret"
assert_no_grep "$SENTINEL" "$CMDLOG" "push argv leaks no secret"
assert_grep "aws_ca=unset ak_set=yes" "$ENVLOG" \
  "push strips AWS_CA_BUNDLE and passes credentials via environment"
pass "push keeps secrets out of output and argv, credentials via env only"

new_logs pushskip
HOME2=$(mktemp -d "$TMP/home.XXXXXX"); mkdir -p "$HOME2/data"
out=$(fake_env FM_HOME="$HOME2" "$ROOT/bin/fm-memory-push.sh" 2>&1)
assert_contains "$out" "config/: skipped - no local directory" "push notes missing config/"
assert_no_grep "sync $HOME2/config" "$CMDLOG" "push does not sync a missing directory"
pass "push skips a missing local directory with a note"

new_logs pushdry; new_home
fake_env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-memory-push.sh" --dry-run >/dev/null 2>&1
assert_grep "--dry-run" "$CMDLOG" "push forwards --dry-run to rclone"
pass "push --dry-run is forwarded to rclone"

new_logs pushfail; new_home
out=$(fake_env FM_HOME="$HOME_DIR" FAKE_RCLONE_FAIL_SYNC=1 \
  "$ROOT/bin/fm-memory-push.sh" 2>&1); code=$?
expect_code 1 "$code" "push with failing rclone sync"
assert_contains "$out" "FAILED" "push surfaces the failed directory"
pass "push propagates rclone sync failures"

# --- pull --------------------------------------------------------------------

new_logs pull; new_home
out=$(fake_env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-memory-pull.sh" 2>&1); code=$?
expect_code 0 "$code" "pull happy path"
assert_grep "rclone copy fmmem:testbucket/memory/data $HOME_DIR/data --update" "$CMDLOG" \
  "pull copies with --update by default (never overwrites newer local files)"
assert_no_grep "rclone sync" "$CMDLOG" "pull never uses sync (no local deletions)"
assert_contains "$out" "memory-pull: done" "pull reports done"
assert_not_contains "$out" "$SENTINEL" "pull output leaks no secret"
assert_no_grep "$SENTINEL" "$CMDLOG" "pull argv leaks no secret"
pass "pull restores additively with --update and leaks no secret"

new_logs pullforce; new_home
fake_env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-memory-pull.sh" --force >/dev/null 2>&1
grep -F "rclone copy fmmem:testbucket/memory/data" "$CMDLOG" | grep -qv -- "--update" \
  || fail "pull --force must omit --update"
pass "pull --force omits --update"

new_logs pullnewer; new_home
out=$(fake_env FM_HOME="$HOME_DIR" FAKE_RCLONE_NEWER=captain.md \
  "$ROOT/bin/fm-memory-pull.sh" 2>&1); code=$?
expect_code 0 "$code" "pull with newer local files"
assert_contains "$out" "NOT overwritten" "pull reports newer-local skips loudly"
assert_contains "$out" "data/captain.md" "pull names the skipped file"
assert_contains "$out" "--force" "pull offers --force as the explicit overwrite path"
pass "pull says so when it declines to overwrite newer local files"

new_logs pullempty; new_home
out=$(fake_env FM_HOME="$HOME_DIR" FAKE_RCLONE_LSF_EMPTY=1 \
  "$ROOT/bin/fm-memory-pull.sh" 2>&1); code=$?
expect_code 0 "$code" "pull with no remote snapshot"
assert_contains "$out" "nothing restored" "pull is safe when the bucket has no snapshot"
assert_no_grep "rclone copy" "$CMDLOG" "pull does not copy from an absent snapshot"
pass "pull on a fresh bucket is a safe no-op"

# --- real-bucket end-to-end (self-skipping) ----------------------------------

e2e_ready=1
for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
  [ -n "${!var:-}" ] || e2e_ready=0
done
command -v rclone >/dev/null 2>&1 || e2e_ready=0

if [ "$e2e_ready" = 1 ]; then
  # shellcheck source=bin/fm-memory-lib.sh
  . "$ROOT/bin/fm-memory-lib.sh"
  fm_memory_rclone lsf "fmmem:$R2_BUCKET" --max-depth 1 >/dev/null 2>&1 || e2e_ready=0
fi

if [ "$e2e_ready" != 1 ]; then
  pass "real-bucket e2e skipped (no R2 credentials, rclone, or reachable bucket)"
else
  FM_MEMORY_PREFIX="memory-selftest-$$-$(date +%s)"
  export FM_MEMORY_PREFIX
  e2e_purge() {
    fm_memory_rclone purge "fmmem:$R2_BUCKET/$FM_MEMORY_PREFIX" >/dev/null 2>&1 || true
  }
  trap 'e2e_purge; fm_test_cleanup' EXIT

  SRC=$(mktemp -d "$TMP/e2e-src.XXXXXX")
  mkdir -p "$SRC/data/task-1" "$SRC/config" "$SRC/state"
  printf 'captain prefs v1\n' > "$SRC/data/captain.md"
  printf 'brief body\n' > "$SRC/data/task-1/brief.md"
  printf 'codex\n' > "$SRC/config/crew-harness"
  printf 'volatile\n' > "$SRC/state/x.status"

  out=$(FM_HOME="$SRC" "$ROOT/bin/fm-memory-push.sh" 2>&1) \
    || fail "e2e push failed: $out"

  DST=$(mktemp -d "$TMP/e2e-dst.XXXXXX")
  out=$(FM_HOME="$DST" "$ROOT/bin/fm-memory-pull.sh" 2>&1) \
    || fail "e2e pull failed: $out"
  diff -r "$SRC/data" "$DST/data" >/dev/null || fail "e2e data/ mismatch after pull"
  diff -r "$SRC/config" "$DST/config" >/dev/null || fail "e2e config/ mismatch after pull"
  assert_absent "$DST/state/x.status" "e2e must not restore state/"
  pass "real e2e: push then pull into a wiped home restores data/ and config/ byte-identical"

  sleep 1
  printf 'captain prefs LOCAL EDIT\n' > "$DST/data/captain.md"
  out=$(FM_HOME="$DST" "$ROOT/bin/fm-memory-pull.sh" 2>&1) \
    || fail "e2e second pull failed: $out"
  assert_contains "$out" "NOT overwritten" "e2e newer-local file is reported"
  assert_grep "LOCAL EDIT" "$DST/data/captain.md" "e2e newer-local file kept intact"
  pass "real e2e: pull refuses to overwrite a newer local file and says so"

  out=$(FM_HOME="$DST" "$ROOT/bin/fm-memory-pull.sh" --force 2>&1) \
    || fail "e2e --force pull failed: $out"
  assert_grep "captain prefs v1" "$DST/data/captain.md" "e2e --force restores snapshot content"
  pass "real e2e: pull --force overwrites from the snapshot"

  e2e_purge
fi

echo "fm-memory-sync: all tests passed"
