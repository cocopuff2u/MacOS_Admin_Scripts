# How to Guide: Using Scripts Locally, Remotely, or via MDM for MacOS

## Guide Overview

This guide provides step-by-step instructions on how to download, customize, and execute scripts on macOS systems. It covers various methods of running scripts locally, remotely, or via Mobile Device Management (MDM) platforms like Intune, Jamf, and Kandji. Additionally, the guide explains necessary preexisting programs and files that may be required for certain scripts and offers guidance on modifying script variables to suit your needs.

### Sections Overview

- **Downloading and Executing Scripts:**  
  Learn how to download scripts from the web or GitHub and how to execute them locally or remotely. This section also explains how to run scripts via MDM platforms and what to expect when running a script without specifying a shell or interpreter.

- **Preexisting Requirements for Some Scripts:**  
  Understand which preinstalled programs or files are necessary for certain scripts to run correctly. This includes dependencies like Xcode for Python scripts, SwiftDialog for scripts that use dialog boxes, and IBM notifications for integration with IBM systems.

- **Customizing Script Variables:**  
  Discover how to modify script variables to tailor logging, paths, or other settings to your environment. This section provides examples of common variables and how to change them.

- **Error Handling, Security, and Logging:**  
  Learn about handling errors, security considerations for running unknown scripts, and understanding logging output provided by scripts. This section emphasizes the importance of script review and security best practices.

## Downloading and Executing Scripts

### Downloading the Script

You can download scripts from the web, GitHub, or other sources using the following methods:

#### 1. From a Web Browser

1. Navigate to the script’s URL.
2. Right-click the link and select "Save As" to download the file to your preferred location, such as the Downloads folder.

#### 2. Using `curl` or `wget`

For a direct download using the command line, use either `curl` or `wget`:

```bash
# Using curl to download a script
curl -o ~/Downloads/SCRIPT_NAME.sh "URL_OF_SCRIPT"

# Using wget to download a script
wget -O ~/Downloads/SCRIPT_NAME.sh "URL_OF_SCRIPT"
```
Replace `"URL_OF_SCRIPT"` with the actual script URL.

#### 3. From GitHub

If the script is hosted on GitHub, you have two options:

- **Download a Single File:**
  1. Navigate to the file in the GitHub repository.
  2. Click the "Raw" button.
  3. Right-click and select "Save As" to download the file.

- **Clone the Repository:**
  1. Clone the entire repository using `git`:

     ```bash
     git clone "URL_OF_REPOSITORY"
     ```

  2. Navigate to the repository directory:

     ```bash
     cd REPOSITORY_NAME
     ```

### Executing the Script

To run a script, use `sudo bash` for Bash scripts or `sudo python3` for Python scripts. Ensure that Python scripts have Xcode installed on the system beforehand.

#### Running Scripts Locally

When running scripts locally, use `sudo` unless you're logged in as root. Here’s how:

```bash
# Running a Bash script
sudo bash "PATH/TO/SCRIPT/SCRIPT_NAME.sh"

# Running a Python script
sudo python3 "PATH/TO/SCRIPT/SCRIPT_NAME.py"
```
Replace `PATH/TO/SCRIPT` with the actual path where the script is saved.

#### Running Scripts Without Specifying a Shell or Interpreter

If you run a script without specifying `bash` or `python3` (or another interpreter), the script will be executed by the system’s default shell. On macOS, the default shell is typically `zsh` for newer systems, but it might be `bash` on older systems.

```bash
# Running a script without specifying the shell or interpreter
./SCRIPT_NAME.sh
```

- **Important Considerations:**
  - The script must have executable permissions. You can add these with:
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
  - The script’s shebang (`#!/bin/bash` or `#!/usr/bin/env python3`) determines the interpreter used, provided it is specified at the top of the script.

#### Running Scripts Remotely

If you need to run a script on a remote machine via SSH, you have two main options:

1. **Option 1: Upload the Script Using `scp`**

   Use `scp` to securely copy the script from your local machine to the remote machine:

   ```bash
   scp ~/Downloads/SCRIPT_NAME.sh user@remote_host:/path/to/destination
   ```

   Then, SSH into the remote machine:

   ```bash
   ssh user@remote_host
   ```

   And execute the script:

   ```bash
   sudo bash /path/to/destination/SCRIPT_NAME.sh
   ```

2. **Option 2: Download the Script Directly on the Remote Machine**

   If you prefer not to upload the script manually, you can download it directly to the remote machine using `curl` or `wget`:

   - **Using `curl`:**

     ```bash
     ssh user@remote_host
     curl -o ~/SCRIPT_NAME.sh "URL_OF_SCRIPT"
     sudo bash ~/SCRIPT_NAME.sh
     ```

   - **Using `wget`:**

     ```bash
     ssh user@remote_host
     wget -O ~/SCRIPT_NAME.sh "URL_OF_SCRIPT"
     sudo bash ~/SCRIPT_NAME.sh
     ```

   This method downloads the script directly from the web to the remote machine, and you can then execute it immediately after downloading.

