#!/bin/zsh --no-rcs

####################################################################################################
#
# Installomator Progress
#
# Purpose: Installs or updates apps with Installomator and shows the user a small progress window
#          (icon, message, progress bar, status) — without swiftDialog. One script replaces
#          "00 - Prepare SwiftDialog" → Installomator → "ZZ - Quit SwiftDialog".
#
# Note: Fully native — the window is built with osascript (JXA) + AppKit and shown in the logged-in
#       user's session, so it works when Jamf runs the script as root. Like App Auto-Patch, it keeps
#       its own local copy of Installomator (see INSTALLOMATOR below).
#
# What the user sees:
#   A small window with the app icon, your message, a progress bar and a status line:
#     Starting…  →  Downloading... 42%  →  Verifying... / Installing...  →  Done
#   The bar fills with the real download progress. While Installomator is busy without a percentage,
#   the bar dims and a bright segment sweeps across it. Four window styles: mini, toast, card, hud.
#
# ---------------------------------------------------------------------------------------------
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:   Installomator label(s)
#   Parameter 5 Label:   Message (text above the progress bar)
#   Parameter 6 Label:   Icon (path, .app, URL, sf:symbol, or selfservice)
#   Parameter 7 Label:   Overlay icon (path, .app, URL, sf:symbol, selfservice, or none)
#   Parameter 8 Label:   Extra Installomator options (optional)
#   Parameter 9 Label:   Installomator version (main, release, or a version like 10.8)
#   Parameter 10 Label:  Window style and/or position (mini, toast, card, hud)
#   Parameter 11 Label:  Show app version in the status text (show or hide)
#
#   When you add this script to a policy, fill the parameters like this (blank = the default):
#     $4  Labels        REQUIRED. One Installomator label, or several separated by spaces.
#                       examples: googlechromepkg      zoom slack
#     $5  Message       blank = "Installing <label>…"
#                       example:  Installing Google Chrome…
#     $6  Icon          blank = the App Store icon. If the icon can't be loaded, the App Store icon is used.
#                       examples: /Applications/Google Chrome.app
#                                 https://acme.com/chrome.png   (e.g. the policy's Self Service icon URL)
#                                 sf:shippingbox
#                                 selfservice
#     $7  Overlay icon  small logo on the corner of the icon. If it can't be loaded, no overlay is shown.
#                       blank = /Library/Application Support/Dialog/Dialog.png if it exists, else selfservice
#                       none  = no overlay
#     $8  Options       any Installomator VAR=value options, separated by spaces (NOTIFY=silent is always set)
#                       examples: INSTALL=force      BLOCKING_PROCESS_ACTION=prompt_user      DEBUG=1
#     $9  Installomator blank = main   · release   · 10.8          (see INSTALLOMATOR_VERSION below)
#     $10 Window        a style, a position, or both — blank = mini in the bottom right
#                       styles:    mini · toast · card · hud      (or 1 · 2 · 3 · 4)
#                       positions: bottomright · bottomleft · bottomcenter · topright · topleft · topcenter · center
#                       examples:  card      toast      mini topleft      hud topcenter
#     $11 Version       blank = hide  ("Downloading...")   · show  ("v1.2.4 Downloading...")
#
#   selfservice = your Jamf Self Service branding image (Jamf Pro > Self Service > Branding, cached on
#                 the Mac for the logged-in user), else the Self Service / Self Service+ app icon.
#
# ---------------------------------------------------------------------------------------------
#
# TESTING (as root — the first three arguments stand in for Jamf's mount point, computer and user):
#   sudo ./Installomator_Progress.sh / "" "" mace "Installing MACE…" "/Applications/MACE.app" "" "DEBUG=1"
#   sudo ./Installomator_Progress.sh / "" "" mace "Installing MACE…" "/Applications/MACE.app" "" "INSTALL=force" "" card
#   DEBUG=1 downloads and checks the app but never installs it — a safe way to watch the window.
#
# Exit codes: 0 = every label installed or was already up to date. Otherwise Installomator's exit code
#             for the last label that failed (so the policy shows as failed in Jamf).
#             1 = Installomator couldn't be downloaded and there's no local copy.
#             95/96/97/98 = bad $9 value / no label in $4 / not run as root / macOS older than 11.
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 11/13/26 - Original release: one script replacing "00 - Prepare SwiftDialog" + Installomator +
#                "ZZ - Quit SwiftDialog", with no swiftDialog. Keeps its own copy of Installomator like
#                App Auto-Patch (main, latest signed release, or a pinned version). Native progress window
#                in four styles (mini, toast, card, hud) with a smooth dimmed + sweep progress bar, your
#                icons and bar color, light and dark mode, and a clean log with a result per app.
#                - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------
# (Settings marked with a $ number can also be set per policy with that Jamf parameter.)

# INSTALLOMATOR -------------------------------------------------------------
# Which Installomator to use ($9):
#   main     the main branch on GitHub (default, like App Auto-Patch): the newest labels and fixes,
#            including ones not in a release yet. Not signed, so it's checked for being a complete
#            Installomator script instead.
#   release  the latest signed release: the pkg's Apple notarisation and Team ID are checked.
#   10.8     a specific signed release, pinned. Never updated automatically.
# The copy is kept in INSTALLOMATOR_DIR and only downloaded again when it's out of date or you switch
# version. If GitHub can't be reached, the local copy is used.
INSTALLOMATOR_VERSION="main"
INSTALLOMATOR_DIR="/Library/Management/Installomator"
INSTALLOMATOR_TEAM_ID="JME5BW3F3R"   # the Team ID release pkgs must be signed with
CHECK_FOR_UPDATES=true               # false = only download when it's missing or you switch version
DEFAULT_OPTIONS="NOTIFY=silent"      # always passed to Installomator, before $8 (so $8 can override it)

