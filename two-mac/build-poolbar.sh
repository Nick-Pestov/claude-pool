#!/bin/bash
# Build PoolBar.app into ~/Applications (ad-hoc signed, menu bar only: no Dock icon).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/PoolBar.app"
build="$(mktemp -d)"
mkdir -p "$build/PoolBar.app/Contents/MacOS"
swiftc -O -target arm64-apple-macos14 -o "$build/PoolBar.app/Contents/MacOS/PoolBar" "$here/PoolBar.swift"
cat > "$build/PoolBar.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.claudepool.poolbar</string>
  <key>CFBundleName</key><string>PoolBar</string>
  <key>CFBundleExecutable</key><string>PoolBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PoolBar reads the other Mac's CPU and memory over the office network or the Thunderbolt cable.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$build/PoolBar.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mv "$build/PoolBar.app" "$app"
rmdir "$build"
echo "built $app"
