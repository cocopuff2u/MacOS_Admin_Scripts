#!/bin/zsh
#set -x

####################################################################################################
#
# Trellix Console Check In for Modules with a Swiftdialog Prompt
#
# Purpose: Loops Trellix console check-in until all modules are present, confirms Trellix & Swift are present
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 10/16/23 - Original Release - @cocopuff2u
#
#
####################################################################################################

# This pulls the current user to scope the path of the branding image
currentUser=$(/bin/echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil | /usr/bin/awk '/Name / { print $3 }')

# Note: This can be BASE64, a Local File, or a URL. If a URL, the file needs to curl down prior to jamfHelper (Default: Jamf Branding Image Path)
icon="/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"

# "Loop Window Title"
title="Trellix Update In Progress"

# "Found Files Completed Window Title"
title2="Trellix Update Completed"

# "Found Files Failed Window Title"
title3="Trellix Update Failed"

# "Loop Window Message"
description="May take a few minutes"

# "Found Files Completed Message"
description2="All Trellix modules were detected"

# "Found Files Failed Message"
description3="Failed to grab Trellix modules, contact support"

# Set the number of iterations
iterations=50

# Keep the computer awake during the loop
symPID="$$"
caffeinate -dimsu -w $symPID &

# Script Log Location
scriptLog="${4:-"/var/tmp/org.URCOMPANY.TrellixLoopModule.log"}"

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Logging

if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Script Logging Function


