# Embedded Swift 実装ガイド

Embedded Swift は通常の Swift（macOS/iOS 向け）と比べて利用できる機能が大幅に制限される。
本ドキュメントでは、Embedded Swift 環境でコードを書く際に特別に考慮すべき点をまとめる。

---

## 1. 使用できない機能

### Existential 型（`any Protocol`）

プロトコル型を値として扱う existential は使用できない。

```swift
// NG: Embedded Swift では使用不可
func process(_ stream: any ByteStream) { ... }

// OK: ジェネリック制約で代替する
func process<S: ByteStream>(_ stream: inout S) { ... }
```

**理由**: Existential はランタイムに型情報（プロトコルウィットネステーブル）を保持するが、
Embedded Swift ではそのランタイム機構が存在しない。

### リフレクション

`Mirror` や `type(of:)` によるランタイム型情報の取得は使用できない。

```swift
// NG
let mirror = Mirror(reflecting: value)
```

型の判別は enum の associated value やジェネリックで静的に行う。

### Foundation フレームワーク

`import Foundation` は使用できない。依存する型もすべて使用不可。

| 使用不可 | 代替 |
|---|---|
| `Data` | `[UInt8]` / `UnsafeBufferPointer<UInt8>` |
| `String`（動的） | `StaticString` / バイト列 |
| `URL` | 文字列リテラル / 静的定数 |
| `Date` | `UInt64`（tick カウント等） |

### 動的メモリ割り当て（環境依存）

ターゲット環境によってはヒープが存在しない、またはサイズが極めて限られる。

```swift
// 要注意: 動的割り当てが発生する操作
var array = [UInt8]()
array.append(...)    // ヒープ割り当て発生

// 代替: 固定サイズのスタック配列
var buffer: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
```

Raspberry Pi Pico (RP2350) は 520 KB の SRAM を持つが、
スタック・グローバル変数・ヒープをすべてこの範囲に収める必要がある。

### Untyped Error（`any Error`）

Swift 6 以前のスタイルの `throws`（型なし）は existential `any Error` を使うため避ける。

---

## 2. 使用すべきパターン

### ジェネリックによる抽象化

Existential の代わりに、プロトコルをジェネリック制約として使う。
コンパイル時に型が確定するため、動的ディスパッチが発生しない。

```swift
protocol ByteStream {
    mutating func consume() throws(LEB128Error) -> UInt8
}

// コンパイル時に S の実体が決定 → 静的ディスパッチ
func decode<S: ByteStream>(from stream: inout S) throws(LEB128Error) -> UInt32 {
    ...
}
```

### 型付き `throws`（Swift 6）

エラー型を具体的に指定することで `any Error` existential を回避できる。

```swift
// OK: 具体的なエラー型を指定
func consume() throws(LEB128Error) -> UInt8

// NG: any Error を内部で使用する
func consume() throws -> UInt8
```

### `UnsafeBufferPointer` によるゼロコピー読み出し

バイト列の処理にはポインタを直接扱うことでヒープ割り当てを回避する。

```swift
struct BufferStream: ByteStream {
    let buffer: UnsafeBufferPointer<UInt8>   // ゼロコピー
    var offset: Int

    mutating func consume() throws(LEB128Error) -> UInt8 {
        guard offset < buffer.count else { throw .insufficientBytes }
        defer { offset += 1 }
        return buffer[offset]
    }
}
```

バッファの生存期間は呼び出し元が管理する。
`withUnsafeBufferPointer` のクロージャ内で使用するか、
静的・グローバルバッファへのポインタとして渡す。

### 値型（struct / enum）の優先

クラス（参照型）はヒープ割り当てが発生する。
Embedded Swift ではスタックに収まる値型を基本とする。

```swift
// NG: ヒープ割り当て発生
class WasmModule { ... }

// OK: スタック割り当て
struct WasmModule { ... }
```

---

## 3. パフォーマンス最適化

