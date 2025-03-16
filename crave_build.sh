#!/bin/bash
#######################################
# DEFINE HELPER FUNCTIONS
#######################################

# --- Telegram Notification Functions ---
# buildHeader returns a common header based on ENV_DEFINED.
buildHeader() {
  if [ "${ENV_DEFINED:-0}" = "1" ]; then
    echo "<b>${PROJECT}-${RELEASE_VERSION}</b>
Build started for ${DEVICE}
Flavour: ${BUILD_FLAVOR} | Release: ${RELEASE_TYPE}"
  else
    echo "<b>${PROJECT}-${RELEASE_VERSION}</b>
Build started for ${DEVICE}"
  fi
}

# formatMsg constructs a full HTML message.
# Modes:
#   final   → expects build duration and download link.
#   failed  → expects a log URL and uses the custom stage (fail_stage).
#   progress→ expects a raw progress string and reformats it.
formatMsg() {
  local mode="$1"
  shift
  local header
  header=$(buildHeader)
  case "$mode" in
    final)
      local duration="$1"; shift
      local dl="$1"
      echo "$header
Status: <b>100% (complete)</b>
Time: ${duration}
Download: ${dl}"
      ;;
    failed)
      local log_url="$1"
      echo "$header
Status: <b>${fail_stage}</b>. Log: ${log_url}"
      ;;
    progress)
      local raw="$1"
      local stat
      if [[ "$raw" == \[* ]]; then
        stat=$(echo "$raw" | sed -E 's/^\[\s*([0-9]+%)\s+([0-9]+\/[0-9]+)\]$/\1 (\2)/')
      else
        stat="$raw"
      fi
      echo "$header
Status: <b>${stat}</b>"
      ;;
    *)
      echo "Error: Invalid mode in formatMsg" >&2
      return 1
      ;;
  esac
}

# notifyMsg sends a new Telegram message or updates an existing one.
notifyMsg() {
  local msg
  msg=$(formatMsg "$@")
  if [ -z "$msg_id" ]; then
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
           -d chat_id="${TG_CID}" \
           -d parse_mode="HTML" \
           -d text="$msg")
    msg_id=$(echo "$resp" | jq -r '.result.message_id')
  else
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
         -d chat_id="${TG_CID}" \
         -d parse_mode="HTML" \
         -d message_id="${msg_id}" \
         -d text="$msg" > /dev/null 2>&1
  fi
}

# notifyStage is a convenience function to update the current stage.
notifyStage() {
  local stage_msg="$1"
  notifyMsg progress "$stage_msg"
}

