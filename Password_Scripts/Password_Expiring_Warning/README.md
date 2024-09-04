# Password Expiring Scripts

These scripts are designed to notify users of an expiring password and provide a prompt for them to change it.

## Available Scripts

### 1. [Password Expiring Warning](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/61776b0a47ea5af4ce3910fca1aa00d90406c0ce/Password_Scripts/Password_Expiring_Warning/Password_Expiring_Warning_OSAScript.sh)

- **Description**: When run daily, this script alerts the user about an impending password expiration via OSAScript.
- **Features**: Customizable maximum days before the password expires.

**Note**: Recommended for use with [Jamf Pro](https://www.jamf.com/) but not required.

  ![firstwindow](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/93e3f21297a7113267f6e63a68c864e73e365590/Password_Scripts/images/firstwindow.png)

### 2. [Password Expiring Top Right Notification](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/61776b0a47ea5af4ce3910fca1aa00d90406c0ce/Password_Scripts/Password_Expiring_Warning/Daily_Password_Warning_Notification_Swift.sh)

- **Description**: Displays a warning notification in the top right corner via `SwiftDialog` to inform the user of the remaining days before the password expires.
- **Features**: Customizable maximum days and notification days.

**Note**: This script uses [SwiftDialog](https://github.com/swiftDialog/swiftDialog) for secure user prompts and interactions.

  ![notifcation](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/2afad689e8e2d6f2da958a706940e46dc056070e/Password_Scripts/images/Example_notification_password.png)

### 3. [Password Self Service Check](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/61776b0a47ea5af4ce3910fca1aa00d90406c0ce/Password_Scripts/Password_Expiring_Warning/Password_Expiring_Jamf_Self_Service.sh)

- **Description**: Allows the user to check the remaining days before their password expires.
- **Features**: Customizable maximum days.

**Note**: Recommended for use with [Jamf Pro](https://www.jamf.com/) but not required.

  ![firstwindow](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/e5beb21223dd33f08e4fca24016adf16898735d4/Password_Scripts/images/selfservicewindow.png)

## How to Download and Execute Scripts

To start using the scripts, follow the detailed instructions in our [How-To Guide](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/7f996a69700d749398ec9a1f84aadd26fd855569/How_To_Guide/README.md). This guide will help you efficiently download, configure, and execute the scripts to meet your needs.

## Preexisting Requirements

Some scripts may require additional software:

- [Install Xcode](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators): Necessary for compiling and running certain scripts.
- [Install SwiftDialog](https://github.com/swiftDialog/swiftDialog): Required for scripts using SwiftDialog for graphical user prompts.
- [Install IBM Notifications](https://github.com/IBM/mac-ibm-notifications): Needed for scripts that involve IBM notifications.

## Questions, Concerns, and Requests

We welcome your feedback and encourage you to get involved:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) for bug reports or feature requests.
- **Join the Discussion**: Connect with cocopuff2u on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) for collaboration and insights.
- **Email**: Contact cocopuff2u at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for detailed inquiries or support.
- **Share Feedback**: Your suggestions are crucial for continuous improvement. Please share your thoughts to help us enhance these scripts.
- **Fork and Fix**: Interested in contributing? Fork the repository, make your modifications, and submit a pull request to improve the codebase.
