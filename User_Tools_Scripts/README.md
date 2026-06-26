# User Tool Scripts

These scripts provide a range of prompts and tools to perform local tasks on macOS machines. They facilitate user interactions and enable administrators to request necessary actions from users. The scripts can be executed locally, remotely, or through platforms like Self Service.

## Available Scripts

### 1. [Recommend User Reboot](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Recommend_User_Reboot.sh)

- **Description**: Reminds the user to restart once their Mac has been up beyond a set number of days. Shows a branded reminder; if they agree, a **live countdown** gives them time to save work before the Mac restarts. Fully native — **no swiftDialog or JamfHelper**; the GUI is `osascript` (JXA) + AppKit, shown in the console user's session, so it works even when run as root from Jamf.
- **Respects the user**: skips the prompt while a meeting / screen share / presentation / full-screen video is active (a display-sleep assertion is held).
- **Jamf parameters**: `$4` uptime days (blank = 14), `$5` countdown minutes (blank = 5), `$6` dry run (`dry`/`true` = show the dialogs without restarting, for testing).
- **Configurable variables**: `bannerColor`, `windowTitle`, `iconStyle` (`selfservice` = the Self Service app icon, falling back to the SF Symbol; or `symbol`), `restartIcon` (SF Symbol), `ignoreAssertionApps`.
- **No dependencies** — uses only built-in macOS tools.

**Reminder:**
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/recommendreboot_reminder.png" width="50%">

**Live countdown** (after the user clicks Restart Now):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/recommendreboot_countdown.png" width="50%">

### 2. [Set Time Zone](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Set_Time_Zone.sh)

- **Description**: Lets the logged-in user set the Mac's time zone from a branded, native picker, then confirms. Fully native — **no swiftDialog or JamfHelper**. The GUI is built with `osascript` (JXA) + AppKit and shown in the console user's session, so it works even when run as root from Jamf.
- **Two picker styles** (set `pickerStyle`):
  - `"dropdown"` *(default)* — an **Area** menu plus a **Zone** menu that repopulates when the area changes.
  - `"list"` — one scrollable, fixed-height list of every `Area/City` zone.
- **Configurable variables** (top of the script):
  - `bannerColor` — banner bar colour, hex (e.g. `#0056D2`)
  - `pickerStyle` — `"dropdown"` or `"list"`
  - `windowTitle` — banner title on the picker
  - `successTitle` / `failTitle` — confirmation window titles
  - `okButton` — confirmation button label
- **No dependencies** — uses only built-in macOS tools. Requires root to apply the change (Jamf runs as root).

**Dropdown style** (default):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/settimezone_dropdown.png" width="50%">

**List style** (`pickerStyle="list"`):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/settimezone_list.png" width="50%">

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
