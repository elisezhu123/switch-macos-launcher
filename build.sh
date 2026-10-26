#!/bin/zsh
# Build "sw-launcher.app" for macOS 15+ on Apple silicon.
set -e
cd "$(dirname "$0")"
VERSION="${1:-1.1.0}"
APP="sw-launcher.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 Launcher.swift LauncherCore.swift NXCatalog.swift -o "$APP/Contents/MacOS/sw-launcher"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>sw-launcher</string>
<key>CFBundleIdentifier</key><string>org.macnativegames.sw-launcher</string>
<key>CFBundleName</key><string>sw-launcher</string>
<key>CFBundleDisplayName</key><string>sw-launcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSAppleEventsUsageDescription</key><string>用于在“终端”里运行安装命令。</string>
</dict></plist>
PLIST
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp totk-mac-fixes.patch sw-port.patch "$APP/Contents/Resources/"
codesign --force -s - "$APP"
echo "built: $PWD/$APP"
