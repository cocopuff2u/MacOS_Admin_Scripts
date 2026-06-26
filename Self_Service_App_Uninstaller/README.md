# Self Service App Uninstaller

A native, GUI-driven uninstaller for macOS that completely removes an app **and** all the leftover files it scatters around the system — preferences, caches, containers, login items, support files, and installer receipts — the way the "AppCleaner" utility does. Dragging an app to the Trash leaves those orphaned files behind (often gigabytes); this finds everything tied to the app and removes it in one step.

It is built to be deployed as a **Jamf Self Service** item. The user clicks it, sees exactly what will be removed in a checklist, and confirms — nothing is deleted without them seeing it first. The interface is built entirely with `osascript` (JXA) + AppKit, so there are **no dependencies** (no swiftDialog, no compiled helper) and it runs as an Accessory app (no Dock icon, no menu‑bar clutter).

### Features:
- **Complete removal**: Resolves the app's bundle id, Team ID, and display name, then sweeps ~60 `~/Library` and `/Library` locations plus `pkgutil` receipts for everything belonging to the app.
- **User reviews and confirms**: A scrollable checklist (everything pre‑checked) lets the user uncheck anything to keep before removing. Cancel / close / uncheck‑all removes nothing.
- **App picker**: Leave the target blank and the user picks from a list of installed apps (with icons); set it and it jumps straight to that app's review.
- **Recoverable**: User files are moved to the logged‑in user's Trash (system files are deleted). The log records the exact Trash destination of every item.
- **Protected apps**: Apple system apps and a configurable list of management tooling (Jamf Connect, Self Service, Nudge, Jamf Setup Manager, …) are hidden from the picker and refused if targeted.
- **Light & Dark mode**: Windows use adaptive system colors; the scanning HUD is an always‑readable dark panel.
- **Dry‑run mode**: Shows the whole experience but deletes nothing — for validating a policy before going live.

## Screens

**Pick an app to uninstall** (shown when no target is specified):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/Self_Service_App_Uninstaller/images/firstwindow.png" width="55%">

**Review exactly what will be removed, then confirm:**
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/Self_Service_App_Uninstaller/images/secondwindow.png" width="55%">

## Available Scripts

### 1. [Self Service App Uninstaller](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/Self_Service_App_Uninstaller/Self_Service_App_Uninstaller.sh)
- **Description**: Fully uninstalls a macOS app and its leftover files. Deploy as a Self Service policy; the user reviews a checklist and confirms before anything is removed.

## Jamf Setup

1. **Settings > Computer Management > Scripts > New** and paste in the script.
2. In the **Options** tab, set the Parameter Labels:
   - **Parameter 4:** `App to remove — name, bundle id, or path (blank = let the user pick)`
   - **Parameter 5:** `Dry run — enter "dry" to preview only (blank = actually remove)`
3. Add the script to a **Policy** and fill in the parameters:
   - **Parameter 4** — leave **blank** to show the app picker, or enter a display name (`Slack`), a bundle id (`com.tinyspeck.slackmacgap`), or a full path (`/Applications/Slack.app`).
   - **Parameter 5** — leave **blank** for a real uninstall, or enter `dry` to preview.
4. Set the trigger to **Self Service** and add it to Self Service. A user must be logged in — the window appears in their session.

> Tip: Edit the **CONFIG** block at the top of the script to change the banner color, dialog text, and the `PROTECTED_*` lists (apps that can never be removed).

## Preexisting Requirements

None. The interface uses only `osascript` (JXA) + AppKit, which ship with macOS. A user must be logged in at the screen for the GUI to appear.

## Questions, Concerns, and Requests

We value your feedback and encourage you to engage with us. Here’s how you can get involved:

- **Report Issues**: [Submit an issue on GitHub](https://github.com/cocopuff2u/MacOS_Admin_Scripts/issues) to report bugs or request new features.
- **Join the Discussion**: Connect with me, cocopuff2u, on the [Mac Admins Slack Channel](https://join.slack.com/t/macadmins/shared_invite/zt-2o5811yhx-q5MNLrFG1VoHRusXLgZwsw) to discuss improvements and collaborate with other Mac administrators.
- **Email**: Contact me directly at [cocopuff2u@yahoo.com](mailto:cocopuff2u@yahoo.com) for any specific inquiries or detailed discussions.
- **Share Feedback**: Your input is invaluable! Share your thoughts and suggestions to help us enhance these scripts.
- **Fork and Fix**: Interested in contributing? Fork the repository, make your changes, and submit a pull request to improve the codebase.
