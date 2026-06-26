#!/bin/zsh

####################################################################################################
#
# Set Time Zone
#
# Purpose: Lets the logged-in user set the Mac's time zone from a branded picker, then confirms.
#
# Note: Fully native — no swiftDialog or JamfHelper. The GUI is built with osascript (JXA) + AppKit
#       and shown in the console user's session, so it works even when run as root from Jamf.
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
####################################################################################################

# --- Config ----------------------------------------------------------------
bannerColor="#0056D2"          # banner bar colour (hex)
pickerStyle="dropdown"         # "dropdown" = Area + Zone menus | "list" = one scrollable list
windowTitle="Set Time Zone"    # banner title on the picker
successTitle="Time Zone Updated"
failTitle="Time Zone Change Failed"
okButton="OK"
# ---------------------------------------------------------------------------

# Resolve the logged-in (console) user so the GUI appears in their session even
# when this script runs as root from Jamf.
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "$consoleUser" == "root" || "$consoleUser" == "loginwindow" ]] && consoleUser=""
[[ -n "$consoleUser" ]] && consoleUID=$(/usr/bin/id -u "$consoleUser" 2>/dev/null)
amRoot=0; [[ "$(id -u)" == 0 ]] && amRoot=1
run_as_user() {
  if (( amRoot )) && [[ -n "$consoleUID" ]]; then /bin/launchctl asuser "$consoleUID" /usr/bin/sudo -u "$consoleUser" "$@"
  else "$@"; fi
}

