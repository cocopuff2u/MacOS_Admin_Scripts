#!/bin/zsh

####################################################################################################
#
# Set Time Zone
#
# Purpose: Lets the user set their Mac's time zone from a searchable list of every time zone, with
#          friendly names ("Chicago · United States · Central Time"), each zone's current time and
#          UTC offset, and their current zone marked. Or set a zone for them from the policy.
#
#          macOS's "Set time zone automatically using your current location" can quietly switch a
#          zone the user picked back again, so by default it's turned off when a zone is set here.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works when run as root from Jamf.
#
# What the user sees:
#   1. Pick  — their current zone and time at the top, then every time zone: search by city, country,
#              region, abbreviation (EST, PST) or name ("Pacific Time"). Click one, then Set.
#   2. Done  — the new zone and what time it is now.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service, the user picks:        leave Parameter 4 blank.
#   Set a specific zone (shows a result): Parameter 4 = America/Chicago
#   Set a zone with no windows:          Parameter 4 = America/Chicago, Parameter 5 = silent
#   Test a policy safely:                Parameter 5 = dry     (nothing is changed)
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Time Zone (e.g. America/Chicago; blank = the user picks)
#   Parameter 5 Label:  Action Mode (verbose, dry, or silent)
#   Parameter 6 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 7 Label:  Banner Color (hex, optional)
#   Parameter 8 Label:  Brand Name (optional)
#   Parameter 9 Label:  Appearance (auto, light, or dark)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Time Zone     blank = the user picks from the list
#                       or a zone name as macOS lists it: America/Chicago, Europe/London, UTC
#                       (see: sudo systemsetup -listtimezones)
#     $5  Action Mode   verbose = windows (default)
#                       dry     = the same windows, but nothing is changed (to test a policy)
#                       silent  = no windows: sets the zone in $4. Needs $4.
#     $6  Brand Icon    logo for the windows. Blank = BRAND_ICON from the Config block.
#                       examples: /Library/Application Support/Acme/logo.png
#                                 /Applications/Self Service.app
#                                 https://acme.com/logo.png
#                                 sf:clock.fill
#                                 selfservice   (your Jamf Self Service branding logo)
#     $7  Banner Color  hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                       "auto-dark" (deeper logo shade for white text). Blank = bannerColor below.
#     $8  Brand Name    small line above the banner title, e.g. "Acme IT Support".
#     $9  Appearance    auto (follow the user's Light/Dark setting), light, or dark.
# ---------------------------------------------------------------------------------------------
#
# TESTING (nothing is changed with "dry"):
#   ./Set_Time_Zone.sh "" dry                          # the picker, preview only
#   ./Set_Time_Zone.sh "" dry "sf:clock.fill" "#1F6FEB" "Acme IT" dark
#   sudo ./Set_Time_Zone.sh                            # the real thing, as Jamf runs it (needs root)
#
# Exit codes (Jamf treats any non-zero exit as a FAILED policy):
#   0 - set, dry run, user cancelled, or already set
#   1 - the zone isn't valid, or it couldn't be set (not root, or macOS refused it)
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 8/29/23 - Original Release - @cocopuff2u
#
# 1.1 6/26/26 - Branded JXA/AppKit picker with two styles (Area + Zone dropdowns, or one scrollable
#               list), native confirmation window (removed JamfHelper), and a configurable banner
#               colour. Runs the GUI in the console user's session - @cocopuff2u
#
# 2.0 11/13/26 - Redesign to match App Uninstaller, Disk Usage and Delete Expired Certificates: branded
#               windows (logo, brand name, banner colour, light/dark), one searchable list of every
#               zone with city, country, region, friendly name, UTC offset and current time, the user's
#               current zone and time at the top, a result window with the new time. Turns off
#               "Set time zone automatically" so a picked zone sticks. New parameters: a zone to set
#               ($4), Action Mode ($5: verbose / dry / silent), branding in $6-$9. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# WHAT TO SET ---------------------------------------------------------------
TARGET_ZONE=""          # hardcode a zone for a dedicated policy, e.g. "America/Chicago".
                        # Blank = take it from Jamf $4; if $4 is blank too, the user picks.

# HOW IT RUNS ---------------------------------------------------------------
DRY_RUN_OVERRIDE=false        # true = ALWAYS preview (show the windows, change NOTHING). Keep false for production.
TURN_OFF_AUTO_TIMEZONE=true   # true = when a zone is set, turn off "Set time zone automatically using your
                              # current location" (otherwise macOS can switch it back). false = leave it alone.
PICKER_ROWS_SHOWN=8           # rows visible at once in the list (it scrolls for more)
logFile="/var/log/set_time_zone.log"   # this script's own run log

# BRANDING (windows only) ---------------------------------------------------
BRAND_NAME="IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($8)
BRAND_ICON=""              # optional logo ($6). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:clock.fill                     (tinted to match the theme)
                           #   • Self Service   selfservice (or: ss) — your Jamf Self Service branding logo
                           # Blank = no logo.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto = follow the user's Light/Dark setting; light or dark forces one. ($9)

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto".
bannerColor="auto"         # banner + main button ($7). auto = the logo's exact main colour;
                           # auto-dark = a deeper shade of it for white text; no logo = #0056D2
BANNER_TEXT_COLOR="auto"   # auto = white, or near-black if the banner is too light for white
ACCENT_COLOR="auto"        # selection, icons, buttons. auto = the banner colour, made readable
SPINNER_BG_COLOR="auto"    # auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # "Time Zone Updated" icon. auto = Apple green
FAIL_COLOR="auto"          # error icon. auto = Apple red

# TEXT ----------------------------------------------------------------------
PICKER_TITLE="Set Time Zone"
PICKER_SUBTITLE="Choose the time zone you're in"
PICKER_NOTE="Your Mac's clock switches to the new time zone right away."
DRY_NOTE="Preview only — your time zone won't be changed, so you can click through safely."   # shown in dry runs
DONE_TITLE="Time Zone Updated"
FAIL_TITLE="Time Zone Not Changed"
DRY_TITLE="Preview Complete"
setButton="Set Time Zone"
previewButton="Finish Preview"      # replaces the Set button in preview (dry-run) mode
cancelButton="Cancel"
okButton="Done"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent
zmodload zsh/datetime 2>/dev/null

SCRIPT_VERSION="2.0"
SCRATCH="/tmp/set-time-zone.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$TZ_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # TZ_DEBUG=1 keeps the scratch folder (testing)
ZONE_FILE="$SCRATCH/zones.tsv"       # rows for the picker
ZONEINFO="/usr/share/zoneinfo"

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point ($1 "/"), computer name ($2) and user ($3) first; strip that trio.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
[[ -n "$1" ]] && TARGET_ZONE="${${1##[[:space:]]#}%%[[:space:]]#}"
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

