# Password Tester Scripts

These scripts are designed to allow users to test their passwords if they've forgotten them without causing a lockout.

Originally created for environments that enforce full SmartCard use without a reminder for users to test or remember their local passwords, these scripts provide an easy prompt for users to test their passwords without affecting the FailedLoginCount limit.

## Available Scripts

### 1. [SwiftDialog Password Tester](LINK)

- **Description**: Utilizes `SwiftDialog` and Jamf Pro Scripts to display engaging messages that allow the current logged-in user to test their password.
- **Features**: Customizable title, logo, and maximum password age.

**Note**: This script uses [SwiftDialog](https://github.com/swiftDialog/swiftDialog) for secure user prompts and interactions.

  ![firstwindow](LINK)

### 2. [OSAScript Password Tester](LINK)

- **Description**: Uses `OSAScript` and Jamf Pro Scripts to provide a simple prompt for users to test their password without causing a lockout.

## How to Download and Execute Scripts

To start using these scripts, follow the detailed instructions in our [How-To Guide](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/7f996a69700d749398ec9a1f84aadd26fd855569/How_To_Guide/README.md). This guide will help you efficiently download, configure, and execute the scripts to suit your needs.

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