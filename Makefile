# ==========================================
# Voqora Automation Pipeline
# ==========================================

# Configuration
PROJECT_PATH = frontend/Voqora/Voqora.xcodeproj
SCHEME = Voqora
CONFIG = Release
BUILD_DIR = build
APP_PATH = $(BUILD_DIR)/DerivedData/Build/Products/$(CONFIG)/Voqora.app
BUNDLE_ID = com.himudigonda.Voqora
# Keep normal local builds and the serial test host from monopolising the Mac.
# `-jobs` limits Xcode build operations. It does not promise to override every
# Swift compiler worker, so the expensive macOS host remains explicit below.
# A release owner can opt into a different cap deliberately, for example
# `make app XCODE_JOBS=6`.
XCODE_JOBS ?= 4

# Local builds default to ad-hoc signing (CODE_SIGN_IDENTITY = "-"), which
# gives the bundle a brand-new designated requirement on every single build.
# macOS records Accessibility and Automation grants against that requirement,
# NOT against the path, and TCC keeps exactly one row per bundle identifier.
# So an ad-hoc rebuild silently invalidates the previous grant while System
# Settings still shows the toggle switched on and AXIsProcessTrusted() returns
# false — which is why re-granting meant deleting the stale row first. Signing
# with a STABLE certificate identity keeps the requirement constant, so the
# grant is given once and survives every rebuild. See scripts/create_dmg.sh
# for the same fix on the release path.
# Override if you sign with something else:
#   make app LOCAL_SIGN_IDENTITY="Developer ID Application: ..."
LOCAL_SIGN_IDENTITY ?= Apple Development: himudigonda@gmail.com (C97M74Y2YF)
LOCAL_DEVELOPMENT_TEAM ?= WL37Y6X6V9

.PHONY: all setup backend app run clean clean-build nuke lint format benchmark test test-backend test-swift test-frozen-backend test-release-scripts test-smoke test-ci test-coverage test-mutation verify check-version release appcast ship help

# Default: Run the full pipeline
all: run

# --- 🛠️ SETUP ---
setup:
	@echo "📦 Installing Python Dependencies..."
	cd backend && uv sync
	@echo "📦 Checking Swift Environment..."
	xcode-select -p || echo "⚠️ Xcode not found!"
	@echo "🛠️ Configuring Git Hooks..."
	@git config core.hooksPath .githooks
	@echo "✅ Setup Complete."

# --- 🐍 BACKEND ---
backend:
	@echo "------------------------------------------------"
	@echo "🚀 [1/3] Building Python Backend..."
	@echo "------------------------------------------------"
	chmod +x scripts/compile_backend.sh
	./scripts/compile_backend.sh

# --- 🍎 FRONTEND ---
app:
	@echo "------------------------------------------------"
	@echo "🔨 [2/3] Building macOS Application..."
	@echo "------------------------------------------------"
	@# A local build's Voqora.app has no business showing up next to the real
	@# install in Spotlight/Raycast/Alfred search — `.metadata_never_index` is
	@# Spotlight's own documented per-folder opt-out, so every build under
	@# here (this local build, the release .xcarchive, shipped DMGs) is
	@# invisible to search from now on without touching System Settings.
	@mkdir -p $(BUILD_DIR)
	@touch $(BUILD_DIR)/.metadata_never_index
	@# `codesign` refuses to sign a bundle carrying a custom Finder icon
	@# ("resource fork, Finder information, or similar detritus not allowed",
	@# Error 65) — and Voqora writes one onto its own bundle itself, via
	@# `NSWorkspace.setIcon` in `AppIconOption.apply()`, whenever the user
	@# picks the non-default app icon. So simply RUNNING a local build with
	@# "Wave — Clay" selected left `Icon\r` plus `com.apple.FinderInfo` on
	@# the previous product, and the next incremental build then failed at
	@# its codesign step on detritus the build never created. Clearing it
	@# before xcodebuild — not after — is what makes `make app` idempotent:
	@# the stale product is scrubbed while it is still just an input.
	@if [ -d "$(APP_PATH)" ]; then \
		rm -f "$(APP_PATH)/Icon"$$'\r'; \
		xattr -c "$(APP_PATH)" 2>/dev/null || true; \
	fi
	@# Fall back to ad-hoc rather than failing the build when this identity
	@# is not in the keychain (another machine, or CI), but say so loudly —
	@# on that path the permission grants go back to needing re-approval.
	@SIGN_ID="$(LOCAL_SIGN_IDENTITY)"; SIGN_TEAM="$(LOCAL_DEVELOPMENT_TEAM)"; \
	if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$$SIGN_ID"; then \
		echo "⚠️  Signing identity not found in keychain: $$SIGN_ID"; \
		echo "   Falling back to ad-hoc signing. Accessibility/Automation will"; \
		echo "   need re-approving after every rebuild until it is available."; \
		SIGN_ID="-"; SIGN_TEAM=""; \
	else \
		echo "🔏 Signing with stable identity: $$SIGN_ID"; \
	fi; \
	xcodebuild -project $(PROJECT_PATH) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-jobs $(XCODE_JOBS) \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$$SIGN_ID" \
		DEVELOPMENT_TEAM="$$SIGN_TEAM" \
		-quiet \
		build
	@# Fonts are NOT injected here any more. `Resources/Fonts` is a folder
	@# reference in the Voqora target's Resources build phase, so Xcode
	@# copies it into the bundle before its own codesign step and the
	@# signature actually seals it. Copying them in afterwards produced an
	@# app whose signature did not cover its own fonts (`codesign --verify
	@# --strict` failed on every local build), and duplicated all 10 faces,
	@# since the synchronized `Voqora` folder group was already flattening
	@# the same .ttf files into `Resources/` where `ATSApplicationFontsPath`
	@# (= "Fonts") never looks. Those flat copies are now excluded.
	@echo "🔎 Verifying bundle signature seals every resource..."
	@codesign --verify --strict "$(APP_PATH)"
	@echo "✅ Build Successful: $(APP_PATH)"

