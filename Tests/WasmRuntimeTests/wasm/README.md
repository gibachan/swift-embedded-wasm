# wasm/

このディレクトリには、Runtime の動作検証・テスト用の WebAssembly テキストフォーマット（`.wat`）ファイルを置く。

## ファイル構成

| ファイル | 内容 |
|---|---|
| `*.wat` | WebAssembly テキスト形式のソース |
| `*.wasm` | `wat2wasm` で変換したバイナリ（生成物、git 管理外） |

## 前提ツール

[wabt](https://github.com/WebAssembly/wabt) に含まれる `wat2wasm` コマンドが必要。

```sh
brew install wabt
```

## 使い方

```sh
# wasm/ ディレクトリに移動
cd wasm

# すべての .wat を .wasm に変換
make

# 特定のファイルだけ変換
make i32-add.wasm

# 生成した .wasm を削除
make clean
```

## .wat の追加方法

1. このディレクトリに `<name>.wat` を作成する
2. `make` を実行すると `<name>.wasm` が生成される
