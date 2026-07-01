#!/bin/bash

# --- CRON ENVIRONMENT FIX ---
# This tells cron to look in standard user folders for commands like 'oci' and 'jq'
export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/home/n8nbilling/bin

# --- CONFIGURATION ---
BILLING_NAMESPACE="bling"
BILLING_BUCKET="<<oci bucket ocid>>"

# Use an ABSOLUTE path so cron always knows exactly where to put the files
DEST_DIR="/home/n8nbilling/oci_billing"

# Create the destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Create a temporary file to hold the list of files to download
FILE_LIST=$(mktemp)

# Calculate the cutoff date (7 days ago) in ISO 8601 format
CUTOFF_DATE=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "Fetching file list and filtering for files modified after $CUTOFF_DATE..."

# 1. List objects and filter by date using jq
# 2. Save the list to our temporary file
oci os object list --namespace-name $BILLING_NAMESPACE --bucket-name $BILLING_BUCKET --all \
  | jq -r ".data[] | select(.\"time-modified\" > \"$CUTOFF_DATE\") | .name" > "$FILE_LIST"

FILES_COUNT=$(wc -l < "$FILE_LIST")

if [ "$FILES_COUNT" -eq 0 ]; then
    echo "No files modified in the last 7 days."
else
    echo "Found $FILES_COUNT files modified in the last 7 days. Checking local sync status..."

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
            --namespace-name $BILLING_NAMESPACE \
            --bucket-name $BILLING_BUCKET \
            --name "$FILE_NAME" \
            --file "$DEST_DIR/$FILE_NAME"
    done < "$FILE_LIST"
fi

# Clean up the temporary list file
rm -f "$FILE_LIST"

# --- CLEANUP OLD LOCAL FILES ---
echo "Cleaning up local files older than 45 days in $DEST_DIR..."
find "$DEST_DIR" -type f -mtime +45 -exec rm -f {} +
find "$DEST_DIR" -type d -empty -delete

echo "Done! Sync and cleanup complete."