# --- 🚀 LAUNCH ---
# Delegate to the exact-bundle runner. It must not kill an installed Voqora
# copy just because it has the same display name as this local candidate.
run:
	@./script/build_and_run.sh run

# --- 🧹 UTILS ---

# Standard clean: Wipes all local build artifacts
clean:
	@echo "🗑️ Cleaning local artifacts..."
	rm -rf backend/dist backend/build
	rm -rf $(BUILD_DIR)
	rm -rf frontend/Voqora/DerivedData
	rm -rf frontend/Voqora/Voqora/Resources/VoqoraServer
	rm -rf frontend/Voqora/Voqora/Resources/VoqoraServer.zip
	rm -rf frontend/Voqora/Voqora/Resources/VoqoraServer.build-id
	rm -rf frontend/Voqora/Voqora/Resources/VoqoraServer.inputs.sha256
	rm -rf frontend/Voqora/Voqora/Resources/VoqoraServer.manifest.json
	find . -name "__pycache__" -type d -exec rm -rf {} +
	@echo "✨ Local build folders cleared."

# `mdfind` reflects real files on disk, not Launch Services — so the actual
# fix for a stray Voqora.app showing up in Spotlight/Raycast/Alfred search is
# either delete it (safe for pure build cache: global/local DerivedData) or
# mark its folder `.metadata_never_index` (for the release .xcarchive, which
# must stay on disk — see the `app` target). `lsregister -u` is deregistered
# too, belt-and-suspenders, since it's what "Open With"/duplicate-icon
# resolution actually consults. Every bare `xcodebuild build` (no
# `-derivedDataPath` — running straight from Xcode.app, or by hand) is what
# drops a Voqora.app under the *global* ~/Library/Developer/Xcode/DerivedData
# in the first place, each with whatever stale icon that build happened to
# ship — this also sweeps those, plus any already-Trashed leftovers, which
# are unambiguous junk since they were already discarded once.
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
GLOBAL_DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

clean-build:
	@echo "🔎 Deregistering every Voqora.app copy outside /Applications..."
	@strays="$$(mdfind "kMDItemFSName == 'Voqora.app'" 2>/dev/null | grep -v '^/Applications/Voqora\.app$$' || true)"; \
	if [ -z "$$strays" ]; then \
		echo "   None found."; \
	else \
		echo "$$strays" | while IFS= read -r app; do \
			echo "   - $$app"; \
			/usr/bin/pkill -f "$$app/Contents/MacOS/Voqora" 2>/dev/null || true; \
			"$(LSREGISTER)" -u "$$app" 2>/dev/null || true; \
		done; \
	fi
	@echo "🗑️  Deleting the actual build caches those came from..."
	@rm -rf $(GLOBAL_DERIVED_DATA)/Voqora-*
	@rm -rf $(BUILD_DIR)/DerivedData
	@echo "🗑️  Purging already-Trashed Voqora build leftovers..."
	@rm -rf $(HOME)/.Trash/Voqora-*
	@echo "🔨 Building one fresh local copy..."
	@$(MAKE) app
	@"$(LSREGISTER)" -u "$(APP_PATH)" 2>/dev/null || true
	@echo "📇 Remaining Voqora.app copies Spotlight can find:"
	@remaining="$$(mdfind "kMDItemFSName == 'Voqora.app'" 2>/dev/null)"; \
	echo "$$remaining"; \
	if [ "$$remaining" != "/Applications/Voqora.app" ]; then \
		echo ""; \
		echo "⚠️  Something above predates the $(BUILD_DIR)/.metadata_never_index marker (e.g. an older release .xcarchive indexed before this target existed)."; \
		echo "   This can't be forced from the command line without touching system Spotlight settings, which this Makefile deliberately never does."; \
		echo "   One-time manual fix: System Settings → Siri & Spotlight → Spotlight Privacy → add the '$(BUILD_DIR)' folder, then remove it again."; \
		echo "   Anything created under $(BUILD_DIR) *after* this point is already covered by the marker and will never need that again."; \
	fi
	@echo "✅ clean-build done. Run 'make run' to launch the fresh local copy — it's deliberately hidden from Spotlight."

