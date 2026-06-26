#!/bin/zsh
#
####################################################################################################
#
# Self Service App Uninstaller
#
# Purpose: Fully uninstall a Mac app AND all the leftover files it leaves scattered around the
#          system — preferences, caches, containers, login items, support files, and installer
#          receipts — the way the "AppCleaner" utility does. Dragging an app to the Trash leaves
#          those orphaned files behind (often gigabytes); this finds everything tied to the app and
#          removes it in one step.
#
#          It is meant to be deployed as a Jamf Self Service item. The user clicks it, sees exactly
#          what will be removed in a checklist, and confirms — nothing is deleted without them
#          seeing it first.
#
# What the user sees (the flow):
#   1. If you DON'T specify an app, they get a list of installed apps (with icons) and pick one.
#      If you DO specify an app, it jumps straight to step 2 for that app.
#   2. A window shows the app's icon and every file/folder that will be removed, each pre-checked.
#      They uncheck anything they want to KEEP, then click "Remove Checked".
#   3. The app and the checked items are removed (the user's files go to the Trash and are
#      recoverable; system files are deleted). Clicking Cancel, closing the window, or unchecking
#      everything removes NOTHING.
#
# Safety (it won't let you break a machine):
#   - Apple's own system apps (com.apple.*) can NEVER be removed.
#   - A built-in PROTECTED list blocks your management / security tools (Jamf, SentinelOne,
#     GlobalProtect, Okta, ...). Edit PROTECTED_BUNDLE_IDS / PROTECTED_APP_NAMES in the config below.
#   - The user always reviews and confirms; a Cancel or an empty selection removes nothing.
#   - Dry-run mode shows the whole experience but deletes nothing — use it to test a policy safely.
#
# --------------------------------------------------------------------------------------------------
# HOW TO SET THIS UP IN JAMF PRO
# --------------------------------------------------------------------------------------------------
#   1. Settings > Computer Management > Scripts > New. Paste this entire script into the Script tab.
#   2. In the Options tab, set the Parameter Labels to EXACTLY these (copy/paste) — the label text
#      is self-documenting, so whoever fills in the policy knows what to enter:
#        Parameter 4 label:   App to remove — name, bundle id, or path (blank = let the user pick)
#        Parameter 5 label:   Dry run — enter "dry" to preview only (blank = actually remove)
#   3. Save. Then create a Policy, add this script to it, and fill in the two parameters:
#
#        Parameter 4  - App to remove
#            • Leave BLANK            -> the user is shown a list of installed apps and picks one.
#            • Or enter an app, any of:
#                 a display name      e.g.  Slack
#                 a bundle identifier e.g.  com.tinyspeck.slackmacgap
#                 a full path         e.g.  /Applications/Slack.app
#            (Alternatively, hardcode TARGET_APP in the config below for a dedicated per-app policy.)
#
#        Parameter 5  - Dry run?
#            • Leave BLANK            -> a real uninstall.
#            • Enter  dry             -> preview only: the dialogs appear but nothing is deleted
#                                        (use this to validate a new policy before going live).
#
#   4. Set the policy's Trigger to "Self Service" and add it to Self Service so users can run it on
#      demand. A user must be logged in at the screen — the window appears in their session.
# --------------------------------------------------------------------------------------------------
#
# CLI (for local testing only — here $1 is the target, since Jamf's first 3 parameters aren't sent):
#   sudo ./app-cleaner.sh "Slack"        # review, then remove
#   sudo ./app-cleaner.sh "Slack" dry    # review, then PREVIEW (nothing deleted)
#   sudo ./app-cleaner.sh                 # no target -> app picker, then review
#   sudo ./app-cleaner.sh -n "Slack"     # plain text dry run, no GUI (needs a target)
#
# Exit codes (for Jamf policy results):
#   NOTE: Jamf treats ANY non-zero exit as a FAILED policy. The routine "good" outcomes (removed,
#         dry run, user cancelled, nothing to do) all exit 0 so scheduled runs stay green.
#     0  - Success or no-op (items removed, dry run, user cancelled, or nothing matched)
#     1  - Failure: app could not be resolved, no bundle id, Apple/PROTECTED app refused, or one
#          or more items failed to remove
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 - 06/26/2026 - Initial release: two-tier scan (bundle-id/Team-ID + display name + pkg
#                    receipts), native AppKit checkbox review UI (osascript/JXA, Accessory app =
#                    hidden helper, scrollable, app icon + centered title), installed-app picker
#                    when $4 is blank, configurable protected-apps guard, $5=dry preview, Trash for
#                    user files / rm for system files, and pkgutil --forget - @cocopuff2u
#
####################################################################################################

# --- Target (Jamf $4 / first CLI arg overrides at runtime) ------------------
TARGET_APP=""                       # hardcode the app to remove (display name / bundle id / path)
                                    # for a dedicated per-app policy. Leave EMPTY to take it from
                                    # Jamf $4 — and if $4 is blank too, the user picks from a list.

# --- Test / dry-run override -----------------------------------------------
DRY_RUN_OVERRIDE=true              # true  = force a PREVIEW (show the dialogs, delete NOTHING),
                                    #         regardless of $5 — handy for testing by hand.
                                    # false = normal: $5="dry" previews, anything else removes.
                                    # MUST be false for production / Jamf.

# --- Behavior --------------------------------------------------------------
MIN_NAME_LEN=4                      # display names shorter than this skip the loose name match
LOG="/var/log/app-cleaner.log"      # action log; falls back to stdout only if not writable
FORGET_RECEIPTS=1                   # 1 = run `pkgutil --forget` for matched receipts after removal

# --- Interactive dialog appearance (ui / pick modes) -----------------------
DIALOG_WIDTH=720                    # window width  (px)
DIALOG_HEIGHT=600                   # window height (px); the list fills the space between the
                                    # header and buttons and scrolls when it overflows
BANNER_COLOR="#0056D2"              # coloured header-bar colour (hex)
BANNER_HEIGHT=72                    # header-bar height (px)
BANNER_TEXT_COLOR="#FFFFFF"         # title text colour shown on the banner
DIALOG_TITLE="Uninstall {APP}"      # banner title; {APP} -> the resolved app name
DIALOG_MESSAGE="Uncheck anything you want to KEEP, then click Remove."        # instruction line
DIALOG_WARNING="Review the list carefully — it may include items not related to {APP}."  # caution (orange)
DIALOG_NOTE="Checked items are moved to {USER}'s Trash — you can restore them if needed."  # reassurance (gray)
DIALOG_REMOVE_LABEL="Remove Checked"
DIALOG_CANCEL_LABEL="Cancel"
PICKER_TITLE="Uninstall an App"     # app-picker window (shown when the target is blank)
PICKER_MESSAGE="Select an app to remove, then click Continue."                       # instruction
PICKER_NOTE="You'll review exactly what gets removed before anything is deleted."    # reassurance (gray)
PICKER_ICON="trash"                 # SF Symbol shown above the list (tinted with BANNER_COLOR)
PICKER_CONTINUE_LABEL="Continue"

# --- Protected apps: NEVER uninstall these (fleet safety net) --------------
# All three lists are case-insensitive and checked against the app's bundle id and display name.
# Protected apps are BOTH hidden from the picker AND refused if targeted directly.
#   PROTECTED_BUNDLE_IDS      - matches the id OR any sub-id under it (e.g. "com.jamf.protect" also
#                               catches "com.jamf.protect.daemon", and GlobalProtect's ".client")
#   PROTECTED_APP_NAMES       - exact display-name match
#   PROTECTED_NAME_SUBSTRINGS - blocks anything whose name CONTAINS the phrase (e.g. "Self Service"
#                               blocks "Jamf Self Service", "<Company> Self Service", ...)
# Defaults cover a typical Jamf deployment's management tooling. Add your own
# (e.g. EDR/VPN/browsers) per environment.
PROTECTED_BUNDLE_IDS=(
    com.jamf.connect com.jamfsoftware.selfservice.mac
    com.jamf.setupmanager com.github.macadmins.Nudge
)
PROTECTED_APP_NAMES=( "Jamf Connect" "Nudge" "Setup Manager" )
PROTECTED_NAME_SUBSTRINGS=( "Self Service" )

####################################################################################################
# End of admin config — you shouldn't need to edit anything below this line.
####################################################################################################

# Shell setup: clean zsh baseline + the globbing options the file scan depends on.
# extended_glob enables the (N) glob qualifiers used throughout; null_glob makes a
# pattern that matches nothing expand to nothing; no_nomatch suppresses no-match errors.
emulate -L zsh
setopt no_nomatch null_glob extended_glob

# --- Logging ---------------------------------------------------------------
# Timestamped lines to both stdout (Jamf policy log) and $LOG when writable.
DRY_RUN=0
log() {
    local line="$(/bin/date '+%Y-%m-%d %H:%M:%S') $*"
    print -r -- "$line"
    { [[ -w "$LOG" ]] || [[ -w "${LOG:h}" ]] } && print -r -- "$line" >> "$LOG" 2>/dev/null
    return 0
}
die() { log "ERROR: $*"; exit 1; }   # any non-zero exit = FAILED policy in Jamf

# ---------------------------------------------------------------------------
# 0. Argument parsing (Jamf shifts $1-$3; CLI does not)
#    The checkbox review is always shown (it's the safety gate), so there is no
#    scope or run-mode parameter — just the target ($4) and a dry toggle ($5).
# ---------------------------------------------------------------------------
UI=1; PICK=0; FORCE_TEXT=0
# CLI convenience: -n = plain TEXT dry run (no GUI). Needs an explicit target.
[[ "$1" == "-n" || "$1" == "--dry-run" ]] && { DRY_RUN=1; FORCE_TEXT=1; UI=0; shift; }
# Jamf always passes mount point as $1 ("/"). Strip the standard trio.
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
TARGET="$1"
[[ -n "$TARGET_APP" ]] && TARGET="$TARGET_APP"   # a hardcoded config target wins over $4
[[ "${2:l}" == "dry" ]] && DRY_RUN=1             # $5 / 2nd CLI arg: "dry" = preview only
[[ "$DRY_RUN_OVERRIDE" == true ]] && DRY_RUN=1   # config toggle: force preview (testing by hand)
[[ -z "$TARGET" ]] && PICK=1                     # no target -> let the user pick from a list
(( FORCE_TEXT && PICK )) && die "Text mode (-n) needs a target app (the picker is GUI-only)."

# ---------------------------------------------------------------------------
# 1. Resolve the console user (we run as root but act on THEIR account)
# ---------------------------------------------------------------------------
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)"
if [[ -n "$JAMF_USER" && "$JAMF_USER" != "root" ]]; then USER_NAME="$JAMF_USER"
elif [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then USER_NAME="$CONSOLE_USER"
else USER_NAME="$(/usr/bin/id -un)"; fi
USER_UID="$(/usr/bin/id -u "$USER_NAME" 2>/dev/null)"
USER_HOME="$(/usr/bin/dscl . -read /Users/"$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -z "$USER_HOME" ]] && USER_HOME="/Users/$USER_NAME"
am_root=0; [[ "$(id -u)" == 0 ]] && am_root=1

