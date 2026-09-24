#!/bin/zsh

####################################################################################################
#
# Network Health Check
#
# Purpose: Tests the Mac's network connection and shows the user a clear, plain-English results
#          window — and gives IT the detailed data needed to troubleshoot. Measures:
#            • Responsiveness — lag, latency, jitter, and packet loss to 1.1.1.1 / 8.8.8.8, plus the
#                               router, so it can tell "your Wi-Fi/router" apart from "your ISP".
#            • Reliability    — how much of the test the connection spent unresponsive (brief
#                               spikes don't count; only sustained drop-outs do).
#            • Speed          — download / upload plus latency under load (bufferbloat).
#            • Web & DNS      — time-to-first-byte for common sites and how fast each DNS server is.
#            • Wi-Fi          — signal, noise, SNR, band/channel, link rate, nearby networks.
#          Everything rolls up into a 0–100 Network Score (90+ Excellent, 80 Good, 70 Okay, 50 Fair,
#          under 50 Poor), a video-call verdict, and findings that say what is wrong. A "For IT"
#          section adds the network path, DNS timings, proxy/VPN/extension info, MTU, IPv6, clock
#          offset, DHCP details, and more. Save Report drops a text report (with raw command output)
#          on the user's Desktop to attach to a ticket.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
#       Running as root (Jamf) adds the Wi-Fi network name, access point, MCS, channel
#       utilization, and TCP retransmit stats.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service (the user clicks it, watches progress, reads the results, can save a report):
#     • Leave the script as-is (HEADLESS=false). Set Jamf Parameter 4 to "verbose" or leave blank.
#
#   Headless / automated (run silently, the report goes to the policy log + $logFile):
#     • Set Jamf Parameter 4 to "silent"  (OR set HEADLESS=true in the Config block below).
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose or silent)
#   Parameter 5 Label:  Speed Test (apple, cloudflare, or off)
#   Parameter 6 Label:  Test Duration in seconds, or "quick" (blank = 20)
#   Parameter 7 Label:  Simulate Scenario (testing only — leave blank)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Action Mode        verbose = progress window + results window (default)
#                            silent  = no windows; report is written to the policy log
#     $5  Speed Test         apple      = macOS networkQuality (multi-stream, default)
#                            cloudflare = speed.cloudflare.com (single stream)
#                            off        = skip the speed test
#     $6  Test Duration      seconds to sample responsiveness/reliability. Blank = TEST_SECONDS.
#                            quick = 5s sample + no speed test (about 15 seconds total)
#     $7  Simulate Scenario  BLANK for real use. A scenario name fakes the results so you can see
#                            what users see (e.g. weak-wifi, no-internet, all-bad) — see SIMULATE.
# ---------------------------------------------------------------------------------------------
#
# TESTING (from Terminal — $1..$4 map to Jamf $4..$7):
#   ./Network_Health_Check.sh                          # normal run
#   ./Network_Health_Check.sh verbose off quick        # quick check, no speed test
#   NHC_SIMULATE=weak-wifi ./Network_Health_Check.sh   # fake a scenario (list: NHC_SIMULATE=list)
#   NHC_DEBUG=1 ./Network_Health_Check.sh              # keep /tmp/network-health-check.<pid>
#   sudo ./Network_Health_Check.sh silent              # full Wi-Fi / TCP detail, report to stdout
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.10 9/24/26 - Original Release - Responsiveness (lag/latency/jitter/loss, router vs internet),
#                reliability, speed + bufferbloat, web & DNS timing, Wi-Fi link, 0–100 scoring,
#                video-call verdict, plain-English findings, "For IT" diagnostics, live progress
#                window with Cancel, results window with Save Report / Run Again, verbose/silent
#                modes, quick mode, simulation scenarios, step timings, optional JSON results.
#                - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # false = behave per the Jamf "Action Mode" param ($4).
                        # true  = ALWAYS run silently (no windows), no matter what $4 says.

# RESPONSIVENESS + RELIABILITY ----------------------------------------------
TEST_SECONDS=20         # how long to sample (Jamf $6 overrides). Longer = better reliability data.
PING_INTERVAL=0.5       # seconds between pings
INTERNET_TARGETS=(      # ICMP targets for internet responsiveness (anycast — nearest server worldwide)
    "1.1.1.1"
    "8.8.8.8"
)
HTTPS_FALLBACK_TARGETS=(   # used ONLY when ICMP is blocked (TCP connect time instead of ping)
    "https://speed.cloudflare.com"
    "https://www.google.com"
)
OUTAGE_MIN_LOST=3       # consecutive pings lost to EVERY target before it counts as an outage
                        # (brief spikes don't count — only sustained unresponsiveness)

# SPEED ---------------------------------------------------------------------
SPEED_ENGINE="apple"    # apple = networkQuality (built in, multi-stream, measures bufferbloat)
                        # cloudflare = speed.cloudflare.com (single stream) | off = skip
                        # (Jamf $5 overrides)
SPEED_MAX_SECONDS=15    # cap on the speed test run time
CF_DOWN_BYTES=25000000  # cloudflare engine: download size (bytes)
CF_UP_BYTES=10000000    # cloudflare engine: upload size (bytes)

# WEB RESPONSIVENESS --------------------------------------------------------
WEB_TARGETS=(           # sites timed for DNS / connect / TLS / time-to-first-byte
    "https://www.google.com"
    "https://www.apple.com"
    "https://www.microsoft.com"
    "https://login.microsoftonline.com"
    "https://www.cloudflare.com"
    "https://zoom.us"
    "https://teams.microsoft.com"
)
DNS_TEST_DOMAINS=(      # names looked up against each DNS server (yours + 1.1.1.1 + 8.8.8.8)
    "apple.com"
    "microsoft.com"
    "google.com"
)

# CONNECTION INFO -----------------------------------------------------------
PUBLIC_IP_LOOKUP_URL="https://ipinfo.io/json"   # public IP / ISP / location. Blank = skip.

# REPORT --------------------------------------------------------------------
# "Save Report" writes a text report to the user's Desktop. Tokens are filled in:
#   {USER} = short name   {SERIAL} = device serial   {STAMP} = YYYYMMDD-HHMMSS
REPORT_NAME_PATTERN="NetworkHealth_{USER}_{SERIAL}_{STAMP}.txt"
logFile="/var/log/network_health_check.log"      # this script's own run log

# TESTING -------------------------------------------------------------------
QUICK_MODE=false        # true = quick check: 5s ping sample and NO speed test (≈15s total).
                        # Jamf $6 = "quick" (or NHC_QUICK=1 on the command line) does the same.
SIMULATE=""             # "" = real test. A scenario name FAKES the results so you can see exactly
                        # what users see, without touching the network. Jamf $7 or NHC_SIMULATE
                        # override this. Combine with commas (weak-wifi,vpn). "list" prints them all:
                        #   healthy  not-connected  no-internet  captive-portal  packet-loss  outage
                        #   ping-blocked  slow-dns  bufferbloat  slow-speed  weak-wifi  2ghz  vpn
                        #   broken-ipv6  router-bottleneck  isp-problem  clock-skew  proxy
                        #   slow-ethernet  all-bad

# RESULTS FILE (optional) ---------------------------------------------------
SAVE_JSON=false                            # true = also save the results as JSON (needs root):
JSON_DIR="/Library/Management/NetworkHealth"   #   last.json  = the latest run
JSON_HISTORY_MAX=500                       #   history.jsonl = one line per run, newest last

# LOOK OF THE WINDOWS (verbose mode only) -----------------------------------
bannerColor="#0056D2"                      # banner bar colour (hex)
BANNER_TEXT_COLOR="#FFFFFF"                # banner title colour (hex)
SPINNER_TEXT="Checking your network…"
RESULT_TITLE="Network Health Check"
SUPPORT_NOTE="Having trouble? Click Save Report and attach it to your IT ticket."
SAVED_TITLE="Report Saved"
okButton="Done"
againButton="Run Again"
saveButton="Save Report"
cancelButton="Cancel"                      # on the progress window — stops the test
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob
zmodload zsh/datetime   # EPOCHREALTIME / EPOCHSECONDS

