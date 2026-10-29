# Changelog

All notable changes to BusinessBar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-10-29
### Added
- Local MLX reasoning discovery: after a model is downloaded (or checked before download), the app reads the model's own files, the chat template and config, and reports whether it supports reasoning and which controls it accepts. Two shapes exist: toggle models (Qwen3 family, template takes `enable_thinking`) and effort models (gpt-oss family, template takes `reasoning_effort` with low/medium/high). The Check card and the catalog rows show a brain icon with the summary, and requests to the local server send the right `chat_template_kwargs` instead of a `reasoning_effort` field the template never reads
- Granular command runner permissions: commands are classified into risk categories (read-only, file writes, file deletion, git changes, package managers, network, unclassified) and the Command Runner sheet in Preferences > Companion gains a per-category Ask/Allow/Deny dial on top of the session mode, plus persistent prefix rules. Deny rules win over everything, category dials override the session mode, and allow rules auto-approve what would otherwise ask. The approval card shows the command's category and targets, and gains an Always Allow button that persists a rule so the same command stops asking across sessions. A category set to Deny produces a plain denial that names the category in Preferences instead of a generic refusal
- Model-dependent reasoning effort options: the effort picker offers only the values the selected model supports. Local MLX models use the discovered effort levels, OpenRouter-style providers can be read live from their model list (a Fetch Models button in the provider sheet hits `GET {base}/models` and reads `supported_parameters`), and known name patterns (gpt-5, o1/o3/o4, gpt-oss) fill the gap. The pickers in the chat panel, model editor and template editor all follow the resolver, and a stored effort outside the model's options still shows so nothing reads as unset. Fetched rows add as models with the discovered vocabulary pinned and its default effort set automatically (Add All bulk-adds the same way), and the model editor builds effort lists as free-text chips for providers that publish nothing
- Template edit modal fix: all four Companion sheets (template, provider, ACP agent, model) are item-based now, so each edit presents a fresh editor for the exact target. The old isPresented binding plus separate state could keep the previous template's values when a quick reopen raced the dismiss animation, and a template saved from outside the tab (shortcut sync, migrations) could be clobbered by a save from the tab's stale copy. Both paths are gone: the sheets re-sync on store notifications and the tab's list reloads before saving
- Chat template layout tolerance: HF snapshots ship the chat template in three layouts (standalone `chat_template.jinja`, `chat_template.json`, a `chat_template` key in `tokenizer_config.json`), and a real Qwen3-VL snapshot here used the standalone jinja file with no key in its config. The snapshot inspector and the remote Check flow now read all three, so discovery works on every layout instead of silently reporting no capability
- Deletion-disguise hardening: `find -delete` (and find's interactive deleters, or `rm` piped through `xargs`) used to classify as read-only because the read-only allowlist ran before deletion-flag detection, so an Allow dial on read-only would auto-approve file deletion. Deletion flags now classify as file deletion and beat the allowlist

## [1.3.2] - 2026-10-29
### Added
- ACP agents as providers: the Providers section in Preferences > Companion adds three kinds, OpenAI-compatible endpoints, the local MLX server, and ACP agents over stdio, each with its own name and command line (for example `gemini --acp`). Multiple agents can coexist and switch from the same model pickers as models. The old Model Backend picker and its global command fields are gone; an existing global ACP config migrates into a provider entry once, keeping the stored command and arguments selected, so the panel never changes behavior on update
- Per-template companion model: every rewrite template can pin its own model in the template editor (grouped by provider, a Default chat model row applies when none is picked). Template shortcuts and rewrite streams use the pinned model's provider, API key and reasoning settings, templates pinned to a local MLX model start that server before streaming even when the selected chat model is remote, and a stale pinned id falls back to the selected model. The template list shows the pinned model under the template name
- Reasoning effort pickers gain a max level alongside none/low/medium/high/xhigh, everywhere efforts are chosen: per template, per model, and the global default
- Command runner permission modes: Allow, Ask, Deny replace the Auto-run (YOLO) toggle. The default lives in Preferences > Companion > Command Runner, the chat header switches it per session, and each new conversation resets to the default. Allow runs commands without asking but still prompts for rm and credentials files, Deny refuses every run_command (read_file and list_files keep working), Ask keeps the confirmation card. A denied call tells the model why and points it at the header picker instead of retrying

## [1.3.1] - 2026-10-29
### Fixed
- Chat input rework: long lines now wrap to the box width instead of clipping sideways, a scrollbar stays visible whenever the text overflows the box (before: nothing indicated there was more text), and the box scrolls to follow the caret while typing new lines. The composer is a native NSTextView now instead of a SwiftUI TextField, so Return still sends, Shift+Return and Option+Return still insert newlines, image paste/drop and focus-on-open keep working, and the tall/compact toggle and window-following height cap are unchanged
- Hard line breaks (Shift+Return) show a ¶ marker at the end of each typed line, and wrapped lines show a ↩ arrow at the left of each wrapped row, the CotEditor convention. A wrap never grows a paragraph mark, a typed break never grows an arrow, so the two always read differently. Marks sit next to the text (the arrow in a small left gutter, the pilcrow after the line's last glyph) instead of pinned to a fixed edge, and a row that both wraps onward and ends in Return carries both marks, one at each side
- Chat panel settings reach an open panel immediately: switching backend, picking a model, and toggling the tall input layout all announce the settings bus now, so gates and layout that depend on them (the YOLO toggle, the tall composer) refresh live instead of on next open
- The Auto-run (YOLO) toggle appears only when command tools are actually offered to the model: the Command Runner is enabled, the backend is OpenAI-compatible, and the selected model is not a local MLX server (mlx-lsp answers run_command by echoing arguments back, so YOLO there would report success for every command). The toggle also refreshes live while the panel is open when Preferences change, including picking a different model or switching to ACP
- The tall input toggle now sizes the box to one third of the panel height (was 45%), and the box starts at that height when toggled, not only growing up to it

## [1.3.0] - 2026-10-28
### Added
- LLM Companion: a rewrite shortcut for the selected text with configurable prompt templates, and a floating chat panel that works over fullscreen apps. Backends: any OpenAI-compatible API or an ACP agent over stdio (for example `gemini --acp`). Optional web search tool via Brave, Tavily, or a custom endpoint; keys live in the Keychain. Rewrite results are shown with Replace/Copy actions, never applied automatically
- Per-template rewrite shortcuts: every prompt template can have its own global shortcut that runs that rewrite on the selected text. The single rewrite-selection shortcut and its template picker are gone; the chat panel keeps the only predefined shortcut, now Cmd+B by default
- Chat panel rendering: assistant answers render as markdown (headings, code blocks, tables, clickable links, inline images) via MarkdownUI, user prompts stay verbatim in clearly separated bubbles. Responses stream live with a status line naming the current phase (Thinking, Writing, Searching the web), a stop button while generating, and an error banner with retry that re-sends the last prompt
- Reasoning display: `agent_thought_chunk` updates from ACP agents and `reasoning`/`reasoning_content` deltas from OpenAI-compatible streams stream into a collapsible Thinking block above the answer. It stays open while the model reasons, folds when the answer text starts, and the manual toggle wins over the automatic behavior. Thinking is persisted with the message, and reasoning never feeds the rewrite output
- Conversation history: every chat is saved to disk as its own JSON file under Application Support, so a crash or restart never loses the thread. The panel restores the most recent conversation on open, and a history drawer lists past sessions (title from the first prompt) to reopen or delete them; a corrupted file is skipped, not fatal. The drawer can delete by age (7/30/90 days) or all at once with confirmation, and Preferences > Companion auto-cleans by age or session count on startup and after each saved reply
- Model profiles: named endpoint presets (name, base URL, model, default reasoning effort, API key in the Keychain per profile) manageable in Preferences > Companion. The chat panel gets a picker to switch profiles mid-conversation, existing users get their current configuration seeded as the first profile automatically
- Providers with multiple models: the flat model profile list becomes providers (name, base URL, Keychain key) each holding any number of models (name, model string, default effort) manageable in Preferences > Companion. The chat picker groups models under their provider. Existing profiles migrate on first launch keeping their ids, so stored API keys keep working; the old blob stays on disk untouched
- Providers fully own the OpenAI backend: the old Model Backend fields (base URL, model, API key, system prompt, reasoning, headers) are gone from Preferences, replaced by the providers list. Request headers are edited per provider in its sheet, the system prompt and the Reasoning checkbox live per model, and the Reasoning checkbox gates an effort picker that also accepts custom values. The main settings gain a default chat model picker. Existing flat configuration attaches to providers once on first load, so nothing is lost when the section disappears
- Reasoning effort per request: each rewrite template can set its own effort in the template editor (Default, none/low/medium/high/xhigh, or a custom value) which overrides the global one for that request; the global picker in Preferences also accepts custom values now
- Model backend options for reasoning deployments: a reasoning toggle with an effort level (none/low/medium/high/xhigh, sent as `reasoning_effort`) and custom HTTP headers on every chat request (stored in the Keychain, overriding the built-in Authorization when named explicitly)
- Web search without API keys: DuckDuckGo, Bing and Google News providers scrape the public pages and fall back to each other when one engine blocks the request, so the tool works with zero configuration
- Links from ACP agents render as clickable markdown: `resource_link` content blocks were silently dropped by the update mapper, and now become `[label](uri)` (label prefers the title, then the name, then the bare URI). Chat links open only http, https, mailto and tel schemes; anything else a model emits stays inert
- Logging through the rewrite path (capture, stream errors, overlay present, replace success or fallback, copy, dismiss) under the Companion category, so failures are visible in Console and `log show` instead of dying silently
- Raw output capture for rewrites: default templates instruct the model to wrap the result in <output></output> tags and show a worked example, and the app extracts only the tagged text for the Replace/Copy overlay. Replies without tags get a leading commentary line ("Here's what I fixed:") stripped as fallback, so the overlay and the replaced text stay free of model chatter. Stored templates are migrated to the new format once when they are still byte-identical to a shipped default; edited templates are left alone
- Accessibility permission management in Preferences > Companion, matching the Badges tab: granted/required status, Open System Settings, and Request Permission buttons, refreshed automatically when the app returns to front. The rewrite shortcuts need this permission to read the selected text
- Feedback for actions and settings: a small toast appears when a template shortcut fires ("Rewriting with <template>…") and again when the rewrite result is ready, plus errors that previously went nowhere visible. Preferences now flash a Saved indicator bottom-right whenever a change is stored, covering UserDefaults settings automatically and Keychain/file-backed ones through explicit signals
- Command tools: the model can run shell commands inside a working dir. Read-only commands auto-approve, mutations ask, rm and credentials files always prompt, escape outside the workspace is rejected, and background processes are tracked and folded back into the conversation. The Auto-run (YOLO) toggle skips the asking within the same guardrails
- Tools section in Preferences > Companion: web search, command runner, and GitHub code search are provided tools that cannot be removed, only toggled on or off, each with its own Configure sheet. Web search keeps its provider picker and gains per-header configuration for custom endpoints; command runner holds the default working dir new sessions start from; GitHub code search is off until you paste a token (fine-grained PAT, no permissions needed for public code search), and the tool is only advertised to the model when the toggle is on and a token exists
- On-device MLX local models: the Add Local Models popup in Preferences > Companion runs an `mlx-lm` server on 127.0.0.1 (default port 8790) as a managed child process, spawned as the resolved uv venv python so a single stop fully unloads the model. Six curated models (Llama 3.2 1B/3B, Qwen3 0.6B/4B/8B, Qwen2.5-Coder 7B) with fit pills against installed RAM, downloads only from an explicit Download button (never automatic, enforced with `HF_HUB_OFFLINE=1` on the server), progress by cache size with cancel, and delete with freed-byte count. The server stops after 5 idle minutes by default (configurable, or Keep loaded to hold it), and critical memory pressure or serious thermal load stops an idle server early. A Local (MLX) chat profile points at the endpoint, starts the server on demand before each message, and needs no API key
- Live MLX model browsing: a Browse more models button in the local models sheet fetches the current mlx-community chat catalog from Hugging Face (text-generation and image-text-to-text repos, so Whisper, TTS and embedding models are filtered out). Each row shows the model's kind pill, fit pill against your RAM, download count and download size, with a Text / Text + Images filter and a sort by size or downloads. Add registers the repo in your catalog; downloading still only happens from its explicit Download button, and only Browse touches the network
- Custom MLX model provisioning: paste any MLX-format Hugging Face repo id (e.g. mlx-community/Model-4bit) under the model catalog and press Check. The check fetches the repo's metadata and config.json, verifies the weights are MLX-format (safetensors, not PyTorch), infers text vs image input from the architecture, and shows the display name, download size, RAM estimate with fit pill, architecture, token context, and quantization before you add it. Added entries behave like curated ones: explicit Download, Use to activate, Delete removes both weights and the entry. Only the Check button touches the network
- The local MLX catalog now lists each model's type (Text or Text + Images) and adds two vision models that fit 16GB RAM: Qwen3-VL 2B (1.7GB download) and Qwen3-VL 4B (3.1GB). Vision models are served by mlx-vlm's OpenAI-compatible server while text models keep mlx-lm, resolved per model with one server running at a time
- Image inputs for chat: models declare what they accept (a Text tickbox on by default and an Images tickbox off by default in the model editor), and when the selected model takes images the chat input grows a paperclip button plus drag-and-drop and paste support. Attached images show as removable thumbnails, travel with the message as base64 data URIs, render inside user bubbles, and history keeps them
- Rewrite template actions: besides the overlay, a template can now Replace the selection or Insert after the selection when the reply carries <output> tags. The old direct-replace toggle maps to Replace. Both direct actions fall back to the overlay when the target app does not support in-place writes, so a result is never lost. New default template Format for Slack rewrites text as Slack mrkdwn and inserts it after the selection; Slack also gets the Accessibility nudge so selection capture works there without the clipboard roundtrip
- Chat panel controls: a model picker and an effort picker above the input apply to the next message, Cmd+N starts a new session (cancelling any stream in flight, so stale completions can never land in the fresh conversation), and the latest prompt bubble has an Edit button that pulls the prompt back into the composer, truncating the thread so the edited version resends cleanly over the remaining history
- Close-chat button: it ends the current conversation and starts a new one in its place, the closed chat stays in history under the configured cleanup rules (age and session count from Preferences), and the button is disabled when there is nothing to close
- Expandable chat input: an arrow button left of the paperclip toggles between the compact input and a tall one, the choice is remembered across restarts, the editor scrolls when the text outgrows the field, and the tall layout grows with the panel (capped at 45 percent of the window, 160pt floor) instead of a fixed line count
- Multi-line composer: Shift+Return and Option+Return insert a newline in the chat input; plain Return still sends
- Chat header row: the new-chat and history buttons sit at the top of the panel, the header is always visible, and the working dir moved to the model row right after the Model and Effort pickers, keeping every per-conversation choice on one line. The header keeps the YOLO toggle when command tools are active
- Each rewrite template row in Preferences gets a delete button; the swipe-only delete gesture never worked on macOS forms. Deleting a template also clears its recorded shortcut
- Test seams for harness coverage: ChatSessionStore accepts an explicit directory (the shared instance keeps the default Application Support location), the uv/python resolution paths and the search response parsing helpers are reachable from harnesses, so the coverage suite can drive the process and network layers against fakes instead of real downloads. Eighteen harnesses reach 94.1 percent line coverage of Core Companion (4571/4859) with no real downloads, no live endpoints, no real MLX servers

### Fixed
- ACP agent chats no longer hang forever after the agent finishes a turn: the client never resolved the session/prompt response, so the stream stayed open with the spinner running and the panel stuck on isStreaming. Turn responses now resolve the prompt continuation and end the stream with the agent's stop reason
- Crash when using Replace in the rewrite overlay: the controller ran a background Task that wrote to the pasteboard and ordered out the panel off the main thread, and SwiftUI touching the main menu from that thread killed the app with an NSInternalInconsistencyException. The overlay controller is now MainActor like the chat panel controller, and it no longer calls NSApp.activate, which was also stealing key focus from the app being rewritten and breaking the AX replace itself
- Replace failed in editors that reject AX writes, like CotEditor: the AX write now walks ancestor elements like the capture does, the value rewrite counts UTF-16 units instead of UTF-8 for the selected range, and a synthetic Cmd+V with clipboard snapshot/restore is the last resort. The user's clipboard contents survive the paste fallback
- The Replace button beeped and nothing happened: the overlay panel was still the key window while the replace ran, so the AX write targeted our own panel and the synthetic Cmd+V landed in a window with no Paste target. The overlay now dismisses before replacing, reactivates the app that owned the selection, and the paste keystroke is posted the way Maccy and Clipy do it: combined-session source, local keys filtered during suppression, annotated session tap, key equivalent taken from the app's own Edit menu. The copy fallback also survives the panel being gone
- The chat input scrolls when the text outgrows the field and the tall input grows with the panel: the editor is capped at 45% of the window (160pt floor) instead of a fixed line count, so enlarging the window gives the composer more room instead of clipping it

### Changed
- The chat panel shows a Submitting… status row with a spinner and turns the send button into a stop button the moment you submit, covering the server warm-up window (local MLX server start, first vision-model load) where previously nothing in the panel moved after pressing send with an image. The button cancels the submission before the stream starts and stops generation afterwards
- Local model rows show Use and Delete after download instead of only Delete: previously the Use button only appeared before downloading, so a downloaded model could never be activated, which also left the Add chat provider button permanently disabled. Use activates the model and creates the Local (MLX) chat provider in one step, and the now-redundant Add chat provider button is gone
- The chat header's Working dir control is the folder picker: the whole label with the folder icon opens the chooser, replacing the small arrow button beside it, and the Command Runner Configure sheet uses the same folder icon for its default working dir picker
- The composer's paperclip is always visible. When the selected model takes text only, clicking it explains that and how to pick an image-capable model, instead of the button silently disappearing
- The Providers section gains an Add Local Models button that opens the on-device MLX setup (server controls, model catalog with explicit downloads, settings) as a popup instead of a long inline section, and the providers list refreshes when it closes so the local provider appears immediately

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