# run a command in the console user's GUI context (for Finder/Trash/swiftDialog).
# As root -> drop into the user's GUI session; if we already ARE that user, run direct.
run_as_user() {
  if (( am_root )); then /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "$USER_NAME" "$@"
  else "$@"; fi
}

as_esc() { local s="${1//\\/\\\\}"; print -r -- "${s//\"/\\\"}"; }   # escape " and \ for JS
hex_rgb() { local h="${1#\#}"; print -r -- "$((16#${h[1,2]})) $((16#${h[3,4]})) $((16#${h[5,6]}))"; }  # "#RRGGBB" -> "R G B"

# is_protected <app-path> -> returns 0 (true) if the app is on any PROTECTED list.
# Bundle id matches the listed id OR any sub-id (".client"/".daemon"/...); names match
# exactly; substrings match anywhere. Case-insensitive. Used to hide protected apps from
# the picker AND to refuse a directly-targeted protected app.
is_protected() {
  local bid nm dn x
  bid="$(/usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  dn="$(/usr/bin/defaults read "$1/Contents/Info" CFBundleDisplayName 2>/dev/null)"
  bid="${bid:l}"; nm="${1:t:r:l}"; dn="${dn:l}"
  for x in $PROTECTED_BUNDLE_IDS;      do x="${x:l}"; [[ -n "$bid" && ( "$bid" == "$x" || "$bid" == "$x".* ) ]] && return 0; done
  for x in $PROTECTED_APP_NAMES;       do x="${x:l}"; [[ "$nm" == "$x" || ( -n "$dn" && "$dn" == "$x" ) ]] && return 0; done
  for x in $PROTECTED_NAME_SUBSTRINGS; do x="${x:l}"; [[ "$nm" == *"$x"* || ( -n "$dn" && "$dn" == *"$x"* ) ]] && return 0; done
  return 1
}

