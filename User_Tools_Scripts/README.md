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

### 4. [Collect User Logs](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Collect_User_Logs.sh)

- **Description**: Gathers log files from the Mac (everything under `/var/log`, the system and user `Library/Logs` folders, and `/Library/Management`), zips them into a single archive, and drops it on the logged-in user's Desktop — ready to attach to a support ticket. Fully native — **no swiftDialog or JamfHelper**. Shows a progress spinner, a result window, and reveals the zip in Finder; the GUI runs in the console user's session via `osascript` (JXA) + AppKit, so it works even when run as root from Jamf.
- **What it grabs**: all `*.log` files (plus rotated `*.log.*` and, optionally, crash/diagnostic reports), preserving each file's original path inside the zip. This includes **Jamf** (`jamf.log`, Self Service logs), **App Auto-Patch** (`aap.log`/`aap_verbose.log`), and **Installomator** (`Installomator.log`) logs. A `_DEVICE_INFO.txt` summary (user, computer name, serial, model, macOS, uptime) is added at the root.
- **Zip name**: `Logs_<user>_<serial>_<timestamp>.zip`, owned by the user, on their Desktop.
- **Two ways to deploy**:
  - **Self Service** (user clicks it, watches progress): leave `HEADLESS=false`, set Jamf Parameter 4 to `verbose` (or blank — the default).
  - **Headless** (collect silently, no UI): set Jamf Parameter 4 to `silent`, **or** set `HEADLESS=true` in the Config block.
- **Jamf parameter labels** (script's *Options* tab):
  - **Parameter 4**: `Action Mode (verbose or silent)`
  - **Parameter 5**: `Extra Log Folders (comma-separated, optional)` — additional folders to include.
- **Configurable variables** (top of the script): `HEADLESS`, `LOG_SOURCES`, `INCLUDE_ROTATED`, `INCLUDE_CRASH_REPORTS`, `MAX_FILE_MB`, `ZIP_NAME_PATTERN`, `logFile`, banner colours.
- **No dependencies** — uses only built-in macOS tools (`find`, `ditto`, `osascript`).

**Progress** (live — shows the folder being scanned and a running file count):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/collectuserlogs_progress.png" width="50%">

**Result window** (with the zip name ready to copy):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/collectuserlogs_result.png" width="50%">

### 5. [Network Health Check](https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/Network_Health_Check.sh)

- **Description**: Tests the Mac's network connection and shows the user a clear, plain-English results window: a **0–100 Network Score**, a **video-call verdict**, and findings that say what's wrong. It also gives IT the detailed data needed to troubleshoot. Fully native — **no swiftDialog or JamfHelper**. The GUI is `osascript` (JXA) + AppKit, shown in the console user's session, so it works even when run as root from Jamf.
- **What it measures**:
  - **Responsiveness**: lag, latency, jitter, and packet loss to `1.1.1.1` / `8.8.8.8`. The router is measured separately, which tells "your Wi-Fi/router" apart from "your ISP". It works even when the router ignores ping or a VPN is on.
  - **Reliability**: time spent unresponsive during the test (sustained drop-outs only).
  - **Speed**: download and upload, plus a bufferbloat grade (latency under load). Uses Apple's built-in `networkQuality` or `speed.cloudflare.com`.
  - **Web & DNS**: time to first byte for Google, Apple, Microsoft, M365 login, Cloudflare, Zoom, and Teams. Each DNS server is timed against 1.1.1.1 and 8.8.8.8.
  - **Wi-Fi**: signal, noise, SNR, band/channel, link rate, signal range during the test, and nearby/same-channel networks.
  - **Connection history**: drops in the last 24 hours while the Mac was awake, read from the Mac's own logs. Drops caused by sleep are skipped.
  - **Other apps**: which apps were using the network during the test (iCloud, OneDrive, backups, updates...).
- **For IT section**:
  - **Device management**: MDM enrollment and vendor (Jamf, Intune, Kandji, Mosyle, Workspace ONE...), whether the MDM server is reachable, the Jamf health check, and Apple Push (ports 5223 and 443).
  - **VPN**: VPN apps installed or running, whether a tunnel is up (full or split), the VPN server and its response time, configured VPN servers, and DNS from the VPN. Nothing to configure; it reads what's on the Mac.
  - **Network path**: a traceroute that flags where latency jumps.
  - **Network configuration**: DHCP, subnet, MAC, MTU, IPv6, proxy/PAC, network extensions, and VPN configurations.
  - **Health checks**: captive portal, path MTU, clock offset, and interface errors. TCP retransmits too, when run as root.
  - **This Mac**: Mac info and step timings.
- **Save Report**: writes a text report to the user's Desktop, including raw command output, ready to attach to a ticket.
- **Progress window**: a 5-step tracker, live color-coded ping and Mbps readouts with graphs, and a **Cancel** button.
- **Two ways to deploy**:
  - **Self Service** (user clicks it, watches progress, reads results): leave `HEADLESS=false` and set Jamf Parameter 4 to `verbose` (or leave it blank).
  - **Headless** (no UI; report goes to the policy log): set Jamf Parameter 4 to `silent`, **or** set `HEADLESS=true` in the Config block.
- **Jamf parameter labels** (script's *Options* tab):
  - **Parameter 4**: `Action Mode (verbose or silent)`
  - **Parameter 5**: `Speed Test (apple, cloudflare, or off)`. `apple` (default) = multi-stream `networkQuality`; `cloudflare` = single stream; `off` = skip.
  - **Parameter 6**: `Test Duration in seconds, or "quick"`. Blank = 20 seconds; `quick` = 5-second sample with no speed test.
  - **Parameter 7**: `Simulate Scenario (testing only — leave blank)`.
- **Testing**:
  - **Simulation mode** fakes the results for a scenario, so you can see exactly what users see without breaking a network. Examples: `NHC_SIMULATE=weak-wifi`, `no-internet`, `captive-portal`, `router-bottleneck`, `wifi-drops`, `bandwidth-hog`, `mdm-unreachable`, `all-bad`. `NHC_SIMULATE=list` shows all 23 scenarios.
  - **Step timings** are logged every run.
  - **Optional JSON results**: `SAVE_JSON=true` writes `/Library/Management/NetworkHealth/last.json` plus a `history.jsonl` log.
- **Runs as root (Jamf)**: adds the Wi-Fi network name, access point, MCS, channel utilization, TCP retransmits, and the MDM server address.
- **Configurable variables** (top of the script): `HEADLESS`, `TEST_SECONDS`, `INTERNET_TARGETS`, `WEB_TARGETS`, `DNS_TEST_DOMAINS`, `SPEED_ENGINE`, `QUICK_MODE`, `SIMULATE`, `SAVE_JSON`, `REPORT_NAME_PATTERN`, `logFile`, banner colours, and button labels.
- **No dependencies** — uses only built-in macOS tools (`ping`, `traceroute`, `networkQuality`, `curl`, `dig`, `osascript`).

**Progress** (live readout with a step tracker and Cancel button):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/networkhealth_progress.png" width="50%">

**Results window** (score, video-call verdict, findings, and scrollable details):
<br />
<img src="https://github.com/cocopuff2u/MacOS_Admin_Scripts/blob/main/User_Tools_Scripts/images/networkhealth_result.png" width="50%">

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
