# =============================================================================
# Makefile — pico-ble（Raspberry Pi Pico W BLE ペリフェラル、CMake ビルド）
# =============================================================================
#
# 使い方:
#   make              build と同じ
#   make build        CMake 設定（初回のみ）+ ビルド → .uf2 生成
#   make reconfigure  CMake を強制再設定してからビルド
#   make flash        .uf2 を Pico にコピー（BOOTSEL マウント後に実行）
#   make clean        ビルド成果物を削除
#   make help         このヘルプを表示
#
# 環境変数（上書き可能）:
#   PICO_BOARD          ボード種別              (デフォルト: pico_w)
#   PICO_SDK_PATH       Pico SDK のパス         (デフォルト: ~/pico/pico-sdk)
#   PICO_TOOLCHAIN_PATH Arm ツールチェーンのパス (デフォルト: /opt/homebrew)
#   SWIFT_TOOLCHAIN     Swift ツールチェーンのパス
#   PICO_MOUNT          Pico のマウントパス      (デフォルト: /Volumes/RPI-RP2)
#
# 例:
#   make
#   make PICO_BOARD=pico2_w
#   make flash PICO_MOUNT=/Volumes/RP2350
# =============================================================================

PROJECT   := pico-ble
BUILD_DIR := build

PICO_BOARD          ?= pico_w
PICO_SDK_PATH       ?= $(HOME)/pico/pico-sdk
PICO_TOOLCHAIN_PATH ?= /opt/homebrew
SWIFT_TOOLCHAIN     ?= $(HOME)/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr
PICO_MOUNT          ?= /Volumes/RPI-RP2

.PHONY: all build reconfigure flash clean help check-sdk

all: build

# ---------------------------------------------------------------------------
# build — CMake 設定（build/ がなければ初回のみ）+ ビルド
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
	@echo "✓ ビルド完了"
	@echo "  UF2: $(BUILD_DIR)/$(PROJECT).uf2"
	@echo "  ELF: $(BUILD_DIR)/$(PROJECT).elf"
	@echo ""
	@echo "次のステップ: make flash"

# ---------------------------------------------------------------------------
# reconfigure — CMake キャッシュを削除して再設定 + ビルド
#
# CMakeLists.txt を変更した場合や PICO_BOARD を切り替えた場合に使う。
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
	@echo "✓ ビルド完了"
	@echo "  UF2: $(BUILD_DIR)/$(PROJECT).uf2"

# ---------------------------------------------------------------------------
# flash — Pico に書き込む
#
# Pico W を BOOTSEL ボタンを押しながら USB 接続すると
# ストレージデバイスとしてマウントされる。
# .uf2 ファイルをコピーするだけで書き込み完了し、自動的に再起動する。
# ---------------------------------------------------------------------------
flash: $(BUILD_DIR)/$(PROJECT).uf2
	@if [ ! -d "$(PICO_MOUNT)" ]; then \
	  echo ""; \
	  echo "エラー: Pico がマウントされていません"; \
	  echo "  手順: BOOTSEL ボタンを押しながら USB 接続 → $(PICO_MOUNT) に現れたら再実行"; \
	  echo ""; \
	  exit 1; \
	fi
	cp $(BUILD_DIR)/$(PROJECT).uf2 $(PICO_MOUNT)/
	@echo "✓ Pico への書き込み完了 ($(PROJECT).uf2 → $(PICO_MOUNT)/)"

# ---------------------------------------------------------------------------
# clean — ビルド成果物を削除
# ---------------------------------------------------------------------------
clean:
	rm -rf $(BUILD_DIR)
	@echo "✓ $(BUILD_DIR)/ を削除しました"

# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------
check-sdk:
	@if [ ! -d "$(PICO_SDK_PATH)" ]; then \
	  echo ""; \
	  echo "エラー: Pico SDK が見つかりません"; \
	  echo "  PICO_SDK_PATH = $(PICO_SDK_PATH)"; \
	  echo ""; \
	  echo "  セットアップ手順:"; \
	  echo "    git clone https://github.com/raspberrypi/pico-sdk ~/pico/pico-sdk"; \
	  echo "    cd ~/pico/pico-sdk && git submodule update --init"; \
	  echo "    export PICO_SDK_PATH=~/pico/pico-sdk"; \
	  echo ""; \
	  exit 1; \
	fi
	@echo "| Pico SDK: $(PICO_SDK_PATH)"

help:
	@echo ""
	@echo "=== pico-ble — Raspberry Pi Pico W BLE ペリフェラル ==="
	@echo ""
	@echo "ターゲット:"
	@echo "  build        CMake 設定 + ビルド → .uf2 生成 [デフォルト]"
	@echo "  reconfigure  CMake を強制再設定してからビルド（CMakeLists.txt 変更時）"
	@echo "  flash        .uf2 を BOOTSEL マウント済みの Pico にコピー"
	@echo "  clean        $(BUILD_DIR)/ を削除"
	@echo ""
	@echo "設定変数（現在値）:"
	@echo "  PICO_BOARD          = $(PICO_BOARD)"
	@echo "  PICO_SDK_PATH       = $(PICO_SDK_PATH)"
	@echo "  PICO_TOOLCHAIN_PATH = $(PICO_TOOLCHAIN_PATH)"
	@echo "  SWIFT_TOOLCHAIN     = $(SWIFT_TOOLCHAIN)"
	@echo "  PICO_MOUNT          = $(PICO_MOUNT)"
	@echo ""
