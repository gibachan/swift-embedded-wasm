# Phase 4 — Wasm インタプリタ実装

## 目的

Phase 3 で実装したパーサーと組み合わせ、Wasm モジュールを実際に実行できるインタプリタを構築する。
Stack Machine・Validation・Linear Memory・Host Function を段階的に実装する。

---

## Wasm 仕様について

スタックマシンの仕組み・値型・トラップ・対象バージョン・命令セットの詳細は `Documentations/WASM_SPEC.md` を参照。

実装上の要点のみ以下に抜粋する。

- 対象: **WebAssembly 1.0 MVP**、初期は `i32` 命令サブセットのみ
- Wasm はレジスタを持たないスタックマシン。命令はスタックを介して値をやり取りする
- 実行時コンポーネント: Value Stack / Call Stack / Call Frame（詳細は `Documentations/WASM_SPEC.md`）

---

## Step 1: Minimal Interpreter（Stack Machine）

### 初期対応命令

| 命令 | 動作 |
|------|------|
| `i32.const n` | 定数 n をスタックに積む |
| `local.get i` | ローカル変数 i をスタックに積む |
| `local.set i` | スタックトップをローカル変数 i に格納 |
| `i32.add` | スタックから 2 値を取り出し加算して積む |
| `i32.sub` | スタックから 2 値を取り出し減算して積む |
| `call n` | 関数 n を呼び出す |
| `return` | 現在の関数から戻る |
| `end` | ブロック・関数の終端 |

### 実装構造

```swift
struct ValueStack {
    // 実行時のオペランドスタック
}

struct CallFrame {
    var functionIndex: UInt32
    var locals: [WasmValue]
    var returnAddress: Int  // バイトコード上の戻り先
}

enum WasmValue {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
}
```

---

## Step 2: Validation（型検証）

### Wasm Validation とは

Wasm は実行前に**静的な型検証**を行う仕様になっている。
検証に通ったモジュールは、実行時に型エラーが起きないことが保証される。

検証内容：
- 関数シグネチャの整合性チェック
- スタックの型が命令の期待する型と一致するか
- ジャンプ先が有効な範囲か

```swift
enum ValueType {
    case i32
    case i64
    case f32
    case f64
}
```

組み込み向けでは、Validation を省略して実行速度を優先する選択肢もある。
本プロジェクトでは「学習」を目的とするため、まず実装して理解する。

---

## Step 3: Linear Memory

### Linear Memory とは

Wasm は **線形メモリ**（Linear Memory）と呼ばれる連続したバイト配列を持つ。
ホスト（Swift 側）から見れば単なるバッファだが、Wasm から見れば唯一アクセスできるメモリ空間。

```text
offset: 0    100   200   ...   65536 (64KB = 1 Page)
        [データ][スタック][ヒープ...]
```

**境界チェック**: メモリアクセスは必ず範囲内かを検証し、範囲外ならトラップ（実行中断）する。

```swift
struct LinearMemory {
    private var buffer: [UInt8]
    let pageSize = 65536  // 64KB

    func load32(offset: UInt32) throws -> Int32
    func store32(offset: UInt32, value: Int32) throws
}
```

組み込みでは動的拡張を避け、固定サイズで確保する。

---

## Step 4: Host Function

### Host Function とは

Wasm 単体ではファイルやハードウェアにアクセスできない。
**Host Function** は、ホスト（Swift 側）の関数を Wasm に公開する仕組みで、
これを通じて GPIO や OLED を操作する。

```text
Wasm コード
   │ call "env" "digitalWrite"
   ▼
Host Function Layer（Swift）
   │
   ▼
Pico GPIO
```

### Swift 的設計

```swift
protocol HostFunction {
    var moduleName: String { get }
    var functionName: String { get }
    func call(args: [WasmValue]) throws -> WasmValue?
}
```

型安全のため、GPIO ピン番号は `Int32` の生値ではなく専用型で扱う。

```swift
struct GPIOPin {
    let number: UInt8
}
```

### 初期 Host API

