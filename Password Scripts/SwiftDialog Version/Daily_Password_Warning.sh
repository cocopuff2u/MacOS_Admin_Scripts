#!/bin/sh

####################################################################################################
#
# Daily Password Notification
#
# Purpose: Displays a notification with the remaining about of days left for the password
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# Build 1.0 3/22/24 - Original
# 
# Build 1.1 4/15/24 - Added threshold days, only to notify users if less than that day
#
####################################################################################################

####################################################################################################
#
# 

#Set maximum days before the password expires, should match the MDM password day policy
MAX_PASSWORD_AGE=60
TEMP_PLIST="/tmp/pwdpolicy.plist"
NOTIFY_THRESHOLD=30

####################################################################################################
#
#This section is the password logic section
#
####################################################################################################

for user in $(ls -l /dev/console | awk '{print $3}'); do
    
    dscl . read /Users/"$user" accountPolicyData | sed '1d' > $TEMP_PLIST
    
    LAST_SET=$(defaults read $TEMP_PLIST passwordLastSetTime | cut -d"." -f 1)
    CURRENT_UNIX_TIME=$(date +"%s")
    
    PASSWORD_LAST_SET_DAYS=$(( LAST_SET / 86400 ))
    CURRENT_TIME_DAYS=$(( CURRENT_UNIX_TIME / 86400 ))
    
    PASSWORD_SET_DAYS=$(( CURRENT_TIME_DAYS - PASSWORD_LAST_SET_DAYS ))
    
    TIME_TO_CHANGE=$(( MAX_PASSWORD_AGE - PASSWORD_SET_DAYS ))

    if [ $TIME_TO_CHANGE -lt $NOTIFY_THRESHOLD ]; then
        echo "$user password was set $PASSWORD_SET_DAYS days ago"
        echo "$user password will expire in $TIME_TO_CHANGE days"

        sleep 0.2

        # Path to our dialog binary
        dialogPath='/usr/local/bin/dialog'
        #"Window Title"
        title="Password Checker"
        #"Window Message"
        description="Local password expires in $TIME_TO_CHANGE days"
        description2="Please change before the expired date"

        $dialogPath \
            --title "$title" \
            --subtitle "$description" \
            --message "$description2"\
            --notification
    else
        echo "$user password was set $PASSWORD_SET_DAYS days ago"
        echo "Not notifying user, Threshold days set to $NOTIFY_THRESHOLD"
    fi

    rm $TEMP_PLIST
    
done

exit 0
