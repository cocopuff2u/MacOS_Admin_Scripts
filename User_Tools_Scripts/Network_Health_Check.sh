#!/bin/zsh

####################################################################################################
#
# Network Health Check
#
# Purpose: Runs a network check on the Mac and shows the user an easy-to-read results window, plus
#          gives IT the details needed to actually figure out what's wrong. It looks at:
#            • Responsiveness - how laggy the connection is (latency, jitter, packet loss) to
#                               1.1.1.1 and 8.8.8.8. It also checks the router on its own, so it
#                               can tell if the problem is the user's Wi-Fi/router or their ISP.
#            • Reliability    - did the connection drop out during the test? Quick blips are
#                               ignored, only real drop-outs count.
#            • Speed          - download, upload, and how much the lag gets worse when the
#                               connection is busy (bufferbloat).
#            • Web & DNS      - how fast common sites start loading, and how fast each DNS server
#                               answers.
#            • Wi-Fi          - signal strength, noise, channel, link speed, and how crowded the
#                               channel is.
#            • History        - how many times the connection dropped in the last 24 hours while the
#                               Mac was awake (read from the Mac's own logs).
#            • Other apps     - what else was using the network during the test (iCloud, OneDrive...).
#          All of that turns into a 0-100 Network Score (90+ Excellent, 80 Good, 70 Okay, 50 Fair,
#          under 50 Poor), a "ready for video calls?" answer, and a short list of what's wrong in
#          plain English. Below that is a "For IT" section with the nerdy stuff: MDM enrollment and
#          whether it can reach the MDM server and Apple Push, VPN apps and the VPN server, traceroute,
#          DNS timings, proxy info, MTU, IPv6, clock offset, DHCP, etc. The Save Report button drops
#          a text file on the user's Desktop they can attach to a ticket.
#
# Note: No swiftDialog or JamfHelper needed. The windows are built with osascript (JXA) + AppKit and
#       show up in the logged-in user's session, so it works fine when Jamf runs it as root.
#       Running as root also unlocks a few extra Wi-Fi details (network name, access point, MCS,
#       channel utilization) and TCP retransmit stats.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service (the user clicks it, watches it run, reads the results, can save a report):
#     • Leave the script as-is (HEADLESS=false). Set Jamf Parameter 4 to "verbose" or leave it blank.
#
#   Headless / automated (no windows, the report just goes to the policy log + $logFile):
#     • Set Jamf Parameter 4 to "silent"  (OR set HEADLESS=true in the Config block below).
#
# JAMF SCRIPT PARAMETERS - on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose or silent)
#   Parameter 5 Label:  Speed Test (apple, cloudflare, or off)
#   Parameter 6 Label:  Test Duration in seconds, or "quick" (blank = 20)
#   Parameter 7 Label:  Simulate Scenario (testing only - leave blank)
#
#   When you add this script to a policy, fill the parameters in like this:
#     $4  Action Mode        verbose = show the progress + results windows (default)
#                            silent  = no windows, the report goes to the policy log
#     $5  Speed Test         apple      = Apple's built-in networkQuality test (default)
#                            cloudflare = speed.cloudflare.com instead
#                            off        = skip the speed test
#     $6  Test Duration      how many seconds to ping for. Blank = TEST_SECONDS below.
#                            quick = 5 second ping and no speed test (about 15 seconds total)
#     $7  Simulate Scenario  Leave this BLANK for real use. Put a scenario name in here (like
#                            weak-wifi or no-internet) and it fakes the results so you can see
#                            what a user would see. See SIMULATE below for the full list.
# ---------------------------------------------------------------------------------------------
#
# TESTING (from Terminal, $1..$4 line up with Jamf's $4..$7):
#   ./Network_Health_Check.sh                          # normal run
#   ./Network_Health_Check.sh verbose off quick        # quick check, no speed test
#   NHC_SIMULATE=weak-wifi ./Network_Health_Check.sh   # fake a bad network (NHC_SIMULATE=list shows them all)
#   NHC_DEBUG=1 ./Network_Health_Check.sh              # keeps the temp files in /tmp/network-health-check.<pid>
#   sudo ./Network_Health_Check.sh silent              # everything, including the root-only Wi-Fi/TCP stuff
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 9/24/26 - Original Release - Tests responsiveness (router vs internet), reliability, speed and
#               bufferbloat, web + DNS timing, and Wi-Fi. 0-100 score, video call check, plain-English
#               findings, "For IT" details, live progress window with a Cancel button, results window
#               with Save Report / Run Again, verbose/silent/quick modes, simulated scenarios for
#               testing, step timings, and optional JSON results. - @cocopuff2u
# 1.1 9/24/26 - Testing + fixes (in progress) - Accuracy fixes: traceroute hops use every reply,
#               your own DNS servers are labeled right, shows the private Wi-Fi MAC and the hardware
#               MAC, VPN status reads right, accurate nearby access point count, Wi-Fi readings don't
#               get cut off, a failed website gets one retry, and packet loss that only one server
#               shows (usually that server limiting ping) no longer counts against the connection.
#               New: connection drops from the last 24 hours (skips the ones caused by sleep), which
#               apps are using the network, MDM detection (Jamf, Intune, Kandji, etc.) with checks it
#               can reach the MDM server and Apple Push, and full VPN details for built-in VPNs and VPN
#               apps (type, tunnel, full vs split, gateway, server, DNS) - tested live with an L2TP VPN
#               and ProtonVPN/WireGuard. Clearer labels, a legend in the report, and a faster path MTU
#               check. New test scenarios: wifi-drops, bandwidth-hog, mdm-unreachable. - @cocopuff2u
#
####################################################################################################

# --- Config - change these to fit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # false = do whatever Jamf Parameter 4 says (verbose or silent).
                        # true  = ALWAYS run silently with no windows, no matter what $4 says.

# RESPONSIVENESS + RELIABILITY ----------------------------------------------
TEST_SECONDS=20         # how long to ping for (Jamf $6 overrides this). Longer = better drop-out data.
PING_INTERVAL=0.5       # how often to ping, in seconds
INTERNET_TARGETS=(      # what we ping. These are "anycast", so every Mac hits the closest server
    "1.1.1.1"           # no matter what country it's in.
    "8.8.8.8"
)
HTTPS_FALLBACK_TARGETS=(   # only used if ping is blocked on the network - we time an HTTPS connection instead
    "https://speed.cloudflare.com"
    "https://www.google.com"
)
OUTAGE_MIN_LOST=3       # how many pings in a row have to go missing (on EVERY target) before we call it
                        # a drop-out. One or two missing pings is just a blip and gets ignored.

# SPEED ---------------------------------------------------------------------
SPEED_ENGINE="apple"    # apple      = Apple's built-in networkQuality (also measures bufferbloat)
                        # cloudflare = speed.cloudflare.com
                        # off        = skip it        (Jamf $5 overrides this)
SPEED_MAX_SECONDS=15    # longest the speed test is allowed to run
CF_DOWN_BYTES=25000000  # cloudflare only: how much to download (bytes)
CF_UP_BYTES=10000000    # cloudflare only: how much to upload (bytes)

# WEBSITES + DNS ------------------------------------------------------------
WEB_TARGETS=(           # sites we time. Swap in whatever your users actually live in (Okta, Slack, etc.)
    "https://www.google.com"
    "https://www.apple.com"
    "https://www.microsoft.com"
    "https://login.microsoftonline.com"
    "https://www.cloudflare.com"
    "https://zoom.us"
    "https://teams.microsoft.com"
)
DNS_TEST_DOMAINS=(      # names we look up on each DNS server (the Mac's own + 1.1.1.1 + 8.8.8.8)
    "apple.com"
    "microsoft.com"
    "google.com"
)

# CONNECTION INFO -----------------------------------------------------------
PUBLIC_IP_LOOKUP_URL="https://ipinfo.io/json"   # used to show the public IP, ISP, and city. Blank = skip it.

# REPORT --------------------------------------------------------------------
# "Save Report" puts a text file on the user's Desktop. These get swapped out in the name:
#   {USER} = username   {SERIAL} = serial number   {STAMP} = date and time (YYYYMMDD-HHMMSS)
REPORT_NAME_PATTERN="NetworkHealth_{USER}_{SERIAL}_{STAMP}.txt"
logFile="/var/log/network_health_check.log"      # where this script logs what it did

# TESTING -------------------------------------------------------------------
QUICK_MODE=false        # true = quick check: 5 second ping and no speed test (about 15 seconds total).
                        # Setting Jamf $6 to "quick" (or NHC_QUICK=1 in Terminal) does the same thing.
SIMULATE=""             # Leave blank for a real test. Put a scenario name here and the script FAKES the
                        # results so you can see what users would see, without messing with the network.
                        # Jamf $7 or NHC_SIMULATE override this. You can combine them (weak-wifi,vpn).
                        # "list" prints them all. The scenarios are:
                        #   healthy  not-connected  no-internet  captive-portal  packet-loss  outage
                        #   ping-blocked  slow-dns  bufferbloat  slow-speed  weak-wifi  2ghz  vpn
                        #   broken-ipv6  router-bottleneck  isp-problem  clock-skew  proxy
                        #   slow-ethernet  wifi-drops  bandwidth-hog  mdm-unreachable  all-bad

# RESULTS FILE (optional) ---------------------------------------------------
SAVE_JSON=false                            # true = also save the results as JSON (has to run as root):
JSON_DIR="/Library/Management/NetworkHealth"   #   last.json     = the most recent run
JSON_HISTORY_MAX=500                       #   history.jsonl = one line per run, keeps the last 500

# LOOK OF THE WINDOWS (verbose mode only) -----------------------------------
bannerColor="#0056D2"                      # banner color (hex)
BANNER_TEXT_COLOR="#FFFFFF"                # banner text color (hex)
SPINNER_TEXT="Checking your network…"
RESULT_TITLE="Network Health Check"
SUPPORT_NOTE="Having trouble? Click Save Report and attach it to your IT ticket."
SAVED_TITLE="Report Saved"
okButton="Done"
againButton="Run Again"
saveButton="Save Report"
cancelButton="Cancel"                      # button on the progress window that stops the test
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob
zmodload zsh/datetime   # EPOCHREALTIME / EPOCHSECONDS

# A temp folder for this run (ping output, results, the window scripts). It gets deleted at the end.
SCRATCH="/tmp/network-health-check.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
# Kills everything this script started in the background (pings, traceroute, speed test, windows).
# It walks down the whole process tree, because some pings are children of children.
kill_tree() { local c; for c in $(/usr/bin/pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
stop_children() { local c; for c in $(/usr/bin/pgrep -P $$ 2>/dev/null); do kill_tree "$c"; done; }
trap 'stop_children; [[ -n "$NHC_DEBUG" ]] || /bin/rm -rf "$SCRATCH"' EXIT INT TERM   # NHC_DEBUG=1 keeps the temp folder around
STATUS_FILE="$SCRATCH/status.txt"   # the progress window reads this to know which step we're on
LIVE_FILE="$SCRATCH/live.txt"       # the live number + graph on the progress window (ping ms, Mbps)
FACTS_FILE="$SCRATCH/facts.txt"     # one-off results for the progress window, each one stays up ~2s so people can read it
DATA_FILE="$SCRATCH/rows.tsv"       # every row shown in the results window and the report
FIND_FILE="$SCRATCH/findings.tsv"   # the "What we found" list
REPORT_FILE="$SCRATCH/report.txt"
CANCEL_FILE="$SCRATCH/cancel.flag"  # the Cancel button writes here (anyone can write to it, since the window runs as the user)
: > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"

# --- Reading the parameters -------------------------------------------------
# Jamf always sends 3 things first ("/", the computer name, the username). We drop those so our
# parameters line up the same whether Jamf runs it or you run it from Terminal.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
ACTION_MODE="${1:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
[[ "$ACTION_MODE" != "silent" ]] && ACTION_MODE="verbose"
[[ -n "$2" ]] && SPEED_ENGINE="${2:l}"
[[ "$SPEED_ENGINE" == (apple|cloudflare|off) ]] || SPEED_ENGINE="apple"
[[ "$3" == <-> ]] && (( $3 >= 5 )) && TEST_SECONDS="$3"
[[ "${3:l}" == quick || -n "$NHC_QUICK" ]] && QUICK_MODE=true
[[ -n "$4" ]] && SIMULATE="${4:l}"                         # Jamf $7
[[ -n "$NHC_SIMULATE" ]] && SIMULATE="${NHC_SIMULATE:l}"
if [[ "$QUICK_MODE" == true ]]; then TEST_SECONDS=5; SPEED_ENGINE="off"; fi

# --- Who's logged in --------------------------------------------------------
# Figure out who's actually sitting at the Mac, so the windows show up on their screen and the
# report lands on THEIR Desktop, even though Jamf runs this as root.
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}

targetUser="${consoleUser:-${JAMF_USER:-$(/usr/bin/id -un)}}"
USER_HOME=$(/usr/bin/dscl . -read /Users/"$targetUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="/Users/$targetUser"

[[ "$HEADLESS" == true ]] && ACTION_MODE="silent"
# Nobody logged in? Then there's no one to show windows to, so run silently.
[[ -z "$consoleUser" ]] && (( amRoot )) && ACTION_MODE="silent"

# Turn the banner hex colors into the RGB numbers AppKit wants
bhex="${bannerColor#\#}";   br=$((16#${bhex[1,2]}));  bg=$((16#${bhex[3,4]}));  bb=$((16#${bhex[5,6]}))
tchex="${BANNER_TEXT_COLOR#\#}"; tr=$((16#${tchex[1,2]})); tg=$((16#${tchex[3,4]})); tb=$((16#${tchex[5,6]}))

PING_COUNT=$(/usr/bin/awk -v s="$TEST_SECONDS" -v i="$PING_INTERVAL" 'BEGIN{printf "%d", s/i}')

# --- Helpers ----------------------------------------------------------------
# Writes a timestamped line to the Jamf policy log, and to $logFile if we can (only as root).
logWritable() { [[ -w "$logFile" ]] || { [[ ! -e "$logFile" && -w "${logFile:h}" ]]; }; }
logMe() { local l="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}"; print -r -- "$l"; logWritable && print -r -- "$l" >> "$logFile"; return 0; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }   # makes text safe to drop into the JavaScript
clean() { local s="${1//$'\t'/ }"; print -r -- "${s//$'\n'/ }"; }                        # strips tabs/newlines so they don't break the results file

# Tells the progress window what step we're on.
#   spin_status <step 0-4> <title> <detail> <start %> <end %> <about how many seconds> [linear]
# The bar slides from the start % toward the end % over that time, so it keeps moving even
# during something slow like the speed test instead of just sitting there.
spin_status() {
  print -rl -- "$1" "$2" "$3" "$4" "$5" "$6" "${7:-0}" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}
# Colors for the big number on the progress window. You write it like "code:text|code:text", where
# w=white c=cyan p=purple g=green o=orange r=red b=blue y=yellow. Example: "c:↓ 42|w:   |p:↑ 36"
lag_code()  { case $(lag_status "$1") in good) print g;; ok) print o;; bad) print r;; *) print w;; esac; }
stat_code() { case "$1" in good) print g;; ok) print o;; bad) print r;; *) print w;; esac; }
band_code() { local v=$1; (( v>=80 )) && { print g; return }; (( v>=70 )) && { print y; return }; (( v>=50 )) && { print o; return }; print r; }

# Shows a one-off result on the progress window. They wait in line so each one stays up long
# enough to actually read.
fact() {
  print -r -- "$(clean "$1")"$'\t'"$(clean "$2")"$'\t'"$3" >> "$FACTS_FILE" 2>/dev/null
  /bin/chmod 644 "$FACTS_FILE" 2>/dev/null; : > "$LIVE_FILE"
}
# Shows a number that keeps changing (ping ms, Mbps) plus its little graph.
#   live_metric <big number> <caption> <graph values> [second graph values]
live_metric() {
  print -rl -- "$1" "$2" "$3" "$4" > "$LIVE_FILE" 2>/dev/null
  /bin/chmod 644 "$LIVE_FILE" 2>/dev/null
}

# How many bytes have gone in/out of the network card. We check it twice a second to get live Mbps.
if_bytes() { /usr/sbin/netstat -ibn -I "$PHYS_IF" 2>/dev/null | /usr/bin/awk 'NR==2{print $7, $10}'; }

# While the speed test is running, keep showing the live Mbps on the progress window.
#   throughput_monitor <pid of the speed test> <both|down|up>
throughput_monitor() {
  local pid=$1 mode=$2 i0 o0 i1 o1 t0 t1 d u big; local -a sd su
  read -r i0 o0 <<< "$(if_bytes)"; t0=$EPOCHREALTIME
  while kill -0 $pid 2>/dev/null; do
    check_cancel
    /bin/sleep 0.5
    read -r i1 o1 <<< "$(if_bytes)"; t1=$EPOCHREALTIME
    isnum "$i1" && isnum "$i0" || { i0=$i1; o0=$o1; t0=$t1; continue; }
    d=$(calc "($i1-$i0)*8/($t1-$t0)/1000000"); u=$(calc "($o1-$o0)*8/($t1-$t0)/1000000")
    i0=$i1; o0=$o1; t0=$t1
    [[ "$ACTION_MODE" == verbose ]] || continue
    case $mode in
      down) sd+=($d); big="↓ $(r0 $d)" ;;
      up)   su+=($u); big="↑ $(r0 $u)" ;;
      *)    sd+=($d); su+=($u); big="↓ $(r0 $d)   ↑ $(r0 $u)" ;;
    esac
    (( ${#sd} > 40 )) && sd=(${sd[-40,-1]}); (( ${#su} > 40 )) && su=(${su[-40,-1]})
    case $mode in down) big="c:$big";; up) big="p:$big";; *) big="c:↓ $(r0 $d)|w:    |p:↑ $(r0 $u)";; esac
    live_metric "$big" "Mbps right now" "${(j:,:)sd}" "${(j:,:)su}"
  done
}

# Adding rows to the results. The status controls the colored dot: good | ok | bad | na (no dot)
heading() { print -r -- "H"$'\t'"$(clean "$1")" >> "$DATA_FILE"; }
section() { print -r -- "S"$'\t'"$(clean "$1")"$'\t'"$2" >> "$DATA_FILE"; }
row()     { print -r -- "R"$'\t'"$(clean "$1")"$'\t'"$(clean "$2")"$'\t'"${3:-na}" >> "$DATA_FILE"; }
finding() { print -r -- "$1"$'\t'"$(clean "$2")" >> "$FIND_FILE"; }

device_serial() {
  /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
    | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# Math helpers (zsh isn't great with decimals, so awk does it)
calc() { /usr/bin/awk "BEGIN{printf \"%.1f\", $1}" 2>/dev/null; }
r0()   { /usr/bin/awk -v v="$1" 'BEGIN{printf "%.0f", v}'; }
isnum() { [[ "$1" == (-|)<->(.<->|) ]]; }

# Turns a measurement into a 0-100 score using a list of points, and fills in between them.
# Example: interp 35 "20:100 50:90" gives about 95.
interp() {
  /usr/bin/awk -v v="$1" -v pts="$2" 'BEGIN{
    n=split(pts,P," "); for(i=1;i<=n;i++){split(P[i],a,":"); X[i]=a[1]+0; Y[i]=a[2]+0}
    if(v<=X[1]){printf "%.0f", Y[1]; exit} if(v>=X[n]){printf "%.0f", Y[n]; exit}
    for(i=1;i<n;i++) if(v>=X[i] && v<=X[i+1]){ printf "%.0f", Y[i]+(v-X[i])*(Y[i+1]-Y[i])/(X[i+1]-X[i]); exit }
  }'
}

# Score -> its label (Excellent, Good...) and color
band_label() { local s=$1; (( s>=90 )) && { print Excellent; return }; (( s>=80 )) && { print Good; return }
               (( s>=70 )) && { print Okay; return }; (( s>=50 )) && { print Fair; return }; print Poor; }
band_color() { local s=$1; (( s>=90 )) && { print "#34C759"; return }; (( s>=80 )) && { print "#7CC444"; return }
               (( s>=70 )) && { print "#F2B800"; return }; (( s>=50 )) && { print "#FF9500"; return }; print "#FF3B30"; }
score_status() { local s=$1; (( s>=80 )) && { print good; return }; (( s>=60 )) && { print ok; return }; print bad; }

# --- Progress window ------------------------------------------------------------------------------
# The dark window users see while the test runs. It has the 5 step circles across the top, a big live
# number with a graph (ping times, then Mbps), a progress bar that keeps moving smoothly, and a
# Cancel button. It checks the status files about 5 times a second to see what's going on.
SPIN_SCPT="$SCRATCH/spin.jxa"
show_spinner() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  {
    print -r -- "var STATUS=\"$(as_esc "$STATUS_FILE")\", LIVE=\"$(as_esc "$LIVE_FILE")\", FACTS=\"$(as_esc "$FACTS_FILE")\", TITLE=\"$(as_esc "$SPINNER_TEXT")\";"
    print -r -- "var SPEED_ON=$([[ "$SPEED_ENGINE" == off ]] && print false || print true);"
    print -r -- "var CANCEL=\"$(as_esc "$CANCEL_FILE")\", CANCEL_L=\"$(as_esc "$cancelButton")\";"
    /bin/cat <<'JXA'
ObjC.import('Cocoa');
function rd(p){try{return ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,$.NSUTF8StringEncoding,null))||"";}catch(e){return "";}}
function C(r,g,b,a){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r,g,b,a==null?1:a);}
var BLUE=C(0.30,0.56,1), CYAN=C(0.35,0.82,1), PURPLE=C(0.72,0.48,1), GREEN=C(0.20,0.78,0.35), DIM=C(1,1,1,0.30), WHITE=C(0.95,0.96,0.98);
function label(x,y,w,h,sz,wt,al){var t=$.NSTextField.alloc.initWithFrame($.NSMakeRect(x,y,w,h));
 t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=(al==null?1:al);
 t.usesSingleLineMode=true;t.cell.lineBreakMode=4;t.textColor=WHITE;t.font=$.NSFont.systemFontOfSizeWeight(sz,wt||$.NSFontWeightRegular);return t;}
function rbox(x,y,w,h,col,rad){var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h));b.boxType=4;b.borderWidth=0;b.titlePosition=0;b.cornerRadius=rad||0;b.fillColor=col;return b;}
function symImg(n){return $.NSImage.imageWithSystemSymbolNameAccessibilityDescription(n,"");}

var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var W=620,H=372;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),0,2,false);
win.opaque=false; win.backgroundColor=$.NSColor.clearColor; win.level=5; win.movableByWindowBackground=true;
win.appearance=$.NSAppearance.appearanceNamed($.NSAppearanceNameDarkAqua);   // dark buttons to match the dark window
var cv=win.contentView; cv.wantsLayer=true;   // layer-backed = smooth, flicker-free animation
var card=rbox(10,10,W-20,H-20,C(0.13,0.13,0.15,0.97),22);
card.shadow=$.NSShadow.alloc.init; card.shadow.shadowBlurRadius=24; card.shadow.shadowOffset=$.NSMakeSize(0,-4); card.shadow.shadowColor=C(0,0,0,0.45);
cv.addSubview(card);

var title=label(30,H-62,W-60,26,18,$.NSFontWeightBold); title.stringValue=TITLE; cv.addSubview(title);

// Cancel button (top right). It writes the cancel file, and the script sees that, stops, and closes this window.
if(!$.NHCancel){ObjC.registerSubclass({name:'NHCancel',superclass:'NSObject',methods:{
 'cancel:':{types:['void',['id']],implementation:function(b){
   $("1").writeToFileAtomicallyEncodingError(CANCEL,false,$.NSUTF8StringEncoding,null);
   b.enabled=false; b.title="Cancelling…"; }}}});}
var ch=$.NHCancel.alloc.init;
var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(W-124,H-60,96,26)); cb.title=CANCEL_L; cb.bezelStyle=1; cb.controlSize=1;
cb.target=ch; cb.action='cancel:'; cv.addSubview(cb);

// The 5 step circles
var STEPS=[["network","Connect"],["gauge.with.dots.needle.67percent","Responsiveness"],["globe","Web & DNS"],["speedometer","Speed"],["checkmark.seal","Score"]];
var nodeY=H-134, x0=92, gap=(W-2*x0)/4, nodes=[], links=[];
for(var i=0;i<4;i++){ var lx=x0+i*gap+22, lw=gap-44;
 cv.addSubview(rbox(lx,nodeY+15,lw,3,C(1,1,1,0.12),1.5));
 var lf=rbox(lx,nodeY+15,0,3,GREEN,1.5); cv.addSubview(lf); links.push({box:lf,x:lx,w:lw,cur:0}); }
for(var i=0;i<STEPS.length;i++){ var cx=x0+i*gap;
 var bgc=rbox(cx-17,nodeY,34,34,C(1,1,1,0.07),17); cv.addSubview(bgc);
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(cx-10,nodeY+7,20,20)); iv.setImage(symImg(STEPS[i][0])); iv.imageScaling=3; iv.contentTintColor=DIM; cv.addSubview(iv);
 var nl=label(cx-60,nodeY-22,120,16,10.5,$.NSFontWeightMedium); nl.stringValue=STEPS[i][1]; nl.textColor=DIM; cv.addSubview(nl);
 nodes.push({bg:bgc,icon:iv,lab:nl,sym:STEPS[i][0],state:-1}); }

// What step we're on
var stepT=label(30,H-196,W-60,22,15,$.NSFontWeightSemibold); cv.addSubview(stepT);
var detail=label(30,H-218,W-60,18,12); detail.textColor=C(0.62,0.66,0.74); cv.addSubview(detail);

