# Application Installer Scripts

This folder contains scripts for installing applications from both local and remote sources, along with any necessary configuration settings they may require.

## Script Variables

Each script includes variables that can be tailored to produce different types of logs or settings the local machine. Adjust these settings as needed. Here are some examples:

```bash
# Global Protect URL to verify current version
GP_pkg_url=("https://URL.com/global-protect/msi/GlobalProtect.pkg")
GP_pkg_url_live=("https://URL.com")

# Script Log Location
scriptLog="${4:-"/var/tmp/org.COMPANYT.GPAutoupdater.log"}"
```

To modify these variables, open the script in your preferred IDE (such as Visual Studio Code) and adjust the relevant lines. For example:

```bash
### BEFORE
GP_pkg_url=("https://URL.com/global-protect/msi/GlobalProtect.pkg")

### AFTER
GP_pkg_url=("https://YOURCOMPANY.com/global-protect/msi/GlobalProtect.pkg")
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