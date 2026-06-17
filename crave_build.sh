#!/bin/bash
set -o pipefail

# Cleanup
cleanup() {
    rm -rf .repo/local_manifests
    rm -rf vendor/lineage-priv
    rm -rf ~/.config/b2
    rm -rf /home/admin/venv
    rm -rf ~/.gitconfig

    unset BKEY_ID
    unset BAPP_KEY
    unset BUCKET_NAME
    unset KEY_PASSWORD
    unset KEY_ENCRYPTION_PASSWORD
    unset GOFILE_TOKEN
}
trap cleanup EXIT INT TERM

# Repo init
repo init -u https://github.com/crdroidandroid/android.git -b 16.0 --git-lfs --no-clone-bundle

# Local manifests
git clone --depth=1 https://github.com/gopaldhanve2003/local_manifests .repo/local_manifests

# Sync
/opt/crave/resync.sh

# Conditionally copy signing keys
if [ -n "${BKEY_ID:-}" ] && [ -n "${BAPP_KEY:-}" ] && [ -n "${BUCKET_NAME:-}" ]; then
  echo "B2 credentials found. Syncing signing keys..."

  set +v

  # Ensure tools are installed
  sudo apt update
  sudo apt --yes install python3-virtualenv virtualenv python3-pip-whl
  virtualenv /home/admin/venv
  source /home/admin/venv/bin/activate
  pip install --upgrade b2 

  # Authorize and sync signing keys
  b2 account authorize "$BKEY_ID" "$BAPP_KEY" > /dev/null 2>&1
  mkdir -p vendor/lineage-priv/keys
  b2 sync "b2://$BUCKET_NAME/keys" vendor/lineage-priv/keys > /dev/null 2>&1

  deactivate
  set -v

  # Unset sensitive B2 variables from memory
  unset BUCKET_NAME KEY_ENCRYPTION_PASSWORD BKEY_ID BAPP_KEY KEY_PASSWORD
fi

# Build
source build/envsetup.sh
breakfast nemo user
m installclean
m bacon

# Find and Upload build
ZIP_FILE=$(find out/target/product/nemo \
    -maxdepth 1 \
    -type f \
    -iname "*.zip" \
    ! -iname "*ota*.zip" \
    -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
if [[ -z "$ZIP_FILE" || ! -f "$ZIP_FILE" ]]; then
    echo "Error: No ROM zip found!"
    exit 1
fi

DOWNLOAD_URL=$(curl --progress-bar -S \
    -H "Authorization: Bearer ${GOFILE_TOKEN}" \
    -F "file=@${ZIP_FILE}" \
    https://upload.gofile.io/uploadfile \
    | jq -r '.data.downloadPage')
if [[ "$DOWNLOAD_URL" == "null" || -z "$DOWNLOAD_URL" ]]; then
    echo "Error: Upload failed or no download URL returned."
    exit 1
fi
echo "$DOWNLOAD_URL"

exit 0
