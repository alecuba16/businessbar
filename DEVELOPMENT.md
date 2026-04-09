# BusinessBar Development Guide

## Quick Start

### Prerequisites
- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+
- Swift 6.0+

### Building the Project

#### Option 1: Using Make (Recommended)
```bash
# Setup dependencies
make setup

# Build debug version
make build

# Build release version
make release

# Run the application
make run

# Open in Xcode
make xcode

# Clean build artifacts
make clean
```

#### Option 2: Using Swift Package Manager
```bash
# Resolve dependencies
swift package resolve

# Build debug
swift build

# Build release
swift build -c release

# Run
.build/debug/BusinessBar
```

#### Option 3: Using the Build Script
```bash
# Make executable (first time only)
chmod +x build.sh

# Build debug
./build.sh

# Build release
./build.sh release

# Clean
./build.sh clean
```

## Project Structure

```
BusinessBar/
├── App/                    # Application entry and lifecycle
│   ├── BusinessBarApp.swift
│   ├── AppDelegate.swift
│   └── Constants.swift
├── Core/                   # Core business logic
│   ├── Meeting/           # Calendar and event management
│   ├── Badges/            # Dock badge monitoring
│   └── NoSleep/           # Sleep prevention
├── UI/                    # User interface
│   ├── StatusBar/         # Menu bar controller
│   ├── Notifications/     # System notifications
│   └── Views/             # SwiftUI views
├── Intents/               # App Intents for Spotlight
├── Services/              # External services (OAuth, etc.)
└── Utilities/             # Helpers and extensions
```

## Key Components

### 1. Meeting Manager
Handles calendar event fetching and management.

**File**: `BusinessBar/Core/Meeting/MeetingManager.swift`

**Key Features**:
- EventKit integration
- Event filtering and sorting
- Combine-based reactive updates
- 180-second refresh interval

**Usage**:
```swift
let meetingManager = MeetingManager()

// Observe next event
meetingManager.$nextEvent
    .sink { event in
        print("Next event: \(event?.title ?? "None")")
    }
```

### 2. Badge Manager
Monitors dock icon badges via Accessibility API.

**File**: `BusinessBar/Core/Badges/BadgeManager.swift`

**Key Features**:
- 1-second polling interval
- Dynamic status item creation/destruction
- Persistent app selection

**Usage**:
```swift
let badgeManager = BadgeManager()

// Observe badge changes
badgeManager.$badges
    .sink { badges in
        print("Active badges: \(badges.count)")
    }
```

### 3. NoSleep Manager
Prevents system sleep using IOKit power assertions.

**File**: `BusinessBar/Core/NoSleep/NoSleepManager.swift`

**Key Features**:
- Two sleep modes (system-only, system+display)
- Configurable duration
- Auto-refresh every 10 seconds

**Usage**:
```swift
let noSleepManager = NoSleepManager()

// Activate for 30 minutes
noSleepManager.activate(duration: 30 * 60)

// Activate indefinitely
noSleepManager.activate(duration: nil)

// Deactivate
noSleepManager.deactivate()
```

## Development Workflow

### Running in Xcode

1. Open project:
   ```bash
   xed .
   ```

2. Select the `BusinessBar` scheme

3. Run (⌘R)

### Adding Dependencies

Edit `Package.swift` and add to the `dependencies` array:

```swift
.package(url: "https://github.com/owner/repo", from: "1.0.0")
```

Then resolve:
```bash
swift package resolve
```

### Testing Permissions

#### Calendar Permission
Add to `Info.plist`:
```xml
<key>NSCalendarsUsageDescription</key>
<string>BusinessBar needs access to your calendar...</string>
```

#### Notifications Permission
Request in code:
```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
```

#### Accessibility Permission
Users must manually enable in System Settings:
- System Settings → Privacy & Security → Accessibility
- Add BusinessBar to the list

Test in code:
```swift
let trusted = AXIsProcessTrusted()
print("Accessibility: \(trusted)")
```

## Debugging

### Enable Verbose Logging

Add to your scheme's environment variables:
- `DEBUG_LOGGING = 1`

### Common Issues

#### 1. App Won't Launch
- Check that `LSUIElement` is set to `YES` in Info.plist
- Verify entitlements are correct
- Check Console.app for crash logs

#### 2. Calendar Events Not Showing
- Verify Calendar permission is granted
- Check selected calendars in preferences
- Ensure EventKit framework is linked

#### 3. Badge Icons Not Appearing
- Grant Accessibility permission
- Check that monitored apps are running
- Verify apps have dock badges

#### 4. NoSleep Not Working
- Check IOKit framework is linked
- Verify NoSleep power assertions are being created (use Activity Monitor)

## Code Style

### Swift Conventions
- Use `@MainActor` for UI-related classes
- Prefer `async/await` over completion handlers
- Use `Combine` for reactive state management
- Follow Swift API Design Guidelines

### File Organization
- One class/struct per file
- Group related files in folders
- Use `// MARK: -` to separate sections

### Naming
- Classes: `PascalCase`
- Functions: `camelCase`
- Constants: `camelCase` (or `SCREAMING_SNAKE_CASE` for global constants)
- Private properties: prefix with underscore if needed for clarity

## Testing

### Manual Testing Checklist

- [ ] Launch app, verify status bar icon appears
- [ ] Check next meeting displays correctly
- [ ] Click status bar, verify dropdown menu
- [ ] Add/remove monitored apps for badges
- [ ] Activate/deactivate NoSleep
- [ ] Open preferences, verify all tabs
- [ ] Run onboarding flow (delete defaults first)
- [ ] Test App Intents in Spotlight
- [ ] Verify notifications appear

### Reset App State

To test onboarding again:
```bash
defaults delete com.businessbar.app
```

## Deployment

### Code Signing

1. Configure signing certificate in Xcode
2. Select "Developer ID Application" certificate
3. Enable hardened runtime

### Notarization

```bash
# Archive
xcodebuild archive -scheme BusinessBar -archivePath BusinessBar.xcarchive

# Export
xcodebuild -exportArchive -archivePath BusinessBar.xcarchive \
  -exportPath . -exportOptionsPlist ExportOptions.plist

# Notarize
xcrun notarytool submit BusinessBar.zip \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

### Creating a DMG

```bash
# Create DMG
hdiutil create -volname "BusinessBar" -srcfolder BusinessBar.app \
  -ov -format UDZO BusinessBar.dmg
```

## Contributing

### Before Submitting a PR

1. Run code formatting:
   ```bash
   swiftformat .
   ```

2. Check for warnings:
   ```bash
   make build
   ```

3. Test all three core features

4. Update documentation if needed

## Resources

- [Swift Package Manager Documentation](https://swift.org/package-manager/)
- [EventKit Framework](https://developer.apple.com/documentation/eventkit)
- [IOKit Power Management](https://developer.apple.com/documentation/iokit)
- [Accessibility API](https://developer.apple.com/accessibility/)
- [App Intents](https://developer.apple.com/documentation/appintents)

## Support

For issues or questions:
1. Check the [IMPLEMENTATION.md](IMPLEMENTATION.md) file
2. Open an issue on GitHub

## License

MIT License - See [LICENSE](LICENSE) file for details.
