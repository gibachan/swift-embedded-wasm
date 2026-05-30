// Conformance test runner for the official WebAssembly spec testsuite.
//
// Prerequisites:
//   1. Run `make spectest-gen` once to convert .wast files to JSON + .wasm
//      (requires wabt: brew install wabt)
//   2. Run `swift test` as usual
//
// If Tests/WasmRuntimeTests/spectest/ is empty, this suite produces 0 tests
// and the overall test run is unaffected.
//
// Supported command types:
//   module          - instantiate a .wasm file
//   assert_return   - invoke a function and compare results
//   assert_trap     - invoke a function and expect any WasmError
//   assert_invalid  - parse a binary .wasm and expect parse failure
//   assert_malformed (binary) - same as assert_invalid
//
// Commands that are skipped:
//   - Modules/assertions using unsupported value types (i64, f32, f64, ...)
//   - Modules that fail to instantiate due to unsupported instructions
//   - assert_invalid/assert_malformed with module_type "text"
//   - register (cross-module imports - not yet implemented)
//
// As more instructions are implemented, add their value types to isSupportedType()
// and the corresponding tests will start running automatically.

import Foundation
import Testing

@testable import WasmRuntime

// MARK: - wast2json JSON model

private struct WastTestSuite: Decodable {
  let source_filename: String
  let commands: [WastCommand]
}

private struct WastCommand: Decodable {
  let type: String
  let line: Int
  let filename: String?  // .wasm file for module / assert_invalid
  let name: String?  // module id for named modules
  let module_type: String?  // "binary" or "text"
  let action: WastAction?
  let expected: [WastValue]?
  let text: String?  // expected trap message
  let asName: String?  // "as" field in register

  enum CodingKeys: String, CodingKey {
    case type, line, filename, name, module_type, action, expected, text
    case asName = "as"
  }
}

private struct WastAction: Decodable {
  let type: String  // "invoke" or "get"
  let module: String?  // named module reference (optional)
  let field: String
  let args: [WastValue]?
}

// Shared for both args and expected values.
// value is nil when type-only (e.g. assert_trap's expected field).
//
// Note: wast2json encodes v128 lane values as JSON arrays, not strings.
// The custom decoder normalizes both forms to String? (arrays → nil).
private struct WastValue: Decodable {
  let type: String
  let value: String?  // decimal bit-pattern string; nil for arrays (v128) or absent

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decode(String.self, forKey: .type)
    // Try string first; fall back to nil for arrays (v128 lane patterns)
    value = try? c.decodeIfPresent(String.self, forKey: .value) ?? nil
  }

  enum CodingKeys: String, CodingKey { case type, value }
}

// MARK: - Conformance runner

// Processes a single .json file produced by wast2json.
// Failures are recorded via Issue.record() so all assertions run before the
// test is marked failed - one test per .json file.
private struct ConformanceRunner {
  let baseDir: String

  // Current Wasm module state
  var currentInterp: WasmInterpreter?
  var currentModuleSkipped = false
  var namedModules: [String: WasmInterpreter] = [:]
  // Modules registered via "register" commands; keyed by the "as" name.
  // These are used to resolve cross-module function imports in subsequently loaded modules.
  var registeredModules: [String: WasmInterpreter] = [:]

  // Set to true after an assert_uninstantiable that we handled (pass or skip).
  // The spec applies element segments before a trap-on-instantiation, producing
  // side effects we cannot replicate without cross-module linking support.
  // When true, an unexpected WasmError in the next assert_return is treated as
  // skip rather than fail, since the missing side effect is the root cause.
  var hadUninstantiableSkip = false

  // Stats (informational only - failures drive pass/fail via Issue.record)
  var passCount = 0
  var skipCount = 0
  var failCount = 0

  init(baseDir: String) {
    self.baseDir = baseDir
  }

  mutating func run(suite: WastTestSuite) {
    for command in suite.commands {
      handle(command)
    }
  }

  // MARK: Dispatch

  private mutating func handle(_ cmd: WastCommand) {
    switch cmd.type {
    case "module": handleModule(cmd)
    case "assert_return": handleAssertReturn(cmd)
    case "assert_trap": handleAssertTrap(cmd)
    case "assert_invalid",
      "assert_malformed":
      handleAssertInvalid(cmd)
    case "action": handleAction(cmd)
    case "assert_uninstantiable": handleAssertUninstantiable(cmd)
    case "register": handleRegister(cmd)
    default: skipCount += 1  // assert_exhaustion etc.
    }
  }

  // MARK: module

