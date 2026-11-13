#!/bin/zsh

####################################################################################################
#
# Self Service App Uninstaller
#
# Purpose: Fully uninstalls one or more Mac apps AND the leftover files they scatter around the
#          system — preferences, caches, containers, login items, support files and installer
#          receipts — the way "AppCleaner" does. Dragging an app to the Trash leaves those files
#          behind (often gigabytes); this finds everything tied to each app and removes it in one step.
#
#          Built for Jamf Self Service. The user picks the apps (or you choose them in the policy),
#          sees every file that will be removed with its size, unchecks anything to keep, and
#          confirms. Nothing is removed without the user seeing it first.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works when run as root from Jamf.
#
# What the user sees:
#   1. Pick apps  — a searchable list of installed apps with icons, sizes and when each was last
#                   opened. Check one or more. (Skipped when the policy names the apps.)
#   2. Scanning   — a progress window while each app's files are found (Cancel stops it).
#   3. Review     — every app and its files, grouped, each with a checkbox and size. Uncheck anything
#                   to keep, then Remove. Cancel removes nothing.
#   4. Done       — what was removed and how much space was freed.
#   User files go to the user's Trash (recoverable); system files are deleted.
#
# Safety:
#   - Apple apps (com.apple.*) can never be removed.
#   - The PROTECTED lists below block your management / security tools (Jamf, Self Service, ...).
#     Protected apps are hidden from the picker and refused if named in the policy.
#   - The user always reviews and confirms (except silent mode, which you choose on purpose).
#   - Dry run shows the whole experience but removes nothing.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service, user picks the apps:   leave Parameter 4 blank.
#   Self Service, one specific app:      Parameter 4 = Slack   (several: Slack, zoom.us, Spotify)
#   Test a policy safely:                Parameter 5 = dry      (nothing is removed)
#   Remove an app fleet-wide, no windows: Parameter 4 = the app(s), Parameter 5 = silent
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Apps to remove (name, bundle id or path; comma-separated; blank = user picks)
#   Parameter 5 Label:  Action Mode (verbose, dry, or silent)
#   Parameter 6 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 7 Label:  Banner Color (hex, optional)
#   Parameter 8 Label:  Brand Name (optional)
#   Parameter 9 Label:  Appearance (auto, light, or dark)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Apps          blank = the user picks from a list of installed apps
#                       or one or more apps, comma-separated, each one of:
#                         a name        Slack
#                         a bundle id   com.tinyspeck.slackmacgap
#                         a path        /Applications/Slack.app
#     $5  Action Mode   verbose = windows: pick, review, confirm (default)
#                       dry     = the same windows, but nothing is removed (to test a policy)
#                       silent  = no windows: removes the app(s) in $4 and the files that clearly
#                                 belong to them (bundle id / Team ID matches). Needs $4.
#     $6  Brand Icon    logo for the windows. Blank = BRAND_ICON from the Config block.
#                       examples: /Library/Application Support/Acme/logo.png
#                                 /Applications/Self Service.app
#                                 https://acme.com/logo.png
#                                 sf:trash.fill
#                                 selfservice   (your Jamf Self Service branding logo)
#     $7  Banner Color  hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                       "auto-dark" (deeper logo shade for white text). Blank = bannerColor below.
#     $8  Brand Name    small line above the banner title, e.g. "Acme IT Support".
#     $9  Appearance    auto (follow the user's Light/Dark setting), light, or dark.
# ---------------------------------------------------------------------------------------------
#
# TESTING (nothing is removed with "dry"):
#   ./Self_Service_App_Uninstaller.sh "" dry                   # pick apps, review — preview only
#   ./Self_Service_App_Uninstaller.sh "Slack, Spotify" dry     # straight to the review
#   sudo ./Self_Service_App_Uninstaller.sh                     # the real thing, as Jamf runs it
#   ./Self_Service_App_Uninstaller.sh "" dry "sf:trash.fill" "#1F6FEB" "Acme IT Support" dark
#
# Exit codes (Jamf treats any non-zero exit as a FAILED policy):
#   0 - removed, dry run, user cancelled, or nothing to do
#   1 - an app couldn't be found or is protected, or one or more items failed to remove
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 06/26/26 - Initial release: AppCleaner-style scan (bundle id / Team ID / name / pkg receipts),
#               checkbox review, app picker, protected apps, dry run. - @cocopuff2u
# 2.0 11/13/26 - Redesign to match Collect User Logs, Network Health Check and Disk Usage: branded
#               windows (logo, brand name, banner colour, light/dark), pick SEVERAL apps at once with
#               search, sort, sizes and last-opened dates, scan progress with Cancel, grouped review
#               with sizes, Name match tags and Show in Finder, live total of what will be freed,
#               removal progress and a summary window. New Action Mode ($5: verbose / dry / silent),
#               several apps in $4, branding in $6-$9. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# WHAT TO REMOVE -----------------------------------------------------------
TARGET_APPS=""          # hardcode the app(s) to remove for a dedicated per-app policy, e.g. "Slack" or
                        # "Slack, zoom.us". Blank = take them from Jamf $4; if $4 is blank too, the user picks.

# HOW IT RUNS ---------------------------------------------------------------
DRY_RUN_OVERRIDE=false  # true = ALWAYS preview (show the windows, remove NOTHING), whatever $5 says.
                        # Handy for testing by hand. Keep false for production.
NAME_MATCHES_CHECKED=true    # true  = files found only by name ("Name match") start checked in the review
                             # false = they start unchecked, so the user has to opt in to each one
SILENT_NAME_MATCHES=false    # silent mode: also remove "Name match" files (true), or only files that
                             # clearly belong to the app by bundle id / Team ID (false, safer)
MIN_NAME_LEN=4          # app names shorter than this skip the loose name match (avoids false hits)
FORGET_RECEIPTS=true    # true = run "pkgutil --forget" for the app's installer receipts after removal
INCLUDE_USER_APPS=true  # true = the picker also lists apps in ~/Applications
PICKER_ROWS_SHOWN=8     # rows visible at once in the app picker (it scrolls for more)
logFile="/var/log/app_uninstaller.log"   # this script's own run log

# PROTECTED APPS: NEVER uninstall these --------------------------------------
# Case-insensitive, checked against each app's bundle id and name. Protected apps are hidden from the
# picker AND refused if named in the policy.
#   PROTECTED_BUNDLE_IDS      - the id OR any sub-id under it ("com.jamf.protect" also blocks
#                               "com.jamf.protect.agent")
#   PROTECTED_APP_NAMES       - exact name
#   PROTECTED_NAME_SUBSTRINGS - anything whose name CONTAINS the phrase ("Self Service" blocks
#                               "Acme Self Service", "Self Service+", ...)
# Add your own security / VPN / EDR tools here.
PROTECTED_BUNDLE_IDS=(
  com.jamf.connect com.jamfsoftware.selfservice.mac com.jamf.selfserviceplus
  com.jamf.protect com.jamf.setupmanager com.github.macadmins.Nudge
  # security and management agents: removing these by dragging to the Trash breaks them
  com.crowdstrike.falcon com.microsoft.wdav com.sentinelone com.sophos com.microsoft.CompanyPortalMac
)
PROTECTED_APP_NAMES=( "Jamf Connect" "Jamf Protect" "JamfProtect" "Nudge" "Setup Manager" )
PROTECTED_NAME_SUBSTRINGS=( "Self Service" )

# BRANDING (windows only) ---------------------------------------------------
BRAND_NAME="IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($8)
BRAND_ICON=""              # optional logo ($6). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:trash.fill                     (tinted to match the theme)
                           #   • Self Service   selfservice (or: ss) — your Jamf Self Service branding logo
                           # Blank = no logo.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto = follow the user's Light/Dark setting; light or dark forces one. ($9)

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto".
bannerColor="auto"         # banner + main button ($7). auto = the logo's exact main colour;
                           # auto-dark = a deeper shade of it for white text; no logo = #0056D2
BANNER_TEXT_COLOR="auto"   # auto = white, or near-black if the banner is too light for white
ACCENT_COLOR="auto"        # checkboxes, spinner, progress bar, icons. auto = the banner colour, made readable
SPINNER_BG_COLOR="auto"    # auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # "Apps Removed" icon. auto = Apple green
FAIL_COLOR="auto"          # error icon. auto = Apple red

# TEXT ----------------------------------------------------------------------
# {APP} = the app name(s), {USER} = the user's short name, {N} = a count
PICKER_TITLE="Uninstall Apps"
PICKER_SUBTITLE="Choose the apps you want to remove"
PICKER_NOTE="You'll see everything that will be removed before anything is deleted."
DRY_NOTE="Preview only — nothing will be removed, so you can click through everything safely."   # shown in dry runs
SCAN_TITLE="Finding App Files"
REVIEW_TITLE="Review & Remove"
REVIEW_MESSAGE="Uncheck anything you want to keep, then click Remove."
PREVIEW_MESSAGE="Uncheck anything you want to keep, then click Finish Preview."   # REVIEW_MESSAGE in preview mode
REVIEW_NOTE="Your files go to the Trash, so you can put them back. Name match items were found by name only — check that they belong to the app."
REMOVING_TITLE="Removing Apps"
DONE_TITLE="Apps Removed"
DRY_TITLE="Preview Complete"
continueButton="Continue"
removeButton="Remove {N} Items"
previewButton="Finish Preview"      # replaces the Remove button in preview (dry-run) mode
cancelButton="Cancel"
backButton="Back"
okButton="Done"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent

SCRIPT_VERSION="2.0"
SCRATCH="/tmp/app-uninstaller.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$UN_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # UN_DEBUG=1 keeps the scratch folder (testing)
STATUS_FILE="$SCRATCH/status.txt"    # the progress window polls this
CANCEL_FILE="$SCRATCH/cancel.flag"   # the Cancel button writes here (the window runs as the user)
: > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"
PICK_FILE="$SCRATCH/apps.tsv"        # rows for the app picker
REVIEW_FILE="$SCRATCH/review.tsv"    # rows for the review window
USE_PICKER=false                     # true when the user picks the apps (then the review has a Back button)

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point ($1 "/"), computer name ($2) and user ($3) first; strip that trio.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
[[ -n "$1" ]] && TARGET_APPS="$1"
ACTION_MODE="${2:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
DRY_RUN=false
case "$ACTION_MODE" in
  dry|dry-run|preview) DRY_RUN=true; ACTION_MODE="verbose" ;;
  silent)              ;;
  *)                   ACTION_MODE="verbose" ;;
esac
[[ "$DRY_RUN_OVERRIDE" == true ]] && DRY_RUN=true
[[ -n "$3" ]] && BRAND_ICON="$3"
[[ -n "$4" ]] && bannerColor="$4"
[[ -n "$5" ]] && BRAND_NAME="$5"
[[ -n "$6" ]] && APPEARANCE="$6"
APPEARANCE="${APPEARANCE:l}"; [[ "$APPEARANCE" == (light|dark) ]] || APPEARANCE="auto"

