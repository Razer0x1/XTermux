#!/bin/bash
# make_ipa.sh — package the built XTermux.app into an installable .ipa and
# copy it to the Windows project's dist/ folder as XTermux.ipa.
#
# The .app from `xtool dev build` lives in the ext4 build mirror at
# ~/xtermux-build/xtool/XTermux.app. An .ipa is just a zip with the app inside
# a Payload/ folder; sideload tools (AltStore, Sideloadly, TrollStore, ...)
# all install this format, and every identifier now reads XTermux natively —
# app name, bundle name, and executable all match, so packaging only stages
# the home-screen icon.
#
# The Linux build has no actool, so the home-screen icon is staged as a plain
# PNG and wired through the classic CFBundleIcons / CFBundleIconFiles
# Info.plist keys — a fully supported, honesty-first path with no compiled
# asset catalog required.

set -e

APP="$HOME/xtermux-build/xtool/XTermux.app"
DIST="/mnt/c/Users/Bhargav/Documents/XTermux/dist"
ICON="/mnt/c/Users/Bhargav/Documents/XTermux/Sources/XTermux/Resources/applogo.png"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run build_ios.sh first"
    exit 1
fi

STAGE="$HOME/xtermux-ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$DIST"
cp -R "$APP" "$STAGE/Payload/"

# --- brand the bundle: display name + home-screen icon --------------------
cp -f "$ICON" "$STAGE/Payload/XTermux.app/AppIcon-1024.png"

python3 - "$STAGE/Payload/XTermux.app/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    p = plistlib.load(f)
p['CFBundleDisplayName'] = 'XTermux'
p['CFBundleName'] = 'XTermux'
p['CFBundleIconFiles'] = ['AppIcon-1024.png']
p['CFBundleIcons'] = {
    'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': ['AppIcon-1024.png'],
        'UIPrerenderedIcon': False,
    },
}
with open(path, 'wb') as f:
    plistlib.dump(p, f)
print('Info.plist: display name -> XTermux, icon -> AppIcon-1024.png')
PY

cd "$STAGE"
if command -v zip >/dev/null 2>&1; then
    zip -qry XTermux.ipa Payload
else
    echo "note: zip not installed, using python3 zipfile"
    python3 -m zipfile -c XTermux.ipa Payload
fi

cp -f XTermux.ipa "$DIST/XTermux.ipa"

echo "--- bundle summary ---"
ls -la "$APP" | sed 's/^/  /'
BIN="$(cd "$STAGE/Payload/XTermux.app" && ls | grep -v -e '\.plist$' -e '\.png$' -e '\.bundle$' -e _CodeSignature -e PkgInfo -e mobileprovision | head -1)"
echo "binary name:      $BIN"
echo "codesign bundle:  $([ -d "$STAGE/Payload/XTermux.app/_CodeSignature" ] && echo present || echo MISSING)"
echo "provision file:   $([ -f "$STAGE/Payload/XTermux.app/embedded.mobileprovision" ] && echo present || echo MISSING)"
echo "app icon:         $([ -f "$STAGE/Payload/XTermux.app/AppIcon-1024.png" ] && echo staged || echo MISSING)"
echo "--- deliverable ---"
cp -f "$STAGE/Payload/XTermux.app/Info.plist" /tmp/XTermux-Info.plist 2>/dev/null || true
ls -la "$DIST/XTermux.ipa"