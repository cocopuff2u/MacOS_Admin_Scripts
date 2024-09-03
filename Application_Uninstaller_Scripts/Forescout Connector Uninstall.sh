#!/bin/sh
####################################################################################################
#
# Uninstalls ForeScout Connector
#
# Purpose: Uinstalls ForeScout Connector
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 3/15/23 - Original Release - @cocopuff2u
#
#
#
####################################################################################################

echo "Start Uninstall script"

App_Name="ForeScout SecureConnector"
Config_Name="com.forescout.secureconnector.plist"

PID=
App_Dst="$base/Applications/${App_Name}.app"
app_type="daemon"
while [ "$#" != "0" ]; do
    case $1 in
        -pid )
            shift
            PID=$1
            ;;
        -t )
            shift
            app_type=$1
            ;;
        -path )
            shift
            App_Dst=$1
            ;;
    esac
    shift
done

base=$HOME
if [ "${app_type}" == "permanent" ]; then
	launchctl stop "secureconnector.job" > /dev/null 2>&1
	launchctl unload "$base/Library/LaunchAgents/${Config_Name}" > /dev/null 2>&1
	rm -f "$base/Library/LaunchAgents/${Config_Name}" > /dev/null 2>&1
elif [ "${app_type}" == "daemon" ]; then
	base=""
	for pid in `ps auxww  | grep -v grep | egrep "ForeScout SecureConnector.*-agent" | awk '{print $2}'`
  	do
		launchctl bsexec $pid launchctl unload "$base/Library/LaunchAgents/com.forescout.secureconnector.agent.plist" > /dev/null 2>&1
	done

	launchctl unload "$base/Library/LaunchDaemons/com.forescout.secureconnector.daemon.plist" > /dev/null 2>&1
	rm -f "$base/Library/LaunchAgents/com.forescout.secureconnector.agent.plist"  > /dev/null 2>&1
	rm -f "$base/Library/LaunchDaemons/com.forescout.secureconnector.daemon.plist"  > /dev/null 2>&1
fi

if [ "${PID}" != "" ]; then
    kill -9 ${PID} > /dev/null 2>&1
else
    killall "${App_Name}" > /dev/null 2>&1
fi

Config_Dst="$base/Library/Preferences/${Config_Name}"
Certificate_Dst="$base/Library/Application Support/ForeScout/"

rm -rf "${App_Dst}"  > /dev/null 2>&1
defaults delete "${Config_Dst}"  > /dev/null 2>&1
rm -f "${Config_Dst}" > /dev/null 2>&1
rm -frd "${Certificate_Dst}" > /dev/null 2>&1

Exit 0
