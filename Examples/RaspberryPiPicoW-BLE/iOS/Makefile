# =============================================================================
# Makefile — iOS/
# =============================================================================
#
# Usage:
#   make                  build all .wasm files from Swift sources
#   make blink-loop-swift.wasm
#   make clean            delete build artifacts
#
# =============================================================================

# --- Tools --------------------------------------------------------------------
SWIFTC   := $(HOME)/.swiftly/bin/swiftc
WASM_LD  := $(HOME)/.swiftly/bin/wasm-ld

# --- SDK path (macOS host) ----------------------------------------------------
SWIFT_SDK := $(shell xcrun --show-sdk-path 2>/dev/null)

# --- Target -------------------------------------------------------------------
TARGET := wasm32-unknown-none-wasm

# --- Build directory ----------------------------------------------------------
BUILD_DIR := .build

# --- Output directory ---------------------------------------------------------
WASM_OUT_DIR := Demo/wasm

# --- Swift compilation flags --------------------------------------------------
SWIFTFLAGS := \
  -target $(TARGET) \
  -enable-experimental-feature Embedded \
  -enable-experimental-feature Extern \
  -wmo \
  -Osize \
  -sdk $(SWIFT_SDK)

# --- Linker flags -------------------------------------------------------------
LDFLAGS := \
  --no-entry \
  --allow-undefined

# =============================================================================
# Targets
# =============================================================================

.PHONY: all clean

all: $(WASM_OUT_DIR)/blink-loop-swift.wasm

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# blink-loop-swift.wasm
$(BUILD_DIR)/blink-loop-swift.o: blink-loop-swift.swift | $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -module-name BlinkLoopSwift -emit-object -o $@ $<

$(WASM_OUT_DIR)/blink-loop-swift.wasm: $(BUILD_DIR)/blink-loop-swift.o
	$(WASM_LD) $(LDFLAGS) --export=run -o $@ $<
	@echo "✓ $@ ($$(wc -c < $@ | tr -d ' ') bytes)"

clean:
	rm -rf $(BUILD_DIR) $(WASM_OUT_DIR)/blink-loop-swift.wasm
