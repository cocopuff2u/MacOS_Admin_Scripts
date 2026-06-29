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

### 3. [Delete Expired Certificates](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Delete_Expired_Certificates.sh)

- **Description**: Scans the logged-in user's **login keychain** and the **System keychain** for certificates that have already expired, skips any matching an exclude list (default `Apple`), backs up each expired certificate's PEM, then removes it with `security delete-certificate`. Fully native — **no swiftDialog or JamfHelper**. The confirmation GUI is built with `osascript` (JXA) + AppKit and shown in the console user's session, so it works even when run as root from Jamf.
- **Two run modes**:
  - `verbose` *(default)* — shows a branded **checklist** of the expired certs found; the user unchecks anything to keep, then clicks **Remove**. A result window confirms the outcome.
  - `silent` — runs unattended (log only), removing every expired, non-excluded certificate.
- **Dry run** (`$6`): scans and reports exactly **which certificates would be deleted** (friendly name, expiry, keychain) without changing anything.
- **Safety**: every removed certificate's PEM is backed up to a timestamped, root-owned folder under `/var/log/expired-cert-backups/` before deletion; the delete is skipped if the backup can't be written. System keychain changes require root (Jamf runs as root).
- **Two ways to deploy**:
  - **Self Service** (user clicks it and confirms): leave `HEADLESS=false` and set Jamf Parameter 4 to `verbose` (or leave it blank — verbose is the default).
  - **Headless / automated** (runs silently, no prompt): set Jamf Parameter 4 to `silent`, **or** set `HEADLESS=true` in the script's Config block.
  - Always test first with Parameter 6 = `dry` — it lists what *would* be removed and deletes nothing.
- **Jamf parameter labels** (type these on the script's *Options* tab):
  - **Parameter 4**: `Action Mode (verbose or silent)` — `verbose` = show the user a confirm window (default); `silent` = remove with no prompt.
  - **Parameter 5**: `Exclude Patterns (comma-separated)` — names/issuers to never touch; blank = `Apple` (e.g. `Apple,JSS Built-In,Coursera`).
  - **Parameter 6**: `Dry Run (type dry to preview)` — `dry` = preview only; blank = actually delete.
- **Configurable variables** (top of the script, with plain-English comments): `HEADLESS`, `DRY_RUN_OVERRIDE`, `EXCLUDE_PATTERNS`, `BACKUP_PARENT`, `logFile`, `bannerColor`, dialog title/labels.
- **No dependencies** — uses only built-in macOS tools (`security`, `openssl`, `osascript`).

**Confirmation checklist** (verbose mode — each row tagged `[User]` / `[System]`):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/deleteexpiredcerts_checklist.png" width="50%">

**Result window** (after removal):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/deleteexpiredcerts_result.png" width="50%">

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
