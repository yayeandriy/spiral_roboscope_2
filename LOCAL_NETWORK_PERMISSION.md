# Local Network Permission Setup

## Problem

iOS requires explicit permission to access the local network. Without this permission, your app cannot communicate with servers on your local network (like the alignment server at `localhost:6000` or `192.168.x.x:6000`).

## Solution

Added `Info.plist` with the following permissions:

### 1. NSLocalNetworkUsageDescription
Explains to the user why the app needs local network access.

### 2. NSBonjourServices
Declares the network services the app will use (`_http._tcp` for HTTP connections).

## What Was Changed

### Created `/roboscope2/Info.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>This app needs to access your local network to communicate with the alignment server for 3D model positioning.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_http._tcp</string>
	</array>
</dict>
</plist>
```

### Updated `project.pbxproj`
Added `INFOPLIST_FILE = roboscope2/Info.plist;` to both Debug and Release configurations.

## User Experience

When the app first tries to access the local network:

1. iOS will show a system alert:
   ```
   "roboscope2" Would Like to Find and Connect to Devices on Your Local Network
   
   This app needs to access your local network to communicate with the 
   alignment server for 3D model positioning.
   
   [Don't Allow]  [OK]
   ```

2. User must tap **"OK"** to allow local network access

3. Permission is saved - won't be asked again unless app is reinstalled

## Testing

### After Rebuilding the App

1. **Delete the app** from your iPhone (if already installed)
2. **Rebuild and run** from Xcode
3. **Tap "Fix model"** button when model is placed
4. **Allow local network** when the permission dialog appears
5. App should now successfully connect to the alignment server

### Verify Permission Granted

Settings → Privacy & Security → Local Network → roboscope2 (should be ON)

## Troubleshooting

### Permission dialog doesn't appear
- Make sure you deleted and reinstalled the app
- Check that Info.plist is properly referenced in Xcode project

### Still can't connect after allowing permission
- Verify alignment server is running: `curl http://localhost:6000/align`
- Check server URL in `ContentView.swift` matches your server address
- Try using iPhone's IP address instead of localhost if server is on different machine
- Check firewall settings on server machine

### Permission was denied
- Go to Settings → Privacy & Security → Local Network
- Find "roboscope2" and toggle it ON
- Restart the app

## Server URL Configuration

### If server is on the same iPhone
```swift
let serverURL = "http://localhost:6000/align"
```

### If server is on your Mac (same WiFi network)
1. Find your Mac's IP address:
   ```bash
   ifconfig | grep "inet " | grep -v 127.0.0.1
   ```
2. Update ContentView.swift:
   ```swift
   let serverURL = "http://192.168.1.XXX:6000/align"  // Replace with your Mac's IP
   ```

### If server is on cloud/remote server
```swift
let serverURL = "http://YOUR_DOMAIN:6000/align"
```

## Important Notes

1. **Local network permission is required for:**
   - Localhost connections (127.0.0.1)
   - Local IP addresses (192.168.x.x, 10.x.x.x)
   - Bonjour/mDNS services

2. **Not required for:**
   - Internet connections (public IP addresses)
   - HTTPS connections to domains

3. **iOS 14+ requirement:**
   - This permission was introduced in iOS 14
   - Your app targets iOS 18+, so this is always required

4. **Privacy:**
   - The permission protects user privacy
   - App cannot scan local network without permission
   - User has full control via Settings

## Alternative: Use Cloud Server

If you don't want to deal with local network permissions, deploy the alignment server to a cloud provider:

1. Deploy to cloud (AWS, DigitalOcean, etc.)
2. Get public domain/IP
3. Update server URL to use public address
4. No local network permission needed!

Example:
```swift
let serverURL = "https://alignment.yourcompany.com/align"
```

## References

- [Apple Documentation: NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription)
- [Apple Documentation: NSBonjourServices](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices)
- [WWDC 2020: Support local network privacy in your app](https://developer.apple.com/videos/play/wwdc2020/10110/)
