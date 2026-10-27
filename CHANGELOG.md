# Changelog

All notable changes to BusinessBar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Logging through the rewrite path (capture, stream errors, overlay present, replace success or fallback, copy, dismiss) under the Companion category, so failures are visible in Console and `log show` instead of dying silently
- Per-template direct replace: a template can opt in to replace the selection in place, skipping the overlay, when the model reply carries the <output></output> tags and the selection was captured over Accessibility. Untagged replies, clipboard captures and failed writes all fall back to the overlay, so a result is never lost. Existing templates keep the overlay behavior until the toggle is enabled
- Raw output capture for rewrites: default templates instruct the model to wrap the result in <output></output> tags and show a worked example, and the app extracts only the tagged text for the Replace/Copy overlay. Replies without tags get a leading commentary line ("Here's what I fixed:") stripped as a fallback, so the overlay and the replaced text stay free of model chatter. Stored templates are migrated to the new format once when they are still byte-identical to a shipped default; edited templates are left alone
- Each rewrite template row in Preferences gets a delete button; the swipe-only delete gesture never worked on macOS forms. Deleting a template also clears its recorded shortcut
- Accessibility permission management in Preferences > Companion, matching the Badges tab: granted/required status, Open System Settings, and Request Permission buttons, refreshed automatically when the app returns to front. The rewrite shortcuts need this permission to read the selected text
- Feedback for actions and settings: a small toast appears when a template shortcut fires ("Rewriting with <template>…") and again when the rewrite result is ready, plus errors that previously went nowhere visible. Preferences now flash a Saved indicator bottom-right whenever a change is stored, covering UserDefaults settings automatically and Keychain/file-backed ones through explicit signals
- Conversation history: every chat is saved to disk as its own JSON file under Application Support, so a crash or restart never loses the thread. The panel restores the most recent conversation on open, and a history drawer lists past sessions (title from the first prompt) to reopen or delete them; a corrupted file is skipped, not fatal. The drawer can delete by age (7/30/90 days) or all at once with confirmation, and Preferences > Companion auto-cleans by age or session count on startup and after each saved reply
- Chat panel rendering overhaul: assistant answers render as markdown (headings, code blocks, tables, clickable links, inline images) via MarkdownUI, user prompts stay verbatim in clearly separated bubbles. Responses stream live with a status line naming the current phase (Thinking, Writing, Searching the web), a stop button while generating, and an error banner with retry that re-sends the last prompt
- Per-template rewrite shortcuts: every prompt template can have its own global shortcut that runs that rewrite on the selected text. The single rewrite-selection shortcut and its template picker are gone; the chat panel keeps the only predefined shortcut, now Cmd+B by default
- Model backend options for reasoning deployments: a reasoning toggle with an effort level (none/low/medium/high/xhigh, sent as `reasoning_effort`) and custom HTTP headers on every chat request (stored in the Keychain, overriding the built-in Authorization when named explicitly)
- LLM Companion: a rewrite shortcut for the selected text with configurable prompt templates, and a floating chat panel that works over fullscreen apps. Backends: any OpenAI-compatible API or an ACP agent over stdio (for example `gemini --acp`). Optional web search tool via Brave, Tavily, or a custom endpoint; keys live in the Keychain. Rewrite results are shown with Replace/Copy actions, never applied automatically
- Web search without API keys: DuckDuckGo, Bing and Google News providers scrape the public pages and fall back to each other when one engine blocks the request, so the tool works with zero configuration

### Fixed
- Crash when using Replace in the rewrite overlay: the controller ran a background Task that wrote to the pasteboard and ordered out the panel off the main thread, and SwiftUI touching the main menu from that thread killed the app with an NSInternalInconsistencyException. The overlay controller is now MainActor like the chat panel controller, and it no longer calls NSApp.activate, which was also stealing key focus from the app being rewritten and breaking the AX replace itself
- Replace failed in editors that reject AX writes, like CotEditor: the AX write now walks ancestor elements like the capture does, the value rewrite counts UTF-16 units instead of UTF-8 for the selected range, and a synthetic Cmd+V with clipboard snapshot/restore is the last resort. The user's clipboard contents survive the paste fallback
- The Replace button beeped and nothing happened: the overlay panel was still the key window while the replace ran, so the AX write targeted our own panel and the synthetic Cmd+V landed in a window with no Paste target. The overlay now dismisses before replacing, reactivates the app that owned the selection, and the paste keystroke is posted the way Maccy and Clipy do it: combined-session source, local keys filtered during suppression, annotated session tap, key equivalent taken from the app's own Edit menu. The copy fallback also survives the panel being gone

## [1.2.5] - 2026-10-17
### Fixed
- Hidden badge icons no longer leave an empty spacer in the menu bar. Collapsing via `NSStatusItem.length = 0` still renders the button's ~2px padding, so an app hidden by "Hide when no notifications" showed up as a gap between its neighbours. Hidden items are now removed from the status bar and recreated when the app becomes visible again. Removal happens only when the hidden/shown state flips, so badge polling causes no extra work

## [1.2.4] - 2026-10-17
### Fixed
- Released DMGs now include an `/Applications` symlink next to the app, so the mounted image supports drag-to-Applications install. `hdiutil` was imaging the `.app` alone in both `bundle_app.sh` and the release workflow's separate DMG step; both now stage the app in a temp dir with the symlink before imaging
- The release workflow now creates the DMG through `bundle_app.sh` (single build + bundle + DMG call) instead of its own `hdiutil` invocation, so local and CI DMGs are built identically

## [1.2.3] - 2026-10-17
### Fixed
- Bundled OAuth credentials: `bundle_app.sh` still looked for the built resources at the old SwiftPM llbuild layout while the toolchain emits SwiftBuild's `.build/out/Products`, so real Google OAuth values were never injected and the app shipped with placeholders. Both layouts are now resolved
- `Package.swift` no longer passes `Assets.xcassets` to SwiftPM: `.process` on a catalog forces an `actool` invocation that only exists in full Xcode, breaking Command Line Tools-only builds. The catalog is unused at runtime (icons render from SF Symbols, app icon ships as `AppIcon.icns`)

### Added
- Local Command Line Tools-only builds: `scripts/swift-clt-plugins.sh` auto-injects the SwiftUI macro plugin dylibs (`libSwiftUIMacros`, `libPreviewsMacros`, Xcode-only files) via `-plugin-path` when CLT is the active developer dir, silent under full Xcode or once CLT ships them natively
- `Refresh Swift Macro Plugins` CI workflow (manual dispatch): re-stashes the plugin dylibs from a GitHub-hosted Xcode into a 90-day artifact, so updating the local toolchain no longer requires owning Xcode

### Changed
- CI runners moved to the `xcode-27` image (macOS 27, Xcode 27, Swift 6.4); stale `setup-xcode` pins updated to match

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
