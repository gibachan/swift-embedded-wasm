# pico-ble

Raspberry Pi Pico W 向けの Embedded Swift BLE ペリフェラル実装です。BTstack を通じて GATT サービスを公開し、iOS アプリから BLE 経由で WASM バイナリを受信・実行できます。

## 機能

- デバイス名 `PicoLED` として BLE アドバタイズ
- カスタムサービス UUID: `12345678-1234-5678-1234-56789abcdef0`
- 書き込み可能なキャラクタリスティック UUID: `12345678-1234-5678-1234-56789abcdef1`
  - コマンドバイト（0xF0 / 0xF1 / 0xF2）で WASM バイナリのチャンク転送と実行を制御
- WASM モジュールを受信後に即時実行（`WasmInterpreter` 使用）
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

## BLE 経由 WASM 転送プロトコル

### 概要

iOS アプリは単一の書き込み可能キャラクタリスティック（UUID 末尾 `...def1`）に対してパケットを送信します。
各パケットの先頭バイトがコマンドを示すステートマシン方式を採用しています。

```
0xF0 → 0xF1 × N → 0xF2
  ↑        ↑          ↑
転送開始  チャンク群  実行開始
```

### コマンド仕様

| コマンドバイト | ペイロード | 説明 |
|---|---|---|
| `0xF0` | bytes[1..2] = 合計サイズ（UInt16 LE） | WASM 転送開始。受信バッファとカウンタをリセットする |
| `0xF1` | bytes[1..2] = 書き込みオフセット（UInt16 LE）、bytes[3..] = データ | WASM チャンクデータ。指定オフセットから受信バッファに書き込む |
| `0xF2` | なし | 受信完了後に WASM を実行する。未受信バイトが残っている場合は無視する |

### チャンクサイズの決定

iOS 側は `peripheral.maximumWriteValueLength(for: .withResponse)` で MTU から最大書き込みサイズを取得し、
コマンドバイト（1 バイト）とオフセット（2 バイト）のヘッダ分を差し引いた残りをデータ部として使用します。

実際の WASM 転送では `withResponse` 書き込みを使用し、前のパケットの書き込み完了通知（`didWriteValueFor`）を受け取ってから次のパケットを送信することで順序保証と輻輳制御を行っています。

### 受信バッファ

Pico 側では BSS 領域（RAM）に静的な 8KB バッファを確保しています。

```c
// wasm_recv_buf.c
static uint8_t buf[8192];  // BSS 領域 — 起動時にゼロ初期化される
uint8_t *wasm_recv_buf_ptr(void) { return buf; }
uint32_t wasm_recv_buf_size(void) { return 8192; }
```

Swift からは `BridgingHeader.h` 経由でアクセスします。

```swift
let wasmBuf = UnsafeBufferPointer<UInt8>(
    start: wasm_recv_buf_ptr(),
    count: Int(wasmRecvLen)
)
```

### WASM エントリポイント規約

転送する WASM モジュールは以下の規約に従う必要があります。

- エントリポイント関数は引数なし・戻り値なし
- 関数は `(export "run" ...)` としてエクスポートすること
- Pico 側は `call(functionIndex: module.importedFunctionCount, args: [])` でエントリポイントを呼び出す
  （最初のローカル関数 = インポート関数の直後）

ホスト関数として `env::blink` が提供されています。`i32` 引数はなく、呼び出すと LED を 300ms ON → 300ms OFF します。

```wat
(module
  (import "env" "blink" (func))  ;; Pico の LED を 1 回点滅させる
  (func (export "run")
    call 0  ;; blink を 3 回呼ぶ例
    call 0
    call 0
  )
)
```

## 書き込み方法

Pico W を BOOTSEL モードで接続し（BOOTSEL ボタンを押しながら USB 接続）、UF2 ファイルをコピーします。

```sh
cp build/pico-ble.uf2 /Volumes/RP2040   # Pico W
cp build/pico-ble.uf2 /Volumes/RP2350   # Pico 2W
```

## 動作確認

1. Pico W にファームウェアを書き込む
2. iOS アプリ（`Examples/RaspberryPiPicoW-BLE/iOS/`）を起動する
3. アプリが自動で `PicoLED` を発見して接続する
4. WASM リストからいずれかを選択して「Send」をタップする
5. 転送完了後、Pico の LED が点滅する

## ファイル構成

| ファイル | 説明 |
|---------|------|
| `Main.swift` | BLE 制御ロジック。BTstack C API を直接呼び出す。`attWriteCallback` が 0xF0/0xF1/0xF2 のステートマシンを実装する |
| `wasm_recv_buf.c` | BSS 領域に確保した 8KB の静的 WASM 受信バッファ。`wasm_recv_buf_ptr()` / `wasm_recv_buf_size()` アクセサを公開する |
| `BridgingHeader.h` | Pico SDK / BTstack の C ヘッダを Swift に公開するブリッジングヘッダ |
| `include/btstack_config.h` | BTstack のコンパイル設定（BLE ペリフェラルロール、バッファサイズなど） |
| `include/lwipopts.h` | lwIP の最小設定（CYW43 ドライバが要求するため用意） |
| `CMakeLists.txt` | CMake ビルド定義 |
| `build.sh` | 環境変数設定とビルドを一括実行するスクリプト |
| `wasm_symbols.c` | 旧静的埋め込み方式のシンボルラッパー（現在はビルド対象外） |
| `blink_loop_wasm.s.in` | 旧静的埋め込み方式のアセンブラテンプレート（現在はビルド対象外） |