# WINDOW --------------------------------------------------------------------
# Window style ($10). Each style has its own default spot on screen:
#   mini   (1)  icon + overlay, message, bar, status, %            bottom right   (default)
#   toast  (2)  small: icon, message, status, thin bar on the edge  top right
#   card   (3)  centered icon + overlay, message, bar, status, %    center of the screen
#   hud    (4)  frosted panel: icon + overlay, message, bar, %      bottom center
WINDOW_STYLE="mini"
WINDOW_POSITION=""                   # ($10) blank = the style's own spot; or bottomright, bottomleft,
                                     # bottomcenter, topright, topleft, topcenter, center
DEFAULT_ICON="/System/Applications/App Store.app"   # ($6) icon when $6 is blank
SHOW_VERSION=false                   # ($11) true = "v1.2.4 Downloading...", false = "Downloading..."
BAR_COLOR="accent"                   # accent     = the user's macOS accent color
                                     # "#0056D2"  = one color for light and dark mode
                                     # "#0056D2/#4C9AFF" = light-mode color / dark-mode color

# LOGGING -------------------------------------------------------------------
CONSOLE_LOG="summary"                # summary = each step, Installomator's key lines and a result per label
                                     # full    = also every line Installomator prints
                                     # (everything is always in /var/log/Installomator.log)
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
emulate -L zsh
setopt no_nomatch null_glob extended_glob
autoload -Uz is-at-least

SCRIPT_VERSION="1.0"
INSTALLOMATOR="$INSTALLOMATOR_DIR/Installomator.sh"
SOURCE_FILE="$INSTALLOMATOR_DIR/.source"   # remembers which version is installed: "release 10.10" or "main"

# --- Parameters (Jamf numbering) ---------------------------------------------
labels=(${=4})
message="$5"
icon="${6:-$DEFAULT_ICON}"
overlayicon="$7"
extraOptions="$8"
[[ -n "$9" ]] && INSTALLOMATOR_VERSION="$9"
# $10: a window style and/or a position, in any order — "toast", "card", "mini topleft", "bottomcenter"
for w in ${=${10:l}}; do
  case "$w" in
    (1|mini) WINDOW_STYLE=mini ;; (2|toast) WINDOW_STYLE=toast ;; (3|card) WINDOW_STYLE=card ;; (4|5|hud) WINDOW_STYLE=hud ;;
    ((top|bottom)(left|right|center)|center) WINDOW_POSITION="$w" ;;
    (*) badWindowWord+=" $w" ;;
  esac
done
case "${WINDOW_STYLE:l}" in (1|mini) WINDOW_STYLE=mini ;; (2|toast) WINDOW_STYLE=toast ;; (3|card) WINDOW_STYLE=card ;; (4|5|hud) WINDOW_STYLE=hud ;; (*) badWindowWord+=" $WINDOW_STYLE"; WINDOW_STYLE=mini ;; esac
case "${11:l}" in (show|true|yes|1) SHOW_VERSION=true ;; (hide|false|no|0) SHOW_VERSION=false ;; esac