# Scanning spinner: a small borderless HUD shown (in its own background process so
# it animates) while the synchronous scan runs, then dismissed. Interactive only.
SPIN_SCPT="/tmp/app-cleaner-spin.$$.jxa"
show_spinner() {
  (( UI )) || return 0
  /bin/cat > "$SPIN_SCPT" <<EOF
ObjC.import('Cocoa');
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var W=320,H=116;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),0,2,false);
win.opaque=false; win.backgroundColor=\$.NSColor.clearColor; win.level=5; win.ignoresMouseEvents=true;
var cv=win.contentView;
var box=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,0,W,H));
box.boxType=4; box.borderWidth=0; box.titlePosition=0; box.cornerRadius=16;
box.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.16,0.16,0.18,0.92);  // always-dark HUD (readable in Light & Dark, like macOS system HUDs)
cv.addSubview(box);
var sp=\$.NSProgressIndicator.alloc.initWithFrame(\$.NSMakeRect((W-32)/2,H-56,32,32));
sp.style=1; sp.indeterminate=true; cv.addSubview(sp); sp.startAnimation(null);
var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(12,24,W-24,20));
t.stringValue="$(as_esc "Scanning ${APP_NAME}…")"; t.bezeled=false; t.editable=false; t.drawsBackground=false;
t.alignment=1; t.textColor=\$.NSColor.whiteColor; t.font=\$.NSFont.systemFontOfSize(13); cv.addSubview(t);
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
EOF
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; /bin/rm -f "$SPIN_SCPT"; return 0; }

