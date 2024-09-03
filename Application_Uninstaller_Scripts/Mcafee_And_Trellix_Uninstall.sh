#!/bin/bash

####################################################################################################
#
# Uninstalls Mcafee and Trelllix
#
# Purpose: Uninstall Mcafee and Trellix
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 8/29/23 - I took the two following scripts below and combined them to clean both Mcafee & Trellix - @cocopuff2u
# (https://gist.github.com/sdagley/566dddd0b497dfe05fb487abaa274024#file-ripoff-mcafee-v2-3-sh)
# (https://github.com/rtrouton/rtrouton_scripts/blob/main/rtrouton_scripts/uninstallers/trellix_uninstall/Trellix_Uninstall.sh)
#
#
#
####################################################################################################


# Temp plist files used for import and export from authorization database.
management_db_original_setting="$(mktemp).plist"
management_db_edited_setting="$(mktemp).plist"
management_db_check_setting="$(mktemp).plist"

# Expected settings from management database for com.apple.system-extensions.admin
original_setting="authenticate-admin-nonshared"
updated_setting="allow"

ManagementDatabaseUpdatePreparation() {
# Create temp plist files
touch "$management_db_original_setting"
touch "$management_db_edited_setting"
touch "$management_db_check_setting"

# Create backup of the original com.apple.system-extensions.admin settings from the management database
/usr/bin/security authorizationdb read com.apple.system-extensions.admin > "$management_db_original_setting"

# Create copy of the original com.apple.system-extensions.admin settings from the management database for editing.
/usr/bin/security authorizationdb read com.apple.system-extensions.admin > "$management_db_edited_setting"
}

UpdateManagementDatabase() {
if [[ -r "$management_db_edited_setting" ]] && [[ $(/usr/libexec/PlistBuddy -c "Print rule:0" "$management_db_edited_setting") = "$original_setting" ]]; then
   /usr/libexec/PlistBuddy -c "Set rule:0 $updated_setting" "$management_db_edited_setting"
   if [[ $(/usr/libexec/PlistBuddy -c "Print rule:0" "$management_db_edited_setting" ) = "$updated_setting" ]]; then
      echo "Edited $management_db_edited_setting is set to allow system extensions to be uninstalled without password prompt."
      echo "Now importing setting into authorization database."
      /usr/bin/security authorizationdb write com.apple.system-extensions.admin < "$management_db_edited_setting"
      if [[ $? -eq 0 ]]; then
         echo "Updated setting successfully imported."
         UpdatedAuthorizationSettingInstalled="true"
      fi
    else
      echo "Failed to update $management_db_edited_setting file with the correct setting to allow system extension uninstallation without prompting for admin credentials."
    fi
fi
}

RestoreManagementDatabase() {
/usr/bin/security authorizationdb read com.apple.system-extensions.admin > "$management_db_check_setting"
if [[ ! $(/usr/libexec/PlistBuddy -c "Print rule:0" "$management_db_check_setting") = "$original_setting" ]]; then
   if [[ -r "$management_db_original_setting" ]] && [[ $(/usr/libexec/PlistBuddy -c "Print rule:0" "$management_db_original_setting") = "$original_setting" ]]; then
      echo "Restoring original settings to allow system extension uninstallation only after prompting for admin credentials."
      echo "Now importing setting into authorization database."
      /usr/bin/security authorizationdb write com.apple.system-extensions.admin < "$management_db_original_setting"
            if [[ $? -eq 0 ]]; then
         echo "Original setting successfully imported."
         OriginalAuthorizationSettingInstalled=1
      fi

    else
      echo "Failed to update the authorization database with the correct setting to allow system extension uninstallation only after prompting for admin credentials."
    fi
fi
}

# Run the vendor-provided uninstallers if available.

if [[ -x /usr/local/McAfee/uninstall ]]; then
	/usr/local/McAfee/uninstall EPM
fi

if [[ -x /Library/McAfee/agent/scripts/uninstall.sh ]]; then
	/Library/McAfee/agent/scripts/uninstall.sh
fi

if [[ -x /usr/local/McAfee/MSCUI/uninstallMSCUI.sh ]]; then
	/usr/local/McAfee/MSCUI/uninstallMSCUI.sh
fi

# Unload the LaunchAgents for the current user.

currentUser=$(/bin/ls -l /dev/console | /usr/bin/awk '{ print $3 }')
if [[ -n "$currentUser" && "$currentUser" != "root" ]]; then
	/usr/bin/sudo -u "$currentUser" /bin/launchctl unload /Library/LaunchAgents/com.mcafee.*
fi

