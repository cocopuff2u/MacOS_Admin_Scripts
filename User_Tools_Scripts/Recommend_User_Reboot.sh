#!/bin/zsh

####################################################################################################
#
# Recommend User Reboot
#
# Purpose: Reminds the logged-in user to restart their Mac once it has been up longer than a set
#          number of days. Shows a branded, native reminder; if the user agrees, a live countdown
#          gives them time to save work before the Mac restarts. Skips the prompt when the user is
#          in a meeting / presentation / Focus (a display-sleep assertion is held).
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
#
# Jamf Script Parameters:
#   $4 - Uptime days before reminding   (number; blank = 21)
#   $5 - Countdown minutes before auto-restart after "Restart Now"   (number; blank = 10)
#   $6 - Dry run   ("dry"/"true" = show the dialogs but DO NOT restart, and ignore the uptime +
#                   meeting checks so the prompt always appears — for testing)
#
# How to set it up in Jamf Pro:
#   1. Settings > Computer Management > Scripts > New, and paste in this script.
#   2. On the Options tab, set these Parameter Labels (copy/paste):
#        Parameter 4:  Uptime days before reminding (blank = 21)
#        Parameter 5:  Countdown minutes before restart (blank = 10)
#        Parameter 6:  Dry run? (type: dry  to test without restarting)
#   3. Add the script to a Policy and fill in the values:
#        $4  e.g.  21        (remind once the Mac has been up 21+ days)
#        $5  e.g.  10        (10-minute save-your-work countdown)
#        $6  =====>  PRODUCTION: enter  false  (or leave blank AND change the DRY_RUN default
#                    in the config below from "dry" to "false"). Enter  dry  only for testing.
#                    ** This script DEFAULTS to dry, so it will NOT restart until you do this. **
#   4. Trigger: add to Self Service, or run on Recurring Check-in / a recurring schedule. A user
#      must be logged in — the prompt appears in their session.
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 8/29/23 - Original Release (JamfHelper / AppleScript) - @cocopuff2u
#
# 2.0 6/26/26 - Rebuilt on native JXA/AppKit: branded banner, restart icon, live countdown timer,
#               meeting/Focus skip, configurable banner colour — no dependencies - @cocopuff2u
#
####################################################################################################

# --- Config (Jamf $4 = uptime days, $5 = countdown minutes, $6 = dry run) --
UPTIME_DAYS="${4:-21}"             # remind once the Mac has been up this many days
RESTART_TIMER="${5:-10}"           # countdown minutes before auto-restart after "Restart Now"
DRY_RUN="${6:-dry}"              # dry/test mode — accepts "dry", "true", "1", or "yes" (any one of
                                   #   them shows the dialogs but does NOT restart, and bypasses the
                                   #   uptime + meeting checks so the prompt always appears).
                                   #   Leave blank / "false" / "no" for production. Default: dry.
bannerColor="#0056D2"              # banner bar colour (hex)
windowTitle="Restart Reminder"     # banner title
iconStyle="symbol"            # icon above the message: "selfservice" = the installed Self
                                   #   Service app's icon (falls back to the SF Symbol if none is
                                   #   found) | "symbol" = always use the SF Symbol below
restartIcon="arrow.triangle.2.circlepath"   # SF Symbol used when iconStyle="symbol" (or as fallback)
ignoreAssertionApps="Amphetamine,caffeinate" # apps that hold display-sleep but aren't meetings
logFile="/var/log/recommend_user_reboot.log"
# ---------------------------------------------------------------------------

####################################################################################################
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob

# Console user (so the GUI shows in their session even when run as root from Jamf)
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}

