#!/bin/sh
####################################################################################################
#
# # Enable BootStrap Token Jamf
#
# Purpose: Fixes the jamf error "Bootstrap Token functionality is not supported on the server"
# 
# https://github.com/cocopuff2u
#
# To Run: Sudo bash /PATH/TO/SCRIPT.SH
#
# Notes: You will still need to prompt the user to escrow the key to Jamf
#
####################################################################################################
#
#   History
#
#  1.0 07/19/24 - Original
#
####################################################################################################
####################################################################################################
# Authentication method is using Bearer Token
####################################################################################################
# API Settings Needed
#
# API ROLE
# Role Name: jamfBootstrapper
# Privileges:
# Read Computer Inventory Collection, View MDM command information in Jamf Pro API, Read Computers, Update Computer Inventory Collection Settings, Send Software Update Settings Command, Send Enable Bootstrap Token Command
#
# API Client
# API Display Name: jamfBootstrap
# API Role: jamfBootstrapper
# Access Token Lifetime: 60
# Enable API Client
# ** Copy the Client ID and Client Secret into the fields below **
####################################################################################################

# Set up default values or use provided arguments
# Recommended to use parameters 4,5,6,8 inside Jamf to fill these out
url=${4:-"https://yourcompany.com"}
client_id=${5:-"CLIENTID"}
client_secret=${6:-"CLIENTSECRET"}

# Define log file location
LOG_FILE=${8:-"/var/log/my_script.log"}

# Function to log messages with timestamps
log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Initialize log file
log "Script started."

# Get the serial number of the machine
serial_number=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

# Log initial parameters
log "Using URL: $url"
log "Client ID: $client_id"
log "Serial Number: $serial_number"

# Function to get an access token
getAccessToken() {
    log "Fetching access token..."
    response=$(curl --silent --location --request POST "${url}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${client_secret}")

    # Extract access token and expiration
    bearer_token=$(echo "$response" | plutil -extract access_token raw -)
    token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)

    # Check if the bearer token is successfully retrieved
    if [ -z "$bearer_token" ]; then
        log "Error: Failed to retrieve access token. Response: $response"
        exit 1
    fi

    log "Bearer token obtained successfully. Expires in $token_expires_in seconds."
}

# Call the function to get the access token
getAccessToken

# Function to get the computer ID from Jamf API using the serial number
get_id() {
    log "Getting management ID..."
    computerId=$(curl -s \
        --request GET \
        --url "${url}/JSSResource/computers/serialnumber/$serial_number" \
        --header 'Accept: text/xml' \
        --header "Authorization: Bearer $bearer_token" \
        | xmllint --xpath '/computer/general/id/text()' -)
    
    # Check if the computer ID is successfully retrieved
    if [ -z "$computerId" ]; then
        log "Error: Failed to retrieve computer ID. Response: $(curl -s --request GET --url "${url}/JSSResource/computers/serialnumber/$serial_number" --header 'Accept: text/xml' --header "Authorization: Bearer $bearer_token")"
        exit 1
    fi

    log "Computer ID retrieved: $computerId"
}

# Call the function to get the computer ID
get_id

# Log the retrieved computer ID
log "ComputerID: $computerId"

# Perform the curl request to get the computer inventory data
response=$(curl --silent --location --request GET "${url}/api/v1/computers-inventory/$computerId" \
    --header "Authorization: Bearer $bearer_token" \
    --header 'Accept: application/json')

# Extract management ID from the response
mgmtID=$(echo "$response" | grep -o '"managementId" : "[^"]*"' | cut -d'"' -f4)

# Check if the management ID is empty
if [ -z "$mgmtID" ]; then
    log "Error: Management ID is empty. Response: $response"
    exit 1
fi

# Log the retrieved management ID and serial number
log "Management ID: $mgmtID"
log "Serial Number: $serial_number"

# API command to set bootstrap to enabled
log "Sending bootstrap command..."
bootstrap=$(curl --silent --location --request POST "${url}/api/v2/mdm/commands"\
     --header "Authorization: Bearer $bearer_token" \
     --header 'accept: application/json' \
     --header 'content-type: application/json' \
     --data '{
  "clientData": [
    {
      "managementId": "'"$mgmtID"'"
    }
  ],
  "commandData": {
    "commandType": "SETTINGS",
    "bootstrapTokenAllowed": true
  }
}')

# Log the response from the bootstrap command with separators
log "####################"
log "Bootstrap command response:"
log "$bootstrap"
log "####################"

# End of script
log "Script completed successfully."
exit 0