# --- Console / user resolution ----------------------------------------------
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}
targetUser="${consoleUser:-${JAMF_USER:-$(/usr/bin/id -un)}}"
targetUID=$(/usr/bin/id -u "$targetUser" 2>/dev/null)
USER_HOME=$(/usr/bin/dscl . -read /Users/"$targetUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="/Users/$targetUser"

# --- Helpers ----------------------------------------------------------------
logWritable() { [[ -w "$logFile" ]] || { [[ ! -e "$logFile" && -w "${logFile:h}" ]]; }; }
logMe() { local l="$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] $2"; print -r -- "$l"; logWritable && print -r -- "$l" >> "$logFile"; return 0; }
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

# human_size <bytes> -> "7.6 MB" (Finder-style: base 1000, one decimal; whole bytes below 1 KB)
human_size() {
  local -F n=${1:-0}; local -a u=(bytes KB MB GB TB); local -i i=1
  while (( n >= 1000 && i < 5 )); do (( n /= 1000.0, i++ )); done
  (( i == 1 )) && { print -r -- "${1:-0} bytes"; return; }
  printf "%.1f %s\n" $n $u[i]
}

# device serial number (built-in tools only)
device_serial() {
  /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
    | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}'
}

# human_kb <KB> -> "7.6 GB" (du's 1024-byte blocks, shown Finder-style like human_size)
human_kb() { human_size $(( ${1:-0} * 1024 )); }
kv() { print -r -- "${(r:14:)1}$2"; }     # kv "Label:" "value" -> aligned "Label:        value"

# Update the live progress window: 1 = chip (an app or file path), 2 = right-hand text ("2 of 3 apps"),
#   3 = "done/total" for the progress bar, 4 = what is happening ("Scanning", "Removing")
spin_status() {
  print -rl -- "$1" "$2" "$3" "$4" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}

# --- Progress window ----------------------------------------------------------------------------
# Same branded header as the other windows (logo, brand name, rounded title) with a Cancel pill,
# then a colourful arc spinner, the app or file being worked on (as a chip, with its icon), a
# progress bar, the step + percent, and a count. show_spinner <title> [nocancel]. A 0.3s timer re-reads $STATUS_FILE; a 30fps timer animates.
SPIN_SCPT="$SCRATCH/spin.jxa"
show_spinner() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  kill_spinner; : > "$STATUS_FILE"
  {
    print -r -- "ObjC.import('Cocoa');"
    print -r -- "var STATUS=\"$(as_esc "$STATUS_FILE")\", CANCEL=\"$(as_esc "$CANCEL_FILE")\", CANCEL_L=\"$(as_esc "$cancelButton")\", STITLE=\"$(as_esc "$1")\", NOCANCEL=$([[ $2 == nocancel ]] && print true || print false);"
    brand_jxa; palette_jxa
    print -r -- "var logo=brandImg(), BNAME=\"$(as_esc "$BRAND_NAME")\";"
    ui_common_jxa
    /bin/cat <<'JXA'
function readStatus(){ try{ var s=$.NSString.stringWithContentsOfFileEncodingError(STATUS,$.NSUTF8StringEncoding,null); return ObjC.unwrap(s)||""; }catch(e){ return ""; } }
function label(x,y,w,h,sz,bold,al){var t=$.NSTextField.alloc.initWithFrame($.NSMakeRect(x,y,w,h));
 t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=(al==null?1:al);
 t.usesSingleLineMode=true;t.cell.lineBreakMode=5;   // 5 = truncate middle (keeps both ends of a path)
 t.textColor=$.NSColor.labelColor; t.font=bold?$.NSFont.boldSystemFontOfSize(sz):$.NSFont.systemFontOfSize(sz);return t;}
var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var W=540, BH=(BNAME?78:66), botPad=22, rowY=botPad, barY=rowY+24, chipH=30, chipY=barY+18, spinCY=chipY+chipH+20+26, H=spinCY+26+22+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.level=3;
[0,1,2].forEach(function(i){ var bt=win.standardWindowButton(i); if(isOk(bt)) bt.hidden=true; });   // no traffic lights
win.appearance=APPEAR;
var cv=win.contentView;
// Header: logo, brand name, title, and the Cancel pill on the right
cv.addSubview(brandFill($.NSMakeRect(0,H-BH,W,BH),false)); bannerShade(cv,W,H,BH);
var LS=(BNAME?50:44), tx=124; if(logo){ var lv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(16,H-BH+(BH-LS)/2,LS,LS));
 lv.setImage(logo); lv.imageScaling=3; if(BI_S) lv.contentTintColor=BTXT; cv.addSubview(lv); }
var TH=30, tY = BNAME ? (H-BH+12) : (H-BH+(BH-TH)/2);
var tl=label(tx,tY,W-2*tx,TH,22,true,1); tl.stringValue=STITLE; tl.font=rounded(22,$.NSFontWeightBold); tl.textColor=BTXT; cv.addSubview(tl);
if(BNAME){ var bn=label(tx,tY+TH+1,W-2*tx,16,11,true,1); bn.stringValue=BNAME.toUpperCase(); bn.font=rounded(11,$.NSFontWeightSemibold); bn.textColor=BTXT; bn.alphaValue=0.72; cv.addSubview(bn); }
// Cancel: writes the cancel file; the script sees it, stops the scan and closes this window. Esc works too.
if(!$.UNCancel){ObjC.registerSubclass({name:'UNCancel',superclass:'NSObject',methods:{
 'cancel:':{types:['void',['id']],implementation:function(b){
   $("1").writeToFileAtomicallyEncodingError(CANCEL,false,$.NSUTF8StringEncoding,null);
   b.enabled=false; cancelLbl.stringValue="Cancelling…"; cancelPill.alphaValue=0.6; cancelLbl.alphaValue=0.7; }}}});}
var ch=$.UNCancel.alloc.init;
var CBW=96, CBH=28, cbx=W-CBW-16, cby=H-BH+(BH-CBH)/2;
var cancelPill=$.NSBox.alloc.initWithFrame($.NSMakeRect(cbx,cby,CBW,CBH)); cancelPill.boxType=4; cancelPill.titlePosition=0; cancelPill.cornerRadius=CBH/2;
cancelPill.fillColor=BTXT.colorWithAlphaComponent(0.20); cancelPill.borderWidth=1; cancelPill.borderColor=BTXT.colorWithAlphaComponent(0.45); cv.addSubview(cancelPill);
var cancelLbl=label(cbx,cby+(CBH-17)/2,CBW,17,12.5,true,1); cancelLbl.stringValue=CANCEL_L; cancelLbl.font=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); cancelLbl.textColor=BTXT; cv.addSubview(cancelLbl);
var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(cbx,cby,CBW,CBH)); cb.title=""; cb.bordered=false; cb.transparent=true;
cb.target=ch; cb.action='cancel:'; cb.keyEquivalent=$("\u001b"); cv.addSubview(cb);
if(NOCANCEL){ cancelPill.hidden=true; cancelLbl.hidden=true; cb.hidden=true; }
// Spinner: a rotating arc whose tail shifts to a neighbouring hue and fades out, over a faint track ring.
var aC=ACCENT.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace), AH=aC.hueComponent, AS=aC.saturationComponent, AB=aC.brightnessComponent;
function hsb(h,sa,br,al){ return $.NSColor.colorWithHueSaturationBrightnessAlpha(((h%1)+1)%1, Math.min(1,sa), Math.min(1,br), al); }
var SEGS=48, SWEEP=290, spinA=90;
var WBG=DARK?C([0.165,0.165,0.17]):C([0.925,0.925,0.93]), SAT=Math.max(AS,0.85);
var ARC=[]; for(var i=0;i<SEGS;i++){ var t=i/(SEGS-1);
 var col=hsb(AH+0.22*(1-t), SAT, Math.min(1,Math.max(AB,0.75)*(0.92+0.12*t)), 1);
 ARC.push(WBG.blendedColorWithFractionOfColor(Math.pow(t,1.35)*0.92+0.08, col)); }
var TRACK=ACCENT.colorWithAlphaComponent(DARK?0.16:0.12);
if(!$.UNArcSpin){ ObjC.registerSubclass({name:'UNArcSpin',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
 var b=this.bounds, c=$.NSMakePoint(b.size.width/2,b.size.height/2), R=b.size.width/2-5, LW=5;
 var tr=$.NSBezierPath.bezierPath; tr.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,R,0,360); tr.lineWidth=LW; TRACK.setStroke; tr.stroke;
 var step=SWEEP/SEGS;
 for(var i=0;i<SEGS;i++){ var st=spinA+SWEEP-i*step, en=st-step*1.15;
  var pth=$.NSBezierPath.bezierPath; pth.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,R,st,en,true);
  pth.lineWidth=LW; pth.lineCapStyle=0; ARC[i].setStroke; pth.stroke; }
 var ha=(spinA)*Math.PI/180, hx=c.x+R*Math.cos(ha), hy=c.y+R*Math.sin(ha);
 var dot=$.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(hx-LW/2,hy-LW/2,LW,LW)); ARC[SEGS-1].setFill; dot.fill;
 }}}}); }
var SPS=60, arcView=$.UNArcSpin.alloc.initWithFrame($.NSMakeRect((W-SPS)/2,spinCY-SPS/2,SPS,SPS)); cv.addSubview(arcView);
// The folder being measured, as a chip (monospaced, accent-tinted)
var CX=40, CW=W-80;
var fchip=$.NSBox.alloc.initWithFrame($.NSMakeRect(CX,chipY,CW,chipH)); fchip.boxType=4; fchip.titlePosition=0; fchip.cornerRadius=8;
fchip.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.14:0.09); fchip.borderWidth=1; fchip.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.35:0.28); cv.addSubview(fchip);
var fic=$.NSImageView.alloc.initWithFrame($.NSMakeRect(CX+10,chipY+(chipH-20)/2,20,20));
fic.image=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("folder",""); fic.imageScaling=3; fic.contentTintColor=ACCENT; cv.addSubview(fic);
var folder=label(CX+36,chipY+(chipH-18)/2,CW-72,18,12,false); folder.textColor=$.NSColor.labelColor; cv.addSubview(folder);
// Progress bar: a faint accent track with an accent fill that eases toward the real progress
var BX=40, BW=W-80, BHt=6;
var track=$.NSBox.alloc.initWithFrame($.NSMakeRect(BX,barY,BW,BHt)); track.boxType=4; track.borderWidth=0; track.titlePosition=0;
track.cornerRadius=BHt/2; track.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.20:0.16); cv.addSubview(track);
var fill=$.NSBox.alloc.initWithFrame($.NSMakeRect(BX,barY,BHt,BHt)); fill.boxType=4; fill.borderWidth=0; fill.titlePosition=0;
fill.cornerRadius=BHt/2; fill.fillColor=ACCENT; cv.addSubview(fill);
var barTarget=0, barCur=0;
function setBar(f){ barCur=f; var w=Math.max(BHt, BW*Math.min(1,f)); fill.frame=$.NSMakeRect(BX,barY,w,BHt); }
// Bottom row: what's happening + percent on the left, amount measured on the right
var step=label(BX,rowY,BW/2,16,11.5,false,0); step.font=rounded(11.5,$.NSFontWeightMedium); step.textColor=SUB; cv.addSubview(step);
var count=label(BX+BW/2,rowY,BW/2,16,11.5,true,2); count.font=rounded(11.5,$.NSFontWeightSemibold); count.textColor=ACCENT; cv.addSubview(count);
var MONO=$.NSFont.monospacedSystemFontOfSizeWeight(12,$.NSFontWeightMedium), UIF=rounded(12.5,$.NSFontWeightSemibold), lastChip="";
function applyStatus(){ var L=readStatus().split("\n"), f=L[0]||"";
 folder.setStringValue(f); count.setStringValue(L[1]||"");
 if(f!==lastChip){ lastChip=f; var isPath=(f.charAt(0)=="/"||f.charAt(0)=="~"), isApp=/\.app$/i.test(f) && $.NSFileManager.defaultManager.fileExistsAtPath(f);
  if(isApp){ fic.image=$.NSWorkspace.sharedWorkspace.iconForFile(f); fic.contentTintColor=null; }   // the app's own icon
  else { fic.image=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(isPath?"folder":"magnifyingglass",""); fic.contentTintColor=ACCENT; }
  folder.font=isPath?MONO:UIF; }
 var m=(L[2]||"").match(/^(\d+)\/(\d+)$/); if(m){ var d=+m[1], t=+m[2]; barTarget=t?Math.min(0.99,d/t):0; }
 step.setStringValue(barTarget>=0.99 && !m ? "Finishing up" : ((L[3]||"Working")+" · "+Math.floor(barTarget*100)+"%")); }
