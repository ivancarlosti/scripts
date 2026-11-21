# AWS Lambda Scripts

> Part of the [scripts](../README.md) collection.

Collection of Python Lambda functions for AWS infrastructure management, cost tracking, backup monitoring, and DNS export — designed to be invoked remotely by **n8n** workflows.

---

## ⚙️ Configuration

| Setting | Value |
|---------|-------|
| **Runtime** | Python 3.13+ |
| **Architecture** | arm64 or x86_64 (arm64 is cheaper) |
| **Timeout** | 1 minute for most functions; **15 minutes** for `s3-to-backblaze` (must exceed `max_seconds`, default 720 s) |
| **Permissions** | Attach the corresponding `lambda_policy_*.json` to the function's IAM role |

---

## 📋 Lambda Functions

### [`lambda_function_addtag.py`](../aws-lambda/lambda_function_addtag.py)
**Purpose:** Propagates a `Tenant` tag across untagged AWS resources by tracing ownership from EC2 instances.

**Resources processed:**
| Resource | Tenant Source |
|----------|---------------|
| AMIs | Extracts instance ID from AMI name/description, then reads the instance's `Tenant` tag |
| EBS Volumes | Reads `Tenant` from attached EC2 instance or its AMI |
| EBS Snapshots | Reads `Tenant` from the source volume |
| Network Interfaces (ENIs) | Reads `Tenant` from attached EC2 instance |
| Elastic IPs (EIPs) | Reads `Tenant` from associated EC2 instance |
| KMS Keys | Uses the KMS alias name (stripping `alias/` prefix) as the `Tenant` value |
| Route53 Hosted Zones | Uses the zone's description/comment as the `Tenant` value |

**Behavior:** Skips already-tagged resources. Returns a detailed JSON report listing each resource's type, ID, tenant value, and status (`TagAdded`, `AlreadyTagged`, or an error description).

---

### [`lambda_function_backup-alert.py`](../aws-lambda/lambda_function_backup-alert.py)
**Purpose:** Monitors AWS Backup jobs and surfaces failures for alerting.

- Queries for jobs in `FAILED` or `EXPIRED` state within the **last 1 day**.
- Calls `describe_backup_job` on each result to pull extended details.
- Returns a JSON array with: `BackupJobId`, `ResourceArn`, `BackupVaultName`, `Status`, `StatusMessage`, `CompletionDate`, `BackupType`, `BytesTransferred`, `IAMRoleArn`.

---

### [`lambda_function_counting.py`](../aws-lambda/lambda_function_counting.py)
**Purpose:** Counts resources grouped by `Tenant` tag for asset tracking and billing allocation.

- **EC2 instances:** Scans `sa-east-1` and `us-east-1` regions. Groups by `(Tenant, SKU)`. Includes a hardcoded SKU map for `t3a.*` and `t4g.*` instance families. Unidentified instance types appear as `UNIDENTIFIED`.
- **Route53 hosted zones:** Groups by `Tenant` tag (zones without a tag appear as `_NoTag`).
- Returns a report with: `Tenant`, `AWS_product`, `Asset Count`, `SKU`, and `AWS_resources` (comma-separated names).

---

### [`lambda_function_dailyusage.py`](../aws-lambda/lambda_function_dailyusage.py)
**Purpose:** Queries AWS Cost Explorer for **daily** unblended cost breakdown.

- Groups by `Tenant` tag and `USAGE_TYPE` dimension.
- Derives a human-readable service name: `EC2 (Instance)`, `EC2 (EBS Storage)`, `VPC (NAT Gateway)`, `Data Transfer`, `S3`, `Lambda`, `Tax`, or `Other Services`.
- Defaults to **yesterday** if no `start_date`/`end_date` is provided in the event.
- Filters out zero-cost entries. Returns `Date`, `Tenant`, `Service`, `Usage_Detail`, and `Cost_USD`.

---

