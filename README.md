# BusinessBar

A unified macOS menu bar application combining three essential functionalities:

1. **Next Meeting** — Shows upcoming calendar events with countdown, one-click join, and notifications
2. **Notification Badges** — Surfaces dock icon badges for selected apps as menu bar icons
3. **NoSleep** — Prevents the computer from sleeping with configurable duration and modes

## Features

### Meeting Management
- 📅 Shows next upcoming calendar event with live countdown
- 🔗 One-click join for 50+ meeting services (Zoom, Meet, Teams, etc.)
- 🔔 Customizable notifications with snooze support
- 📆 EventKit (macOS Calendar) and Google Calendar support

### Notification Badges
- 🔴 Displays dock notification badges in the menu bar
- 👆 Click badge icons to open/focus the app
- ✨ Auto-appear when badges appear, auto-disappear when cleared
- 🎯 User-selectable apps to monitor

### NoSleep
- ☕️ Prevents system sleep with configurable duration
- ⚙️ Two modes: system-only or system+display
- ⏱️ Duration options: 15min, 30min, 1h, 2h, 5h, or indefinite
- 💡 Optional activity simulation to prevent "Away" status

### LLM Companion
- ⌨️ Per-template rewrite shortcuts: each prompt template gets its own global shortcut for the selected text, with a toast confirming the trigger and the result
- ✅ Preferences show a Saved indicator after every change is stored (UserDefaults, Keychain and file-backed settings included), and the Companion tab has the same Accessibility permission check and management as the Badges tab
- 💬 Floating chat panel that works over fullscreen apps, with markdown rendering (headings, code blocks, tables, links, images), a streaming response with a live status line, and retry on errors. The send button turns into a stop button the moment you submit: it shows Submitting while the local server warms up, and stops generation once the stream runs. The chat input is a native composer: text wraps to the box width, a scrollbar stays visible when the text overflows, and the box follows the caret while you type. An arrow button next to the paperclip toggles a tall input for longer prompts, the panel remembers the choice, and the tall input grows with the window; Shift+Return and Option+Return insert newlines while plain Return sends
- 🔀 Providers: three kinds side by side, OpenAI-compatible endpoints (base URL, Keychain key, headers) holding multiple models (system prompt, reasoning toggle, effort with custom values), the local MLX server, and ACP agents over stdio with their own command line; switch mid-conversation from the chat picker; existing setup migrates automatically and the old backend section is gone
- ✍️ Rewrite actions: templates can replace the selection, insert the reply right after it, or show the overlay; Format for Slack template emits Slack mrkdwn
- 🎚️ Per-request reasoning effort: pick it per rewrite template, per model, or per chat message, custom values included
- ✏️ Edit last prompt: an Edit button on the latest prompt bubble pulls your previous question back into the editor, tweak it, and resend over the remaining history; Cmd+N starts a fresh session
- 💭 Collapsible thinking block: reasoning from ACP agents and OpenAI-compatible reasoning models streams live above the answer, folds once the answer starts, and stays with the saved message
- 🔗 Agent links render as clickable markdown, and chat links open only http, https, mailto and tel schemes
- 🗂️ Conversation history: sessions are saved on disk and restored on restart, so you can pick up any past chat and continue it. Cleanup by age or all at once from the history drawer, plus auto-clean by age or session count in Preferences. A close-chat button in the header ends the current conversation and starts a new one, the closed chat stays in history; the history toggle sits next to it, left of the working dir
- 🔌 OpenAI-compatible API or any ACP agent (Gemini, Claude, Codex) over stdio
- 🧠 Reasoning models: reasoning effort level and custom HTTP headers for gateway deployments
- 🛠️ Tools section in Preferences: provided tools (web search, command runner, GitHub code search) are never removable, only toggled on or off, each with a Configure sheet for its settings
- 🌐 Optional web search tool: DuckDuckGo, Bing, or Google News (scraped, no key, with engine fallback) or Brave, Tavily, or a custom endpoint (API key); the custom endpoint takes URL templates with {query} and {count} for GET mode plus any number of headers, or the legacy JSON POST mode
- 🐙 GitHub code search tool: token-gated (fine-grained PAT, no permissions needed for public code search), capped at 5 results per query, and only advertised to the model when both the toggle and the token are set
- 🖥️ Command tools: run_command, read_file, and list_files scoped to the working dir shown in the chat header (default set in the Command Runner Configure sheet, click the dir label to switch it per session); read-only commands run without asking, everything else shows a confirmation card, and Auto-run (YOLO) skips the prompts (rm and credentials files still ask)
- 🖼️ Image inputs: models opt in with the Images tickbox (Text is on by default); once a model accepts images the chat input grows a paperclip, drag-and-drop, and paste. Two Qwen3-VL models in the local MLX catalog take images and fit 16GB RAM
- ➕ Custom MLX models: paste any MLX-format Hugging Face repo id, Check fetches the tech details (architecture, token context, quantization, sizes, fit) before you add it, then it downloads and serves like any curated model
- 🌐 Live MLX browsing: Browse more models in the local models sheet lists the current mlx-community chat catalog from Hugging Face with Text / Text + Images filters, download counts and sizes, and a sort by size or downloads; Add registers a repo, its Download button stays the only thing that fetches weights
- 🔑 API keys stored in the Keychain
- 🔒 The chat panel and rewrite overlay never replace your text automatically; you choose Replace or Copy

