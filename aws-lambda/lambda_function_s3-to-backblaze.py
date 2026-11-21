"""
S3 -> Backblaze B2 backup, chunked across Lambda invocations.

Why this shape: a single 25-minute invocation does not fit inside Lambda's execution
limit, and n8n's AWS Lambda node aborts the HTTP request after 300 s (hard-coded
axios timeout, not configurable). So each invocation works within a time budget
(~12 min), persists its progress to S3, and re-invokes itself asynchronously
(InvocationType=Event) whenever work is left, returning to the caller in <1 s.

Invocation payload (sent by n8n):
{
  "backblaze_key_id": "...",
  "backblaze_key": "...",
  "backblaze_endpoint": "s3.us-west-004.backblazeb2.com",
  "dest_bucket": "my-backup",
  "state_bucket": "my-state-bucket",    # S3 bucket in the same account, holds checkpoints
  "exclude_buckets": ["temp-bucket"],
  "dest_prefix": "",                    # optional key prefix on the destination
  "max_seconds": 720,                   # time budget per invocation (default 720)
  "notify_url": "https://n8n.../webhook/backup-done",  # optional: POSTed when finished
  "job_id": "...",                      # set by the function itself on self-invocation

  # OPTIONAL: reconcile bucket settings before copying (omit = no change in behaviour)
  "hardening": {
    "enabled": true,                    # default true when the block is present
    "dry_run": false,                   # true: report only, never write
    "versioning": true,                 # PutBucketVersioning Status=Enabled
    "lifecycle": {                      # false to skip; true/{} for the defaults below
      "rule_id": "cleanup-old-deleted", # rules are merged BY ID, other rules untouched
      "prefix": "",                     # "" = entire bucket
      "noncurrent_days": 30,            # delete noncurrent versions 30 days after they age out
      "abort_mpu_days": 7,              # abort incomplete multipart uploads after 7 days
      "expired_delete_markers": true    # remove delete markers with no noncurrent versions
    },
    "exclude_buckets": ["legacy-*"],    # glob patterns, matched with fnmatch
    "include_excluded_buckets": false   # false: reuse the backup "exclude_buckets" list
  }
}

Hardening runs once per job (once per day, since n8n starts a new job each run), before
any object is copied, and is a no-op on buckets that already conform. It is idempotent:
every action is read -> compare -> write-if-needed -> read back to verify. A failure on
one bucket is recorded in the report and never aborts the backup.

Latin characters: object KEYS are UTF-8 and copy fine, but S3 user metadata is
transmitted as HTTP headers and botocore rejects anything outside US-ASCII, so every
metadata value goes through _ascii_metadata() (percent-encoding, reversible).

Return value (fast, synchronous):
{"status": "running" | "completed" | "stalled", "job_id": "...", "state": "s3://...",
 "ok": bool, "stats": {...}, "failures_sample": [...], "invocations": N,
 "hardening": {"dry_run": false, "pending": 0, "unchanged": 12,
               "changes": [{"bucket": "b1", "changes": ["versioning: enabled",
                           "lifecycle: rule created (1 rule(s) in bucket)"]}],
               "errors": [{"bucket": "b2", "code": "InvalidBucketState", "error": "..."}]}}

Required permissions for the function role:
  s3:ListAllMyBuckets, s3:ListBucket, s3:GetObject on the source buckets,
  s3:PutObject / s3:GetObject on the state bucket, lambda:InvokeFunction on itself,
  s3:GetBucketVersioning + s3:PutBucketVersioning      (hardening.versioning)
  s3:GetLifecycleConfiguration + s3:PutLifecycleConfiguration  (hardening.lifecycle)
"""

import fnmatch
import hashlib
import json
import logging
import os
import time
import urllib.request
import uuid
from datetime import datetime, timezone
from urllib.parse import quote

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MULTIPART_THRESHOLD = 32 * 1024 * 1024   # above this: multipart fed by ranged GETs
PART_SIZE = 64 * 1024 * 1024             # 64 MB per part
MAX_PUT_SIZE = 5 * 1024 * 1024 * 1024    # put_object refuses objects larger than 5 GB
STATE_PREFIX = "_backup-state/"
MAX_FAILURES = 200                       # cap on the failure list kept in the checkpoint
METADATA_VALUE_LIMIT = 700               # keeps total user metadata under S3's 2 KB cap

