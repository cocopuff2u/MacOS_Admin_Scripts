#!/bin/zsh

####################################################################################################
#
# Delete Expired Certificates
#
# Purpose: Scans the logged-in user's login keychain AND the System keychain for certificates that
#          have already expired, skips any matching an exclude list (default "Apple"), backs up
#          each expired certificate's PEM, then removes it with `security delete-certificate`.
#          VERBOSE mode shows the user a branded checklist of what will be removed and lets them
#          confirm; SILENT mode runs unattended (log only). A dry-run flag previews without
#          changing anything.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
#
# ---------------------------------------------------------------------------------------------
# HOW TO DEPLOY — two common patterns:
#
#   A) Self Service (the user clicks it, sees a checklist, and confirms what to remove):
#        • Leave the script as-is (HEADLESS=false in the Config block below).
#        • Set Jamf Parameter 4 to "verbose"  (or leave it blank — verbose is the default).
#
#   B) Headless / automated (runs silently at check-in, the user is never prompted):
#        • Set Jamf Parameter 4 to "silent"   (OR set HEADLESS=true in the Config block below).
#
#   TIP: Test first with Parameter 6 = "dry" — it lists what WOULD be removed and deletes nothing.
#
# JAMF SCRIPT PARAMETERS — on the script's "Options" tab in Jamf Pro, type these labels:
#
#   Parameter 4 Label:  Action Mode (verbose or silent)
#   Parameter 5 Label:  Exclude Patterns (comma-separated)
#   Parameter 6 Label:  Dry Run (type dry to preview)
#
#   Then, when you add this script to a policy, fill the parameters in like this:
#     $4  Action Mode      verbose = show the user a confirm window (this is the default)
#                          silent  = remove expired certs with no prompt
#     $5  Exclude Patterns names/issuers to NEVER touch, comma-separated. Blank = Apple.
#                          example:  Apple,JSS Built-In,Coursera
#     $6  Dry Run          dry = preview only, delete nothing.  Blank = actually delete.
# ---------------------------------------------------------------------------------------------
#
# https://github.com/cocopuff2u
#
####################################################################################################
#
# HISTORY
#
# 1.0 6/29/26 - Original Release - Native JXA/AppKit checklist + result window, login & System
#               keychain scan, PEM backup before delete, verbose/silent/dry-run modes. - @cocopuff2u
#
####################################################################################################

# --- Config — edit these to suit your environment --------------------------------------------

# HOW IT RUNS ---------------------------------------------------------------
HEADLESS=false          # false = behave per the Jamf "Action Mode" param ($4): verbose shows the
                        #         user a checklist, silent runs unattended.
                        # true  = ALWAYS run unattended (no prompt), no matter what $4 says.

DRY_RUN_OVERRIDE=false  # false = normal operation (will delete, unless $6 says "dry").
                        # true  = SAFETY PREVIEW: only logs what WOULD be deleted, never deletes.
                        #         Handy when hand-testing. Leave FALSE for production.

# WHAT TO KEEP --------------------------------------------------------------
EXCLUDE_PATTERNS=("Apple")   # Certificates whose subject OR issuer contains any of these words are
                             # NEVER removed (case-insensitive). Add more in quotes, space-separated,
                             # e.g.  EXCLUDE_PATTERNS=("Apple" "JSS Built-In" "Coursera")
                             # The Jamf $5 param, if set, REPLACES this list.

# WHERE THINGS GO -----------------------------------------------------------
BACKUP_PARENT="/var/log/expired-cert-backups"        # every removed cert is saved here (as a .pem)
                                                     # BEFORE deletion, in a timestamped subfolder.
logFile="/var/log/delete_expired_certificates.log"   # run log.

# LOOK OF THE USER PROMPT (verbose mode only) -------------------------------
bannerColor="#0056D2"                      # banner bar colour (hex)
BANNER_TEXT_COLOR="#FFFFFF"                # banner title colour (hex)
BANNER_HEIGHT=72
DIALOG_WIDTH=780
DIALOG_HEIGHT=560
DIALOG_TITLE="Remove Expired Certificates"
DIALOG_MESSAGE="Uncheck any certificate you want to KEEP, then click Remove."
DIALOG_WARNING="Each removed certificate is backed up before deletion."
DIALOG_REMOVE_LABEL="Remove Selected"
DIALOG_CANCEL_LABEL="Cancel"
okButton="OK"
# ---------------------------------------------------------------------------------------------
# Do not edit below this line.
####################################################################################################

emulate -L zsh
setopt no_nomatch null_glob

