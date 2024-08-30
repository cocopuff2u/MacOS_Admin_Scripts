#!/bin/sh
# Copyright (c) 2010-2021 by Pulse Secure, LLC. All rights reserved

# uninstall.sh 0 -> do not save configuration

PulseDir="/Library/Application Support/Pulse Secure/Pulse"
BrandingDir="/Library/Application Support/Pulse Secure/PulseBranding"
UninstallDir="/Library/Application Support/Pulse Secure/Pulse/Uninstall.app/Contents/Resources"
FirewallKext="/Applications/Ivanti Secure Access.app/Contents/Plugins/Kext/PulseSecureFirewall.kext"

SaveConfig=0	#default to save configuration
if [ "$#" -gt 0 ]; then
    SaveConfig=$1   # 1st argument
fi

UnloadUninstallPulseDaemon=0
if [ "$#" -gt 1 ]; then
    UnloadUninstallPulseDaemon=$2   # 2nd argument
fi

#Uninstallater gets automaticaly invoked in root context on PulseSecure.app deletion or 
#end-users can directly click on Uninstallater application to uninstall PulseSecure.app. So, we need to handly both.
if [ "$SaveConfig" -ne 1 ]; then
    echo "Don't save configuration so proceed for ZTA unenrollment"  >> "$PulseDir/uninstall.log"
    ConsoleUsername=`stat -f "%Su" /dev/console`
    PULSEUI_PID=`ps -xalwwww|grep \[A\]pplications\/Ivanti\ Secure\ Access.app\/Contents\/MacOS\/Ivanti\ Secure\ Access |awk '{print $2}'`
    if [ ! "$PULSEUI_PID" = "" ]; then
        echo "UNENROLL_ZTA: Send SIGUSR1 signal to $PULSEUI_PID" >> "$PulseDir/uninstall.log"
        su -l $ConsoleUsername -c "kill -30 $PULSEUI_PID"
        retVal=$?
        sleep 5
        if [ $retVal -ne 0 ]; then
            echo "Failed to notify PulseUI for unenrollment"  >> "$PulseDir/uninstall.log"
            kill -30 $PULSEUI_PID
            retVal = $?
            sleep 5
            if [ $retVal != "0" ]; then
                echo "Failed to notified PulseUI for unenrollment in 3rd attempt "  >> "$PulseDir/uninstall.log"
            else
                echo "Successfully notified PulseUI for unenrollment"  >> "$PulseDir/uninstall.log"
            fi
        else 
            echo "Successfully notified PulseUI for unenrollment"  >> "$PulseDir/uninstall.log"
        fi
    else
        echo "ERROR - PulseUI not running. Unable to notify PulseUI for unenrollment" >> "$PulseDir/uninstall.log"
    fi
else
    echo "Save configuration so don't unenroll ZTA" >> "$PulseDir/uninstall.log"
fi

echo "Checking if Pulse SysExt is loaded" >> "$PulseDir/uninstall.log"
systemextensionsctl list | grep -i net.pulsesecure. | grep enabled
if [ "$?" == "0" ]; then
    echo "Pulse System Extension is loaded. Asking to unload it" >> "$PulseDir/uninstall.log"
    /usr/bin/osascript -e 'if application "/Applications/Ivanti Secure Access.app" is not running then' -e 'tell application "/Applications/Ivanti Secure Access.app" to activate' -e 'end if' -e 'if application "/Applications/Ivanti Secure Access.app" is running then' -e 'tell application "/Applications/Ivanti Secure Access.app"' -e 'do PulseMainUI command "UNINSTALL_SYSEXT"' -e 'end tell' -e 'end if'
    echo "Pulse System Extension is loaded. Application open" >> "$PulseDir/uninstall.log"
    tries=0
    systemextensionsctl list | grep -i net.pulsesecure. | grep enabled
    while [ "$?" == "0" ]
    do
        if [[ $tries -lt 30 ]]; then
            echo "Pulse System Extension is still loaded" >> "$PulseDir/uninstall.log"
            ((tries++))
            sleep 3
            systemextensionsctl list | grep -i net.pulsesecure. | grep enabled
        else
            break
        fi
    done
else
    echo "Pulse System Extension is not loaded" >> "$PulseDir/uninstall.log"
fi

# Check if PulseUI is running and, in such case, ask it to close itself gracefully
ps -xalwwww|grep "/[A]pplications/Ivanti Secure Access.app/Contents/MacOS/Ivanti Secure Access"
if [ "$?" == "0" ]; then
    echo "PulseUI running, stopping it" >> "$PulseDir/uninstall.log"
    /usr/bin/osascript << EOF
        tell application "Ivanti Secure Access"
                do PulseMainUI command "QUITPULSEUI"
        end tell
