#!/bin/zsh

####################################################################################################
#
# Reset User Keychain
#
# Purpose: Reset Users keychain
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 04/10/24 - Original
# 1.1 09/04/24 - Added adjustable Variables
# 2.0 11/13/26 - Redesign to match the other Self Service tools: branded windows (logo, brand name,
#               banner colour, light/dark) that explain what happens; the keychain is backed up
#               (moved to a dated folder), never deleted; login keychain only unless Local Items is
#               switched on; Restart Now / Later at the end; verbose / dry / silent modes ($4),
#               Local Items ($5), branding in $6-$9. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# WHAT TO RESET -------------------------------------------------------------
RESET_LOCAL_ITEMS=false     # true = also reset the Local Items keychain (the UUID-named folder that holds the
                            # iCloud Keychain / Local Items data). Fixes repeated "Local Items" prompts.
                            # In the window this is the switch's starting position. ($5 overrides)
DRY_RUN_OVERRIDE=false      # true = ALWAYS preview (show the windows, change NOTHING). Keep false for production.
BACKUP_FOLDER_NAME="Keychains Backup"   # created in the user's ~/Library; each reset gets a dated folder inside
logFile="/var/log/reset_user_keychain.log"   # this script's own run log

# BRANDING (windows only) ---------------------------------------------------
BRAND_NAME="IT Support"    # small line above the banner title — your team, e.g. "Acme IT". Blank = none. ($8)
BRAND_ICON=""              # optional logo ($6). Accepts any ONE of:
                           #   • an image file  /Library/Application Support/Acme/logo.png
                           #   • an app/folder  /Applications/Self Service.app   (uses its Finder icon)
                           #   • a URL          https://acme.com/logo.png         (downloaded each run)
                           #   • base64         iVBORw0KGgoAAAANSUhEUgAA...       (make: base64 -i logo.png | pbcopy)
                           #   • an SF Symbol   sf:key.fill                       (tinted to match the theme)
                           #   • Self Service   selfservice (or: ss) — your Jamf Self Service branding logo
                           # Blank = no logo.

# APPEARANCE ----------------------------------------------------------------
APPEARANCE="auto"          # auto = follow the user's Light/Dark setting; light or dark forces one. ($9)

# COLOURS -------------------------------------------------------------------
# Each takes a hex value (#RRGGBB or #RGB) or "auto". A bad hex value is treated as "auto".
bannerColor="auto"         # banner + main button ($7). auto = the logo's exact main colour;
                           # auto-dark = a deeper shade of it for white text; no logo = #0056D2
BANNER_TEXT_COLOR="auto"   # auto = white, or near-black if the banner is too light for white
ACCENT_COLOR="auto"        # icons, switch, buttons. auto = the banner colour, made readable
SPINNER_BG_COLOR="auto"    # auto = #F5F5F7 light / #1C1C1E dark
SUCCESS_COLOR="auto"       # "Keychain Reset" icon. auto = Apple green
FAIL_COLOR="auto"          # error icon. auto = Apple red

# TEXT ----------------------------------------------------------------------
CONFIRM_TITLE="Reset Keychain"
CONFIRM_SUBTITLE="Fix keychain password prompts with a fresh keychain"
DRY_NOTE="Preview only — your keychain won't be changed, so you can click through safely."   # shown in dry runs
DONE_TITLE="Keychain Reset"
FAIL_TITLE="Keychain Not Reset"
DRY_TITLE="Preview Complete"
resetButton="Reset Keychain"
previewButton="Finish Preview"      # replaces the Reset button in preview (dry-run) mode
cancelButton="Cancel"
restartButton="Restart Now"
laterButton="Later"
okButton="Done"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob extended_glob typeset_silent
zmodload zsh/datetime 2>/dev/null