# Defaults for the lifecycle rule; identical to the console rule in the screenshot.
HARDEN_RULE_DEFAULTS = {
    "rule_id": "cleanup-old-deleted",
    "prefix": "",
    "noncurrent_days": 30,
    "abort_mpu_days": 7,
    "expired_delete_markers": True,
}
HARDEN_KEYS = {
    "enabled",
    "dry_run",
    "versioning",
    "lifecycle",
    "exclude_buckets",
    "include_excluded_buckets",
}

_BOTO_CFG = Config(
    retries={"max_attempts": 5, "mode": "standard"},
    connect_timeout=10,
    read_timeout=60,
    max_pool_connections=4,
)


def _mono():
    """Monotonic clock, isolated so tests can substitute a virtual clock."""
    return time.monotonic()


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _b2_region(endpoint):
    # s3.us-west-004.backblazeb2.com -> us-west-004
    parts = endpoint.split(".")
    if len(parts) >= 3 and parts[1]:
        return parts[1]
    return "us-west-004"


def _clients(event):
    """Source S3 client (default endpoint) and B2 client (S3-compatible endpoint)."""
    s3 = boto3.client("s3", config=_BOTO_CFG)
    b2 = boto3.client(
        "s3",
        endpoint_url=f"https://{event['backblaze_endpoint']}",
        aws_access_key_id=event["backblaze_key_id"],
        aws_secret_access_key=event["backblaze_key"],
        region_name=_b2_region(event["backblaze_endpoint"]),
        config=_BOTO_CFG,
    )
    return s3, b2


def _state_key(job_id):
    return f"{STATE_PREFIX}{job_id}.json"


def _load_state(s3, state_bucket, job_id):
    """Read the checkpoint; None when this job has never run."""
    try:
        obj = s3.get_object(Bucket=state_bucket, Key=_state_key(job_id))
        return json.loads(obj["Body"].read())
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404", "NotFound"):
            return None
        raise


def _save_state(s3, state_bucket, state):
    """Persist the checkpoint. Called after each listing page and every 50 objects."""
    state["updated_at"] = _now_iso()
    s3.put_object(
        Bucket=state_bucket,
        Key=_state_key(state["job_id"]),
        Body=json.dumps(state).encode(),
        ContentType="application/json",
    )


# --------------------------------------------------------------------------- #
# Hardening: parse the payload block
# --------------------------------------------------------------------------- #
def _parse_hardening(raw):
    """Normalise the optional 'hardening' block. Absent -> disabled (old behaviour)."""
    if not raw:
        return {"enabled": False}
    if raw is True:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError("'hardening' must be an object (or true)")
    unknown = set(raw) - HARDEN_KEYS
    if unknown:
        logger.warning("ignoring unknown hardening keys: %s", sorted(unknown))

    lifecycle = None
    lc_raw = raw.get("lifecycle", False)
    if lc_raw:
        if lc_raw is True:
            lc_raw = {}
        if not isinstance(lc_raw, dict):
            raise ValueError("'hardening.lifecycle' must be an object, true or false")
        lifecycle = dict(HARDEN_RULE_DEFAULTS)
        lifecycle.update({k: v for k, v in lc_raw.items() if k in HARDEN_RULE_DEFAULTS})
        lifecycle["rule_id"] = str(lifecycle["rule_id"]).strip()
        lifecycle["prefix"] = str(lifecycle["prefix"] or "")
        lifecycle["noncurrent_days"] = int(lifecycle["noncurrent_days"])
        lifecycle["abort_mpu_days"] = int(lifecycle["abort_mpu_days"])
        lifecycle["expired_delete_markers"] = bool(lifecycle["expired_delete_markers"])
        if not lifecycle["rule_id"]:
            raise ValueError("'hardening.lifecycle.rule_id' cannot be empty")
        if lifecycle["noncurrent_days"] < 1:
            raise ValueError("'hardening.lifecycle.noncurrent_days' must be >= 1")
        if lifecycle["abort_mpu_days"] < 1:
            raise ValueError("'hardening.lifecycle.abort_mpu_days' must be >= 1")

    cfg = {
        "enabled": bool(raw.get("enabled", True)),
        "dry_run": bool(raw.get("dry_run", False)),
        "versioning": bool(raw.get("versioning", True)),
        "lifecycle": lifecycle,
        "exclude_buckets": [str(p) for p in (raw.get("exclude_buckets") or [])],
        "include_excluded_buckets": bool(raw.get("include_excluded_buckets", False)),
    }
    if cfg["enabled"] and not (cfg["versioning"] or cfg["lifecycle"]):
        logger.warning("hardening enabled but nothing to enforce; treating it as disabled")
        cfg["enabled"] = False
    return cfg


