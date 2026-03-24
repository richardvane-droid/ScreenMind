# ============================================================
# ScreenMind — Makefile
# Prerequisites: xcodegen, xcodebuild, node, npm, ollama
# ============================================================

SCHEME_MAC  = ScreenMindMac
SCHEME_IOS  = ScreenMindIOS
XCPROJ      = ScreenMind.xcodeproj
DERIVED_DATA = DerivedData

# Default target
.PHONY: all
all: gen build-mac

# ──────────────────────────────────────────────────────────
# 1. Generate Xcode project from project.yml
# ──────────────────────────────────────────────────────────
.PHONY: gen
gen:
	@echo "▶ Generating Xcode project..."
	xcodegen generate
	@echo "  ✓ $(XCPROJ) generated"

# ──────────────────────────────────────────────────────────
# 2. Build macOS app (no signing for CI)
# ──────────────────────────────────────────────────────────
.PHONY: build-mac
build-mac: gen
	@echo "▶ Building macOS app..."
	xcodebuild build \
	  -project $(XCPROJ) \
	  -scheme $(SCHEME_MAC) \
	  -destination "platform=macOS" \
	  -derivedDataPath $(DERIVED_DATA)/mac \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO \
	  | xcbeautify || xcodebuild build \
	    -project $(XCPROJ) \
	    -scheme $(SCHEME_MAC) \
	    -destination "platform=macOS" \
	    -derivedDataPath $(DERIVED_DATA)/mac \
	    CODE_SIGN_IDENTITY="" \
	    CODE_SIGNING_REQUIRED=NO \
	    CODE_SIGNING_ALLOWED=NO

# ──────────────────────────────────────────────────────────
# 3. Build iOS app (Simulator)
# ──────────────────────────────────────────────────────────
.PHONY: build-ios
build-ios: gen
	@echo "▶ Building iOS app (Simulator)..."
	xcodebuild build \
	  -project $(XCPROJ) \
	  -scheme $(SCHEME_IOS) \
	  -destination "platform=iOS Simulator,name=iPhone 16 Pro,OS=latest" \
	  -derivedDataPath $(DERIVED_DATA)/ios \
	  CODE_SIGN_IDENTITY="" \
	  CODE_SIGNING_REQUIRED=NO \
	  CODE_SIGNING_ALLOWED=NO

# ──────────────────────────────────────────────────────────
# 4. Run unit tests
# ──────────────────────────────────────────────────────────
.PHONY: test
test:
	@echo "▶ Running ScreenMindCore tests..."
	swift test --package-path ScreenMindCore

# ──────────────────────────────────────────────────────────
# 5. Frontend (web-config React app)
# ──────────────────────────────────────────────────────────
.PHONY: web-dev
web-dev:
	@echo "▶ Starting React dev server..."
	cd web-config && npm install && npm run dev

.PHONY: web-build
web-build:
	@echo "▶ Building React frontend..."
	cd web-config && npm install && npm run build
	@echo "  ✓ dist/ ready for Xcode bundle"

# ──────────────────────────────────────────────────────────
# 6. Ollama model setup
# ──────────────────────────────────────────────────────────
.PHONY: ollama-setup
ollama-setup:
	@echo "▶ Pulling qwen2.5:3b model (~1.9 GB)..."
	ollama pull qwen2.5:3b
	@echo "  ✓ Model ready"

.PHONY: ollama-test
ollama-test:
	@echo "▶ Testing Ollama..."
	curl -s http://127.0.0.1:11434/api/generate \
	  -d '{"model":"qwen2.5:3b","prompt":"你好，请用一句话回答：今天天气如何？","stream":false}' \
	  | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"

# ──────────────────────────────────────────────────────────
# 7. Convenience
# ──────────────────────────────────────────────────────────
.PHONY: setup
setup:
	@echo "▶ Running full dev environment setup..."
	bash scripts/setup.sh

.PHONY: clean
clean:
	rm -rf $(DERIVED_DATA) $(XCPROJ)
	@echo "  ✓ Cleaned"

.PHONY: open
open: gen
	open $(XCPROJ)

.PHONY: help
help:
	@echo ""
	@echo "ScreenMind Makefile targets:"
	@echo "  make gen          — Generate Xcode project from project.yml"
	@echo "  make build-mac    — Build macOS app"
	@echo "  make build-ios    — Build iOS app (Simulator)"
	@echo "  make test         — Run ScreenMindCore unit tests"
	@echo "  make web-dev      — Start React dev server"
	@echo "  make web-build    — Build React frontend"
	@echo "  make ollama-setup — Pull qwen2.5:3b model"
	@echo "  make ollama-test  — Test Ollama endpoint"
	@echo "  make open         — Generate + open in Xcode"
	@echo "  make clean        — Remove derived data + xcodeproj"
	@echo ""
