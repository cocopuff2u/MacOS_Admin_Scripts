#!/bin/bash

loggedInUser=$(python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
hardUUID="system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}'"
sudo rm -Rf /Users/$loggedInUser/Library/Keychains/*
#sudo rm -Rf /Users/$loggedInUser/Library/Keychains/$hardUUID

exit 0
