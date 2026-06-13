# =============================================================================
# Makefile — pico-ble (Raspberry Pi Pico W BLE peripheral, CMake build)
# =============================================================================
#
# Usage:
#   make              same as build
#   make build        CMake configure (first time only) + build → generate .uf2
#   make reconfigure  force CMake reconfigure, then build
#   make flash        copy .uf2 to Pico (run after BOOTSEL mount)
#   make clean        delete build artifacts
#   make help         show this help
#
# Environment variables (overridable):
#   PICO_BOARD          board type                   (default: pico_w)
#   PICO_SDK_PATH       path to Pico SDK             (default: ~/pico/pico-sdk)
#   PICO_TOOLCHAIN_PATH path to Arm toolchain        (default: /opt/homebrew)
#   SWIFT_TOOLCHAIN     path to Swift toolchain
#   PICO_MOUNT          Pico mount path              (default: /Volumes/RPI-RP2)
#
# Examples:
#   make
#   make PICO_BOARD=pico2_w
#   make flash PICO_MOUNT=/Volumes/RP2350
# =============================================================================

PROJECT   := pico-ble
BUILD_DIR := build

PICO_BOARD          ?= pico_w
PICO_SDK_PATH       ?= $(HOME)/pico/pico-sdk
PICO_TOOLCHAIN_PATH ?= /opt/homebrew
SWIFT_TOOLCHAIN     ?= $(HOME)/.swiftly
PICO_MOUNT          ?= /Volumes/RPI-RP2

.PHONY: all build reconfigure flash clean help check-sdk

all: build

# ---------------------------------------------------------------------------
# build — CMake configure (first time only, when build/ does not exist) + build
# ---------------------------------------------------------------------------
build: check-sdk
	@if [ ! -d "$(BUILD_DIR)" ]; then \
	  PICO_BOARD=$(PICO_BOARD) \
	  PICO_SDK_PATH=$(PICO_SDK_PATH) \
	  PICO_TOOLCHAIN_PATH=$(PICO_TOOLCHAIN_PATH) \
	  cmake -B $(BUILD_DIR) -G Ninja . \
	    -DCMAKE_EXPORT_COMPILE_COMMANDS=On \
	    -DCMAKE_Swift_COMPILER="$(SWIFT_TOOLCHAIN)/bin/swiftc"; \
	fi
	@cmake --build $(BUILD_DIR)
	@echo ""
	@echo "✓ Build complete"
	@echo "  UF2: $(BUILD_DIR)/$(PROJECT).uf2"
	@echo "  ELF: $(BUILD_DIR)/$(PROJECT).elf"
	@echo ""
	@echo "Next step: make flash"

# ---------------------------------------------------------------------------
# reconfigure — delete CMake cache, reconfigure, then build
#
# Use this when CMakeLists.txt has changed or when switching PICO_BOARD.
# ---------------------------------------------------------------------------
reconfigure: check-sdk
	rm -rf $(BUILD_DIR)
	@PICO_BOARD=$(PICO_BOARD) \
	 PICO_SDK_PATH=$(PICO_SDK_PATH) \
	 PICO_TOOLCHAIN_PATH=$(PICO_TOOLCHAIN_PATH) \
	 cmake -B $(BUILD_DIR) -G Ninja . \
	   -DCMAKE_EXPORT_COMPILE_COMMANDS=On \
	   -DCMAKE_Swift_COMPILER="$(SWIFT_TOOLCHAIN)/bin/swiftc"
	@cmake --build $(BUILD_DIR)
	@echo ""
	@echo "✓ Build complete"
	@echo "  UF2: $(BUILD_DIR)/$(PROJECT).uf2"

# ---------------------------------------------------------------------------
# flash — write firmware to Pico
#
# Hold the BOOTSEL button while connecting Pico W via USB; it will mount
# as a storage device. Copying the .uf2 file completes the flash and the
# device reboots automatically.
# ---------------------------------------------------------------------------
flash: $(BUILD_DIR)/$(PROJECT).uf2
	@if [ ! -d "$(PICO_MOUNT)" ]; then \
	  echo ""; \
	  echo "Error: Pico is not mounted"; \
	  echo "  Steps: hold BOOTSEL and connect via USB → wait for $(PICO_MOUNT) to appear → re-run"; \
	  echo ""; \
	  exit 1; \
	fi
	cp $(BUILD_DIR)/$(PROJECT).uf2 $(PICO_MOUNT)/
	@echo "✓ Flash complete ($(PROJECT).uf2 → $(PICO_MOUNT)/)"

# ---------------------------------------------------------------------------
# clean — delete build artifacts
# ---------------------------------------------------------------------------
clean:
	rm -rf $(BUILD_DIR)
	@echo "✓ Deleted $(BUILD_DIR)/"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
check-sdk:
	@if [ ! -d "$(PICO_SDK_PATH)" ]; then \
	  echo ""; \
	  echo "Error: Pico SDK not found"; \
	  echo "  PICO_SDK_PATH = $(PICO_SDK_PATH)"; \
	  echo ""; \
	  echo "  Setup steps:"; \
	  echo "    git clone https://github.com/raspberrypi/pico-sdk ~/pico/pico-sdk"; \
	  echo "    cd ~/pico/pico-sdk && git submodule update --init"; \
	  echo "    export PICO_SDK_PATH=~/pico/pico-sdk"; \
	  echo ""; \
	  exit 1; \
	fi
	@echo "| Pico SDK: $(PICO_SDK_PATH)"

help:
	@echo ""
	@echo "=== pico-ble — Raspberry Pi Pico W BLE peripheral ==="
	@echo ""
	@echo "Targets:"
	@echo "  build        CMake configure + build → generate .uf2 [default]"
	@echo "  reconfigure  force CMake reconfigure then build (use after CMakeLists.txt changes)"
	@echo "  flash        copy .uf2 to BOOTSEL-mounted Pico"
	@echo "  clean        delete $(BUILD_DIR)/"
	@echo ""
	@echo "Configuration variables (current values):"
	@echo "  PICO_BOARD          = $(PICO_BOARD)"
	@echo "  PICO_SDK_PATH       = $(PICO_SDK_PATH)"
	@echo "  PICO_TOOLCHAIN_PATH = $(PICO_TOOLCHAIN_PATH)"
	@echo "  SWIFT_TOOLCHAIN     = $(SWIFT_TOOLCHAIN)"
	@echo "  PICO_MOUNT          = $(PICO_MOUNT)"
	@echo ""
