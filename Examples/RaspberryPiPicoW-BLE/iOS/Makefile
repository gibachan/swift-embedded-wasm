# =============================================================================
# Makefile — iOS/
# =============================================================================
#
# Usage:
#   make                  build all .wasm files from Swift sources
#   make gpio-blink-swift.wasm
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

all: $(WASM_OUT_DIR)/gpio-blink-swift.wasm $(WASM_OUT_DIR)/i32-add.wasm

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# gpio-blink-swift.wasm
$(BUILD_DIR)/gpio-blink-swift.o: gpio-blink-swift.swift | $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -module-name GpioBlink -emit-object -o $@ $<

$(WASM_OUT_DIR)/gpio-blink-swift.wasm: $(BUILD_DIR)/gpio-blink-swift.o
	$(WASM_LD) $(LDFLAGS) --export=run -o $@ $<
	@echo "✓ $@ ($$(wc -c < $@ | tr -d ' ') bytes)"

# i32-add.wasm
$(BUILD_DIR)/i32-add.o: i32-add.swift | $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -module-name I32Add -emit-object -o $@ $<

$(WASM_OUT_DIR)/i32-add.wasm: $(BUILD_DIR)/i32-add.o
	$(WASM_LD) $(LDFLAGS) --export=add -o $@ $<
	@echo "✓ $@ ($$(wc -c < $@ | tr -d ' ') bytes)"

clean:
	rm -rf $(BUILD_DIR) $(WASM_OUT_DIR)/gpio-blink-swift.wasm $(WASM_OUT_DIR)/i32-add.wasm
