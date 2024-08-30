#!/bin/sh

disk0=`diskutil info disk0 | grep "Solid State" | awk '{ print $3 }'`
disk1=`diskutil info disk1 | grep "Solid State" | awk '{ print $3 }'`

if [[ $disk0 == "Yes" ]]; then

echo "<result>disk0 is SSD</result>"
exit 0

elif [[ $disk1 == "Yes" ]]; then

echo "<result>disk1 is SSD</result>"
exit 0

fi

echo "<result>No SSD Drives</result>"

exit 0