applyStatus(); setBar(barTarget);
if(!$.UNSpinTick){ObjC.registerSubclass({name:'UNSpinTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){ applyStatus(); }},
 'spin:':{types:['void',['id']],implementation:function(s){ spinA=(spinA-12+360)%360; arcView.needsDisplay=true;
   if(Math.abs(barTarget-barCur)>0.002) setBar(barCur+(barTarget-barCur)*0.07); }}}});}
var tk=$.UNSpinTick.alloc.init;
[[0.3,'tick:'],[1/30,'spin:']].forEach(function(a){   // common modes: keeps animating while the window is dragged
 var tm=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(a[0],tk,a[1],null,true); $.NSRunLoop.currentRunLoop.addTimerForMode(tm,$.NSRunLoopCommonModes); });
win.center; win.orderFrontRegardless; app.activateIgnoringOtherApps(true);
app.run();
JXA
  } > "$SPIN_SCPT"
  /bin/chmod 644 "$SPIN_SCPT"
  run_as_user /usr/bin/osascript -l JavaScript "$SPIN_SCPT" >/dev/null 2>&1 &
}
kill_spinner() { /usr/bin/pkill -f "$SPIN_SCPT" 2>/dev/null; return 0; }

# --- Shared window pieces (picker + review) -----------------------------------------------------
# Defines: label/wrapLabel/rbox/sym, fmt(KB), readLines, iconFor(path), bringFinder(),
#          header(cv,W,H,BH,title,subtitle,chip,chipSymbol) and pill(...) — the same look as the
#          results windows of Disk Usage / Network Health Check.
un_ui_jxa() {
  /bin/cat <<'JXA'
function G(a){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,a);}
function fmt(kb){ var b=kb*1024, u=["bytes","KB","MB","GB","TB"], i=0; while(b>=1000&&i<4){ b/=1000; i++; }
 return i==0 ? Math.round(b)+" bytes" : (b>=100?Math.round(b):b.toFixed(1))+" "+u[i]; }
function readLines(p){try{var s=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p,$.NSUTF8StringEncoding,null))||"";return s.split("\n").filter(function(l){return l.length;});}catch(e){return [];}}
function label(s,x,y,w,h,sz,wt,al){var t=$.NSTextField.alloc.initWithFrame($.NSMakeRect(x,y,w,h));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al==null?0:al;
 t.usesSingleLineMode=true;t.cell.lineBreakMode=4;t.textColor=$.NSColor.labelColor;
 t.font=$.NSFont.systemFontOfSizeWeight(sz,wt||$.NSFontWeightRegular);return t;}
function wrapLabel(s,x,y,w,h,sz,al){var t=label(s,x,y,w,h,sz,null,al);t.usesSingleLineMode=false;t.cell.wraps=true;t.cell.lineBreakMode=0;return t;}
function rbox(x,y,w,h,col,rad){var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h));b.boxType=4;b.borderWidth=0;b.titlePosition=0;b.cornerRadius=rad||0;b.fillColor=col;return b;}
function sym(name,x,y,s,col){var img=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(name,"");if(!isOk(img))return null;
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(x,y,s,s));iv.setImage(img);iv.imageScaling=3;iv.contentTintColor=col;return iv;}
function tw(s,f){ return Math.ceil($(s).sizeWithAttributes($.NSDictionary.dictionaryWithObjectForKey(f,$.NSFontAttributeName)).width); }
// Finder icon for an item; if it isn't there (already gone, or test data), the icon for its kind.
function iconFor(p){ var ws=$.NSWorkspace.sharedWorkspace; if($.NSFileManager.defaultManager.fileExistsAtPath(p)) return ws.iconForFile(p);
 var n=p.split("/").pop(), ext=n.indexOf(".")>0 ? n.split(".").pop().toLowerCase() : "";
 if(ext=="app") return ws.iconForFileType("com.apple.application-bundle");
 if(ext=="plist") return ws.iconForFileType("com.apple.property-list");
 if(!/^(plist|bom|log|txt|json|db|sqlite|binarycookies|dylib|zip|dmg|pkg|plugin|kext|prefpane|bundle|framework|app)$/.test(ext)) return ws.iconForFileType("public.folder");   // "com.vendor.app" style names are folders
 return ws.iconForFileType(ext); }
// Put Finder in front of this window after showing an item (macOS otherwise opens it behind us).
function bringFinder(){ try{ var fa=$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.finder");
 if(fa.count>0){ fa=fa.objectAtIndex(0); try{ $.NSApplication.sharedApplication.yieldActivationToApplication(fa); }catch(e){} fa.activateWithOptions(1|2); } }catch(e){} }
function reveal(p){ var fm=$.NSFileManager.defaultManager;
 while(p && p!="/" && !fm.fileExistsAtPath(p)) p=p.replace(/\/[^\/]*$/,"")||"/";   // gone? show the nearest folder that exists
 if(p){ $.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs($([$.NSURL.fileURLWithPath(p)])); bringFinder(); } }
// A borderless button with the pointing-hand cursor
if(!$.UNLink){ObjC.registerSubclass({name:'UNLink',superclass:'NSButton',methods:{'resetCursorRects':{implementation:function(){
 this.addCursorRectCursor(this.bounds,$.NSCursor.pointingHandCursor); }}}});}
function clickArea(x,y,w,h,target,act,tag,parent,hand){ var b=(hand?$.UNLink:$.NSButton).alloc.initWithFrame($.NSMakeRect(x,y,w,h));
 b.title=""; b.bordered=false; b.transparent=true; b.target=target; b.action=act; b.tag=tag; parent.addSubview(b); return b; }
// Banner: a left-aligned header (logo, brand name, title, subtitle) with an optional chip on the right.
function header(cv,W,H,BH,PAD,title,sub,chipText,chipSym){
 cv.addSubview(brandFill($.NSMakeRect(0,H-BH,W,BH),false)); bannerShade(cv,W,H,BH);
 var LS=56, btx=PAD;
 if(logo){ var blv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(PAD,H-BH+(BH-LS)/2,LS,LS)); blv.setImage(logo); blv.imageScaling=3; if(BI_S) blv.contentTintColor=BTXT; cv.addSubview(blv); btx=PAD+LS+16; }
 var CHF=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold), chw=chipText?tw(chipText,CHF)+46:0, CHH=30;
 var tw0=W-btx-PAD-(chw?chw+16:0), hasEb=!!BNAME;
 var tY=hasEb ? H-BH+(BH-62)/2+16 : H-BH+(BH-48)/2+16;
 if(hasEb){ var bnl=label(BNAME.toUpperCase(),btx,tY+30,tw0,15,11,$.NSFontWeightSemibold,0); bnl.font=rounded(11,$.NSFontWeightBold); bnl.textColor=BTXT; bnl.alphaValue=0.75; cv.addSubview(bnl); }
 var tl=label(title,btx,tY,tw0,30,24,$.NSFontWeightBold,0); tl.font=rounded(24,$.NSFontWeightBold); tl.textColor=BTXT; cv.addSubview(tl);
 var st=label(sub,btx,tY-17,tw0,17,12.5,$.NSFontWeightMedium,0); st.textColor=BTXT; st.alphaValue=0.8; cv.addSubview(st);
 if(chw){ var cx=W-PAD-chw, cy=H-BH+(BH-CHH)/2;
  var chip=$.NSBox.alloc.initWithFrame($.NSMakeRect(cx,cy,chw,CHH)); chip.boxType=4; chip.titlePosition=0; chip.cornerRadius=CHH/2;
  chip.fillColor=BTXT.colorWithAlphaComponent(0.16); chip.borderWidth=1; chip.borderColor=BTXT.colorWithAlphaComponent(0.35); cv.addSubview(chip);
  var di=sym(chipSym||"info.circle.fill",cx+12,cy+(CHH-16)/2,16,BTXT); if(di) cv.addSubview(di);
  var dl=label(chipText,cx+34,cy+(CHH-17)/2,chw-40,17,12.5,$.NSFontWeightSemibold,0); dl.font=CHF; dl.textColor=BTXT; cv.addSubview(dl); }
 return st; }
// pill(text,x,y,w,h,target,action,key,primary) -> {btn,lbl,box,set(text),enable(on)}
//   primary = filled with the banner colour; otherwise accent-tinted.
function pill(t,x,y,w,h,target,act,key,primary){
 var bx; if(primary){ bx=brandFill($.NSMakeRect(x,y,w,h),true); cv.addSubview(bx); }
 else { bx=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); bx.boxType=4; bx.titlePosition=0; bx.cornerRadius=h/2;
   bx.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.20:0.12); bx.borderWidth=1; bx.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.45:0.35); cv.addSubview(bx); }
 var lb=label(t,x,y+(h-18)/2,w,18,13,$.NSFontWeightSemibold,1); lb.textColor=primary?BTXT:ACCENT; cv.addSubview(lb);
 // Disabled look: a plain grey pill that reads in both light and dark mode (a faded brand fill vanishes on dark).
 var off=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); off.boxType=4; off.titlePosition=0; off.cornerRadius=h/2;
 var ink=DARK?$.NSColor.whiteColor:$.NSColor.blackColor;
 off.fillColor=ink.colorWithAlphaComponent(DARK?0.10:0.07); off.borderWidth=1;
 off.borderColor=ink.colorWithAlphaComponent(DARK?0.22:0.20); off.hidden=true;
 cv.addSubviewPositionedRelativeTo(off,-1,lb);
 var onC=lb.textColor;
 var b=$.NSButton.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); b.title=""; b.bordered=false; b.transparent=true;
 b.target=target; b.action=act; if(key) b.keyEquivalent=$(key); cv.addSubview(b);
 return {btn:b,lbl:lb,box:bx,set:function(s){lb.stringValue=s;},enable:function(on){ b.enabled=on; bx.hidden=!on; off.hidden=on;
   lb.textColor=on?onC:$.NSColor.secondaryLabelColor; lb.alphaValue=1; }}; }