function updateScriptLog() {
    echo -e "$( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

updateScriptLog "!!!!!!!!Starting up the script!!!!!!!!"

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Validate / install swiftDialog

updateScriptLog "Verifying/installing Swiftdialog...."
function dialogInstall() {

    # Get the URL of the latest PKG From the Dialog GitHub repo
    dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")

    # Expected Team ID of the downloaded PKG
    expectedDialogTeamID="PWA5E9TQ59"

    updateScriptLog "Installing swiftDialog..."

    # Create temporary working directory
    workDirectory=$( /usr/bin/basename "$0" )
    tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )

    # Download the installer package
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"

    # Verify the download
    teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')

    # Install the package if Team ID validates
    if [[ "$expectedDialogTeamID" == "$teamID" ]]; then

        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
        sleep 2
        dialogVersion=$( /usr/local/bin/dialog --version )
        updateScriptLog "swiftDialog version ${dialogVersion} installed; proceeding..."
        Echo "SwiftDialog version $dialogVersion Installed" 

    else

        # Display a so-called "simple" dialog if Team ID fails to validate
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "Trellix Module Loop" buttons {"Close"} with icon caution'
        completionActionOption="Quit"
        exitCode="1"
        quitScript

    fi

    # Remove the temporary working directory when done
    /bin/rm -Rf "$tempDirectory"

}
function dialogCheck() {

    # Output Line Number in `verbose` Debug Mode
    if [[ "${debugMode}" == "verbose" ]]; then updateScriptLog "PRE-FLIGHT CHECK: # # # SETUP YOUR MAC VERBOSE DEBUG MODE: Line No. ${LINENO} # # #" ; fi

    # Check for Dialog and install if not found
    if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then

        updateScriptLog "swiftDialog not found. Installing..."
        Echo "SwiftDialog not found. Installing" 
        dialogInstall

    else

        dialogVersion=$(/usr/local/bin/dialog --version)
        if [[ "${dialogVersion}" < "${swiftDialogMinimumRequiredVersion}" ]]; then
            
            updateScriptLog "swiftDialog version ${dialogVersion} found but swiftDialog ${swiftDialogMinimumRequiredVersion} or newer is required; updating..."
            Echo "SwiftDialog version $dialogVersion but Swift Dialog $swiftDialogMinimumRequiredVersion or newer is required, updating..." 
            dialogInstall
            
        else
        updateScriptLog "swiftDialog version ${dialogVersion} found; proceeding..."
        Echo "SwiftDialog version $dialogVersion found, proceeding..."
        fi
    
    fi
#!/bin/zsh
#set -x 

####################################################################################################
#
# Trellix Console Check In for Modules with a Swiftdialog Prompt
#
# Purpose: Loops Trellix console check-in until all modules are present, confirms Trellix & Swift are present
#
# https://github.com/cocopuff2u
#
####################################################################################################
# 
# HISTORY
#
# 1.0 10/16/23 - Original Release - @cocopuff2u
#
#
####################################################################################################

# This pulls the current user to scope the path of the branding image
currentUser=$(/bin/echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil | /usr/bin/awk '/Name / { print $3 }')

# Note: This can be BASE64, a Local File, or a URL. If a URL, the file needs to curl down prior to jamfHelper (Default: Jamf Branding Image Path)
icon="/Users/$currentUser/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png"

# "Loop Window Title"
title="Trellix Update In Progress"

# "Found Files Completed Window Title"
title2="Trellix Update Completed"

# "Found Files Failed Window Title"
title3="Trellix Update Failed"

# "Loop Window Message"
description="May take a few minutes"

# "Found Files Completed Message"
description2="All Trellix modules were detected"

# "Found Files Failed Message"
description3="Failed to grab Trellix modules, contact support"

# Set the number of iterations
iterations=50

# Keep the computer awake during the loop
symPID="$$"
caffeinate -dimsu -w $symPID &

# Script Log Location
scriptLog="${4:-"/var/tmp/org.NIWCRDTE.TrellixLoopModule.log"}"

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Logging

if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Script Logging Function


function updateScriptLog() {
    echo -e "$( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

updateScriptLog "!!!!!!!!Starting up the script!!!!!!!!"

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Validate / install swiftDialog

updateScriptLog "Verifying/installing Swiftdialog...."
function dialogInstall() {

    # Get the URL of the latest PKG From the Dialog GitHub repo
    dialogURL=$(curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")

    # Expected Team ID of the downloaded PKG
    expectedDialogTeamID="PWA5E9TQ59"

    updateScriptLog "Installing swiftDialog..."

    # Create temporary working directory
    workDirectory=$( /usr/bin/basename "$0" )
    tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )

    # Download the installer package
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"

    # Verify the download
    teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')

    # Install the package if Team ID validates
    if [[ "$expectedDialogTeamID" == "$teamID" ]]; then

        /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
        sleep 2
        dialogVersion=$( /usr/local/bin/dialog --version )
        updateScriptLog "swiftDialog version ${dialogVersion} installed; proceeding..."
        Echo "SwiftDialog version $dialogVersion Installed" 

    else

        # Display a so-called "simple" dialog if Team ID fails to validate
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Dialog Team ID verification failed\r\r" with title "Trellix Module Loop" buttons {"Close"} with icon caution'
        completionActionOption="Quit"
        exitCode="1"
        quitScript

    fi

    # Remove the temporary working directory when done
    /bin/rm -Rf "$tempDirectory"

}
function dialogCheck() {

    # Output Line Number in `verbose` Debug Mode
    if [[ "${debugMode}" == "verbose" ]]; then updateScriptLog "PRE-FLIGHT CHECK: # # # SETUP YOUR MAC VERBOSE DEBUG MODE: Line No. ${LINENO} # # #" ; fi

    # Check for Dialog and install if not found
    if [ ! -e "/Library/Application Support/Dialog/Dialog.app" ]; then

        updateScriptLog "swiftDialog not found. Installing..."
        Echo "SwiftDialog not found. Installing" 
        dialogInstall

    else

        dialogVersion=$(/usr/local/bin/dialog --version)
        if [[ "${dialogVersion}" < "${swiftDialogMinimumRequiredVersion}" ]]; then
            
            updateScriptLog "swiftDialog version ${dialogVersion} found but swiftDialog ${swiftDialogMinimumRequiredVersion} or newer is required; updating..."
            Echo "SwiftDialog version $dialogVersion but Swift Dialog $swiftDialogMinimumRequiredVersion or newer is required, updating..." 
            dialogInstall
            
        else
        updateScriptLog "swiftDialog version ${dialogVersion} found; proceeding..."
        Echo "SwiftDialog version $dialogVersion found, proceeding..."
        fi
    
    fi

}

dialogCheck

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Validate Trellix

# Path to Trellix CmdAgent
TrellixCommandFile="/Library/McAfee/agent/bin/cmdagent"
updateScriptLog "Verifying Trellix...."

if [ -e "$TrellixCommandFile" ]; then
        updateScriptLog "Trellix cmdagent found; proceeding..."
        Echo "Trellix cmdagent present; proceeding..." 
    else
        # Display a so-called "simple" dialog if Team ID fails to validate
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Trellix verification failed\r\r" with title "Trellix Presence Check" buttons {"Close"} with icon caution'
        completionActionOption="Quit"
        exitCode="1"
        updateScriptLog "Trellix not found; exiting on error..."
    fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Main function

# Define the path to your dialog command file
dialogCommandFile="/var/tmp/SwiftDialogTrellixLoop.log"

# Check if the file exists and remove it if it does
if [ -e "$dialogCommandFile" ]; then
    updateScriptLog "File $dialogCommandFile found"
    if rm "$dialogCommandFile"; then
        echo "File '$dialogCommandFile' has been deleted."
        updateScriptLog "File $dialogCommandFile has been deleted."
    else
        echo "Failed to delete '$dialogCommandFile'."
        updateScriptLog "Failed to delete $dialogCommandFile."
    fi
fi

# Create a new dialog command file
if touch "$dialogCommandFile"; then
    echo "New file '$dialogCommandFile' has been created."
    updateScriptLog "New file '$dialogCommandFile' has been created for Swiftdialog command"
else
    echo "Failed to create '$dialogCommandFile'."
    updateScriptLog "Failed to create '$dialogCommandFile'."
fi

# An array containing the list of items to progress through
itemsToProgress=()

# Populate the array with elements containing loop count
for ((i=1; i<=iterations; i++)); do
    itemsToProgress+=("Looping Trellix Updates Until All Modules Load: $i/$iterations")
done

# Counting started attempts for logging
count=0 

# Print the elements of the array
for element in "${itemsToProgress[@]}"; do
    echo "$element"
done

# Path to our dialog binary
dialogPath='/usr/local/bin/dialog'

# This function sends a command to our command file, and sleeps briefly to avoid race conditions
function dialog_command() {
    echo "$@" >> "$dialogCommandFile"
    sleep 0.1
}

# Calling our initial dialog window. The & is crucial so that our script progresses.
# ${#itemsToProgress[@]} is equal to the number of items in our array
$dialogPath \
--title "$title" \
--message "$description"  \
--ontop \
--mini \
--commandfile "$dialogCommandFile" \
--progress ${#itemsToProgress[@]} \
--icon "$icon" \
--button1 \
&

# Display the bouncy bounce for 2 seconds
sleep 2

# Create an array of files to check for existence
filesToCheck=("/usr/local/McAfee/fmp/config/FMPInfo.xml" "/usr/local/McAfee/fmp/config/StatefulFirewall/FMConfig.xml" "/usr/local/McAfee/fmp/config/WebProtection/FMConfig.xml" "/usr/Local/McAfee/DlpAgent/Version")

for list in "${filesToCheck[@]}"; do
updateScriptLog "Checking for files $list"
done

updateScriptLog "Script set to loop $iterations time/s until all files are found"

# Iterate through our array
# For each item we've outlined
for item in "${itemsToProgress[@]}"; do
    dialog_command "progress: increment"
    dialog_command "progresstext: $item"
    
    all_files_exist=true
    ((count++))

    # Check if all specified files exist
    for file in "${filesToCheck[@]}"; do
        if [ ! -f "$file" ]; then
            all_files_exist=false
            break
        fi
    done
    
    if $all_files_exist; then
        updateScriptLog "All Trellix files found! after $count/$iterations attempts"
        updateScriptLog "Running 1 more loop for policy grab...."
        open /Applications/Trellix\ Endpoint\ Security\ for\ Mac.app
        /Library/McAfee/agent/bin/cmdagent -c
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -e
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -p
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -f
        sleep 5
        pkill -x "Trellix Endpoint Security for Mac"
        echo  "Confirmed all Trellix files found! Exiting loop...."
        updateScriptLog "Confirmed all Trellix files found! Exiting loop...."
        sleep 1
        break
    fi
        for MissingFile in "${filesToCheck[@]}"; do
            if [ ! -f "$MissingFile" ]; then
                updateScriptLog "Trellix file $MissingFile missing."
            fi
        done
    updateScriptLog "Loop Re-attempt $count/$iterations"
    echo "Trellix "$filesToCheck" not found, re-attempt $count/$iterations"
    /Library/McAfee/agent/bin/cmdagent -c
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -e
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -p
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -f
    sleep 5
    open /Applications/Trellix\ Endpoint\ Security\ for\ Mac.app
done

#avoids race situation
sleep 2

# Close our dialog window
dialog_command "quit:"

if $all_files_exist; then
   updateScriptLog "Prompting user that all files are present..."
    $dialogPath \
    --title "$title2" \
    --message "$description2"  \
    --ontop \
    --mini \
    --icon "$icon" \
    --button1text "Close" \
    &

    else
    updateScriptLog "Prompting user that all files failed to present..."

        $dialogPath \
        --title "$title3" \
        --message "$description3"  \
        --ontop \
        --mini \
        --icon "$icon" \
        --button1text "Close" \
        &

    updateScriptLog "All Trellix files not found, notified user, max re-attempts reached, finalizing script...."
fi

# Delete our command file
updateScriptLog "removing the $dialogCommandFile file...."
rm "$dialogCommandFile"
updateScriptLog "File $dialogCommandFile removed..."
updateScriptLog "Script Completed"

exit 0
}

dialogCheck

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Validate Trellix

# Path to Trellix CmdAgent
TrellixCommandFile="/Library/McAfee/agent/bin/cmdagent"
updateScriptLog "Verifying Trellix...."

if [ -e "$TrellixCommandFile" ]; then
        updateScriptLog "Trellix cmdagent found; proceeding..."
        Echo "Trellix cmdagent present; proceeding..." 
    else
        # Display a so-called "simple" dialog if Team ID fails to validate
        osascript -e 'display dialog "Please advise your Support Representative of the following error:\r\r• Trellix verification failed\r\r" with title "Trellix Presence Check" buttons {"Close"} with icon caution'
        completionActionOption="Quit"
        exitCode="1"
        updateScriptLog "Trellix not found; exiting on error..."
    fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Main function

# Define the path to your dialog command file
dialogCommandFile="/var/tmp/SwiftDialogTrellixLoop.log"

# Check if the file exists and remove it if it does
if [ -e "$dialogCommandFile" ]; then
    updateScriptLog "File $dialogCommandFile found"
    if rm "$dialogCommandFile"; then
        echo "File '$dialogCommandFile' has been deleted."
        updateScriptLog "File $dialogCommandFile has been deleted."
    else
        echo "Failed to delete '$dialogCommandFile'."
        updateScriptLog "Failed to delete $dialogCommandFile."
    fi
fi

# Create a new dialog command file
if touch "$dialogCommandFile"; then
    echo "New file '$dialogCommandFile' has been created."
    updateScriptLog "New file '$dialogCommandFile' has been created for Swiftdialog command"
else
    echo "Failed to create '$dialogCommandFile'."
    updateScriptLog "Failed to create '$dialogCommandFile'."
fi

# An array containing the list of items to progress through
itemsToProgress=()

# Populate the array with elements containing loop count
for ((i=1; i<=iterations; i++)); do
    itemsToProgress+=("Looping Trellix Updates Until All Modules Load: $i/$iterations")
done

# Counting started attempts for logging
count=0 

# Print the elements of the array
for element in "${itemsToProgress[@]}"; do
    echo "$element"
done

# Path to our dialog binary
dialogPath='/usr/local/bin/dialog'

# This function sends a command to our command file, and sleeps briefly to avoid race conditions
function dialog_command() {
    echo "$@" >> "$dialogCommandFile"
    sleep 0.1
}

# Calling our initial dialog window. The & is crucial so that our script progresses.
# ${#itemsToProgress[@]} is equal to the number of items in our array
$dialogPath \
--title "$title" \
--message "$description"  \
--ontop \
--mini \
--commandfile "$dialogCommandFile" \
--progress ${#itemsToProgress[@]} \
--icon "$icon" \
--button1 \
&

# Display the bouncy bounce for 2 seconds
sleep 2

# Create an array of files to check for existence
filesToCheck=("/usr/local/McAfee/fmp/config/FMPInfo.xml!" "/usr/local/McAfee/fmp/config/StatefulFirewall/FMConfig.xml!" "/usr/local/McAfee/fmp/config/WebProtection/FMConfig.xml" "/usr/Local/McAfee/DlpAgent/Version")

for list in "${filesToCheck[@]}"; do
updateScriptLog "Checking for files $list"
done

updateScriptLog "Script set to loop $iterations time/s until all files are found"

# Iterate through our array
# For each item we've outlined
for item in "${itemsToProgress[@]}"; do
    dialog_command "progress: increment"
    dialog_command "progresstext: $item"
    
    all_files_exist=true
    ((count++))

    # Check if all specified files exist
    for file in "${filesToCheck[@]}"; do
        if [ ! -f "$file" ]; then
            all_files_exist=false
            break
        fi
    done
    
    if $all_files_exist; then
        updateScriptLog "All Trellix files found! after $count/$iterations attempts"
        updateScriptLog "Running 1 more loop for policy grab...."
        open /Applications/Trellix\ Endpoint\ Security\ for\ Mac.app
        /Library/McAfee/agent/bin/cmdagent -c
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -e
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -p
        sleep 5
        /Library/McAfee/agent/bin/cmdagent -f
        sleep 5
        pkill -x "Trellix Endpoint Security for Mac"
        echo  "Confirmed all Trellix files found! Exiting loop...."
        updateScriptLog "Confirmed all Trellix files found! Exiting loop...."
        sleep 1
        break
    fi
        for MissingFile in "${filesToCheck[@]}"; do
            if [ ! -f "$MissingFile" ]; then
                updateScriptLog "Trellix file $MissingFile missing."
            fi
        done
    updateScriptLog "Loop Re-attempt $count/$iterations"
    echo "Trellix "$filesToCheck" not found, re-attempt $count/$iterations"
    /Library/McAfee/agent/bin/cmdagent -c
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -e
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -p
    sleep 5
    /Library/McAfee/agent/bin/cmdagent -f
    sleep 5
    open /Applications/Trellix\ Endpoint\ Security\ for\ Mac.app
done

#avoids race situation
sleep 2

# Close our dialog window
dialog_command "quit:"

if $all_files_exist; then
   updateScriptLog "Prompting user that all files are present..."
    $dialogPath \
    --title "$title2" \
    --message "$description2"  \
    --ontop \
    --mini \
    --icon "$icon" \
    --button1text "Close" \
    &

    else
    updateScriptLog "Prompting user that all files failed to present..."

        $dialogPath \
        --title "$title3" \
        --message "$description3"  \
        --ontop \
        --mini \
        --icon "$icon" \
        --button1text "Close" \
        &

    updateScriptLog "All Trellix files not found, notified user, max re-attempts reached, finalizing script...."
fi

# Delete our command file
updateScriptLog "removing the $dialogCommandFile file...."
rm "$dialogCommandFile"
updateScriptLog "File $dialogCommandFile removed..."
updateScriptLog "Script Completed"

exit 0