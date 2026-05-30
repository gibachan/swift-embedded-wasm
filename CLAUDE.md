Read Documentations/OVERVIEW.md

# Claude へのルール

## コミット
git commit は必ずユーザーの許可を得てから行う。作業完了後に自動でコミットしてはいけない。

## フォーマット
ソースコード（`Sources/`・`Tests/` 以下の Swift ファイル）に変更を加えた後は、必ず `make format` を実行してフォーマットを整えること。

# プロジェクトについて

## 概要

本プロジェクトでは、Embedded Swift を利用して Raspberry Pi Pico 上で動作する WebAssembly Runtime (Interpreter) を段階的に実装する。

本プロジェクトの目的は以下である。

- Embedded Swift の理解を深める
- WebAssembly Runtime の内部構造を理解する
- Interpreter 実装技術を学ぶ
- Swift の型安全性を活かした Runtime 設計を研究する
- Actor を活用した安全な組み込み設計を実践する
- iOS アプリと連携した Scriptable Device を構築する

本プロジェクトでは「完成」を急がず、

> Runtime の仕組みを理解しながら少しずつ実装する

ことを重視する。

## 対象者プロフィール

- Swift 言語には習熟している
- Embedded 環境（Raspberry Pi Pico / RP2350、クロスコンパイル、メモリ制約など）は初心者
- WebAssembly（バイナリフォーマット、Stack machine、Runtime 構造など）は初心者

## サポート方針

- Embedded / Wasm に関するトピックは、実装支援と並行して適宜解説を加える
- Swift の知識を前提として説明してよい（基本的な Swift 構文・型システムの説明は不要）
- 「なぜそうするのか」の背景・理由も説明に含める
- 学ぶことも目的の一つであるため、理解を深める観点を優先する

---

## VM 実装における設計方針

WASM VM を実装する際は **`Documentations/SWIFT_VM_DESIGN.md` の設計方針に従う**こと。
型設計・エラー設計・インタプリタループ・Generics 採用方針・WasmKit との比較など、
実装上の判断基準がすべてこのドキュメントにまとめられている。

## VM 実装における Embedded Swift 対応方針

WASM VM の実装は、macOS 上での開発段階においても **Embedded Swift 環境でのビルドを常に意識した設計**とする。
詳細な制約・パターン・理由については `Documentations/EMBEDDED_SWIFT.md` を参照すること。

### 実装時の必須チェック事項

| チェック項目 | NG 例 | OK 例 |
|---|---|---|
| 参照型の使用禁止 | `class GlobalStore { ... }` | `private var globals: [Value]` + `mutating` メソッド |
| Existential 型の禁止 | `any Protocol` | ジェネリック制約 `<T: Protocol>` |
| `String ==` による比較禁止 | `name == "increment"` | `nameBytes.elementsEqual("increment".utf8)` |
| 型なし `throws` の禁止 | `func f() throws` | `func f() throws(WasmError)` |

### macOS フェーズで許容するもの（Embedded フェーズで要置換）

- `Array<T>` の動的確保（パース結果・スタック・ローカル変数の格納）

これらは macOS フェーズでは正確さ優先で使用してよいが、コメントや設計上の区別を意識しておく。

なお、`block` / `loop` / `if` 命令の子命令格納に用いていた `indirect case` は、
フラット bytecode（ジャンプオフセット付き命令列）への移行により除去済み（フェーズ 1.5 完了）。

---

## Wasm3 調査から得た設計指針（Embedded Swift 向け）

`Documentations/PHASE2_WASM3.md` の調査結果のうち、Embedded Swift インタプリタ実装に有効な点を以下にまとめる。

### 採用する設計