# Unload the McAfee and Trellix LaunchDaemons
echo "unloading launch items"
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.*
/bin/launchctl bootout system /Library/LaunchAgents/com.mcafee.*
/bin/launchctl bootout system /Library/LaunchAgents/com.mcafee.McAfeeSafariHost.plist
/bin/launchctl bootout system /Library/LaunchAgents/com.mcafee.menulet.plist
/bin/launchctl bootout system /Library/LaunchAgents/com.mcafee.reporter.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.aac.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.agent.ma.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.agent.macmn.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.agent.macompat.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.dxl.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.ssm.Eupdate.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.ssm.ScanFactory.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.ssm.ScanManager.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.virusscan.fmpcd.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.virusscan.fmpd.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.agentMonitor.helper.plist
/bin/launchctl bootout system /Library/LaunchDaemons/com.mcafee.pa.agent.plist

/usr/bin/killall -c Menulet
/usr/bin/killall -c "McAfee Agent Status Monitor"
/usr/bin/killall -c McAfee\ Reporter
echo ""

# Stop all running processes if running.
echo "stopping running processes"
/usr/local/McAfee/DlpAgent/bin/DlpAgentControl.sh mastop
/usr/local/McAfee/AntiMalware/VSControl mastop
/usr/local/McAfee/StatefulFirewall/bin/StatefullFirewallControl mastop
/usr/local/McAfee/WebProtection/bin/WPControl mastop
/usr/local/McAfee/atp/bin/ATPControl mastop
/usr/local/McAfee/FRP/bin/FRPControl mastop
/usr/local/McAfee/Mar/MarControl stop
/usr/local/McAfee/mvedr/MVEDRControl stop
/usr/local/McAfee/Mcp/bin/mcpcontrol.sh mastop
/usr/local/McAfee/MNE/bin/MNEControl mastop
/usr/local/McAfee/fmp/bin/fmp stop
/opt/McAfee/dx/bin/dxlservice stop
/Library/McAfee/agent/bin/maconfig -stop
/usr/bin/killall "McAfee Reporter" "McAfee Endpoint Security for Mac" "Trellix Reporter" "Trellix Endpoint Security for Mac" "Menulet" "Trellix Agent Status Monitor"
echo ""

