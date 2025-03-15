#!/bin/bash
# Set the Android build top directory and change into it.
export ANDROID_BUILD_TOP="/tmp/src/android"
cd "$ANDROID_BUILD_TOP" || { echo "[ERROR] Failed to cd to $ANDROID_BUILD_TOP"; exit 1; }

# Define an absolute log file path.
LOG_FILE="$ANDROID_BUILD_TOP/build.log"

# Redirect all output to LOG_FILE while still printing to the console
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

#######################################
# 1. INITIAL SETUP
#######################################
# Source global and user-specific environment variables and credentials.
source /home/admin/.profile
source /home/admin/.bashrc
source /tmp/crave_bashrc

# Enable verbose mode for debugging.
set -v

#######################################
# 2. DEFINE BUILD VARIABLES & ENVIRONMENT
#######################################
PACKAGE_NAME=lineage-22.1
VARIANT_NAME=user
REPO_URL="-u https://github.com/accupara/los22.git -b lineage-22.1 --git-lfs"

# Export build system variables.
export BUILD_USERNAME=user
export BUILD_HOSTNAME=localhost
export KBUILD_BUILD_USER=user
export KBUILD_BUILD_HOST=localhost

# Telegram and ntfy configuration (ensure TG_TOKEN, TG_CID, and NTFYSUB are set in your environment)
TG_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

# Start a timer to measure build duration.
SECONDS=0

# Notify build start
START_TIME=$(env TZ=Asia/kolkata date)
notify "$PACKAGE_NAME Build on crave.io started. $START_TIME."

#######################################
# 3. DEFINE HELPER FUNCTIONS
#######################################

# Notification function for Telegram and ntfy notifications.
notify() {
    local message="$1"
    # Send notification via Telegram.
    curl -s -X POST "$TG_URL" -d chat_id="$TG_CID" -d text="$message" > /dev/null 2>&1
    # Send notification via ntfy.
    curl -s -d "$message" "https://ntfy.sh/$NTFYSUB" > /dev/null 2>&1
}

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

