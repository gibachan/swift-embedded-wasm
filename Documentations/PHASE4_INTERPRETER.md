# Phase 4 — Wasm インタプリタ実装

## 目的

Phase 3 で実装したパーサーと組み合わせ、Wasm モジュールを実際に実行できるインタプリタを構築する。
Stack Machine・Validation・Linear Memory・Host Function を段階的に実装する。

---

## Wasm 仕様について

スタックマシンの仕組み・値型・トラップ・対象バージョン・命令セットの詳細は `docs/WASM_SPEC.md` を参照。

実装上の要点のみ以下に抜粋する。

- 対象: **WebAssembly 1.0 MVP**、初期は `i32` 命令サブセットのみ
- Wasm はレジスタを持たないスタックマシン。命令はスタックを介して値をやり取りする
- 実行時コンポーネント: Value Stack / Call Stack / Call Frame（詳細は `docs/WASM_SPEC.md`）

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

- [ ] `i32.add` を含む簡単な Wasm 関数を実行できる
- [ ] ローカル変数の get/set が正しく動作する
- [ ] 関数呼び出し（call / return）が動作する
- [ ] Type Validation が不正な Wasm を弾ける
- [ ] Linear Memory への load/store が動作する
- [ ] Host Function 経由で Swift のコードを呼び出せる
