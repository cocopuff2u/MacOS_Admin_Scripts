#!/bin/zsh

####################################################################################################
#
# Delete Expired Certificates
#
# Purpose: Finds certificates that have already expired in the logged-in user's login keychain and
#          the System keychain, backs each one up, and removes it. Expired certificates can't be used
#          for anything, but they pile up and can cause confusing sign-in, Wi-Fi, VPN and "certificate
#          not trusted" prompts.
#
#          Built for Jamf Self Service: the user sees every expired certificate (what it is, who issued
#          it, when it expired, and whether a newer copy is already installed), unchecks anything to
#          keep, and confirms. Or run it silently at check-in to clean up with no prompt.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works when run as root from Jamf.
#
# What the user sees:
#   1. Review  — expired certificates grouped by keychain, each with its name, issuer, expiry date and
#                a checkbox. "RENEWED" marks ones that already have a newer, valid copy installed.
#   2. Removing — a progress window while each certificate is backed up and removed.
#   3. Done    — how many were removed.
#   No expired certificates? They get a short "you're all set" window instead.
#
# Safety:
#   - Only certificates that have ALREADY expired are ever touched. Private keys are never removed.
#   - Anything whose name or issuer matches EXCLUDE_PATTERNS (default: Apple) is never removed.
#   - Every certificate is backed up (PEM) BEFORE it's removed; if the backup fails, it's kept.
#     Each run's backup folder has a manifest.txt with the command to put a certificate back.
#   - Dry run shows the whole experience but removes nothing.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY:
#
#   Self Service (the user reviews and confirms):  leave Parameter 4 blank (or "verbose").
#   Test a policy safely:                          Parameter 4 = dry      (nothing is removed)
#   Clean up at check-in, no windows:              Parameter 4 = silent
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose, dry, or silent)
#   Parameter 5 Label:  Exclude Patterns (comma-separated)
#   Parameter 6 Label:  Brand Icon (path, .app, URL, base64, sf:symbol, or selfservice — optional)
#   Parameter 7 Label:  Banner Color (hex, optional)
#   Parameter 8 Label:  Brand Name (optional)
#   Parameter 9 Label:  Appearance (auto, light, or dark)
#
#   When you add this script to a policy, fill the parameters like this:
#     $4  Action Mode   verbose = the user reviews and confirms (default)
#                       dry     = the same windows, but nothing is removed (to test a policy)
#                       silent  = no windows: removes every expired, non-excluded certificate
#     $5  Exclude       names or issuers to NEVER remove, comma-separated. Blank = EXCLUDE_PATTERNS
#                       below (Apple). Example: Apple, JSS Built-In, Acme Root CA
#     $6  Brand Icon    logo for the windows. Blank = BRAND_ICON from the Config block.
#                       examples: /Library/Application Support/Acme/logo.png
#                                 /Applications/Self Service.app
#                                 https://acme.com/logo.png
#                                 sf:checkmark.seal.fill
#                                 selfservice   (your Jamf Self Service branding logo)
#     $7  Banner Color  hex colour for the banner, e.g. #1F2937, "auto" (exact logo colour), or
#                       "auto-dark" (deeper logo shade for white text). Blank = bannerColor below.
#     $8  Brand Name    small line above the banner title, e.g. "Acme IT Support".
#     $9  Appearance    auto (follow the user's Light/Dark setting), light, or dark.
#
#   Upgrading from 1.x: Parameter 6 used to be "Dry Run". A policy that still has "dry" there keeps
#   working (it's read as a dry run, not a logo), but update the labels above when you can.
# ---------------------------------------------------------------------------------------------
#
# TESTING (nothing is removed with "dry"):
#   ./Delete_Expired_Certificates.sh dry                       # review window, preview only
#   ./Delete_Expired_Certificates.sh dry "" "sf:checkmark.seal.fill" "#1F6FEB" "Acme IT" dark
#   sudo ./Delete_Expired_Certificates.sh                      # the real thing, as Jamf runs it
#   Not running as root, only the login keychain can be changed, so the System keychain is skipped
#   (it's still listed in a dry run).
#
# Exit codes (Jamf treats any non-zero exit as a FAILED policy):
#   0 - removed, dry run, user cancelled, or nothing to do
#   1 - one or more certificates couldn't be backed up or removed
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 6/29/26 - Original Release - Native JXA/AppKit checklist + result window, login & System
#               keychain scan, PEM backup before delete, verbose/silent/dry-run modes. - @cocopuff2u
# 2.0 11/13/26 - Redesign to match App Uninstaller, Disk Usage and Network Health Check: branded
#               windows (logo, brand name, banner colour, light/dark), certificates grouped by
#               keychain with name, issuer and expiry, a RENEWED tag when a newer copy is installed,
#               removal progress and a summary window. Backups now include a manifest with restore
#               commands. Faster scan (one openssl call per certificate). Action Mode ($4) now takes
#               verbose / dry / silent; branding in $6-$9 ($6 "dry" from 1.x still works).
#               - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # true = ALWAYS run silently (no windows), whatever Parameter 4 says.
DRY_RUN_OVERRIDE=false  # true = ALWAYS preview (show the windows, remove NOTHING), whatever $4 says.
                        # Handy for testing by hand. Keep false for production.
SCAN_SYSTEM_KEYCHAIN=true    # also check /Library/Keychains/System.keychain (changing it needs root)

# WHAT TO KEEP --------------------------------------------------------------
EXCLUDE_PATTERNS=("Apple")   # certificates whose name OR issuer contains any of these are NEVER removed
                             # (case-insensitive). e.g. EXCLUDE_PATTERNS=("Apple" "JSS Built-In")
                             # Parameter 5, if set, REPLACES this list.

# WHERE THINGS GO -----------------------------------------------------------
BACKUP_PARENT="/var/log/expired-cert-backups"        # every removed certificate is saved here first,
                                                     # in a dated folder with a manifest.txt
logFile="/var/log/delete_expired_certificates.log"   # this script's own run log

# BRANDING (windows only) ---------------------------------------------------
BRAND_NAME="IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($8)
BRAND_ICON=""              # optional logo ($6). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:checkmark.seal.fill            (tinted to match the theme)
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
SUCCESS_COLOR="auto"       # "Certificates Removed" icon. auto = Apple green
FAIL_COLOR="auto"          # error icon. auto = Apple red

# TEXT ----------------------------------------------------------------------
REVIEW_TITLE="Expired Certificates"
REVIEW_MESSAGE="Uncheck any you want to keep. Click a certificate to see its details."
PREVIEW_MESSAGE="Uncheck any you want to keep. Click a certificate to see its details."   # REVIEW_MESSAGE in preview mode
REVIEW_NOTE="Expired certificates can't be used anymore and can cause sign-in, Wi-Fi or VPN prompts. A backup of each one is kept."
DRY_NOTE="Preview only — nothing will be removed, so you can click through everything safely."   # shown in dry runs
REMOVING_TITLE="Removing Certificates"
DONE_TITLE="Certificates Removed"
NONE_TITLE="No Expired Certificates"
DRY_TITLE="Preview Complete"
removeButton="Remove {N} Certificates"
previewButton="Finish Preview"      # replaces the Remove button in preview (dry-run) mode
cancelButton="Cancel"
okButton="Done"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent
zmodload zsh/datetime 2>/dev/null

SCRIPT_VERSION="2.0"
SCRATCH="/tmp/delete-expired-certs.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$DC_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # DC_DEBUG=1 keeps the scratch folder (testing)
STATUS_FILE="$SCRATCH/status.txt"    # the progress window polls this
CANCEL_FILE="$SCRATCH/cancel.flag"   # the progress window's Cancel button writes here
: > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"
REVIEW_FILE="$SCRATCH/review.tsv"    # rows for the review window
PEM_DIR="$SCRATCH/pem"; /bin/mkdir -p "$PEM_DIR"

# --- Argument parsing -------------------------------------------------------
# Jamf passes mount point ($1 "/"), computer name ($2) and user ($3) first; strip that trio.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
ACTION_MODE="${1:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
DRY_RUN=false
case "$ACTION_MODE" in
  dry|dry-run|preview) DRY_RUN=true; ACTION_MODE="verbose" ;;
  silent)              ;;
  *)                   ACTION_MODE="verbose" ;;