#### Running Scripts via MDM

When deploying scripts via MDM (e.g., Intune, Jamf, Kandji), they usually run as root and don’t require `sudo`. Scripts may need a specific header for MDM compatibility, but scripts tested on Intune, Jamf, and Kandji are typically ready for use without modification.

- **[Running Scripts via Intune](https://learn.microsoft.com/en-us/mem/intune/apps/macos-shell-scripts):**  
  Microsoft Intune allows you to deploy scripts to macOS devices using the Intune Management Extension. Follow the link for a step-by-step guide.

- **[Running Scripts via Jamf](https://docs.jamf.com/10.26.0/jamf-pro/administrator-guide/Scripts.html):**  
  Jamf Pro supports deploying scripts to managed devices. This guide explains how to upload and execute scripts in Jamf.

- **[Running Scripts via Kandji](https://support.kandji.io/hc/en-us/articles/360050942731-Custom-Scripts):**  
  Kandji provides a platform to run custom scripts on enrolled macOS devices. The linked guide covers script creation and deployment.

## Preexisting Requirements for Some Scripts

Some scripts depend on preinstalled programs or files on the system. If these dependencies are not met, the script may fail to execute correctly. Below are common examples:

#### 1. Python Scripts

- **Xcode Requirement:**  
  Python scripts often require Xcode to be installed on macOS. Xcode includes necessary developer tools and libraries that Python may depend on. Ensure Xcode is installed by running:

  ```bash
  xcode-select --install
  ```

#### 2. Scripts Using SwiftDialog

- **SwiftDialog Installation:**  
  Some scripts may require SwiftDialog, a utility for creating dialog boxes in macOS. Before running any script that utilizes SwiftDialog, ensure that it’s installed on your system. You can install SwiftDialog by downloading it from its [GitHub repository](https://github.com/bartreardon/swiftDialog).

  After downloading, you can place the SwiftDialog binary in `/usr/local/bin/` for easy access:

  ```bash
  sudo mv /path/to/swiftdialog /usr/local/bin/dialog
  ```

  Once installed, confirm it’s working by running:

  ```bash
  dialog --version
  ```

#### 3. IBM Notifications

- **IBM mac-ibm-notifications:**  
  Some scripts may integrate with IBM systems and require the IBM mac-ibm-notifications package. Install it by following the instructions provided on its [GitHub repository](https://github.com/IBM/mac-ibm-notifications).

## Customizing Script Variables

Scripts may include variables that you can customize to suit your environment. Here’s how to modify these variables:

### Variables Example

```bash
# Enable or Disable Logging
Enable_Logging=true # Example of Boolean Variable

# Script Log Location
scriptLog="/var/tmp/org.COMPANY.GPAutoupdater.log" # Example of String Variable
```

### Modifying Variables

1. **Open the Script:**
   Open the script file in your preferred IDE or text editor.

2. **Edit Variable Values:**
   Modify the variables as needed. These are usually located at the top of the script.

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

Boolean variables represent true/false values and control the script’s behavior.

1. **Identify the Boolean Variable:**
   Look for variables set to `true` or `false`.

   ```bash
   # Example boolean variable
   enableFeature=true
   ```

2. **Modify the Boolean Value:**
   Adjust the value based on your needs.

   - **Example: Enabling/Disabling a Feature**

     ```bash
     ### BEFORE
     enableFeature=false

     ### AFTER
     enableFeature=true
     ```

3. **Update the Script Logic:**
   Ensure any conditional logic in the script reflects your changes.

   ```bash
   if [ "$enableFeature" = true ]; then
       # Code to run if the feature is enabled
   else
       # Code to run if the feature is disabled
   fi
   ```

## Error Handling, Security, and Logging

### Error Handling and Debugging

Scripts often include error logging to provide information about issues encountered during execution. Check the script’s documentation or output for details on where logs are stored or how errors are reported.

- **Error Handling Tips:**
  - Look for common error messages or log entries that indicate problems.
  - Use debugging techniques like `set -x` in Bash to trace script execution.
  - Check for typos or incorrect paths in the script.

### Security Considerations

When running unknown scripts, it’s crucial to ensure they are safe and do not pose a security risk. 

- **Review the Script:**  
  Before running a script, inspect its contents to understand what it does. Look for commands that might alter system settings, access sensitive data, or execute potentially harmful operations.

- **Use Trusted Sources:**  
  Download scripts from reputable sources and avoid executing scripts from unverified sources.

- **Check Permissions:**  
  Ensure the script has the necessary permissions to execute but avoid giving excessive permissions that could pose security risks.

### Logging Output

Many scripts provide logging output to track their execution and errors.

- **Checking Logs:**  
  Review logs for information about script performance and any issues encountered. Logs can often be found in system directories like `/var/log/` or specified by the script itself

- **Example Logging Output:**
  - Errors related to file permissions or missing dependencies.
  - Informational messages about the script’s progress.