# --- Shared window pieces (picker window) -------------------------------------------------------
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
  /bin/chmod 644 "$1" "$ZONE_FILE" 2>/dev/null
  run_as_user /usr/bin/osascript -l JavaScript "$1" 2>>"$SCRATCH/jxa-err.log"
}


# --- Time zones -----------------------------------------------------------------------------------
# current_zone -> REPLY = the zone the Mac is using now (from /etc/localtime, the source of truth)
current_zone() { REPLY="$(/usr/bin/readlink /etc/localtime 2>/dev/null)"; REPLY="${REPLY##*zoneinfo/}"; }
# Automatic time zone is two switches: the System Settings toggle (com.apple.timezone.auto) and timed's own
# setting (TMAutomaticTimeZoneEnabled). With only the first on, macOS shows it as on but never re-detects.
TZ_AUTO_PLIST="/Library/Preferences/com.apple.timezone.auto"
TIMED_PLIST="/private/var/db/timed/Library/Preferences/com.apple.timed.plist"
# auto_zone_on -> 0 if automatic time zone is on (both switches when we can read timed's, i.e. as root)
auto_zone_on() {
  [[ "$(/usr/bin/defaults read "$TZ_AUTO_PLIST" Active 2>/dev/null)" == 1 ]] || return 1
  (( amRoot )) || return 0
  [[ "$(/usr/bin/defaults read "$TIMED_PLIST" TMAutomaticTimeZoneEnabled 2>/dev/null)" != 0 ]]
}
# set_auto <true|false> -> sets both switches (needs root), then restarts timed so it reads them: the running
# service caches the setting and only System Settings tells it about a change (launchd starts it again at once).
set_auto() {
  /usr/bin/defaults write "$TZ_AUTO_PLIST" Active -bool $1 2>/dev/null || return 1
  [[ -d "${TIMED_PLIST:h}" ]] && /usr/bin/defaults write "$TIMED_PLIST" TMAutomaticTimeZoneEnabled -bool $1 2>/dev/null
  if /usr/bin/pgrep -x timed >/dev/null 2>&1; then
    /usr/bin/killall timed 2>/dev/null && logMe INFO "Restarted timed so it picks up the automatic time zone setting."
  fi
  return 0
}
# location_on -> 0 if Location Services is on (macOS needs it to detect the time zone; root can read this)
location_on() { [[ "$(/usr/bin/defaults read /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled 2>/dev/null)" == 1 ]]; }
# wifi_on -> 0 if any Wi-Fi interface is powered on. Macs find their location by scanning nearby Wi-Fi networks
# (no GPS), so with Wi-Fi off automatic time zone can't work, even on a wired network. It doesn't need to be joined.
wifi_on() {
  local dev
  for dev in ${(f)"$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '/^Hardware Port: (Wi-Fi|AirPort)/{getline; print $2}')"}; do
    [[ "$(/usr/sbin/networksetup -getairportpower "$dev" 2>/dev/null)" == *": On" ]] && return 0
  done
  return 1
}
# 24-hour clock: a per-user setting (System Settings > General > Date & Time > 24-hour time).
# clock24_get -> prints 1 (24-hour), 0 (12-hour), or nothing (not set: follows the user's region)
clock24_get() { run_as_user /usr/bin/defaults read -g AppleICUForce24HourTime 2>/dev/null; }
# clock24_set <true|false> -> sets it for the user, then announces the change the way System Settings does,
# so the menu bar clock and open apps switch right away (writing the setting alone isn't noticed).
clock24_set() {
  run_as_user /usr/bin/defaults write -g AppleICUForce24HourTime -bool $1 2>/dev/null || return 1
  run_as_user /usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation"); var c=$.NSDistributedNotificationCenter.defaultCenter;
    ["AppleTimePreferencesChangedNotification","AppleICUForce24HourTimeChanged","AppleDatePreferencesChangedNotification"].forEach(function(n){
      c.postNotificationNameObjectUserInfoDeliverImmediately(n,$(),$(),true); }); ""' >/dev/null 2>&1
  return 0
}
# is_auto <value> -> 0 if it asks for automatic time zone ("auto", "automatic", or the picker's __AUTO__)
is_auto() { [[ "${1:l}" == (auto|automatic|__auto__) ]]; }
# enable_auto -> turns "Set time zone automatically using your current location" on. 0 = on.
enable_auto() {
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to change the time zone setting."; return 1; }
  if (( ! amRoot )); then logMe ERROR "Turning on automatic time zone needs root (run via Jamf or with sudo)."; return 1; fi
  set_auto true
  auto_zone_on
}
# valid_zone <zone> -> 0 if macOS has it
valid_zone() { [[ "$1" == [A-Za-z0-9_/+-]## && "$1" != */../* && -f "$ZONEINFO/$1" ]]; }
# pretty_zone <zone> -> REPLY = "Chicago" (the city part, readable)
pretty_zone() { REPLY="${${1##*/}//_/ }"; }
# zone_now <zone> -> REPLY = "1:04 PM", ZONE_ABBR = "CST", ZONE_OFF = "UTC−6"
zone_now() {
  REPLY="$(TZ="$1" /bin/date '+%-I:%M %p')"; ZONE_ABBR="$(TZ="$1" /bin/date '+%Z')"
  local z="$(TZ="$1" /bin/date '+%z')" h m
  h=$(( 10#${z[2,3]} )); m="${z[4,5]}"
  if [[ "$z" == "+0000" ]]; then ZONE_OFF="UTC"
  else ZONE_OFF="UTC${${z[1]}/-/−}$h$([[ "$m" != 00 ]] && print ":$m")"; fi
}

# build_zones -> $ZONE_FILE rows "Z  zone  city  country  region note  country code", from macOS's own
# time zone data (zone.tab + iso3166.tab), plus UTC.
build_zones() {
  /usr/bin/awk -F'\t' '
    FNR==NR { if ($0 !~ /^#/) cn[$1]=$2; next }
    /^#/ { next }
    { city=$3; sub(/.*\//,"",city); gsub(/_/," ",city)
      printf "Z\t%s\t%s\t%s\t%s\t%s\n", $3, city, ($1 in cn ? cn[$1] : $1), $4, $1 }
  ' "$ZONEINFO/iso3166.tab" "$ZONEINFO/zone.tab" > "$ZONE_FILE" 2>/dev/null
  print -r -- "Z"$'\t'"UTC"$'\t'"UTC"$'\t'"Coordinated Universal Time"$'\t'"No daylight saving"$'\t'"" >> "$ZONE_FILE"
  /bin/chmod 644 "$ZONE_FILE"
}

# --- Picker window ----------------------------------------------------------------------------------
# The user's current zone and time in a card at the top, then every zone in a searchable list sorted
# by UTC offset: flag, city, country · region, the zone's name, its offset and the time there now.
# Click a zone to select it (double-click to set it straight away). Prints the zone, or __CANCEL__.
show_picker() {
  local s="$SCRATCH/picker.jxa"
  current_zone; local cur="$REPLY"
  {
    win_prelude
    print -r -- "var DATA=\"$(as_esc "$ZONE_FILE")\", PTITLE=\"$(as_esc "$PICKER_TITLE")\", PSUB=\"$(as_esc "$PICKER_SUBTITLE")\", PNOTE=\"$(as_esc "$PICKER_NOTE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\";"
    print -r -- "var L_SET=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$previewButton" || print -r -- "$setButton")")\", L_CANCEL=\"$(as_esc "$cancelButton")\", VIS=${PICKER_ROWS_SHOWN:-8}, DRY=$DRY_RUN;"
    print -r -- "var CUR=\"$(as_esc "$cur")\", H24=\"$(clock24_get)\", AUTO=$(auto_zone_on && print true || print false), WIFI=$(wifi_on && print true || print false), LOC=\"$( (( amRoot )) && { location_on && print on || print off; } || print unknown)\";"
    /bin/cat <<'JXA'
// ---- the zones, with names, offsets and times from macOS ----
var loc=$.NSLocale.currentLocale, NOW=$.NSDate.date, df=$.NSDateFormatter.alloc.init;
var dday=$.NSDateFormatter.alloc.init; dday.dateFormat="EEEE, MMM d";
function U(o){ return (o && !(typeof o.isNil==='function' && o.isNil())) ? ObjC.unwrap(o) : ""; }
function offStr(s){ if(!s) return "UTC"; var a=Math.abs(s), h=Math.floor(a/3600), m=Math.round((a%3600)/60); return "UTC"+(s<0?"−":"+")+h+(m?":"+(m<10?"0":"")+m:""); }
function flag(cc){ if(!cc || cc.length!=2) return "🌐"; try{ return String.fromCodePoint(0x1F1E6+cc.charCodeAt(0)-65, 0x1F1E6+cc.charCodeAt(1)-65); }catch(e){ return "🌐"; } }
// 24-hour clock: what the user has now (their setting, else what their region uses)
var H24NOW = H24=="1" ? true : H24=="0" ? false : U($.NSDateFormatter.dateFormatFromTemplateOptionsLocale("j",0,loc)).indexOf("H")>=0;
var H24SEL = H24NOW;
function tfmt(){ df.dateFormat = H24SEL ? "HH:mm" : "h:mm a"; }
function timeIn(id){ tfmt(); df.timeZone=$.NSTimeZone.timeZoneWithName(id); return U(df.stringFromDate(NOW)); }
// Extra words people search for: big cities that share a zone (Beijing is Asia/Shanghai), old names, US states
var ALIAS={
 "America/New_York":"boston atlanta miami orlando philadelphia washington dc pittsburgh charlotte baltimore new jersey florida georgia ohio virginia carolina massachusetts pennsylvania michigan east coast",
 "America/Chicago":"dallas houston austin san antonio nashville minneapolis st louis saint louis kansas city new orleans milwaukee memphis oklahoma texas illinois wisconsin minnesota iowa missouri louisiana alabama tennessee",
 "America/Denver":"salt lake city albuquerque boise colorado utah new mexico montana wyoming idaho",
 "America/Phoenix":"arizona tucson scottsdale",
 "America/Los_Angeles":"san francisco seattle portland san diego las vegas sacramento san jose silicon valley bay area california washington state oregon nevada west coast",
 "America/Anchorage":"alaska juneau fairbanks", "Pacific/Honolulu":"hawaii maui oahu",
 "America/Toronto":"ottawa montreal quebec ontario", "America/Vancouver":"british columbia victoria", "America/Edmonton":"calgary alberta",
 "America/Mexico_City":"guadalajara monterrey", "America/Sao_Paulo":"rio de janeiro brasilia", "America/Argentina/Buenos_Aires":"argentina",
 "Europe/London":"uk britain great britain england scotland wales manchester edinburgh glasgow birmingham liverpool",
 "Europe/Berlin":"frankfurt munich hamburg cologne germany", "Europe/Paris":"france lyon marseille", "Europe/Rome":"milan naples italy",
 "Europe/Madrid":"barcelona valencia spain", "Europe/Zurich":"geneva bern basel switzerland", "Europe/Amsterdam":"rotterdam netherlands holland",
 "Europe/Kyiv":"kiev ukraine", "Europe/Moscow":"st petersburg saint petersburg", "Europe/Istanbul":"ankara turkey",
 "Asia/Shanghai":"beijing peking shenzhen guangzhou chengdu china", "Asia/Hong_Kong":"hk", "Asia/Tokyo":"osaka kyoto japan",
 "Asia/Seoul":"busan korea", "Asia/Kolkata":"calcutta mumbai bombay delhi new delhi bangalore bengaluru chennai madras hyderabad pune india",
 "Asia/Karachi":"lahore islamabad pakistan", "Asia/Dubai":"uae abu dhabi emirates", "Asia/Jerusalem":"tel aviv israel",
 "Asia/Ho_Chi_Minh":"saigon hanoi vietnam", "Asia/Bangkok":"thailand", "Asia/Singapore":"sg", "Asia/Manila":"philippines",
 "Asia/Jakarta":"indonesia", "Asia/Taipei":"taiwan", "Asia/Riyadh":"saudi arabia jeddah",
 "Australia/Sydney":"canberra new south wales nsw", "Australia/Melbourne":"victoria", "Australia/Brisbane":"queensland gold coast",
 "Pacific/Auckland":"wellington new zealand nz", "Africa/Johannesburg":"cape town durban pretoria south africa", "Africa/Lagos":"nigeria abuja",
 "Africa/Cairo":"egypt", "Africa/Nairobi":"kenya" };
var CCWORDS={US:"us usa united states america", GB:"uk gb britain", AE:"uae", CA:"canada", AU:"australia", NZ:"nz"};
var Z=[];
readLines(DATA).forEach(function(l){ var r=l.split("\t"); if(r[0]!="Z") return;
 var tz=$.NSTimeZone.timeZoneWithName(r[1]); if(!isOk(tz)) return;
 var z={id:r[1],city:r[2],country:r[3],note:r[4]||"",cc:r[5]||"",off:tz.secondsFromGMT,gen:U(tz.localizedNameLocale(4,loc))||r[1],
        s1:U(tz.localizedNameLocale(1,loc)),s3:U(tz.localizedNameLocale(3,loc)),i:Z.length};
 // the offset in the forms people type: "utc-6", "utc-6:00", "-06:00" (search turns gmt / spaces / − into these)
 z.utc=offStr(z.off).replace("−","-").toLowerCase();
 var oh=Math.floor(Math.abs(z.off)/3600), om=Math.round((Math.abs(z.off)%3600)/60), osg=z.off<0?"-":"+";
 var ohm=osg+(oh<10?"0":"")+oh+":"+(om<10?"0":"")+om;
 z.key=[z.id,z.city,z.country,z.note,z.gen,z.s1,z.s3,
  U(tz.localizedNameLocale(0,loc)),U(tz.localizedNameLocale(2,loc)),U(tz.localizedNameLocale(5,loc)),   // "Central Standard Time", "Central Daylight Time", "CT"
  ALIAS[z.id]||"",CCWORDS[z.cc]||"",z.cc,z.utc,(z.utc.indexOf(":")<0&&z.off?z.utc+":00":""),"utc"+ohm,ohm].join(" ").toLowerCase().replace(/_/g," ");
 z.std=U(tz.localizedNameLocale(0,loc)); z.dst=U(tz.localizedNameLocale(2,loc)); z.sg=U(tz.localizedNameLocale(5,loc));
 z.names=[z.city,z.country,z.gen,z.std,z.dst,z.sg,z.s1,z.s3,z.utc,z.id.replace(/_/g," ")].map(function(x){ return (x||"").toLowerCase(); });
 z.toks=z.key.split(/[\s,()\/·.]+/).filter(function(t){ return t; });
 z.pop=(ALIAS[z.id]?2:0)+(/most (areas|locations)/i.test(z.note)?1:0);   // the main zone of a region / a well-known city first
 Z.push(z); });
Z.sort(function(a,b){ return a.off-b.off || a.city.localeCompare(b.city); });
// wordHit(z, w): offsets ("utc-6", "+05:30") must match exactly; short words (≤3 letters, e.g. "ct", "uk", "usa")
// must start a word, so they don't match inside "Moncton" or "Jerusalem"; longer words can appear anywhere.
function isOff(w){ return /^utc([+-]|$)/.test(w) || /^[+-]\d/.test(w); }
function wordHit(z,w){ if(isOff(w)) return z.toks.indexOf(w)>=0;
 if(w.length<=3) return z.toks.some(function(t){ return t.indexOf(w)==0; });
 return z.key.indexOf(w)>=0; }
Z.forEach(function(z,k){ z.i=k; });
var CURZ=null; Z.forEach(function(z){ if(z.id==CUR) CURZ=z; });
// Why automatic can't work on this Mac right now ("" = it can)
var AUTOWHY = LOC=="off" ? "Needs Location Services, which is off on this Mac" : (!WIFI ? "Needs Wi-Fi on to find your location" : "");

// What the user is choosing: AUTOSEL (automatic on/off), SEL (a zone, when automatic is off), H24SEL (24-hour clock)
var AUTOSEL=AUTO, SEL=CURZ?CURZ.i:-1;
// The zone and automatic are independent: on a wired Mac (no Wi-Fi to find its location) you can set the right
// zone by hand AND leave automatic on, so it takes over whenever it can.
function changed(){ var z=SEL>=0?Z[SEL]:null, zc=!!(z && z!==CURZ), ac=(AUTOSEL!=AUTO), hc=(H24SEL!=H24NOW);
 return { zone: zc, auto: ac, h24: hc, any: zc||ac||hc }; }

var hd=null;
if(!$.TZPick){ObjC.registerSubclass({name:'TZPick',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){ if(changed().any) $.NSApplication.sharedApplication.stopModalWithCode(1); }},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'auto:':{types:['void',['id']],implementation:function(s){ AUTOSEL=ObjC.unwrap(swA.state)==1; update(); }},
 'h24:':{types:['void',['id']],implementation:function(s){ H24SEL=ObjC.unwrap(swH.state)==1; refreshTimes(); update(); }},
 'search:':{types:['void',['id']],implementation:function(s){ layout(); }},
 // ↑ / ↓ in the search field move through the results; Return applies (when something will change)
 'control:textView:doCommandBySelector:':{types:['bool',['id','id','SEL']],implementation:function(c,tv,sel){
   var cmd=""; try{ cmd=ObjC.unwrap($.NSStringFromSelector(sel)); }catch(e){ cmd=""+sel; }
   if(cmd=="moveDown:"||cmd=="moveUp:"){ moveSel(cmd=="moveDown:"?1:-1); return true; }
   if(cmd=="insertNewline:"){ if(changed().any) $.NSApplication.sharedApplication.stopModalWithCode(1); return true; }
   return false; }}}});}
hd=$.TZPick.alloc.init;
// A click layer on top of each row: takes the first click; double-click applies.
if(!$.TZHit){ObjC.registerSubclass({name:'TZHit',superclass:'NSView',methods:{
 'acceptsFirstMouse:':{types:['bool',['id']],implementation:function(e){ return true; }},
 'mouseUp:':{types:['void',['id']],implementation:function(e){ }},
 'mouseDown:':{types:['void',['id']],implementation:function(e){ var n=+ObjC.unwrap(this.identifier); SEL=n;
   update();
   if(e.clickCount>=2 && changed().any) $.NSApplication.sharedApplication.stopModalWithCode(1); }}}});}
// The window is a non-activating panel: it takes keyboard focus when clicked even when macOS won't bring a
// script launched by Jamf / sudo to the front (macOS 14+), so the search field always works.
if(!$.TZPanel){ObjC.registerSubclass({name:'TZPanel',superclass:'NSPanel',methods:{
 'canBecomeKeyWindow':{types:['bool',[]],implementation:function(){ return true; }},
 'canBecomeMainWindow':{types:['bool',[]],implementation:function(){ return true; }}}});}
if(!$.TZSearch){ ObjC.registerSubclass({name:'TZSearch',superclass:'NSSearchField',methods:{
 'acceptsFirstMouse:':{types:['bool',['id']],implementation:function(e){ return true; }}}}); }

// ---- sizes and positions (bottom-up) ----
var W=760, PAD=24, BH=(BNAME?96:84), ROWH=48, LH=Math.max(4,VIS)*ROWH+10, TBH=28, OPH=56;
var PBW=150, PBW2=190, PBH=34, PBY=18, noteY=PBY+PBH+12, NOTEH=DRY?16:0, listY=noteY+NOTEH+(DRY?12:2), tbY=listY+LH+14, opY=tbY+TBH+14;
var H=opY+OPH+18+BH;
var win=$.TZPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15)|(1<<7),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR;
win.hidesOnDeactivate=false; win.becomesKeyOnlyIfNeeded=false; win.floatingPanel=false;
var cv=win.contentView;
header(cv,W,H,BH,PAD,PTITLE,PSUB,"","");
// card(x,y,w,h) -> a rounded panel with a hairline outline, so it reads clearly on the dark window too
function card(x,y,w,h){ var b=rbox(x,y,w,h,DARK?C([1,1,1],0.06):C([0,0,0],0.045),12);
 b.borderWidth=1; b.borderColor=DARK?C([1,1,1],0.12):C([0,0,0],0.09); cv.addSubview(b); return b; }

// Top-right of the banner: the time where the Mac is now, and where that is
dday.timeZone=CURZ?$.NSTimeZone.timeZoneWithName(CURZ.id):$.NSTimeZone.localTimeZone;
var CKW=300, ckY=H-BH+(BH-56)/2;
var c3=label("",W-PAD-CKW,ckY+20,CKW,34,28,$.NSFontWeightBold,2); c3.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(28,$.NSFontWeightSemibold); c3.textColor=BTXT; cv.addSubview(c3);
var c4=label((DRY?"Preview only  ·  ":"")+(CURZ?flag(CURZ.cc)+"  "+CURZ.city+"  ·  "+offStr(CURZ.off):(CUR||"")),W-PAD-CKW,ckY+2,CKW,16,12,$.NSFontWeightSemibold,2); c4.textColor=BTXT; c4.alphaValue=0.85;
c4.toolTip=(CURZ?CURZ.gen+"  ·  ":"")+U(dday.stringFromDate(NOW))+(AUTO?"  ·  set automatically from your location":""); cv.addSubview(c4);

// Two switches, like System Settings: automatic time zone, and 24-hour time
function option(x,w,symName,title,sub,act,on,warn){
 card(x,opY,w,OPH);
 cv.addSubview(rbox(x+12,opY+(OPH-32)/2,32,32,ACCENT.colorWithAlphaComponent(DARK?0.20:0.12),8));
 var si=sym(symName,x+12+8,opY+(OPH-16)/2,16,ACCENT); if(si) cv.addSubview(si);
 var t=label(title,x+54,opY+OPH/2+1,w-54-70,18,13,$.NSFontWeightSemibold); cv.addSubview(t);
 var d=label(sub,x+54,opY+OPH/2-16,w-54-70,15,11); d.cell.lineBreakMode=4; d.toolTip=sub;
 d.textColor = warn ? (DARK?C([1,0.62,0.04]):C([0.75,0.38,0.0])) : $.NSColor.secondaryLabelColor; cv.addSubview(d);
 var sw; try{ sw=$.NSSwitch.alloc.initWithFrame($.NSMakeRect(x+w-12-42,opY+(OPH-24)/2,42,24)); }catch(e){ sw=null; }
 if(!sw || sw.isNil()){ sw=$.NSButton.alloc.initWithFrame($.NSMakeRect(x+w-12-24,opY+(OPH-20)/2,22,20)); sw.setButtonType(3); sw.title=""; }
 sw.state=on?1:0; sw.target=hd; sw.action=act; try{ sw.contentTintColor=ACCENT; }catch(e){} cv.addSubview(sw); return sw; }
var OW=(W-2*PAD-12)/2;
var swA=option(PAD,OW,"location.fill","Set time zone automatically",AUTOWHY||"Uses your Mac's location",'auto:',AUTO,!!AUTOWHY);
var swH=option(PAD+OW+12,OW,"clock.arrow.2.circlepath","24-hour time",H24NOW?"Shows 14:30 instead of 2:30 PM":"Shows 2:30 PM — turn on for 14:30",'h24:',H24NOW,false);

// Search
var search=$.TZSearch.alloc.initWithFrame($.NSMakeRect(PAD,tbY,380,TBH)); search.placeholderString="Search a city, country, or zone (e.g. Pacific, EST)";
search.target=hd; search.action='search:'; search.delegate=hd; try{ search.sendsSearchStringImmediately=true; }catch(e){} cv.addSubview(search);
var kh=label("↑ ↓ to choose  ·  Return to set",W-PAD-260,tbY+6,260,16,11.5,$.NSFontWeightRegular,2); kh.textColor=$.NSColor.tertiaryLabelColor; cv.addSubview(kh);

// The list
var LW=W-2*PAD;
var listBox=card(PAD,listY,LW,LH);
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,listY+5,LW,LH-10)); sv.drawsBackground=false; sv.borderType=0;
sv.hasVerticalScroller=true; sv.autohidesScrollers=true; sv.scrollerStyle=1; cv.addSubview(sv);
var SVH=LH-10, doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,SVH)); sv.documentView=doc;
var empty=label("",0,0,LW,18,12.5,$.NSFontWeightRegular,1); empty.textColor=$.NSColor.secondaryLabelColor; doc.addSubview(empty);
var NF=$.NSFont.systemFontOfSizeWeight(13.5,$.NSFontWeightSemibold), TAGF=$.NSFont.systemFontOfSizeWeight(9.5,$.NSFontWeightBold);
var RW=LW-18, RCW=230;
Z.forEach(function(z){
 var rv=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,RW,ROWH)); doc.addSubview(rv); z.view=rv;
 var hl=rbox(6,3,RW-6,ROWH-6,ACCENT.colorWithAlphaComponent(DARK?0.22:0.13),9); hl.hidden=true; rv.addSubview(hl); z.hl=hl;
 var sep=rbox(56,ROWH-0.5,RW-56-12,1,G(DARK?0.16:0.14)); rv.addSubview(sep); z.sep=sep;
 var fl=label(flag(z.cc),16,(ROWH-26)/2,32,26,20,$.NSFontWeightRegular,1); fl.font=$.NSFont.systemFontOfSize(20); rv.addSubview(fl);
 var nx=58, nw=RW-nx-RCW-24, cw=Math.min(tw(z.city,NF)+6,nw-(z===CURZ?70:0));
 var nl=label(z.city,nx,ROWH/2+1,cw,18,13.5,$.NSFontWeightSemibold); nl.font=NF; nl.cell.lineBreakMode=4; rv.addSubview(nl);
 if(z===CURZ){ var tw0=tw("CURRENT",TAGF)+14, tx=nx+cw+6;
  var tb=$.NSBox.alloc.initWithFrame($.NSMakeRect(tx,ROWH/2+2,tw0,16)); tb.boxType=4; tb.titlePosition=0; tb.cornerRadius=8; tb.borderWidth=0;
  tb.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.25:0.15); rv.addSubview(tb);
  var tl=label("CURRENT",tx,ROWH/2+3.5,tw0,13,9.5,$.NSFontWeightBold,1); tl.font=TAGF; tl.textColor=ACCENT; rv.addSubview(tl); }
 var sl=label(z.country+(z.note?"  ·  "+z.note:""),nx,ROWH/2-16,nw,15,11.5); sl.textColor=$.NSColor.secondaryLabelColor; sl.cell.lineBreakMode=4; rv.addSubview(sl);
 var gl=label(z.gen,RW-14-RCW,ROWH/2+1,RCW,18,12.5,$.NSFontWeightSemibold,2); gl.cell.lineBreakMode=4; rv.addSubview(gl);
 var ol=label("",RW-14-RCW,ROWH/2-16,RCW,15,11.5,$.NSFontWeightRegular,2); ol.textColor=$.NSColor.secondaryLabelColor;
 ol.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(11.5,$.NSFontWeightRegular); rv.addSubview(ol); z.ol=ol;
 var hit=$.TZHit.alloc.initWithFrame($.NSMakeRect(0,0,RW,ROWH)); hit.identifier=""+z.i; hit.toolTip=z.id; rv.addSubview(hit);
});
// The banner clock: the current zone's time, or a preview of the chosen zone's time ("→ Tokyo")
var C4CUR=c4.stringValue;
function updateClock(){ var z=SEL>=0?Z[SEL]:null;
 if(z && z!==CURZ){ c3.stringValue=timeIn(z.id); c4.stringValue=(DRY?"Preview only  ·  ":"")+"→  "+flag(z.cc)+"  "+z.city+"  ·  "+offStr(z.off);
  c4.toolTip="What your clock will show after you set "+z.city; }
 else { c3.stringValue=CURZ?timeIn(CURZ.id):(tfmt(),df.timeZone=$.NSTimeZone.localTimeZone,U(df.stringFromDate(NOW))); c4.stringValue=C4CUR; } }