esac
if [[ -n "$2" ]]; then
  EXCLUDE_PATTERNS=()
  for p in "${(@s:,:)2}"; do p="${${p##[[:space:]]#}%%[[:space:]]#}"; [[ -n "$p" ]] && EXCLUDE_PATTERNS+=("$p"); done
fi
# 1.x compatibility: Parameter 6 was "Dry Run". "dry" there still means a dry run, not a logo.
if [[ "${3:l}" == (dry|dry-run|preview|true|yes|1) ]]; then DRY_RUN=true
elif [[ -n "$3" ]]; then BRAND_ICON="$3"; fi
[[ -n "$4" ]] && bannerColor="$4"
[[ -n "$5" ]] && BRAND_NAME="$5"
[[ -n "$6" ]] && APPEARANCE="$6"
APPEARANCE="${APPEARANCE:l}"; [[ "$APPEARANCE" == (light|dark) ]] || APPEARANCE="auto"
[[ "$HEADLESS" == true ]] && ACTION_MODE="silent"
[[ "$DRY_RUN_OVERRIDE" == true ]] && DRY_RUN=true

# --- Console / user resolution ----------------------------------------------
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}
# The keychain owner: the console user, else the user Jamf passed in.
kcUser="${consoleUser:-$JAMF_USER}"; [[ "$kcUser" == root ]] && kcUser=""
(( amRoot )) || kcUser="$(/usr/bin/id -un)"
USER_HOME=""
if [[ -n "$kcUser" ]]; then
  USER_HOME=$(/usr/bin/dscl . -read /Users/"$kcUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$kcUser"
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

# --- Shared window pieces (review window) -------------------------------------------------------
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

# pace_until <EPOCHREALTIME start> <seconds> -> wait until that many seconds have passed since start.
pace_until() { local left=$(( $2 - (EPOCHREALTIME - $1) )); (( left > 0.01 )) && /bin/sleep $(printf '%.2f' $left); return 0; }

# --- Finding expired certificates -------------------------------------------------------------
# One record per expired, non-excluded certificate (same index in each array):
#   C_SHA sha-1 · C_KC keychain path · C_LOGIN 1 = login keychain · C_PEM extracted PEM file
#   C_NAME display name · C_ISSUER issuer name · C_END expiry (epoch) · C_SUBJ full subject
typeset -a C_SHA C_KC C_LOGIN C_PEM C_NAME C_ISSUER C_END C_SUBJ
typeset -a C_DETAIL          # details for the info popover: start  serial  key  signature  usedFor  altNames  isCA  sha256 (tab-separated)
typeset -A VALID_SUBJ        # subject of every still-valid certificate -> "expiry<TAB>keychain<TAB>issuer<TAB>sha-1"
                             # of the newest one (to spot renewed ones and show the newer copy)
typeset -A VALID_PEM         # subject -> PEM file of that newest valid copy (for its details)
typeset -A IDENT             # sha-1 of every certificate that has a private key (an "identity") -> 1
typeset -a EXCLUDED          # "name (keychain)" of expired certificates kept by EXCLUDE_PATTERNS

# is_excluded <subject> <issuer> -> 0 if either contains any EXCLUDE_PATTERNS entry (case-insensitive)
is_excluded() {
  local subj="${1:l}" iss="${2:l}" pat
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    pat="${pat:l}"; [[ -z "$pat" ]] && continue
    [[ "$subj" == *"$pat"* || "$iss" == *"$pat"* ]] && return 0
  done
  return 1
}

# dn_get <RFC 2253 name> <attr> -> REPLY = that attribute's value ("" if missing). Handles "\," in values.
dn_get() {
  local dn="${1//\\,/$'\x01'}" part; REPLY=""
  for part in "${(@s:,:)dn}"; do
    part="${part##[[:space:]]#}"
    [[ "$part" == "$2="* ]] && { REPLY="${${part#$2=}//$'\x01'/,}"; REPLY="${REPLY//\\/}"; return 0; }
  done
  return 1
}
# dn_name <RFC 2253 name> -> REPLY = the friendliest single name: CN, else O, else OU, else the whole thing
dn_name() {
  dn_get "$1" CN || dn_get "$1" O || dn_get "$1" OU || REPLY="${1##[[:space:]]#}"
  [[ -z "$REPLY" ]] && REPLY="Unnamed certificate"
}

# cert_details <pem file> -> REPLY = "startEpoch<TAB>serial<TAB>key<TAB>signature<TAB>usedFor<TAB>altNames<TAB>isCA<TAB>sha256"
# (only run for expired certificates, so the scan stays fast)
cert_details() {
  local out start sdate
  out=$(/usr/bin/openssl x509 -noout -text -fingerprint -sha256 -in "$1" 2>/dev/null | /usr/bin/awk '
    /Serial Number:/ { s=$0; sub(/.*Serial Number: */,"",s); if(s==""){ getline s; gsub(/^ +| +$/,"",s) } serial=s }
    /Not Before:/    { nb=$0; sub(/.*Not Before: */,"",nb) }
    /Public Key Algorithm:/ { ka=$0; sub(/.*Public Key Algorithm: */,"",ka) }
    /Public-Key: \(/ { b=$0; sub(/.*\(/,"",b); sub(/ bit\).*/,"",b); bits=b }
    /^    Signature Algorithm:/ && sig=="" { sig=$0; sub(/.*Signature Algorithm: */,"",sig) }
    /Extended Key Usage:/ { getline e; gsub(/^ +| +$/,"",e); eku=e }
    /Subject Alternative Name:/ { getline a; gsub(/^ +| +$/,"",a); san=a }
    /CA:TRUE/ { ca=1 }
    /Fingerprint=/ { f=$0; sub(/.*Fingerprint=/,"",f); fp=f }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", nb, serial, ka, bits, sig, eku, san, (ca?1:0) "\t" fp }')
  local -a f; f=("${(@ps:\t:)out}")
  start=$(/bin/date -j -f "%b %e %T %Y %Z" "$f[1]" +%s 2>/dev/null)
  # friendlier words for the common ones
  local key="$f[3]"; case "$key" in rsaEncryption) key="RSA" ;; id-ecPublicKey) key="Elliptic curve" ;; esac
  [[ -n "$f[4]" ]] && key="$key $f[4]-bit"
  local sig="$f[5]"; sig="${sig/WithRSAEncryption/ with RSA}"; sig="${sig/ecdsa-with-/ECDSA }"; sig="${sig/sha/SHA-}"
  local use="$f[6]" u; local -a uses=()
  for u in "${(@s:, :)use}"; do
    case "$u" in
      "TLS Web Server Authentication") uses+=("Websites and servers") ;;
      "TLS Web Client Authentication") uses+=("Signing in (Wi-Fi, VPN, websites)") ;;
      "E-mail Protection")             uses+=("Email signing and encryption") ;;
      "Code Signing")                  uses+=("Signing apps and code") ;;
      "Time Stamping")                 uses+=("Time stamping") ;;
      "1.3.6.1.5.2.3.5")               uses+=("Kerberos (domain controller)") ;;
      "1.3.6.1.5.2.3.4")               uses+=("Kerberos sign-in") ;;
      "1.3.6.1.4.1.311.20.2.2")        uses+=("Smart card sign-in") ;;
      "OCSP Signing")                  uses+=("Certificate status (OCSP)") ;;
      "")                              ;;
      *)                               uses+=("$u") ;;
    esac
  done
  (( ${#uses} )) || { [[ "$f[8]" == 1 ]] && uses=("Issuing other certificates (CA)") || uses=("Not limited"); }
  local san="$f[7]"; san="${san//DNS:/}"; san="${san//email:/}"; san="${san//IP Address:/}"
  REPLY="${start:-0}"$'\t'"$f[2]"$'\t'"$key"$'\t'"$sig"$'\t'"${(j:, :)uses}"$'\t'"$san"$'\t'"$f[8]"$'\t'"$f[9]"
}

# kc_read <keychain> <login(0/1)> -> "SHA-1 hash:" + PEM for every certificate in it.
# The login keychain is read as its owner (right search list and permissions); System as root.
kc_read() {
  if (( $2 )); then run_as_user /usr/bin/security find-certificate -a -Z -p "$1" 2>/dev/null
  else /usr/bin/security find-certificate -a -Z -p "$1" 2>/dev/null; fi
}

# scan_keychain <keychain> <login(0/1)> -> appends to C_* (expired ones) and VALID_SUBJ (valid ones)
scan_keychain() {
  local kc="$1" login="$2" line sha="" pem="" inpem=0 tmp out endtxt subj iss end n=0 l name issname
  [[ -e "$kc" ]] || { logMe INFO "Keychain not found, skipping: $kc"; return 0; }
  # certificates with a private key: Keychain Access shows these as "personal" certificates
  local idl; for idl in ${(f)"$(if (( login )); then run_as_user /usr/bin/security find-identity "$kc" 2>/dev/null; else /usr/bin/security find-identity "$kc" 2>/dev/null; fi | /usr/bin/awk '$1 ~ /^[0-9]+\)$/ && $2 ~ /^[0-9A-F]+$/ {print $2}')"}; do IDENT[$idl]=1; done
  while IFS= read -r line; do
    if [[ "$line" == "SHA-1 hash: "* ]]; then sha="${${line#SHA-1 hash: }//[[:space:]]/}"; pem=""; inpem=0; continue; fi
    [[ "$line" == "-----BEGIN CERTIFICATE-----" ]] && { inpem=1; pem=""; }
    (( inpem )) && pem+="$line"$'\n'
    [[ "$line" == "-----END CERTIFICATE-----" ]] || continue
    inpem=0; [[ -n "$sha" ]] || continue
    (( n++ ))
    tmp="$PEM_DIR/${kc:t}_$sha.pem"; print -rn -- "$pem" > "$tmp"
    # one openssl call for everything we need
    out=$(/usr/bin/openssl x509 -noout -enddate -subject -issuer -nameopt RFC2253 -in "$tmp" 2>/dev/null)
    endtxt=""; subj=""; iss=""
    for l in "${(@f)out}"; do
      case "$l" in
        notAfter=*) endtxt="${l#notAfter=}" ;;
        subject=*)  subj="${${l#subject=}##[[:space:]]#}" ;;
        issuer=*)   iss="${${l#issuer=}##[[:space:]]#}" ;;
      esac
    done
    end=$(/bin/date -j -f "%b %e %T %Y %Z" "$endtxt" +%s 2>/dev/null)
    if [[ -z "$end" ]]; then
      logMe WARN "Couldn't read the expiry of ${sha:0:8}… ($endtxt) — skipping it"; /bin/rm -f "$tmp"; continue
    fi
    if (( end >= EPOCHSECONDS )); then
      if (( end > ${${VALID_SUBJ[$subj]%%$'\t'*}:-0} )); then
        if [[ "$iss" == "$subj" ]]; then issname="itself (self-signed)"; else dn_name "$iss"; issname="$REPLY"; fi
        VALID_SUBJ[$subj]="$end"$'\t'"$login"$'\t'"$issname"$'\t'"$sha"
        [[ -n "${VALID_PEM[$subj]}" ]] && /bin/rm -f "${VALID_PEM[$subj]}"
        VALID_PEM[$subj]="$tmp"
      else /bin/rm -f "$tmp"; fi
      continue
    fi
    dn_name "$subj"; name="$REPLY"
    if is_excluded "$subj" "$iss"; then
      logMe INFO "Keeping (exclude list): $name  [${kc:t}, expired $endtxt]"
      EXCLUDED+=("$name"); /bin/rm -f "$tmp"; continue
    fi
    if [[ "$iss" == "$subj" ]]; then issname="itself (self-signed)"; else dn_name "$iss"; issname="$REPLY"; fi
    C_SHA+=("$sha"); C_KC+=("$kc"); C_LOGIN+=("$login"); C_PEM+=("$tmp")
    C_NAME+=("$name"); C_ISSUER+=("$issname"); C_END+=("$end"); C_SUBJ+=("$subj")
    cert_details "$tmp"; C_DETAIL+=("$REPLY")
    logMe INFO "Expired: $name  [${kc:t}, expired $endtxt, issued by $issname, ${sha:0:8}…]"
  done < <(kc_read "$kc" "$login")
  logMe INFO "Checked $n certificate(s) in ${kc:t}"
}

