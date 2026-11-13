#!/bin/zsh

####################################################################################################
#
# Disk Usage
#
# Purpose: Shows the user (and IT) what is filling up the Mac's disk. Scans the data volume once,
#          then shows how full the disk is, what the space is used by (your home folder, apps, other
#          users, macOS and system data), the biggest items, and simple ways to free up space. Every
#          item can be shown in Finder with one click, and the full report can be saved to the Desktop.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
#       Inspired by Dan Snelson's "Disk Usage with swiftDialog" (https://snelson.us).
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service (the user clicks it, watches the scan, gets the results window):
#     • Leave the script as-is (HEADLESS=false). Set Jamf Parameter 4 to "verbose" or leave blank.
#
#   Headless / automated (no windows — the report goes to the policy log):
#     • Set Jamf Parameter 4 to "silent"  (OR set HEADLESS=true in the Config block below).
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose or silent)
#   Parameter 5 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 6 Label:  Banner Color (hex, optional)
#   Parameter 7 Label:  Brand Name (optional)
#   Parameter 8 Label:  Appearance (auto, light, or dark)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Action Mode   verbose = show the progress + results windows (default)
#                       silent  = scan quietly, no windows; the report is printed to the policy log
#     $5  Brand Icon    logo for the windows. Blank = BRAND_ICON from the Config block.
#                       examples: /Library/Application Support/Acme/logo.png
#                                 /Applications/Self Service.app
#                                 https://acme.com/logo.png
#                                 sf:internaldrive.fill
#                                 selfservice   (your Jamf Self Service branding logo)
#     $6  Banner Color  hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                       "auto-dark" (deeper logo shade for white text). Blank = bannerColor below.
#     $7  Brand Name    small line above the banner title, e.g. "Acme IT Support".
#     $8  Appearance    auto (follow the user's Light/Dark setting), light, or dark.
# ---------------------------------------------------------------------------------------------
#
# TESTING:
#   ./Disk_Usage.sh                      # windows, as you (some protected folders can't be measured)
#   sudo ./Disk_Usage.sh                 # windows, as root (measures everything, like Jamf does)
#   sudo ./Disk_Usage.sh silent          # no windows, report printed to the terminal
#   ./Disk_Usage.sh verbose "sf:internaldrive.fill" "#1F6FEB" "Acme IT Support" dark
#   ./Disk_Usage.sh demo                 # made-up sample data (getting low) — see how it all looks
#   ./Disk_Usage.sh demo-full            # sample data, almost out of space   (demo-ok = plenty free)
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 11/12/26 - Original Release - native rewrite of the swiftDialog "Disk Usage" Self Service
#               script: one-pass scan with live progress and Cancel, used/free ring, breakdown bar,
#               biggest items (click to show in Finder), ways to free up space, Storage Settings
#               button, Save Report, silent mode, branding + light/dark like Collect User Logs and
#               Network Health Check. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # false = do whatever Jamf Parameter 4 says (verbose or silent).
                        # true  = ALWAYS run silently with no windows, no matter what $4 says.

# DEMO / SIMULATION ---------------------------------------------------------
SIMULATE="off"          # off  = measure this Mac (normal)
                        # low / full / ok = skip the scan and show made-up sample data (big files,
                        #        folders, apps, an iPhone backup, Docker…) so you can see how everything
                        #        looks: low = "Space is getting low", full = "Almost out of space",
                        #        ok = "Plenty of free space". Nothing on the Mac is measured or changed.
                        # Same as running:  ./Disk_Usage.sh demo   (or demo-full / demo-ok)

# WHAT IT SHOWS -------------------------------------------------------------
BIG_ITEMS_SHOWN=7       # rows visible at once in the "Biggest items" list (it scrolls for more)
BIG_ITEMS_MAX=30        # how many items each tab (All / Files / Folders / Apps) holds; the report lists 25
TIPS_SHOWN=5            # most "Ways to free up space" rows in the window
MIN_ITEM_MB=100         # items smaller than this are never listed (also keeps the scan light)
TIP_MIN_MB=500          # a "free up space" tip only shows when it would free at least this much

# WHEN TO WARN --------------------------------------------------------------
# The ring and headline turn yellow / red when free space drops below EITHER limit.
WARN_FREE_PERCENT=20    # yellow "Space is getting low" below this % free ...
WARN_FREE_GB=30         # ... or below this many GB free
CRIT_FREE_PERCENT=10    # red "Almost out of space" below this % free ...
CRIT_FREE_GB=15         # ... or below this many GB free

# WHERE IT GOES -------------------------------------------------------------
# "Save Report" writes a text report to the logged-in user's Desktop. Tokens are filled in:
#   {USER} = short name   {SERIAL} = device serial   {STAMP} = date/time in STAMP_FORMAT below
REPORT_NAME_PATTERN="DiskUsage_{USER}_{SERIAL}_{STAMP}.txt"
STAMP_FORMAT="%Y-%m-%d_%H-%M"   # e.g. 2026-11-12_10-40. If the name exists, _2, _3… is added.
logFile="/var/log/disk_usage.log"     # this script's own run log

# BRANDING (verbose mode only) ----------------------------------------------
BRAND_NAME="IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($7)
BRAND_ICON=""              # optional logo ($5). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:internaldrive.fill             (tinted to match the theme)
                           #   • Self Service   selfservice (or: ss) — your Jamf Self Service branding logo
                           # Blank = no logo.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto = follow the user's Light/Dark setting; light or dark forces one. ($8)

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto".
bannerColor="auto"         # banner + Done button ($6). auto = the logo's exact main colour;
                           # auto-dark = a deeper shade of it for white text; no logo = #0056D2
BANNER_TEXT_COLOR="auto"   # auto = white, or near-black if the banner is too light for white
ACCENT_COLOR="auto"        # spinner, progress bar, icons, buttons. auto = the banner colour, made readable
SPINNER_BG_COLOR="auto"    # auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # "Report Saved" icon. auto = Apple green
FAIL_COLOR="auto"          # error icon. auto = Apple red

# TEXT ----------------------------------------------------------------------
SPINNER_TEXT="Checking Disk Space"
RESULT_TITLE="Disk Usage"
SAVED_TITLE="Disk Report Saved"
okButton="Done"
saveButton="Save Report"
storageButton="Storage Settings"
cancelButton="Cancel"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent
zmodload zsh/stat 2>/dev/null