| 関数名 | シグネチャ | 機能 |
|--------|-----------|------|
| `digitalWrite` | `(i32, i32) -> void` | GPIO 出力 |
| `digitalRead` | `(i32) -> i32` | GPIO 入力 |
| `sleep` | `(i32) -> void` | 待機（ms） |
| `oledDrawText` | `(i32, i32, i32) -> void` | OLED 表示 |

---

## 成功基準

- [x] `i32.add` を含む簡単な Wasm 関数を実行できる
- [x] ローカル変数の get/set が正しく動作する
- [x] 関数呼び出し（call / return）が動作する
- [x] Type Validation が不正な Wasm を弾ける（macOS ビルドのみ）
- [x] Linear Memory への load/store が動作する
- [x] Host Function 経由で Swift のコードを呼び出せる

## 追加実装済み（Step 1〜4 以降）

- [x] `i64` 全算術・比較・ビット演算命令（`i64.add` / `i64.sub` / `i64.mul` / `i64.div_s` / ... など）
- [x] `f32` 算術・比較・単項演算命令（`f32.add` / `f32.sqrt` / `f32.le` など）
- [x] `f64` 算術・比較・単項演算命令の全セット
  - 比較 6 種（0x61–0x66）: `f64.eq` / `f64.ne` / `f64.lt` / `f64.gt` / `f64.le` / `f64.ge` → `i32`
  - 単項 7 種（0x99–0x9F）: `f64.abs` / `f64.neg` / `f64.ceil` / `f64.floor` / `f64.trunc` / `f64.nearest` / `f64.sqrt` → `f64`
  - 二項算術 7 種（0xA0–0xA6）: `f64.add` / `f64.sub` / `f64.mul` / `f64.div` / `f64.min` / `f64.max` / `f64.copysign` → `f64`
- [x] `call_indirect`（複数テーブルサポート、result 型チェック含む）
- [x] Global 変数（`global.get` / `global.set`）
- [x] フラット bytecode への移行（`block` / `loop` / `if` が `indirect case` を使わずジャンプオフセットで管理）
- [x] メモリ命令（全 load/store 命令）
  - `i32.load`（0x28）、`i64.load`（0x29）、`f32.load`（0x2A）、`f64.load`（0x2B）
  - `i32.load8_s`（0x2C）、`i32.load8_u`（0x2D）、`i32.load16_s`（0x2E）、`i32.load16_u`（0x2F）
  - `i64.load8_s`（0x30）、`i64.load8_u`（0x31）、`i64.load16_s`（0x32）、`i64.load16_u`（0x33）
  - `i64.load32_s`（0x34）、`i64.load32_u`（0x35）
  - `i32.store`（0x36）、`i64.store`（0x37）、`f32.store`（0x38）、`f64.store`（0x39）
  - `i32.store8`（0x3A）、`i32.store16`（0x3B）
  - `i64.store8`（0x3C）、`i64.store16`（0x3D）、`i64.store32`（0x3E）
  - `memory.grow`（0x40）
- [x] `i64.extend_i32_s`（型変換命令の一部）

### 既知の未対応・TODO（Embedded フェーズ向け）

- `memory.size`（0x3F）: パース時に `invalidInstruction` を送出する既知の問題あり（`unimplemented` に変更すべき）
- 32 ビットターゲットでの実効アドレス計算: 現在 `let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)` と記述しているが、32 ビット環境では `Int` が 32 ビット幅のため、加算がオーバーフローする可能性がある。Embedded フェーズでは `UInt64` 中間計算に変更が必要（詳細は `Documentations/EMBEDDED_SWIFT.md` の「メモリアクセスの実効アドレス計算」を参照）

### 設計上の対象外事項

**クロスモジュール・リンキング**（テーブル/メモリインポートによるモジュール間共有）は実装を見送っている。

spectest の `linking0` が 1 件失敗しているのはこの設計判断による既知の制限事項である。詳細な理由は `Documentations/WASM_SPEC.md` の「クロスモジュール・リンキングを対象外とする理由」を参照。
