Read Documentations/OVERVIEW.md

# ⚠️ 最重要注意点

## コミット禁止（許可なし）

**git commit は絶対にユーザーの事前許可なしに実行してはいけない。**

- 作業完了後に自動でコミットしてはいけない
-「コミットして」と明示的に指示された場合のみ実行する
- サブエージェント（embedded-wasm-runtime-implementer 等）もコミットしてはいけない
- ワークフロー完了時も同様。必ず「コミットしますか？」と確認してから待つ

# Claude へのルール

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
詳細な制約・パターン・理由については `Documentations/SWIFT_VM_DESIGN.md` の Section 8〜10 を参照すること。

### 実装時の必須チェック事項

| チェック項目 | NG 例 | OK 例 |
|---|---|---|
| 参照型の使用禁止 | `class GlobalStore { ... }` | `private var globals: [Value]` + `mutating` メソッド |
| Existential 型の禁止 | `any Protocol` | ジェネリック制約 `<T: Protocol>` |
| `String ==` による比較禁止 | `name == "increment"` | `nameBytes.elementsEqual("increment".utf8)` |
| 型なし `throws` の禁止 | `func f() throws` | `func f() throws(WasmError)` |

なお、`block` / `loop` / `if` 命令の子命令格納に用いていた `indirect case` は、
フラット bytecode（ジャンプオフセット付き命令列）への移行により除去済み（フェーズ 1.5 完了）。

### 実装フェーズを通じた共通方針

macOS フェーズであっても Embedded Swift の制約に最初から合わせて実装する。

- ホットパスでの `Array(xxx.suffix(n))` などの中間コピーは作らない
- `String ==` による比較は使わない（`[UInt8]` バイト比較で代替）
- `throws(WasmError)` の typed throws を常に使う
- `Array<T>` の動的確保が構造上避けられない箇所（フレームの `locals` 等）は `// TODO: Embedded Phase 5` コメントで明示する
- バリデーションは Embedded ビルドでは省略し、非 Embedded（macOS）でのみ実装する（`#if !hasFeature(Embedded)`）

---

## Sub-Agent Workflow

This project uses four sub-agents defined in `.claude/agents/`. They follow a structured loop for implementing and reviewing WASM Runtime components.

### Agents

| Agent | Role |
|---|---|
| `embedded-wasm-runtime-implementer` | Implements WASM Runtime components with Embedded Swift constraints in mind |
| `wasm-embedded-researcher` | Researches reference implementations (wasm3, WasmKit) and Embedded Swift constraints when needed during implementation |
| `wasm-runtime-reviewer` | Reviews implemented code for correctness, Embedded Swift compatibility, and design consistency |
| `wasm-runtime-tester` | Verifies implementation changes by running the three test perspectives: `swift test`, `make compile`, and BLE example build |
| `docs-sync-agent` | Updates documentation to reflect implementation changes after a task is complete |

### Test Perspectives

`wasm-runtime-tester` は以下の3つの観点でテストを実施する:

1. **`swift test`（macOS ユニットテスト）** — ロジックが仕様通りに動作するかを検証する
2. **`make compile`（Embedded Swift コンパイル検証）** — Embedded Swift の制約を満たしてコンパイルできるかを検証する（`.o` 生成、Pico SDK 不要）
3. **BLE例 `make build`（Embedded Swift リンク検証）** — コンパイルに加えてリンクまで通るかを検証する（`Examples/RaspberryPiPicoW-BLE/Embedded/`、Pico SDK 必要）

### Workflow

1. **Implement** — Launch `embedded-wasm-runtime-implementer` for the implementation task. If technical research is needed mid-implementation, it delegates to `wasm-embedded-researcher`.
2. **Test** — After implementation, launch `wasm-runtime-tester` to verify the changes pass all three test perspectives.
3. **Review** — Launch `wasm-runtime-reviewer` to review the changes.
4. **Revise** — If the review identifies valid issues, launch `embedded-wasm-runtime-implementer` to address them, then re-run `wasm-runtime-tester` and `wasm-runtime-reviewer`. Repeat until no further changes are needed.
5. **Sync docs** — Once implementation is stable, launch `docs-sync-agent` to update affected documentation as needed.

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
