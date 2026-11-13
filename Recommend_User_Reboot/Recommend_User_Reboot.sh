#!/bin/zsh

####################################################################################################
#
# Recommend User Reboot
#
# Purpose: Reminds the logged-in user to restart their Mac once it has been up longer than a set number of
#          days. A branded reminder shows how long it's been and why restarting helps; if they choose
#          Restart Now, a live countdown gives them time to save their work. Skips the reminder while
#          they're in a meeting or presenting. Optionally limits how many times they can postpone.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit and
#       shown in the console user's session, so it works when run as root from Jamf.
#
# What the user sees:
#   1. Reminder  — how many days since the last restart (and the date), why restarting helps, and
#                  Restart Now / Not Now. With a postpone limit, how many postpones are left; at the
#                  limit, only Restart Now.
#   2. Countdown — a live countdown ring (default 2 minutes) to save work, then the Mac restarts.
#                  Restart Now restarts straight away.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Recurring check-in (once a day):  Parameter 4 = 14  — reminds once the Mac has been up 14+ days
#   Self Service ("Restart my Mac"):   Parameter 4 = 0   — always shows the reminder
#   Test a policy safely:              Parameter 6 = dry — shows the windows, never restarts
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Uptime days before reminding (blank = 14)
#   Parameter 5 Label:  Countdown minutes before restart (blank = 2)
#   Parameter 6 Label:  Action Mode (verbose or dry)
#   Parameter 7 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 8 Label:  Banner Color (hex, optional)
#   Parameter 9 Label:  Brand Name (optional)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Uptime days   remind once the Mac has been up at least this many days. 0 = always remind.
#     $5  Countdown     minutes to save work after Restart Now, before the Mac restarts.
#     $6  Action Mode   verbose (or blank) = normal. dry = show the windows but never restart, and skip
#                       the uptime and meeting checks so the reminder always appears (for testing).
#     $7  Brand Icon    logo for the windows. Blank = BRAND_ICON from the Config block.
#                       examples: /Library/Application Support/Acme/logo.png
#                                 /Applications/Self Service.app
#                                 https://acme.com/logo.png
#                                 sf:arrow.clockwise.circle.fill
#                                 selfservice   (your Jamf Self Service branding logo)
#     $8  Banner Color  hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                       "auto-dark" (deeper logo shade for white text). Blank = bannerColor below.
#     $9  Brand Name    small line above the banner title, e.g. "Acme IT Support".
#
#   Upgrading from 2.0: Parameter 6 "dry" still means a dry run. 2.0 defaulted to a dry run when
#   Parameter 6 was blank; 3.0 restarts normally when it's blank.
# ---------------------------------------------------------------------------------------------
#
# TESTING (nothing restarts with "dry"):
#   ./Recommend_User_Reboot.sh 14 1 dry                 # the windows with a 1-minute countdown
#   ./Recommend_User_Reboot.sh 14 1 dry "sf:arrow.clockwise.circle.fill" "#1F6FEB" "Acme IT"
#
# Exit codes: 0 always (not due, deferred, skipped for a meeting, restarting, or dry run).
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
# 3.0 11/13/26 - Redesign to match the other Self Service tools: branded windows (logo, brand name,
#               banner colour, light/dark), the days since the last restart and why it helps, an
#               optional postpone limit (MAX_DEFERRALS), a countdown ring, branding in $7-$9.
#               Parameter 6 blank now means a normal run (2.0 defaulted to a dry run). - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# WHEN TO REMIND ------------------------------------------------------------
UPTIME_DAYS=1              # remind once the Mac has been up this many days ($4). 0 = always remind
RESTART_MINUTES=2           # countdown minutes to save work after Restart Now ($5)
MAX_DEFERRALS=0             # how many times the user can choose Not Now before only Restart Now is offered.
                            # 0 = no limit. The count resets after each restart.
SKIP_DURING_MEETINGS=true   # true = don't remind while an app keeps the display awake (a call, a presentation)
IGNORE_ASSERTION_APPS="Amphetamine,caffeinate"   # apps that keep the display awake but aren't meetings
DRY_RUN_OVERRIDE=false      # true = ALWAYS a dry run (never restarts). Keep false for production.
STATE_FILE="/Library/Application Support/RecommendUserReboot/state.plist"   # remembers the postpone count
logFile="/var/log/recommend_user_reboot.log"   # this script's own run log

