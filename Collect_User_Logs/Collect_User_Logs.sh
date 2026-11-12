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
#   Parameter 6 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 7 Label:  Banner Color (hex, optional)
#   Parameter 8 Label:  Brand Name (optional)
#   Parameter 9 Label:  Appearance (auto, light, or dark)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Action Mode        verbose = show progress + result window (default)
#                            silent  = collect quietly, no windows
#     $5  Extra Log Folders  additional folders to include, comma-separated. Blank = none.
#                            example:  /Library/Application Support/MyApp/Logs,/opt/app/log
#     $6  Brand Icon         logo for the windows. Blank = use BRAND_ICON from the Config block.
#                            examples: /Library/Application Support/Acme/logo.png
#                                      /Applications/Self Service.app
#                                      https://acme.com/logo.png
#                                      sf:building.2.fill
#                                      selfservice   (your Jamf Self Service branding logo)
#                            (long base64 strings are best pasted into BRAND_ICON below)
#     $7  Banner Color       hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                            "auto-dark" (deeper logo shade for white text).
#                            Blank = bannerColor below.
#     $8  Brand Name         small line under the banner title, e.g. "Acme IT Support".
#     $9  Appearance         auto (follow the user's Light/Dark setting), light, or dark.
#                            Blank = APPEARANCE below.
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
# 1.1 11/12/26 - Branding: custom logo (file, .app, URL, base64, or SF Symbol), brand name line,
#               light/dark mode (auto-follow or forced, $9), "auto" colours derived from the logo,
#               branded OK button + accent spinner,
#               configurable accent / card / success / fail colours, Jamf params $6-$8. Bad hex
#               values now fall back to defaults instead of breaking the window. - @cocopuff2u
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
INCLUDE_APP_LOGS=true   # true = also grab logs that sandboxed apps (Teams, Outlook, OneDrive, 1Password…)
                        #        keep in ~/Library/Containers/*/Data/Library/Logs and
                        #        ~/Library/Group Containers/*/…/Logs. Every file there, MAX_FILE_MB cap applies.
INCLUDE_REPORTS=true    # true = add readable reports to the bundle: install history, installed apps,
                        #        background items (launch agents/daemons, extensions), config profiles.
LOOKUP_PUBLIC_IP=true   # true = add the Mac's public (internet-facing) IP to _DEVICE_INFO.txt. This asks
                        # an outside service (api.ipify.org, then checkip.amazonaws.com) — 5s timeout,
                        # nothing is sent but the request itself. false = local IPs only.

# WHERE IT GOES -------------------------------------------------------------
# The zip is written to the logged-in user's Desktop. Name pattern below; tokens are filled in:
#   {USER} = short name   {SERIAL} = device serial   {STAMP} = date/time in STAMP_FORMAT below
#   e.g. Logs_jsmith_C02XK1ABJG5H_2026-11-12_10-40.zip
ZIP_NAME_PATTERN="Logs_{USER}_{SERIAL}_{STAMP}.zip"
STAMP_FORMAT="%Y-%m-%d_%H-%M"   # date format for {STAMP} (strftime). Default = 2026-11-12_10-40 — easy to
                                # read and still sorts by date. No colons (Finder doesn't allow them).
                                # If a zip with the same name already exists, _2, _3… is added.
logFile="/var/log/collect_user_logs.log"     # this script's own run log

# BRANDING (verbose mode only) ----------------------------------------------
BRAND_NAME=""              # optional small line under the banner title, e.g. "Acme IT Support".
                           # Jamf Parameter 8 overrides this.
BRAND_ICON=""              # optional logo, shown in the result banner and above the progress spinner.
                           # Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #                    (png, jpg, heic, icns, pdf, tiff, gif)
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (data:image/png;base64,… ok)
                           #                    make one with:  base64 -i logo.png | pbcopy
                           #   • an SF Symbol   sf:building.2.fill                (tinted to match the theme)
                           #   • Self Service   selfservice   (or: ss) — your Jamf Self Service branding
                           #                    logo (Jamf Pro > Self Service > Branding), as cached on the
                           #                    Mac for the logged-in user. If the user hasn't opened Self
                           #                    Service yet, falls back to the Self Service app's icon.
                           # Blank = no logo. Jamf Parameter 6 overrides this.
                           # Tip: a square PNG with a transparent background, 256×256 or larger, looks best.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto  = follow the user's macOS Light/Dark setting (checked as each window opens)
                           # light = always light windows      dark = always dark windows
                           # Jamf Parameter 9 overrides this.

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto", so a
# typo can't break the window. "auto" values are tuned separately for light and dark mode.
bannerColor="auto"         # banner bar + OK button. Jamf Parameter 7.
                           #   auto      = the exact main colour of BRAND_ICON (text auto-switches to
                           #               near-black if the colour is too bright for white)
                           #   auto-dark = a deeper shade of the logo colour, dark enough for white text
                           #   no logo   = #0056D2
BANNER_TEXT_COLOR="auto"   # banner title / brand name / OK button text. auto = white, or near-black if
                           # the banner is too light for white to read.
ACCENT_COLOR="auto"        # file count, progress divider, filename chip, SF Symbol logo tint.
                           # auto = the banner colour, lightened (dark mode) or darkened (light mode)
                           # until it is readable on the window.
SPINNER_BG_COLOR="auto"    # progress card background. auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # result icon on success. auto = Apple green (#34C759 light / #30D158 dark)
FAIL_COLOR="auto"          # result icon on failure. auto = Apple red   (#FF3B30 light / #FF453A dark)

# TEXT ----------------------------------------------------------------------
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
[[ -n "$3" ]] && BRAND_ICON="$3"
[[ -n "$4" ]] && bannerColor="$4"
[[ -n "$5" ]] && BRAND_NAME="$5"
[[ -n "$6" ]] && APPEARANCE="$6"
APPEARANCE="${APPEARANCE:l}"; [[ "$APPEARANCE" == (light|dark) ]] || APPEARANCE="auto"

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

# --- Helpers ----------------------------------------------------------------
logMe() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}" | /usr/bin/tee -a "$logFile" 2>/dev/null || print -r -- "$2"; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }   # escape \ " newline for JS