# Factory reset: confirmed build cleanup + system-level wipe + permission reset
# Wipes ~/Library/Application Support/com.himudigonda.Voqora (audiobooks,
# history, settings). Prompts unless CI=1. See HARD-050.
nuke:
	@# A reset must never touch data or build artifacts before its owning apps
	@# are closed and the user has explicitly confirmed the exact current target.
	@if pgrep -f "/Applications/Voqora.app/Contents/MacOS/Voqora" >/dev/null; then \
		echo "Quit /Applications/Voqora.app before resetting its shared data."; exit 2; \
	fi
	@if pgrep -f "$(CURDIR)/$(APP_PATH)/Contents/MacOS/Voqora" >/dev/null || \
		pgrep -f "$$HOME/Library/Application Support/$(BUNDLE_ID)/VoqoraServer/VoqoraServer" >/dev/null; then \
		echo "Quit every local Voqora candidate before resetting shared data."; exit 2; \
	fi
ifndef CI
	@printf "⚠️  This wipes ALL local Voqora data (audiobooks, history,\n   accessibility grants). Continue? [y/N] " && read ans && [ "$$ans" = "y" ] || (echo "Aborted." && exit 1)
endif
	@$(MAKE) clean
	@echo "🧨 NUKING SYSTEM DATA..."
	rm -rf ~/Library/Application\ Support/$(BUNDLE_ID)
	@echo "🔐 Resetting macOS Accessibility Database..."
	tccutil reset Accessibility $(BUNDLE_ID) || true
	@echo "✅ Factory reset complete. Run 'make run' for a truly fresh start."

# --- 🔍 CODE QUALITY ---
lint:
	@echo "🧹 Linting Python..."
	cd backend && uv run ruff check .
	cd backend && uv run black --check .
	@echo "🧹 Linting Swift..."
	@command -v swiftlint >/dev/null || { echo "SwiftLint is required; install the documented release-quality tools."; exit 2; }
	swiftlint lint --strict --config .swiftlint.yml
	@command -v swiftformat >/dev/null || { echo "SwiftFormat is required; install the documented release-quality tools."; exit 2; }
	swiftformat --lint frontend/Voqora/Voqora frontend/Voqora/VoqoraTests --swift-version 6

format:
	@echo "✨ Formatting Python..."
	cd backend && uv run ruff check --fix .
	cd backend && uv run black .
	@echo "✨ Formatting Swift..."
	@command -v swiftformat >/dev/null || { echo "SwiftFormat is required; install the documented release-quality tools."; exit 2; }
	swiftformat frontend/Voqora/Voqora frontend/Voqora/VoqoraTests --swift-version 6

# --- 📊 BENCHMARKS ---
benchmark:
	@mkdir -p backend/benchmarks
	@echo "🧪 Running Engine Scenarios..."
	cd backend && PYTHONPATH=. uv run python benchmarks/deep_profiler.py
	@echo "📈 Generating Visual Trends..."
	uv run python scripts/visualize_vitals.py
	@echo "📝 Generating Website Markdown Table..."
	uv run python scripts/generate_vitals_table.py

# --- 🧪 TESTS ---
# `make test` is deliberately the fast, headless backend suite. macOS unit
# tests launch an app-host process, so they are explicit and serialised below.
# This keeps everyday validation from opening a pile of Voqora instances.
test: test-backend

test-backend:
	@echo "🧪 Running fast backend tests (no macOS app launch)..."
	cd backend && uv run pytest -q --no-cov

test-swift:
	@set -e; \
		lock="$(BUILD_DIR)/.swift-test.lock"; \
		mkdir -p "$(BUILD_DIR)"; \
		if ! mkdir "$$lock" 2>/dev/null; then \
			if pgrep -x xcodebuild >/dev/null; then \
				echo "⚠️  A macOS Xcode build is already active. Wait for it to finish."; exit 2; \
			fi; \
			if ! rmdir "$$lock" 2>/dev/null; then \
				echo "⚠️  The Voqora Swift-test lock is not recoverable. Inspect $$lock before retrying."; exit 2; \
			fi; \
			mkdir "$$lock"; \
			echo "ℹ️  Recovered a stale Voqora Swift-test lock."; \
		fi; \
		trap 'rmdir "$$lock"' EXIT; \
		if pgrep -x xcodebuild >/dev/null; then \
			echo "⚠️  An Xcode build is already active. Refusing to overlap the macOS test host."; exit 2; \
		fi; \
		echo "🧪 Running one serial Swift test host..."; \
		xcodebuild test -project $(PROJECT_PATH) -scheme $(SCHEME) \
			-destination 'platform=macOS,arch=arm64' \
			-jobs $(XCODE_JOBS) \
			-parallel-testing-enabled NO \
			CODE_SIGNING_ALLOWED=NO