// The live number box: a faint graph across the back, with the colored number on top
cv.addSubview(rbox(30,72,W-60,78,C(1,1,1,0.05),12));
var SPW=W-76, SPH=66;
var spark=$.NSImageView.alloc.initWithFrame($.NSMakeRect(38,78,SPW,SPH)); spark.imageScaling=0; spark.alphaValue=0.45; cv.addSubview(spark);
var big=label(40,102,W-80,40,30,$.NSFontWeightBold,1); cv.addSubview(big);
var cap=label(40,82,W-80,16,11.5,$.NSFontWeightMedium,1); cap.textColor=C(0.70,0.74,0.82); cv.addSubview(cap);
var CODES={w:WHITE,c:CYAN,p:PURPLE,g:GREEN,o:C(1,0.62,0.22),r:C(1,0.38,0.35),b:BLUE,y:C(1,0.84,0.26)};
var BIGF=$.NSFont.monospacedDigitSystemFontOfSizeWeight(30,$.NSFontWeightBold);
var PS=$.NSMutableParagraphStyle.alloc.init; PS.alignment=1; PS.lineBreakMode=4;
function setBig(m){ var txt="", parts=[];
 (m||"").split("|").forEach(function(sg){ var col=WHITE, t=sg;
  if(sg.length>1 && sg.charAt(1)==":" && CODES[sg.charAt(0)]){ col=CODES[sg.charAt(0)]; t=sg.substr(2); }
  parts.push([txt.length,t.length,col]); txt+=t; });
 var as=$.NSMutableAttributedString.alloc.init, all=$.NSMakeRange(0,txt.length); as.mutableString.setString(txt);
 as.addAttributeValueRange($.NSFontAttributeName,BIGF,all); as.addAttributeValueRange($.NSParagraphStyleAttributeName,PS,all);
 parts.forEach(function(p){ if(p[1]) as.addAttributeValueRange($.NSForegroundColorAttributeName,p[2],$.NSMakeRange(p[0],p[1])); });
 big.attributedStringValue=as; }
// Live readout: the number and the graph are driven by ONE smoothed value. Each new reading sets a
// target, the value glides toward it on a steady time-based curve, and the graph is a trace of that
// value recorded 10 times a second that scrolls left at a constant speed. Result: no jumping number,
// and no stop-and-go graph, no matter how unevenly the readings arrive.
var TW={tpl:null,key:"",cur:[],tgt:[],shown:"",override:null};
function splitNums(m){ var tpl=[], vals=[], cols=[];
 (m||"").split("|").forEach(function(sg){ var mm=sg.match(/-?\d+(\.\d+)?/);
  if(mm){ vals.push(parseFloat(mm[0])); tpl.push(sg.replace(mm[0],"#")); cols.push(sg.charAt(0)=="p"?PURPLE:CYAN); }
  else { vals.push(null); tpl.push(sg); cols.push(null); } });
 return {tpl:tpl, vals:vals, cols:cols, key:tpl.map(function(t){return t.replace(/^[a-z]:/,"");}).join("|")}; }
function renderTween(){ if(TW.override) return; var out=TW.tpl.map(function(t,i){ return TW.cur[i]==null ? t : t.replace("#",String(Math.round(TW.cur[i]))); }).join("|");
 if(out!=TW.shown){ TW.shown=out; setBig(out); } }
function tweenStep(dt){ if(!TW.tpl) return; var k=1-Math.exp(-dt/0.28);   // glide toward the target (about 0.3s)
 for(var i=0;i<TW.cur.length;i++){ if(TW.cur[i]==null||TW.tgt[i]==null) continue; TW.cur[i]+=(TW.tgt[i]-TW.cur[i])*k; }
 renderTween(); }

var LV={on:false, hist:[], cols:[], last:0, base0:false}, WIN=12;   // seconds of history across the graph
var SC={mn:0,mx:1,init:false};                                      // graph scale (eases when the range changes)
function liveSample(t){ var v=[]; for(var i=0;i<TW.cur.length;i++) if(TW.cur[i]!=null) v.push(TW.cur[i]);
 if(!v.length) return; if(t-LV.last>=0.1){ LV.hist.push({t:t,v:v,miss:!!TW.override}); LV.last=t; }   // miss = "no reply" moment
 while(LV.hist.length && LV.hist[0].t < t-WIN-1) LV.hist.shift(); }
function drawLive(t,dt){
 var img=$.NSImage.alloc.initWithSize($.NSMakeSize(SPW,SPH)), H=LV.hist; if(H.length<2) return img;
 var head=[]; for(var i=0;i<TW.cur.length;i++) if(TW.cur[i]!=null) head.push(TW.cur[i]);
 var lo=1e9, hi=-1e9; H.forEach(function(h){ if(!h.miss) h.v.forEach(function(x){ if(x<lo)lo=x; if(x>hi)hi=x; }); });   // dips don't count toward the scale
 if(lo>hi){ lo=0; hi=1; }
 var tmn=LV.base0?0:lo*0.8, tmx=Math.max(hi*1.1, tmn+1);
 if(!SC.init){ SC.mn=tmn; SC.mx=tmx; SC.init=true; } else { var k=1-Math.exp(-dt/0.5); SC.mn+=(tmn-SC.mn)*k; SC.mx+=(tmx-SC.mx)*k; }
 var R=SPW-6, span=SPW-12;
 function Y(x){ return 5+Math.max(0,Math.min(1,(x-SC.mn)/(SC.mx-SC.mn)))*(SPH-12); }
 img.lockFocus;
 for(var s=0;s<head.length;s++){ var col=LV.cols[s]||CYAN, P=[];
  // a "no reply" moment drops to the bottom of the graph, like a missed beat
  H.forEach(function(h){ if(h.v[s]!=null) P.push([R-(t-h.t)/WIN*span, h.miss ? 3 : Y(h.v[s])]); });
  var hy=TW.override ? 3 : Y(head[s]); P.push([R, hy]);
  if(P.length<2) continue;
  var area=$.NSBezierPath.bezierPath; area.moveToPoint($.NSMakePoint(P[0][0],0));
  P.forEach(function(p){ area.lineToPoint($.NSMakePoint(p[0],p[1])); }); area.lineToPoint($.NSMakePoint(R,0)); area.closePath;
  col.colorWithAlphaComponent(0.16).setFill; area.fill;
  var ln=$.NSBezierPath.bezierPath; ln.moveToPoint($.NSMakePoint(P[0][0],P[0][1]));
  for(var i=1;i<P.length;i++) ln.lineToPoint($.NSMakePoint(P[i][0],P[i][1]));
  ln.lineWidth=2; ln.lineCapStyle=1; ln.lineJoinStyle=1; col.setStroke; ln.stroke;
  (TW.override ? CODES.o : col).setFill; $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(R-3.5,hy-3.5,7,7)).fill; }
 img.unlockFocus; return img; }

// One-off results can come with a small graph of their own (like each site's load time) - drawn as-is.
function drawStatic(a,b){
 var img=$.NSImage.alloc.initWithSize($.NSMakeSize(SPW,SPH)), all=a.concat(b); if(all.length<2) return img;
 var mx=Math.max.apply(null,all)*1.1, mn=b.length?0:Math.min.apply(null,all)*0.8; if(mx-mn<1) mx=mn+1;
 img.lockFocus;
 [[a,CYAN],[b,PURPLE]].forEach(function(sv){ var v=sv[0], col=sv[1]; if(v.length<2) return;
  var st=(SPW-12)/(Math.max(v.length,16)-1), xs=SPW-6-(v.length-1)*st;
  var P=v.map(function(y,k){ return [xs+k*st, 5+(y-mn)/(mx-mn)*(SPH-12)]; });
  var ln=$.NSBezierPath.bezierPath; ln.moveToPoint($.NSMakePoint(P[0][0],P[0][1])); P.forEach(function(p){ ln.lineToPoint($.NSMakePoint(p[0],p[1])); });
  ln.lineWidth=2; ln.lineJoinStyle=1; col.setStroke; ln.stroke; });
 img.unlockFocus; return img; }

function showMetric(bigTxt,capTxt,a,b,live){
 cap.setStringValue(capTxt||"");
 var s=splitNums(bigTxt);
 if(live){
  if(LV.on && TW.tpl && !s.vals.some(function(v){return v!=null;})){                  // "no reply": show it, keep the graph going
    TW.override=bigTxt; setBig(bigTxt); return; }
  if(TW.tpl && LV.on && s.key==TW.key){ TW.tpl=s.tpl; TW.tgt=s.vals;                   // same kind of reading: glide to it
    if(TW.override){ TW.override=null; TW.shown=""; } }
  else { TW.tpl=s.tpl; TW.key=s.key; TW.cur=s.vals.slice(); TW.tgt=s.vals.slice(); TW.shown=""; TW.override=null; renderTween();
         LV.hist=[]; LV.last=0; SC.init=false; LV.on=true; LV.cols=s.cols.filter(function(c){return c;});
         LV.base0=(LV.cols.length>1)||/Mbps/.test(capTxt||""); }
 } else { TW.tpl=null; TW.override=null; LV.on=false; setBig(bigTxt); spark.setImage(drawStatic(nums(a),nums(b))); }
}
// Progress bar (slides smoothly, with a little shine moving across it)
var BX=44, BY=44, BW=W-88-52, BH=10;
cv.addSubview(rbox(BX,BY,BW,BH,C(1,1,1,0.10),5));
var fill=rbox(BX,BY,0,BH,BLUE,5); try{fill.clipsToBounds=true;}catch(e){} cv.addSubview(fill);
var shim=rbox(-80,0,80,BH,C(1,1,1,0.28),5); fill.addSubview(shim);
var pct=label(W-44-48,BY-4,48,18,12.5,$.NSFontWeightSemibold,2); pct.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); cv.addSubview(pct);

function nums(s){return (s||"").split(",").filter(function(x){return x.length;}).map(parseFloat).filter(function(x){return !isNaN(x);});}

function setSteps(k){
 for(var i=0;i<nodes.length;i++){ var n=nodes[i], st=(i<k)?0:(i==k?1:2);
  if(i==3 && !SPEED_ON) st=3;
  if(n.state==st) continue; n.state=st;
  if(st==0){ n.icon.setImage(symImg("checkmark.circle.fill")); n.icon.contentTintColor=GREEN; n.bg.fillColor=C(0.20,0.78,0.35,0.16); n.lab.textColor=WHITE; n.icon.alphaValue=1; }
  else if(st==1){ n.icon.setImage(symImg(n.sym)); n.icon.contentTintColor=BLUE; n.bg.fillColor=C(0.30,0.56,1,0.22); n.lab.textColor=WHITE; }
  else if(st==3){ n.icon.setImage(symImg("minus.circle")); n.icon.contentTintColor=DIM; n.bg.fillColor=C(1,1,1,0.05); n.lab.stringValue="Skipped"; n.lab.textColor=DIM; }
  else { n.icon.setImage(symImg(n.sym)); n.icon.contentTintColor=DIM; n.bg.fillColor=C(1,1,1,0.07); n.lab.textColor=DIM; n.icon.alphaValue=1; }
 }
 for(var i=0;i<links.length;i++) links[i].goal=(i<k)?1:0;
}

var shown=0, cur={key:"",step:0,from:0,to:2,eta:2,lin:false,t0:0}, frame=0, lastLive="", factIdx=0, holdUntil=0, lastT=Date.now()/1000, lastPoll=0, lastFW=-1, lastPct="", barDone=false;
var HOLD=1.7, HOLD_BUSY=1.1;   // how long a one-off result stays up (shorter if a few are waiting)
function now(){return Date.now()/1000;}
function target(){ var el=now()-cur.t0, eta=Math.max(cur.eta,0.2), f;
 f = cur.lin ? Math.min(0.98, el/eta) : (1-Math.exp(-2.3*el/eta));
 return cur.from+(cur.to-cur.from)*Math.min(f,0.985); }
if(!$.NHTick){ObjC.registerSubclass({name:'NHTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){
  frame++; var tnow=now(), dt=Math.min(0.1, tnow-lastT); lastT=tnow;
  if(tnow-lastPoll>=0.05){ lastPoll=tnow;
   var L=rd(STATUS).split("\n");
   if(L.length>=6){ var key=[L[0],L[1],L[3],L[4]].join("|");
    if(key!=cur.key){ cur={key:key,step:parseInt(L[0])||0,from:parseFloat(L[3])||0,to:parseFloat(L[4])||0,eta:parseFloat(L[5])||3,lin:L[6]=="1",t0:now()};
     setSteps(cur.step); stepT.setStringValue(L[1]||""); stepT.textColor=(cur.step>=5)?GREEN:WHITE; }
    detail.setStringValue(L[2]||""); }
   // One-off results wait in line and each stays up long enough to read. Live numbers fill in between.
   var F=rd(FACTS).split("\n").filter(function(x){return x.length;});
   if(cur.step>=5 && F.length>factIdx+1){ factIdx=F.length-1; holdUntil=0; }   // at the end, skip straight to the score
   if(F.length>factIdx && now()>=holdUntil){
    var f=F[factIdx++].split("\t"); showMetric(f[0],f[1],f[2],"",false);
    holdUntil=now()+((F.length-factIdx)>1?HOLD_BUSY:HOLD); lastLive="";
   } else if(now()>=holdUntil){
    var lv=rd(LIVE);
    if(lv.length && lv!=lastLive){ lastLive=lv; var M=lv.split("\n"); showMetric(M[0],M[1],M[2],M[3],true); }
   }
  }
  tweenStep(dt); if(LV.on){ liveSample(tnow); spark.setImage(drawLive(tnow,dt)); }   // smooth live number + scrolling graph
  var tg=target(); if(cur.to>=100 && cur.eta<=0.5) tg=100;
  if(tg>shown) shown+=(tg-shown)*(1-Math.exp(-dt/0.3));
  var fw=Math.round(Math.max(BH,BW*shown/100));
  if(fw!=lastFW){ fill.setFrame($.NSMakeRect(BX,BY,fw,BH)); lastFW=fw; }
  // the shine sweeps across every 1.6s and fades in/out at the ends instead of popping back to the start
  var ph=(tnow%1.6)/1.6, sx=Math.round(-80+ph*(fw+80));
  shim.setFrame($.NSMakeRect(sx,0,80,BH)); shim.alphaValue=Math.sin(ph*Math.PI);
  var pt=Math.floor(shown+0.5)+"%"; if(pt!=lastPct){ pct.setStringValue(pt); lastPct=pt; }
  if(shown>=99.5 && !barDone){ fill.fillColor=GREEN; barDone=true; }
  var n=nodes[cur.step]; if(n && n.state==1) n.icon.alphaValue=0.55+0.45*Math.sin(tnow*6);
  for(var i=0;i<links.length;i++){ var lk=links[i]; lk.cur+=((lk.goal||0)-lk.cur)*(1-Math.exp(-dt/0.18)); lk.box.setFrame($.NSMakeRect(lk.x,nodeY+15,lk.w*lk.cur,3)); }
 }}}});}
var tk=$.NHTick.alloc.init;
// 60 frames a second, and keep ticking while the window is being dragged (common run loop modes)
var tmr=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1/60,tk,'tick:',null,true);
$.NSRunLoop.currentRunLoop.addTimerForMode(tmr,$.NSRunLoopCommonModes);
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
JXA
  } > "$SPIN_SCPT"
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; return 0; }

# --- Simple message window (shown after Save Report) --------------------------
# show_message <title> <SF Symbol name> <icon color hex> <message> [file name]
show_message() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  local th="${3#\#}"; local ir=$((16#${th[1,2]})) ig=$((16#${th[3,4]})) ib=$((16#${th[5,6]}))
  local mscpt="$SCRATCH/message.jxa"
  {
    print -r -- "var T=\"$(as_esc "$1")\", SYM=\"$2\", MSG=\"$(as_esc "$4")\", FNAME=\"$(as_esc "$5")\", OKL=\"$(as_esc "$okButton")\";"
    print -r -- "var BC=[$br,$bg,$bb], TC=[$tr,$tg,$tb], IC=[$ir,$ig,$ib];"
    /bin/cat <<'JXA'
ObjC.import('Cocoa');
function rgb(a){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(a[0]/255,a[1]/255,a[2]/255,1);}
if(!$.NHMsg){ObjC.registerSubclass({name:'NHMsg',superclass:'NSObject',methods:{'ok:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});}
function label(s,x,y,w,ht,sz,bold,al){var t=$.NSTextField.alloc.initWithFrame($.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=true;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=$.NSColor.labelColor;t.font=bold?$.NSFont.boldSystemFontOfSize(sz):$.NSFont.systemFontOfSize(sz);return t;}
var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=$.NHMsg.alloc.init; var hasFile=FNAME.length>0;
var W=560, BH=66, okH=32, iconS=56, msgH=52, chipH=34, g=14, topPad=18, botPad=24;
var okY=botPad, chipY=hasFile?(okY+okH+g):okY+okH, msgY=hasFile?(chipY+chipH+g):(okY+okH+g), iconY=msgY+msgH+g, H=iconY+iconS+topPad+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=$.NSBox.alloc.initWithFrame($.NSMakeRect(0,H-BH,W,BH)); banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=rgb(BC); cv.addSubview(banner);
var tl=label(T,20,H-BH+(BH-26)/2,W-40,26,18,true,1); tl.textColor=rgb(TC); cv.addSubview(tl);
var img=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(SYM,"");
if(img){ var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect((W-iconS)/2,iconY,iconS,iconS)); iv.setImage(img); iv.imageScaling=3; iv.contentTintColor=rgb(IC); cv.addSubview(iv); }
cv.addSubview(label(MSG,36,msgY,W-72,msgH,13,false,1));
if(hasFile){
 var chip=$.NSBox.alloc.initWithFrame($.NSMakeRect(40,chipY,W-80,chipH)); chip.boxType=4; chip.borderWidth=0; chip.cornerRadius=8;
 chip.fillColor=$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.16); cv.addSubview(chip);
 var fn=$.NSTextField.alloc.initWithFrame($.NSMakeRect(52,chipY+(chipH-18)/2,W-104,18));
 fn.stringValue=FNAME; fn.bezeled=false; fn.editable=false; fn.selectable=true; fn.drawsBackground=false;
 fn.alignment=1; fn.usesSingleLineMode=true; fn.cell.lineBreakMode=5; fn.textColor=$.NSColor.labelColor;
 fn.font=$.NSFont.monospacedSystemFontOfSizeWeight(12,$.NSFontWeightMedium); cv.addSubview(fn);
}
var b=$.NSButton.alloc.initWithFrame($.NSMakeRect((W-130)/2,okY,130,32)); b.title=OKL; b.bezelStyle=1; b.target=h; b.action='ok:'; b.keyEquivalent=$('\r'); cv.addSubview(b);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
JXA
  } > "$mscpt"
  /bin/chmod 644 "$mscpt"
  run_as_user /usr/bin/osascript -l JavaScript "$mscpt" >/dev/null 2>&1
}

# --- Results window -----------------------------------------------------------
# The big results window: score circle, headline, the three score boxes, "What we found", and the
# scrollable details. Hands back which button they clicked: done, again, or save.
show_results() {
  local rscpt="$SCRATCH/results.jxa" nc="$(band_color $NET_SCORE)" h
  local -a ncr; h="${nc#\#}"; ncr=($((16#${h[1,2]})) $((16#${h[3,4]})) $((16#${h[5,6]})))
  {
    print -r -- "var DATA=\"$(as_esc "$DATA_FILE")\", FIND=\"$(as_esc "$FIND_FILE")\";"
    print -r -- "var TITLE=\"$(as_esc "$RESULT_TITLE")\", SUB=\"$(as_esc "$RUN_SUBTITLE")\", NOTE=\"$(as_esc "$SUPPORT_NOTE")\";"
    print -r -- "var HEAD=\"$(as_esc "$HEADLINE")\", SUBHEAD=\"$(as_esc "$SUBHEADLINE")\";"
    print -r -- "var SCORE=$NET_SCORE, BAND=\"$(band_label $NET_SCORE)\", SC=[${ncr[1]},${ncr[2]},${ncr[3]}];"
    print -r -- "var VIDEO=\"$(as_esc "$VIDEO_TEXT")\", VIDEO_S=\"$VIDEO_STATUS\";"
    print -r -- "var TILES=[[\"Responsiveness\",$RESP_SCORE],[\"Reliability\",$REL_SCORE],[\"Speed\",${SPEED_SCORE:--1}]];"
    print -r -- "var BC=[$br,$bg,$bb], TC=[$tr,$tg,$tb];"
    print -r -- "var L_OK=\"$(as_esc "$okButton")\", L_AGAIN=\"$(as_esc "$againButton")\", L_SAVE=\"$(as_esc "$saveButton")\";"
    /bin/cat <<'JXA'
ObjC.import('Cocoa');
function rgb(a,al){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(a[0]/255,a[1]/255,a[2]/255,al==null?1:al);}
function hex(s){s=s.replace('#','');return [parseInt(s.substr(0,2),16),parseInt(s.substr(2,2),16),parseInt(s.substr(4,2),16)];}
function bandHex(s){return s<0?'#8E8E93':s>=90?'#34C759':s>=80?'#7CC444':s>=70?'#F2B800':s>=50?'#FF9500':'#FF3B30';}
var STAT={good:'#34C759',ok:'#FF9500',bad:'#FF3B30',na:'#8E8E93'};
var SYMS={good:'checkmark.circle.fill',ok:'exclamationmark.triangle.fill',bad:'xmark.octagon.fill',na:'info.circle.fill'};
function readLines(p){try{var s=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,$.NSUTF8StringEncoding,null))||"";return s.split("\n").filter(function(l){return l.length;});}catch(e){return [];}}
function label(s,x,y,w,h,sz,wt,al){var t=$.NSTextField.alloc.initWithFrame($.NSMakeRect(x,y,w,h));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al==null?0:al;
 t.usesSingleLineMode=true;t.cell.lineBreakMode=4;t.textColor=$.NSColor.labelColor;
 t.font=$.NSFont.systemFontOfSizeWeight(sz,wt||$.NSFontWeightRegular);return t;}
function wrapLabel(s,x,y,w,h,sz){var t=label(s,x,y,w,h,sz);t.usesSingleLineMode=false;t.cell.wraps=true;t.cell.lineBreakMode=0;return t;}
function rbox(x,y,w,h,col,rad){var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h));b.boxType=4;b.borderWidth=0;b.titlePosition=0;b.cornerRadius=rad||0;b.fillColor=col;return b;}
function sym(name,x,y,s,col){var img=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(name,"");if(!img)return null;
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(x,y,s,s));iv.setImage(img);iv.imageScaling=3;iv.contentTintColor=col;return iv;}
function ring(size,frac,col){var img=$.NSImage.alloc.initWithSize($.NSMakeSize(size,size));img.lockFocus;
 var c=$.NSMakePoint(size/2,size/2),r=size/2-9;
 var t=$.NSBezierPath.bezierPath;t.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,r,0,360);t.lineWidth=12;
 $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.18).setStroke;t.stroke;
 if(frac>0){var p=$.NSBezierPath.bezierPath;p.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,r,90,90-359.9*frac,true);
  p.lineWidth=12;p.lineCapStyle=1;col.setStroke;p.stroke;}
 img.unlockFocus;return img;}

var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);
if(!$.NHRes){ObjC.registerSubclass({name:'NHRes',superclass:'NSObject',methods:{
 'done:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'again:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(2);}},
 'save:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(3);}}}});}
var hd=$.NHRes.alloc.init;

var rows=readLines(DATA).map(function(l){return l.split("\t");});
var finds=readLines(FIND).map(function(l){return l.split("\t");});
var ORD={bad:0,ok:1,na:2,good:3}; function rk(f){return /^SIMULATED/.test(f[1]||"")?-1:((f[0] in ORD)?ORD[f[0]]:2);} finds.sort(function(a,b){return rk(a)-rk(b);});   // problems at the top

// ---- sizes and positions (laid out top to bottom) ----
var W=780, BH=74, PAD=28, HERO=176, FROW=22, TILEH=70;
var findH=finds.length?(finds.length*FROW+44):0;
var scr=$.NSScreen.mainScreen.visibleFrame.size.height;
var fixedH=BH+18+HERO+14+(findH?findH+14:0)+30+20+18+32+22;
var detH=Math.max(170,Math.min(380,scr-80-fixedH));
var H=fixedH+detH;

var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true;win.titleVisibility=1;win.movableByWindowBackground=true;
var cv=win.contentView;

// Banner
cv.addSubview(rbox(0,H-BH,W,BH,rgb(BC)));
var tl=label(TITLE,24,H-BH+30,W-48,26,19,$.NSFontWeightBold,1);tl.textColor=rgb(TC);cv.addSubview(tl);
var st=label(SUB,24,H-BH+10,W-48,18,12,$.NSFontWeightRegular,1);st.textColor=rgb(TC,0.8);cv.addSubview(st);

// Top section: score circle, headline, and the 3 score boxes
var top=BH+18, RS=156, heroY=H-top-HERO;
var rv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(PAD+4,heroY+(HERO-RS)/2,RS,RS));rv.setImage(ring(RS,Math.max(0,SCORE)/100,rgb(SC)));cv.addSubview(rv);
var sn=label(SCORE<0?"–":String(SCORE),PAD+4,heroY+(HERO-RS)/2+RS/2-14,RS,52,46,$.NSFontWeightBold,1);cv.addSubview(sn);
var sb=label(BAND.toUpperCase(),PAD+4,heroY+(HERO-RS)/2+RS/2-34,RS,18,11,$.NSFontWeightSemibold,1);sb.textColor=rgb(SC);cv.addSubview(sb);
var hx=PAD+RS+30, hw=W-hx-PAD;
cv.addSubview(label(HEAD,hx,heroY+HERO-34,hw,28,21,$.NSFontWeightBold));
var shl=wrapLabel(SUBHEAD,hx,heroY+HERO-76,hw,38,13);shl.textColor=$.NSColor.secondaryLabelColor;cv.addSubview(shl);
if(VIDEO){ var vc=rgb(hex(STAT[VIDEO_S]||STAT.na)), vi=sym("video.fill",hx,heroY+82,16,vc); if(vi)cv.addSubview(vi);
 var vt=label("Video calls: "+VIDEO,hx+22,heroY+81,hw-22,18,12.5,$.NSFontWeightSemibold);vt.textColor=vc;cv.addSubview(vt); }
var tg=12, tw=(hw-2*tg)/3;
for(var i=0;i<TILES.length;i++){
 var tx=hx+i*(tw+tg), ty=heroY+6, sc=TILES[i][1], col=rgb(hex(bandHex(sc)));
 cv.addSubview(rbox(tx,ty,tw,TILEH,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.10),10));
 var tn=label(TILES[i][0],tx+12,ty+TILEH-24,tw-24,16,11,$.NSFontWeightMedium);tn.textColor=$.NSColor.secondaryLabelColor;cv.addSubview(tn);
 var tv=label(sc<0?"Skipped":String(sc),tx+12,ty+18,tw-24,28,sc<0?15:23,$.NSFontWeightBold);tv.textColor=col;cv.addSubview(tv);
 cv.addSubview(rbox(tx+12,ty+10,tw-24,4,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.22),2));
 if(sc>0) cv.addSubview(rbox(tx+12,ty+10,Math.max(4,(tw-24)*sc/100),4,col,2));
}

