# WebAssembly 仕様リファレンス

本プロジェクトで参照する WebAssembly 仕様をまとめたドキュメント。
実装の判断基準・設計の根拠として参照する。

---

## 仕様バージョンとターゲット

| バージョン | 標準化 | 主な内容 |
|-----------|--------|---------|
| **WebAssembly 1.0（MVP）** | 2019年 | コアの最小仕様。整数・浮動小数点・線形メモリ・関数呼び出し |
| **WebAssembly 2.0** | 2022年 | 多値返却・参照型・SIMD・Bulk Memory・符号拡張演算子など |

**本プロジェクトのターゲット: WebAssembly 1.0（MVP）**

- MVP は有用な Wasm を実行するために必要な最小セットとして設計されており、学習・実装の出発点として最適
- 2.0 以降の機能（SIMD / 参照型 / スレッドなど）は Embedded 環境と相性が悪く対象外
- 参考実装の Wasm3 も MVP ベース

---

## 実装するサブセット

### Step 1 — 最初に動かす最小セット

- **型**: `i32` のみ
- **算術**: `i32.const` / `i32.add` / `i32.sub` / `i32.mul`
- **ローカル変数**: `local.get` / `local.set`
- **制御**: `call` / `return` / `end`
- **セクション**: Type / Function / Export / Code

### Step 2 — 順次追加

- `i32` の比較・論理演算（`i32.eq` / `i32.lt_s` / `i32.and` など）
- 制御フロー: `if` / `block` / `loop` / `br` / `br_if`
- `i64`（必要になったタイミングで）

### 実装済み（Phase 4 で追加）

- `f32` — `f32.const` および算術・比較・単項演算命令（`add` / `sub` / `mul` / `div` / `min` / `max` / `sqrt` / `abs` / `neg` / `ceil` / `floor` / `trunc` / `nearest` / `copysign` / 比較 6 種）
- `f64` — `f64.const` および算術・比較・単項演算命令の全セット
  - 比較 6 種（0x61–0x66）: `f64.eq` / `f64.ne` / `f64.lt` / `f64.gt` / `f64.le` / `f64.ge` → `i32`
  - 単項 7 種（0x99–0x9F）: `f64.abs` / `f64.neg` / `f64.ceil` / `f64.floor` / `f64.trunc` / `f64.nearest` / `f64.sqrt` → `f64`
  - 二項算術 7 種（0xA0–0xA6）: `f64.add` / `f64.sub` / `f64.mul` / `f64.div` / `f64.min` / `f64.max` / `f64.copysign` → `f64`
- `call_indirect` — 複数テーブルのサポートを含む。型チェック（result 型含む）を実装済み
- メモリ命令（全 load/store 命令）
  - `i32.load`（0x28）、`i64.load`（0x29）、`f32.load`（0x2A）、`f64.load`（0x2B）
  - `i32.load8_s`（0x2C）、`i32.load8_u`（0x2D）、`i32.load16_s`（0x2E）、`i32.load16_u`（0x2F）
  - `i64.load8_s`（0x30）、`i64.load8_u`（0x31）、`i64.load16_s`（0x32）、`i64.load16_u`（0x33）
  - `i64.load32_s`（0x34）、`i64.load32_u`（0x35）
  - `i32.store`（0x36）、`i64.store`（0x37）、`f32.store`（0x38）、`f64.store`（0x39）
  - `i32.store8`（0x3A）、`i32.store16`（0x3B）
  - `i64.store8`（0x3C）、`i64.store16`（0x3D）、`i64.store32`（0x3E）
  - `memory.grow`（0x40）
- Global 変数（`global.get` / `global.set`）。init 式で `i64.const` / `f64.const` をサポート済み

### 後回し（MVP に含まれるが急がない）

- 型変換命令（`i32.trunc_f32_s`、`f64.promote_f32`、`i32.reinterpret_f32` など）
- `memory.size`（0x3F） — パース時に `invalidInstruction` を送出する既知の問題あり（`unimplemented` に変更すべき）

### 対象外

- SIMD / スレッド / 例外処理 / GC
- WASI（WebAssembly System Interface）

---

## バイナリフォーマット

### ファイル構造

```text
[magic: 4 bytes] [version: 4 bytes] [section...] [section...]
```