# Banner colour -> RGB components for AppKit
bhex="${bannerColor#\#}"
br=$((16#${bhex[1,2]})); bg=$((16#${bhex[3,4]})); bb=$((16#${bhex[5,6]}))

# All time zones (requires root; Jamf runs as root)
timezones=("${(@)${(@)${(f)$(systemsetup -listtimezones | awk '{$1=$1;print}')}##[[:space:]]##}[2,-1]}")
tzjs=""; for tz in "${timezones[@]}"; do tzjs+="\"${tz//\"/\\\"}\","; done

# --- Native branded confirmation window (replaces JamfHelper) ---------------
show_message() {  # $1 = title, $2 = message
  local t="${1//\"/\\\"}" m="${2//\"/\\\"}" mscpt="/tmp/set-timezone-msg.$$.jxa"
  /bin/cat > "$mscpt" <<EOF
ObjC.import('Cocoa');
ObjC.registerSubclass({name:'MSGH',superclass:'NSObject',methods:{'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;t.usesSingleLineMode=false;t.cell.wraps=true;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.MSGH.alloc.init;
var W=460,H=220,BH=64;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$t",20,H-BH+(BH-26)/2,W-40,26,17,true,1); tl.textColor=\$.NSColor.whiteColor; cv.addSubview(tl);
cv.addSubview(label("$m",30,78,W-60,64,13,false,1));
var b=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect((W-130)/2,22,130,32)); b.title="$okButton"; b.bezelStyle=1; b.target=h; b.action='ok:'; b.keyEquivalent=\$('\r'); cv.addSubview(b);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
app.runModalForWindow(win); win.orderOut(null); "";
EOF
  /bin/chmod 644 "$mscpt"
  run_as_user /usr/bin/osascript -l JavaScript "$mscpt" >/dev/null 2>&1
  /bin/rm -f "$mscpt"
}

# --- Build the picker (style chosen by $pickerStyle) ------------------------
pickerScpt="/tmp/set-timezone.$$.jxa"
if [[ "$pickerStyle" == "list" ]]; then
  # One scrollable, fixed-height list of every "Area/City" zone (NSTableView).
  /bin/cat > "$pickerScpt" <<EOF
ObjC.import('Cocoa');
var items=[ $tzjs ];
ObjC.registerSubclass({name:'TZSrc',superclass:'NSObject',methods:{
 'numberOfRowsInTableView:':{types:['q',['id']],implementation:function(tv){return items.length;}},
 'tableView:objectValueForTableColumn:row:':{types:['id',['id','id','q']],implementation:function(tv,c,r){return items[r];}}}});
ObjC.registerSubclass({name:'TZH',superclass:'NSObject',methods:{
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var src=\$.TZSrc.alloc.init, h=\$.TZH.alloc.init;
var W=520,H=560,BH=66;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$windowTitle",20,H-BH+(BH-26)/2,W-40,26,18,true,1); tl.textColor=\$.NSColor.whiteColor; cv.addSubview(tl);
cv.addSubview(label("Choose your time zone, then click Set.",30,H-BH-34,W-60,20,12,false,1));
var sv=\$.NSScrollView.alloc.initWithFrame(\$.NSMakeRect(20,66,W-40,H-BH-112));
sv.hasVerticalScroller=true; sv.borderType=1;
var table=\$.NSTableView.alloc.initWithFrame(\$.NSMakeRect(0,0,W-40,H-BH-112));
var col=\$.NSTableColumn.alloc.initWithIdentifier('tz'); col.width=W-60; table.addTableColumn(col);
table.headerView=\$(); table.rowHeight=22; table.usesAlternatingRowBackgroundColors=true; table.setDataSource(src);
sv.setDocumentView(table); cv.addSubview(sv);
var bc=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-156,18,150,32)); bc.title="Cancel"; bc.bezelStyle=1; bc.target=h; bc.action='no:'; cv.addSubview(bc);
var bset=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,18,150,32)); bset.title="Set"; bset.bezelStyle=1; bset.target=h; bset.action='ok:'; bset.keyEquivalent=\$('\r'); cv.addSubview(bset);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
var r=ObjC.unwrap(table.selectedRow);
(resp==1 && r>=0) ? items[r] : "__CANCEL__";
EOF
else
  # Two linked dropdowns: pick an Area, then the Zone within that Area.
  /bin/cat > "$pickerScpt" <<EOF
ObjC.import('Cocoa');
var items=[ $tzjs ];
var map={}, areas=[];
for (var k=0;k<items.length;k++){var tz=items[k];var i=tz.indexOf('/');var a=(i<0)?'Other':tz.substring(0,i);if(!map[a]){map[a]=[];areas.push(a);}map[a].push(tz);}
areas.sort();
var areaPop, zonePop;
function fillZones(area){ zonePop.removeAllItems; var arr=map[area]; for(var k=0;k<arr.length;k++){var t=arr[k]; zonePop.addItemWithTitle((area=='Other')?t:t.substring(area.length+1));} }
ObjC.registerSubclass({name:'TZH',superclass:'NSObject',methods:{
 'areaChanged:':{types:['void',['id']],implementation:function(s){ fillZones(areas[ObjC.unwrap(areaPop.indexOfSelectedItem)]); }},
 'ok:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(1);}},
 'no:':{types:['void',['id']],implementation:function(s){\$.NSApplication.sharedApplication.stopModalWithCode(0);}}}});
function label(s,x,y,w,ht,sz,bold,al){var t=\$.NSTextField.alloc.initWithFrame(\$.NSMakeRect(x,y,w,ht));
 t.stringValue=s;t.bezeled=false;t.editable=false;t.selectable=false;t.drawsBackground=false;t.alignment=al;
 t.textColor=\$.NSColor.labelColor;t.font=bold?\$.NSFont.boldSystemFontOfSize(sz):\$.NSFont.systemFontOfSize(sz);return t;}
var app=\$.NSApplication.sharedApplication; app.setActivationPolicy(1);
var h=\$.TZH.alloc.init;
var W=480,H=300,BH=64;
var win=\$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(\$.NSMakeRect(0,0,W,H),(1<<0)|(1<<15),2,false);
win.titlebarAppearsTransparent=true; win.titleVisibility=1; win.movableByWindowBackground=true;
var cv=win.contentView;
var banner=\$.NSBox.alloc.initWithFrame(\$.NSMakeRect(0,H-BH,W,BH));
banner.boxType=4; banner.borderWidth=0; banner.titlePosition=0;
banner.fillColor=\$.NSColor.colorWithSRGBRedGreenBlueAlpha($br/255,$bg/255,$bb/255,1);
cv.addSubview(banner);
var tl=label("$windowTitle",20,H-BH+(BH-26)/2,W-40,26,18,true,1); tl.textColor=\$.NSColor.whiteColor; cv.addSubview(tl);
cv.addSubview(label("Choose your time zone, then click Set.",30,H-BH-30,W-60,20,12,false,1));
cv.addSubview(label("Area:",30,160,90,20,13,false,2));
areaPop=\$.NSPopUpButton.alloc.initWithFrame(\$.NSMakeRect(130,156,W-160,26)); areaPop.addItemsWithTitles(\$(areas)); areaPop.target=h; areaPop.action='areaChanged:'; cv.addSubview(areaPop);
cv.addSubview(label("Zone:",30,120,90,20,13,false,2));
zonePop=\$.NSPopUpButton.alloc.initWithFrame(\$.NSMakeRect(130,116,W-160,26)); cv.addSubview(zonePop);
fillZones(areas[0]);
var bc=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2-156,22,150,32)); bc.title="Cancel"; bc.bezelStyle=1; bc.target=h; bc.action='no:'; cv.addSubview(bc);
var bset=\$.NSButton.alloc.initWithFrame(\$.NSMakeRect(W/2+6,22,150,32)); bset.title="Set"; bset.bezelStyle=1; bset.target=h; bset.action='ok:'; bset.keyEquivalent=\$('\r'); cv.addSubview(bset);
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
var resp=app.runModalForWindow(win); win.orderOut(null);
var a=areas[ObjC.unwrap(areaPop.indexOfSelectedItem)];
(resp==1) ? map[a][ObjC.unwrap(zonePop.indexOfSelectedItem)] : "__CANCEL__";
EOF
fi
/bin/chmod 644 "$pickerScpt"
selectedTimeZone="$(run_as_user /usr/bin/osascript -l JavaScript "$pickerScpt" 2>/dev/null)"
/bin/rm -f "$pickerScpt"

if [[ "$selectedTimeZone" == "__CANCEL__" || -z "$selectedTimeZone" ]]; then
  echo "User aborted"
  exit 0
fi

# --- Apply the time zone and confirm ----------------------------------------
echo "Selected time zone: $selectedTimeZone"
systemsetup -settimezone "$selectedTimeZone" >/dev/null 2>&1

# Verify against the active /etc/localtime symlink (source of truth, reliable
# across macOS versions — parsing `systemsetup -gettimezone` output is flaky).
currentTimeZone=$(/usr/bin/readlink /etc/localtime 2>/dev/null | /usr/bin/sed -E 's#.*/zoneinfo/##')
if [[ "$currentTimeZone" == "$selectedTimeZone" ]]; then
  echo "Time zone successfully set to $selectedTimeZone"
  show_message "$successTitle" "Your time zone is now set to \"$selectedTimeZone\"."
else
  echo "Failed to set time zone to $selectedTimeZone"
  show_message "$failTitle" "The time zone could not be changed to \"$selectedTimeZone\"."
fi
exit 0
