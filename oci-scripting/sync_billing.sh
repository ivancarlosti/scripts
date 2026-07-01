#!/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# The Linux username executing this script (used to resolve home directory paths)
SYSTEM_USER="n8nbilling"

# OCI Storage details
BILLING_NAMESPACE="bling"
BILLING_BUCKET="<<oci bucket ocid>>"

# Local destination directory for downloaded files 
# (Absolute path recommended for cron compatibility)
DEST_DIR="/home/${SYSTEM_USER}/oci_billing"

# Sync and Retention policies
FETCH_DAYS_AGO=7  # Download files modified within this many days
RETAIN_DAYS=45    # Delete local files older than this many days
# ==============================================================================

# --- CRON ENVIRONMENT FIX ---
# This tells cron to look in standard user folders for commands like 'oci' and 'jq'
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/home/${SYSTEM_USER}/bin

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Create a temporary file to hold the list of files to download
FILE_LIST=$(mktemp)

# Calculate the cutoff date in ISO 8601 format based on FETCH_DAYS_AGO
CUTOFF_DATE=$(date -u -d "${FETCH_DAYS_AGO} days ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "Fetching file list and filtering for files modified after $CUTOFF_DATE..."

# 1. List objects and filter by date using jq
# 2. Save the list to our temporary file
oci os object list --namespace-name "$BILLING_NAMESPACE" --bucket-name "$BILLING_BUCKET" --all \
  | jq -r ".data[] | select(.\"time-modified\" > \"$CUTOFF_DATE\") | .name" > "$FILE_LIST"

FILES_COUNT=$(wc -l < "$FILE_LIST")

if [ "$FILES_COUNT" -eq 0 ]; then
    echo "No files modified in the last ${FETCH_DAYS_AGO} days."
else
    echo "Found $FILES_COUNT files modified in the last ${FETCH_DAYS_AGO} days. Checking local sync status..."

    while read -r FILE_NAME; do
        # Check if the file already exists locally
        if [ -f "$DEST_DIR/$FILE_NAME" ]; then
            echo "Skipping: $FILE_NAME (Already downloaded)"
            continue
        fi

        echo "Downloading: $FILE_NAME"

        # Create the local sub-directories before downloading
        mkdir -p "$DEST_DIR/$(dirname "$FILE_NAME")"

        # Download the file
        oci os object get \
            --namespace-name "$BILLING_NAMESPACE" \
            --bucket-name "$BILLING_BUCKET" \
            --name "$FILE_NAME" \
            --file "$DEST_DIR/$FILE_NAME"
    done < "$FILE_LIST"
fi

# Clean up the temporary list file
rm -f "$FILE_LIST"

# --- CLEANUP OLD LOCAL FILES ---
echo "Cleaning up local files older than ${RETAIN_DAYS} days in $DEST_DIR..."
find "$DEST_DIR" -type f -mtime +${RETAIN_DAYS} -exec rm -f {} +
find "$DEST_DIR" -type d -empty -delete

echo "Done! Sync and cleanup complete."
