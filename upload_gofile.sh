#!/bin/bash
#
# upload_gofile.sh — Upload a file to gofile.io and print the download URL
#
# Usage:
#   GOFILE_TOKEN="YOUR_TOKEN_HERE"
#   ./upload_gofile.sh <file_path>
#
set -euo pipefail

# Check args
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <file_path>"
    exit 1
fi

FILE="$1"

# Check file exists
if [[ ! -f "$FILE" ]]; then
    echo "Error: File '$FILE' not found!"
    exit 1
fi

# Check token exists
if [[ -z "${GOFILE_TOKEN:-}" ]]; then
    echo "Error: GOFILE_TOKEN is not set."
    exit 1
fi

# Get an upload server
SERVER=$(curl -s -H "Authorization: Bearer ${GOFILE_TOKEN}" https://api.gofile.io/servers | jq -r '.data.servers[0].name')

# Upload the file and extract download page URL
DOWNLOAD_URL=$(curl --progress-bar -S \
  -H "Authorization: Bearer ${GOFILE_TOKEN}" \
  -F "file=@${FILE}" \
  "https://${SERVER}.gofile.io/contents/uploadfile" \
  | jq -r '.data.downloadPage')

if [[ "$DOWNLOAD_URL" == "null" || -z "$DOWNLOAD_URL" ]]; then
    echo "Error: Upload failed or no download URL returned."
    exit 1
fi

echo "$DOWNLOAD_URL"