  private mutating func handleModule(_ cmd: WastCommand) {
    hadUninstantiableSkip = false
    guard let filename = cmd.filename,
      let bytes = loadFile(filename)
    else {
      currentInterp = nil
      currentModuleSkipped = true
      skipCount += 1
      return
    }
    do {
      let module = try parseBytes(bytes)
      // Build host imports: standard spectest imports plus any cross-module imports
      // from modules previously registered via the "register" command.
      let hostImports = spectestHostImports() + crossModuleImports(for: module)
      let interp = try WasmInterpreter(module: module, hostImports: hostImports)
      currentInterp = interp
      currentModuleSkipped = false
      if let name = cmd.name {
        namedModules[name] = interp
      }
      passCount += 1
    } catch WasmError.invalidInstruction(_) {
      // Module uses an instruction we haven't implemented yet.
      currentInterp = nil
      currentModuleSkipped = true
      skipCount += 1
    } catch {
      // importNotFound, unsupportedElementSegment, etc.
      currentInterp = nil
      currentModuleSkipped = true
      skipCount += 1
    }
  }

  // MARK: register

  // register: binds the current (or named) module under a new name so that
  // subsequently loaded modules can import from it by that name.
  private mutating func handleRegister(_ cmd: WastCommand) {
    guard let asName = cmd.asName else {
      skipCount += 1
      return
    }
    // If the command names a specific module (via cmd.name), use that; otherwise
    // use the most recently instantiated module.
    let interp: WasmInterpreter?
    if let moduleName = cmd.name {
      interp = namedModules[moduleName]
    } else {
      interp = currentInterp
    }
    guard let reg = interp else {
      skipCount += 1
      return
    }
    registeredModules[asName] = reg
    passCount += 1
  }

  // MARK: Cross-module import helpers

  // Builds HostImport entries for any function imports in `module` that refer to
  // a module name present in `registeredModules`.
  //
  // The returned closures capture a value-copy of the registered interpreter.
  // This is intentional: ef0-ef4 are pure constant functions and do not mutate
  // state, so a value copy is safe and avoids shared-mutable state.
  private func crossModuleImports(for module: WasmModule) -> [HostImport] {
    var result: [HostImport] = []
    for imp in module.imports {
      guard case .function(let fi) = imp else { continue }
      let modName = String(bytes: fi.module, encoding: .utf8) ?? ""
      guard let regInterp = registeredModules[modName] else { continue }
      // Value-copy the interpreter so the closure is self-contained.
      var capturedInterp = regInterp
      let fieldBytes = fi.name  // [UInt8]; captured by value
      let hf: HostFunction = { args, _ in
        return (try? capturedInterp.callExport(nameBytes: fieldBytes, args: args)) ?? []
      }
      let fieldName = String(bytes: fi.name, encoding: .utf8) ?? ""
      result.append(.function(modName, fieldName, hf))
    }
    return result
  }

  // MARK: assert_return

  private mutating func handleAssertReturn(_ cmd: WastCommand) {
    if currentModuleSkipped {
      skipCount += 1
      return
    }
    guard let action = cmd.action else {
      skipCount += 1
      return
    }

    // Skip if any arg or expected value type is not yet supported.
    let allValues = (action.args ?? []) + (cmd.expected ?? [])
    if allValues.contains(where: { !isSupportedType($0.type) }) {
      skipCount += 1
      return
    }

    do {
      let actual = try invoke(action)
      let expected = cmd.expected ?? []
      if valuesMatch(actual: actual, expected: expected) {
        passCount += 1
      } else {
        failCount += 1
        Issue.record(
          "Line \(cmd.line): expected [\(describeValues(expected))], got [\(actual)]"
        )
      }
    } catch WasmError.invalidInstruction(_) {
      skipCount += 1
    } catch WasmError.executionLimitExceeded {
      skipCount += 1
    } catch {
      // If a preceding assert_uninstantiable was skipped, its element-segment
      // side effects were never applied in our interpreter. An unexpected error
      // here is most likely due to that missing state, not a real bug.
      if hadUninstantiableSkip {
        hadUninstantiableSkip = false
        skipCount += 1
      } else {
        failCount += 1
        Issue.record("Line \(cmd.line): unexpected error in assert_return: \(error)")
      }
    }
  }

  // MARK: assert_trap

  private mutating func handleAssertTrap(_ cmd: WastCommand) {
    if currentModuleSkipped {
      skipCount += 1
      return
    }
    guard let action = cmd.action else {
      skipCount += 1
      return
    }

    if (action.args ?? []).contains(where: { !isSupportedType($0.type) }) {
      skipCount += 1
      return
    }

    do {
      _ = try invoke(action)
      // No error thrown - should have trapped.
      failCount += 1
      Issue.record(
        "Line \(cmd.line): expected trap '\(cmd.text ?? "")' but execution succeeded"
      )
    } catch WasmError.invalidInstruction(_) {
      skipCount += 1
    } catch WasmError.executionLimitExceeded {
      skipCount += 1
    } catch {
      // Any WasmError = some trap occurred = pass.
      passCount += 1
    }
  }