SCRIPT_VERSION="1.0"
SCRATCH="/tmp/disk-usage.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$DU_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # DU_DEBUG=1 keeps the scratch folder (testing)
STATUS_FILE="$SCRATCH/status.txt"    # the progress window polls this
CANCEL_FILE="$SCRATCH/cancel.flag"   # the Cancel button writes here (the window runs as the user)
: > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"
RAW_FILE="$SCRATCH/raw.tsv"          # every item >= MIN_ITEM_MB:  KB <tab> path
UNIT_FILE="$SCRATCH/units.tsv"       # the total of each scanned unit
PROG_FILE="$SCRATCH/progress.tsv"    # scan job -> foreground: KB done <tab> current path
DATA_FILE="$SCRATCH/results.tsv"     # rows for the results window
REPORT_FILE="$SCRATCH/report.txt"

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point ($1 "/"), computer name ($2) and user ($3) first; strip that trio.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
ACTION_MODE="${1:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
DEMO=""; SIMULATE="${SIMULATE:l}"; [[ "$SIMULATE" == (low|full|ok) ]] && DEMO="$SIMULATE"
case "$ACTION_MODE" in demo|demo-low|simulate) DEMO=low ;; demo-full) DEMO=full ;; demo-ok) DEMO=ok ;; esac
[[ "$ACTION_MODE" != "silent" ]] && ACTION_MODE="verbose"
[[ -n "$2" ]] && BRAND_ICON="$2"
[[ -n "$3" ]] && bannerColor="$3"
[[ -n "$4" ]] && BRAND_NAME="$4"
[[ -n "$5" ]] && APPEARANCE="$5"
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
USER_HOME=$(/usr/bin/dscl . -read /Users/"$targetUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="/Users/$targetUser"

[[ "$HEADLESS" == true ]] && ACTION_MODE="silent"
# Nobody logged in? Then there's no one to show windows to, so run silently.
[[ -z "$consoleUser" ]] && (( amRoot )) && ACTION_MODE="silent"

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
  { print -r -- "ObjC.import('Cocoa'); ObjC.import('CoreGraphics');"; brand_jxa; /bin/cat <<'EOF'
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

# Update the live progress window: 1 = folder being measured, 2 = amount measured, 3 = "done/total" (KB)
spin_status() {
  print -rl -- "$1" "$2" "$3" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}

# --- Progress window ----------------------------------------------------------------------------
# Same branded header as the other windows (logo, brand name, rounded title) with a Cancel pill,
# then a colourful arc spinner, the folder being measured (as a chip), a progress bar, the percent
# and the amount measured so far. A 0.3s timer re-reads $STATUS_FILE; a 30fps timer animates.
SPIN_SCPT="$SCRATCH/spin.jxa"
show_spinner() {
  [[ "$ACTION_MODE" == "verbose" ]] || return 0
  {
    print -r -- "ObjC.import('Cocoa'); ObjC.import('CoreGraphics');"
    print -r -- "var STATUS=\"$(as_esc "$STATUS_FILE")\", CANCEL=\"$(as_esc "$CANCEL_FILE")\", CANCEL_L=\"$(as_esc "$cancelButton")\", STITLE=\"$(as_esc "$SPINNER_TEXT")\";"
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
if(!$.DUCancel){ObjC.registerSubclass({name:'DUCancel',superclass:'NSObject',methods:{
 'cancel:':{types:['void',['id']],implementation:function(b){
   $("1").writeToFileAtomicallyEncodingError(CANCEL,false,$.NSUTF8StringEncoding,null);
   b.enabled=false; cancelLbl.stringValue="Cancelling…"; cancelPill.alphaValue=0.6; cancelLbl.alphaValue=0.7; }}}});}
var ch=$.DUCancel.alloc.init;
var CBW=96, CBH=28, cbx=W-CBW-16, cby=H-BH+(BH-CBH)/2;
var cancelPill=$.NSBox.alloc.initWithFrame($.NSMakeRect(cbx,cby,CBW,CBH)); cancelPill.boxType=4; cancelPill.titlePosition=0; cancelPill.cornerRadius=CBH/2;
cancelPill.fillColor=BTXT.colorWithAlphaComponent(0.20); cancelPill.borderWidth=1; cancelPill.borderColor=BTXT.colorWithAlphaComponent(0.45); cv.addSubview(cancelPill);
var cancelLbl=label(cbx,cby+(CBH-17)/2,CBW,17,12.5,true,1); cancelLbl.stringValue=CANCEL_L; cancelLbl.font=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); cancelLbl.textColor=BTXT; cv.addSubview(cancelLbl);
var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(cbx,cby,CBW,CBH)); cb.title=""; cb.bordered=false; cb.transparent=true;
cb.target=ch; cb.action='cancel:'; cb.keyEquivalent=$("\u001b"); cv.addSubview(cb);
// Spinner: a rotating arc whose tail shifts to a neighbouring hue and fades out, over a faint track ring.
var aC=ACCENT.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace), AH=aC.hueComponent, AS=aC.saturationComponent, AB=aC.brightnessComponent;
function hsb(h,sa,br,al){ return $.NSColor.colorWithHueSaturationBrightnessAlpha(((h%1)+1)%1, Math.min(1,sa), Math.min(1,br), al); }
var SEGS=48, SWEEP=290, spinA=90;
var WBG=DARK?C([0.165,0.165,0.17]):C([0.925,0.925,0.93]), SAT=Math.max(AS,0.85);
var ARC=[]; for(var i=0;i<SEGS;i++){ var t=i/(SEGS-1);
 var col=hsb(AH+0.22*(1-t), SAT, Math.min(1,Math.max(AB,0.75)*(0.92+0.12*t)), 1);
 ARC.push(WBG.blendedColorWithFractionOfColor(Math.pow(t,1.35)*0.92+0.08, col)); }
var TRACK=ACCENT.colorWithAlphaComponent(DARK?0.16:0.12);
if(!$.ArcSpin){ ObjC.registerSubclass({name:'ArcSpin',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
 var b=this.bounds, c=$.NSMakePoint(b.size.width/2,b.size.height/2), R=b.size.width/2-5, LW=5;
 var tr=$.NSBezierPath.bezierPath; tr.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,R,0,360); tr.lineWidth=LW; TRACK.setStroke; tr.stroke;
 var step=SWEEP/SEGS;
 for(var i=0;i<SEGS;i++){ var st=spinA+SWEEP-i*step, en=st-step*1.15;
  var pth=$.NSBezierPath.bezierPath; pth.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,R,st,en,true);
  pth.lineWidth=LW; pth.lineCapStyle=0; ARC[i].setStroke; pth.stroke; }
 var ha=(spinA)*Math.PI/180, hx=c.x+R*Math.cos(ha), hy=c.y+R*Math.sin(ha);
 var dot=$.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(hx-LW/2,hy-LW/2,LW,LW)); ARC[SEGS-1].setFill; dot.fill;
 }}}}); }
var SPS=60, arcView=$.ArcSpin.alloc.initWithFrame($.NSMakeRect((W-SPS)/2,spinCY-SPS/2,SPS,SPS)); cv.addSubview(arcView);
// The folder being measured, as a chip (monospaced, accent-tinted)
var CX=40, CW=W-80;
var fchip=$.NSBox.alloc.initWithFrame($.NSMakeRect(CX,chipY,CW,chipH)); fchip.boxType=4; fchip.titlePosition=0; fchip.cornerRadius=8;
fchip.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.14:0.09); fchip.borderWidth=1; fchip.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.35:0.28); cv.addSubview(fchip);
var fic=$.NSImageView.alloc.initWithFrame($.NSMakeRect(CX+12,chipY+(chipH-16)/2,18,16));
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
 if(f!==lastChip){ lastChip=f; var isPath=(f.charAt(0)=="/"||f.charAt(0)=="~");
  fic.image=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(isPath?"folder":(f.toLowerCase().indexOf("report")>=0?"doc.text":"internaldrive"),""); folder.font=isPath?MONO:UIF; }
 var m=(L[2]||"").match(/^(\d+)\/(\d+)$/); if(m){ var d=+m[1], t=+m[2]; barTarget=t?Math.min(0.99,d/t):0; }
 step.setStringValue(barTarget>=0.99 && !m ? "Finishing up" : ("Measuring · "+Math.floor(barTarget*100)+"%")); }
applyStatus(); setBar(barTarget);
if(!$.SpinTick){ObjC.registerSubclass({name:'SpinTick',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(s){ applyStatus(); }},
 'spin:':{types:['void',['id']],implementation:function(s){ spinA=(spinA-12+360)%360; arcView.needsDisplay=true;
   if(Math.abs(barTarget-barCur)>0.002) setBar(barCur+(barTarget-barCur)*0.07); }}}});}
var tk=$.SpinTick.alloc.init;
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

# --- Results window -------------------------------------------------------------------------
# Banner, then: a ring showing how full the disk is (green / yellow / red) with the free space in
# the middle, a headline, a bar showing what the space is used by, the biggest items (click one to
# show it in Finder), and ways to free up space. Buttons: Storage Settings, Save Report, Done.
# Prints "save" or "done".
show_results() {
  local rscpt="$SCRATCH/results.jxa"
  {
    print -r -- "ObjC.import('Cocoa'); ObjC.import('CoreGraphics');"
    print -r -- "var VISROWS=${BIG_ITEMS_SHOWN:-7};"
    print -r -- "var DATA=\"$(as_esc "$DATA_FILE")\", RTITLE=\"$(as_esc "$RESULT_TITLE")\", SUBT=\"$(as_esc "$RUN_SUBTITLE")\", DCHIP=\"$(as_esc "$DISK_CHIP")\", NOTE=\"$(as_esc "$RESULT_NOTE")\";"
    print -r -- "var HEAD=\"$(as_esc "$HEAD")\", SUBHEAD=\"$(as_esc "$SUBHEAD")\", STATUS=\"$DISK_STATUS\", USED_FRAC=$USED_FRAC, FREE_KB=$(( DISK_FREE / 1024 ));"
    print -r -- "var L_OK=\"$(as_esc "$okButton")\", L_SAVE=\"$(as_esc "$saveButton")\", L_STORAGE=\"$(as_esc "$storageButton")\";"
    brand_jxa; palette_jxa
    print -r -- "var logo=brandImg(), BNAME=\"$(as_esc "$BRAND_NAME")\";"
    ui_common_jxa
    /bin/cat <<'JXA'
function rgb(a,al){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(a[0]/255,a[1]/255,a[2]/255,al==null?1:al);}
function hex(s){s=s.replace('#','');return [parseInt(s.substr(0,2),16),parseInt(s.substr(2,2),16),parseInt(s.substr(4,2),16)];}
function G(a){return $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5,0.5,0.5,a);}
// Status colours: darker shades in light mode so text on the window stays 4.5:1 readable.
var STAT=DARK?{good:'#34C759',ok:'#FFD60A',bad:'#FF6961'}:{good:'#146C2E',ok:'#7D5B00',bad:'#C4000F'};
var SC=rgb(hex(STAT[STATUS]||STAT.good));
// Breakdown colours: home = brand accent, the rest fixed Apple-style hues that read in both modes
// Breakdown colours, like System Settings > Storage: each kind of personal stuff has its own colour;
// the system parts are grey (System Data striped, macOS solid), so personal vs system is obvious.
var WINBG=DARK?C([0.165,0.165,0.17]):C([0.925,0.925,0.93]);
var CATC=DARK?{docs:'#409CFF',photos:'#FF9F0A',media:'#FF375F',mail:'#64D2FF',dev:'#30D158',backup:'#7D7AFF',trash:'#AC8E68',users:'#9AAFD0',apps:'#BF5AF2',sysdata:'#48484A',macos:'#8E8E93'}
             :{docs:'#0062CC',photos:'#C25E00',media:'#D70040',mail:'#0071A4',dev:'#1E7B34',backup:'#3634A3',trash:'#7F6545',users:'#56688A',apps:'#8944AB',sysdata:'#B4B4B9',macos:'#7C7C80'};
var HATCH=rgb(hex(DARK?'#6E6E73':'#D8D8DC'));
// paint one part of the bar (or a legend dot) into the current drawing context
function segPaint(r,s){ s.col.setFill; $.NSBezierPath.fillRect(r);
 if(s.key=="sysdata"){ $.NSGraphicsContext.saveGraphicsState; $.NSBezierPath.clipRect(r); var ln=$.NSBezierPath.bezierPath; ln.lineWidth=1.6;
  for(var x=r.origin.x-r.size.height; x<r.origin.x+r.size.width; x+=5){ ln.moveToPoint($.NSMakePoint(x,r.origin.y)); ln.lineToPoint($.NSMakePoint(x+r.size.height,r.origin.y+r.size.height)); }
  HATCH.setStroke; ln.stroke; $.NSGraphicsContext.restoreGraphicsState; } }
function dotImg(s){ var im=$.NSImage.alloc.initWithSize($.NSMakeSize(12,12)); im.lockFocus;
 $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(0,0,12,12)).addClip; segPaint($.NSMakeRect(0,0,12,12),s); im.unlockFocus; return im; }
