#!/bin/zsh --no-rcs

####################################################################################################
#
# # Admin FileVault Key Retrieval Script
#
# Purpose: Allow a user to retrieve the FileVault Key for there computer via serial number.
#
# Requires: API access to Jamf Pro, swiftDialog installed, and the script must have permission to view
# the FileVault Recovery Key.
#
# https://github.com/cocopuff2u
#
#####################################################################################################
#   History
#
#  1.0 05/29/25 - Original
#
ScriptVersion="1.0.0"
####################################################################################################


# Instructions:
# - The `client_id` and `client_secret` are used to authenticate with the Jamf Pro API.
# - These values must be generated in Jamf Pro by creating an API account with the necessary permissions.
# - Navigate to Jamf Pro > Settings > API Credentials > Create API Client.
# - Assign the required permissions to the API client (Read Computers and View Disk Encryption Recovery Key).
# - Copy the generated `client_id` and `client_secret` and replace the values below.

# Passing `client_id` and `client_secret` through a Jamf policy:
# - In Jamf Pro, create a policy and add this script.
# - Under the "Scripts" section of the policy, configure the parameters:
#   1. Parameter 4: client_id (e.g., "76a4c8fe-bb13-408b-9583-48d099db4892").
#   2. Parameter 5: client_secret (e.g., "lPynBg-nkrx3FWePgwOGZy-CG6cgUuaLIE1tIhi7Z3jxjdaOeM59AOerWLDt1h6C").
# - These values will automatically populate the `client_id` and `client_secret` variables in the script.

# Ensure that the client_id and client_secret are passed as parameters when running the script.
client_id=${4}
client_secret=${5}

######################################################################################################
#
# Global Common variables
#
######################################################################################################

# Window icon for the dialog window
OVERLAY_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FileVaultIcon.icns"

# Banner image for the dialog window
SD_BANNER_IMAGE="colour=blue"

# Banner title for the dialog window
SD_WINDOW_TITLE="View FileVault Recovery Key"

# Directory for logging
LOG_DIR="/var/log/"

# Logging file name
LOG_NAME="View_FileVault_Key.log"

# Path to the swiftDialog binary
SW_DIALOG="/usr/local/bin/dialog"


######################################################################################################
#
# Global Advanced variables
#
######################################################################################################

# Logged in user
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

# Logged in user's home directory
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

# Logging Stamp
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

# Full path to the log file
LOG_FILE="${LOG_DIR}/${LOG_NAME}"

# Jamf Pro URL
jamf_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
jamf_url=${jamf_url%%/}

# Variables available to child processes
declare ID
declare reason
declare serial_num
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Global variables to control log visibility
LOG_LEVEL="ALL"  # Options: ALL, INFO

####################################################################################################
#
# Functions
#
####################################################################################################

function logMe() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(/bin/date '+[%B %d, %Y %I:%M:%S %p]')  # Format: [Month Day, Year HH:MM:SS AM/PM]

    case "$LOG_LEVEL" in
        "ALL")
            echo "${timestamp} [${level}] ${message}"  # Echo all logs
            echo "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"  # Append all logs
            ;;
        "INFO")
            if [[ "$level" == "INFO" ]]; then
                echo "${timestamp} [${level}] ${message}"  # Echo INFO logs
                echo "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"  # Append INFO logs
            fi
            ;;
    esac
}

function create_log_directory (){
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    logMe "INFO" "Checking if log directory exists..."
    if [[ ! -d "${LOG_DIR}" ]]; then
        logMe "WARNING" "Log directory not found. Creating ${LOG_DIR}..."
        /bin/mkdir -p "${LOG_DIR}"
        /bin/chmod 755 "${LOG_DIR}"
    fi

    logMe "INFO" "Checking if log file exists..."
    if [[ ! -f "${LOG_FILE}" ]]; then
        logMe "WARNING" "Log file not found. Creating ${LOG_FILE}..."
        /usr/bin/touch "${LOG_FILE}"
        /bin/chmod 644 "${LOG_FILE}"
    fi
}

function logAdditionalDetails () {
    # Log the current logged-in user and the serial number of the device running the script
    logMe "INFO" "Logged-in User: $LOGGED_IN_USER"
    logMe "INFO" "Serial Number of Device Running Script: $(ioreg -l | awk '/IOPlatformSerialNumber/ {print $4}' | tr -d '"')"
}

##########################################
#
# Dialog Update/Install Function
#
##########################################