| フィールド | 値 |
|-----------|-----|
| Magic | `0x00 0x61 0x73 0x6D`（`\0asm`） |
| Version | `0x01 0x00 0x00 0x00`（リトルエンディアン） |

### セクション構造

各セクションは以下のレイアウト。

```text
[section_id: u8] [size: u32 LEB128] [content: size bytes]
```

Wasm 仕様はセクションの出現順を保証している。

| Section | ID | 内容 |
|---------|-----|------|
| Type    | 1  | 関数シグネチャの定義 |
| Import  | 2  | 外部からインポートする関数・メモリ等 |
| Function | 3 | 各関数が参照するシグネチャのインデックス |
| Table   | 4  | 関数テーブル |
| Memory  | 5  | 線形メモリの定義 |
| Global  | 6  | グローバル変数 |
| Export  | 7  | 外部公開する関数・メモリ等 |
| Start   | 8  | 起動時に呼ぶ関数 |
| Element | 9  | テーブルの初期値 |
| Code    | 10 | 関数本体のバイトコード |
| Data    | 11 | メモリの初期値 |

---

## LEB128

Wasm は整数を **LEB128**（Little Endian Base 128）形式でエンコードする。
可変長エンコードで、小さい値ほど少ないバイト数で表現できる。

```text
各バイトのビット構造:
  bit 7 (MSB) = 継続ビット: 1 なら後続バイトがある、0 なら最終バイト
  bit 6〜0    = データの 7 ビット

値 300 のエンコード例:
  300 = 0b1_0010_1100
  → [0xAC, 0x02]  (2 バイト)
  0xAC = 1010_1100  (継続ビット=1, データ=010_1100)
  0x02 = 0000_0010  (継続ビット=0, データ=000_0010)
```

符号なし整数には **ULEB128**、符号付き整数には **SLEB128** を使い分ける。

---

## スタックマシン

Wasm はレジスタを持たない **スタックマシン**（Stack Machine）方式。
命令は「スタックから値を取り出し、演算して結果をスタックに積む」という形で動作する。

```text
i32.const 3   → stack: [3]
i32.const 4   → stack: [3, 4]
i32.add       → stack: [7]      (3+4 を計算し積む)
return        → 戻り値として 7 を返す
```

### 実行時の主要コンポーネント

| コンポーネント | 役割 |
|--------------|------|
| Value Stack | 命令が操作するオペランドスタック |
| Call Stack | 関数呼び出しのフレームを管理 |
| Call Frame | ローカル変数・戻り先アドレスを保持 |

---

## 値型

| 型 | 説明 |
|----|------|
| `i32` | 32 ビット整数（符号なし・符号付きの区別は命令側で行う） |
| `i64` | 64 ビット整数 |
| `f32` | 32 ビット浮動小数点 |
| `f64` | 64 ビット浮動小数点 |

---

## 線形メモリ（Linear Memory）

Wasm モジュールが持つ連続したバイト配列。Wasm から直接アクセスできる唯一のメモリ空間。

- 単位は **Page**（1 Page = 64KB）
- 初期サイズと最大サイズをモジュールで宣言
- `memory.grow` 命令で動的拡張可能（Embedded では固定サイズにする）
- すべてのアクセスに境界チェックが必要（範囲外はトラップ）

---

## トラップ

不正な操作が発生した場合、Wasm ランタイムは **トラップ**（実行中断）を発生させる。
例：ゼロ除算・メモリ境界外アクセス・スタックオーバーフロー・型不一致。

トラップは例外ではなくランタイムによる強制終了に近い。
本プロジェクトでは `WasmTrap` 型で表現する。

```swift
enum WasmTrap {
    case divisionByZero
    case memoryOutOfBounds
    case stackOverflow
    case unreachable
    case indirectCallTypeMismatch
}
```

---

## 仕様書・参考リンク

| リソース | 用途 |
|---------|------|
| [WebAssembly Core Spec](https://webassembly.github.io/spec/core/) | バイナリ形式・実行モデルの一次ソース |
| [WebAssembly Reference Manual](https://github.com/sunfishcode/wasm-reference-manual) | 読みやすい非公式リファレンス |
| [wat2wasm (WABT)](https://github.com/WebAssembly/wabt) | テキスト形式（.wat）からバイナリを生成するツール |
| [Wasm3](https://github.com/wasm3/wasm3) | 参考実装（Embedded 向け MVP インタプリタ） |
