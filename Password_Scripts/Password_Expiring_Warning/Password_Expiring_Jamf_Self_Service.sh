#!/bin/sh

####################################################################################################
#
# Password Change Warning via OSAScript
#
# Purpose: Displays a triggered window encouraging the end-user change the password for there account
# before the expired date. If the user decides to change it, it will open the system preference
# change password window
#
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# Build 1.0 3/22/23 - Allows local user to display current password expire days with the option to change it
#
# Build 1.1 10/4/23 - Changed the script to support older and newer operating system password path
# 
#
####################################################################################################

####################################################################################################
#
# 
#Set maximum days before the password expires, should match the MDM password day policy
MAX_PASSWORD_AGE=60


####################################################################################################
#
#This section is the password logic section
#
####################################################################################################
TEMP_PLIST="/tmp/pwdpolicy.plist"

for user in $(ls -l /dev/console | awk '{print $3}'); do
    
    dscl . read /Users/"$user" accountPolicyData | sed '1d' > $TEMP_PLIST
    
    LAST_SET=$(defaults read $TEMP_PLIST passwordLastSetTime | cut -d"." -f 1)
    CURRENT_UNIX_TIME=$(date +"%s")
    
    PASSWORD_LAST_SET_DAYS=$(( LAST_SET / 86400 ))
    CURRENT_TIME_DAYS=$(( CURRENT_UNIX_TIME / 86400 ))
    
    PASSWORD_SET_DAYS=$(( CURRENT_TIME_DAYS - PASSWORD_LAST_SET_DAYS ))
    
    TIME_TO_CHANGE=$(( MAX_PASSWORD_AGE - PASSWORD_SET_DAYS ))

    rm $TEMP_PLIST
    
done
####################################################################################################
#
#This section is the main script
#
####################################################################################################

#Current MacOS Version (Needed for the new path to the password reset on Monterey or higher)
currentmacosversion=$(sw_vers -productVersion | cut -c 1-2 )
getUID=$(id -u "$user")

echo "$user password will expire in $TIME_TO_CHANGE days"
echo "$user password was set $PASSWORD_SET_DAYS days ago"
#Checks current MacOS and changes the OSAscript to use the correct path to open the password
if [ "13" -gt "$currentmacosversion" ]; then
echo "Users MacOS is less than MacOS Monterey"
        if [[ "$TIME_TO_CHANGE" -gt 1 ]]; then
        launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password will expire in '$TIME_TO_CHANGE' days. 

        You can change it in System Preferences under Users & Groups.

        To avoid being locked out please change it before it expires." with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Preferences" to delay 2' -e 'tell application "System Events" to tell process "System Preferences" to click button "Change Password…" of tab group 1 of window "Users & Groups"' 2> /dev/null
        else
        launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password has expired. 

        To avoid being locked out change it now." with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Cancel", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Preferences" to delay 2' -e 'tell application "System Events" to tell process "System Preferences" to click button "Change Password…" of tab group 1 of window "Users & Groups"' 2> /dev/null
        fi
else
echo "Users MacOS is greater than Ventura"
        if [[ "$TIME_TO_CHANGE" -gt 1 ]]; then
        launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password will expire in '$TIME_TO_CHANGE' days. 

        You can change it in System Preferences under Users & Groups.

        To avoid being locked out please change it before it expires." with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 4 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window "Users & Groups"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 3 of group 1 of scroll area 1 of group 1 of sheet 1 of window "Users & Groups"' 2> /dev/null
        else
        launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password has expired. 

        To avoid being locked out please change it now." with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 4 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window "Users & Groups"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 3 of group 1 of scroll area 1 of group 1 of sheet 1 of window "Users & Groups"' 2> /dev/null
        fi
fi
exit 0