## Requirements

- macOS 14.0 (Sonoma) or later
- Building: Command Line Tools alone suffice. Full Xcode is optional; see
  DEVELOPMENT.md ("Building with Command Line Tools only") for the SwiftUI
  macro plugin setup. Running the XCTest suite still needs Xcode.
- Updating the plugin stash after major CLT/SDK updates: full Xcode briefly,
  or the "Refresh Swift Macro Plugins" GitHub workflow (no local Xcode).

## Installation

### From Source

```bash
git clone https://github.com/yourusername/businessbar.git
cd businessbar

# Set up Google Calendar credentials (required for Google Calendar support)
cp BusinessBar/Resources/credentials.local.json.example \
   BusinessBar/Resources/credentials.local.json
# Edit credentials.local.json with your Google OAuth values (see below)

# Build and run
swift run
```

Or build a standalone `.app` bundle:

```bash
./bundle_app.sh                        # snapshot build → BusinessBar.app
./bundle_app.sh 1.2.0 42              # versioned release build (CI)
./bundle_app.sh dmg                    # snapshot build + DMG
```

### Google Calendar Credentials

BusinessBar supports Google Calendar via OAuth 2.0. The credentials are **never hardcoded** in source — they're loaded at runtime from JSON files and injected at build time by CI.

#### Obtaining the OAuth Credentials

