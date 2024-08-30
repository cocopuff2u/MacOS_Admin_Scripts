#!/usr/bin/env bash

####################################################################################################
#
# Password test window via AppleScript
#
# Purpose: Displays a test window for an end-user to test the local account password via AppleScript 
#
#
#  https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 8/21/23 - Original Release - @cocopuff2u
#
# NOTES: NO LONGER UPDATING BUT SHOULD STILL WORK
#
####################################################################################################


user=$(ls -l /dev/console | awk '{ print $3 }')
pass=$(osascript -e 'display dialog "Please Enter Your Password to Verify You Know It:" default answer "" with title "Password Tester" giving up after 60 with text buttons {"Authenticate"} default button 1 with hidden answer' -e 'return text returned of result')
attempts=1
until dscl . authonly "$user" "$pass" &>/dev/null ; do
	# lines 9 and 10 are only necessary if you wish to display no. of attempts remaining before failure
	attemptsRemaining=$(( 4 - attempts ))
	[[ $attemptsRemaining -eq 1 ]] && s= || s=s
	pass=$(osascript -e 'display dialog "Incorrect password entered, please try again. ('"$attemptsRemaining"' attempt'"$s"' remaining)" default answer "" with title "Password Tester" giving up after 60 with text buttons {"Authenticate"} default button 1 with hidden answer' -e 'return text returned of result')
	let attempts++
	(( attempts > 3 )) && exit 0
done
(osascript -e 'display dialog "Password Entered Correctly, CONGRATS \n \nPasswords Must Be Changed Every 60 Days To Avoid A Complete System Lockout" with title "Password Tester" giving up after 60 with text buttons {"Close"} default button 1 with hidden answer' &>/dev/null)  

exit 0
