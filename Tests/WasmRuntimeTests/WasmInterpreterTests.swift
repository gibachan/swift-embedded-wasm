import Testing
@testable import WasmRuntime

// loop.wasm のバイナリをそのまま埋め込む
// (module (func $loop_test (export "loop_test") (local i32) ...loop...) )
private let loopWasm: [UInt8] = [
  // magic + version
  0x00, 0x61, 0x73, 0x6d,
  0x01, 0x00, 0x00, 0x00,
  // Type section (id=1, size=4): () -> ()
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
  // Function section (id=3, size=2): func[0] = type[0]
  0x03, 0x02, 0x01, 0x00,
  // Export section (id=7, size=13): "loop_test" -> func[0]
  0x07, 0x0d, 0x01, 0x09,
  0x6c, 0x6f, 0x6f, 0x70, 0x5f, 0x74, 0x65, 0x73, 0x74,
  0x00, 0x00,
  // Code section (id=10, size=32)
  0x0a, 0x20, 0x01, 0x1e,
  0x01, 0x01, 0x7f,        // 1 local: i32
  0x41, 0x00,              // i32.const 0
  0x21, 0x00,              // local.set 0
  0x03, 0x40,              // loop void
    0x02, 0x40,            //   block void
      0x20, 0x00,          //     local.get 0
      0x41, 0x01,          //     i32.const 1
      0x6a,                //     i32.add
      0x21, 0x00,          //     local.set 0
      0x20, 0x00,          //     local.get 0
      0x41, 0x05,          //     i32.const 5
      0x46,                //     i32.eq
      0x0d, 0x00,          //     br_if 0  (i==5 でブロックを抜ける)
      0x0c, 0x01,          //     br 1     (ループ先頭へ)
    0x0b,                  //   end block
  0x0b,                    // end loop
  0x0b,                    // end function
]

// memory.wasm のバイナリをそのまま埋め込む
// (module (memory 1) (func $start) (start $start))
private let memoryWasm: [UInt8] = [
  // magic + version
  0x00, 0x61, 0x73, 0x6d,
  0x01, 0x00, 0x00, 0x00,
  // Type section (id=1, size=4): () -> ()
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
  // Function section (id=3, size=2): func[0] = type[0]
  0x03, 0x02, 0x01, 0x00,
  // Memory section (id=5, size=3): memory[0] = {min:1, max:none}
  0x05, 0x03, 0x01, 0x00, 0x01,
  // Start section (id=8, size=1): start = func[0]
  0x08, 0x01, 0x00,
  // Code section (id=10, size=4): func[0] = end のみ
  0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
]

// i32-add.wasm のバイナリをそのまま埋め込む
// xxd wasm/i32-add.wasm で確認した 45 バイト
private let i32AddWasm: [UInt8] = [
  // magic + version
  0x00, 0x61, 0x73, 0x6d,
  0x01, 0x00, 0x00, 0x00,
  // Type section (id=1, size=7): (i32, i32) -> i32
  0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
  // Function section (id=3, size=2): 関数0 → type 0
  0x03, 0x02, 0x01, 0x00,
  // Export section (id=7, size=11): "i32-add" → func 0
  0x07, 0x0b, 0x01, 0x07, 0x69, 0x33, 0x32, 0x2d, 0x61, 0x64, 0x64, 0x00, 0x00,
  // Code section (id=10, size=9): local.get 0, local.get 1, i32.add, end
  0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
]

private func parseModule(_ bytes: [UInt8]) throws -> WasmModule {
  try bytes.withUnsafeBufferPointer { buffer in
    var parser = WasmParser(buffer)
    return try parser.parse()
  }
}

// MARK: - Parser Tests

@Suite("WasmParser")
struct WasmParserTests {
  @Test func parsesTypeSection() throws {
    let module = try parseModule(i32AddWasm)
    #expect(module.types.count == 1)
    #expect(module.types[0].params == [.i32, .i32])
    #expect(module.types[0].results == [.i32])
  }
  
  @Test func parsesFunctionSection() throws {
    let module = try parseModule(i32AddWasm)
    #expect(module.functions == [0])
  }
  
  @Test func parsesExportSection() throws {
    let module = try parseModule(i32AddWasm)
    #expect(module.exports.count == 1)
    #expect(module.exports[0].nameBytes == Array("i32-add".utf8))
    #expect(module.exports[0].kind == .function)
    #expect(module.exports[0].index == 0)
  }
  
