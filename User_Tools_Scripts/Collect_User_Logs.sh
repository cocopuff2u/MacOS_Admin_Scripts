#!/bin/zsh

####################################################################################################
#
# Collect User Logs
#
# Purpose: Gathers log files from the Mac (everything under /var/log plus the system and user
#          Library/Logs folders), zips them into a single archive, and drops it on the logged-in
#          user's Desktop — ready to attach to a support ticket. Shows a progress spinner while it
#          works, a result window with the file location, and reveals the zip in Finder.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service (the user clicks it, watches progress, gets the zip on their Desktop):
#     • Leave the script as-is (HEADLESS=false). Set Jamf Parameter 4 to "verbose" or leave blank.
#
#   Headless / automated (collect silently, no UI — e.g. remote trigger before remoting in):
#     • Set Jamf Parameter 4 to "silent"  (OR set HEADLESS=true in the Config block below).
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose or silent)
#   Parameter 5 Label:  Extra Log Folders (comma-separated, optional)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Action Mode        verbose = show progress + result window (default)
#                            silent  = collect quietly, no windows
#     $5  Extra Log Folders  additional folders to include, comma-separated. Blank = none.
#                            example:  /Library/Application Support/MyApp/Logs,/opt/app/log
# ---------------------------------------------------------------------------------------------
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 6/29/26 - Original Release - Collects *.log files from /var/log + Library/Logs, zips to the
#               user's Desktop (Logs_<user>_<serial>_<timestamp>.zip), spinner + result + reveal,
#               verbose/silent modes. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # false = behave per the Jamf "Action Mode" param ($4): verbose shows a
                        #         progress spinner + result window; silent collects quietly.
                        # true  = ALWAYS run silently (no windows), no matter what $4 says.

# WHAT TO COLLECT -----------------------------------------------------------
LOG_SOURCES=(           # folders searched for log files (subfolders included)
    "/var/log"                            # system logs, jamf.log, Installomator.log, etc.
    "/Library/Logs"                       # system-wide app logs + DiagnosticReports
    "/Library/Management"                 # App Auto-Patch (appautopatch.log) and other MDM tooling
    "{USER_HOME}/Library/Logs"            # {USER_HOME} is replaced with the logged-in user's home
)
INCLUDE_ROTATED=true    # true = also grab rotated/compressed logs (install.log.0.gz, system.log.1…)
INCLUDE_CRASH_REPORTS=true   # true = also include crash / diagnostic reports (.ips, .crash, .panic,
                             #        .diag) from the DiagnosticReports folders — useful for crashes.
MAX_FILE_MB=50          # skip any single log bigger than this many MB (0 = no limit). Keeps the zip
                        # small when a runaway log is huge.

# WHERE IT GOES -------------------------------------------------------------
# The zip is written to the logged-in user's Desktop. Name pattern below; tokens are filled in:
#   {USER} = short name   {SERIAL} = device serial   {STAMP} = YYYYMMDD-HHMMSS
ZIP_NAME_PATTERN="Logs_{USER}_{SERIAL}_{STAMP}.zip"
logFile="/var/log/collect_user_logs.log"     # this script's own run log

# LOOK OF THE WINDOWS (verbose mode only) -----------------------------------
bannerColor="#0056D2"                      # banner bar colour (hex)
BANNER_TEXT_COLOR="#FFFFFF"                # banner title colour (hex)
SPINNER_TEXT="Collecting logs…"
RESULT_TITLE="Logs Collected"
RESULT_FAIL_TITLE="Log Collection Failed"
okButton="OK"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob

# Per-run scratch dir (staging tree + generated .jxa); always cleaned up.
SCRATCH="/tmp/collect-user-logs.$$"
/bin/mkdir -p "$SCRATCH"
trap '/bin/rm -rf "$SCRATCH"' EXIT INT TERM
STAGING=""   # set in Main once the bundle name is known, so the unzipped folder matches the zip name
STATUS_FILE="$SCRATCH/status.txt"   # the spinner polls this to show the folder it's on + a live count

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point as $1 ("/"), computer name $2, user $3. Strip that trio so our real
# params line up as $1=$4, $2=$5. Run locally without "/" and params pass through.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
ACTION_MODE="${1:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
[[ "$ACTION_MODE" != "silent" ]] && ACTION_MODE="verbose"
EXTRA_DIRS_ARG="$2"

# --- Console / user resolution ----------------------------------------------
# Resolve the logged-in (console) user so windows appear in their session and the zip lands on
# THEIR Desktop, even when this runs as root from Jamf.
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}

