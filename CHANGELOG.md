# Changelog

All notable changes to BusinessBar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

- **1.1.1** - CI workflow fixes: SPM resource warning and release permissions
- **1.1.0** - CPU/energy optimizations, configurable badge polling, notification scheduling
- **1.0.0** - Initial implementation complete, pending first release
