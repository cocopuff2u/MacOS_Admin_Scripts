#!/bin/bash

#CMK WRITTEN 12/03/2021

consoleuser=$(ls -l /dev/console | awk '{ print $3 }')

echo "logged in user is" $consoleuser

echo "Kill Microsoft Office Process..."
pkill -f Microsoft

folders=(
"/Applications/Microsoft Excel.app"
"/Applications/Microsoft OneNote.app"
"/Applications/Microsoft Outlook.app"
"/Applications/Microsoft PowerPoint.app"
"/Applications/Microsoft Word.app"
"/Applications/Microsoft Teams.app"
"/Applications/OneDrive.app"
"/Library/Application Support/Microsoft"
#
"/Users/$consoleuser/Library/Application\ Support/Microsoft AU Daemon"
"/Users/$consoleuser/Library/Application\ Support/Microsoft AutoUpdate"
"/Users/$consoleuser/Library/Application\ Support/com.microsoft.OneDriveStandaloneUpdater/"
"/Users/$consoleuser/Library/Application\ Support/Microsoft\ Update\ Assistant/"
"/Users/$consoleuser/Library/Preferences/com.microsoft.autoupdate.fba.debuglogging.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.autoupdate.fba.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.autoupdate2.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.office.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.OneDriveUpdater.plist"
"/Users/$consoleuser/Library/Preferences/com.microsoft.shared.plist"
"/Users/$consoleuser/Library/Containers/com.microsoft.errorreporting"
"/Users/$consoleuser/Library/Containers/com.microsoft.Excel"
"/Users/$consoleuser/Library/Containers/com.microsoft.netlib.shipassertprocess"
"/Users/$consoleuser/Library/Containers/com.microsoft.Office365ServiceV2"
"/Users/$consoleuser/Library/Containers/com.microsoft.Outlook"
"/Users/$consoleuser/Library/Containers/com.microsoft.Powerpoint"
"/Users/$consoleuser/Library/Containers/com.microsoft.RMS-XPCService"
"/Users/$consoleuser/Library/Containers/com.microsoft.Word"
"/Users/$consoleuser/Library/Containers/com.microsoft.onenote.mac"
#
#
#### WARNING: Outlook data will be removed when you move the three folders listed below.
#### You should back up these folders before you delete them.
"/Users/$consoleuser/Library/Group Containers/UBF8T346G9.ms"
"/Users/$consoleuser/Library/Group Containers/UBF8T346G9.Office"
"/Users/$consoleuser/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost"
"/Users/$consoleuser/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration"
)

search="*"

for i in "${folders[@]}"
do
echo "removing folder ${i}"
rm -rf "${i}"
done