# --- Colour helpers (pure zsh math; results come back in $REPLY) ------------
# hex_norm <hex>    -> RRGGBB (uppercase), or "" if it isn't a valid #RRGGBB / #RGB
hex_norm() {
  local h="${1#\#}"
  [[ "$h" == [[:xdigit:]](#c3) ]] && h="${h[1]}${h[1]}${h[2]}${h[2]}${h[3]}${h[3]}"
  [[ "$h" == [[:xdigit:]](#c6) ]] && REPLY="${h:u}" || REPLY=""
}
# lum <RRGGBB>      -> WCAG relative luminance 0..1
lum() {
  local i; local -F c L=0; local -a w=(0.2126 0.7152 0.0722)
  for i in 1 2 3; do
    c=$(( 16#${1[2*i-1,2*i]} / 255.0 ))
    if (( c <= 0.04045 )); then c=$(( c / 12.92 )); else c=$(( ((c + 0.055) / 1.055) ** 2.4 )); fi
    (( L += w[i] * c ))
  done
  REPLY=$L
}
# contrast <A> <B>  -> WCAG contrast ratio 1..21
contrast() {
  local -F a b t; lum $1; a=$REPLY; lum $2; b=$REPLY
  (( a < b )) && { t=$a; a=$b; b=$t; }
  REPLY=$(( (a + 0.05) / (b + 0.05) ))
}
# mix <A> <B> <t>   -> A blended toward B by t (0..1)
mix() {
  local i out=""; local -i x
  for i in 1 2 3; do
    x=$(( 16#${1[2*i-1,2*i]} * (1 - $3) + 16#${2[2*i-1,2*i]} * $3 + 0.5 ))
    out+=${(l:2::0:)$(( [##16] x ))}
  done
  REPLY=$out
}
# readable <C> <BG> <min> -> C nudged toward white (dark BG) or black (light BG) until contrast >= min
readable() {
  local c=$1 toward; local -F t=0
  lum $2; (( REPLY < 0.4 )) && toward=FFFFFF || toward=000000
  while :; do
    contrast $c $2; (( REPLY >= $3 || t >= 1 )) && break
    t=$(( t + 0.05 )); mix $1 $toward $t; c=$REPLY
  done
  REPLY=$c
}
# rgbjs <RRGGBB>    -> "r,g,b" (0..1) for colorWithSRGBRedGreenBlueAlpha
rgbjs() { print -r -- "$((16#${1[1,2]}))/255,$((16#${1[3,4]}))/255,$((16#${1[5,6]}))/255"; }

# icon_color -> REPLY = the logo's main colour (most common saturated hue), or "" if it has none.
# Draws the logo at 32x32 and buckets the pixels by hue; greys, near-black and transparent pixels
# are ignored so a black/white logo on a coloured tile picks the tile colour.
icon_color() {
  REPLY=""
  [[ -n "$BRAND_ICON_FILE" ]] || return 0
  local js="$SCRATCH/iconcolor.jxa" out
  { print -r -- "ObjC.import('Cocoa');"; brand_jxa; /bin/cat <<'EOF'
(function(){ var img=brandImg(); if(!img) return "";
 // Read the image's own pixels (no redraw, so colours aren't shifted) on a ~32x32 grid.
 var rep=$.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation); if(!isOk(rep)) return "";
 var PW=rep.pixelsWide, PH=rep.pixelsHigh, N=32, sx=Math.max(1,PW/N), sy=Math.max(1,PH/N);
 var B=[], i; for(i=0;i<18;i++) B.push({w:0,r:0,g:0,b:0});
 for(var yy=0;yy<N;yy++) for(var xx=0;xx<N;xx++){ var x=Math.floor(xx*sx), y=Math.floor(yy*sy); if(x>=PW||y>=PH) continue;
  var c=rep.colorAtXY(x,y); if(!isOk(c)) continue; c=c.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace); if(!isOk(c)) continue;
  var r=c.redComponent, g=c.greenComponent, b=c.blueComponent, a=c.alphaComponent;
  var mx=Math.max(r,g,b), mn=Math.min(r,g,b), v=mx, sat=mx? (mx-mn)/mx : 0;
  if(a<0.6 || sat<0.3 || v<0.2) continue;
  var h; if(mx==r) h=((g-b)/(mx-mn)+6)%6; else if(mx==g) h=(b-r)/(mx-mn)+2; else h=(r-g)/(mx-mn)+4;
  var k=Math.floor(h*3)%18, wt=sat*v; B[k].w+=wt;
  // Count exact colours inside the bucket so we return a real pixel of the logo, not a blend.
  var key=Math.round(r*255)+","+Math.round(g*255)+","+Math.round(b*255);
  var e=B[k][key]||(B[k][key]={n:0,x:x,y:y}); e.n++; }
 var best=B[0]; for(i=1;i<18;i++) if(B[i].w>best.w) best=B[i];
 if(best.w<1) return "";
 var top=null, tk=""; for(var kk in best){ if(kk=="w"||kk=="r"||kk=="g"||kk=="b") continue; if(!top||best[kk].n>top.n){ top=best[kk]; tk=kk; } }
 var p=tk.split(",").map(Number);
 function hx(n){ return (n<16?"0":"")+n.toString(16); }
 return hx(p[0])+hx(p[1])+hx(p[2])+" "+top.x+" "+top.y;   // "RRGGBB x y" (x,y = pixel in the image rep)
})();
EOF
  } > "$js"
  /bin/chmod 644 "$js"
  out=$(run_as_user /usr/bin/osascript -l JavaScript "$js" 2>/dev/null)
  ICON_PX="${out#* }"; [[ "$ICON_PX" == <->" "<-> ]] || ICON_PX=""
  hex_norm "${out%% *}"
}

# build_palette — turns the colour settings into AppKit-ready values for light AND dark mode.
# The windows pick one set at open time (APPEARANCE=auto follows the user's current setting).
build_palette() {
  local banner btxt accent card c
  # Banner: explicit hex; else the logo's exact main colour ("auto"), or that colour deepened until
  # white text reads well ("auto-dark"); else (no logo / no colour in it) the default blue.
  # For "auto", BANNER_PX also tells the window which logo pixel to copy, so the banner is drawn
  # from the logo's own colour space and matches it 1:1 on screen.
  BANNER_PX=""
  hex_norm "$bannerColor"; banner=$REPLY
  if [[ -z "$banner" ]]; then
    icon_color
    if [[ -n "$REPLY" ]]; then
      banner=$REPLY
      if [[ "${bannerColor:l}" == auto-dark ]]; then readable "$banner" FFFFFF 4.5; banner=$REPLY
      else BANNER_PX="$ICON_PX"; fi
      logMe INFO "Banner colour from logo: #$banner"
    else banner=0056D2; fi
  fi
  # Banner text: explicit, else white when it reads (>= 3:1, large bold text), else near-black.
  hex_norm "$BANNER_TEXT_COLOR"; btxt=$REPLY
  if [[ -z "$btxt" ]]; then contrast FFFFFF $banner; (( REPLY >= 3 )) && btxt=FFFFFF || btxt=1D1D1F; fi
  PAL_BANNER=$(rgbjs $banner); PAL_BTXT=$(rgbjs $btxt)

  local m
  for m in L D; do
    hex_norm "$SPINNER_BG_COLOR"; card=$REPLY
    [[ -z "$card" ]] && { [[ $m == L ]] && card=F5F5F7 || card=1C1C1E; }
    hex_norm "$ACCENT_COLOR"; accent=$REPLY
    [[ -z "$accent" ]] && { readable $banner $card 4.5; accent=$REPLY; }
    typeset -g PAL_CARD_$m=$(rgbjs $card) PAL_ACCENT_$m=$(rgbjs $accent)
    # Card text follows the card's own lightness (so a custom card colour still reads).
    lum $card
    if (( REPLY < 0.4 )); then typeset -g PAL_TITLE_$m=$(rgbjs FFFFFF) PAL_SUB_$m=$(rgbjs D1D1D6)
    else typeset -g PAL_TITLE_$m=$(rgbjs 1D1D1F) PAL_SUB_$m=$(rgbjs 3A3A3C); fi
    hex_norm "$SUCCESS_COLOR"; c=$REPLY; [[ -z "$c" ]] && { [[ $m == L ]] && c=34C759 || c=30D158; }
    typeset -g PAL_OK_$m=$(rgbjs $c)
    hex_norm "$FAIL_COLOR";    c=$REPLY; [[ -z "$c" ]] && { [[ $m == L ]] && c=FF3B30 || c=FF453A; }
    typeset -g PAL_FAIL_$m=$(rgbjs $c)
  done
}

# palette_jxa — JS prelude for both windows: decides light/dark and defines the colour objects.
palette_jxa() {
  print -r -- "var MODE=\"$APPEARANCE\";"
  /bin/cat <<'EOF'
function C(rgb,a){ return $.NSColor.colorWithSRGBRedGreenBlueAlpha(rgb[0],rgb[1],rgb[2],a==null?1:a); }
var DARK = MODE=="dark" ? true : MODE=="light" ? false : (function(){
 var n=$.NSApplication.sharedApplication.effectiveAppearance.bestMatchFromAppearancesWithNames($(["NSAppearanceNameAqua","NSAppearanceNameDarkAqua"]));
 return ObjC.unwrap(n)=="NSAppearanceNameDarkAqua"; })();
var APPEAR=$.NSAppearance.appearanceNamed(DARK?"NSAppearanceNameDarkAqua":"NSAppearanceNameAqua");
EOF
  print -r -- "var P_L={card:[$PAL_CARD_L],accent:[$PAL_ACCENT_L],title:[$PAL_TITLE_L],sub:[$PAL_SUB_L],ok:[$PAL_OK_L],fail:[$PAL_FAIL_L]};"
  print -r -- "var P_D={card:[$PAL_CARD_D],accent:[$PAL_ACCENT_D],title:[$PAL_TITLE_D],sub:[$PAL_SUB_D],ok:[$PAL_OK_D],fail:[$PAL_FAIL_D]};"
  print -r -- "var P=DARK?P_D:P_L, BANNER=C([$PAL_BANNER]), BTXT=C([$PAL_BTXT]);"
  print -r -- "var CARD=C(P.card), ACCENT=C(P.accent), TITLE=C(P.title), SUB=C(P.sub), OKC=C(P.ok), FAILC=C(P.fail);"
}

# --- Branding: resolve BRAND_ICON into something the windows can load ----------------------
# Sets BRAND_ICON_FILE (an image file, or an .app/folder when BRAND_ICON_APP=true) or BRAND_ICON_SF
# (an SF Symbol name). Files are copied/decoded into $SCRATCH and made world-readable so the window,
# which runs in the user's session, can read them even when this script runs as root.
BRAND_ICON_FILE=""; BRAND_ICON_SF=""; BRAND_ICON_APP=false
# self_service_icon -> prints the best Self Service logo source for this Mac, or nothing:
#   1. the org's branding image that Self Service caches for the logged-in user (set in Jamf Pro under
#      Self Service > Branding) — this is the custom logo, not the app icon
#   2. the Self Service app's own icon, using the app path Jamf has on record (handles renamed apps,
#      e.g. "Acme Self Service.app"), then the standard Self Service / Self Service+ locations
self_service_icon() {
  local p
  for p in \
    "$USER_HOME/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png" \
    "$USER_HOME/Library/Application Support/com.jamf.selfserviceplus/Documents/Images/brandingimage.png"; do
    [[ -s "$p" ]] && { print -r -- "$p"; return 0; }
  done
  p=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf self_service_app_path 2>/dev/null)
  for p in "$p" "/Applications/Self Service.app" "/Applications/Self Service+.app"; do
    [[ -n "$p" && -d "$p" ]] && { print -r -- "$p"; return 0; }
  done
}

resolve_brand_icon() {
  local src="$BRAND_ICON" out="$SCRATCH/brand_icon"
  [[ -z "$src" ]] && return 0
  if [[ "${src:l}" == (selfservice|self service|ss) ]]; then
    src=$(self_service_icon)
    if [[ -z "$src" ]]; then logMe WARN "BRAND_ICON=selfservice, but no Self Service branding image or app was found — continuing without a logo."; return 0; fi
    logMe INFO "Brand icon from Self Service: $src"
  fi
  if [[ "$src" == sf:* ]]; then
    BRAND_ICON_SF="${src#sf:}"; return 0
  elif [[ "$src" == /* || "$src" == "~"* ]]; then
    src="${src/#\~/$USER_HOME}"
    if [[ -d "$src" ]]; then BRAND_ICON_FILE="$src"; BRAND_ICON_APP=true; return 0; fi
    [[ -f "$src" ]] || { logMe WARN "Brand icon not found: $src"; return 0; }
    /bin/cp "$src" "$out" 2>/dev/null
  elif [[ "$src" == http(s|)://* ]]; then
    /usr/bin/curl -fsSL --max-time 15 -o "$out" "$src" 2>/dev/null \
      || { logMe WARN "Brand icon download failed: $src"; return 0; }
  else
    # base64 (optionally with a data: URI prefix). Strip the prefix and any whitespace/newlines.
    src="${src#data:*;base64,}"; src="${src//[[:space:]]/}"
    print -rn -- "$src" | /usr/bin/base64 -D > "$out" 2>/dev/null
  fi
  # Only keep it if macOS can actually read it as an image.
  if [[ -s "$out" ]] && /usr/bin/sips -g pixelWidth "$out" 2>/dev/null | /usr/bin/grep -qE 'pixelWidth: [0-9]+'; then
    /bin/chmod 644 "$out"; BRAND_ICON_FILE="$out"
  else
    logMe WARN "Brand icon is not a readable image — continuing without a logo."
    /bin/rm -f "$out"
  fi
}

# JXA snippet shared by both windows: brandImg() returns an NSImage for the logo, or null.
brand_jxa() {
  print -r -- "var BI_P=\"$(as_esc "$BRAND_ICON_FILE")\", BI_S=\"$(as_esc "$BRAND_ICON_SF")\", BI_APP=${BRAND_ICON_APP};"
  /bin/cat <<'EOF'
function isOk(o){ return !!o && !(typeof o.isNil==='function' && o.isNil()); }
function brandImg(){
 var i=null;
 if(BI_S) i=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(BI_S,"");
 else if(BI_P && BI_APP) i=$.NSWorkspace.sharedWorkspace.iconForFile(BI_P);
 else if(BI_P) i=$.NSImage.alloc.initWithContentsOfFile(BI_P);
 return isOk(i)?i:null; }
EOF
}

# ui_common_jxa — JS shared by both windows (needs brand_jxa + palette_jxa + "var logo" first):
#   brandFill(rect, pill) : a view in the banner colour (logo-pixel fill when bannerColor=auto)
#   rounded(size, weight) : SF Pro Rounded font
ui_common_jxa() {
  print -r -- "var BANNER_PX=\"$BANNER_PX\";"
  /bin/cat <<'EOF'
// bannerColor=auto: paint the banner (and OK pill) with one pixel of the logo stretched to fill it.
// It goes through the exact same image-drawing/colour-management path as the logo itself, so the two
// match 1:1 on screen (a solid colour fill of the same hex is converted differently and can be off).
var BPX=BANNER_PX.split(" ").map(Number), LOGOSRC=null;
if(logo && BPX.length==2){ try{ var lr=$.NSBitmapImageRep.imageRepWithData(logo.TIFFRepresentation), PW=lr.pixelsWide, PH=lr.pixelsHigh, ls=logo.size;
 LOGOSRC=$.NSMakeRect((BPX[0]+0.25)/PW*ls.width, ls.height-(BPX[1]+0.75)/PH*ls.height, 0.5/PW*ls.width, 0.5/PH*ls.height); }catch(e){ LOGOSRC=null; } }
if(LOGOSRC && !$.LogoFill){ ObjC.registerSubclass({name:'LogoFill',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
 var b=this.bounds; if(ObjC.unwrap(this.identifier)=="pill") $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(b,b.size.height/2,b.size.height/2).addClip;
 logo.drawInRectFromRectOperationFraction(b,LOGOSRC,1,1); }}}}); }
// brandFill(rect, pill) -> a view filled with the banner colour (logo-pixel fill when available)
function brandFill(rect,pill){
 if(LOGOSRC){ var v=$.LogoFill.alloc.initWithFrame(rect); if(pill) v.identifier="pill"; return v; }
 var bx=$.NSBox.alloc.initWithFrame(rect); bx.boxType=4; bx.borderWidth=0; bx.titlePosition=0; bx.fillColor=BANNER;
 if(pill) bx.cornerRadius=rect.size.height/2; return bx; }
// bannerShade(W, H, BH) -> adds a soft shadow just under the banner so the header sits on the window
// instead of ending in a hard edge (stronger in dark mode, barely there in light mode).
function bannerShade(cv,W,H,BH){
 if(!$.ShadeView){ ObjC.registerSubclass({name:'ShadeView',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
  $.NSGradient.alloc.initWithStartingColorEndingColor(C([0,0,0],DARK?0.32:0.07),C([0,0,0],0)).drawInRectAngle(this.bounds,-90); }}}}); }
 cv.addSubview($.ShadeView.alloc.initWithFrame($.NSMakeRect(0,H-BH-12,W,12))); }
// Rounded system font (SF Pro Rounded), falling back to the regular system font.
function rounded(sz,wt){ var f=$.NSFont.systemFontOfSizeWeight(sz,wt);
 try{ var d=f.fontDescriptor.fontDescriptorWithDesign($.NSFontDescriptorSystemDesignRounded); var r=isOk(d)?$.NSFont.fontWithDescriptorSize(d,sz):null; if(isOk(r)) return r; }catch(e){}
 return f; }
EOF
}

# Update the live progress window: line 1 = current folder/step, line 2 = count, line 3 = done/total. The spinner window
# re-reads this file on a timer and updates its labels. World-readable so the user-session window
# can read it even when this script runs as root.
spin_status() {   # spin_status <folder/step> <count text> [done/total]
  print -rl -- "$1" "$2" "$3" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}

# human_size <bytes> -> "7.6 MB" (Finder-style: base 1000, one decimal; whole bytes below 1 KB)
human_size() {
  local -F n=${1:-0}; local -a u=(bytes KB MB GB TB); local -i i=1
  while (( n >= 1000 && i < 5 )); do (( n /= 1000.0, i++ )); done
  (( i == 1 )) && { print -r -- "${1:-0} bytes"; return; }
  printf "%.1f %s\n" $n $u[i]
}

# local_ip_summary -> "192.168.1.20 (en0, Wi-Fi)" for the interface carrying the default route, plus
# any other active IPv4 addresses (e.g. a VPN tunnel) as "; also 10.8.0.2 (utun4)".
local_ip_summary() {
  local dif dip hw out="" i a
  dif=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')
  [[ -n "$dif" ]] && dip=$(/usr/sbin/ipconfig getifaddr "$dif" 2>/dev/null)
  if [[ -n "$dip" ]]; then
    hw=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk -v d="$dif" '/^Hardware Port:/{p=substr($0,16)} $2==d{print p; exit}')
    out="$dip ($dif${hw:+, $hw})"
  fi
  while read -r i a; do
    [[ "$i" == lo0 || "$a" == "$dip" || "$a" == 169.254.* ]] && continue
    out+="${out:+; also }$a ($i)"
  done < <(/sbin/ifconfig 2>/dev/null | /usr/bin/awk '/^[a-z]/{sub(":","",$1); i=$1} /inet /{print i, $2}')
  print -r -- "${out:-none (no network)}"
}
# public_ip -> the Mac's internet-facing IPv4 (via VPN if one is routing all traffic), or a note.
public_ip() {
  local u ip
  for u in https://api.ipify.org https://checkip.amazonaws.com; do
    ip=$(/usr/bin/curl -fsS --max-time 5 "$u" 2>/dev/null | /usr/bin/tr -d '[:space:]')
    [[ "$ip" == <->.<->.<->.<-> || "$ip" == *:*:* ]] && { print -r -- "$ip"; return; }
  done
  print -r -- "unavailable (offline or blocked)"
}

# device serial number (built-in tools only)
device_serial() {
  /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
    | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# --- Progress window (sibling of the result window) --------------------------------------------
# Same branded header as the result window (logo, brand name, rounded title), then a colourful arc
# spinner, the folder (as a chip) being scanned, a progress bar and "Step x of y · N files".
# The shell writes $STATUS_FILE (line 1 = folder/step, line 2 = file count, line 3 = "done/total");
# a 0.3s timer re-reads it, and a 30fps timer animates the spinner and eases the bar.
SPIN_SCPT="$SCRATCH/spin.jxa"
show_spinner() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  /bin/cat > "$SPIN_SCPT" <<EOF
ObjC.import('Cocoa');
var STATUS="$(as_esc "$STATUS_FILE")";
function readStatus(){ try{ var s=\$.NSString.stringWithContentsOfFileEncodingError(STATUS,\$.NSUTF8StringEncoding,null); return ObjC.unwrap(s)||""; }catch(e){ return ""; } }
function label(x,y,w,h,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,h));
 t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=(al==null?1:al);
 t.usesSingleLineMode=true;t.cell.lineBreakMode=5;   // 5 = truncate middle (keeps both ends of a path)
 t.textColor=\$.NSColor.labelColor; t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
$(brand_jxa)
$(palette_jxa)
var logo=brandImg(), BNAME="$(as_esc "$BRAND_NAME")";
$(ui_common_jxa)
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
// Layout (bottom-up): step/count row, progress bar, folder, spinner + glow, header.
var W=520, BH=(BNAME?78:66), botPad=22, rowY=botPad, barY=rowY+24, chipH=30, chipY=barY+18, spinCY=chipY+chipH+20+26, H=spinCY+26+22+BH;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.level=3;
[0,1,2].forEach(function(i){ var bt=win.standardWindowButton(i); if(isOk(bt)) bt.hidden=true; });   // no traffic lights
win.appearance=APPEAR;
var cv=win.contentView;
// Header — identical to the result window
cv.addSubview(brandFill(\$.NSMakeRect(0,H-BH,W,BH),false)); bannerShade(cv,W,H,BH);
var LS=(BNAME?50:44), tx=20; if(logo){ tx=LS+32; var lv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect(16,H-BH+(BH-LS)/2,LS,LS));
 lv.setImage(logo); lv.imageScaling=3; if(BI_S) lv.contentTintColor=BTXT; cv.addSubview(lv); }
var TH=30, tY = BNAME ? (H-BH+12) : (H-BH+(BH-TH)/2);
var tl=label(tx,tY,W-2*tx,TH,22,true,1); tl.stringValue="$(as_esc "$SPINNER_TEXT")"; tl.font=rounded(22,\$.NSFontWeightBold); tl.textColor=BTXT; cv.addSubview(tl);
if(BNAME){ var bn=label(tx,tY+TH+1,W-2*tx,16,11,true,1); bn.stringValue=BNAME.toUpperCase(); bn.font=rounded(11,\$.NSFontWeightSemibold); bn.textColor=BTXT; bn.alphaValue=0.72; cv.addSubview(bn); }
// Spinner — a rotating arc with a colour tail: the head is the brand accent, the tail shifts to a
// neighbouring hue and fades out, over a faint track ring. Redrawn every 80ms by the spin timer.
var aC=ACCENT.colorUsingColorSpace(\$.NSColorSpace.sRGBColorSpace), AH=aC.hueComponent, AS=aC.saturationComponent, AB=aC.brightnessComponent;
function hsb(h,sa,br,al){ return \$.NSColor.colorWithHueSaturationBrightnessAlpha(((h%1)+1)%1, Math.min(1,sa), Math.min(1,br), al); }
var SEGS=48, SWEEP=290, spinA=90;
// Colours are pre-blended with the window background (opaque), so overlapping segments can't stack
// into visible seams. Hue sweeps ~80 degrees from the accent at the head to a neighbouring hue in the tail.
var WBG=DARK?C([0.165,0.165,0.17]):C([0.925,0.925,0.93]), SAT=Math.max(AS,0.85);
var ARC=[]; for(var i=0;i<SEGS;i++){ var t=i/(SEGS-1);   // t: 0 = tail end, 1 = head
 var col=hsb(AH+0.22*(1-t), SAT, Math.min(1,Math.max(AB,0.75)*(0.92+0.12*t)), 1);
 ARC.push(WBG.blendedColorWithFractionOfColor(Math.pow(t,1.35)*0.92+0.08, col)); }
var TRACK=ACCENT.colorWithAlphaComponent(DARK?0.16:0.12);
if(!\$.ArcSpin){ ObjC.registerSubclass({name:'ArcSpin',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
 var b=this.bounds, c=\$.NSMakePoint(b.size.width/2,b.size.height/2), R=b.size.width/2-5, LW=5;
 var tr=\$.NSBezierPath.bezierPath; tr.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,R,0,360); tr.lineWidth=LW; TRACK.setStroke; tr.stroke;
 var step=SWEEP/SEGS;
 for(var i=0;i<SEGS;i++){ var st=spinA+SWEEP-i*step, en=st-step*1.15;   // tail (i=0) to head (i=SEGS-1), clockwise
  var pth=\$.NSBezierPath.bezierPath; pth.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,R,st,en,true);
  pth.lineWidth=LW; pth.lineCapStyle=0; ARC[i].setStroke; pth.stroke; }   // drawn tail→head so the head sits on top
 // rounded bright head
 var ha=(spinA)*Math.PI/180, hx=c.x+R*Math.cos(ha), hy=c.y+R*Math.sin(ha);
 var dot=\$.NSBezierPath.bezierPathWithOvalInRect(\$.NSMakeRect(hx-LW/2,hy-LW/2,LW,LW)); ARC[SEGS-1].setFill; dot.fill;
 }}}}); }
var SPS=60, arcView=\$.ArcSpin.alloc.initWithFrame(\$.NSMakeRect((W-SPS)/2,spinCY-SPS/2,SPS,SPS)); cv.addSubview(arcView);
function spinTick(){ spinA=(spinA-12+360)%360; arcView.needsDisplay=true; }   // 12° per 1/30s = one turn per second
// Current folder, shown as a chip like the filename on the result window (monospaced, accent-tinted)
var CX=40, CW=W-80;
var fchip=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(CX,chipY,CW,chipH)); fchip.boxType=4; fchip.titlePosition=0; fchip.cornerRadius=8;
fchip.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.14:0.09); fchip.borderWidth=1; fchip.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.35:0.28); cv.addSubview(fchip);
var fic=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect(CX+12,chipY+(chipH-16)/2,18,16));
fic.image=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("folder",""); fic.imageScaling=3; fic.contentTintColor=ACCENT; cv.addSubview(fic);
var folder=label(CX+36,chipY+(chipH-18)/2,CW-72,18,12,false); folder.textColor=\$.NSColor.labelColor;
folder.font=\$.NSFont.monospacedSystemFontOfSizeWeight(12,\$.NSFontWeightMedium); cv.addSubview(folder);
// Progress bar: a faint accent track with an accent fill that eases toward the real progress
var BX=40, BW=W-80, BHt=6;
var track=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(BX,barY,BW,BHt)); track.boxType=4; track.borderWidth=0; track.titlePosition=0;
track.cornerRadius=BHt/2; track.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.20:0.16); cv.addSubview(track);
var fill=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(BX,barY,BHt,BHt)); fill.boxType=4; fill.borderWidth=0; fill.titlePosition=0;
fill.cornerRadius=BHt/2; fill.fillColor=ACCENT; cv.addSubview(fill);
var barTarget=0, barCur=0;
function setBar(f){ barCur=f; var w=Math.max(BHt, BW*Math.min(1,f)); fill.frame=\$.NSMakeRect(BX,barY,w,BHt); }
// Bottom row: step on the left, running file count on the right
var step=label(BX,rowY,BW/2,16,11.5,false,0); step.font=rounded(11.5,\$.NSFontWeightMedium); step.textColor=SUB; cv.addSubview(step);
var count=label(BX+BW/2,rowY,BW/2,16,11.5,true,2); count.font=rounded(11.5,\$.NSFontWeightSemibold); count.textColor=ACCENT; cv.addSubview(count);
// Chip icon + font follow the content: real paths get a folder icon and monospaced text; named steps
// (preparing, app logs, device information, archive) get their own icon and the normal UI font.
var MONO=\$.NSFont.monospacedSystemFontOfSizeWeight(12,\$.NSFontWeightMedium), UIF=rounded(12.5,\$.NSFontWeightSemibold), lastChip="";
function chipFor(t){ if(t.charAt(0)=="/") return ["folder",MONO];
 var l=t.toLowerCase(); return [ l.indexOf("device")>=0 ? "desktopcomputer" : l.indexOf("archive")>=0 ? "archivebox" :
   l.indexOf("app")>=0 ? "square.grid.2x2" : "gearshape", UIF ]; }
function applyStatus(){ var L=readStatus().split("\n"); folder.setStringValue(L[0]||""); count.setStringValue(L[1]||"");
 if((L[0]||"")!==lastChip){ lastChip=L[0]||""; var c=chipFor(lastChip); fic.image=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(c[0],""); folder.font=c[1]; }
 var m=(L[2]||"").match(/^(\d+)\/(\d+)$/); if(m){ var d=+m[1], t=+m[2]; barTarget=t?d/t:0; step.setStringValue(d<t ? ("Step "+(d+1)+" of "+t) : "Finishing up"); } }
applyStatus(); setBar(barTarget);
if(!\$.SpinTick){ObjC.registerSubclass({name:'SpinTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){ applyStatus(); }},
 'spin:':{types:['void',['id']],implementation:function(s){ spinTick(); if(Math.abs(barTarget-barCur)>0.002) setBar(barCur+(barTarget-barCur)*0.07); }}}});}
var tk=\$.SpinTick.alloc.init;
\$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.3,tk,'tick:',null,true);
\$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(1/30,tk,'spin:',null,true);   // 30 fps animation
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
EOF
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; return 0; }

# --- Result window ----------------------------------------------------------
# show_message <title> <sfSymbol> <ok|fail> <message> [filename] [full path]
#   Branded banner (brand name + rounded title), a glowing status icon, a wrapping message, an
#   optional filename chip that reveals the file in Finder when clicked, and a branded OK button.
#   Window height auto-fits the content.
show_message() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  local t="${1//\"/\\\"}" sym="$2" m="${4//\"/\\\"}" fname="${5//\"/\\\"}" fpath="$(as_esc "$6")" mscpt="$SCRATCH/result.jxa"
  local tint="OKC"; [[ "$3" == fail ]] && tint="FAILC"
  /bin/cat > "$mscpt" <<EOF
ObjC.import('Cocoa');
$(brand_jxa)
$(palette_jxa)
var logo=brandImg(), BNAME="$(as_esc "$BRAND_NAME")";
$(ui_common_jxa)
var FPATH="$fpath";
ObjC.registerSubclass({name:'CLMSG',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'reveal:':{types:['void',['id']],implementation:function(s){   // open Finder with the zip selected
   if(FPATH) \$.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs(\$([\$.NSURL.fileURLWithPath(FPATH)])); }}}});
// A borderless button that shows the pointing-hand cursor, so the filename chip reads as clickable.
ObjC.registerSubclass({name:'LinkBtn',superclass:'NSButton',methods:{'resetCursorRects':{implementation:function(){
 this.addCursorRectCursor(this.bounds,\$.NSCursor.pointingHandCursor); }}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=true;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.CLMSG.alloc.init;
var FNAME="$fname"; var hasFile=FNAME.length>0;
var W=560, BH=(BNAME?78:66), okH=32, iconS=52, haloS=84, msgH=52, chipH=34, g=14, topPad=16, botPad=24;
// Lay out bottom-up so the window height auto-fits.
var okY=botPad;
var chipY = hasFile ? (okY+okH+g) : okY+okH;
var msgY  = (hasFile ? (chipY+chipH+g) : (okY+okH+g));
var iconY = msgY+msgH+g;
var H = iconY+haloS+topPad+BH;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
win.appearance=APPEAR;
var cv=win.contentView;
var banner=brandFill(\$.NSMakeRect(0,H-BH,W,BH),false);
cv.addSubview(banner); bannerShade(cv,W,H,BH);
// Brand logo on the left of the banner (optional); title stays centred, inset so it can't overlap
var LS=(BNAME?50:44), tx=20; if(logo){ tx=LS+32; var lv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect(16,H-BH+(BH-LS)/2,LS,LS));
 lv.setImage(logo); lv.imageScaling=3; if(BI_S) lv.contentTintColor=BTXT; cv.addSubview(lv); }
// Header: small uppercase brand name above a large rounded title (or just the title, centred)
var TH=30, tY = BNAME ? (H-BH+12) : (H-BH+(BH-TH)/2);
var tl=label("$t",tx,tY,W-2*tx,TH,22,true,1); tl.font=rounded(22,\$.NSFontWeightBold); tl.textColor=BTXT; tl.selectable=false; cv.addSubview(tl);
if(BNAME){ var bn=label(BNAME.toUpperCase(),tx,tY+TH+1,W-2*tx,16,11,true,1); bn.font=rounded(11,\$.NSFontWeightSemibold);
 bn.textColor=BTXT; bn.alphaValue=0.72; bn.selectable=false; cv.addSubview(bn); }
// Tinted SF Symbol
var tint=$tint;
var img=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("$sym","");
if(img){
 // Soft radial glow behind the icon: the status colour fading smoothly to nothing. Drawn with a
 // radial NSGradient (5 stops for an ease-out falloff) and placed beneath everything, so where it
 // reaches the banner it simply disappears under it.
 var GA=DARK?0.42:0.30;
 var GLOWG=\$.NSGradient.alloc.initWithColors(\$([GA,GA*0.62,GA*0.30,GA*0.09,0].map(function(a){ return tint.colorWithAlphaComponent(a); })));
 if(!\$.GlowView){ ObjC.registerSubclass({name:'GlowView',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
  var b=this.bounds, c=\$.NSMakePoint(b.size.width/2,b.size.height/2);   // circle that ends fully transparent at its edge
  GLOWG.drawFromCenterRadiusToCenterRadiusOptions(c,0,c,b.size.width/2,0); }}}}); }
 var GS=170, glow=\$.GlowView.alloc.initWithFrame(\$.NSMakeRect((W-GS)/2,iconY+(haloS-GS)/2,GS,GS));
 cv.addSubviewPositionedRelativeTo(glow,-1,null);
 // the icon itself, with a coloured glow
 var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-iconS)/2,iconY+(haloS-iconS)/2,iconS,iconS));
 // Two-colour symbol (white mark on a coloured badge) so the glow can't show through the cut-out.
 try{ var pc=\$.NSImageSymbolConfiguration.configurationWithPaletteColors(\$([\$.NSColor.whiteColor,tint]));
  var pimg=img.imageWithSymbolConfiguration(pc); if(isOk(pimg)) img=pimg; }catch(e){}
 iv.setImage(img); iv.imageScaling=3; iv.contentTintColor=tint;
 var gl=\$.NSShadow.alloc.init; gl.shadowBlurRadius=9; gl.shadowOffset=\$.NSMakeSize(0,-1); gl.shadowColor=tint.colorWithAlphaComponent(DARK?0.7:0.45);
 iv.shadow=gl; cv.addSubview(iv); }
// Message
// Message: first line is the headline (semibold, primary colour), the rest is secondary detail.
var MSG="$m".split("\n"), m1=MSG[0], m2=MSG.slice(1).join("\n");
if(m2){ var l1=label(m1,36,msgY+msgH-22,W-72,20,14,false,1); l1.font=\$.NSFont.systemFontOfSizeWeight(14,\$.NSFontWeightSemibold); cv.addSubview(l1);
 var l2=label(m2,36,msgY,W-72,msgH-26,12.5,false,1); l2.textColor=\$.NSColor.secondaryLabelColor; cv.addSubview(l2); }
else { var l0=label(m1,36,msgY,W-72,msgH,13.5,false,1); l0.font=\$.NSFont.systemFontOfSizeWeight(13.5,\$.NSFontWeightMedium); cv.addSubview(l0); }
// Filename chip — click to show the file in Finder
if(hasFile){
 var chip=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(40,chipY,W-80,chipH));
 chip.boxType=4; chip.cornerRadius=8;
 chip.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.14:0.09);
 chip.borderWidth=1; chip.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.35:0.28); cv.addSubview(chip);
 var fn=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(52,chipY+(chipH-18)/2,W-104,18));
 fn.stringValue=FNAME; fn.bezeled=false; fn.editable=false; fn.selectable=true; fn.drawsBackground=false;
 fn.alignment=1; fn.usesSingleLineMode=true; fn.cell.lineBreakMode=5; fn.textColor=\$.NSColor.labelColor;
 fn.font=\$.NSFont.monospacedSystemFontOfSizeWeight(12,\$.NSFontWeightMedium); cv.addSubview(fn);
 if(FPATH){
  fn.frame=\$.NSMakeRect(52,chipY+(chipH-18)/2,W-104-26,18); fn.selectable=false;
  // folder icon on the right of the chip
  var fi=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect(W-40-12-20,chipY+(chipH-18)/2,20,18));
  fi.image=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("folder",""); fi.imageScaling=3; fi.contentTintColor=ACCENT; cv.addSubview(fi);
  // invisible hand-cursor button over the whole chip
  var lk=\$.LinkBtn.alloc.initWithFrame(\$.NSMakeRect(40,chipY,W-80,chipH)); lk.title=""; lk.bordered=false; lk.transparent=true;
  lk.target=h; lk.action='reveal:'; lk.toolTip="Show in Finder"; cv.addSubview(lk);
 }
}
// Branded OK button: a rounded pill in the banner colour with the banner's text colour, plus an
// invisible button on top that handles the click and the Return key.
var bx=(W-140)/2;
var pill=brandFill(\$.NSMakeRect(bx,okY,140,okH),true); cv.addSubview(pill);
var bl=label("$okButton",bx,okY+(okH-18)/2,140,18,13,true,1); bl.selectable=false; bl.textColor=BTXT; cv.addSubview(bl);
var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(bx,okY,140,okH)); b.title=""; b.bordered=false; b.transparent=true;
b.target=h; b.action='ok:'; b.keyEquivalent=\$('\r'); cv.addSubview(b);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
EOF
  /bin/chmod 644 "$mscpt"
  run_as_user /usr/bin/osascript -l JavaScript "$mscpt" >/dev/null 2>&1
}

# --- System details (used for _DEVICE_INFO.txt and the report files) ------------------------
kv() { print -r -- "${(r:14:)1}$2"; }     # kv "Label:" "value" -> aligned "Label:        value"

device_health() {
  local d mem boot batt
  d=$(/bin/df -H / 2>/dev/null | /usr/bin/awk 'NR==2{print $4" free of "$2" ("$5" used)"}')
  mem=$(( $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null) / 1073741824 ))
  boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/sed 's/^.*} //')
  batt=$(/usr/sbin/system_profiler SPPowerDataType 2>/dev/null | /usr/bin/awk -F': ' '
    /Cycle Count/{c=$2} /^ *Condition/{k=$2} /Maximum Capacity/{m=$2}
    END{ if(c!="") printf "%s cycles, condition %s%s", c, k, (m!=""?", max capacity "m:""); }')
  kv "Disk:"     "${d:-unknown}"
  kv "Memory:"   "${mem} GB"
  kv "Last boot:" "${boot:-unknown}"
  kv "Battery:"  "${batt:-none (desktop Mac)}"
}

device_security() {
  local fv sip gk fw mdm jv
  fv=$(/usr/bin/fdesetup status 2>/dev/null | /usr/bin/head -1)
  sip=$(/usr/bin/csrutil status 2>/dev/null | /usr/bin/sed 's/^System Integrity Protection status: //; s/\.$//')
  gk=$(/usr/sbin/spctl --status 2>/dev/null)
  fw=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | /usr/bin/sed 's/ *(State = [0-9])//; s/\.$//')
  mdm=$(/usr/bin/profiles status -type enrollment 2>/dev/null | /usr/bin/paste -sd ';' - | /usr/bin/sed 's/;/; /g')
  jv=$( { /usr/local/bin/jamf -version || /usr/local/jamf/bin/jamf -version; } 2>/dev/null | /usr/bin/sed 's/^version=//' | /usr/bin/head -1)
  kv "FileVault:"  "${fv:-unknown}"
  kv "SIP:"        "${sip:-unknown}"
  kv "Gatekeeper:" "${gk:-unknown}"
  kv "Firewall:"   "${fw:-unknown}"
  kv "MDM:"        "${mdm:-unknown}"
  kv "Jamf:"       "${jv:-not installed}"
}

device_network() {
  local wif ssid sig dns prx pac
  wif=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '/^Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
  if [[ -n "$wif" ]]; then
    ssid=$(/usr/sbin/ipconfig getsummary "$wif" 2>/dev/null | /usr/bin/awk -F' SSID : ' '/ SSID : /{print $2; exit}')
    sig=$(/usr/sbin/system_profiler SPAirPortDataType 2>/dev/null | /usr/bin/awk -F': ' '/Current Network Information/{f=1} f&&/Signal \/ Noise/{print $2; exit}')
  fi
  dns=$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/awk '/nameserver\[[0-9]+\]/{print $3}' | /usr/bin/sort -u | /usr/bin/paste -sd ',' - | /usr/bin/sed 's/,/, /g')
  prx=$(/usr/sbin/scutil --proxy 2>/dev/null | /usr/bin/awk '/HTTPEnable : 1/{h=1} /HTTPProxy :/{hp=$3} /HTTPPort :/{po=$3}
        /HTTPSEnable : 1/{s=1} /HTTPSProxy :/{sp=$3} /HTTPSPort :/{spo=$3} /ProxyAutoConfigEnable : 1/{a=1} /ProxyAutoConfigURLString :/{u=$3}
        END{o=""; if(h) o=o"HTTP "hp":"po" "; if(s) o=o"HTTPS "sp":"spo" "; if(a) o=o"PAC "u; print o}')
  if [[ -z "$wif" ]]; then kv "Wi-Fi:" "no Wi-Fi interface"
  elif [[ -n "$ssid" ]]; then kv "Wi-Fi:" "$ssid${sig:+  (signal / noise: $sig)}"
  else kv "Wi-Fi:" "not connected${sig:+ (signal / noise: $sig)}"; fi
  kv "DNS:"   "${dns:-none}"
  kv "Proxy:" "${prx:-none}"
}

# JXA helper: run a small JS snippet with argv, print its result (used to format plists / JSON).
jxa() { local js="$1"; shift; /usr/bin/osascript -l JavaScript -e "$js" "$@" 2>/dev/null; }

write_reports() {   # write_reports <staging dir>
  local out="$1" tmp="$SCRATCH/apps.json" d p lbl prog
  # Install history (every app / macOS install with its date), newest first
  if [[ -r /Library/Receipts/InstallHistory.plist ]]; then
    { print -r -- "Install history — newest first (from /Library/Receipts/InstallHistory.plist)"; print -r -- ""
      jxa 'ObjC.import("Foundation"); function run(a){ var x=ObjC.deepUnwrap($.NSArray.arrayWithContentsOfFile(a[0]))||[];
        x.sort(function(p,q){ return (q.date||0)-(p.date||0); });
        function pad(n){ return (n<10?"0":"")+n; }
        return x.map(function(i){ var d=i.date?new Date(i.date):null;
          var ds=d? d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate())+" "+pad(d.getHours())+":"+pad(d.getMinutes()) : "????-??-?? ??:??";
          return ds+"  "+(i.displayName||"?")+(i.displayVersion?" "+i.displayVersion:"")+"   ["+(i.processName||"")+"]"; }).join("\n"); }' \
        /Library/Receipts/InstallHistory.plist
    } > "$out/_INSTALL_HISTORY.txt" 2>/dev/null
  fi
  # Installed applications: name, version, where it came from, path
  /usr/sbin/system_profiler SPApplicationsDataType -json -detailLevel mini > "$tmp" 2>/dev/null
  if [[ -s "$tmp" ]]; then
    { print -r -- "Installed applications (built-in /System apps omitted) — name, version, source, path"; print -r -- ""
      jxa 'ObjC.import("Foundation"); function run(a){ var t=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(a[0],4,null));
        var x=(JSON.parse(t).SPApplicationsDataType)||[]; x.sort(function(p,q){ return (p._name||"").toLowerCase()<(q._name||"").toLowerCase()?-1:1; });
        function col(s,n){ s=String(s||""); return s.length>=n? s.slice(0,n-1)+" " : s+Array(n-s.length+1).join(" "); }
        var SRC={identified_developer:"Developer ID", mac_app_store:"App Store", apple:"Apple", unknown:"Unknown"};
        x=x.filter(function(i){ var q=i.path||""; return q.indexOf("/System/")!==0 && q.indexOf("/Library/Apple/")!==0; });   // skip built-in macOS helpers
        return x.map(function(i){ return col(i._name,38)+col(i.version,18)+col(SRC[i.obtained_from]||i.obtained_from,15)+(i.path||""); }).join("\n"); }' "$tmp"
    } > "$out/_INSTALLED_APPS.txt" 2>/dev/null
  fi
  # Background items: launch daemons / agents (label -> program), system extensions, login items
  { print -r -- "Background items"; print -r -- ""
    for d in /Library/LaunchDaemons /Library/LaunchAgents "$USER_HOME/Library/LaunchAgents"; do
      print -r -- "== $d"
      for p in "$d"/*.plist; do
        lbl=$(/usr/bin/plutil -extract Label raw -o - "$p" 2>/dev/null)
        prog=$(/usr/bin/plutil -extract Program raw -o - "$p" 2>/dev/null || /usr/bin/plutil -extract ProgramArguments.0 raw -o - "$p" 2>/dev/null)
        print -r -- "  ${lbl:-${p:t}}${prog:+  ->  $prog}"
      done
      print -r -- ""
    done
    print -r -- "== System extensions"; /usr/bin/systemextensionsctl list 2>/dev/null | /usr/bin/sed 's/^/  /'; print -r -- ""
    if (( amRoot )); then
      print -r -- "== Login & background items (sfltool dumpbtm)"; /usr/bin/sfltool dumpbtm 2>/dev/null | /usr/bin/sed 's/^/  /'
    else
      print -r -- "== Login & background items: run as root (via Jamf) to include sfltool dumpbtm"
    fi
  } > "$out/_BACKGROUND_ITEMS.txt" 2>/dev/null
  # Configuration profiles (full detail needs root)
  { print -r -- "Configuration profiles"; print -r -- ""
    /usr/bin/profiles status -type enrollment 2>/dev/null; print -r -- ""
    if (( amRoot )); then /usr/bin/profiles show -type configuration 2>/dev/null
    else /usr/bin/profiles list 2>/dev/null; print -r -- ""; print -r -- "(run as root via Jamf for full computer-level profile details)"; fi
  } > "$out/_PROFILES.txt" 2>/dev/null
}

# app_log_files -> every non-empty file in sandboxed-app log folders (Containers + Group Containers).
# One find over all the Logs folders at once (spawning a find per container took ~8s with ~500 apps).
app_log_files() {
  local -a d=( "$USER_HOME"/Library/Containers/*/Data/Library/Logs(N/) ) g
  g=( "${(@f)$(/usr/bin/find "$USER_HOME/Library/Group Containers" -maxdepth 4 -type d -iname logs 2>/dev/null)}" ); g=( ${g:#} )
  (( ${#d} + ${#g} )) && /usr/bin/find "${d[@]}" "${g[@]}" -type f -size +0 2>/dev/null
}

# --- Collection -------------------------------------------------------------
# Copies matching files from every source into the staging tree, preserving their full path so
# IT can see where each came from. Sets COPIED (file count) and SKIPPED_BIG.
typeset -gi COPIED=0 SKIPPED_BIG=0
typeset -ga COLLECTED_PATHS=()   # original full path of every file we grabbed (for the manifest)
collect_logs() {
  local src f dest d maxbytes=0 szk
  local -i si=0
  (( MAX_FILE_MB > 0 )) && maxbytes=$(( MAX_FILE_MB * 1024 * 1024 ))

  # copy_one <file> <status label> — size cap, mirror the full path under staging, count it
  copy_one() {
    local f="$1" szk dest
    [[ -f "$1" ]] || return 0
    if (( maxbytes > 0 )); then
      szk=$(/usr/bin/stat -f%z "$f" 2>/dev/null)
      if [[ -n "$szk" ]] && (( szk > maxbytes )); then logMe INFO "Skipping (>${MAX_FILE_MB}MB): $f"; (( SKIPPED_BIG++ )); return 0; fi
    fi
    dest="$STAGING/${f#/}"            # mirror the absolute path under staging (drop leading /)
    /bin/mkdir -p "${dest:h}" 2>/dev/null
    if /bin/cp -p "$f" "$dest" 2>/dev/null; then
      (( COPIED++ )); COLLECTED_PATHS+=("$f")
      (( COPIED % 25 == 0 )) && spin_status "$2" "$COPIED files collected" "$(( si - 1 ))/$TOTAL_STEPS"   # refresh the count
    fi
  }

  # Build the find name-pattern list: *.log always; rotated and crash reports optionally.
  local -a findargs=( -iname '*.log' )
  [[ "$INCLUDE_ROTATED" == true ]] && findargs+=( -o -iname '*.log.*' )
  if [[ "$INCLUDE_CRASH_REPORTS" == true ]]; then
    findargs+=( -o -iname '*.ips' -o -iname '*.crash' -o -iname '*.panic' -o -iname '*.diag' -o -iname '*.spin' )
  fi

  # Background jobs start first and run while the log folders below are copied:
  #   A) sandboxed app logs      B) device details (health/security/network) + report files
  # Each writes its results to $SCRATCH (file list, counts); they're merged in once both finish.
  local BGA="$SCRATCH/bg_applogs" BGB="$SCRATCH/bg_devinfo" pidA="" pidB=""
  if [[ "$INCLUDE_APP_LOGS" == true ]]; then
    (
      COPIED=0; SKIPPED_BIG=0; COLLECTED_PATHS=()
      spin_status() { :; }                 # only the foreground job updates the progress window
      while IFS= read -r f; do copy_one "$f" ""; (( COPIED % 10 == 0 )) && print -r -- $COPIED > "$BGA.count"; done < <(app_log_files)
      print -r -- $COPIED > "$BGA.count"; print -r -- $SKIPPED_BIG > "$BGA.skipped"
      print -rl -- "${COLLECTED_PATHS[@]}" > "$BGA.list"
    ) &
    pidA=$!
  fi
  (
    {
      print -r -- "== Health";               device_health;   print -r -- ""
      print -r -- "== Security & management"; device_security; print -r -- ""
      print -r -- "== Network"
      kv "Local IP:" "$(local_ip_summary)"
      [[ "$LOOKUP_PUBLIC_IP" == true ]] && kv "Public IP:" "$(public_ip)"
      device_network; print -r -- ""
    } > "$BGB.txt" 2>/dev/null
    [[ "$INCLUDE_REPORTS" == true ]] && write_reports "$STAGING"
  ) &
  pidB=$!
  bgcount() { local n=0; [[ -r "$BGA.count" ]] && n=$(<"$BGA.count"); print -r -- $(( COPIED + ${n:-0} )); }

  # 1) the log folders (foreground)
  for src in "${LOG_SOURCES[@]}"; do
    (( si++ ))
    [[ -d "$src" ]] || { logMe INFO "Source not found, skipping: $src"; continue; }
    logMe INFO "Scanning: $src"
    spin_status "$src" "$(bgcount) files collected" "$(( si - 1 ))/$TOTAL_STEPS"
    while IFS= read -r f; do copy_one "$f" "$src"; done < <(/usr/bin/find "$src" -type f \( "${findargs[@]}" \) 2>/dev/null)
  done

  # 2) wait for the background jobs (usually already done), keeping the count live meanwhile
  (( si++ ))
  logMe INFO "Waiting for app logs + device information"
  while { [[ -n "$pidA" ]] && kill -0 $pidA 2>/dev/null; } || kill -0 $pidB 2>/dev/null; do
    spin_status "Gathering device information…" "$(bgcount) files collected" "$(( si - 1 ))/$TOTAL_STEPS"; sleep 0.3
  done
  wait $pidA $pidB 2>/dev/null
  spin_status "Gathering device information…" "$(bgcount) files collected" "$(( si - 1 ))/$TOTAL_STEPS"
  # merge app-log results
  local -a appfiles=()
  if [[ -n "$pidA" ]]; then
    [[ -s "$BGA.list" ]] && appfiles=( "${(@f)$(<"$BGA.list")}" ) && appfiles=( ${appfiles:#} )
    COLLECTED_PATHS+=( "${appfiles[@]}" ); (( COPIED += ${#appfiles} ))
    [[ -r "$BGA.skipped" ]] && (( SKIPPED_BIG += $(<"$BGA.skipped") ))
    logMe INFO "App log files collected: ${#appfiles}"
  fi
  [[ "$INCLUDE_REPORTS" == true && -r /Library/Receipts/InstallHistory.plist ]] && copy_one /Library/Receipts/InstallHistory.plist "Gathering device information…"

  # A device summary at the root of the bundle so IT can identify the machine at a glance.
  {
    print -r -- "== Device"
    kv "Collected:"  "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
    kv "User:"       "$targetUser"
    kv "Computer:"   "$(/usr/sbin/scutil --get ComputerName 2>/dev/null)"
    kv "Serial:"     "$(device_serial)"
    kv "Model:"      "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    kv "macOS:"      "$(/usr/bin/sw_vers -productName) $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    kv "Uptime:"     "$(/usr/bin/uptime | /usr/bin/sed 's/^ *//')"
    print -r -- ""
    [[ -r "$BGB.txt" ]] && /bin/cat "$BGB.txt"      # Health / Security & management / Network (built in the background)
    print -r -- "== Sources scanned"
    for src in "${LOG_SOURCES[@]}"; do print -r -- "  - $src"; done
    [[ "$INCLUDE_APP_LOGS" == true ]] && print -r -- "  - sandboxed app logs (~/Library/Containers, ~/Library/Group Containers): ${#appfiles} file(s)"
    [[ "$INCLUDE_REPORTS" == true ]] && print -r -- "  - reports: _INSTALL_HISTORY.txt, _INSTALLED_APPS.txt, _BACKGROUND_ITEMS.txt, _PROFILES.txt"
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
STAMP="$(/bin/date "+${STAMP_FORMAT:-%Y-%m-%d_%H-%M}")"; STAMP="${STAMP//[:\/]/-}"   # no : or / in file names
ZIP_NAME="${ZIP_NAME_PATTERN//\{USER\}/$targetUser}"
ZIP_NAME="${ZIP_NAME//\{SERIAL\}/$SERIAL}"
ZIP_NAME="${ZIP_NAME//\{STAMP\}/$STAMP}"
DESKTOP="$USER_HOME/Desktop"
[[ -d "$DESKTOP" ]] || DESKTOP="$USER_HOME"
ZIP_PATH="$DESKTOP/$ZIP_NAME"
# Never overwrite an earlier bundle (e.g. two runs in the same minute): add _2, _3, ...
if [[ -e "$ZIP_PATH" ]]; then
  base="${ZIP_NAME%.zip}"; n=2
  while [[ -e "$DESKTOP/${base}_$n.zip" ]]; do (( n++ )); done
  ZIP_NAME="${base}_$n.zip"; ZIP_PATH="$DESKTOP/$ZIP_NAME"
fi

# Name the staging folder after the bundle so the unzipped folder matches the zip name.
STAGING="$SCRATCH/${ZIP_NAME%.zip}"
/bin/mkdir -p "$STAGING"

# Branding (logo + light/dark colour palette) — only needed when windows are shown.
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

# Collect (with a spinner in verbose mode).
TOTAL_STEPS=$(( ${#LOG_SOURCES} + 2 ))   # one step per log folder, device info + app logs (run in parallel), archive
spin_status "Preparing…" "" "0/$TOTAL_STEPS"
show_spinner
collect_logs
logMe INFO "Copied $COPIED file(s); skipped $SKIPPED_BIG over ${MAX_FILE_MB}MB."

if (( COPIED == 0 )); then
  kill_spinner
  logMe ERROR "No log files were collected."
  show_message "$RESULT_FAIL_TITLE" "xmark.octagon.fill" fail "No log files could be collected. If this keeps happening, contact IT." ""
  exit 1
fi

# Zip the staging tree (ditto is built in; produces a standard .zip).
spin_status "Creating archive…" "$COPIED files collected" "$(( TOTAL_STEPS - 1 ))/$TOTAL_STEPS"
logMe INFO "Creating archive: $ZIP_PATH"
if ! /usr/bin/ditto -c -k --norsrc --keepParent "$STAGING" "$ZIP_PATH" 2>/dev/null; then
  kill_spinner
  logMe ERROR "Failed to create archive at $ZIP_PATH"
  show_message "$RESULT_FAIL_TITLE" "xmark.octagon.fill" fail "Could not create the log archive on your Desktop. Contact IT for help." ""
  exit 1
fi

# Make sure the user owns the file on their own Desktop.
if (( amRoot )) && [[ -n "$consoleUID" ]]; then
  /usr/sbin/chown "$targetUser" "$ZIP_PATH" 2>/dev/null
fi

ZIP_SIZE="$(human_size "$(/usr/bin/stat -f%z "$ZIP_PATH" 2>/dev/null)")"
FILES_WORD="files"; (( COPIED == 1 )) && FILES_WORD="file"
kill_spinner
logMe INFO "Done. Archive: $ZIP_PATH ($ZIP_SIZE, $COPIED files)."

# Reveal the file in Finder (verbose mode), then show the result window.
if [[ "$ACTION_MODE" == "verbose" ]]; then
  run_as_user /usr/bin/open -R "$ZIP_PATH" 2>/dev/null
fi
show_message "$RESULT_TITLE" "checkmark.seal.fill" ok "Collected $COPIED log $FILES_WORD ($ZIP_SIZE).\nSaved to your Desktop — attach it to your support ticket." "$ZIP_NAME" "$ZIP_PATH"

exit 0