# Per-run scratch dir (ping output, data rows, generated .jxa); always cleaned up.
SCRATCH="/tmp/network-health-check.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
# Stop every background process this script started (pings, traceroute, speed test, windows) —
# walks the whole tree, since pings launched from functions sit under a subshell.
kill_tree() { local c; for c in $(/usr/bin/pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
stop_children() { local c; for c in $(/usr/bin/pgrep -P $$ 2>/dev/null); do kill_tree "$c"; done; }
trap 'stop_children; [[ -n "$NHC_DEBUG" ]] || /bin/rm -rf "$SCRATCH"' EXIT INT TERM   # NHC_DEBUG=1 keeps it
STATUS_FILE="$SCRATCH/status.txt"   # the progress HUD polls this (step / title / detail / percent range / eta)
LIVE_FILE="$SCRATCH/live.txt"       # live metric for the HUD (big value / caption / sparkline series)
FACTS_FILE="$SCRATCH/facts.txt"     # one-off results for the HUD — each is held on screen ~2s so it can be read
DATA_FILE="$SCRATCH/rows.tsv"       # result rows the results window + text report are built from
FIND_FILE="$SCRATCH/findings.tsv"   # findings (status <tab> text)
REPORT_FILE="$SCRATCH/report.txt"
CANCEL_FILE="$SCRATCH/cancel.flag"  # the HUD's Cancel button writes here (world-writable: HUD runs as the user)
: > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point as $1 ("/"), computer name $2, user $3. Strip that trio so our real
# params line up as $1=$4, $2=$5, $3=$6, $4=$7. Run locally without "/" and params pass through.
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

# --- Console / user resolution ----------------------------------------------
# Resolve the logged-in (console) user so windows appear in their session and the report lands
# on THEIR Desktop, even when this runs as root from Jamf.
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
# No one logged in = nobody to show windows to.
[[ -z "$consoleUser" ]] && (( amRoot )) && ACTION_MODE="silent"

# Banner colour -> RGB for AppKit
bhex="${bannerColor#\#}";   br=$((16#${bhex[1,2]}));  bg=$((16#${bhex[3,4]}));  bb=$((16#${bhex[5,6]}))
tchex="${BANNER_TEXT_COLOR#\#}"; tr=$((16#${tchex[1,2]})); tg=$((16#${tchex[3,4]})); tb=$((16#${tchex[5,6]}))

PING_COUNT=$(/usr/bin/awk -v s="$TEST_SECONDS" -v i="$PING_INTERVAL" 'BEGIN{printf "%d", s/i}')

# --- Helpers ----------------------------------------------------------------
# Timestamped line to stdout (Jamf policy log) and $logFile when writable (i.e. running as root).
logWritable() { [[ -w "$logFile" ]] || { [[ ! -e "$logFile" && -w "${logFile:h}" ]]; }; }
logMe() { local l="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}"; print -r -- "$l"; logWritable && print -r -- "$l" >> "$logFile"; return 0; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }   # escape \ " newline for JS
clean() { local s="${1//$'\t'/ }"; print -r -- "${s//$'\n'/ }"; }                        # no tabs/newlines in a field

# Update the progress HUD.
#   spin_status <step 0-4> <title> <detail> <pct-from> <pct-to> <expected-seconds> [linear]
# The bar eases from pct-from toward pct-to over the expected time (linear=1 for timed steps
# like the ping sample), so it keeps moving even while a long test runs.
spin_status() {
  print -rl -- "$1" "$2" "$3" "$4" "$5" "$6" "${7:-0}" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}
# HUD text markup for the big value: "code:text|code:text" — w white, c cyan, p purple, g green,
# o orange, r red, b blue, y yellow. e.g. "c:↓ 42|w:   |p:↑ 36"
lag_code()  { case $(lag_status "$1") in good) print g;; ok) print o;; bad) print r;; *) print w;; esac; }
stat_code() { case "$1" in good) print g;; ok) print o;; bad) print r;; *) print w;; esac; }
band_code() { local v=$1; (( v>=80 )) && { print g; return }; (( v>=70 )) && { print y; return }; (( v>=50 )) && { print o; return }; print r; }

# A one-off result for the HUD (queued; each stays up long enough to read). Clears the live stream.
fact() {
  print -r -- "$(clean "$1")"$'\t'"$(clean "$2")"$'\t'"$3" >> "$FACTS_FILE" 2>/dev/null
  /bin/chmod 644 "$FACTS_FILE" 2>/dev/null; : > "$LIVE_FILE"
}
# Live streaming value on the HUD (ping ms, Mbps): live_metric <big value> <caption> <csv series> [csv series 2]
live_metric() {
  print -rl -- "$1" "$2" "$3" "$4" > "$LIVE_FILE" 2>/dev/null
  /bin/chmod 644 "$LIVE_FILE" 2>/dev/null
}

# Interface byte counters (in out) — sampled for the live throughput readout.
if_bytes() { /usr/sbin/netstat -ibn -I "$PHYS_IF" 2>/dev/null | /usr/bin/awk 'NR==2{print $7, $10}'; }

# throughput_monitor <pid> <both|down|up> — while <pid> runs, show live Mbps + sparkline on the HUD.
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

# Result rows. Status is one of: good | ok | bad | na
heading() { print -r -- "H"$'\t'"$(clean "$1")" >> "$DATA_FILE"; }
section() { print -r -- "S"$'\t'"$(clean "$1")"$'\t'"$2" >> "$DATA_FILE"; }
row()     { print -r -- "R"$'\t'"$(clean "$1")"$'\t'"$(clean "$2")"$'\t'"${3:-na}" >> "$DATA_FILE"; }
finding() { print -r -- "$1"$'\t'"$(clean "$2")" >> "$FIND_FILE"; }

device_serial() {
  /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
    | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# Math helpers (awk does the floating point)
calc() { /usr/bin/awk "BEGIN{printf \"%.1f\", $1}" 2>/dev/null; }
r0()   { /usr/bin/awk -v v="$1" 'BEGIN{printf "%.0f", v}'; }
isnum() { [[ "$1" == (-|)<->(.<->|) ]]; }

# interp <value> "<x:y> <x:y> ..."  -> piecewise-linear score (points sorted by x ascending)
interp() {
  /usr/bin/awk -v v="$1" -v pts="$2" 'BEGIN{
    n=split(pts,P," "); for(i=1;i<=n;i++){split(P[i],a,":"); X[i]=a[1]+0; Y[i]=a[2]+0}
    if(v<=X[1]){printf "%.0f", Y[1]; exit} if(v>=X[n]){printf "%.0f", Y[n]; exit}
    for(i=1;i<n;i++) if(v>=X[i] && v<=X[i+1]){ printf "%.0f", Y[i]+(v-X[i])*(Y[i+1]-Y[i])/(X[i+1]-X[i]); exit }
  }'
}

# Score -> band label / colour
band_label() { local s=$1; (( s>=90 )) && { print Excellent; return }; (( s>=80 )) && { print Good; return }
               (( s>=70 )) && { print Okay; return }; (( s>=50 )) && { print Fair; return }; print Poor; }
band_color() { local s=$1; (( s>=90 )) && { print "#34C759"; return }; (( s>=80 )) && { print "#7CC444"; return }
               (( s>=70 )) && { print "#F2B800"; return }; (( s>=50 )) && { print "#FF9500"; return }; print "#FF3B30"; }
score_status() { local s=$1; (( s>=80 )) && { print good; return }; (( s>=60 )) && { print ok; return }; print bad; }

# --- Progress HUD ---------------------------------------------------------------------------------
# Dark card with a 5-step tracker (Connect → Responsiveness → Websites → Speed → Score), a big live
# metric + sparkline (ping times, then live Mbps), and an animated progress bar. The bar runs at
# 30 fps and keeps easing forward through long steps using each step's expected duration (so it
# never sits frozen), with a shimmer sweeping across it. Reads STATUS_FILE + LIVE_FILE ~5×/sec.
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
win.appearance=$.NSAppearance.appearanceNamed($.NSAppearanceNameDarkAqua);   // dark controls on the dark card
var cv=win.contentView;
var card=rbox(10,10,W-20,H-20,C(0.13,0.13,0.15,0.97),22);
card.shadow=$.NSShadow.alloc.init; card.shadow.shadowBlurRadius=24; card.shadow.shadowOffset=$.NSMakeSize(0,-4); card.shadow.shadowColor=C(0,0,0,0.45);
cv.addSubview(card);

var title=label(30,H-62,W-60,26,18,$.NSFontWeightBold); title.stringValue=TITLE; cv.addSubview(title);

// Cancel (top-right): writes the flag file the shell polls; the shell then stops and closes this window.
if(!$.NHCancel){ObjC.registerSubclass({name:'NHCancel',superclass:'NSObject',methods:{
 'cancel:':{types:['void',['id']],implementation:function(b){
   $("1").writeToFileAtomicallyEncodingError(CANCEL,false,$.NSUTF8StringEncoding,null);
   b.enabled=false; b.title="Cancelling…"; }}}});}
var ch=$.NHCancel.alloc.init;
var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(W-124,H-60,96,26)); cb.title=CANCEL_L; cb.bezelStyle=1; cb.controlSize=1;
cb.target=ch; cb.action='cancel:'; cv.addSubview(cb);

// Step tracker
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

// Current step text
var stepT=label(30,H-196,W-60,22,15,$.NSFontWeightSemibold); cv.addSubview(stepT);
var detail=label(30,H-218,W-60,18,12); detail.textColor=C(0.62,0.66,0.74); cv.addSubview(detail);

// Live metric card: sparkline drawn faintly across the whole card, centered coloured value on top
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
function showMetric(bigTxt,capTxt,a,b){ setBig(bigTxt); cap.setStringValue(capTxt||""); spark.setImage(drawSpark(nums(a),nums(b))); }

