import Testing
@testable import WasmRuntime

// MARK: - Parser Tests

@Suite("WasmParser")
struct WasmParserTests {
  @Test func parsesTypeSection() throws {
    let module = try parseModule("i32-add")
    #expect(module.types.count == 1)
    #expect(module.types[0].params == [.i32, .i32])
    #expect(module.types[0].results == [.i32])
  }

  @Test func parsesFunctionSection() throws {
    let module = try parseModule("i32-add")
    #expect(module.functions == [0])
  }

  @Test func parsesExportSection() throws {
    let module = try parseModule("i32-add")
    #expect(module.exports.count == 1)
    #expect(module.exports[0].nameBytes == Array("i32-add".utf8))
    #expect(module.exports[0].kind == .function)
    #expect(module.exports[0].index == 0)
  }

  @Test func parsesCodeSection() throws {
    let module = try parseModule("i32-add")
    #expect(module.code.count == 1)
    #expect(module.code[0].locals.isEmpty)
    // end はパーサーの終端マーカーであり命令として格納しない
    #expect(module.code[0].instructions.count == 3)
  }

  @Test func parsesMemorySection() throws {
    let module = try parseModule("memory")
    #expect(module.memories.count == 1)
    #expect(module.memories[0].min == 1)
    #expect(module.memories[0].max == nil)
  }

  @Test func parsesStartSection() throws {
    let module = try parseModule("memory")
    #expect(module.start == 0)
  }

  @Test func parsesLoopInstructions() throws {
    let module = try parseModule("loop")
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

  @Test func rejectsInvalidMagic() throws {
    var bad = try loadWasm("i32-add")
    bad[0] = 0xFF
    #expect(throws: WasmError.invalidMagic) {
      try parseBytes(bad)
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
    let module = try parseModule("i32-add")
    let interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(3), .i32(4)])
    #expect(result == [.i32(7)])
  }

  @Test func i32AddWithNegatives() throws {
    let module = try parseModule("i32-add")
    let interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(-10), .i32(3)])
    #expect(result == [.i32(-7)])
  }

  @Test func i32AddWrapsAround() throws {
    let module = try parseModule("i32-add")
    let interp = try WasmInterpreter(module: module)
    // Wasm の i32.add はオーバーフロー時にラップアラウンドする
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(Int32.max), .i32(1)])
    #expect(result == [.i32(Int32.min)])
  }

  @Test func throwsOnUnknownExport() throws {
    let module = try parseModule("i32-add")
    let interp = try WasmInterpreter(module: module)
    #expect(throws: WasmError.functionNotFound) {
      try interp.callExport(nameBytes: Array("nonexistent".utf8), args: [])
    }
  }

  @Test func throwsOnArgumentCountMismatch() throws {
    let module = try parseModule("i32-add")
    let interp = try WasmInterpreter(module: module)
    #expect(throws: WasmError.argumentCountMismatch) {
      try interp.callExport(nameBytes: i32AddName, args: [.i32(1)])
    }
  }

  @Test func instantiatesWithStart() throws {
    let module = try parseModule("memory")
    // start 関数（() -> ()）がインスタンス化時にエラーなく実行される
    _ = try WasmInterpreter(module: module)
  }

  @Test func executesLoop() throws {
    let module = try parseModule("loop")
    let interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: Array("loop_test".utf8), args: [])
    #expect(result.isEmpty)
  }
}
