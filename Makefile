# =============================================================================
# Makefile — Embedded Swift × Raspberry Pi Pico 2 (RP2350)
# =============================================================================
#
# 使い方:
#   make              compile と同じ（ツールチェーン確認）
#   make compile      Swift → .o のみ（Pico SDK 不要）
#   make build        完全ビルド → .elf / .bin / .uf2 生成
#   make flash        .uf2 を Pico にコピー（BOOTSEL マウント後に実行）
#   make clean        ビルド成果物を削除
#   make help         このヘルプを表示
#
# 環境変数（上書き可能）:
#   PICO_SDK_PATH   Pico SDK のパス         (デフォルト: ~/pico/pico-sdk)
#   PICO_MOUNT      Pico のマウントパス      (デフォルト: /Volumes/RPI-RP2)
#
# 例:
#   make compile
#   make build PICO_SDK_PATH=~/pico/pico-sdk
#   make flash PICO_MOUNT=/Volumes/RPI-RP2
# =============================================================================

# --- プロジェクト設定 ---------------------------------------------------------
PROJECT     := pico-wasm
MODULE_NAME := Main

SRC_DIR   := src
BUILD_DIR := build

# ビルド対象の Swift ソース
# Sources/WasmRuntime/ 以下は macOS (SwiftPM) と共有するロジック層
# src/main.swift は Pico 固有のエントリポイント
SWIFT_SRCS := $(SRC_DIR)/main.swift $(wildcard Sources/WasmRuntime/*.swift)

# --- ターゲット設定 -----------------------------------------------------------
#
# 本来 RP2350 (Cortex-M33 / ARMv8-M Mainline) のターゲットトリプルは:
#   thumbv8m.main-none-none-eabi
# だが、Swift 6.3.2 の embedded stdlib にこのターゲットは含まれていない。
#
# embedded stdlib がサポートする ARM Cortex-M 系のターゲット一覧:
#   armv6m-none-none-eabi   → Cortex-M0/M0+ (RP2040)
#   armv7em-none-none-eabi  → Cortex-M4/M7
#
# ARMv8-M (Cortex-M33) は ARMv7-M の上位互換なので、armv7em でコンパイルした
# コードは RP2350 上でそのまま動く。将来 Swift が thumbv8m.main を追加したら戻す。
#
TARGET := armv7em-none-none-eabi

# --- SDK / ツールパス --------------------------------------------------------
PICO_SDK_PATH ?= $(HOME)/pico/pico-sdk
PICO_MOUNT    ?= /Volumes/RPI-RP2

# --- ツール -------------------------------------------------------------------
#
# swiftly（https://github.com/swiftlang/swiftly）で管理するツールチェーンを使う。
# ~/.swiftly/bin/swiftc がアクティブな Swift を指している。
#
# /usr/bin/swiftc（Xcode）は ARM ベアメタル向け embedded stdlib を持たないため使えない。
#
# シェルでも swiftly の Swift を有効にするには ~/.zshrc に追記:
#   source ~/.swiftly/env.sh
#
SWIFTC := $(HOME)/.swiftly/bin/swiftc

CC      := arm-none-eabi-gcc
LD      := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy

# --- SDK パス（macOS ホスト用）------------------------------------------------
#
# ベアメタルターゲットでも -sdk の指定が必要な理由:
#   Embedded Swift モードでは stdlib をソースから一緒にコンパイルするが、
#   コンパイラは stdlib モジュールファイル (.swiftmodule) の探索起点として
#   SDK パスを使う。-sdk を省略するとモジュールが見つからずエラーになる。
#
SWIFT_SDK := $(shell xcrun --show-sdk-path 2>/dev/null)

# --- Swift コンパイルフラグ ---------------------------------------------------
#
# -enable-experimental-feature Embedded
#     Embedded Swift モードを有効化。
#     標準ライブラリの動的アロケーション依存部分が除去される。
#
# -wmo (Whole Module Optimization)
#     全ソースを一括最適化。Embedded では基本的に必須。
#
# -parse-as-library
#     ファイルをライブラリとして扱う（@main または @_cdecl("main") でエントリを定義する場合）。
#     main.swift にトップレベルコードを書く場合はこのフラグを外す。
#
# -Osize
#     コードサイズ最小化を優先した最適化。Flash 容量の制限がある組み込みに最適。
#
SWIFTFLAGS := \
  -target $(TARGET) \
  -enable-experimental-feature Embedded \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -wmo \
  -Osize \
  -module-name $(MODULE_NAME) \
  -sdk $(SWIFT_SDK)

# トップレベルコード（let x = 1 など）を使う場合は上記のまま。
# @main や @_cdecl("main") でエントリポイントを定義する場合は以下を追加:
#   SWIFTFLAGS += -parse-as-library

# --- C コンパイルフラグ（Pico SDK のスタートアップコード用）-------------------
#
# RP2350 は FPU を持つ。Pico SDK は softfp (呼び出し規約はソフト、演算はハード) を使用。
#
CFLAGS := \
  -mcpu=cortex-m33 \
  -mthumb \
  -mfloat-abi=softfp \
  -mfpu=fpv5-sp-d16 \
  -ffunction-sections \
  -fdata-sections \
  -nostdlib

# --- リンカフラグ -------------------------------------------------------------
LDFLAGS := \
  -mcpu=cortex-m33 \
  -mthumb \
  -nostdlib \
  -Wl,--gc-sections \
  -Wl,-Map=$(BUILD_DIR)/$(PROJECT).map

# RP2350 の UF2 ファミリ ID (ARM Secure モード)
RP2350_FAMILY_ID := 0xe48bff57

# =============================================================================
# ターゲット定義
# =============================================================================

SPECTEST_SRC := third_party/testsuite
SPECTEST_OUT := Tests/WasmRuntimeTests/spectest

.PHONY: all compile build flash clean help check-sdk check-tools check-toolchain test swift-test setup-hooks spectest-gen spectest-clean

# デフォルトは test — 素の `make` で両環境のチェックを行う
all: test

# ---------------------------------------------------------------------------
# test — ロジック検証（macOS）+ Embedded Swift ビルド検証（Pico 向け）
#
# 2 段階で検証する:
#   1. swift test  : macOS 上でユニットテストを実行（高速、Pico 実機不要）
#   2. make compile: 同じソースが Embedded Swift でもコンパイルできることを確認
#
# swift test が失敗した時点で compile は実行されない。
# ロジックが正しく、かつ Embedded 互換であることを一度に保証できる。
# ---------------------------------------------------------------------------
test: swift-test compile
	@echo ""
	@echo "✓ すべてのチェックが通りました"
	@echo "  [1/2] swift test : macOS ロジック検証"
	@echo "  [2/2] compile    : Embedded Swift ビルド検証"

swift-test:
	@echo "--- [1/2] swift test (macOS) ---"
	@swift test -Xswiftc -DMACOS
	@echo ""

# ---------------------------------------------------------------------------
# compile — Swift → .o のみ
#
# Pico SDK は不要。
# swiftc が PATH にあり Embedded Swift に対応していれば動作する。
# まずここでツールチェーンが正しく設定されているか確認する。
# ---------------------------------------------------------------------------
compile: check-tools $(BUILD_DIR)/$(PROJECT).o
	@echo ""
	@echo "✓ Embedded Swift コンパイル成功"
	@echo "  出力:     $(BUILD_DIR)/$(PROJECT).o"
	@echo "  ターゲット: $(TARGET)"

$(BUILD_DIR)/$(PROJECT).o: $(SWIFT_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) -c $^ -o $@

# ---------------------------------------------------------------------------
# build — 完全ビルド (.o → .elf → .bin → .uf2)
#
# Pico SDK が PICO_SDK_PATH に存在する必要がある。
# スタートアップコード (crt0.S) をコンパイルし、Swift オブジェクトとリンクする。
# ---------------------------------------------------------------------------
build: check-sdk check-tools $(BUILD_DIR)/$(PROJECT).uf2
	@echo ""
	@echo "✓ ビルド完了"
	@echo "  ELF : $(BUILD_DIR)/$(PROJECT).elf"
	@echo "  BIN : $(BUILD_DIR)/$(PROJECT).bin"
	@echo "  UF2 : $(BUILD_DIR)/$(PROJECT).uf2"
	@echo ""
	@echo "次のステップ: make flash"

# ELF → BIN（バイナリイメージ）
$(BUILD_DIR)/$(PROJECT).bin: $(BUILD_DIR)/$(PROJECT).elf
	$(OBJCOPY) -O binary $< $@

# BIN → UF2（Pico が認識する書き込みフォーマット）
# picotool があれば使い、なければ Pico SDK 付属の uf2conv.py を使う
$(BUILD_DIR)/$(PROJECT).uf2: $(BUILD_DIR)/$(PROJECT).bin
	@if command -v picotool > /dev/null 2>&1; then \
	  picotool uf2 convert $< $@ --family rp2350-arm-s; \
	else \
	  python3 $(PICO_SDK_PATH)/tools/uf2conv.py \
	    -f $(RP2350_FAMILY_ID) -o $@ $<; \
	fi

# ELF のリンク
$(BUILD_DIR)/$(PROJECT).elf: $(BUILD_DIR)/$(PROJECT).o $(BUILD_DIR)/pico_crt0.o
	$(LD) $(LDFLAGS) \
	  -T $(PICO_SDK_PATH)/src/rp2_common/pico_standard_link/memmap_default.ld \
	  $^ \
	  -o $@

# Pico SDK スタートアップコードのコンパイル
PICO_CRT0_SRC := $(PICO_SDK_PATH)/src/rp2_common/pico_standard_link/crt0.S

$(BUILD_DIR)/pico_crt0.o: $(PICO_CRT0_SRC)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) \
	  -I$(PICO_SDK_PATH)/src/rp2_common/hardware_regs/include \
	  -I$(PICO_SDK_PATH)/src/rp2_common/pico_platform_compiler/include \
	  -I$(PICO_SDK_PATH)/src/rp2_common/pico_platform_sections/include \
	  -I$(PICO_SDK_PATH)/src/rp2_common/pico_platform_panic/include \
	  -I$(PICO_SDK_PATH)/src/common/pico_base_headers/include \
	  -I$(PICO_SDK_PATH)/src/boards/include \
	  -I$(PICO_SDK_PATH)/generated/pico_base \
	  -DPICO_RP2350=1 \
	  -DPICO_BOARD=\"pico2\" \
	  -c $< -o $@

# ---------------------------------------------------------------------------
# flash — Pico に書き込む
#
# Pico を BOOTSEL ボタンを押しながら USB 接続すると
# ストレージデバイスとしてマウントされる（macOS: /Volumes/RPI-RP2）。
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
# ユーティリティ
# ---------------------------------------------------------------------------
check-tools:
	@if [ ! -f "$(SWIFTC)" ]; then \
	  echo ""; \
	  echo "エラー: swiftc が見つかりません: $(SWIFTC)"; \
	  echo ""; \
	  echo "  swiftly がインストールされていることを確認してください:"; \
	  echo "    https://github.com/swiftlang/swiftly"; \
	  echo "  インストール後、Swift 6.x を追加:"; \
	  echo "    swiftly install latest"; \
	  echo ""; \
	  exit 1; \
	fi
	@# embedded stdlib の存在確認
	@SWIFTC_DIR=$$(dirname $(SWIFTC)); \
	 TOOLCHAIN_DIR=$$(dirname $$SWIFTC_DIR); \
	 EMBEDDED_DIR="$$TOOLCHAIN_DIR/lib/swift/embedded"; \
	 if [ ! -d "$$EMBEDDED_DIR" ]; then \
	   echo ""; \
	   echo "警告: embedded stdlib が見つかりません: $$EMBEDDED_DIR"; \
	   echo "  swiftly で snapshot ツールチェーンを試してください:"; \
	   echo "    swiftly install main-snapshot"; \
	   echo "    swiftly use main-snapshot-<日付>"; \
	   echo ""; \
	 fi
	@echo "| swiftc: $$($(SWIFTC) --version 2>&1 | head -1)"

check-toolchain:
	@echo "=== ツールチェーン診断 ==="
	@echo "swiftc    : $$(which swiftc)"
	@echo "バージョン  : $$(swiftc --version 2>&1 | head -1)"
	@echo "SDK       : $(SWIFT_SDK)"
	@echo "ターゲット  : $(TARGET)"
	@echo ""
	@echo "--- embedded stdlib の確認 ---"
	@SWIFTC_DIR=$$(dirname $$(which swiftc)); \
	 EMBEDDED_DIR="$$SWIFTC_DIR/../lib/swift/embedded"; \
	 if [ -d "$$EMBEDDED_DIR" ]; then \
	   echo "✓ embedded stdlib あり: $$EMBEDDED_DIR"; \
	   ls "$$EMBEDDED_DIR" | head -5; \
	 else \
	   echo "✗ embedded stdlib なし: $$EMBEDDED_DIR"; \
	   echo ""; \
	   echo "  → swift.org から Swift 6.x ツールチェーンをインストールしてください:"; \
	   echo "    https://www.swift.org/download/"; \
	   echo "    インストール後: export TOOLCHAINS=<bundle-id>"; \
	 fi

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

clean:
	rm -rf $(BUILD_DIR)

# ---------------------------------------------------------------------------
# setup-hooks — Git pre-commit フックをインストールする
#
# Scripts/pre-commit を .git/hooks/pre-commit にコピーし実行権限を付与する。
# 一度だけ実行すれば、以後はコミット時に自動で Embedded ビルドが検証される。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# spectest-gen — 公式 WebAssembly testsuite の .wast → JSON + .wasm に変換
#
# wast2json (wabt) が必要: brew install wabt
#
# 変換結果は Tests/WasmRuntimeTests/spectest/ に出力される (.gitignore 対象)。
# swift test を実行すると SpectestTests がこれらを自動検出して実行する。
#
# 初回または testsuite を更新した際に実行する:
#   make spectest-gen
# ---------------------------------------------------------------------------
spectest-gen:
	@if ! command -v wast2json > /dev/null 2>&1; then \
	  echo "エラー: wast2json が見つかりません"; \
	  echo "  brew install wabt"; \
	  exit 1; \
	fi
	@mkdir -p $(SPECTEST_OUT)
	@echo "--- spec testsuite を変換中 (wast2json) ---"
	@count=0; skip=0; \
	for wast in $(SPECTEST_SRC)/*.wast; do \
	  name=$$(basename "$$wast" .wast); \
	  if wast2json "$$wast" -o "$(SPECTEST_OUT)/$$name.json" 2>/dev/null; then \
	    count=$$((count + 1)); \
	  else \
	    skip=$$((skip + 1)); \
	  fi; \
	done; \
	echo "✓ $$count ファイル変換完了 → $(SPECTEST_OUT)/  ($$skip スキップ)"

spectest-clean:
	rm -rf $(SPECTEST_OUT)
	@echo "✓ $(SPECTEST_OUT)/ を削除しました"

setup-hooks:
	@cp Scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ pre-commit フックをインストールしました"
	@echo "  Sources/WasmRuntime/ を変更してコミットすると自動で Embedded ビルドを検証します"

help:
	@echo ""
	@echo "=== Embedded Swift × Raspberry Pi Pico 2 (RP2350) ==="
	@echo ""
	@echo "ターゲット:"
	@echo "  spectest-gen     公式 testsuite (.wast) を JSON + .wasm に変換（初回・更新時）"
	@echo "  spectest-clean   変換済みファイルを削除"
	@echo "  test             swift test (macOS) + compile (Embedded) の両方を検証 [デフォルト]"
	@echo "  compile          Swift → .o のみ（ツールチェーン確認、Pico SDK 不要）"
	@echo "  build            完全ビルド → .elf / .bin / .uf2 生成（Pico SDK 必要）"
	@echo "  flash            .uf2 を BOOTSEL マウント済みの Pico にコピー"
	@echo "  setup-hooks      Git pre-commit フックをインストール（初回のみ）"
	@echo "  clean            $(BUILD_DIR)/ を削除"
	@echo "  check-toolchain  ツールチェーンの設定を診断"
	@echo ""
	@echo "設定変数（現在値）:"
	@echo "  TARGET        = $(TARGET)"
	@echo "  PICO_SDK_PATH = $(PICO_SDK_PATH)"
	@echo "  PICO_MOUNT    = $(PICO_MOUNT)"
	@echo ""
