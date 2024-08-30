# Jamf-Only Scripts

These scripts are specifically designed to run within the Jamf MDM environment. While they are optimized for Jamf, with some adjustments, they can potentially be adapted for use with other MDM solutions.

## Available Scripts

### 1. [Jamf Bootstraptoken Scripts](SCRIPTLINK)

- **Description**: This set of scripts manages Bootstraptokens for devices in Jamf. They perform three main tasks:
  - **Enable Bootstraptoken**: Activates the Bootstraptoken for the device.
  - **Escrow Bootstraptoken**: Safeguards the token with the user’s password.
  - **Verify Bootstraptoken**: Confirms that the escrowed token is functioning correctly.

  **Note**: Uses SwiftDialog to prompt users for password

  ![IMAGE OF SCRIPT](IMAGELINKT)

### 2. [Jamf Extension Attributes Scripts](SCRIPTLINK)

- **Description**: A collection of scripts designed to extract extension attribute information from the machine and upload it to Jamf. These scripts help in gathering and managing detailed device attributes.

## Downloading and Executing Scripts

### Downloading the Script

You can download scripts from the web or directly from GitHub using the methods below:

#### From a Web Browser

1. Navigate to the script’s URL.
2. Save the file to your preferred location, such as the Downloads folder.

#### Using `curl` or `wget`

To download a script from a direct URL, use one of the following commands:

```bash
# Using curl to download a script
curl -o ~/Downloads/SCRIPT_NAME.sh "URL_OF_SCRIPT"

# Using wget to download a script
wget -O ~/Downloads/SCRIPT_NAME.sh "URL_OF_SCRIPT"
```

Replace `"URL_OF_SCRIPT"` with the actual URL of the script.

#### From GitHub

If the script is hosted on GitHub, you can either download it directly or clone the repository:

1. **Download a Single File:**

   - Go to the file in the GitHub repository.
   - Click the "Raw" button.
   - Right-click and select "Save As" to download the file.

2. **Clone the Repository:**

   - Clone the repository using `git`:

     ```bash
     git clone "URL_OF_REPOSITORY"
     ```

   - Navigate to the cloned repository:

     ```bash
     cd REPOSITORY_NAME
     ```

   - The script will be in the repository's directory.

### Executing the Script

To run a script, use `sudo bash` or `sudo python3`, depending on the script type. Most of these scripts are written in Bash or Python. Note that Python scripts require Xcode to be installed on the device prior to running.

When scripts are run from MDM (Mobile Device Management), they typically execute as root and do not require `sudo`. However, if running the scripts standalone, you will likely need `sudo` unless you are already logged in as root. Some MDMs may require a special header to be added to the script, but the necessary header is already included. The scripts should work with most MDMs and have been tested with Intune and Jamf.

Here are examples of how to execute them:

```bash
# Running a Bash script
sudo bash "PATH/TO/SCRIPT/SCRIPT_NAME.sh"

# Running a Python script
sudo python3 "PATH/TO/SCRIPT/SCRIPT_NAME.py"
```

*Note:* Replace `PATH/TO/SCRIPT` with the actual location where the script is saved. If you downloaded the script to your Downloads folder, use:

```bash
# Running a Bash script from the Downloads folder
sudo bash "~/Downloads/SCRIPT_NAME.sh"

# Running a Python script from the Downloads folder
sudo python3 "~/Downloads/SCRIPT_NAME.py"
```

## Script Variables

Each script may include variables that can be customized to tailor logging behavior or adjust settings on your local machine. Below, you'll find instructions on how to modify these variables based on their type, such as string or boolean.

### Variables Example

Here are some example variables you might find in a script:

```bash
# Enable or Disables Logging
Enable_Logging=true # Example of Boolean Varible

# Script Log Location
scriptLog="/var/tmp/org.COMPANY.GPAutoupdater.log" # Example of String Varible
```

### Modifying Variables

To customize these variables, follow these steps:

1. **Open the Script:**
   Open the script file in your preferred IDE (such as Visual Studio Code) or a text editor.

2. **Edit Variable Values:**
   Modify the variable values according to your needs.

   *Note: These variables are usually located at the top of the script.*

   - **Example: Changing a URL Variable**

     ```bash
     ### BEFORE
     GP_pkg_url=("https://URL.com/global-protect/msi/GlobalProtect.pkg")

     ### AFTER
     GP_pkg_url=("https://YOURCOMPANY.com/global-protect/msi/GlobalProtect.pkg")
     ```

   - **Example: Changing the Log Location**

     ```bash
     ### BEFORE
     scriptLog="/var/tmp/org.COMPANY.GPAutoupdater.log"

     ### AFTER
     scriptLog="/var/tmp/org.YOURCOMPANY.GPAutoupdater.log"
     ```

### Modifying Boolean Variables

Boolean variables are used to represent true/false values. They often control the flow of the script or enable/disable features. Here’s how to handle boolean variables:

1. **Identify the Boolean Variable:**
   Look for variables that are set to `true` or `false`. They might also be represented as `1` (true) or `0` (false).

   ```bash
   # Example boolean variable
   enableFeature=true
   ```

2. **Modify the Boolean Value:**
   Change the value based on the desired state. For instance, to enable a feature, set it to `true`; to disable it, set it to `false`.

   - **Example: Enabling/Disabling a Feature**

     ```bash
     ### BEFORE
     enableFeature=false

     ### AFTER
     enableFeature=true
     ```

3. **Update the Script Logic:**
   Ensure that any conditional logic or checks that use the boolean variable reflect your changes. For example:

   ```bash
   if [ "$enableFeature" = true ]; then
       # Code to run if the feature is enabled
   else
       # Code to run if the feature is disabled
   fi
   ```

By following these instructions, you can customize the script to fit your specific requirements and control various aspects of its behavior.