function fmt(kb){ var b=kb*1024, u=["bytes","KB","MB","GB","TB"], i=0; while(b>=1000&&i<4){ b/=1000; i++; }
 return i==0 ? Math.round(b)+" bytes" : (b>=100?Math.round(b):b.toFixed(1))+" "+u[i]; }
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
 var t=$.NSBezierPath.bezierPath;t.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,r,0,360);t.lineWidth=12;G(0.18).setStroke;t.stroke;
 if(frac>0){var p=$.NSBezierPath.bezierPath;p.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,r,90,90-359.9*Math.min(1,frac),true);
  p.lineWidth=12;p.lineCapStyle=1;col.setStroke;p.stroke;}
 img.unlockFocus;return img;}
// The breakdown bar: one rounded bar, each part as wide as its share of the disk, free space as the track
function stackImg(w,h,segs,totalKB){var img=$.NSImage.alloc.initWithSize($.NSMakeSize(w,h));img.lockFocus;
 $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(0,0,w,h),h/2,h/2).addClip;
 G(0.18).setFill; $.NSBezierPath.fillRect($.NSMakeRect(0,0,w,h));
 var x=0; segs.forEach(function(s){ var sw=w*s.kb/totalKB; if(sw<=0) return; segPaint($.NSMakeRect(x,0,sw,h),s);
  x+=sw; WINBG.setFill; $.NSBezierPath.fillRect($.NSMakeRect(x-1,0,1.5,h)); });   // a thin gap between parts
 img.unlockFocus;return img;}

var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var REV=[];
// Put Finder in front of this window after showing an item (macOS otherwise opens it behind us).
// bringFinder(): put the Finder window that was just opened in front of this one. Asks Finder to come forward;
// when macOS won't hand it the focus (run by Jamf / sudo, or because this window is modal), this window steps
// back to sit just below Finder's window, so the item shown is always visible and nothing else is covered.
function bringFinder(){ try{ var app=$.NSApplication.sharedApplication;
 var fa=$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.apple.finder"); if(!(fa.count>0)) return; fa=fa.objectAtIndex(0);
 try{ app.yieldActivationToApplication(fa); }catch(e){}
 var ok=false; try{ ok=fa.activateFromApplicationOptions($.NSRunningApplication.currentApplication,0); }catch(e){} if(!ok) fa.activateWithOptions(1|2);
 $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.4));
 var w=app.keyWindow; if(!w || w.isNil()) w=app.modalWindow; if(!w || w.isNil()) return;
 var fw=0, pid=fa.processIdentifier, l=ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1|16,0));   // Finder's top window
 for(var i=0;i<l.count;i++){ var d=l.objectAtIndex(i);
  if(ObjC.unwrap(d.objectForKey("kCGWindowOwnerPID"))==pid && ObjC.unwrap(d.objectForKey("kCGWindowLayer"))==0){ fw=ObjC.unwrap(d.objectForKey("kCGWindowNumber")); break; } }
 w.level=0; if(fw) w.orderWindowRelativeTo(-1,fw); else w.orderBack(null); }catch(e){} }
if(!$.DURes){ObjC.registerSubclass({name:'DURes',superclass:'NSObject',methods:{
 'done:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'save:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(3);}},
 'reveal:':{types:['void',['id']],implementation:function(s){ var p=REV[s.tag], fm=$.NSFileManager.defaultManager;
   while(p && p!="/" && !fm.fileExistsAtPath(p)) p=p.replace(/\/[^\/]*$/,"")||"/";   // gone (or demo)? show the nearest folder that exists
   if(p){ $.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs($([$.NSURL.fileURLWithPath(p)])); bringFinder(); } }},
 'tab:':{types:['void',['id']],implementation:function(s){ var k=s.selectedSegment; PANES.forEach(function(p,i){ p.hidden=(i!=k); }); }},
 'storage:':{types:['void',['id']],implementation:function(s){ var ws=$.NSWorkspace.sharedWorkspace;   // macOS 13+: System Settings > Storage; older: Storage Management
   if(!ws.openURL($.NSURL.URLWithString("x-apple.systempreferences:com.apple.settings.Storage"))) ws.openFile("/System/Library/CoreServices/Applications/Storage Management.app"); }}}});}
// A borderless button with the pointing-hand cursor, laid over a row so the whole row is clickable
if(!$.DULink){ObjC.registerSubclass({name:'DULink',superclass:'NSButton',methods:{'resetCursorRects':{implementation:function(){
 this.addCursorRectCursor(this.bounds,$.NSCursor.pointingHandCursor); }}}});}
var hd=$.DURes.alloc.init;
var PANES=[];
function link(x,y,w,h,path,tip,parent){ if(!path) return; REV.push(path);
 var b=$.DULink.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); b.title=""; b.bordered=false; b.transparent=true;
 b.tag=REV.length-1; b.target=hd; b.action='reveal:'; b.toolTip=tip||path; (parent||cv).addSubview(b); }

var rows=readLines(DATA).map(function(l){return l.split("\t");});
var segs=rows.filter(function(r){return r[0]=="B";}).map(function(r){return {name:r[1],kb:+r[2],key:r[3],grp:r[4]||"sys",col:rgb(hex(CATC[r[3]]||'#8E8E93'))};}).filter(function(s){return s.kb>0;});
// Legend layout (worked out before the window size): your stuff first, then a new row for apps + system + free.
var LF=$.NSFont.systemFontOfSizeWeight(12,$.NSFontWeightMedium);
function tw(s,f){ return Math.ceil($(s).sizeWithAttributes($.NSDictionary.dictionaryWithObjectForKey(f||LF,$.NSFontAttributeName)).width); }
var LEG=segs.concat([{name:"Free",kb:FREE_KB,key:"free",grp:"sys",col:G(DARK?0.38:0.22)}]), LHW=920-26-(26+6+150+34), LROWS=1;
(function(){ var x=0, prev=null; LEG.forEach(function(s){ s.t=s.name+"  "+fmt(s.kb); s.w=tw(s.t)+28;
  if(x>0 && (x+s.w>LHW || (prev && prev.grp=="you" && s.grp!="you"))){ x=0; LROWS++; }
  s.lx=x; s.lr=LROWS-1; x+=s.w; prev=s; }); })();
var SETS={all:[],files:[],folders:[],apps:[]};
rows.forEach(function(r){ if(r[0]=="I" && SETS[r[1]]) SETS[r[1]].push({name:r[2],where:r[3],kb:+r[4],path:r[5],kind:r[6]||""}); });
var NROWS=Math.max(1,Math.min(VISROWS,Math.max(SETS.all.length,SETS.files.length,SETS.folders.length,SETS.apps.length)));
// Finder icon for an item; if it isn't there (deleted since the scan, or demo data), the icon for its kind.
function iconFor(p,kind){ var ws=$.NSWorkspace.sharedWorkspace; if($.NSFileManager.defaultManager.fileExistsAtPath(p)) return ws.iconForFile(p);
 var n=p.split("/").pop(), ext=n.indexOf(".")>0 ? n.split(".").pop().toLowerCase() : "";
 if(kind=="a"||ext=="app") return ws.iconForFileType("com.apple.application-bundle");
 if(kind=="d") return ws.iconForFileType("public.folder");
 return ws.iconForFileType(ext || "public.data"); }
var tips=rows.filter(function(r){return r[0]=="T";}).map(function(r){return {icon:r[1],title:r[2],text:r[3],kb:+r[4],size:r[5],path:r[6]};});

// ---- sizes and positions ----
var W=920, BH=(BNAME?96:84), PAD=26, HERO=Math.max(168,146+20*(LROWS-1)), IRH=42, TRH=58, HDR=46;
var hasTips=tips.length>0, CG=16;
var LW=hasTips?Math.round((W-2*PAD-CG)*0.58):W-2*PAD, RW=W-2*PAD-CG-LW;
var cardH=Math.max(HDR+NROWS*IRH+10, hasTips?HDR+tips.length*TRH+10:0);
var NOTEH=NOTE?22:0, PBW=150, PBH=34, PBY=18;
var H=BH+16+HERO+16+cardH+12+NOTEH+PBH+PBY+12;

var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true;win.titleVisibility=1;win.movableByWindowBackground=true;
win.appearance=APPEAR;
var WINBG=DARK?C([0.165,0.165,0.17]):C([0.925,0.925,0.93]);
var cv=win.contentView;