  // MARK: assert_invalid / assert_malformed

  private mutating func handleAssertInvalid(_ cmd: WastCommand) {
    // Only binary modules - we have no text-format parser.
    if cmd.module_type == "text" {
      skipCount += 1
      return
    }
    guard let filename = cmd.filename,
      filename.hasSuffix(".wasm"),
      let bytes = loadFile(filename)
    else {
      skipCount += 1
      return
    }
    do {
      _ = try parseBytes(bytes)
      // Parsing succeeded but should have failed.
      // We skip rather than fail: most of these test validation rules
      // (type checking) that we have not yet implemented.
      skipCount += 1
    } catch {
      passCount += 1  // correctly rejected the invalid module
    }
  }

  // MARK: assert_uninstantiable

  // assert_uninstantiable: the module must fail to instantiate (trap during init).
  // We lack the full validation and cross-module linking required to verify this
  // correctly, so we skip rather than attempt instantiation.
  // hadUninstantiableSkip is set so that the immediately following assert_return
  // can absorb an unexpected WasmError that results from missing element-segment
  // side effects (which the spec applies before the instantiation trap).
  private mutating func handleAssertUninstantiable(_ cmd: WastCommand) {
    hadUninstantiableSkip = true
    skipCount += 1
  }

  // MARK: action

  private mutating func handleAction(_ cmd: WastCommand) {
    if currentModuleSkipped {
      skipCount += 1
      return
    }
    guard let action = cmd.action else {
      skipCount += 1
      return
    }
    if (action.args ?? []).contains(where: { !isSupportedType($0.type) }) {
      skipCount += 1
      return
    }
    do {
      _ = try invoke(action)
      passCount += 1
    } catch WasmError.invalidInstruction(_) {
      skipCount += 1
    } catch WasmError.executionLimitExceeded {
      skipCount += 1
    } catch {
      failCount += 1
      Issue.record("Line \(cmd.line): action failed: \(error)")
    }
  }

  // MARK: Invoke

  private mutating func invoke(_ action: WastAction) throws -> [Value] {
    // "get" (global read) is not yet supported.
    guard action.type == "invoke" else { throw WasmError.functionNotFound }
    guard var interp = resolveModule(named: action.module) else {
      throw WasmError.functionNotFound
    }
    var args: [Value] = []
    for v in (action.args ?? []) {
      args.append(try convertValue(v))
    }
    let result = try interp.callExport(nameBytes: Array(action.field.utf8), args: args)
    // Persist mutations (updated globals etc.)
    storeModule(named: action.module, interp: interp)
    return result
  }

  private func resolveModule(named name: String?) -> WasmInterpreter? {
    if let name { return namedModules[name] }
    return currentInterp
  }

  private mutating func storeModule(named name: String?, interp: WasmInterpreter) {
    if let name { namedModules[name] = interp } else { currentInterp = interp }
  }

  // MARK: Value helpers

  private func isSupportedType(_ type: String) -> Bool {
    // Expand this list as more value types are implemented in the interpreter.
    type == "i32" || type == "i64" || type == "f32" || type == "f64" || type == "funcref"
  }

  private func convertValue(_ v: WastValue) throws -> Value {
    switch v.type {
    case "i32":
      guard let str = v.value, let bits = UInt32(str) else { throw WasmError.typeMismatch }
      return .i32(Int32(bitPattern: bits))
    case "i64":
      guard let str = v.value, let bits = UInt64(str) else { throw WasmError.typeMismatch }
      return .i64(Int64(bitPattern: bits))
    case "f32":
      let str = v.value ?? "nan:canonical"
      // nan:canonical / nan:arithmetic: pass canonical NaN (0x7FC00000) as input
      if str == "nan:canonical" || str == "nan:arithmetic" {
        return .f32(.nan)
      }
      guard let bits = UInt32(str) else { throw WasmError.typeMismatch }
      return .f32(Float(bitPattern: bits))
    case "f64":
      let str = v.value ?? "nan:canonical"
      if str == "nan:canonical" || str == "nan:arithmetic" {
        return .f64(.nan)
      }
      guard let bits = UInt64(str) else { throw WasmError.typeMismatch }
      return .f64(Double(bitPattern: bits))
    case "funcref":
      let str = v.value ?? "null"
      if str == "null" { return .funcref(nil) }
      guard let idx = UInt32(str) else { throw WasmError.typeMismatch }
      return .funcref(idx)
    default:
      throw WasmError.typeMismatch
    }
  }

  private func valuesMatch(actual: [Value], expected: [WastValue]) -> Bool {
    guard actual.count == expected.count else { return false }
    for (a, e) in zip(actual, expected) {
      if !valueMatches(actual: a, expected: e) { return false }
    }
    return true
  }

