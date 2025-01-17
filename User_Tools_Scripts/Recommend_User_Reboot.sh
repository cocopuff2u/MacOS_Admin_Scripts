#!/bin/sh

####################################################################################################
#
# Recommend Reboot via JamfHelper
#
# Purpose: Encourages the user to reboot after reaching maximum set uptime
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 5/30/23 - Master Release - @cocopuff2u
#
# 1.1 8/28/23 - Adjusted variable locations in the script - @cocopuff2u
#
#
####################################################################################################

# Allowed Maxminum Days without a reboot (Default: 14)
max_days="14"

## Gets boot time in unix seconds
uptime_raw=$(/usr/sbin/sysctl kern.boottime | awk -F'[= |,]' '{print $6}')

## Gets current time in unix seconds
time_now=$(date +"%s")

## Convert to uptime in days
uptime_days=$(($((time_now-uptime_raw))/60/60/24))

# Get the username of the currently logged in user 
loggedInUser=$(/bin/ls -la /dev/console | /usr/bin/cut -d ' ' -f 4)
#echo current logged in user
echo "Current User: $loggedInUser"

#echo current uptime
echo "This Mac has an uptime of $uptime_days days"

#This pulls current user to scope the path of the brandingimage
currentUser=$(/bin/echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil | /usr/bin/awk '/Name / { print $3 }')
# This will set a variable for the jamfHelper
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
#Window Type picks out how it is presented. Note: Your choices include utility, hud or fs
windowType="utility"
#Note: This can be BASE64, a Local File or a URL. If a URL the file needs to curl down prior to jamfHelper (Default: Jamf Branding Image Path)
icon="/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"
#"Window Title"
title="MacOS System Admin Message"
#"Window Heading"
heading="Reboot Recommended"
#"Window Message"
description="Your Mac has been running for $uptime_days days without a reboot. 

Its recommended to reboot your machine weekly in order to maintain a stable working system.

Would you like to reboot your Mac now?"

#"Button1"
button1="Proceed"
#"Button2"
button2="Decline"


if [ "$uptime_days" -ge "$max_days" ]; then
	/bin/echo "The uptime maximum has been reached, recommending user to restart."
	
## Section below uses jamfHelper for the dialog. This can be swapped out for a different messaging tool if desired
userChoice=$("$jamfHelper" -windowType "$windowType" -icon "$icon" -title "$title" -heading "$heading" -description "$description" -button1 "$button1" -button2 "$button2" -defaultButton 1 -cancelButton 2)

if [[ "$userChoice" == "0" ]]; then
echo "User accepted the reboot"

#Actions for Button 1 Go Here
osascript -e 'tell app "loginwindow" to «event aevtrrst»'

else
echo "User declined the reboot"
exit 0
fi

else
echo "Uptime limit not reached yet. Exiting."
exit 0
fi
