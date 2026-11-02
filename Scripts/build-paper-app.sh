#!/bin/bash
# Builds a double-clickable Paper.app (release build) in the project folder.
#   Scripts/build-paper-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Paper
swift build -c release --product PaperSnapshots

APP=Paper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Paper "$APP/Contents/MacOS/Paper"

# App icon: painted by Paper's own brush engine, then scaled to every size macOS asks for.
WORK=$(mktemp -d)
ICONSET="$WORK/Paper.iconset"
mkdir -p "$ICONSET"
.build/release/PaperSnapshots --icon "$WORK/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Paper.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Paper</string>
  <key>CFBundleDisplayName</key><string>Paper</string>
  <key>CFBundleIdentifier</key><string>com.silverninja71.paper</string>
  <key>CFBundleExecutable</key><string>Paper</string>
  <key>CFBundleIconFile</key><string>Paper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.silverninja71.paper.artwork</string>
      <key>UTTypeDescription</key><string>Paper Artwork</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>paper</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.silverninja71.paper.brush</string>
      <key>UTTypeDescription</key><string>Paper Brush</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>paperbrush</string><string>paperbrushset</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Paper Artwork</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>com.silverninja71.paper.artwork</string></array>
      <key>LSTypeIsPackage</key><true/>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Brushes</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.silverninja71.paper.brush</string></array>
      <key>CFBundleTypeExtensions</key><array><string>abr</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
