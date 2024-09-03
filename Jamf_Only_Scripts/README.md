# Jamf-Only Scripts

These scripts are specifically developed to operate within the Jamf MDM (Mobile Device Management) environment. While they are optimized for use with Jamf, they are designed with flexibility in mind, allowing for potential adaptation to other MDM solutions with some adjustments.

### Features:
- **Jamf Integration**: Tailored for seamless operation within the Jamf MDM framework, ensuring compatibility and ease of use.
- **Versatile Functionality**: Covers a range of tasks from managing Bootstraptokens to extracting extension attributes, providing comprehensive management capabilities.
- **User Interaction**: Some scripts include user prompts and feedback mechanisms to enhance usability and ensure accurate execution.

## Available Scripts

### 1. [Jamf Bootstraptoken Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/5add3d0e6f4e9037934f6d313e1e83468104536b/Jamf%20Only%20Scripts/Jamf%20Escrow%20Scripts)
- **Description**: This set of scripts is designed to manage Bootstraptokens within the Jamf environment. It includes three main functionalities:
  - **Enable Bootstraptoken**: Activates the Bootstraptoken for the device, enabling secure management.
  - **Escrow Bootstraptoken**: Safeguards the Bootstraptoken by storing it securely with the user’s password.
  - **Verify Bootstraptoken**: Confirms that the escrowed token is working correctly and is accessible when needed.

  **Note**: These scripts utilize [SwiftDialog](https://github.com/swiftDialog/swiftDialog) for secure user prompts and interactions.

  ![Escrow Example](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/2e7ed2338fcc7850272a8908b1f91b5c865d3527/Jamf%20Only%20Scripts/images/Example_BootStrapToken_Escrow.png)

### 2. [Jamf Extension Attributes Scripts](https://github.com/cocopuff2u/MacOS_Admin_Scripts/tree/5add3d0e6f4e9037934f6d313e1e83468104536b/Jamf%20Only%20Scripts/Jamf%20Extension%20Attributes)
- **Description**: This collection of scripts is designed to extract and upload extension attribute information from macOS devices to Jamf. They assist in gathering detailed device attributes, enhancing the management and reporting capabilities within Jamf.

## How to Download and Execute Scripts

[LINK TO GUIDE]

## Preexisting Requirements

Some scripts may require additional programs or files to function correctly:

- [Install Xcode](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators): Essential for compiling and running certain scripts.
- [Install SwiftDialog](https://github.com/swiftDialog/swiftDialog): Required for scripts that use SwiftDialog for user interaction.
- [Install IBM Notifications](https://github.com/IBM/mac-ibm-notifications): Necessary for scripts that include IBM notification features.

## Questions, Concerns, and Requests

We value your feedback and encourage you to engage with us. Here’s how you can get involved:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) to report bugs or request new features.
- **Join the Discussion**: Connect with me, cocopuff2u, on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) for discussions and collaboration.
- **Email**: Contact me directly at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for inquiries or support.
- **Share Feedback**: Your suggestions are valuable for ongoing improvement. Please share your thoughts to help us enhance these scripts.
- **Fork and Fix**: Interested in contributing? Fork the repository, make your changes, and submit a pull request to help improve the codebase.