### [`lambda_function_monthlyusage.py`](../aws-lambda/lambda_function_monthlyusage.py)
**Purpose:** Queries AWS Cost Explorer for **monthly** unblended cost breakdown.

- Groups by `Tenant` tag and `SERVICE` dimension.
- Defaults to the **previous full month** if no date range is provided.
- Untagged resources appear as `_NoTag`.
- Returns `Tenant`, `Service`, and `Cost (USD)`.

---

### [`lambda_function_route53-bind.py`](../aws-lambda/lambda_function_route53-bind.py)
**Purpose:** Exports all Route53 hosted zones in **BIND zone file format**.

- Reads the real SOA and NS records from each hosted zone.
- Appends all other resource records with proper TTL and formatting.
- Uses `@` for the root domain name.
- Returns a JSON array with `domain` and `bind_file` (the full zone file as a string).

---

### [`lambda_function_s3-to-backblaze.py`](../aws-lambda/lambda_function_s3-to-backblaze.py)
**Purpose:** Mirrors every S3 bucket (with optional exclusions) to a **Backblaze B2** bucket through B2's S3-compatible API — as a **chunked, resumable job** with optional versioning/lifecycle hardening.

**Why it is chunked:** a full account copy does not fit in Lambda's 15-minute limit, and the n8n AWS Lambda node aborts the HTTP request after 300 s (hard-coded axios timeout, not configurable). Each invocation therefore works for a bounded time budget, checkpoints its progress to S3 and re-invokes itself asynchronously (`InvocationType=Event`), returning to the caller in under a second with `"status": "running"`.

#### Event payload

| Key | Required | Description |
|-----|----------|-------------|
| `backblaze_key_id` | ✅ | B2 application key ID |
| `backblaze_key` | ✅ | B2 application key secret |
| `backblaze_endpoint` | ✅ | S3-compatible endpoint, e.g. `s3.us-west-004.backblazeb2.com` (the B2 region is derived from it) |
| `dest_bucket` | ✅ | Destination B2 bucket name |
| `state_bucket` | ✅ | S3 bucket **in the same account** holding the job checkpoints |
| `exclude_buckets` | — | S3 bucket names to skip (the `state_bucket` is always skipped) |
| `dest_prefix` | — | Optional key prefix on the destination |
| `max_seconds` | — | Time budget per invocation, default `720` (12 min) |
| `notify_url` | — | Optional webhook (n8n) POSTed with the final result |
| `job_id` | — | Set by the function itself on self-invocation; sending the `job_id` of a finished job only re-reports it |
| `hardening` | — | Optional bucket settings reconciliation — see below |

```json
{
  "backblaze_key_id": "0033...",
  "backblaze_key": "...",
  "backblaze_endpoint": "s3.us-west-004.backblazeb2.com",
  "dest_bucket": "my-backup",
  "state_bucket": "my-backup-state",
  "exclude_buckets": ["temp-bucket"],
  "dest_prefix": "aws/",
  "max_seconds": 720,
  "notify_url": "https://n8n.example.com/webhook/backup-done",
  "hardening": {
    "enabled": true,
    "dry_run": false,
    "versioning": true,
    "lifecycle": true
  }
}
```

#### What a job does

1. Enumerates all buckets once (skipping `exclude_buckets` and `state_bucket`) and writes the work queue to `s3://<state_bucket>/_backup-state/<job_id>.json`.
2. Runs the optional **hardening** pass before copying anything, so new buckets are protected before the first byte is copied.
3. Lists each bucket with `ListObjectsV2` (1 000 keys per page) and copies to `{dest_prefix}{source-bucket}/{key}` — **no timestamp folder**, so the destination layout is stable and re-runs are incremental.
4. Skips objects already on B2 with the same key **and the same size** (counted as `skipped`).
5. Copies objects **≥ 32 MB** with a multipart upload fed by 64 MB ranged GETs: memory stays flat and objects above `put_object`'s 5 GB limit are supported. Failed multipart uploads are aborted, never left as orphaned parts.
6. Checkpoints after every listing page and every 50 objects; when the budget runs out it self-invokes and resumes from the checkpoint (no re-listing, no re-`HEAD` of already-processed keys).
7. Records per-object failures (up to 200; the response keeps the first 5) and **never aborts the whole job** for one bad object — a new job retries them.
8. Stops the chain with `"status": "stalled"` if an invocation makes no progress at all, instead of looping forever.