# The user whose Desktop/home we use (console user, else Jamf-passed user, else whoever runs this).
targetUser="${consoleUser:-${JAMF_USER:-$(/usr/bin/id -un)}}"
USER_HOME=$(/usr/bin/dscl . -read /Users/"$targetUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="/Users/$targetUser"

# Headless config toggle forces silent mode regardless of $4.
[[ "$HEADLESS" == true ]] && ACTION_MODE="silent"

# Expand {USER_HOME} token in the source list, and append any extra dirs from $5.
LOG_SOURCES=("${(@)LOG_SOURCES//\{USER_HOME\}/$USER_HOME}")
[[ -n "$EXTRA_DIRS_ARG" ]] && LOG_SOURCES+=("${(@s/,/)EXTRA_DIRS_ARG}")

# Banner colour -> RGB for AppKit
bhex="${bannerColor#\#}";   br=$((16#${bhex[1,2]}));  bg=$((16#${bhex[3,4]}));  bb=$((16#${bhex[5,6]}))
tchex="${BANNER_TEXT_COLOR#\#}"; tr=$((16#${tchex[1,2]})); tg=$((16#${tchex[3,4]})); tb=$((16#${tchex[5,6]}))

# --- Helpers ----------------------------------------------------------------
logMe() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}" | /usr/bin/tee -a "$logFile" 2>/dev/null || print -r -- "$2"; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }   # escape \ " newline for JS

# Update the live spinner: line 1 = current folder/step, line 2 = count/detail. The spinner window
# re-reads this file on a timer and updates its labels. World-readable so the user-session window
# can read it even when this script runs as root.
spin_status() {
  print -rl -- "$1" "$2" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}

# device serial number (built-in tools only)
device_serial() {
  /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
    | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# --- Progress spinner (larger dark HUD that updates live from $STATUS_FILE) --------------------
# Shows: a title, the spinner, the folder currently being scanned, and a running file count.
# A 0.3s NSTimer re-reads STATUS_FILE so the shell can update what's displayed as it works.
SPIN_SCPT="$SCRATCH/spin.jxa"
show_spinner() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  /bin/cat > "$SPIN_SCPT" <<EOF
ObjC.import('Cocoa');
var STATUS="$(as_esc "$STATUS_FILE")";
function readStatus(){ try{ var s=\$.NSString.stringWithContentsOfFileEncodingError(STATUS,\$.NSUTF8StringEncoding,null); return ObjC.unwrap(s)||""; }catch(e){ return ""; } }
function label(x,y,w,h,sz,bold){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,h));
 t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=1;
 t.usesSingleLineMode=true;t.cell.lineBreakMode=5;   // 5 = truncate middle (keeps both ends of a path)
 t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var W=560,H=210;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),0,2,false);
win.opaque=false; win.backgroundColor=\$.NSColor.clearColor; win.level=5; win.ignoresMouseEvents=true;
var cv=win.contentView;
// Card background with a soft shadow
var box=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(10,10,W-20,H-20));
box.boxType=4; box.borderWidth=0; box.titlePosition=0; box.cornerRadius=20;
box.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.15,0.15,0.17,0.97);
box.shadow=\$.NSShadow.alloc.init; box.shadow.shadowBlurRadius=24; box.shadow.shadowOffset=\$.NSMakeSize(0,-4);
box.shadow.shadowColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0,0,0,0.45);
cv.addSubview(box);
// Spinner
var sp=\$.NSProgressIndicator.alloc.initWithFrame(\$.NSMakeRect((W-26)/2,H-56,26,26));
sp.style=1; sp.indeterminate=true; sp.controlSize=1; cv.addSubview(sp); sp.startAnimation(null);
// Title
var title=label(30,H-96,W-60,24,17,true); title.stringValue="$(as_esc "$SPINNER_TEXT")"; title.textColor=\$.NSColor.whiteColor; cv.addSubview(title);
// Hairline separator
var sep=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(60,H-112,W-120,1));
sep.boxType=4; sep.borderWidth=0; sep.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(1,1,1,0.12); cv.addSubview(sep);
// Current folder (monospaced so paths read cleanly)
var folder=label(30,H-146,W-60,20,13,false); folder.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.92,0.93,0.96,1);
folder.font=\$.NSFont.monospacedSystemFontOfSizeWeight(12.5,\$.NSFontWeightRegular); cv.addSubview(folder);
// Running count (accent)
var count=label(30,H-172,W-60,18,12,false); count.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.45,0.62,1,1); cv.addSubview(count);
if(!\$.SpinTick){ObjC.registerSubclass({name:'SpinTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){ var L=readStatus().split("\n"); folder.setStringValue(L[0]||""); count.setStringValue(L[1]||""); }}}});}
var tk=\$.SpinTick.alloc.init;
\$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.3,tk,'tick:',null,true);
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
EOF
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; return 0; }

# --- Result window ----------------------------------------------------------
# show_message <title> <sfSymbol> <tintHex> <message> [filename]
#   Branded banner + a tinted SF Symbol, a wrapping message, an optional monospaced filename
#   "chip" that stands out, and a default OK button. Window height auto-fits the content.
show_message() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  local t="${1//\"/\\\"}" sym="$2" m="${4//\"/\\\"}" fname="${5//\"/\\\"}" mscpt="$SCRATCH/result.jxa"
  local th="${3#\#}"; local ir=$((16#${th[1,2]})) ig=$((16#${th[3,4]})) ib=$((16#${th[5,6]}))
  /bin/cat > "$mscpt" <<EOF
ObjC.import('Cocoa');
ObjC.registerSubclass({name:'CLMSG',superclass:'NSObject',methods:{'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=true;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.CLMSG.alloc.init;
var FNAME="$fname"; var hasFile=FNAME.length>0;
var W=560, BH=66, okH=32, iconS=56, msgH=52, chipH=34, g=14, topPad=18, botPad=24;
// Lay out bottom-up so the window height auto-fits.
var okY=botPad;
var chipY = hasFile ? (okY+okH+g) : okY+okH;
var msgY  = (hasFile ? (chipY+chipH+g) : (okY+okH+g));
var iconY = msgY+msgH+g;
var H = iconY+iconS+topPad+BH;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$t",20,H-BH+(BH-26)/2,W-40,26,18,true,1); tl.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($tr/255,$tg/255,$tb/255,1); cv.addSubview(tl);
// Tinted SF Symbol
var tint=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($ir/255,$ig/255,$ib/255,1);
var img=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("$sym","");
if(img){ var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-iconS)/2,iconY,iconS,iconS));
 iv.setImage(img); iv.imageScaling=3; iv.contentTintColor=tint; cv.addSubview(iv); }
// Message
cv.addSubview(label("$m",36,msgY,W-72,msgH,13,false,1));
// Filename chip (monospaced, selectable)
if(hasFile){
 var chip=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(40,chipY,W-80,chipH));
 chip.boxType=4; chip.borderWidth=0; chip.cornerRadius=8;
 chip.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.16); cv.addSubview(chip);
 var fn=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(52,chipY+(chipH-18)/2,W-104,18));
 fn.stringValue=FNAME; fn.bezeled=false; fn.editable=false; fn.selectable=true; fn.drawsBackground=false;
 fn.alignment=1; fn.usesSingleLineMode=true; fn.cell.lineBreakMode=5; fn.textColor=\$.NSColor.labelColor;
 fn.font=\$.NSFont.monospacedSystemFontOfSizeWeight(12,\$.NSFontWeightMedium); cv.addSubview(fn);
}
var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect((W-130)/2,okY,130,32)); b.title="$okButton"; b.bezelStyle=1; b.target=h; b.action='ok:'; b.keyEquivalent=\$('\r'); cv.addSubview(b);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
EOF
  /bin/chmod 644 "$mscpt"
  run_as_user /usr/bin/osascript -l JavaScript "$mscpt" >/dev/null 2>&1
}

