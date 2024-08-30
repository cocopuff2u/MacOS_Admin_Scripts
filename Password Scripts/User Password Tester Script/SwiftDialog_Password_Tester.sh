#!/usr/bin/env bash

####################################################################################################
#
# Password test window via swiftDialog
#
# Purpose: Displays a test window for an end-user to test the local account password via swiftDialog. 
#
# See Link for SwiftDialog: https://github.com/swiftDialog/swiftDialog
#
#  https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 8/21/23 - Original Release - @cocopuff2u
#
#
# 1.2 9/13/23 - Converted from AppleScript over to SwiftDialog, added logic for current password, added ability to "Not Now" Prompt and added a FailedLoginCount to reset back to zero on failed attempts - @cocopuff2u
#
#
#
####################################################################################################


###Adjustable Varibles per Company###

#Determines how often the password should me changed and inform the user of days remaining before it expires
MAX_PASSWORD_AGE=60 

#Title Name of the Application
COMPANY_NAME="COCO COMPANY"

#Uses the Logo Present for the Self Service Application
SELF_SERVICE_APP_LOGO="/Applications/Self Service.app"


####################################################################################################
###Tmp File for checking the local Password dates
###
TEMP_PLIST="/tmp/pwdpolicy.plist"
for user1 in $(/bin/ls -la /dev/console | /usr/bin/cut -d ' ' -f 4); do  
    dscl . read /Users/"$user1" accountPolicyData | sed '1d' > $TEMP_PLIST 
    LAST_SET=$(defaults read $TEMP_PLIST passwordLastSetTime | cut -d"." -f 1)
    CURRENT_UNIX_TIME=$(date +"%s")  
    PASSWORD_LAST_SET_DAYS=$(( LAST_SET / 86400 ))
    CURRENT_TIME_DAYS=$(( CURRENT_UNIX_TIME / 86400 ))   
    PASSWORD_SET_DAYS=$(( CURRENT_TIME_DAYS - PASSWORD_LAST_SET_DAYS ))
    TIME_TO_CHANGE=$(( MAX_PASSWORD_AGE - PASSWORD_SET_DAYS ))
    rm $TEMP_PLIST
done
###
####################################################################################################

####################################################################################################
###Main Script
###

user=$(ls -l /dev/console | awk '{ print $3 }')
passlogic=$(dialog -t "$COMPANY_NAME Password Tester" --icon "$SELF_SERVICE_APP_LOGO" -p --alignment center --message "Please type in your local system password in the provided field to verify you know it." --infobox "### *Additional Info*:\n\n _Current local system password will expire in $TIME_TO_CHANGE days_" --textfield "Authenticate with Local Password",secure --button1text "Enter Local Password to Continue" --button2text "Not Now")

#Process if User Presses "Not Now"
if [ $? -eq 2 ]; then
echo "User Exited Script"
exit 0

else
pass=$(echo "$passlogic" | awk -F ' : ' '{print $2}')
fi

#Resets FailedLoginCount back to zero
dscl . createpl /Users/"$user" accountPolicyData failedLoginCount 0

attempts=1
until dscl . authonly "$user" "$pass" &>/dev/null ; do
	# lines 9 and 10 are only necessary if you wish to display no. of attempts remaining before failure
	attemptsRemaining=$(( 4 - attempts ))
	[[ $attemptsRemaining -eq 1 ]] && s= || s=s
passlogic=$(dialog -t "$COMPANY_NAME Password Tester" --icon "$SELF_SERVICE_APP_LOGO" -p --alignment center --message "Sorry, you've entered an incorrect password, please try again.<br><br>_("$attemptsRemaining" attempt"$s" remaining*)_" --infobox "### *Please Note*:\n\n_*Reattempts do not count towards your lockout limit_" --textfield "Authenticate with Local Password",secure --button1text "Enter Local Password to Continue" --button2text "Not Now")

#Process if User Presses "Not Now"
if [ $? -eq 2 ]; then
echo "User Exited Script"

exit 0
break 
else
pass=$(echo "$passlogic" | awk -F ' : ' '{print $2}')
#Resets FailedLoginCount back to zero
	dscl . createpl /Users/"$user" accountPolicyData failedLoginCount 0

	let attempts++
#logic For Failing to Enter the Password Correctly 4 Times
	(( attempts > 3 )) && (dialog -t "$COMPANY_NAME Password Tester" --icon "$SELF_SERVICE_APP_LOGO" -p --alignment center --message "### **Apologizes** <br> <br> You've exceeded the maximum allowed incorrect password attempts. <br> <br> Try again later"  --infobox "### *Additional Info*\n\n _If you need a reset please contact our Mac Admin for assistance_"  --button1text "Close") && exit 0
    fi
done
(dialog -t "$COMPANY_NAME Password Tester" --icon "$SELF_SERVICE_APP_LOGO" -p --alignment center --message "### **Congratulations** <br> <br> You've entered the correct password. <br>Thank you" --infobox "### *Please Note*:\n\n _For security purposes, Passwords must be reset every $MAX_PASSWORD_AGE days_" --button1text "Close" &>/dev/null )  

exit 0

###
####################################################################################################