// Banner: a left-aligned header (logo, brand name, title, computer name) with a disk chip on the right.
cv.addSubview(brandFill($.NSMakeRect(0,H-BH,W,BH),false)); bannerShade(cv,W,H,BH);
var LS=56, btx=PAD;
if(logo){ var blv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(PAD,H-BH+(BH-LS)/2,LS,LS)); blv.setImage(logo); blv.imageScaling=3; if(BI_S) blv.contentTintColor=BTXT; cv.addSubview(blv); btx=PAD+LS+16; }
var CHF=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold);
var chw=DCHIP?Math.ceil($(DCHIP).sizeWithAttributes($.NSDictionary.dictionaryWithObjectForKey(CHF,$.NSFontAttributeName)).width)+46:0, CHH=30;
var tw0=W-btx-PAD-(chw?chw+16:0), hasEb=!!BNAME;
var tY=hasEb ? H-BH+(BH-62)/2+16 : H-BH+(BH-48)/2+16;       // title baseline area; eyebrow above, computer name below
if(hasEb){ var bnl=label(BNAME.toUpperCase(),btx,tY+30,tw0,15,11,$.NSFontWeightSemibold,0); bnl.font=rounded(11,$.NSFontWeightBold); bnl.textColor=BTXT; bnl.alphaValue=0.75; cv.addSubview(bnl); }
var tl=label(RTITLE,btx,tY,tw0,30,24,$.NSFontWeightBold,0); tl.font=rounded(24,$.NSFontWeightBold); tl.textColor=BTXT; cv.addSubview(tl);
var st=label(SUBT,btx,tY-17,tw0,17,12.5,$.NSFontWeightMedium,0); st.textColor=BTXT; st.alphaValue=0.8; cv.addSubview(st);
if(chw){ var cx=W-PAD-chw, cy=H-BH+(BH-CHH)/2;
 var chip=$.NSBox.alloc.initWithFrame($.NSMakeRect(cx,cy,chw,CHH)); chip.boxType=4; chip.titlePosition=0; chip.cornerRadius=CHH/2;
 chip.fillColor=BTXT.colorWithAlphaComponent(0.16); chip.borderWidth=1; chip.borderColor=BTXT.colorWithAlphaComponent(0.35); cv.addSubview(chip);
 var di=sym("internaldrive.fill",cx+12,cy+(CHH-16)/2,16,BTXT); if(di) cv.addSubview(di);
 var dl=label(DCHIP,cx+34,cy+(CHH-17)/2,chw-40,17,12.5,$.NSFontWeightSemibold,0); dl.font=CHF; dl.textColor=BTXT; cv.addSubview(dl); }

// Top: the ring (how full the disk is) with the free space inside, headline, breakdown bar + legend
var heroY=H-BH-16-HERO, RS=150, rx=PAD+6, ry=heroY+(HERO-RS)/2;
var rv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(rx,ry,RS,RS)); rv.setImage(ring(RS,USED_FRAC,SC)); cv.addSubview(rv);
var fv=label(fmt(FREE_KB),rx,ry+RS/2-10,RS,34,26,$.NSFontWeightBold,1); fv.font=rounded(26,$.NSFontWeightBold); cv.addSubview(fv);
var fl=label("FREE",rx,ry+RS/2-30,RS,18,11,$.NSFontWeightSemibold,1); fl.textColor=SC; cv.addSubview(fl);
var hx=rx+RS+34, hw=W-hx-PAD;
var HT=heroY+HERO;   // top of the section; laid out downward from here
var hl=label(HEAD,hx,HT-38,hw,28,21,$.NSFontWeightBold); hl.textColor=(STATUS=="good")?$.NSColor.labelColor:SC; cv.addSubview(hl);
var shl=wrapLabel(SUBHEAD,hx,HT-78,hw,38,13); shl.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(shl);
var totKB=segs.reduce(function(a,s){return a+s.kb;},0)+FREE_KB;
var bar=$.NSImageView.alloc.initWithFrame($.NSMakeRect(hx,HT-104,hw,14)); bar.imageScaling=0; bar.setImage(stackImg(hw,14,segs,Math.max(1,totKB))); cv.addSubview(bar);
LEG.forEach(function(s){ if(s.kb<=0) return; var lx=hx+s.lx, ly=HT-132-20*s.lr;
 var dv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(lx-1,ly+2,12,12)); dv.setImage(dotImg(s)); cv.addSubview(dv);
 var l=label(s.t,lx+16,ly,s.w-16,17,12,$.NSFontWeightMedium); l.font=LF; l.toolTip=s.grp=="you"?"Yours":"System"; cv.addSubview(l); });

// Cards
var cardY=heroY-16-cardH;
// Biggest items: Finder icon, name, where it is, a size bar, the size. Click a row to show it in Finder.
cv.addSubview(rbox(PAD,cardY,LW,cardH,G(0.08),12));
cv.addSubview(label("Biggest items",PAD+16,cardY+cardH-32,160,18,13,$.NSFontWeightSemibold));
// All / Files / Apps: each tab is its own pane of rows; only the selected one is shown.
var TABS=[["all","All","No large items were found."],["files","Files","No single file over 100 MB was found."],["folders","Folders","No folder over 100 MB was found."],["apps","Apps","No app over 100 MB was found."]];
var seg=$.NSSegmentedControl.segmentedControlWithLabelsTrackingModeTargetAction($(TABS.map(function(t){return t[1];})),0,hd,'tab:');
seg.controlSize=1; seg.sizeToFit; var sgw=Math.max(240,seg.frame.size.width);
seg.frame=$.NSMakeRect(PAD+LW-16-sgw,cardY+cardH-36,sgw,22); seg.selectedSegment=0;
try{ seg.selectedSegmentBezelColor=ACCENT; }catch(e){}
seg.toolTip="Click an item to show it in Finder"; cv.addSubview(seg);
var BARW=110, SZW=76, PH=cardH-HDR-4;   // each tab = a scrolling list over the rows area of the card
TABS.forEach(function(t,ti){
 var items=SETS[t[0]], DH=Math.max(PH,items.length*IRH);
 var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,cardY+6,LW,PH)); sv.hasVerticalScroller=(DH>PH); sv.autohidesScrollers=true;
 sv.drawsBackground=false; sv.borderType=0; sv.scrollerStyle=1; sv.hidden=(ti>0); cv.addSubview(sv); PANES.push(sv);
 var pane=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,DH)); sv.documentView=pane;
 sv.contentView.scrollToPoint($.NSMakePoint(0,DH-PH)); sv.reflectScrolledClipView(sv.contentView);   // start at the top
 if(!items.length){ var nl=label(t[2],0,DH/2-10,LW,18,12.5,$.NSFontWeightRegular,1); nl.textColor=$.NSColor.secondaryLabelColor; pane.addSubview(nl); return; }
 var maxKB=items[0].kb||1;
 items.forEach(function(it,i){
  var y=DH-(i+1)*IRH;
  if(i>0) pane.addSubview(rbox(54,y+IRH,LW-54-14,1,G(0.15)));
  var ic=iconFor(it.path,it.kind);
  if(isOk(ic)){ var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(14,y+(IRH-30)/2,30,30)); iv.setImage(ic); iv.imageScaling=3; pane.addSubview(iv); }
  var sx=LW-14-SZW, bx=sx-10-BARW, nx=54, nw=bx-12-nx;
  pane.addSubview(label(it.name,nx,y+IRH/2+1,nw,17,13,$.NSFontWeightSemibold));
  var wl=label(it.where,nx,y+IRH/2-16,nw,15,11); wl.cell.lineBreakMode=5; wl.textColor=$.NSColor.secondaryLabelColor; pane.addSubview(wl);
  pane.addSubview(rbox(bx,y+IRH/2-3,BARW,6,G(0.18),3));
  pane.addSubview(rbox(bx,y+IRH/2-3,Math.max(6,BARW*it.kb/maxKB),6,ACCENT,3));
  var sl=label(fmt(it.kb),sx,y+(IRH-18)/2,SZW,18,13,$.NSFontWeightSemibold,2); sl.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(13,$.NSFontWeightSemibold); pane.addSubview(sl);
  link(6,y,LW-12,IRH,it.path,it.path+"  (click to show in Finder)",pane);
 });
});
// Ways to free up space: icon, what it is, how much, and what to do about it. Click to show it in Finder.
if(hasTips){ var x2=PAD+LW+CG;
 cv.addSubview(rbox(x2,cardY,RW,cardH,G(0.08),12));
 cv.addSubview(label("Ways to free up space",x2+16,cardY+cardH-32,RW-32,18,13,$.NSFontWeightSemibold));
 tips.forEach(function(t,i){
  var y=cardY+cardH-HDR-(i+1)*TRH;
  if(i>0) cv.addSubview(rbox(x2+44,y+TRH,RW-44-14,1,G(0.15)));
  var ic=sym(t.icon,x2+14,y+TRH-26,20,ACCENT); if(ic) cv.addSubview(ic);
  cv.addSubview(label(t.title,x2+44,y+TRH-25,RW-44-14-84,17,13,$.NSFontWeightSemibold));
  var sl=label(t.size,x2+RW-14-84,y+TRH-25,84,17,13,$.NSFontWeightSemibold,2); sl.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(13,$.NSFontWeightSemibold); sl.textColor=ACCENT; cv.addSubview(sl);
  var tx=wrapLabel(t.text,x2+44,y+4,RW-44-14,30,11.5); tx.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(tx);
  link(x2+6,y,RW-12,TRH,t.path,t.path?("Show "+t.title+" in Finder"):"");
 });
}

// Note + buttons
if(NOTE){ var nt=label(NOTE,PAD,PBY+PBH+12,W-2*PAD,16,11,$.NSFontWeightRegular,1); nt.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(nt); }
// All three buttons are the same pill. Done (Return key) is filled with the banner colour; the others are accent-tinted.
function pill(t,x,act,key,primary){
 if(primary) cv.addSubview(brandFill($.NSMakeRect(x,PBY,PBW,PBH),true));
 else { var bx=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,PBY,PBW,PBH)); bx.boxType=4; bx.titlePosition=0; bx.cornerRadius=PBH/2;
   bx.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.20:0.12); bx.borderWidth=1; bx.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.45:0.35); cv.addSubview(bx); }
 var lb=label(t,x,PBY+(PBH-18)/2,PBW,18,13,$.NSFontWeightSemibold,1); lb.textColor=primary?BTXT:ACCENT; cv.addSubview(lb);
 var b=$.NSButton.alloc.initWithFrame($.NSMakeRect(x,PBY,PBW,PBH)); b.title=""; b.bordered=false; b.transparent=true;
 b.target=hd; b.action=act; if(key) b.keyEquivalent=$(key); cv.addSubview(b); return b; }