# cert_kind <issuer name> <sha-1> -> root / personal / std (picks the same icon Keychain Access shows)
cert_kind() { if [[ "$1" == "itself (self-signed)" ]]; then print root; elif [[ -n "$2" && -n "${IDENT[$2]}" ]]; then print personal; else print std; fi; }

# is_renewed <record #> -> 0 if a still-valid certificate with exactly the same subject is installed
is_renewed() { [[ -n "${VALID_SUBJ[${C_SUBJ[$1]}]}" ]]; }

# write_review -> $REVIEW_FILE rows and ORDER (record # of each I row, in the order shown)
#   G  group#  title  subtitle  symbol
#   I  group#  name  issuer  expiryEpoch  renewed(0/1)  sha1  subject
#      newer copy: expiry  login(0/1)  issuer  sha1          (blank when not renewed)
#      details:    start  serial  key  signature  usedFor  altNames  isCA  sha256
#      newer copy's details: the same 8 fields (blank when not renewed)
#      kind, newer copy's kind: root (self-signed) / personal (has a private key) / std  -> the Keychain Access icon
write_review() {
  : > "$REVIEW_FILE"; ORDER=()
  local gi=0 login i nv dt nd; local -a idx
  for login in 1 0; do
    idx=(); for (( i=1; i<=${#C_SHA}; i++ )); do (( C_LOGIN[i] == login )) && idx+=($i); done
    (( ${#idx} )) || continue
    (( gi++ ))
    # oldest first
    idx=( ${(f)"$(for i in $idx; do print -r -- "${C_END[i]} $i"; done | /usr/bin/sort -n | /usr/bin/awk '{print $2}')"} )
    if (( login )); then
      print -r -- "G"$'\t'"$gi"$'\t'"Your login keychain"$'\t'"Only your account uses these"$'\t'"person.crop.circle.fill" >> "$REVIEW_FILE"
    else
      print -r -- "G"$'\t'"$gi"$'\t'"System keychain"$'\t'"Shared by everyone who uses this Mac"$'\t'"desktopcomputer" >> "$REVIEW_FILE"
    fi
    for i in $idx; do
      nv="${VALID_SUBJ[${C_SUBJ[i]}]}"; [[ -n "$nv" ]] || nv=$'\t\t\t'          # newer copy: 4 fields, blank if none
      dt="${C_DETAIL[i]}"; [[ -n "$dt" ]] || dt=$'\t\t\t\t\t\t\t'               # details: 8 fields
      nd=""; [[ -n "${VALID_PEM[${C_SUBJ[i]}]}" ]] && { cert_details "${VALID_PEM[${C_SUBJ[i]}]}"; nd="$REPLY"; }
      [[ -n "$nd" ]] || nd=$'\t\t\t\t\t\t\t'                                       # newer copy's details: 8 fields
      print -r -- "I"$'\t'"$gi"$'\t'"${C_NAME[i]}"$'\t'"${C_ISSUER[i]}"$'\t'"${C_END[i]}"$'\t'"$(is_renewed $i && print 1 || print 0)"$'\t'"${C_SHA[i]}"$'\t'"${C_SUBJ[i]}"$'\t'"$nv"$'\t'"$dt"$'\t'"$nd"$'\t'"$(cert_kind "${C_ISSUER[i]}" "${C_SHA[i]}")"$'\t'"$(cert_kind "${${(@ps:\t:)nv}[3]}" "${${(@ps:\t:)nv}[4]}")" >> "$REVIEW_FILE"
      ORDER+=($i)
    done
  done
}

# --- Review window --------------------------------------------------------------------------------
# Expired certificates grouped by keychain. Each group header has a checkbox for the whole group
# (mixed when only some are checked), an icon, and how many are checked. Each row: checkbox, the
# certificate icon, its name, who issued it and how long ago it expired, a RENEWED tag when a newer
# copy is installed, and the expiry date. Hovering a row shows the full subject and SHA-1.
# Prints the checked row numbers ("0,1,4") or __CANCEL__.
show_review() {
  local s="$SCRATCH/review.jxa"
  {
    win_prelude
    print -r -- "var DATA=\"$(as_esc "$REVIEW_FILE")\", RTITLE=\"$(as_esc "$REVIEW_TITLE")\", RMSG=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$PREVIEW_MESSAGE" || print -r -- "$REVIEW_MESSAGE")")\", RNOTE=\"$(as_esc "$REVIEW_NOTE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\";"
    print -r -- "var L_REMOVE=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$previewButton" || print -r -- "$removeButton")")\", L_CANCEL=\"$(as_esc "$cancelButton")\", DRY=$DRY_RUN, NOW=$EPOCHSECONDS;"
    /bin/cat <<'JXA'
var GR=[], ITEMS=[];
// The certificate icons Keychain Access uses (SecurityInterface.framework): Root (gold), Personal (grey,
// has a private key) and Std (blue); the small ones have an "_Invalid" version with a red ✕ for expired.
var SIB=$.NSBundle.bundleWithPath("/System/Library/Frameworks/SecurityInterface.framework");
function certIcon(kind,large,expired){ var K={root:"Root",personal:"Personal"}[kind]||"Std";
 try{ var im=SIB.imageForResource((large?"CertLarge":"CertSmall")+K+(!large&&expired?"_Invalid":"")); if(im && !im.isNil()) return im; }catch(e){}
 return null; }
function det(r,o){ return {start:+r[o]||0,serial:r[o+1]||"",key:r[o+2]||"",sig:r[o+3]||"",use:r[o+4]||"",san:r[o+5]||"",ca:r[o+6]=="1",sha256:r[o+7]||""}; }
readLines(DATA).forEach(function(l){ var r=l.split("\t");
 if(r[0]=="G") GR.push({g:r[1],title:r[2],sub:r[3],sym:r[4],items:[]});
 else if(r[0]=="I"){ var it={g:r[1],name:r[2],iss:r[3],end:+r[4]||0,renewed:r[5]=="1",sha:r[6],subj:r[7],i:ITEMS.length,
   nw:r[8]?{end:+r[8]||0,login:r[9]=="1",iss:r[10]||"",sha:r[11]||""}:null,
   d:det(r,12),kind:r[28]||"std"}; if(it.nw){ it.nw.d=det(r,20); it.nw.kind=r[29]||"std"; } ITEMS.push(it);
  for(var k=GR.length-1;k>=0;k--) if(GR[k].g==it.g){ GR[k].items.push(it); break; } } });

var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
function dstr(e){ var d=new Date(e*1000); return MON[d.getMonth()]+" "+d.getDate()+", "+d.getFullYear(); }
function until(e){ var days=Math.floor((e-NOW)/86400);
 if(days<1) return "today"; if(days<2) return "tomorrow"; if(days<14) return "in "+days+" days";
 if(days<60) return "in "+Math.round(days/7)+" weeks"; if(days<365) return "in "+Math.round(days/30.4)+" months";
 var y=Math.round(days/365.25*10)/10; return "in "+(y==1?"a year":y+" years"); }
function ago(e){ var days=Math.floor((NOW-e)/86400);
 if(days<1) return "today"; if(days<2) return "yesterday"; if(days<14) return days+" days ago";
 if(days<60) return Math.round(days/7)+" weeks ago"; if(days<365) return Math.round(days/30.4)+" months ago";
 var y=Math.floor(days/365.25); return y==1?"over a year ago":"over "+y+" years ago"; }

if(!$.DCRev){ObjC.registerSubclass({name:'DCRev',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'item:':{types:['void',['id']],implementation:function(s){ refresh(); }},
 'renewed:':{types:['void',['id']],implementation:function(s){ var it=ITEMS[s.tag]; showNewer(it,it.chev||s); }},
 'info:':{types:['void',['id']],implementation:function(s){ var it=ITEMS[s.tag]; showInfo(it,it.chev||s); }},
 'pnew:':{types:['void',['id']],implementation:function(s){ showCard(ITEMS[s.tag],true,null); }},
 'pold:':{types:['void',['id']],implementation:function(s){ showCard(ITEMS[s.tag],false,null); }},
 'row:':{types:['void',['id']],implementation:function(s){ var cb=ITEMS[s.tag].cb; cb.state=ObjC.unwrap(cb.state)==1?0:1; refresh(); }},
 'group:':{types:['void',['id']],implementation:function(s){ var g=GR[s.tag], all=g.items.every(function(it){return ObjC.unwrap(it.cb.state)==1;});
   g.items.forEach(function(it){ it.cb.state=all?0:1; }); refresh(); }}}});}
var hd=$.DCRev.alloc.init;

// ---- sizes and positions ----
var W=820, PAD=24, BH=(BNAME?96:84), GH=42, IH=52, GAP=8;
var CH=GR.reduce(function(a,g){ return a+GH+g.items.length*IH+GAP; },0)+4;
var LH=Math.min(Math.max(CH,200),500)+10;
var PBW=150, RBW=230, PBH=34, PBY=18, NOTEH=32, noteY=PBY+PBH+12, listY=noteY+NOTEH+10, msgY=listY+LH+12, MSGH=20;
var H=msgY+MSGH+14+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR;
var cv=win.contentView;
var nItems=ITEMS.length, subt=nItems+(nItems==1?" expired certificate":" expired certificates")+" found";
header(cv,W,H,BH,PAD,RTITLE,subt,DRY?"Preview only — nothing will be removed":"",DRY?"eye.fill":"");

// Instruction on the left; what the "Renewed" tag means on the right
var ml=label(RMSG,PAD+2,msgY,W-2*PAD-300,MSGH,13,$.NSFontWeightMedium); cv.addSubview(ml);
var TAGF=$.NSFont.systemFontOfSizeWeight(9.5,$.NSFontWeightBold), GOOD=DARK?C([0.19,0.82,0.35]):C([0.08,0.50,0.20]);
function tag(x,y,parent,it){ var t="RENEWED", w=tw(t,TAGF)+14;
 var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,16)); b.boxType=4; b.titlePosition=0; b.cornerRadius=8; b.borderWidth=0;
 b.fillColor=GOOD.colorWithAlphaComponent(DARK?0.22:0.14); parent.addSubview(b);
 var l=label(t,x,y+1.5,w,13,9.5,$.NSFontWeightBold,1); l.font=TAGF; l.textColor=GOOD; parent.addSubview(l);
 l.toolTip="A newer, valid copy of this certificate is already installed, so this old one isn't needed";
 if(it && it.nw){ var cb=clickArea(x-2,y-3,w+4,22,hd,'renewed:',it.i,parent,true); cb.toolTip="Click to see the newer copy"; }
 return w; }
// DCRow: a row that lights up while the mouse is over it, so it reads as clickable.
var HOVER={};
if(!$.DCRow){ ObjC.registerSubclass({name:'DCRow',superclass:'NSView',methods:{
 'updateTrackingAreas':{types:['void',[]],implementation:function(){ var ta=this.trackingAreas;
   for(var i=ta.count-1;i>=0;i--) this.removeTrackingArea(ta.objectAtIndex(i));
   this.addTrackingArea($.NSTrackingArea.alloc.initWithRectOptionsOwnerUserInfo(this.bounds,0x01|0x80|0x200,this,null)); }},
 'mouseEntered:':{types:['void',['id']],implementation:function(e){ hoverOn(ObjC.unwrap(this.identifier)); }},
 'mouseExited:':{types:['void',['id']],implementation:function(e){ hoverOff(ObjC.unwrap(this.identifier)); }},
 'mouseDown:':{types:['void',['id']],implementation:function(e){ }},
 'mouseUp:':{types:['void',['id']],implementation:function(e){   // a click anywhere on the row (text included) opens its details
   var it=ITEMS[+ObjC.unwrap(this.identifier).slice(1)]; if(it) toggleInfo(it); }}}}); }
// DCHit: an invisible layer on top of a row or header that takes the click itself. It accepts the
// "first click" (so a click still works right after a details card was in front) and nothing under
// it (labels, dates) can swallow it. identifier "rN" = row N (open its details), "gN" = group N (show/hide).
if(!$.DCHit){ ObjC.registerSubclass({name:'DCHit',superclass:'NSView',methods:{
 'acceptsFirstMouse:':{types:['bool',['id']],implementation:function(e){ return true; }},
 'resetCursorRects':{implementation:function(){ if(ObjC.unwrap(this.identifier).charAt(0)=="g") this.addCursorRectCursor(this.bounds,$.NSCursor.pointingHandCursor); }},
 'mouseUp:':{types:['void',['id']],implementation:function(e){ }},   // swallow it, so the row/header under us doesn't toggle again
 'mouseDown:':{types:['void',['id']],implementation:function(e){ var id=ObjC.unwrap(this.identifier), n=+id.slice(1);
   if(id.charAt(0)=="g") toggleGroup(n); else if(ITEMS[n]) toggleInfo(ITEMS[n]); }}}}); }
function hit(parent,x,y,w,h,id,tip){ var v=$.DCHit.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); v.identifier=id; if(tip) v.toolTip=tip; parent.addSubview(v); return v; }
// DCHead: a keychain group header; clicking it (anywhere but its checkbox) shows or hides its certificates.
if(!$.DCHead){ ObjC.registerSubclass({name:'DCHead',superclass:'NSView',methods:{
 'resetCursorRects':{implementation:function(){ this.addCursorRectCursor(this.bounds,$.NSCursor.pointingHandCursor); }},
 'mouseDown:':{types:['void',['id']],implementation:function(e){ }},
 'mouseUp:':{types:['void',['id']],implementation:function(e){ toggleGroup(+ObjC.unwrap(this.identifier).slice(1)); }}}}); }
// Highlights: at most one row lit by the mouse (CURHOV), plus the row whose details card is open (SELROW).
// Entering a row clears any other hover highlight, so a missed "mouse left" event can't leave rows lit.
var CURHOV=null, SELROW=null;
function lit(id,on){ var h=HOVER[id]; if(h) h.hidden=!on; }
function hoverOn(id){ if(CURHOV && CURHOV!=id && CURHOV!=SELROW) lit(CURHOV,false); CURHOV=id; lit(id,true); }
function hoverOff(id){ if(id!=SELROW) lit(id,false); if(CURHOV==id) CURHOV=null; }
function selectRow(id){ var old=SELROW; SELROW=id; if(old && old!=id && old!=CURHOV) lit(old,false); if(id) lit(id,true); }
// badge(parent, x, y, item) -> the small green "Renewed" badge next to a name; click it for the newer copy
var BDF=$.NSFont.systemFontOfSizeWeight(10.5,$.NSFontWeightSemibold);
function badge(parent,x,y,it){ var w=tw("Renewed",BDF)+30, h=18;
 var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,h)); b.boxType=4; b.titlePosition=0; b.cornerRadius=h/2; b.borderWidth=0;
 b.fillColor=GOOD.colorWithAlphaComponent(DARK?0.20:0.13); parent.addSubview(b);
 var si=sym("checkmark.seal.fill",x+6,y+3,12,GOOD); if(si) parent.addSubview(si);
 var l=label("Renewed",x+21,y+1.5,w-24,14,10.5,$.NSFontWeightSemibold); l.font=BDF; l.textColor=GOOD; parent.addSubview(l);
 var c=clickArea(x,y,w,h,hd,'renewed:',it.i,parent,true); c.toolTip="A newer copy is installed — click to see it"; return w; }
