Read docs/OVERVIEW.md

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

## 現在の状況

**フェーズ: 計画・ドキュメント整備**

実装はまだ始まっていない。プロジェクト全体の方針と各 Phase の詳細計画を文書化している段階。

| ドキュメント | 状態 |
|---|---|
| `docs/OVERVIEW.md` | 完成（大枠計画・開発方針） |
| `docs/PROJECT_GOAL.md` | 完成（最終成果物・成功ライン） |
| `docs/PHASE1_ENV.md` | 初稿完成（詳細化待ち） |
| `docs/PHASE2_WASM3.md` | 初稿完成（詳細化待ち） |
| `docs/PHASE3_PARSER.md` | 初稿完成（詳細化待ち） |
| `docs/PHASE4_INTERPRETER.md` | 初稿完成（詳細化待ち） |
| `docs/PHASE5_PICO.md` | 初稿完成（詳細化待ち） |
| `docs/PHASE6_IOS.md` | 初稿完成（詳細化待ち） |

**次のステップ**: 各 Phase の詳細計画を順次詰める。実装は Phase 1（環境構築）から開始予定。

重要: この現在の状況についてはプロジェクトの進捗と共に適宜更新します。

---

## 参照リソース

### wasm3（ローカル）

wasm3 のソースコードを `third_party/wasm3/` に Git Submodule として配置している。
WebAssembly Runtime の実装を参照する際は、ネットワーク通信なしにこのローカルコピーを使用すること。

主要ファイル:

| ファイル | 内容 |
|---|---|
| `third_party/wasm3/source/m3_core.h` | 型定義・主要データ構造 |
| `third_party/wasm3/source/m3_env.h` | VM 環境・モジュール構造 |
| `third_party/wasm3/source/m3_exec.c` | インタープリタのメインループ |
| `third_party/wasm3/source/m3_parse.c` | バイナリパーサー |
| `third_party/wasm3/source/m3_compile.c` | コンパイル・中間表現 |