// Findings card
var y=heroY-14;
if(findH){
 y-=findH;
 cv.addSubview(rbox(PAD,y,W-2*PAD,findH,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.08),12));
 var fh=label("What we found",PAD+16,y+findH-30,300,18,13,$.NSFontWeightSemibold);cv.addSubview(fh);
 for(var i=0;i<finds.length;i++){
  var fy=y+findH-40-(i+1)*FROW+4, s=finds[i][0], ic=sym(SYMS[s]||SYMS.na,PAD+16,fy+2,15,rgb(hex(STAT[s]||STAT.na)));
  if(ic)cv.addSubview(ic);
  var ft=label(finds[i][1]||"",PAD+40,fy,W-2*PAD-56,18,12.5);ft.toolTip=finds[i][1]||"";cv.addSubview(ft);
 }
 y-=14;
}

// Details (scrolls)
var dl=label("Details",PAD,y-22,300,18,13,$.NSFontWeightSemibold);cv.addSubview(dl);
y-=30;
var dw=W-2*PAD, SECH=34, RH=24, docH=12;
var HDH=46;
rows.forEach(function(r){docH+=(r[0]=="S")?SECH:(r[0]=="H")?HDH:RH;});
docH=Math.max(docH,detH);
var doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,dw-2,docH));
var dy=docH-6, alt=0;
rows.forEach(function(r){
 if(r[0]=="H"){   // the line that splits the user stuff from the "For IT" stuff
  dy-=HDH; alt=0;
  var hl=label(r[1].toUpperCase(),0,dy+12,dw,16,10.5,$.NSFontWeightBold,1);hl.textColor=$.NSColor.tertiaryLabelColor;doc.addSubview(hl);
  doc.addSubview(rbox(16,dy+19,(dw-260)/2,1,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.35)));
  doc.addSubview(rbox(dw-16-(dw-260)/2,dy+19,(dw-260)/2,1,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.35)));
 } else if(r[0]=="S"){
  dy-=SECH; alt=0;
  var ic=sym(r[2]||"circle",12,dy+7,17,rgb(BC)); if(ic)doc.addSubview(ic);
  doc.addSubview(label(r[1],38,dy+6,dw-60,20,13.5,$.NSFontWeightSemibold));
  doc.addSubview(rbox(12,dy+2,dw-28,1,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.25)));
 } else {
  dy-=RH;
  if(alt++%2) doc.addSubview(rbox(8,dy,dw-20,RH,$.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,0.06),5));
  var lb=label(r[1],38,dy+4,250,16,12);lb.textColor=$.NSColor.secondaryLabelColor;doc.addSubview(lb);
  var s=r[3]||"na";
  var vl=label(r[2],290,dy+4,dw-290-44,16,12,$.NSFontWeightMedium,2);vl.selectable=true;vl.toolTip=r[2];
  if(s=="bad"||s=="ok") vl.textColor=rgb(hex(STAT[s]));   // color problem values so they stand out
  doc.addSubview(vl); if(s!="na"){doc.addSubview(rbox(dw-36,dy+8,8,8,rgb(hex(STAT[s]||STAT.na)),4));}
 }
});
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,y-detH,dw,detH));
sv.hasVerticalScroller=true;sv.borderType=1;sv.drawsBackground=false;sv.setDocumentView(doc);cv.addSubview(sv);
sv.contentView.scrollToPoint($.NSMakePoint(0,docH-sv.contentView.bounds.size.height));sv.reflectScrolledClipView(sv.contentView);   // start scrolled to the top

// Note + buttons
var nt=label(NOTE,PAD,22+32+10,W-2*PAD,16,11,$.NSFontWeightRegular,1);nt.textColor=$.NSColor.secondaryLabelColor;cv.addSubview(nt);
function btn(t,x,w,act,key){var b=$.NSButton.alloc.initWithFrame($.NSMakeRect(x,20,w,32));b.title=t;b.bezelStyle=1;b.target=hd;b.action=act;if(key)b.keyEquivalent=$(key);cv.addSubview(b);return b;}
btn(L_AGAIN,PAD,130,'again:');
btn(L_SAVE,W-PAD-130-10-130,130,'save:');
btn(L_OK,W-PAD-130,130,'done:','\r');

win.center;win.makeKeyAndOrderFront(null);app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win);win.orderOut(null);
resp==2?"again":resp==3?"save":"done";
JXA
  } > "$rscpt"
  /bin/chmod 644 "$rscpt" "$DATA_FILE" "$FIND_FILE" 2>/dev/null
  run_as_user /usr/bin/osascript -l JavaScript "$rscpt" 2>>"$SCRATCH/jxa-err.log"
}

####################################################################################################
#
# Measurements
#
####################################################################################################

# --- Connection info ----------------------------------------------------------
# Finds the real Wi-Fi or Ethernet connection. If a VPN is on, all traffic looks like it goes
# through the VPN, so we dig past it to find the actual network card and the real router.
detect_connection() {
  local def_if dev port line
  PHYS_IF=""; PORT_NAME=""; CONN_TYPE=""; LOCAL_IP=""; GATEWAY=""; VPN_ACTIVE=0; VPN_NAME=""
  def_if=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
  if [[ "$def_if" == (utun|ppp|ipsec|gpd|tun|tap|wg)* ]]; then
    VPN_ACTIVE=1
    VPN_NAME=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk -F'"' '/\(Connected\)/{print $2; exit}')
    [[ -z "$VPN_NAME" ]] && VPN_NAME="Active ($def_if)"
  fi

  # match each device (en0...) to its name (Wi-Fi, Ethernet...)
  typeset -gA PORT_OF; PORT_OF=()
  while IFS= read -r line; do
    [[ "$line" == "Hardware Port: "* ]] && port="${line#Hardware Port: }"
    [[ "$line" == "Device: "* ]] && PORT_OF[${line#Device: }]="$port"
  done < <(/usr/sbin/networksetup -listallhardwareports 2>/dev/null)

  if [[ -n "$def_if" && -n "${PORT_OF[$def_if]}" ]]; then
    PHYS_IF="$def_if"
  else
    # VPN is on (or something odd): use the first real network port that has an IP address.
    for dev in $(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | /usr/bin/sed -n 's/.*Device: \([^)]*\)).*/\1/p'); do
      [[ -n "${PORT_OF[$dev]}" ]] || continue
      [[ -n "$(/usr/sbin/ipconfig getifaddr "$dev" 2>/dev/null)" ]] && { PHYS_IF="$dev"; break; }
    done
  fi
  [[ -z "$PHYS_IF" ]] && return 1

  PORT_NAME="${PORT_OF[$PHYS_IF]}"
  if [[ "$PORT_NAME" == *(Wi-Fi|AirPort)* ]]; then CONN_TYPE="Wi-Fi"; else CONN_TYPE="Ethernet"; fi
  LOCAL_IP=$(/usr/sbin/ipconfig getifaddr "$PHYS_IF" 2>/dev/null)
  GATEWAY=$(/usr/sbin/ipconfig getoption "$PHYS_IF" router 2>/dev/null)
  DNS_SERVERS=$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/awk '/nameserver\[[0-9]+\]/{print $3}' | /usr/bin/awk '!s[$0]++' | /usr/bin/head -3 | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')
  [[ -n "$LOCAL_IP" ]]
}

lookup_public_ip() {
  PUB_IP=""; PUB_ISP=""; PUB_LOC=""
  [[ -n "$PUBLIC_IP_LOOKUP_URL" ]] || return 0
  local f="$SCRATCH/ipinfo.json"
  /usr/bin/curl -s -m 6 -o "$f" "$PUBLIC_IP_LOOKUP_URL" 2>/dev/null || return 0
  PUB_IP=$(/usr/bin/plutil -extract ip raw -o - "$f" 2>/dev/null)
  PUB_ISP=$(/usr/bin/plutil -extract org raw -o - "$f" 2>/dev/null | /usr/bin/sed -E 's/^AS[0-9]+ //')
  local c=$(/usr/bin/plutil -extract city raw -o - "$f" 2>/dev/null) r=$(/usr/bin/plutil -extract region raw -o - "$f" 2>/dev/null)
  [[ -n "$c" ]] && PUB_LOC="$c${r:+, $r}"
}

# --- Wi-Fi link ---------------------------------------------------------------
# As root we can use wdutil, which gives the most detail (network name, access point, etc.).
# Otherwise we ask CoreWLAN directly. macOS hides the network name unless we're root.
wifi_info() {
  WIFI_SSID=""; WIFI_RSSI=""; WIFI_NOISE=""; WIFI_TX=""; WIFI_CH=""; WIFI_BAND=""; WIFI_WIDTH=""; WIFI_PHY=""; WIFI_SEC=""
  WIFI_BSSID=""; WIFI_MCS=""; WIFI_NSS=""; WIFI_CCA=""
  local out ch
  if (( amRoot )); then
    out=$(/usr/bin/wdutil info 2>/dev/null | /usr/bin/awk '/^WIFI/{f=1;next} f&&/^[A-Z][A-Z ]+$/{exit} f')
    kv() { print -r -- "$out" | /usr/bin/awk -F' : ' -v k="$1" '{g=$1; gsub(/^ +| +$/,"",g)} g==k{sub(/^ +/,"",$2); print $2; exit}'; }
    WIFI_SSID=$(kv SSID); WIFI_RSSI=$(kv RSSI); WIFI_NOISE=$(kv Noise); WIFI_TX=$(kv "Tx Rate")
    WIFI_PHY=$(kv "PHY Mode"); WIFI_SEC=$(kv Security); ch=$(kv Channel)          # looks like 5g153/80 (band, channel, width)
    WIFI_BSSID=$(kv BSSID); WIFI_MCS=$(kv "MCS Index"); WIFI_NSS=$(kv NSS); WIFI_CCA=$(kv CCA)
    [[ "$WIFI_BSSID" == *redacted* ]] && WIFI_BSSID=""
    WIFI_RSSI="${WIFI_RSSI%% *}"; WIFI_NOISE="${WIFI_NOISE%% *}"; WIFI_TX="${WIFI_TX%% *}"
    if [[ "$ch" == (#b)([0-9])g([0-9]##)/([0-9]##)* ]]; then
      WIFI_BAND="${match[1]}"; WIFI_CH="${match[2]}"; WIFI_WIDTH="${match[3]}"
      [[ "$WIFI_BAND" == 2 ]] && WIFI_BAND="2.4"
    fi
  fi
  if [[ -z "$WIFI_RSSI" ]]; then
    # CoreWLAN answers instantly. (system_profiler works too, but it takes ~13 seconds.)
    out=$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreWLAN"); var i=$.CWWiFiClient.sharedWiFiClient.interface;
      var c=i.wlanChannel; [i.rssiValue, i.noiseMeasurement, i.transmitRate, c.channelNumber, c.channelBand, c.channelWidth,
      i.activePHYMode, i.security, ObjC.unwrap(i.ssid)||""].join("|")' 2>/dev/null)
    local -a w=("${(@s:|:)out}") bands=("2.4" "5" "6") widths=(20 40 80 160 320)
    local -a phys=("802.11a" "802.11b" "802.11g" "802.11n (Wi-Fi 4)" "802.11ac (Wi-Fi 5)" "802.11ax (Wi-Fi 6)" "802.11be (Wi-Fi 7)")
    local -a secs=("WEP" "WPA Personal" "WPA/WPA2 Personal" "WPA2 Personal" "Personal" "Dynamic WEP" "WPA Enterprise" "WPA/WPA2 Enterprise"
                   "WPA2 Enterprise" "Enterprise" "WPA3 Personal" "WPA3 Enterprise" "WPA2/WPA3 Personal" "OWE" "OWE Transition")
    if isnum "${w[1]}" && (( w[1] != 0 )); then
      WIFI_RSSI="${w[1]}"; WIFI_NOISE="${w[2]}"; WIFI_TX="${w[3]}"; WIFI_CH="${w[4]}"
      WIFI_BAND="${bands[${w[5]:-0}]}"; WIFI_WIDTH="${widths[${w[6]:-0}]}"; WIFI_PHY="${phys[${w[7]:-0}]}"
      [[ "${w[8]}" == 0 ]] && WIFI_SEC="None (open network)" || WIFI_SEC="${secs[${w[8]:-99}]}"
      [[ -z "$WIFI_SSID" ]] && WIFI_SSID="${w[9]}"
    fi
  fi
  [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *redacted* ]] && \
    WIFI_SSID=$(/usr/sbin/ipconfig getsummary "$PHYS_IF" 2>/dev/null | /usr/bin/awk -F' : ' '/^ +SSID :/{print $2; exit}')
  # Newer macOS hides the Wi-Fi name even from root, unless ipconfig's verbose mode is on.
  # So we turn it on just long enough to read the name, then turn it right back off.
  if [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *redacted* ]] && (( amRoot )); then
    /usr/sbin/ipconfig setverbose 1 2>/dev/null
    WIFI_SSID=$(/usr/sbin/ipconfig getsummary "$PHYS_IF" 2>/dev/null | /usr/bin/awk -F' : ' '/^ +SSID :/{print $2; exit}')
    /usr/sbin/ipconfig setverbose 0 2>/dev/null
  fi
  [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *redacted* ]] && \
    WIFI_SSID="$( (( amRoot )) && print "(hidden by macOS)" || print "(hidden by macOS — shows when run as root / from Jamf)")"
}

# --- Ping + stats ---------------------------------------------------------------
# ping_run <what to ping> <save output here> [network card to use]
ping_run() {
  local -a bind; [[ -n "$3" ]] && bind=(-b "$3")
  /sbin/ping -n $bind -c "$PING_COUNT" -i "$PING_INTERVAL" -W 1000 "$1" > "$2" 2>&1
}

# Backup plan for when ping is blocked: time how long an HTTPS connection takes to open instead.
# We save it in the same format as ping so the same math works on it.
http_probe() {   # <site> <save output here>
  local i t a b
  for (( i=0; i<PING_COUNT; i++ )); do
    check_cancel
    t=$(/usr/bin/curl -s -I -o /dev/null -m 2 -w '%{time_namelookup} %{time_connect}' "$1" 2>/dev/null)
    read -r a b <<< "$t"
    if isnum "$b" && isnum "$a" && (( b > 0 )); then print -r -- "icmp_seq=$i time=$(calc "($b-$a)*1000")"; fi
    /bin/sleep "$PING_INTERVAL"
  done > "$2"
}

# Crunches a ping file into the numbers we show.
#   Latency = the average ping time.
#   Jitter  = how much the ping time jumps around from one ping to the next.
#   Lag     = what apps actually feel. A lost packet has to be sent again, so each one adds a
#             wait on top. That way packet loss shows up as extra delay, like it does in real life.
ping_stats() {
  local out
  out=$(/usr/bin/awk -v n="$PING_COUNT" '
    /icmp_seq=/ && /time=/ {
      if (!match($0,/icmp_seq=[0-9]+/)) next; s=substr($0,RSTART+9,RLENGTH-9)+0
      if (!match($0,/time=[0-9.]+/)) next;     t=substr($0,RSTART+5,RLENGTH-5)+0
      if (!(s in rtt)) rtt[s]=t
    }
    END {
      r=0; sum=0; mx=0; mn=-1; prev=-1; js=0; jc=0; lost=""
      for (i=0;i<n;i++) {
        if (i in rtt) { t=rtt[i]; r++; sum+=t; if(t>mx)mx=t; if(mn<0||t<mn)mn=t
                        if(prev>=0){d=t-prev; if(d<0)d=-d; js+=d; jc++}; prev=t }
        else lost=lost (lost==""?"":",") i
      }
      if (r==0) { print "0 100 - - - - - " (lost==""?"-":lost); exit }
      avg=sum/r; jit=(jc?js/jc:0); loss=(n-r)*100/n; lag=(sum+(n-r)*(1.5*mx+avg))/n
      printf "%d %.1f %.1f %.1f %.1f %.1f %.1f %s\n", r, loss, avg, mn, mx, jit, lag, (lost==""?"-":lost)
    }' "$1" 2>/dev/null)
  read -r P_RECV P_LOSS P_AVG P_MIN P_MAX P_JIT P_LAG P_LOST <<< "$out"
  [[ -z "$P_RECV" ]] && { P_RECV=0; P_LOSS=100; P_AVG=-; P_JIT=-; P_LAG=-; P_LOST=-; }
}

# Works out how much of the test the connection was actually down.
# It only counts as down if EVERY target missed the same pings, and only if it lasted at
# least OUTAGE_MIN_LOST pings in a row. One-off blips don't count.
reliability_calc() {
  local out
  out=$(/usr/bin/awk -v n="$PING_COUNT" -v lists="$1" -v minrun="$OUTAGE_MIN_LOST" -v iv="$PING_INTERVAL" 'BEGIN{
    nt=split(lists,L,";")
    for(j=1;j<=nt;j++){ if(L[j]=="-") continue; m=split(L[j],S,","); for(q=1;q<=m;q++) c[S[q]+0]++ }
    run=0; un=0; lg=0; ev=0
    for(i=0;i<=n;i++){ if(i<n && c[i]==nt) run++; else { if(run>=minrun){un+=run; ev++; if(run>lg)lg=run}; run=0 } }
    printf "%.1f %.1f %d\n", (n?100*(1-un/n):0), lg*iv, ev }')
  read -r REL_PCT OUTAGE_LONGEST_S OUTAGE_EVENTS <<< "$out"
}

lag_status()    { isnum "$1" || { print na; return }; (( $1 <= 50 )) && print good || { (( $1 <= 120 )) && print ok || print bad; }; }
jitter_status() { isnum "$1" || { print na; return }; (( $1 <= 10 )) && print good || { (( $1 <= 30 )) && print ok || print bad; }; }
loss_status()   { isnum "$1" || { print na; return }; (( $1 < 1 )) && print good || { (( $1 < 3 )) && print ok || print bad; }; }
ms()            { isnum "$1" && print -r -- "$(r0 $1) ms" || print -r -- "—"; }

# --- Extra troubleshooting data -------------------------------------------------------------------
# All of these are quick (under half a second each). They show up in the "For IT" part of the results.

mac_info() {
  MAC_MODEL=$(/usr/sbin/sysctl -n hw.model 2>/dev/null)
  MAC_OS="$(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
  local boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/awk -F'[ ,]+' '{print $4}') up
  isnum "$boot" && { up=$(( EPOCHSECONDS - boot )); MAC_UPTIME="$(( up/86400 ))d $(( up%86400/3600 ))h $(( up%3600/60 ))m"; }
  MAC_LOWPOWER=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/lowpowermode/{print $2; exit}')
  MAC_BATT=$(/usr/bin/pmset -g batt 2>/dev/null | /usr/bin/grep -Eo '[0-9]+%; [a-zA-Z ]+' | /usr/bin/head -1)
  MAC_HOST=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)
}