# --------------------------------------------------------------------------- #
# Hardening: enforce versioning + lifecycle on every bucket
# --------------------------------------------------------------------------- #
def _new_hardening_state(cfg, backup_buckets, all_buckets):
    """Build the one-shot reconciliation queue and its report holder."""
    h = cfg["hardening"]
    report = {
        "started_at": _now_iso(),
        "finished_at": None,
        "dry_run": h.get("dry_run", False),
        "changes": [],
        "unchanged": 0,
        "errors": [],
    }
    if not h.get("enabled"):
        return {"pending": [], "report": None}
    if h.get("include_excluded_buckets"):
        source = list(all_buckets)
    else:
        # Reuse the backup scope: buckets excluded from the backup stay untouched,
        # plus the state bucket (tiny versioned checkpoints, harmless to include).
        source = list(backup_buckets) + [cfg["state_bucket"]]
    patterns = h.get("exclude_buckets", [])
    targets = [
        b
        for b in dict.fromkeys(source)          # dedupe, keep order
        if not any(fnmatch.fnmatch(b, p) for p in patterns)
    ]
    logger.info(
        "hardening: %d bucket(s) queued (dry_run=%s, versioning=%s, lifecycle=%s)",
        len(targets),
        bool(h.get("dry_run")),
        bool(h.get("versioning")),
        bool(h.get("lifecycle")),
    )
    return {"cfg": h, "pending": targets, "report": report}


def _rule_prefix(rule):
    """Effective prefix of a rule, tolerating the legacy top-level Prefix field."""
    flt = rule.get("Filter")
    if isinstance(flt, dict):
        if "And" in flt:
            return json.dumps(flt["And"], sort_keys=True)
        return flt.get("Prefix") or ""
    return rule.get("Prefix") or ""


def _rule_conforms(rule, lc):
    """True when the rule already carries exactly the actions we want.

    Compared field by field, never by JSON equality: S3 returns equivalent rules
    with a different field order and with legacy fields, and a naive comparison
    would rewrite every bucket on every run (destroying the drift signal).
    """
    if rule.get("Status") != "Enabled":
        return False
    if _rule_prefix(rule) != lc["prefix"]:
        return False
    nve = rule.get("NoncurrentVersionExpiration") or {}
    if nve.get("NoncurrentDays") != lc["noncurrent_days"]:
        return False
    # "Retain 0 noncurrent versions" is expressed by omitting NewerNoncurrentVersions
    # (the API only accepts 1..100 there).
    if nve.get("NewerNoncurrentVersions"):
        return False
    aim = rule.get("AbortIncompleteMultipartUpload") or {}
    if aim.get("DaysAfterInitiation") != lc["abort_mpu_days"]:
        return False
    if lc["expired_delete_markers"] and not (rule.get("Expiration") or {}).get(
        "ExpiredObjectDeleteMarker"
    ):
        return False
    return True


def _build_rule(existing, lc):
    """Desired rule. Keys we don't manage (Transitions, ...) are preserved as-is."""
    rule = dict(existing) if existing else {}
    rule["ID"] = lc["rule_id"]
    rule["Status"] = "Enabled"
    rule["Filter"] = {"Prefix": lc["prefix"]}
    rule.pop("Prefix", None)                    # legacy field, cannot coexist with Filter
    rule["NoncurrentVersionExpiration"] = {"NoncurrentDays": lc["noncurrent_days"]}
    rule["AbortIncompleteMultipartUpload"] = {"DaysAfterInitiation": lc["abort_mpu_days"]}
    if lc["expired_delete_markers"]:
        rule["Expiration"] = {"ExpiredObjectDeleteMarker": True}
    elif (rule.get("Expiration") or {}).get("ExpiredObjectDeleteMarker"):
        rule.pop("Expiration")
    return rule