### `@inlinable`：ジェネリック関数への必須指定

#### 通常の Swift との違い

Swift のモジュール境界では、ジェネリック関数の実装は外部から見えない。
外部モジュールからの呼び出しは「特殊化なし」で動的ディスパッチになる。

```
@inlinable なし（通常 public）
  呼び出し側 → プロトコルウィットネステーブル経由 → 動的ディスパッチ
  → Embedded Swift ではランタイム機構が存在しないためコンパイルエラーになる場合がある

@inlinable あり
  呼び出し側 → 実装が展開・特殊化される → 静的ディスパッチ
  → コンパイル時に全て解決される
```

#### Embedded Swift で `@inlinable` が実質的に必須な理由

Embedded Swift ではプロトコルウィットネステーブルの動的解決が利用できない。
そのためジェネリック関数はコンパイル時に特殊化されなければならず、
`@inlinable` なしでは**モジュール外から呼び出せない**ケースがある。

通常の Swift（iOS/macOS）では「パフォーマンスのトレードオフ」だが、
Embedded Swift では「動作するかどうか」の問題になりうる。

```swift
// Embedded Swift でモジュール外から使う場合は @inlinable 必須
@inlinable
public func decodeULEB128<T: FixedWidthInteger & UnsignedInteger, S: ByteStream>(
    from stream: inout S
) throws(LEB128Error) -> T { ... }
```

#### `@inlinable` を付けることのコスト

- **ABI への影響**: 実装がクライアントのバイナリに焼き込まれる。
  後から実装を変更しても、再コンパイルしないクライアントには反映されない。
- **コードサイズ**: 呼び出し箇所の数だけ関数本体が複製される。
- **コンパイル時間**: 特殊化・インライン展開の最適化コストが増加する。

Embedded Swift（アプリ全体を一緒にビルドする形態）ではこれらのコストは
ほぼ問題にならない。バイナリ配布ライブラリとして提供する場合は注意が必要。

### `@inline(__always)`：極小関数の強制インライン

1 バイト読み出しのような極小関数は、関数呼び出しオーバーヘッドがゼロになるよう強制インライン化する。

```swift
@inline(__always)
public mutating func consume() throws(LEB128Error) -> UInt8 { ... }
```

`@inlinable` との違い:

| | `@inlinable` | `@inline(__always)` |
|---|---|---|
| 目的 | モジュール外への実装公開・特殊化許可 | 呼び出し元での強制展開 |
| コンパイラの裁量 | コンパイラが判断して展開 | 無条件に展開（無視不可） |
| 主な用途 | ジェネリック関数・モジュール境界 | ループ内の極小関数 |

### `&<<`（オーバーフローシフト）の使用

符号付き整数の通常の左シフト（`<<`）はオーバーフロー時にランタイムトラップが発生する。
Embedded Swift ではデバッグ用トラップ機構の挙動が通常と異なる場合があるため、
意図的なビット操作には `&<<` を使う。

```swift
// NG: Int32(0x78) << 28 はオーバーフロートラップ
result |= T(byte & 0x7F) << shift

// OK: ビットパターンをそのまま扱う
result |= T(byte & 0x7F) &<< shift
```

---

## 4. メモリレイアウトの考慮

### `@frozen` enum と struct

Embedded Swift では型のメモリレイアウトが固定されていることが前提になる場合がある。
公開する型には `@frozen` を検討する。

### スタックサイズ

Pico のデフォルトスタックサイズは数 KB 程度。再帰呼び出しや大きなスタック変数は避ける。

---

## 5. デバッグ

Embedded 環境では `print` が使えない（または UART 等に繋がっている）。

- デバッグ出力が必要な場合は、ターゲット固有の出力関数（UART 書き込み等）を使う
- インライン化された関数はスタックトレースに現れないことを念頭に置く
- `assert` / `precondition` の挙動はターゲットのトラップ実装に依存する
