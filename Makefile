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

.PHONY: all setup backend app run clean nuke lint format benchmark test test-backend test-swift test-frozen-backend test-release-scripts test-ci test-coverage test-mutation verify check-version release appcast ship help

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
	xcodebuild -project $(PROJECT_PATH) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-jobs $(XCODE_JOBS) \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		-quiet \
		build
	@echo "📦 Injecting Custom Fonts..."
	mkdir -p $(APP_PATH)/Contents/Resources/Fonts
	cp frontend/Voqora/Voqora/Resources/Fonts/*.ttf $(APP_PATH)/Contents/Resources/Fonts/
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
	@echo "  make nuke      Complete factory reset (removes permissions/app data)"
	@echo "  make run       Build and launch fresh"
	@echo "  make release   Rebuild a DMG and matching SHA-256 receipt"
	@echo "  make appcast   Create a signed Sparkle update feed from a built DMG"
	@echo "  make ship      Upload from main (notarized by default; manual needs explicit channel opt-in)"
	@echo "  make test      Run fast backend tests only (no macOS app host)"
	@echo "  make test-swift Run one serial macOS test host"
	@echo "  make test-ci   Run backend + serial macOS tests"
	@echo "  make verify    Lint + fast backend tests"