def _read_lifecycle(s3, bucket):
    """(rules, configured) — an unconfigured bucket returns ([], False), not an error."""
    try:
        resp = s3.get_bucket_lifecycle_configuration(Bucket=bucket)
        return resp.get("Rules", []), True
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in ("NoSuchLifecycleConfiguration", "NoSuchLifecycle", "404", "NotFound"):
            return [], False
        raise


def _ensure_versioning(s3, bucket, dry_run):
    """Idempotent: enable versioning when it is off or suspended."""
    resp = s3.get_bucket_versioning(Bucket=bucket)
    status = resp.get("Status")
    if status == "Enabled":
        return []
    if resp.get("MFADelete") == "Enabled":
        raise RuntimeError(
            "MFA Delete is enabled on this bucket; versioning cannot be changed without MFA"
        )
    change = "versioning: enabled" if not status else f"versioning: {status.lower()} -> enabled"
    if dry_run:
        return [f"{change} (dry-run)"]
    s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={"Status": "Enabled"})
    if s3.get_bucket_versioning(Bucket=bucket).get("Status") != "Enabled":
        raise RuntimeError("put_bucket_versioning did not take effect")
    return [change]


def _ensure_lifecycle(s3, bucket, lc, dry_run):
    """Upsert our rule by ID; every other rule in the bucket is kept verbatim.

    PutBucketLifecycleConfiguration REPLACES the whole configuration, so a blind
    put would delete rules managed by Terraform / other tooling. Hence read-merge-write.
    """
    rules, configured = _read_lifecycle(s3, bucket)
    existing = next((r for r in rules if r.get("ID") == lc["rule_id"]), None)
    if existing is not None and _rule_conforms(existing, lc):
        return []
    if existing is None:
        action = "rule added" if configured else "rule created"
    else:
        action = "rule updated"
    if dry_run:
        return [f"lifecycle: {action} (dry-run)"]
    merged = [r for r in rules if r.get("ID") != lc["rule_id"]] + [_build_rule(existing, lc)]
    s3.put_bucket_lifecycle_configuration(
        Bucket=bucket, LifecycleConfiguration={"Rules": merged}
    )
    after, _ = _read_lifecycle(s3, bucket)
    applied = next((r for r in after if r.get("ID") == lc["rule_id"]), None)
    if applied is None or not _rule_conforms(applied, lc):
        raise RuntimeError("put_bucket_lifecycle_configuration did not take effect")
    return [f"lifecycle: {action} ({len(merged)} rule(s) in bucket)"]


def _harden_bucket(s3, bucket, h):
    changes = []
    if h.get("versioning"):
        changes.extend(_ensure_versioning(s3, bucket, h.get("dry_run", False)))
    if h.get("lifecycle"):
        changes.extend(_ensure_lifecycle(s3, bucket, h["lifecycle"], h.get("dry_run", False)))
    return changes


def _harden_step(s3, state, deadline):
    """Drain the reconciliation queue until the deadline. True = work left."""
    hs = state.get("hardening") or {}
    pending = hs.get("pending") or []
    if not pending:
        return False
    h, report = hs["cfg"], hs["report"]
    while pending:
        if _mono() >= deadline:
            return True
        bucket = pending.pop(0)
        try:
            changes = _harden_bucket(s3, bucket, h)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            report["errors"].append({"bucket": bucket, "code": code, "error": str(e)[:300]})
            logger.error("hardening %s: %s (code=%s)", bucket, e, code)
            continue
        except Exception as e:  # noqa: BLE001 - one bucket must not stop the sweep
            report["errors"].append({"bucket": bucket, "error": str(e)[:300]})
            logger.error("hardening %s failed: %s", bucket, e)
            continue
        if changes:
            report["changes"].append({"bucket": bucket, "changes": changes})
            logger.info("hardening %s: %s", bucket, "; ".join(changes))
        else:
            report["unchanged"] += 1
    report["finished_at"] = _now_iso()
    logger.info(
        "hardening finished: %d changed, %d already compliant, %d error(s)",
        len(report["changes"]),
        report["unchanged"],
        len(report["errors"]),
    )
    return False


