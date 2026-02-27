# LiDARScanner Project - Session Notes
## Date: Feb 27, 2026

## Project Overview
- **App**: LiDAR Scanner iOS app (SwiftUI + ARKit)
- **Bundle ID**: `com.lidarscanner.LiDarScanner`
- **Team ID**: `J4FK2D7585`
- **GitHub Repo**: https://github.com/mberoz420/LiDARScanner

## What We Did
1. Set up proper iOS project structure (no Mac needed - uses XcodeGen)
2. Created `codemagic.yaml` for CI/CD builds
3. Created `project.yml` for XcodeGen to generate Xcode project
4. Connected Codemagic to GitHub repo
5. Set up App Store Connect API key for TestFlight deployment
6. Created Apple Distribution certificate (using OpenSSL on Windows)
7. Created App Store provisioning profile

## Codemagic Configuration
- **Environment Variable Group**: `App_Store`
- **Variables in group**:
  - `APP_STORE_CONNECT_ISSUER_ID`: aa8bb80e-7e37-4f55-b8dc-4fa5ccba1567
  - `APP_STORE_CONNECT_KEY_IDENTIFIER`: MKXR42YG2V
  - `APP_STORE_CONNECT_PRIVATE_KEY`: (the .p8 file contents)
  - `CM_CERTIFICATE`: (base64 encoded .p12 certificate)
  - `CM_PROVISIONING_PROFILE`: (base64 encoded .mobileprovision)
  - `CERTIFICATE_PASSWORD`: codemagic123

## Apple Developer Portal
- Distribution certificate created and active
- App Store provisioning profile: "LiDARScanner AppStore"

## Current Status
- Build pipeline is set up and running
- TestFlight has version 2 (build 3) from earlier
- New builds should auto-deploy to TestFlight on push to master

## To Start a New Build
1. Go to https://codemagic.io
2. Click on LiDARScanner app
3. Click "Start new build"
4. Select workflow: `ios-workflow`
5. Select branch: `master`
6. Click Start

## Files Created/Modified
- `codemagic.yaml` - CI/CD configuration
- `project.yml` - XcodeGen project definition
- `LiDARScanner/LiDARScannerApp.swift` - App entry point
- `LiDARScanner/ContentView.swift` - Main view
- `LiDARScanner/ScannerView.swift` - AR/LiDAR scanning view
- `LiDARScanner/Info.plist` - App configuration
- `LiDARScanner/Assets.xcassets/` - App icons

## Auto-Publish & Update Alerts Setup

### Triggers
- **Ad-Hoc (Diawi)**: Auto-triggers on push to `main` or `develop` branches
- **TestFlight**: Auto-triggers on version tags (e.g., `v1.0.0`, `v1.1.0`)

### Required: Codemagic Environment Variables

**Add a new group called `Diawi`** with these variables:

| Variable | Description |
|----------|-------------|
| `DIAWI_TOKEN` | Your Diawi API token (get from https://dashboard.diawi.com/profile/api) |
| `DIAWI_EMAIL` | Email to receive Diawi notifications |
| `GITHUB_TOKEN` | GitHub Personal Access Token with `repo` scope |
| `VERSION_JSON_REPO` | GitHub repo for hosting version.json (e.g., `mberoz420/LiDARScanner`) |

### How to Get Diawi Token
1. Go to https://www.diawi.com and sign up/login
2. Go to Profile → API → Generate API Token
3. Copy the token to Codemagic

### How to Set Up GitHub Token
1. Go to https://github.com/settings/tokens
2. Generate new token (classic) with `repo` scope
3. Copy to Codemagic as `GITHUB_TOKEN`
4. Set `VERSION_JSON_REPO` to `mberoz420/LiDARScanner`

### Configure In-App Update URL
After first successful build, your version.json will be at:
```
https://raw.githubusercontent.com/mberoz420/LiDARScanner/main/version.json
```

1. Open the app → Settings → Updates
2. Enter the URL above in "Version Check URL"
3. Enable "Auto Check for Updates"

### How It Works
1. Push to `main` → Codemagic builds & uploads to Diawi
2. Diawi URL is captured and written to `version.json`
3. `version.json` is pushed to GitHub repo
4. App checks `version.json` and shows update alert if newer version available
5. User taps "Download" → Opens Diawi install page

## If Build Fails
- Check Codemagic build logs for specific error
- Common issues: code signing, provisioning profile mismatch
- Certificate password: `codemagic123`