# failStage is invoked when a command fails and captures log details on error and notifies Telegram.
# If called with "from_wait", it extracts the log starting from the first occurrence of "FAILED:".
failStage() {
  local stage="$1"
  local mode="$2"   # Internal flag; not shown in the Telegram message.
  fail_stage="$stage"
  local log_content
  if [ "$mode" == "from_wait" ]; then
    # Find the line number of the first exact occurrence of "FAILED:" (case-sensitive, whole word).
    local start_line
    start_line=$(grep -n -w -F "FAILED:" "$LOG_FILE" | head -n 1 | cut -d: -f1)
    if [ -n "$start_line" ]; then
      log_content=$(sed -n "${start_line},\$p" "$LOG_FILE")
    else
      log_content=$(tail -n 100 "$LOG_FILE")
    fi
  else
    log_content=$(tail -n 100 "$LOG_FILE")
  fi
  echo "$log_content" > err.log
  local log_url
  log_url=$(curl -s --data-binary @"err.log" https://paste.rs)
  notifyMsg failed "$log_url"
  exit 1
}

# monitorProgress monitors build progress by scanning LOG_FILE and updating Telegram.
monitorProgress() {
  local build_pid="$1"
  local last_pct=0
  get_prog() {
    sed -n '/Starting ninja/,$p' "$LOG_FILE" | \
      grep -oP '\[\s*\d+%\s+\d+/\d+' | \
      tail -n 1 | \
      sed -E 's/\[\s*//; s/[[:space:]]+/ (/; s/$/)/'
  }
  while kill -0 "$build_pid" 2>/dev/null; do
    local prog_line curr_pct
    prog_line=$(get_prog)
    curr_pct=$(echo "$prog_line" | grep -oP '^\d+(?=%)')
    if [[ "$curr_pct" =~ ^[0-9]+$ ]] && (( curr_pct > last_pct )); then
      notifyMsg progress "$prog_line"
      last_pct=$curr_pct
    fi
    sleep 10
  done
}

# waitForBuild waits for the build process to finish.
# If the build fails, it calls failStage with the "from_wait" flag.
waitForBuild() {
  local build_pid="$1"
  wait "$build_pid"
  local ec=$?
  if [ $ec -ne 0 ]; then
    failStage "Build failed" "from_wait"
  fi
}

# finalizeMsg sends the final success notification.
finalizeMsg() {
  local duration="$1"
  local dl="$2"
  notifyMsg final "$duration" "$dl"
}

# --- Non-Telegram Helper Functions ---
# Cleanup function to remove temporary files and directories.
cleanup_self () {
    cd "$ANDROID_BUILD_TOP" || exit 1

    rm -rf .repo/local_manifests
    rm -rf device/realme/RMX2001L1
    rm -rf device/realme/RMX2151L1
    rm -rf device/realme/RM6785-common
    rm -rf vendor/realme/RM6785-common
    rm -rf kernel/realme/mt6785
    rm -rf hardware/mediatek
    rm -rf device/mediatek/sepolicy_vndr

    rm -rf vendor/extra
    rm -rf vendor/pixel
    rm -rf packages/apps/FaceUnlock

    rm -rf vendor/lineage-priv
    rm -rf .config/b2/account_info
    rm -rf ~/.gitconfig
    rm -rf /home/admin/venv

    rm -f goupload.sh
    rm -f GOFILE.txt
}

# Function to upload a log file to paste.rs.
upload_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found." >&2
        return 1
    fi
    # Upload the file to paste.rs by sending raw data.
    local output_url
    output_url=$(curl --silent --data-binary @"$file" https://paste.rs)
    if [ -z "$output_url" ]; then
        # Check if paste.rs is reachable.
        if curl --silent --head https://paste.rs > /dev/null; then
            echo "Error: Upload failed despite paste.rs being up." >&2
        else
            echo "Error: Upload failed. paste.rs appears to be down." >&2
        fi
        return 1
    fi
    echo "$output_url"
}

# Function to apply local patches (if necessary) before building.
apply_patches() {
    local patches_path="$1"
    local branch="$2"

    # Validate input parameters.
    if [ -z "$patches_path" ] || [ -z "$branch" ]; then
        echo "Usage: apply_patches <patches_path> <branch>"
        echo "  <patches_path> - Path to the patches folder containing subdirectories for each target repo."
        echo "  <branch>       - The Git branch to compare HEAD against before applying patches."
        return 1
    fi

    # Ensure the patches directory exists.
    if [ ! -d "$patches_path" ]; then
        echo "Patches directory '$patches_path' does not exist."
        return 1
    fi

    # Loop over each subdirectory in the patches folder.
    for patch_subdir in "$patches_path"/*/; do
        # Extract the repository name from the subdirectory name.
        local target_repo
        target_repo=$(basename "${patch_subdir}")

        # Convert underscores to slashes to form the local repository path.
        local target_repo_path
        target_repo_path=$(echo "$target_repo" | tr '_' '/')

        # Change to the Android build top directory.
        cd "${ANDROID_BUILD_TOP}" || { echo "ANDROID_BUILD_TOP is not set or invalid"; return 1; }
        # Change to the target repository path.
        cd "${target_repo_path}" || { echo "Repository path '${target_repo_path}' not found. Skipping."; continue; }

        # Get the current commit and the commit of the specified branch.
        local head_commit branch_commit
        head_commit=$(git rev-parse HEAD)
        branch_commit=$(git rev-parse "$branch" 2>/dev/null)

        # If the branch is not found, skip this repo.
        if [ $? -ne 0 ]; then
            echo "Branch '$branch' not found in repository '${target_repo}'. Skipping."
            cd "${ANDROID_BUILD_TOP}" || exit 1
            continue
        fi

        # Only apply patches if the repository HEAD matches the branch commit.
        if [ "$head_commit" = "$branch_commit" ]; then
            echo "Applying patches for repository: ${target_repo} on commit ${head_commit}"
            if ! git am "${patches_path}/${target_repo}"/*.patch --no-gpg-sign; then
                echo "Failed to apply patches for repository: ${target_repo}. Aborting."
                git am --abort &> /dev/null
            fi
        else
            echo "Skipping repository: ${target_repo}, HEAD (${head_commit}) is not on branch ${branch} (${branch_commit})."
        fi

        # Return to the Android build top directory for the next repo.
        cd "${ANDROID_BUILD_TOP}" || exit 1
    done
}

# This function applies Gerrit patches.
# Each input should be either a Gerrit URL or a full cherry-pick command or set the GERRIT_PATCH environment variable seperated by pipe.
apply_gerrit_patches() {
    if [ "$#" -eq 0 ]; then
        if [ -n "$GERRIT_PATCH" ]; then
            IFS='|' read -r -a GERRIT_PATCH_INPUTS <<< "$GERRIT_PATCH"
            set -- "${GERRIT_PATCH_INPUTS[@]}"
        else
            echo "Usage: apply_gerrit_patches <gerrit_patch_input1> [<gerrit_patch_input2> ...]"
            echo "  Each input should be a Gerrit URL or a full cherry-pick command."
            echo "  Alternatively, you can set the GERRIT_PATCH environment variable with patch inputs separated by the '|' character."
            return 1
        fi
    fi

    # Helper function: Convert a target repo string to a local directory path.
    # It removes the organization prefix and replaces underscores with slashes.
    convert_target_repo() {
        local target_repo="$1"
        local repo_path="${target_repo#*/}"
        : ${GERRIT_REPO_PREFIX:="android_"}
        if [[ "$repo_path" == ${GERRIT_REPO_PREFIX}* ]]; then
            repo_path="${repo_path#$GERRIT_REPO_PREFIX}"
        fi
        echo "$repo_path" | tr '_' '/'
    }

    # Helper function: Change directory into the repository if it exists.
    enter_repo() {
        local repo_path="$1"
        if [ ! -d "${ANDROID_BUILD_TOP}/${repo_path}" ]; then
            echo "Project directory ${ANDROID_BUILD_TOP}/${repo_path} not found. Skipping."
            return 1
        fi
        cd "${ANDROID_BUILD_TOP}/${repo_path}" || { echo "Failed to cd to ${ANDROID_BUILD_TOP}/${repo_path}"; return 1; }
    }

    local top_dir="${ANDROID_BUILD_TOP}"

    # Process each Gerrit patch input.
    for patch in "$@"; do
        patch=$(echo "$patch" | xargs)  # Trim whitespace.
        echo "---------------------------------------"
        echo "Processing Gerrit patch input: $patch"

        if [[ "$patch" == git\ fetch* ]]; then
            # Handle full cherry-pick command input.
            echo "Detected full cherry-pick command input."
            set -- $patch
            local remote_url="$3"
            local ref="$4"
            local target_repo
            # Extract the target repo from the remote URL.
            target_repo=$(echo "$remote_url" | sed -E 's|https?://[^/]+/||')
            local repo_path
            repo_path=$(convert_target_repo "$target_repo")

            if ! enter_repo "$repo_path"; then
                continue
            fi

            echo "Executing: $patch"
            eval "$patch"
            if [ $? -ne 0 ]; then
                echo "Failed to apply Gerrit patch for ${target_repo}."
                git cherry-pick --abort 2>/dev/null
                cd "$top_dir" || exit 1
                return 1
            else
                echo "Gerrit patch applied successfully for ${target_repo}."
            fi
            cd "$top_dir" || exit 1

        else
            # Handle direct Gerrit URL input.
            echo "Detected direct Gerrit URL input."
            local gerrit_link="${patch%/}"
            local target_repo
            # Extract the target repo from the Gerrit URL.
            target_repo=$(echo "$gerrit_link" | sed -E 's|https?://[^/]+/c/([^/]+/[^/]+)/\+.*|\1|')
            if [ -z "$target_repo" ]; then
                echo "Could not parse repository from URL: $gerrit_link"
                continue
            fi
            local repo_path
            repo_path=$(convert_target_repo "$target_repo")
            local change_id
            # Extract the change ID from the Gerrit URL.
            change_id=$(echo "$gerrit_link" | sed -E 's|.*/\+/([0-9]+).*|\1|')
            if [ -z "$change_id" ]; then
                echo "Could not parse change ID from URL: $gerrit_link"
                continue
            fi
            local patchset="1"
            local two_digits
            two_digits=$(printf "%02d" $((change_id % 100)))
            local ref="refs/changes/${two_digits}/${change_id}/${patchset}"
            local base_remote=""
            # Determine the base remote URL.
            if [ -n "$GERRIT_BASE_REMOTE_OVERRIDE" ]; then
                base_remote="$GERRIT_BASE_REMOTE_OVERRIDE"
            elif echo "$gerrit_link" | grep -q "^https://review\."; then
                base_remote=$(echo "$gerrit_link" | sed -E 's|https://review\.[^/]+/c/([^/]+/[^/]+)/.*|\1|')
                base_remote="https://github.com/${base_remote}"
            else
                base_remote=$(echo "$gerrit_link" | sed -E 's|(https?://[^/]+)/.*|\1|')"/c"
            fi

            echo "Applying Gerrit patch for target repo: ${target_repo} (repo path: ${repo_path}) with change ${change_id}, patchset ${patchset} (ref: ${ref}) from ${base_remote}"
            if ! enter_repo "$repo_path"; then
                continue
            fi

            local full_remote=""
            if echo "$gerrit_link" | grep -q "^https://review\."; then
                full_remote="$base_remote"
            else
                full_remote="${base_remote}/${target_repo}"
            fi

            echo "Fetching from: ${full_remote} ${ref}"
            if git fetch "${full_remote}" "${ref}" && git cherry-pick FETCH_HEAD; then
                echo "Gerrit patch applied successfully for ${target_repo}."
            else
                echo "Failed to apply Gerrit patch for ${target_repo} (change ${change_id})."
                git cherry-pick --abort 2>/dev/null
                cd "$top_dir" || exit 1
                return 1
            fi
            cd "$top_dir" || exit 1
        fi
    done

    echo "---------------------------------------"
    echo "All Gerrit patches applied successfully."
    return 0
}

