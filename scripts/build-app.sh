#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Building AgentMonitor in release mode..."
swift build -c release

# Locate release binary
BIN_PATH=""
for candidate in \
    ".build/release/AgentMonitor" \
    ".build/arm64-apple-macosx/release/AgentMonitor" \
    ".build/out/Products/Release/AgentMonitor"; do
    if [ -f "$candidate" ]; then
        BIN_PATH="$candidate"
        break
    fi
done

if [ -z "$BIN_PATH" ]; then
    # Try finding it dynamically
    BIN_PATH="$(find .build -type f -name AgentMonitor -perm +111 2>/dev/null | grep -i release | head -n 1)"
fi

if [ -z "$BIN_PATH" ] || [ ! -f "$BIN_PATH" ]; then
    echo "Error: Could not locate compiled AgentMonitor binary."
    exit 1
fi

echo "==> Found binary at: $BIN_PATH"

APP_DIR="build/AgentMonitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Assembling $APP_DIR..."
mkdir -p build
PACKAGE_DIR="$(mktemp -d "$REPO_ROOT/build/package.XXXXXX")"
if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$PACKAGE_DIR/AgentMonitor.previous.app"
fi
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/AgentMonitor"
chmod +x "$MACOS_DIR/AgentMonitor"
# SwiftPM resource bundle used by the read-only Paseo bridge.
cp -R "$(dirname "$BIN_PATH")/AgentMonitor_AgentMonitorCore.bundle" "$RESOURCES_DIR/"

echo "==> Generating AppIcon.icns..."
ICONSET_DIR="$PACKAGE_DIR/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET_DIR"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

cat <<'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AgentMonitor</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.cy.agentmonitor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Agent Monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>用于跳转到会话所在的终端标签页。</string>
</dict>
</plist>
EOF

echo "==> Signing application bundle..."
# A fresh CFBundleVersion per build makes LaunchServices and Notification Center re-read the
# bundle (including its icon) instead of keeping what they cached on the first launch.
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS_DIR/Info.plist"

codesign --force --sign - "$APP_DIR"

echo "==> Registering with LaunchServices (build $BUILD_VERSION)..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"

if [ -d "/Applications/AgentMonitor.app" ] && [ -w "/Applications/AgentMonitor.app" ]; then
    echo "==> Updating /Applications/AgentMonitor.app..."
    rm -rf /Applications/AgentMonitor.app
    cp -R "$APP_DIR" /Applications/AgentMonitor.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/AgentMonitor.app
fi

echo "==> Successfully built: $REPO_ROOT/$APP_DIR"
echo "To launch: open $REPO_ROOT/$APP_DIR"
