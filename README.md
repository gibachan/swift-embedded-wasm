# swift-embedded-wasm

Embedded Swift で実装する WebAssembly Runtime（Raspberry Pi Pico 2 / RP2350 向け）。

## ビルド

### 前提条件

| ツール | 用途 | インストール |
|---|---|---|
| [swiftly](https://github.com/swiftlang/swiftly) | Swift ツールチェーン管理 | `curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh \| bash` |
| Swift 6.x (embedded stdlib 付き) | Embedded Swift コンパイル | `swiftly install latest` |

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
