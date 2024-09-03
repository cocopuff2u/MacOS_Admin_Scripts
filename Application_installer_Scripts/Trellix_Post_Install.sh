#!/bin/bash

####################################################################################################
#
# Post Install Script Trellix
#
# Purpose: Script to install/upgrade the latest McAfee version with install.sh located in /private/tmp/
#
# https://github.com/cocopuff2u
#
# Extra: Use with Jamf Composer to install the install.sh into /private/tmp/
#
####################################################################################################
#
# HISTORY
#
# 1.0 - Original (https://github.com/franton/McAfee-Agent/blob/master/postinstall.sh)
# 2.0 - Added more error detecting, Updated log folder name, corrected a bad interpreter issue
#
#
####################################################################################################

# Set up log file, folder, and function
LOGFOLDER="/var/log/Mcafee_Install_Logs"
LOG="$LOGFOLDER/McAfee-Install.log"

# Function to log messages
logme() {
    if [ -z "$1" ]; then
        echo "$(date) - logme function call error: no text passed to function! Please recheck code!" >> "$LOG"
        exit 1
    fi
    echo "" >> "$LOG"
    echo "$(date) - $1" >> "$LOG"
    echo "" >> "$LOG"
}

# Function to log errors with line numbers
log_error() {
    local lineno=$1
    local errmsg=$2
    echo "$(date) - Error on line $lineno: $errmsg" >> "$LOG"
}

# Trap errors and call log_error function
trap 'log_error $LINENO "$BASH_COMMAND"' ERR

# Ensure log folder exists
if [ ! -d "$LOGFOLDER" ]; then
    mkdir "$LOGFOLDER"
fi

echo "$(date) - Starting installation of Trellix Agent" > "$LOG"

# Check for existing McAfee agent. Upgrade if present. Full install if not.
if [ -d "/Library/McAfee/cma/" ]; then
    logme "Existing installation detected. Upgrading."
    if [ ! -f "/private/tmp/install.sh" ]; then
        logme "Error: /private/tmp/install.sh not found!"
        exit 1
    fi
    /bin/bash /private/tmp/install.sh -u 2>&1 | tee -a "$LOG"
else
    logme "Installing new Trellix Agent"
    if [ ! -f "/private/tmp/install.sh" ]; then
        logme "Error: /private/tmp/install.sh not found!"
        exit 1
    fi
     /bin/bash /private/tmp/install.sh -i 2>&1 | tee -a "$LOG"
fi

# Now make the agent check for policies and other tasks
logme "Checking for new policies"
/Library/McAfee/agent/bin/cmdagent -c 2>&1 | tee -a "$LOG"

logme "Collecting and sending computer properties to ePO server"
/Library/McAfee/agent/bin/cmdagent -p 2>&1 | tee -a "$LOG"

logme "Forwarding events to ePO server"
/Library/McAfee/agent/bin/cmdagent -f 2>&1 | tee -a "$LOG"

logme "Enforcing ePO server policies"
/Library/McAfee/agent/bin/cmdagent -e 2>&1 | tee -a "$LOG"

# All done!
logme "Installation script completed"
