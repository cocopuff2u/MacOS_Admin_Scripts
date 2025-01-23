#!/bin/zsh
#set -x
####################################################################################################
#
# # Trellix Loop Update Selection
#
# Purpose: Prompts users to select loop of Trellix Updates
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
#   History
#
#  1.0 03/01/24 - Original
#
#  1.1 03/06/24 - Gave the user a selective prompt for various loops, fixed logging, and icon check
#
#  2.0 01/17/24 - Added movable windows functionality, enhanced the loop screen with additional
#                 information, implemented an Early Exit feature, and added more loops for selection
#                 to improve user interaction.
#
####################################################################################################

# Script Version
ScriptVersion="2.0"
# Path to the dialog binary
dialogPath='/usr/local/bin/dialog'
# Create a temporary file for dialog commands
dialogCommandFile=$(mktemp /var/tmp/trellixloopDialog.XXXXX) && chmod 644 "$dialogCommandFile"
# Note: This can be BASE64, a local file, or a URL
icon="/Applications/Trellix Endpoint Security for Mac.app/Contents/Resources/Application.icns"
# Window Titles
titleloop="Trellix Update In Progress"
title="Trellix Loop Utility"
# Window Messages
descriptionloop="Commands are running and will auto-close when done. Then, open Trellix, press update, and reboot if needed."
description="Select the loops to set how many times the updates run. Afterward, open the Trellix app, press update, and reboot if needed"
# Help Message
helpmessage="This script performs a series of Trellix update commands in a loop. The commands executed in each loop are:
1. cmdagent -c: Checking for new policies
2. cmdagent -e: Enforcing new policies
3. cmdagent -p: Collecting and sending properties
4. cmdagent -f: Sending events"
# Script Log Location
scriptLog="${4:-"/var/log/org.trellixloopupdate.log"}"
# Button Labels
button1="Exit"
button2="Select"
buttonLoop="Exit Early"



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Logging
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Script Logging Function
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function updateScriptLog() {
    echo -e "$( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

updateScriptLog "Trellix Loop Updates: Starting...."

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Checking for Icon Availability
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

updateScriptLog "Trellix Loop Updates: Checking for icon path...."
if [ ! -e "$icon" ]; then
    updateScriptLog "Trellix Loop Updates: icon path not valid, using default icon...."
    icon="SF=clock.arrow.2.circlepath,colour=green,colour2=blue,weight=bold"
else
    updateScriptLog "Trellix Loop Updates: Icon valid, proceeding...."
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Validate / install swiftDialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function dialogInstall() {
    dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")
    expectedDialogTeamID="PWA5E9TQ59"
    updateScriptLog "Trellix Loop Updates: Installing swiftDialog...."
    workDirectory=$( /usr/bin/basename "$0" )
    tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"
    teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')
    if [[ "$expectedDialogTeamID" == "$teamID" ]]; then
        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
        sleep 2
        dialogVersion=$( /usr/local/bin/dialog --version )
        updateScriptLog "Trellix Loop Updates: swiftDialog version ${dialogVersion} installed; proceeding...."
    else
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "Self Heal Your Mac: Error" buttons {"Close"} with icon caution' & exit 0
    fi
    /bin/rm -Rf "$tempDirectory"
}

function dialogCheck() {
    if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then
        updateScriptLog "Trellix Loop Updates: swiftDialog not found. Installing...."
        dialogInstall
    else
        dialogVersion=$(/usr/local/bin/dialog --version)
        if [[ "${dialogVersion}" < "${swiftDialogMinimumRequiredVersion}" ]]; then
            updateScriptLog "Trellix Loop Updates: swiftDialog version ${dialogVersion} found but swiftDialog ${swiftDialogMinimumRequiredVersion} or newer is required; updating...."
            dialogInstall
        else
            updateScriptLog "Trellix Loop Updates: swiftDialog version ${dialogVersion} found; proceeding...."
        fi
    fi
}

dialogCheck

# Keep the system awake while the script is running
caffeinate -dimsu &
updateScriptLog "Trellix Loop Updates: System caffeinate started...."

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Flight: Prompts users to select loop of Trellix Updates
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# This function sends a command to our command file, and sleeps briefly to avoid race conditions
function dialog_command(){
    echo "$@" >> "$dialogCommandFile"
    sleep 0.1
}

# Needed a slight delay with DialogCheck
sleep 0.1

updateScriptLog "Trellix Loop Updates: Prompting user for loop selection...."

# Get the Last Policy Update Time
last_policy_update=$(date -j -f "%Y%m%d%H%M%S" $(/Library/McAfee/agent/bin/cmdagent -i | grep LastPolicyUpdateTime | awk -F: '{print $2}' | tr -d ' ') "+%b %d, %Y %I:%M %p")
[[ -z "$last_policy_update" ]] && last_policy_update="N/A"

# Get the Last DAT Update Time
last_dat_date=$(date -u -r $(/usr/bin/defaults read /Library/Preferences/com.mcafee.ssm.antimalware.plist Update_DAT_Time) +"%m/%d/%y")
[[ -z "$last_dat_date" ]] && last_dat_date="N/A"

# Get the Last DLP Update Time
last_dlp_date=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" $(/usr/bin/defaults read /usr/local/McAfee/DlpAgent/var/Info.plist PolicyModificationDate) +"%m/%d/%y")
[[ -z "$last_dlp_date" ]] && last_dlp_date="N/A"

# Get the Agent Version
agent_version=$(/Library/McAfee/agent/bin/cmdagent -i | grep "^Version:" | awk '{print $2}')
[[ -z "$agent_version" ]] && agent_version="N/A"

# Extract the version for various components
statefull_firewall=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Statefull Firewall" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$statefull_firewall" ]] && statefull_firewall="N/A"

