import Foundation

@testable import WasmRuntime

enum TestFixtureError: Error {
  case wasmFileNotFound(String)
}

/// Loads a .wasm file from the wasm/ directory via Bundle.module.
///
/// Files are copied into the test bundle at build time via
/// resources: [.copy("wasm")] in Package.swift.
func loadWasm(_ name: String) throws -> [UInt8] {
  guard let url = Bundle.module.url(forResource: name, withExtension: "wasm", subdirectory: "wasm")
  else {
    throw TestFixtureError.wasmFileNotFound(name)
  }
  return try [UInt8](Data(contentsOf: url))
}

/// Loads a .wasm file by name and parses it into a WasmModule
func parseModule(_ name: String) throws -> WasmModule {
  try parseBytes(try loadWasm(name))
}

/// Parses a raw byte array directly (used in tests that manipulate bytes)
func parseBytes(_ bytes: [UInt8]) throws -> WasmModule {
  try bytes.withUnsafeBufferPointer { buffer in
    var parser = WasmParser(buffer)
    return try parser.parse()
  }
}