#######################################
# 1. INITIAL SETUP
#######################################
# Initialization notification.
notifyStage "Initiating build..."

# Set the Android build top directory and change into it.
export ANDROID_BUILD_TOP="/tmp/src/android"
cd "$ANDROID_BUILD_TOP" || { echo "[ERROR] Failed to cd to $ANDROID_BUILD_TOP"; exit 1; }

# Define an absolute log file path.
LOG_FILE="$ANDROID_BUILD_TOP/build.log"

# Redirect all output to LOG_FILE while still printing to the console
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Source global and user-specific environment variables and credentials.
source /home/admin/.profile
source /home/admin/.bashrc
source /tmp/crave_bashrc

# Enable verbose mode for debugging.
set -v

#######################################
# 2. DEFINE BUILD VARIABLES & ENVIRONMENT
#######################################
notifyStage "Defining build variables and environment..."

PROJECT=${PROJECT:-LineageOS}
PRODUCT_NAME=${PRODUCT_NAME:-lineage_RMX2001L1}
DEVICE=${DEVICE:-RMX2001L1}
BUILD_FLAVOR=${BUILD_FLAVOR:-gms}  # alternatives: gms or vanilla
RELEASE_TYPE=${RELEASE_TYPE:-user}  # e.g., user build
RELEASE_VERSION=${RELEASE_VERSION:-22.1}
REPO_URL="-u https://github.com/accupara/los22.git -b lineage-22.1 --git-lfs"