EOF
    sleep 2    # wait for 2 seconds to quit Pulse UI gracefully
else
    echo "PulseUI not running, go on" >> "$PulseDir/uninstall.log"
fi

PULSEUI_PID=`ps -xalwwww|grep \[A\]pplications\/Ivanti\ Secure\ Access.app\/Contents\/MacOS\/Ivanti\ Secure\ Access |awk '{print $2}'`
if [ ! "$PULSEUI_PID" = "" ]; then
    echo "Quit PulseUI: $PULSEUI_PID" >> "$PulseDir/uninstall.log"
    kill -9 $PULSEUI_PID
fi

echo "Checking for PulseUI " >> "$PulseDir/uninstall.log"
# unload UI for all other logged in Users
if [ -f /Library/LaunchAgents/net.pulsesecure.pulseagent.plist ]; then
        for userName in `/usr/bin/users`
        do 
               	echo "Unload PulseUI for $userName" >> "$PulseDir/uninstall.log"
                su -l $userName -c  "launchctl unload -S Aqua /Library/LaunchAgents/net.pulsesecure.pulseagent.plist"
        done
fi

PULSEUI_PID=`ps -xalwwww|grep \[A\]pplications\/Ivanti\ Secure\ Access.app\/Contents\/MacOS\/Ivanti\ Secure\ Access |awk '{print $2}'`
if [ ! "$PULSEUI_PID" = "" ]; then
    echo "Quit PulseUI: $PULSEUI_PID" >> "$PulseDir/uninstall.log"
    kill -9 $PULSEUI_PID
fi

if [ -f /Library/LaunchAgents/com.pulsesecure.pulseagent.plist ]; then
sudo rm -rf /Library/LaunchAgents/com.pulsesecure.pulseagent.plist
fi

if [ -f /Library/LaunchAgents/net.pulsesecure.pulseagent.plist ]; then
sudo rm -rf /Library/LaunchAgents/net.pulsesecure.pulseagent.plist
fi
echo "Checking for PulseUI done" >> "$PulseDir/uninstall.log"

echo "Checking for Cert Service " >> "$PulseDir/uninstall.log"
# unload UI for all other logged in Users
if [ -f /Library/LaunchAgents/net.pulsesecure.CertService.plist ]; then
    for userName in `/usr/bin/users`
    do
        echo "Unload CertService for $userName" >> "$PulseDir/uninstall.log"
        su -l $userName -c  "launchctl unload -S Aqua /Library/LaunchAgents/net.pulsesecure.CertService.plist"
    done
    sudo rm -rf /Library/LaunchAgents/net.pulsesecure.CertService.plist
fi

echo "Checking for Cert Service done" >> "$PulseDir/uninstall.log"

echo "Unload /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased.plist" >> "$PulseDir/uninstall.log"
if [ -f /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased.plist ]; then
    sudo launchctl unload /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased.plist
    sudo rm -rf /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased.plist
fi

echo "Unload /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased_x86_64.plist" >> "$PulseDir/uninstall.log"
if [ -f /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased_x86_64.plist ]; then
    sudo launchctl unload /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased_x86_64.plist
    sudo rm -rf /Library/LaunchDaemons/net.pulsesecure.PulseOpswatServiceAgentbased_x86_64.plist
fi

echo "Unload /Library/LaunchDaemons/net.pulsesecure.AccessService.plist" >> "$PulseDir/uninstall.log"
if [ -f /Library/LaunchDaemons/net.pulsesecure.AccessService.plist ]; then
    sudo launchctl unload /Library/LaunchDaemons/net.pulsesecure.AccessService.plist
    sudo rm -rf /Library/LaunchDaemons/net.pulsesecure.AccessService.plist
fi

sudo rm /Library/Application\ Support/Pulse\ Secure/Pulse/firewallRules*.dat
sudo rm /Library/Application\ Support/Pulse\ Secure/Pulse/firewallConfig*.dat

echo "Unloading $FirewallKext" >> "$PulseDir/uninstall.log"
sudo kextunload -b "net.pulsesecure.PulseSecureFirewall"
status=$?
 
if [ $status -eq 0 ]
then
    echo "Unload $FirewallKext successful" >> "$PulseDir/uninstall.log"
else 
    echo "Unload $FirewallKext failed" >> "$PulseDir/uninstall.log"
fi