SCRIPT_VERSION="2.0"
SCRATCH="/tmp/reset-keychain.$$"
/bin/mkdir -p "$SCRATCH"; /bin/chmod 755 "$SCRATCH"
[[ -n "$RK_DEBUG" ]] || trap '/bin/rm -rf "$SCRATCH"' EXIT   # RK_DEBUG=1 keeps the scratch folder (testing)
STATUS_FILE="$SCRATCH/status.txt"; CANCEL_FILE="$SCRATCH/cancel.flag"; : > "$CANCEL_FILE"; /bin/chmod 666 "$CANCEL_FILE"
REVIEW_FILE="$SCRATCH/info.txt"

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
case "${2:l}" in yes|true|1|on) RESET_LOCAL_ITEMS=true ;; no|false|0|off) RESET_LOCAL_ITEMS=false ;; esac
[[ -n "$3" ]] && BRAND_ICON="$3"
[[ -n "$4" ]] && bannerColor="$4"
[[ -n "$5" ]] && BRAND_NAME="$5"
[[ -n "$6" ]] && APPEARANCE="$6"
APPEARANCE="${APPEARANCE:l}"; [[ "$APPEARANCE" == (light|dark) ]] || APPEARANCE="auto"
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
# Whose keychain: the console user, else the user Jamf passed in (never root)
kcUser="${consoleUser:-$JAMF_USER}"; [[ "$kcUser" == root ]] && kcUser=""
(( amRoot )) || kcUser="$(/usr/bin/id -un)"
USER_HOME=""
if [[ -n "$kcUser" ]]; then
  USER_HOME=$(/usr/bin/dscl . -read /Users/"$kcUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$kcUser"
fi
KC_DIR="$USER_HOME/Library/Keychains"

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


# --- What's in the user's keychain folder ---------------------------------------------------------
# LOGIN_FILES = the login keychain (plus the old-style name and its metadata file, if there)
# LOCAL_DIRS  = the Local Items keychain folder(s) (named with the Mac's hardware UUID)
typeset -a LOGIN_FILES LOCAL_DIRS
find_keychains() {
  LOGIN_FILES=(); LOCAL_DIRS=()
  local f
  for f in "$KC_DIR"/login.keychain-db "$KC_DIR"/login.keychain "$KC_DIR"/metadata.keychain-db; do [[ -e "$f" ]] && LOGIN_FILES+=("$f"); done
  for f in "$KC_DIR"/[0-9A-Fa-f](#c8)-[0-9A-Fa-f](#c4)-[0-9A-Fa-f](#c4)-[0-9A-Fa-f](#c4)-[0-9A-Fa-f](#c12)(N/); do LOCAL_DIRS+=("$f"); done
}
# kc_info -> REPLY = "Last changed Nov 13, 2026 · 1.2 MB" for the login keychain (or "" if it isn't there)
kc_info() {
  REPLY=""
  local f="$KC_DIR/login.keychain-db"; [[ -e "$f" ]] || f="$KC_DIR/login.keychain"; [[ -e "$f" ]] || return 1
  local mt=$(/usr/bin/stat -f %m "$f" 2>/dev/null) kb=$(/usr/bin/du -sk "$f" 2>/dev/null | /usr/bin/awk '{print $1}')
  REPLY="Last changed $(/bin/date -r ${mt:-0} '+%b %-d, %Y')  ·  $(human_kb ${kb:-0})"
}

# --- Confirm window ---------------------------------------------------------------------------------
# What will happen in plain words, the user's login keychain (when it last changed, its size), a switch to
# also reset Local Items, and Reset / Cancel. Prints "reset<TAB>localItems(1/0)" or __CANCEL__.
show_confirm() {
  local s="$SCRATCH/confirm.jxa"
  kc_info; local info="$REPLY"
  {
    win_prelude
    print -r -- "var CTITLE=\"$(as_esc "$CONFIRM_TITLE")\", CSUB=\"$(as_esc "$CONFIRM_SUBTITLE")\", DNOTE=\"$(as_esc "$DRY_NOTE")\", INFO=\"$(as_esc "$info")\", HASLOCAL=$( (( ${#LOCAL_DIRS} )) && print true || print false);"
    print -r -- "var L_RESET=\"$(as_esc "$([[ $DRY_RUN == true ]] && print -r -- "$previewButton" || print -r -- "$resetButton")")\", L_CANCEL=\"$(as_esc "$cancelButton")\", DRY=$DRY_RUN, LOCAL=$RESET_LOCAL_ITEMS, BKNAME=\"$(as_esc "$BACKUP_FOLDER_NAME")\";"
    /bin/cat <<'JXA'
if(!$.RKConfirm){ObjC.registerSubclass({name:'RKConfirm',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});}
var hd=$.RKConfirm.alloc.init;
// A non-activating panel: it takes the keyboard even when macOS won't bring a script launched by Jamf to the front
if(!$.RKPanel){ObjC.registerSubclass({name:'RKPanel',superclass:'NSPanel',methods:{
 'canBecomeKeyWindow':{types:['bool',[]],implementation:function(){ return true; }}}});}

// ---- sizes and positions (bottom-up) ----
var W=640, PAD=24, BH=(BNAME?96:84), PBW=150, PBW2=190, PBH=34, PBY=18;
var noteY=PBY+PBH+12, NOTEH=DRY?16:0, togY=noteY+NOTEH+(DRY?12:2), TOGH=HASLOCAL?58:0, stepsY=togY+TOGH+(HASLOCAL?12:0), STEPH=4*52+14, kcY=stepsY+STEPH+12, KCH=64;
var H=kcY+KCH+18+BH;
var win=$.RKPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15)|(1<<7),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR; win.hidesOnDeactivate=false;
var cv=win.contentView;
header(cv,W,H,BH,PAD,CTITLE,CSUB,DRY?"Preview only":"",DRY?"eye.fill":"");
function card(x,y,w,h){ var b=rbox(x,y,w,h,DARK?C([1,1,1],0.06):C([0,0,0],0.045),12);
 b.borderWidth=1; b.borderColor=DARK?C([1,1,1],0.12):C([0,0,0],0.09); cv.addSubview(b); return b; }

// The login keychain: Keychain Access's icon, when it last changed and how big it is
card(PAD,kcY,W-2*PAD,KCH);
// Keychain Access's icon (it moved in macOS 15), else a key in an accent tile
var KCA=["/System/Library/CoreServices/Applications/Keychain Access.app","/System/Applications/Utilities/Keychain Access.app"].filter(function(p){ return $.NSFileManager.defaultManager.fileExistsAtPath(p); })[0];
if(KCA){ var kv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(PAD+14,kcY+(KCH-40)/2,40,40)); kv.image=$.NSWorkspace.sharedWorkspace.iconForFile(KCA); kv.imageScaling=3; cv.addSubview(kv); }
else { cv.addSubview(rbox(PAD+14,kcY+(KCH-40)/2,40,40,ACCENT.colorWithAlphaComponent(DARK?0.20:0.12),10)); var kk=sym("key.fill",PAD+24,kcY+(KCH-20)/2,20,ACCENT); if(kk) cv.addSubview(kk); }
var k1=label("Your login keychain",PAD+66,kcY+KCH/2+1,W-2*PAD-80,19,14,$.NSFontWeightBold); k1.font=rounded(14,$.NSFontWeightBold); cv.addSubview(k1);
var k2=label(INFO||"Not found — a new one will be made when you log in",PAD+66,kcY+KCH/2-17,W-2*PAD-80,16,11.5); k2.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(k2);

// What happens, step by step
card(PAD,stepsY,W-2*PAD,STEPH);
var STEPS=[
 ["archivebox.fill","Your keychain is backed up, not deleted","It's moved to “"+BKNAME+"” in your Library, so IT can bring it back."],
 ["key.fill","A new keychain is made with your current password","This stops “login keychain” password prompts after a password change."],
 ["icloud.fill","iCloud Keychain passwords come back on their own","Other saved passwords (some websites, apps, Wi-Fi) need to be entered again."],
 ["arrow.clockwise.circle.fill","Restart when it's done","Your Mac starts using the new keychain after a restart."]];
STEPS.forEach(function(st,k){ var y=stepsY+STEPH-7-(k+1)*52;
 cv.addSubview(rbox(PAD+14,y+(52-32)/2,32,32,ACCENT.colorWithAlphaComponent(DARK?0.20:0.12),8));
 var si=sym(st[0],PAD+14+7,y+(52-18)/2,18,ACCENT); if(si) cv.addSubview(si);
 var t=label(st[1],PAD+58,y+52/2+1,W-2*PAD-72,18,13,$.NSFontWeightSemibold); cv.addSubview(t);
 var d=label(st[2],PAD+58,y+52/2-16,W-2*PAD-72,15,11.5); d.textColor=$.NSColor.secondaryLabelColor; d.cell.lineBreakMode=4; d.toolTip=st[2]; cv.addSubview(d);
 if(k<STEPS.length-1) cv.addSubview(rbox(PAD+58,y,W-2*PAD-72,1,G(DARK?0.16:0.12))); });

// Also reset Local Items (only when there is one)
var TOG={on:LOCAL};
if(HASLOCAL){
 card(PAD,togY,W-2*PAD,TOGH);
 var t1=label("Also reset Local Items",PAD+16,togY+TOGH/2+1,W-2*PAD-100,18,13,$.NSFontWeightSemibold); cv.addSubview(t1);
 var t2=label("Fixes repeated “Local Items” password prompts. Usually not needed.",PAD+16,togY+TOGH/2-16,W-2*PAD-100,15,11.5); t2.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(t2);
 if(!$.RKToggle){ ObjC.registerSubclass({name:'RKToggle',superclass:'NSView',methods:{
  'acceptsFirstMouse:':{types:['bool',['id']],implementation:function(e){ return true; }},
  'resetCursorRects':{implementation:function(){ this.addCursorRectCursor(this.bounds,$.NSCursor.pointingHandCursor); }},
  'drawRect:':{implementation:function(r){ var b=this.bounds, h=b.size.height, w=b.size.width;
    var tr=$.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(b,h/2,h/2); (TOG.on?ACCENT:(DARK?C([1,1,1],0.20):C([0,0,0],0.16))).setFill; tr.fill;
    var k=h-4, kn=$.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(TOG.on?w-k-2:2,2,k,k)); $.NSColor.whiteColor.setFill; kn.fill;
    C([0,0,0],0.12).setStroke; kn.lineWidth=0.5; kn.stroke; }},
  'mouseUp:':{types:['void',['id']],implementation:function(e){ }},
  'mouseDown:':{types:['void',['id']],implementation:function(e){ TOG.on=!TOG.on; this.needsDisplay=true; }}}}); }
 var tv=$.RKToggle.alloc.initWithFrame($.NSMakeRect(W-PAD-16-42,togY+(TOGH-24)/2,42,24)); cv.addSubview(tv); TOG.view=tv;
}

// Footer
if(DRY){ var nt=label(DNOTE,PAD,noteY,W-2*PAD,16,12,$.NSFontWeightSemibold,1); nt.textColor=ACCENT; cv.addSubview(nt); }
var BX=(W-(PBW+12+PBW2))/2;   // the two buttons, centred
var pc=pill(L_CANCEL,BX,PBY,PBW,PBH,hd,'no:','\u001b',false);
var pk=pill(L_RESET,BX+PBW+12,PBY,PBW2,PBH,hd,'ok:','\r',true);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
try{ app.activate; }catch(e){} try{ $.NSRunningApplication.currentApplication.activateWithOptions(3); }catch(e){}
var resp=app.runModalForWindow(win); win.orderOut(null);
(resp==1) ? "reset\t"+(TOG.on?"1":"0") : "__CANCEL__";
JXA
  } > "$s"
  run_window "$s"
}

