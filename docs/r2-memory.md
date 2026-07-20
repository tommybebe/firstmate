# R2 persistent memory sync

Cloud firstmate sessions are ephemeral: the container loses `data/` and `config/` between runs.
`bin/fm-memory-push.sh` and `bin/fm-memory-pull.sh` back those two directories up to an S3-compatible Cloudflare R2 bucket and restore them into a fresh clone.

## Experiment status (read this first in a new session)

This is an early experiment, started 2026-07-20, living only on the fork's `claude/r2-persistent-memory-k5sivy` branch.
R2 was the first storage candidate tried, chosen with no comparative data; it is a testbed, not a decision, and other backends remain unevaluated.
Do not open a PR to the upstream repo (`kunchenguid/firstmate`) with this work until the approach is fully tested and deliberately chosen as the best option - the captain's standing rule, also recorded in the memory snapshot's `data/captain.md`.

What exists and is intended so far:

- `bin/fm-memory-push.sh` mirrors `data/` and `config/` to the bucket's `memory/` prefix; `state/` and `projects/` are deliberately excluded.
- `bin/fm-memory-pull.sh` restores them; safe on a fresh clone, never deletes local files, refuses (loudly, with `--force` as the override) to overwrite local files newer than the snapshot.
- `bin/fm-memory-lib.sh` holds the shared credential checks and the environment-only rclone configuration.
- `tests/fm-memory-sync.test.sh` covers both with fake-rclone unit tests plus a self-skipping real-bucket e2e.
- The stub at the top of `AGENTS.md` section 3 is the fresh-session entry point: pull before session start digests `data/`, push after durable changes.
- Not yet built, pending the experiment's verdict: automatic pull/push wiring inside `fm-session-start.sh` or hooks, backend comparison, and any upstreaming.

## Fresh-session test protocol

1. Confirm the four `R2_*` variables are present (existence only; never print values).
2. Confirm rclone is installed (`apt-get update && apt-get install -y rclone` in the cloud sandbox).
3. Run `bin/fm-memory-pull.sh` and confirm it restores `data/captain.md` containing the captain's standing rules - that file round-tripping is the experiment's core success signal.
4. Exercise a change: edit or add a file under `data/`, run `bin/fm-memory-push.sh`, and confirm the object changed (`rclone lsf` via the lib, or a second pull into a temp `FM_HOME`).
5. Confirm the newer-local guard: edit a restored file locally, pull again, and expect the loud NOT-overwritten report instead of silent loss.
6. Record observations (latency, quirks, failures) here in the verification record, dated, with exact commands and output.

## Usage

```sh
bin/fm-memory-push.sh [--dry-run]            # mirror data/ and config/ up to the bucket
bin/fm-memory-pull.sh [--dry-run] [--force]  # restore them; never deletes local files
```

Both require `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, and `R2_BUCKET` in the environment, fail loudly naming any that are missing, and never print their values.
Objects live under a `memory/` prefix (`FM_MEMORY_PREFIX` overrides it, which the test suite uses to keep its traffic out of the real snapshot).
`state/` and `projects/` are deliberately excluded: state is volatile runtime signal and projects are re-clonable.
Push is a mirror per directory (local deletions propagate to the snapshot); pull is additive (local-only files are never deleted) and by default skips and loudly lists any local file newer than its snapshot copy, with `--force` as the explicit overwrite path.
The bucket is never created by these scripts (`no_check_bucket=true`); a missing bucket is a loud error instead.
Credentials travel to rclone only as child-process environment variables (`RCLONE_CONFIG_FMMEM_*`), never on the command line.

## Empirical verification record

All facts below were verified 2026-07-19 and 2026-07-20 against rclone 1.60.1 on Ubuntu 24.04 and a real R2 bucket, inside a Claude Code remote session routed through the CCR agent proxy.

- rclone's S3 backend cannot consume the `AWS_CA_BUNDLE` env var that the CCR environment pre-sets: `rclone lsf` fails with `LoadCustomCABundleError: unable to load custom CA bundle, HTTPClient's transport unsupported type: *fshttp.Transport`.
  `fm_memory_rclone` therefore strips `AWS_CA_BUNDLE` (`env -u`) and passes the same bundle through rclone's own `RCLONE_CA_CERT`, keeping TLS verification on.
- The newer-destination skip that pull's report depends on is logged by rclone 1.60.1 at DEBUG level, not INFO: `DEBUG : f.md: Destination is newer than source, skipping` (newer rclone releases log it at INFO).
  Pull therefore runs rclone with `-vv --log-file` and matches the message at any level.
- First-write quirk: the first PutObject of an rclone invocation against the bucket intermittently returned `NotImplemented: Not Implemented (status code: 501)` and succeeded on rclone's automatic retry (`Attempt 2/3 succeeded`).
  No action needed; rclone's default 3 retries absorb it.
- A TLS `handshake_failure` (alert 40) from `<accountid>.r2.cloudflarestorage.com`, before any HTTP exchange, from every client and every vantage point, meant R2 was not enabled on the account: Cloudflare provisions the per-account S3 endpoint (SNI routing and certificate) only once the R2 subscription is added.
  Adding the subscription and creating the bucket fixed it within a minute; the same failure is also the signature of a wrong account hash in `R2_ENDPOINT` or a jurisdiction-scoped bucket (`<accountid>.eu.r2.cloudflarestorage.com`) addressed via the plain hostname.

The end-to-end proof (push a fixture home, pull into a wiped home, byte-identical `diff -r`, newer-local skip report, `--force` overwrite, purge) is automated as the self-skipping tail of `tests/fm-memory-sync.test.sh`: it runs only when the four `R2_*` variables are set, rclone is installed, and the bucket answers, so CI without credentials skips it cleanly.
