#!/bin/bash

####################################################################################################
#
# # Import DoD Certs
#
# Purpose: Import the latest DoD Certs from dod.cyber.mil
# 
# https://github.com/cocopuff2u
#
####################################################################################################
#
#   History
#
#  1.0 8/07/23 Original
#
# Issues: If Smart Card is present it will not accept the pin when granting trust per self-signed cert
# Solution: Ask the user to remove smart card doing those steps, logic put in place if smart card is not
# present to keep running the script. 
#
# Issue Update 4/10/24: Noticed with Sonoma 14.4.1 the keychain will accept your pin on trust import, did not change the
# to reflect the changes until i can confirm its working moving forward.
#
####################################################################################################
# Add a confirmation dialog at the beginning
userChoice=$(osascript -e 'tell application "System Events" to set frontmost of process "osascript" to true' -e 'button returned of (display dialog "This script will import DoD certificates direct from dod.cyber.mil. Do you want to continue with the import?" with title "Confirmation" buttons {"Exit", "Continue"} default button "Continue")')


# Check the user's choice
if [ "$userChoice" == "Exit" ]; then
    echo "User chose to exit the script. Exiting..."
    exit 1
fi

osascript -e 'display notification "Initiating Import of DoD Certificates" with title "Certificate Import"'
sleep 5

# Set the URL of the ZIP file you want to download
ZIP_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-dod_approved_external_pkis_trust_chains.zip"

# Define folder and file names
TEMP_DIR="/var/tmp"
GENERIC_FOLDER_NAME="DOD_Certs"
ZIP_FILE_NAME="DOD_Certs.zip"

# Define subfolder names
SUBFOLDER1="_DoD/Intermediate_and_Issuing_CA_Certs"
SUBFOLDER2="_DoD/Trust_Anchors_Self-Signed"

# Calculate full paths
FULL_FOLDER_PATH="$TEMP_DIR/$GENERIC_FOLDER_NAME"
FULL_PATH_WITH_CERTS_SUBFOLDERS="$FULL_FOLDER_PATH/$SUBFOLDER1"
FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS="$FULL_FOLDER_PATH/$SUBFOLDER2"

# Function to cleanup and exit
cleanup_and_exit() {
    rm -rf "$TEMP_DIR"
    exit 1
}

# Check if the generic folder exists and remove it if it does
if [ -d "$FULL_FOLDER_PATH" ]; then
    echo "Generic folder already exists. Removing..."
    rm -rf "$FULL_FOLDER_PATH"
fi

# Download the ZIP file using curl
echo "Downloading ZIP file..."
if ! curl -L -o "$TEMP_DIR/$ZIP_FILE_NAME" "$ZIP_URL"; then
    echo "Failed to download the ZIP file."
    cleanup_and_exit
fi

# Extract the downloaded file with the generic folder name
echo "Unzipping the downloaded file..."
unzip -q "$TEMP_DIR/$ZIP_FILE_NAME" -d "$TEMP_DIR"

# Identify the name of the extracted folder
extracted_folder_name=$(unzip -l "$TEMP_DIR/$ZIP_FILE_NAME" | awk 'NR==4{print $4}')
if [ -z "$extracted_folder_name" ]; then
    echo "Failed to determine the extracted folder name."
    cleanup_and_exit
fi

# Rename the extracted folder to the generic folder name
mv "$TEMP_DIR/$extracted_folder_name" "$FULL_FOLDER_PATH"

# Remove the downloaded ZIP file
rm "$TEMP_DIR/$ZIP_FILE_NAME"

echo "Downloaded and extracted the ZIP file to: $FULL_FOLDER_PATH"
echo "Full path for DoD Certs: $FULL_PATH_WITH_CERTS_SUBFOLDERS"
echo "Full path for DoD Self-Signed Certs: $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS"

# Import all the files in $FULL_PATH_WITH_CERTS_SUBFOLDERS
echo "Importing certificates from $FULL_PATH_WITH_CERTS_SUBFOLDERS..."
osascript -e 'display notification "Initiating Import of Non Self-Signed Certificates" with title "Certificate Import in Progress"'
sleep 5
for cert_file in "$FULL_PATH_WITH_CERTS_SUBFOLDERS"/*; do
    if [ -f "$cert_file" ]; then
        security import "$cert_file" -k /Library/Keychains/system.keychain
    fi
done
osascript -e 'display notification "Completed Import of Non Self-Signed Certificates" with title "Certificate Import Complete"'
sleep 5

osascript -e 'display notification "Initiating Import of Self-Signed Certificates" with title "Certificate Import in Progress"'
sleep 5
if security list-smartcards | grep -q "com.apple.pivtoken:"; then
    # AppleScript code to display the dialog
    osascript -e 'tell application "System Events" to set frontmost of process "osascript" to true' -e 'set dialogText to "A smart card has been detected. Please remove it before proceeding. Failure to do so will result in the certificates being added but not trusted. You will be prompted for your password multiple times to trust these certificates."' -e 'set dialogTitle to "Smart Card Removal Notice"' -e 'set userChoice to display dialog dialogText with title dialogTitle buttons {"OK", "Cancel"} default button "OK"' -e 'return button returned of userChoice'
    # Check the user's choice and take action
    if [ "$?" -eq 1 ]; then
    osascript -e 'display notification "Initiating Import of Self-Signed Certificates untrusted" with title "Certificate Import in Progress"'
        sleep 5
        echo "User selected 'Cancel.' importing them as untrusted"
        # Add all the files in $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS as trusted certificates
        echo "Adding certificates untrusted from $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS..."
        for cert_file in "$FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS"/*; do
            if [ -f "$cert_file" ]; then
                security import "$cert_file" -k /Library/Keychains/system.keychain
            fi
        done

    else
        echo "User selected 'OK.' Continuing with the script."
        osascript -e 'display notification "Initiating Import of Self-Signed Certificates, Prompting user for password" with title "Certificate Import in Progress"'
        sleep 5
        # Add your further commands here to proceed after the user clicks 'OK'.
        # Add all the files in $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS as trusted certificates
        echo "Adding trusted certificates from $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS..."
        for cert_file in "$FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS"/*; do
            if [ -f "$cert_file" ]; then
                sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"
            fi
        done
    fi

else
    echo "Smart card is not present."
    osascript -e 'display notification "Initiating Import of Self-Signed Certificates, Prompting user for password" with title "Certificate Import in Progress"'
    sleep 5
    echo "Adding trusted certificates from $FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS..."
    for cert_file in "$FULL_PATH_WITH_SELF_SIGNED_CERTS_SUBFOLDERS"/*; do
        if [ -f "$cert_file" ]; then
            sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"
        fi
    done
fi

osascript -e 'display notification "Completed Import of all Certificates" with title "Certificate Import Complete"'
sleep 5
# Remove all downloaded files
rm -rf "$FULL_FOLDER_PATH"

echo "Certificate import and trust addition completed."
echo "Script execution completed."
  
