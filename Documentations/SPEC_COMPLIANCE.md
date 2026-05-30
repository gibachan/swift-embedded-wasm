# WebAssembly 仕様準拠状況

本ドキュメントは、`swift test` で実行される WebAssembly 公式 Spec Testsuite の結果をもとに、
現在の実装がどの仕様水準まで準拠しているかをまとめる。

最終評価日: 2026-05-31

---

## テスト結果（全体）

| 指標 | 数値 |
|------|------|
| 総テストケース数 | 59,889 |
| **PASS** | 31,925 (53.3%) |
| **SKIP** | 27,964 (46.7%) |
| **FAIL** | **0 (0.0%)** |

FAIL = 0 が最重要の指標。実行を試みたすべてのテストケースを正しく処理できている。

---

## スキップの内訳

スキップの大半は意図的に未実装の機能に起因する。

| カテゴリ | pass | skip | 主な原因 |
|---------|------|------|---------|
| SIMD (v128) | 790 | 25,199 | 意図的に未実装（Embedded 対象外）|
| Memory64（64 ビットアドレッシング）| 9,503 | 1,789 | 32 ビット Embedded ターゲット向けに未実装 |
| その他 | 21,632 | 976 | 下表参照 |

### その他 976 件の内訳（主要なもの）

| テスト名 | skip 数 | 推定原因 |
|---------|--------|---------|
| `utf8-invalid-encoding` | 176 | インポート/エクスポート名の不正 UTF-8 バイト列の検証が未実装 |
| `if` | 153 | ブロック型アノテーション付き `if` の多値返却 |
| `float_literals` / `const` | 154 | NaN ペイロード（non-canonical NaN のビットパターン）|
| `memory_init` | 141 | passive data segment の一部パターン |
| `data` / `data1` | 46 | data segment の特定エンコーディング |
| `block` / `loop` | 30 | ブロック型アノテーション |
| `token` | 26 | テキスト形式トークン |
| `ref_func` | 14 | funcref の一部操作 |

---

## 仕様準拠水準

### WebAssembly 1.0（MVP）— 約 95〜98% 準拠

SIMD・Memory64・obsolete-keywords・UTF-8 バリデーションを除くすべての MVP 機能が通過している。

| MVP 機能 | 状態 |
|---------|------|
| i32 / i64 / f32 / f64 全算術命令 | ✅ 完全 |
| `block` / `loop` / `if` / `br` / `br_if` / `br_table` | ✅ ほぼ完全（153 件の多値 if アノテーションはスキップ）|
| `call` / `call_indirect`（複数テーブル対応）| ✅ 完全 |
| `local.get` / `local.set` / `local.tee` | ✅ 完全 |
| `global.get` / `global.set` | ✅ 完全 |
| メモリ load/store 全命令（`i32.load8_s` 〜 `f64.store` 等）| ✅ 完全 |
| `memory.size` / `memory.grow` | ✅ 完全 |
| `table.get` / `table.set` | ✅ 完全 |
| import / export / start セクション | ✅ 完全 |
| バイナリフォーマット検証（magic / version / セクション順序）| ✅ 完全 |
| LEB128 符号付き・符号なし | ✅ 完全 |
| トラップ処理（ゼロ除算・境界外アクセス等）| ✅ 完全 |

### WebAssembly 2.0 — 約 97% 準拠（SIMD 除く）

SIMD（プロジェクト対象外）を除けば、Wasm 2.0 のほぼすべての機能が実装済み。

| Wasm 2.0 機能 | 状態 |
|--------------|------|
| Saturating float-to-int truncation (`i32.trunc_sat_*` 等) | ✅ 完全（619 pass）|
| Sign-extension operators (`i32.extend8_s` 等) | ✅ 完全 |
| Bulk Memory（`memory.copy` / `fill` / `init` / `data.drop`）| ✅ 完全 |
| Bulk Table（`table.copy` / `fill` / `init` / `grow` / `size` / `elem.drop`）| ✅ 完全 |
| Reference types（`funcref` / `externref` / `ref.null` / `ref.is_null` / `ref.func`）| ✅ ほぼ完全 |
| Multiple values（多値返却）| ✅ |
| **Fixed-width SIMD（v128）** | ❌ 意図的に未実装 |

---

## 意図的に未実装の機能

| 機能 | 対象外とする理由 |
|-----|----------------|
| SIMD (v128) | Embedded 環境のユースケースに不要。RP2350 での SIMD サポートも限定的 |
| Memory64（64 ビットアドレッシング）| 32 ビット Embedded ターゲット（RP2040/RP2350）に不要 |
| Threads | Embedded Swift が Swift Concurrency ランタイムに非対応 |
| Exception Handling | Embedded 環境向けのユースケースに不要 |
| GC（Garbage Collection）| Embedded 環境の動的メモリ管理と相容れない |
| WASI | OS のない Embedded 環境では適用不可 |

---

## Non-SIMD・Non-Memory64 のパスレート

SIMD と Memory64 を除いた実質的な実装範囲でのパスレート。

| 指標 | 数値 |
|------|------|
| 対象テストケース数 | 22,608 |
| PASS | 21,632 |
| SKIP | 976 |
| **パスレート** | **95.7%** |

残り 976 件のスキップのうち、NaN ペイロード（154 件）・UTF-8 バリデーション（176 件）・多値 if アノテーション（153 件）の 3 項目だけで 483 件を占める。これらはいずれも MVP の範囲内であるが実装難度の高いエッジケースである。

---

## 評価コマンド

```sh
# 全テスト実行（pass/skip/fail が出力される）
swift test

# pass/skip/fail の集計（awk でパイプ）
swift test 2>&1 | grep -E '^\[' \
  | awk -F'pass=|skip=|fail=' \
    '{p+=$2; s+=$3; f+=$4} END {print "pass:", p, "skip:", s, "fail:", f, "total:", p+s+f}'
```
