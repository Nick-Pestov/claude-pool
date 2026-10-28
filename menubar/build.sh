#!/bin/bash
# Build ClaudePool.app (the single-Mac menu bar app) into ~/Applications. Menu bar only, no Dock icon, ad-hoc signed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/ClaudePool.app"
build="$(mktemp -d)"
mkdir -p "$build/ClaudePool.app/Contents/MacOS"
swiftc -O -target arm64-apple-macos13 -o "$build/ClaudePool.app/Contents/MacOS/ClaudePool" "$here/ClaudePool.swift"
cat > "$build/ClaudePool.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.claudepool.menubar</string>
  <key>CFBundleName</key><string>Claude Pool</string>
  <key>CFBundleExecutable</key><string>ClaudePool</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$build/ClaudePool.app" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$app"
mv "$build/ClaudePool.app" "$app"
rmdir "$build" 2>/dev/null || true
echo "built $app"