1. Go to the [Google Cloud Console](https://console.cloud.google.com/) and create a new project (or select an existing one)
2. Enable the **Google Calendar API**:
   - Navigate to **APIs & Services → Library**
   - Search for "Google Calendar API" and click **Enable**
3. Configure the OAuth consent screen:
   - Navigate to **APIs & Services → OAuth consent screen**
   - Choose **External** (unless you have a Google Workspace account and want Internal)
   - Fill in the required fields (App name, User support email, Developer contact email)
   - Under **Scopes**, add:
     - `email`
     - `.../auth/calendar.calendarlist.readonly`
     - `.../auth/calendar.events.readonly`
   - Add your email as a **Test User** (required while the app stays in "Testing" mode)
4. Create OAuth 2.0 credentials:
   - Navigate to **APIs & Services → Credentials**
   - Click **Create Credentials → OAuth client ID**
   - Application type: **Desktop app**
   - Name it (e.g. "BusinessBar")
   - Click **Create** — you'll see your **Client ID** and **Client Secret**
5. Extract the values BusinessBar needs:
   - **`google_client_number`** — the numeric prefix of the Client ID before `.apps.googleusercontent.com`. For example, if the Client ID is `12345678.apps.googleusercontent.com`, the client number is `12345678`
   - **`google_client_secret`** — the Client Secret value shown on the credentials page (e.g. `GOCSPX-XXXXXXXXX`)

#### Local Development Setup

Copy the example file and fill in your credentials:

```bash
cp BusinessBar/Resources/credentials.local.json.example \
   BusinessBar/Resources/credentials.local.json
```

Edit `BusinessBar/Resources/credentials.local.json`:

```json
{
    "google_client_number": "12345678",
    "google_client_secret": "GOCSPX-XXXXXXXXX",
    "sparkle_appcast_url": "",
    "sparkle_public_ed_key": ""
}
```

The `sparkle_appcast_url` and `sparkle_public_ed_key` fields are optional — leave them empty for local development. They're only needed when building a distributable `.app` with Sparkle auto-updates enabled.

This file is **gitignored** and takes precedence over the placeholder `credentials.json` at runtime. When you run `swift run` or `./bundle_app.sh`, the app loads credentials from `credentials.local.json` first.

> **Note:** The `Info.plist` URL scheme (`com.googleusercontent.apps.YOUR_GOOGLE_CLIENT_NUMBER`) is also patched automatically by `bundle_app.sh` at build time. For `swift run` or `make run`, the redirect is handled by the app's URL event handler regardless. Under Command Line Tools without full Xcode use `make run` (or `./bundle_app.sh`); a bare `swift run` misses the SwiftUI macro plugin flags, see [DEVELOPMENT.md](/DEVELOPMENT.md).

#### GitHub Actions Configuration

For CI builds, configure these repository secrets and variables:

**Secrets** (sensitive values, never shown in logs):

| Secret | Description |
|--------|-------------|
| `GOOGLE_CLIENT_NUMBER` | The Google OAuth client number (e.g. `12345678`) |
| `GOOGLE_CLIENT_SECRET` | The Google OAuth client secret (e.g. `GOCSPX-XXXXXXXXX`) |
| `SPARKLE_PUBLIC_ED_KEY` | The Sparkle EdDSA public key for update verification (e.g. `abcdef123456...`) |

**Variables** (non-sensitive values, visible in logs):

| Variable | Description |
|----------|-------------|
| `SPARKLE_APPCAST_URL` | The URL to your Sparkle appcast XML file (e.g. `https://your-host.example.com/businessbar/appcast.xml`) |

**To configure:**

1. Go to your repository on GitHub
2. Navigate to **Settings → Secrets and variables → Actions**
3. Under **Secrets**, click **New repository secret** for each secret above
4. Under **Variables**, click **New repository variable** for each variable above

The [Build](/.github/workflows/build.yml) and [Release](/.github/workflows/release.yml) workflows inject Google credentials into `credentials.json` and patch the `Info.plist` URL scheme at build time. If the Sparkle variables are set, they also patch `SUFeedURL` and `SUPublicEDKey` in `Info.plist`. Any `.local.json` is removed from the `.app` bundle.

#### Sparkle Auto-Update Setup

BusinessBar uses [Sparkle 2](https://sparkle-project.org/) for in-app updates. To set up auto-updates:

1. **Generate an EdDSA key pair:**
   ```bash
   # Install Sparkle's generate_keys tool (bundled with Sparkle.framework)
   .build/release/Sparkle.framework/Versions/B/XPCServices/Updater.app/Contents/Frameworks/SparkleCore.framework/Versions/A/generate_keys
   ```
   Or download the `generate_keys` utility from the [Sparkle releases](https://github.com/sparkle-project/Sparkle/releases). This saves the private key to your Keychain and prints the public key — set `SPARKLE_PUBLIC_ED_KEY` to that value.

2. **Host an appcast XML file** at a public URL. The appcast lists available versions with download URLs and EdDSA signatures. Set `SPARKLE_APPCAST_URL` to this URL.

3. **Sign updates locally** using Sparkle's `sign_update` tool:
   ```bash
   sign_update BusinessBar-1.2.0.dmg
   # Outputs the EdDSA signature and length to add to your appcast entry
   ```

For full documentation, see the [Sparkle guide](https://sparkle-project.org/documentation/).

#### Credential Resolution Order

At runtime, `CredentialLoader` resolves credentials in this order:

1. `credentials.local.json` — local dev override (gitignored, never shipped)
2. `credentials.json` — bundled default (placeholder in source, real values injected by CI or `bundle_app.sh`)
3. Fallback — `YOUR_GOOGLE_CLIENT_NUMBER` / `YOUR_GOOGLE_CLIENT_SECRET` (detected as unconfigured)

When the values start with `YOUR_`, `GoogleAuthConfig.isConfigured` returns `false` and the Google Calendar option is hidden from the UI.

### Permissions

BusinessBar requires the following permissions:
- **Calendar Access** — To read your calendar events
- **Notifications** — To send meeting reminders
- **Accessibility** (optional) — To read dock badges and simulate activity; the LLM Companion also uses it to read the selected text for rewrites

## Usage

1. Launch BusinessBar
2. Grant Calendar and Notification permissions during onboarding
3. Select which calendars to monitor in Preferences
4. (Optional) Add apps to monitor for notification badges
5. (Optional) Grant Accessibility permission for badge monitoring
6. (Optional) Configure the LLM Companion: enable it in Preferences, then add
   providers. Three kinds exist: OpenAI-compatible (base URL, API key,
   headers) with models under it (model string, system prompt, Reasoning
   toggle with effort), the local MLX server (Add Local Models opens its
   setup), and ACP agents over stdio with their own command line (for
   example `gemini --acp`). Pick the default chat model or agent, record
   the chat panel shortcut (Cmd+B by default) and
   assign a shortcut to each rewrite template you want. Default templates
   ask the model to wrap the result in `<output></output>` tags; the overlay
   shows only the tagged text, with no model commentary. A template can also
   pick a direct action: Replace swaps the tagged reply into the selection in
   place, and Insert after selection writes it right after the caret, falling
   back to the overlay when the app does not support in-place writes. The
   Format for Slack template asks for Slack mrkdwn and inserts after the
   selection
7. (Optional) On-device models: install uv (`brew install uv`), then open
   Preferences > Companion and press Add Local Models in the providers
   section. Download one of the curated MLX
   models (nothing downloads until you press Download), press Use to
   activate it (this also creates the Local (MLX) chat model), and chat
   without any API key; the server starts on the first message. Text models serve
   through mlx-lm and the two Qwen3-VL vision models through mlx-vlm, picked
   per model automatically. The server stops
   itself after 5 idle minutes and the next message starts it again. Add more
   models under the same provider or more providers in Preferences >
   Companion; existing model profiles migrate to the new providers layout on
   first launch

## Architecture

BusinessBar is built with:
- **Swift 6** with strict concurrency
- **AppKit** for menu bar integration (NSStatusItem)
- **SwiftUI** for preferences and onboarding UI
- **Combine** for reactive data flow
- **EventKit** for calendar access
- **IOKit** for power assertions
- **Accessibility API** for dock badge reading
- **AppAuth** for Google OAuth 2.0 authentication
- **ACP** (Agent Client Protocol) over JSON-RPC stdio for the companion's agent backend
- **URLSession byte streams** for OpenAI-compatible SSE streaming
- **CredentialLoader** — JSON-based credential system (`.local.json` override → `.json` default → placeholder fallback)
- **AppLogger** — structured logging via OSLog + rotating file logs (`~/Library/Logs/BusinessBar/`)
- **Sparkle** for in-app auto-updates
- **Gitleaks** via pre-commit for secret detection on push

## License

MIT NON-AI License - See LICENSE file for details

## Secret Detection (Gitleaks)

To prevent secrets from being pushed, set up [Gitleaks](https://github.com/gitleaks/gitleaks) via [pre-commit](https://pre-commit.com/):

### 1. Install pre-commit

```bash
# macOS
brew install pre-commit

# or pip
pip install pre-commit
```

### 2. Create `.pre-commit-config.yaml` at the repo root

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.3  # or run: pre-commit autoupdate
    hooks:
      - id: gitleaks
        stages: [pre-push]  # runs on push, not commit
```

### 3. Install the hook

```bash
pre-commit install --hook-type pre-push
```

Gitleaks will now scan for secrets on every `git push`.

## Credits

Inspired by:
- [MeetingBar](https://github.com/leits/MeetingBar)
- [Doll](https://github.com/xiaogdgenuine/Doll)
- [Caffeinated](https://github.com/evanriley/Caffeinated)

Third-party libraries:
- [Defaults](https://github.com/sindresorhus/Defaults) — Copyright © Sindre Sorhus (MIT)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — Copyright © Sindre Sorhus (MIT)
- [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) — Copyright © Sindre Sorhus (MIT)
- [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) — Copyright © OpenID contributors (Apache 2.0)
- [Sparkle](https://github.com/sparkle-project/Sparkle) — Copyright © Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd Ranch (MIT)