# --- Done window: where the backup is, and Restart Now / Later ----------------------------------------
# show_done <headline> <detail> <backup path> -> prints "restart" or "later"
show_done() {
  local s="$SCRATCH/done.jxa"
  {
    win_prelude
    print -r -- "var DTITLE=\"$(as_esc "$DONE_TITLE")\", M1=\"$(as_esc "$1")\", M2=\"$(as_esc "$2")\", BK=\"$(as_esc "$3")\", BKSHOW=\"$(as_esc "${3/#$USER_HOME/~}")\", L_RESTART=\"$(as_esc "$restartButton")\", L_LATER=\"$(as_esc "$laterButton")\";"
    /bin/cat <<'JXA'
if(!$.RKDone){ObjC.registerSubclass({name:'RKDone',superclass:'NSObject',methods:{
 'restart:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'later:':{types:['void',['id']],implementation:function(s){$.NSApplication.sharedApplication.stopModalWithCode(0);}},
 'reveal:':{types:['void',['id']],implementation:function(s){ reveal(BK); }}}});}
var hd=$.RKDone.alloc.init;
var W=560, PAD=24, BH=(BNAME?96:84), PBW=150, PBW2=170, PBH=34, PBY=20, chipH=34, chipY=PBY+PBH+16, msgY=chipY+chipH+14, MSGH=66, iconY=msgY+MSGH+10, ICS=56;
var H=iconY+ICS+20+BH;
var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true; win.appearance=APPEAR;
var cv=win.contentView;
header(cv,W,H,BH,PAD,DTITLE,"A fresh keychain is ready","","");
// the status icon
var img=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("checkmark.circle.fill","");
if(isOk(img)){ try{ var pc0=$.NSImageSymbolConfiguration.configurationWithPaletteColors($([$.NSColor.whiteColor,OKC])); var pi=img.imageWithSymbolConfiguration(pc0); if(isOk(pi)) img=pi; }catch(e){}
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect((W-ICS)/2,iconY,ICS,ICS)); iv.image=img; iv.imageScaling=3; iv.contentTintColor=OKC; cv.addSubview(iv); }
var l1=label(M1,PAD,msgY+MSGH-20,W-2*PAD,19,14.5,$.NSFontWeightSemibold,1); cv.addSubview(l1);
var l2=wrapLabel(M2,PAD+10,msgY,W-2*PAD-20,MSGH-26,12.5,1); l2.textColor=$.NSColor.secondaryLabelColor; cv.addSubview(l2);
// the backup folder: click to show it in Finder
if(BK){ var chip=$.NSBox.alloc.initWithFrame($.NSMakeRect(PAD+16,chipY,W-2*PAD-32,chipH)); chip.boxType=4; chip.titlePosition=0; chip.cornerRadius=8;
 chip.fillColor=ACCENT.colorWithAlphaComponent(DARK?0.14:0.09); chip.borderWidth=1; chip.borderColor=ACCENT.colorWithAlphaComponent(DARK?0.35:0.28); cv.addSubview(chip);
 var fi=sym("archivebox.fill",PAD+28,chipY+(chipH-16)/2,16,ACCENT); if(fi) cv.addSubview(fi);
 var fl=label("Backup:  "+BKSHOW,PAD+52,chipY+(chipH-17)/2,W-2*PAD-32-60,17,12,$.NSFontWeightMedium); fl.cell.lineBreakMode=5; cv.addSubview(fl);
 var ff=sym("folder",W-PAD-16-26,chipY+(chipH-16)/2,16,ACCENT); if(ff) cv.addSubview(ff);
 clickArea(PAD+16,chipY,W-2*PAD-32,chipH,hd,'reveal:',0,cv,true).toolTip="Show in Finder"; }
var BX=(W-(PBW+12+PBW2))/2;   // the two buttons, centred
var pl=pill(L_LATER,BX,PBY,PBW,PBH,hd,'later:','\u001b',false);
var pr=pill(L_RESTART,BX+PBW+12,PBY,PBW2,PBH,hd,'restart:','\r',true);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
try{ $.NSRunningApplication.currentApplication.activateWithOptions(3); }catch(e){}
var resp=app.runModalForWindow(win); win.orderOut(null);
resp==1 ? "restart" : "later";
JXA
  } > "$s"
  run_window "$s"
}

