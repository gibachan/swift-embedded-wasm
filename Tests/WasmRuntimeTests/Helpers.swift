import Foundation
@testable import WasmRuntime

enum TestFixtureError: Error {
  case wasmFileNotFound(String)
}

/// Bundle.module 経由で wasm/ ディレクトリの .wasm ファイルを読み込む。
///
/// Package.swift の resources: [.copy("wasm")] によりビルド時にバンドルへコピーされる。
/// パス計算が不要で、SPM のリソース管理に従う。
func loadWasm(_ name: String) throws -> [UInt8] {
  guard let url = Bundle.module.url(forResource: name, withExtension: "wasm", subdirectory: "wasm") else {
    throw TestFixtureError.wasmFileNotFound(name)
  }
  return try [UInt8](Data(contentsOf: url))
}

/// ファイル名から wasm を読み込んでパースする
func parseModule(_ name: String) throws -> WasmModule {
  try parseBytes(try loadWasm(name))
}

/// バイト列から直接パースする（バイト改ざんが必要なテスト用）
func parseBytes(_ bytes: [UInt8]) throws -> WasmModule {
  try bytes.withUnsafeBufferPointer { buffer in
    var parser = WasmParser(buffer)
    return try parser.parse()
  }
}
