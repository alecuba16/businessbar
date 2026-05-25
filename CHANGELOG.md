# Changelog

All notable changes to BusinessBar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.2] - 2026-05-25
### Fixed
- Fixed SIGTRAP crash when opening Preferences in CI-built app — SPM's `Bundle.module` accessor for KeyboardShortcuts could not locate the resource bundle inside `.app/Contents/Resources/`, causing a `fatalError` at view initialization. Added a safe lookup that uses `Bundle.main.url(forResource:withExtension:)` which correctly searches the app bundle. ([KeyboardShortcuts #229](https://github.com/sindresorhus/KeyboardShortcuts/issues/229))
- SPM resource bundles in `Contents/Resources/` are now signed before the main app during `bundle_app.sh`, preventing macOS from rejecting them at runtime

### Changed
- `bundle_app.sh` resolves SPM dependencies (`swift package resolve`) and patches KeyboardShortcuts' `Utilities.swift` before building, injecting a `keyboardShortcutsSafeBundle` accessor as a drop-in replacement for the broken `Bundle.module`

## [1.2.1] - 2026-05-25
### Added
- Crash handling with signal and NSException handlers — unhandled crashes are captured to `~/Library/Logs/BusinessBar/crash_*.log`
- Alert on next launch when a previous session crash is detected, with "Reveal in Finder" button

### Changed
- Refactored relative time formatting in `StatusBarController` into shared `formatRelative(minutes:)` helper (eliminates duplicate logic)
- Moved "Meeting title max length" and "Event time format" controls from Calendars tab to Appearance tab
- Appearance tab preferences now post `businessBarPreferencesDidChange` notification on change (immediate live update without waiting for next event refresh)
- `String.truncated(to:trailing:)` clamps prefix length to zero instead of crashing on negative values

### Fixed
- `String.truncated(to:trailing:)` no longer traps at runtime when custom trailing string exceeds `maxLength` (e.g. trailing "....." with maxLength 3)

### Removed
- Unused `cachedFallbackIcon` and `renderFallbackIcon()` from `StatusBarController`

## [1.2.0] - 2026-05-25
### Added
- Configurable rounding threshold for relative times in Appearance preferences (0 = always exact, 1+ = round to whole hours when ≥ that many hours away)
- Relative times now show minutes past the hour when < threshold (e.g. "1h31m" instead of just "1h")

### Changed
- CI workflow uses `PlistBuddy` instead of `defaults read` for version sanity check (more reliable in CI environments)

## [1.1.2] - 2026-04-11
### Changed
- Improved the coverage test
- Updated version management

## [1.1.1] - 2026-04-09

### Fixed
- Removed `credentials.local.json` from SPM resources in `Package.swift` (moved to `exclude`) to eliminate `Invalid Resource: File not found` warning in CI where the gitignored file doesn't exist
- Added `permissions: contents: write` to release workflow so `GITHUB_TOKEN` can create GitHub Releases (fixes 403 error)

## [1.1.0] - 2026-03-10

### Added
- Configurable badge poll interval via Preferences with energy impact indicator
- Meeting notification scheduling for start and end of events
- Minute-level status bar time refresh for accurate relative time display
- `recalculateNextEvent()` for lightweight next-event updates without full refresh

### Changed
- Badge poll timer default increased from 1s to 3s; user-configurable (1s/3s/5s/10s)
- NoSleep countdown replaced with computed `timeRemaining` from stored `endTime`, eliminating 1 Hz timer
- `ActivitySimulator` fetches only `HIDIdleTime` instead of full IOKit dictionary
- Shared static `CIContext` in image transforms to avoid repeated GPU allocation
- Cached `DateFormatter` instances in `StatusBarController` and `MenuBuilder`
- Cached status bar icons (NoSleep, fallback "Bb") to prevent regeneration on every update
- Badge image rendering skipped when badge count is unchanged
- `NSWorkspace.runningApplications` query deferred unless `hideWhenNotRunning` is enabled
- Verbose `print` statements wrapped in `#if DEBUG` across all modules

## [1.0.0] - TBD

### Added
- Initial implementation of BusinessBar
- Meeting management with EventKit integration
- Badge monitoring with Accessibility API
- NoSleep functionality with IOKit power assertions
- StatusBarController with multiple NSStatusItems
- SwiftUI preferences window with 5 tabs
- 3-step onboarding flow
- App Intents for Spotlight integration
- Notification system with snooze support
- Meeting link detection for 50+ services
- Dynamic badge icon creation/destruction
- Two NoSleep modes (system-only, system+display)
- Duration options for NoSleep
- Activity simulation for "Away" prevention

### Architecture
- Swift 6 with strict concurrency
- Combine-based reactive data flow
- Protocol-oriented design
- Clear separation of concerns (App/Core/UI/Utilities)
- SPM dependency management

### Documentation
- Comprehensive README
- Implementation summary
- Development guide
- Contributing guidelines
- Design review document

### Dependencies
- Defaults 8.2.0
- KeyboardShortcuts 2.4.0
- LaunchAtLogin-Modern 1.1.0
- AppAuth 1.7.6
- Sparkle 2.9.0

---

## Version History

- **1.2.2** - KeyboardShortcuts Bundle.module crash fix, resource bundle signing
- **1.2.1** - Crash handler, preference live updates, String.truncated fix, UI reorg
- **1.2.0** - Configurable time rounding threshold, relative time minutes, CI PlistBuddy fix
- **1.1.2** - Improved coverage test, updated version management
- **1.1.1** - Removed credentials.local.json from SPM resources, added release workflow permissions
- **1.1.0** - CPU/energy optimizations, configurable badge polling, notification scheduling
- **1.0.0** - Initial implementation complete, pending first release