// btn(parent, x, y, text, colour, symbol, action, tag, tip) -> an outlined capsule button (hand cursor). Returns its width.
var BTF=$.NSFont.systemFontOfSizeWeight(11.5,$.NSFontWeightSemibold), BTH=24;
function btnW(text,symb){ return tw(text,BTF)+(symb?20:0)+28; }
function btn(parent,x,y,text,col,symb,act,tg,tip){ var w=btnW(text,symb);
 var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,BTH)); b.boxType=4; b.titlePosition=0; b.cornerRadius=BTH/2;
 b.fillColor=col.colorWithAlphaComponent(DARK?0.16:0.10); b.borderWidth=1; b.borderColor=col.colorWithAlphaComponent(DARK?0.55:0.45); parent.addSubview(b);
 var tx=x+11; if(symb){ var si=sym(symb,x+10,y+(BTH-14)/2,14,col); if(si) parent.addSubview(si); tx+=19; }
 var l=label(text,tx-2,y+(BTH-16)/2,w-(tx-x)-4,16,11.5,$.NSFontWeightSemibold); l.font=BTF; l.textColor=col; parent.addSubview(l);
 var c=clickArea(x,y,w,BTH,hd,act,tg,parent,true); if(tip) c.toolTip=tip; return w; }
// "OU=IT,O=Acme Corp,CN=Acme VPN" (RFC 2253) -> "Acme VPN  ·  Acme Corp  ·  IT" (just the values, name first)
function friendlyDN(dn){
 var parts=dn.replace(/\\,/g,"\u0001").split(",").map(function(p){ p=p.trim(); var k=p.indexOf("=");
  return {k:p.slice(0,k).toUpperCase(), v:p.slice(k+1).replace(/\u0001/g,",")}; });
 var seen={}, out=[];
 ["CN","EMAILADDRESS","O","OU","L","ST","C"].forEach(function(k){ parts.forEach(function(p){ if(p.k==k && p.v && !seen[p.v]){ seen[p.v]=1; out.push(p.v); } }); });
 return out.join("  ·  ") || dn; }
