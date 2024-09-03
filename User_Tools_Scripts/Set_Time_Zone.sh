#!/bin/zsh

####################################################################################################
#
# Set Time Zone via AppleScript & JamfHelper (for confirmation)
#
# Purpose: Allow end-user to set timezone based with a confirmation
#
# Note: optional Jamfhelper or AppleScript Only
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 8/29/23 - Original Release - @cocopuff2u
#
#
####################################################################################################

#This pulls current user to scope the path of the brandingimage
currentUser=$(/bin/echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil | /usr/bin/awk '/Name / { print $3 }')
# This will set a variable for the jamfHelper
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
#Window Type picks out how it is presented. Note: Your choices include utility, hud or fs
windowType="utility"
#Icon Note: This can be BASE64, a Local File or a URL. If a URL the file needs to curl down prior to jamfHelper (Default: Jamf Branding Image Path)
icon="/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"
#Icon2 Note: This one is used for AppleScript 
icon2="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ToolbarCustomizeIcon.icns"
#"Window Title Success"
title="Time Zone Changed Succcessful"
#"Window Title Failure"
title2="Time Zone Changed Failed"
#"Button1"
button1="Okay"


timezones=("${(@)${(@)${(f)$(systemsetup -listtimezones | awk '{$1=$1;print}')}##[[:space:]]##}[2,-1]}")
selectedTimeZone=$(osascript <<OSA
    set ASlist to the paragraphs of "$(printf '%s\n' "${timezones[@]}")"
    set selectedSSID to choose from list ASlist with prompt "Choose the Time Zone you are in:" with title "Time Zone Selection" default items {""}
selectedSSID
OSA
)

if [[ $selectedTimeZone == "false" ]];then
    echo "User aborted"
	exit 0
fi
echo ${selectedTimeZone}
systemsetup -settimezone ${selectedTimeZone}

timeZone=$(systemsetup -gettimezone | cut -d ':' -f 2 | xargs)

if [[ $timeZone == *"$selectedTimeZone"* ]];then
# Use (#) to comment out the JamfHelper section below
   "$jamfHelper"  -windowType "$windowType" -title "$title" -description "The Time Zone was successfully changed to \"$selectedTimeZone\" ." -icon "$icon" -button1 "$button1"  -defaultButton 1 -timeout 1200

# Remove all (##) to enable the AppleScript section below
##   /usr/bin/osascript <<EOT
##   tell application (path to frontmost application as text)
##        display dialog "The Time Zone was successfully changed to $selectedTimeZone" buttons {"Okay"}with title "$title" with icon posix file "$icon2"
##    end tell
##EOT
	echo "User was successful $selectedTimeZone"
else
# Use (#) to comment out the JamfHelper section below
  "$jamfHelper"  -windowType "$windowType" -title "$title2" -description "The Time Zone was not changed to \"$selectedTimeZone\" due to an unknown error." -icon "$icon" -button1 "$button1"  -defaultButton 1 -timeout 1200
	
# Remove all (##) to enable the AppleScript section below
##   /usr/bin/osascript <<EOT
##   tell application (path to frontmost application as text)
##        display dialog "The Time Zone was not changed changed to $selectedTimeZone" buttons {"Okay"}with title "$title" with icon posix file "$icon2"
##    end tell
	echo "User was unsuccessful"

Exit 0
fi