# BRANDING (windows only) ---------------------------------------------------
BRAND_NAME="Wave IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($9)
BRAND_ICON="ss"              # optional logo ($7). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:arrow.clockwise.circle.fill    (tinted to match the theme)
                           #   • Self Service   selfservice (or: ss) — your Jamf Self Service branding logo
                           # Blank = no logo.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto = follow the user's Light/Dark setting; light or dark forces one.

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto".
bannerColor="auto"         # banner + main button ($8). auto = the logo's exact main colour;
                           # auto-dark = a deeper shade of it for white text; no logo = #0056D2
BANNER_TEXT_COLOR="auto"   # auto = white, or near-black if the banner is too light for white
ACCENT_COLOR="auto"        # icons, countdown ring, buttons. auto = the banner colour, made readable
SPINNER_BG_COLOR="auto"    # auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # auto = Apple green
FAIL_COLOR="auto"          # auto = Apple red

# TEXT ----------------------------------------------------------------------
REMIND_TITLE="Time to Restart"
REMIND_SUBTITLE="A quick restart keeps your Mac running its best"
COUNTDOWN_TITLE="Restarting Soon"
COUNTDOWN_SUBTITLE="Your Mac restarts when the timer ends"
DRY_NOTE="Preview only — your Mac won't restart."   # shown in dry runs
restartButton="Restart Now"
laterButton="Not Now"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent
zmodload zsh/datetime 2>/dev/null

SCRIPT_VERSION="3.0"
SCRATCH="/tmp/recommend-reboot.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$RR_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # RR_DEBUG=1 keeps the scratch folder (testing)
STATUS_FILE="$SCRATCH/status.txt"; CANCEL_FILE="$SCRATCH/cancel.flag"; : > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"
REVIEW_FILE="$SCRATCH/info.txt"

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point ($1 "/"), computer name ($2) and user ($3) first; strip that trio.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
[[ "$1" == <-> ]] && UPTIME_DAYS=$1
[[ "$2" == <-> && "$2" -gt 0 ]] && RESTART_MINUTES=$2
DRY_RUN=false; [[ "${3:l}" == (dry|dry-run|preview|true|yes|1) ]] && DRY_RUN=true
[[ -n "$4" ]] && BRAND_ICON="$4"
[[ -n "$5" ]] && bannerColor="$5"
[[ -n "$6" ]] && BRAND_NAME="$6"
APPEARANCE="${APPEARANCE:l}"; [[ "$APPEARANCE" == (light|dark) ]] || APPEARANCE="auto"
[[ "$DRY_RUN_OVERRIDE" == true ]] && DRY_RUN=true
ACTION_MODE="verbose"

# --- Console / user resolution ----------------------------------------------
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}
USER_HOME=""
if [[ -n "$consoleUser" ]]; then
  USER_HOME=$(/usr/bin/dscl . -read /Users/"$consoleUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$consoleUser"
fi

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

# Update the live progress window: 1 = chip (the certificate's name), 2 = right-hand text ("2 of 3 certificates"),
#   3 = "done/total" for the progress bar, 4 = what is happening ("Removing")
spin_status() {
  print -rl -- "$1" "$2" "$3" "$4" > "$STATUS_FILE" 2>/dev/null
  /bin/chmod 644 "$STATUS_FILE" 2>/dev/null
}

# --- Progress window ----------------------------------------------------------------------------
# Same branded header as the other windows (logo, brand name, rounded title) with a Cancel pill,
# then a colourful arc spinner, the certificate being worked on (as a chip), a
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
  else { fic.image=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(isPath?"folder":"checkmark.seal",""); fic.contentTintColor=ACCENT; }
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

# --- Shared window pieces ----------------------------------------------------------------------------
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
  /bin/chmod 644 "$1" "$REVIEW_FILE" 2>/dev/null
  run_as_user /usr/bin/osascript -l JavaScript "$1" 2>>"$SCRATCH/jxa-err.log"
}