# --- Resetting --------------------------------------------------------------------------------------
# reset_keychain <localItems 1/0> -> moves the keychain files into a dated backup folder. Sets BACKUP_DIR,
# MOVED_N. 0 = everything moved. Never deletes anything.
reset_keychain() {
  local withLocal=$1 f
  [[ "$DRY_RUN" == true ]] && { logMe WARN "Preview mode: refusing to change the keychain."; return 1; }   # belt and braces
  local -a items=("${LOGIN_FILES[@]}"); [[ "$withLocal" == 1 ]] && items+=("${LOCAL_DIRS[@]}")
  BACKUP_DIR="$USER_HOME/Library/$BACKUP_FOLDER_NAME/$(/bin/date '+%Y-%m-%d %H.%M.%S')"; MOVED_N=0
  if ! /bin/mkdir -p "$BACKUP_DIR" 2>/dev/null; then logMe ERROR "Couldn't create the backup folder: $BACKUP_DIR"; return 1; fi
  for f in "${items[@]}"; do
    if /bin/mv "$f" "$BACKUP_DIR/" 2>/dev/null; then logMe INFO "  backed up: ${f/#$USER_HOME/~}"; (( MOVED_N++ ))
    else logMe ERROR "  FAILED to move: $f"; fi
  done
  # the backup belongs to the user, and only they (and root) can read it
  (( amRoot )) && /usr/sbin/chown -R "$kcUser" "${BACKUP_DIR:h}" 2>/dev/null
  /bin/chmod 700 "${BACKUP_DIR:h}" "$BACKUP_DIR" 2>/dev/null
  {
    print -r -- "Keychain backup made by Reset User Keychain $SCRIPT_VERSION on $(/bin/date '+%Y-%m-%d %H:%M:%S') for $kcUser."
    print -r -- ""
    print -r -- "To put it back: log out (or restart and don't log in as $kcUser), then move these files back into"
    print -r -- "$KC_DIR/ (replacing the new ones). The old keychain still uses the password it had when it was backed up."
  } > "$BACKUP_DIR/README.txt" 2>/dev/null
  (( amRoot )) && /usr/sbin/chown "$kcUser" "$BACKUP_DIR/README.txt" 2>/dev/null
  (( MOVED_N == ${#items} ))
}

# restart_mac -> asks macOS to restart the way the Apple menu does (apps can still ask to save their work)
restart_mac() {
  run_as_user /usr/bin/osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1 \
    || { (( amRoot )) && /sbin/shutdown -r +1 >/dev/null 2>&1; }
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



# RK_LIB=1 source Reset_User_Keychain.sh  -> loads the functions without running anything (testing).
[[ -n "$RK_LIB" ]] && return 0

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Reset User Keychain $SCRIPT_VERSION — mode=${ACTION_MODE}$([[ $DRY_RUN == true ]] && print " (DRY RUN — nothing will be changed)"); user=${kcUser:-none}; local items=$RESET_LOCAL_ITEMS; running as $(/usr/bin/id -un)"
if [[ -z "$kcUser" || ! -d "$KC_DIR" ]]; then
  logMe ERROR "No logged-in user with a keychain folder (${KC_DIR:-none}). Nothing changed."; exit 1
fi
if [[ "$ACTION_MODE" == verbose && -z "$consoleUser" ]] && (( amRoot )); then
  logMe INFO "No one is logged in, so there's no one to confirm. Nothing changed. (Use Action Mode \"silent\".)"; exit 0
fi
[[ "$ACTION_MODE" == "verbose" ]] && { resolve_brand_icon; build_palette; }

find_keychains
logMe INFO "Login keychain files: ${(j:, :)${LOGIN_FILES[@]:t}:-none}; Local Items folders: ${(j:, :)${LOCAL_DIRS[@]:t}:-none}"
if (( ! ${#LOGIN_FILES} && ! ${#LOCAL_DIRS} )); then
  logMe INFO "There's no keychain to reset. Nothing changed."
  show_message "$DONE_TITLE" "checkmark.circle.fill" ok "There's nothing to reset\nmacOS will make a new keychain the next time you log in." ""
  exit 0
fi

# --- 1. Confirm --------------------------------------------------------------------------------
WITH_LOCAL=$([[ "$RESET_LOCAL_ITEMS" == true ]] && print 1 || print 0)
if [[ "$ACTION_MODE" == verbose ]]; then
  out="$(show_confirm)"
  [[ "$out" == reset$'\t'* ]] || { logMe INFO "User cancelled. Nothing changed."; exit 0; }
  WITH_LOCAL="${out#*$'\t'}"
  logMe INFO "User confirmed the reset$([[ $WITH_LOCAL == 1 ]] && print " (including Local Items)")."
else
  logMe INFO "Silent mode: resetting the keychain$([[ $WITH_LOCAL == 1 ]] && print " (including Local Items)")."
fi
(( ${#LOGIN_FILES} )) || [[ "$WITH_LOCAL" == 1 ]] || { logMe INFO "No login keychain and Local Items not chosen. Nothing changed."; exit 0; }

if [[ "$DRY_RUN" == true ]]; then
  logMe INFO "DRY RUN — nothing changed. Would back up and reset:"
  for f in "${LOGIN_FILES[@]}"; do logMe INFO "  would move: ${f/#$USER_HOME/~}"; done
  [[ "$WITH_LOCAL" == 1 ]] && for f in "${LOCAL_DIRS[@]}"; do logMe INFO "  would move: ${f/#$USER_HOME/~}"; done
  show_message "$DRY_TITLE" "eye.circle.fill" ok "Preview only — nothing was changed\nYour keychain$([[ $WITH_LOCAL == 1 ]] && print " and Local Items") would have been backed up to “$BACKUP_FOLDER_NAME” and a new one made after a restart." ""
  exit 0
fi

# --- 2. Reset ----------------------------------------------------------------------------------
if ! reset_keychain "$WITH_LOCAL"; then
  logMe ERROR "FAILED: moved $MOVED_N item(s); some couldn't be moved. Backup folder: ${BACKUP_DIR:-none}"
  show_message "$FAIL_TITLE" "xmark.octagon.fill" fail "Your keychain couldn't be fully reset\nSome files couldn't be moved. Nothing was deleted. Contact IT for help." ""
  exit 1
fi
logMe INFO "Done: backed up and reset the keychain ($MOVED_N item(s)) to $BACKUP_DIR."

# --- 3. Restart --------------------------------------------------------------------------------
if [[ "$ACTION_MODE" == verbose ]]; then
  choice="$(show_done "Your keychain has been reset" "Restart now so your Mac makes a new keychain with your current password. Until then, some apps may ask for keychain passwords." "$BACKUP_DIR")"
  if [[ "$choice" == restart ]]; then logMe INFO "User chose Restart Now."; restart_mac
  else logMe INFO "User chose Later — the new keychain takes effect after the next restart."; fi
else
  logMe INFO "Silent mode: not restarting. The new keychain takes effect after the user's next restart."
fi
exit 0