data_loss_prevention=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Data Loss Prevention" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$data_loss_prevention" ]] && data_loss_prevention="N/A"

trellix_data_exchange_layer=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Trellix Data Exchange Layer" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$trellix_data_exchange_layer" ]] && trellix_data_exchange_layer="N/A"

epm_general=$(/Library/McAfee/agent/bin/cmdagent -i | grep "EPM General" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$epm_general" ]] && epm_general="N/A"

threat_protection_for_mac=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Threat Protection for Mac" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$threat_protection_for_mac" ]] && threat_protection_for_mac="N/A"

webprotection=$(/Library/McAfee/agent/bin/cmdagent -i | grep "WebProtection" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$webprotection" ]] && webprotection="N/A"

trellix_policy_auditor_advanced_host_assessment=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Trellix Policy Auditor Advanced Host Assessment" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$trellix_policy_auditor_advanced_host_assessment" ]] && trellix_policy_auditor_advanced_host_assessment="N/A"

policy_auditor=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Policy Auditor" | sed 's/.*(\([^)]*\)).*/\1/')
[[ -z "$policy_auditor" ]] && policy_auditor="N/A"

exit_status=$(
    $dialogPath \
    --title "$title" \
    --message "$description <br><br>**Local Agent and Component Version Details**<br>Agent Version: \`$agent_version\` <br>Threat Prevention Version: \`$threat_protection_for_mac\` <br>Firewall Version: \`$statefull_firewall\` <br>Web Control Version: \`$webprotection\`  <br>Data Loss Prevention Version: \`$data_loss_prevention\` " \
    --ontop \
    --moveable \
    --commandfile "$dialogCommandFile" \
    --icon "$icon" \
    --messagefont "size=14" \
    --button1 \
    --button1text "$button2" \
    --button2 \
    --button2text "$button1" \
    --infobox "**Last Policy Update:** <br> \`$last_policy_update\` <br> **Last DAT Date:** <br> \`$last_dat_date\` <br> **Last DLP Date:** <br> \`$last_dlp_date\`" \
    --infotext "V $ScriptVersion" \
    --selecttitle "Select the amount of loop cycles:",required \
    --selectvalues "5 Loops, 10 Loops, 20 Loops, ---, 60 Loops, 120 Loops, 240 loops" \
    --helpmessage "$helpmessage" \ | grep "SelectedOption" | awk -F ": " '{print $NF}' | grep -o '[0-9]\+'
)