# Review UI: native AppKit window via JXA (osascript) — centered app icon +
# title, then a scrollable list of real checkboxes (all checked = will remove).
# A custom NSWindow run with runModalForWindow is responsive (no freeze) and the
# scroll view caps height so title/buttons stay visible on any screen. 100%
# script: Jamf-deployable, no compiled app, no swiftDialog.
# Prints the still-checked paths on stdout, one per line.
# Exit: 0=confirmed (>=1 checked), 1=cancelled / nothing checked.
ui_confirm() {  # args: candidate paths
  local -a list; local p
  for p in "$@"; do [[ -e "$p" ]] && list+=("$p"); done
  (( ${#list} )) || return 1
  local js=""
  for p in $list; do js+="\"$(as_esc "$p")\","; done
  local title="${DIALOG_TITLE//\{APP\}/$APP_NAME}"
  local msg="${${DIALOG_MESSAGE//\{APP\}/$APP_NAME}//\{USER\}/$USER_NAME}"
  local warn="${${DIALOG_WARNING//\{APP\}/$APP_NAME}//\{USER\}/$USER_NAME}"
  local notetxt="${${DIALOG_NOTE//\{APP\}/$APP_NAME}//\{USER\}/$USER_NAME}"
  local bc=(${(s: :)$(hex_rgb "$BANNER_COLOR")}) tc=(${(s: :)$(hex_rgb "$BANNER_TEXT_COLOR")})
  local scpt="/tmp/app-cleaner.$$.jxa" out idx
  /bin/cat > "$scpt" <<EOF
ObjC.import('Cocoa');
var paths=[ $js ];
function label(s,x,y,w,h,sz,bold){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,h));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;
 t.alignment=1;t.textColor=\$.NSColor.labelColor;t.usesSingleLineMode=false;t.cell.wraps=true;t.cell.lineBreakMode=0;
 t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);  // 1=Accessory: no Dock icon, no menu-bar app menu
if(!\$.ACHandler){ObjC.registerSubclass({name:'ACHandler',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});}
var h=\$.ACHandler.alloc.init;
var W=$DIALOG_WIDTH,H=$DIALOG_HEIGHT;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true;win.titleVisibility=1;win.movableByWindowBackground=true;  // banner reaches the very top
var cv=win.contentView;
var BH=$BANNER_HEIGHT;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4;banner.borderWidth=0;banner.titlePosition=0;   // solid colour bar (NSColor, not CGColor -> no JXA crash)
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(${bc[1]}/255,${bc[2]}/255,${bc[3]}/255,1);
cv.addSubview(banner);
var tl=label("$(as_esc "$title")",20,H-BH+(BH-26)/2,W-40,26,18,true);
tl.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(${tc[1]}/255,${tc[2]}/255,${tc[3]}/255,1);cv.addSubview(tl);
var icon=\$.NSWorkspace.sharedWorkspace.iconForFile("$(as_esc "$APP_PATH")");
var BB=H-BH, IS=60, iy=BB-10-IS;
var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-IS)/2,iy,IS,IS));
iv.setImage(icon);iv.imageScaling=3;cv.addSubview(iv);
cv.addSubview(label("$(as_esc "$msg")",40,iy-28,W-80,20,13,false));            // instruction
var wn=label("$(as_esc "$warn")",30,iy-50,W-60,18,12,false);wn.textColor=\$.NSColor.systemOrangeColor;cv.addSubview(wn);   // caution
var nt=label("$(as_esc "$notetxt")",40,iy-70,W-80,16,11,false);nt.textColor=\$.NSColor.secondaryLabelColor;cv.addSubview(nt);  // trash note
var LH=iy-154;   // list fills from y=70 up to just below the note block
var rowH=22,sw=W-60,docH=Math.max(paths.length*rowH,LH);
var doc=\$.NSView.alloc.initWithFrame(\$.NSMakeRect(0,0,sw,docH));
var boxes=[];
for(var i=0;i<paths.length;i++){var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(4,docH-(i+1)*rowH,sw-8,rowH));
 b.setButtonType(3);b.title=paths[i];b.state=1;doc.addSubview(b);boxes.push(b);}