// Hover text for a row: the essentials in plain words
function summaryTip(it){ var t=[it.name+"  —  expired "+ago(it.end)];
 if(it.d.use) t.push("Used for: "+it.d.use);
 t.push("Issued by: "+it.iss);
 if(it.renewed && it.nw) t.push("Renewed: a newer copy is valid until "+dstr(it.nw.end));
 t.push("Click for details"); return t.join("\n"); }

// ---- Certificate card: the ⓘ popover, and the newer copy of a renewed one ----
// Header (icon, name, status) · validity dates · ABOUT (plain words) · TECHNICAL DETAILS (small, for IT)
// · a "Renewed" callout with "See newer copy ›" (expired copy) or "‹ Back" (newer copy).
function card(it,newer){
 var c=newer ? {iss:it.nw.iss,start:it.nw.d.start,end:it.nw.end,d:it.nw.d,sha:it.nw.sha,ok:true,
                kc:it.nw.login?"Your login keychain":"System keychain"}
             : {iss:it.iss,start:it.d.start,end:it.end,d:it.d,sha:it.sha,ok:false,
                kc:(GR.filter(function(g){return g.g==it.g;})[0]||{}).title||""};
 var col=c.ok?GOOD:WARN, PW=420, P=18, LBW=86, VW=PW-2*P-LBW;
 var about=[["Used for",c.d.use||"Not limited"],["Issued to",friendlyDN(it.subj)]];
 if(c.d.san) about.push(["Also covers",c.d.san]);
 about.push(["Issued by",c.iss],["Keychain",c.kc]);
 var tech=[]; if(c.d.key) tech.push(["Key",c.d.key]); if(c.d.sig) tech.push(["Signature",c.d.sig]); if(c.d.serial) tech.push(["Serial",c.d.serial]);
 tech.push(["SHA-1",c.sha]); if(c.d.sha256) tech.push(["SHA-256",c.d.sha256.replace(/:/g,"")]);
 var VF=$.NSFont.systemFontOfSizeWeight(12,$.NSFontWeightMedium), MF=$.NSFont.monospacedSystemFontOfSizeWeight(10.5,$.NSFontWeightRegular);
 function rh(t,f){ return tw(t,f)>VW-4 ? 32 : 17; }   // one line, or two when it's long
 var hA=about.reduce(function(a,r){ return a+rh(r[1],VF)+5; },0), hT=tech.reduce(function(a,r){ return a+rh(r[1],MF)+3; },0);
 var call=!newer && it.renewed && it.nw;
 var H=16+44+12+28+(16+14+6)+hA+(16+14+6)+hT+(call?16+48:0)+(newer?14+20:0)+16;
 var v=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,PW,H)), y=H-16;
 // header
 y-=44; var big=certIcon(newer?it.nw.kind:it.kind,true,false);
 if(big){ var biv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(P-2,y+1,44,44)); biv.image=big; biv.imageScaling=3; v.addSubview(biv);
  var st=sym(c.ok?"checkmark.circle.fill":"xmark.circle.fill",P+26,y,18,col);
  if(st){ try{ var pc=$.NSImageSymbolConfiguration.configurationWithPaletteColors($([$.NSColor.whiteColor,col])); var pi=st.image.imageWithSymbolConfiguration(pc); if(pi && !pi.isNil()) st.image=pi; }catch(e){} v.addSubview(st); } }
 else { v.addSubview(rbox(P,y+4,38,38,col.colorWithAlphaComponent(DARK?0.20:0.13),10));
  var si=sym(c.ok?"checkmark.seal.fill":"xmark.seal.fill",P+8,y+12,22,col); if(si) v.addSubview(si); }
 var t1=label(it.name,P+50,y+22,PW-P-50-P,20,15,$.NSFontWeightBold); t1.font=rounded(15,$.NSFontWeightBold); t1.cell.lineBreakMode=5; t1.selectable=true; v.addSubview(t1);
 var t2=label(c.ok?(newer?"Newer copy  ·  ":"")+"Valid  ·  expires "+until(c.end):"Expired "+ago(c.end),P+50,y+4,PW-P-50-P,17,12,$.NSFontWeightSemibold); t2.textColor=col; v.addSubview(t2);
 // validity dates
 y-=12+28; v.addSubview(rbox(P,y,PW-2*P,28,G(DARK?0.14:0.08),8));
 var vf=label("Valid",P+12,y+7,90,15,11,$.NSFontWeightRegular); vf.textColor=$.NSColor.secondaryLabelColor; v.addSubview(vf);
 var vd=label((c.start?dstr(c.start):"Unknown")+"   →   "+dstr(c.end),P+80,y+6,PW-2*P-92,17,12.5,$.NSFontWeightSemibold,2); vd.font=$.NSFont.monospacedDigitSystemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); v.addSubview(vd);
 // sections
 function section(title,rows,font,valCol,gap){
  y-=16+14; var s=label(title,P,y,PW-2*P,14,10,$.NSFontWeightBold); s.textColor=$.NSColor.tertiaryLabelColor; v.addSubview(s); y-=6;
  rows.forEach(function(r){ var h=rh(r[1],font); y-=h+gap;
   var a=label(r[0],P,y+h-16,LBW,15,11.5,$.NSFontWeightRegular); a.textColor=$.NSColor.secondaryLabelColor; v.addSubview(a);
   var b=wrapLabel(r[1],P+LBW,y,VW,h,12,0); b.font=font; b.selectable=true; if(valCol) b.textColor=valCol; v.addSubview(b); }); }
 section("ABOUT",about,VF,null,5);
 section("TECHNICAL DETAILS",tech,MF,$.NSColor.secondaryLabelColor,3);
 // renewed callout, or the way back
 if(call){ y-=16+48; v.addSubview(rbox(P,y,PW-2*P,48,GOOD.colorWithAlphaComponent(DARK?0.16:0.10),10));
  var ci=sym("checkmark.seal.fill",P+12,y+14,20,GOOD); if(ci) v.addSubview(ci);
  var c1=label("Renewed: newer copy installed",P+42,y+25,PW-2*P-42-128,16,12,$.NSFontWeightSemibold); v.addSubview(c1);
  var c2=label("Valid until "+dstr(it.nw.end),P+42,y+8,PW-2*P-42-128,15,11.5); c2.textColor=$.NSColor.secondaryLabelColor; v.addSubview(c2);
  var lk=label("See newer copy  ›",PW-P-12-120,y+16,120,16,12,$.NSFontWeightSemibold,2); lk.textColor=GOOD; v.addSubview(lk);
  clickArea(P,y,PW-2*P,48,hd,'pnew:',it.i,v,true).toolTip="Show the newer copy"; }
 if(newer){ y-=14+20; var BT="‹  Back to the expired copy", bl=label(BT,P,y+2,PW-2*P,16,12,$.NSFontWeightSemibold); bl.textColor=ACCENT; v.addSubview(bl);
  clickArea(P,y,tw(BT,bl.font)+10,20,hd,'pold:',it.i,v,true); }
 return {v:v,w:PW,h:H}; }
