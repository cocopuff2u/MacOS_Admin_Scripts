#!/bin/bash

####################################################################################################
#
# Encourager via JamfHelper
#
# Purpose: Displays a JamfHelper window encouraging the end-user to download the MacOS Upgrade you provided
# It checks the current OS compared to the varible OS and then curls the URL provided, once it downloads
# it will have the application installer open, allowing the user to install right then, when they want, 
# or later on when they get prompted again
#
# https://github.com/cocopuff2u
#
# Note: This was designed to go from Major OS to Major OS and not minor updates. This works different than Nudge
# Id still recommend Nudge in most situations https://github.com/macadmins/nudge
#
#
####################################################################################################
# 
# HISTORY
#
# build 1.0 11/2/22 - This script is designed to prompt the user to download MacOS installer in the background direct from Apple. 
# Allows you to choose a specific OS instead of using the built in latest
#
# build 1.1 11/3/22 - Added Set -x to log results while testing this, also added recon to a proceed option
#
# build 1.2 11/4/22 - added a nested if than statement to catch if the applications was already there, added curl to download direct from Apple
#
# Build 1.3 4/11/23 - Upgraded Script to run for Ventura Deployment
#
# Build 1.4 8/29/23 - Removed Set -x, Added varibles for easier deployment/updates, and updated to support Sonoma latest
#
# Build 1.5 9/2/23 - Added Check if URL is live and added check if current version is higher than the deployable one
# 
#
####################################################################################################

####################################################################################################
#
#This section determines what you are upgrading too and the varibles for it

#MacOS Name You Are Pushing (Example - Sonoma, Ventura)
macos="Sonoma"
#MacOS Application Mame (Example - /Applications/Install MacOS Sonoma.app )
macosapplicationpath="/Applications/Install MacOS Sonoma.app"
#MacOS minimum version to prompt user, use whole numbers (Example - 14, 13, 12)
macosminversion="14"
#MacOS Installer URL (Best place i found the url's https://mrmacintosh.com/macos-sonoma-full-installer-database-download-directly-from-apple/)
macoscurlurl="https://swcdn.apple.com/content/downloads/26/09/042-58988-A_114Q05ZS90/yudaal746aeavnzu5qdhk26uhlphm3r79u/InstallAssistant.pkg"

#
####################################################################################################

####################################################################################################
#
#This section determines the messages the user will see

#This pulls current user to scope the path of the brandingimage
currentUser=$(/bin/echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil | /usr/bin/awk '/Name / { print $3 }')
#Current MacOS Version
currentmacosversion=$(sw_vers -productVersion | cut -c 1-2 )
# This will set a variable for the jamfHelper
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
#Window Type picks out how it is presented. Note: Your choices include utility, hud or fs
windowType="utility"
#Note: This can be BASE64, a Local File or a URL. If a URL the file needs to curl down prior to jamfHelper
#Default: Jamf Branding Image "/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"
icon="/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"
#"Window Title"
title="MacOS System Admin Reminder"
#"Window Heading"
heading="MacOS "$macos" Upgrade"
#"Window Message"
description="Currently we are in the process of upgrading those that can support MacOS "$macos". Your machine has been flagged for the upgrade.

This upgrade will download in the background with no user input needed. Once downloaded you can do the upgrade at your leisure. 

If the upgrade fails to download or install this prompt will rerun on next weekly check-in.

The upgrade will prompt when the download is complete or the MacOS upgrade will be located in the applications folder called 'install MacOS "$macos"'."

#Second "Window Message" if declined
descriptionno="Upgrade reminder will be pushed weekly until the upgrade is complete.

If you are unable to upgrade due to limitations please reach out to the Mac Administrator."

#"Button1"
button1="Proceed"
#"Button1no"
button1no="Close"
#"Button2"
button2="Decline"

#
####################################################################################################


####################################################################################################
#
#This section below is main script

#Check to see if current version is greater than the listed one
if [ "$macosminversion" -gt "$currentmacosversion" ]; then
    echo "Users MacOS version is not greater than the required OS"
        #Check to see if URL is live before asking user to download
        if curl --output /dev/null --silent --head --fail "$macoscurlurl"; then
        echo "URL is live."
        #Set the default button. Your choices are 1 or 2. button2 is for the decline button on the second window. Note: Default and Cancel buttons let the user press the "Return" key or "Escape" key
        #This will set a variable for jamfHelper to do an action...
        userChoice=$("$jamfHelper" -windowType "$windowType" -icon "$icon" -title "$title" -heading "$heading" -description "$description" -button1 "$button1" -button2 "$button2" -defaultButton 1 -cancelButton 2)
                if [[ "$userChoice" == "0" ]]; then
                        #Actions for Button 1 Go Here (User Pressed Proceed)
                        echo "User proceeded with install"
                        if [ -d "$macosapplicationpath" ] ; then
                        open "$macosapplicationpath"
                        else
                        curl "$macoscurlurl" -o /tmp/InstallAssistant.pkg
                        sleep 10
                        installer -pkg /tmp/InstallAssistant.pkg -target /
                        sleep 20
                        open "$macosapplicationpath"
                        jamf recon
                        fi
                else
                #Actions for Button 2 Go Here (User Pressed Decline)
                echo "User declined the Install"
                "$jamfHelper" -windowType "$windowType" -icon "$icon" -title "$title" -heading "$heading" -description "$descriptionno" -button1 "$button1no"  -defaultButton 1
                fi
        else
        echo "URL is not responding, Not prompting user" 
        exit 0
        fi
    else 
    echo "users version is greater than the required OS, Not prompting user"
    fi
exit 0