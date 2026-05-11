#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

source build.env

pkill -x Cue 2>/dev/null || true
pkill -f "chrome-headless-shell" 2>/dev/null || true
pkill -f "sidecar/index.js" 2>/dev/null || true

swift build -c debug

APP="/Applications/Cue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/debug/Cue "$APP/Contents/MacOS/Cue"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.chaurasia.cue</string>
    <key>CFBundleName</key>
    <string>cue</string>
    <key>CFBundleDisplayName</key>
    <string>cue</string>
    <key>CFBundleExecutable</key>
    <string>Cue</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>cue reads what's on screen so it can guide you through your task step by step.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>cue transcribes what you say so you can speak your task instead of typing it.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>cue uses speech recognition to turn your spoken task into text.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements Cue.entitlements --options runtime "$APP"

# Tell Launch Services about this bundle so `open` and Spotlight pick it up.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP" 2>/dev/null || true

# Grant TCC permissions directly so they survive rebuilds without re-prompting.
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
BUNDLE="com.chaurasia.cue"
NOW=$(date +%s)
for SERVICE in kTCCServiceAccessibility kTCCServiceScreenCapture; do
  sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified,pid,pid_version,boot_uuid,last_reminded) VALUES('$SERVICE','$BUNDLE',0,2,4,1,NULL,NULL,NULL,'UNUSED',NULL,0,$NOW,NULL,NULL,'UNUSED',0);" 2>/dev/null || true
done

echo "installed $APP"
