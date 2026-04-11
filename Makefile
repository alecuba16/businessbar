# Makefile for BusinessBar

.PHONY: all build release app app-release install uninstall dmg run clean setup xcode test help

APP_NAME  = BusinessBar
INSTALL   = /Applications/$(APP_NAME).app
DEBUG_BIN = .build/debug/$(APP_NAME)

# ── Default ────────────────────────────────────────────────────────────────────
all: app

# ── Swift build ────────────────────────────────────────────────────────────────
build:
	@echo "Building $(APP_NAME) (debug)…"
	@swift build
	@echo "Done → $(DEBUG_BIN)"

release:
	@echo "Building $(APP_NAME) (release)…"
	@swift build -c release
	@echo "Done → .build/release/$(APP_NAME)"

# ── .app bundle ────────────────────────────────────────────────────────────────
# Produces BusinessBar.app in the project root.
# bundle_app.sh builds release internally and auto-detects version from git
# (e.g. 1.1.1-snapshot+7.abc1234).  No separate swift build needed.
app:
	@./bundle_app.sh

# Alias for backward compatibility — identical to `make app`.
app-release:
	@./bundle_app.sh

# ── Install / uninstall ────────────────────────────────────────────────────────
install: app-release
	@echo "Installing to $(INSTALL)…"
	@rm -rf "$(INSTALL)"
	@cp -R "$(APP_NAME).app" "$(INSTALL)"
	@echo "Installed → $(INSTALL)"

uninstall:
	@echo "Removing $(INSTALL)…"
	@rm -rf "$(INSTALL)"
	@echo "Done"

# ── DMG ────────────────────────────────────────────────────────────────────────
# Creates a versioned DMG (e.g. BusinessBar-1.1.1-snapshot.dmg).
dmg:
	@./bundle_app.sh dmg

# ── Run ────────────────────────────────────────────────────────────────────────
run: app
	@open "$(APP_NAME).app"

# ── Tests ─────────────────────────────────────────────────────────────────────
test:
	@echo "Running tests…"
	@swift test

# ── Utilities ─────────────────────────────────────────────────────────────────
setup:
	@echo "Resolving dependencies…"
	@swift package resolve
	@echo "Done"

xcode:
	@xed .

clean:
	@echo "Cleaning…"
	@rm -rf .build .swiftpm $(APP_NAME).app $(APP_NAME).dmg
	@echo "Done"

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@echo "BusinessBar — available targets"
	@echo ""
	@echo "  make             → build .app (same as make app)"
	@echo "  make app         → snapshot .app bundle (version from git)"
	@echo "  make app-release → same as make app (backward compat)"
	@echo "  make run         → build .app and open it"
	@echo "  make install     → release .app → /Applications"
	@echo "  make uninstall   → remove from /Applications"
	@echo "  make dmg         → snapshot .app + versioned DMG"
	@echo "  make test        → run unit tests"
	@echo "  make setup       → resolve SPM dependencies"
	@echo "  make xcode       → open in Xcode"
	@echo "  make clean       → delete .build, .app, .dmg"
