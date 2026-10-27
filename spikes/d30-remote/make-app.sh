#!/bin/bash
# Baut den Spike als Programmpaket (ad hoc signiert): .build/D30Remote.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=.build/D30Remote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/D30Remote "$APP/Contents/MacOS/D30Remote"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>d30-remote</string>
  <key>CFBundleIdentifier</key><string>io.github.mymartek.avpplay.d30remote</string>
  <key>CFBundleExecutable</key><string>D30Remote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSWorldSensingUsageDescription</key><string>Die Kopfposition der Vision Pro, damit der Würfel im Raum stehen bleibt.</string>
</dict></plist>
PLIST
codesign -s - --force "$APP"
echo "$APP"