def _new_state(job_id, cfg, all_buckets):
    """Build the initial work queue: one entry per source bucket plus a page cursor."""
    buckets = [
        b
        for b in all_buckets
        if b not in cfg["exclude_buckets"] and b != cfg["state_bucket"]
    ]
    logger.info("job %s: %d bucket(s) queued: %s", job_id, len(buckets), ", ".join(buckets))
    return {
        "job_id": job_id,
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
        "dest_bucket": cfg["dest_bucket"],
        "dest_prefix": cfg["dest_prefix"],
        # Work queue: [{"bucket": name, "token": continuation_token_or_null}, ...]
        "queue": [{"bucket": b, "token": None} for b in buckets],
        # Keys already listed from the current page but not copied yet, so a
        # resumed invocation never has to re-list (and re-HEAD) them.
        "pending": [],
        "stats": {"copied": 0, "skipped": 0, "failed": 0, "bytes": 0},
        "failures": [],
        "invocations": 0,
        "done": False,
        "hardening": _new_hardening_state(cfg, buckets, all_buckets),
    }


def _dest_exists(b2, bucket, key, size):
    """True when the destination already holds an object of the same size."""
    try:
        head = b2.head_object(Bucket=bucket, Key=key)
        return head.get("ContentLength") == size
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def _ascii_metadata(value, limit=METADATA_VALUE_LIMIT):
    """Make a value safe for S3 user metadata.

    S3 object keys are UTF-8, so accented keys are perfectly legal - but user
    metadata is transmitted as HTTP headers and botocore rejects anything outside
    US-ASCII ("Non ascii characters found in S3 metadata"). Percent-encoding keeps
    it reversible (urllib.parse.unquote on the way back) and the length cap keeps
    the whole metadata set under S3's 2 KB limit; when truncating, a short hash is
    appended so two long keys never collide.
    """
    text = str(value)
    encoded = quote(text, safe="/-_. ")
    if len(encoded) > limit:
        digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]
        encoded = f"{encoded[: limit - len(digest) - 1]}~{digest}"
    return encoded or "-"


def _copy_object(s3, b2, src_bucket, key, size, dest_bucket, dest_key, metadata):
    """Copy one object with bounded memory.

    Small objects: single get_object + put_object.
    Large objects: multipart upload fed by ranged GETs, so RAM usage stays flat
    and files above put_object's 5 GB limit work too.
    """
    if size >= MULTIPART_THRESHOLD:
        mpu = b2.create_multipart_upload(
            Bucket=dest_bucket,
            Key=dest_key,
            Metadata=metadata,
            ContentType="application/octet-stream",
        )
        upload_id = mpu["UploadId"]
        parts, offset, number = [], 0, 1
        try:
            while offset < size:
                end = min(offset + PART_SIZE, size) - 1
                chunk = s3.get_object(
                    Bucket=src_bucket, Key=key, Range=f"bytes={offset}-{end}"
                )["Body"].read()
                resp = b2.upload_part(
                    Bucket=dest_bucket,
                    Key=dest_key,
                    UploadId=upload_id,
                    PartNumber=number,
                    Body=chunk,
                )
                parts.append({"ETag": resp["ETag"], "PartNumber": number})
                offset = end + 1
                number += 1
            b2.complete_multipart_upload(
                Bucket=dest_bucket,
                Key=dest_key,
                UploadId=upload_id,
                MultipartUpload={"Parts": parts},
            )
        except Exception:
            # Never leave orphaned parts consuming storage on the B2 side.
            try:
                b2.abort_multipart_upload(Bucket=dest_bucket, Key=dest_key, UploadId=upload_id)
            except Exception:
                logger.warning("could not abort multipart upload for %s", dest_key)
            raise
        return "copied"

    if size > MAX_PUT_SIZE:
        raise ValueError(f"object of {size} bytes exceeds the put_object limit")

    body = s3.get_object(Bucket=src_bucket, Key=key)["Body"].read()
    b2.put_object(
        Bucket=dest_bucket,
        Key=dest_key,
        Body=body,
        Metadata=metadata,
        ContentType="application/octet-stream",
    )
    return "copied"


