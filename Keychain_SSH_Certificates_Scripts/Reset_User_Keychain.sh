#!/bin/bash

####################################################################################################
#
# # Reset Users Keychain
#
# Purpose: Reset Users keychain
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
#   History
#
#  1.0 04/10/24 - Original
#  1.1 09/04/24 - Added adjustable Variables
#
####################################################################################################
loggedInUser=$(ls -l /dev/console | awk '{ print $3 }')
####################################################################################################

# Message Before Starting the Script
Beginning_Message="This script will clear the user $loggedInUser local keychain. Do you want to continue?"

# Message When Script is Done
Exit_Message="The keychain has been reset. Please reboot your system for changes to take effect."

# Icon for the Window
Message_Icon="/System/Applications/Utilities/Keychain Access.app/Contents/Resources/AppIcon.icns"

####################################################################################################

# Prompt the user to confirm before proceeding
osascript -e 'display dialog "'"$Beginning_Message"'" buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" with icon POSIX file "'"$Message_Icon"'"'

# Check the user's response to the prompt
response=$(echo $?)

if [ $response -eq 1 ]; then
    echo "User canceled the operation."
    exit 0
fi

# Uncomment the following line to perform keychain deletion
rm -Rf /Users/$loggedInUser/Library/Keychains/*

# Inform the user that the keychain was reset and to reboot
osascript -e 'display dialog "'"$Exit_Message"'" buttons {"OK"} default button "OK" with icon POSIX file "'"$Message_Icon"'"'

exit 0
