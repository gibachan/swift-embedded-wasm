# プロジェクト大枠計画

Embedded Swift を用いて Raspberry Pi Pico 上で動作する WebAssembly インタプリタを実装し、
最終的に iOS アプリから Wasm バイナリをアップロードして動的に実行できる Scriptable Device を構築する。

---

## Phase 1 — Embedded Swift 開発環境構築

Embedded Swift のツールチェーンをセットアップし、Raspberry Pi Pico への書き込みと基本動作を確認する。

詳細計画: `Documentations/PHASE1_ENV.md`

---

## Phase 2 — Wasm3 調査・参考点洗い出し

組み込み向け Wasm Runtime である Wasm3 のソースコードを読解し、
本プロジェクトへの設計上の参考点を整理する。

詳細計画: `Documentations/PHASE2_WASM3.md`

---

## Phase 3 — Wasm バイナリパーサー実装

Wasm バイナリフォーマットを仕様に基づいて解析するパーサーを Swift で実装する。

詳細計画: `Documentations/PHASE3_PARSER.md`

---

## Phase 4 — Wasm インタプリタ実装

Stack machine、Validation、Linear Memory、Host Function を段階的に実装し、
Wasm モジュールを実行できるインタプリタを構築する。

詳細計画: `Documentations/PHASE4_INTERPRETER.md`

---

## Phase 5 — Raspberry Pi Pico への移植・動作確認

Phase 3〜4 で実装したコンポーネントを Embedded Swift 向けにクロスコンパイルし、
Pico 上で Wasm を実行して GPIO 制御まで動作確認する。

詳細計画: `Documentations/PHASE5_PICO.md`

---

## Phase 6 — iOS 連携

BLE または Wi-Fi 経由で iPhone から Wasm バイナリを Pico へアップロードする仕組みを構築し、
Scriptable Device として完成させる。

詳細計画: `Documentations/PHASE6_IOS.md`

---

## 進行方針：インクリメンタル開発

Phase を 1 つずつ完成させてから次へ進むのではなく、
**最小限の成果を出せる小さな変更を積み重ねる**インクリメンタルな進行を基本とする。

```text
❌ Phase 完結型（避ける）
  Phase 3 全完成 → Phase 4 全完成 → Phase 5 全完成 → ...

✅ インクリメンタル型（採用する）
  LEB128 実装 → Magic 検証 → Type Section パース
  → i32.const 実行 → i32.add 実行 → call 実行
  → Pico ビルド確認 → GPIO 制御 → ...
```

### この方針を採用する理由

- **理解の確認が細かくできる** — 各ステップで動作を確認し、仕組みを理解してから次へ進む
- **成果を早期に確認できる** — 部分的に動くものが常に手元にある
- **誤りの早期発見** — 設計ミスやアーキテクチャの問題を小さなうちに発見できる
- **軌道修正が容易** — 一度に変更する範囲が小さいほど、手戻りのコストが低い

### インクリメントの粒度の目安

1 つのインクリメントは「1 つの概念または機能が動作することを確認できる」単位を目安とする。

例:
- `readByte()` と `readULEB128()` が正しく動く
- Type Section をパースして関数シグネチャを取り出せる
- `i32.const` + `i32.add` + `return` の 3 命令だけで加算結果が得られる
- Pico 上でビルドが通り UART にログが出る

---

## 開発方針

### 1. 学習を重視する
最初から高速化や完全実装を目指さない。Wasm Runtime の仕組み・Stack Machine・Validation・Linear Memory・Host Function を理解することを優先する。

### 2. Step by Step で実装する
小さく作って理解を積み上げる。WASI / JIT / Threads / Full Spec は最初から目指さない。

### 3. Swift の特徴を活かす
`enum` / `protocol` / `generics` / `actor` / `Sendable` / value semantics を積極的に活用する。

### 4. Embedded 制約を意識する
RAM 不足・アロケーターコスト・コードサイズ制限を考慮し、fixed-size memory / minimal allocation / arena allocator を重視する。

---

## 推奨ディレクトリ構成

```text
swift-embedded-wasm/
├── pico-runtime/       # Pico 上で動作するファームウェア
├── wasm-parser/        # Wasm バイナリパーサー
├── wasm-interpreter/   # Wasm インタプリタ
├── host-api/           # Host Function 実装
├── ios-controller/     # iOS コントローラーアプリ
├── Documentations/     # ドキュメント
└── experiments/        # 実験・調査用コード
```

---

## 推奨学習順

**Embedded 領域**
1. Embedded Swift Documentation
2. RP2350 Datasheet
3. Pico SDK

**WebAssembly 領域**
1. Wasm Binary Format
2. Validation
3. Execution Model

**Runtime 実装参考**
1. Wasm3（メイン参考実装）
2. WAMR
3. WasmKit

---

## 成功ライン

| レベル | 条件 |
|--------|------|
| 最低 | Pico 上で Wasm を実行し GPIO を制御できる |
| 中間 | iPhone から BLE 経由で Wasm をアップロードして実行できる |
| 最終 | 複数 Wasm アプリを動的に切り替えられる Scriptable Device |
