# Application Specific Scripts

This folder contains scripts tailored to specific applications for performing various tasks, both within the application and externally

## Script Variables

Each script includes variables that can be tailored to produce different types of logs or settings the local machine. Adjust these settings as needed. Here are some examples:

```bash
# Path to our dialog binary
dialogPath='/usr/local/bin/dialog'
# Path to our dialog command file
dialogCommandFile=$(mktemp /var/tmp/trellixloopDialog.XXXXX)
#Note: This can be BASE64, a Local File or a URL
icon="/Applications/Trellix Endpoint Security for Mac.app/Contents/Resources/McAfee_Locked.png"
#"Window Title"
titleloop="Trellix Update In Progress"
title="Trellix Loop Utility"
#"Window Message During Loop"
descriptionloop="May take a few minutes"
#"Window Message To Select Loop"
description="Choose the number of loops for executing Trellix updates"
```

To modify these variables, open the script in your preferred IDE (such as Visual Studio Code) and adjust the relevant lines. For example:

```bash
### BEFORE
title="Trellix Loop Utility"

### AFTER
title="MY COMPANY Trellix Loop Utility"
```

## Executing Scripts

To execute a script, use the command `sudo bash` followed by the script's name. For example:

```bash
sudo bash "PATH/TO/SCRIPT/Global_Protect_Installer_Upgrader.sh"
```

*Note:* The file path will depend on where you downloaded the file. For example, if saved to the Downloads folder in your home directory, the command would be:

```bash
sudo bash "~/downloads/Global_Protect_Installer_Upgrader.sh"
```
## Scripts


### <p align="center"> [Trellix Loop GUI](https://github.com/cocopuff2u/Jamf-Scripts/blob/e3f51ef10df8da28c5c6cff739c812c27cac15c8/Other_Scripts/Trellix_Loop_Updates_GUI.sh)  </p> 
<p align="center"> This is designed to help you push Trellix Loops to speed up enrollment or updates</p>
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/e3f51ef10df8da28c5c6cff739c812c27cac15c8/Other_Scripts/images/Trellix_Loop_Image.png" width=50% height=50%>
</p>
