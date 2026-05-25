# swift-embedded-wasm

Embedded Swift で実装する WebAssembly Runtime（Raspberry Pi Pico 2 / RP2350 向け）。

## 構成

```
swift-embedded-wasm/
├── Sources/WasmRuntime/   # 共有ロジック（macOS / Pico 両方でコンパイル）
├── Tests/WasmRuntimeTests/# macOS 上でのテスト（swift test）
├── src/main.swift         # Pico 固有のエントリポイント
├── pico-ble/              # BLE ペリフェラル実装（Pico W 向け、CMake ビルド）
├── Package.swift          # macOS 向けビルド定義（テスト・開発用）
└── Makefile               # Pico 向けクロスコンパイル定義
```

`Sources/WasmRuntime/` 以下のコードは macOS（SwiftPM）と Pico（Makefile）の両方でコンパイルされます。
Pico 固有のハードウェア操作は `src/main.swift` に分離します。

## ビルド

### 前提条件

| ツール | 用途 | インストール |
|---|---|---|
| [swiftly](https://github.com/swiftlang/swiftly) | Swift ツールチェーン管理 | `curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh \| bash` |
| Swift 6.x (embedded stdlib 付き) | Embedded Swift コンパイル | `swiftly install latest` |

### macOS でのテスト（Pico 不要）

```sh
swift test
```

`Sources/WasmRuntime/` の共有ロジックを macOS 上でテストできます。実機なしで開発・検証する際のメインの手段です。

テストは 2 種類あります。

#### ユニットテスト

`Tests/WasmRuntimeTests/` 以下の手書きテスト群。パーサー・インタプリタの動作を個別に検証します。

#### Spectest 準拠テスト

公式 [WebAssembly Spec Testsuite](https://github.com/WebAssembly/testsuite) を使って、実装が Wasm 標準に沿っているか継続的に確認するテストです。

**初回セットアップ（`wabt` が必要）**

```sh
brew install wabt       # wast2json をインストール
make spectest-gen       # .wast → JSON + .wasm に変換（Tests/WasmRuntimeTests/spectest/ に出力）
```

その後は通常の `swift test` に自動で含まれます。

**各テストの意味**

| 結果 | 意味 |
|---|---|
| PASS | 仕様通りに動作している |
| SKIP | 未実装の命令・型を使用しているため実行できない |
| FAIL | 仕様との不一致（バグ）|

新しい命令を実装するごとに、対応するテストが SKIP → PASS または FAIL に変わります。FAIL が出た場合は仕様との不一致を示します。

**統計の確認**

`SpectestTests.swift` 内の以下の行のコメントを外すと、ファイルごとの pass/skip/fail 数が出力されます。

```swift
// print("[\(file.name)] pass=\(runner.passCount) skip=\(runner.skipCount) fail=\(runner.failCount)")
```

**生成ファイルの削除**

```sh
make spectest-clean
```

`Tests/WasmRuntimeTests/spectest/` は `.gitignore` 対象です。

### Swift コンパイルのみ（Pico SDK 不要）

```sh
make compile
```

Embedded Swift のツールチェーンが正しく設定されているか確認するのに最適です。
成功すると `build/pico-wasm.o` が生成されます。

### 完全ビルド（.uf2 生成、Pico SDK 必要）

```sh
# Pico SDK のクローン（初回のみ）
git clone https://github.com/raspberrypi/pico-sdk ~/pico/pico-sdk
cd ~/pico/pico-sdk && git submodule update --init

# ビルド
make build
```

`build/` 以下に `.elf` / `.bin` / `.uf2` が生成されます。

### Pico への書き込み

1. BOOTSEL ボタンを押しながら USB 接続（`/Volumes/RPI-RP2` としてマウントされる）
2. 以下を実行:

```sh
make flash
```

### 環境変数

| 変数 | デフォルト | 説明 |
|---|---|---|
| `PICO_SDK_PATH` | `~/pico/pico-sdk` | Pico SDK のパス |
| `PICO_MOUNT` | `/Volumes/RPI-RP2` | Pico のマウントパス |

```sh
# カスタムパスを指定する場合
make build PICO_SDK_PATH=/path/to/pico-sdk
make flash PICO_MOUNT=/Volumes/RPI-RP2
```
