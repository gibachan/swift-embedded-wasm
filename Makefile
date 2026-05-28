# =============================================================================
# Makefile — swift-embedded-wasm
# =============================================================================
#
# 使い方:
#   make              test と同じ（両方のチェックを実行）
#   make test         swift test (macOS) + Embedded Swift ビルド検証
#   make compile      Swift → .o のみ（Embedded Swift 検証、Pico SDK 不要）
#   make spectest-gen 公式 WebAssembly testsuite の .wast → JSON + .wasm に変換
#   make setup-hooks  Git pre-commit フックをインストール（初回のみ）
#   make clean        ビルド成果物を削除
#   make help         このヘルプを表示
#
# =============================================================================

# --- プロジェクト設定 ---------------------------------------------------------
PROJECT     := pico-wasm
MODULE_NAME := Main

BUILD_DIR := build

# ビルド対象の Swift ソース（macOS / Pico 共有ロジック層）
SWIFT_SRCS := $(wildcard Sources/WasmRuntime/*.swift)

# --- ターゲット設定 -----------------------------------------------------------
#
# ARMv8-M (Cortex-M33) は ARMv7-M 上位互換なので armv7em でコンパイルした
# コードは RP2350 上でそのまま動く。
#
TARGET := armv7em-none-none-eabi

# --- ツール -------------------------------------------------------------------
SWIFTC := $(HOME)/.swiftly/bin/swiftc

# --- SDK パス（macOS ホスト用）------------------------------------------------
SWIFT_SDK := $(shell xcrun --show-sdk-path 2>/dev/null)

# --- Swift コンパイルフラグ ---------------------------------------------------
SWIFTFLAGS := \
  -target $(TARGET) \
  -enable-experimental-feature Embedded \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -wmo \
  -Osize \
  -module-name $(MODULE_NAME) \
  -sdk $(SWIFT_SDK)

# --- spectest パス -----------------------------------------------------------
SPECTEST_SRC := third_party/testsuite
SPECTEST_OUT := Tests/WasmRuntimeTests/spectest

# =============================================================================
# ターゲット定義
# =============================================================================

.PHONY: all test swift-test compile clean setup-hooks spectest-gen spectest-clean check-tools check-toolchain help

# デフォルトは test — 素の `make` で両環境のチェックを行う
all: test

# ---------------------------------------------------------------------------
# test — ロジック検証（macOS）+ Embedded Swift ビルド検証
#
# 2 段階で検証する:
#   1. swift test  : macOS 上でユニットテストを実行（高速、Pico 実機不要）
#   2. make compile: 同じソースが Embedded Swift でもコンパイルできることを確認
#
# swift test が失敗した時点で compile は実行されない。
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
# compile — Swift → .o のみ（Embedded Swift 検証）
#
# Pico SDK は不要。swiftc が Embedded Swift に対応していれば動作する。
# pre-commit フックからも呼ばれる。
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

clean:
	rm -rf $(BUILD_DIR)

# ---------------------------------------------------------------------------
# setup-hooks — Git pre-commit フックをインストールする
#
# Scripts/pre-commit を .git/hooks/pre-commit にコピーし実行権限を付与する。
# 一度だけ実行すれば、以後はコミット時に自動で Embedded ビルドが検証される。
# ---------------------------------------------------------------------------
setup-hooks:
	@cp Scripts/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ pre-commit フックをインストールしました"
	@echo "  Sources/WasmRuntime/ を変更してコミットすると自動で Embedded ビルドを検証します"

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

help:
	@echo ""
	@echo "=== swift-embedded-wasm ==="
	@echo ""
	@echo "ターゲット:"
	@echo "  spectest-gen     公式 testsuite (.wast) を JSON + .wasm に変換（初回・更新時）"
	@echo "  spectest-clean   変換済みファイルを削除"
	@echo "  test             swift test (macOS) + compile (Embedded) の両方を検証 [デフォルト]"
	@echo "  compile          Swift → .o のみ（ツールチェーン確認、Pico SDK 不要）"
	@echo "  setup-hooks      Git pre-commit フックをインストール（初回のみ）"
	@echo "  clean            $(BUILD_DIR)/ を削除"
	@echo "  check-toolchain  ツールチェーンの設定を診断"
	@echo ""
	@echo "設定変数（現在値）:"
	@echo "  TARGET    = $(TARGET)"
	@echo "  SWIFT_SDK = $(SWIFT_SDK)"
	@echo ""
