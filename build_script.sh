#!/bin/bash
# Quick Build Script for LiDARScanner
# Paste this entire script into Terminal on your Cloud Mac

cd ~/Desktop

# Clone if not exists
if [ ! -d "LiDARScanner" ]; then
    git clone https://github.com/mberoz420/LiDARScanner.git
fi

cd LiDARScanner

# Pull latest
git pull

# Install xcodegen if needed
if ! command -v xcodegen &> /dev/null; then
    brew install xcodegen
fi

# Create project.yml for XcodeGen
cat > project.yml << 'EOF'
name: LiDARScanner
options:
  bundleIdPrefix: com.lidarscanner
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"
settings:
  base:
    SWIFT_VERSION: "5.9"
targets:
  LiDARScanner:
    type: application
    platform: iOS
    sources:
      - path: LiDARScanner
        excludes:
          - "**/*.plist"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lidarscanner.app
        INFOPLIST_FILE: LiDARScanner/Info.plist
        DEVELOPMENT_TEAM: ""
        CODE_SIGNING_ALLOWED: "NO"
    info:
      path: LiDARScanner/Info.plist
      properties:
        CFBundleDisplayName: LiDAR Scanner
        UILaunchScreen: {}
        NSCameraUsageDescription: "Camera access is required for LiDAR scanning"
        UIRequiredDeviceCapabilities:
          - arkit
          - lidar
EOF

# Generate Xcode project
xcodegen generate

# Build for simulator (no code signing needed)
xcodebuild build \
    -project LiDARScanner.xcodeproj \
    -scheme LiDARScanner \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee build_output.txt

echo ""
echo "========================================="
echo "Build complete! Check build_output.txt for details"
echo "========================================="
