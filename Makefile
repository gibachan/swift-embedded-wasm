# =============================================================================
# Makefile — swift-embedded-wasm
# =============================================================================
#
# Usage:
#   make              same as test (runs both checks)
#   make test         swift test (macOS) + Embedded Swift build verification
#   make compile      Swift → .o only (Embedded Swift verification, no Pico SDK required)
#   make format       format Sources/ and Tests/ with swift-format (in-place)
#   make format-check check formatting only (exits non-zero if changes found)
#   make spectest-gen convert official WebAssembly testsuite .wast → JSON + .wasm
#   make setup-hooks  install Git pre-commit hook (first time only)
#   make clean        delete build artifacts
#   make help         show this help
#
# =============================================================================

# --- Project settings ---------------------------------------------------------
PROJECT     := pico-wasm
MODULE_NAME := Main

BUILD_DIR := build

# Swift sources to build (shared logic layer for macOS / Pico)
SWIFT_SRCS := $(wildcard Sources/WasmRuntime/*.swift)

# --- Target settings ----------------------------------------------------------
#
# ARMv8-M (Cortex-M33) is upward-compatible with ARMv7-M, so code compiled
# for armv7em runs on RP2350 without modification.
#
TARGET := armv7em-none-none-eabi

# --- Tools --------------------------------------------------------------------
SWIFTC        := $(HOME)/.swiftly/bin/swiftc
SWIFT_FORMAT  := $(HOME)/.swiftly/bin/swift-format

# --- SDK path (macOS host) ----------------------------------------------------
SWIFT_SDK := $(shell xcrun --show-sdk-path 2>/dev/null)

# --- Swift compilation flags --------------------------------------------------
SWIFTFLAGS := \
  -target $(TARGET) \
  -enable-experimental-feature Embedded \
  -enable-experimental-feature Extern \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -wmo \
  -Osize \
  -module-name $(MODULE_NAME) \
  -sdk $(SWIFT_SDK)

# --- spectest paths -----------------------------------------------------------
SPECTEST_SRC := ThirdParty/testsuite
SPECTEST_OUT := Tests/WasmRuntimeTests/spectest

# =============================================================================
# Target definitions
# =============================================================================

.PHONY: all test swift-test compile format format-check clean setup-hooks spectest-gen spectest-clean check-tools check-toolchain help

# Default is test — bare `make` runs both environment checks
all: test

# ---------------------------------------------------------------------------
# test — logic verification (macOS) + Embedded Swift build verification
#
# Two-stage verification:
#   1. swift test  : run unit tests on macOS (fast, no physical Pico required)
#   2. make compile: confirm the same sources compile under Embedded Swift
#
# If swift test fails, compile is not executed.
# ---------------------------------------------------------------------------
test: swift-test compile
	@echo ""
	@echo "✓ All checks passed"
	@echo "  [1/2] swift test : macOS logic verification"
	@echo "  [2/2] compile    : Embedded Swift build verification"

swift-test:
	@echo "--- [1/2] swift test (macOS) ---"
	@swift test -Xswiftc -DMACOS
	@echo ""

# ---------------------------------------------------------------------------
# compile — Swift → .o only (Embedded Swift verification)
#
# Pico SDK is not required; works as long as swiftc supports Embedded Swift.
# Also called by the pre-commit hook.
# ---------------------------------------------------------------------------
compile: check-tools $(BUILD_DIR)/$(PROJECT).o
	@echo ""
	@echo "✓ Embedded Swift compilation succeeded"
	@echo "  Output: $(BUILD_DIR)/$(PROJECT).o"
	@echo "  Target: $(TARGET)"

$(BUILD_DIR)/$(PROJECT).o: $(SWIFT_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -c $^ -o $@

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
check-tools:
	@if [ ! -f "$(SWIFTC)" ]; then \
	  echo ""; \
	  echo "Error: swiftc not found: $(SWIFTC)"; \
	  echo ""; \
	  echo "  Make sure swiftly is installed:"; \
	  echo "    https://github.com/swiftlang/swiftly"; \
	  echo "  Then add Swift 6.x:"; \
	  echo "    swiftly install latest"; \
	  echo ""; \
	  exit 1; \
	fi
	@SWIFTC_DIR=$$(dirname $(SWIFTC)); \
	 TOOLCHAIN_DIR=$$(dirname $$SWIFTC_DIR); \
	 EMBEDDED_DIR="$$TOOLCHAIN_DIR/lib/swift/embedded"; \
	 if [ ! -d "$$EMBEDDED_DIR" ]; then \
	   echo ""; \
	   echo "Warning: embedded stdlib not found: $$EMBEDDED_DIR"; \
	   echo "  Try a snapshot toolchain via swiftly:"; \
	   echo "    swiftly install main-snapshot"; \
	   echo "    swiftly use main-snapshot-<date>"; \
	   echo ""; \
	 fi
	@echo "| swiftc: $$($(SWIFTC) --version 2>&1 | head -1)"

check-toolchain:
	@echo "=== Toolchain diagnostics ==="
	@echo "swiftc  : $$(which swiftc)"
	@echo "version : $$(swiftc --version 2>&1 | head -1)"
	@echo "SDK     : $(SWIFT_SDK)"
	@echo "target  : $(TARGET)"
	@echo ""
	@echo "--- Checking embedded stdlib ---"
	@SWIFTC_DIR=$$(dirname $$(which swiftc)); \
	 EMBEDDED_DIR="$$SWIFTC_DIR/../lib/swift/embedded"; \
	 if [ -d "$$EMBEDDED_DIR" ]; then \
	   echo "✓ embedded stdlib found: $$EMBEDDED_DIR"; \
	   ls "$$EMBEDDED_DIR" | head -5; \
	 else \
	   echo "✗ embedded stdlib not found: $$EMBEDDED_DIR"; \
	   echo ""; \
	   echo "  → Install a Swift 6.x toolchain from swift.org:"; \
	   echo "    https://www.swift.org/download/"; \
	   echo "    After installing: export TOOLCHAINS=<bundle-id>"; \
	 fi

# ---------------------------------------------------------------------------
# format / format-check — code formatting via swift-format
#
# format       : recursively format Sources/ and Tests/ in-place
# format-check : exit non-zero if formatting diff exists (used for CI lint)
# ---------------------------------------------------------------------------
format:
	$(SWIFT_FORMAT) format --in-place --recursive Sources/ Tests/
	@echo "✓ Formatting complete"

format-check:
	$(SWIFT_FORMAT) lint --recursive Sources/ Tests/

clean:
	rm -rf $(BUILD_DIR)

# ---------------------------------------------------------------------------
# setup-hooks — install Git pre-commit hook
#
# Copies Scripts/pre-commit to .git/hooks/pre-commit and makes it executable.
# Run once; subsequent commits will automatically verify the Embedded build.
# ---------------------------------------------------------------------------
setup-hooks:
	@cp Scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ pre-commit hook installed"
	@echo "  Committing changes to Sources/WasmRuntime/ will automatically verify the Embedded build"

# ---------------------------------------------------------------------------
# spectest-gen — convert official WebAssembly testsuite .wast → JSON + .wasm
#
# Requires wast2json (wabt): brew install wabt
#
# Output is written to Tests/WasmRuntimeTests/spectest/ (.gitignore target).
# Running swift test causes SpectestTests to auto-discover and run them.
#
# Run on first use or after updating the testsuite:
#   make spectest-gen
# ---------------------------------------------------------------------------
spectest-gen:
	@if ! command -v wast2json > /dev/null 2>&1; then \
	  echo "Error: wast2json not found"; \
	  echo "  brew install wabt"; \
	  exit 1; \
	fi
	@mkdir -p $(SPECTEST_OUT)
	@echo "--- Converting spec testsuite (wast2json) ---"
	@count=0; skip=0; \
	for wast in $(SPECTEST_SRC)/*.wast; do \
	  name=$$(basename "$$wast" .wast); \
	  if wast2json "$$wast" -o "$(SPECTEST_OUT)/$$name.json" 2>/dev/null; then \
	    count=$$((count + 1)); \
	  else \
	    skip=$$((skip + 1)); \
	  fi; \
	done; \
	echo "✓ $$count files converted → $(SPECTEST_OUT)/  ($$skip skipped)"

spectest-clean:
	rm -rf $(SPECTEST_OUT)
	@echo "✓ Deleted $(SPECTEST_OUT)/"

help:
	@echo ""
	@echo "=== swift-embedded-wasm ==="
	@echo ""
	@echo "Targets:"
	@echo "  spectest-gen     convert official testsuite (.wast) to JSON + .wasm (first run / update)"
	@echo "  spectest-clean   delete converted files"
	@echo "  test             verify with swift test (macOS) + compile (Embedded) [default]"
	@echo "  compile          Swift → .o only (toolchain check, no Pico SDK required)"
	@echo "  format           format Sources/ and Tests/ with swift-format (in-place)"
	@echo "  format-check     check formatting only (exits non-zero if diff found)"
	@echo "  setup-hooks      install Git pre-commit hook (first time only)"
	@echo "  clean            delete $(BUILD_DIR)/"
	@echo "  check-toolchain  diagnose toolchain configuration"
	@echo ""
	@echo "Configuration variables (current values):"
	@echo "  TARGET    = $(TARGET)"
	@echo "  SWIFT_SDK = $(SWIFT_SDK)"
	@echo ""