JXA
}

# Everything a window needs before its own code: palette, logo, shared pieces.
win_prelude() {
  print -r -- "ObjC.import('Cocoa');"
  brand_jxa; palette_jxa
  print -r -- "var logo=brandImg(), BNAME=\"$(as_esc "$BRAND_NAME")\";"
  ui_common_jxa; un_ui_jxa
  print -r -- "var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);"
}

# run_window <script> -> runs a window in the user's session and prints what it returns
run_window() {
  /bin/chmod 644 "$1" "$PICK_FILE" "$REVIEW_FILE" 2>/dev/null
  run_as_user /usr/bin/osascript -l JavaScript "$1" 2>>"$SCRATCH/jxa-err.log"
}

# --- Apps on this Mac ------------------------------------------------------------------------------
# is_protected <app path> <bundle id> -> 0 (true) if the app is on any PROTECTED list
is_protected() {
  local bid="${2:l}" nm="${1:t:r:l}" x
  for x in $PROTECTED_BUNDLE_IDS;      do x="${x:l}"; [[ -n "$bid" && ( "$bid" == "$x" || "$bid" == "$x".* ) ]] && return 0; done
  for x in $PROTECTED_APP_NAMES;       do x="${x:l}"; [[ "$nm" == "$x" ]] && return 0; done
  for x in $PROTECTED_NAME_SUBSTRINGS; do x="${x:l}"; [[ "$nm" == *"$x"* ]] && return 0; done
  return 1
}

# app_dirs -> every .app where users keep apps (one folder deep too, e.g. /Applications/Adobe X/X.app)
app_dirs() {
  local -a d=( /Applications/*.app(N) /Applications/*/*.app(N) )
  [[ "$INCLUDE_USER_APPS" == true ]] && d+=( "$USER_HOME"/Applications/*.app(N) "$USER_HOME"/Applications/*/*.app(N) )
  local a; for a in $d; do [[ "${a:h}" == *.app ]] || print -r -- "$a"; done
}

# app_meta <path> -> M_BID M_VER M_KB M_USED (epoch, 0 = unknown). Spotlight first (one fast call),
# Info.plist / du when Spotlight has nothing.
zmodload zsh/datetime 2>/dev/null
app_meta() {
  local -a v=( "${(@0)$(/usr/bin/mdls -raw -name kMDItemCFBundleIdentifier -name kMDItemLastUsedDate -name kMDItemPhysicalSize -name kMDItemVersion "$1" 2>/dev/null)}" )
  M_BID="${v[1]}"; M_USED=0; M_KB=0; M_VER="${v[4]}"
  [[ "$M_BID" == "(null)" || -z "$M_BID" ]] && M_BID="$(/usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  [[ "${v[2]}" == <->-<->-<->" "* ]] && { TZ=UTC strftime -r -s M_USED '%Y-%m-%d %H:%M:%S' "${v[2]% *}" 2>/dev/null || M_USED=0; }
  [[ "${v[3]}" == <1-> ]] && M_KB=$(( v[3] / 1024 ))
  (( M_KB )) || M_KB=$(/usr/bin/du -sk "$1" 2>/dev/null | /usr/bin/awk '{print $1}')
  [[ "$M_VER" == "(null)" || -z "$M_VER" ]] && M_VER="$(/usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
  M_VER="${M_VER//$'\t'/ }"
}

# is_running <app path> -> 0 if any process runs from inside the app
PS_CACHE=""
is_running() { [[ -z "$PS_CACHE" ]] && PS_CACHE="$(/bin/ps -axo comm= 2>/dev/null)"; [[ $'\n'"$PS_CACHE" == *$'\n'"$1/"* ]]; }

# build_picker -> PICK_APPS (paths) and $PICK_FILE rows:  A path name version lastUsedEpoch KB running
build_picker() {
  PICK_APPS=(); : > "$PICK_FILE"
  local a
  for a in ${(f)"$(app_dirs)"}; do
    app_meta "$a"
    if [[ "${M_BID:l}" == com.apple.* ]]; then continue; fi
    if is_protected "$a" "$M_BID"; then logMe INFO "Picker: hiding protected app ${a:t:r} [$M_BID]"; continue; fi
    [[ -n "$M_BID" ]] || { logMe INFO "Picker: hiding ${a:t:r} (no bundle id)"; continue; }
    PICK_APPS+=("$a")
    print -r -- "A"$'\t'"$a"$'\t'"${a:t:r}"$'\t'"$M_VER"$'\t'"$M_USED"$'\t'"${M_KB:-0}"$'\t'"$(is_running "$a" && print 1 || print 0)" >> "$PICK_FILE"
  done
  logMe INFO "Picker: offering ${#PICK_APPS} app(s)."
}

# --- App picker window --------------------------------------------------------------------------
# A searchable, sortable list of apps with checkboxes (pick several). Each row: icon, name, version,
# when it was last opened, whether it's open, and its size. Prints the picked row numbers ("0,3,5")
# or __CANCEL__.
show_picker() {
  local s="$SCRATCH/picker.jxa"
  {
    win_prelude
    print -r -- "var DATA=\"$(as_esc "$PICK_FILE")\", PTITLE=\"$(as_esc "$PICKER_TITLE")\", PSUB=\"$(as_esc "$PICKER_SUBTITLE")\", PNOTE=\"$(as_esc "$PICKER_NOTE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\";"
    print -r -- "var L_CONT=\"$(as_esc "$continueButton")\", L_CANCEL=\"$(as_esc "$cancelButton")\", VIS=${PICKER_ROWS_SHOWN:-8}, DRY=$DRY_RUN, PRESEL=[$PICKED];"
    /bin/cat <<'JXA'
var APPS=readLines(DATA).map(function(l){return l.split("\t");}).filter(function(r){return r[0]=="A";})
 .map(function(r,i){return {i:i,path:r[1],name:r[2],ver:r[3],used:+r[4]||0,kb:+r[5]||0,run:r[6]=="1"};});
var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
// "Last opened Nov 12, 2026 (yesterday)" — the date, plus how long ago in plain words
function ago(t){ if(!t) return "Last opened: unknown"; var now=new Date(), d=new Date(t*1000), days=Math.floor((new Date(now.getFullYear(),now.getMonth(),now.getDate())-new Date(d.getFullYear(),d.getMonth(),d.getDate()))/86400000);
 var mo=Math.round(days/30.4), rel = days<=0 ? "today" : days==1 ? "yesterday" : days<30 ? days+" days ago" : days<365 ? mo+(mo==1?" month ago":" months ago") : Math.floor(days/365)+(days<730?" year ago":" years ago");
 return "Last opened "+MON[d.getMonth()]+" "+d.getDate()+", "+d.getFullYear()+" ("+rel+")"; }

var hd=null;
if(!$.UNPick){ObjC.registerSubclass({name:'UNPick',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'row:':{types:['void',['id']],implementation:function(s){ var r=ROWS[s.tag]; r.cb.state=ObjC.unwrap(r.cb.state)==1?0:1; update(); }},
 'chk:':{types:['void',['id']],implementation:function(s){ update(); }},
 'search:':{types:['void',['id']],implementation:function(s){ layout(); }},
 'sort:':{types:['void',['id']],implementation:function(s){ layout(); }}}});}
hd=$.UNPick.alloc.init;

// ---- sizes and positions (bottom-up) ----
var W=700, PAD=24, BH=(BNAME?96:84), ROWH=54, NV=Math.max(4,Math.min(VIS,APPS.length||4)), LH=NV*ROWH+10, TBH=28;
var PBW=150, PBH=34, PBY=18, noteY=PBY+PBH+12, NOTEH=16, listY=noteY+NOTEH+12, tbY=listY+LH+14;
var H=tbY+TBH+16+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR;
var cv=win.contentView;
header(cv,W,H,BH,PAD,PTITLE,PSUB,DRY?"Preview only":"",DRY?"eye.fill":"");

// Toolbar: search on the left, sort on the right
var search=$.NSSearchField.alloc.initWithFrame($.NSMakeRect(PAD,tbY,280,TBH)); search.placeholderString="Search apps";
search.target=hd; search.action='search:'; try{ search.sendsSearchStringImmediately=true; }catch(e){} cv.addSubview(search);
var sorter=$.NSSegmentedControl.segmentedControlWithLabelsTrackingModeTargetAction($(["Name","Size","Last Opened"]),0,hd,'sort:');
sorter.sizeToFit; var sgw=Math.max(250,sorter.frame.size.width); sorter.frame=$.NSMakeRect(W-PAD-sgw,tbY+2,sgw,24); sorter.selectedSegment=0;
try{ sorter.selectedSegmentBezelColor=ACCENT; }catch(e){}
sorter.setToolTipForSegment("Biggest first",1); sorter.setToolTipForSegment("Apps you haven't opened in the longest time first",2);
cv.addSubview(sorter);
var sl=label("Sort",W-PAD-sgw-44,tbY+5,36,17,12,$.NSFontWeightMedium,2); sl.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(sl);

// The list: a rounded card with a scrolling column of rows
var LW=W-2*PAD;
cv.addSubview(rbox(PAD,listY,LW,LH,G(0.08),12));
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,listY+5,LW,LH-10)); sv.drawsBackground=false; sv.borderType=0;
sv.hasVerticalScroller=true; sv.autohidesScrollers=true; sv.scrollerStyle=1; cv.addSubview(sv);
var SVH=LH-10, doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,SVH)); sv.documentView=doc;
var empty=label("",0,0,LW,18,12.5,$.NSFontWeightRegular,1); empty.textColor=$.NSColor.secondaryLabelColor; doc.addSubview(empty);
var NF=$.NSFont.systemFontOfSizeWeight(13.5,$.NSFontWeightSemibold);
var ROWS=APPS.map(function(a,i){
 var rv=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,ROWH)); doc.addSubview(rv);
 var hl=rbox(6,3,LW-12,ROWH-6,ACCENT.colorWithAlphaComponent(DARK?0.18:0.10),9); hl.hidden=true; rv.addSubview(hl);
 var sep=rbox(88,ROWH-1,LW-88-16,1,G(0.15)); rv.addSubview(sep);
 clickArea(6,0,LW-12,ROWH,hd,'row:',i,rv,false);
 var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(18,(ROWH-20)/2,22,20)); cb.setButtonType(3); cb.title=""; cb.target=hd; cb.action='chk:'; cb.tag=i; if(PRESEL.indexOf(i)>=0) cb.state=1;   // back from the review: keep what was picked
 try{ cb.contentTintColor=ACCENT; }catch(e){} rv.addSubview(cb);
 var ic=$.NSWorkspace.sharedWorkspace.iconForFile(a.path);
 if(isOk(ic)){ var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(46,(ROWH-36)/2,36,36)); iv.setImage(ic); iv.imageScaling=3; rv.addSubview(iv); }
 var SZW=90, nx=92, nw=LW-nx-SZW-24;
 var nl=label(a.name,nx,ROWH/2+1,nw,18,13.5,$.NSFontWeightSemibold); nl.font=NF; rv.addSubview(nl);
 var bits=[]; if(a.ver) bits.push("Version "+a.ver); var ag=ago(a.used); if(ag) bits.push(ag);
 var sub=label(bits.join("  ·  "),nx,ROWH/2-17,nw,16,11.5); sub.textColor=$.NSColor.secondaryLabelColor; rv.addSubview(sub);
 if(a.run){ var stw=tw(bits.join("  ·  "),sub.font); var ox=nx+(bits.length?stw+10:0);   // a small "Open" badge after the details
  var ob=$.NSBox.alloc.initWithFrame($.NSMakeRect(ox,ROWH/2-16,44,15)); ob.boxType=4; ob.titlePosition=0; ob.cornerRadius=7.5; ob.borderWidth=0;
  ob.fillColor=OKC.colorWithAlphaComponent(DARK?0.22:0.16); rv.addSubview(ob);
  var ol=label("OPEN",ox,ROWH/2-15,44,13,9.5,$.NSFontWeightBold,1); ol.textColor=DARK?OKC:C([0.08,0.42,0.18]); ol.toolTip="This app is open now — it will be quit before it's removed"; rv.addSubview(ol); }
 var szl=label(a.kb?fmt(a.kb):"",LW-16-SZW,(ROWH-18)/2,SZW,18,13,$.NSFontWeightSemibold,2); szl.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(13,$.NSFontWeightSemibold); rv.addSubview(szl);
 return {a:a,view:rv,cb:cb,hl:hl,sep:sep};
});

