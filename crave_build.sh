#!/bin/bash
# Redirect all output to build.log while still printing to the console
touch build.log
exec > >(tee -a build.log) 2>&1

#######################################
# 1. INITIAL SETUP
#######################################
# Source global and user-specific environment variables and credentials.
source /home/admin/.profile
source /home/admin/.bashrc
source /tmp/crave_bashrc

# Set the Android build top directory and change into it.
export ANDROID_BUILD_TOP="/tmp/src/android"
cd "$ANDROID_BUILD_TOP" || { echo "[ERROR] Failed to cd to $ANDROID_BUILD_TOP"; exit 1; }

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

# Argument processing by loop; if key is "gerrit_patch", store its value in an array,otherwise export the key:value pair.which can utilized by other functions.
process_arguments() {
    GERRIT_PATCH_INPUTS=()
    for arg in "$@"; do
        if [[ "$arg" == *:* ]]; then
            key="${arg%%:*}"
            value="${arg#*:}"
            if [ "$key" = "gerrit_patch" ]; then
                GERRIT_PATCH_INPUTS+=("$value")
            else
                export "$key"="$value"
                echo "Set parameter: $key=$value"
            fi
        fi
    done

    if [ ${#GERRIT_PATCH_INPUTS[@]} -gt 0 ]; then
        echo "Found ${#GERRIT_PATCH_INPUTS[@]} Gerrit patch input(s):"
        printf "  %s\n" "${GERRIT_PATCH_INPUTS[@]}"
    else
        echo "No Gerrit patch inputs provided."
    fi
}

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
       # Capture the last 50 lines of build.log into output.txt.
       tail -n 50 build.log > output.txt
       
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
    # Expect two parameters: patches path and branch name.
    local patches_path="$1"
    local branch="$2"

    if [ -z "$patches_path" ] || [ -z "$branch" ]; then
        echo "Usage: apply_patches <patches_path> <branch>"
        echo "  <patches_path> - Absolute or relative path to the patches folder containing subdirectories for each project."
        echo "  <branch>       - The Git branch to compare HEAD against before applying patches."
        return 1
    fi

    if [ ! -d "$patches_path" ]; then
        echo "Patches directory '$patches_path' does not exist."
        return 1
    fi

    # Loop over each project directory in the patches path
    for project_dir in "$patches_path"/*/; do
        # Remove trailing slash and extract project name
        local project_name
        project_name=$(basename "${project_dir}")

        # Convert underscores to slashes to form the repository path
        local project_path
        project_path=$(echo "$project_name" | tr '_' '/')

        # Change to the repository top directory and then to the project path
        cd "${ANDROID_BUILD_TOP}" || { echo "ANDROID_BUILD_TOP is not set or invalid"; return 1; }
        cd "${project_path}" || { echo "Project path '${project_path}' not found. Skipping."; continue; }

        # Get the current commit and the commit of the specified branch
        local head_commit branch_commit
        head_commit=$(git rev-parse HEAD)
        branch_commit=$(git rev-parse "$branch" 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo "Branch '$branch' not found in project '${project_name}'. Skipping."
            cd "${ANDROID_BUILD_TOP}" || exit 1
            continue
        fi

        # If HEAD matches the branch commit, apply the patches
        if [ "$head_commit" = "$branch_commit" ]; then
            echo "Applying patches for project: ${project_name} on commit ${head_commit}"
            if ! git am "${patches_path}/${project_name}"/*.patch --no-gpg-sign; then
                echo "Failed to apply patches for project: ${project_name}. Aborting patch application."
                git am --abort &> /dev/null
            fi
        else
            echo "Skipping project: ${project_name}, HEAD (${head_commit}) is not on branch ${branch} (${branch_commit})."
        fi

        # Return to the root of the build directory for the next project
        cd "${ANDROID_BUILD_TOP}" || exit 1
    done
}

# Fuction for applying Gerrit patches via direct Gerrit URL or a full cherry-pick command from gerrit review page.
# Each input should be provided as a key:value with key "gerrit_patch".
apply_gerrit_patches() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: apply_gerrit_patches <gerrit_patch_input1> [<gerrit_patch_input2> ...]"
        echo "  Each gerrit_patch_input should be a Gerrit URL or a full cherry-pick command."
        return 1
    fi

    # Nested helper to convert a raw project string to a local repository path.
    convert_project() {
        local proj="$1"
        # Remove the organization prefix (everything before the first slash).
        local repo_path="${proj#*/}"
        # Optionally remove a common project prefix (default: "android_")
        : ${GERRIT_PROJECT_PREFIX:="android_"}
        if [[ "$repo_path" == ${GERRIT_PROJECT_PREFIX}* ]]; then
            repo_path="${repo_path#$GERRIT_PROJECT_PREFIX}"
        fi
        # Replace underscores with directory separators.
        echo "$repo_path" | tr '_' '/'
    }

    for patch in "$@"; do
        patch=$(echo "$patch" | xargs)  # Trim whitespace.
        echo "---------------------------------------"
        echo "Processing Gerrit patch input: $patch"

        if [[ "$patch" == git\ fetch* ]]; then
            echo "Detected full cherry-pick command input."
            # Split the command into its parts.
            set -- $patch
            local remote_url="$3"
            local ref="$4"

            # Remove protocol and domain from remote_url.
            local project
            project=$(echo "$remote_url" | sed -E 's|https?://[^/]+/||')
            local repo_path
            repo_path=$(convert_project "$project")

            if [ ! -d "${ANDROID_BUILD_TOP}/${repo_path}" ]; then
                echo "Project directory ${ANDROID_BUILD_TOP}/${repo_path} not found. Skipping."
                continue
            fi

            cd "${ANDROID_BUILD_TOP}/${repo_path}" || { echo "Failed to cd to ${ANDROID_BUILD_TOP}/${repo_path}"; continue; }
            echo "Executing: $patch"
            eval "$patch"
            if [ $? -ne 0 ]; then
                echo "Failed to apply Gerrit patch for ${repo_path}."
                git cherry-pick --abort 2>/dev/null
                return 1
            else
                echo "Gerrit patch applied successfully for ${repo_path}."
            fi
            cd "${ANDROID_BUILD_TOP}" || exit 1

        else
            echo "Detected direct Gerrit URL input."
            local link="${patch%/}"
            # Extract the Gerrit project from the URL.
            local project
            project=$(echo "$link" | sed -E 's|https?://[^/]+/c/([^/]+/[^/]+)/\+.*|\1|')
            if [ -z "$project" ]; then
                echo "Could not parse project from URL: $link"
                continue
            fi

            local repo_path
            repo_path=$(convert_project "$project")

            # Extract change number.
            local change
            change=$(echo "$link" | sed -E 's|.*/\+/([0-9]+).*|\1|')
            if [ -z "$change" ]; then
                echo "Could not parse change number from URL: $link"
                continue
            fi

            local patchset="1"
            local two_digits
            two_digits=$(printf "%02d" $((change % 100)))
            local ref="refs/changes/${two_digits}/${change}/${patchset}"

            # Extract the base remote URL.
            local base_remote
            base_remote=$(echo "$link" | sed -E 's|(https?://[^/]+)/.*|\1|')"/c"

            echo "Applying Gerrit patch for project: ${project} (repo path: ${repo_path}) with change ${change}, patchset ${patchset} (ref: ${ref}) from ${base_remote}"
            if [ ! -d "${ANDROID_BUILD_TOP}/${repo_path}" ]; then
                echo "Project directory ${ANDROID_BUILD_TOP}/${repo_path} not found. Skipping."
                continue
            fi

            cd "${ANDROID_BUILD_TOP}/${repo_path}" || { echo "Failed to cd to ${ANDROID_BUILD_TOP}/${repo_path}"; continue; }
            local full_remote="${base_remote}/${project}"
            echo "Fetching from: ${full_remote} ${ref}"
            if git fetch "${full_remote}" "${ref}" && git cherry-pick FETCH_HEAD; then
                echo "Gerrit patch applied successfully for ${repo_path}."
            else
                echo "Failed to apply Gerrit patch for ${repo_path} (change ${change})."
                git cherry-pick --abort 2>/dev/null
                return 1
            fi
            cd "${ANDROID_BUILD_TOP}" || exit 1
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
# check if there are Gerrit patch inputs and apply them.
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

# Restore default output and remove build.log.
exec > /dev/tty 2>&1
rm -rf build.log

# Pause briefly before exiting.
sleep 60
exit 0

