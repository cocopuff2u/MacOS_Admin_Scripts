# User Tool Scripts

These scripts provide a range of prompts and tools to perform local tasks on macOS machines. They facilitate user interactions and enable administrators to request necessary actions from users. The scripts can be executed locally, remotely, or through platforms like Self Service.

## Available Scripts

### 1. [Recommend User Reboot](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Recommend_User_Reboot.sh)

- **Description**: Utilizes `JamfHelper` and `AppleScript` with Jamf Pro Scripts to display engaging end-user messages prompting them to reboot their device based on maximum uptime. 
- **Features**: Customizable uptime days, logo, title, and message.

**Note**: This script requires [Jamf Pro](https://www.jamf.com/).

<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/recommendrebootwindow.png" width="50%">

### 2. [Set Time Zone](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Set_Time_Zone.sh)

- **Description**: Leverages `AppleScript`, &/or `JamfHelper` and Jamf Pro Scripts to easily display an engaging end-user message to set the timezone.
- **Features**: Customizable Title, Logo, & Buttons
- **Optional**: JamfHelper Prompt

**Note**: This script also uses [Jamf Pro](https://www.jamf.com/).

![Set Time Zone](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/firstwindow.png)

## How to Download and Execute Scripts

To get started with downloading and executing the scripts, please follow the detailed instructions provided in our [How-To Guide](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/How_To_Guide/README.md). This guide will walk you through the necessary steps to ensure you can efficiently download, configure, and run the scripts for your needs.

## Preexisting Requirements

Some scripts may require additional programs or files to function correctly:

- [Install Xcode](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators): Essential for compiling and running certain scripts.
- [Install SwiftDialog](https://github.com/swiftDialog/swiftDialog): Required for scripts that use SwiftDialog for graphical user prompts and interactions.
- [Install IBM Notifications](https://github.com/IBM/mac-ibm-notifications): Necessary for scripts that include IBM notification features.

## Questions, Concerns, and Requests

We value your feedback and encourage you to engage with us. Here’s how you can get involved:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) for bug reports or feature requests.
- **Join the Discussion**: Connect with me, cocopuff2u, on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) for collaboration and insights.
- **Email**: Reach out directly at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for detailed inquiries or support.
- **Share Feedback**: Your suggestions are crucial for continuous improvement. Please share your thoughts and feedback to help us enhance these scripts.
- **Fork and Fix**: Interested in contributing? Fork the repository, make your modifications, and submit a pull request to help improve the codebase.
