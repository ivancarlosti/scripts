# Move sub-documentation to /docs and refresh S3 → Backblaze docs

## Context

The repository kept one `README-<module>.md` file per module in the repository root, and the
`s3-to-backblaze` Lambda was rewritten as a chunked, resumable job (commit `a2cd61e`) while its
documentation still described the old single-invocation copy with a `{bucket}/{timestamp}/{key}`
layout. The organization standards require all documentation under `/docs`, implementation plans
under `/plans`, and a `.dockerignore` that excludes `docs`, `plans`, `docker` and `.github`.

## Goal

- Single documentation location: `/docs/<module>.md`, with the root `README.md` kept as a
  high-level overview that links into it.
- `docs/aws-lambda.md` matches the current `lambda_function_s3-to-backblaze.py` and
  `lambda_policy_s3-to-backblaze.json` (payload, chunking, checkpoints, incremental skips,
  multipart, hardening, return value, IAM permissions, function settings).
- No broken relative links, no duplicate backup documentation.
- `.dockerignore` present with `docs`, `plans`, `docker`, `.github`; `.gitignore` must not ignore
  those paths (none exists, so nothing to change).

## Steps

1. `git mv` the six module READMEs into `docs/` with module names (`aws-lambda.md`,
   `backup-scripts.md`, `cloudflare-worker.md`, `computerinfo-scripts.md`, `linux-scripts.md`,
   `oci-scripting.md`).
2. Merge the legacy `README-backup.md` content (cron/chmod setup, external articles) into
   `docs/backup-scripts.md`; that content was already fully covered, so the duplicate was removed.
3. Rewrite relative links inside the moved files (`lambda_*.py` → `../aws-lambda/...`,
   `linux-scripts/...` → `../linux-scripts/...`, and equivalents) and add a back-link to the
   project overview.
4. Replace the `s3-to-backblaze` section in `docs/aws-lambda.md` with the current behaviour and
   update the IAM policy table plus the Notes section.
5. Update the root `README.md`: project tree, version (`4.17.0`, matching `manifest.json`), section
   links and "See …" links.
6. Add `.dockerignore` with the four mandatory entries.
7. Validate: JSON parses, Python file compiles, every relative Markdown link resolves.

## Risks

- **Deep links:** external pages pointing at `README-*.md` will 404 after the move. GitHub does not
  redirect; the raw URLs used by the `curl | bash` snippets target script files, not docs, so they
  are unaffected.
- **Version drift:** `README.md` was pinned to `4.0.11` while `manifest.json` was at `4.17.0`;
  semantic-release will keep bumping the manifest, so the README version must be kept in sync or
  turned into a badge.
- **Documented side effects:** the new hardening block can enable bucket versioning on production
  buckets. The docs recommend `dry_run: true` first; the code defaults to disabled when the block
  is absent, so existing invocations are unchanged.