| 項目 | 方針 | 根拠（PHASE2 Section） |
|---|---|---|
| **インタプリタループ** | `switch` ベースのシンプルな実装 | Threaded Code（関数ポインタ配列 + tail call）は Embedded Swift で動作が保証されない（F） |
| **値の型表現** | `enum WasmValue { case i32(Int32); case i64(Int64); ... }` | C の union + type フラグより型安全。Embedded Swift でも enum は使用可能（C） |
| **エラー処理** | typed throws + `enum WasmError` | `M3Result = const char*` より型安全。Embedded Swift でも throws は使用可能（B） |
| **メモリアクセス** | `UnsafeBufferPointer` / `UnsafeMutableRawBufferPointer` | ヒープアロケーション不要。Linear Memory の境界チェックも明示的に書ける（E） |
| **データ構造** | `struct` 中心の値型設計 | ヒープ確保を避けるため class より struct を優先（A） |
| **パーサー** | Code section はバイト範囲のみ記録し、実行時に逐次デコード | Wasm3 と同じ遅延評価方式。メモリ使用量を最小化（PHASE2 Section 6） |

### Embedded Swift では使えない／注意が必要な設計

| 項目 | 理由 | 代替案 |
|---|---|---|
| `actor` | Embedded Swift は Swift Concurrency ランタイム非対応 | シングルスレッド前提の `struct` で設計 |
| ヒープ確保クロージャ | Embedded Swift でクロージャはスタック上に収まるもののみ使用可能 | Host Function は `@convention(c)` 関数ポインタ + 静的テーブルで登録 |
| `Array<T>`（動的確保） | `malloc` が使えない環境では動的配列不可 | 固定サイズバッファ / `UnsafeBufferPointer` で代替。macOS フェーズは `Array` で先行実装してよい |
| `String` | Embedded Swift では `String` が使えない | エクスポート名の比較はバイト列のまま行う（macOS フェーズは `String` で先行実装してよい） |

### macOS フェーズと Embedded フェーズの切り替え方針

- macOS フェーズ（現在）: `Array` / `String` / `throws` を自由に使い、正確さを優先する
- Embedded フェーズ（Phase 5〜）: 動的確保箇所を固定サイズバッファに置き換えていく
- バリデーションは macOS フェーズでのみ実装し、Embedded フェーズでは実装しない。

---

## Sub-Agent Workflow

This project uses four sub-agents defined in `.claude/agents/`. They follow a structured loop for implementing and reviewing WASM Runtime components.

### Agents

| Agent | Role |
|---|---|
| `embedded-wasm-runtime-implementer` | Implements WASM Runtime components with Embedded Swift constraints in mind |
| `wasm-embedded-researcher` | Researches reference implementations (wasm3, WasmKit) and Embedded Swift constraints when needed during implementation |
| `wasm-runtime-reviewer` | Reviews implemented code for correctness, Embedded Swift compatibility, and design consistency |
| `docs-sync-agent` | Updates documentation to reflect implementation changes after a task is complete |

### Workflow

1. **Implement** — Launch `embedded-wasm-runtime-implementer` for the implementation task. If technical research is needed mid-implementation, it delegates to `wasm-embedded-researcher`.
2. **Review** — After implementation, launch `wasm-runtime-reviewer` to review the changes.
3. **Revise** — If the review identifies valid issues, launch `embedded-wasm-runtime-implementer` to address them, then re-run `wasm-runtime-reviewer`. Repeat until no further changes are needed.
4. **Sync docs** — Once implementation is stable, launch `docs-sync-agent` to update affected documentation as needed.

---

## 参照リソース

### wasm3（ローカル）

wasm3 のソースコードを `ThirdParty/wasm3/` に Git Submodule として配置している。
WebAssembly Runtime の実装を参照する際は、ネットワーク通信なしにこのローカルコピーを使用すること。

主要ファイル:

| ファイル | 内容 |
|---|---|
| `ThirdParty/wasm3/source/m3_core.h` | 型定義・主要データ構造 |
| `ThirdParty/wasm3/source/m3_env.h` | VM 環境・モジュール構造 |
| `ThirdParty/wasm3/source/m3_exec.c` | インタープリタのメインループ |
| `ThirdParty/wasm3/source/m3_parse.c` | バイナリパーサー |
| `ThirdParty/wasm3/source/m3_compile.c` | コンパイル・中間表現 |