test-frozen-backend:
	@echo "🧪 Exercising the sealed frozen backend through its inherited FD..."
	python3 scripts/test_frozen_backend.py

test-release-scripts:
	@echo "🧪 Exercising release-channel safety guards..."
	bash scripts/test_ship_modes.sh
	@echo "🧪 Exercising backend archive safety guards..."
	python3 scripts/test_backend_archive_safety.py
	@echo "🧪 Exercising launch-critical build/source contracts..."
	python3 scripts/test_launch_contracts.py

# Launch the built app for real and prove it reaches a working backend. Needs
# `make app` first, and is deliberately NOT part of `test-ci`: it opens a real
# window and takes a couple of minutes on a cold extraction.
# `make test-smoke SMOKE_ARGS=--use-real-home` validates this exact machine
# instead of a throwaway home (quit any running Voqora first).
test-smoke:
	@echo "🧪 Launching the built app and waiting for a live backend..."
	python3 scripts/test_app_smoke.py $(SMOKE_ARGS)

# CI or a deliberate full local proof. This is the only aggregate target that
# invokes the macOS test host.
test-ci: test-backend test-release-scripts test-swift

# Good default before a commit: lint plus the fast, non-graphical suite.
verify: lint test-backend

test-coverage:
	@echo "📊 Backend coverage..."
	cd backend && uv run pytest --cov=app --cov-report=term-missing --cov-report=html:.coverage_html --cov-fail-under=74
	@echo "📊 Backend coverage HTML at backend/.coverage_html/index.html"
	@echo "ℹ️  Current verified coverage floor is 74%."

test-mutation:
	@echo "🧬 Mutation testing (privacy modules)..."
	cd backend && uv run mutmut run || true
	cd backend && uv run mutmut results || true

# --- 📦 RELEASES ---

check-version:
ifndef VERSION
	$(error VERSION is required, e.g. `make release VERSION=1.0.0`)
endif

# Build the DMG WITHOUT nuking the developer's machine. The previous
# `release: nuke backend` chain destroyed local audiobooks/history every
# time. If you want a truly fresh build, run `make nuke` explicitly first.
# See HARD-050.
release: check-version
	@echo "🚀 Validating release source for v$(VERSION) before any heavy build..."
	ALLOW_MISSING_BACKEND_ARTIFACT=1 ./scripts/validate_release.sh $(VERSION)
	@echo "🚀 Starting release build for v$(VERSION) (no nuke)..."
	$(MAKE) backend
	$(MAKE) test-frozen-backend
	chmod +x scripts/create_dmg.sh
	./scripts/create_dmg.sh $(VERSION)
	./scripts/validate_release.sh $(VERSION) build/Voqora-$(VERSION).dmg
	@echo "✅ Release Ready: build/Voqora-$(VERSION).dmg and build/Voqora-$(VERSION).dmg.sha256"

appcast: check-version
	chmod +x scripts/create_appcast.sh
	./scripts/create_appcast.sh $(VERSION)

## `ship` never rebuilds. The notarized appcast is signed for a particular
## byte stream, so rebuilds after `make appcast` would invalidate the update.
ship: check-version
	@echo "🚢 Shipping v$(VERSION)..."
	chmod +x scripts/ship.sh
	./scripts/ship.sh $(VERSION)

help:
	@echo "Voqora Management"
	@echo "  make clean     Wipe build artifacts"
	@echo "  make clean-build  Deregister/remove every stray Voqora.app (dupes in Spotlight) and rebuild one fresh local copy"
	@echo "  make nuke      Complete factory reset (removes permissions/app data)"
	@echo "  make run       Build and launch fresh"
	@echo "  make release   Rebuild a DMG and matching SHA-256 receipt"
	@echo "  make appcast   Create a signed Sparkle update feed from a built DMG"
	@echo "  make ship      Upload from main (notarized by default; manual needs explicit channel opt-in)"
	@echo "  make test      Run fast backend tests only (no macOS app host)"
	@echo "  make test-swift Run one serial macOS test host"
	@echo "  make test-ci   Run backend + serial macOS tests"
	@echo "  make verify    Lint + fast backend tests"
