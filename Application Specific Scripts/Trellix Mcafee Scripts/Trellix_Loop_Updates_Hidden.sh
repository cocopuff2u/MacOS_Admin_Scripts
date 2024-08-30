#!/bin/zsh
#set -x 
####################################################################################################
#
# # Trellix Loop Update Selection
#
# Purpose: Runs the Trellix updates in a loop with no user prompt
# 
# https://github.com/cocopuff2u
#
# To Run: Sudo zsh /PATH/TO/SCRIPT.SH
#
####################################################################################################
#
#   History
#
#  1.0 03/22/24 - Original
#
####################################################################################################

# Define the number of loops you would like the commands to run
iterations=1

# Define the log file location
scriptLog="${4:-"/var/log/org.trellixloopupdatehidden.log"}" 


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Logging
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Check if the log file exists, if not, create it
if [ ! -f "$scriptLog" ]; then
    touch "$scriptLog"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Pre-flight Check: Client-side Script Logging Function
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Function to log messages
function updateScriptLog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$scriptLog"
}

updateScriptLog "Trellix Loop Updates: Starting...."

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Flight: Loop the Trellix Updates hidden from user
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #


# Generate itemsToProgress array based on the number of iterations
itemsToProgress=()
for ((i = 1; i <= iterations; i++)); do
    itemsToProgress+=("$i")
done

# Iterate through the array
for item in "${itemsToProgress[@]}"; do
    updateScriptLog "Trellix Begin Loop Run Number: $item"
    /Library/McAfee/agent/bin/cmdagent -c | tee -a "$scriptLog"
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -e | tee -a "$scriptLog"
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -p | tee -a "$scriptLog"
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -f | tee -a "$scriptLog"
    sleep 5
done

updateScriptLog "Completed the set number loop iterations"
updateScriptLog "Trellix Loop Updates: Loop Completed"

exit 0
