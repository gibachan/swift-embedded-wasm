# pico-ble

Raspberry Pi Pico W 向けの Embedded Swift BLE ペリフェラル実装です。BTstack を通じて GATT サービスを公開し、iPhone などの BLE セントラルからの書き込みでオンボード LED を ON/OFF できます。

## 機能

- デバイス名 `PicoLED` として BLE アドバタイズ
- カスタムサービス UUID: `12345678-1234-5678-1234-56789abcdef0`
- 書き込み可能なキャラクタリスティック UUID: `12345678-1234-5678-1234-56789abcdef1`
  - `"1"` を書き込む → LED ON
  - `"0"` を書き込む → LED OFF
- セントラルが切断すると自動で再アドバタイズ

## 必要なもの

- Raspberry Pi Pico W または Pico 2W
- [pico-sdk](https://github.com/raspberrypi/pico-sdk)（git submodule 含む）
- CMake / Ninja
- [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads)
- Embedded Swift 対応の Swift 6.3.1 以降のツールチェーン

## ビルド方法

`build.sh` 内の環境変数を自分の環境に合わせて編集してから実行します。

```sh
cd Examples/RaspberryPiPicoW-BLE/Embedded
./build.sh
```

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `PICO_BOARD` | `pico_w` | Pico 2W の場合は `pico2_w` |
| `PICO_SDK_PATH` | `~/pico/pico-sdk` | pico-sdk のパス |
| `PICO_TOOLCHAIN_PATH` | `/opt/homebrew` | Arm ツールチェーンのパス |
| `SWIFT_TOOLCHAIN` | `~/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr` | Swift ツールチェーンのパス |

CMakeLists.txt を変更した場合はビルドディレクトリを削除してから再実行してください。

```sh
rm -rf build && ./build.sh
```

ビルド成果物は `build/` に出力されます（`pico-ble.uf2`、`pico-ble.elf` など）。

## Wasm バイナリの埋め込みと更新

### 仕組み

Wasm バイナリは GAS の `.incbin` ディレクティブを使ってアセンブラレベルでファームウェアに直接埋め込まれます。
変換やエンコードは一切行われず、`.wasm` ファイルのバイト列がそのままフラッシュ（ROM）の `.rodata` セクションに配置されます。

```
Tests/WasmRuntimeTests/wasm/blink-loop.wasm  ← ソース
        ↓  wasm-validate（オプション）― 不正なら即ビルド失敗
        ↓  wasm-opt -Oz（オプション）― blink-loop.opt.wasm を生成
        ↓  .incbin（アセンブル時）
blink_loop_wasm_start … blink_loop_wasm_end  ← ROM 上のリンカシンボル
        ↓  wasm_symbols.c でラップ
blink_loop_wasm_ptr() / blink_loop_wasm_len()  ← C 関数
        ↓  BridgingHeader.h 経由
Swift から UnsafeBufferPointer として参照
```

C ラッパーを挟む理由: Embedded Swift の C interop は `extern const uint8_t arr[]` のような不完全配列型を直接インポートできません。
`wasm_symbols.c` 側で `const uint8_t *` に変換し、Swift には通常の C 関数として公開しています。

Swift 側では以下のように参照します（`Main.swift` の `blinkLoop` 関数）。

```swift
let buf = UnsafeBufferPointer<UInt8>(
    start: blink_loop_wasm_ptr(),  // ROM 上の開始アドレス
    count: Int(blink_loop_wasm_len())  // end - start をバイト数として返す
)
```

### ビルド時に自動で行われること

`wasm-validate`（wabt）と `wasm-opt`（Binaryen）がインストールされている場合、ビルド時に以下が自動実行されます。

| ツール | 処理 | ツールがない場合 |
|--------|------|-----------------|
| `wasm-validate` | wasm の正当性を検証。不正なら**ビルドを失敗**させる | 警告を出してスキップ |
| `wasm-opt -Oz` | サイズ最適化した `blink-loop.opt.wasm` を生成してから埋め込む | 元の wasm をそのまま埋め込む |

インストール方法（macOS）:

```sh
brew install wabt      # wasm-validate を含む
brew install binaryen  # wasm-opt を含む
```

### Wasm を変更する手順

1. `.wat` ファイルを編集する

   ```
   Tests/WasmRuntimeTests/wasm/blink-loop.wat
   ```

2. `wat2wasm` で `.wasm` を再生成する

   ```sh
   wat2wasm Tests/WasmRuntimeTests/wasm/blink-loop.wat \
            -o Tests/WasmRuntimeTests/wasm/blink-loop.wasm
   ```

3. ビルドし直す（`rm -rf build` 不要）

   ```sh
   ./build.sh
   ```

   `.wasm` ファイルの変更が ninja に伝わるため、差分ビルドで正しく再アセンブルされます。

### 参照する Wasm ファイルを変更したい場合

`CMakeLists.txt` の以下の変数を書き換えてください。

```cmake
set(BLINK_LOOP_WASM_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/../Tests/WasmRuntimeTests/wasm/blink-loop.wasm)
```

変更後はビルドディレクトリを削除して CMake を再実行してください。

```sh
rm -rf build && ./build.sh
```

## 書き込み方法

Pico W を BOOTSEL モードで接続し（BOOTSEL ボタンを押しながら USB 接続）、UF2 ファイルをコピーします。

```sh
cp build/pico-ble.uf2 /Volumes/RP2040   # Pico W
cp build/pico-ble.uf2 /Volumes/RP2350   # Pico 2W
```

## 動作確認

書き込み後にデバイスが再起動し、BLE アドバタイズを開始します。nRF Connect などの BLE アプリでキャラクタリスティック（末尾 `...def1`）に `"1"` または `"0"` を書き込むと LED が点灯・消灯します。

## ファイル構成

| ファイル | 説明 |
|---------|------|
| `Main.swift` | BLE 制御ロジック。BTstack C API を直接呼び出す |
| `BridgingHeader.h` | Pico SDK / BTstack の C ヘッダを Swift に公開するブリッジングヘッダ |
| `blink_loop_wasm.s.in` | `.incbin` で Wasm バイナリを ROM に埋め込むアセンブラのテンプレート。CMake が絶対パスを展開して `build/blink_loop_wasm.s` を生成する |
| `wasm_symbols.c` | `.incbin` で定義されたリンカシンボルを Swift から使える C 関数（`blink_loop_wasm_ptr` / `blink_loop_wasm_len`）としてラップする |
| `include/btstack_config.h` | BTstack のコンパイル設定（BLE ペリフェラルロール、バッファサイズなど） |
| `include/lwipopts.h` | lwIP の最小設定（CYW43 ドライバが要求するため用意） |
| `CMakeLists.txt` | CMake ビルド定義 |
| `build.sh` | 環境変数設定とビルドを一括実行するスクリプト |