def _record_failure(state, bucket, key, err):
    """Track a per-object failure without aborting the whole job."""
    state["stats"]["failed"] += 1
    if len(state["failures"]) < MAX_FAILURES:
        state["failures"].append({"bucket": bucket, "key": key, "error": str(err)[:300]})
    logger.error("failed %s/%s: %s", bucket, key, err)


def _process(s3, b2, state, cfg, deadline):
    """Drain the work queue until the deadline. Returns True if work is left."""
    dest_bucket = state["dest_bucket"]
    prefix = state["dest_prefix"]
    since_save = 0

    while True:
        # The clock is checked between objects, never in the middle of a copy.
        if _mono() >= deadline:
            return True

        if state["pending"]:
            item = state["pending"][0]
            key, size = item["Key"], item["Size"]
            if key.endswith("/"):          # zero-byte folder marker
                state["pending"].pop(0)
                continue
            dest_key = f"{prefix}{item['bucket']}/{key}" if prefix else f"{item['bucket']}/{key}"
            metadata = {
                # percent-encoded on purpose: S3 metadata must be US-ASCII
                "original-bucket": _ascii_metadata(item["bucket"]),
                "original-key": _ascii_metadata(key),
                "original-key-encoding": "percent",
                "backup-time": _now_iso(),
            }
            try:
                # Incremental behaviour: same key and same size already on B2 -> skip.
                if _dest_exists(b2, dest_bucket, dest_key, size):
                    state["stats"]["skipped"] += 1
                else:
                    _copy_object(s3, b2, item["bucket"], key, size, dest_bucket, dest_key, metadata)
                    state["stats"]["copied"] += 1
                    state["stats"]["bytes"] += size
            except Exception as e:  # noqa: BLE001 - one bad object must not stop the job
                _record_failure(state, item["bucket"], key, e)
            state["pending"].pop(0)
            since_save += 1
            if since_save >= 50:
                _save_state(s3, cfg["state_bucket"], state)
                since_save = 0
            continue

        if not state["queue"]:
            return False                   # nothing left to do

        # No pending page: list the next page of the bucket at the head of the queue.
        current = state["queue"][0]
        bucket = current["bucket"]
        kwargs = {"Bucket": bucket, "MaxKeys": 1000}
        if current.get("token"):
            kwargs["ContinuationToken"] = current["token"]
        resp = s3.list_objects_v2(**kwargs)
        state["pending"] = [
            {"bucket": bucket, "Key": o["Key"], "Size": o["Size"]}
            for o in resp.get("Contents", [])
        ]
        if resp.get("IsTruncated") and resp.get("NextContinuationToken"):
            current["token"] = resp["NextContinuationToken"]
        else:
            current["token"] = None
            state["queue"].pop(0)          # bucket fully listed
        _save_state(s3, cfg["state_bucket"], state)
        logger.info(
            "listed %d key(s) from %s (buckets left in queue: %d)",
            len(state["pending"]), bucket, len(state["queue"]),
        )
        since_save = 0


def _self_invoke(event, job_id):
    """Hand the remaining work to a fresh invocation (async: returns immediately)."""
    payload = dict(event)
    payload["job_id"] = job_id
    # "_function_name" is passed through on purpose: it overrides the environment
    # variable below so local tests can chain invocations without AWS.
    function_name = event.get("_function_name") or os.environ["AWS_LAMBDA_FUNCTION_NAME"]
    boto3.client("lambda").invoke(
        FunctionName=function_name,
        InvocationType="Event",
        Payload=json.dumps(payload).encode(),
    )
    logger.info("job %s: self-invoked, remaining work continues asynchronously", job_id)


def _notify(url, body):
    """Best-effort webhook (n8n) notification; never breaks the job."""
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:  # noqa: BLE001
        logger.warning("notification to %s failed: %s", url, e)