#### Object metadata

| Key | Value |
|-----|-------|
| `original-bucket` | Source bucket name |
| `original-key` | Source key, **percent-encoded** |
| `original-key-encoding` | Always `percent` |
| `backup-time` | UTC timestamp of the copy |

Object **keys** are UTF-8 and copy as-is, but S3 user metadata is sent as HTTP headers and botocore rejects anything outside US-ASCII. Metadata values are therefore percent-encoded (reversible with `urllib.parse.unquote`) and capped at 700 chars (with a short hash appended when truncated) to stay under S3's 2 KB metadata limit.

#### Hardening (optional)

Reconciles bucket settings idempotently — read, compare, write only if needed, read back to verify. It runs once per job. Omit the block to keep the previous copy-only behaviour.

| Key | Default | Effect |
|-----|---------|--------|
| `enabled` | `true` (when the block is present) | Master switch |
| `dry_run` | `false` | Report intended changes without writing |
| `versioning` | `true` | `PutBucketVersioning Status=Enabled` on every target bucket |
| `lifecycle` | `false` (or `true` / object) | Upserts one lifecycle rule, **merged by ID**; all other rules are preserved verbatim |
| `exclude_buckets` | `[]` | Glob patterns (`fnmatch`) of buckets to leave untouched |
| `include_excluded_buckets` | `false` | `false` reuses the backup scope (backup buckets + `state_bucket`); `true` targets every bucket |

Lifecycle defaults (override any key inside `lifecycle`): `rule_id` `cleanup-old-deleted`, `prefix` `""` (whole bucket), `noncurrent_days` `30`, `abort_mpu_days` `7`, `expired_delete_markers` `true`.

> **⚠️ Side effects:** enabling versioning increases storage cost and cannot be undone without deleting versions first. Buckets with **MFA Delete** enabled fail that bucket only (recorded in `hardening.errors`). Run once with `"dry_run": true` and review `hardening.changes` before applying.

#### Return value

Every invocation returns quickly; the real work continues asynchronously.

```json
{
  "status": "running | completed | stalled",
  "ok": true,
  "job_id": "20261121T162400Z-1a2b3c4d",
  "state": "s3://my-backup-state/_backup-state/20261121T162400Z-1a2b3c4d.json",
  "stats": {"copied": 1234, "skipped": 56, "failed": 0, "bytes": 123456789},
  "failures_sample": [],
  "invocations": 3,
  "hardening": {
    "dry_run": false,
    "pending": 0,
    "changes": [{"bucket": "b1", "changes": ["versioning: enabled", "lifecycle: rule created (1 rule(s) in bucket)"]}],
    "unchanged": 12,
    "errors": []
  }
}
```

- `ok: false` means the job finished but some objects still failed upstream of B2 — check `failures_sample` and run a new job to retry them.
- `notify_url` receives this same object when the job completes.

#### Function settings

| Setting | Value |
|---------|-------|
| **Timeout** | **15 minutes** — must be greater than `max_seconds` (the code keeps 15 s of headroom) |
| **Memory** | 512 MB recommended (small objects are read fully; multipart buffers 64 MB per part) |
| **IAM policy** | [`lambda_policy_s3-to-backblaze.json`](../aws-lambda/lambda_policy_s3-to-backblaze.json) |

---

## 🔐 IAM Policy Files

Each Lambda function requires its corresponding policy attached to its execution role:

| Policy File | Function | Key Permissions |
|-------------|----------|-----------------|
| [`lambda_policy_addtag.json`](../aws-lambda/lambda_policy_addtag.json) | `addtag` | `ec2:Describe*` + `ec2:CreateTags`, `kms:ListAliases` + `kms:ListResourceTags` + `kms:TagResource`, `route53:ListHostedZones` + `route53:ListTagsForResource` + `route53:ChangeTagsForResource` |
| [`lambda_policy_backup-alert.json`](../aws-lambda/lambda_policy_backup-alert.json) | `backup-alert` | `backup:ListBackupJobs`, `backup:DescribeBackupJob` |
| [`lambda_policy_counting.json`](../aws-lambda/lambda_policy_counting.json) | `counting` | `route53:ListHostedZones` + `route53:ListTagsForResource`, `ec2:DescribeInstances` |
| [`lambda_policy_dailyusage.json`](../aws-lambda/lambda_policy_dailyusage.json) | `dailyusage` | Full Cost Explorer read-only suite (`ce:Get*`) |
| [`lambda_policy_monthlyusage.json`](../aws-lambda/lambda_policy_monthlyusage.json) | `monthlyusage` | Full Cost Explorer read-only suite (`ce:Get*`) |
| [`lambda_policy_route53-bind.json`](../aws-lambda/lambda_policy_route53-bind.json) | `route53-bind` | `route53:ListHostedZones`, `route53:ListResourceRecordSets` |
| [`lambda_policy_s3-to-backblaze.json`](../aws-lambda/lambda_policy_s3-to-backblaze.json) | `s3-to-backblaze` | `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:ListBucket`, `s3:GetObject`, `s3:GetObjectVersion`; `s3:PutObject` scoped to `arn:aws:s3:::*/_backup-state/*`; `lambda:InvokeFunction` (self-continuation); `s3:GetBucketVersioning` + `s3:PutBucketVersioning` and `s3:GetLifecycleConfiguration` + `s3:PutLifecycleConfiguration` for hardening |

---

## 🔗 Remote Invocation

To invoke Lambda functions from external services (e.g., n8n), create an IAM user and attach the shared policy:

| File | Description |
|------|-------------|
| [`remotecall_policy_lambda.json`](../aws-lambda/remotecall_policy_lambda.json) | Grants `lambda:InvokeFunction` on all functions, plus `lambda:ListFunctions`, `lambda:GetFunction`, `lambda:GetAccountSettings`, and `lambda:ListTags`. |

---

## 📝 Notes

- **AddTag:** Uses KMS alias names (without `alias/` prefix) and Route53 zone descriptions as `Tenant` tag sources.
- **Backup Alert:** Uses a 1-day lookback window to gather failed and expired job alerts.
- **Billing / AddTag:** Both rely on the `Tenant` tag being present on resources for accurate grouping.
- **Counting:** SKU map is hardcoded; unrecognized instance types are labeled `UNIDENTIFIED`.
- **S3 → B2:** The backup role needs `lambda:InvokeFunction` on itself (self-continuation) and the function timeout must exceed `max_seconds`. Writes to the AWS account are limited to `s3:PutObject` under `*/_backup-state/*`; B2 writes are authorised by the B2 application key, not by this policy. `s3:GetObjectVersion` is granted but not used by the current code path (it copies the latest version of each key) — remove it if you prefer a tighter policy, and narrow `lambda:InvokeFunction` from `arn:aws:lambda:*:*:function:*` to the function's own ARN.
- **S3 → B2 credentials:** the B2 keys travel in the event payload of every self-invocation (Lambda keeps the payload of asynchronous invocations while retrying) and are **never** written to the checkpoint. Use a dedicated B2 application key scoped to the destination bucket, rotate it periodically, and inject it from n8n credentials rather than hard-coding it in the workflow.

---

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support

- For personal support and queries, please submit a new issue to have it addressed.
- For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

| 🩷 Project support |
| :---: |
| If you found this project helpful, consider [**buying me a coffee**][buymeacoffee] |
| Thanks for your support, it is much appreciated! |

[ivancarlos]: https://ivancarlos.me
[buymeacoffee]: https://www.buymeacoffee.com/ivancarlos