# BAR_COLOR -> "accent", "RRGGBB" or "RRGGBB/RRGGBB" for the window (#RGB is expanded; bad values = accent)
hex6() { local h="${1#\#}"; [[ "$h" == [[:xdigit:]](#c3) ]] && h="${h[1]}${h[1]}${h[2]}${h[2]}${h[3]}${h[3]}"
         [[ "$h" == [[:xdigit:]](#c6) ]] && print -r -- "${h:u}"; }
barColorArg="accent"
if [[ -n "$BAR_COLOR" && "${BAR_COLOR:l}" != accent ]]; then
  bcLight=$(hex6 "${BAR_COLOR%%/*}"); bcDark=$(hex6 "${BAR_COLOR#*/}")
  if [[ -n "$bcLight" && -n "$bcDark" ]]; then barColorArg="$bcLight/$bcDark"
  else barColorWarning="Bar colour '$BAR_COLOR' isn't a valid hex colour — using the accent colour."; fi
fi
INSTALLOMATOR_VERSION="${${INSTALLOMATOR_VERSION:l}#v}"
[[ "$INSTALLOMATOR_VERSION" == latest ]] && INSTALLOMATOR_VERSION=release

log() { print -r -- "$(date '+%H:%M:%S')  $*"; }
START_TIME=$(date +%s)

# --- Sanity checks ------------------------------------------------------------
if [[ $(sw_vers -buildVersion) < "20A" ]]; then log "This script requires at least macOS 11 Big Sur."; exit 98; fi
if [[ $(id -u) -ne 0 ]]; then log "This script should be run as root"; exit 97; fi
if (( ${#labels} == 0 )); then log "No Installomator label given in parameter 4."; exit 96; fi
if [[ "$INSTALLOMATOR_VERSION" != (release|main|[0-9]##(.[0-9]##)#) ]]; then
  log "Installomator version '$INSTALLOMATOR_VERSION' isn't valid — use release, main, or a version like 10.8."; exit 95
fi

# --- Scratch space (readable by the user's window, writable only by root) ----
SCRATCH=$(mktemp -d /var/tmp/installomator-progress.XXXXXX)
chmod 755 "$SCRATCH"
CMD_FILE="$SCRATCH/progress.log"; : > "$CMD_FILE"; chmod 644 "$CMD_FILE"
UI_SCRIPT="$SCRATCH/progress.js"

cleanup() {
  [[ -n "$UI_STARTED" ]] && { print "quit:" >> "$CMD_FILE"; sleep 0.5; pkill -f "$UI_SCRIPT" 2>/dev/null; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

dialogUpdate() { print -r -- "$1" >> "$CMD_FILE"; }

# --- Logged-in user -----------------------------------------------------------
consoleUser=$(stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == (root|loginwindow|_mbsetupuser) ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(id -u "$consoleUser" 2>/dev/null)
userHome=""
[[ -n "$consoleUser" ]] && userHome=$(dscl . -read "/Users/$consoleUser" NFSHomeDirectory 2>/dev/null | awk '{print $2}')

# --- Icons: make each one a local file (or .app / sf:symbol) the user can read --
# resolve_icon <source> <name>  -> prints a path/app/sf: value, or nothing
# self_service_icon -> the org's Self Service branding image cached for the logged-in user, else the
# Self Service app icon (the path Jamf has on record, then the standard Self Service / Self Service+ apps)
self_service_icon() {
  local p
  for p in "$userHome/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingimage.png" \
           "$userHome/Library/Application Support/com.jamf.selfserviceplus/Documents/Images/brandingimage.png"; do
    [[ -n "$userHome" && -s "$p" ]] && { print -r -- "$p"; return 0; }
  done
  p=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)
  for p in "$p" "/Applications/Self Service.app" "/Applications/Self Service+.app"; do
    [[ -n "$p" && -d "$p" ]] && { print -r -- "$p"; return 0; }
  done
}

FALLBACK_ICON="/System/Applications/App Store.app"   # used when the icon you set can't be loaded
GENERIC_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"   # only if App Store.app is missing

# resolve_icon <source> <name> <label> <fallback text> — prints a usable path/app/sf: value, or nothing.
# When the source can't be used it logs one line saying why and what happens instead.
resolve_icon() {
  local src="$1" out="$SCRATCH/$2" what="$3" instead="$4" why=""
  [[ -z "$src" || "${src:l}" == none ]] && return 0
  if [[ "${src:l}" == (selfservice|self service|ss) ]]; then
    src=$(self_service_icon)
    [[ -z "$src" ]] && { log "$what  no Self Service branding image or app found — $instead" >&2; return 0; }
  fi
  if [[ "$src" == sf:* ]]; then print -r -- "$src"; return 0; fi   # checked by the window (falls back there)
  if [[ "$src" == http(s|)://* ]]; then
    curl -fsSL --max-time 15 -o "$out" "$src" 2>/dev/null || why="download failed"
  elif [[ -d "$src" ]]; then print -r -- "$src"; return 0      # .app / folder → its Finder icon
  elif [[ -f "$src" ]]; then cp "$src" "$out" 2>/dev/null
  else why="not found"; fi
  if [[ -z "$why" ]] && [[ -s "$out" ]] && sips -g pixelWidth "$out" 2>/dev/null | grep -qE 'pixelWidth: [0-9]+'; then
    chmod 644 "$out"; print -r -- "$out"; return 0
  fi
  rm -f "$out"
  log "$what  ${why:-not a readable image}: $src — $instead" >&2
}

installOpts=( ${(Q)${(z)DEFAULT_OPTIONS}} ${(Q)${(z)extraOptions}} )
print -r -- "==================== Installomator Progress $SCRIPT_VERSION ===================="
log "Labels:         ${labels[*]}"
log "User:           ${consoleUser:-nobody logged in — no window}"
log "Installomator:  $INSTALLOMATOR_VERSION"
log "Options:        ${installOpts[*]:-none}"
log "Window style:   $WINDOW_STYLE${WINDOW_POSITION:+ ($WINDOW_POSITION)}"
[[ -n "$badWindowWord" ]] && log "Window:         didn't recognise '${badWindowWord# }' — use mini, toast, card, hud and/or a position like topright."
[[ -n "$barColorWarning" ]] && log "$barColorWarning"

if [[ -z "$overlayicon" ]]; then
  overlayicon="selfservice"
  [[ -f "/Library/Application Support/Dialog/Dialog.png" ]] && overlayicon="/Library/Application Support/Dialog/Dialog.png"
fi
overlayGiven="$7"
iconFile=$(resolve_icon "$icon" icon "Icon:         " "using the App Store icon instead.")
if [[ -z "$iconFile" ]]; then [[ -d "$FALLBACK_ICON" ]] && iconFile="$FALLBACK_ICON" || iconFile="$GENERIC_ICON"; fi
# A blank overlay falls back to Self Service quietly — only a broken overlay you set is worth a log line.
if [[ -n "$overlayGiven" ]]; then overlayFile=$(resolve_icon "$overlayicon" overlay "Overlay icon: " "showing no overlay.")
else overlayFile=$(resolve_icon "$overlayicon" overlay "Overlay icon: " "showing no overlay." 2>/dev/null); fi

# --- The progress window (JXA + AppKit) ---------------------------------------
# Reads $CMD_FILE every 0.25s and understands the swiftDialog commands Installomator writes:
#   progress: <0-100|increment|reset|complete|indeterminate>   progresstext: <text>
#   message: <text>   icon: <path>   overlayicon: <path>   quit:
write_ui() {
  cat > "$UI_SCRIPT" <<'JXA'
ObjC.import('Cocoa');
function isOk(o){ return !!o && !(typeof o.isNil==='function' && o.isNil()); }
function loadImg(p){
 if(!p) return null; var i=null, isDir=Ref();
 if(p.indexOf('sf:')==0) i=$.NSImage.imageWithSystemSymbolNameAccessibilityDescription(p.slice(3),'');
 else if($.NSFileManager.defaultManager.fileExistsAtPathIsDirectory(p,isDir) && isDir[0]) i=$.NSWorkspace.sharedWorkspace.iconForFile(p);
 else i=$.NSImage.alloc.initWithContentsOfFile(p);
 return isOk(i)?i:null; }
function run(argv){
 var CMD=argv[0], MSG=argv[1], ICON=argv[2], OVL=argv[3], POS=(argv[4]||'').toLowerCase(), SHOWVER=(argv[5]=='true'), BARCOL=(argv[6]||'accent'), STYLE=(argv[7]||'mini');
 var app=$.NSApplication.sharedApplication; app.setActivationPolicy(1);   // no Dock icon
 // ---- Window style (WINDOW_STYLE / $10) -----------------------------------------------------------
 //   mini   540×128  icon + overlay on the left; message, bar, status, % on the right (default: bottom right)
 //   toast  380×72   small icon; message + status; thin bar along the bottom edge    (default: top right)
 //   card   340×250  big centred icon + overlay, centred message, bar, status and %   (default: centre)
 //   hud    380×96   frosted translucent panel; small icon + overlay, message, bar, %  (default: bottom centre)
 var L={ mini:{W:540,H:128, icon:[20,20,80], ovl:0.45, msg:[118,62,402,44,14,'medium',2,0], bar:[118,40,402,8,false], st:[118,14,342,16,11], pct:[460,14,60,16], pos:'bottomright'},
         toast:{W:380,H:72, icon:[14,16,40], ovl:0.45, msg:[64,38,300,18,13,'semibold',1,0], bar:[0,0,380,4,true],   st:[64,19,300,16,11], pos:'topright'},
         card:{W:340,H:250, icon:[134,148,72], ovl:0.42, msg:[20,104,300,40,16,'semibold',2,1], bar:[28,72,284,10,false], st:[28,44,220,16,12], pct:[252,44,60,16], pos:'center'},
         hud:{W:380,H:96, icon:[18,26,44], ovl:0.45, msg:[76,56,282,20,14,'semibold',1,0], bar:[76,38,282,6,false], st:[76,12,218,16,11], pct:[298,12,60,16], pos:'bottomcenter', hud:true} };
 var S=L[STYLE]||L.mini;
 if(S===L.card){   // the card fits its height to the message (1 or 2 lines), stacked with even spacing
  var mt=$.NSTextField.labelWithString(MSG); mt.font=$.NSFont.systemFontOfSizeWeight(16,$.NSFontWeightSemibold);
  mt.maximumNumberOfLines=2; mt.lineBreakMode=0;
  var mh=Math.min(44, Math.ceil(mt.cell.cellSizeForBounds($.NSMakeRect(0,0,300,200)).height));
  //  bottom 18 · status 16 · 8 · bar 10 · 14 · message mh · 16 · icon 72 · top 22
  S.st=[28,18,220,16,12]; S.pct=[252,18,60,16]; S.bar=[28,42,284,10,false];
  S.msg=[20,66,300,mh,16,'semibold',2,1]; S.icon=[134,82+mh,72]; S.H=176+mh; }
 var W=S.W, H=S.H, M=20; if(!POS) POS=S.pos;
 var win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
 win.titlebarAppearsTransparent=true; win.titleVisibility=1;              // no title, like --title none
 [0,1,2].forEach(function(b){ var x=win.standardWindowButton(b); if(isOk(x)) x.hidden=true; });
 win.movableByWindowBackground=true;                                      // --moveable
 win.level=$.NSFloatingWindowLevel; win.collectionBehavior=(1<<0)|(1<<8); // all Spaces + over full-screen apps
 win.releasedWhenClosed=false;
 var cv=win.contentView;
 if(S.hud){   // frosted, translucent panel with rounded corners
  win.opaque=false; win.backgroundColor=$.NSColor.clearColor; win.hasShadow=true;
  var fx=$.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0,0,W,H)); fx.material=13; fx.blendingMode=0; fx.state=1;
  fx.wantsLayer=true; fx.layer.cornerRadius=16; fx.layer.masksToBounds=true; cv.addSubview(fx); cv=fx; }

 // Icon with the overlay logo on its bottom-right corner (swiftDialog --icon / --overlayicon)
 var IX=S.icon[0], IY=S.icon[1], IS=S.icon[2];
 var iv=$.NSImageView.alloc.initWithFrame($.NSMakeRect(IX,IY,IS,IS)); iv.imageScaling=3; cv.addSubview(iv);
 // Icon that can't be loaded (e.g. an sf: symbol that doesn't exist) → the App Store icon (generic app icon if that's missing)
 var img=loadImg(ICON)||loadImg('/System/Applications/App Store.app')||loadImg('/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns');
 if(img) iv.image=img;
 var OS=IS*S.ovl, ov=$.NSImageView.alloc.initWithFrame($.NSMakeRect(IX+IS-OS*0.75,IY-OS*0.2,OS,OS)); ov.imageScaling=3; cv.addSubview(ov);
 var oimg=loadImg(OVL); if(oimg) ov.image=oimg;

 // Message, progress bar, progress text
 function lbl(r,size,weight,color,lines,align){ var t=$.NSTextField.labelWithString('');
  t.frame=$.NSMakeRect(r[0],r[1],r[2],r[3]); t.font=$.NSFont.systemFontOfSizeWeight(size,weight); t.textColor=color;
  t.alignment=align||0; t.maximumNumberOfLines=lines; t.lineBreakMode=lines>1?0:4; t.cell.truncatesLastVisibleLine=true; cv.addSubview(t); return t; }
 var m=S.msg, msg=lbl(m, m[4], m[5]=='semibold'?$.NSFontWeightSemibold:$.NSFontWeightMedium, $.NSColor.labelColor, m[6], m[7]); msg.stringValue=MSG;
 // Progress bar drawn in the user's accent colour (a stock NSProgressIndicator turns grey in a window
 // that isn't focused, and we don't steal focus from the user while installing).
 // Style "dimmed + sweep": the fill only ever shows real progress; while Installomator is busy without
 // a percentage the fill dims and a bright segment sweeps over it. Nothing changes shape between steps —
 // the dimming and the sweep just fade in and out — so every step change is smooth.
 var TX=S.bar[0], BY=S.bar[1], TW=S.bar[2], BH=S.bar[3], BR=S.bar[4]?0:BH/2;   // BR: square ends for the toast's edge bar
 function box(parent,x,y,w,color){ var b=$.NSBox.alloc.initWithFrame($.NSMakeRect(x,y,w,BH)); b.boxType=4; b.borderWidth=0;
  b.titlePosition=0; b.cornerRadius=BR; b.fillColor=color; parent.addSubview(b); return b; }
 box(cv,TX,BY,TW,$.NSColor.quaternaryLabelColor);                                   // track
 var clip=$.NSView.alloc.initWithFrame($.NSMakeRect(TX,BY,TW,BH)); clip.wantsLayer=true;   // keeps the
 clip.layer.cornerRadius=BR; clip.layer.masksToBounds=true; cv.addSubview(clip);         // sweep inside
 // Bar colour: the accent colour (macOS adapts it to light/dark itself), or BAR_COLOR — "RRGGBB" for both
 // modes or "RRGGBB/RRGGBB" for light/dark. The track, text and background are system colours, so the
 // window follows light/dark mode, and the bar colour is re-picked if the user switches mid-install.
 function hexColor(h){ return $.NSColor.colorWithSRGBRedGreenBlueAlpha(parseInt(h.substr(0,2),16)/255,parseInt(h.substr(2,2),16)/255,parseInt(h.substr(4,2),16)/255,1); }
 function isDark(){ var n=win.effectiveAppearance.bestMatchFromAppearancesWithNames($(['NSAppearanceNameAqua','NSAppearanceNameDarkAqua']));
  return ObjC.unwrap(n)=='NSAppearanceNameDarkAqua'; }
 var barMode=null;
 function barColor(){ if(BARCOL=='accent') return $.NSColor.controlAccentColor; var c=BARCOL.split('/'); return hexColor(isDark()?c[1]:c[0]); }
 var fill=box(clip,0,0,BH,barColor()), seg=box(clip,0,0,BH,barColor());
 function refreshBarColor(){ var m=isDark(); if(m!==barMode){ barMode=m; var c=barColor(); fill.fillColor=c; seg.fillColor=c; } }
 var pt=lbl(S.st, S.st[4], $.NSFontWeightRegular, $.NSColor.secondaryLabelColor, 1); pt.stringValue='Starting…';
 var pctL = S.pct ? lbl(S.pct, S.st[4], $.NSFontWeightSemibold, $.NSColor.secondaryLabelColor, 1, 2) : null, pctShown='';   // mini, card, hud: "42%" (same size as the status text)

 // Animation is time-based (60fps timer, every step uses the real time since the last frame):
 //   percentage   the fill moves to each new value on a critically-damped spring (starts gently, settles
 //                without overshoot) with a speed cap, so even a big jump takes ~0.8s and never snaps
 //   busy         busyAmt eases 0 → 1 (~0.4s): the fill dims to 38% and the sweep fades in; and back
 //   sweep        a segment crosses with a sine ease-in-out, pausing out of sight at each end
 //   tiny widths  fade in/out instead of popping (a pill can't be narrower than it is tall)
 //   idle         the 60fps timer pauses while nothing moves (CPU near zero), poll() wakes it
 var value=0, shown=0, vel=0, indeterminate=true, busyAmt=1, dimAmt=1, blendAt=-1;
 var now0=Date.now()/1000, last=now0, t0=now0, SWEEP=1.8, SEG=0.30, SPRING=7, VMAX=150, applied='';
 function ease(x){ return (1-Math.cos(Math.PI*x))/2; }                       // sine ease-in-out
 // put(view, left, right, alpha, fromLeft) -> a key describing what was drawn (so unchanged frames can be skipped).
 // A pill can't be narrower than it is tall. The fill (fromLeft) instead slides out from behind the track's
 // rounded left end at full colour — the rounded clip shows just the sliver. The sweep fades in/out instead.
 function put(v,L,R,alpha,fromLeft){
  var w=R-L; if(w<0.5 || alpha<0.005){ v.hidden=true; return 'h'; }
  var dw=Math.max(BH,w), dl=fromLeft ? w-dw : L-(dw-w)/2;
  var a=Math.max(0,Math.min(1, fromLeft ? alpha : alpha*Math.min(1,w/BH)));
  v.hidden=false; v.alphaValue=a; v.frame=$.NSMakeRect(dl,0,dw,BH);
  return dl.toFixed(1)+','+dw.toFixed(1)+','+a.toFixed(3); }
 function draw(){
  var now=Date.now()/1000, dt=Math.min(0.05, now-last); last=now;
  if(!indeterminate){   // critically damped spring toward value (% per second, capped)
   vel += (SPRING*SPRING*(value-shown) - 2*SPRING*vel)*dt; vel=Math.max(-VMAX,Math.min(VMAX,vel));
   shown += vel*dt; if(Math.abs(value-shown)<0.05 && Math.abs(vel)<1){ shown=value; vel=0; } }
  var goal=indeterminate?1:0, k=1-Math.exp(-dt*8);
  busyAmt += (goal-busyAmt)*k; if(Math.abs(goal-busyAmt)<0.002) busyAmt=goal;   // sweep fade
  dimAmt  += (goal-dimAmt)*k;  if(Math.abs(goal-dimAmt)<0.002)  dimAmt=goal;    // fill dimming fade
  var p=((now-t0)%SWEEP)/SWEEP, sw=TW*SEG, sx=-sw+ease(p)*(TW+sw);
  var key=put(fill,0,TW*shown/100,1-0.62*dimAmt,true)+'|'+put(seg,Math.max(0,sx),Math.min(TW,sx+sw),busyAmt);
  // % only while there's real progress to report (1–99): not on Done / up to date (100), busy steps or a failure (0)
  if(pctL){ var pc = (!indeterminate && value>0 && value<100) ? Math.min(99,Math.round(shown))+'%' : ''; if(pc!==pctShown){ pctShown=pc; pctL.stringValue=pc; } key+='|'+pc; }
  if(key===applied){   // nothing moved: if nothing will, pause the 60fps timer until poll() wakes it
   if(!indeterminate && busyAmt===0 && dimAmt===0 && shown===value && animTimer && !sleeping){ sleeping=true; animTimer.fireDate=$.NSDate.distantFuture; }
   return; }
  applied=key; }
 function startBusy(){ if(!indeterminate){ t0=Date.now()/1000; indeterminate=true; } }   // sweep enters from the left
 function setProgress(v){
  v=String(v).trim().toLowerCase();
  if(v=='indeterminate'){ startBusy(); return; }
  var n = v=='complete'?100 : v=='reset'?0 : v=='increment'?value+1 : parseFloat(v);
  if(isNaN(n)) return;
  // The fill keeps its real progress; the sweep fades out. Only a fill that was already showing while busy
  // (e.g. the full bar after a download) fades back from dimmed — new fill (a download starting from empty)
  // is full colour straight away, so it never flickers dim.
  if(indeterminate && shown<1) dimAmt=0;
  indeterminate=false; vel = (n<value-50) ? 0 : vel;
  value=Math.max(0,Math.min(100,n)); }
 // Busy without a percentage (Verifying/Installing/Updating/Finishing after the download hit 100%):
 // switch to the moving bar so it doesn't look finished. Installomator writes "progress: N" just before
 // the text when it HAS a percentage (pkg installs), so a busy text right after a number keeps the bar.
 var BUSY=/(Verifying|Installing|Updating|Finishing|Mounting|Reporting)/i, UPTODATE=/(Latest version already installed|Already installed from App Store)/i;
 var lastNum=false;
 function onText(v){
  if(!SHOWVER) v=v.replace(/^v\d[^\s]*\s+/,'');   // "v1.2.4 Downloading..." -> "Downloading..."
  pt.stringValue=v;
  if(UPTODATE.test(v)){ indeterminate=false; value=100; }
  else if(BUSY.test(v) && !lastNum) startBusy(); }
 var seen=0, lastLine=Date.now();
 function poll(){
  var s=$.NSString.stringWithContentsOfFileEncodingError(CMD,$.NSUTF8StringEncoding,null); if(!isOk(s)) return;
  var lines=ObjC.unwrap(s).split('\n'), full=lines.length-1;   // the last piece may still be being written
  if(full<seen) seen=0;
  if(seen<full) lastLine=Date.now();
  // Download finished but Installomator is quiet (mounting the DMG, checking it): after 1s, show the
  // moving bar instead of a full one that looks done.
  else if(!indeterminate && value>=100 && /Downloading/i.test(ObjC.unwrap(pt.stringValue)) && Date.now()-lastLine>1000) startBusy();
  for(; seen<full; seen++){
   var m=lines[seen].match(/^\s*([A-Za-z]+):\s?(.*)$/); if(!m) continue;
   var k=m[1].toLowerCase(), v=m[2];
   if(k=='progress'){ setProgress(v); lastNum=/^\s*\d+(\.\d+)?\s*$/.test(v); continue; }
   if(k=='progresstext') onText(v);
   else if(k=='message') msg.stringValue=v.replace(/\\n/g,'\n');
   else if(k=='icon'){ var a=loadImg(v.trim()); if(a) iv.image=a; }
   else if(k=='overlayicon'){ var b=loadImg(v.trim()); if(b) ov.image=b; }
   else if(k=='quit'){ app.terminate(null); }
   lastNum=false;
  }
  if(indeterminate || shown!==value || busyAmt!==(indeterminate?1:0) || dimAmt!==(indeterminate?1:0)) wake(); }
 var animTimer=null, sleeping=false;
 function wake(){ if(sleeping && animTimer){ sleeping=false; last=Date.now()/1000; animTimer.fireDate=$.NSDate.date; } }
 if(!$.IPTick){ ObjC.registerSubclass({name:'IPTick',superclass:'NSObject',methods:{
  'tick:':{types:['void',['id']],implementation:function(t){ refreshBarColor(); poll(); }},
  'anim:':{types:['void',['id']],implementation:function(t){ draw(); }}}}); }
 var tk=$.IPTick.alloc.init;
 [[0.25,'tick:'],[1/60,'anim:']].forEach(function(a){   // common modes: keeps updating while dragged
  var tm=$.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(a[0],tk,a[1],null,true);
  $.NSRunLoop.currentRunLoop.addTimerForMode(tm,$.NSRunLoopCommonModes); if(a[1]=='anim:') animTimer=tm; });

 // Position (--position)
 var vf=$.NSScreen.mainScreen.visibleFrame, x0=vf.origin.x, y0=vf.origin.y, vw=vf.size.width, vh=vf.size.height;
 var x = POS.indexOf('left')>=0 ? x0+M : POS.indexOf('right')>=0 ? x0+vw-W-M : x0+(vw-W)/2;
 var y = POS.indexOf('top')>=0 ? y0+vh-H-M : POS.indexOf('bottom')>=0 ? y0+M : y0+(vh-H)/2;
 win.setFrameOrigin($.NSMakePoint(x,y));
 poll(); win.orderFrontRegardless;
 app.run();
}
JXA
  chmod 644 "$UI_SCRIPT"
}

start_ui() {
  [[ -z "$consoleUID" ]] && return 0
  write_ui
  launchctl asuser "$consoleUID" sudo -u "$consoleUser" \
    osascript -l JavaScript "$UI_SCRIPT" "$CMD_FILE" "$1" "$iconFile" "$overlayFile" "$WINDOW_POSITION" "$SHOW_VERSION" "$barColorArg" "$WINDOW_STYLE" >/dev/null 2>&1 &
  UI_STARTED=1
  log "Window:         opened for $consoleUser"
}


# --- Local Installomator (App Auto-Patch style) -------------------------------
local_version() { [[ -f "$INSTALLOMATOR" ]] && awk -F'"' '/^VERSION="/{print $2; exit}' "$INSTALLOMATOR"; }
local_source() {   # "main", "release 10.10", or "" — copies from 1.0 (no .source file) were releases
  if [[ -s "$SOURCE_FILE" ]]; then cat "$SOURCE_FILE"; elif [[ -f "$INSTALLOMATOR" ]]; then print -r -- "release $(local_version)"; fi
}

# put_installomator <file> <source> — moves a checked Installomator.sh into place (root-owned)
put_installomator() {
  mkdir -p "$INSTALLOMATOR_DIR"
  cp "$1" "$INSTALLOMATOR.new" && mv -f "$INSTALLOMATOR.new" "$INSTALLOMATOR" || return 1
  print -r -- "$2" > "$SOURCE_FILE"
  chown -R root:wheel "$INSTALLOMATOR_DIR"; chmod 755 "$INSTALLOMATOR_DIR" "$INSTALLOMATOR"; chmod 644 "$SOURCE_FILE"
}

latest_version() {
  local url
  url=$(curl -fsIL -o /dev/null -w '%{url_effective}' --max-time 20 \
        "https://github.com/Installomator/Installomator/releases/latest" 2>/dev/null)
  url="${url##*/}"; url="${url#v}"
  [[ "$url" == [0-9]##(.[0-9]##)# ]] && print -r -- "$url"
}

install_release() {   # $1 = version — signed pkg, notarisation + Team ID checked
  local v="$1" pkg="$SCRATCH/Installomator.pkg" exp="$SCRATCH/expanded" spctlOut team found
  dialogUpdate "progresstext: Downloading Installomator $v…"
  rm -rf "$pkg" "$exp"
  if ! curl -fsSL --max-time 120 -o "$pkg" \
       "https://github.com/Installomator/Installomator/releases/download/v$v/Installomator-$v.pkg"; then
    log "Installomator $v download failed."; return 1
  fi
  spctlOut=$(spctl -a -vv -t install "$pkg" 2>&1)
  team=$(print -r -- "$spctlOut" | awk -F'[()]' '/origin=/{print $2}')
  if [[ "$spctlOut" != *": accepted"* || "$team" != "$INSTALLOMATOR_TEAM_ID" ]]; then
    log "Installomator pkg failed verification (Team ID '$team', expected $INSTALLOMATOR_TEAM_ID)."; return 1
  fi
  pkgutil --expand-full "$pkg" "$exp" >/dev/null 2>&1
  found=( "$exp"/**/Installomator.sh(.N) )
  [[ -n "$found[1]" ]] || { log "Installomator.sh not found in the pkg."; return 1; }
  put_installomator "$found[1]" "release $v" || return 1
  log "Installed Installomator $v (release) to $INSTALLOMATOR — Team ID $team verified."
}

install_main() {   # main branch — raw script (unsigned), checked that it's a complete Installomator script
  local f="$SCRATCH/Installomator-main.sh" v
  dialogUpdate "progresstext: Checking Installomator (main)…"
  if ! curl -fsSL --max-time 120 -o "$f" \
       "https://raw.githubusercontent.com/Installomator/Installomator/main/Installomator.sh"; then
    log "Installomator main download failed."; return 1
  fi
  v=$(awk -F'"' '/^VERSION="/{print $2; exit}' "$f")
  if [[ "$(head -n 1 "$f")" != "#!/bin/zsh"* || -z "$v" ]] \
     || ! tail -n 5 "$f" | grep -q '^cleanupAndExit 0'; then
    log "Downloaded Installomator main doesn't look like a complete Installomator script — not using it."; return 1
  fi
  if [[ "$(local_source)" == main ]] && cmp -s "$f" "$INSTALLOMATOR"; then
    log "Installomator $v (main) is current."; return 0
  fi
  put_installomator "$f" "main" || return 1
  log "Installed Installomator $v (main branch) to $INSTALLOMATOR."
}

prepare_installomator() {
  local want="$INSTALLOMATOR_VERSION" current source latest
  current=$(local_version); source=$(local_source)

  # use_local — GitHub couldn't be reached (or the download failed its checks): keep using the local
  # copy if there is one, whatever version it is, so installs still work offline.
  use_local() {
    if [[ -n "$current" ]]; then log "Couldn't get Installomator ($want) from GitHub — using the local copy ($source)."; return 0; fi
    log "Couldn't get Installomator from GitHub and there is no local copy."; return 1
  }

  case "$want" in
    main)
      if [[ "$source" != main || "$CHECK_FOR_UPDATES" == true ]]; then
        install_main || use_local || return 1
      else
        log "Installomator $current (main) — not checking for updates."
      fi ;;
    release)
      if [[ "$source" != release* || "$CHECK_FOR_UPDATES" == true ]]; then
        dialogUpdate "progresstext: Checking for the latest Installomator…"
        latest=$(latest_version)
        if [[ -z "$latest" ]]; then use_local || return 1
        elif [[ "$source" != release* ]] || ! is-at-least "$latest" "$current"; then
          log "Installomator: local ${source:-none}, latest release $latest — updating."
          install_release "$latest" || use_local || return 1
        else
          log "Installomator $current (release) is current."
        fi
      else
        log "Installomator $current (release) — not checking for updates."
      fi ;;
    *)   # pinned version
      if [[ "$source" == "release $want" ]]; then
        log "Installomator $want (pinned) is in place."
      else
        install_release "$want" || use_local || return 1
      fi ;;
  esac

  # Run a copy whose swiftDialog check points at /usr/bin/true, so it writes progress to our window.
  RUN_COPY="$SCRATCH/Installomator.sh"
  sed 's|^DIALOG_CMD="/usr/local/bin/dialog"$|DIALOG_CMD="/usr/bin/true"|' "$INSTALLOMATOR" > "$RUN_COPY"
  chmod 700 "$RUN_COPY"
  grep -q '^DIALOG_CMD="/usr/bin/true"$' "$RUN_COPY" \
    || log "WARNING: couldn't enable progress output in this Installomator version — the window will show status only."
}

# --- Console output for one Installomator run ---------------------------------
# Installomator prints a lot (and always writes all of it to /var/log/Installomator.log). With
# CONSOLE_LOG=summary only its key lines are shown, and the result is worked out from what it printed.
# Lines look like: "2026-11-13 20:42:35 : REQ   : mace : Installed MACE, version 1.2.4"
typeset -A R   # result details for the current label
show_installomator_line() {
  local l="$1" lvl msg t
  if [[ "$l" != [0-9](#c4)-[0-9](#c2)-[0-9](#c2)" "[0-9:](#c8)" : "* ]]; then   # not a log line (hdiutil etc.)
    [[ "$CONSOLE_LOG" == full ]] && print -r -- "            $l"
    return
  fi
  t="${l[12,19]}"; l="${l#* : }"; lvl="${l%% *}"; msg="${l#* : * : }"
  # remember what happened, for the result line
  case "$msg" in
    "found app at "*", version "*)      [[ -z "${R[was]}${R[dl]}" ]] && R[was]="${${msg#*, version }%%, on versionKey*}" ;;   # first one = before installing
    "Latest version of "*" is "*)       R[latest]="${msg##* is }" ;;
    "Downloading "*)                    R[dl]=1 ;;   # "found app" lines after this are the result, not what was there before
    "Installed "*", version "*)         R[installed]="${msg##*, version }" ;;
    "Installed "*)                      [[ "$lvl" == REQ ]] && R[installed]="${R[latest]:-yes}" ;;
    ("No new version to install"|"No newer version."|*"same as installed."*)  R[uptodate]=1 ;;
    "DEBUG mode "*" enabled"*)          R[debug]=1 ;;
  esac
  [[ "$lvl" == ERROR ]] && R[error]="${msg#ERROR: }"
  if [[ "$CONSOLE_LOG" == full ]]; then print -r -- "$t    ${lvl}  $msg"; return; fi
  [[ "$msg" == "#"* || "$msg" == *"Last Log repeated"* ]] && return
  case "$lvl" in
    REQ|REG)    print -r -- "$t    $msg" ;;
    WARN|ERROR) print -r -- "$t    $lvl: ${msg#$lvl: }" ;;
    *) case "$msg" in   # the few INFO lines worth seeing
         ("found app at "*|"Latest version of "*|"Team ID matching"*|"Downloaded version of "*|"App(s) found: "*|"BLOCKING_PROCESS_ACTION="*))
           print -r -- "$t    $msg" ;;
       esac ;;
  esac
}

label_result() {   # $1 = Installomator exit code -> one line describing what happened
  if (( $1 != 0 )); then print -r -- "FAILED (error $1${R[error]:+: ${R[error]}})"
  elif [[ -n "${R[debug]}" ]]; then print -r -- "Test run (DEBUG) — nothing installed (installed: ${R[was]:-none}, latest: ${R[latest]:-?})"
  elif [[ -n "${R[installed]}" && "${R[was]}" == "${R[installed]}" ]]; then print -r -- "Reinstalled ${R[installed]}"
  elif [[ -n "${R[installed]}" && -n "${R[was]}" ]]; then print -r -- "Updated ${R[was]} → ${R[installed]}"
  elif [[ -n "${R[installed]}" ]]; then print -r -- "Installed ${R[installed]}"
  elif [[ -n "${R[uptodate]}" ]]; then print -r -- "Already up to date (${R[was]:-${R[latest]:-?}})"
  else print -r -- "Done"; fi
}

# --- Main ---------------------------------------------------------------------
firstMessage="${message:-Installing ${labels[1]}…}"
start_ui "$firstMessage"

if ! prepare_installomator; then
  dialogUpdate "progress: reset"   # stop the moving bar — nothing is happening any more
  dialogUpdate "progresstext: Couldn't download Installomator."
  print -r -- "-------------------------------- Summary --------------------------------"
  log "FAILED — couldn't get Installomator. Exit 1"
  sleep 3; exit 1
fi

exitCode=0; allUpToDate=1; results=()
for label in $labels; do
  [[ -z "$message" && ${#labels} -gt 1 ]] && dialogUpdate "message: Installing $label…"
  dialogUpdate "progress: indeterminate"
  dialogUpdate "progresstext: Starting…"
  print -r -- "-------------------------------- $label --------------------------------"
  R=()
  "$RUN_COPY" "$label" DIALOG_CMD_FILE="$CMD_FILE" DEBUG=0 $installOpts 2>&1 \
    | while IFS= read -r line; do show_installomator_line "$line"; done
  rc=${pipestatus[1]}
  result=$(label_result $rc)
  log "Result:  $result"
  results+=("$label|$result")
  [[ "$result" == "Already up to date"* ]] || allUpToDate=0
  if (( rc != 0 )); then
    exitCode=$rc
    dialogUpdate "progress: reset"   # stop the moving bar
    dialogUpdate "progresstext: $label failed (error $rc)"
    sleep 3
  fi
done

if (( exitCode == 0 )); then
  dialogUpdate "progress: complete"
  if (( allUpToDate )); then dialogUpdate "progresstext: Already up to date"
  else dialogUpdate "progresstext: Done"; fi
fi

print -r -- "-------------------------------- Summary --------------------------------"
for r in $results; do printf '%-22s %s\n' "${r%%|*}" "${r#*|}"; done
log "Finished in $(( $(date +%s) - START_TIME ))s — exit $exitCode. Full Installomator log: /var/log/Installomator.log"
sleep 1.5   # let the bar visibly reach full on "Done" before the window closes
exit $exitCode
