#!/bin/zsh
#set -x 
####################################################################################################
#
# # Trellix Loop Update Selection
#
# Purpose: Runs the Trellix updates in a loop with cli user input
# 
# https://github.com/cocopuff2u
#
# To Run: Sudo zsh /PATH/TO/SCRIPT.SH
#
####################################################################################################
#
#   History
#
#  1.0 04/10/24 - Original
#
####################################################################################################

# Define the log file location
scriptLog="${4:-"/var/log/org.trellixloopupdateuserprompt.log"}" 


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

echo "-------------------"
echo "-------------------"
updateScriptLog "Trellix Loop Updates: Starting...."

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Flight: Loop the Trellix Updates hidden from user
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #


# Prompt the user for input and validate it
while true; do
    echo "Please enter the number of trellix loops (numeric value only):"
    read name

    # Check if the input contains only numeric characters
    if [[ $name =~ ^[0-9]+$ ]]; then
        iterations=$name
        break
    else
        echo "Invalid input. Please enter a numeric value."
    fi
done

# Generate itemsToProgress array based on the number of iterations
itemsToProgress=()
for ((i = 1; i <= iterations; i++)); do
    itemsToProgress+=("$i")
done

echo "Trellix Number of Selected Loops: $iterations"
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
