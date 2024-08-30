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
# To Run: Sudo zsh /PATH/TO/SCRIPT.SH
#
####################################################################################################
#
#   History
#
#  1.0 03/01/24 - Original
#
#  1.1 03/06/24 - Gave the user a selective prompt for various loops, fixed logging, and icon check
#
#  1.2 03/20/24 - Fixed loop for 60
#
####################################################################################################

# Path to our dialog binary
dialogPath='/usr/local/bin/dialog'
# Path to our dialog command file
dialogCommandFile=$(mktemp /var/tmp/trellixloopDialog.XXXXX)
#Note: This can be BASE64, a Local File or a URL
icon="/Applications/Trellix Endpoint Security for Mac.app/Contents/Resources/McAfee_Locked.png"
#"Window Title"
titleloop="Trellix Update In Progress"
title="Trellix Loop Utility"
#"Window Message During Loop"
descriptionloop="May take a few minutes"
#"Window Message To Select Loop"
description="Choose the number of loops for executing Trellix updates"
#Help Message
helpmessage="This script is crafted to automate essential Trellix update functions on MacOS in conjunction with the EPO server. The loop iterates through all permissible commands to EPO, incorporating a sleep function between each command for optimal execution."
# Script Log Location [ /var/log/org.YOURCOMPANY.log ] (i.e., Your organization's default location for client-side logs)
scriptLog="${4:-"/var/log/org.trellixloopupdate.log"}"

#"Button1"
button1="Exit"
#"Button2"
button2="Select"



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
    # The path is missing, so perform action x
    updateScriptLog "Trellix Loop Updates: icon path not valid, using default icon...."
    icon="SF=clock.arrow.2.circlepath,colour=green,colour2=blue,weight=bold"
else
    updateScriptLog "Trellix Loop Updates: Icon valid, proceeding...."
fi



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Validate / install swiftDialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function dialogInstall() {

    # Get the URL of the latest PKG From the Dialog GitHub repo
    dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")

    # Expected Team ID of the downloaded PKG
    expectedDialogTeamID="PWA5E9TQ59"

    updateScriptLog "Trellix Loop Updates: Installing swiftDialog...."

    # Create temporary working directory
    workDirectory=$( /usr/bin/basename "$0" )
    tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )

    # Download the installer package
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"

    # Verify the download
    teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')

    # Install the package if Team ID validates
    if [[ "$expectedDialogTeamID" == "$teamID" ]]; then

        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
        sleep 2
        dialogVersion=$( /usr/local/bin/dialog --version )
        updateScriptLog "Trellix Loop Updates: swiftDialog version ${dialogVersion} installed; proceeding...."

    else

        # Display a so-called "simple" dialog if Team ID fails to validate
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "Self Heal Your Mac: Error" buttons {"Close"} with icon caution' & exit 0

    fi

    # Remove the temporary working directory when done
    /bin/rm -Rf "$tempDirectory"

}

function dialogCheck() {

    # Check for Dialog and install if not found
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

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Flight: Prompts users to select loop of Trellix Updates
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# This function sends a command to our command file, and sleeps briefly to avoid race conditions
function dialog_command()
{
echo "$@" >> "$dialogCommandFile"
sleep 0.1
}

# Needed a slight delay with DialogCheck
sleep 0.1

updateScriptLog "Trellix Loop Updates: Prompting user for loop selection...."

exit_status=$(
    $dialogPath \
    --title "$title" \
    --message "$description" \
    --ontop \
    --commandfile "$dialogCommandFile" \
    --icon "$icon" \
    --button1 \
    --button1text "$button2" \
    --button2 \
    --button2text "$button1" \
    --selecttitle "Select below the amount of loop cycles:",radio \
    --selectvalues "5 Loops, 10 Loops, 20 Loops, 60 Loops" \
    --helpmessage "$helpmessage" \ | grep "SelectedOption" | awk -F ": " '{print $NF}'
)

if [[ $exit_status == *5* ]]; then
    updateScriptLog "Trellix Loop Updates: User selected 5 loops...."
    iterations=5
elif [[ $exit_status == *10* ]]; then
    updateScriptLog "Trellix Loop Updates: User selected 10 loops...."
    iterations=10
elif [[ $exit_status == *20* ]]; then
    updateScriptLog "Trellix Loop Updates: User selected 20 loops...."
    iterations=20
elif [[ $exit_status == *60* ]]; then
    updateScriptLog "Trellix Loop Updates: User selected 60 loops...."
    iterations=60
else
    updateScriptLog "Trellix Loop Updates: User selected exit or timed-out"
    exit 0
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
# ${#itemsToProgress[@]} is equal to the number of items in our array

$dialogPath \
    --title $title \
    --message $descriptionloop  \
    --ontop \
    --mini \
    --commandfile "$dialogCommandFile" \
    --progress ${#itemsToProgress[@]} \
    --icon $icon \
    --button1 \ &


# Display the bouncy bounce for 2 seconds
sleep 2

# Iterate through our array
# For each item we've outlined
for 2 in "${itemsToProgress[@]}"; do
    dialog_command "progress: increment"
    dialog_command "progresstext: $2"
    updateScriptLog "Trellix Loop Updates: $2"
    /Library/McAfee/agent/bin/cmdagent -c &>/dev/null
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -e &>/dev/null
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -p &>/dev/null
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -f &>/dev/null
    sleep 5
done

# Close our dialog window
dialog_command "quit:"
echo "Completed the loop, SwiftDialog closed"

# Delete our command file
rm "$dialogCommandFile"

updateScriptLog "Trellix Loop Updates: Loop Completed"

exit 0
