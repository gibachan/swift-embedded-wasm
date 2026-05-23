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
cd pico-ble
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
| `include/btstack_config.h` | BTstack のコンパイル設定（BLE ペリフェラルロール、バッファサイズなど） |
| `include/lwipopts.h` | lwIP の最小設定（CYW43 ドライバが要求するため用意） |
| `CMakeLists.txt` | CMake ビルド定義 |
| `build.sh` | 環境変数設定とビルドを一括実行するスクリプト |
