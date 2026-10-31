# BusinessBar Development Guide

## Quick Start

### Prerequisites
- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+ (or Command Line Tools, see below)
- Swift 6.0+

### Building with Command Line Tools only

The macOS 26 SDK implements SwiftUI `@State` and `#Preview` as external
Swift macros. Their plugin dylibs (`libSwiftUIMacros.dylib`,
`libPreviewsMacros.dylib`) ship only inside full Xcode, not in CLT, so a bare
`swift build` under CLT fails with `plugin for module 'SwiftUIMacros' not found`.

The repo's build entry points (`make`, `build.sh`, `bundle_app.sh`) handle
this automatically via `scripts/swift-clt-plugins.sh`: under CLT they add the
missing `-plugin-path` flags, resolved from a vendored stash first and from a
live Xcode install second. With full Xcode selected nothing changes.

To build without Xcode installed, stash the dylibs once while it is still
installed: `make plugins-refresh` (copies ~2 MB into the gitignored
`Vendor/SwiftMacroPlugins/`). The stash is version-locked to the SDK, so
re-run it after any macOS SDK / CLT update.

### Refreshing the macro plugin stash

The stash in `Vendor/SwiftMacroPlugins/` is version-locked to the Swift
frontend and SDK that built it. It goes stale after a major CLT or macOS
SDK update; symptoms are `plugin for module 'SwiftUIMacros' not found` or a
frontend crash during macro expansion. When that happens, re-stash from any
full Xcode 27+ install that matches your CLT's Swift version:

1. **GitHub workflow (no local Xcode needed):** Actions tab → *Refresh
   Swift Macro Plugins* → *Run workflow*. It extracts the two dylibs from
   the hosted Xcode 27 image and uploads them as an artifact. Download, then:
   ```
   cp <artifact>/SwiftMacroPlugins/*.dylib Vendor/SwiftMacroPlugins/
   make release   # verify the build is green again
   ```
   The artifact includes `TOOLCHAIN.txt` (Swift, Xcode, and macOS versions
   it was built against); compare with your local `swift --version`.
2. **Local Xcode:** `make plugins-refresh` while Xcode is installed, then
   delete it again if you want.
3. **Another Mac:** copy the two dylibs from
   `<Xcode>/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/`
   into `Vendor/SwiftMacroPlugins/`.

Summary: building needs CLT only, refreshing the stash needs full Xcode,
but only briefly (a workflow run, a temporary install, or a borrowed Mac).
If Apple ships the plugins inside CLT itself, the build helper goes silent
on its own and the stash becomes unnecessary.

Limitation: running the XCTest suite still needs full Xcode: XCTest.framework
is also Xcode-only. Under CLT, `make test` fails to compile the suite:
swiftc cannot resolve the XCTest module at build time, so the tests never
launch at all.

The chat markdown regression check runs with CLT alone:
`bash scripts/test-chat-markdown.sh`. It compiles the production renderer
and native hosting view directly, then checks incomplete streamed markup,
glyph bounds inside the allocated chat bubble, width-dependent sizing in
light and dark appearances, select-all and main-run-loop progress under a 10-second watchdog.
Optional `--stream-chunks /path/to/recorded-stream.json` replays captured
client deltas. The JSON contains `chunks` (an ordered string array),
`fullText` (their joined text) and `terminal` ("finished"). This replay
does not call a model or modify the app's chat history or preferences.

### Whole-application coverage

Run `bash scripts/test-coverage.sh` for the instrumented production-module
scenarios and native markdown/composer regressions. With full Xcode, run
`bash scripts/test-coverage.sh --with-xctest` to include the original XCTest
suite and the shared application scenarios through XCTest. CI uses this
second command and uploads its coverage inventory and exports.

The gate requires strictly more than 90% across **all** Swift production
sources in `BusinessBar/` and `BusinessBarCore/`, including unchanged and
zero-hit files. It checks both LLVM's summary-line count and deduplicated
LCOV `(file, line)` entries. LLVM's summary count can be larger than the
unique source-line count, so both are reported. Tests and dependencies
are outside the denominator. Declaration-only sources with
no executable mappings are listed explicitly, not counted as covered.

Each run needs a fresh output directory. Use `--output-dir /path/to/output`
to retain profiles, `summary.json`, `coverage.json`, and `coverage.lcov`.
`--report-only` is diagnostic: it can exit successfully below the threshold,
but the report still says `FAIL`. It is not the PR or CI gate.
Reusing a build with `--no-build` requires `--report-only`; it cannot satisfy
the acceptance gate. A gating run checks the complete production source
fingerprint before and after execution.

Shared scenarios use injected system boundaries and isolated storage.
The standalone runner links the actual instrumented app and core objects,
not rewritten production sources. It substitutes only its own executable
entry point. Coverage is exported from the complete app executable, so
the original application entry remains in the denominator.

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
