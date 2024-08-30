#!/bin/sh

####################################################################################################
#
# Installs Latest Brave Browser
#
# Purpose: Installs Brave Browser
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 3/21/23 - Original Release - @cocopuff2u
#
#
# 1.1 8/29/23 - Verified Still functioning, confirm it grabs Apple or Silcon based on hardware - @cocopuff2u
#
#
####################################################################################################


# Vendor supplied DMG file
VendorDMG="Brave-Browser.dmg"

# Download vendor supplied DMG file into /tmp/
curl https://referrals.brave.com/latest/$VendorDMG -o /tmp/$VendorDMG

# Mount vendor supplied DMG File
hdiutil attach /tmp/$VendorDMG -nobrowse

# Copy contents of vendor supplied DMG file to /Applications/
# Preserve all file attributes and ACLs
cp -pPR /Volumes/Brave\ Browser/Brave\ Browser.app /Applications/

# Identify the correct mount point for the vendor supplied DMG file
BraveBrowserDMG="$(hdiutil info | grep "/Volumes/Brave Browser" | awk '{ print $1 }')"

# Unmount the vendor supplied DMG file
hdiutil detach $BraveBrowserDMG

# Remove the downloaded vendor supplied DMG file
rm -f /tmp/$VendorDMG

exit 0