// Progress bar (eased fill + shimmer)
var BX=44, BY=44, BW=W-88-52, BH=10;
cv.addSubview(rbox(BX,BY,BW,BH,C(1,1,1,0.10),5));
var fill=rbox(BX,BY,0,BH,BLUE,5); try{fill.clipsToBounds=true;}catch(e){} cv.addSubview(fill);
var shim=rbox(-80,0,80,BH,C(1,1,1,0.28),5); fill.addSubview(shim);
var pct=label(W-44-48,BY-4,48,18,12.5,$.NSFontWeightSemibold,2); pct.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); cv.addSubview(pct);

function drawSpark(a,b){
 var img=$.NSImage.alloc.initWithSize($.NSMakeSize(SPW,SPH)); var all=a.concat(b);
 if(all.length<2) return img;
 img.lockFocus;
 var mx=Math.max.apply(null,all), mn=b.length?0:Math.min.apply(null,all)*0.8; if(mx-mn<1){mx=mn+1;}
 function series(v,col){ if(v.length<2) return; var N=Math.max(v.length,16), st=SPW/(N-1), xs=SPW-(v.length-1)*st-4;
  var P=v.map(function(y,k){return [xs+k*st, 5+(y-mn)/(mx-mn)*(SPH-12)];});
  var area=$.NSBezierPath.bezierPath; area.moveToPoint($.NSMakePoint(P[0][0],0));
  P.forEach(function(p){area.lineToPoint($.NSMakePoint(p[0],p[1]));}); area.lineToPoint($.NSMakePoint(P[P.length-1][0],0)); area.closePath;
  col.colorWithAlphaComponent(0.16).setFill; area.fill;
  var ln=$.NSBezierPath.bezierPath; ln.moveToPoint($.NSMakePoint(P[0][0],P[0][1]));
  P.forEach(function(p){ln.lineToPoint($.NSMakePoint(p[0],p[1]));}); ln.lineWidth=2; ln.lineJoinStyle=1; col.setStroke; ln.stroke;
  var e=P[P.length-1]; col.setFill; $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(e[0]-3.5,e[1]-3.5,7,7)).fill; }
 series(a,CYAN); series(b,PURPLE);
 img.unlockFocus; return img; }
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

var shown=0, cur={key:"",step:0,from:0,to:2,eta:2,lin:false,t0:0}, frame=0, lastLive="", factIdx=0, holdUntil=0;
var HOLD=1.7, HOLD_BUSY=1.1;   // seconds a one-off result stays up (shorter when several are queued)
function now(){return Date.now()/1000;}
function target(){ var el=now()-cur.t0, eta=Math.max(cur.eta,0.2), f;
 f = cur.lin ? Math.min(0.98, el/eta) : (1-Math.exp(-2.3*el/eta));
 return cur.from+(cur.to-cur.from)*Math.min(f,0.985); }
if(!$.NHTick){ObjC.registerSubclass({name:'NHTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){
  frame++;
  if(frame%6==1){
   var L=rd(STATUS).split("\n");
   if(L.length>=6){ var key=[L[0],L[1],L[3],L[4]].join("|");
    if(key!=cur.key){ cur={key:key,step:parseInt(L[0])||0,from:parseFloat(L[3])||0,to:parseFloat(L[4])||0,eta:parseFloat(L[5])||3,lin:L[6]=="1",t0:now()};
     setSteps(cur.step); stepT.setStringValue(L[1]||""); stepT.textColor=(cur.step>=5)?GREEN:WHITE; }
    detail.setStringValue(L[2]||""); }
   // One-off results are queued and each held on screen; live streams fill the gaps between them.
   var F=rd(FACTS).split("\n").filter(function(x){return x.length;});
   if(cur.step>=5 && F.length>factIdx+1){ factIdx=F.length-1; holdUntil=0; }   // finish line: jump to the score
   if(F.length>factIdx && now()>=holdUntil){
    var f=F[factIdx++].split("\t"); showMetric(f[0],f[1],f[2],"");
    holdUntil=now()+((F.length-factIdx)>1?HOLD_BUSY:HOLD); lastLive="";
   } else if(now()>=holdUntil){
    var lv=rd(LIVE);
    if(lv.length && lv!=lastLive){ lastLive=lv; var M=lv.split("\n"); showMetric(M[0],M[1],M[2],M[3]); }
   }
  }
  var tg=target(); if(cur.to>=100 && cur.eta<=0.5) tg=100;
  if(tg>shown) shown+=(tg-shown)*0.10;
  var fw=Math.max(BH,BW*shown/100);
  fill.setFrame($.NSMakeRect(BX,BY,fw,BH));
  shim.setFrame($.NSMakeRect(((frame*5)%(fw+160))-80,0,80,BH));
  pct.setStringValue(Math.floor(shown+0.5)+"%");
  if(shown>=99.5){ fill.fillColor=GREEN; }
  var n=nodes[cur.step]; if(n && n.state==1) n.icon.alphaValue=0.55+0.45*Math.sin(frame/5);
  for(var i=0;i<links.length;i++){ var lk=links[i]; lk.cur+=((lk.goal||0)-lk.cur)*0.15; lk.box.setFrame($.NSMakeRect(lk.x,nodeY+15,lk.w*lk.cur,3)); }
 }}}});}
var tk=$.NHTick.alloc.init;
$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(1/30,tk,'tick:',null,true);
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
JXA
  } > "$SPIN_SCPT"
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; return 0; }

# --- Simple message window (used after Save Report) ---------------------------
# show_message <title> <sfSymbol> <tintHex> <message> [filename]
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
# Score ring + headline, three sub-score tiles, findings card, and a scrollable details list
# built from $DATA_FILE. Prints the button pressed: done | again | save
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
var ORD={bad:0,ok:1,na:2,good:3}; function rk(f){return /^SIMULATED/.test(f[1]||"")?-1:((f[0] in ORD)?ORD[f[0]]:2);} finds.sort(function(a,b){return rk(a)-rk(b);});   // problems first

// ---- geometry (laid out top-down; y = H - top) ----
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

// Hero: score ring + headline + tiles
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