# Per-run scratch dir for extracted PEMs / generated .jxa; always cleaned up.
SCRATCH="/tmp/delete-expired-certs.$$"
/bin/mkdir -p "$SCRATCH"
trap '/bin/rm -rf "$SCRATCH"' EXIT INT TERM

# --- Argument parsing -------------------------------------------------------
# Jamf always passes the mount point as $1 ("/"), computer name $2, user $3. Strip that trio so
# our real params line up as $1=$4, $2=$5, $3=$6. Run locally without "/" and params pass through.
JAMF_USER=""
if [[ "$1" == "/" ]]; then JAMF_USER="$3"; shift 3; fi
ACTION_MODE="${1:-verbose}"; ACTION_MODE="${ACTION_MODE:l}"
[[ "$ACTION_MODE" != "silent" ]] && ACTION_MODE="verbose"
EXCLUDE_ARG="$2"
DRY_RUN_ARG="$3"

[[ -n "$EXCLUDE_ARG" ]] && EXCLUDE_PATTERNS=("${(@s/,/)EXCLUDE_ARG}")
isDry=0; [[ "${DRY_RUN_ARG:l}" == (dry|true|1|yes) ]] && isDry=1
[[ "$DRY_RUN_OVERRIDE" == true ]] && isDry=1

# HEADLESS config toggle forces unattended (silent) mode, ignoring the $4 Action Mode param.
[[ "$HEADLESS" == true ]] && ACTION_MODE="silent"

# --- Console / keychain user resolution -------------------------------------
# Resolve the logged-in (console) user so the GUI appears in their session even when this script
# runs as root from Jamf. The login keychain we touch belongs to that user.
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}

# The keychain user (console user, else the Jamf-passed user) and their home for login.keychain-db.
kcUser="${consoleUser:-$JAMF_USER}"
[[ "$kcUser" == "root" ]] && kcUser=""
USER_HOME=""
if [[ -n "$kcUser" ]]; then
  USER_HOME=$(/usr/bin/dscl . -read /Users/"$kcUser" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -z "$USER_HOME" ]] && USER_HOME="/Users/$kcUser"
fi