# --- Uptime, meetings, postpone count ----------------------------------------------------------
# uptime_info -> BOOT_EPOCH, UP_DAYS (whole days), UP_TEXT ("16 days", "1 day", "5 hours")
uptime_info() {
  # kern.boottime looks like "{ sec = 1794500000, usec = 123 } ..." — take the first number
  BOOT_EPOCH=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/awk -F'[= ,]+' '{print $3}')
  local secs=$(( EPOCHSECONDS - ${BOOT_EPOCH:-$EPOCHSECONDS} )); UP_DAYS=$(( secs / 86400 ))
  if (( UP_DAYS >= 1 )); then UP_TEXT="$UP_DAYS day$( (( UP_DAYS == 1 )) || print s)"
  else local h=$(( secs / 3600 )); UP_TEXT="$h hour$( (( h == 1 )) || print s)"; fi
}
# in_meeting -> 0 if an app is keeping the display awake (a call, a presentation), except IGNORE_ASSERTION_APPS.
# REPLY = the app's name.
in_meeting() {
  local apps app; local -a ignore=("${(@s:,:)IGNORE_ASSERTION_APPS}"); REPLY=""
  apps="$(/usr/bin/pmset -g assertions 2>/dev/null | /usr/bin/awk \
    '/NoDisplaySleepAssertion | PreventUserIdleDisplaySleep/ && match($0,/\(.+\)/) && ! /coreaudiod/ \
     {gsub(/^.*\(/,"",$0); gsub(/\).*$/,"",$0); print}')"
  for app in ${(f)apps}; do (( ${ignore[(Ie)$app]} )) && continue; REPLY="$app"; return 0; done
  return 1
}
# Postpones are counted per boot: a restart starts the count again.
deferrals_get() {
  local b=$(/usr/bin/defaults read "$STATE_FILE" BootEpoch 2>/dev/null) n=$(/usr/bin/defaults read "$STATE_FILE" Deferrals 2>/dev/null)
  [[ "$b" == "$BOOT_EPOCH" && "$n" == <-> ]] && REPLY=$n || REPLY=0
}
deferrals_set() {
  (( amRoot )) || return 0
  /bin/mkdir -p "${STATE_FILE:h}" 2>/dev/null
  /usr/bin/defaults write "$STATE_FILE" BootEpoch -int "$BOOT_EPOCH" 2>/dev/null
  /usr/bin/defaults write "$STATE_FILE" Deferrals -int "$1" 2>/dev/null
}

