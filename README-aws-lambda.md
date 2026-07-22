# AWS Lambda Scripts

Collection of Python Lambda functions for AWS infrastructure management, cost tracking, backup monitoring, and DNS export — designed to be invoked remotely by **n8n** workflows.

---

## ⚙️ Configuration

| Setting | Value |
|---------|-------|
| **Runtime** | Python 3.13+ |
| **Architecture** | arm64 or x86_64 (arm64 is cheaper) |
| **Timeout** | 1 minute |
| **Permissions** | Attach the corresponding `lambda_policy_*.json` to the function's IAM role |

---

## 📋 Lambda Functions

### [`lambda_function_addtag.py`](lambda_function_addtag.py)
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

### [`lambda_function_backup-alert.py`](lambda_function_backup-alert.py)
**Purpose:** Monitors AWS Backup jobs and surfaces failures for alerting.

- Queries for jobs in `FAILED` or `EXPIRED` state within the **last 1 day**.
- Calls `describe_backup_job` on each result to pull extended details.
- Returns a JSON array with: `BackupJobId`, `ResourceArn`, `BackupVaultName`, `Status`, `StatusMessage`, `CompletionDate`, `BackupType`, `BytesTransferred`, `IAMRoleArn`.

---

### [`lambda_function_counting.py`](lambda_function_counting.py)
**Purpose:** Counts resources grouped by `Tenant` tag for asset tracking and billing allocation.

- **EC2 instances:** Scans `sa-east-1` and `us-east-1` regions. Groups by `(Tenant, SKU)`. Includes a hardcoded SKU map for `t3a.*` and `t4g.*` instance families. Unidentified instance types appear as `UNIDENTIFIED`.
- **Route53 hosted zones:** Groups by `Tenant` tag (zones without a tag appear as `_NoTag`).
- Returns a report with: `Tenant`, `AWS_product`, `Asset Count`, `SKU`, and `AWS_resources` (comma-separated names).

---

### [`lambda_function_dailyusage.py`](lambda_function_dailyusage.py)
**Purpose:** Queries AWS Cost Explorer for **daily** unblended cost breakdown.

- Groups by `Tenant` tag and `USAGE_TYPE` dimension.
- Derives a human-readable service name: `EC2 (Instance)`, `EC2 (EBS Storage)`, `VPC (NAT Gateway)`, `Data Transfer`, `S3`, `Lambda`, `Tax`, or `Other Services`.
- Defaults to **yesterday** if no `start_date`/`end_date` is provided in the event.
- Filters out zero-cost entries. Returns `Date`, `Tenant`, `Service`, `Usage_Detail`, and `Cost_USD`.

---

### [`lambda_function_monthlyusage.py`](lambda_function_monthlyusage.py)
**Purpose:** Queries AWS Cost Explorer for **monthly** unblended cost breakdown.

- Groups by `Tenant` tag and `SERVICE` dimension.
- Defaults to the **previous full month** if no date range is provided.
- Untagged resources appear as `_NoTag`.
- Returns `Tenant`, `Service`, and `Cost (USD)`.

---

### [`lambda_function_route53-bind.py`](lambda_function_route53-bind.py)
**Purpose:** Exports all Route53 hosted zones in **BIND zone file format**.

- Reads the real SOA and NS records from each hosted zone.
- Appends all other resource records with proper TTL and formatting.
- Uses `@` for the root domain name.
- Returns a JSON array with `domain` and `bind_file` (the full zone file as a string).

---

### [`lambda_function_s3-to-backblaze.py`](lambda_function_s3-to-backblaze.py)
**Purpose:** Copies all S3 buckets (with optional exclusions) to a **Backblaze B2** bucket.

- Accepts Backblaze credentials and configuration via the event payload:
  - `backblaze_key_id` — B2 application key ID
  - `backblaze_key` — B2 application key secret
  - `backblaze_endpoint` — S3-compatible endpoint (e.g., `s3.us-west-004.backblazeb2.com`)
  - `dest_bucket` — destination B2 bucket name
  - `exclude_buckets` — optional array of S3 bucket names to skip
- Objects are stored as `{source-bucket}/{ISO-timestamp}/{key}`.
- Sets metadata (`original-bucket`, `backup-timestamp`) on each copied object.
- Logs progress every 100 objects.

---

## 🔐 IAM Policy Files

Each Lambda function requires its corresponding policy attached to its execution role:

| Policy File | Function | Key Permissions |
|-------------|----------|-----------------|
| [`lambda_policy_addtag.json`](lambda_policy_addtag.json) | `addtag` | `ec2:Describe*` + `ec2:CreateTags`, `kms:ListAliases` + `kms:ListResourceTags` + `kms:TagResource`, `route53:ListHostedZones` + `route53:ListTagsForResource` + `route53:ChangeTagsForResource` |
| [`lambda_policy_backup-alert.json`](lambda_policy_backup-alert.json) | `backup-alert` | `backup:ListBackupJobs`, `backup:DescribeBackupJob` |
| [`lambda_policy_counting.json`](lambda_policy_counting.json) | `counting` | `route53:ListHostedZones` + `route53:ListTagsForResource`, `ec2:DescribeInstances` |
| [`lambda_policy_dailyusage.json`](lambda_policy_dailyusage.json) | `dailyusage` | Full Cost Explorer read-only suite (`ce:Get*`) |
| [`lambda_policy_monthlyusage.json`](lambda_policy_monthlyusage.json) | `monthlyusage` | Full Cost Explorer read-only suite (`ce:Get*`) |
| [`lambda_policy_route53-bind.json`](lambda_policy_route53-bind.json) | `route53-bind` | `route53:ListHostedZones`, `route53:ListResourceRecordSets` |
| [`lambda_policy_s3-to-backblaze.json`](lambda_policy_s3-to-backblaze.json) | `s3-to-backblaze` | `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:ListBucket`, `s3:GetObject`, `s3:GetObjectVersion` |

---

## 🔗 Remote Invocation

To invoke Lambda functions from external services (e.g., n8n), create an IAM user and attach the shared policy:

| File | Description |
|------|-------------|
| [`remotecall_policy_lambda.json`](remotecall_policy_lambda.json) | Grants `lambda:InvokeFunction` on all functions, plus `lambda:ListFunctions`, `lambda:GetFunction`, `lambda:GetAccountSettings`, and `lambda:ListTags`. |

---

## 📝 Notes

- **AddTag:** Uses KMS alias names (without `alias/` prefix) and Route53 zone descriptions as `Tenant` tag sources.
- **Backup Alert:** Uses a 1-day lookback window to gather failed and expired job alerts.
- **Billing / AddTag:** Both rely on the `Tenant` tag being present on resources for accurate grouping.
- **Counting:** SKU map is hardcoded; unrecognized instance types are labeled `UNIDENTIFIED`.

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