# Banner colour -> RGB components for AppKit
bhex="${bannerColor#\#}"
br=$((16#${bhex[1,2]})); bg=$((16#${bhex[3,4]})); bb=$((16#${bhex[5,6]}))
tchex="${BANNER_TEXT_COLOR#\#}"
tr=$((16#${tchex[1,2]})); tg=$((16#${tchex[3,4]})); tb=$((16#${tchex[5,6]}))

# --- Helpers ----------------------------------------------------------------
logMe() { print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$1] ${2}" | /usr/bin/tee -a "$logFile" 2>/dev/null || print -r -- "$2"; }
die()   { logMe ERROR "$*"; exit 1; }
as_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; print -r -- "${s//$'\n'/\\n}"; }   # escape \ " and newlines for JS

# is_excluded <subject> <issuer> -> 0 (true) if either matches any EXCLUDE_PATTERNS substring (case-insensitive)
is_excluded() {
  local subj="${1:l}" iss="${2:l}" pat
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    pat="${pat:l}"
    [[ -z "$pat" ]] && continue
    [[ "$subj" == *"$pat"* || "$iss" == *"$pat"* ]] && return 0
  done
  return 1
}

# kc_read <keychain> <login(0/1)> -> dumps "SHA-1 hash:" + PEM blocks for every cert.
# Login keychain is read as the user (correct search domain/ACLs); System keychain as root.
kc_read() {
  if (( $2 )); then run_as_user /usr/bin/security find-certificate -a -Z -p "$1" 2>/dev/null
  else /usr/bin/security find-certificate -a -Z -p "$1" 2>/dev/null; fi
}

# --- Expired-cert records (parallel global arrays) --------------------------
typeset -ga REC_SHA REC_KC REC_LOGIN REC_PEM REC_DISP

# scan_keychain_expired <keychain> <login(0/1)>
# Appends one entry per EXPIRED, non-excluded cert to the REC_* arrays.
scan_keychain_expired() {
  # Declare all locals once up front: re-declaring a bare `local` inside the loop
  # makes zsh echo the variable's value every iteration.
  local kc="$1" login="$2" line sha1="" pem="" inpem=0
  local now_epoch tmp enddate subject issuer end_epoch cn disp kclabel
  [[ -e "$kc" ]] || { logMe INFO "Keychain not found, skipping: $kc"; return 0; }
  logMe INFO "Scanning keychain: $kc"
  now_epoch=$(/bin/date +%s)

  while IFS= read -r line; do
    if [[ "$line" == "SHA-1 hash: "* ]]; then
      sha1="${line#SHA-1 hash: }"; sha1="${sha1//[[:space:]]/}"; pem=""; inpem=0; continue
    fi
    [[ "$line" == "-----BEGIN CERTIFICATE-----" ]] && { inpem=1; pem=""; }
    (( inpem )) && pem+="$line"$'\n'
    if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
      inpem=0
      [[ -z "$sha1" ]] && continue
      tmp="$SCRATCH/${sha1}.pem"; print -rn -- "$pem" > "$tmp"

      enddate=$(/usr/bin/openssl x509 -noout -enddate -in "$tmp" 2>/dev/null | /usr/bin/sed 's/^notAfter=//')
      subject=$(/usr/bin/openssl x509 -noout -subject -in "$tmp" 2>/dev/null | /usr/bin/sed 's/^subject=//')
      issuer=$(/usr/bin/openssl x509 -noout -issuer  -in "$tmp" 2>/dev/null | /usr/bin/sed 's/^issuer=//')
      # openssl prints "Jun  3 12:00:00 2024 GMT"; BSD date -j -f parses it (%e = space-padded day).
      end_epoch=$(/bin/date -j -f "%b %e %T %Y %Z" "$enddate" +%s 2>/dev/null)

      if [[ -z "$end_epoch" ]]; then
        logMe INFO "Could not parse expiry for $sha1 (notAfter='$enddate') — skipping"
        /bin/rm -f "$tmp"
      elif (( end_epoch >= now_epoch )); then
        /bin/rm -f "$tmp"   # still valid
      elif is_excluded "$subject" "$issuer"; then
        logMe INFO "Excluded (pattern match): ${sha1:0:8}… $subject"
        /bin/rm -f "$tmp"
      else
        # Build a short, single-line display string for the checklist.
        cn="$subject"
        [[ "$subject" == *CN=* ]] && cn="${subject##*CN=}" && cn="${cn%%,*}"
        (( login )) && kclabel="User" || kclabel="System"
        disp=$(printf "[%-6s] %-10s  exp %-20s  %.42s" "$kclabel" "${sha1:0:8}…" "$enddate" "$cn")
        REC_SHA+=("$sha1"); REC_KC+=("$kc"); REC_LOGIN+=("$login"); REC_PEM+=("$tmp"); REC_DISP+=("$disp")
        logMe INFO "Found expired: ${sha1:0:8}…  exp $enddate  $cn  [${kc:t}]"
      fi
    fi
  done < <(kc_read "$kc" "$login")
}

# --- VERBOSE confirm checklist (adapted from Self_Service_App_Uninstaller ui_confirm) ----------
# Args: display strings (parallel to REC_*). Prints checked 0-based indices (comma-separated) on
# stdout. Exit 0 = confirmed (>=1 checked), 1 = cancelled / nothing checked.
ui_confirm() {
  local -a list=("$@"); (( ${#list} )) || return 1
  local js="" p
  for p in "${list[@]}"; do js+="\"$(as_esc "$p")\","; done
  local note="Backups are saved to ${BACKUP_PARENT}."
  local scpt="$SCRATCH/confirm.jxa" out idx
  /bin/cat > "$scpt" <<EOF
ObjC.import('Cocoa');
var rows=[ $js ];
function label(s,x,y,w,h,sz,bold){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,h));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;
 t.alignment=1;t.textColor=\$.NSColor.labelColor;t.usesSingleLineMode=false;t.cell.wraps=true;t.cell.lineBreakMode=0;
 t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
if(!\$.DECHandler){ObjC.registerSubclass({name:'DECHandler',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});}
var h=\$.DECHandler.alloc.init;
var W=$DIALOG_WIDTH,H=$DIALOG_HEIGHT;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true;win.titleVisibility=1;win.movableByWindowBackground=true;
var cv=win.contentView;
var BH=$BANNER_HEIGHT;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4;banner.borderWidth=0;banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$(as_esc "$DIALOG_TITLE")",20,H-BH+(BH-26)/2,W-40,26,18,true);
tl.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($tr/255,$tg/255,$tb/255,1);cv.addSubview(tl);
var BB=H-BH, IS=52, iy=BB-12-IS;
var icon=\$.NSImage.imageWithSystemSymbolNameAccessibilityDescription("lock.shield","cert");
if(icon){var iv=\$.NSImageView.alloc.initWithFrame(\$.NSMakeRect((W-IS)/2,iy,IS,IS));
 iv.setImage(icon);iv.imageScaling=3;iv.contentTintColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);cv.addSubview(iv);}
cv.addSubview(label("$(as_esc "$DIALOG_MESSAGE")",40,iy-26,W-80,20,13,false));
var wn=label("$(as_esc "$DIALOG_WARNING")",30,iy-48,W-60,18,12,false);wn.textColor=\$.NSColor.systemOrangeColor;cv.addSubview(wn);
var nt=label("$(as_esc "$note")",40,iy-68,W-80,16,11,false);nt.textColor=\$.NSColor.secondaryLabelColor;cv.addSubview(nt);
var LH=iy-152;
var rowH=22,sw=W-60,docH=Math.max(rows.length*rowH,LH);
var doc=\$.NSView.alloc.initWithFrame(\$.NSMakeRect(0,0,sw,docH));
var boxes=[];
for(var i=0;i<rows.length;i++){var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(4,docH-(i+1)*rowH,sw-8,rowH));
 b.setButtonType(3);b.title=rows[i];b.state=1;b.font=\$.NSFont.userFixedPitchFontOfSize(11);doc.addSubview(b);boxes.push(b);}
var sv=\$.NSScrollView.alloc.initWithFrame(\$.NSMakeRect(30,70,sw,LH));
sv.hasVerticalScroller=true;sv.borderType=1;sv.setDocumentView(doc);doc.scrollPoint(\$.NSMakePoint(0,docH));cv.addSubview(sv);
var cancel=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-176,20,170,32));
cancel.title="$(as_esc "$DIALOG_CANCEL_LABEL")";cancel.bezelStyle=1;cancel.target=h;cancel.action='no:';cv.addSubview(cancel);
var rm=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,20,170,32));
rm.title="$(as_esc "$DIALOG_REMOVE_LABEL")";rm.bezelStyle=1;rm.target=h;rm.action='ok:';rm.keyEquivalent=\$('\r');cv.addSubview(rm);
win.center;win.makeKeyAndOrderFront(null);app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win);win.orderOut(null);
if(resp==1){var o=[];for(var i=0;i<boxes.length;i++){if(ObjC.unwrap(boxes[i].state)==1)o.push(i);}o.join(',');}else '__CANCEL__';
EOF
  /bin/chmod 644 "$scpt"
  out="$(run_as_user /usr/bin/osascript -l JavaScript "$scpt" 2>/dev/null)"
  [[ "$out" == "__CANCEL__" || -z "$out" ]] && return 1
  print -r -- "$out"
  return 0
}