# --- Reminder window --------------------------------------------------------------------------------
# show_reminder <deferralsLeft (-1 = no limit)> -> prints RESTART or LATER
show_reminder() {
  local s="$SCRATCH/remind.jxa" first greet hour
  first="$(/usr/bin/id -F "$consoleUser" 2>/dev/null | /usr/bin/awk '{print $1}')"
  hour=$(/bin/date +%H); case $hour in 0[0-9]|1[0-1]) greet="Good morning";; 1[2-7]) greet="Good afternoon";; *) greet="Good evening";; esac
  {
    win_prelude
    print -r -- "var RTITLE=\"$(as_esc "$REMIND_TITLE")\", RSUB=\"$(as_esc "$REMIND_SUBTITLE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\", DRY=$DRY_RUN;"
    print -r -- "var GREET=\"$(as_esc "$greet${first:+, $first}")\", UPTXT=\"$(as_esc "$UP_TEXT")\", UPDAYS=$UP_DAYS, BOOT=${BOOT_EPOCH:-0}, GOAL=$UPTIME_DAYS, MINS=$RESTART_MINUTES, LEFT=$1;"
    print -r -- "var L_RESTART=\"$(as_esc "$restartButton")\", L_LATER=\"$(as_esc "$laterButton")\";"
    /bin/cat <<'JXA'
if(!$.RRRemind){ObjC.registerSubclass({name:'RRRemind',superclass:'NSObject',methods:{
 'yes:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'tick:':{types:['void',['id']],implementation:function(t){ big.stringValue=upLive(); }}}});}
var hd=$.RRRemind.alloc.init;
// Live uptime, from the boot time: "16d 4h 12m 33s" (ticks every second)
function p2(n){ return (n<10?"0":"")+n; }
function upLive(){ var s=Math.max(0,Math.floor(Date.now()/1000)-BOOT), d=Math.floor(s/86400), h=Math.floor(s%86400/3600), m=Math.floor(s%3600/60), x=s%60;
 return (d?d+"d ":"")+(d||h?h+"h ":"")+p2(m)+"m "+p2(x)+"s"; }
if(!$.RRPanel){ObjC.registerSubclass({name:'RRPanel',superclass:'NSPanel',methods:{'canBecomeKeyWindow':{types:['bool',[]],implementation:function(){ return true; }}}});}
var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], bd=new Date(BOOT*1000);
var BOOTSTR=MON[bd.getMonth()]+" "+bd.getDate()+(bd.getFullYear()!=new Date().getFullYear()?", "+bd.getFullYear():"");

var W=600, PAD=24, BH=(BNAME?96:84), PBW=150, PBW2=180, PBH=34, PBY=18, canLater=(LEFT!=0);
var noteY=PBY+PBH+12, NOTEH=(DRY||LEFT>=0)?16:0, whyY=noteY+NOTEH+((DRY||LEFT>=0)?12:4), WHYH=3*46+14, upY=whyY+WHYH+12, UPH=(GOAL>0?120:84), grY=upY+UPH+12, GRH=22;
var H=grY+GRH+16+BH;
var win=$.RRPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15)|(1<<7),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR; win.hidesOnDeactivate=false; win.level=3;
[0,1,2].forEach(function(i){ var bt=win.standardWindowButton(i); if(isOk(bt)) bt.hidden=true; });   // no close button: choose one
var cv=win.contentView;
header(cv,W,H,BH,PAD,RTITLE,RSUB,DRY?"Preview only":"",DRY?"eye.fill":"");
function card(x,y,w,h){ var b=rbox(x,y,w,h,DARK?C([1,1,1],0.06):C([0,0,0],0.045),12);
 b.borderWidth=1; b.borderColor=DARK?C([1,1,1],0.12):C([0,0,0],0.09); cv.addSubview(b); return b; }

// Greeting
var gl=label(GREET+"!",PAD+2,grY,W-2*PAD,GRH,15,$.NSFontWeightSemibold); gl.font=rounded(15,$.NSFontWeightSemibold); cv.addSubview(gl);

// How long it's been: the big number, the date, and a bar toward the goal
card(PAD,upY,W-2*PAD,UPH);
var big=label(upLive(),PAD+20,upY+UPH-48,W-2*PAD-40,36,30,$.NSFontWeightBold,1); big.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(30,$.NSFontWeightBold); big.textColor=ACCENT; cv.addSubview(big);
var since=label("Your Mac has been on this long — it last restarted on "+BOOTSTR,PAD+20,upY+UPH-68,W-2*PAD-40,17,12.5,$.NSFontWeightRegular,1); since.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(since);
if(GOAL>0){ var BW=W-2*PAD-40, bx=PAD+20, by=upY+34, SCALE=Math.max(GOAL*2,UPDAYS), gx=bx+BW*GOAL/SCALE, over=UPDAYS-GOAL;
 var LATE=DARK?C([1,0.62,0.04]):C([0.85,0.42,0.0]);
 cv.addSubview(rbox(bx,by,BW,6,ACCENT.colorWithAlphaComponent(DARK?0.20:0.14),3));
 cv.addSubview(rbox(bx,by,Math.max(6,BW*Math.min(UPDAYS,GOAL)/SCALE),6,ACCENT,3));            // up to the goal
 if(over>0) cv.addSubview(rbox(gx,by,Math.max(4,BW*over/SCALE),6,LATE,3));                    // past it, in orange
 cv.addSubview(rbox(gx-1,by-3,2,12,$.NSColor.secondaryLabelColor));
 var gt=label(over>0 ? over+" day"+(over==1?"":"s")+" overdue  ·  restart every "+GOAL+" days" : "Restart every "+GOAL+" days",bx,by-22,BW,14,10.5,$.NSFontWeightSemibold,1);
 gt.textColor=over>0?LATE:$.NSColor.secondaryLabelColor; cv.addSubview(gt); }

// Why
card(PAD,whyY,W-2*PAD,WHYH);
[["lock.shield.fill","Installs security updates","Many updates only finish after a restart."],
 ["bolt.fill","Speeds things up","Clears memory and stuck apps so your Mac feels fresh."],
 ["clock.fill","Takes about two minutes","You get "+MINS+" minute"+(MINS==1?"":"s")+" to save your work first."]].forEach(function(r,k){
 var y=whyY+WHYH-7-(k+1)*46;
 cv.addSubview(rbox(PAD+14,y+(46-30)/2,30,30,ACCENT.colorWithAlphaComponent(DARK?0.20:0.12),8));
 var si=sym(r[0],PAD+14+7,y+(46-16)/2,16,ACCENT); if(si) cv.addSubview(si);
 var t=label(r[1],PAD+56,y+46/2+1,W-2*PAD-70,17,12.5,$.NSFontWeightSemibold); cv.addSubview(t);
 var d=label(r[2],PAD+56,y+46/2-15,W-2*PAD-70,15,11.5); d.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(d);
 if(k<2) cv.addSubview(rbox(PAD+56,y,W-2*PAD-70,1,G(DARK?0.16:0.12))); });

// Footer: a note about postpones (or the dry run), and the buttons, centred
var note = DRY ? DNOTE : (LEFT>0 ? "You can postpone "+LEFT+" more time"+(LEFT==1?"":"s")+"." : (LEFT==0 ? "You've postponed the most times allowed — please restart now." : ""));
if(note){ var nt=label(note,PAD,noteY,W-2*PAD,16,12,$.NSFontWeightSemibold,1); nt.textColor=(DRY||LEFT==0)?ACCENT:$.NSColor.secondaryLabelColor; cv.addSubview(nt); }
if(canLater){ var BX=(W-(PBW+12+PBW2))/2;
 pill(L_LATER,BX,PBY,PBW,PBH,hd,'no:','\u001b',false); pill(L_RESTART,BX+PBW+12,PBY,PBW2,PBH,hd,'yes:','\r',true); }
else pill(L_RESTART,(W-PBW2)/2,PBY,PBW2,PBH,hd,'yes:','\r',true);
var upTimer=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1,hd,'tick:',null,true);
$.NSRunLoop.currentRunLoop.addTimerForMode(upTimer,$.NSRunLoopCommonModes);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
try{ $.NSRunningApplication.currentApplication.activateWithOptions(3); }catch(e){}
var resp=app.runModalForWindow(win); win.orderOut(null);
resp==1 ? "RESTART" : "LATER";
JXA
  } > "$s"
  run_window "$s"
}