def _result(state, state_bucket, status):
    out = {
        "status": status,
        # False means the job finished but some objects are still missing upstream
        # of B2: check "failures_sample" and run again (a new job retries them).
        "ok": state["stats"]["failed"] == 0,
        "job_id": state["job_id"],
        "state": f"s3://{state_bucket}/{_state_key(state['job_id'])}",
        "stats": state["stats"],
        "failures_sample": state["failures"][:5],
        "invocations": state["invocations"],
    }
    hs = state.get("hardening") or {}
    if hs.get("report"):
        report = hs["report"]
        out["hardening"] = {
            "dry_run": report["dry_run"],
            "pending": len(hs.get("pending") or []),
            "finished_at": report["finished_at"],
            "changes": report["changes"],
            "unchanged": report["unchanged"],
            "errors": report["errors"],
        }
    return out


def lambda_handler(event, context):
    """Entry point. Starts a new job, or resumes one when the event carries a job_id."""
    required = (
        "backblaze_key_id",
        "backblaze_key",
        "backblaze_endpoint",
        "dest_bucket",
        "state_bucket",
    )
    missing = [k for k in required if not event.get(k)]
    if missing:
        raise ValueError(f"missing required parameters: {missing}")

    cfg = {
        "state_bucket": event["state_bucket"],
        "dest_bucket": event["dest_bucket"],
        "dest_prefix": event.get("dest_prefix", ""),
        "exclude_buckets": event.get("exclude_buckets", []),
        "max_seconds": int(event.get("max_seconds", 720)),
        "hardening": _parse_hardening(event.get("hardening")),
    }
    s3, b2 = _clients(event)

    job_id = event.get("job_id")
    state = _load_state(s3, cfg["state_bucket"], job_id) if job_id else None
    if state is None:
        # First invocation of a new job: enumerate buckets once, queue hardening too.
        job_id = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
        all_buckets = [b["Name"] for b in s3.list_buckets()["Buckets"]]
        state = _new_state(job_id, cfg, all_buckets)
        _save_state(s3, cfg["state_bucket"], state)
    elif state.get("done"):
        # n8n retried a job that already finished: report it, upload nothing again.
        return _result(state, cfg["state_bucket"], "completed")

    state["invocations"] += 1

    # Keep 15 s of headroom for the checkpoint write and the self-invocation call.
    remaining = context.get_remaining_time_in_millis() / 1000.0
    budget = min(cfg["max_seconds"], max(0.0, remaining - 15))
    if budget <= 0:
        _save_state(s3, cfg["state_bucket"], state)
        _self_invoke(event, job_id)
        return _result(state, cfg["state_bucket"], "running")

    # Reconciliation comes first: it is cheap and keeps new buckets protected
    # before the first byte is copied. Resumes from the checkpoint if interrupted.
    if _harden_step(s3, state, _mono() + budget):
        _save_state(s3, cfg["state_bucket"], state)
        _self_invoke(event, job_id)
        return _result(state, cfg["state_bucket"], "running")

    before = dict(state["stats"])
    more = _process(s3, b2, state, cfg, _mono() + budget)

    if more:
        _save_state(s3, cfg["state_bucket"], state)
        if before == state["stats"] and state["invocations"] > 1:
            # No progress at all: do not chain invocations forever, report instead.
            logger.warning("job %s: no progress in this invocation, stopping the chain", job_id)
            return _result(state, cfg["state_bucket"], "stalled")
        _self_invoke(event, job_id)
        return _result(state, cfg["state_bucket"], "running")

    # Everything copied (or skipped): close the job.
    state["done"] = True
    _save_state(s3, cfg["state_bucket"], state)
    logger.info(
        "job %s finished: copied=%d skipped=%d failed=%d bytes=%d",
        job_id,
        state["stats"]["copied"],
        state["stats"]["skipped"],
        state["stats"]["failed"],
        state["stats"]["bytes"],
    )
    if event.get("notify_url"):
        _notify(event["notify_url"], _result(state, cfg["state_bucket"], "completed"))
    return _result(state, cfg["state_bucket"], "completed")