pill(L_STORAGE,PAD,'storage:',null,false);
pill(L_SAVE,W-PAD-PBW-12-PBW,'save:',null,false);
pill(L_OK,W-PAD-PBW,'done:','\r',true);

win.center;win.makeKeyAndOrderFront(null);app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win);win.orderOut(null);
resp==3?"save":"done";
JXA
  } > "$rscpt"
  /bin/chmod 644 "$rscpt" "$DATA_FILE" 2>/dev/null
  run_as_user /usr/bin/osascript -l JavaScript "$rscpt" 2>>"$SCRATCH/jxa-err.log"
}

# --- Scanning -----------------------------------------------------------------------------
# One pass over the data volume (where everything except macOS itself lives). The big structural
# folders (the volume, /Users, the home folder, ~/Library and its Containers / Application Support,
# /Library, /private, /Applications) are opened up and each thing inside is measured on its own,
# so the progress bar moves steadily and we know every one of their sizes. `du -x` never leaves the
# volume. Packages (.app, Photos libraries, VM bundles…) count as one item and aren't opened.
DATA_ROOT=""; [[ -d /System/Volumes/Data/Users ]] && DATA_ROOT="/System/Volumes/Data"   # macOS 10.15+
SCAN_ROOT="${DATA_ROOT:-/}"
H_R="$DATA_ROOT$USER_HOME"                      # the home folder as seen on the data volume
PKG_RE='[.](app|bundle|framework|photoslibrary|musiclibrary|tvlibrary|photolibrary|aplibrary|vmwarevm|pvm|utm|sparsebundle|xcarchive|plugin|kext|appex|xpc|logarchive|docset|fcpbundle|imovielibrary|logicx|band)/'
typeset -A IS_EXP SZ MAXC
typeset -a UNITS EXPANDED SORTED BIG
for _e in "$SCAN_ROOT" "$DATA_ROOT/Users" "$H_R" "$H_R/Library" "$H_R/Library/Containers" "$H_R/Library/Group Containers" \
          "$H_R/Library/Application Support" "$DATA_ROOT/Library" "$DATA_ROOT/private" "$DATA_ROOT/private/var" "$DATA_ROOT/Applications"; do
  IS_EXP[$_e]=1
done