// showCard(item, newer, anchor): opens the card under anchor, or (anchor=null) swaps the open one
var POP=null;
function showCard(it,newer,anchor){
 var c=card(it,newer);
 if(!anchor && POP && POP.shown){ POP.contentViewController.view=c.v; POP.contentSize=$.NSMakeSize(c.w,c.h); return; }
 if(!anchor) return;
 if(POP && POP.shown) POP.close;
 var vc=$.NSViewController.alloc.init; vc.view=c.v;
 POP=$.NSPopover.alloc.init; POP.contentViewController=vc; POP.contentSize=$.NSMakeSize(c.w,c.h); POP.behavior=0; POP.animates=true;   // 0 = stays open until we close it, so clicks elsewhere aren't swallowed
 try{ POP.appearance=APPEAR; }catch(e){}
 POP.showRelativeToRectOfViewPreferredEdge(anchor.bounds,anchor,1); }
function showInfo(it,anchor){ showCard(it,false,anchor); POPIT=it; selectRow("r"+it.i); }
var POPIT=null;
function toggleInfo(it){ if(POP && POP.shown && POPIT===it){ POP.close; POPIT=null; selectRow(null); return; } showInfo(it,it.chev||it.cb); }                 // ⓘ
function showNewer(it,anchor){ if(it.nw){ showCard(it,true,anchor); POPIT=it; selectRow("r"+it.i); } }      // RENEWED tag
var lgT="Renewed = a newer copy is already installed", lgF=$.NSFont.systemFontOfSizeWeight(11.5,$.NSFontWeightRegular), lgw=tw(lgT,lgF);
if(ITEMS.some(function(it){return it.renewed;})){
 var lgl=label(lgT,W-PAD-lgw-2,msgY+1,lgw+4,17,11.5); lgl.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(lgl);
 var lgs=sym("checkmark.seal.fill",W-PAD-lgw-2-20,msgY+2,15,GOOD); if(lgs) cv.addSubview(lgs); }

