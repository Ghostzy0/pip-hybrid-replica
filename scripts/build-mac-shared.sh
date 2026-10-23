#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ]; then echo "Usage: $0 [pip|baseline|pip-plus|baseline-plus]" >&2; exit 2; fi
TASK_EDITION=${1:-pip}
case "$TASK_EDITION" in
  pip|pip-plus)
    TASK_BASELINE=0
    TASK_NAME="Pip Hybrid"
    TASK_BUNDLE_ID="app.pip.hybrid.mac"
    TASK_ICON_PLIST='<key>CFBundleIconFile</key><string>Pip.icns</string>'
    ;;
  baseline|baseline-plus)
    TASK_BASELINE=1
    TASK_NAME="Pip Hybrid Baseline"
    TASK_BUNDLE_ID="app.pip.hybrid.baseline"
    TASK_ICON_PLIST=''
    ;;
  *) echo "Unknown edition: $TASK_EDITION. Use pip, baseline, pip-plus or baseline-plus." >&2; exit 2 ;;
esac
TASK_VERSION="0.1.0"
TASK_BUILD="3"
TASK_ENHANCED=0
case "$TASK_EDITION" in
  *-plus)
    TASK_NAME="$TASK_NAME Plus"
    TASK_BUNDLE_ID="$TASK_BUNDLE_ID.plus"
    TASK_VERSION="0.2.0"
    TASK_BUILD="1"
    TASK_ENHANCED=1
    ;;
esac
TASK_SCRATCH="$TASK_ROOT/apps/mac/.build-$TASK_EDITION"
if [ "$(uname -m)" != "arm64" ]; then echo "This alpha targets Apple Silicon Macs." >&2; exit 1; fi
/usr/bin/python3 "$TASK_ROOT/scripts/prepare-mac-runtime.py"
set -- --package-path "$TASK_ROOT/apps/mac" --scratch-path "$TASK_SCRATCH" -c release --jobs 4
if [ "$TASK_BASELINE" = "1" ]; then set -- "$@" -Xswiftc -DBASELINE_EDITION; fi
if [ "$TASK_ENHANCED" = "1" ]; then set -- "$@" -Xswiftc -DENHANCED_EDITION; fi
swift build "$@" --product LocalSwitch
TASK_BIN_DIR=$(swift build "$@" --show-bin-path)
mkdir -p "$TASK_ROOT/dist"
TASK_OUTPUT="$TASK_ROOT/dist/$TASK_NAME.app"
TASK_STAGE=$(mktemp -d "$TASK_ROOT/dist/.package-$TASK_EDITION.XXXXXX")
trap 'rm -rf "$TASK_STAGE"' EXIT HUP INT TERM
TASK_APP="$TASK_STAGE/$TASK_NAME.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN_DIR/LocalSwitch" "$TASK_APP/Contents/MacOS/LocalSwitch"
rm -rf "$TASK_APP/Contents/Resources/runtime"
cp -R "$TASK_ROOT/apps/mac/.runtime/llama-b11768" "$TASK_APP/Contents/Resources/runtime"
cp "$TASK_ROOT/apps/mac/.runtime/provenance.json" "$TASK_APP/Contents/Resources/runtime-provenance.json"
cp -R "$TASK_ROOT/apps/mac/Resources/Licenses" "$TASK_APP/Contents/Resources/"
cp "$TASK_ROOT/LICENSE" "$TASK_APP/Contents/Resources/LocalSwitch-LICENSE"
cp "$TASK_ROOT/THIRD_PARTY_NOTICES.md" "$TASK_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Package only the requested edition's presentation resources. Never launch a GUI.
if [ "$TASK_BASELINE" = "0" ]; then
  cp -R "$TASK_ROOT/apps/mac/Resources/Fonts" "$TASK_APP/Contents/Resources/"
  cp "$TASK_ROOT/apps/mac/Resources/Pip.icns" "$TASK_APP/Contents/Resources/Pip.icns"
  cp "$TASK_ROOT/apps/mac/Resources/PIP-PROVENANCE.json" "$TASK_APP/Contents/Resources/PIP-PROVENANCE.json"
else
  # A baseline has no custom icon yet; macOS supplies the generic application icon.
  rm -f "$TASK_APP/Contents/Resources/Pip.icns" "$TASK_APP/Contents/Resources/PIP-PROVENANCE.json"
  rm -rf "$TASK_APP/Contents/Resources/Fonts"
fi
cat > "$TASK_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleName</key><string>$TASK_NAME</string><key>CFBundleDisplayName</key><string>$TASK_NAME</string>
<key>CFBundleIdentifier</key><string>$TASK_BUNDLE_ID</string><key>CFBundleExecutable</key><string>LocalSwitch</string>
$TASK_ICON_PLIST
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$TASK_VERSION</string><key>CFBundleVersion</key><string>$TASK_BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Pip Hybrid contributors · MIT</string>
</dict></plist>
PLIST
# Re-sign individual runtime files first. The manifest reflects their final installed bytes.
find "$TASK_APP/Contents/Resources/runtime" -type f \( -name '*.dylib' -o -name 'llama-*' \) -exec codesign --force --sign - {} \; 2>/dev/null
/usr/bin/python3 - "$TASK_APP/Contents/Resources/runtime" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); files={}
for p in root.iterdir():
    if p.is_file() and p.name!='localswitch-runtime.json': files[p.name]=hashlib.file_digest(p.open('rb'),'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(p.read_bytes()).hexdigest()
(root/'localswitch-runtime.json').write_text(json.dumps(files,indent=2)+'\n')
PY
codesign --force --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
# Replace only after the fresh bundle passes signature verification. Never merge old resources.
TASK_PREVIOUS="$TASK_STAGE/previous.app"
if [ -e "$TASK_OUTPUT" ] || [ -L "$TASK_OUTPUT" ]; then mv "$TASK_OUTPUT" "$TASK_PREVIOUS"; fi
if ! mv "$TASK_APP" "$TASK_OUTPUT"; then
  if [ -e "$TASK_PREVIOUS" ] || [ -L "$TASK_PREVIOUS" ]; then mv "$TASK_PREVIOUS" "$TASK_OUTPUT"; fi
  echo "Could not install staged package; previous package restored." >&2
  exit 1
fi
echo "Built $TASK_EDITION edition, local ad-hoc alpha: $TASK_OUTPUT"
echo "No notarisation or public installer is claimed. Open when you are ready."