# --- Result window (copied from Set_Time_Zone show_message) ------------------
show_message() {  # $1 = title, $2 = message
  local t="${1//\"/\\\"}" m="${2//\"/\\\"}" mscpt="$SCRATCH/result.jxa"
  /bin/cat > "$mscpt" <<EOF
ObjC.import('Cocoa');
ObjC.registerSubclass({name:'DECMSG',superclass:'NSObject',methods:{'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.DECMSG.alloc.init;
var W=460,H=220,BH=64;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$t",20,H-BH+(BH-26)/2,W-40,26,17,true,1); tl.textColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($tr/255,$tg/255,$tb/255,1); cv.addSubview(tl);
cv.addSubview(label("$m",30,72,W-60,72,13,false,1));
var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect((W-130)/2,22,130,32)); b.title="$okButton"; b.bezelStyle=1; b.target=h; b.action='ok:'; b.keyEquivalent=\$('\r'); cv.addSubview(b);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
EOF
  /bin/chmod 644 "$mscpt"
  run_as_user /usr/bin/osascript -l JavaScript "$mscpt" >/dev/null 2>&1
}

# --- Deletion ---------------------------------------------------------------
# delete_cert <sha1> <keychain> <pem> <login(0/1)> -> 0 ok, 1 fail (backup verified before delete).
delete_cert() {
  local sha1="$1" kc="$2" pem="$3" login="$4"
  local dest="$BACKUP_DIR/${kc:t}_${sha1}.pem"
  if (( isDry )); then
    logMe INFO "[DRY] would back up ${sha1:0:8}… -> $dest, then delete from ${kc:t}"
    return 0
  fi
  /bin/cp -f "$pem" "$dest" 2>/dev/null && [[ -s "$dest" ]] || { logMe ERROR "Backup failed; NOT deleting ${sha1:0:8}…"; return 1; }
  if (( login )); then
    run_as_user /usr/bin/security delete-certificate -Z "$sha1" "$kc" >/dev/null 2>&1
  else
    /usr/bin/security delete-certificate -Z "$sha1" "$kc" >/dev/null 2>&1
  fi
  if (( $? == 0 )); then logMe INFO "Deleted ${sha1:0:8}… from ${kc:t} (backup: $dest)"; return 0
  else logMe ERROR "delete-certificate FAILED for ${sha1:0:8}… in ${kc:t}"; return 1; fi
}

####################################################################################################
#
# Main
#
####################################################################################################
logMe INFO "============================================================"
logMe INFO "Delete Expired Certificates — mode=${ACTION_MODE} dry=${isDry} excludes=(${EXCLUDE_PATTERNS[*]})"
logMe INFO "Running as $(/usr/bin/id -un) (uid $(/usr/bin/id -u)); console user=${consoleUser:-<none>}; keychain user=${kcUser:-<none>}"

# In verbose mode we need a console user to show the GUI; downgrade gracefully if none.
if [[ "$ACTION_MODE" == "verbose" && -z "$consoleUser" ]]; then
  logMe INFO "No console user for the GUI — downgrading to SILENT."
  ACTION_MODE="silent"
fi

# Build the keychain scan list: user login keychain (login=1) + System keychain (login=0).
typeset -a SCAN_KC SCAN_LOGIN
if [[ -n "$USER_HOME" && -e "$USER_HOME/Library/Keychains/login.keychain-db" ]]; then
  SCAN_KC+=("$USER_HOME/Library/Keychains/login.keychain-db"); SCAN_LOGIN+=(1)
else
  logMe INFO "No accessible login keychain (user=${kcUser:-<none>}) — scanning System keychain only."
fi
SCAN_KC+=("/Library/Keychains/System.keychain"); SCAN_LOGIN+=(0)

# System keychain edits require root.
if ! (( amRoot )); then
  logMe INFO "Not running as root — System keychain changes will fail (run via Jamf or with sudo)."
fi

# Scan.
integer i=1
for kc in "${SCAN_KC[@]}"; do
  scan_keychain_expired "$kc" "${SCAN_LOGIN[$i]}"
  (( i++ ))
done

total=${#REC_SHA}
logMe INFO "Total expired (non-excluded) certificates found: $total"

if (( total == 0 )); then
  logMe INFO "Nothing to remove. Done."
  [[ "$ACTION_MODE" == "verbose" ]] && show_message "No Expired Certificates" "No expired certificates were found in the login or System keychain."
  exit 0
fi

# Choose which records to remove.
typeset -a chosen
if [[ "$ACTION_MODE" == "verbose" ]]; then
  sel="$(ui_confirm "${REC_DISP[@]}")" || { logMe INFO "User cancelled — nothing removed."; exit 0; }
  for idx in ${(s:,:)sel}; do chosen+=($((idx+1))); done   # JS 0-based -> zsh 1-based
  (( ${#chosen} )) || { logMe INFO "Nothing selected — nothing removed."; exit 0; }
  logMe INFO "User confirmed ${#chosen} of $total certificate(s) for removal."
else
  for idx in {1..$total}; do chosen+=($idx); done
  logMe INFO "SILENT mode — removing all $total expired certificate(s)."
fi

# Prepare backup dir (live runs only).
if (( ! isDry )); then
  BACKUP_DIR="$BACKUP_PARENT/$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "$BACKUP_DIR" || die "Could not create backup dir: $BACKUP_DIR"
  /bin/chmod 700 "$BACKUP_DIR"
  logMe INFO "Backups -> $BACKUP_DIR"
else
  BACKUP_DIR="$BACKUP_PARENT/<dry-run>"
  logMe INFO "DRY RUN — no backups written, nothing deleted."
  logMe INFO "DRY RUN — the following ${#chosen} certificate(s) WOULD be deleted:"
  for idx in "${chosen[@]}"; do
    logMe INFO "  WOULD DELETE: ${REC_DISP[$idx]}  [${REC_KC[$idx]:t}]"
  done
fi

# Remove.
integer removed=0 failed=0
for idx in "${chosen[@]}"; do
  if delete_cert "$REC_SHA[$idx]" "$REC_KC[$idx]" "$REC_PEM[$idx]" "$REC_LOGIN[$idx]"; then
    (( removed++ ))
  else
    (( failed++ ))
  fi
done

logMe INFO "Done. removed=$removed failed=$failed (dry=$isDry)."

if [[ "$ACTION_MODE" == "verbose" ]]; then
  if (( isDry )); then
    show_message "Dry Run Complete" "Preview only — no changes made. ${#chosen} certificate(s) would have been removed."
  elif (( failed )); then
    show_message "Removal Finished With Errors" "Removed $removed certificate(s); $failed failed. Backups saved to $BACKUP_DIR. See the log for details."
  else
    show_message "Certificates Removed" "Removed $removed expired certificate(s). Backups saved to $BACKUP_DIR."
  fi
fi

# Exit 1 if any deletion failed so Jamf flags the policy.
(( failed )) && exit 1
exit 0