# npath <data-volume path> -> REPLY = the normal path (/System/Volumes/Data/Users/x -> /Users/x)
npath() { REPLY="${1#$DATA_ROOT}"; [[ -z "$REPLY" ]] && REPLY="/"; }
# dpath <data-volume path> -> REPLY = the path to show (home folder as ~)
dpath() { npath "$1"
  if [[ "$REPLY" == "$USER_HOME" ]]; then REPLY="~"
  elif [[ "$REPLY" == "$USER_HOME"/* ]]; then REPLY="~${REPLY#$USER_HOME}"; fi; }

add_units() {
  local d="$1" c dev; EXPANDED+=("$d")
  for c in "${d%/}"/*(DN); do
    [[ -L "$c" ]] && continue
    if [[ "$d" == "$SCAN_ROOT" ]]; then
      [[ -z "$DATA_ROOT" && "$c" == /System ]] && continue          # pre-Catalina: skip macOS itself
      if [[ -d "$c" ]]; then dev=$(zstat +device -- "$c" 2>/dev/null); [[ -n "$dev" && "$dev" != "$ROOT_DEV" ]] && continue; fi
    fi
    if [[ -d "$c" && -n "${IS_EXP[$c]}" ]]; then add_units "$c"; else UNITS+=("$c"); fi
  done
}

kill_tree() { local p; /bin/kill -STOP $1 2>/dev/null; for p in $(/usr/bin/pgrep -P $1); do kill_tree $p; done; /bin/kill -9 $1 2>/dev/null; }
cancelled() {
  logMe INFO "User cancelled the scan."
  kill_spinner; exit 0      # cancelling isn't an error, so Jamf shouldn't mark the policy as failed
}

scan_disk() {
  local u last p; local -i kb bg
  : > "$RAW_FILE"; : > "$UNIT_FILE"; print -r -- "0" > "$PROG_FILE"
  ROOT_DEV=$(zstat +device -- "$SCAN_ROOT" 2>/dev/null)
  UNITS=(); EXPANDED=(); add_units "$SCAN_ROOT"
  logMe INFO "Scanning $SCAN_ROOT: ${#UNITS} items, $(human_kb $VOL_USED_KB) used on the volume"
  (
    local -i dn=0
    for u in "${UNITS[@]}"; do
      [[ -s "$CANCEL_FILE" ]] && exit 0
      print -r -- "$dn"$'\t'"$u" > "$PROG_FILE"
      last=$(/usr/bin/du -xak -- "$u" 2>/dev/null | /usr/bin/awk -v m=$MIN_KB -v raw="$RAW_FILE" -v pk="$PKG_RE" \
        '{ if ($1+0 >= m && $0 !~ pk) print >> raw; l=$0 } END { if (l != "") print l }')
      [[ -n "$last" ]] && { print -r -- "$last" >> "$UNIT_FILE"; (( dn += ${last%%$'\t'*} )); }
    done
    print -r -- "$dn" > "$PROG_FILE"
  ) &
  bg=$!
  while /bin/kill -0 $bg 2>/dev/null; do
    if [[ -s "$CANCEL_FILE" ]]; then kill_tree $bg; cancelled; fi
    IFS=$'\t' read -r kb p < "$PROG_FILE" 2>/dev/null
    if [[ -n "$p" ]]; then dpath "$p"; spin_status "$REPLY" "$(human_kb $kb) measured" "$kb/$VOL_USED_KB"; fi
    /bin/sleep 0.25
  done
  wait $bg 2>/dev/null
  [[ -s "$CANCEL_FILE" ]] && cancelled
}

# --- Demo mode -------------------------------------------------------------------------------
# Made-up sample data, run through exactly the same analysis as a real scan, so you can see the
# drill-down, the tabs, the tips and the colours without filling a disk. Sizes are in GB.
#   where (H = the home folder, R = the data volume) | GB | f(ile)/d(irectory) | path
DEMO_LEAVES=(
  "H|64.4|f|Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  "H|31.7|d|Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E"
  "H|22.0|d|Movies/Wedding Footage"
  "H|9.1|d|Movies/Screen Recordings"
  "H|8.8|f|Movies/Vacation 2025.mov"
  "H|18.4|f|Pictures/Photos Library.photoslibrary"
  "H|13.1|f|Downloads/macOS Installer.dmg"
  "H|6.1|f|Downloads/Ubuntu-24.04.iso"
  "H|3.7|d|Downloads/Old Installers"
  "H|14.1|d|Library/Developer/Xcode/DerivedData"
  "H|4.5|d|Library/Developer/CoreSimulator"
  "H|5.7|f|Documents/Project Backup.zip"
  "H|4.2|d|Documents/Work"
  "H|3.2|d|Library/Caches/com.spotify.client"
  "H|2.1|d|Library/Caches/Google"
  "H|2.6|d|Library/Group Containers/UBF8T346G9.Office"
  "H|2.4|d|.Trash"
  "H|1.8|d|Library/Mail"
  "H|3.1|d|Library/Messages"
  "H|6.3|d|Music/Music Library"
  "H|7.5|d|Library/Mobile Documents/com~apple~CloudDocs"
  "R|12.5|d|Applications/Xcode.app"
  "R|6.2|d|Applications/GarageBand.app"
  "R|3.9|d|Applications/iMovie.app"
  "R|2.4|d|Applications/Microsoft Word.app"
  "R|1.6|d|Applications/Google Chrome.app"
  "R|0.6|d|Applications/Slack.app"
  "R|7.9|d|Users/alex/Movies"
  "R|2.2|d|Users/Shared/Installers"
  "R|16.0|f|private/var/vm/sleepimage"
  "R|9.0|d|System/Library/AssetsV2"
  "R|2.3|d|private/var/db"
  "R|1.0|d|Library/Application Support/GarageBand"
)
demo_disk() {   # a 500 GB disk, as full as the chosen level
  DISK_TOTAL=500000000000; VOL_NAME="Macintosh HD"; SNAPS=3; MACOS_KB=12207031
  case "$DEMO" in ok) DISK_FREE=286000000000 ;; full) DISK_FREE=11000000000 ;; *) DISK_FREE=86000000000 ;; esac
}
# demo_build: turns DEMO_LEAVES into what a real scan leaves behind (UNITS, EXPANDED, RAW_FILE,
# UNIT_FILE), adding every parent folder's size on the way up.
demo_build() {
  local spec base g t rel p a e; local -i kb; local -A ACC UNIT_OF
  FAKE_TYPE=(); UNITS=(); EXPANDED=("$SCAN_ROOT"); DEMO_KB=0
  : > "$RAW_FILE"; : > "$UNIT_FILE"
  for spec in "${DEMO_LEAVES[@]}"; do
    IFS='|' read -r base g t rel <<< "$spec"
    [[ "$base" == H ]] && p="$H_R/$rel" || p="${DATA_ROOT}/$rel"
    kb=$(( g * 976562.5 )); FAKE_TYPE[$p]=$t; a="$p"
    while :; do                          # walk up to the measured "unit" (child of an opened-up folder)
      (( ACC[$a] += kb )); [[ -n "${FAKE_TYPE[$a]}" ]] || FAKE_TYPE[$a]=d
      [[ -n "${IS_EXP[${a:h}]}" || "${a:h}" == "/" ]] && break
      a="${a:h}"
    done
    UNIT_OF[$a]=1; e="${a:h}"
    while [[ -n "${IS_EXP[$e]}" ]]; do (( ${EXPANDED[(Ie)$e]} )) || EXPANDED+=("$e"); [[ "$e" == "$SCAN_ROOT" ]] && break; e="${e:h}"; done
  done
  UNITS=( "${(@k)UNIT_OF}" )
  for a in "${(@k)ACC}"; do (( ACC[$a] >= MIN_KB )) && print -r -- "${ACC[$a]}"$'\t'"$a" >> "$RAW_FILE"; done
  typeset -gA DEMO_UKB=()
  for a in "${UNITS[@]}"; do print -r -- "${ACC[$a]}"$'\t'"$a" >> "$UNIT_FILE"; DEMO_UKB[$a]=${ACC[$a]}; (( DEMO_KB += ACC[$a] )); done
}
demo_scan() {   # a short pretend scan so the progress window can be seen too
  local u; local -i dn=0
  demo_build; VOL_USED_KB=$DEMO_KB
  logMe INFO "DEMO: simulating a scan of ${#UNITS} items ($(human_kb $DEMO_KB)) — nothing on this Mac is measured."
  for u in "${(@o)UNITS}"; do
    [[ -s "$CANCEL_FILE" ]] && cancelled
    dpath "$u"; spin_status "$REPLY" "$(human_kb $dn) measured" "$dn/$VOL_USED_KB"
    (( dn += DEMO_UKB[$u] ))
    [[ "$ACTION_MODE" == verbose ]] && /bin/sleep 0.3
  done
  print -r -- "$dn" > "$PROG_FILE"
}

# --- Working out what it all means ----------------------------------------------------------------
analyze() {
  local kb p q e; local -i k
  SZ=(); MAXC=()
  while IFS=$'\t' read -r kb p; do [[ -n "$p" ]] && SZ[$p]=$kb; done < "$RAW_FILE"
  while IFS=$'\t' read -r kb p; do [[ -n "$p" ]] && SZ[$p]=$kb; done < "$UNIT_FILE"
  # Opened-up folders weren't measured directly: add up what's inside them, deepest first.
  for e in "${EXPANDED[@]}"; do SZ[$e]=0; done
  for p in "${UNITS[@]}"; do [[ -n "${SZ[$p]}" ]] && (( SZ[${p:h}] += SZ[$p] )); done
  for e in "${(@f)$(for e in "${EXPANDED[@]}"; do print -r -- "${#${e//[^\/]/}}"$'\t'"$e"; done | /usr/bin/sort -t$'\t' -k1,1rn | /usr/bin/cut -f2-)}"; do
    [[ "$e" == "$SCAN_ROOT" || -z "$e" ]] && continue
    (( SZ[${e:h}] += SZ[$e] ))
  done
  MEASURED_KB=${SZ[$SCAN_ROOT]:-0}
  # Largest child of every folder (to find where the space really goes)
  for p in "${(@k)SZ}"; do
    [[ "$p" == "$SCAN_ROOT" ]] && continue
    q=${p:h}; (( ${MAXC[$q]:-0} < SZ[$p] )) && MAXC[$q]=${SZ[$p]}
  done
  # Everything >= MIN_ITEM_MB, biggest first
  SORTED=( "${(@f)$(for p in "${(@k)SZ}"; do (( SZ[$p] >= MIN_KB )) && print -r -- "${SZ[$p]}"$'\t'"$p"; done | /usr/bin/sort -t$'\t' -k1,1rn)}" )
  SORTED=( ${SORTED:#} )
  # Biggest items = the place where the space actually sits: an item no single thing inside makes
  # up half of (so we drill past ~/Library -> Containers -> com.docker.docker … to Docker.raw), that
  # isn't one of the structural folders, and doesn't overlap an item already picked.
  BIG=()
  local b skip
  for e in "${SORTED[@]}"; do
    p="${e#*$'\t'}"; k=${e%%$'\t'*}
    [[ -n "${IS_EXP[$p]}" || "$p" == "$SCAN_ROOT" ]] && continue
    (( ${MAXC[$p]:-0} * 2 >= k )) && continue
    skip=0; for b in "${BIG[@]}"; do [[ "$p" == "$b"/* || "$b" == "$p"/* ]] && { skip=1; break; }; done
    (( skip )) && continue
    BIG+=("$p"); (( ${#BIG} >= 60 )) && break
  done
  # What the space is used by
  HOME_KB=${SZ[$H_R]:-0}
  APPS_KB=${SZ[$DATA_ROOT/Applications]:-0}
  OTHERU_KB=$(( ${SZ[$DATA_ROOT/Users]:-0} - HOME_KB )); (( OTHERU_KB < 0 )) && OTHERU_KB=0
  SYS_KB=$(( (DISK_TOTAL - DISK_FREE) / 1024 - HOME_KB - APPS_KB - OTHERU_KB )); (( SYS_KB < 0 )) && SYS_KB=0
  # Categories, like System Settings > Storage. Most of ~/Library (caches, app data) counts as System
  # Data, as macOS does; the parts of it that are clearly yours (Mail, backups, iCloud Drive…) don't.
  local L="$H_R/Library"
  szk() { REPLY=${SZ[$1]:-0}; }
  local -i ph mm mail dev bk tr icl dock lib
  szk "$H_R/Pictures"; ph=$REPLY
  szk "$H_R/Music"; mm=$REPLY; szk "$H_R/Movies"; (( mm += REPLY ))
  szk "$L/Mail"; mail=$REPLY; szk "$L/Messages"; (( mail += REPLY ))
  szk "$H_R/.docker"; dock=$REPLY
  szk "$L/Developer"; dev=$REPLY; szk "$L/Containers/com.docker.docker"; (( dev += REPLY + dock ))
  szk "$L/Application Support/MobileSync"; bk=$REPLY
  szk "$H_R/.Trash"; tr=$REPLY
  szk "$L/Mobile Documents"; icl=$REPLY
  szk "$L"; lib=$REPLY
  CAT_DOCS=$(( HOME_KB - lib - ph - mm - tr - dock + icl )); (( CAT_DOCS < 0 )) && CAT_DOCS=0
  CAT_PHOTOS=$ph; CAT_MEDIA=$mm; CAT_MAIL=$mail; CAT_DEV=$dev; CAT_BACKUP=$bk; CAT_TRASH=$tr
  SYSDATA_KB=$(( (DISK_TOTAL - DISK_FREE) / 1024 - CAT_DOCS - ph - mm - mail - dev - bk - tr - OTHERU_KB - APPS_KB - MACOS_KB ))
  (( SYSDATA_KB < 0 )) && SYSDATA_KB=0
}

# item_name <data-volume path> -> REPLY = a friendly name for it
item_name() {
  case "$1" in
    "$H_R/.Trash") REPLY="Trash" ;;
    "$H_R") REPLY="Home folder" ;;
    *) REPLY="${1:t}"; [[ "$REPLY" == *.app ]] && REPLY="${REPLY%.app}" ;;
  esac
}

# Ways to free up space: well-known space hogs, only when they're at least TIP_MIN_MB.
# Each entry: path (relative to the home folder) | SF Symbol | title | advice
TIP_DEFS=(
  ".Trash|trash.fill|Trash|Empty the Trash to get this space back right away."
  "Downloads|arrow.down.circle.fill|Downloads|Delete installers and files you no longer need."
  "Library/Application Support/MobileSync/Backup|iphone|iPhone & iPad backups|Delete old backups in Finder: select the device, then Manage Backups."
  "Movies|film.fill|Movies|Move videos you don't need on this Mac to cloud storage or an external drive."
  "Library/Containers/com.docker.docker|shippingbox.fill|Docker|Remove unused images, containers and volumes in Docker Desktop."
  "Library/Developer|hammer.fill|Developer files|Xcode build data and simulators. Clean up old ones in Xcode."
  "Library/Caches|archivebox.fill|App caches|Apps rebuild these as needed. Ask IT before clearing them."
  "Library/Mail|envelope.fill|Mail|Large attachments add up. Delete old messages with big attachments."
)
build_tips() {
  local d rel ico ttl txt p; local -i k
  TIPS=()
  for d in "${TIP_DEFS[@]}"; do
    rel="${d%%|*}"; d="${d#*|}"; ico="${d%%|*}"; d="${d#*|}"; ttl="${d%%|*}"; txt="${d#*|}"
    p="$H_R/$rel"; k=${SZ[$p]:-0}
    (( k >= TIP_MIN_KB )) && TIPS+=("$k"$'\t'"$ico"$'\t'"$ttl"$'\t'"$txt"$'\t'"$p")
  done
  TIPS=( "${(@f)$(print -rl -- "${TIPS[@]}" | /usr/bin/sort -t$'\t' -k1,1rn)}" ); TIPS=( ${TIPS:#} )
}

# is_file / is_dir <path>: real checks, or the made-up types in demo mode. Packages other than apps
# (Photos libraries, VMs, disk bundles) count as files, the way Finder shows them.
PKG_EXT='(bundle|framework|photoslibrary|musiclibrary|tvlibrary|photolibrary|aplibrary|vmwarevm|pvm|utm|sparsebundle|xcarchive|plugin|kext|appex|xpc|logarchive|docset|fcpbundle|imovielibrary|logicx|band)'
typeset -A FAKE_TYPE
is_file() { if [[ -n "$DEMO" ]]; then [[ "${FAKE_TYPE[$1]}" == f ]]; else [[ -f "$1" && ! -L "$1" ]]; fi; }
is_dir()  { if [[ -n "$DEMO" ]]; then [[ "${FAKE_TYPE[$1]}" == d ]]; else [[ -d "$1" && ! -L "$1" ]]; fi; }
is_pkg()  { [[ "${1:l}" == *.${~PKG_EXT} ]]; }

# user_facing <data-volume path> -> true for things the user can act on: their home folder, apps,
# and users' folders (macOS / system items are listed in the saved report instead)
user_facing() { npath "$1"; [[ "$REPLY" == ("$USER_HOME"|/Applications|/Users)/* ]]; }
# item_row <all|files|apps> <data-volume path> -> one "Biggest items" row for the window
item_row() {
  local nm wh k=d; item_name "$2"; nm="$REPLY"; dpath "${2:h}"; wh="$REPLY"; npath "$2"
  if [[ "$2" == *.app ]]; then k=a; elif is_file "$2" || is_pkg "$2"; then k=f; fi   # kind, for the icon
  print -r -- "I"$'\t'"$1"$'\t'"$nm"$'\t'"$wh"$'\t'"${SZ[$2]}"$'\t'"$REPLY"$'\t'"$k"
}

# Rows for the results window
write_data() {
  local e p kb ico ttl txt
  {
    # The bar: your stuff first, then apps and the system parts. Slivers too small to see are folded
    # into Documents (yours) or System Data (everything else) so the bar still adds up.
    local -i tiny=$(( (DISK_TOTAL - DISK_FREE) / 1024 / 250 )) docs=$CAT_DOCS sysd=$SYSDATA_KB
    (( tiny < MIN_KB )) && tiny=$MIN_KB
    local -a yours=( "Photos|photos|$CAT_PHOTOS" "Music & Movies|media|$CAT_MEDIA" "Mail & Messages|mail|$CAT_MAIL" \
                     "Developer|dev|$CAT_DEV" "iPhone backups|backup|$CAT_BACKUP" "Trash|trash|$CAT_TRASH" "Other users|users|$OTHERU_KB" )
    local c; local -a keep=()
    for c in "${yours[@]}"; do (( ${c##*|} >= tiny )) && keep+=("$c") || (( docs += ${c##*|} )); done
    (( APPS_KB < tiny )) && { (( sysd += APPS_KB )); APPS_KB=0; }
    print -r -- "B"$'\t'"Documents"$'\t'"$docs"$'\t'"docs"$'\t'"you"
    for c in "${keep[@]}"; do print -r -- "B"$'\t'"${c%%|*}"$'\t'"${c##*|}"$'\t'"${${c#*|}%%|*}"$'\t'"you"; done
    (( APPS_KB )) && print -r -- "B"$'\t'"Apps"$'\t'"$APPS_KB"$'\t'"apps"$'\t'"sys"
    print -r -- "B"$'\t'"System Data"$'\t'"$sysd"$'\t'"sysdata"$'\t'"sys"
    (( MACOS_KB )) && print -r -- "B"$'\t'"macOS"$'\t'"$MACOS_KB"$'\t'"macos"$'\t'"sys"
    # The window lists what the user can act on (their home folder, apps, other users' folders);
    # macOS / system items are in the saved report. If there's nothing like that, show everything.
    # Lists for the tabs. Files / Folders / Apps = the biggest of each kind (folders: not the structural
    # ones like ~/Library, never one inside another). All = where the space sits (the drill-down
    # spots) plus the biggest files and apps, mixed together by size.
    local -a ui=() uf=() ua=() uo=(); local b skip; local -i N=BIG_ITEMS_MAX
    for p in "${BIG[@]}"; do user_facing "$p" && ui+=("$p"); done
    (( ${#ui} )) || ui=("${BIG[@]}")
    for e in "${SORTED[@]}"; do
      p="${e#*$'\t'}"; user_facing "$p" || continue
      if [[ "$p" == *.app ]] && is_dir "$p"; then (( ${#ua} < N )) && ua+=("$p")
      elif is_file "$p" || { is_dir "$p" && is_pkg "$p"; }; then (( ${#uf} < N )) && uf+=("$p")
      elif is_dir "$p" && [[ -z "${IS_EXP[$p]}" ]] && (( ${#uo} < N )); then
        skip=0; for b in "${uo[@]}"; do [[ "$p" == "$b"/* || "$b" == "$p"/* ]] && { skip=1; break; }; done
        (( skip )) || uo+=("$p")
      fi
      (( ${#ua} >= N && ${#uf} >= N && ${#uo} >= N )) && break
    done
    local -A seen; local -a mix=()
    for p in "${ui[@]}" "${uf[@]}" "${ua[@]}"; do [[ -n "${seen[$p]}" ]] && continue; seen[$p]=1; mix+=("${SZ[$p]}"$'\t'"$p"); done
    for e in "${(@)${(@f)$(print -rl -- "${mix[@]}" | /usr/bin/sort -t$'\t' -k1,1rn)}[1,N]}"; do [[ -n "$e" ]] && item_row all "${e#*$'\t'}"; done
    for p in "${uf[@]}"; do item_row files "$p"; done
    for p in "${uo[@]}"; do item_row folders "$p"; done
    for p in "${ua[@]}"; do item_row apps "$p"; done
    for e in "${(@)TIPS[1,TIPS_SHOWN]}"; do
      IFS=$'\t' read -r kb ico ttl txt p <<< "$e"; npath "$p"
      print -r -- "T"$'\t'"$ico"$'\t'"$ttl"$'\t'"$txt"$'\t'"$kb"$'\t'"$(human_kb $kb)"$'\t'"$REPLY"
    done
    if (( SNAPS > 0 && ${#TIPS} < TIPS_SHOWN )); then
      print -r -- "T"$'\t'"clock.arrow.circlepath"$'\t'"Time Machine snapshots"$'\t'"macOS deletes these by itself when it needs the space."$'\t'"0"$'\t'"$SNAPS"$'\t'""
    fi
  } > "$DATA_FILE"
}

# --- The text report (saved to the Desktop, or printed in silent mode) ----------------------------
build_report() {
  local e p; local -i k n
  {
    print -r -- "Disk Usage Report"
    print -r -- "================="
    [[ -n "$DEMO" ]] && { print -r -- "SIMULATED — demo mode, made-up sample data. Nothing on this Mac was measured."; print -r -- ""; }
    kv "Date:"      "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
    kv "User:"      "$targetUser ($USER_HOME)"
    kv "Computer:"  "$COMPUTER_NAME"
    kv "Serial:"    "$(device_serial)"
    kv "Model:"     "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    kv "macOS:"     "$(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    kv "Disk:"      "$VOL_NAME — $(human_size $DISK_FREE) free of $(human_size $DISK_TOTAL) (${FREE_PCT}% free)"
    kv "Status:"    "$HEAD"
    kv "Scan:"      "$(human_kb $MEASURED_KB) measured in ${SCAN_SECS}s$( (( amRoot )) || print " (not run as root, so protected folders were skipped)")"
    print -r -- ""
    print -r -- "== What's using space"
    printf "%10s  %s\n" "$(human_kb $CAT_DOCS)" "Documents (Desktop, Documents, Downloads, iCloud Drive, other files)" \
      "$(human_kb $CAT_PHOTOS)" "Photos (~/Pictures)" "$(human_kb $CAT_MEDIA)" "Music & Movies (~/Music, ~/Movies)" \
      "$(human_kb $CAT_MAIL)" "Mail & Messages" "$(human_kb $CAT_DEV)" "Developer (Xcode, Docker)" \
      "$(human_kb $CAT_BACKUP)" "iPhone & iPad backups" "$(human_kb $CAT_TRASH)" "Trash" \
      "$(human_kb $OTHERU_KB)" "Other users' home folders" "$(human_kb $APPS_KB)" "Apps (/Applications)" \
      "$(human_kb $SYSDATA_KB)" "System Data (caches, app data in ~/Library, /Library, /private, anything not measured)" \
      "$(human_kb $MACOS_KB)" "macOS (the system volume)" "$(human_size $DISK_FREE)" "Free"
    print -r -- "  (Your home folder in total: $(human_kb $HOME_KB))"
    print -r -- ""
    print -r -- "== Biggest items (where the space actually sits)"
    for p in "${(@)BIG[1,25]}"; do npath "$p"; printf "%10s  %s\n" "$(human_kb ${SZ[$p]})" "$REPLY"; done
    (( ${#BIG} )) || print -r -- "  (nothing over ${MIN_ITEM_MB} MB)"
    print -r -- ""
    print -r -- "== Ways to free up space"
    for e in "${TIPS[@]}"; do
      local kb ico ttl txt tp; IFS=$'\t' read -r kb ico ttl txt tp <<< "$e"
      printf "%10s  %s: %s\n" "$(human_kb $kb)" "$ttl" "$txt"
    done
    (( SNAPS > 0 )) && printf "%10s  %s\n" "$SNAPS" "local Time Machine snapshot(s). macOS deletes these by itself when it needs the space."
    (( ${#TIPS} || SNAPS )) || print -r -- "  (nothing obvious — see the lists below)"
    print -r -- ""
    print -r -- "== Your home folder ($USER_HOME)"
    for e in "${SORTED[@]}"; do p="${e#*$'\t'}"; [[ "${p:h}" == "$H_R" ]] || continue; item_name "$p"; printf "%10s  %s\n" "$(human_kb ${e%%$'\t'*})" "${p:t}"; done
    print -r -- ""
    print -r -- "== Largest folders (top 50, folders inside folders are listed too)"
    n=0; for e in "${SORTED[@]}"; do p="${e#*$'\t'}"; is_dir "$p" && [[ "$p" != "$SCAN_ROOT" ]] || continue; npath "$p"; printf "%10s  %s\n" "$(human_kb ${e%%$'\t'*})" "$REPLY"; (( ++n >= 50 )) && break; done
    print -r -- ""
    print -r -- "== Largest apps (top 25)"
    n=0; for e in "${SORTED[@]}"; do p="${e#*$'\t'}"; [[ "$p" == *.app ]] && is_dir "$p" || continue; npath "$p"; printf "%10s  %s\n" "$(human_kb ${e%%$'\t'*})" "$REPLY"; (( ++n >= 25 )) && break; done
    (( n )) || print -r -- "  (no app over ${MIN_ITEM_MB} MB)"
    print -r -- ""
    print -r -- "== Largest files (top 25)"
    n=0; for e in "${SORTED[@]}"; do p="${e#*$'\t'}"; is_file "$p" || continue; npath "$p"; printf "%10s  %s\n" "$(human_kb ${e%%$'\t'*})" "$REPLY"; (( ++n >= 25 )) && break; done
    (( n )) || print -r -- "  (no single file over ${MIN_ITEM_MB} MB)"
    print -r -- ""
    print -r -- "== Time Machine local snapshots"
    if (( SNAPS > 0 )); then
      /usr/bin/tmutil listlocalsnapshots / 2>/dev/null | /usr/bin/grep -v '^Snapshots for' | /usr/bin/sed 's/^/  /'
      print -r -- "  For IT: 'tmutil thinlocalsnapshots / <bytes> 4' frees space by deleting snapshots (use with care)."
    else
      print -r -- "  none"
    fi
    print -r -- ""
    print -r -- "Sizes are disk space used (as measured by du), shown like Finder (1 GB = 1,000,000,000 bytes)."
  } > "$REPORT_FILE"
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
ObjC.import('Cocoa'); ObjC.import('CoreGraphics');
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

# DU_LIB=1 source Disk_Usage.sh  -> loads the functions without running anything (for testing).
[[ -n "$DU_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Disk Usage $SCRIPT_VERSION — mode=${ACTION_MODE}${DEMO:+ (DEMO: $DEMO, sample data)}; user=${targetUser}; running as $(/usr/bin/id -un)"
(( amRoot )) || logMe INFO "Not running as root — protected folders can't be measured (run via Jamf or with sudo)."

MIN_KB=$(( MIN_ITEM_MB * 1024 )); TIP_MIN_KB=$(( TIP_MIN_MB * 1024 ))
COMPUTER_NAME="$(/usr/sbin/scutil --get ComputerName 2>/dev/null)"

# Disk numbers: the whole APFS container (what System Settings > Storage shows), else the volume.
disk_info() {
  local pl="$SCRATCH/disk.plist"
  /usr/sbin/diskutil info -plist / > "$pl" 2>/dev/null
  px() { /usr/bin/plutil -extract "$1" raw -o - "$pl" 2>/dev/null; }
  DISK_TOTAL=$(px APFSContainerSize); DISK_FREE=$(px APFSContainerFree); VOL_NAME=$(px VolumeName)
  [[ "$DISK_TOTAL" == <1-> ]] || DISK_TOTAL=$(px TotalSize)
  [[ "$DISK_FREE" == <1-> ]] || DISK_FREE=$(px FreeSpace)
  if [[ "$DISK_TOTAL" != <1-> || "$DISK_FREE" != <-> ]]; then
    local -a d=( $(/bin/df -k / | /usr/bin/awk 'NR==2{print $2, $4}') )
    DISK_TOTAL=$(( d[1] * 1024 )); DISK_FREE=$(( d[2] * 1024 ))
  fi
  [[ -n "$VOL_NAME" ]] || VOL_NAME="Macintosh HD"
  VOL_USED_KB=$(/bin/df -k "$SCAN_ROOT" 2>/dev/null | /usr/bin/awk 'NR==2{print $3}'); [[ "$VOL_USED_KB" == <1-> ]] || VOL_USED_KB=1
  MACOS_KB=0   # macOS itself: the sealed system volume (macOS 10.15+), shown as its own part of the bar
  [[ -n "$DATA_ROOT" ]] && { MACOS_KB=$(/bin/df -k / 2>/dev/null | /usr/bin/awk 'NR==2{print $3}'); [[ "$MACOS_KB" == <-> ]] || MACOS_KB=0; }
  SNAPS=$(/usr/bin/tmutil listlocalsnapshots / 2>/dev/null | /usr/bin/grep -c 'com.apple')
  [[ -n "$DEMO" ]] && demo_disk
  local -F fp=$(( DISK_FREE * 100.0 / DISK_TOTAL ))
  FREE_PCT=$(printf "%.0f" $fp); USED_FRAC=$(printf "%.4f" $(( 1 - fp / 100 )))
  local -i fgb=$(( DISK_FREE / 1000000000 ))
  local nums="$(human_size $DISK_FREE) free of $(human_size $DISK_TOTAL) ($(( 100 - FREE_PCT ))% used)."
  if (( fp < CRIT_FREE_PERCENT || fgb < CRIT_FREE_GB )); then
    DISK_STATUS=bad; HEAD="Almost out of space"
    SUBHEAD="$nums macOS needs free space to update and run well. Free some up now — see below."
  elif (( fp < WARN_FREE_PERCENT || fgb < WARN_FREE_GB )); then
    DISK_STATUS=ok; HEAD="Space is getting low"
    SUBHEAD="$nums Free some up soon to keep your Mac running smoothly."
  else
    DISK_STATUS=good; HEAD="Plenty of free space"
    SUBHEAD="$nums Here's what's using the rest."
  fi
}

# Branding (logo + light/dark colour palette) — only needed when windows are shown.
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

disk_info
logMe INFO "Disk: $VOL_NAME — $(human_size $DISK_FREE) free of $(human_size $DISK_TOTAL) (${FREE_PCT}% free) — $HEAD"
spin_status "Getting ready…" "" "0/1"
show_spinner

SECONDS=0
if [[ -n "$DEMO" ]]; then demo_scan; else scan_disk; fi
SCAN_SECS=$SECONDS
spin_status "Building your report…" "$(human_kb $(<"$PROG_FILE")) measured" "1/1"
analyze; build_tips; write_data; build_report
logMe INFO "Measured $(human_kb $MEASURED_KB) in ${SCAN_SECS}s · home $(human_kb $HOME_KB) · apps $(human_kb $APPS_KB) · other users $(human_kb $OTHERU_KB) · macOS & system $(human_kb $SYS_KB)"
(( ${#BIG} )) && { npath "${BIG[1]}"; logMe INFO "Biggest item: $REPLY ($(human_kb ${SZ[${BIG[1]}]}))"; }
kill_spinner

if [[ "$ACTION_MODE" == "silent" ]]; then
  /bin/cat "$REPORT_FILE"
  logWritable && /bin/cat "$REPORT_FILE" >> "$logFile"
  exit 0
fi

RUN_SUBTITLE="${COMPUTER_NAME:-This Mac}"
DISK_CHIP="$VOL_NAME  ·  $(human_size $DISK_TOTAL)"
RESULT_NOTE=""
(( amRoot )) || RESULT_NOTE="Some protected folders couldn't be measured, so they count toward macOS & system."
if [[ -n "$DEMO" ]]; then
  RUN_SUBTITLE="DEMO  ·  $RUN_SUBTITLE"
  RESULT_NOTE="Demo — this is made-up sample data. Nothing on this Mac was measured or changed."
fi

choice=$(show_results)
logMe INFO "User clicked: $([[ $choice == save ]] && print "Save Report" || print "Done")"
if [[ "$choice" == save ]]; then
  SERIAL="$(device_serial)"; [[ -z "$SERIAL" ]] && SERIAL="unknown"
  REPORT_NAME="${REPORT_NAME_PATTERN//\{USER\}/$targetUser}"
  REPORT_NAME="${REPORT_NAME//\{SERIAL\}/$SERIAL}"
  _stamp="$(/bin/date "+${STAMP_FORMAT:-%Y-%m-%d_%H-%M}")"; _stamp="${_stamp//[:\/]/-}"   # no : or / in file names
  REPORT_NAME="${REPORT_NAME//\{STAMP\}/$_stamp}"
  DESKTOP="$USER_HOME/Desktop"; [[ -d "$DESKTOP" ]] || DESKTOP="$USER_HOME"
  if [[ -e "$DESKTOP/$REPORT_NAME" ]]; then   # never overwrite an earlier report: add _2, _3, ...
    _base="${REPORT_NAME%.*}"; _ext="${REPORT_NAME##*.}"; _n=2
    while [[ -e "$DESKTOP/${_base}_$_n.$_ext" ]]; do (( _n++ )); done
    REPORT_NAME="${_base}_$_n.$_ext"
  fi
  if /bin/cp "$REPORT_FILE" "$DESKTOP/$REPORT_NAME" 2>/dev/null; then
    (( amRoot )) && /usr/sbin/chown "$targetUser" "$DESKTOP/$REPORT_NAME" 2>/dev/null
    logMe INFO "Report saved: $DESKTOP/$REPORT_NAME"
    run_as_user /usr/bin/open -R "$DESKTOP/$REPORT_NAME" 2>/dev/null
    show_message "$SAVED_TITLE" "arrow.down.doc.fill" ok "Your disk usage report was saved to your Desktop.\nAttach it to your IT ticket." "$REPORT_NAME" "$DESKTOP/$REPORT_NAME"
  else
    logMe ERROR "Could not save report to $DESKTOP"
    show_message "$SAVED_TITLE" "xmark.octagon.fill" fail "The report could not be saved to your Desktop. Contact IT for help." ""
  fi
fi

exit 0