// every time on screen follows the 24-hour switch, so the user sees the change before applying it
function refreshTimes(){ Z.forEach(function(z){ z.time=timeIn(z.id); z.ol.stringValue=offStr(z.off)+"  ·  "+z.time; });
 updateClock(); }

// Footer: what will change on the left, Cancel + Set on the right, note above
if(DRY){ var nt=label(DNOTE,PAD,noteY,W-2*PAD,16,12,$.NSFontWeightSemibold,1); nt.textColor=ACCENT; cv.addSubview(nt); }   // dry run: say so plainly
var summary=label("",PAD+4,PBY+(PBH-18)/2,W-2*PAD-PBW-PBW2-24,18,13,$.NSFontWeightSemibold); summary.cell.lineBreakMode=4; cv.addSubview(summary);
var pc=pill(L_CANCEL,W-PAD-PBW2-12-PBW,PBY,PBW,PBH,hd,'no:','\u001b',false);
var pk=pill(L_SET,W-PAD-PBW2,PBY,PBW2,PBH,hd,'ok:','\r',true);

var VISZ=[];
function layout(){
 // tidy offsets so "GMT -6", "utc−6", "utc 9", "UTC+09" all match: gmt → utc, true minus → -, no space after utc,
 // a bare number after utc gets a +, and a leading zero is dropped
 var q=ObjC.unwrap(search.stringValue).toLowerCase().trim().replace(/_/g," ").replace(/−/g,"-").replace(/\bgmt\b|\bgmt(?=[+-\d])/g,"utc")
   .replace(/utc\s*([+-])\s*/g,"utc$1").replace(/utc\s+(\d)/g,"utc+$1").replace(/utc(\d)/g,"utc+$1").replace(/utc([+-])0(\d)/g,"utc$1$2");
 var words=q.split(/\s+/).filter(function(w){return w;});
 VISZ=Z.filter(function(z){ return words.every(function(w){ return wordHit(z,w); }); });
 // best matches first: an exact city / country / zone / abbreviation, then names that start with the search, then the rest
 // best matches first: 0 = exactly a name / city / country / offset / alias word, 1 = a name starts with it or
 // contains the whole phrase, 2 = the rest. Ties: the main zone of a region and well-known cities, then by offset.
 if(q){ var ql=q;
  VISZ.forEach(function(z){
   z.score = (z.names.indexOf(ql)>=0 || (words.length==1 && z.toks.indexOf(ql)>=0) || (" "+(ALIAS[z.id]||"")+" ").indexOf(" "+ql+" ")>=0) ? 0
           : (z.names.some(function(n){ return n.indexOf(ql)==0; }) || z.key.indexOf(ql)>=0) ? 1 : 2; });
  VISZ.sort(function(x,y){ return x.score-y.score || y.pop-x.pop || x.i-y.i; }); }
 var DH=Math.max(SVH,VISZ.length*ROWH); doc.frame=$.NSMakeRect(0,0,LW,DH);
 Z.forEach(function(z){ z.view.hidden=true; });
 VISZ.forEach(function(z,k){ z.view.frame=$.NSMakeRect(0,DH-(k+1)*ROWH,RW,ROWH); z.view.hidden=false; z.sep.hidden=(k==VISZ.length-1); });
 empty.hidden=VISZ.length>0; empty.stringValue="No time zones match “"+q+"”"; empty.frame=$.NSMakeRect(0,DH/2-9,LW,18);
 sv.hasVerticalScroller=(DH>SVH);
 // keep the selected zone in view if it's listed, else start at the top
 var k=-1; VISZ.forEach(function(z,j){ if(z.i==SEL) k=j; });
 var top=DH-SVH; if(k>=0 && !q){ var rowTop=DH-k*ROWH; top=Math.max(0,Math.min(DH-SVH,rowTop-SVH/2-ROWH/2)); }
 sv.contentView.scrollToPoint($.NSMakePoint(0,top)); sv.reflectScrolledClipView(sv.contentView);
}
// moveSel(+1 / -1): the next / previous zone in the list as it's shown now, kept in view
function moveSel(d){ if(!VISZ.length) return; var k=-1; VISZ.forEach(function(z,j){ if(z.i==SEL) k=j; });
 k = k<0 ? (d>0?0:VISZ.length-1) : Math.max(0,Math.min(VISZ.length-1,k+d)); SEL=VISZ[k].i; update();
 doc.scrollRectToVisible(VISZ[k].view.frame); }
