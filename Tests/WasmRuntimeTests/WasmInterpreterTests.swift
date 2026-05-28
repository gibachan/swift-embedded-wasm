import Foundation
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
    // end is a parser terminator and is not stored as an instruction
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
    // Locals: one i32
    #expect(body.locals == [.i32])
    // Top-level instructions: i32.const / local.set / loop = 3
    #expect(body.instructions.count == 3)
    // The third instruction is a loop containing one block
    guard case .loop(_, let loopBody) = body.instructions[2] else {
      Issue.record("Expected loop instruction at index 2")
      return
    }
    #expect(loopBody.count == 1)
    guard case .block(_, let blockBody) = loopBody[0] else {
      Issue.record("Expected block instruction inside loop")
      return
    }
    // Instructions inside the block:
    // local.get / i32.const / i32.add / local.set /
    // local.get / i32.const / i32.eq / br_if / br = 9
    #expect(blockBody.count == 9)
  }

  @Test func parsesTableSection() throws {
    let module = try parseModule("table")
    #expect(module.tables.count == 1)
    #expect(module.tables[0].refType == .funcRef)
    #expect(module.tables[0].min == 4)
    #expect(module.tables[0].max == nil)
  }

  @Test func parsesGlobalSection() throws {
    let module = try parseModule("table")
    #expect(module.globals.count == 1)
    #expect(module.globals[0].type.valueType == .i32)
    #expect(module.globals[0].type.mutability == .mutable)
    #expect(module.globals[0].initValue == .i32(0))
  }

  @Test func parsesElementSection() throws {
    let module = try parseModule("table")
    #expect(module.elements.count == 1)
    #expect(module.elements[0].tableIndex == 0)
    #expect(module.elements[0].offset == 0)
    // 4 entries: js.increment(0), js.decrement(1), increment(2), decrement(3)
    #expect(module.elements[0].functionIndices == [0, 1, 2, 3])
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
  private let i32AddName = Array("i32-add".utf8)

  @Test func i32Add() throws {
    let module = try parseModule("i32-add")
    var interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(3), .i32(4)])
    #expect(result == [.i32(7)])
  }

  @Test func i32AddWithNegatives() throws {
    let module = try parseModule("i32-add")
    var interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(-10), .i32(3)])
    #expect(result == [.i32(-7)])
  }

  @Test func i32AddWrapsAround() throws {
    let module = try parseModule("i32-add")
    var interp = try WasmInterpreter(module: module)
    // Wasm i32.add wraps around on overflow
    let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(Int32.max), .i32(1)])
    #expect(result == [.i32(Int32.min)])
  }

  @Test func throwsOnUnknownExport() throws {
    let module = try parseModule("i32-add")
    var interp = try WasmInterpreter(module: module)
    #expect(throws: WasmError.functionNotFound) {
      try interp.callExport(nameBytes: Array("nonexistent".utf8), args: [])
    }
  }

  @Test func throwsOnArgumentCountMismatch() throws {
    let module = try parseModule("i32-add")
    var interp = try WasmInterpreter(module: module)
    #expect(throws: WasmError.argumentCountMismatch) {
      try interp.callExport(nameBytes: i32AddName, args: [.i32(1)])
    }
  }

  @Test func instantiatesWithStart() throws {
    let module = try parseModule("memory")
    // The start function (() -> ()) should run without error at instantiation
    _ = try WasmInterpreter(module: module)
  }

  @Test func executesLoop() throws {
    let module = try parseModule("loop")
    var interp = try WasmInterpreter(module: module)
    let result = try interp.callExport(nameBytes: Array("loop_test".utf8), args: [])
    #expect(result.isEmpty)
  }

  @Test func fizzBuzz() throws {
    var output: [String] = []

    let module = try parseModule("fizz-buzz")
    let hostImports: [HostImport] = [
      .function(
        "env", "print_string",
        { args, memory in
          guard case .i32(let offset) = args[0],
            case .i32(let len) = args[1]
          else { return [] }
          let bytes = Array(memory[Int(offset)..<(Int(offset) + Int(len))])
          output.append(String(bytes: bytes, encoding: .utf8) ?? "")
          return []
        }),
      .function(
        "env", "print_value",
        { args, _ in
          guard case .i32(let value) = args[0] else { return [] }
          output.append("\(value)")
          return []
        }),
      .memory("env", "buffer", 1),
    ]

    var interp = try WasmInterpreter(module: module, hostImports: hostImports)
    _ = try interp.callExport(nameBytes: Array("fizzbuzz".utf8), args: [.i32(16)])

    #expect(
      output == [
        "1", "2", "Fizz", "4", "Buzz", "Fizz", "7", "8",
        "Fizz", "Buzz", "11", "Fizz", "13", "14", "FizzBuzz",
      ])
  }

  @Test func blinkLoopCallsBlinkNTimes() throws {
    var blinkCount = 0

    let module = try parseModule("blink-loop")
    let hostImports: [HostImport] = [
      .function(
        "env", "blink",
        { _, _ in
          blinkCount += 1
          return []
        })
    ]

    var interp = try WasmInterpreter(module: module, hostImports: hostImports)
    _ = try interp.callExport(nameBytes: Array("blink_loop".utf8), args: [.i32(5)])
    #expect(blinkCount == 5)
  }

  @Test func tableGlobalIncrementDecrement() throws {
    let module = try parseModule("table")
    // Provide the imported host functions (their return values are unused in this test;
    // they're in the element segment but never called via call_indirect here)
    let hostImports: [HostImport] = [
      .function("js", "increment", { _, _ in [.i32(0)] }),
      .function("js", "decrement", { _, _ in [.i32(0)] }),
    ]
    var interp = try WasmInterpreter(module: module, hostImports: hostImports)

    // global $i starts at 0
    // increment: $i = 0 + 1 = 1, returns 1
    let r1 = try interp.callExport(nameBytes: Array("increment".utf8), args: [])
    #expect(r1 == [.i32(1)])

    // increment: $i = 1 + 1 = 2, returns 2
    let r2 = try interp.callExport(nameBytes: Array("increment".utf8), args: [])
    #expect(r2 == [.i32(2)])

    // decrement: $i = 2 - 1 = 1, returns 1
    let r3 = try interp.callExport(nameBytes: Array("decrement".utf8), args: [])
    #expect(r3 == [.i32(1)])

    // decrement: $i = 1 - 1 = 0, returns 0
    let r4 = try interp.callExport(nameBytes: Array("decrement".utf8), args: [])
    #expect(r4 == [.i32(0)])
  }

  @Test func blinkLoopWithZeroDoesNotBlink() throws {
    var blinkCount = 0

    let module = try parseModule("blink-loop")
    let hostImports: [HostImport] = [
      .function(
        "env", "blink",
        { _, _ in
          blinkCount += 1
          return []
        })
    ]

    var interp = try WasmInterpreter(module: module, hostImports: hostImports)
    _ = try interp.callExport(nameBytes: Array("blink_loop".utf8), args: [.i32(0)])
    #expect(blinkCount == 0)
  }

  @Test func forwardMutualRecursion() throws {
    // Tests even/odd mutual recursion from forward.0.wasm spectest
    let path = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("spectest/forward.0.wasm")
      .path
    guard let data = Foundation.FileManager.default.contents(atPath: path) else {
      return  // spectest not generated, skip
    }
    let bytes = [UInt8](data)
    let module = try parseBytes(bytes)
    var interp = try WasmInterpreter(module: module)
    let even = Array("even".utf8)
    let odd = Array("odd".utf8)
    #expect(try interp.callExport(nameBytes: even, args: [Value.i32(13)]) == [Value.i32(0)])
    #expect(try interp.callExport(nameBytes: even, args: [Value.i32(20)]) == [Value.i32(1)])
    #expect(try interp.callExport(nameBytes: odd, args: [Value.i32(13)]) == [Value.i32(1)])
    #expect(try interp.callExport(nameBytes: odd, args: [Value.i32(20)]) == [Value.i32(0)])
  }
}
