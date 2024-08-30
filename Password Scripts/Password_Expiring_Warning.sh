#!/bin/sh
####################################################################################################
#
# Password Change Warning via OSAScript
# Purpose: Displays a simple window encouraging the end-user change the password for there account
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
# Build 1.0 3/21/23 - Looks for local users and does the math to find out how many days remain, warns the user to change password based on time frame
# Once the user is warned it prompts them to change the password
#
# Build 1.1 3/27/23 - Changed Echo to reflect password date and shortened the notfication time from 30 days to 20 Days
#
# Build 1.2 5/22/23 - Path of Ventura Change password button has changed, adjusted it for Ventura
#
# Build 1.3 10/4/23 - Changed the script to support older and newer operating system password path
#
# Build 1.4 4/10/24 - Increased delay from 2 to 4 greater than Ventura, was triggering to quick and not opening
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

for user in $(/bin/ls -la /dev/console | /usr/bin/cut -d ' ' -f 4); do
    
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

#Checks current MacOS and changes the OSAscript to use the correct path to open the password
if [ "13" -gt "$currentmacosversion" ]; then
        echo "Users MacOS is less than MacOS Monterey"
        if [ "$TIME_TO_CHANGE" -gt 60 ];then
                echo "The password for $user is outside the warning period of 20 days. Password expires in $TIME_TO_CHANGE days."
                exit 0
        elif [ "$TIME_TO_CHANGE" -le 60 ] && [ "$TIME_TO_CHANGE" -gt 1 ];
        then
                echo "The password for $user expires in $TIME_TO_CHANGE days!"
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password expires in '$TIME_TO_CHANGE' days!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Expiration Warning" with text buttons {"Maybe Later", "Change Password"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Preferences" to delay 2' -e 'tell application "System Events" to tell process "System Preferences" to click button "Change Password…" of tab group 1 of window "Users & Groups"' 

        elif [ "$TIME_TO_CHANGE" = 1 ];
        then
                echo "The password for $user expires in 1 day!"	
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password expires tomorrow!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Expiration Warning" with text buttons {"Maybe Later", "Change Password"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Preferences" to delay 2' -e 'tell application "System Events" to tell process "System Preferences" to click button "Change Password…" of tab group 1 of window "Users & Groups"' 
                
        elif [ "$TIME_TO_CHANGE" = 0 ];
        then
                echo "The password for $user expires today!"	
                launchctl asuser "$getUID"/usr/bin/osascript -e 'Tell current application to display dialog "Your password expires today!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Expiration Warning" with text buttons {"Maybe Later", "Change Password"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Preferences" to delay 2' -e 'tell application "System Events" to tell process "System Preferences" to click button "Change Password…" of tab group 1 of window "Users & Groups"' 	
        elif [ "$TIME_TO_CHANGE" -lt 0 ];
        then
                echo "The password for $user has expired!"	
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password has expired! Attempt to change your password or contact the Mac Administrator for help"' 
        fi
else
        echo "Users MacOS is greater than Ventura"
        if [ "$TIME_TO_CHANGE" -gt 20 ];then
                echo "The password for $user is outside the warning period of 20 days. Password expires in $TIME_TO_CHANGE days."
                exit 0
        elif [ "$TIME_TO_CHANGE" -le 20 ] && [ "$TIME_TO_CHANGE" -gt 1 ];
        then
                echo "The password for $user expires in $TIME_TO_CHANGE days!"
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password expires in '$TIME_TO_CHANGE' days!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Settings" to delay 4' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 4 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window "Users & Groups"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 3 of group 1 of scroll area 1 of group 1 of sheet 1 of window "Users & Groups"' 2> /dev/null
        elif [ "$TIME_TO_CHANGE" = 1 ];
        then
                echo "The password for $user expires in 1 day!"	
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password expires tomorrow!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Settings" to delay 4' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 4 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window "Users & Groups"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 3 of group 1 of scroll area 1 of group 1 of sheet 1 of window "Users & Groups"' 2> /dev/null	
        elif [ "$TIME_TO_CHANGE" = 0 ];
        then
                echo "The password for $user expires today!"	
                launchctl asuser "$getUID"/usr/bin/osascript -e 'Tell current application to display dialog "Your password expires today!" with icon "Macintosh HD:System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns" as alias with title "Password Status Check" with text buttons {"Maybe Later", "Change Now"} cancel button 1 default button 2' -e 'tell application "Finder" to open POSIX file "/System/Library/PreferencePanes/Accounts.prefPane"' -e 'tell application "System Events" to tell process "System Settings" to delay 4' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 4 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window "Users & Groups"' -e 'tell application "System Events" to tell process "System Settings" to delay 2' -e 'tell application "System Events" to tell process "System Settings" to click UI Element 3 of group 1 of scroll area 1 of group 1 of sheet 1 of window "Users & Groups"' 2> /dev/null
        elif [ "$TIME_TO_CHANGE" -lt 0 ];
        then
                echo "The password for $user has expired!"	
                launchctl asuser "$getUID" /usr/bin/osascript -e 'Tell current application to display dialog "Your password has expired! Attempt to change your password or contact the Mac Administrator for help"' 
        fi
fi

#Pause while they change the password
sleep 120
#Updates Inventory in Jamf
/usr/local/jamf/bin/jamf recon 

exit 0