function update(){
 Z.forEach(function(z){ z.hl.hidden = z.i!=SEL; });
 updateClock();
 var c=changed(), z=SEL>=0?Z[SEL]:null, bits=[];
 if(c.zone) bits.push(flag(z.cc)+"  "+z.city+"  ·  it's "+z.time+" there");
 if(c.auto) bits.push(AUTOSEL ? "📍  Automatic on" : "Automatic off");
 if(c.h24) bits.push(H24SEL ? "24-hour time" : "12-hour time");
 if(!c.any){ summary.stringValue = z===CURZ ? "This is your current time zone" : "Choose a time zone";
  summary.textColor=$.NSColor.secondaryLabelColor; pk.enable(false); return; }
 summary.stringValue=bits.join("   +   "); summary.textColor=$.NSColor.labelColor; pk.enable(true);
}
refreshTimes(); layout(); update();
win.center; win.makeKeyAndOrderFront(null); win.makeFirstResponder(search); app.activateIgnoringOtherApps(true);
try{ app.activate; }catch(e){} try{ $.NSRunningApplication.currentApplication.activateWithOptions(3); }catch(e){}   // macOS 14+: really come to the front
var resp=app.runModalForWindow(win); win.orderOut(null);
// Result: "zone<TAB>automatic(1/0)<TAB>24-hour(1/0)", or __CANCEL__
// Result: "zone<TAB>automatic<TAB>24-hour", or __CANCEL__. zone and 24-hour are filled in only when they change
// ("" = leave it); automatic is always the switch's final state (1 / 0).
var CHG=changed();
(resp==1 && CHG.any) ? [CHG.zone ? Z[SEL].id : "", AUTOSEL ? "1" : "0", CHG.h24 ? (H24SEL?"1":"0") : ""].join("\t") : "__CANCEL__";
JXA
  } > "$s"
  run_window "$s"
}

