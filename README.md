# MacOS Admin Scripts

Welcome to a collection of valuable scripts designed for Mac administrators. These scripts assist in performing a variety of tasks on macOS machines. Created with deployment in mind, they work seamlessly with Mobile Device Management (MDM) solutions like Intune, Jamf, and Kandji. Most scripts are adaptable for both local and remote execution via SSH. Some may require pre-existing software such as SwiftDialog, JamfHelper, Xcode, or AppleScript, and can be customized to fit specific needs.

Sharing tools and scripts is essential in the Mac admin community. Many of these scripts are adaptations or combinations of existing ones, and others are original creations. Feel free to modify, request, or contribute your own scripts. After all, it’s all about collaboration and community support.

## Available Scripts

### 1. [Application Installers Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Application_installer_Scripts)
A comprehensive collection of scripts for installing various applications.

### 2. [Application Specific Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Application_Specific_Scripts)
Scripts tailored for customizing or configuring specific applications.

### 3. [Application Uninstall Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Application_Uninstaller_Scripts)
A set of scripts designed for uninstalling different applications.

### 4. [Delete/Disable Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Delete_Disable_Scripts)
Scripts for disabling or uninstalling software and services.

### 5. [Jamf Only Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Jamf_Only_Scripts)
Scripts specifically crafted for deployment via Jamf Pro.

### 6. [Keychain, SSH, and Certificate Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Keychain_SSH_Certificates_Scripts)
Scripts focused on managing keychain, SSH, and certificates.

### 7. [MacOS Update/Upgrade Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/MacOS_Update_Upgrade_Scripts)
Scripts to assist with updating or upgrading macOS.

### 8. [Password Management Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/Password_Scripts)
Scripts designed to help admins manage and communicate password requirements.

### 9. [User Tool Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/7e9c4c4bace4505e891f0fe3b11d00eade53ab5b/User_Tools_Scripts)
Scripts that provide tools and prompts for user and admin tasks.

## Featured Scripts

### [Password Expiring Warning](https://github.com/cocopuff2u/Jamf-Scripts/tree/e9726a40ae3d0c85901b81bdebf9cfaee3eff9c3/Password%20Expiring%20Warning)
Warns users when their password is nearing expiration.
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/e180c6ff51823ef44a81a8d22f471d1d95888035/Password%20Expiring%20Warning/images/firstwindow.png" width=50% height=50%>
</p>

### [Encourager MacOS Upgrade Script](https://github.com/cocopuff2u/Jamf-Scripts/tree/aed85f88d759b35859bd2603e6ee099794a01680/Encourager%20(MacOS%20Upgrader%20Script))
Prompts users to upgrade macOS via the Install Assistant pkg, encouraging them to perform the upgrade.
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/440682a92426b6de0611e3156271bcb685b70525/Encourager%20(MacOS%20Upgrader%20Script)/images/firstwindow.png" width=50% height=50%>
</p>

### [User Password Tester](https://github.com/cocopuff2u/Jamf-Scripts/tree/main/User%20Password%20Tester)
Allows the local logged-in user to test their password, useful in SmartCard-enforced environments.
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/660c747b97d5187b8c9d75ef4213cee70bfdc834/User%20Password%20Tester/images/firstwindow.png" width=50% height=50%>
</p>

### [User Recommend Reboot](https://github.com/cocopuff2u/Jamf-Scripts/tree/a85717d38bf522ecbe26fafaff94df51fdd85ca4/User%20Recommend%20Reboot)
Recommends users to reboot their devices based on a maximum uptime setting.
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/93797f84db5149487ae2f7cab3abca728192b2bf/User%20Recommend%20Reboot/recommendrebootwindow.png" width=50% height=50%>
</p>

### [Set Time Zone](https://github.com/cocopuff2u/Jamf-Scripts/tree/5884e9ec57f1f9c58b958df2725e36cc90dbd0f8/Set%20Time%20Zone)
Allows users to select their time zone.
<br />
<p align="center">
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/84457f9da900fc5f54a5968825ab2b1fd96dfdf9/Set%20Time%20Zone/firstwindow.png" width=50% height=50%>
</p>

## How to Download and Execute Scripts

To get started, follow the detailed instructions in our [How-To Guide](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/7f996a69700d749398ec9a1f84aadd26fd855569/How_To_Guide/README.md). This guide covers the steps to download, configure, and execute the scripts effectively.

## Preexisting Requirements

Certain scripts may require additional software:

- [Xcode](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators): Required for compiling and running specific scripts.
- [SwiftDialog](https://github.com/swiftDialog/swiftDialog): Needed for scripts using SwiftDialog for graphical user prompts.
- [IBM Notifications](https://github.com/IBM/mac-ibm-notifications): Necessary for scripts involving IBM notifications.

## Questions, Concerns, and Requests

We welcome your feedback and encourage you to get involved:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) for bug reports or feature requests.
- **Join the Discussion**: Engage with us on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) for collaboration and insights.
- **Email**: Contact us at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for detailed inquiries or support.
- **Share Feedback**: Your suggestions are crucial for continuous improvement. Please share your thoughts to help us enhance these scripts.
- **Fork and Fix**: Interested in contributing? Fork the repository, make your modifications, and submit a pull request to improve the codebase.
