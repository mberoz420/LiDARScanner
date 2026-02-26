# Setup Guide for Windows Developers

This guide helps you set up the LiDAR Scanner project for development on Windows using a Cloud Mac.

## Prerequisites

- GitHub account
- Apple Developer account ($99/year) - for device testing
- iPhone 12 Pro or newer with iOS 17+

## Step 1: Set Up Cloud Mac

### MacinCloud (Recommended)

1. Go to [MacinCloud](https://www.macincloud.com)
2. Sign up for "Dedicated Server" plan (~$30/month)
3. Choose latest macOS version
4. Note your connection details (IP, username, password)

### Connect from Windows

1. Download Microsoft Remote Desktop from Microsoft Store
2. Add a new PC with your MacinCloud IP
3. Connect using provided credentials

## Step 2: Set Up Development Environment

On your Cloud Mac:

### Install Xcode
```bash
# Open Mac App Store and install Xcode (free)
# This takes 20-30 minutes
```

### Install Command Line Tools
```bash
xcode-select --install
```

### Configure Git
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Clone the Project
```bash
cd ~/Developer
git clone https://github.com/yourusername/LiDARScanner.git
cd LiDARScanner
```

## Step 3: Create Xcode Project

Since we have Swift files but no .xcodeproj yet, create it in Xcode:

1. Open Xcode
2. File → New → Project
3. Choose "iOS App"
4. Settings:
   - Product Name: LiDARScanner
   - Team: Your Apple Developer Team
   - Organization Identifier: com.yourname
   - Interface: SwiftUI
   - Language: Swift
5. Save to the project directory (overwriting)
6. Delete the auto-generated files
7. Add existing files:
   - Right-click project → Add Files to "LiDARScanner"
   - Select all files in LiDARScanner folder
   - Check "Copy items if needed"
   - Check "Create groups"

### Configure Capabilities

1. Select the project in navigator
2. Select target "LiDARScanner"
3. Go to "Signing & Capabilities"
4. Add capabilities:
   - Camera
   - ARKit
5. Update Info.plist permissions (already configured)

### Build Settings

1. Set iOS Deployment Target to 17.0
2. Set TARGETED_DEVICE_FAMILY to iPhone (1)

## Step 4: Configure API Keys

Create `Config/APIKeys.swift`:

```swift
import Foundation

enum APIKeys {
    // Google Cloud Vision API (for image search)
    // Get from: https://console.cloud.google.com
    static let googleCloud = "YOUR_GOOGLE_CLOUD_API_KEY"

    // GrabCAD API (optional)
    // Request access: https://grabcad.com/developers
    static let grabcad = ""

    // TraceParts API (optional)
    // Register: https://www.traceparts.com/developers
    static let traceparts = ""

    // Thingiverse API (optional)
    // Get from: https://www.thingiverse.com/developers
    static let thingiverse = ""
}
```

### Getting Google Cloud API Key

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create a new project
3. Enable APIs:
   - Cloud Vision API
   - Custom Search API
4. Create credentials → API Key
5. Restrict key to iOS apps (optional but recommended)

## Step 5: Connect Your iPhone

### Enable Developer Mode on iPhone
1. Settings → Privacy & Security → Developer Mode → Enable
2. Restart when prompted

### Trust Your Mac
1. Connect iPhone via USB to your physical Mac
2. Trust the computer when prompted
3. In Xcode: Window → Devices and Simulators
4. Your iPhone should appear

### For Cloud Mac (Remote Development)
1. You'll need a physical connection at some point
2. Alternative: Use TestFlight for wireless testing:
   - Archive the app in Xcode
   - Upload to App Store Connect
   - Add yourself as internal tester
   - Install via TestFlight app

## Step 6: Build and Run

### In Xcode:
1. Select your iPhone as target device
2. Click Run (▶) or press ⌘+R
3. Wait for build and installation
4. App should launch on your iPhone

### First Launch
1. Grant camera permission when prompted
2. Point camera at an object
3. Tap capture to start scanning

## Troubleshooting

### "Could not launch LiDARScanner"
- Ensure Developer Mode is enabled on iPhone
- Trust the developer certificate in Settings → General → VPN & Device Management

### "ARKit is not available"
- Ensure you're using iPhone 12 Pro or newer
- LiDAR sensor required for mesh scanning

### Build Errors
- Clean build folder: Product → Clean Build Folder
- Reset package caches: File → Packages → Reset Package Caches

### Code Signing Issues
- Check your team is selected in Signing & Capabilities
- Ensure Apple Developer account is active

## Workflow Tips

### Efficient Remote Development

1. **Edit locally, build remotely**
   - Edit Swift files in VS Code on Windows
   - Push to Git
   - Pull on Cloud Mac
   - Build and test

2. **Use screen sharing sparingly**
   - Cloud Mac has latency
   - Do major coding locally
   - Use Cloud Mac for builds/testing

3. **TestFlight for testing**
   - Build once on Cloud Mac
   - Test wirelessly via TestFlight
   - Iterate on code locally

### Git Workflow
```bash
# On Windows (local editing)
git add .
git commit -m "Feature: Add dimension display"
git push

# On Cloud Mac (building)
git pull
# Open Xcode, build and test
```

## Cost Summary

| Service | Cost | Notes |
|---------|------|-------|
| MacinCloud | ~$30/month | Cloud Mac for development |
| Apple Developer | $99/year | Required for device testing |
| Google Cloud | ~$5-10/month | Vision API usage |
| Total | ~$45/month | First year higher due to Apple fee |

## Next Steps

1. Complete the Xcode project setup
2. Configure your API keys
3. Build and run on your iPhone
4. Start scanning objects!

## Support

- [Apple Developer Forums](https://developer.apple.com/forums/)
- [Stack Overflow - ARKit](https://stackoverflow.com/questions/tagged/arkit)
- [Swift Forums](https://forums.swift.org)