# --- Setting the zone ----------------------------------------------------------------------------
# apply_zone <zone> -> 0 if the Mac is now using it. Turns off automatic time zone first (if set to).
apply_zone() {
  local z="$1" out rc
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to change the time zone."; return 1; }   # belt and braces
  if (( ! amRoot )); then logMe ERROR "Setting the time zone needs root (run via Jamf or with sudo)."; return 1; fi
  if [[ "$TURN_OFF_AUTO_TIMEZONE" == true ]] && auto_zone_on; then
    set_auto false \
      && logMe INFO "Turned off \"Set time zone automatically\" so the new zone sticks." \
      || logMe WARN "Couldn't turn off \"Set time zone automatically\" — macOS may switch the zone back."
  fi
  out="$(/usr/sbin/systemsetup -settimezone "$z" 2>&1)"; rc=$?
  logMe INFO "systemsetup -settimezone $z -> exit $rc${out:+: ${${(f)out}[-1]}}"
  current_zone
  [[ "$REPLY" == "$z" ]]
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



# TZ_LIB=1 source Set_Time_Zone.sh  -> loads the functions without running anything (testing).
[[ -n "$TZ_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
current_zone; START_ZONE="$REPLY"
logMe INFO "============================================================"
logMe INFO "Set Time Zone $SCRIPT_VERSION — mode=${ACTION_MODE}$([[ $DRY_RUN == true ]] && print " (DRY RUN — nothing will be changed)"); current zone=${START_ZONE:-unknown}; automatic=$(auto_zone_on && print on || print off); target=${TARGET_ZONE:-<user picks>}; running as $(/usr/bin/id -un)"
(( amRoot )) || logMe INFO "Not running as root — the time zone can't be changed (run via Jamf or with sudo)."
if [[ "$ACTION_MODE" == verbose && -z "$consoleUser" ]] && (( amRoot )); then
  if [[ -n "$TARGET_ZONE" ]]; then logMe INFO "No one is logged in — setting the zone without windows."; ACTION_MODE="silent"
  else logMe INFO "No one is logged in, so there's no one to pick a zone. Nothing changed."; exit 0; fi
fi
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

# --- 1. What to change ------------------------------------------------------------------------------
# WANT_ZONE = a zone to set now, WANT_AUTO = automatic time zone afterwards (1 on / 0 off),
# WANT_24 = 1 / 0 to switch to 24- / 12-hour time. Blank = leave it.
WANT_ZONE=""; WANT_AUTO=""; WANT_24=""
if [[ -n "$TARGET_ZONE" ]]; then
  if is_auto "$TARGET_ZONE"; then WANT_AUTO=1
  elif valid_zone "$TARGET_ZONE"; then WANT_ZONE="$TARGET_ZONE"; WANT_AUTO=0   # a policy zone sticks: automatic off
  else
    logMe ERROR "\"$TARGET_ZONE\" isn't a time zone macOS knows (see: sudo systemsetup -listtimezones). Nothing changed."
    show_message "$FAIL_TITLE" "xmark.octagon.fill" fail "Your time zone wasn't changed\nThe time zone in this policy isn't valid. Contact IT." ""
    exit 1
  fi
else
  [[ "$ACTION_MODE" == silent ]] && { logMe ERROR "Silent mode needs the time zone to set in Parameter 4 (a zone, or auto)."; exit 1; }
  build_zones
  out="$(show_picker)"
  [[ "$out" == "__CANCEL__" || -z "$out" ]] && { logMe INFO "User closed the window. Nothing changed."; exit 0; }
  parts=("${(@ps:\t:)out}"); WANT_ZONE="$parts[1]"; WANT_AUTO="$parts[2]"; WANT_24="$parts[3]"
  [[ -n "$WANT_ZONE" ]] && ! valid_zone "$WANT_ZONE" && { logMe ERROR "The window returned an unknown zone ($WANT_ZONE). Nothing changed."; exit 1; }
  logMe INFO "User chose: zone=${WANT_ZONE:-unchanged} automatic=$([[ $WANT_AUTO == 1 ]] && print on || print off) 24-hour=${WANT_24:-unchanged}"
fi

# Everything below adds to one result window: HEAD (first line), BODY (detail lines), STATUS ok / warn / fail
HEAD=""; BODY=(); STATUS=ok; MSG24=""
say() { [[ -z "$HEAD" ]] && HEAD="$1" || BODY+=("$1"); }

# --- 2a. 24-hour time (the user's own setting; doesn't need root) --------------------------------
if [[ -n "$WANT_24" ]]; then
  W24=$([[ "$WANT_24" == 1 ]] && print 24 || print 12)
  if [[ "$DRY_RUN" == true ]]; then logMe INFO "DRY RUN — would switch to $W24-hour time."; MSG24="Your clock would switch to $W24-hour time."
  elif clock24_set $([[ "$WANT_24" == 1 ]] && print true || print false); then logMe INFO "Switched to $W24-hour time."; MSG24="Your clock now uses $W24-hour time."
  else logMe ERROR "Couldn't switch to $W24-hour time."; MSG24="Your clock couldn't be switched to $W24-hour time."; STATUS=fail; fi
fi

# --- 2b. A zone set by hand -----------------------------------------------------------------------
if [[ -n "$WANT_ZONE" ]]; then
  pretty_zone "$WANT_ZONE"; CITY="$REPLY"
  if [[ "$WANT_ZONE" == "$START_ZONE" ]] && ! auto_zone_on; then
    logMe INFO "The Mac is already set to $WANT_ZONE. Nothing to change."; zone_now "$WANT_ZONE"
    say "Your time zone is already $CITY"; BODY+=("It's $REPLY ($ZONE_ABBR, $ZONE_OFF).")
  elif [[ "$DRY_RUN" == true ]]; then
    zone_now "$WANT_ZONE"; logMe INFO "DRY RUN — would set the time zone to $WANT_ZONE (it's $REPLY there)."
    say "Your time zone would be set to $CITY"; BODY+=("It's $REPLY there ($ZONE_ABBR, $ZONE_OFF).")
  elif apply_zone "$WANT_ZONE"; then
    zone_now "$WANT_ZONE"; logMe INFO "Done: the time zone is now $WANT_ZONE (was ${START_ZONE:-unknown}). It's $REPLY $ZONE_ABBR."
    say "Your time zone is now $CITY"; BODY+=("It's $REPLY ($ZONE_ABBR, $ZONE_OFF). Your clock has updated.")
  else
    current_zone; logMe ERROR "FAILED: wanted $WANT_ZONE but the Mac is using ${REPLY:-unknown}."
    say "Your time zone couldn't be changed"; BODY+=("It's still set to ${${REPLY##*/}//_/ }. Contact IT if you need help."); STATUS=fail
  fi
fi

# --- 2c. Automatic time zone -----------------------------------------------------------------------
if [[ "$WANT_AUTO" == 1 ]] && { [[ -n "$WANT_ZONE" ]] || ! auto_zone_on; }; then
  NOFIX=""
  if (( amRoot )) && ! location_on; then NOFIX="Location Services is off, so your Mac can't find where you are. Turn it on in System Settings → Privacy & Security → Location Services."
  elif ! wifi_on; then NOFIX="Wi-Fi is off, so your Mac can't find its location (it uses nearby Wi-Fi networks). Turn Wi-Fi on; you don't have to join a network."; fi
  if [[ -n "$WANT_ZONE" ]]; then   # a zone was just set by hand; keep automatic on so it takes over when it can
    if [[ "$DRY_RUN" == true ]]; then BODY+=("Automatic time zone would stay on.")
    elif enable_auto; then logMe INFO "Automatic time zone left on (the zone was set by hand too).${NOFIX:+ $NOFIX}"
      BODY+=("Automatic time zone stays on, so it updates from your location when it can.")
    else logMe WARN "Couldn't turn automatic time zone back on."; BODY+=("Automatic time zone couldn't be turned back on."); fi
  elif [[ "$DRY_RUN" == true ]]; then
    logMe INFO "DRY RUN — would turn on automatic time zone.${NOFIX:+ $NOFIX}"
    say "Your Mac would set its time zone automatically."; [[ -n "$NOFIX" ]] && BODY+=("$NOFIX")
  elif enable_auto; then
    # macOS re-detects on its own; give it a few seconds so the window can show the new zone
    integer w=0; current_zone; while [[ "$REPLY" == "$START_ZONE" && -z "$NOFIX" ]] && (( w < 15 )); do /bin/sleep 1; (( w++ )); current_zone; done
    NOW_ZONE="$REPLY"; logMe INFO "Automatic time zone is on (was ${START_ZONE:-unknown}; now ${NOW_ZONE:-unknown}).${NOFIX:+ $NOFIX}"
    if [[ "$NOW_ZONE" != "$START_ZONE" ]]; then pretty_zone "$NOW_ZONE"; zone_now "$NOW_ZONE"
      say "Your Mac now sets its time zone automatically"; BODY+=("It's now set to ${${NOW_ZONE##*/}//_/ } ($ZONE_ABBR), and it follows you when you travel.")
    elif [[ -n "$NOFIX" ]]; then say "Automatic time zone is on, but your Mac can't find its location yet"; BODY+=("$NOFIX"); STATUS=warn
    else say "Your Mac now sets its time zone automatically"; BODY+=("It uses your location and may take a minute to update.")
    fi
  else logMe ERROR "FAILED: couldn't turn on automatic time zone."; say "Automatic time zone couldn't be turned on"; STATUS=fail; fi
elif [[ "$WANT_AUTO" == 0 && -z "$WANT_ZONE" ]] && auto_zone_on; then   # just switch automatic off, keep the zone
  current_zone; pretty_zone "$REPLY"
  if [[ "$DRY_RUN" == true ]]; then logMe INFO "DRY RUN — would turn off automatic time zone."; say "Automatic time zone would be turned off"; BODY+=("Your time zone would stay $REPLY.")
  elif (( amRoot )) && set_auto false; then logMe INFO "Turned off automatic time zone; the zone stays ${REPLY}."; say "Automatic time zone is off"; BODY+=("Your time zone stays $REPLY.")
  else logMe ERROR "Couldn't turn off automatic time zone (needs root)."; say "Automatic time zone couldn't be turned off"; STATUS=fail; fi
fi

# --- 3. Tell the user ------------------------------------------------------------------------------
[[ -n "$MSG24" ]] && say "$MSG24"     # the clock change goes last (or first, when it's the only change)
[[ -z "$HEAD" ]] && { logMe INFO "Nothing to change."; exit 0; }
MSG="$HEAD"; (( ${#BODY} )) && MSG+="\n${(j: :)BODY}"
if [[ "$DRY_RUN" == true ]]; then show_message "$DRY_TITLE" "eye.circle.fill" ok "Preview only — nothing was changed\n$HEAD${${(j: :)BODY}:+. ${(j: :)BODY}}" ""
elif [[ "$STATUS" == fail ]]; then [[ "$MSG" == *"Contact IT"* ]] || MSG+=" Contact IT if you need help."; show_message "$FAIL_TITLE" "xmark.octagon.fill" fail "$MSG" ""; exit 1
elif [[ "$STATUS" == warn ]]; then show_message "Automatic Time Zone Is On" "exclamationmark.triangle.fill" fail "$MSG" ""
else show_message "$DONE_TITLE" "checkmark.circle.fill" ok "$MSG" ""; fi
exit 0