logMe() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}" | /usr/bin/tee -a "$logFile" 2>/dev/null || print -r -- "$2"; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }  # escape \ " and newlines for a JS string
bhex="${bannerColor#\#}"; br=$((16#${bhex[1,2]})); bg=$((16#${bhex[3,4]})); bb=$((16#${bhex[5,6]}))
isDry=0; [[ "${DRY_RUN:l}" == (dry|true|1|yes) ]] && isDry=1

# Resolve the reminder icon: an app bundle (Self Service) or an SF Symbol name.
ICON_KIND="symbol"; ICON_VALUE="$restartIcon"
if [[ "${iconStyle:l}" == "selfservice" ]]; then
  ssPath=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)
  if [[ -n "$ssPath" && -e "$ssPath" ]]; then
    ICON_KIND="app"; ICON_VALUE="$ssPath"
  else
    ss_candidates=(/Applications/*[Ss]elf*[Ss]ervice*.app(N))   # Self Service / Self Service+ / rebranded
    (( ${#ss_candidates} )) && { ICON_KIND="app"; ICON_VALUE="${ss_candidates[1]}"; }
  fi
fi

# True if an app is holding a display-sleep assertion (meeting / presentation / Focus).
# Adapted from Installomator. Apps in $ignoreAssertionApps are excluded.
hasDisplaySleepAssertion() {
  local apps
  apps="$(/usr/bin/pmset -g assertions | /usr/bin/awk \
    '/NoDisplaySleepAssertion | PreventUserIdleDisplaySleep/ && match($0,/\(.+\)/) && ! /coreaudiod/ \
     {gsub(/^.*\(/,"",$0); gsub(/\).*$/,"",$0); print}')"
  [[ -z "$apps" ]] && return 1
  local ignore=("${(@s/,/)ignoreAssertionApps}") app
  for app in ${(f)apps}; do
    if (( ! ${ignore[(Ie)$app]} )); then
      logMe INFO "Display-sleep assertion held by '$app' — skipping the reminder"
      return 0
    fi
  done
  return 1
}

# Reminder dialog. Prints RESTART or DEFER.
show_reminder() {  # $1 = message body
  local msg="$(as_esc "$1")" scpt="/tmp/reboot-reminder.$$.jxa"
  /bin/cat > "$scpt" <<EOF
ObjC.import('Cocoa');
ObjC.registerSubclass({name:'RRH',superclass:'NSObject',methods:{
 'yes:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});
function label(s,x,y,w,ht,sz,bold,al,sec){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=sec?\$.NSColor.secondaryLabelColor:\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.RRH.alloc.init;
var W=560,H=400,BH=72;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.level=3;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$(as_esc "$windowTitle")",20,H-BH+(BH-26)/2,W-40,26,18,true,1,false); tl.textColor=\$.NSColor.whiteColor; cv.addSubview(tl);
var iconKind="$ICON_KIND", iconVal="$(as_esc "$ICON_VALUE")";
var img=(iconKind=="app")?\$.NSWorkspace.sharedWorkspace.iconForFile(iconVal):\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(iconVal,\$());
var iSize=(iconKind=="app")?56:46;
var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-iSize)/2,H-BH-iSize-12,iSize,iSize));
iv.setImage(img); iv.imageScaling=3;
if(iconKind=="symbol") iv.contentTintColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);   // tint the symbol only
cv.addSubview(iv);
cv.addSubview(label("$msg",40,80,W-80,H-BH-150,13,false,1,false));
var bno=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-166,24,160,34)); bno.title="Not Now"; bno.bezelStyle=1; bno.target=h; bno.action='no:'; cv.addSubview(bno);
var byes=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,24,160,34)); byes.title="Restart Now"; byes.bezelStyle=1; byes.target=h; byes.action='yes:'; byes.keyEquivalent=\$('\r'); cv.addSubview(byes);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
(resp==1)?"RESTART":"DEFER";
EOF
  /bin/chmod 644 "$scpt"
  local out; out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/dev/null)"
  /bin/rm -f "$scpt"
  print -r -- "$out"
}

# Live countdown dialog. Blocks until the user clicks Restart Now or the timer expires.
show_countdown() {  # $1 = total seconds
  local secs="$1" scpt="/tmp/reboot-countdown.$$.jxa"
  /bin/cat > "$scpt" <<EOF
ObjC.import('Cocoa');
var remaining=$secs, label;
function fmt(s){var m=Math.floor(s/60),x=s%60;return m+":"+(x<10?"0":"")+x;}
ObjC.registerSubclass({name:'RCH',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(t){ remaining--; if(remaining<=0){\$.NSApplication.sharedApplication.stopModalWithCode(2);return;} label.setStringValue(\$('Restarting in '+fmt(remaining))); }},
 'now:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});
function label2(s,x,y,w,ht,sz,bold,al,sec){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=sec?\$.NSColor.secondaryLabelColor:\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.RCH.alloc.init;
var W=460,H=300,BH=72;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.level=3;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label2("$(as_esc "$windowTitle")",20,H-BH+(BH-26)/2,W-40,26,18,true,1,false); tl.textColor=\$.NSColor.whiteColor; cv.addSubview(tl);
label=label2('Restarting in '+fmt(remaining),20,H-BH-58,W-40,38,26,true,1,false); cv.addSubview(label);
cv.addSubview(label2("Save any open work now. Your Mac will restart when the timer reaches zero.",30,84,W-60,40,12,false,1,true));
var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect((W-170)/2,24,170,34)); b.title="Restart Now"; b.bezelStyle=1; b.target=h; b.action='now:'; b.keyEquivalent=\$('\r'); cv.addSubview(b);
var timer=\$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1,h,'tick:',\$(),true);
\$.NSRunLoop.currentRunLoop.addTimerForMode(timer,\$.NSModalPanelRunLoopMode);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
EOF
  /bin/chmod 644 "$scpt"
  run_as_user /usr/bin/osascript -l JavaScript "$scpt" >/dev/null 2>&1
  /bin/rm -f "$scpt"
}

####################################################################################################
# Main
####################################################################################################

logMe INFO "============================================================"
logMe INFO "Recommend User Reboot — threshold ${UPTIME_DAYS} day(s), user '${consoleUser:-none}'"
logMe INFO "Reminder icon: ${ICON_KIND} (${ICON_VALUE})"

# Uptime in whole days, from the kernel boot time. NOTE: parse the FIRST "sec ="
# field — a greedy match grabs "usec" instead. awk on { sec = N, usec = M } => $3.
bootEpoch=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F'[= ,]+' '{print $3}')
nowEpoch=$(/bin/date +%s)
uptimeDays=$(( (nowEpoch - bootEpoch) / 86400 ))
logMe INFO "Current uptime: ${uptimeDays} day(s)"

(( isDry )) && logMe INFO "[DRY RUN] Bypassing the uptime + meeting checks; the Mac will NOT restart."

# A logged-in GUI user is required either way (the prompt shows in their session).
if [[ -z "$consoleUser" ]]; then
  logMe INFO "No GUI user logged in — cannot prompt; exiting"; exit 0
fi

if (( ! isDry )); then
  if (( uptimeDays < UPTIME_DAYS )); then
    logMe INFO "Under the ${UPTIME_DAYS}-day threshold — nothing to do"; exit 0
  fi
  if hasDisplaySleepAssertion; then
    exit 0
  fi
fi

# Time-appropriate greeting + body
hour=$(/bin/date +%H)
case $hour in 0[0-9]|1[0-1]) greet="morning";; 1[2-7]) greet="afternoon";; *) greet="evening";; esac
firstName="$(/usr/bin/id -F "$consoleUser" 2>/dev/null | /usr/bin/awk '{print $1}')"
dayLabel="days"; (( uptimeDays == 1 )) && dayLabel="day"

body="Good ${greet}${firstName:+, $firstName}!

Your Mac hasn't been restarted in ${uptimeDays} ${dayLabel}. Regular restarts help keep it secure, up to date, and running smoothly — we recommend one at least every ${UPTIME_DAYS} days.

Choosing Restart Now gives you a ${RESTART_TIMER}-minute countdown to save your work before the Mac restarts. If now isn't a good time, choose Not Now and you'll be reminded later."

logMe INFO "Showing reminder (uptime ${uptimeDays} ${dayLabel})"
choice="$(show_reminder "$body")"

if [[ "$choice" != "RESTART" ]]; then
  logMe INFO "User deferred the restart"
  logMe INFO "============================================================"
  exit 0
fi

logMe INFO "User chose Restart Now — showing ${RESTART_TIMER}-minute countdown"
show_countdown $(( RESTART_TIMER * 60 ))

if (( isDry )); then
  logMe INFO "[DRY RUN] Countdown finished — restart SUPPRESSED."
else
  logMe INFO "Restarting now"
  run_as_user /usr/bin/osascript -e 'tell application "System Events" to restart' 2>/dev/null \
    || /sbin/shutdown -r now
fi
logMe INFO "============================================================"
exit 0