function dialogInstall() {
    # Install swiftDialog if not found or outdated
    logMe "INFO" "Installing swiftDialog..."
    dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")
    expectedDialogTeamID="PWA5E9TQ59"
    workDirectory=$( /usr/bin/basename "$0" )
    tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"
    teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')
    if [[ "$expectedDialogTeamID" == "$teamID" ]]; then
        logMe "INFO" "Team ID verified. Installing swiftDialog..."
        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
        sleep 2
        dialogVersion=$( /usr/local/bin/dialog --version )
        logMe "INFO" "swiftDialog version ${dialogVersion} installed successfully."
    else
        logMe "ERROR" "Team ID verification failed."
        osascript -e 'display dialog "Team ID verification failed. Please contact support." with title "Error" buttons {"Close"} with icon caution' & exit 0
    fi
    /bin/rm -Rf "$tempDirectory"
}

function dialogCheck() {
    # Check if swiftDialog is installed and up-to-date
    logMe "INFO" "Checking for swiftDialog installation..."
    if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then
        logMe "WARNING" "swiftDialog not found. Installing..."
        dialogInstall
    else
        dialogVersion=$(/usr/local/bin/dialog --version)
        if [[ "${dialogVersion}" < "${swiftDialogMinimumRequiredVersion}" ]]; then
            logMe "WARNING" "swiftDialog version ${dialogVersion} is outdated. Updating..."
            dialogInstall
        else
            logMe "INFO" "swiftDialog version ${dialogVersion} is up-to-date."
        fi
    fi
}

##########################################
#
# Window Functions
#
##########################################

function display_welcome_message () {
    # Display the welcome message dialog
    logMe "INFO" "Displaying welcome message dialog..."
    local serial_num=$(ioreg -l | awk '/IOPlatformSerialNumber/ {print $4}' | tr -d '"')
    MainDialogBody="${SW_DIALOG} \
        --bannerimage \"${SD_BANNER_IMAGE}\" \
        --titlefont "shadow=1" \
        --bannertitle \"${SD_WINDOW_TITLE}\" \
        --icon \"${OVERLAY_ICON}\" --iconsize 100 \
        --message \"Device Serial Number: **${serial_num}** \n\nPlease provide a reason for retrieving the FileVault Recovery Key for this device.\" \
        --messagefont name=Arial,size=16 \
        --textfield \"Reason,required\" \
        --button1text \"Continue\" \
        --button2text \"Quit\" \
        --infotext \"V ${ScriptVersion}\" \
        --ontop \
        --height 300 \
        --json \
        --moveable"
    message=$(eval "$MainDialogBody")
    buttonpress=$?
    [[ $buttonpress = 2 ]] && logMe "INFO" "User chose to quit." && exit 0

    reason=$(echo $message | grep "Reason" | awk -F '"Reason" : "' '{print$2}' | awk -F '"' '{print$1}')
    logMe "INFO" "User's Reason: $reason"
}

##########################################
#
# API Token Functions
#
##########################################

# This function checks if the API token is valid and renews it if necessary
# This function will set the global variables:
# - access_token (the API token to use for subsequent API calls)
# - token_expires_in
# - token_expiration_epoch
Get_Jamf_API_Token() {
     current_epoch=$(date +%s)
	response=$(curl --silent --location --request POST "${jamf_url}/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${client_secret}")
	access_token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
	token_expiration_epoch=$(($current_epoch + $token_expires_in - 1))
}

# This function checks if the API token is valid and renews it if necessary
# If the token is valid, it will return the epoch time when the token expires
# If the token is not valid, it will call Get_Jamf_API_Token to get a new token
Check_Token_Expiration() {
    current_epoch=$(date +%s)
    if [[ token_expiration_epoch -ge current_epoch ]]; then
        readable_expiration_date=$(date -r "$token_expiration_epoch" '+%I:%M %p %B %d, %Y')  # Format: 1:00 PM Month Day, Year
        logMe "INFO" "Token valid until: $readable_expiration_date"
    else
        logMe "INFO" "No valid token available, getting new access_token"
        Get_Jamf_API_Token
    fi
}

# This function invalidates the current API token (Adds a layer of security by invalidating the token after use)
Invalidate_Token() {
	responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" $jamf_url/api/v1/auth/invalidate-token -X POST -s -o /dev/null)
	if [[ ${responseCode} == 204 ]]
	then
		logMe "INFO" "Token successfully invalidated"
		access_token=""
		token_expiration_epoch="0"
	elif [[ ${responseCode} == 401 ]]
	then
		logMe "INFO" "Token already invalid"
	else
		logMe "WARNING" "An unknown error occurred invalidating the token"
	fi
}

##########################################
#
# API Get Functions
#
##########################################

function Get_JAMF_Device_ID_Serial ()
{
     # Retrieves the Jamf Pro Device ID for the computer based on the serial number or hostname.
     ID=$(/usr/bin/curl -s -X GET "$jamf_url/api/v1/computers-inventory?section=&page=0&page-size=100&filter=hardware.serialNumber%3D%3D%22$serial_num%22" -H "accept: application/json" -H "Authorization: Bearer $access_token" | plutil -extract results.0.id raw - )
     if [[ ! "$ID" =~ ^[0-9]+$ ]]; then
          logMe "ERROR" "Device ID not found for serial number: $serial_num"
     else
          logMe "INFO" "Device ID for serial number: $serial_num is $ID"
     fi
}

