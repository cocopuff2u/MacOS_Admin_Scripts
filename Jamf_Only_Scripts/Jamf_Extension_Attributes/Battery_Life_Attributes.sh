#!/bin/sh

#Battery Cycle Count
echo "<result>$(system_profiler SPPowerDataType | grep "Cycle Count" | awk '{print $3}')</result>"

# Battery Condition
echo "<result>$(system_profiler SPPowerDataType | grep "Condition" | awk '{print $2}')</result>"