# Export build system variables.
export BUILD_USERNAME=user
export BUILD_HOSTNAME=localhost
export KBUILD_BUILD_USER=user
export KBUILD_BUILD_HOST=localhost

# Defines that env variable are set ; default to 0 if not set.
ENV_DEFINED=1

# Start a timer to measure build duration.
SECONDS=0
START_TIME=$(env TZ=Asia/kolkata date)

#######################################
# 3. INITIALIZE REPO & SYNC CODE
#######################################
if echo "$@" | grep resume >/dev/null; then
    echo "Resuming previous session..."
else
    notifyStage "Repo syncing in progress..."
    repo init $REPO_URL || failStage "Repo init failed"
    cleanup_self
    # Let's curl xmls before repo sync.
    # Ensure the local_manifests directory exists.
    mkdir -p .repo/local_manifests

    # Download the device tree manifest.
    curl -o .repo/local_manifests/roomservice.xml \
         https://raw.githubusercontent.com/gopaldhanve2003/local_manifests/refs/heads/lineage-21.1/roomservice.xml || failStage "Failed to download Roomservice"
    # Download the extra manifest for vendor extras.
    curl -o .repo/local_manifests/extra.xml \
         https://raw.githubusercontent.com/gopaldhanve2003/android_vendor_extra/refs/heads/main/extra.xml || failStage "Failed to download extra.xml"
    # Repo sync.
    /opt/crave/resync.sh || failStage "Repo sync failed"