var sv=\$.NSScrollView.alloc.initWithFrame(\$.NSMakeRect(30,70,sw,LH));
sv.hasVerticalScroller=true;sv.borderType=1;sv.setDocumentView(doc);doc.scrollPoint(\$.NSMakePoint(0,docH));cv.addSubview(sv);
var bc=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-176,20,170,32));
bc.title="$(as_esc "$DIALOG_CANCEL_LABEL")";bc.bezelStyle=1;bc.target=h;bc.action='no:';cv.addSubview(bc);
var br=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,20,170,32));
br.title="$(as_esc "$DIALOG_REMOVE_LABEL")";br.bezelStyle=1;br.target=h;br.action='ok:';br.keyEquivalent=\$('\r');cv.addSubview(br);
win.center;win.makeKeyAndOrderFront(null);app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win);win.orderOut(null);
if(resp==1){var o=[];for(var i=0;i<boxes.length;i++){if(ObjC.unwrap(boxes[i].state)==1)o.push(i);}o.join(',');}else '__CANCEL__';
EOF
  /bin/chmod 644 "$scpt"
  if [[ -n "$AC_DEBUG" ]]; then
    /bin/cp "$scpt" /tmp/ac-last.jxa
    out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/tmp/ac-err.log)"
  else
    out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/dev/null)"
  fi
  /bin/rm -f "$scpt"
  [[ "$out" == "__CANCEL__" || -z "$out" ]] && return 1
  for idx in ${(s:,:)out}; do print -r -- "$list[$((idx+1))]"; done   # JS 0-based -> zsh 1-based
  return 0
}