  @Test func parsesCodeSection() throws {
    let module = try parseModule(i32AddWasm)
    #expect(module.code.count == 1)
    #expect(module.code[0].locals.isEmpty)
    // end はパーサーの終端マーカーであり命令として格納しない
    #expect(module.code[0].instructions.count == 3)
  }

  @Test func parsesLoopInstructions() throws {
    let module = try parseModule(loopWasm)
    let body = module.code[0]
    // ローカル変数: i32 が 1 つ
    #expect(body.locals == [.i32])
    // トップレベル命令: i32.const / local.set / loop の 3 つ
    #expect(body.instructions.count == 3)
    // 3 番目が loop であり、中に block が 1 つ入っている
    guard case .loop(_, let loopBody) = body.instructions[2] else {
      Issue.record("Expected loop instruction at index 2")
      return
    }
    #expect(loopBody.count == 1)
    guard case .block(_, let blockBody) = loopBody[0] else {
      Issue.record("Expected block instruction inside loop")
      return
    }
    // block 内の命令: local.get / i32.const / i32.add / local.set /
    //                 local.get / i32.const / i32.eq / br_if / br = 9 つ
    #expect(blockBody.count == 9)
  }
  
  @Test func parsesMemorySection() throws {
    let module = try parseModule(memoryWasm)
    #expect(module.memories.count == 1)
    #expect(module.memories[0].min == 1)
    #expect(module.memories[0].max == nil)
  }

  @Test func executesLoop() throws {
    let module = try parseModule(loopWasm)
    let interp = try WasmInterpreter(module: module)
    let loopTestName = Array("loop_test".utf8)
    // () -> () 関数: 結果なし
    let result = try interp.callExport(nameBytes: loopTestName, args: [])
    #expect(result.isEmpty)
  }

  @Test func parsesStartSection() throws {
    let module = try parseModule(memoryWasm)
    #expect(module.start == 0)
  }

  @Test func instantiatesWithStart() throws {
    let module = try parseModule(memoryWasm)
    // start 関数（() -> ()）がインスタンス化時にエラーなく実行される
    _ = try WasmInterpreter(module: module)
  }

  @Test func rejectsInvalidMagic() throws {
    var bad = i32AddWasm
    bad[0] = 0xFF
    #expect(throws: WasmError.invalidMagic) {
      try parseModule(bad)
    }
  }
}

// MARK: - Interpreter Tests

@Suite("WasmInterpreter")
struct WasmInterpreterTests {
  // テストでは nameBytes を直接組み立てる。
  // "i32-add".utf8 のバイト変換は照合ではなくテストデータ準備のためなので問題ない。
  private let i32AddName = Array("i32-add".utf8)
  
  @Test func i32Add() throws {
    let module = try parseModule(i32AddWasm)
    let interp = try WasmInterpreter(module: module)
    
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(3), .i32(4)])
    
    #expect(result == [.i32(7)])
  }
  
  @Test func i32AddWithNegatives() throws {
    let module = try parseModule(i32AddWasm)
    let interp = try WasmInterpreter(module: module)
    
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(-10), .i32(3)])
    #expect(result == [.i32(-7)])
  }
  
  @Test func i32AddWrapsAround() throws {
    let module = try parseModule(i32AddWasm)
    let interp = try WasmInterpreter(module: module)
    
    // Wasm の i32.add はオーバーフロー時にラップアラウンドする
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(Int32.max), .i32(1)])
    #expect(result == [.i32(Int32.min)])
  }
  
  @Test func throwsOnUnknownExport() throws {
    let module = try parseModule(i32AddWasm)
    let interp = try WasmInterpreter(module: module)
    
    #expect(throws: WasmError.functionNotFound) {
      try interp.callExport(nameBytes: Array("nonexistent".utf8), args: [])
    }
  }
  
  @Test func throwsOnArgumentCountMismatch() throws {
    let module = try parseModule(i32AddWasm)
    let interp = try WasmInterpreter(module: module)
    
    #expect(throws: WasmError.argumentCountMismatch) {
      try interp.callExport(nameBytes: i32AddName, args: [.i32(1)])
    }
  }
}