fi

# Clone vendor_extra.
git clone https://github.com/gopaldhanve2003/android_vendor_extra --depth 1 -b main vendor/extra

# For proper post-syncing check each repo, if .gitattributes is present and contains "filter=lfs", install Git LFS, fetch LFS objects, and checkout the actual content.
repo forall -c 'if [ -f .gitattributes ] && grep -q "filter=lfs" .gitattributes; then git lfs install && git lfs fetch && git lfs checkout; fi'

#######################################
# 4. SANITIZE CREDENTIALS AND SYNC KEYS FOR SIGNING
#######################################
grep -vE "BKEY_ID|BUCKET_NAME|KEY_ENCRYPTION_PASSWORD|BAPP_KEY|KEY_PASSWORD|TG_TOKEN|TG_CID" /tmp/crave_bashrc > /tmp/crave_bashrc.1
mv /tmp/crave_bashrc.1 /tmp/crave_bashrc

# Get keys from B2Bucket for signing.
set +v
sudo apt update
sudo apt --yes install python3-virtualenv virtualenv python3-pip-whl
virtualenv /home/admin/venv || failStage "Virtualenv setup failed"
source /home/admin/venv/bin/activate
pip install --upgrade b2 || failStage "B2 upgrade failed"
b2 account authorize "$BKEY_ID" "$BAPP_KEY" > /dev/null 2>&1 || failStage "B2  authorization failed"
mkdir -p vendor/lineage-priv/keys
b2 sync "b2://$BUCKET_NAME/keys" vendor/lineage-priv/keys > /dev/null 2>&1 || failStage "B2 sync failed"
deactivate
set -v

# Unset some variables.
unset BUCKET_NAME KEY_ENCRYPTION_PASSWORD BKEY_ID BAPP_KEY KEY_PASSWORD

# Let's create neccessary files for signing
# If keys.mk does not exist, create it.
if [ ! -f vendor/lineage-priv/keys/keys.mk ]; then
  echo "PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey" > vendor/lineage-priv/keys/keys.mk
fi

# If BUILD.bazel does not exist, create it.
if [ ! -f vendor/lineage-priv/keys/BUILD.bazel ]; then
cat <<EOF > vendor/lineage-priv/keys/BUILD.bazel
filegroup(
    name = "android_certificate_directory",
    srcs = glob([
        "*.pk8",
        "*.pem",
    ]),
    visibility = ["//visibility:public"],
)
EOF
fi

