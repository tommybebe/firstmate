# R2 persistent memory sync

Cloud firstmate sessions are ephemeral: the container loses `data/` and `config/` between runs.
`bin/fm-memory-push.sh` and `bin/fm-memory-pull.sh` back those two directories up to an S3-compatible Cloudflare R2 bucket and restore them into a fresh clone.

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