// The list
var LW=W-2*PAD;
cv.addSubview(rbox(PAD,listY,LW,LH,G(0.08),12));
var sv=$.NSScrollView.alloc.initWithFrame($.NSMakeRect(PAD,listY+5,LW,LH-10)); sv.drawsBackground=false; sv.borderType=0;
sv.scrollerStyle=1; sv.autohidesScrollers=true; cv.addSubview(sv);
var SVH=LH-10, DH=Math.max(SVH,CH), doc=$.NSView.alloc.initWithFrame($.NSMakeRect(0,0,LW,DH)); sv.documentView=doc;
sv.hasVerticalScroller=(DH>SVH);
var DTW=130, NF=$.NSFont.systemFontOfSizeWeight(13,$.NSFontWeightSemibold), DF=$.NSFont.monospacedDigitSystemFontOfSizeWeight(12.5,$.NSFontWeightSemibold);
var WARN=DARK?C([1,0.62,0.04]):C([0.80,0.40,0.0]);   // expired = orange seal
var RX=14, RW=LW-RX-18;                                      // rows keep clear of the scroll bar
GR.forEach(function(g,gi){
 // group header: ▾ [✓] Your login keychain  5 certificates ............ 5 of 5 selected
 var HW=LW-4-18, hv=$.DCHead.alloc.initWithFrame($.NSMakeRect(4,0,HW,GH)); hv.identifier="g"+gi; doc.addSubview(hv); g.hv=hv;
 hv.addSubview(rbox(0,3,HW,GH-6,G(DARK?0.11:0.07),9));
 hv.toolTip=g.sub+" — click to show or hide";
 var ar=sym("chevron.down",4,(GH-12)/2,12,$.NSColor.secondaryLabelColor); if(ar){ hv.addSubview(ar); g.arrow=ar; }
 var mb=$.NSButton.alloc.initWithFrame($.NSMakeRect(RX+12-4,(GH-20)/2,22,20)); mb.setButtonType(3); mb.allowsMixedState=true; mb.title="";
 mb.target=hd; mb.action='group:'; mb.tag=gi; try{ mb.contentTintColor=ACCENT; }catch(e){} hv.addSubview(mb); g.cb=mb;
 var HF=rounded(13.5,$.NSFontWeightBold), gtw=tw(g.title,HF)+4;
 var gn=label(g.title,RX+44-4,(GH-18)/2,gtw,18,13.5,$.NSFontWeightBold); gn.font=HF; hv.addSubview(gn);
 var cnt=g.items.length+(g.items.length==1?" certificate":" certificates");
 var gc=label(cnt,RX+44-4+gtw+8,(GH-16)/2,180,16,12); gc.textColor=$.NSColor.secondaryLabelColor; hv.addSubview(gc);
 var gz=label("",HW-16-200,(GH-16)/2,200,16,12,$.NSFontWeightMedium,2); gz.textColor=$.NSColor.secondaryLabelColor; hv.addSubview(gz); g.size=gz;
 hit(hv,0,0,RX+8-4,GH,"g"+gi,"Show or hide these certificates");          // the arrow
 hit(hv,RX+8+22,0,HW-(RX+8+22),GH,"g"+gi,"Show or hide these certificates");  // the title and count
 g.collapsed=false;
 // its certificates
 g.items.forEach(function(it,k){
  var rv=$.DCRow.alloc.initWithFrame($.NSMakeRect(RX,0,RW,IH)); rv.identifier="r"+it.i; doc.addSubview(rv); it.rv=rv;
  if(k>0) rv.addSubview(rbox(80,IH-0.5,RW-80-12,1,G(DARK?0.16:0.14)));   // thin divider, aligned with the text
  var hov=rbox(0,2,RW,IH-4,ACCENT.colorWithAlphaComponent(DARK?0.14:0.08),9); hov.hidden=true; rv.addSubview(hov); HOVER["r"+it.i]=hov;
  rv.toolTip=summaryTip(it);                                 // clicking the row opens the details (DCRow mouseUp)
  var cb=$.NSButton.alloc.initWithFrame($.NSMakeRect(12,(IH-20)/2,22,20)); cb.setButtonType(3); cb.title=""; cb.state=1;
  cb.target=hd; cb.action='item:'; cb.tag=it.i; try{ cb.contentTintColor=ACCENT; }catch(e){} rv.addSubview(cb); it.cb=cb;
  // right side: date / how long ago, then the chevron
  var chev=sym("chevron.right",RW-22,(IH-13)/2,13,$.NSColor.tertiaryLabelColor); if(chev){ rv.addSubview(chev); it.chev=chev; }
  var dcx=RW-30-DTW;
  var el=label("Expired",dcx,IH/2+1,DTW,15,11,$.NSFontWeightMedium,2); el.textColor=$.NSColor.secondaryLabelColor; rv.addSubview(el);
  var dl=label(dstr(it.end),dcx,IH/2-17,DTW,18,12.5,$.NSFontWeightSemibold,2); dl.font=DF; rv.addSubview(dl);
  // the Keychain Access certificate icon (expired = with the red ✕)
  var ci=certIcon(it.kind,false,true); if(ci){ var civ=$.NSImageView.alloc.initWithFrame($.NSMakeRect(42,(IH-30)/2,30,30)); civ.image=ci; civ.imageScaling=3; rv.addSubview(civ); }
  // name (+ a small Renewed badge right after it), then who issued it and how long ago it expired
  var nx=80, maxw=dcx-nx-14, bw=(it.renewed&&it.nw)?tw("Renewed",BDF)+30:0;
  var nw=Math.min(tw(it.name,NF)+6, maxw-(bw?bw+8:0));
  var nl=label(it.name,nx,IH/2+1,nw,18,13,$.NSFontWeightSemibold); nl.font=NF; nl.cell.lineBreakMode=5; rv.addSubview(nl);
  var wl=label("Issued by "+it.iss+"  ·  Expired "+ago(it.end).replace(/^over /,""),nx,IH/2-16,maxw,15,11.5); wl.cell.lineBreakMode=4; wl.textColor=$.NSColor.secondaryLabelColor; rv.addSubview(wl);
  hit(rv,40,0,RW-40,IH,"r"+it.i,summaryTip(it));             // click anywhere right of the checkbox -> details
  if(bw) badge(rv,nx+nw+6,IH/2+1,it);
 });
});
// layoutList(): positions the groups and rows top-down, skipping the rows of collapsed groups.
// Keeps the scroll position measured from the top, so the header you clicked stays put.
function layoutList(){
 var vis=sv.contentView.bounds, oldDH=doc.frame.size.height, fromTop=oldDH-(vis.origin.y+vis.size.height);
 var h=4; GR.forEach(function(g){ h+=GH+(g.collapsed?0:g.items.length*IH)+GAP; });
 var DH=Math.max(SVH,h); doc.frame=$.NSMakeRect(0,0,LW,DH);
 var y=DH-4;
 GR.forEach(function(g){
  y-=GH; g.hv.frame=$.NSMakeRect(4,y,LW-4-18,GH);
  if(g.arrow) g.arrow.image=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(g.collapsed?"chevron.right":"chevron.down","");
  g.items.forEach(function(it){ it.rv.hidden=g.collapsed; if(!g.collapsed){ y-=IH; it.rv.frame=$.NSMakeRect(RX,y,RW,IH); } });
  y-=GAP; });
 sv.hasVerticalScroller=(DH>SVH);
 var oy=Math.max(0,Math.min(DH-SVH, DH-SVH-Math.max(0,fromTop)));
 sv.contentView.scrollToPoint($.NSMakePoint(0,oy)); sv.reflectScrolledClipView(sv.contentView); }
function toggleGroup(gi){ var g=GR[gi]; if(!g) return; g.collapsed=!g.collapsed;
 if(POP && POP.shown && POPIT && POPIT.g==g.g && g.collapsed){ POP.close; POPIT=null; selectRow(null); }
 layoutList(); }
layoutList();

// Footer
var nt=wrapLabel(RNOTE,PAD+40,noteY,W-2*PAD-80,NOTEH,11.5,1); nt.textColor=$.NSColor.secondaryLabelColor;
if(DRY){ nt.stringValue=DNOTE; nt.textColor=ACCENT; nt.font=$.NSFont.systemFontOfSizeWeight(12.5,$.NSFontWeightSemibold); }   // dry run: say so plainly
cv.addSubview(nt);
var summary=label("",PAD+4,PBY+(PBH-18)/2,W-2*PAD-PBW-RBW-24,18,13,$.NSFontWeightSemibold); cv.addSubview(summary);
var pc=pill(L_CANCEL,W-PAD-RBW-12-PBW,PBY,PBW,PBH,hd,'no:','\u001b',false);
var pr=pill("",W-PAD-RBW,PBY,RBW,PBH,hd,'ok:','\r',true);

function refresh(){
 var n=0;
 GR.forEach(function(g){ var on=0;
  g.items.forEach(function(it){ if(ObjC.unwrap(it.cb.state)==1) on++; });
  g.cb.state = on==g.items.length ? 1 : (on==0 ? 0 : -1);
  g.size.stringValue = on ? on+" of "+g.items.length+" selected" : "None selected";
  n+=on; });
 summary.stringValue = n ? (n+(n==1?" certificate":" certificates")+(DRY?" would be removed":" selected")) : "Nothing selected";
 summary.textColor = n ? $.NSColor.labelColor : $.NSColor.secondaryLabelColor;
 var t=L_REMOVE.replace("{N}",n); if(n==1) t=t.replace(/Certificates\b/,"Certificate").replace(/certificates\b/,"certificate"); pr.set(t); pr.enable(n>0);
}
refresh();
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
var out=[]; ITEMS.forEach(function(it){ if(ObjC.unwrap(it.cb.state)==1) out.push(it.i); });
(resp==1 && out.length) ? out.join(",") : "__CANCEL__";
JXA
  } > "$s"
  run_window "$s"
}

