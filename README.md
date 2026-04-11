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

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later for building

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
./bundle_app.sh              # debug build → BusinessBar.app
./bundle_app.sh release      # release build → BusinessBar.app
./scripts/bundle_app.sh 1.2.0 42   # versioned release build
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

> **Note:** The `Info.plist` URL scheme (`com.googleusercontent.apps.YOUR_GOOGLE_CLIENT_NUMBER`) is also patched automatically by `bundle_app.sh` at build time. For `swift run`, the redirect is handled by the app's URL event handler regardless.

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
- **Accessibility** (optional) — To read dock badges and simulate activity

## Usage

1. Launch BusinessBar
2. Grant Calendar and Notification permissions during onboarding
3. Select which calendars to monitor in Preferences
4. (Optional) Add apps to monitor for notification badges
5. (Optional) Grant Accessibility permission for badge monitoring

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