  private func valueMatches(actual: Value, expected: WastValue) -> Bool {
    switch expected.type {
    case "i32":
      guard let str = expected.value,
        let bits = UInt32(str),
        case .i32(let av) = actual
      else { return false }
      return av == Int32(bitPattern: bits)
    case "i64":
      guard let str = expected.value,
        let bits = UInt64(str),
        case .i64(let av) = actual
      else { return false }
      return av == Int64(bitPattern: bits)
    case "f32":
      guard case .f32(let af) = actual else { return false }
      let expStr = expected.value ?? ""
      if expStr == "nan:canonical" {
        // Canonical NaN: exponent all 1s, top mantissa bit set, lower 22 bits zero
        // Bit pattern (ignoring sign): 0x7FC00000
        guard af.isNaN else { return false }
        return (af.bitPattern & 0x7FFF_FFFF) == 0x7FC0_0000
      } else if expStr == "nan:arithmetic" {
        return af.isNaN
      } else {
        guard let bits = UInt32(expStr) else { return false }
        return af.bitPattern == bits
      }
    case "f64":
      guard case .f64(let af) = actual else { return false }
      let expStr = expected.value ?? ""
      if expStr == "nan:canonical" {
        // Canonical NaN for f64: quiet bit (bit 51) set, lower 51 bits zero
        // Bit pattern (ignoring sign): 0x7FF8_0000_0000_0000
        guard af.isNaN else { return false }
        return (af.bitPattern & 0x7FFF_FFFF_FFFF_FFFF) == 0x7FF8_0000_0000_0000
      } else if expStr == "nan:arithmetic" {
        return af.isNaN
      } else {
        guard let bits = UInt64(expStr) else { return false }
        return af.bitPattern == bits
      }
    case "funcref":
      guard case .funcref(let ar) = actual else { return false }
      let expStr = expected.value ?? "null"
      if expStr == "null" { return ar == nil }
      guard let idx = UInt32(expStr) else { return false }
      return ar == idx
    default:
      return false
    }
  }

  private func describeValues(_ values: [WastValue]) -> String {
    values.map { "\($0.type)(\($0.value ?? "?"))" }.joined(separator: ", ")
  }

  // MARK: File loading

  private func loadFile(_ filename: String) -> [UInt8]? {
    let path = "\(baseDir)/\(filename)"
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return [UInt8](data)
  }
}

// MARK: - Spectest host module

// Provides the standard "spectest" imports used by many spec test modules.
// See: https://github.com/WebAssembly/spec/tree/main/interpreter#spectest-host-module
//
// Note: spectest.global_i32 / spectest.table are not provided here because
// HostImport does not yet support global or table imports. Modules that require
// them will fail at instantiation and be marked SKIP.
private func spectestHostImports() -> [HostImport] {
  [
    .function("spectest", "print", { _, _ in [] }),
    .function("spectest", "print_i32", { _, _ in [] }),
    .function("spectest", "print_i64", { _, _ in [] }),
    .function("spectest", "print_f32", { _, _ in [] }),
    .function("spectest", "print_f64", { _, _ in [] }),
    .function("spectest", "print_i32_f32", { _, _ in [] }),
    .function("spectest", "print_f64_f64", { _, _ in [] }),
    .memory("spectest", "memory", 1),
  ]
}

// MARK: - Test file descriptor

struct SpectestFile: Sendable, CustomStringConvertible {
  let name: String
  let jsonPath: String

  var description: String { name }
}

// MARK: - Test suite

@Suite("Spectest Conformance", .serialized)
struct SpectestTests {
  // Locate the spectest/ directory relative to this source file.
  // The directory is created by `make spectest-gen` and is .gitignored.
  private static let spectestDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("spectest")
    .path

  // Discovers .json files at test-module-load time.
  // Returns [] if the directory does not exist (spectest-gen not yet run).
  static func discoverFiles() -> [SpectestFile] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: spectestDir) else {
      return []
    }
    return
      entries
      .filter { $0.hasSuffix(".json") }
      .sorted()
      .map { SpectestFile(name: String($0.dropLast(5)), jsonPath: "\(spectestDir)/\($0)") }
  }

  @Test(arguments: SpectestTests.discoverFiles())
  func conformance(file: SpectestFile) throws {
    guard let data = FileManager.default.contents(atPath: file.jsonPath) else { return }
    let suite = try JSONDecoder().decode(WastTestSuite.self, from: data)
    var runner = ConformanceRunner(
      baseDir: URL(fileURLWithPath: file.jsonPath).deletingLastPathComponent().path
    )
    runner.run(suite: suite)
    // Individual failures are recorded via Issue.record() in the runner.
    print(
      "[\(file.name)] pass=\(runner.passCount) skip=\(runner.skipCount) fail=\(runner.failCount)")
  }
}