# --- Countdown window ------------------------------------------------------------------------------
# show_countdown <seconds> -> blocks until the timer runs out or the user clicks Restart Now
show_countdown() {
  local s="$SCRATCH/count.jxa"
  {
    win_prelude
    print -r -- "var CTITLE=\"$(as_esc "$COUNTDOWN_TITLE")\", CSUB=\"$(as_esc "$COUNTDOWN_SUBTITLE")\", TOTAL=$1, DRY=$DRY_RUN, L_RESTART=\"$(as_esc "$restartButton")\";"
    /bin/cat <<'JXA'
ObjC.import('CoreGraphics');
var LEFTS=TOTAL;
function fmt(s){ var m=Math.floor(s/60), x=s%60; return m+":"+(x<10?"0":"")+x; }
if(!$.RRCount){ObjC.registerSubclass({name:'RRCount',superclass:'NSObject',methods:{
 'tick:':{types:['void',['id']],implementation:function(t){ LEFTS--; if(LEFTS<=0){ $.NSApplication.sharedApplication.stopModalWithCode(2); return; }
   big.stringValue=fmt(LEFTS); ring.needsDisplay=true; }},
 'app:':{types:['void',['id']],implementation:function(s){ var a=SHOWN[s.tag]; if(a) bringApp(a); }},
 'now:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});}
var hd=$.RRCount.alloc.init;
// ---- sizes and positions (bottom-up) ----
var W=500, PAD=24, BH=(BNAME?96:84), PBW2=180, PBH=34, PBY=20, CHIPH=26, CHIPG=6;
var tipY=PBY+PBH+16, TIPH=48+1+28+2*CHIPH+CHIPG+16, atY=tipY+TIPH+12, RS=150, ringY=atY+18+10;
var H=ringY+RS+22+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR; win.level=3;
[0,1,2].forEach(function(i){ var bt=win.standardWindowButton(i); if(isOk(bt)) bt.hidden=true; });
var cv=win.contentView;
header(cv,W,H,BH,PAD,CTITLE,CSUB,DRY?"Preview only":"",DRY?"eye.fill":"");
// the ring: a faint track and an accent arc that shrinks as time runs out
if(!$.RRRing){ ObjC.registerSubclass({name:'RRRing',superclass:'NSView',methods:{'drawRect:':{implementation:function(r){
  var b=this.bounds, c=$.NSMakePoint(b.size.width/2,b.size.height/2), R=b.size.width/2-8;
  var tr=$.NSBezierPath.bezierPath; tr.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle(c,R,0,360); tr.lineWidth=10;
  ACCENT.colorWithAlphaComponent(DARK?0.20:0.14).setStroke; tr.stroke;
  var f=LEFTS/TOTAL, p=$.NSBezierPath.bezierPath; p.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngleClockwise(c,R,90,90-360*f,true);
  p.lineWidth=10; p.lineCapStyle=1; ACCENT.setStroke; p.stroke; }}}}); }
var ring=$.RRRing.alloc.initWithFrame($.NSMakeRect((W-RS)/2,ringY,RS,RS)); cv.addSubview(ring);
var big=label(fmt(LEFTS),(W-RS)/2,ringY+RS/2-8,RS,40,34,$.NSFontWeightBold,1); big.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(34,$.NSFontWeightBold); cv.addSubview(big);
var sm=label("until restart",(W-RS)/2,ringY+RS/2-26,RS,16,11.5,$.NSFontWeightMedium,1); sm.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(sm);
// when it will happen, as a clock time
var at=new Date(Date.now()+TOTAL*1000), ah=at.getHours(), am=at.getMinutes();
var atl=label((DRY?"Preview only  ·  would restart at ":"Restarts at ")+((ah%12)||12)+":"+(am<10?"0":"")+am+(ah<12?" AM":" PM"),PAD,atY,W-2*PAD,18,12.5,$.NSFontWeightSemibold,1);
atl.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(atl);
// the card: "Save your work", then the apps that are still open
var cb=rbox(PAD,tipY,W-2*PAD,TIPH,DARK?C([1,1,1],0.06):C([0,0,0],0.045),12); cb.borderWidth=1; cb.borderColor=DARK?C([1,1,1],0.12):C([0,0,0],0.09); cv.addSubview(cb);
var sy=tipY+TIPH-6-48;
cv.addSubview(rbox(PAD+14,sy+(48-30)/2,30,30,ACCENT.colorWithAlphaComponent(DARK?0.20:0.12),8));
var si=sym("doc.text.fill",PAD+14+7,sy+(48-16)/2,16,ACCENT); if(si) cv.addSubview(si);
cv.addSubview(label("Save your work",PAD+56,sy+48/2+1,W-2*PAD-70,17,12.5,$.NSFontWeightSemibold));
var sd=label("Apps with unsaved changes will ask before they close.",PAD+56,sy+48/2-15,W-2*PAD-70,15,11.5); sd.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(sd);
cv.addSubview(rbox(PAD+14,sy,W-2*PAD-28,1,G(DARK?0.16:0.12)));
var ohY=sy-24, oh=label("",PAD+16,ohY,W-2*PAD-32,15,10.5,$.NSFontWeightBold); oh.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(oh);
var CX0=PAD+16, CXW=W-2*PAD-32, chipsTop=ohY-6, CHF=$.NSFont.systemFontOfSizeWeight(11.5,$.NSFontWeightMedium), CHIPS=[], SHOWN=[], LASTKEY="";
var done=label("",CX0,chipsTop-CHIPH-12,CXW,18,12.5,$.NSFontWeightSemibold,1); done.textColor=OKC; cv.addSubview(done);
// openApps(): the user's regular apps (the ones in the Dock), not Finder and not this window
function openApps(){ var me=$.NSRunningApplication.currentApplication.processIdentifier, out=[], l=$.NSWorkspace.sharedWorkspace.runningApplications;
 for(var i=0;i<l.count;i++){ var a=l.objectAtIndex(i);
  if(a.activationPolicy!=0 || a.processIdentifier==me || a.terminated) continue;
  if(ObjC.unwrap(a.bundleIdentifier)=="com.apple.finder") continue;
  out.push(a); }
 return out.sort(function(x,y){ return ObjC.unwrap(x.localizedName).localeCompare(ObjC.unwrap(y.localizedName)); }); }
// bringApp(app): puts that app in front so the user can save, and tucks this window just below its window
// (this window normally floats above everything). It comes back to the front when an app quits.
function topWindowOf(pid){ try{ var l=ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1|16,0));
 for(var i=0;i<l.count;i++){ var d=l.objectAtIndex(i);
  if(ObjC.unwrap(d.objectForKey("kCGWindowOwnerPID"))==pid && ObjC.unwrap(d.objectForKey("kCGWindowLayer"))==0) return ObjC.unwrap(d.objectForKey("kCGWindowNumber")); } }catch(e){} return 0; }
function bringApp(a){
 try{ $.NSApplication.sharedApplication.yieldActivationToApplication(a); }catch(e){}
 var ok=false; try{ ok=a.activateFromApplicationOptions($.NSRunningApplication.currentApplication,0); }catch(e){} if(!ok) try{ a.activateWithOptions(1|2); }catch(e){}
 win.level=0;
 $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.3));
 var wn=topWindowOf(a.processIdentifier); if(wn) win.orderWindowRelativeTo(-1,wn); else win.orderBack(null); }
function raiseSelf(){ if(win.level!=3){ win.level=3; win.orderFrontRegardless; } }
function chipW(a){ return Math.min(tw(ObjC.unwrap(a.localizedName)||"App",CHF)+38,CXW); }
// refreshApps(): redraws the chips (two rows at most, then "+N more") when the list of open apps changes
function refreshApps(){
 var apps=openApps(), key=apps.map(function(a){ return a.processIdentifier; }).join(",");
 if(key==LASTKEY) return;
 if(LASTKEY && key.split(",").length<LASTKEY.split(",").length) raiseSelf();   // an app quit: bring the countdown back
 LASTKEY=key;
 CHIPS.forEach(function(v){ v.removeFromSuperview; }); CHIPS=[]; SHOWN=[];
 oh.stringValue = apps.length ? "STILL OPEN  ·  CLICK ONE TO SAVE YOUR WORK IN IT" : "";
 done.stringValue = apps.length ? "" : "✓  Everything's closed — you're ready to restart";
 // lay out: fill row 1, then row 2; keep room on row 2 for a "+N more" chip if not everything fits
 var pos=[], x=CX0, row=0;
 for(var k=0;k<apps.length;k++){ var w=chipW(apps[k]); if(x+w>CX0+CXW){ row++; x=CX0; } if(row>1) break; pos.push([x,row,w]); x+=w+CHIPG; }
 if(pos.length<apps.length){ var moreW=function(n){ return tw("+"+n+" more",CHF)+22; };
  while(pos.length && (pos[pos.length-1][1]==1) && pos[pos.length-1][0]+pos[pos.length-1][2]+CHIPG+moreW(apps.length-pos.length+1)>CX0+CXW) pos.pop(); }
 pos.forEach(function(ps,k){ var a=apps[k], nm=ObjC.unwrap(a.localizedName)||"App", y=chipsTop-CHIPH-ps[1]*(CHIPH+CHIPG);
  var bg=rbox(ps[0],y,ps[2],CHIPH,DARK?C([1,1,1],0.08):C([1,1,1],0.92),CHIPH/2); bg.borderWidth=1; bg.borderColor=DARK?C([1,1,1],0.14):C([0,0,0],0.10); cv.addSubview(bg); CHIPS.push(bg);
  var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(ps[0]+6,y+(CHIPH-18)/2,18,18)); iv.image=a.icon; iv.imageScaling=3; cv.addSubview(iv); CHIPS.push(iv);
  var nl=label(nm,ps[0]+28,y+(CHIPH-16)/2,ps[2]-34,16,11.5,$.NSFontWeightMedium); nl.font=CHF; nl.cell.lineBreakMode=4; cv.addSubview(nl); CHIPS.push(nl);
  SHOWN.push(a); var ca=clickArea(ps[0],y,ps[2],CHIPH,hd,'app:',SHOWN.length-1,cv,true); ca.toolTip="Bring "+nm+" to the front"; CHIPS.push(ca); });
 if(pos.length<apps.length){ var n=apps.length-pos.length, more="+"+n+" more", mw=tw(more,CHF)+22, last=pos[pos.length-1];
  var mx=last?last[0]+last[2]+CHIPG:CX0, mr=last?last[1]:0; if(mx+mw>CX0+CXW){ mr=1; mx=CX0; }
  var my=chipsTop-CHIPH-mr*(CHIPH+CHIPG);
  var mb=rbox(mx,my,mw,CHIPH,ACCENT.colorWithAlphaComponent(DARK?0.18:0.10),CHIPH/2); cv.addSubview(mb); CHIPS.push(mb);
  var ml=label(more,mx,my+(CHIPH-16)/2,mw,16,11.5,$.NSFontWeightSemibold,1); ml.textColor=ACCENT; cv.addSubview(ml); CHIPS.push(ml);
  ml.toolTip=apps.slice(pos.length).map(function(a){ return ObjC.unwrap(a.localizedName); }).join(", "); }
}
refreshApps();
// update the list the moment an app opens or quits (and check twice a second, in case a notice is missed)
if(!$.RRWatch){ObjC.registerSubclass({name:'RRWatch',superclass:'NSObject',methods:{
 'changed:':{types:['void',['id']],implementation:function(n){ refreshApps(); }}}});}
var watch=$.RRWatch.alloc.init, wnc=$.NSWorkspace.sharedWorkspace.notificationCenter;
["NSWorkspaceDidTerminateApplicationNotification","NSWorkspaceDidLaunchApplicationNotification"].forEach(function(n){ wnc.addObserverSelectorNameObject(watch,'changed:',n,null); });
var appTimer=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(0.5,watch,'changed:',null,true);
$.NSRunLoop.currentRunLoop.addTimerForMode(appTimer,$.NSRunLoopCommonModes);
pill(L_RESTART,(W-PBW2)/2,PBY,PBW2,PBH,hd,'now:','\r',true);
var timer=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1,hd,'tick:',null,true);
$.NSRunLoop.currentRunLoop.addTimerForMode(timer,$.NSRunLoopCommonModes);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
try{ $.NSRunningApplication.currentApplication.activateWithOptions(3); }catch(e){}
var resp=app.runModalForWindow(win); win.orderOut(null); resp==1 ? "NOW" : "TIMEUP";
JXA
  } > "$s"
  run_window "$s"
}