# Wait a short time to ensure all processes are settled.
sleep 15

# Disable verbose mode to reduce log clutter.
set +v

#######################################
# 5. DEVICE & BUILD VARIANT SETUP
#######################################
# Allow an external override of BUILD_FLAVOR using WITH_GMS.
if [ "${WITH_GMS}" == "true" ]; then
    BUILD_FLAVOR="gms"
elif [ "${WITH_GMS}" == "false" ]; then
    BUILD_FLAVOR="vanilla"
fi

## Set Git username and email silently (suppress output and errors)
git config --global user.name "$NAME" > /dev/null 2>&1
git config --global user.email "$MAIL" > /dev/null 2>&1

# Unset git variables
unset NAME MAIL

# If this is a GMS build, apply the necessary patches.
if [[ "${BUILD_FLAVOR}" == "gms" ]]; then
    echo -e "GMS build selected: applying local patches..."
    notifyStage "Applying local patches..."
    apply_patches "$PWD/vendor/extra/patches" "m/lineage-22.1" || failStage "Local patches failed"
fi

# Call apply_gerrit_patches function.
echo "Applying Gerrit patches..."
notifyStage "Applying Gerrit patches..."
apply_gerrit_patches

## Unset Git username and email
git config --global --unset user.name > /dev/null 2>&1
git config --global --unset user.email > /dev/null 2>&1

#######################################
# 6. BUILD THE ROM
#######################################
echo -e "Starting build for device: ${DEVICE} (flavour: ${BUILD_FLAVOR})"
notifyStage "Starting actual build..."
cd "$ANDROID_BUILD_TOP"
source build/envsetup.sh || failStage "Env setup failed"
breakfast "${DEVICE}" "$RELEASE_TYPE" || failStage "Breakfast failed"
m installclean || failStage "Clean build failed"
echo -e "Running m bacon for ${DEVICE}"
notifyStage "Build started"
# Run m bacon in background for progress monitoring.
m bacon &
BUILD_PID=$!
monitorProgress "$BUILD_PID"
waitForBuild "$BUILD_PID"

# Re-enable verbose mode for final steps.
set -v

#######################################
# 7. POST-BUILD PROCESSING & UPLOAD
#######################################
SUCCESS_TIME=$(env TZ=Asia/kolkata date)

# Search for the generated ZIP file based on PROJECT (latest file by modification time)
ZIP_FILE=$(find out/target/product/"${DEVICE}" -maxdepth 1 -type f -iname "*${PROJECT}*${DEVICE}*.zip" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)
if [ -z "$ZIP_FILE" ]; then
    echo "[ERROR] No ZIP file found matching ${PROJECT} (case-insensitive)."
    exit 1
fi

# Copy the generated ZIP file to the current directory.
cp "$ZIP_FILE" .
GO_FILE=$(pwd)/$(basename "$ZIP_FILE")

# Download and execute the file upload script.
curl -o goupload.sh -L https://raw.githubusercontent.com/Joe7500/Builds/refs/heads/main/crave/gofile.sh || failStage "Unable to download Upload script"
bash goupload.sh "$GO_FILE" || failStage "Gofile upload failed"
GO_LINK=$(cat GOFILE.txt)

#######################################
# 8. FINAL NOTIFICATIONS & CLEANUP
#######################################
# Echo just in case notification fails.
echo -e "$PROJECT $(basename "$GO_FILE") $GO_LINK"
TIME_TAKEN=$(printf '%dh:%dm:%ds\n' $((SECONDS/3600)) $((SECONDS%3600/60)) $((SECONDS%60)))
finalizeMsg "$TIME_TAKEN" "$GO_LINK"

# Run cleanup to remove temporary and sensitive files.
cleanup_self

# Unset notification variables.
unset TG_TOKEN TG_CID

# Restore default output and remove LOG_FILE.
exec > /dev/tty 2>&1
rm -rf "$LOG_FILE"

# Pause briefly before exiting.
sleep 60
exit 0