// Footer: what's picked on the left, Cancel + Continue on the right, note above
var nt=label(DRY?DNOTE:PNOTE,PAD,noteY,W-2*PAD,NOTEH,11.5,$.NSFontWeightRegular,1); nt.textColor=$.NSColor.secondaryLabelColor;
if(DRY){ nt.textColor=ACCENT; nt.font=$.NSFont.systemFontOfSizeWeight(12,$.NSFontWeightSemibold); }   // dry run: say so plainly
cv.addSubview(nt);
var summary=label("",PAD+4,PBY+(PBH-18)/2,W-2*PAD-2*PBW-24,18,13,$.NSFontWeightSemibold); cv.addSubview(summary);
var pc=pill(L_CANCEL,W-PAD-2*PBW-12,PBY,PBW,PBH,hd,'no:','\u001b',false);
var pk=pill(L_CONT,W-PAD-PBW,PBY,PBW,PBH,hd,'ok:','\r',true);

function layout(){
 var q=ObjC.unwrap(search.stringValue).toLowerCase().trim(), mode=sorter.selectedSegment;
 var vis=ROWS.filter(function(r){ return !q || r.a.name.toLowerCase().indexOf(q)>=0; });
 vis.sort(function(x,y){ if(mode==1) return y.a.kb-x.a.kb; if(mode==2) return (x.a.used||0)-(y.a.used||0);
  return x.a.name.toLowerCase().localeCompare(y.a.name.toLowerCase()); });
 var DH=Math.max(SVH,vis.length*ROWH); doc.frame=$.NSMakeRect(0,0,LW,DH);
 ROWS.forEach(function(r){ r.view.hidden=true; });
 vis.forEach(function(r,k){ r.view.frame=$.NSMakeRect(0,DH-(k+1)*ROWH,LW,ROWH); r.view.hidden=false; r.sep.hidden=(k==0); });
 empty.hidden=vis.length>0; empty.stringValue=APPS.length?("No apps match “"+q+"”"):"No apps can be removed on this Mac."; empty.frame=$.NSMakeRect(0,DH/2-9,LW,18);
 sv.hasVerticalScroller=(DH>SVH); sv.contentView.scrollToPoint($.NSMakePoint(0,DH-SVH)); sv.reflectScrolledClipView(sv.contentView);
}
function update(){
 var n=0, kb=0; ROWS.forEach(function(r){ var on=ObjC.unwrap(r.cb.state)==1; r.hl.hidden=!on; if(on){ n++; kb+=r.a.kb; } });
 summary.stringValue = n ? (n+(n==1?" app":" apps")+" selected  ·  "+fmt(kb)) : "Select one or more apps";
 summary.textColor = n ? $.NSColor.labelColor : $.NSColor.secondaryLabelColor;
 pk.enable(n>0);
}
layout(); update();
win.center; win.makeKeyAndOrderFront(null); win.makeFirstResponder(search); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
var out=[]; ROWS.forEach(function(r,i){ if(ObjC.unwrap(r.cb.state)==1) out.push(i); });
(resp==1 && out.length) ? out.join(",") : "__CANCEL__";
JXA
  } > "$s"
  run_window "$s"
}

# --- Resolving the apps named in the policy ------------------------------------------------------
# resolve_app <name | bundle id | path> -> REPLY = the .app path. 0 = found, 1 = not found, 2 = ambiguous
resolve_app() {
  local arg="$1" low="${1:l}" a nm dn bid; REPLY=""
  if [[ "$arg" == /* ]]; then [[ -d "$arg" && "$arg" == *.app ]] && { REPLY="${arg:A}"; return 0; }; return 1; fi
  local -aU found
  for a in ${(f)"$(app_dirs)"}; do
    if [[ "${a:t:r:l}" == "$low" || "${a:t:l}" == "$low" ]]; then found+=("$a"); continue; fi
    bid="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    [[ -n "$bid" && "${bid:l}" == "$low" ]] && { found+=("$a"); continue; }
    nm="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleName 2>/dev/null)"
    dn="$(/usr/bin/defaults read "$a/Contents/Info" CFBundleDisplayName 2>/dev/null)"
    [[ "${nm:l}" == "$low" || ( -n "$dn" && "${dn:l}" == "$low" ) ]] && found+=("$a")
  done
  case ${#found} in
    0) return 1 ;;
    1) REPLY="${found[1]}"; return 0 ;;
    *) logMe WARN "\"$arg\" matches more than one app: ${(j:, :)found}"; return 2 ;;
  esac
}

# --- Finding each app's files --------------------------------------------------------------------
LIBSUBS=(
  "Application Support" "Application Scripts" "Containers" "Group Containers"
  "Caches" "Caches/Metadata" "HTTPStorages" "Preferences" "Preferences/ByHost" "Saved Application State"
  "WebKit" "Cookies" "Logs" "LaunchAgents" "Internet Plug-Ins" "PreferencePanes"
  "QuickLook" "Services" "Spotlight" "Frameworks" "Extensions" "StartupItems"
  "Widgets" "Address Book Plug-Ins" "Mail" "Screen Savers" "Audio" "Audio/Plug-Ins/Components"
  "Autosave Information" "ColorPickers" "Components" "Input Methods"
  "Keyboard Layouts" "PDF Services" "Printers" "ScriptingAdditions" "Scripts"
  "Sounds" "SyncedPreferences" "Receipts" "Application Support/CrashReporter"
)
SYSONLY=( "/Library/LaunchDaemons" "/Library/PrivilegedHelperTools" "/private/var/db/receipts" )

# classify <path> -> REPLY = h (clearly the app's: its bundle id, its Team ID + bundle id, or a folder
#                    named exactly like the app), r (the name only CONTAINS the app's name — "Name match"), or ""
# name_hit <lowercased name> -> true if an app-name token appears in it as a whole word, so "Code"
# matches "Code Helper" or "code-cache" but not "onetimepasscodes" or "Xcode". Apple's own
# com.apple.* files never match by name (they belong to macOS, not the app).
name_hit() {
  setopt localoptions extendedglob
  local n="$1" tok
  [[ "$n" == com.apple.* || "$n" == */com.apple.* ]] && return 1
  for tok in $NAME_TOKENS; do [[ "$n" == (|*[^a-z0-9])"$tok"(|[^a-z0-9]*) ]] && return 0; done
  return 1
}

classify() {
  local name="${1:t}" low="${1:t:l}" tok; REPLY=""
  if [[ "$name" == "$BUNDLE_ID" || "$name" == "$BUNDLE_ID".* || "$name" == "$BUNDLE_ID"-* \
     || "$name" == *".$BUNDLE_ID" || "$name" == *".$BUNDLE_ID."* ]]; then REPLY=h; return; fi
  if [[ -n "$TEAM_ID" && "$name" == "$TEAM_ID".* && "$name" == *"$BUNDLE_ID"* ]]; then REPLY=h; return; fi
  for tok in $NAME_TOKENS; do [[ "$low" == "$tok" ]] && { REPLY=h; return; }; done
  name_hit "$low" && REPLY=r
}

# Every item found, across all the apps (same index in each array):
#   IT_G = which app (1..), IT_P = path, IT_C = a (the app itself) / h (clearly its) / r (name match), IT_KB = size
typeset -a IT_G IT_P IT_C IT_KB
typeset -A SEEN
typeset -a G_PATH G_NAME G_BID G_VER G_RUN G_PKGS G_TEAM
add_item() { [[ -n "${SEEN[$2]}" ]] && return; SEEN[$2]=1; IT_G+=("$1"); IT_P+=("$2"); IT_C+=("$3"); IT_KB+=(0); }