# restart_mac -> restarts the way the Apple menu does (apps can still ask to save their work)
restart_mac() {
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to restart."; return 0; }   # belt and braces
  run_as_user /usr/bin/osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 \
    || { (( amRoot )) && /sbin/shutdown -r now >/dev/null 2>&1; }
}

# RR_LIB=1 source Recommend_User_Reboot.sh  -> loads the functions without running anything (testing).
[[ -n "$RR_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
uptime_info
logMe INFO "============================================================"
logMe INFO "Recommend User Reboot $SCRIPT_VERSION — up $UP_TEXT (remind at $UPTIME_DAYS days)$([[ $DRY_RUN == true ]] && print " (DRY RUN — the Mac won't restart)"); user=${consoleUser:-none}; running as $(/usr/bin/id -un)"
[[ -n "$consoleUser" ]] || { logMe INFO "No one is logged in, so there's no one to remind. Nothing to do."; exit 0; }

if [[ "$DRY_RUN" != true ]]; then
  (( UP_DAYS >= UPTIME_DAYS )) || { logMe INFO "Up $UP_TEXT — under $UPTIME_DAYS days. Nothing to do."; exit 0; }
  if [[ "$SKIP_DURING_MEETINGS" == true ]] && in_meeting; then
    logMe INFO "\"$REPLY\" is keeping the display awake (a call or presentation) — not reminding now."; exit 0
  fi
fi
resolve_brand_icon; build_palette

# --- 1. Remind -----------------------------------------------------------------------------------
LEFT=-1
if (( MAX_DEFERRALS > 0 )); then deferrals_get; USED=$REPLY; LEFT=$(( MAX_DEFERRALS - USED )); (( LEFT < 0 )) && LEFT=0; fi
logMe INFO "Showing the reminder$( (( LEFT >= 0 )) && print " ($LEFT postpone(s) left)")."
choice="$(show_reminder $LEFT)"
if [[ "$choice" != RESTART ]]; then
  (( MAX_DEFERRALS > 0 )) && { deferrals_set $(( USED + 1 )); logMe INFO "User chose Not Now ($(( USED + 1 )) of $MAX_DEFERRALS postpones used)."; } \
    || logMe INFO "User chose Not Now."
  exit 0
fi

# --- 2. Countdown, then restart --------------------------------------------------------------------
logMe INFO "User chose Restart Now — showing a $RESTART_MINUTES-minute countdown."
how="$(show_countdown $(( RESTART_MINUTES * 60 )))"
logMe INFO "$([[ $how == NOW ]] && print "User clicked Restart Now in the countdown" || print "Countdown finished") — restarting$([[ $DRY_RUN == true ]] && print " (DRY RUN: not really)")."
(( MAX_DEFERRALS > 0 )) && deferrals_set 0
restart_mac
exit 0
