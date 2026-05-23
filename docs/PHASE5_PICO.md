# Phase 5 — Raspberry Pi Pico への移植・動作確認

## 目的

Phase 3〜4 で macOS 上に実装した Wasm パーサー・インタプリタを
Embedded Swift 向けにクロスコンパイルし、Raspberry Pi Pico 2 (RP2350) 上で動作させる。
Wasm から GPIO を制御することを最低成功ラインとする。

---

## 移植時の主な課題

### 動的アロケーションの排除

macOS 版では `Array` や動的なデータ構造を使えるが、
Embedded Swift では動的アロケーションを最小化する必要がある。

| macOS 版 | Embedded 版 |
|----------|------------|
| `var stack: [WasmValue]` | 固定長バッファ + インデックス管理 |
| `var locals: [WasmValue]` | スタック上の固定配列 |
| `String` によるログ | UART への直接書き込み |

### Arena Allocator

組み込みでよく使われる手法。
一度確保した大きなバッファから順番に切り出して使い、まとめて解放する。

```text
[          大きなバッファ（例: 64KB SRAM の一部）          ]
 ↑使用済み↑ ↑ここから次を確保
```

個別の `malloc` / `free` を繰り返すより高速で断片化しない。

---

## Actor ベース Runtime 設計

Phase 5 では、Swift Concurrency の `actor` を用いた安全な Runtime 設計も試みる。
ただし Embedded Swift での Concurrency サポートは限定的なため、
まず macOS / Swift Playground 上で設計を検証してから Pico に適用する。

### なぜ Actor を使うか

組み込みでも複数のタスク（Wasm 実行・GPIO 割り込み・UART 通信）が並行する場面がある。
`actor` により、共有状態へのアクセスを Swift コンパイラが安全に管理してくれる。

```swift
actor WasmRuntime {
    private var module: WasmModule?

    func load(_ binary: [UInt8]) throws
    func execute(function: String) async throws -> WasmValue?
}

actor GPIOController {
    func write(pin: GPIOPin, value: Bool)
    func read(pin: GPIOPin) -> Bool
}
```

### Embedded Swift での制約

Embedded Swift では `actor` / `async` / `await` のサポートが現時点で限定的。
利用できるかは toolchain バージョンに依存するため、実際の動作確認が必要。

---

## バイナリサイズと制約

### 現状のサイズ（pico-ble.uf2）

| 項目 | 値 |
|---|---|
| UF2 ファイルサイズ | 821 KB |
| 実バイナリサイズ（UF2 は 2:1 のオーバーヘッド） | 約 410 KB |

UF2 形式は 512 バイトブロックのうち 256 バイトが実データのため、ファイルサイズは実バイナリの約 2 倍になる。

### フラッシュ容量との比較

| ボード | Flash | 410KB 使用後の残り |
|---|---|---|
| Raspberry Pi Pico（RP2040） | 2 MB | 約 1.6 MB |
| Raspberry Pi Pico 2（RP2350） | 4 MB | 約 3.6 MB |

現状は両ボードで収まるが、実装が完成に近づくにつれてサイズは増大する見込み。

### 他の最小 Wasm インタプリタとの比較

| 実装 | 言語 | バイナリサイズ |
|---|---|---|
| wasm3 | C | 約 64 KB |
| wasm-micro-runtime (WAMR) | C | 100〜300 KB |
| 本プロジェクト（現状） | Embedded Swift | 約 410 KB |

差の主な要因は Embedded Swift でも残る型メタデータ・protocol witness table、および BLE スタックの混在。

### 完成度向上時のサイズ見込み

| 追加内容 | 想定増加 |
|---|---|
| 命令セット全体（float / memory ops） | +50〜100 KB |
| バリデーション強化 | +20〜50 KB |
| 複数モジュール対応 | +30〜80 KB |

最終的に実バイナリで 600〜700 KB 規模になる可能性がある。RP2350 ターゲットなら問題ないが、RP2040 ターゲットではサイズ最適化が必要になりえる。

### 本当の制約は Flash ではなく RAM

RP2040 の SRAM は **264 KB**（RP2350 は 520 KB）。Wasm プログラム実行時の RAM 使用量が実質的な限界を決める：

- Wasm の Linear Memory（ページ単位 64 KB）
- インタプリタのスタック・フレーム
- BLE スタックのバッファ
- グローバル変数・静的データ

フラッシュ残量よりも **RAM に全てが収まるか** を優先して確認すること。

### サイズ最適化の手段（Phase 5 で検討）

- **LTO（Link-Time Optimization）** の有効化：ビルド設定で数十〜百 KB 削減できることがある
- `Array` → 固定長バッファへの置き換え（動的アロケーション排除と同時に達成）
- 使わない命令セットのコンパイル除外（`#if` による静的分岐）

---

## 動作確認項目

### 最低確認

```text
Pico 上で Wasm バイナリをロードし、
i32.add を含む関数を実行して UART に結果を出力する
```

### GPIO 制御確認

```text
Wasm から Host Function 経由で LED を点滅させる
（digitalWrite を Wasm から呼び出す）
```

---

## 成功基準

- [ ] Embedded Swift でパーサー・インタプリタがビルドできる
- [ ] Pico 上で Wasm モジュールをロードできる
- [ ] Wasm から `i32.add` を実行して UART に結果が出る
- [ ] Wasm の Host Function 経由で LED を制御できる