# Unload any running kernel extensions.
echo "unloading kexts"
/sbin/kextunload /usr/local/McAfee/AntiMalware/Extensions/*.kext
/sbin/kextunload /usr/local/McAfee/fmp/Extensions/*.kext
/sbin/kextunload "/Library/Application Support/McAfee/AntiMalware/"*.kext
/sbin/kextunload "/Library/Application Support/McAfee/FMP/"*.kext
/sbin/kextunload /Library/Application\ Support/McAfee/AntiMalware/AVKext.kext
/sbin/kextunload /Library/Application\ Support/McAfee/FMP/mfeaac.kext
/sbin/kextunload /Library/Application\ Support/McAfee/FMP/FileCore.kext
/sbin/kextunload /Library/Application\ Support/McAfee/FMP/FMPSysCore.kext
/sbin/kextunload /Library/Application\ Support/McAfee/StatefulFirewall/SFKext.kext
/sbin/kextunload /usr/local/McAfee/AntiMalware/Extensions/AVKext.kext
/sbin/kextunload /usr/local/McAfee/StatefulFirewall/Extensions/SFKext.kext
/sbin/kextunload /usr/local/McAfee/Mcp/MCPDriver.kext
/sbin/kextunload /usr/local/McAfee/DlpAgent/Extensions/DLPKext.kext
/sbin/kextunload /usr/local/McAfee/DlpAgent/Extensions/DlpUSB.kext
/sbin/kextunload /usr/local/McAfee/fmp/Extensions/FileCore.kext
/sbin/kextunload /usr/local/McAfee/fmp/Extensions/NWCore.kext
/sbin/kextunload /usr/local/McAfee/fmp/Extensions/FMPSysCore.kext
echo ""

echo "uninstalling system extensions"
if [ -e /Applications/McAfeeSystemExtensions.app ] ; then
	McAfeeNetworkExtensionLoaded=$(/usr/bin/systemextensionsctl list | /usr/bin/grep "McAfee Network Extension")

	if [[ -n "$McAfeeNetworkExtensionLoaded" ]]; then

		# Prepare to update authorization database to allow system extensions to be uninstalled without password prompt.
		ManagementDatabaseUpdatePreparation

		# Update authorization database with new settings.
		UpdateManagementDatabase

		# Uninstall the System Extension
		/usr/bin/sudo -u $userName /usr/local/McAfee/fmp/AAC/bin/deactivatesystemextension com.mcafee.CMF.networkextension

		# Once the system extensions are uninstalled, the relevant settings for the authorization database will be restored from backup to their prior state.
		if [[ -n "$UpdatedAuthorizationSettingInstalled" ]]; then
			RestoreManagementDatabase

			if [[ -n "$OriginalAuthorizationSettingInstalled" ]]; then
				echo "com.apple.system-extensions.admin settings in the authorization database successfully restored to $original_setting."
				rm -rf "$management_db_original_setting"
				rm -rf "$management_db_edited_setting"
				rm -rf "$management_db_check_setting"
			fi

		fi
	fi
fi
echo ""

# Delete any remaining files.
echo "removing files"
/bin/rm -rf /Library/LaunchAgents/com.mcafee.* \
			/Library/LaunchDaemons/com.mcafee.* \
			/Library/StartupItems/cma \
			/usr/local/McAfee \
            /opt/McAfee \
			/etc/cma.d \
			/etc/ma.d \
			/etc/cma.conf \
			/var/log/McAfeeSecurity* \
			/var/log/DLPAgent* \
			/var/log/DlpAgent* \
			/var/log/mcupdater* \
			/var/log/MFEdx* \
			/var/tmp/.msgbus/ma_* \
			/var/McAfee \
			/Library/Logs/DiagnosticReports/masvc* \
			/Library/Logs/DiagnosticReports/VShieldService* \
			"/Library/Application Support/McAfee" \
			/Library/McAfee \
			"/Library/Internet Plug-Ins/Web Control.plugin" \
			/Library/Documentation/Help/McAfeeSecurity* \
			/Library/Preferences/com.mcafee.* \
			/Library/Preferences/.com.mcafee.* \
			/Library/Frameworks/AVEngine.framework \
			/Library/Frameworks/VirusScanPreferences.framework \
			/Library/PrivilegedHelperTools/com.trellix.* \
			"/Applications/McAfee Endpoint Security for Mac.app" \
			"/Applications/McAfee Endpoint Protection for Mac.app" \
			"/Applications/McAfeeSystemExtensions.app" \
			"/Applications/Trellix Endpoint Security for Mac.app" \
			"/Applications/TrellixSystemExtensions.app"
            echo ""

# rm logs
echo "removing logs"
/bin/rm -f /Library/Logs/Native\ Encryption.log
/bin/rm -f /Library/Logs/FRP.log
/bin/rm -f /private/var/log/McAfeeSecurity.log*
/bin/rm -f /private/var/log/mcupdater*
/bin/rm -f /private/var/log/MFEdx*
echo ""

# forget receipts
echo "forgetting receipts"
/usr/sbin/pkgutil --forget com.mcafee.dxl
/usr/sbin/pkgutil --forget com.mcafee.mscui
/usr/sbin/pkgutil --forget com.mcafee.mar
/usr/sbin/pkgutil --forget com.mcafee.mvedr
/usr/sbin/pkgutil --forget com.mcafee.pkg.FRP
/usr/sbin/pkgutil --forget com.mcafee.pkg.MNE
/usr/sbin/pkgutil --forget com.mcafee.pkg.StatefulFirewall
/usr/sbin/pkgutil --forget com.mcafee.pkg.utility
/usr/sbin/pkgutil --forget com.mcafee.pkg.WebProtection
/usr/sbin/pkgutil --forget com.mcafee.ssm.atp
/usr/sbin/pkgutil --forget com.mcafee.ssm.fmp
/usr/sbin/pkgutil --forget com.mcafee.ssm.mcp
/usr/sbin/pkgutil --forget com.mcafee.ssm.dlp
/usr/sbin/pkgutil --forget com.mcafee.virusscan
/usr/sbin/pkgutil --forget comp.nai.cmamac
echo ""

# remove users/groups
echo "removing user and groups"
/usr/bin/dscl . delete /Users/mfe
/usr/bin/dscl . delete /Groups/mfe
/usr/bin/dscl . delete /Groups/Virex
echo ""

# Remove the Quarantine folder if present and empty.

if [[ -z "$(/bin/ls -A /Quarantine 2>/dev/null | /usr/bin/grep -vE '(.DS_Store|.Quarantine.lck)')" ]]; then
	/bin/rm -rf /Quarantine
fi

localUsers=$(/usr/bin/dscl . -list /Users | /usr/bin/grep -v "^_")

for userName in ${localUsers}; do

	# Get path to user's home directory
	userHome=$(/usr/bin/dscl . -read /Users/$userName NFSHomeDirectory 2>/dev/null | /usr/bin/sed 's/^[^\/]*//g')

    # Remove user-level files from the user home directories.

	if [[ -d "$userHome" && "$userHome" != "/var/empty" ]]; then
		/bin/rm -f "$userHome/Library/Preferences/com.mcafee."* \
		           "$userHome/Library/Logs/DiagnosticReports/Menulet"*
	fi
done

# remove the mfe user account created by Trellix and McAfee.

if [[ -n $(/usr/bin/id mfe 2>/dev/null) ]]; then
	/usr/sbin/sysadminctl -deleteUser mfe --keepHome
fi

# Forget the Trellix and McAfee installer package receipts

allPackages=$(/usr/sbin/pkgutil --pkgs | /usr/bin/grep -E "(mcafee|trellix|comp.nai.cmamac)")
for aPackage in ${allPackages}; do
	/usr/sbin/pkgutil --forget "$aPackage" >/dev/null 2>&1
done

exit 0
