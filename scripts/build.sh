#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Agent Isle.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Sounds" .build
for ARCH in arm64 x86_64; do
  swiftc -swift-version 5 -O -parse-as-library -target "$ARCH-apple-macosx14.0" Sources/*.swift \
    -o ".build/agent-isle-$ARCH" \
    -framework AppKit -framework SwiftUI -framework UserNotifications -framework QuartzCore -framework ApplicationServices -framework Carbon -framework ServiceManagement
done
lipo -create .build/agent-isle-arm64 .build/agent-isle-x86_64 -output "$APP/Contents/MacOS/agent-isle"
/usr/bin/python3 scripts/bundle_runtime.py
mkdir -p "$APP/Contents/Resources/Guide"
cp web/guide/* "$APP/Contents/Resources/Guide/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
mkdir -p "$APP/Contents/Resources/Licenses"
cp licenses/* "$APP/Contents/Resources/Licenses/"
cp -R agent_isle "$APP/Contents/Resources/"
find "$APP/Contents/Resources/agent_isle" -type d -name __pycache__ -exec rm -rf {} +
/usr/bin/python3 scripts/make_sounds.py "$APP/Contents/Resources/Sounds"
/usr/bin/python3 scripts/package_bridge.py
cp dist/agent-isle-bridge.vsix "$APP/Contents/Resources/agent-isle-bridge.vsix"
swift scripts/make_icon.swift .build/AgentIsle.iconset
iconutil -c icns .build/AgentIsle.iconset -o "$APP/Contents/Resources/AgentIsle.icns"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
