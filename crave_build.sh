#!/bin/bash
# Redirect all output to build.log while still printing to the console
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

    rm -rf /tmp/android-certs*
    rm -rf vendor/lineage-priv/keys
    rm -rf vendor/lineage-priv
    rm -rf priv-keys

    rm -rf .config/b2/account_info
    rm -rf /home/admin/venv

    rm -f goupload.sh
    rm -f GOFILE.txt
}

# Function to upload a log file to 0x0.st.
upload_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found." >&2
        return 1
    fi
    # Upload the file to 0x0.st and capture the URL.
    local output_url
    output_url=$(curl --silent --upload-file "$file" https://0x0.st)
    if [ -z "$output_url" ]; then
        # Check if 0x0.st is reachable.
        if curl --silent --head https://0x0.st > /dev/null; then
            echo "Error: Upload failed despite 0x0.st being up." >&2
        else
            echo "Error: Upload failed. 0x0.st appears to be down." >&2
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
       
       # Upload output.txt to 0x0.st and capture the URL.
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

# Function to apply patches (if necessary) before building.
apply_patches() {
    PATCHES_PATH="$PWD/vendor/extra/patches"
    for project_name in $(cd "$PATCHES_PATH" && echo */); do
        project_path=$(echo "$project_name" | tr _ /)
        cd "${ANDROID_BUILD_TOP}" || exit 1
        cd "${project_path}" || continue
        HEAD_COMMIT=$(git rev-parse HEAD)
        LINEAGE_COMMIT=$(git rev-parse m/lineage-22.1)
        if [[ "${HEAD_COMMIT}" == "${LINEAGE_COMMIT}" ]]; then
            echo "Applying patches for project: ${project_name} on ${HEAD_COMMIT}"
            if ! git am "${PATCHES_PATH}/${project_name}"/*.patch --no-gpg-sign; then
                echo "Failed to apply patches for project: ${project_name}. Aborting patch application."
                git am --abort &> /dev/null
            fi
        else
            echo "Skipping project: ${project_name}, HEAD is not on m/lineage-22.1."
        fi
        cd "${ANDROID_BUILD_TOP}" || exit 1
    done
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
         https://raw.githubusercontent.com/gopaldhanve2003/local_manifests/refs/heads/lineage-21.1/roomservice.xml || { echo "Failed to download local_manifest.xml"; check_fail; }

    # Download the extra manifest for vendor extras.
    curl -o .repo/local_manifests/extra.xml \
         https://raw.githubusercontent.com/gopaldhanve2003/android_vendor_extra/refs/heads/main/extra.xml || { echo "Failed to download extra.xml"; check_fail; }
    # Repo sync.
    /opt/crave/resync.sh ; check_fail
fi

# Clone vendor_extra.
git clone https://github.com/gopaldhanve2003/android_vendor_extra --depth 1 -b main vendor/extra

#######################################
# 7. SANITIZE CREDENTIALS
#######################################
grep -vE "BKEY_ID|BUCKET_NAME|KEY_ENCRYPTION_PASSWORD|BAPP_KEY|KEY_PASSWORD|TG_TOKEN|TG_CID|NTFYSUB" /tmp/crave_bashrc > /tmp/crave_bashrc.1
mv /tmp/crave_bashrc.1 /tmp/crave_bashrc

# (Optional) Credentials & B2 storage setup commands for future use:
#sudo apt --yes install python3-virtualenv virtualenv python3-pip-whl
#virtualenv /home/admin/venv ; check_fail
#set +v
#source /home/admin/venv/bin/activate
#set -v
#pip install --upgrade b2 ; check_fail
#b2 account authorize "$BKEY_ID" "$BAPP_KEY" > /dev/null 2>&1 ; check_fail
#mkdir priv-keys
#b2 sync "b2://$BUCKET_NAME/inline" "priv-keys" > /dev/null 2>&1 ; check_fail
#mkdir --parents vendor/lineage-priv/keys
#mv priv-keys/* vendor/lineage-priv/keys
#deactivate
# Unset some variables.
unset BUCKET_NAME KEY_ENCRYPTION_PASSWORD BKEY_ID BAPP_KEY KEY_PASSWORD
    
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

# If this is a GMS build, apply the necessary patches.
if [[ ${WITH_GMS} == "true" ]]; then
    echo -e "\e[32m[INFO]\e[0m GMS build selected: applying patches before build..."
    notify "[INFO] GMS build selected: applying patches before build..."
    apply_patches
fi

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

# Pause briefly before exiting.
sleep 60
exit 0