echo "Deleting route host keys file"  >> "$PulseDir/uninstall.log"
sudo rm -rf "$PulseDir/hostRoutes.dat"
 
RscDir="$( cd "$( dirname "$0" )" && pwd )"

echo "Remove semaphore /var/log/Pulse Secure/Logging" >> "$PulseDir/uninstall.log"
sudo "$RscDir"/sem_delete.pl "/var/log/Pulse Secure/Logging/"

echo "Remove $PulseDir/Uninstall.app" >> "$PulseDir/uninstall.log"
sudo rm -rf "$PulseDir"/Uninstall.app
echo "Remove $PulseDir/StartupLauncher.app" >> "$PulseDir/uninstall.log"
sudo rm -rf "$PulseDir"/StartupLauncher.app
echo "Remove $BrandingDir" >> "$PulseDir/uninstall.log"
sudo rm -rf "$BrandingDir"

if [ "$SaveConfig" -ne 1 ]; then
    echo "Remove Pulse configuration" >> "$PulseDir/uninstall.log"
    sudo rm -f "$PulseDir"/*.dat
    sudo rm -f "$PulseDir"/*.bak
    sudo rm -f "$PulseDir"/*.tmp
    sudo rm -f "$PulseDir"/DeviceId
fi

if [[ -L "/Applications/Pulse Secure.app" ]]; then
    echo "Pulse Secure.app is a link. Deleting it"
    rm "/Applications/Pulse Secure.app"
fi

echo "Forget packages..." >> "$PulseDir/uninstall.log"
sudo pkgutil --forget net.pulsesecure.PulsePreflight.pkg
sudo pkgutil --forget net.pulsesecure.JUNS.pkg
sudo pkgutil --forget net.pulsesecure.JamUI.pkg
sudo pkgutil --forget net.pulsesecure.ConnectionStore.pkg
sudo pkgutil --forget net.pulsesecure.ConnectionManager.pkg
sudo pkgutil --forget net.pulsesecure.eapService.pkg
sudo pkgutil --forget net.pulsesecure.dsTMService.pkg
sudo pkgutil --forget net.pulsesecure.iveConnectionMethod.pkg
sudo pkgutil --forget net.pulsesecure.TnccPlugin.pkg
sudo pkgutil --forget net.pulsesecure.TMPostflight.pkg
sudo pkgutil --forget net.pulsesecure.TnccPostflight.pkg
sudo pkgutil --forget net.pulsesecure.vpnAccessMethod.pkg
sudo pkgutil --forget net.pulsesecure.PulsePostflight.pkg
sudo pkgutil --forget net.pulsesecure.CorePostflight.pkg
sudo pkgutil --forget net.pulsesecure.UACNCPostflight.pkg
sudo pkgutil --forget net.pulsesecure.PulseSecureFirewall.pkg
# forget more packages

if [ -d "/Applications/Ivanti Secure Access.app" ]; then
  echo "Remove /Applications/Ivanti Secure Access.app" >> "$PulseDir/uninstall.log"
  sudo rm -rf "/Applications/Ivanti Secure Access.app"
fi

if [ -d "/Applications/Junos Pulse.app" ]; then
  echo "Remove /Applications/Junos Pulse.app" >> "$PulseDir/uninstall.log"
  sudo rm -rf "/Applications/Junos Pulse.app"
fi

#Obtain console username
ConsoleUsername=`stat -f "%Su" /dev/console`
if [ -d "/Users/$ConsoleUsername/.Trash/Ivanti Secure Access.app" ]; then
   echo "Remove /Users/$ConsoleUsername/.Trash/Ivanti Secure Access.app" >> "$PulseDir/uninstall.log"
   sudo rm -rf "/Users/$ConsoleUsername/.Trash/Ivanti Secure Access.app";
   echo "Remove /Users/$ConsoleUsername/.Trash/PulseSecureFirewall.kext" >> "$PulseDir/uninstall.log"
   sudo rm -rf "/Users/$ConsoleUsername/.Trash/PulseSecureFirewall.kext";
fi

echo "Remove /Library/LaunchDaemons/net.pulsesecure.UninstallPulse.plist" >> "$PulseDir/uninstall.log"
sudo unlink /Library/LaunchDaemons/net.pulsesecure.UninstallPulse.plist

if [ "$UnloadUninstallPulseDaemon" -eq 1 ]; then
    echo "Unload net.pulsesecure.UninstallPulse" >> "$PulseDir/uninstall.log"
    sudo launchctl remove net.pulsesecure.UninstallPulse
fi

exit 0