# --- Collection -------------------------------------------------------------
# Copies matching files from every source into the staging tree, preserving their full path so
# IT can see where each came from. Sets COPIED (file count) and SKIPPED_BIG.
typeset -gi COPIED=0 SKIPPED_BIG=0
typeset -ga COLLECTED_PATHS=()   # original full path of every file we grabbed (for the manifest)
collect_logs() {
  local src f dest maxbytes=0 szk
  (( MAX_FILE_MB > 0 )) && maxbytes=$(( MAX_FILE_MB * 1024 * 1024 ))

  # Build the find name-pattern list: *.log always; rotated and crash reports optionally.
  local -a findargs=( -iname '*.log' )
  [[ "$INCLUDE_ROTATED" == true ]] && findargs+=( -o -iname '*.log.*' )
  if [[ "$INCLUDE_CRASH_REPORTS" == true ]]; then
    findargs+=( -o -iname '*.ips' -o -iname '*.crash' -o -iname '*.panic' -o -iname '*.diag' -o -iname '*.spin' )
  fi

  for src in "${LOG_SOURCES[@]}"; do
    [[ -d "$src" ]] || { logMe INFO "Source not found, skipping: $src"; continue; }
    logMe INFO "Scanning: $src"
    spin_status "$src" "$COPIED files collected"
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      # Size cap
      if (( maxbytes > 0 )); then
        szk=$(/usr/bin/stat -f%z "$f" 2>/dev/null)
        if [[ -n "$szk" ]] && (( szk > maxbytes )); then
          logMe INFO "Skipping (>${MAX_FILE_MB}MB): $f"
          (( SKIPPED_BIG++ )); continue
        fi
      fi
      dest="$STAGING/${f#/}"            # mirror the absolute path under staging (drop leading /)
      /bin/mkdir -p "${dest:h}" 2>/dev/null
      if /bin/cp -p "$f" "$dest" 2>/dev/null; then
        (( COPIED++ )); COLLECTED_PATHS+=("$f")
        (( COPIED % 25 == 0 )) && spin_status "$src" "$COPIED files collected"   # refresh the count
      fi
    done < <(/usr/bin/find "$src" -type f \( "${findargs[@]}" \) 2>/dev/null)
  done

  # A small device summary at the root of the bundle so IT can identify the machine.
  {
    print -r -- "Collected:    $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    print -r -- "User:         $targetUser"
    print -r -- "Computer:     $(/usr/sbin/scutil --get ComputerName 2>/dev/null)"
    print -r -- "Serial:       $(device_serial)"
    print -r -- "Model:        $(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    print -r -- "macOS:        $(/usr/bin/sw_vers -productName) $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    print -r -- "Uptime:       $(/usr/bin/uptime)"
    print -r -- ""
    print -r -- "Sources scanned:"
    for src in "${LOG_SOURCES[@]}"; do print -r -- "  - $src"; done
    print -r -- ""
    print -r -- "Files collected: ${COPIED}   (skipped over ${MAX_FILE_MB}MB: ${SKIPPED_BIG})"
    print -r -- "------------------------------------------------------------"
    for f in "${(@o)COLLECTED_PATHS}"; do print -r -- "$f"; done
  } > "$STAGING/_DEVICE_INFO.txt" 2>/dev/null
}

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Collect User Logs — mode=${ACTION_MODE}; user=${targetUser}; running as $(/usr/bin/id -un)"