// Details (scrollable)
var dl=label("Details",PAD,y-22,300,18,13,$.NSFontWeightSemibold);cv.addSubview(dl);
y-=30;
var dw=W-2*PAD, SECH=34, RH=24, docH=12;
var HDH=46;
rows.forEach(function(r){docH+=(r[0]=="S")?SECH:(r[0]=="H")?HDH:RH;});
docH=Math.max(docH,detH);
var doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,dw-2,docH));
var dy=docH-6, alt=0;
rows.forEach(function(r){
 if(r[0]=="H"){   // divider between the user-facing results and the technical block
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
  if(s=="bad"||s=="ok") vl.textColor=rgb(hex(STAT[s]));   // problem values stand out in colour
  doc.addSubview(vl); if(s!="na"){doc.addSubview(rbox(dw-36,dy+8,8,8,rgb(hex(STAT[s]||STAT.na)),4));}
 }
});
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,y-detH,dw,detH));
sv.hasVerticalScroller=true;sv.borderType=1;sv.drawsBackground=false;sv.setDocumentView(doc);cv.addSubview(sv);
sv.contentView.scrollToPoint($.NSMakePoint(0,docH-sv.contentView.bounds.size.height));sv.reflectScrolledClipView(sv.contentView);   // start at the top

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
# Works out the physical interface even when a VPN owns the default route, so router tests go
# to the real LAN gateway. Sets PHYS_IF, PORT_NAME, CONN_TYPE, LOCAL_IP, GATEWAY, VPN_*.
detect_connection() {
  local def_if dev port line
  PHYS_IF=""; PORT_NAME=""; CONN_TYPE=""; LOCAL_IP=""; GATEWAY=""; VPN_ACTIVE=0; VPN_NAME=""
  def_if=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
  if [[ "$def_if" == (utun|ppp|ipsec|gpd|tun|tap|wg)* ]]; then
    VPN_ACTIVE=1
    VPN_NAME=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk -F'"' '/\(Connected\)/{print $2; exit}')
    [[ -z "$VPN_NAME" ]] && VPN_NAME="Active ($def_if)"
  fi

  # device -> hardware port name
  typeset -gA PORT_OF; PORT_OF=()
  while IFS= read -r line; do
    [[ "$line" == "Hardware Port: "* ]] && port="${line#Hardware Port: }"
    [[ "$line" == "Device: "* ]] && PORT_OF[${line#Device: }]="$port"
  done < <(/usr/sbin/networksetup -listallhardwareports 2>/dev/null)

  if [[ -n "$def_if" && -n "${PORT_OF[$def_if]}" ]]; then
    PHYS_IF="$def_if"
  else
    # VPN (or unusual route): walk the service order for the first hardware port with an IP.
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
# Root: wdutil (full detail incl. SSID/BSSID). Otherwise: system_profiler (SSID may be hidden
# by macOS location privacy). Sets WIFI_* vars.
wifi_info() {
  WIFI_SSID=""; WIFI_RSSI=""; WIFI_NOISE=""; WIFI_TX=""; WIFI_CH=""; WIFI_BAND=""; WIFI_WIDTH=""; WIFI_PHY=""; WIFI_SEC=""
  WIFI_BSSID=""; WIFI_MCS=""; WIFI_NSS=""; WIFI_CCA=""
  local out ch
  if (( amRoot )); then
    out=$(/usr/bin/wdutil info 2>/dev/null | /usr/bin/awk '/^WIFI/{f=1;next} f&&/^[A-Z][A-Z ]+$/{exit} f')
    kv() { print -r -- "$out" | /usr/bin/awk -F' : ' -v k="$1" '{g=$1; gsub(/^ +| +$/,"",g)} g==k{sub(/^ +/,"",$2); print $2; exit}'; }
    WIFI_SSID=$(kv SSID); WIFI_RSSI=$(kv RSSI); WIFI_NOISE=$(kv Noise); WIFI_TX=$(kv "Tx Rate")
    WIFI_PHY=$(kv "PHY Mode"); WIFI_SEC=$(kv Security); ch=$(kv Channel)          # e.g. 5g153/80
    WIFI_BSSID=$(kv BSSID); WIFI_MCS=$(kv "MCS Index"); WIFI_NSS=$(kv NSS); WIFI_CCA=$(kv CCA)
    [[ "$WIFI_BSSID" == *redacted* ]] && WIFI_BSSID=""
    WIFI_RSSI="${WIFI_RSSI%% *}"; WIFI_NOISE="${WIFI_NOISE%% *}"; WIFI_TX="${WIFI_TX%% *}"
    if [[ "$ch" == (#b)([0-9])g([0-9]##)/([0-9]##)* ]]; then
      WIFI_BAND="${match[1]}"; WIFI_CH="${match[2]}"; WIFI_WIDTH="${match[3]}"
      [[ "$WIFI_BAND" == 2 ]] && WIFI_BAND="2.4"
    fi
  fi
  if [[ -z "$WIFI_RSSI" ]]; then
    # CoreWLAN via JXA — instant (system_profiler takes ~13s because it scans nearby networks).
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
  # macOS 14.4+ redacts the SSID in wdutil/ipconfig even for root unless ipconfig verbose mode is
  # on — flip it on just long enough to read the name, then back off.
  if [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *redacted* ]] && (( amRoot )); then
    /usr/sbin/ipconfig setverbose 1 2>/dev/null
    WIFI_SSID=$(/usr/sbin/ipconfig getsummary "$PHYS_IF" 2>/dev/null | /usr/bin/awk -F' : ' '/^ +SSID :/{print $2; exit}')
    /usr/sbin/ipconfig setverbose 0 2>/dev/null
  fi
  [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *redacted* ]] && \
    WIFI_SSID="$( (( amRoot )) && print "(hidden by macOS)" || print "(hidden by macOS — shows when run as root / from Jamf)")"
}

# --- Ping + stats ---------------------------------------------------------------
# ping_run <host> <outfile> [bind-interface]
ping_run() {
  local -a bind; [[ -n "$3" ]] && bind=(-b "$3")
  /sbin/ping -n $bind -c "$PING_COUNT" -i "$PING_INTERVAL" -W 1000 "$1" > "$2" 2>&1
}

# HTTPS fallback when ICMP is blocked: TCP connect time (≈ 1 RTT), written in ping's format
# so the same stats code applies.
http_probe() {   # <url> <outfile>
  local i t a b
  for (( i=0; i<PING_COUNT; i++ )); do
    check_cancel
    t=$(/usr/bin/curl -s -I -o /dev/null -m 2 -w '%{time_namelookup} %{time_connect}' "$1" 2>/dev/null)
    read -r a b <<< "$t"
    if isnum "$b" && isnum "$a" && (( b > 0 )); then print -r -- "icmp_seq=$i time=$(calc "($b-$a)*1000")"; fi
    /bin/sleep "$PING_INTERVAL"
  done > "$2"
}

# ping_stats <file> -> P_RECV P_LOSS P_AVG P_MIN P_MAX P_JIT P_LAG P_LOST
#   Latency = mean RTT of replies. Jitter = mean change between consecutive RTTs.
#   Lag     = "what apps feel": every lost packet costs a resend (a 1.5 × worst-RTT wait)
#             plus another trip, so loss shows up as extra delay.
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

# reliability <lost-list;lost-list;...> -> REL_PCT OUTAGE_LONGEST_S OUTAGE_EVENTS
#   A moment is "unresponsive" only if EVERY target lost that ping, and only runs of
#   OUTAGE_MIN_LOST or more count (spikes don't).
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
# All quick (<0.5s each). Everything here lands in the "For IT" part of the results + the report.

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
  IF_MAC=$(print -r -- "$out" | /usr/bin/awk '/ether /{print $2; exit}')
  IF_MTU=$(print -r -- "$out" | /usr/bin/awk '/mtu /{print $NF; exit}')
  IF_MEDIA=$(print -r -- "$out" | /usr/bin/awk -F'media: ' '/media:/{print $2; exit}')
  IPV6_ADDR=$(print -r -- "$out" | /usr/bin/awk '/inet6 / && !/fe80/ && !/deprecated/{print $2; exit}')

  # Other interfaces that also have an address (Wi-Fi + Ethernet both up, docks, etc.)
  OTHER_IFS=""
  for k in ${(k)PORT_OF}; do
    [[ "$k" == "$PHYS_IF" ]] && continue
    f=$(/usr/sbin/ipconfig getifaddr "$k" 2>/dev/null)
    [[ -n "$f" ]] && OTHER_IFS+="${OTHER_IFS:+, }${PORT_OF[$k]} ($k) $f"
  done

  # Proxy / PAC / WPAD
  out=$(/usr/sbin/scutil --proxy 2>/dev/null)
  pv() { print -r -- "$out" | /usr/bin/awk -F' : ' -v k="$1" '{g=$1; gsub(/^ +/,"",g)} g==k{print $2; exit}'; }
  PROXY_DESC=""
  [[ "$(pv HTTPEnable)" == 1 ]]  && PROXY_DESC+="${PROXY_DESC:+; }HTTP $(pv HTTPProxy):$(pv HTTPPort)"
  [[ "$(pv HTTPSEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }HTTPS $(pv HTTPSProxy):$(pv HTTPSPort)"
  [[ "$(pv SOCKSEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }SOCKS $(pv SOCKSProxy):$(pv SOCKSPort)"
  [[ "$(pv ProxyAutoConfigEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }PAC $(pv ProxyAutoConfigURLString)"
  [[ "$(pv ProxyAutoDiscoveryEnable)" == 1 ]] && PROXY_DESC+="${PROXY_DESC:+; }Auto-discovery (WPAD)"

  # Network extensions (VPN clients, content filters, security agents) + configured VPNs
  NE_LIST=$(/usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/sed -n '/network_extension/,/^---/p' \
            | /usr/bin/awk -F'\t' '/activated enabled/{print $5}' | /usr/bin/awk '!s[$0]++' | /usr/bin/paste -sd';' - | /usr/bin/sed 's/;/; /g')
  VPN_CONFIGS=$(/usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk -F'"' 'NF>2{ st=$1; sub(/.*\(/,"",st); sub(/\).*/,"",st); print $2 " (" st ")" }' | /usr/bin/paste -sd';' - | /usr/bin/sed 's/;/; /g')
}

# Which Cloudflare edge city this Mac lands on (a far-away edge = odd routing / VPN egress).
cf_edge() {
  local out=$(/usr/bin/curl -s -m 4 https://speed.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  CF_COLO=$(print -r -- "$out" | /usr/bin/awk -F= '/^colo=/{print $2}')
  CF_WARP=$(print -r -- "$out" | /usr/bin/awk -F= '/^warp=/{print $2}')
}

# Interface error counters + TCP retransmits (TCP stats only populate when run as root).
counters() {
  local e=$(/usr/sbin/netstat -ibn -I "$PHYS_IF" 2>/dev/null | /usr/bin/awk 'NR==2{print $6+0, $9+0}')
  local t=$(/usr/sbin/netstat -s -p tcp 2>/dev/null | /usr/bin/awk '/packets? sent$/ && !s{s=$1} /data packets? \(.*\) retransmitted$/ && !r{r=$1} END{print s+0, r+0}')
  print -r -- "$e $t"
}

# Wi-Fi sampler: one CoreWLAN reading per second (rssi noise txrate channel) for N seconds.
wifi_sampler() {   # <seconds> <outfile>
  /usr/bin/osascript -l JavaScript -e "ObjC.import('CoreWLAN'); var i=\$.CWWiFiClient.sharedWiFiClient.interface, o=[];
    for(var k=0;k<$1;k++){ var c=i.wlanChannel; o.push([i.rssiValue,i.noiseMeasurement,i.transmitRate,c?c.channelNumber:0].join(' '));
    \$.NSThread.sleepForTimeInterval(1); } o.join('\n')" > "$2" 2>/dev/null
}

# Nearby networks from the last system scan (no new scan = instant). Sets WIFI_NEARBY / WIFI_COCHAN.
wifi_neighbors() {
  local out=$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreWLAN"); var s=$.CWWiFiClient.sharedWiFiClient.interface.cachedScanResults;
    var a=s?s.allObjects:null, o=[]; if(a){ for(var k=0;k<a.count;k++){ var x=a.objectAtIndex(k); o.push(x.wlanChannel.channelNumber+":"+x.rssiValue);} } o.join(" ")' 2>/dev/null)
  read -r WIFI_NEARBY WIFI_COCHAN WIFI_COCHAN_STRONG <<< "$(print -r -- "$out" | /usr/bin/tr ' ' '\n' | /usr/bin/awk -F: -v ch="$WIFI_CH" '
    NF==2 && !seen[$0]++ { n++; if($1==ch){ c++; if($2>-75) s++ } } END{ print n+0, c+0, s+0 }')"
}

# Path trace: hop list "n<tab>ip<tab>avg-ms<tab>lost-of-3". Private/CGNAT ranges flag the LAN side.
parse_trace() {
  /usr/bin/awk '/^ *[0-9]+ /{ n=$1; ip=""; s=0; c=0; l=0
    for(i=2;i<=NF;i++){ if($i=="*") l++; else if($(i+1)=="ms" && $i ~ /^[0-9.]+$/){s+=$i;c++} else if(ip=="" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i }
    printf "%s\t%s\t%s\t%d\n", n, (ip==""?"*":ip), (c?sprintf("%.1f",s/c):"-"), l }' "$1" 2>/dev/null
}
is_private_ip() { [[ "$1" == (10.*|192.168.*|172.(1[6-9]|2[0-9]|3[01]).*|100.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]).*|169.254.*) ]]; }

# Router timing via a 1-hop traceroute aimed AT the router — many routers ignore ping but still
# answer UDP probes (port-unreachable / "!X"). Aimed at the gateway it stays on the LAN even when a
# VPN owns the default route. Sets R_RESPONDER (the address that answered — e.g. Meraki 10.128.128.128).
router_trace() {   # <outfile in ping format>
  local line=$(/usr/sbin/traceroute -n -m 1 -q 10 -w 1 "$GATEWAY" 2>/dev/null | /usr/bin/tail -1)
  R_RESPONDER=$(print -r -- "$line" | /usr/bin/awk '{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')
  print -r -- "$line" | /usr/bin/awk '{k=0; for(i=2;i<=NF;i++){ if($i=="*") k++; else if($(i+1)=="ms"){ print "icmp_seq=" k " time=" $i; k++ } }}' > "$1"
}

# DNS: time each configured resolver against public ones. Rows go to DNS_ROWS.
dns_tests() {
  local r d q lbl sum n fails; local -a rs=(${(s:, :)DNS_SERVERS} 1.1.1.1 8.8.8.8); rs=(${(u)rs})
  DNS_ROWS=(); DNS_CFG_AVG=""; DNS_PUB_BEST=""
  [[ -x /usr/bin/dig ]] || return 0
  for r in $rs; do
    check_cancel
    sum=0; n=0; fails=0
    for d in $DNS_TEST_DOMAINS; do
      q=$(/usr/bin/dig +tries=1 +time=2 @"$r" "$d" A 2>/dev/null | /usr/bin/awk '/Query time/{print $4}')
      if isnum "$q"; then sum=$(( sum + q )); (( n++ )); else (( fails++ )); fi
    done
    case $r in 1.1.1.1) lbl="Cloudflare 1.1.1.1";; 8.8.8.8) lbl="Google 8.8.8.8";; *) lbl="Your DNS $r";; esac
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

# Captive portal, IPv6 reachability, path MTU, clock offset.
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
    for s in 1472 1452 1400 1372 1300 1200; do
      /sbin/ping -D -n -s $s -c 1 -t 1 "${INTERNET_TARGETS[1]}" >/dev/null 2>&1 && { PMTU=$(( s + 28 )); break; }
    done
  fi
  CLOCK_OFF_MS=$(/usr/bin/sntp -t 2 time.apple.com 2>/dev/null | /usr/bin/awk '$1 ~ /^[+-][0-9]/{printf "%.0f", $1*1000; exit}')
}

# --- Speed ------------------------------------------------------------------------
# Sets DL_MBPS UL_MBPS IDLE_MS LOADED_MS SPEED_SERVER SPEED_NOTE
speed_apple() {
  local f="$SCRATCH/nq.json" rpm
  local pid
  # -s = sequential: download, then upload. Running both at once (the default) makes them fight
  # for Wi-Fi airtime and badly under-reports download on many networks.
  /usr/bin/networkQuality -c -s -M "$SPEED_MAX_SECONDS" > "$f" 2>/dev/null & pid=$!
  throughput_monitor $pid both; wait $pid
  if [[ ! -s "$f" ]]; then /usr/bin/networkQuality -c -s > "$f" 2>/dev/null & pid=$!; throughput_monitor $pid both; wait $pid; fi
  local dl=$(/usr/bin/plutil -extract dl_throughput raw -o - "$f" 2>/dev/null)
  local ul=$(/usr/bin/plutil -extract ul_throughput raw -o - "$f" 2>/dev/null)
  isnum "$dl" || return 1
  DL_MBPS=$(calc "$dl/1000000"); UL_MBPS=$(calc "${ul:-0}/1000000")
  IDLE_MS=$(/usr/bin/plutil -extract base_rtt raw -o - "$f" 2>/dev/null)
  # Latency under load: the worse (lower RPM) of the download and upload phases.
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
  # Download while pinging, to measure latency under load (bufferbloat)
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

# --- Simulation mode (testing) --------------------------------------------------------------------
# Fakes the measurements for a named scenario, then runs the SAME scoring, findings, HUD and results
# window as a real test — so you can see exactly what a user would see without breaking a network.
# Combine scenarios with commas, e.g.  NHC_SIMULATE=weak-wifi,vpn ./Network_Health_Check.sh
SIM_SCENARIOS=(healthy not-connected no-internet captive-portal packet-loss outage ping-blocked slow-dns
               bufferbloat slow-speed weak-wifi 2ghz vpn broken-ipv6 router-bottleneck isp-problem
               clock-skew proxy slow-ethernet all-bad)

simulate_run() {
  sim_sleep() { [[ "$ACTION_MODE" == verbose ]] && /bin/sleep "$1"; return 0; }   # no waiting when silent
  local sc="$SIMULATE" i host
  [[ "$sc" == all-bad ]] && sc="weak-wifi,packet-loss,outage,slow-dns,bufferbloat,slow-speed,vpn,broken-ipv6,clock-skew,proxy"
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

  # Healthy baseline -----------------------------------------------------------------
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

  # Scenario overrides ---------------------------------------------------------------
  sim weak-wifi   && { WIFI_RSSI=-78; WIFI_NOISE=-92; WS_MIN=-84; WS_AVG=-78; WS_MAX=-72; WIFI_TX=29; WS_TXMIN=6; WS_TXMAX=58; INET_JIT=38; INET_LAT=44; INET_LAG=52; INET_LOSS=1.5; R_LAT=28; R_JIT=22; R_LAG=31; }
  sim 2ghz        && { WIFI_BAND=2.4; WIFI_CH=6; WIFI_WIDTH=20; WIFI_TX=72; WS_TXMIN=58; WS_TXMAX=72; WS_CHANS=6; WIFI_COCHAN=9; WIFI_COCHAN_STRONG=6; WIFI_PHY="802.11n (Wi-Fi 4)"; }
  sim packet-loss && { INET_LOSS=6.5; INET_LAT=35; INET_LAG=96; INET_JIT=24; }
  sim outage      && { REL_PCT=86.0; OUTAGE_EVENTS=3; OUTAGE_LONGEST_S=4.5; }
  sim ping-blocked && { INET_METHOD="HTTPS connect (ICMP blocked)"; ROUTER_OK=0; PMTU=""; INET_LAT=24; INET_LAG=24; }
  sim slow-dns    && { DNS_CFG_AVG=240; WEB_DNS=260; WEB_TTFB=520; }
  sim bufferbloat && { LOADED_MS=640; }
  sim slow-speed  && { DL_MBPS=6.2; UL_MBPS=0.9; LOADED_MS=310; }
  sim vpn         && { VPN_ACTIVE=1; VPN_NAME="Corporate VPN (simulated)"; PMTU=1400; INET_LAT=$(( INET_LAT + 30 )); INET_LAG=$(( INET_LAG + 30 )); VPN_CONFIGS="Corporate VPN (Connected)"; NE_LIST="Example VPN Extension"; }
  sim broken-ipv6 && { IPV6_ADDR="2001:db8::50"; IPV6_NET="broken"; }
  sim router-bottleneck && { R_LAT=118; R_JIT=45; R_LAG=140; R_LOSS=4; INET_LAT=150; INET_LAG=170; INET_JIT=48; }
  sim isp-problem && { R_LAT=3; R_LAG=3; ISP_HOP_MS=150; INET_LAT=185; INET_LAG=190; INET_JIT=12; }
  sim clock-skew  && { CLOCK_OFF_MS=312000; }
  sim proxy       && { PROXY_DESC="PAC http://proxy.example.com/proxy.pac"; }
  sim slow-ethernet && { CONN_TYPE="Ethernet"; PHYS_IF="en5"; PORT_NAME="USB 10/100 LAN"; IF_MEDIA="autoselect (100baseTX <half-duplex>)"; DL_MBPS=88; UL_MBPS=85; }
  if sim captive-portal || sim no-internet; then
    NO_INTERNET=1; INET_LAT="-"; INET_JIT="-"; INET_LOSS=100; INET_LAG="-"; REL_PCT=0; OUTAGE_EVENTS=1; OUTAGE_LONGEST_S=$TEST_SECONDS
    ISP_HOP=""; PMTU=""; DL_MBPS=""; UL_MBPS=""; IDLE_MS=""; LOADED_MS=""; WEB_TTFB="-"; WEB_DNS="-"; DNS_CFG_AVG=""; DNS_PUB_BEST=""
    CAPTIVE="unknown"; sim captive-portal && CAPTIVE="detected"
  fi

  # Rows built from the (faked) numbers ------------------------------------------------
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

  # Walk the HUD through the steps with fake live data so the whole experience can be seen -------
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
  (( NO_INTERNET )) || fact "g:${#WEB_TARGETS} of ${#WEB_TARGETS}" "websites loaded"
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

SCRIPT_VERSION="1.10"

# --- Step timing ------------------------------------------------------------------------------------
# mark <step> — records how long the step since the previous mark took (log + report + JSON).
mark() { local n=$EPOCHREALTIME; TIMINGS+=("$1 $(calc "$n-$T_LAST")"); T_LAST=$n; }
timings_text() { local t out=""; for t in $TIMINGS; do out+="${out:+ · }${t% *} ${t#* }s"; done; print -r -- "$out · total $(calc "$EPOCHREALTIME-$T_START")s"; }

# --- Cancel -------------------------------------------------------------------------------------------
# The HUD's Cancel button writes to CANCEL_FILE (made world-writable because the HUD runs as the
# logged-in user while this script may run as root). Checked in every loop and between steps.
check_cancel() {
  [[ -s "$CANCEL_FILE" ]] || return 0
  logMe INFO "User cancelled the test."
  kill_spinner; stop_children
  exit 0      # a user cancel is not a failure (keeps the Jamf policy green)
}

# --- JSON results (optional) ----------------------------------------------------------------------
# SAVE_JSON=true writes $JSON_DIR/last.json and appends one line per run to history.jsonl — handy for
# comparing runs before/after a fix, or for a Jamf Extension Attribute to read the last score.
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
    print -r -- "  \"checks\": {\"captive_portal\": $(jstr "$CAPTIVE"), \"ipv6\": $(jstr "${IPV6_NET:-not configured}"), \"path_mtu\": $(jnum "$PMTU"), \"clock_offset_ms\": $(jnum "$CLOCK_OFF_MS"), \"proxy\": $(jstr "$PROXY_DESC")},"
    print -rn -- "  \"timings_s\": {"; first=1
    for t in $TIMINGS; do (( first )) || print -rn -- ", "; first=0; print -rn -- "$(jstr "${t% *}"): ${t#* }"; done
    print -r -- "},"
    print -rn -- "  \"findings\": ["; first=1
    while IFS=$'\t' read -r tag txt; do (( first )) || print -rn -- ", "; first=0; print -rn -- "{\"status\": $(jstr "$tag"), \"text\": $(jstr "$txt")}"; done < "$FIND_FILE"
    print -r -- "]"
    print -r -- "}"
  } > "$f"
  # one-line copy for the history log (trimmed to JSON_HISTORY_MAX runs)
  /usr/bin/tr -d '\n' < "$f" | /usr/bin/sed 's/  */ /g' >> "$JSON_DIR/history.jsonl"; print >> "$JSON_DIR/history.jsonl"
  /usr/bin/tail -n "$JSON_HISTORY_MAX" "$JSON_DIR/history.jsonl" > "$JSON_DIR/.h.tmp" 2>/dev/null && /bin/mv "$JSON_DIR/.h.tmp" "$JSON_DIR/history.jsonl"
  /bin/chmod 644 "$f" "$JSON_DIR/history.jsonl" 2>/dev/null
  logMe INFO "JSON results written: $f"
}

####################################################################################################
#
# Run all tests -> fills $DATA_FILE / $FIND_FILE / $REPORT_FILE and the score variables
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

  # Progress ranges per step (from to) — speed is the longest step when it runs.
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

  # 2. Responsiveness: pings + (in the background) path trace, Wi-Fi sampling, counters -------------
  local router_file="$SCRATCH/ping_router.txt" trace_file="$SCRATCH/trace.txt" wifi_file="$SCRATCH/wifi_samples.txt"
  : > "$router_file"; : > "$trace_file"; : > "$wifi_file"
  c0=($(counters))
  for (( i=1; i<=${#INTERNET_TARGETS}; i++ )); do
    f="$SCRATCH/ping_inet_$i.txt"; inet_files+=("$f")
    ping_run "${INTERNET_TARGETS[$i]}" "$f" & ping_pids+=($!)
  done
  [[ -n "$GATEWAY" ]] && { ping_run "$GATEWAY" "$router_file" "$PHYS_IF" & ping_pids+=($!); }
  /usr/sbin/traceroute -n -q 3 -w 1 -m 12 "${INTERNET_TARGETS[1]}" > "$trace_file" 2>/dev/null & local trace_pid=$!
  local wifi_pid=""; [[ "$CONN_TYPE" == "Wi-Fi" ]] && { wifi_sampler "$TEST_SECONDS" "$wifi_file" & wifi_pid=$!; }

  local start=$SECONDS last; local -a lspk
  spin_status 1 "Measuring responsiveness & reliability" "Pinging ${(j:, :)INTERNET_TARGETS}${GATEWAY:+ and your router} for ${TEST_SECONDS}s…" ${P_RSP[1]} ${P_RSP[2]} $TEST_SECONDS 1
  pings_running() { local p; for p in $ping_pids; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
  while pings_running && (( SECONDS - start < TEST_SECONDS + 5 )); do
    check_cancel
    t=$(( TEST_SECONDS - (SECONDS - start) )); (( t < 0 )) && t=0
    if [[ "$ACTION_MODE" == verbose ]]; then
      # Live readout uses its own one-shot ping: ping's file output is block-buffered, so reading the
      # measurement files would update in bursts. (Display only — the stats come from the files.)
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
  # give the path trace a few more seconds, then stop it
  for (( i=0; i<12; i++ )); do check_cancel; kill -0 $trace_pid 2>/dev/null || break; /bin/sleep 0.5; done
  kill $trace_pid 2>/dev/null; wait $trace_pid 2>/dev/null
  [[ -n "$wifi_pid" ]] && { kill $wifi_pid 2>/dev/null; wait $wifi_pid 2>/dev/null; }

  # Analyse internet targets
  INET_METHOD="ICMP ping"
  for (( i=1; i<=${#INTERNET_TARGETS}; i++ )); do
    ping_stats "${inet_files[$i]}"
    if (( P_RECV > 0 )); then
      (( n_ok++ )); ok_lists+=("$P_LOST")
      sum_lat=$(calc "$sum_lat+$P_AVG"); sum_jit=$(calc "$sum_jit+$P_JIT"); sum_loss=$(calc "$sum_loss+$P_LOSS"); sum_lag=$(calc "$sum_lag+$P_LAG")
      tgt_rows+=("${INTERNET_TARGETS[$i]}"$'\t'"$(ms $P_AVG) avg ($(ms $P_MIN)–$(ms $P_MAX)) · jitter $(ms $P_JIT) · ${P_LOSS}% loss"$'\t'"$(lag_status $P_LAG)")
    else
      tgt_rows+=("${INTERNET_TARGETS[$i]}"$'\t'"No reply (ping blocked or unreachable)"$'\t'"na")
    fi
  done

  # ICMP blocked everywhere? fall back to HTTPS connect timing
  if (( n_ok == 0 )); then
    INET_METHOD="HTTPS connect (ICMP blocked)"
    tgt_rows=()
    for (( i=1; i<=${#HTTPS_FALLBACK_TARGETS}; i++ )); do
      host="${HTTPS_FALLBACK_TARGETS[$i]}"; f="$SCRATCH/http_$i.txt"
      spin_status 1 "Measuring responsiveness" "Ping is blocked — timing HTTPS connections to ${host#https://}…" ${P_RSP[2]} ${P_WEB[1]} $TEST_SECONDS
      http_probe "$host" "$f"; ping_stats "$f"
      if (( P_RECV > 0 )); then
        (( n_ok++ )); ok_lists+=("$P_LOST")
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
  else
    INET_LAT=$(calc "$sum_lat/$n_ok"); INET_JIT=$(calc "$sum_jit/$n_ok"); INET_LOSS=$(calc "$sum_loss/$n_ok"); INET_LAG=$(calc "$sum_lag/$n_ok")
    reliability_calc "${(j:;:)ok_lists}"
    fact "$(lag_code $INET_LAG):$(r0 $INET_LAG) ms" "internet lag  ·  jitter $(ms $INET_JIT)  ·  ${INET_LOSS}% loss"
  fi

  # Router (first hop): ping, else traceroute hop 1 (routers often ignore ping but answer that)
  ROUTER_OK=0; R_METHOD=""
  if [[ -n "$GATEWAY" ]]; then
    ping_stats "$router_file"
    if (( P_RECV > 0 )); then R_METHOD="ping"
    else local pc=$PING_COUNT; router_trace "$router_file"; PING_COUNT=10; ping_stats "$router_file"; PING_COUNT=$pc
         if (( P_RECV > 0 )) && is_private_ip "$R_RESPONDER"; then
           R_METHOD="traceroute (router ignores ping$([[ $R_RESPONDER != $GATEWAY ]] && print "; answered as $R_RESPONDER"))"
           P_LOSS="-"; P_LAG=$P_AVG     # routers rate-limit these replies, so "loss" here isn't real loss
         else P_RECV=0; fi
    fi
    if (( P_RECV > 0 )); then ROUTER_OK=1; R_LAT=$P_AVG; R_JIT=$P_JIT; R_LOSS=$P_LOSS; R_LAG=$P_LAG; fi
  fi

  # Path hops + ISP first hop
  hops=("${(@f)$(parse_trace "$trace_file")}")
  ISP_HOP=""; ISP_HOP_MS=""
  for t in $hops; do local -a p=("${(@ps:\t:)t}")
    [[ "${p[2]}" != "*" ]] && ! is_private_ip "${p[2]}" && isnum "${p[3]}" && { ISP_HOP="${p[2]}"; ISP_HOP_MS="${p[3]}"; break; }
  done

  # Wi-Fi during the test
  WS_MIN=""; WS_AVG=""; WS_MAX=""; WS_TXMIN=""; WS_TXMAX=""; WS_CHANS=""
  if [[ -s "$wifi_file" ]]; then
    read -r WS_MIN WS_AVG WS_MAX WS_TXMIN WS_TXMAX WS_CHANS <<< "$(/usr/bin/awk '$1<0{ n++; s+=$1; if(!mn||$1<mn)mn=$1; if(!mx||$1>mx)mx=$1;
      if(!tn||$3<tn)tn=$3; if($3>tx)tx=$3; if(!(($4) in c)){c[$4]=1; ch=ch (ch==""?"":"/") $4} }
      END{ if(n) printf "%d %.0f %d %.0f %.0f %s\n", mn, s/n, mx, tn, tx, ch }' "$wifi_file")"
  fi

  check_cancel; mark responsiveness

  # 3. Web, DNS & network checks -------------------------------------------------------------
  local code dns conn tls ttfb hv rip
  if (( ! NO_INTERNET )); then
    spin_status 2 "Testing websites & DNS" "Loading ${#WEB_TARGETS} common sites…" ${P_WEB[1]} ${P_WEB[2]} $(( ${#WEB_TARGETS} + 4 ))
    for (( i=1; i<=${#WEB_TARGETS}; i++ )); do
      check_cancel
      host="${WEB_TARGETS[$i]#https://}"; host="${host%%/*}"
      read -r code dns conn tls ttfb hv rip <<< "$(/usr/bin/curl -s -o /dev/null -m 10 -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{http_version} %{remote_ip}' "${WEB_TARGETS[$i]}" 2>/dev/null)"
      if [[ -n "$code" && "$code" != 000 ]] && isnum "$ttfb"; then
        dns=$(calc "$dns*1000"); ttfb=$(calc "$ttfb*1000"); conn=$(calc "$conn*1000"); tls=$(calc "$tls*1000")
        (( n_web++ )); sum_ttfb=$(calc "$sum_ttfb+$ttfb"); sum_dns=$(calc "$sum_dns+$dns")
        s=good; (( ttfb > 400 )) && s=ok; (( ttfb > 1000 )) && s=bad
        web_rows+=("$host"$'\t'"first byte $(ms $ttfb) · DNS $(ms $dns) · TLS $(ms $tls) · HTTP/$hv"$'\t'"$s")
        web_spark+=($ttfb); live_metric "$(stat_code $s):$(r0 $ttfb) ms" "first byte  ·  $host" "${(j:,:)web_spark}"
      else
        (( web_fail++ )); web_rows+=("$host"$'\t'"Failed to load"$'\t'"bad")
      fi
    done
    fact "$( (( web_fail )) && print r || print g):$(( ${#WEB_TARGETS} - web_fail )) of ${#WEB_TARGETS}" "websites loaded"
    spin_status 2 "Testing websites & DNS" "Timing DNS servers, checking IPv6, MTU and clock…" ${P_WEB[1]} ${P_WEB[2]} 4
    dns_tests
    [[ -n "$DNS_CFG_AVG" && "$DNS_CFG_AVG" != 9999 ]] && fact "$( (( DNS_CFG_AVG > 150 )) && print r || { (( DNS_CFG_AVG > 60 )) && print o || print g; })":"$DNS_CFG_AVG ms" "your DNS server lookup time"
  fi
  (( n_web )) && { WEB_TTFB=$(calc "$sum_ttfb/$n_web"); WEB_DNS=$(calc "$sum_dns/$n_web"); } || { WEB_TTFB="-"; WEB_DNS="-"; }
  misc_checks
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
  fi   # end real measurements (simulation fills the same variables in simulate_run)

  # 5. Scores -------------------------------------------------------------------------
  spin_status 4 "Scoring results" "Crunching the numbers…" ${P_SCR[1]} 99 1
  # Responsiveness is driven by lag (jitter + loss feed in through lag).
  if (( NO_INTERNET )); then RESP_SCORE=0; else RESP_SCORE=$(interp "$INET_LAG" "0:100 20:100 50:92 100:78 200:55 400:25 800:0"); fi
  # Bufferbloat grade (needed below): how much latency rises under load
  BLOAT_MS=""; BLOAT_GRADE=""
  if isnum "$LOADED_MS" && isnum "$IDLE_MS"; then
    BLOAT_MS=$(calc "$LOADED_MS-$IDLE_MS"); (( BLOAT_MS < 0 )) && BLOAT_MS=0
    if   (( BLOAT_MS < 30 ));  then BLOAT_GRADE="A"
    elif (( BLOAT_MS < 60 ));  then BLOAT_GRADE="B"
    elif (( BLOAT_MS < 200 )); then BLOAT_GRADE="C"
    elif (( BLOAT_MS < 400 )); then BLOAT_GRADE="D"
    else BLOAT_GRADE="F"; fi
  fi
  # Things users feel that lag alone under-counts: jitter (choppy calls), packet loss, and lag that
  # balloons when the connection is busy (bufferbloat).
  if (( ! NO_INTERNET )); then
    local pen=0
    isnum "$INET_JIT" && (( INET_JIT > 10 )) && pen=$(calc "$pen+($INET_JIT-10)*0.5")
    isnum "$INET_LOSS" && pen=$(calc "$pen+$INET_LOSS*4")
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
  # The overall score is scaled down by reliability when reliability < 90
  (( REL_SCORE < 90 )) && NET_SCORE=$(r0 "$(calc "$NET_SCORE*$REL_SCORE/90")")

  # Video-call readiness (Zoom/Teams guidance: latency ≤150 ms, jitter ≤30 ms, loss <1%)
  if (( NO_INTERNET )); then VIDEO_STATUS=bad; VIDEO_TEXT="Not ready — no internet"
  elif (( INET_LAT <= 150 && INET_JIT <= 30 && INET_LOSS < 1 && REL_SCORE >= 90 )); then
    VIDEO_STATUS=good; VIDEO_TEXT="Ready"
    [[ "$BLOAT_GRADE" == [DF] ]] && { VIDEO_STATUS=ok; VIDEO_TEXT="Ready, but may stutter during big uploads/downloads"; }
  elif (( INET_LAT <= 250 && INET_JIT <= 50 && INET_LOSS < 3 )); then VIDEO_STATUS=ok; VIDEO_TEXT="Usable — may stutter or freeze at times"
  else VIDEO_STATUS=bad; VIDEO_TEXT="Poor — expect freezing, robotic audio, or drops"; fi

  # Headline (pairs responsiveness with speed)
  local rgood=0 sgood=0; (( RESP_SCORE >= 80 )) && rgood=1; [[ -n "$SPEED_SCORE" ]] && (( SPEED_SCORE >= 80 )) && sgood=1
  if (( NO_INTERNET )); then
    HEADLINE="No Internet"; SUBHEADLINE="Connected to ${CONN_TYPE}, but nothing on the internet answered. Check the network, captive portal, or VPN."
  elif (( REL_SCORE < 75 )); then
    HEADLINE="Unstable Connection"; SUBHEADLINE="Your connection dropped out during the test. Calls, uploads, and remote sessions may disconnect."
  elif [[ -z "$SPEED_SCORE" ]]; then
    (( rgood )) && { HEADLINE="Responsive"; SUBHEADLINE="Quick to react — good for calls, browsing, and remote sessions. (Speed test skipped.)"; } \
                || { HEADLINE="Laggy"; SUBHEADLINE="Slow to react — calls and remote sessions may stutter. (Speed test skipped.)"; }
  elif (( rgood && sgood )); then HEADLINE="Fast & Responsive"; SUBHEADLINE="Your connection is quick to react and has plenty of bandwidth. You're good to go."
  elif (( rgood ));          then HEADLINE="Responsive but Slow"; SUBHEADLINE="Quick to react, but bandwidth is limited — large downloads, uploads, and HD video may be slow."
  elif (( sgood ));          then HEADLINE="Fast but Laggy"; SUBHEADLINE="Plenty of bandwidth, but slow to react — video calls, gaming, and remote sessions may stutter."
  else                            HEADLINE="Laggy & Slow"; SUBHEADLINE="Your connection is slow to react and short on bandwidth. Most online work will feel sluggish."
  fi

  # Counter deltas
  local ierr=$(( ${c1[1]:-0} - ${c0[1]:-0} )) oerr=$(( ${c1[2]:-0} - ${c0[2]:-0} ))
  local tsent=$(( ${c1[3]:-0} - ${c0[3]:-0} )) tretx=$(( ${c1[4]:-0} - ${c0[4]:-0} )) retx_pct=""
  (( tsent > 100 )) && retx_pct=$(calc "$tretx*100/$tsent")

  # 6. Findings (plain English) ---------------------------------------------------------
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
    if (( INET_LOSS >= 2 )); then
      finding bad "${INET_LOSS}% packet loss — congestion or a weak signal is forcing resends (lag $(ms $INET_LAG) vs latency $(ms $INET_LAT))."
    elif (( INET_JIT > 30 )); then
      finding ok "High jitter ($(ms $INET_JIT)) — response times swing a lot, typical of busy or weak Wi-Fi. Calls may sound choppy."
    fi
    (( OUTAGE_EVENTS > 0 )) && finding bad "Connection went unresponsive ${OUTAGE_EVENTS}× during the test (longest ${OUTAGE_LONGEST_S}s)."
    (( web_fail > 0 )) && finding bad "$web_fail of ${#WEB_TARGETS} test websites failed to load."
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
    isnum "$WIFI_COCHAN_STRONG" && (( WIFI_COCHAN_STRONG >= 4 )) && finding ok "$WIFI_COCHAN_STRONG other strong networks share Wi-Fi channel $WIFI_CH — interference likely."
    isnum "${WIFI_CCA%%[^0-9]*}" && (( ${WIFI_CCA%%[^0-9]*} >= 50 )) && finding ok "Wi-Fi channel is busy ${WIFI_CCA} of the time — congestion."
  fi
  (( ierr + oerr > 0 )) && finding ok "$(( ierr + oerr )) network interface errors during the test."
  [[ -n "$retx_pct" ]] && (( retx_pct >= 2 )) && finding ok "TCP retransmits at ${retx_pct}% — packets are being lost and resent."
  [[ "$MAC_LOWPOWER" == 1 ]] && finding na "Low Power Mode is on — it can limit network performance."
  [[ -s "$FIND_FILE" ]] || finding good "No problems found — your connection looks healthy."
  # Don't say "you're good to go" next to red findings.
  local nbad=$(/usr/bin/grep -c "^bad" "$FIND_FILE")
  if (( nbad > 0 && NET_SCORE >= 80 )); then
    SUBHEADLINE="Speed and responsiveness look good, but we found $nbad issue$( (( nbad > 1 )) && print s) below that can still cause problems."
  fi

  # Finish line: the bar hits 100%, the score shows, then the results window opens.
  if [[ "$ACTION_MODE" == verbose ]]; then
    fact "$(band_code $NET_SCORE):$NET_SCORE" "Network Score  ·  $(band_label $NET_SCORE)  ·  Video calls: ${VIDEO_TEXT%% —*}"
    spin_status 5 "All done — $HEADLINE" "Opening your results…" 100 100 0.1
    /bin/sleep 2.5
  fi

  # 7. Detail rows — user-facing first, then the "For IT" block ------------------------------
  section "Connection" "network"
  row "Connection type" "$CONN_TYPE ($PHYS_IF)" na
  [[ "$CONN_TYPE" == "Wi-Fi" ]] && row "Network name" "$WIFI_SSID" na
  [[ -n "$PUB_ISP" ]] && row "Internet provider" "$PUB_ISP${PUB_LOC:+ · $PUB_LOC}" na
  row "VPN" "$( (( VPN_ACTIVE )) && print -r -- "$VPN_NAME" || print Off)" "$( (( VPN_ACTIVE )) && print ok || print na)"
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
    [[ -n "$WIFI_PHY" ]] && row "Wi-Fi standard" "$WIFI_PHY" na
    if isnum "$WIFI_TX"; then s=good; (( WIFI_TX < 200 )) && s=ok; (( WIFI_TX < 50 )) && s=bad
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
    row "Packet loss" "${INET_LOSS}%" "$(loss_status $INET_LOSS)"
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
    isnum "$IDLE_MS" && row "Latency (idle)" "$(ms $IDLE_MS)" "$(lag_status $IDLE_MS)"
    isnum "$LOADED_MS" && row "Latency (under load)" "$(ms $LOADED_MS)" "$(lag_status $LOADED_MS)"
    if [[ -n "$BLOAT_GRADE" ]]; then
      s=good; [[ $BLOAT_GRADE == C ]] && s=ok; [[ $BLOAT_GRADE == [DF] ]] && s=bad
      row "Bufferbloat" "Grade $BLOAT_GRADE  (+$(ms $BLOAT_MS) when busy)" $s
    fi
  fi

  section "Reliability  ·  score $REL_SCORE" "checkmark.shield"
  s=good; (( REL_PCT < 99 )) && s=ok; (( REL_PCT < 95 )) && s=bad
  row "Responsive during test" "${REL_PCT}%" $s
  row "Outages" "$( (( OUTAGE_EVENTS )) && print "$OUTAGE_EVENTS (longest ${OUTAGE_LONGEST_S}s)" || print None)" "$( (( OUTAGE_EVENTS )) && print bad || print good)"

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
  row "MAC address" "${IF_MAC:-—}" na
  row "Interface MTU" "${IF_MTU:-—}" na
  [[ -n "$IF_MEDIA" && "$CONN_TYPE" == Ethernet ]] && row "Ethernet link" "$IF_MEDIA" "$([[ $IF_MEDIA == *(10baseT|100baseTX|half-duplex)* ]] && print bad || print good)"
  row "IPv6" "${IPV6_ADDR:+$IPV6_ADDR · }${IPV6_NET:-not configured}" "$([[ $IPV6_NET == broken ]] && print bad || { [[ $IPV6_NET == working* ]] && print good || print na; })"
  [[ -n "$OTHER_IFS" ]] && row "Other active interfaces" "$OTHER_IFS" na
  [[ -n "$PUB_IP" ]] && row "Public IP" "$PUB_IP" na
  [[ -n "$CF_COLO" ]] && row "Nearest Cloudflare edge" "$CF_COLO$([[ $CF_WARP == on ]] && print " · WARP on")" na
  row "Proxy" "${PROXY_DESC:-None}" "$([[ -n $PROXY_DESC ]] && print ok || print na)"
  row "Network extensions" "${NE_LIST:-None}" na
  row "VPN configurations" "${VPN_CONFIGS:-None}" na

  if [[ "$CONN_TYPE" == "Wi-Fi" ]]; then
    section "Wi-Fi Details" "antenna.radiowaves.left.and.right"
    [[ -n "$WIFI_BSSID" ]] && row "Access point (BSSID)" "$WIFI_BSSID" na
    [[ -n "$WIFI_MCS" ]] && row "MCS / spatial streams" "MCS $WIFI_MCS${WIFI_NSS:+ · $WIFI_NSS streams}" na
    [[ -n "$WIFI_CCA" ]] && row "Channel utilization (CCA)" "$WIFI_CCA" "$( (( ${WIFI_CCA%%[^0-9]*:-0} >= 50 )) && print ok || print na)"
    isnum "$WIFI_NEARBY" && row "Nearby networks (last scan)" "$WIFI_NEARBY seen · $WIFI_COCHAN on channel $WIFI_CH ($WIFI_COCHAN_STRONG strong)" "$( (( WIFI_COCHAN_STRONG >= 4 )) && print ok || print na)"
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
    # Flag the hop where latency jumps — that's where delay enters the path. (Lost probes on middle
    # hops are usually just routers rate-limiting traceroute, so they're shown but not flagged.)
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

# Plain-text report (saved to Desktop / printed in silent mode), built from the same rows.
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
    # Raw output for IT
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

# Simulation helpers: "list" prints the scenarios; unknown names are rejected.
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
