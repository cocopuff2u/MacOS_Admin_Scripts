#!/bin/sh
####################################################################################################
#
# # Verify BootStrap Token to Jamf
#
# Purpose: Designed to prompt the user to type in the local password to verify the bootstrap with Jamf
#
# https://github.com/cocopuff2u
#
# To Run: Sudo bash /PATH/TO/SCRIPT.SH
#
# Note: Uses SwiftDialog to prompt user
#
####################################################################################################
#
#   History
#
# 1.0 08/30/24 - original
#
####################################################################################################

# Number of retries for failed password before cancelling the script
max_retries=3

# Log file location
log_file="/var/log/verify_bootstrap.log"

# Self Service Path (For Icon)
self_service_path="/Applications/Self Service.app"

# Company Name
company_name="Your Company"

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Logging
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

updateScriptLog() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$timestamp - $message" >> "$log_file"
}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check for / install swiftDialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Define variables
dialogBinary="/usr/local/bin/dialog"
dialogCommandFile="/tmp/dialog_command_file"

function dialogCheck() {

    # Get the current version of swiftDialog from GitHub
    dialogURL=$(curl -s https://api.github.com/repos/swiftdialog/swiftdialog/releases/latest | \
        awk -F'"' '/browser_download_url/ {print $4}')

    updateScriptLog "Downloading Dialog from URL: $dialogURL"

    if [[ ! -x "${dialogBinary}" ]]; then

        updateScriptLog "SwiftDialog not found; installing..."

        tempDirectory=$(mktemp -d)

        curl -sL "$dialogURL" -o "${tempDirectory}/Dialog.pkg"

        # Check if installation package is valid
        teamID=$(pkgutil --pkg-info com.swiftdialog.dialog | awk -F' ' '/origin=/ {print $NF}')

        if [ "$teamID" != "$expectedDialogTeamID" ]; then

            updateScriptLog "Downloaded Dialog package is not from the expected Team ID. Exiting."

            /usr/local/bin/dialog --title "Setup Your Mac: Error" \
            --message "The Dialog installer package is not from the expected Team ID. Exiting the script." \
            --button1text "Close" \
            --button1 \
            --icon caution

            exit 1
        fi

        # Install the Dialog package
        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /

        # Check if installation succeeded
        if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then
            updateScriptLog "Dialog installation failed."

            /usr/local/bin/dialog --title "Setup Your Mac: Error" \
            --message "The Dialog installation failed. Please contact your administrator." \
            --button1text "Close" \
            --button1 \
            --icon caution

            exit 1
        fi

        # Remove the temporary working directory when done
        /bin/rm -Rf "$tempDirectory"

    else

        updateScriptLog "swiftDialog version $(dialog --version) found; proceeding..."

    fi

}

dialogCheck

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Function to prompt the user for password
prompt_password() {
    local attempts_left=$1
    user=$(ls -l /dev/console | awk '{ print $3 }')

    # Message with the remaining attempts
    message="Please type in your local system password in the provided field to verify the bootstrap token with the $company_name Jamf server. You have $attempts_left attempt(s) left."

    passlogic=$(dialog -t "$company_name Verify BootStrap Token" --icon "$self_service_path" -p --alignment center --message "$message" --textfield "Authenticate with Local Password",secure --button1text "Enter Local Password to Continue" --button2text "Not Now")

    if [ $? -eq 2 ]; then
        updateScriptLog "User exited the script."
        echo "User Exited Script"
        exit 0
    else
        pass=$(echo "$passlogic" | awk -F ' : ' '{print $2}')
    fi
}

# Function to display a success dialog
show_success_dialog() {
    dialog --title "Success" --message "Bootstrap token has been successfully verified to the $company_name Jamf server. Thank You" --icon "$self_service_path" --button "Close" -s
    updateScriptLog "Bootstrap token successfully verified with Jamf server."
}

# Function to display a failed dialog
show_failed_dialog() {
    dialog --title "Failure" --message "Bootstrap token has been failed to verify with the $company_name Jamf server. Clearing local token to trigger repair." --icon "$self_service_path" --button "Close" -s
    updateScriptLog "Bootstrap token failed to verify with Jamf server."
}

attempt=1

while [ $attempt -le $max_retries ]; do
    # Calculate remaining attempts
    remaining_attempts=$((max_retries - attempt))

    # Prompt the user for password
    prompt_password $remaining_attempts

    # Retry logic for `profiles validate`
    output=$(profiles validate -type bootstraptoken -user "${user}" -password "${pass}" 2>&1)

    # Check specific error messages in the output
    if echo "$output" | grep -q "Unable to authenticate user information."; then
        updateScriptLog "Authentication failed on attempt $attempt. Retrying password input."
        echo "Authentication failed. Retrying..."
        # Increment attempt counter
        attempt=$((attempt + 1))
    elif echo "$output" | grep -q "Unable to verify token (err = -69594)."; then
        updateScriptLog "Unable to verify token. Removing Bootstrap Token."
        profiles remove -type bootstraptoken -user "${user}" -password "${pass}"
        show_failed_dialog
        exit 1
    elif echo "$output" | grep -q "validated"; then
        updateScriptLog "Bootstrap Token validated on attempt $attempt."
        show_success_dialog
        exit 0
    else
        if [ $remaining_attempts -gt 0 ]; then
            updateScriptLog "Attempt $attempt failed. You have $remaining_attempts attempt(s) left. Please try again."
            echo "Attempt $attempt failed. You have $remaining_attempts attempt(s) left. Please try again."
            dscl . createpl /Users/"$user" accountPolicyData failedLoginCount 0
        else
            updateScriptLog "Attempt $attempt failed. No attempts left."
            echo "Attempt $attempt failed. No attempts left."
            dscl . createpl /Users/"$user" accountPolicyData failedLoginCount 0
        fi
        # Increment attempt counter
        attempt=$((attempt + 1))
    fi

    # Wait before retrying (optional)
    sleep 2
done

# Exit with failure status if all attempts fail
updateScriptLog "Command failed after $max_retries attempts."
echo "Command failed after $max_retries attempts"
exit 1
