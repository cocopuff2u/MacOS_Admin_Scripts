#!/bin/sh

####################################################################################################
#
# Installs ForeScout Connector
#
# Purpose: Installs ForeScout Connector
#
# Note: Pulls the verison from your local instance, Update the URL in the Script
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
# 1.1 3/16/23 - added || exit 1 if curl fails - @cocopuff2u
#
#
#
####################################################################################################

#Make sure to update the url path for your instance
curl -o /tmp/update.tgz https://X.X.X.X/SC_packages/update.tgz|| exit 1; sleep 3

#Extracting update.tgz to /tmp
tar -zxvf /tmp/update.tgz -C /tmp; sleep 3

#Installing SecureConnector as a Daemon/Dissolvable w/ visible/invisible menu bar icon
sudo -S /tmp/Update/Update.sh -t daemon -v 1; sleep 3

#Checking/Starting processes in case they did not start on install
daemon_pid=ps auxww | grep -v grep | egrep "ForeScout SecureConnector.-daemon" | awk '{print $2}'
agent_pid=ps auxww | grep -v grep | egrep "ForeScout SecureConnector.-agent" | awk '{print $2}'
daemon_plist=/Library/LaunchDaemons/com.forescout.secureconnector.daemon.plist
agent_plist=/Library/LaunchAgents/com.forescout.secureconnector.agent.plist

if [[ -z "$daemon_pid" && -z "$agent_pid" ]]; then 
#Starting Daemon process 
launchctl unload $daemon_plist 
launchctl load $daemon_plist
#Starting GUI process 
launchctl unload $agent_plist 
launchctl load $agent_plist

elif [[ ! -z "$daemon_pid" && -z "$agent_pid" ]]; then 
#Starting GUI process 
launchctl unload $agent_plist 
launchctl load $agent_plist
fi

#Clean-up a little
sudo rm -rf /tmp/update.tgz /tmp/Update/

exit 0