net_config() {
  local f out k
  NET_MASK=$(/usr/sbin/ipconfig getoption "$PHYS_IF" subnet_mask 2>/dev/null)
  DHCP_SERVER=$(/usr/sbin/ipconfig getoption "$PHYS_IF" server_identifier 2>/dev/null)
  DHCP_LEASE=$(/usr/sbin/ipconfig getoption "$PHYS_IF" lease_time 2>/dev/null)
  DHCP_DOMAIN=$(/usr/sbin/ipconfig getoption "$PHYS_IF" domain_name 2>/dev/null)
  SEARCH_DOMAINS=$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/awk '/search domain/{print $4}' | /usr/bin/awk '!s[$0]++' | /usr/bin/head -3 | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')
  out=$(/sbin/ifconfig "$PHYS_IF" 2>/dev/null)
  IF_MAC=$(print -r -- "$out" | /usr/bin/awk '/ether /{print $2; exit}')          # the address this network actually sees
  HW_MAC=$(/usr/sbin/networksetup -getmacaddress "$PHYS_IF" 2>/dev/null | /usr/bin/awk '{print $3}')   # the Mac's real hardware address
  IF_MTU=$(print -r -- "$out" | /usr/bin/awk '/mtu /{print $NF; exit}')
  IF_MEDIA=$(print -r -- "$out" | /usr/bin/awk -F'media: ' '/media:/{print $2; exit}')
  IPV6_ADDR=$(print -r -- "$out" | /usr/bin/awk '/inet6 / && !/fe80/ && !/deprecated/{print $2; exit}')

  # Any other network connections that are also up (Wi-Fi and Ethernet at the same time, docks, etc.)
  OTHER_IFS=""
  for k in ${(k)PORT_OF}; do
    [[ "$k" == "$PHYS_IF" ]] && continue
    f=$(/usr/sbin/ipconfig getifaddr "$k" 2>/dev/null)
    [[ -n "$f" ]] && OTHER_IFS+="${OTHER_IFS:+, }${PORT_OF[$k]} ($k) $f"
  done

  # Proxy settings (manual proxy, PAC file, or auto-discovery)
  out=$(/usr/sbin/scutil --proxy 2>/dev/null)
  pv() { print -r -- "$out" | /usr/bin/awk -F' : ' -v k="$1" '{g=$1; gsub(/^ +/,"",g)} g==k{print $2; exit}'; }
  PROXY_DESC=""
  [[ "$(pv HTTPEnable)" == 1 ]]  && PROXY_DESC+="${PROXY_DESC:+; }HTTP $(pv HTTPProxy):$(pv HTTPPort)"
  [[ "$(pv HTTPSEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }HTTPS $(pv HTTPSProxy):$(pv HTTPSPort)"
  [[ "$(pv SOCKSEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }SOCKS $(pv SOCKSProxy):$(pv SOCKSPort)"
  [[ "$(pv ProxyAutoConfigEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }PAC $(pv ProxyAutoConfigURLString)"
  [[ "$(pv ProxyAutoDiscoveryEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }Auto-discovery (WPAD)"

  # Network extensions (VPN apps, web filters, security tools) and any VPNs set up on the Mac
  NE_LIST=$(/usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/sed -n '/network_extension/,/^---/p' \
            | /usr/bin/awk -F'\t' '/activated enabled/{print $5}' | /usr/bin/awk '!s[$0]++' | /usr/bin/paste -sd';' - | /usr/bin/sed 's/;/; /g')
  VPN_CONFIGS=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk -F'"' 'NF>2{ st=""; if(match($1,/\([A-Za-z ]+\)/)) st=substr($1,RSTART+1,RLENGTH-2); print $2 (st==""?"":" (" st ")") }' | /usr/bin/paste -sd';' - | /usr/bin/sed 's/;/; /g')
}

# Which Cloudflare city this Mac connects to. If it's far away, the traffic is taking a weird route
# (usually a VPN).
cf_edge() {
  local out=$(/usr/bin/curl -s -m 4 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  CF_COLO=$(print -r -- "$out" | /usr/bin/awk -F= '/^colo=/{print $2}')
  CF_WARP=$(print -r -- "$out" | /usr/bin/awk -F= '/^warp=/{print $2}')
}

# Network card error counts and TCP resends. (macOS only fills in the TCP numbers for root.)
counters() {
  local e=$(/usr/sbin/netstat -ibn -I "$PHYS_IF" 2>/dev/null | /usr/bin/awk 'NR==2{print $6+0, $9+0}')
  local t=$(/usr/sbin/netstat -s -p tcp 2>/dev/null | /usr/bin/awk '/packets? sent$/ && !s{s=$1} /data packets? \(.*\) retransmitted$/ && !r{r=$1} END{print s+0, r+0}')
  print -r -- "$e $t"
}

# Reads the Wi-Fi signal once a second during the test, so we can see if it dips or changes channel.
wifi_sampler() {   # <how many seconds> <save output here>
  /usr/bin/osascript -l JavaScript -e "ObjC.import('CoreWLAN'); var i=\$.CWWiFiClient.sharedWiFiClient.interface, o=[];
    for(var k=0;k<$1;k++){ var c=i.wlanChannel; o.push([i.rssiValue,i.noiseMeasurement,i.transmitRate,c?c.channelNumber:0].join(' '));
    \$.NSThread.sleepForTimeInterval(1); } o.join('\n')" > "$2" 2>/dev/null
}

# Counts nearby access points from the Mac's last Wi-Fi scan (we don't start a new scan, that would
# mess with the ping results). Also counts how many are on the same channel as us.
wifi_neighbors() {
  local out=$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreWLAN"); var s=$.CWWiFiClient.sharedWiFiClient.interface.cachedScanResults;
    var a=s?s.allObjects:null, o=[]; if(a){ for(var k=0;k<a.count;k++){ var x=a.objectAtIndex(k); o.push(x.wlanChannel.channelNumber+":"+x.rssiValue);} } o.join(" ")' 2>/dev/null)
  read -r WIFI_NEARBY WIFI_COCHAN WIFI_COCHAN_STRONG <<< "$(print -r -- "$out" | /usr/bin/tr ' ' '\n' | /usr/bin/awk -F: -v ch="$WIFI_CH" '
    NF==2 { n++; if($1==ch){ c++; if($2>-75) s++ } } END{ print n+0, c+0, s+0 }')"
}

# Turns the traceroute output into one line per hop: hop number, address, average time, missed replies.
# Some hops answer from a few different addresses and traceroute puts those on extra lines, so we
# fold them back into the same hop. We use the middle value of the replies, because busy routers
# sometimes answer traceroute slowly and one slow reply shouldn't make the whole hop look slow.
parse_trace() {
  /usr/bin/awk 'function med(   i,j,t){ for(i=2;i<=c;i++){ t=v[i]; for(j=i-1;j>=1 && v[j]>t;j--) v[j+1]=v[j]; v[j+1]=t }
                 return (c%2) ? v[(c+1)/2] : (v[c/2]+v[c/2+1])/2 }
    function flush(){ if(n!="") printf "%s\t%s\t%s\t%d\n", n, (ip==""?"*":ip), (c?sprintf("%.1f",med()):"-"), l }
    { start=($0 ~ /^ *[0-9]+ /); if(start){ flush(); n=$1; ip=""; c=0; l=0; f=2 } else if(n!="") f=1; else next
      for(i=f;i<=NF;i++){ if($i=="*") l++; else if($(i+1)=="ms" && $i ~ /^[0-9.]+$/){v[++c]=$i+0} else if(ip=="" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i } }
    END{ flush() }' "$1" 2>/dev/null
}
is_private_ip() { [[ "$1" == (10.*|192.168.*|172.(1[6-9]|2[0-9]|3[01]).*|100.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]).*|169.254.*) ]]; }

# Times the router with a tiny traceroute instead of ping. A lot of routers ignore ping but still
# answer this. Because it's aimed right at the router it stays on the local network, even with a VPN
# on. Sometimes a different local address answers (Meraki uses 10.128.128.128), and that's fine.
router_trace() {   # <save output here, in ping's format>
  local line=$(/usr/sbin/traceroute -n -m 1 -q 10 -w 1 "$GATEWAY" 2>/dev/null | /usr/bin/tail -1)
  R_RESPONDER=$(print -r -- "$line" | /usr/bin/awk '{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')
  print -r -- "$line" | /usr/bin/awk '{k=0; for(i=2;i<=NF;i++){ if($i=="*") k++; else if($(i+1)=="ms"){ print "icmp_seq=" k " time=" $i; k++ } }}' > "$1"
}

# Times the Mac's own DNS servers, then 1.1.1.1 and 8.8.8.8 to compare.
dns_tests() {
  local r d q lbl sum n fails; local -a cfg=(${(s:, :)DNS_SERVERS}); local -a rs=($cfg 1.1.1.1 8.8.8.8); rs=(${(u)rs})
  DNS_ROWS=(); DNS_CFG_AVG=""; DNS_PUB_BEST=""
  [[ -x /usr/bin/dig ]] || return 0
  for r in $rs; do
    check_cancel
    sum=0; n=0; fails=0
    for d in $DNS_TEST_DOMAINS; do
      q=$(/usr/bin/dig +tries=1 +time=2 @"$r" "$d" A 2>/dev/null | /usr/bin/awk '/Query time/{print $4}')
      if isnum "$q"; then sum=$(( sum + q )); (( n++ )); else (( fails++ )); fi
    done
    if (( ${cfg[(Ie)$r]} )); then lbl="Your DNS $r"
      case $r in 1.1.1.1|1.0.0.1) lbl+=" (Cloudflare)";; 8.8.8.8|8.8.4.4) lbl+=" (Google)";; esac
    else case $r in 1.1.1.1) lbl="Public: Cloudflare 1.1.1.1";; *) lbl="Public: Google $r";; esac; fi
    if (( n )); then
      local avg=$(( sum / n )) s=good; (( avg > 60 )) && s=ok; (( avg > 150 || fails )) && s=bad
      DNS_ROWS+=("$lbl"$'\t'"$avg ms avg$( (( fails )) && print " · $fails failed")"$'\t'"$s")
      if [[ "$lbl" == Your* ]]; then [[ -z "$DNS_CFG_AVG" ]] || (( avg > DNS_CFG_AVG )) && DNS_CFG_AVG=$avg
      else [[ -z "$DNS_PUB_BEST" ]] || (( avg < DNS_PUB_BEST )) && DNS_PUB_BEST=$avg; fi
    else
      DNS_ROWS+=("$lbl"$'\t'"No answer"$'\t'"bad"); [[ "$lbl" == Your* ]] && DNS_CFG_AVG=9999
    fi
  done
}

# A few quick health checks: hotel-style sign-in page, IPv6, packet size (MTU), and the clock.
misc_checks() {
  local out s
  out=$(/usr/bin/curl -s -m 4 http://captive.apple.com/hotspot-detect.html 2>/dev/null)
  if [[ "$out" == *Success* ]]; then CAPTIVE="none"; elif [[ -n "$out" ]]; then CAPTIVE="detected"; else CAPTIVE="unknown"; fi
  IPV6_NET=""
  if [[ -n "$IPV6_ADDR" ]]; then
    out=$(/usr/bin/curl -6 -s -m 4 https://api64.ipify.org 2>/dev/null)
    [[ "$out" == *:* ]] && IPV6_NET="working ($out)" || IPV6_NET="broken"
  fi
  PMTU=""
  if [[ "$INET_METHOD" == "ICMP ping" ]]; then
    # Send one "don't split this" packet of each size at the same time, and the biggest one that makes
    # it back is the path MTU. (Doing them one by one wastes a second on every size that's too big.)
    local -a mpids; local sz
    for sz in 1472 1452 1400 1372 1300 1252 1200; do
      /sbin/ping -D -n -s $sz -c 1 -t 1 "${INTERNET_TARGETS[1]}" > "$SCRATCH/mtu_$sz.txt" 2>&1 & mpids+=($!)
    done
    wait $mpids 2>/dev/null
    for sz in 1472 1452 1400 1372 1300 1252 1200; do
      /usr/bin/grep -q "bytes from" "$SCRATCH/mtu_$sz.txt" 2>/dev/null && { PMTU=$(( sz + 28 )); break; }
    done
  fi
  CLOCK_OFF_MS=$(/usr/bin/sntp -t 2 time.apple.com 2>/dev/null | /usr/bin/awk '$1 ~ /^[+-][0-9]/{printf "%.0f", $1*1000; exit}')
}

# --- Connection history (last 24 hours) ------------------------------------------------------------
# The test only sees the network right now, but people usually complain after the fact ("my call
# dropped an hour ago"). macOS logs every time the network connection goes down and comes back, so
# we read the last 24 hours of that. The catch: the connection also goes down every time the Mac
# sleeps, so we check the sleep/wake log too and only count drops that happened while it was awake.
history_collect() {   # runs in the background during the ping test
  /usr/bin/log show --last 24h --style compact \
    --predicate "subsystem == \"com.apple.IPConfiguration\" AND (eventMessage CONTAINS \"$PHYS_IF link \" OR eventMessage CONTAINS \"DHCP $PHYS_IF: BOUND\")" 2>/dev/null \
    | /usr/bin/awk '/link (ACTIVE|INACTIVE)$/{print $1" "substr($2,1,8)" L "$NF} /BOUND/{print $1" "substr($2,1,8)" L BOUND"}' > "$SCRATCH/hist_link.txt"
  /usr/bin/pmset -g log 2>/dev/null \
    | /usr/bin/awk '$4=="Sleep" || $4=="DarkWake" || ($4=="Wake" && $5!="Requests") {print $1" "$2" P "$4}' > "$SCRATCH/hist_power.txt"
}
history_parse() {
  HIST_DROPS=""; HIST_LAST=""; HIST_LAST_DUR=""; HIST_LONGEST=""; HIST_JOINS=""
  [[ -s "$SCRATCH/hist_link.txt" ]] || return 0
  local d tm k ev t out
  # turn the timestamps into seconds so we can compare them
  { while read -r d tm k ev; do t=$(strftime -r "%Y-%m-%d %H:%M:%S" "$d $tm" 2>/dev/null) && print -r -- "$t $k $ev"; done < "$SCRATCH/hist_power.txt"
    while read -r d tm k ev; do t=$(strftime -r "%Y-%m-%d %H:%M:%S" "$d $tm" 2>/dev/null) && print -r -- "$t $k $ev"; done < "$SCRATCH/hist_link.txt"
  } | /usr/bin/sort -n > "$SCRATCH/hist_all.txt"
  # A drop only counts if the Mac was awake, it wasn't right after waking up, and the Mac didn't go
  # to sleep a moment later (going to sleep takes the network down too).
  out=$(/usr/bin/awk 'NR==FNR { if($2=="P" && $3=="Sleep") S[++n]=$1; next }
    $2=="P" { st=($3=="Wake")?"awake":(($3=="Sleep")?"asleep":"dark"); lp=$1; next }
    $3=="INACTIVE" { ok=(st=="awake" && $1-lp>90); for(i=1;i<=n;i++) if(S[i]>=$1-5 && S[i]<=$1+90) ok=0; pend=ok?$1:""; next }
    $3=="ACTIVE" { if(pend!=""){ d=$1-pend; drops++; if(d>lg) lg=d; last=pend; lastd=d; pend="" } next }
    $3=="BOUND" { if(st=="awake") joins++ }
    END { printf "%d %d %s %s %d\n", drops, lg, (last==""?"-":last), (lastd==""?"-":lastd), joins }' "$SCRATCH/hist_all.txt" "$SCRATCH/hist_all.txt")
  read -r HIST_DROPS HIST_LONGEST HIST_LAST HIST_LAST_DUR HIST_JOINS <<< "$out"
}
when_text() {   # epoch seconds -> "2:14 PM" today, or "Tue 2:14 PM"
  isnum "$1" || { print -r -- "—"; return }
  if [[ "$(strftime %F "$1")" == "$(strftime %F $EPOCHSECONDS)" ]]; then strftime "%-I:%M %p" "$1"; else strftime "%a %-I:%M %p" "$1"; fi
}
dur_text() { isnum "$1" || { print -r -- "?"; return }; (( $1 < 90 )) && print -r -- "${1}s" || print -r -- "$(( $1 / 60 ))m"; }

# --- Apps using the network ------------------------------------------------------------------------
# "My internet is slow" is often just something else hogging it: iCloud, OneDrive, Dropbox, a backup,
# a big update. nettop shows how much each app sent/received over a few seconds. It runs during the
# ping test (before our own speed test) so we're not counting ourselves.
apps_collect() { /usr/bin/nettop -P -d -L 2 -s 3 -x -J bytes_in,bytes_out > "$SCRATCH/nettop.txt" 2>/dev/null; }
apps_parse() {
  APP_ROWS=(); APPS_TOTAL_MBPS=""; APP_TOP=""; APP_TOP_MBPS=""
  [[ -s "$SCRATCH/nettop.txt" ]] || return 0
  local line name mbps
  # nettop prints two samples; the second one is just the last 3 seconds. Add up each app and skip
  # our own tools (ping, curl, etc.).
  while IFS=$'\t' read -r name mbps; do
    case $name in
      bird|cloudd|fileproviderd) name="iCloud Drive ($name)";;
      cloudphotod|photolibraryd) name="iCloud Photos ($name)";;
      nsurlsessiond) name="Background downloads (nsurlsessiond)";;
      softwareupdated|com.apple.MobileSoftwareUpdate*) name="macOS updates ($name)";;
      backupd*) name="Time Machine ($name)";;
      avconferenced) name="FaceTime / video call ($name)";;
    esac
    APP_ROWS+=("$name"$'\t'"$mbps")
    [[ -z "$APP_TOP" ]] && { APP_TOP="$name"; APP_TOP_MBPS="$mbps"; }
  done < <(/usr/bin/awk -F, '/^,/ {blk++; next} blk==2 && NF>=3 {
      n=$1; sub(/\.[0-9]+$/,"",n)
      if (n ~ /^(ping|traceroute|curl|osascript|nettop|dig|networkQuality|sntp|zsh|awk|mDNSResponder)$/) next
      if (tolower(n) ~ /vpn|wireguard|pangps|globalprotect|zscaler|warp|forti|tailscale|netskope|twingate|openvpn|anyconnect|secureclient|nesessionmanager/) next
      b[n]+=$2+$3 }
    END { for (n in b) if (b[n]*8/3 >= 100000) printf "%s\t%.2f\n", n, b[n]*8/3/1000000 }' "$SCRATCH/nettop.txt" | /usr/bin/sort -t$'\t' -k2 -rn | /usr/bin/head -5)
  APPS_TOTAL_MBPS=$(/usr/bin/awk -F, '/^,/ {blk++; next} blk==2 && NF>=3 { n=$1; sub(/\.[0-9]+$/,"",n); if (n !~ /^(ping|traceroute|curl|osascript|nettop|dig|networkQuality|sntp)$/) t+=$2+$3 } END { printf "%.2f", t*8/3/1000000 }' "$SCRATCH/nettop.txt")
}
rate_text() { (( $1 >= 1 )) && print -r -- "$(r0 $1) Mbps" || print -r -- "$(r0 "$(calc "$1*1000")") Kbps"; }

# --- Device management (MDM) -----------------------------------------------------------------------
# Figures out if the Mac is enrolled in an MDM and which one (Jamf, Intune, Kandji...), then checks it
# can actually reach that server and Apple's push service. No setup needed, it reads what's on the Mac.
mgmt_info() {
  local out host
  out=$(/usr/bin/profiles status -type enrollment 2>/dev/null)
  MDM_ENROLLED=$(print -r -- "$out" | /usr/bin/awk -F': ' '/MDM enrollment/{print $2; exit}')     # "Yes (User Approved)" / "No"
  MDM_ADE=$(print -r -- "$out" | /usr/bin/awk -F': ' '/Enrolled via DEP/{print $2; exit}')         # Automated Device Enrollment
  # The MDM server address is only readable as root.
  MDM_URL=""
  (( amRoot )) && MDM_URL=$(/usr/sbin/system_profiler SPConfigurationProfileDataType 2>/dev/null | /usr/bin/awk -F'= ' '/ServerURL/{gsub(/[";]/,"",$2); print $2; exit}')
  JAMF_URL=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf jss_url 2>/dev/null)

  # Which MDM is it? Go by the server address if we have it, otherwise by which agent is installed.
  MDM_VENDOR=""
  case "${MDM_URL:l}" in
    *jamfcloud.com*|*jamf*) MDM_VENDOR="Jamf Pro";;
    *manage.microsoft.com*) MDM_VENDOR="Microsoft Intune";;
    *kandji*)               MDM_VENDOR="Kandji";;
    *mosyle*)               MDM_VENDOR="Mosyle";;
    *awmdm*|*airwatch*)     MDM_VENDOR="Workspace ONE";;
    *addigy*)               MDM_VENDOR="Addigy";;
    *jumpcloud*)            MDM_VENDOR="JumpCloud";;
    *simplemdm*)            MDM_VENDOR="SimpleMDM";;
    *hexnode*)              MDM_VENDOR="Hexnode";;
    *fleetdm*|*fleet*)      MDM_VENDOR="Fleet";;
  esac
  if [[ -z "$MDM_VENDOR" ]]; then
    if   [[ -n "$JAMF_URL" || -e /usr/local/jamf/bin/jamf ]]; then MDM_VENDOR="Jamf Pro"
    elif [[ -e "/Library/Intune/Microsoft Intune Agent.app" || -e "/Applications/Company Portal.app" ]]; then MDM_VENDOR="Microsoft Intune"
    elif [[ -e /Library/Kandji ]]; then MDM_VENDOR="Kandji"
    elif [[ -e "/Library/Application Support/Mosyle" || -e "/Applications/Self-Service.app/Contents/Info.plist" && -n "$(/usr/bin/defaults read "/Applications/Self-Service.app/Contents/Info" CFBundleIdentifier 2>/dev/null | /usr/bin/grep -i mosyle)" ]]; then MDM_VENDOR="Mosyle"
    elif [[ -e "/Applications/Workspace ONE Intelligent Hub.app" ]]; then MDM_VENDOR="Workspace ONE"
    elif [[ -e /Library/Addigy ]]; then MDM_VENDOR="Addigy"
    elif [[ -e /opt/jc ]]; then MDM_VENDOR="JumpCloud"
    fi
  fi

  # Can we reach the management server?
  MDM_HOST=""; MDM_REACH=""; MDM_MS=""; JAMF_HEALTH=""
  host="${MDM_URL:-$JAMF_URL}"; host="${host#*://}"; host="${host%%/*}"; host="${host%%:*}"
  [[ -z "$host" && "$MDM_VENDOR" == "Microsoft Intune" ]] && host="enrollment.manage.microsoft.com"
  if [[ -n "$host" ]]; then
    MDM_HOST="$host"
    read -r out MDM_MS <<< "$(/usr/bin/curl -s -o /dev/null -m 8 -w '%{http_code} %{time_connect}' "https://$host/" 2>/dev/null)"
    if [[ -n "$out" && "$out" != 000 ]]; then MDM_REACH=yes; MDM_MS=$(calc "$MDM_MS*1000"); else MDM_REACH=no; MDM_MS=""; fi
  fi
  if [[ -n "$JAMF_URL" ]]; then   # Jamf's own health check page returns "[]" when the server is happy
    out=$(/usr/bin/curl -s -m 8 "${JAMF_URL%/}/healthCheck.html" 2>/dev/null)
    [[ "$out" == "[]" ]] && JAMF_HEALTH="healthy" || JAMF_HEALTH="${out:-no answer}"
  fi

  # Apple Push (APNs) is how MDM commands, notifications, FaceTime and iMessage reach the Mac. It uses
  # port 5223, and can fall back to 443 if 5223 is blocked.
  APNS_5223=""; APNS_443=""
  local t0=$EPOCHREALTIME
  /usr/bin/nc -z -G 3 courier.push.apple.com 5223 >/dev/null 2>&1 && APNS_5223=$(calc "($EPOCHREALTIME-$t0)*1000")
  t0=$EPOCHREALTIME
  /usr/bin/nc -z -G 3 courier.push.apple.com 443 >/dev/null 2>&1 && APNS_443=$(calc "($EPOCHREALTIME-$t0)*1000")
  # Apple's enrollment service (used when a Mac enrolls or re-enrolls)
  APPLE_ENROLL=""
  out=$(/usr/bin/curl -s -o /dev/null -m 6 -w '%{http_code}' https://deviceenrollment.apple.com/ 2>/dev/null)
  [[ -n "$out" && "$out" != 000 ]] && APPLE_ENROLL=yes || APPLE_ENROLL=no
}

# --- VPN clients --------------------------------------------------------------------------------------
# Finds VPN apps that are installed or running, whether a tunnel is actually up (and if everything
# goes through it or just some traffic), and where the VPN server is. Nothing to configure: it reads the
# app settings, the Mac's VPN settings, and the routing table.
VPN_CLIENTS=(   # "name|app path|process name to look for"
  "GlobalProtect|/Applications/GlobalProtect.app|PanGPS"
  "Cisco Secure Client|/Applications/Cisco/Cisco Secure Client.app|vpnagentd"
  "Cisco AnyConnect|/Applications/Cisco/Cisco AnyConnect Secure Mobility Client.app|vpnagentd"
  "Zscaler|/Applications/Zscaler/Zscaler.app|ZscalerTunnel"
  "Cloudflare WARP|/Applications/Cloudflare WARP.app|CloudflareWARP"
  "FortiClient|/Applications/FortiClient.app|fctservctl2"
  "Ivanti Secure Access|/Applications/Ivanti Secure Access.app|dsAccessService"
  "Pulse Secure|/Applications/Pulse Secure.app|dsAccessService"
  "Check Point VPN|/Applications/Endpoint Security VPN.app|tracd"
  "F5 BIG-IP Edge|/Applications/BIG-IP Edge Client.app|svpn"
  "Netskope|/Applications/Netskope Client.app|Netskope Client"
  "Twingate|/Applications/Twingate.app|Twingate"
  "Tailscale|/Applications/Tailscale.app|IPNExtension"
  "OpenVPN Connect|/Applications/OpenVPN Connect.app|ovpnagent"
  "Tunnelblick|/Applications/Tunnelblick.app|openvpn"
  "WireGuard|/Applications/WireGuard.app|WireGuardNetworkExtension"
  "NordVPN|/Applications/NordVPN.app|NordVPN"
  "ProtonVPN|/Applications/ProtonVPN.app|ProtonVPN"
  "ExpressVPN|/Applications/ExpressVPN.app|expressvpnd"
  "Mullvad|/Applications/Mullvad VPN.app|mullvad-daemon"
)
# When a VPN is on, it adds a route so its own traffic to the server still goes out the normal
# Wi-Fi/Ethernet. That route gives the server's real address away.
vpn_server_from_routes() {
  [[ -n "$GATEWAY" ]] || return 0
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk -v gw="$GATEWAY" -v ifc="$PHYS_IF" \
    '$2==gw && $4==ifc && $3 ~ /H/ && $3 ~ /S/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^169\.254\./ {print $1; exit}'
}