if ! (( amRoot )); then
  logMe INFO "Not running as root — some protected logs in /var/log may be skipped (run via Jamf or with sudo)."
fi

# Build the destination zip path/name.
SERIAL="$(device_serial)"; [[ -z "$SERIAL" ]] && SERIAL="unknown"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
ZIP_NAME="${ZIP_NAME_PATTERN//\{USER\}/$targetUser}"
ZIP_NAME="${ZIP_NAME//\{SERIAL\}/$SERIAL}"
ZIP_NAME="${ZIP_NAME//\{STAMP\}/$STAMP}"
DESKTOP="$USER_HOME/Desktop"
[[ -d "$DESKTOP" ]] || DESKTOP="$USER_HOME"
ZIP_PATH="$DESKTOP/$ZIP_NAME"

# Name the staging folder after the bundle so the unzipped folder matches the zip name.
STAGING="$SCRATCH/${ZIP_NAME%.zip}"
/bin/mkdir -p "$STAGING"

# Collect (with a spinner in verbose mode).
spin_status "Preparing…" ""
show_spinner
collect_logs
logMe INFO "Copied $COPIED file(s); skipped $SKIPPED_BIG over ${MAX_FILE_MB}MB."

if (( COPIED == 0 )); then
  kill_spinner
  logMe ERROR "No log files were collected."
  show_message "$RESULT_FAIL_TITLE" "xmark.octagon.fill" "#FF3B30" "No log files could be collected. If this keeps happening, contact IT." ""
  exit 1
fi

# Zip the staging tree (ditto is built in; produces a standard .zip).
spin_status "Creating archive…" "$COPIED files"
logMe INFO "Creating archive: $ZIP_PATH"
if ! /usr/bin/ditto -c -k --norsrc --keepParent "$STAGING" "$ZIP_PATH" 2>/dev/null; then
  kill_spinner
  logMe ERROR "Failed to create archive at $ZIP_PATH"
  show_message "$RESULT_FAIL_TITLE" "xmark.octagon.fill" "#FF3B30" "Could not create the log archive on your Desktop. Contact IT for help." ""
  exit 1
fi

# Make sure the user owns the file on their own Desktop.
if (( amRoot )) && [[ -n "$consoleUID" ]]; then
  /usr/sbin/chown "$targetUser" "$ZIP_PATH" 2>/dev/null
fi

ZIP_SIZE="$(/usr/bin/du -h "$ZIP_PATH" 2>/dev/null | /usr/bin/awk '{print $1}')"
kill_spinner
logMe INFO "Done. Archive: $ZIP_PATH ($ZIP_SIZE, $COPIED files)."

# Reveal the file in Finder (verbose mode), then show the result window.
if [[ "$ACTION_MODE" == "verbose" ]]; then
  run_as_user /usr/bin/open -R "$ZIP_PATH" 2>/dev/null
fi
show_message "$RESULT_TITLE" "checkmark.seal.fill" "#34C759" "Collected $COPIED log file(s) ($ZIP_SIZE).\nSaved to your Desktop — attach it to your support ticket." "$ZIP_NAME"

exit 0