if [[ -z $exit_status ]]; then
    updateScriptLog "Trellix Loop Updates: User selected exit or timed-out"
    # Close our dialog window
    dialog_command "quit:"
    updateScriptLog "Trellix Loop Updates: Completed the loop, SwiftDialog closed"

    # Delete our command file
    rm "$dialogCommandFile"
    updateScriptLog "Trellix Loop Updates: Deleted command file"

    # Stop caffeinate
    kill %1
    updateScriptLog "Trellix Loop Updates: Stopped system caffeinate"

    updateScriptLog "Trellix Loop Updates: Loop Completed"
    exit 0
else
    updateScriptLog "Trellix Loop Updates: User selected $exit_status loops...."
    iterations=$exit_status
fi

# An array containing the list of items to progress through
itemsToProgress=()

# Populate the array with elements containing loop count
for ((i=1; i<=iterations; i++)); do
    itemsToProgress+=("Looping Trellix Updates: $i/$iterations")
done

# Print the elements of the array
for element in "${itemsToProgress[@]}"; do
    echo "$element"
done

sleep 1.0

# Calling our initial dialog window. The & is crucial so that our script progresses.
$dialogPath \
    --title $title \
    --message "$descriptionloop <br><br>**Local Agent and Component Version Details**<br>Agent Version: \`$agent_version\` <br>Threat Prevention Version: \`$threat_protection_for_mac\` (_DAT DATE:_ \`$last_dat_date\`) <br>Firewall Version: \`$statefull_firewall\` <br>Web Control Version: \`$webprotection\`  <br>Data Loss Prevention Version: \`$data_loss_prevention\` (_DLP DATE:_ \`$last_dlp_date\`)"  \
    --ontop \
    --small \
    --messagefont "size=12" \
    --commandfile "$dialogCommandFile" \
    --progress ${#itemsToProgress[@]} \
    --button1 \
    --button1text "$buttonLoop" \
    --icon $icon \
    --infotext "V $ScriptVersion " \
    --moveable \
    --helpmessage "$helpmessage" \
    --button1 \ &

# Capture the PID of the dialog process
dialogPID=$!
updateScriptLog "Trellix Loop Updates: Dialog process started with PID $dialogPID...."

# Function to check if the dialog process is still running
function check_dialog_process() {
    if ! ps -p $dialogPID > /dev/null; then
        updateScriptLog "Trellix Loop Updates: Dialog process closed, terminating loop...."
        # Close our dialog window
        dialog_command "quit:"
        updateScriptLog "Trellix Loop Updates: Completed the loop, SwiftDialog closed"

        # Delete our command file
        rm "$dialogCommandFile"
        updateScriptLog "Trellix Loop Updates: Deleted command file"

        # Stop caffeinate
        kill %1
        updateScriptLog "Trellix Loop Updates: Stopped system caffeinate"

        updateScriptLog "Trellix Loop Updates: Loop Completed"
        exit 0
    fi
}

# Display the bouncy bounce for 2 seconds
sleep 2

# Iterate through our array
for element in "${itemsToProgress[@]}"; do
    check_dialog_process

    # Re-fetch version variables
    agent_version=$(/Library/McAfee/agent/bin/cmdagent -i | grep "^Version:" | awk '{print $2}')
    [[ -z "$agent_version" ]] && agent_version="N/A"

    statefull_firewall=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Statefull Firewall" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$statefull_firewall" ]] && statefull_firewall="N/A"

    data_loss_prevention=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Data Loss Prevention" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$data_loss_prevention" ]] && data_loss_prevention="N/A"

    trellix_data_exchange_layer=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Trellix Data Exchange Layer" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$trellix_data_exchange_layer" ]] && trellix_data_exchange_layer="N/A"

    epm_general=$(/Library/McAfee/agent/bin/cmdagent -i | grep "EPM General" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$epm_general" ]] && epm_general="N/A"

    threat_protection_for_mac=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Threat Protection for Mac" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$threat_protection_for_mac" ]] && threat_protection_for_mac="N/A"

    webprotection=$(/Library/McAfee/agent/bin/cmdagent -i | grep "WebProtection" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$webprotection" ]] && webprotection="N/A"

    trellix_policy_auditor_advanced_host_assessment=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Trellix Policy Auditor Advanced Host Assessment" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$trellix_policy_auditor_advanced_host_assessment" ]] && trellix_policy_auditor_advanced_host_assessment="N/A"

    policy_auditor=$(/Library/McAfee/agent/bin/cmdagent -i | grep "Policy Auditor" | sed 's/.*(\([^)]*\)).*/\1/')
    [[ -z "$policy_auditor" ]] && policy_auditor="N/A"

    last_dat_date=$(date -u -r $(/usr/bin/defaults read /Library/Preferences/com.mcafee.ssm.antimalware.plist Update_DAT_Time) +"%m/%d/%y")
    [[ -z "$last_dat_date" ]] && last_dat_date="N/A"

    last_dlp_date=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" $(/usr/bin/defaults read /usr/local/McAfee/DlpAgent/var/Info.plist PolicyModificationDate) +"%m/%d/%y")
    [[ -z "$last_dlp_date" ]] && last_dlp_date="N/A"

    dialog_command "progress: increment"
    dialog_command "message: $descriptionloop <br><br>**Local Agent and Component Version Details**<br>Agent Version: \`$agent_version\` <br>Threat Prevention Version: \`$threat_protection_for_mac\` (_DAT DATE:_ \`$last_dat_date\`) <br>Firewall Version: \`$statefull_firewall\` <br>Web Control Version: \`$webprotection\`  <br>Data Loss Prevention Version: \`$data_loss_prevention\` (_DLP DATE:_ \`$last_dlp_date\`)"
    dialog_command "progresstext: $element (Step 1: Checking For New Policies)"
    updateScriptLog "Trellix Loop Updates: Executing cmdagent -c: $element"
    /Library/McAfee/agent/bin/cmdagent -c &>/dev/null
    check_dialog_process
    sleep 5
    dialog_command "progresstext: $element (Step 2: Enforcing New Policies)"
    updateScriptLog "Trellix Loop Updates: Executing cmdagent -e: $element"
    /Library/McAfee/agent/bin/cmdagent -e &>/dev/null
    check_dialog_process
    sleep 5
    dialog_command "progresstext: $element (Step 3: Collecting and Sending)"
    updateScriptLog "Trellix Loop Updates: Executing cmdagent -p: $element"
    /Library/McAfee/agent/bin/cmdagent -p &>/dev/null
    check_dialog_process
    sleep 5
    dialog_command "progresstext: $element (Step 4: Sending Events)"
    updateScriptLog "Trellix Loop Updates: Executing cmdagent -f: $element"
    /Library/McAfee/agent/bin/cmdagent -f &>/dev/null
    check_dialog_process
    sleep 5
done

# Close our dialog window
dialog_command "quit:"
updateScriptLog "Trellix Loop Updates: Completed the loop, SwiftDialog closed"

# Delete our command file
rm "$dialogCommandFile"
updateScriptLog "Trellix Loop Updates: Deleted command file"

# Stop caffeinate
kill %1
updateScriptLog "Trellix Loop Updates: Stopped system caffeinate"

updateScriptLog "Trellix Loop Updates: Loop Completed"

exit 0