vpn_info() {
  local e n app proc st i a flags
  VPN_APPS=""; VPN_RUNNING=""
  for e in $VPN_CLIENTS; do
    n="${e%%|*}"; app="${${e#*|}%|*}"; proc="${e##*|}"
    [[ -e "$app" ]] || /usr/bin/pgrep -qf -- "$proc" || continue
    # Running = something is running from inside the app, or its known background process is up
    if /usr/bin/pgrep -qf -- "$app/Contents/" || /usr/bin/pgrep -qf -- "$proc"; then st="running"; VPN_RUNNING+="${VPN_RUNNING:+, }$n"; else st="installed, not running"; fi
    VPN_APPS+="${VPN_APPS:+; }$n ($st)"
  done

  # Where each VPN connects to (read from the app's settings / the Mac's VPN settings)
  VPN_SERVERS=""
  a=$(/usr/bin/plutil -extract "Palo Alto Networks.GlobalProtect.PanSetup.Portal" raw /Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist 2>/dev/null)
  [[ -n "$a" ]] && VPN_SERVERS+="${VPN_SERVERS:+; }GlobalProtect portal $a"
  a=$(/usr/bin/grep -hoE '<HostAddress>[^<]+' /opt/cisco/secureclient/vpn/profile/*.xml /opt/cisco/anyconnect/profile/*.xml 2>/dev/null | /usr/bin/head -1 | /usr/bin/sed 's/<HostAddress>//')
  if [[ -n "$a" ]]; then
    [[ -e "/Applications/Cisco" ]] && VPN_SERVERS+="${VPN_SERVERS:+; }Cisco $a" || VPN_SERVERS+="${VPN_SERVERS:+; }Cisco $a (old profile, app not installed)"
  fi
  local line name
  while IFS= read -r line; do
    name=$(print -r -- "$line" | /usr/bin/awk -F'"' '{print $2}'); [[ -n "$name" ]] || continue
    a=$(/usr/sbin/scutil --nc show "$name" 2>/dev/null | /usr/bin/awk -F' : ' '/(Comm)?RemoteAddress/{print $2; exit}')
    [[ -n "$a" ]] && VPN_SERVERS+="${VPN_SERVERS:+; }$name $a"
  done < <(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep '"')

  # Is a tunnel actually up? macOS has a bunch of its own utun interfaces, but a real VPN tunnel has
  # an IPv4 address on it.
  VPN_TUNNELS=""; VPN_MODE=""
  for i in ${=$(/sbin/ifconfig -l)}; do
    [[ "$i" == (utun|ppp|ipsec|gpd|tun|tap|wg)* ]] || continue
    a=$(/sbin/ifconfig "$i" 2>/dev/null | /usr/bin/awk '/inet /{print $2; exit}')
    [[ -n "$a" && "$a" != 169.254.* ]] && VPN_TUNNELS+="${VPN_TUNNELS:+, }$i $a (MTU $(/sbin/ifconfig "$i" 2>/dev/null | /usr/bin/awk '/mtu /{print $NF; exit}'))"
  done
  if [[ -n "$VPN_TUNNELS" ]]; then
    (( VPN_ACTIVE )) && VPN_MODE="full tunnel (all traffic goes through the VPN)" || VPN_MODE="split tunnel (only some traffic goes through the VPN)"
  fi

  # The VPN server's real address: when a VPN is on, it adds a route so its own traffic to the server
  # still goes out the normal Wi-Fi/Ethernet. That route gives the server away.
  VPN_GW=""; VPN_GW_MS=""
  if [[ -n "$VPN_TUNNELS" && -n "$GATEWAY" ]]; then
    VPN_GW=$(vpn_server_from_routes)
    VPN_GW_NOTE=""
    if [[ -n "$VPN_GW" ]]; then
      if [[ -n "$VPN_PING_PID" ]]; then   # pinged back during the ping test
        wait $VPN_PING_PID 2>/dev/null
        VPN_GW_MS=$(/usr/bin/awk -F'/' '/round-trip/{printf "%.0f", $5}' "$SCRATCH/vpn_ping.txt" 2>/dev/null)
      else
        VPN_GW_MS=$(/sbin/ping -n -c 3 -i 0.3 -t 3 "$VPN_GW" 2>/dev/null | /usr/bin/awk -F'/' '/round-trip/{printf "%.0f", $5}')
      fi
      if [[ -z "$VPN_GW_MS" ]]; then
        # A lot of VPN servers ignore ping. A traceroute toward it still gets us the time to the last
        # router in front of it, which is close enough to tell how far away the server is. It was
        # started back during the ping test (it can take ~10 seconds), so just wait for it if needed.
        if [[ -n "$VPN_TRACE_PID" ]]; then
          for (( i=0; i<24; i++ )); do kill -0 $VPN_TRACE_PID 2>/dev/null || break; /bin/sleep 0.5; done
          kill $VPN_TRACE_PID 2>/dev/null; wait $VPN_TRACE_PID 2>/dev/null
        fi
        local last=$(parse_trace "$SCRATCH/vpn_trace.txt" | /usr/bin/awk -F'\t' '$3 != "-" {h=$2; t=$3} END{ if(h!="") print h, t }')
        if [[ -n "$last" ]]; then
          VPN_GW_MS=$(r0 "${last#* }")
          [[ "${last%% *}" != "$VPN_GW" ]] && VPN_GW_NOTE="measured to the last router before it, ${last%% *}"
        fi
      fi
    fi
  fi
  # More detail on the connected VPN: what kind it is, the gateway on the inside of the tunnel, the
  # server's name, and for split tunnels, which networks and domains go through it.
  VPN_TYPE=""; VPN_TGW=""; VPN_TGW_MS=""; VPN_HOST=""; VPN_ROUTES=""; VPN_ROUTE_COUNT=0; VPN_DOMAINS=""
  local tif="${${VPN_TUNNELS%%,*}%% *}" nc_line kind st
  if [[ -n "$tif" ]]; then
    # A VPN set up in the Mac's own settings shows up in scutil, which knows the type and inside gateway
    nc_line=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep '(Connected)' | /usr/bin/head -1)
    if [[ -n "$nc_line" ]]; then
      name=$(print -r -- "$nc_line" | /usr/bin/awk -F'"' '{print $2}')
      kind=$(print -r -- "$nc_line" | /usr/bin/sed -n 's/.*\[\(.*\)\].*/\1/p')
      case $kind in
        PPP:L2TP) VPN_TYPE="L2TP over IPsec (built into macOS)";;
        PPP:PPTP) VPN_TYPE="PPTP (built into macOS)";;
        IPSec)    VPN_TYPE="IPsec / Cisco IPsec (built into macOS)";;
        IKEv2)    VPN_TYPE="IKEv2 (built into macOS)";;
        VPN:*)    # name the protocol if the app's VPN extension gives it away
                  local prov=$(/usr/sbin/scutil --nc show "$name" 2>/dev/null | /usr/bin/awk -F' : ' '/NEProviderBundleIdentifier/{print tolower($2); exit}') proto=""
                  case $prov in *wireguard*) proto="WireGuard";; *openvpn*) proto="OpenVPN";; *ikev2*) proto="IKEv2";; *ipsec*) proto="IPsec";; esac
                  VPN_TYPE="App VPN${proto:+, $proto} (${kind#VPN:})";;
        *)        VPN_TYPE="$kind";;
      esac
      VPN_TYPE="$name · $VPN_TYPE"
      st=$(/usr/sbin/scutil --nc status "$name" 2>/dev/null)
      VPN_TGW=$(print -r -- "$st" | /usr/bin/awk '/DestAddresses/{f=1; next} f && /[0-9]+ : /{print $3; exit}')
      # VPN apps usually don't list a far-end address. Instead they add a single-address route to their
      # gateway inside the tunnel (often also their DNS server), so use that if it isn't our own address.
      if [[ -z "$VPN_TGW" ]]; then
        local own=$(print -r -- "$st" | /usr/bin/awk '/Addresses : <array>/ && !/Dest/{f=1; next} f && /[0-9]+ : /{print $3; exit}')
        VPN_TGW=$(print -r -- "$st" | /usr/bin/awk -v own="$own" '/DestinationAddress :/{d=$3} /SubnetMask : 255.255.255.255/ && d!="" && d!=own {print d; exit} /}/{d=""}')
      fi
      # VPN apps built on Apple's VPN framework often don't add the route we use to spot the server,
      # but they do tell macOS which server they're connected to. Use that if the route trick came up empty.
      if [[ -z "$VPN_GW" ]]; then
        # The VPN's own settings (RemoteAddress) are the most reliable. The live status has a
        # ServerAddress too, but VPN apps often fill that with a placeholder like 127.0.0.1.
        local srv=$(/usr/sbin/scutil --nc show "$name" 2>/dev/null | /usr/bin/awk -F' : ' '/ (Comm)?RemoteAddress :/{print $2; exit}')
        [[ -z "$srv" || "$srv" == (127.*|0.0.0.0|localhost) ]] && srv=$(print -r -- "$st" | /usr/bin/awk -F' : ' '/ ServerAddress :/{print $2; exit}')
        [[ "$srv" == (127.*|0.0.0.0|localhost) ]] && srv=""
        if [[ "$srv" == <->.<->.<->.<-> ]]; then VPN_GW="$srv"
        elif [[ -n "$srv" ]]; then VPN_HOST="$srv"; VPN_GW=$(/usr/bin/dig +short +time=2 +tries=1 "$srv" A 2>/dev/null | /usr/bin/grep -E '^[0-9.]+$' | /usr/bin/head -1); fi
        if [[ -n "$VPN_GW" ]]; then
          VPN_GW_MS=$(/sbin/ping -n -c 3 -i 0.3 -t 2 "$VPN_GW" 2>/dev/null | /usr/bin/awk -F'/' '/round-trip/{printf "%.0f", $5}')
          [[ -z "$VPN_GW_MS" ]] && VPN_GW_NOTE="doesn't answer ping"
        fi
      fi
      VPN_DOMAINS=$(print -r -- "$st" | /usr/bin/awk '/SupplementalMatchDomains/{f=1; next} f && /}/{f=0} f && /[0-9]+ : ./{print $3}' | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')
    elif [[ -n "$VPN_RUNNING" ]]; then
      VPN_TYPE="$VPN_RUNNING (app tunnel)"
    fi
    # Point-to-point tunnels also list the far end in ifconfig ("inet A --> B")
    [[ -z "$VPN_TGW" ]] && VPN_TGW=$(/sbin/ifconfig "$tif" 2>/dev/null | /usr/bin/awk '/inet / && $3=="-->" && $4!=$2 {print $4; exit}')
    # How long it takes to get through the tunnel to that gateway. If it ignores ping, the first hop
    # of the traceroute (which goes through the tunnel on a full-tunnel VPN) is the same router.
    if [[ -n "$VPN_TGW" ]]; then
      VPN_TGW_MS=$(/sbin/ping -n -c 3 -i 0.3 -t 2 "$VPN_TGW" 2>/dev/null | /usr/bin/awk -F'/' '/round-trip/{printf "%.0f", $5}')
      if [[ -z "$VPN_TGW_MS" && -n "${hops[1]}" ]]; then
        local -a h1=("${(@ps:\t:)hops[1]}")
        [[ "${h1[2]}" == "$VPN_TGW" ]] && isnum "${h1[3]}" && VPN_TGW_MS=$(r0 "${h1[3]}")
      fi
    fi
    # Split tunnel: which networks are sent into the tunnel (skip the per-host entries macOS adds itself)
    if (( ! VPN_ACTIVE )); then
      local -a nets=(${(f)"$(/usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk -v i="$tif" '$4==i && $3 !~ /W/ && $1!="default" && $1 !~ /^(169\.254|224\.|255\.)/ {print $1}' | /usr/bin/awk '!s[$0]++')"})
      VPN_ROUTE_COUNT=${#nets}
      (( ${#nets} )) && VPN_ROUTES="${(j:, :)nets[1,6]}$( (( ${#nets} > 6 )) && print " …")"
    fi
    # DNS domains sent to the VPN's DNS (from the resolver tied to the tunnel), if scutil didn't say
    [[ -z "$VPN_DOMAINS" ]] && VPN_DOMAINS=$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/awk -v i="($tif)" '/^resolver/{d=""} /^  domain/{d=$3} /if_index/ && index($0,i) && d!="" {print d; d=""}' | /usr/bin/awk '!s[$0]++' | /usr/bin/head -5 | /usr/bin/paste -sd, - | /usr/bin/sed 's/,/, /g')
  fi
  # The VPN server's name, if it has one
  if [[ -n "$VPN_GW" && -z "$VPN_HOST" ]]; then
    VPN_HOST=$(/usr/bin/dig +short +time=1 +tries=1 -x "$VPN_GW" 2>/dev/null | /usr/bin/head -1 | /usr/bin/sed 's/\.$//')
  fi

  # DNS servers the VPN pushed (resolvers tied to a tunnel interface)
  VPN_DNS=$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/awk '/^resolver/{ns=""} /nameserver\[/{ns=ns (ns==""?"":", ") $3} /if_index/ && /(utun|ppp|ipsec)/ && ns!="" {print ns; ns=""}' | /usr/bin/awk '!s[$0]++' | /usr/bin/head -2 | /usr/bin/paste -sd';' -)
}

# --- Speed ------------------------------------------------------------------------
# Both of these fill in the download/upload speed and the lag with and without load.
speed_apple() {
  local f="$SCRATCH/nq.json" rpm
  local pid
  # -s runs download first, then upload. If they run at the same time (Apple's default) they fight
  # over the Wi-Fi and the download number comes out way too low.
  /usr/bin/networkQuality -c -s -M "$SPEED_MAX_SECONDS" > "$f" 2>/dev/null & pid=$!
  throughput_monitor $pid both; wait $pid
  if [[ ! -s "$f" ]]; then /usr/bin/networkQuality -c -s > "$f" 2>/dev/null & pid=$!; throughput_monitor $pid both; wait $pid; fi
  local dl=$(/usr/bin/plutil -extract dl_throughput raw -o - "$f" 2>/dev/null)
  local ul=$(/usr/bin/plutil -extract ul_throughput raw -o - "$f" 2>/dev/null)
  isnum "$dl" || return 1
  DL_MBPS=$(calc "$dl/1000000"); UL_MBPS=$(calc "${ul:-0}/1000000")
  IDLE_MS=$(/usr/bin/plutil -extract base_rtt raw -o - "$f" 2>/dev/null)
  # Lag while busy: use whichever was worse, the download half or the upload half.
  local k v; rpm=""
  for k in dl_responsiveness ul_responsiveness responsiveness; do
    v=$(/usr/bin/plutil -extract $k raw -o - "$f" 2>/dev/null)
    isnum "$v" && (( v > 0 )) && { [[ -z "$rpm" ]] || (( v < rpm )) } && rpm=$v
  done
  [[ -n "$rpm" ]] && LOADED_MS=$(calc "60000/$rpm")
  SPEED_SERVER="Apple ($(/usr/bin/plutil -extract test_endpoint raw -o - "$f" 2>/dev/null))"
  SPEED_NOTE="Multi-stream (peak) test, download then upload — macOS networkQuality"
}

speed_cloudflare() {
  local up="$SCRATCH/upload.bin" t lp="$SCRATCH/loaded.txt" pid
  # Keep pinging during the download so we can see how much the lag goes up (bufferbloat)
  /sbin/ping -n -i 0.5 -W 1000 "${INTERNET_TARGETS[1]}" > "$lp" 2>&1 & pid=$!
  /usr/bin/curl -s -o /dev/null -m "$SPEED_MAX_SECONDS" -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=$CF_DOWN_BYTES" > "$SCRATCH/cf_down.txt" 2>/dev/null &
  local cpid=$!; throughput_monitor $cpid down; wait $cpid; t=$(<"$SCRATCH/cf_down.txt")
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  isnum "$t" && (( t > 0 )) || return 1
  DL_MBPS=$(calc "$t*8/1000000")
  spin_status 3 "Testing upload speed" "Uploading to speed.cloudflare.com…" $(( (P_SPD[1]+P_SPD[2])/2 )) ${P_SPD[2]} $(( SPEED_MAX_SECONDS/2 + 1 ))
  /bin/dd if=/dev/zero of="$up" bs=1000000 count=$(( CF_UP_BYTES / 1000000 )) 2>/dev/null
  /usr/bin/curl -s -o /dev/null -m "$SPEED_MAX_SECONDS" -w '%{speed_upload}' --data-binary @"$up" "https://speed.cloudflare.com/__up" > "$SCRATCH/cf_up.txt" 2>/dev/null &
  cpid=$!; throughput_monitor $cpid up; wait $cpid; t=$(<"$SCRATCH/cf_up.txt")
  isnum "$t" && UL_MBPS=$(calc "$t*8/1000000")
  local PING_COUNT=9999; ping_stats "$lp"; isnum "$P_AVG" && LOADED_MS="$P_AVG"
  IDLE_MS="$INET_LAT"
  SPEED_SERVER="Cloudflare (speed.cloudflare.com)"
  SPEED_NOTE="Single-stream test — speed.cloudflare.com"
}

# --- Simulation mode (for testing) ----------------------------------------------------------------
# Makes up the test results for a scenario (weak Wi-Fi, no internet, etc.) and then runs the exact
# same scoring, findings, and windows as a real test. That way you can see what a user would see
# without actually breaking a network. You can combine them:
#   NHC_SIMULATE=weak-wifi,vpn ./Network_Health_Check.sh
SIM_SCENARIOS=(healthy not-connected no-internet captive-portal packet-loss outage ping-blocked slow-dns
               bufferbloat slow-speed weak-wifi 2ghz vpn broken-ipv6 router-bottleneck isp-problem
               clock-skew proxy slow-ethernet wifi-drops bandwidth-hog mdm-unreachable all-bad)

simulate_run() {
  sim_sleep() { [[ "$ACTION_MODE" == verbose ]] && /bin/sleep "$1"; return 0; }   # silent mode doesn't need the pauses
  local sc="$SIMULATE" i host
  [[ "$sc" == all-bad ]] && sc="weak-wifi,packet-loss,outage,slow-dns,bufferbloat,slow-speed,vpn,broken-ipv6,clock-skew,proxy,wifi-drops,bandwidth-hog,mdm-unreachable"
  sim() { [[ ",$sc," == *",$1,"* ]]; }
  RUN_SUBTITLE="SIMULATION ($SIMULATE) · $RUN_SUBTITLE"
  logMe INFO "SIMULATION MODE — scenario: $SIMULATE (nothing is actually measured)"

  if sim not-connected; then
    sim_sleep 1
    NET_SCORE=0; RESP_SCORE=0; REL_SCORE=0
    HEADLINE="Not Connected"; SUBHEADLINE="This Mac isn't connected to a network. Turn on Wi-Fi or plug in Ethernet, then run the check again."
    finding na "SIMULATED RESULTS (scenario: $SIMULATE) — nothing was actually measured."
    finding bad "No active Wi-Fi or Ethernet connection was found."
    section "Connection" "network"; row "Status" "Not connected" bad
    return 1
  fi

  # Start from a healthy network -----------------------------------------------------
  CONN_TYPE="Wi-Fi"; PHYS_IF="en0"; PORT_NAME="Wi-Fi"; LOCAL_IP="192.168.1.50"; GATEWAY="192.168.1.1"; DNS_SERVERS="192.168.1.1"
  VPN_ACTIVE=0; VPN_NAME=""; PUB_IP="203.0.113.25"; PUB_ISP="Example Internet Co. (simulated)"; PUB_LOC="Anytown, USA"; CF_COLO="ATL"; CF_WARP="off"
  mac_info
  NET_MASK="255.255.255.0"; DHCP_SERVER="192.168.1.1"; DHCP_LEASE=86400; DHCP_DOMAIN=""; SEARCH_DOMAINS=""
  IF_MAC="aa:bb:cc:dd:ee:ff"; IF_MTU=1500; IF_MEDIA="autoselect"; IPV6_ADDR=""; IPV6_NET=""; OTHER_IFS=""
  PROXY_DESC=""; NE_LIST=""; VPN_CONFIGS=""
  WIFI_SSID="Simulated-WiFi"; WIFI_RSSI=-55; WIFI_NOISE=-95; WIFI_TX=866; WIFI_CH=149; WIFI_BAND=5; WIFI_WIDTH=80
  WIFI_PHY="802.11ax (Wi-Fi 6)"; WIFI_SEC="WPA2 Personal"; WIFI_BSSID=""; WIFI_MCS=""; WIFI_NSS=""; WIFI_CCA=""
  WIFI_NEARBY=12; WIFI_COCHAN=1; WIFI_COCHAN_STRONG=0; WS_MIN=-58; WS_AVG=-55; WS_MAX=-52; WS_TXMIN=780; WS_TXMAX=866; WS_CHANS=149
  NO_INTERNET=0; INET_METHOD="ICMP ping"; INET_LAT=18; INET_JIT=3; INET_LOSS=0; INET_LAG=18; REL_PCT=100; OUTAGE_EVENTS=0; OUTAGE_LONGEST_S=0
  ROUTER_OK=1; R_METHOD="ping"; R_LAT=3; R_JIT=1; R_LOSS=0; R_LAG=3; ISP_HOP="203.0.113.1"; ISP_HOP_MS=9
  WEB_TTFB=120; WEB_DNS=15; web_fail=0; DNS_CFG_AVG=12; DNS_PUB_BEST=10
  CAPTIVE="none"; PMTU=1500; CLOCK_OFF_MS=12
  DL_MBPS=250; UL_MBPS=40; IDLE_MS=18; LOADED_MS=35; SPEED_SERVER="Simulated server"; SPEED_NOTE="Simulated result"
  c0=(0 0 0 0); c1=(0 0 0 0)
  HIST_DROPS=0; HIST_LAST=""; HIST_LAST_DUR=""; HIST_LONGEST=0; APP_ROWS=(); APP_TOP=""; APP_TOP_MBPS=""
  MDM_ENROLLED="Yes (User Approved)"; MDM_ADE="Yes"; MDM_VENDOR="Jamf Pro"; MDM_URL=""; JAMF_URL="https://example.jamfcloud.com/"
  MDM_HOST="example.jamfcloud.com"; MDM_REACH=yes; MDM_MS=42; JAMF_HEALTH="healthy"; APNS_5223=35; APNS_443=30; APPLE_ENROLL=yes
  VPN_APPS="GlobalProtect (running)"; VPN_RUNNING="GlobalProtect"; VPN_SERVERS="GlobalProtect portal vpn.example.com"; VPN_TUNNELS=""; VPN_MODE=""; VPN_GW=""; VPN_GW_MS=""; VPN_DNS=""
  VPN_TYPE=""; VPN_TGW=""; VPN_TGW_MS=""; VPN_HOST=""; VPN_ROUTES=""; VPN_ROUTE_COUNT=0; VPN_DOMAINS=""

  # Then break whatever the scenario says to break -----------------------------------
  sim weak-wifi   && { WIFI_RSSI=-78; WIFI_NOISE=-92; WS_MIN=-84; WS_AVG=-78; WS_MAX=-72; WIFI_TX=29; WS_TXMIN=6; WS_TXMAX=58; INET_JIT=38; INET_LAT=44; INET_LAG=52; INET_LOSS=1.5; R_LAT=28; R_JIT=22; R_LAG=31; }
  sim 2ghz        && { WIFI_BAND=2.4; WIFI_CH=6; WIFI_WIDTH=20; WIFI_TX=72; WS_TXMIN=58; WS_TXMAX=72; WS_CHANS=6; WIFI_COCHAN=9; WIFI_COCHAN_STRONG=6; WIFI_PHY="802.11n (Wi-Fi 4)"; }
  sim packet-loss && { INET_LOSS=6.5; INET_LAT=35; INET_LAG=96; INET_JIT=24; }
  sim outage      && { REL_PCT=86.0; OUTAGE_EVENTS=3; OUTAGE_LONGEST_S=4.5; }
  sim ping-blocked && { INET_METHOD="HTTPS connect (ICMP blocked)"; ROUTER_OK=0; PMTU=""; INET_LAT=24; INET_LAG=24; }
  sim slow-dns    && { DNS_CFG_AVG=240; WEB_DNS=260; WEB_TTFB=520; }
  sim bufferbloat && { LOADED_MS=640; }
  sim slow-speed  && { DL_MBPS=6.2; UL_MBPS=0.9; LOADED_MS=310; }
  sim vpn         && { VPN_TUNNELS="utun4 10.20.30.40 (MTU 1400)"; VPN_MODE="full tunnel (all traffic goes through the VPN)"; VPN_GW="203.0.113.77"; VPN_GW_MS=38; VPN_DNS="10.20.0.10, 10.20.0.11"
                       VPN_TYPE="GlobalProtect (app tunnel)"; VPN_TGW="10.20.30.1"; VPN_TGW_MS=41; VPN_HOST="gp-east.vpn.example.com"; VPN_DOMAINS="corp.example.com"; }
  sim vpn         && { VPN_ACTIVE=1; VPN_NAME="Corporate VPN (simulated)"; PMTU=1400; INET_LAT=$(( INET_LAT + 30 )); INET_LAG=$(( INET_LAG + 30 )); VPN_CONFIGS="Corporate VPN (Connected)"; NE_LIST="Example VPN Extension"; }
  sim broken-ipv6 && { IPV6_ADDR="2001:db8::50"; IPV6_NET="broken"; }
  sim router-bottleneck && { R_LAT=118; R_JIT=45; R_LAG=140; R_LOSS=4; INET_LAT=150; INET_LAG=170; INET_JIT=48; }
  sim isp-problem && { R_LAT=3; R_LAG=3; ISP_HOP_MS=150; INET_LAT=185; INET_LAG=190; INET_JIT=12; }
  sim clock-skew  && { CLOCK_OFF_MS=312000; }
  sim wifi-drops  && { HIST_DROPS=5; HIST_LAST=$(( EPOCHSECONDS - 2400 )); HIST_LAST_DUR=48; HIST_LONGEST=190; }
  sim bandwidth-hog && { APP_ROWS=("OneDrive"$'\t'"38.5" "iCloud Drive (bird)"$'\t'"4.2" "Slack"$'\t'"0.1"); APP_TOP="OneDrive"; APP_TOP_MBPS=38.5; DL_MBPS=18; }
  sim mdm-unreachable && { MDM_REACH=no; MDM_MS=""; JAMF_HEALTH="no answer"; APNS_5223=""; APNS_443=""; }
  sim proxy       && { PROXY_DESC="PAC http://proxy.example.com/proxy.pac"; }
  sim slow-ethernet && { CONN_TYPE="Ethernet"; PHYS_IF="en5"; PORT_NAME="USB 10/100 LAN"; IF_MEDIA="autoselect (100baseTX <half-duplex>)"; DL_MBPS=88; UL_MBPS=85; }
  if sim captive-portal || sim no-internet; then
    NO_INTERNET=1; INET_LAT="-"; INET_JIT="-"; INET_LOSS=100; INET_LAG="-"; REL_PCT=0; OUTAGE_EVENTS=1; OUTAGE_LONGEST_S=$TEST_SECONDS
    ISP_HOP=""; PMTU=""; DL_MBPS=""; UL_MBPS=""; IDLE_MS=""; LOADED_MS=""; WEB_TTFB="-"; WEB_DNS="-"; DNS_CFG_AVG=""; DNS_PUB_BEST=""
    CAPTIVE="unknown"; sim captive-portal && CAPTIVE="detected"
  fi

  LOSS_EFF=$INET_LOSS; INET_LOST_N=$(( ${INET_LOSS%.*} > 0 || ${INET_LOSS#*.} > 0 ? 3 : 0 )); ONE_TARGET_LOSS=""

  # Build the detail rows from the made-up numbers -----------------------------------
  if (( NO_INTERNET )); then
    tgt_rows=("1.1.1.1"$'\t'"No reply (ping blocked or unreachable)"$'\t'"na" "8.8.8.8"$'\t'"No reply (ping blocked or unreachable)"$'\t'"na")
  else
    tgt_rows=("1.1.1.1"$'\t'"$(ms $INET_LAT) avg · jitter $(ms $INET_JIT) · ${INET_LOSS}% loss"$'\t'"$(lag_status $INET_LAG)"
              "8.8.8.8"$'\t'"$(ms $(( ${INET_LAT%.*} + 4 ))) avg · jitter $(ms $INET_JIT) · ${INET_LOSS}% loss"$'\t'"$(lag_status $INET_LAG)")
    hops=("1"$'\t'"$GATEWAY"$'\t'"$R_LAT"$'\t'"0" "2"$'\t'"$ISP_HOP"$'\t'"$ISP_HOP_MS"$'\t'"0" "3"$'\t'"*"$'\t'"-"$'\t'"3" "4"$'\t'"1.1.1.1"$'\t'"$INET_LAT"$'\t'"0")
    DNS_ROWS=("Your DNS 192.168.1.1"$'\t'"$DNS_CFG_AVG ms avg"$'\t'"$( (( DNS_CFG_AVG > 150 )) && print bad || print good)"
              "Cloudflare 1.1.1.1"$'\t'"10 ms avg"$'\t'"good" "Google 8.8.8.8"$'\t'"14 ms avg"$'\t'"good")
    for (( i=1; i<=${#WEB_TARGETS}; i++ )); do
      host="${WEB_TARGETS[$i]#https://}"; host="${host%%/*}"
      web_rows+=("$host"$'\t'"first byte $(ms $(( ${WEB_TTFB%.*} + i*9 ))) · DNS $(ms $WEB_DNS) · TLS $(ms 60) · HTTP/2"$'\t'"$( (( WEB_TTFB > 400 )) && print ok || print good)")
    done
    n_web=${#WEB_TARGETS}
  fi
  (( ! NO_INTERNET )) || [[ "$CAPTIVE" != detected ]] || { web_fail=${#WEB_TARGETS}; for (( i=1; i<=${#WEB_TARGETS}; i++ )); do host="${WEB_TARGETS[$i]#https://}"; web_rows+=("${host%%/*}"$'\t'"Failed to load"$'\t'"bad"); done; }
  finding na "SIMULATED RESULTS (scenario: $SIMULATE) — nothing was actually measured."

  # Walk the progress window through each step with fake live numbers ----------------
  local v; local -a sp sd su
  fact "b:$CONN_TYPE" "connected on $PHYS_IF  ·  IP $LOCAL_IP"; fact "w:$PUB_ISP" "internet provider  ·  $PUB_LOC"
  [[ "$CONN_TYPE" == Wi-Fi ]] && fact "$( (( WIFI_RSSI < -70 )) && print r || { (( WIFI_RSSI < -65 )) && print o || print g; }):$WIFI_RSSI dBm" "Wi-Fi signal  ·  $WIFI_BAND GHz  ·  channel $WIFI_CH"
  check_cancel; sim_sleep 2; mark connect
  spin_status 1 "Measuring responsiveness & reliability" "Simulated ping test…" ${P_RSP[1]} ${P_RSP[2]} 6 1
  for (( i=0; i<12; i++ )); do
    check_cancel
    if (( NO_INTERNET )); then live_metric "o:no reply" "ping to 1.1.1.1  ·  simulated" ""
    else v=$(( ${INET_LAT%.*} + (RANDOM % (${INET_JIT%.*} + 2)) )); sp+=($v); live_metric "$(lag_code $v):$v ms" "ping to 1.1.1.1  ·  simulated" "${(j:,:)sp}"; fi
    sim_sleep 0.5
  done
  mark responsiveness
  (( NO_INTERNET )) || fact "$(lag_code $INET_LAG):$(r0 $INET_LAG) ms" "internet lag  ·  jitter $(ms $INET_JIT)  ·  ${INET_LOSS}% loss"
  spin_status 2 "Testing websites & DNS" "Simulated…" ${P_WEB[1]} ${P_WEB[2]} 3
  (( NO_INTERNET )) || fact "g:All ${#WEB_TARGETS} loaded" "websites"
  check_cancel; sim_sleep 2; mark web_dns
  if [[ "$SPEED_ENGINE" != off ]] && (( ! NO_INTERNET )); then
    spin_status 3 "Testing download & upload speed" "Simulated…" ${P_SPD[1]} ${P_SPD[2]} 6
    for (( i=0; i<12; i++ )); do
      check_cancel
      if (( i < 6 )); then v=$(r0 "$(calc "$DL_MBPS*(0.7+($RANDOM%30)/100)")"); sd+=($v); live_metric "c:↓ $v" "Mbps right now" "${(j:,:)sd}" ""
      else v=$(r0 "$(calc "$UL_MBPS*(0.7+($RANDOM%30)/100)")"); su+=($v); live_metric "p:↑ $v" "Mbps right now" "" "${(j:,:)su}"; fi
      sim_sleep 0.5
    done
    fact "c:↓ $(r0 $DL_MBPS)|w:    |p:↑ $(r0 $UL_MBPS)" "Mbps  ·  final result"
    mark speed
  else
    DL_MBPS=""; UL_MBPS=""
  fi
  return 0
}

SCRIPT_VERSION="1.1"

# --- Step timing ------------------------------------------------------------------------------------
# mark <step name> - writes down how long that step took. Shows up in the log, report, and JSON.
mark() { local n=$EPOCHREALTIME; TIMINGS+=("$1 $(calc "$n-$T_LAST")"); T_LAST=$n; }
timings_text() { local t out=""; for t in $TIMINGS; do out+="${out:+ · }${t% *} ${t#* }s"; done; print -r -- "$out · total $(calc "$EPOCHREALTIME-$T_START")s"; }

# --- Cancel -------------------------------------------------------------------------------------------
# When the user clicks Cancel, the window writes to CANCEL_FILE. We check it in every loop and between
# steps, and if it's there we clean up and quit.
check_cancel() {
  [[ -s "$CANCEL_FILE" ]] || return 0
  logMe INFO "User cancelled the test."
  kill_spinner; stop_children
  exit 0      # the user cancelling isn't an error, so Jamf shouldn't mark the policy as failed
}

# --- JSON results (optional) ----------------------------------------------------------------------
# If SAVE_JSON=true, each run saves last.json and adds a line to history.jsonl. Handy for comparing
# before and after a fix, or for a Jamf Extension Attribute to read the last score.
jstr() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/ }"; print -rn -- "\"$s\""; }
jnum() { isnum "$1" && print -rn -- "$1" || print -rn -- null; }
write_json() {
  [[ "$SAVE_JSON" == true ]] || return 0
  /bin/mkdir -p "$JSON_DIR" 2>/dev/null
  [[ -w "$JSON_DIR" ]] || { logMe INFO "JSON: $JSON_DIR not writable (run as root) — skipped."; return 0; }
  local f="$JSON_DIR/last.json" tag txt first=1 t
  {
    print -r -- "{"
    print -r -- "  \"timestamp\": $(jstr "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"), \"script_version\": $(jstr "$SCRIPT_VERSION"),"
    print -r -- "  \"computer\": $(jstr "$(/usr/sbin/scutil --get ComputerName 2>/dev/null)"), \"serial\": $(jstr "$(device_serial)"), \"user\": $(jstr "$targetUser"),"
    print -r -- "  \"simulated\": $([[ -n $SIMULATE ]] && jstr "$SIMULATE" || print -n null), \"mode\": $(jstr "$ACTION_MODE"), \"test_seconds\": $TEST_SECONDS,"
    print -r -- "  \"scores\": {\"network\": $(jnum $NET_SCORE), \"band\": $(jstr "$(band_label $NET_SCORE)"), \"responsiveness\": $(jnum $RESP_SCORE), \"reliability\": $(jnum $REL_SCORE), \"speed\": $(jnum "$SPEED_SCORE")},"
    print -r -- "  \"headline\": $(jstr "$HEADLINE"), \"video_calls\": $(jstr "$VIDEO_TEXT"),"
    print -r -- "  \"connection\": {\"type\": $(jstr "$CONN_TYPE"), \"interface\": $(jstr "$PHYS_IF"), \"ssid\": $(jstr "$WIFI_SSID"), \"ip\": $(jstr "$LOCAL_IP"), \"router\": $(jstr "$GATEWAY"), \"dns\": $(jstr "$DNS_SERVERS"), \"public_ip\": $(jstr "$PUB_IP"), \"isp\": $(jstr "$PUB_ISP"), \"vpn\": $(jstr "$VPN_NAME")},"
    print -r -- "  \"wifi\": {\"rssi\": $(jnum "$WIFI_RSSI"), \"noise\": $(jnum "$WIFI_NOISE"), \"band_ghz\": $(jnum "$WIFI_BAND"), \"channel\": $(jnum "$WIFI_CH"), \"width_mhz\": $(jnum "$WIFI_WIDTH"), \"tx_mbps\": $(jnum "$WIFI_TX"), \"rssi_min\": $(jnum "$WS_MIN"), \"rssi_max\": $(jnum "$WS_MAX")},"
    print -r -- "  \"responsiveness\": {\"lag_ms\": $(jnum "$INET_LAG"), \"latency_ms\": $(jnum "$INET_LAT"), \"jitter_ms\": $(jnum "$INET_JIT"), \"loss_pct\": $(jnum "$INET_LOSS"), \"router_ms\": $(jnum "$R_LAT"), \"isp_hop_ms\": $(jnum "$ISP_HOP_MS"), \"method\": $(jstr "$INET_METHOD")},"
    print -r -- "  \"reliability\": {\"responsive_pct\": $(jnum "$REL_PCT"), \"outages\": $(jnum "$OUTAGE_EVENTS"), \"longest_outage_s\": $(jnum "$OUTAGE_LONGEST_S")},"
    print -r -- "  \"speed\": {\"down_mbps\": $(jnum "$DL_MBPS"), \"up_mbps\": $(jnum "$UL_MBPS"), \"idle_ms\": $(jnum "$IDLE_MS"), \"loaded_ms\": $(jnum "$LOADED_MS"), \"bufferbloat\": $(jstr "$BLOAT_GRADE")},"
    print -r -- "  \"web\": {\"ttfb_ms\": $(jnum "$WEB_TTFB"), \"dns_ms\": $(jnum "$WEB_DNS"), \"failures\": $(jnum "$web_fail"), \"dns_server_ms\": $(jnum "$DNS_CFG_AVG"), \"public_dns_ms\": $(jnum "$DNS_PUB_BEST")},"
    print -r -- "  \"history_24h\": {\"drops_while_awake\": $(jnum "$HIST_DROPS"), \"last_drop\": $(isnum "$HIST_LAST" && jstr "$(strftime '%Y-%m-%dT%H:%M:%S' $HIST_LAST)" || print -n null), \"longest_s\": $(jnum "$HIST_LONGEST")},"
    print -r -- "  \"top_app\": {\"name\": $(jstr "$APP_TOP"), \"mbps\": $(jnum "$APP_TOP_MBPS")},"
    print -r -- "  \"management\": {\"mdm\": $(jstr "$MDM_ENROLLED"), \"ade\": $(jstr "$MDM_ADE"), \"vendor\": $(jstr "$MDM_VENDOR"), \"server\": $(jstr "$MDM_HOST"), \"server_reachable\": $(jstr "$MDM_REACH"), \"apns_5223_ms\": $(jnum "$APNS_5223"), \"apns_443_ms\": $(jnum "$APNS_443")},"
    print -r -- "  \"vpn\": {\"apps\": $(jstr "$VPN_APPS"), \"tunnels\": $(jstr "$VPN_TUNNELS"), \"mode\": $(jstr "$VPN_MODE"), \"server\": $(jstr "$VPN_GW"), \"server_name\": $(jstr "$VPN_HOST"), \"server_ms\": $(jnum "$VPN_GW_MS"), \"type\": $(jstr "$VPN_TYPE"), \"tunnel_gateway\": $(jstr "$VPN_TGW"), \"tunnel_gateway_ms\": $(jnum "$VPN_TGW_MS"), \"split_routes\": $(jnum "$VPN_ROUTE_COUNT"), \"dns_domains\": $(jstr "$VPN_DOMAINS")},"
    print -r -- "  \"checks\": {\"captive_portal\": $(jstr "$CAPTIVE"), \"ipv6\": $(jstr "${IPV6_NET:-not configured}"), \"path_mtu\": $(jnum "$PMTU"), \"clock_offset_ms\": $(jnum "$CLOCK_OFF_MS"), \"proxy\": $(jstr "$PROXY_DESC")},"
    print -rn -- "  \"timings_s\": {"; first=1
    for t in $TIMINGS; do (( first )) || print -rn -- ", "; first=0; print -rn -- "$(jstr "${t% *}"): ${t#* }"; done
    print -r -- "},"
    print -rn -- "  \"findings\": ["; first=1
    while IFS=$'\t' read -r tag txt; do (( first )) || print -rn -- ", "; first=0; print -rn -- "{\"status\": $(jstr "$tag"), \"text\": $(jstr "$txt")}"; done < "$FIND_FILE"
    print -r -- "]"
    print -r -- "}"
  } > "$f"
  # add a one-line copy to the history file, and only keep the last JSON_HISTORY_MAX runs
  /usr/bin/tr -d '\n' < "$f" | /usr/bin/sed 's/  */ /g' >> "$JSON_DIR/history.jsonl"; print >> "$JSON_DIR/history.jsonl"
  /usr/bin/tail -n "$JSON_HISTORY_MAX" "$JSON_DIR/history.jsonl" > "$JSON_DIR/.h.tmp" 2>/dev/null && /bin/mv "$JSON_DIR/.h.tmp" "$JSON_DIR/history.jsonl"
  /bin/chmod 644 "$f" "$JSON_DIR/history.jsonl" 2>/dev/null
  logMe INFO "JSON results written: $f"
}

####################################################################################################
#
# Run all the tests, then build the scores, findings, and results rows
#
####################################################################################################
run_tests() {
  : > "$DATA_FILE"; : > "$FIND_FILE"
  NET_SCORE=0; RESP_SCORE=0; REL_SCORE=0; SPEED_SCORE=""; DL_MBPS=""; UL_MBPS=""; IDLE_MS=""; LOADED_MS=""
  RUN_SUBTITLE="$(/usr/sbin/scutil --get ComputerName 2>/dev/null) · $(/bin/date '+%b %-d, %Y at %-I:%M %p')"
  VIDEO_STATUS="na"; VIDEO_TEXT=""
  local t pct s i f host
  local -a inet_files ping_pids ok_lists tgt_rows hops web_rows web_spark c0 c1
  local n_ok=0 sum_lat=0 sum_jit=0 sum_loss=0 sum_lag=0 n_web=0 sum_ttfb=0 sum_dns=0 web_fail=0
  typeset -ga TIMINGS DNS_ROWS; TIMINGS=(); DNS_ROWS=(); T_START=$EPOCHREALTIME; T_LAST=$EPOCHREALTIME
  : > "$LIVE_FILE"

  # How much of the progress bar each step gets. The speed test is the longest, so it gets the most.
  typeset -ga P_CON P_RSP P_WEB P_SPD P_SCR
  if [[ "$SPEED_ENGINE" == off ]]; then P_CON=(0 12) P_RSP=(12 72) P_WEB=(72 96) P_SPD=(96 96) P_SCR=(96 100)
  else                                  P_CON=(0 8)  P_RSP=(8 46)  P_WEB=(46 62) P_SPD=(62 96) P_SCR=(96 100); fi

  # 1. Connection ------------------------------------------------------------
  spin_status 0 "Looking at your connection" "Gathering network details…" ${P_CON[1]} ${P_CON[2]} 4
  if [[ -n "$SIMULATE" ]]; then
    simulate_run || return 1
  else
  if ! detect_connection; then
    logMe ERROR "No active network connection found."
    NET_SCORE=0; RESP_SCORE=0; REL_SCORE=0
    HEADLINE="Not Connected"; SUBHEADLINE="This Mac isn't connected to a network. Turn on Wi-Fi or plug in Ethernet, then run the check again."
    finding bad "No active Wi-Fi or Ethernet connection was found."
    section "Connection" "network"; row "Status" "Not connected" bad
    return 1
  fi
  fact "b:$CONN_TYPE" "connected on $PHYS_IF  ·  IP $LOCAL_IP"
  mac_info; net_config
  lookup_public_ip; cf_edge
  [[ -n "$PUB_ISP" ]] && fact "w:${PUB_ISP}" "internet provider${PUB_LOC:+  ·  $PUB_LOC}"
  if [[ "$CONN_TYPE" == "Wi-Fi" ]]; then
    wifi_info; wifi_neighbors
    if isnum "$WIFI_RSSI"; then
      s=g; (( WIFI_RSSI < -65 )) && s=o; (( WIFI_RSSI < -70 )) && s=r
      fact "$s:$WIFI_RSSI dBm" "Wi-Fi signal  ·  ${WIFI_BAND:+$WIFI_BAND GHz  ·  }${WIFI_CH:+channel $WIFI_CH}"
    fi
  fi
  logMe INFO "Interface $PHYS_IF ($PORT_NAME) ip=$LOCAL_IP gw=$GATEWAY vpn=$VPN_ACTIVE public=$PUB_IP"
  check_cancel; mark connect

  # 2. Responsiveness: start the pings, plus traceroute and Wi-Fi readings in the background --------
  local router_file="$SCRATCH/ping_router.txt" trace_file="$SCRATCH/trace.txt" wifi_file="$SCRATCH/wifi_samples.txt"
  : > "$router_file"; : > "$trace_file"; : > "$wifi_file"
  c0=($(counters))
  for (( i=1; i<=${#INTERNET_TARGETS}; i++ )); do
    f="$SCRATCH/ping_inet_$i.txt"; inet_files+=("$f")
    ping_run "${INTERNET_TARGETS[$i]}" "$f" & ping_pids+=($!)
  done
  [[ -n "$GATEWAY" ]] && { ping_run "$GATEWAY" "$router_file" "$PHYS_IF" & ping_pids+=($!); }
  /usr/sbin/traceroute -n -q 3 -w 1 -m 12 "${INTERNET_TARGETS[1]}" > "$trace_file" 2>/dev/null & local trace_pid=$!
  VPN_TRACE_PID=""; VPN_PING_PID=""
  if (( VPN_ACTIVE )); then   # trace toward the VPN server now, since it can take a while (see vpn_info)
    local vs=$(vpn_server_from_routes)
    [[ -n "$vs" ]] && { /usr/sbin/traceroute -n -q 1 -w 1 -m 16 "$vs" > "$SCRATCH/vpn_trace.txt" 2>/dev/null & VPN_TRACE_PID=$!
                        /sbin/ping -n -c 5 -i 0.5 -t 5 "$vs" > "$SCRATCH/vpn_ping.txt" 2>/dev/null & VPN_PING_PID=$!; }
  fi
  history_collect & local hist_pid=$!     # last 24h of connection drops (reads the Mac's logs)
  apps_collect & local apps_pid=$!        # which apps are using the network right now
  local wifi_pid=""; [[ "$CONN_TYPE" == "Wi-Fi" ]] && { wifi_sampler "$(( TEST_SECONDS > 2 ? TEST_SECONDS - 1 : 1 ))" "$wifi_file" & wifi_pid=$!; }

  local start=$SECONDS last; local -a lspk
  spin_status 1 "Measuring responsiveness & reliability" "Pinging ${(j:, :)INTERNET_TARGETS}${GATEWAY:+ and your router} for ${TEST_SECONDS}s…" ${P_RSP[1]} ${P_RSP[2]} $TEST_SECONDS 1
  pings_running() { local p; for p in $ping_pids; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
  while pings_running && (( SECONDS - start < TEST_SECONDS + 5 )); do
    check_cancel
    t=$(( TEST_SECONDS - (SECONDS - start) )); (( t < 0 )) && t=0
    if [[ "$ACTION_MODE" == verbose ]]; then
      # The live number on screen uses its own quick ping. The real pings only write to their files in
      # chunks, so reading those would make the number jump around. (This one is just for show, the
      # actual results come from the real pings.)
      last=$(/sbin/ping -n -c 1 -t 1 "${INTERNET_TARGETS[1]}" 2>/dev/null | /usr/bin/awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')
      if isnum "$last"; then lspk+=($last); (( ${#lspk} > 40 )) && lspk=(${lspk[-40,-1]})
        live_metric "$(lag_code $last):$(r0 $last) ms" "ping to ${INTERNET_TARGETS[1]}  ·  ${t}s left" "${(j:,:)lspk}"
      else live_metric "o:no reply" "ping to ${INTERNET_TARGETS[1]}  ·  ${t}s left" "${(j:,:)lspk}"; fi
      /bin/sleep 0.4
    else
      /bin/sleep 0.5
    fi
  done
  kill $ping_pids 2>/dev/null; wait $ping_pids 2>/dev/null
  # give traceroute a few more seconds to finish, then stop it
  for (( i=0; i<12; i++ )); do check_cancel; kill -0 $trace_pid 2>/dev/null || break; /bin/sleep 0.5; done
  kill $trace_pid 2>/dev/null; wait $trace_pid 2>/dev/null
  # the log reader and app check usually finish well before the pings, but give them a moment if not
  for (( i=0; i<20; i++ )); do check_cancel; kill -0 $hist_pid 2>/dev/null || kill -0 $apps_pid 2>/dev/null || break; /bin/sleep 0.5; done
  kill_tree $hist_pid; kill_tree $apps_pid; wait $hist_pid $apps_pid 2>/dev/null
  history_parse; apps_parse
  # the Wi-Fi reader only saves when it's done, so give it a moment instead of cutting it off
  if [[ -n "$wifi_pid" ]]; then
    for (( i=0; i<8; i++ )); do kill -0 $wifi_pid 2>/dev/null || break; /bin/sleep 0.5; done
    kill $wifi_pid 2>/dev/null; wait $wifi_pid 2>/dev/null
  fi

  # Crunch the ping results for each internet target. We keep track of the lowest loss and lag too:
  # real packet loss on the connection shows up on EVERY target, so if only one server is dropping
  # pings, that's the server limiting ping (common on VPNs), not the user's connection.
  local min_loss=999 min_lag=999999 max_loss=0 lossy="" min_lost_n=0
  local -a T_LAT T_JIT T_LOSS T_LAG
  track() { local n=0; [[ "$P_LOST" != "-" ]] && n=${#${(s:,:)P_LOST}}
            T_LAT+=($P_AVG); T_JIT+=($P_JIT); T_LOSS+=($P_LOSS); T_LAG+=($P_LAG)
            (( P_LOSS < min_loss )) && { min_loss=$P_LOSS; min_lost_n=$n; }; (( P_LAG < min_lag )) && min_lag=$P_LAG
            (( P_LOSS > max_loss )) && { max_loss=$P_LOSS; lossy="$1"; }; }
  INET_METHOD="ICMP ping"
  for (( i=1; i<=${#INTERNET_TARGETS}; i++ )); do
    ping_stats "${inet_files[$i]}"
    if (( P_RECV > 0 )); then
      (( n_ok++ )); ok_lists+=("$P_LOST"); track "${INTERNET_TARGETS[$i]}"
      sum_lat=$(calc "$sum_lat+$P_AVG"); sum_jit=$(calc "$sum_jit+$P_JIT"); sum_loss=$(calc "$sum_loss+$P_LOSS"); sum_lag=$(calc "$sum_lag+$P_LAG")
      tgt_rows+=("${INTERNET_TARGETS[$i]}"$'\t'"$(ms $P_AVG) avg ($(ms $P_MIN)–$(ms $P_MAX)) · jitter $(ms $P_JIT) · ${P_LOSS}% loss"$'\t'"$(lag_status $P_LAG)")
    else
      tgt_rows+=("${INTERNET_TARGETS[$i]}"$'\t'"No reply (ping blocked or unreachable)"$'\t'"na")
    fi
  done

  # Ping blocked everywhere? Then time HTTPS connections instead
  if (( n_ok == 0 )); then
    INET_METHOD="HTTPS connect (ICMP blocked)"
    tgt_rows=()
    for (( i=1; i<=${#HTTPS_FALLBACK_TARGETS}; i++ )); do
      host="${HTTPS_FALLBACK_TARGETS[$i]}"; f="$SCRATCH/http_$i.txt"
      spin_status 1 "Measuring responsiveness" "Ping is blocked — timing HTTPS connections to ${host#https://}…" ${P_RSP[2]} ${P_WEB[1]} $TEST_SECONDS
      http_probe "$host" "$f"; ping_stats "$f"
      if (( P_RECV > 0 )); then
        (( n_ok++ )); ok_lists+=("$P_LOST"); track "${host#https://}"
        sum_lat=$(calc "$sum_lat+$P_AVG"); sum_jit=$(calc "$sum_jit+$P_JIT"); sum_loss=$(calc "$sum_loss+$P_LOSS"); sum_lag=$(calc "$sum_lag+$P_LAG")
        tgt_rows+=("${host#https://}"$'\t'"$(ms $P_AVG) · jitter $(ms $P_JIT) · ${P_LOSS}% fail"$'\t'"$(lag_status $P_LAG)")
      else
        tgt_rows+=("${host#https://}"$'\t'"Unreachable"$'\t'"bad")
      fi
    done
  fi

  NO_INTERNET=0
  if (( n_ok == 0 )); then
    NO_INTERNET=1; INET_LAT="-"; INET_JIT="-"; INET_LOSS=100; INET_LAG="-"; REL_PCT=0; OUTAGE_LONGEST_S=$TEST_SECONDS; OUTAGE_EVENTS=1
    LOSS_EFF=100; INET_LOST_N=$PING_COUNT
  else
    # Average latency, jitter and lag over the same servers, leaving out any server that lost a lot
    # more pings than the best one (that's the server limiting ping, see below). Loss = the best server's.
    local k=0 sl=0 sj=0 sg=0
    for (( i=1; i<=${#T_LAT}; i++ )); do
      (( T_LOSS[i] <= min_loss + 5 )) || continue
      (( k++ )); sl=$(calc "$sl+${T_LAT[i]}"); sj=$(calc "$sj+${T_JIT[i]}"); sg=$(calc "$sg+${T_LAG[i]}")
    done
    INET_LAT=$(calc "$sl/$k"); INET_JIT=$(calc "$sj/$k"); INET_LAG=$(calc "$sg/$k"); INET_LOSS=$min_loss
    # One lost ping out of ~40 is just noise, so it doesn't count against the score or the findings
    INET_LOST_N=$min_lost_n; LOSS_EFF=$INET_LOSS; (( INET_LOST_N <= 1 )) && LOSS_EFF=0
    # remember if one server dropped a lot more than the rest, so we can explain it
    ONE_TARGET_LOSS=""; (( n_ok > 1 && max_loss >= 5 && max_loss - min_loss >= 5 )) && ONE_TARGET_LOSS="$lossy $max_loss"
    reliability_calc "${(j:;:)ok_lists}"
    fact "$(lag_code $INET_LAG):$(r0 $INET_LAG) ms" "internet lag  ·  jitter $(ms $INET_JIT)  ·  ${INET_LOSS}% loss"
  fi

  # The router: try ping first, and if it ignores ping, use the traceroute trick
  ROUTER_OK=0; R_METHOD=""
  if [[ -n "$GATEWAY" ]]; then
    ping_stats "$router_file"
    if (( P_RECV > 0 )); then R_METHOD="ping"
    else local pc=$PING_COUNT; router_trace "$router_file"; PING_COUNT=10; ping_stats "$router_file"; PING_COUNT=$pc
         if (( P_RECV > 0 )) && is_private_ip "$R_RESPONDER"; then
           R_METHOD="traceroute (router ignores ping$([[ $R_RESPONDER != $GATEWAY ]] && print "; answered as $R_RESPONDER"))"
           P_LOSS="-"; P_LAG=$P_AVG     # routers limit how often they answer these, so missing replies here aren't real packet loss
         else P_RECV=0; fi
    fi
    if (( P_RECV > 0 )); then ROUTER_OK=1; R_LAT=$P_AVG; R_JIT=$P_JIT; R_LOSS=$P_LOSS; R_LAG=$P_LAG; fi
  fi

  # The traceroute hops, and the first hop that belongs to the ISP
  hops=("${(@f)$(parse_trace "$trace_file")}")
  ISP_HOP=""; ISP_HOP_MS=""
  for t in $hops; do local -a p=("${(@ps:\t:)t}")
    [[ "${p[2]}" != "*" ]] && ! is_private_ip "${p[2]}" && isnum "${p[3]}" && { ISP_HOP="${p[2]}"; ISP_HOP_MS="${p[3]}"; break; }
  done

  # How the Wi-Fi signal did during the test
  WS_MIN=""; WS_AVG=""; WS_MAX=""; WS_TXMIN=""; WS_TXMAX=""; WS_CHANS=""
  if [[ -s "$wifi_file" ]]; then
    read -r WS_MIN WS_AVG WS_MAX WS_TXMIN WS_TXMAX WS_CHANS <<< "$(/usr/bin/awk '$1<0{ n++; s+=$1; if(!mn||$1<mn)mn=$1; if(!mx||$1>mx)mx=$1;
      if(!tn||$3<tn)tn=$3; if($3>tx)tx=$3; if(!(($4) in c)){c[$4]=1; ch=ch (ch==""?"":"/") $4} }
      END{ if(n) printf "%d %.0f %d %.0f %.0f %s\n", mn, s/n, mx, tn, tx, ch }' "$wifi_file")"
  fi

  check_cancel; mark responsiveness

  # 3. Websites, DNS, and the other quick checks -----------------------------------------
  local code dns conn tls ttfb hv rip; local -a failed_sites
  if (( ! NO_INTERNET )); then
    spin_status 2 "Testing websites & DNS" "Loading ${#WEB_TARGETS} common sites…" ${P_WEB[1]} ${P_WEB[2]} $(( ${#WEB_TARGETS} + 4 ))
    for (( i=1; i<=${#WEB_TARGETS}; i++ )); do
      check_cancel
      host="${WEB_TARGETS[$i]#https://}"; host="${host%%/*}"
      local try
      for try in 1 2; do     # try twice, so one random blip doesn't show up as a failed site
        read -r code dns conn tls ttfb hv rip <<< "$(/usr/bin/curl -s -o /dev/null -m 6 -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{http_version} %{remote_ip}' "${WEB_TARGETS[$i]}" 2>/dev/null)"
        [[ -n "$code" && "$code" != 000 ]] && break
      done
      if [[ -n "$code" && "$code" != 000 ]] && isnum "$ttfb"; then
        dns=$(calc "$dns*1000"); ttfb=$(calc "$ttfb*1000"); conn=$(calc "$conn*1000"); tls=$(calc "$tls*1000")
        (( n_web++ )); sum_ttfb=$(calc "$sum_ttfb+$ttfb"); sum_dns=$(calc "$sum_dns+$dns")
        s=good; (( ttfb > 400 )) && s=ok; (( ttfb > 1000 )) && s=bad
        web_rows+=("$host"$'\t'"first byte $(ms $ttfb) · DNS $(ms $dns) · TLS done $(ms $tls) · HTTP/$hv"$'\t'"$s")
        web_spark+=($ttfb); live_metric "$(stat_code $s):$(r0 $ttfb) ms" "first byte  ·  $host" "${(j:,:)web_spark}"
      else
        (( web_fail++ )); web_rows+=("$host"$'\t'"Failed to load"$'\t'"bad"); failed_sites+=("$host")
      fi
    done
    if (( web_fail )); then fact "g:$(( ${#WEB_TARGETS} - web_fail )) loaded|w:  ·  |r:$web_fail failed" "websites  ·  ${(j:, :)failed_sites} didn't load"
    else fact "g:All ${#WEB_TARGETS} loaded" "websites"; fi
    spin_status 2 "Testing websites & DNS" "Timing DNS servers, checking IPv6, MTU and clock…" ${P_WEB[1]} ${P_WEB[2]} 4
    dns_tests
    [[ -n "$DNS_CFG_AVG" && "$DNS_CFG_AVG" != 9999 ]] && fact "$( (( DNS_CFG_AVG > 150 )) && print r || { (( DNS_CFG_AVG > 60 )) && print o || print g; })":"$DNS_CFG_AVG ms" "your DNS server lookup time"
  fi
  (( n_web )) && { WEB_TTFB=$(calc "$sum_ttfb/$n_web"); WEB_DNS=$(calc "$sum_dns/$n_web"); } || { WEB_TTFB="-"; WEB_DNS="-"; }
  misc_checks
  mgmt_info; vpn_info
  check_cancel; mark web_dns

  # 4. Speed ------------------------------------------------------------------------
  local engine="$SPEED_ENGINE"; (( NO_INTERNET )) && engine="off"
  if [[ "$engine" != off ]]; then
    fact "w:…" "Mbps right now  ·  starting speed test"
    spin_status 3 "Testing download & upload speed" "Up to ${SPEED_MAX_SECONDS}s — this is the longest step" ${P_SPD[1]} ${P_SPD[2]} $(( SPEED_MAX_SECONDS + 3 ))
    if [[ "$engine" == apple ]] && [[ -x /usr/bin/networkQuality ]]; then
      speed_apple || { logMe INFO "networkQuality failed — falling back to Cloudflare"; speed_cloudflare; }
    else
      speed_cloudflare
    fi
    isnum "$DL_MBPS" && fact "c:↓ $(r0 $DL_MBPS)|w:    |p:↑ $(r0 ${UL_MBPS:-0})" "Mbps  ·  final result"
    mark speed
  fi
  c1=($(counters))
  fi   # done with the real tests (simulation mode fills in the same things itself)

  # How many errors/resends happened during the test (worked out before scoring, see below)
  local ierr=$(( ${c1[1]:-0} - ${c0[1]:-0} )) oerr=$(( ${c1[2]:-0} - ${c0[2]:-0} ))
  local tsent=$(( ${c1[3]:-0} - ${c0[3]:-0} )) tretx=$(( ${c1[4]:-0} - ${c0[4]:-0} )) retx_pct=""
  (( tsent > 100 )) && retx_pct=$(calc "$tretx*100/$tsent")
  # If pings are getting lost but real (TCP) traffic barely needs resending, it's the pings being
  # dropped somewhere along the way, not the connection losing traffic. Don't score it as real loss.
  PING_ONLY_LOSS=0
  if (( LOSS_EFF >= 2 )) && [[ -n "$retx_pct" ]] && (( retx_pct < 2 )); then
    PING_ONLY_LOSS=1; LOSS_EFF=0; INET_LAG=$INET_LAT     # lag's lost-packet penalty doesn't apply to real traffic
  fi

  # 5. Scores -------------------------------------------------------------------------
  spin_status 4 "Scoring results" "Crunching the numbers…" ${P_SCR[1]} 99 1
  # Responsiveness is mostly based on lag.
  if (( NO_INTERNET )); then RESP_SCORE=0; else RESP_SCORE=$(interp "$INET_LAG" "0:100 20:100 50:92 100:78 200:55 400:25 800:0"); fi
  # Bufferbloat grade: how much worse the lag gets when the connection is busy
  BLOAT_MS=""; BLOAT_GRADE=""
  if isnum "$LOADED_MS" && isnum "$IDLE_MS"; then
    BLOAT_MS=$(calc "$LOADED_MS-$IDLE_MS"); (( BLOAT_MS < 0 )) && BLOAT_MS=0
    if   (( BLOAT_MS < 30 ));  then BLOAT_GRADE="A"
    elif (( BLOAT_MS < 60 ));  then BLOAT_GRADE="B"
    elif (( BLOAT_MS < 200 )); then BLOAT_GRADE="C"
    elif (( BLOAT_MS < 400 )); then BLOAT_GRADE="D"
    else BLOAT_GRADE="F"; fi
  fi
  # Then take points off for the stuff people really notice that lag alone doesn't show: jitter
  # (choppy calls), packet loss, and lag that shoots up when the connection is busy.
  if (( ! NO_INTERNET )); then
    local pen=0
    isnum "$INET_JIT" && (( INET_JIT > 10 )) && pen=$(calc "$pen+($INET_JIT-10)*0.5")
    isnum "$LOSS_EFF" && pen=$(calc "$pen+$LOSS_EFF*4")
    case $BLOAT_GRADE in C) pen=$(calc "$pen+3");; D) pen=$(calc "$pen+8");; F) pen=$(calc "$pen+15");; esac
    RESP_SCORE=$(r0 "$(calc "$RESP_SCORE-$pen")"); (( RESP_SCORE < 0 )) && RESP_SCORE=0
  fi
  REL_SCORE=$(interp "$REL_PCT" "0:0 70:0 90:50 97:75 99:90 100:100")
  if isnum "$DL_MBPS"; then
    local dls=$(interp "$DL_MBPS" "0:0 5:30 10:50 25:70 50:80 100:88 200:95 500:100")
    local uls=$(interp "${UL_MBPS:-0}" "0:0 1:20 5:50 10:70 20:80 50:90 100:100")
    SPEED_SCORE=$(r0 "$(calc "0.6*$dls+0.4*$uls")")
    NET_SCORE=$(r0 "$(calc "0.6*$RESP_SCORE+0.4*$SPEED_SCORE")")
  else
    NET_SCORE=$RESP_SCORE
  fi
  # If the connection dropped out (reliability under 90), pull the overall score down too
  (( REL_SCORE < 90 )) && NET_SCORE=$(r0 "$(calc "$NET_SCORE*$REL_SCORE/90")")

  # Video call check, based on what Zoom and Teams recommend (lag 150 ms or less, jitter 30 ms or
  # less, under 1% loss)
  if (( NO_INTERNET )); then VIDEO_STATUS=bad; VIDEO_TEXT="Not ready — no internet"
  elif (( INET_LAT <= 150 && INET_JIT <= 30 && LOSS_EFF < 1 && REL_SCORE >= 90 )); then
    VIDEO_STATUS=good; VIDEO_TEXT="Ready"
    [[ "$BLOAT_GRADE" == [DF] ]] && { VIDEO_STATUS=ok; VIDEO_TEXT="Ready, but may stutter during big uploads/downloads"; }
  elif (( INET_LAT <= 250 && INET_JIT <= 50 && LOSS_EFF < 3 )); then VIDEO_STATUS=ok; VIDEO_TEXT="Usable — may stutter or freeze at times"
  else VIDEO_STATUS=bad; VIDEO_TEXT="Poor — expect freezing, robotic audio, or drops"; fi

  # The headline (like "Fast & Responsive") depends on how responsiveness and speed did
  local rgood=0 sgood=0; (( RESP_SCORE >= 80 )) && rgood=1; [[ -n "$SPEED_SCORE" ]] && (( SPEED_SCORE >= 80 )) && sgood=1
  if (( NO_INTERNET )); then
    HEADLINE="No Internet"; SUBHEADLINE="Connected to ${CONN_TYPE}, but nothing on the internet answered. Check the network, captive portal, or VPN."
  elif (( REL_SCORE < 75 )); then
    HEADLINE="Unstable Connection"; SUBHEADLINE="Your connection dropped out during the test. Calls, uploads, and remote sessions may disconnect."
  elif (( LOSS_EFF >= 2 )) && [[ "$(lag_status $INET_LAT)" != bad ]]; then
    HEADLINE="$([[ -n $SPEED_SCORE ]] && (( SPEED_SCORE >= 80 )) && print "Fast but Dropping Packets" || print "Dropping Packets")"
    SUBHEADLINE="Response times are fine, but ${INET_LOSS}% of packets are getting lost. Video calls may freeze or cut out, and pages may stall."
  elif [[ -z "$SPEED_SCORE" ]]; then
    (( rgood )) && { HEADLINE="Responsive"; SUBHEADLINE="Quick to react — good for calls, browsing, and remote sessions. (Speed test skipped.)"; } \
                || { HEADLINE="Laggy"; SUBHEADLINE="Slow to react — calls and remote sessions may stutter. (Speed test skipped.)"; }
  elif (( rgood && sgood )); then HEADLINE="Fast & Responsive"; SUBHEADLINE="Your connection is quick to react and has plenty of bandwidth. You're good to go."
  elif (( rgood ));          then HEADLINE="Responsive but Slow"; SUBHEADLINE="Quick to react, but bandwidth is limited — large downloads, uploads, and HD video may be slow."
  elif (( sgood ));          then HEADLINE="Fast but Laggy"; SUBHEADLINE="Plenty of bandwidth, but slow to react — video calls, gaming, and remote sessions may stutter."
  else                            HEADLINE="Laggy & Slow"; SUBHEADLINE="Your connection is slow to react and short on bandwidth. Most online work will feel sluggish."
  fi


  # 6. Findings - the plain-English "What we found" list -------------------------------
  (( VPN_ACTIVE )) && finding na "Connected through a VPN (${VPN_NAME}) — internet results reflect the VPN path."
  [[ "$CAPTIVE" == detected ]] && finding bad "A captive portal (sign-in page) is intercepting traffic — open a browser and finish signing in to this network."
  if (( NO_INTERNET )); then
    finding bad "Nothing on the internet responded — check the cable/Wi-Fi, captive portal, or firewall."
  else
    local lat_bad=0; [[ "$(lag_status $INET_LAG)" == bad ]] && lat_bad=1
    if (( ROUTER_OK )); then
      if [[ "$(lag_status $R_LAG)" != good || "$(loss_status $R_LOSS)" == bad ]] && (( lat_bad )) || [[ "$(loss_status $R_LOSS)" == bad ]]; then
        finding bad "Delays start at your own ${CONN_TYPE}/router (router $(ms $R_LAG)$(isnum $R_LOSS && print ", ${R_LOSS}% loss")) — the local network is the bottleneck."
      elif (( lat_bad )); then
        finding bad "Your router responds fine ($(ms $R_LAG)) — the slowdown is beyond it, at your internet provider or further out."
      fi
    elif [[ -n "$GATEWAY" ]]; then
      finding na "Your router didn't answer ping or traceroute, so the local hop couldn't be measured separately."
    fi
    if (( LOSS_EFF >= 2 || PING_ONLY_LOSS )); then
      # Work out WHERE the loss is from what we already measured, instead of guessing
      local where="" confirm=""
      local wifi_ok=1; [[ "$CONN_TYPE" == "Wi-Fi" ]] && isnum "$WIFI_RSSI" && (( WIFI_RSSI < -70 )) && wifi_ok=0
      local router_ok=0; (( ROUTER_OK )) && [[ "$(lag_status $R_LAG)" == good ]] && router_ok=1
      if (( ! wifi_ok )); then where="most likely from the weak Wi-Fi signal"
      elif (( router_ok && VPN_ACTIVE )); then where="your Wi-Fi and router look fine, so it's happening on the VPN connection. Try a different VPN server or protocol"
      elif (( router_ok )); then where="your Wi-Fi and router look fine, so it's happening past your network (internet provider or further out)"
      else where="congestion or interference on the network is the likely cause"; fi
      # TCP resends (root only) tell us if real traffic is being lost too, or just pings
      if [[ -n "$retx_pct" ]]; then
        (( retx_pct >= 2 )) && confirm=" Real traffic is being resent too (${retx_pct}% TCP resends)." \
                             || confirm=" Real traffic isn't being resent much (${retx_pct}% TCP resends), so this may mostly be pings getting dropped."
      fi
      if (( PING_ONLY_LOSS )); then
        finding ok "${INET_LOSS}% of pings were lost, but real traffic barely needed resending (${retx_pct}% TCP resends), so it's most likely just pings being dropped along the way$( (( VPN_ACTIVE )) && print " (common on VPNs)"), not a real problem."
      else
        finding bad "${INET_LOSS}% packet loss: $where.$confirm"
      fi
    elif (( INET_JIT > 30 )); then
      finding ok "High jitter ($(ms $INET_JIT)) — response times swing a lot, typical of busy or weak Wi-Fi. Calls may sound choppy."
    fi
    if [[ -n "$ONE_TARGET_LOSS" ]]; then
      finding na "${ONE_TARGET_LOSS% *} ignored ${ONE_TARGET_LOSS#* }% of pings, but the other server didn't. That's the server limiting ping (common on VPNs), not your connection."
    fi
    (( OUTAGE_EVENTS > 0 )) && finding bad "Connection went unresponsive ${OUTAGE_EVENTS}× during the test (longest ${OUTAGE_LONGEST_S}s)."
    (( web_fail > 0 )) && finding bad "$( (( web_fail == 1 )) && print "${failed_sites[1]} didn't load." || print "$web_fail of ${#WEB_TARGETS} test websites didn't load (${(j:, :)failed_sites}).")"
    if [[ -n "$DNS_CFG_AVG" ]] && (( DNS_CFG_AVG > 80 )) && [[ -n "$DNS_PUB_BEST" ]] && (( DNS_CFG_AVG > 2 * DNS_PUB_BEST )); then
      finding ok "Your DNS server is slow ($( (( DNS_CFG_AVG == 9999 )) && print "not answering" || print "$DNS_CFG_AVG ms")) — public DNS answers in $DNS_PUB_BEST ms. Every new site starts slower."
    fi
    [[ "$BLOAT_GRADE" == [DF] ]] && finding bad "Bufferbloat grade $BLOAT_GRADE — latency jumps +$(ms $BLOAT_MS) when the connection is busy. Calls lag during uploads/downloads."
    [[ "$BLOAT_GRADE" == C ]] && finding ok "Bufferbloat grade C — latency rises +$(ms $BLOAT_MS) under load."
    if [[ -n "$SPEED_SCORE" ]] && (( SPEED_SCORE < 60 )); then
      finding ok "Speed is low (↓ $(r0 $DL_MBPS) / ↑ $(r0 ${UL_MBPS:-0}) Mbps) — Wi-Fi signal, router limits, congestion, or VPN can all cap it."
    fi
    [[ "$IPV6_NET" == broken ]] && finding bad "IPv6 is configured but doesn't reach the internet — sites may hang a few seconds before loading."
    [[ -n "$PMTU" ]] && (( PMTU < 1500 )) && finding ok "Path MTU is $PMTU (below 1500) — can break large packets on VPNs and some apps."
  fi
  if isnum "$CLOCK_OFF_MS" && (( ${CLOCK_OFF_MS#-} > 60000 )); then
    finding bad "The Mac's clock is off by $(( ${CLOCK_OFF_MS#-} / 1000 ))s — this breaks secure sites, VPN, and sign-ins."
  fi
  [[ -n "$PROXY_DESC" ]] && finding na "A proxy is configured ($PROXY_DESC)."
  [[ "$CONN_TYPE" == Ethernet && "$IF_MEDIA" == *(10baseT|100baseTX|half-duplex)* ]] && finding bad "Ethernet link is only $IF_MEDIA — check the cable, dock, or switch port."
  if [[ "$CONN_TYPE" == "Wi-Fi" ]] && isnum "$WIFI_RSSI"; then
    (( WIFI_RSSI < -70 )) && finding bad "Weak Wi-Fi signal ($WIFI_RSSI dBm) — move closer to the access point or use Ethernet."
    (( WIFI_RSSI >= -70 && WIFI_RSSI < -65 )) && finding ok "Wi-Fi signal is fair ($WIFI_RSSI dBm) — closer to the access point would help."
    isnum "$WS_MIN" && (( WS_MIN < -75 && WIFI_RSSI >= -70 )) && finding ok "Wi-Fi signal dipped to $WS_MIN dBm during the test."
    [[ "$WS_CHANS" == */* ]] && finding ok "Wi-Fi switched channels during the test ($WS_CHANS) — roaming between access points or bands."
    [[ "$WIFI_BAND" == "2.4" ]] && finding ok "Connected on 2.4 GHz — slower and more crowded than 5/6 GHz."
    isnum "$WIFI_COCHAN_STRONG" && (( WIFI_COCHAN_STRONG >= 4 )) && finding ok "$WIFI_COCHAN_STRONG other strong access points share Wi-Fi channel $WIFI_CH — interference likely."
    isnum "${WIFI_CCA%%[^0-9]*}" && (( ${WIFI_CCA%%[^0-9]*} >= 50 )) && finding ok "Wi-Fi channel is busy ${WIFI_CCA} of the time — congestion."
  fi
  if isnum "$HIST_DROPS" && (( HIST_DROPS > 0 )); then
    finding "$( (( HIST_DROPS >= 3 )) && print bad || print ok)" "Your connection dropped $HIST_DROPS time$( (( HIST_DROPS > 1 )) && print s) in the last 24 hours while the Mac was awake (last at $(when_text $HIST_LAST), down $(dur_text $HIST_LAST_DUR))."
  fi
  if isnum "$APP_TOP_MBPS" && (( APP_TOP_MBPS >= 5 )); then
    finding ok "${APP_TOP} was using $(rate_text $APP_TOP_MBPS) during the test. Other apps using the network can make things feel slow and lower the speed results."
  fi
  if [[ "$MDM_ENROLLED" == Yes* && "$MDM_REACH" == no ]]; then
    finding bad "This Mac can't reach its management server ($MDM_HOST). Policies, apps and updates from IT won't come through."
  fi
  [[ -n "$JAMF_HEALTH" && "$JAMF_HEALTH" != healthy ]] && finding ok "The Jamf server's health check didn't come back healthy ($JAMF_HEALTH)."
  [[ "$MDM_ENROLLED" == "Yes" ]] && finding ok "MDM enrollment isn't user-approved, so some management features won't work."
  if [[ -z "$APNS_5223" && -z "$APNS_443" ]] && (( ! NO_INTERNET )); then
    finding bad "Can't reach Apple's push service. MDM commands, notifications, FaceTime and iMessage may not arrive."
  fi
  if isnum "$VPN_TGW_MS" && isnum "$VPN_GW_MS" && (( VPN_TGW_MS > VPN_GW_MS * 3 / 2 + 30 )); then
    finding ok "The VPN itself is adding delay: $VPN_GW_MS ms to reach the VPN server, but $VPN_TGW_MS ms through the tunnel. The VPN server may be overloaded."
  fi
  isnum "$VPN_GW_MS" && (( VPN_GW_MS > 100 )) && finding ok "The VPN server is slow to reach ($VPN_GW_MS ms), and everything goes through it."
  (( ierr + oerr > 0 )) && finding ok "$(( ierr + oerr )) network interface errors during the test."
  [[ -n "$retx_pct" ]] && (( retx_pct >= 2 )) && finding ok "TCP retransmits at ${retx_pct}% — packets are being lost and resent."
  [[ "$MAC_LOWPOWER" == 1 ]] && finding na "Low Power Mode is on — it can limit network performance."
  [[ -s "$FIND_FILE" ]] || finding good "No problems found — your connection looks healthy."
  # Don't say "you're good to go" if there are red problems in the list.
  local nbad=$(/usr/bin/grep -c "^bad" "$FIND_FILE")
  if (( nbad > 0 && NET_SCORE >= 80 )); then
    SUBHEADLINE="Speed and responsiveness look good, but we found $nbad issue$( (( nbad > 1 )) && print s) below that can still cause problems."
  fi

  # Finish up: fill the bar to 100%, flash the score, then open the results window.
  if [[ "$ACTION_MODE" == verbose ]]; then
    fact "$(band_code $NET_SCORE):$NET_SCORE" "Network Score  ·  $(band_label $NET_SCORE)  ·  Video calls: ${VIDEO_TEXT%% —*}"
    spin_status 5 "All done — $HEADLINE" "Opening your results…" 100 100 0.1
    /bin/sleep 2.5
  fi

  # 7. Detail rows - the stuff users care about first, then the "For IT" section --------------
  section "Connection" "network"
  row "Connection type" "$CONN_TYPE ($PHYS_IF)" na
  [[ "$CONN_TYPE" == "Wi-Fi" ]] && row "Network name" "$WIFI_SSID" na
  [[ -n "$PUB_ISP" ]] && row "$( (( VPN_ACTIVE )) && print "Internet provider (VPN's)" || print "Internet provider")" "$PUB_ISP${PUB_LOC:+ · $PUB_LOC}" na
  row "VPN" "$( (( VPN_ACTIVE )) && print -r -- "$VPN_NAME (on)" || print Off)" na
  row "Video calls" "$VIDEO_TEXT" "$VIDEO_STATUS"

  if [[ "$CONN_TYPE" == "Wi-Fi" ]]; then
    section "Wi-Fi Signal" "wifi"
    if isnum "$WIFI_RSSI"; then
      s=good; (( WIFI_RSSI < -65 )) && s=ok; (( WIFI_RSSI < -70 )) && s=bad
      row "Signal strength (RSSI)" "$WIFI_RSSI dBm" $s
      isnum "$WS_MIN" && row "Signal during test" "$WS_MIN to $WS_MAX dBm (avg $WS_AVG)" "$( (( WS_MIN < -75 )) && print ok || print na)"
      if isnum "$WIFI_NOISE"; then
        local snr=$(( WIFI_RSSI - WIFI_NOISE )); s=good; (( snr < 25 )) && s=ok; (( snr < 15 )) && s=bad
        row "Noise" "$WIFI_NOISE dBm" na
        row "Signal-to-noise (SNR)" "$snr dB" $s
      fi
    else
      row "Signal" "Unavailable" na
    fi
    [[ -n "$WIFI_CH" ]] && row "Band / channel" "${WIFI_BAND} GHz · channel $WIFI_CH · ${WIFI_WIDTH} MHz wide" "$([[ $WIFI_BAND == 2.4 ]] && print ok || print good)"
    case $WIFI_PHY in 11ax) WIFI_PHY="802.11ax (Wi-Fi 6)";; 11ac) WIFI_PHY="802.11ac (Wi-Fi 5)";; 11n) WIFI_PHY="802.11n (Wi-Fi 4)";; 11be) WIFI_PHY="802.11be (Wi-Fi 7)";; 11[abg]) WIFI_PHY="802.$WIFI_PHY";; esac
    [[ "$WIFI_SEC" == (None|Open|none) ]] && WIFI_SEC="None (open network, no password)"
    [[ -n "$WIFI_PHY" ]] && row "Wi-Fi standard" "$WIFI_PHY" na
    if isnum "$WIFI_TX"; then s=good; (( WIFI_TX < 80 )) && s=ok; (( WIFI_TX < 30 )) && s=bad   # 173 is the max on a 20 MHz channel, so only flag really low rates
      row "Link rate (Tx)" "$(r0 $WIFI_TX) Mbps$(isnum "$WS_TXMIN" && [[ "$WS_TXMIN" != "$WS_TXMAX" ]] && print " (ranged $WS_TXMIN–$WS_TXMAX during test)")" $s; fi
    [[ -n "$WIFI_SEC" ]] && row "Security" "$WIFI_SEC" "$([[ ${WIFI_SEC:l} == (none|open)* ]] && print ok || print na)"
  fi

  section "Responsiveness  ·  score $RESP_SCORE" "gauge.with.dots.needle.67percent"
  if (( NO_INTERNET )); then
    row "Internet" "No response" bad
  else
    row "Internet lag" "$(ms $INET_LAG)" "$(lag_status $INET_LAG)"
    row "Internet latency" "$(ms $INET_LAT)" "$(lag_status $INET_LAT)"
    row "Jitter" "$(ms $INET_JIT)" "$(jitter_status $INET_JIT)"
    row "Packet loss" "${INET_LOSS}%$( (( INET_LOST_N > 0 )) && print " ($INET_LOST_N of $PING_COUNT pings)")$( (( PING_ONLY_LOSS )) && print " · pings only, real traffic is fine")" "$( (( PING_ONLY_LOSS )) && print ok || loss_status $LOSS_EFF)"
  fi
  if (( ROUTER_OK )); then
    row "Router (your network)" "$(ms $R_LAT) · jitter $(ms $R_JIT)$(isnum $R_LOSS && print " · ${R_LOSS}% loss")" "$(lag_status $R_LAG)"
  else
    row "Router (your network)" "$([[ -n $GATEWAY ]] && print "Doesn't respond — not measurable" || print "No router found")" na
  fi
  [[ -n "$ISP_HOP" ]] && row "$( (( VPN_ACTIVE )) && print "First public hop (via VPN)" || print "Internet provider (first hop)")" "$(ms $ISP_HOP_MS) · $ISP_HOP" "$(lag_status $ISP_HOP_MS)"

  section "Speed$([[ -n $SPEED_SCORE ]] && print "  ·  score $SPEED_SCORE")" "speedometer"
  if [[ -z "$SPEED_SCORE" ]]; then
    row "Speed test" "$( (( NO_INTERNET )) && print "Skipped — no internet" || print "Skipped (turned off)")" na
  else
    s=good; (( DL_MBPS < 50 )) && s=ok; (( DL_MBPS < 10 )) && s=bad; row "Download" "$(r0 $DL_MBPS) Mbps" $s
    s=good; (( ${UL_MBPS:-0} < 10 )) && s=ok; (( ${UL_MBPS:-0} < 3 )) && s=bad; row "Upload" "$(r0 ${UL_MBPS:-0}) Mbps" $s
    # These come from the speed test and time full web requests, so they're higher than a plain ping
    isnum "$IDLE_MS" && row "Web request time (idle)" "$(ms $IDLE_MS)" na
    isnum "$LOADED_MS" && row "Web request time (busy)" "$(ms $LOADED_MS)" "$(lag_status $LOADED_MS)"
    if [[ -n "$BLOAT_GRADE" ]]; then
      s=good; [[ $BLOAT_GRADE == C ]] && s=ok; [[ $BLOAT_GRADE == [DF] ]] && s=bad
      row "Bufferbloat" "Grade $BLOAT_GRADE  (+$(ms $BLOAT_MS) when busy)" $s
    fi
  fi
  if (( ${#APP_ROWS} )); then
    local apps_txt=""; for t in ${APP_ROWS[1,3]}; do apps_txt+="${apps_txt:+ · }${t%%$'\t'*} $(rate_text ${t##*$'\t'})"; done
    row "Other apps using the network" "$apps_txt" "$( isnum "$APP_TOP_MBPS" && (( APP_TOP_MBPS >= 5 )) && print ok || print na)"
  elif [[ -s "$SCRATCH/nettop.txt" || -n "$SIMULATE" ]]; then
    row "Other apps using the network" "Nothing noticeable" good
  fi

  section "Reliability  ·  score $REL_SCORE" "checkmark.shield"
  s=good; (( REL_PCT < 99 )) && s=ok; (( REL_PCT < 95 )) && s=bad
  row "Responsive during test" "${REL_PCT}%" $s
  row "Outages" "$( (( OUTAGE_EVENTS )) && print "$OUTAGE_EVENTS (longest ${OUTAGE_LONGEST_S}s)" || print None)" "$( (( OUTAGE_EVENTS )) && print bad || print good)"
  if isnum "$HIST_DROPS"; then
    if (( HIST_DROPS == 0 )); then row "Drops in the last 24 hours" "None while the Mac was awake" good
    else row "Drops in the last 24 hours" "$HIST_DROPS while awake · last at $(when_text $HIST_LAST) (down $(dur_text $HIST_LAST_DUR)) · longest $(dur_text $HIST_LONGEST)" "$( (( HIST_DROPS >= 3 )) && print bad || print ok)"; fi
  fi

  if (( ${#web_rows} )); then
    section "Websites" "globe"
    isnum "$WEB_TTFB" && { s=good; (( WEB_TTFB > 400 )) && s=ok; (( WEB_TTFB > 1000 )) && s=bad; row "Average time to first byte" "$(ms $WEB_TTFB)" $s; }
    for t in $web_rows; do local -a p=("${(@ps:\t:)t}"); row "  ${p[1]}" "${p[2]}" "${p[3]}"; done
  fi

  # ---------------- For IT ----------------
  heading "For IT — technical details"

  section "Network Configuration" "slider.horizontal.3"
  row "Local IP / subnet" "$LOCAL_IP${NET_MASK:+ / $NET_MASK}" na
  row "Router" "${GATEWAY:-—}" na
  row "DHCP server" "${DHCP_SERVER:-— (manual or none)}${DHCP_LEASE:+ · lease $(( DHCP_LEASE / 3600 ))h}" na
  row "DNS servers" "${DNS_SERVERS:-—}" na
  [[ -n "$SEARCH_DOMAINS$DHCP_DOMAIN" ]] && row "Search domains" "${SEARCH_DOMAINS:-$DHCP_DOMAIN}" na
  if [[ -n "$HW_MAC" && -n "$IF_MAC" && "${HW_MAC:l}" != "${IF_MAC:l}" ]]; then
    row "MAC address (in use)" "$IF_MAC — private Wi-Fi address" na
    row "MAC address (hardware)" "$HW_MAC" na
  else
    row "MAC address" "${IF_MAC:-${HW_MAC:-—}}" na
  fi
  row "Interface MTU" "${IF_MTU:-—}" na
  [[ -n "$IF_MEDIA" && "$CONN_TYPE" == Ethernet ]] && row "Ethernet link" "$IF_MEDIA" "$([[ $IF_MEDIA == *(10baseT|100baseTX|half-duplex)* ]] && print bad || print good)"
  row "IPv6" "${IPV6_ADDR:+$IPV6_ADDR · }${IPV6_NET:-not configured}" "$([[ $IPV6_NET == broken ]] && print bad || { [[ $IPV6_NET == working* ]] && print good || print na; })"
  [[ -n "$OTHER_IFS" ]] && row "Other active interfaces" "$OTHER_IFS" na
  [[ -n "$PUB_IP" ]] && row "Public IP" "$PUB_IP" na
  [[ -n "$CF_COLO" ]] && row "Nearest Cloudflare edge" "$CF_COLO$([[ $CF_WARP == on ]] && print " · WARP on")" na
  row "Proxy" "${PROXY_DESC:-None}" "$([[ -n $PROXY_DESC ]] && print ok || print na)"
  row "Network extensions" "${NE_LIST:-None}" na

  section "Device Management" "building.2"
  row "MDM enrollment" "${MDM_ENROLLED:-unknown}$([[ $MDM_ADE == Yes ]] && print " · via Automated Device Enrollment")" "$( [[ $MDM_ENROLLED == "Yes (User Approved)" ]] && print good || { [[ $MDM_ENROLLED == Yes ]] && print ok || print na; })"
  [[ -n "$MDM_VENDOR" ]] && row "Managed by" "$MDM_VENDOR${MDM_URL:+ · $MDM_URL}${JAMF_URL:+$([[ -z $MDM_URL ]] && print " · $JAMF_URL")}" na
  [[ -n "$MDM_HOST" ]] && row "Management server" "$([[ $MDM_REACH == yes ]] && print "Reachable · $(ms $MDM_MS) · $MDM_HOST" || print "Can't reach $MDM_HOST")" "$([[ $MDM_REACH == yes ]] && print good || print bad)"
  [[ -n "$JAMF_HEALTH" ]] && row "Jamf health check" "$JAMF_HEALTH" "$([[ $JAMF_HEALTH == healthy ]] && print good || print ok)"
  row "Apple Push (port 5223)" "$(isnum "$APNS_5223" && print "Reachable · $(ms $APNS_5223)" || print "Blocked")" "$(isnum "$APNS_5223" && print good || print ok)"
  row "Apple Push (port 443 fallback)" "$(isnum "$APNS_443" && print "Reachable · $(ms $APNS_443)" || print "Blocked")" "$(isnum "$APNS_443" && print good || { isnum "$APNS_5223" && print na || print bad; })"
  row "Apple enrollment service" "$([[ $APPLE_ENROLL == yes ]] && print Reachable || print "Can't reach deviceenrollment.apple.com")" "$([[ $APPLE_ENROLL == yes ]] && print good || print ok)"
  [[ "$MDM_ENROLLED" == Yes* ]] && (( ! amRoot )) && row "Note" "Run as root (Jamf) to see the MDM server address" na

  if [[ -n "$VPN_APPS$VPN_CONFIGS$VPN_SERVERS$VPN_TUNNELS" ]]; then
  section "VPN" "lock.shield"
  row "VPN apps" "${VPN_APPS:-None found}" na
  row "Mac VPN connections" "${VPN_CONFIGS:-None set up}" na
  [[ -n "$VPN_TYPE" ]] && row "Connected VPN" "$VPN_TYPE" na
  row "Tunnel" "$([[ -n $VPN_TUNNELS ]] && print "Up · $VPN_TUNNELS · $VPN_MODE" || print "No VPN tunnel up")" na
  [[ -n "$VPN_TGW" ]] && row "Tunnel gateway (inside the VPN)" "$VPN_TGW$(isnum "$VPN_TGW_MS" && print " · $VPN_TGW_MS ms" || print " · doesn't answer")" "$(isnum "$VPN_TGW_MS" && { (( VPN_TGW_MS > 150 )) && print ok || print good; } || print na)"
  [[ -n "$VPN_GW" ]] && row "Connected VPN server" "$VPN_GW${VPN_HOST:+ ($VPN_HOST)}$(isnum "$VPN_GW_MS" && print " · about $VPN_GW_MS ms${VPN_GW_NOTE:+ ($VPN_GW_NOTE)}" || print " · ${VPN_GW_NOTE:-doesn't answer ping or traceroute}")" "$(isnum "$VPN_GW_MS" && { (( VPN_GW_MS > 100 )) && print ok || print good; } || print na)"
  [[ -n "$VPN_SERVERS" ]] && row "Configured VPN servers" "$VPN_SERVERS" na
  [[ -n "$VPN_DNS" ]] && row "DNS from the VPN" "$VPN_DNS" na
  [[ -n "$VPN_DOMAINS" ]] && row "Domains sent to the VPN's DNS" "$VPN_DOMAINS" na
  (( VPN_ROUTE_COUNT )) && row "Networks sent through the VPN" "$VPN_ROUTES ($VPN_ROUTE_COUNT total)" na
  fi

  if [[ "$CONN_TYPE" == "Wi-Fi" ]]; then
    section "Wi-Fi Details" "antenna.radiowaves.left.and.right"
    [[ -n "$WIFI_BSSID" ]] && row "Access point (BSSID)" "$WIFI_BSSID" na
    [[ -n "$WIFI_MCS" ]] && row "MCS / spatial streams" "MCS $WIFI_MCS${WIFI_NSS:+ · $WIFI_NSS streams}" na
    [[ -n "$WIFI_CCA" ]] && row "Channel utilization (CCA)" "$WIFI_CCA" "$( (( ${WIFI_CCA%%[^0-9]*:-0} >= 50 )) && print ok || print na)"
    isnum "$WIFI_NEARBY" && row "Nearby access points (last scan)" "$WIFI_NEARBY radios seen · $WIFI_COCHAN on channel $WIFI_CH ($WIFI_COCHAN_STRONG strong)" "$( (( WIFI_COCHAN_STRONG >= 4 )) && print ok || print na)"
    [[ -n "$WS_CHANS" ]] && row "Channel(s) during test" "$WS_CHANS" "$([[ $WS_CHANS == */* ]] && print ok || print na)"
  fi

  section "Responsiveness Detail" "waveform.path.ecg"
  for t in $tgt_rows; do local -a p=("${(@ps:\t:)t}"); row "  ${p[1]}" "${p[2]}" "${p[3]}"; done
  (( ROUTER_OK )) && row "  Router $GATEWAY" "lag $(ms $R_LAG) · via $R_METHOD" "$(lag_status $R_LAG)"
  row "Method" "$INET_METHOD · ${TEST_SECONDS}s · every ${PING_INTERVAL}s" na
  if isnum "$LOADED_MS" || [[ -n "$SPEED_SERVER" ]]; then
    row "Speed server" "${SPEED_SERVER:-—}" na
    row "Speed method" "${SPEED_NOTE:-—}" na
  fi

  if (( ${#hops} )) && [[ -n "${hops[1]}" ]]; then
    section "Network Path (traceroute to ${INTERNET_TARGETS[1]}$( (( VPN_ACTIVE )) && print ", through VPN"))" "point.topleft.down.to.point.bottomright.curvepath"
    # Point out the hop where the time jumps, since that's where the slowdown starts. (Missed replies
    # in the middle are usually just routers ignoring traceroute, so we show them but don't flag them.)
    local prev=0 jump
    for t in $hops; do local -a p=("${(@ps:\t:)t}")
      if [[ "${p[2]}" == "*" ]]; then row "  Hop ${p[1]}" "no reply (hop hides itself — normal)" na
      else jump=$(calc "${p[3]}-$prev"); s=na; (( jump > 40 )) && s=ok; (( jump > 100 )) && s=bad
        row "  Hop ${p[1]}" "$(ms ${p[3]}) · ${p[2]}$(is_private_ip ${p[2]} && print " (private)")$( (( jump > 40 )) && print " · +$(r0 $jump) ms")$( (( ${p[4]} )) && print " · ${p[4]}/3 no reply")" "$s"
        prev=${p[3]}; fi
    done
  fi

  if (( ${#DNS_ROWS} )); then
    section "DNS Servers (avg of ${#DNS_TEST_DOMAINS} lookups)" "server.rack"
    for t in $DNS_ROWS; do local -a p=("${(@ps:\t:)t}"); row "  ${p[1]}" "${p[2]}" "${p[3]}"; done
    isnum "$WEB_DNS" && row "  In-browser DNS (avg)" "$(ms $WEB_DNS)" "$( (( WEB_DNS > 150 )) && print bad || { (( WEB_DNS > 60 )) && print ok || print good; })"
  fi

  section "Health Checks" "stethoscope"
  row "Captive portal" "$( case $CAPTIVE in none) print "None";; detected) print "Detected — sign-in page intercepting";; *) print "Couldn't check";; esac)" \
      "$( case $CAPTIVE in none) print good;; detected) print bad;; *) print na;; esac)"
  row "Path MTU" "${PMTU:-couldn't test}" "$( [[ -z $PMTU ]] && print na || { (( PMTU < 1500 )) && print ok || print good; })"
  isnum "$CLOCK_OFF_MS" && row "Clock offset vs time.apple.com" "$CLOCK_OFF_MS ms" "$( (( ${CLOCK_OFF_MS#-} > 60000 )) && print bad || { (( ${CLOCK_OFF_MS#-} > 2000 )) && print ok || print good; })"
  row "Interface errors (during test)" "in $ierr · out $oerr" "$( (( ierr + oerr )) && print ok || print good)"
  [[ -n "$retx_pct" ]] && row "TCP retransmits (during test)" "${retx_pct}% ($tretx of $tsent)" "$( (( retx_pct >= 2 )) && print ok || print good)"

  section "This Mac" "laptopcomputer"
  row "Model / macOS" "${MAC_MODEL:-—} · macOS $MAC_OS" na
  row "Hostname" "${MAC_HOST:-—}" na
  row "Uptime" "${MAC_UPTIME:-—}" na
  [[ -n "$MAC_BATT" ]] && row "Battery" "$MAC_BATT" na
  row "Low Power Mode" "$([[ $MAC_LOWPOWER == 1 ]] && print On || print Off)" "$([[ $MAC_LOWPOWER == 1 ]] && print ok || print na)"
  row "Test ran as" "$(/usr/bin/id -un)$( (( amRoot )) || print " (not root — some Wi-Fi/TCP details unavailable)")" na

  section "Test Run" "timer"
  row "Script version" "$SCRIPT_VERSION" na
  row "Mode" "$ACTION_MODE$([[ $QUICK_MODE == true ]] && print " · quick")$([[ -n $SIMULATE ]] && print " · SIMULATED ($SIMULATE)") · ping sample ${TEST_SECONDS}s · speed $SPEED_ENGINE" "$([[ -n $SIMULATE ]] && print ok || print na)"
  mark scoring
  TIMINGS_TEXT="$(timings_text)"
  row "Step timings" "$TIMINGS_TEXT" na
  return 0
}

# The text report (saved to the Desktop, or printed in silent mode). Uses the same rows as the window.
build_report() {
  local tag
  {
    print -r -- "NETWORK HEALTH CHECK"
    print -r -- "============================================================"
    print -r -- "Date:          $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    print -r -- "User:          $targetUser"
    print -r -- "Computer:      $(/usr/sbin/scutil --get ComputerName 2>/dev/null)"
    print -r -- "Serial:        $(device_serial)"
    print -r -- "macOS:         $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    print -r -- ""
    print -r -- "NETWORK SCORE: $NET_SCORE / 100  ($(band_label $NET_SCORE)) — $HEADLINE"
    print -r -- "  Responsiveness $RESP_SCORE   Reliability $REL_SCORE   Speed ${SPEED_SCORE:-skipped}"
    print -r -- "  $SUBHEADLINE"
    print -r -- ""
    print -r -- "(!) = worth a look    (X) = a problem"
    print -r -- ""
    print -r -- "FINDINGS"
    while IFS=$'\t' read -r tag t; do
      case $tag in good) tag="OK  ";; ok) tag="WARN";; bad) tag="FAIL";; *) tag="INFO";; esac
      print -r -- "  [$tag] $t"
    done < "$FIND_FILE"
    while IFS=$'\t' read -r k a b c; do
      if [[ "$k" == H ]]; then print -r -- ""; print -r -- ""; print -r -- "==================== ${a:u} ===================="
      elif [[ "$k" == S ]]; then print -r -- ""; print -r -- "${a:u}"
      else
        case $c in good) c="";; ok) c="  (!)";; bad) c="  (X)";; *) c="";; esac
        printf "  %-32s %s%s\n" "$a" "$b" "$c"
      fi
    done < "$DATA_FILE"
    print -r -- ""
    print -r -- "Score bands: 90+ Excellent, 80 Good, 70 Okay, 50 Fair, <50 Poor."
    # Raw command output at the bottom, for IT
    if [[ -n "$PHYS_IF" ]]; then
      print -r -- ""; print -r -- "==================== RAW OUTPUT ===================="
      print -r -- ""; print -r -- "--- traceroute -n ${INTERNET_TARGETS[1]}"; /bin/cat "$SCRATCH/trace.txt" 2>/dev/null
      print -r -- ""; print -r -- "--- netstat -rn -f inet (default routes)"; /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk 'NR<=4 || /^default/'
      print -r -- ""; print -r -- "--- ifconfig $PHYS_IF"; /sbin/ifconfig "$PHYS_IF" 2>/dev/null
      print -r -- ""; print -r -- "--- scutil --dns (first resolvers)"; /usr/sbin/scutil --dns 2>/dev/null | /usr/bin/sed -n '1,/^resolver #3/p'
      print -r -- ""; print -r -- "--- scutil --proxy"; /usr/sbin/scutil --proxy 2>/dev/null
      [[ -s "$SCRATCH/nq.json" ]] && { print -r -- ""; print -r -- "--- networkQuality summary"; /usr/bin/grep -E '"(base_rtt|dl_throughput|ul_throughput|dl_responsiveness|ul_responsiveness|responsiveness|interface_name|test_endpoint)"' "$SCRATCH/nq.json"; }
    fi
  } > "$REPORT_FILE"
}

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Network Health Check — mode=${ACTION_MODE}; speed=${SPEED_ENGINE}; duration=${TEST_SECONDS}s; user=${targetUser}; running as $(/usr/bin/id -un)"

# Simulation: "list" just prints the scenarios, and a typo in a scenario name stops the script.
if [[ "$SIMULATE" == list ]]; then print -r -- "Scenarios: ${SIM_SCENARIOS[*]}  (combine with commas)"; exit 0; fi
if [[ -n "$SIMULATE" ]]; then
  for _s in ${(s:,:)SIMULATE}; do
    (( ${SIM_SCENARIOS[(Ie)$_s]} )) || { logMe ERROR "Unknown simulation scenario '$_s'. Scenarios: ${SIM_SCENARIOS[*]}"; exit 1; }
  done
fi

while true; do
  : > "$FACTS_FILE"; : > "$LIVE_FILE"; : > "$CANCEL_FILE"
  spin_status 0 "Starting…" "" 0 2 1
  show_spinner
  run_tests
  build_report
  kill_spinner
  logMe INFO "Step timings: ${TIMINGS_TEXT:-n/a}"
  write_json
  logMe INFO "Score $NET_SCORE ($(band_label $NET_SCORE)) — resp=$RESP_SCORE rel=$REL_SCORE speed=${SPEED_SCORE:-skipped} lag=${INET_LAG} loss=${INET_LOSS}% dl=${DL_MBPS:-—} ul=${UL_MBPS:-—}"

  if [[ "$ACTION_MODE" == "silent" ]]; then
    /bin/cat "$REPORT_FILE"
    logWritable && /bin/cat "$REPORT_FILE" >> "$logFile"
    break
  fi

  choice=$(show_results)
  logMe INFO "User chose: ${choice:-done}"
  case "$choice" in
    again) continue ;;
    save)
      SERIAL="$(device_serial)"; [[ -z "$SERIAL" ]] && SERIAL="unknown"
      REPORT_NAME="${REPORT_NAME_PATTERN//\{USER\}/$targetUser}"
      REPORT_NAME="${REPORT_NAME//\{SERIAL\}/$SERIAL}"
      REPORT_NAME="${REPORT_NAME//\{STAMP\}/$(/bin/date +%Y%m%d-%H%M%S)}"
      DESKTOP="$USER_HOME/Desktop"; [[ -d "$DESKTOP" ]] || DESKTOP="$USER_HOME"
      if /bin/cp "$REPORT_FILE" "$DESKTOP/$REPORT_NAME" 2>/dev/null; then
        (( amRoot )) && /usr/sbin/chown "$targetUser" "$DESKTOP/$REPORT_NAME" 2>/dev/null
        logMe INFO "Report saved: $DESKTOP/$REPORT_NAME"
        run_as_user /usr/bin/open -R "$DESKTOP/$REPORT_NAME" 2>/dev/null
        show_message "$SAVED_TITLE" "doc.text.fill" "#34C759" "Your network report was saved to your Desktop.\nAttach it to your IT ticket." "$REPORT_NAME"
      else
        logMe ERROR "Could not save report to $DESKTOP"
        show_message "$SAVED_TITLE" "xmark.octagon.fill" "#FF3B30" "The report could not be saved to your Desktop. Contact IT for help." ""
      fi
      break ;;
    *) break ;;
  esac
done

exit 0
