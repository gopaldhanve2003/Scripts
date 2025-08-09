#!/bin/bash
#
# upload_gofile.sh — Upload a ZIP file to gofile.io and print the download URL
#
# Usage: upload_gofile.sh <file_path>
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <file_path>"
    exit 1
fi

FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "Error: File '$FILE' not found!"
    exit 1
fi

# Get best server for upload
SERVER=$(curl -s https://api.gofile.io/servers | jq -r '.data.servers[0].name')

# Upload the file and extract download page URL
DOWNLOAD_URL=$(curl -s -F "file=@${FILE}" "https://${SERVER}.gofile.io/uploadFile" | jq -r '.data.downloadPage')

if [[ "$DOWNLOAD_URL" == "null" || -z "$DOWNLOAD_URL" ]]; then
    echo "Error: Upload failed or no download URL returned."
    exit 1
fi

echo "$DOWNLOAD_URL"

