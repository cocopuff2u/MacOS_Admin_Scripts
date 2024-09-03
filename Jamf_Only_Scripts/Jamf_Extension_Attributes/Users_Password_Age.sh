#!/bin/bash

curUser=$(ls -l /dev/console | cut -d " " -f 4)
passwordAge=$(expr $(expr $(date +%s) - $(dscl . read /Users/${curUser} | grep -A1 passwordLastSetTime | grep real | awk -F'real>|</real' '{print $2}' | awk -F'.' '{print $1}')) / 86400)
echo "<result>${passwordAge}</result>"