ALL_PKGS=()
# scan_app <group #> <app path>
scan_app() {
  local g=$1 APP_PATH="$2" r s child dir pkg plow info vol loc f full flow keep tok
  BUNDLE_ID="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  local disp="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleDisplayName 2>/dev/null)"
  [[ -z "$disp" ]] && disp="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleName 2>/dev/null)"
  TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}')"
  [[ "$TEAM_ID" == "not set" ]] && TEAM_ID=""
  NAME_TOKENS=()
  for tok in "${APP_PATH:t:r}" "$disp"; do [[ -n "$tok" && ${#tok} -ge $MIN_NAME_LEN ]] && NAME_TOKENS+=("${tok:l}"); done
  NAME_TOKENS=( ${(u)NAME_TOKENS} )
  logMe INFO "Scanning ${APP_PATH:t:r}: bundle id $BUNDLE_ID, Team ID ${TEAM_ID:-none}, name match ${NAME_TOKENS:-off}"
  G_BID[$g]="$BUNDLE_ID"; G_TEAM[$g]="$TEAM_ID"

  add_item $g "$APP_PATH" a
  for r in "$USER_HOME/Library" "/Library"; do
    for s in $LIBSUBS; do
      dir="$r/$s"; [[ -d "$dir" ]] || continue
      for child in "$dir"/*(N); do classify "$child"; [[ -n "$REPLY" ]] && add_item $g "$child" $REPLY; done
    done
  done
  for dir in $SYSONLY; do
    for child in "$dir"/*(N); do classify "$child"; [[ -n "$REPLY" ]] && add_item $g "$child" $REPLY; done
  done

  # Installer receipts: the package ids, and files they installed whose path names the app
  (( ${#ALL_PKGS} )) || ALL_PKGS=( ${(f)"$(/usr/sbin/pkgutil --pkgs 2>/dev/null)"} )
  local -a pkgs=()
  for pkg in $ALL_PKGS; do
    plow="${pkg:l}"; keep=0
    [[ -n "$BUNDLE_ID" && "$plow" == *"${BUNDLE_ID:l}"* ]] && keep=1
    (( keep )) || { name_hit "$plow" && keep=1; }
    (( keep )) || continue
    pkgs+=("$pkg")
    info="$(/usr/sbin/pkgutil --pkg-info "$pkg" 2>/dev/null)"
    vol="$(print -r -- "$info" | /usr/bin/awk -F': ' '/^volume:/{print $2}')"; [[ -z "$vol" ]] && vol="/"
    loc="$(print -r -- "$info" | /usr/bin/awk -F': ' '/^location:/{print $2}')"
    for f in ${(f)"$(/usr/sbin/pkgutil --files "$pkg" --only-files 2>/dev/null)"}; do
      full="${vol%/}/${loc:+${loc#/}/}$f"
      [[ "$full" == "$APP_PATH"/* || ! -e "$full" ]] && continue
      flow="${full:l}"; keep=0
      [[ "$flow" == *"${BUNDLE_ID:l}"* ]] && keep=1
      (( keep )) || { name_hit "$flow" && keep=1; }
      (( keep )) && add_item $g "$full" r
    done
  done
  G_PKGS[$g]="${(j: :)pkgs}"
}

# drop_nested -> removes items that sit inside another item (removing the parent covers them)
drop_nested() {
  local -a g p c; local i j n=${#IT_P} inside
  for (( i=1; i<=n; i++ )); do
    inside=0
    for (( j=1; j<=n; j++ )); do (( i != j )) && [[ "${IT_P[i]}" == "${IT_P[j]}"/* ]] && { inside=1; break; }; done
    (( inside )) || { g+=("${IT_G[i]}"); p+=("${IT_P[i]}"); c+=("${IT_C[i]}"); }
  done
  IT_G=("${g[@]}"); IT_P=("${p[@]}"); IT_C=("${c[@]}"); IT_KB=(); for i in $IT_P; do IT_KB+=(0); done
}

# size_items -> IT_KB (du -sk each item; the app itself counts its whole bundle)
size_items() {
  local i n=${#IT_P}
  for (( i=1; i<=n; i++ )); do
    [[ -s "$CANCEL_FILE" ]] && return 1
    spin_status "${IT_P[i]}" "$i of $n files" "$i/$n" "Measuring"
    IT_KB[i]=$(/usr/bin/du -sk "${IT_P[i]}" 2>/dev/null | /usr/bin/awk '{print $1}'); [[ "${IT_KB[i]}" == <-> ]] || IT_KB[i]=0
  done
}

# tilde <path> -> REPLY = the path with the home folder as ~
tilde() { REPLY="$1"; [[ "$REPLY" == "$USER_HOME"/* ]] && REPLY="~${REPLY#$USER_HOME}"; }

# write_review -> $REVIEW_FILE rows and ORDER (item index of each I row, in the order shown)
#   G  group  name  version  path  running  itemCount
#   I  group  path  name  where  KB  kind(a|h|r)  checked
write_review() {
  : > "$REVIEW_FILE"; ORDER=()
  local g i chk n; local -a idx
  for (( g=1; g<=${#G_PATH}; g++ )); do
    idx=(); for (( i=1; i<=${#IT_P}; i++ )); do (( IT_G[i] == g )) && idx+=($i); done
    (( ${#idx} )) || continue
    # the app first, then biggest first
    idx=( ${(f)"$(for i in $idx; do print -r -- "$([[ ${IT_C[i]} == a ]] && print 1 || print 0) ${IT_KB[i]} $i"; done | /usr/bin/sort -k1,1nr -k2,2nr | /usr/bin/awk '{print $3}')"} )
    print -r -- "G"$'\t'"$g"$'\t'"${G_NAME[g]}"$'\t'"${G_VER[g]}"$'\t'"${G_PATH[g]}"$'\t'"${G_RUN[g]}"$'\t'"${#idx}" >> "$REVIEW_FILE"
    for i in $idx; do
      chk=1; [[ "${IT_C[i]}" == r && "$NAME_MATCHES_CHECKED" != true ]] && chk=0
      tilde "${IT_P[i]:h}"
      print -r -- "I"$'\t'"$g"$'\t'"${IT_P[i]}"$'\t'"${IT_P[i]:t}"$'\t'"$REPLY"$'\t'"${IT_KB[i]}"$'\t'"${IT_C[i]}"$'\t'"$chk" >> "$REVIEW_FILE"
      ORDER+=($i)
    done
  done
}

# --- Review window --------------------------------------------------------------------------------
# Every app and its files, grouped. Each group header has a checkbox for the whole app (mixed when
# only some files are checked), the app icon, version, file count, whether it's open, and the size
# of what's checked. Each file row: checkbox, icon, name, where it is, a "Name match" tag when it
# was found by name only, its size, and a button to show it in Finder. A live total and the Remove
# button update as boxes are ticked. Prints the checked row numbers ("0,1,4") or __CANCEL__.
show_review() {
  local s="$SCRATCH/review.jxa"
  {
    win_prelude
    print -r -- "var DATA=\"$(as_esc "$REVIEW_FILE")\", RTITLE=\"$(as_esc "$REVIEW_TITLE")\", RMSG=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$PREVIEW_MESSAGE" || print -r -- "$REVIEW_MESSAGE")")\", RNOTE=\"$(as_esc "$REVIEW_NOTE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\";"
    print -r -- "var L_REMOVE=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$previewButton" || print -r -- "$removeButton")")\", L_CANCEL=\"$(as_esc "$cancelButton")\", DRY=$DRY_RUN, L_BACK=\"$(as_esc "$backButton")\", CAN_BACK=$USE_PICKER;"
    /bin/cat <<'JXA'
var GR=[], ITEMS=[];
readLines(DATA).forEach(function(l){ var r=l.split("\t");
 if(r[0]=="G") GR.push({g:r[1],name:r[2],ver:r[3],path:r[4],run:r[5]=="1",items:[]});
 else if(r[0]=="I"){ var it={g:r[1],path:r[2],name:r[3],where:r[4],kb:+r[5]||0,kind:r[6],on:r[7]=="1",i:ITEMS.length}; ITEMS.push(it);
  for(var k=GR.length-1;k>=0;k--) if(GR[k].g==it.g){ GR[k].items.push(it); break; } } });

if(!$.UNRev){ObjC.registerSubclass({name:'UNRev',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'back:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(2);}},
 'item:':{types:['void',['id']],implementation:function(s){ refresh(); }},
 'row:':{types:['void',['id']],implementation:function(s){ var cb=ITEMS[s.tag].cb; cb.state=ObjC.unwrap(cb.state)==1?0:1; refresh(); }},
 'group:':{types:['void',['id']],implementation:function(s){ var g=GR[s.tag], all=g.items.every(function(it){return ObjC.unwrap(it.cb.state)==1;});
   g.items.forEach(function(it){ it.cb.state=all?0:1; }); refresh(); }},
 'reveal:':{types:['void',['id']],implementation:function(s){ reveal(ITEMS[s.tag].path); }}}});}
var hd=$.UNRev.alloc.init;

// ---- sizes and positions ----
var W=820, PAD=24, BH=(BNAME?96:84), GH=58, IH=40, GAP=8;
var CH=GR.reduce(function(a,g){ return a+GH+g.items.length*IH+GAP; },0)+4;
var LH=Math.min(Math.max(CH,220),440)+10;
var PBW=150, RBW=190, PBH=34, PBY=18, NOTEH=32, noteY=PBY+PBH+12, listY=noteY+NOTEH+10, msgY=listY+LH+12, MSGH=20;
var H=msgY+MSGH+14+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR;
var cv=win.contentView;
var nItems=ITEMS.length, subt=GR.length+(GR.length==1?" app":" apps")+"  ·  "+nItems+(nItems==1?" item":" items")+" found";
header(cv,W,H,BH,PAD,RTITLE,subt,DRY?"Preview only — nothing will be removed":"",DRY?"eye.fill":"");

// Instruction on the left; what the "Name match" tag means on the right
var ml=label(RMSG,PAD+2,msgY,W-2*PAD-260,MSGH,13,$.NSFontWeightMedium); cv.addSubview(ml);
var TAGF=$.NSFont.systemFontOfSizeWeight(9.5,$.NSFontWeightBold), WARN=DARK?C([1,0.62,0.04]):C([0.70,0.33,0.0]);
function tag(x,y,parent){ var t="NAME MATCH", w=tw(t,TAGF)+14;
 var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,16)); b.boxType=4; b.titlePosition=0; b.cornerRadius=8; b.borderWidth=0;
 b.fillColor=WARN.colorWithAlphaComponent(DARK?0.22:0.14); parent.addSubview(b);
 var l=label(t,x,y+1.5,w,13,9.5,$.NSFontWeightBold,1); l.font=TAGF; l.textColor=WARN; parent.addSubview(l);
 l.toolTip="Found because its name contains the app's name — check that it belongs to this app"; return w; }
var lgT="= found by name only", lgF=$.NSFont.systemFontOfSizeWeight(11.5,$.NSFontWeightRegular), lgw=tw(lgT,lgF);
if(ITEMS.some(function(it){return it.kind=="r";})){
 var lgl=label(lgT,W-PAD-lgw-2,msgY+1,lgw+4,17,11.5); lgl.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(lgl);
 tag(W-PAD-lgw-2-8-(tw("NAME MATCH",TAGF)+14),msgY+2,cv); }

// The list
var LW=W-2*PAD;
cv.addSubview(rbox(PAD,listY,LW,LH,G(0.08),12));
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,listY+5,LW,LH-10)); sv.drawsBackground=false; sv.borderType=0;
sv.scrollerStyle=1; sv.autohidesScrollers=true; cv.addSubview(sv);
var SVH=LH-10, DH=Math.max(SVH,CH), doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,DH)); sv.documentView=doc;
sv.hasVerticalScroller=(DH>SVH);
var SZW=84, RVW=28, NF=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightMedium), MONO=$.NSFont.monospacedDigitSystemFontOfSizeWeight(12.5,$.NSFontWeightSemibold);
var y=DH-4;
GR.forEach(function(g,gi){
 // group header
 y-=GH;
 doc.addSubview(rbox(6,y+3,LW-12,GH-6,G(DARK?0.10:0.07),10));
 var mb=$.NSButton.alloc.initWithFrame($.NSMakeRect(16,y+(GH-20)/2,22,20)); mb.setButtonType(3); mb.allowsMixedState=true; mb.title="";
 mb.target=hd; mb.action='group:'; mb.tag=gi; try{ mb.contentTintColor=ACCENT; }catch(e){} doc.addSubview(mb); g.cb=mb;
 var ic=$.NSWorkspace.sharedWorkspace.iconForFile(g.path); if(!$.NSFileManager.defaultManager.fileExistsAtPath(g.path)) ic=iconFor(g.path);
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(44,y+(GH-40)/2,40,40)); iv.setImage(ic); iv.imageScaling=3; doc.addSubview(iv);
 var gx=94, gw=LW-gx-SZW-130;
 var gn=label(g.name,gx,y+GH/2+1,gw,19,14.5,$.NSFontWeightBold); gn.font=rounded(14.5,$.NSFontWeightBold); doc.addSubview(gn);
 var bits=[]; if(g.ver) bits.push("Version "+g.ver); bits.push(g.items.length+(g.items.length==1?" item":" items"));
 if(g.run) bits.push("Open now — it will be quit first");
 var gs=label(bits.join("  ·  "),gx,y+GH/2-17,gw+120,16,11.5); gs.textColor=g.run?WARN:$.NSColor.secondaryLabelColor; doc.addSubview(gs);
 var gz=label("",LW-16-SZW-RVW-150,y+(GH-20)/2,150+SZW,20,14,$.NSFontWeightBold,2); gz.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(14,$.NSFontWeightBold); gz.textColor=ACCENT; doc.addSubview(gz); g.size=gz;
 // its files
 g.items.forEach(function(it,k){
  y-=IH;
  if(k>0) doc.addSubview(rbox(98,y+IH-0.5,LW-98-16,1,G(0.13)));
  clickArea(40,y,LW-40-RVW-20,IH,hd,'row:',it.i,doc,false);
  var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(46,y+(IH-20)/2,22,20)); cb.setButtonType(3); cb.title=""; cb.state=it.on?1:0;
  cb.target=hd; cb.action='item:'; cb.tag=it.i; try{ cb.contentTintColor=ACCENT; }catch(e){} doc.addSubview(cb); it.cb=cb;
  var fi=iconFor(it.path); if(isOk(fi)){ var fv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(72,y+(IH-22)/2,22,22)); fv.setImage(fi); fv.imageScaling=3; doc.addSubview(fv); }
  var tagW=(it.kind=="r")?tw("NAME MATCH",TAGF)+14+10:0, nx=102, nw=LW-nx-16-RVW-SZW-tagW-12;
  var nl=label(it.kind=="a"?it.name+"  (the app)":it.name,nx,y+IH/2,nw,17,12.5,$.NSFontWeightMedium); nl.font=NF; nl.cell.lineBreakMode=5; doc.addSubview(nl);
  var wl=label(it.where,nx,y+IH/2-15,nw,15,11); wl.cell.lineBreakMode=5; wl.textColor=$.NSColor.secondaryLabelColor; doc.addSubview(wl);
  nl.toolTip=it.path; wl.toolTip=it.path;
  if(tagW) tag(LW-16-RVW-SZW-tagW,y+(IH-16)/2,doc);
  var sl=label(it.kb?fmt(it.kb):"—",LW-16-RVW-SZW,y+(IH-17)/2,SZW,17,12.5,$.NSFontWeightSemibold,2); sl.font=MONO; doc.addSubview(sl);
  var rv=sym("magnifyingglass.circle.fill",LW-16-RVW+6,y+(IH-20)/2,20,ACCENT.colorWithAlphaComponent(0.85)); if(rv) doc.addSubview(rv);
  var rb=clickArea(LW-16-RVW,y,RVW+8,IH,hd,'reveal:',it.i,doc,true); rb.toolTip="Show in Finder";
 });
 y-=GAP;
});
sv.contentView.scrollToPoint($.NSMakePoint(0,DH-SVH)); sv.reflectScrolledClipView(sv.contentView);   // start at the top

// Footer
var nt=wrapLabel(RNOTE,PAD+40,noteY,W-2*PAD-80,NOTEH,11.5,1); nt.textColor=$.NSColor.secondaryLabelColor;
if(DRY){ nt.stringValue=DNOTE; nt.textColor=ACCENT; nt.font=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); }   // dry run: say so plainly
cv.addSubview(nt);
var BKW=120, sumX=PAD+4+(CAN_BACK?BKW+16:0);   // Back (only when the user picked the apps) sits bottom-left
var summary=label("",sumX,PBY+(PBH-18)/2,W-PAD-PBW-RBW-24-sumX,18,13,$.NSFontWeightSemibold); cv.addSubview(summary);
var pc=pill(L_CANCEL,W-PAD-RBW-12-PBW,PBY,PBW,PBH,hd,'no:','\u001b',false);
if(CAN_BACK){ var pb=pill("‹  "+L_BACK,PAD,PBY,BKW,PBH,hd,'back:',null,false); pb.btn.toolTip="Back to the list of apps"; }
var pr=pill("",W-PAD-RBW,PBY,RBW,PBH,hd,'ok:','\r',true);

function refresh(){
 var n=0, kb=0;
 GR.forEach(function(g){ var on=0, gkb=0;
  g.items.forEach(function(it){ if(ObjC.unwrap(it.cb.state)==1){ on++; gkb+=it.kb; } });
  g.cb.state = on==g.items.length ? 1 : (on==0 ? 0 : -1);
  g.size.stringValue = on ? fmt(gkb) : "Keep";
  g.size.textColor = on ? ACCENT : $.NSColor.secondaryLabelColor;
  n+=on; kb+=gkb; });
 summary.stringValue = n ? (n+(n==1?" item":" items")+"  ·  "+fmt(kb)+(DRY?" would be freed":" will be freed")) : "Nothing selected";
 summary.textColor = n ? $.NSColor.labelColor : $.NSColor.secondaryLabelColor;
 var t=L_REMOVE.replace("{N}",n); if(n==1) t=t.replace(/Items\b/,"Item").replace(/items\b/,"item"); pr.set(t); pr.enable(n>0);
}
refresh();
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
var out=[]; ITEMS.forEach(function(it){ if(ObjC.unwrap(it.cb.state)==1) out.push(it.i); });
resp==2 ? "__BACK__" : ((resp==1 && out.length) ? out.join(",") : "__CANCEL__");
JXA
  } > "$s"
  run_window "$s"
}

# --- Removing -------------------------------------------------------------------------------------
USER_TRASH="$USER_HOME/.Trash"
# trash_item <path> -> moves it into the user's Trash, owned by them (mv + chown, not Finder Apple
# Events, which TCC blocks from root). Sets TRASH_DEST. 0 = ok.
trash_item() {
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to move $1 to the Trash."; return 1; }
  local base="${1:t}"
  [[ -d "$USER_TRASH" ]] || { /bin/mkdir -p "$USER_TRASH" 2>/dev/null; (( amRoot )) && /usr/sbin/chown "$targetUser" "$USER_TRASH" 2>/dev/null; }
  TRASH_DEST="$USER_TRASH/$base"
  if [[ -e "$TRASH_DEST" ]]; then   # never clobber: add the time, like Finder ("MACE.app" -> "MACE 10.58.09.app")
    local stamp="$(/bin/date '+%H.%M.%S')"
    # keep a real extension (files, and bundles like .app that have a Contents folder); folders named
    # like "com.vendor.app" get the time at the end
    if [[ -n "${base:e}" ]] && [[ -f "$1" || -d "$1/Contents" ]]; then
      TRASH_DEST="$USER_TRASH/${base:r} $stamp.${base:e}"
    else TRASH_DEST="$USER_TRASH/$base $stamp"; fi
    local n=2; while [[ -e "$TRASH_DEST" ]]; do TRASH_DEST="${TRASH_DEST% #*} #$n"; (( n++ )); done
  fi
  /bin/mv -f "$1" "$TRASH_DEST" 2>/dev/null || return 1
  (( amRoot )) && /usr/sbin/chown -R "$targetUser":staff "$TRASH_DEST" 2>/dev/null
  [[ -e "$TRASH_DEST" ]]
}

# quit_app <group #> -> asks the app to quit, waits up to 10s, then force-quits what's left
quit_app() {
  [[ "$DRY_RUN" == true ]] && return 0   # preview never quits apps
  local g=$1 p="${G_PATH[$1]}" n=0
  is_running "$p" || return 0
  logMe INFO "Quitting ${G_NAME[g]}…"
  run_as_user /usr/bin/osascript -e "tell application id \"${G_BID[g]}\" to quit" >/dev/null 2>&1
  while (( n++ < 20 )); do PS_CACHE=""; is_running "$p" || return 0; /bin/sleep 0.5; done
  logMe WARN "${G_NAME[g]} didn't quit — force-quitting it."
  /usr/bin/pkill -9 -f "$p/Contents/" 2>/dev/null; PS_CACHE=""
}

# remove_selected -> removes SEL (item indexes). Sets FREED_KB, REMOVED_N, FAILED_N, REMOVED_APPS
# pace_until <EPOCHREALTIME start> <seconds> -> wait until that many seconds have passed since start.
# Removing a few files takes a blink; this keeps each step on screen long enough to read.
pace_until() { local left=$(( $2 - (EPOCHREALTIME - $1) )); (( left > 0.01 )) && /bin/sleep $(printf '%.2f' $left); return 0; }

remove_selected() {
  FREED_KB=0; REMOVED_N=0; FAILED_N=0; REMOVED_APPS=()
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: removal skipped."; return 0; }   # belt and braces
  local -A gsel; local i m g k=0 n=${#SEL}
  for i in $SEL; do gsel[${IT_G[i]}]=1; done
  for g in ${(k)gsel}; do quit_app $g; done
  # stop launchd jobs that are about to be removed
  for i in $SEL; do m="${IT_P[i]}"
    case "$m" in
      /Library/LaunchDaemons/*.plist) /bin/launchctl bootout system "$m" 2>/dev/null ;;
      */LaunchAgents/*.plist) [[ -n "$targetUID" ]] && /bin/launchctl bootout gui/"$targetUID" "$m" 2>/dev/null ;;
    esac
  done
  # show each item for a moment so the user sees it work: about 2.5s in all at most (0.5s each for a
  # few items); with lots of items there's no waiting, since the list already takes time to go through.
  local step=$(( 2.5 / n )) t0; (( step > 0.5 )) && step=0.5; (( step < 0.05 )) && step=0
  for i in $SEL; do
    m="${IT_P[i]}"; (( k++ )); t0=$EPOCHREALTIME
    spin_status "$m" "$k of $n items" "$(( k - 1 ))/$n" "Removing"
    [[ -e "$m" || -L "$m" ]] || { logMe INFO "  already gone: $m"; continue; }
    case "$m" in
      "$USER_HOME"/*|/Applications/*)   # the user's files + the app itself -> the user's Trash
        if trash_item "$m"; then logMe INFO "  trashed: $m  ->  $TRASH_DEST"
        elif /bin/rm -rf "$m" 2>/dev/null && [[ ! -e "$m" ]]; then logMe INFO "  removed (couldn't trash): $m"
        else logMe ERROR "  FAILED: $m"; (( FAILED_N++ )); continue; fi ;;
      *)                                # system files (/Library, receipts) -> deleted
        if /bin/rm -rf "$m" 2>/dev/null && [[ ! -e "$m" ]]; then logMe INFO "  removed (system): $m"
        else logMe ERROR "  FAILED: $m$( (( amRoot )) || print " (needs root)")"; (( FAILED_N++ )); continue; fi ;;
    esac
    (( REMOVED_N++ )); (( FREED_KB += IT_KB[i] ))
    [[ "${IT_C[i]}" == a ]] && REMOVED_APPS+=("${G_NAME[${IT_G[i]}]}")
    pace_until $t0 $step
  done
  # forget the installer receipts of the apps that were removed
  if [[ "$FORGET_RECEIPTS" == true ]]; then
    for i in $SEL; do
      [[ "${IT_C[i]}" == a && ! -e "${IT_P[i]}" ]] || continue
      for m in ${(s: :)G_PKGS[${IT_G[i]}]}; do
        /usr/sbin/pkgutil --forget "$m" >/dev/null 2>&1 && logMe INFO "  forgot receipt: $m"
      done
    done
  fi
}

# join_names a b c -> "a, b and c"
join_names() {
  case $# in 0) REPLY="" ;; 1) REPLY="$1" ;; 2) REPLY="$1 and $2" ;; *) REPLY="${(j:, :)@[1,-2]} and ${@[-1]}" ;; esac
}

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
   if(FPATH){ \$.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs(\$([\$.NSURL.fileURLWithPath(FPATH)]));
     try{ var fa=\$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.finder");   // Finder in front of this window
       if(fa.count>0){ fa=fa.objectAtIndex(0); try{ \$.NSApplication.sharedApplication.yieldActivationToApplication(fa); }catch(e){} fa.activateWithOptions(3); } }catch(e){} } }}}});
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

# UN_LIB=1 source Self_Service_App_Uninstaller.sh  -> loads the functions without running anything (testing).
[[ -n "$UN_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "App Uninstaller $SCRIPT_VERSION — mode=${ACTION_MODE}$([[ $DRY_RUN == true ]] && print " (DRY RUN — nothing will be removed)"); user=${targetUser}; running as $(/usr/bin/id -un)"
(( amRoot )) || logMe INFO "Not running as root — system files (/Library) can't be removed (run via Jamf or with sudo)."
if [[ "$ACTION_MODE" == verbose && -z "$consoleUser" ]] && (( amRoot )); then
  logMe INFO "No one is logged in, so there's no one to show the windows to. Nothing removed."; exit 0
fi
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

cancelled() { kill_spinner; logMe INFO "User cancelled. Nothing removed."; exit 0; }
EXIT_CODE=0

# Steps 1-3 run in a loop so Back on the review window returns to the app picker (with the same
# apps still checked) and the scan runs again for the new choice.
USE_PICKER=false; [[ -n "${TARGET_APPS//[[:space:],]/}" ]] || USE_PICKER=true
PICKED=""          # the picker rows checked last time ("0,3"), so Back keeps them checked
while true; do
# start each pass clean
TARGETS=(); G_PATH=(); G_NAME=(); G_BID=(); G_VER=(); G_RUN=(); G_PKGS=(); G_TEAM=()
IT_G=(); IT_P=(); IT_C=(); IT_KB=(); SEEN=(); SEL=(); ORDER=(); : > "$CANCEL_FILE"; PS_CACHE=""

# --- 1. Which apps -----------------------------------------------------------------------------
typeset -a TARGETS
if [[ "$USE_PICKER" == false ]]; then
  for t in "${(@s:,:)TARGET_APPS}"; do
    t="${${t##[[:space:]]#}%%[[:space:]]#}"; [[ -n "$t" ]] || continue
    if resolve_app "$t"; then TARGETS+=("$REPLY"); logMe INFO "App \"$t\" -> $REPLY"
    else logMe ERROR "Could not find a single app matching \"$t\" — skipping it."; EXIT_CODE=1; fi
  done
else
  [[ "$ACTION_MODE" == silent ]] && { logMe ERROR "Silent mode needs the app(s) to remove in Parameter 4."; exit 1; }
  (( ${#PICK_APPS} )) || build_picker
  if (( ! ${#PICK_APPS} )); then
    show_message "$PICKER_TITLE" "checkmark.circle.fill" ok "There are no apps you can remove\nApps that came with macOS and apps your IT team manages can't be removed here." ""
    exit 0
  fi
  out="$(show_picker)"
  [[ "$out" == "__CANCEL__" || -z "$out" || "$out" != [0-9,]## ]] && { logMe INFO "User closed the app picker. Nothing removed."; exit 0; }
  PICKED="$out"
  for i in ${(s:,:)out}; do TARGETS+=("${PICK_APPS[$(( i + 1 ))]}"); done
  logMe INFO "User picked: ${(j:, :)${TARGETS[@]:t:r}}"
fi

# Safety checks on each app, then the groups the review shows
typeset -aU TARGETS
REFUSED=()
for a in $TARGETS; do
  app_meta "$a"
  if [[ -z "$M_BID" ]];                then logMe ERROR "${a:t:r} has no bundle id — skipping it."; REFUSED+=("${a:t:r}"); continue; fi
  if [[ "${M_BID:l}" == com.apple.* ]]; then logMe ERROR "${a:t:r} is an Apple app ($M_BID) — refusing to remove it."; REFUSED+=("${a:t:r}"); continue; fi
  if is_protected "$a" "$M_BID";        then logMe ERROR "${a:t:r} is PROTECTED ($M_BID) — refusing to remove it."; REFUSED+=("${a:t:r}"); continue; fi
  G_PATH+=("$a"); G_NAME+=("${a:t:r}"); G_VER+=("$M_VER"); G_RUN+=("$(is_running "$a" && print 1 || print 0)")
done
(( ${#REFUSED} )) && EXIT_CODE=1
if (( ! ${#G_PATH} )); then
  join_names "${REFUSED[@]}"
  show_message "$PICKER_TITLE" "xmark.octagon.fill" fail "${REPLY:-That app} can't be removed here\nIt's an Apple app or one your IT team manages, or it couldn't be found. Contact IT if you need it removed." ""
  exit 1
fi

# --- 2. Find each app's files --------------------------------------------------------------------
show_spinner "$SCAN_TITLE"
SECONDS=0; N=${#G_PATH}
for (( g=1; g<=N; g++ )); do
  [[ -s "$CANCEL_FILE" ]] && cancelled
  spin_status "${G_PATH[g]}" "$g of $N app$( (( N > 1 )) && print s)" "$(( g - 1 ))/$N" "Scanning"
  scan_app $g "${G_PATH[g]}"
done
drop_nested
size_items || cancelled
[[ -s "$CANCEL_FILE" ]] && cancelled
spin_status "Getting the list ready…" "" "1/1" "Scanning"
total_kb=0; for k in $IT_KB; do (( total_kb += k )); done
logMe INFO "Found ${#IT_P} item(s), $(human_kb $total_kb), in ${SECONDS}s:"
for (( i=1; i<=${#IT_P}; i++ )); do logMe INFO "  [${IT_C[i]:u}] ${G_NAME[${IT_G[i]}]}: ${IT_P[i]} ($(human_kb ${IT_KB[i]}))"; done

# --- 3. What to remove -----------------------------------------------------------------------------
typeset -a SEL
if [[ "$ACTION_MODE" == verbose ]]; then
  write_review
  kill_spinner
  out="$(show_review)"
  if [[ "$out" == "__BACK__" ]]; then logMe INFO "User went back to the app list."; continue; fi
  [[ "$out" == "__CANCEL__" || -z "$out" || "$out" != [0-9,]## ]] && { logMe INFO "User cancelled the review (or kept everything). Nothing removed."; exit 0; }
  for i in ${(s:,:)out}; do SEL+=(${ORDER[$(( i + 1 ))]}); done
  logMe INFO "User confirmed ${#SEL} of ${#IT_P} item(s)."
else
  for (( i=1; i<=${#IT_P}; i++ )); do
    [[ "${IT_C[i]}" == (a|h) || ( "${IT_C[i]}" == r && "$SILENT_NAME_MATCHES" == true ) ]] && SEL+=($i)
  done
  logMe INFO "Silent mode: removing ${#SEL} item(s) ($([[ $SILENT_NAME_MATCHES == true ]] && print "including" || print "not including") name matches)."
fi
break
done
(( ${#SEL} )) || { logMe INFO "Nothing selected. Nothing removed."; exit $EXIT_CODE; }
sel_kb=0; sel_apps=(); for i in $SEL; do (( sel_kb += IT_KB[i] )); [[ ${IT_C[i]} == a ]] && sel_apps+=("${G_NAME[${IT_G[i]}]}"); done

if [[ "$DRY_RUN" == true ]]; then
  logMe INFO "DRY RUN — nothing changed. Would remove ${#SEL} item(s), $(human_kb $sel_kb):"
  for i in $SEL; do logMe INFO "  would remove: ${IT_P[i]}"; done
  join_names "${sel_apps[@]}"
  show_message "$DRY_TITLE" "eye.circle.fill" ok "Preview only — nothing was removed\nRemoving ${REPLY:-these items} (${#SEL} item$( (( ${#SEL} > 1 )) && print s)) would free $(human_kb $sel_kb)." ""
  exit $EXIT_CODE
fi

# --- 4. Remove ---------------------------------------------------------------------------------
show_spinner "$REMOVING_TITLE" nocancel
/bin/sleep 0.6                      # let the window appear before the first item goes
remove_selected
spin_status "Cleaning up…" "${#SEL} of ${#SEL} items" "1/1" "Finishing"
/bin/sleep 0.8                      # let the bar reach the end before the result window
kill_spinner
logMe INFO "Done: removed $REMOVED_N of ${#SEL} item(s), freed $(human_kb $FREED_KB), $FAILED_N failure(s)."
join_names "${REMOVED_APPS[@]}"
if (( FAILED_N == 0 )); then
  if (( ${#REMOVED_APPS} )); then head="Removed $REPLY"; else head="Removed $REMOVED_N leftover item$( (( REMOVED_N > 1 )) && print s)"; fi
  show_message "$DONE_TITLE" "checkmark.circle.fill" ok "$head\nFreed $(human_kb $FREED_KB). Your files are in the Trash if you need them back." ""
else
  EXIT_CODE=1
  show_message "Some Items Weren't Removed" "exclamationmark.triangle.fill" fail "$FAILED_N item$( (( FAILED_N > 1 )) && print "s" ) couldn't be removed\nRemoved $REMOVED_N of ${#SEL} and freed $(human_kb $FREED_KB). Contact IT if you need help." ""
fi
exit $EXIT_CODE
