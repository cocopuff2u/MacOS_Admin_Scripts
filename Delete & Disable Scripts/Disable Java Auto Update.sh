#!/bin/sh

/usr/bin/defaults write "/Library/Preferences/com.oracle.java.Java-Updater" JavaAutoUpdateEnabled -bool false
echo "Disabled Java automatic update check."



exit 0