# App picker: scrollable list of /Applications with real icons (radio single-
# select). Prints the chosen .app path on stdout. Exit 0=picked, 1=cancelled.
pick_app() {
  local -a apps; local a bid
  for a in /Applications/*.app(N) /Applications/Utilities/*.app(N); do
    bid="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    if [[ "${bid:l}" == com.apple.* ]]; then log "picker: skip Apple     ${a:t:r} [$bid]"; continue; fi
    if is_protected "$a";            then log "picker: skip protected ${a:t:r} [$bid]"; continue; fi
    apps+=("$a"); log "picker: list ${a:t:r} [${bid:-no-bundle-id}]"
  done
  log "picker: offering ${#apps} app(s)."
  (( ${#apps} )) || return 1
  local js=""
  for a in $apps; do js+="\"$(as_esc "$a")\","; done
  local bc=(${(s: :)$(hex_rgb "$BANNER_COLOR")}) tc=(${(s: :)$(hex_rgb "$BANNER_TEXT_COLOR")})
  local scpt="/tmp/app-cleaner-pick.$$.jxa" out idx
  /bin/cat > "$scpt" <<EOF
ObjC.import('Cocoa');
var apps=[ $js ];
function label(s,x,y,w,h,sz,bold){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,h));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;
 t.alignment=1;t.textColor=\$.NSColor.labelColor;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);  // 1=Accessory: no Dock icon, no menu-bar app menu
if(!\$.ACPick){ObjC.registerSubclass({name:'ACPick',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'sel:':{types:['void',['id']],implementation:function(s){}}}});}
var h=\$.ACPick.alloc.init;
var W=$DIALOG_WIDTH,H=$DIALOG_HEIGHT;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true;win.titleVisibility=1;win.movableByWindowBackground=true;  // banner reaches the very top
var cv=win.contentView;
var BH=$BANNER_HEIGHT;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4;banner.borderWidth=0;banner.titlePosition=0;   // solid colour bar (NSColor, not CGColor -> no JXA crash)
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(${bc[1]}/255,${bc[2]}/255,${bc[3]}/255,1);
cv.addSubview(banner);
var tl=label("$(as_esc "$PICKER_TITLE")",20,H-BH+(BH-26)/2,W-40,26,18,true);
tl.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(${tc[1]}/255,${tc[2]}/255,${tc[3]}/255,1);cv.addSubview(tl);
var BB=H-BH, IS=54, iy=BB-12-IS;
var sym=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("$PICKER_ICON",\$());
var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-IS)/2,iy,IS,IS));
iv.setImage(sym);iv.imageScaling=3;iv.contentTintColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha(${bc[1]}/255,${bc[2]}/255,${bc[3]}/255,1);cv.addSubview(iv);
cv.addSubview(label("$(as_esc "$PICKER_MESSAGE")",40,iy-30,W-80,20,13,false));
var pn=label("$(as_esc "$PICKER_NOTE")",40,iy-50,W-80,16,11,false);pn.textColor=\$.NSColor.secondaryLabelColor;cv.addSubview(pn);
var ws=\$.NSWorkspace.sharedWorkspace,rowH=40,sw=W-60,pLH=iy-134,docH=Math.max(apps.length*rowH,pLH);
var doc=\$.NSView.alloc.initWithFrame(\$.NSMakeRect(0,0,sw,docH));
var btns=[];
for(var i=0;i<apps.length;i++){
 var y=docH-(i+1)*rowH;
 var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(8,y,sw-16,rowH));
 b.setButtonType(4);               // radio
 b.target=h; b.action='sel:';      // shared action -> AppKit radio-groups them (single select)
 var nm=ObjC.unwrap(\$(apps[i]).lastPathComponent); nm=nm.replace(/\.app$/,'');
 b.title="        "+nm;            // leading space leaves room for the icon
 b.font=\$.NSFont.systemFontOfSize(13);
 b.state=(i==0)?1:0; doc.addSubview(b);
 var ic=ws.iconForFile(apps[i]); ic.setSize(\$.NSMakeSize(24,24));   // icon as a SEPARATE view so the radio circle stays
 var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect(30,y+(rowH-24)/2,24,24));
 iv.setImage(ic); iv.imageScaling=3; doc.addSubview(iv);
 btns.push(b);
}
var sv=\$.NSScrollView.alloc.initWithFrame(\$.NSMakeRect(30,70,sw,pLH));
sv.hasVerticalScroller=true;sv.borderType=1;sv.setDocumentView(doc);doc.scrollPoint(\$.NSMakePoint(0,docH));cv.addSubview(sv);
var bc=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-176,20,170,32));
bc.title="$(as_esc "$DIALOG_CANCEL_LABEL")";bc.bezelStyle=1;bc.target=h;bc.action='no:';cv.addSubview(bc);
var br=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,20,170,32));
br.title="$(as_esc "$PICKER_CONTINUE_LABEL")";br.bezelStyle=1;br.target=h;br.action='ok:';br.keyEquivalent=\$('\r');cv.addSubview(br);
win.center;win.makeKeyAndOrderFront(null);app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win);win.orderOut(null);
if(resp==1){var pick=-1;for(var i=0;i<btns.length;i++){if(ObjC.unwrap(btns[i].state)==1){pick=i;break;}}(pick>=0)?String(pick):'__CANCEL__';}else '__CANCEL__';
EOF
  /bin/chmod 644 "$scpt"
  if [[ -n "$AC_DEBUG" ]]; then
    /bin/cp "$scpt" /tmp/ac-pick.jxa
    out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/tmp/ac-pick-err.log)"
  else
    out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/dev/null)"
  fi
  /bin/rm -f "$scpt"
  [[ "$out" == "__CANCEL__" || -z "$out" || "$out" != <-> ]] && return 1
  PICKED="$apps[$((out+1))]"   # set a global (not stdout) so log lines above don't pollute it
  return 0
}

# ---------------------------------------------------------------------------
# 2. Resolve the target .app by path, bundle dir name, or display name
# ---------------------------------------------------------------------------
resolve_app() {
  local arg="$1" low="${1:l}" a nm dn
  # explicit bundle path wins outright
  if [[ -d "$arg" && "$arg" == *.app ]]; then print -r -- "${arg:A}"; return 0; fi
  # otherwise match real directory entries only (avoids case-insensitive-FS dupes)
  typeset -aU found
  for a in /Applications/*.app(N) /Applications/Utilities/*.app(N) "$USER_HOME"/Applications/*.app(N); do
    if [[ "${a:t:r:l}" == "$low" ]]; then found+=("$a"); continue; fi
    nm="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleName 2>/dev/null)"
    dn="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleDisplayName 2>/dev/null)"
    [[ "${nm:l}" == "$low" || "${dn:l}" == "$low" ]] && found+=("$a")
  done
  case ${#found} in
    0) return 1 ;;
    1) print -r -- "${found[1]}"; return 0 ;;
    *) log "Ambiguous target '$arg' matches: ${found}"; return 2 ;;
  esac
}

# If pick mode, let the user choose the app first (sets TARGET).
if (( PICK )); then
  pick_app || { log "User cancelled the app picker. Nothing removed."; exit 0; }
  TARGET="$PICKED"
  log "User picked: $TARGET"
fi

APP_PATH="$(resolve_app "$TARGET")" || die "Could not uniquely resolve app: '$TARGET'"
APP_NAME="${APP_PATH:t:r}"
INFO="$APP_PATH/Contents/Info"
BUNDLE_ID="$(/usr/bin/defaults read "$INFO" CFBundleIdentifier 2>/dev/null)"
DISP_NAME="$(/usr/bin/defaults read "$INFO" CFBundleDisplayName 2>/dev/null)"
[[ -z "$DISP_NAME" ]] && DISP_NAME="$(/usr/bin/defaults read "$INFO" CFBundleName 2>/dev/null)"
TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/awk -F'= ' '/TeamIdentifier/{print $2}')"
[[ "$TEAM_ID" == "not set" ]] && TEAM_ID=""

[[ -z "$BUNDLE_ID" ]] && die "No bundle id in $APP_PATH."
[[ "$BUNDLE_ID" == com.apple.* ]] && die "Refusing Apple system bundle id ($BUNDLE_ID)."

# Protected-apps guard: never uninstall management/security tooling (also hidden from the picker).
is_protected "$APP_PATH" && die "PROTECTED app — refusing to remove $APP_NAME ($BUNDLE_ID)."

typeset -aU NAME_TOKENS
for t in "$APP_NAME" "$DISP_NAME"; do
  [[ -n "$t" && ${#t} -ge $MIN_NAME_LEN ]] && NAME_TOKENS+=("${t:l}")
done

log "=== app-cleaner start ==="
log "Target='$TARGET' -> $APP_PATH"
log "BundleID=$BUNDLE_ID  Team=${TEAM_ID:-none}  User=$USER_NAME ($USER_UID)  Home=$USER_HOME"
log "Dry=$DRY_RUN  Interactive=$UI  NameTokens=${NAME_TOKENS:-<disabled>}"

show_spinner   # brief "Scanning …" HUD while the sweep below runs (interactive only)

# ---------------------------------------------------------------------------
# 3. Build match lists
# ---------------------------------------------------------------------------
libsubs=(
  "Application Support" "Application Scripts" "Containers" "Group Containers"
  "Caches" "Caches/Metadata" "HTTPStorages" "Preferences" "Saved Application State"
  "WebKit" "Cookies" "Logs" "LaunchAgents" "Internet Plug-Ins" "PreferencePanes"
  "QuickLook" "Services" "Spotlight" "Frameworks" "Extensions" "StartupItems"
  "Widgets" "Address Book Plug-Ins" "Mail" "Screen Savers" "Audio"
  "Autosave Information" "ColorPickers" "Components" "Input Methods"
  "Keyboard Layouts" "PDF Services" "Printers" "ScriptingAdditions" "Scripts"
  "Sounds" "SyncedPreferences" "Receipts"
)
roots=( "$USER_HOME/Library" "/Library" )
sysonly=( "/Library/LaunchDaemons" "/Library/PrivilegedHelperTools" "/private/var/db/receipts" )

classify() {
  local name="${1:t}" low="${1:t:l}"
  if   [[ "$name" == "$BUNDLE_ID" ]]; then echo high; return
  elif [[ "$name" == "$BUNDLE_ID".* || "$name" == "$BUNDLE_ID"-* ]]; then echo high; return
  elif [[ "$name" == *".$BUNDLE_ID" || "$name" == *".$BUNDLE_ID."* ]]; then echo high; return
  elif [[ -n "$TEAM_ID" && "$name" == "$TEAM_ID".* && "$name" == *"$BUNDLE_ID"* ]]; then echo high; return
  fi
  local tok
  for tok in $NAME_TOKENS; do [[ "$low" == *"$tok"* ]] && { echo review; return; }; done
  echo ""
}

typeset -aU high_hits review_hits
high_hits=("$APP_PATH")
scan_dir() {
  local dir="$1" child v
  [[ -d "$dir" ]] || return
  for child in "$dir"/*(N); do
    v="$(classify "$child")"
    [[ "$v" == high   ]] && high_hits+=("$child")
    [[ "$v" == review ]] && review_hits+=("$child")
  done
}
for r in $roots; do for s in $libsubs; do scan_dir "$r/$s"; done; done
for d in $sysonly; do scan_dir "$d"; done

# Receipts
typeset -aU receipt_pkgs receipt_files
for pkg in ${(f)"$(/usr/sbin/pkgutil --pkgs 2>/dev/null)"}; do
  plow="${pkg:l}"; match=0
  [[ "$plow" == *"${BUNDLE_ID:l}"* ]] && match=1
  if (( ! match )); then for tok in $NAME_TOKENS; do [[ "$plow" == *"$tok"* ]] && { match=1; break; }; done; fi
  (( match )) || continue
  receipt_pkgs+=("$pkg")
  info="$(/usr/sbin/pkgutil --pkg-info "$pkg" 2>/dev/null)"
  vol="$(print -r -- "$info" | /usr/bin/awk -F': ' '/volume:/{print $2}')"; [[ -z "$vol" ]] && vol="/"
  loc="$(print -r -- "$info" | /usr/bin/awk -F': ' '/location:/{print $2}')"
  for f in ${(f)"$(/usr/sbin/pkgutil --files "$pkg" --only-files 2>/dev/null)"}; do
    full="${vol%/}/${loc:+${loc#/}/}$f"; keep=0
    [[ -e "$full" ]] || continue
    [[ "$full" == "$APP_PATH"/* ]] && continue
    flow="${full:l}"
    [[ "$flow" == *"${BUNDLE_ID:l}"* ]] && keep=1
    if (( ! keep )); then for tok in $NAME_TOKENS; do [[ "$flow" == *"$tok"* ]] && { keep=1; break; }; done; fi
    (( keep )) && receipt_files+=("$full")
  done
done
typeset -A _seen
for m in $high_hits $review_hits; do _seen[$m]=1; done
for f in $receipt_files; do [[ -n "${_seen[$f]}" ]] || { review_hits+=("$f"); _seen[$f]=1; }; done

# ---------------------------------------------------------------------------
# 4. Report + assemble the full target set
#    The review (or dry run) is the filter, so always present everything:
#    HIGH (anchored) plus REVIEW (loose name / receipt) matches.
# ---------------------------------------------------------------------------
typeset -a targets
targets=($high_hits $review_hits)

log "--- HIGH confidence (${#high_hits}) ---"
for m in $high_hits; do log "  [H] $m"; done
log "--- REVIEW name/receipt (${#review_hits}) ---"
for m in $review_hits; do log "  [R] $m"; done
(( ${#receipt_pkgs} )) && log "--- receipts to forget: ${receipt_pkgs} ---"

kill_spinner   # scan done — dismiss the HUD before the review window

(( ${#targets} )) || { log "Nothing to remove."; exit 0; }

# 4b. UI review: scrollable, clickable list. User deselects anything to keep.
# Runs in dry mode too, as a live preview — nothing is deleted afterward.
if (( UI )); then
  log "Presenting review list of ${#targets} item(s) to $USER_NAME ..."
  ui_out="$(ui_confirm $targets)"; ui_rc=$?
  if (( ui_rc != 0 )); then log "User cancelled (or kept everything). Nothing removed."; exit 0; fi
  targets=(${(f)ui_out})
  (( ${#targets} )) || { log "Nothing selected. Nothing removed."; exit 0; }
  log "User confirmed ${#targets} item(s) for removal."
fi

if (( DRY_RUN )); then
  log "DRY RUN — nothing changed. Would remove ${#targets} item(s):"
  for m in $targets; do log "  would remove: $m"; done
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Quit app + unload launchd jobs among the targets
# ---------------------------------------------------------------------------
log "Quitting $APP_NAME ..."
run_as_user /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
/usr/bin/pkill -i -f "$APP_PATH" 2>/dev/null
for m in $targets; do
  case "$m" in
    /Library/LaunchDaemons/*.plist) /bin/launchctl bootout system "$m" 2>/dev/null ;;
    */LaunchAgents/*.plist) (( am_root )) && /bin/launchctl bootout gui/"$USER_UID" "$m" 2>/dev/null ;;
  esac
done

# ---------------------------------------------------------------------------
# 6. Remove: user files -> Trash (recoverable); system files -> rm -rf
# ---------------------------------------------------------------------------
fail=0
USER_TRASH="$USER_HOME/.Trash"
[[ -d "$USER_TRASH" ]] || /bin/mkdir -p "$USER_TRASH" 2>/dev/null

# Move an item into the console user's Trash, owned by them. Uses mv + chown (NOT
# Finder Apple Events, which TCC blocks from a Jamf/root context), so it works
# headless. Recoverable from the Trash; "Put Back" won't be available. 0=ok 1=fail.
trash_item() {   # sets TRASH_DEST to the exact path it landed at; 0=ok 1=fail
  local item="$1" base="${1:t}"
  TRASH_DEST="$USER_TRASH/${1:t}"
  [[ -e "$TRASH_DEST" ]] && TRASH_DEST="$USER_TRASH/${base:r}-$EPOCHSECONDS.${base:e}"   # avoid clobber
  /bin/mv -f "$item" "$TRASH_DEST" 2>/dev/null || return 1
  /usr/sbin/chown -R "$USER_NAME":staff "$TRASH_DEST" 2>/dev/null
  [[ -e "$TRASH_DEST" ]]
}

for m in $targets; do
  [[ -e "$m" ]] || continue
  case "$m" in
    "$USER_HOME"/*|/Applications/*)   # user files + the app bundle -> user's Trash (recoverable)
      if trash_item "$m"; then log "  trashed: $m  ->  $TRASH_DEST"
      else log "  trash failed, removing instead: $m"
           /bin/rm -rf "$m" 2>/dev/null && log "  removed: $m" || { log "  FAILED: $m"; ((fail++)); }
      fi ;;
    *)                                # system / root-owned (/Library, receipts) -> delete
      if /bin/rm -rf "$m" 2>/dev/null; then log "  removed (system): $m"; else log "  FAILED remove: $m"; ((fail++)); fi ;;
  esac
done

# forget receipts (we're root under Jamf)
for pkg in $receipt_pkgs; do /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 && log "  forgot receipt: $pkg"; done

log "=== done: removed up to ${#targets} item(s), $fail failure(s) ==="
(( fail )) && exit 1 || exit 0