# Function to check the exit status of commands and send appropriate notifications.
check_fail () {
   if [ $? -ne 0 ]; then 
       # Capture the last 50 lines of LOG_FILE into output.txt.
       tail -n 50 "$LOG_FILE" > output.txt
       
       # Upload output.txt to paste.rs and capture the URL.
       output_url=$(upload_log output.txt)
       
       # Output the URL to the console.
       echo "Log URL: $output_url"
       
       # Determine the type of failure and notify accordingly.
       if ls out/target/product/"${device}"/"$PACKAGE_NAME"*.zip >/dev/null 2>&1; then
          notify "$PACKAGE_NAME Build on crave.io softfailed. $(env TZ=Asia/kolkata date). Log: $output_url"
          echo "Weird: build failed but OTA package exists."
          cleanup_self
          exit 1
       else
          notify "$PACKAGE_NAME Build on crave.io failed. $(env TZ=Asia/kolkata date). Log: $output_url"
          echo "Oh no, the script failed."
          cleanup_self
          exit 1 
       fi
   fi
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
# Each input should be either a Gerrit URL or a full cherry-pick command.
apply_gerrit_patches() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: apply_gerrit_patches <gerrit_patch_input1> [<gerrit_patch_input2> ...]"
        echo "  Each input should be a Gerrit URL or a full cherry-pick command."
        return 1
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
# 4. INITIALIZE REPO & SYNC CODE
#######################################
if echo "$@" | grep resume >/dev/null; then
    echo "Resuming previous session..."
else
    repo init $REPO_URL ; check_fail
    cleanup_self
    # Let's curl xmls before repo sync.
    # Ensure the local_manifests directory exists.
    mkdir -p .repo/local_manifests

    # Download the device tree manifest.
    curl -o .repo/local_manifests/roomservice.xml \
         https://raw.githubusercontent.com/gopaldhanve2003/local_manifests/refs/heads/lineage-21.1/roomservice.xml || { echo "Failed to download roomservice.xml"; check_fail; }

    # Download the extra manifest for vendor extras.
    curl -o .repo/local_manifests/extra.xml \
         https://raw.githubusercontent.com/gopaldhanve2003/android_vendor_extra/refs/heads/main/extra.xml || { echo "Failed to download extra.xml"; check_fail; }
    # Repo sync.
    /opt/crave/resync.sh ; check_fail
fi

# Clone vendor_extra.
git clone https://github.com/gopaldhanve2003/android_vendor_extra --depth 1 -b main vendor/extra

# For proper post-syncing check each repo, if .gitattributes is present and contains "filter=lfs", install Git LFS, fetch LFS objects, and checkout the actual content.
repo forall -c 'if [ -f .gitattributes ] && grep -q "filter=lfs" .gitattributes; then git lfs install && git lfs fetch && git lfs checkout; fi'

#######################################
# Process script arguments to collect arguments.
# This should be done now so the inputs are stored for later use.
#######################################
process_arguments "$@"

#######################################
# 7. SANITIZE CREDENTIALS
#######################################
grep -vE "BKEY_ID|BUCKET_NAME|KEY_ENCRYPTION_PASSWORD|BAPP_KEY|KEY_PASSWORD|TG_TOKEN|TG_CID|NTFYSUB" /tmp/crave_bashrc > /tmp/crave_bashrc.1
mv /tmp/crave_bashrc.1 /tmp/crave_bashrc

# Get keys from B2Bucket for signing.
set +v
sudo apt update
sudo apt --yes install python3-virtualenv virtualenv python3-pip-whl
virtualenv /home/admin/venv ; check_fail
source /home/admin/venv/bin/activate
pip install --upgrade b2 ; check_fail
b2 account authorize "$BKEY_ID" "$BAPP_KEY" > /dev/null 2>&1 ; check_fail
mkdir -p vendor/lineage-priv/keys
b2 sync "b2://$BUCKET_NAME/keys" vendor/lineage-priv/keys > /dev/null 2>&1 ; check_fail
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
device=RMX2001L1
#WITH_GMS=true
project_name="${device}"

if [[ ${WITH_GMS} == "true" ]]; then
    type="GMS"
    device_variant="${device}_gms"
else
    type="VANILLA"
    device_variant="${device}"
fi

echo -e "\e[32m[INFO]\e[0m Starting build for device: ${device} (${type} build)"
notify "[INFO] Starting build for device: ${device} (${type} build)"

## Set Git username and email silently (suppress output and errors)
git config --global user.name "$NAME" > /dev/null 2>&1
git config --global user.email "$MAIL" > /dev/null 2>&1

# Unset git variables
unset NAME MAIL

# If this is a GMS build, apply the necessary patches.
if [[ ${WITH_GMS} == "true" ]]; then
    echo -e "\e[32m[INFO]\e[0m GMS build selected: applying patches before build..."
    notify "[INFO] GMS build selected: applying patches before build..."
    apply_patches "$PWD/vendor/extra/patches" "m/lineage-22.1"
fi

# Now that the repo is populated and local patches applied,
# If the GERRIT_PATCH environment variable is set,split it into an array using semicolons as delimiters.
if [ -n "$GERRIT_PATCH" ]; then
    IFS=';' read -r -a GERRIT_PATCH_INPUTS <<< "$GERRIT_PATCH"
fi
# If any Gerrit patch inputs are provided in the environment,call the apply_gerrit_patches function with those inputs.
if [ ${#GERRIT_PATCH_INPUTS[@]} -gt 0 ]; then
    echo "Applying Gerrit patches..."
    apply_gerrit_patches "${GERRIT_PATCH_INPUTS[@]}"
fi

## Unset Git username and email
git config --global --unset user.name > /dev/null 2>&1
git config --global --unset user.email > /dev/null 2>&1

#######################################
# 6. BUILD THE ROM
#######################################
cd "$ANDROID_BUILD_TOP"
source build/envsetup.sh ; check_fail
breakfast "${device}" ; check_fail
m installclean ; check_fail
echo -e "\e[32m[INFO]\e[0m Running m bacon for ${device}"
notify "[INFO] Running m bacon for ${device}"
m bacon ; check_fail

# Re-enable verbose mode for final steps.
set -v

#######################################
# 7. POST-BUILD PROCESSING & UPLOAD
#######################################

# Notify that the build succeeded.
SUCCESS_TIME=$(env TZ=Asia/kolkata date)
notify "Build $PACKAGE_NAME GAPPS on crave.io succeeded. $SUCCESS_TIME."

# Copy the generated ZIP file to the current directory.
cp out/target/product/"${device}"/"$PACKAGE_NAME"*.zip .
GO_FILE=$(ls -1tr "$PACKAGE_NAME"*.zip | tail -1)
GO_FILE=$(pwd)/"$GO_FILE"

# Download and execute the file upload script.
curl -o goupload.sh -L https://raw.githubusercontent.com/Joe7500/Builds/refs/heads/main/crave/gofile.sh ; check_fail
bash goupload.sh "$GO_FILE" ; check_fail
GO_LINK=$(cat GOFILE.txt)

# Send upload notification.
notify "$PACKAGE_NAME $(basename "$GO_FILE") $GO_LINK"
# Echo just in case notification fails.
echo -e "\e[32m[INFO]\e[0m $PACKAGE_NAME $(basename "$GO_FILE") $GO_LINK"

#######################################
# 8. FINAL NOTIFICATIONS & CLEANUP
#######################################
TIME_TAKEN=$(printf '%dh:%dm:%ds\n' $((SECONDS/3600)) $((SECONDS%3600/60)) $((SECONDS%60)))
notify "$PACKAGE_NAME Build on crave.io completed. $TIME_TAKEN. $(env TZ=Asia/kolkata date)."

# Run cleanup to remove temporary and sensitive files.
cleanup_self

# Unset notification variables.
unset TG_TOKEN TG_CID NTFYSUB

# Restore default output and remove LOG_FILE.
exec > /dev/tty 2>&1
rm -rf "$LOG_FILE"

# Pause briefly before exiting.
sleep 60
exit 0