function Get_JAMF_Device_ID_Hostname ()
{
     # Retrieves the Jamf Pro Device ID for the computer based on the serial number or hostname.
     ID=$(/usr/bin/curl -s -X GET "$jamf_url/api/v1/computers-inventory?section=&page=0&page-size=100&filter=general.name%3D%3D%22$device_value%22" -H "accept: application/json" -H "Authorization: Bearer $access_token" | plutil -extract results.0.id raw - )
     if [[ ! "$ID" =~ ^[0-9]+$ ]]; then
          logMe "ERROR" "Device ID not found for hostname: $device_value"
     else
          logMe "INFO" "Device ID for hostname: $device_value is $ID"
     fi
}

function FileVault_Recovery_Key_Retrieval () {
    # Ensure the function runs only if a valid device ID exists
    if [[ ! "$ID" =~ ^[0-9]+$ ]]; then
        logMe "ERROR" "Invalid or missing device ID. FileVault Recovery Key retrieval aborted."
        return 1  # Exit the function
    fi

    # Retrieves a FileVault recovery key from the computer inventory record.
    filevault_recovery_key_retrieved=$(/usr/bin/curl -s -X GET "${jamf_url}/api/v1/computers-inventory/$ID/filevault" -H "accept: application/json" -H "Authorization: Bearer $access_token" | plutil -extract personalRecoveryKey raw - )
    
    if [[ "$filevault_recovery_key_retrieved" == *"<stdin>: Could not extract value"* ]]; then
        logMe "ERROR" "No FileVault Recovery Key available for device ID $ID"
        filevault_recovery_key_retrieved="No FileVault Recovery Key available with Jamf Pro. \nPlease contact your support team for further assistance."
        return 1  # Exit the function
    fi

    if [[ "$filevault_recovery_key_retrieved" == *"<stdin>: Property List error"* ]]; then
        logMe "ERROR" "No FileVault Recovery Key available for device ID $ID"
        filevault_recovery_key_retrieved="No FileVault Recovery Key available with Jamf Pro. \nPlease contact your support team for further assistance."
        return 1  # Exit the function
    fi

    logAdditionalDetails
    # This is for debugging purposes, you can remove this line if you don't want to log the recovery key
    #logMe "Retrieved FileVault Recovery Key: $filevault_recovery_key_retrieved"
}

####################################################################################################
#
# Main Workflow
#
####################################################################################################
create_log_directory
dialogCheck

while true; do
    logMe "INFO" "Starting main workflow loop..."
    display_welcome_message

    # Automatically use the local serial number
    serial_num=$(ioreg -l | awk '/IOPlatformSerialNumber/ {print $4}' | tr -d '"')
    logMe "INFO" "Using local serial number: $serial_num"

    Get_Jamf_API_Token
    Get_JAMF_Device_ID_Serial
    FileVault_Recovery_Key_Retrieval
    Invalidate_Token

    if [[ ! "$ID" =~ ^[0-9]+$ ]]; then
        logMe "WARNING" "Device inventory not found reprompting to user."
        $SW_DIALOG \
            --bannerimage "${SD_BANNER_IMAGE}" \
            --bannertitle "${SD_WINDOW_TITLE}" \
            --icon "${OVERLAY_ICON}" --iconsize 100 \
            --message "Device inventory not found. \n\nPlease make sure the device serial number is correct." \
            --messagefont "name=Arial,size=17" \
            --button1text "Retry" \
            --button2text "Quit" \
            --infotext "V ${ScriptVersion}" \
            --ontop \
            --moveable \
            --small
        dialog_exit_code=$?

        if [[ "$dialog_exit_code" == 2 ]]; then
            logMe "INFO" "User chose to quit from retry dialog."
            Invalidate_Token
            exit 0
        else
            logMe "INFO" "User chose to retry."
            Check_Token_Expiration
            continue
        fi
    fi

    # Show the result
    logMe "INFO" "Displaying recovery key dialog..."
    $SW_DIALOG \
        --bannerimage "${SD_BANNER_IMAGE}" \
        --bannertitle "${SD_WINDOW_TITLE}" \
        --icon "${OVERLAY_ICON}" --iconsize 100 \
        --message "The Recovery Key for this device is: <br><br>**$filevault_recovery_key_retrieved**" \
        --messagefont "name=Arial,size=17" \
        --infotext "V ${ScriptVersion}" \
        --width 900 \
        --ontop \
        --moveable \
        --small &
    logMe "INFO" "Script completed successfully."
    Invalidate_Token
    exit 0
done
