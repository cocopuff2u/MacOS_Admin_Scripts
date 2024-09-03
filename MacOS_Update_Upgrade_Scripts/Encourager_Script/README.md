# Encourager macOS Upgrade Script (with JamfHelper)

The Encourager script uses `JamfHelper` and Jamf Pro to present a compelling message to users, prompting them to upgrade their macOS. It provides the Apple Install Assistant package for immediate installation or deferred installation with a re-prompt.

### Key Features

- **Upgrade Management**: Compares the current OS to the target OS specified in the script, downloads the installer from a provided URL, and opens it for the user to install immediately or later.
- **Customization**: Easily customizable URL, title, logo, message, and buttons.
- **Design Note**: This script is tailored for major OS upgrades rather than minor updates. For most scenarios, consider using [Nudge](https://github.com/macadmins/nudge) or [Superman](https://github.com/Macjutsu/super) as alternatives. Both offer robust features for managing and prompting upgrades.

### Future Features

- **Progress Bar**: Plans to integrate a progress bar for background downloads using SwiftDialog, time permitting.

### Screenshots

**Initial Window**  
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/455adc33bd632014626dac66bfec10af62beb0e7/MacOS_Update_Upgrade_Scripts/Encourager_Script/images/firstwindow.png">

**Decline Window**  
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/455adc33bd632014626dac66bfec10af62beb0e7/MacOS_Update_Upgrade_Scripts/Encourager_Script/images/declinewindow.png">

**After Download Window**  
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/455adc33bd632014626dac66bfec10af62beb0e7/MacOS_Update_Upgrade_Scripts/Encourager_Script/images/afterdownloadwindow.png">

## How to Download and Execute Scripts

Follow the detailed instructions in our [How-To Guide](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/7f996a69700d749398ec9a1f84aadd26fd855569/How_To_Guide/README.md) to download, configure, and run the scripts effectively.

## Preexisting Requirements

Ensure the following software is installed:

- [Xcode](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators): Required for compiling and running certain scripts.
- [SwiftDialog](https://github.com/swiftDialog/swiftDialog): Needed for scripts utilizing SwiftDialog for graphical prompts.
- [IBM Notifications](https://github.com/IBM/mac-ibm-notifications): Necessary for scripts with IBM notification features.

## Questions, Concerns, and Requests

We appreciate your feedback and encourage you to connect with us:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) for bug reports or feature requests.
- **Join the Discussion**: Connect on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) for collaboration and insights.
- **Email**: Reach out at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for detailed inquiries or support.
- **Share Feedback**: Your suggestions help us improve. Please share your thoughts.
- **Fork and Fix**: Contribute by forking the repository, making changes, and submitting a pull request to enhance the codebase.
