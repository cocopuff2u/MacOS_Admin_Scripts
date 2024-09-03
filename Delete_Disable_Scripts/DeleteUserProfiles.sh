#!/bin/bash

# This script removes local accounts that are older than 45 days.
# The 45 day time frame can be modified (-mtime +45).  


DATE=`date "+%Y-%m-%d %H:%M:%S"`

# Don't delete local accounts
keep1="/Users/"ADMINACCOUNT""
keep2="/Users/Shared"
currentuser=`ls -l /dev/console | cut -d " " -f 4`
keep3=/Users/$currentuser
keep4="/Users/Guest"

USERLIST=`/usr/bin/find /Users -type d -maxdepth 1 -mindepth 1 -mtime +45d`

for a in $USERLIST ; do
    [[ "$a" == "$keep1" ]] && continue  #skip acts
    [[ "$a" == "$keep2" ]] && continue  #skip shared
    [[ "$a" == "$keep3" ]] && continue  #skip current user
	[[ "$a" == "$keep4" ]] && continue  #skip Guest
# Log results
echo ${DATE} - "Deleting account and home directory for" $a >> "/Users/acts/Desktop/deleted user account.log"

# Delete the account
sudo /usr/bin/dscl . -delete $a  

# Delete the home directory
sudo /bin/rm -rf $a

done 
exit 0