# --- Removing -------------------------------------------------------------------------------------
# backup_dir -> creates this run's backup folder (root-only) with a manifest. Sets BACKUP_DIR.
backup_dir() {
  BACKUP_DIR="$BACKUP_PARENT/$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
  /bin/chmod 700 "$BACKUP_DIR" 2>/dev/null
  {
    print -r -- "Expired certificates removed by Delete Expired Certificates $SCRIPT_VERSION on $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    print -r -- "Mac: $(/usr/sbin/scutil --get ComputerName 2>/dev/null)   User: ${kcUser:-none}"
    print -r -- ""
    print -r -- "To put one back, add its .pem file to the keychain it came from:"
    print -r -- "  login keychain:  sudo -u <user> security add-certificates -k /Users/<user>/Library/Keychains/login.keychain-db <file>.pem"
    print -r -- "  System keychain: sudo security add-certificates -k /Library/Keychains/System.keychain <file>.pem"
    print -r -- "(Trust settings aren't restored; re-trust the certificate in Keychain Access if it needs it.)"
    print -r -- ""
  } > "$BACKUP_DIR/manifest.txt" 2>/dev/null
  return 0
}

# delete_cert <record #> -> backs it up, then removes it. 0 = removed. Never removes without a backup.
delete_cert() {
  local i=$1 sha="${C_SHA[$1]}" kc="${C_KC[$1]}" dest
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to remove ${C_NAME[i]}."; return 1; }   # belt and braces
  dest="$BACKUP_DIR/${${C_NAME[i]//[^A-Za-z0-9._@-]/_}[1,60]}_${kc:t:r}_${sha:0:8}.pem"
  if ! { /bin/cp -f "${C_PEM[i]}" "$dest" 2>/dev/null && [[ -s "$dest" ]]; }; then
    logMe ERROR "Couldn't back up ${C_NAME[i]} (${sha:0:8}…) — keeping it."; return 1
  fi
  print -r -- "${dest:t}  |  ${kc}  |  expired $(/bin/date -r ${C_END[i]} '+%Y-%m-%d')  |  SHA-1 $sha  |  ${C_SUBJ[i]}" >> "$BACKUP_DIR/manifest.txt"
  if (( C_LOGIN[i] )); then run_as_user /usr/bin/security delete-certificate -Z "$sha" "$kc" >/dev/null 2>&1
  else /usr/bin/security delete-certificate -Z "$sha" "$kc" >/dev/null 2>&1; fi
  if (( $? == 0 )); then logMe INFO "  removed: ${C_NAME[i]}  [${kc:t}, ${sha:0:8}…]  backup: ${dest:t}"; return 0; fi
  logMe ERROR "  FAILED: ${C_NAME[i]}  [${kc:t}, ${sha:0:8}…]$( (( C_LOGIN[i] || amRoot )) || print " (needs root)")"
  return 1
}

# remove_selected -> removes every record in SEL with progress. Sets REMOVED_N / FAILED_N.
remove_selected() {
  REMOVED_N=0; FAILED_N=0
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: removal skipped."; return 0; }
  local i k=0 n=${#SEL} t0
  # show each certificate for a moment (about 2.5s in all at most) so the user sees it work
  local step=$(( 2.5 / n )); (( step > 0.5 )) && step=0.5; (( step < 0.05 )) && step=0
  for i in $SEL; do
    (( k++ )); t0=$EPOCHREALTIME
    spin_status "${C_NAME[i]}" "$k of $n certificates" "$(( k - 1 ))/$n" "Removing"
    if delete_cert $i; then (( REMOVED_N++ )); else (( FAILED_N++ )); fi
    pace_until $t0 $step
  done
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


# DC_LIB=1 source Delete_Expired_Certificates.sh  -> loads the functions without running anything (testing).
[[ -n "$DC_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Delete Expired Certificates $SCRIPT_VERSION — mode=${ACTION_MODE}$([[ $DRY_RUN == true ]] && print " (DRY RUN — nothing will be removed)"); excludes=(${(j:, :)EXCLUDE_PATTERNS}); user=${kcUser:-none}; running as $(/usr/bin/id -un)"
if [[ "$ACTION_MODE" == verbose && -z "$consoleUser" ]] && (( amRoot )); then
  logMe INFO "No one is logged in, so there's no one to show the windows to. Nothing removed. (Use Action Mode \"silent\" for unattended cleanup.)"
  exit 0
fi
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

# --- 1. Find expired certificates ----------------------------------------------------------------
if [[ -n "$USER_HOME" && -e "$USER_HOME/Library/Keychains/login.keychain-db" ]]; then
  scan_keychain "$USER_HOME/Library/Keychains/login.keychain-db" 1
else
  logMe INFO "No login keychain for ${kcUser:-<no user>} — checking the System keychain only."
fi
if [[ "$SCAN_SYSTEM_KEYCHAIN" == true ]]; then
  if (( amRoot )) || [[ "$DRY_RUN" == true ]]; then scan_keychain "/Library/Keychains/System.keychain" 0
  else logMe INFO "Not running as root — skipping the System keychain (only root can change it; it's still listed in a dry run)."; fi
fi
total=${#C_SHA}
logMe INFO "Found $total expired certificate(s) to remove$( (( ${#EXCLUDED} )) && print ", ${#EXCLUDED} kept by the exclude list")."

if (( total == 0 )); then
  logMe INFO "Nothing to remove."
  show_message "$NONE_TITLE" "checkmark.seal.fill" ok "You're all set\nThere are no expired certificates on this Mac to remove." ""
  exit 0
fi

# --- 2. What to remove ---------------------------------------------------------------------------
typeset -a SEL ORDER
if [[ "$ACTION_MODE" == verbose ]]; then
  write_review
  out="$(show_review)"
  [[ "$out" == "__CANCEL__" || -z "$out" || "$out" != [0-9,]## ]] && { logMe INFO "User cancelled (or kept everything). Nothing removed."; exit 0; }
  for i in ${(s:,:)out}; do SEL+=(${ORDER[$(( i + 1 ))]}); done
  logMe INFO "User confirmed ${#SEL} of $total certificate(s)."
else
  SEL=( {1..$total} )
  logMe INFO "Silent mode: removing all $total expired certificate(s)."
fi
(( ${#SEL} )) || { logMe INFO "Nothing selected. Nothing removed."; exit 0; }
plural() { (( $1 == 1 )) && print -r -- "$1 $2" || print -r -- "$1 ${2}s"; }

if [[ "$DRY_RUN" == true ]]; then
  logMe INFO "DRY RUN — nothing changed. Would remove ${#SEL} certificate(s):"
  for i in $SEL; do logMe INFO "  would remove: ${C_NAME[i]}  [${C_KC[i]:t}, ${C_SHA[i]:0:8}…]"; done
  show_message "$DRY_TITLE" "eye.circle.fill" ok "Preview only — nothing was removed\n$(plural ${#SEL} "expired certificate") would have been backed up and removed." ""
  exit 0
fi

# --- 3. Remove -----------------------------------------------------------------------------------
if (( ! amRoot )) && [[ -n "$USER_HOME" ]]; then   # testing by hand: /var/log needs root, so back up in the user's Logs
  BACKUP_PARENT="$USER_HOME/Library/Logs/expired-cert-backups"
fi
if ! backup_dir; then
  logMe ERROR "Couldn't create the backup folder in $BACKUP_PARENT — nothing removed (needs root)."
  show_message "Certificates Not Removed" "xmark.octagon.fill" fail "Nothing was removed\nThe backup folder couldn't be created, so no certificates were touched. Contact IT if you need help." ""
  exit 1
fi
logMe INFO "Backups -> $BACKUP_DIR"
show_spinner "$REMOVING_TITLE" nocancel
/bin/sleep 0.6                      # let the window appear before the first certificate goes
remove_selected
spin_status "Cleaning up…" "${#SEL} of ${#SEL} certificates" "1/1" "Finishing"
/bin/sleep 0.8                      # let the bar reach the end before the result window
kill_spinner
logMe INFO "Done: removed $REMOVED_N of ${#SEL} certificate(s), $FAILED_N failure(s). Backups: $BACKUP_DIR"
if (( FAILED_N == 0 )); then
  show_message "$DONE_TITLE" "checkmark.circle.fill" ok "Removed $(plural $REMOVED_N "expired certificate")\nA backup of each one is kept, so IT can restore it if it's ever needed." ""
  exit 0
fi
show_message "Some Certificates Weren't Removed" "exclamationmark.triangle.fill" fail "$(plural $FAILED_N "certificate") couldn't be removed\nRemoved $REMOVED_N of ${#SEL}. Contact IT if you need help." ""
exit 1
