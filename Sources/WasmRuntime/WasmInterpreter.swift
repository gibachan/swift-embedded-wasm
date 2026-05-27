// Wasm stack machine interpreter — iterative execution engine
//
// Wasm is a stack machine: instructions pop operands from the stack and push results.
// Function arguments and declared local variables are stored in a "locals" array
// accessible by index.
//
// Structured control flow (block / loop / br):
//   Each nested scope (block/loop/if) is pushed onto a per-frame scope stack.
//   br(n) pops n+1 scopes: the first n are discarded (bypassed), the (n+1)th is
//   either restarted (loop) or exited (block/ifElse).
//
// Function calls:
//   Instead of recursive Swift calls, an explicit frame stack is maintained.
//   Each frame tracks its scope stack and locals; the value stack is shared.
//   This avoids Swift stack overflow for deeply-recursive Wasm programs.

// MARK: - Host Function Types

/// Type of a host-provided function.
/// args: argument values, memory: read-only view of linear memory.
typealias HostFunction = ([Value], [UInt8]) -> [Value]

/// Import bindings provided by the host at instantiation time
enum HostImport {
  case function(String, String, HostFunction)  // (module, name, body)
  case memory(String, String, UInt32)          // (module, name, pages)
}

// Wasm f32.min: propagates NaN; treats -0 < +0
private func wasmF32Min(_ a: Float, _ b: Float) -> Float {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
  return Swift.min(a, b)
}

// Wasm f32.max: propagates NaN; treats +0 > -0
private func wasmF32Max(_ a: Float, _ b: Float) -> Float {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0 }
  return Swift.max(a, b)
}

// MARK: - Iterative execution engine types

/// A label scope within a function execution (one per block/loop/if or function top-level)
private enum ScopeKind {
  case topLevel   // function's implicit outer block; br here = early return
  case block      // br(0) exits; stack trimmed to scope base
  case loop       // br(0) restarts from ip=0
  case ifElse     // br(0) exits; like block
}

private struct Scope {
  var instructions: [Instruction]
  var ip: Int
  let kind: ScopeKind
  let stackBase: Int  // value stack depth when this scope was entered
}

/// One activation record per live Wasm function invocation
private struct Frame {
  var scopes: [Scope]   // scopes[last] = current executing scope
  var locals: [Value]
  let stackBase: Int    // value stack depth when this frame was entered
  let resultCount: Int
}

// MARK: - Interpreter

// Does not conform to Sendable because HostFunction (a closure) is not Sendable.
struct WasmInterpreter {
  let module: WasmModule
  let memory: [UInt8]
  private let hostFunctions: [HostFunction]
  private var globals: [Value]  // mutable global variable slots (global.get/set)

  // MARK: - Init

  /// Instantiates the module.
  ///
  /// - hostImports: host-provided functions and memories required by the module's imports.
  ///   Throws .importNotFound if an import is declared but no matching HostImport is given.
  init(module: WasmModule, hostImports: [HostImport] = []) throws(WasmError) {
    self.module = module

    // Match host functions to imports, preserving import order.
    // Compare as UTF8 byte sequences (fi.module/fi.name are [UInt8]; m/n are String).
    // String == triggers Unicode normalization (NFC) which is unavailable in Embedded Swift,
    // so use elementsEqual against the raw utf8 view instead.
    var funcs: [HostFunction] = []
    for imp in module.imports {
      guard case .function(let fi) = imp else { continue }
      var found = false
      for hi in hostImports {
        guard case .function(let m, let n, let body) = hi else { continue }
        if fi.module.elementsEqual(m.utf8) && fi.name.elementsEqual(n.utf8) {
          funcs.append(body)
          found = true
          break
        }
      }
      guard found else { throw .importNotFound }
    }
    self.hostFunctions = funcs
    self.globals = module.globals.map { $0.initValue }

    // Determine memory size: prefer imported memory, fall back to local memory definition
    var memPageCount: UInt32 = 0
    for imp in module.imports {
      guard case .memory(let mi) = imp else { continue }
      var found = false
      for hi in hostImports {
        guard case .memory(let m, let n, let pages) = hi else { continue }
        if mi.module.elementsEqual(m.utf8) && mi.name.elementsEqual(n.utf8) {
          memPageCount = max(memPageCount, pages)
          found = true
          break
        }
      }
      guard found else { throw .importNotFound }
    }
    if memPageCount == 0, let localMem = module.memories.first {
      memPageCount = localMem.min
    }

    // Allocate memory and initialize it from data segments (1 page = 64 KiB)
    var mem = [UInt8](repeating: 0, count: Int(memPageCount) * 65536)
    for seg in module.data {
      let start = Int(seg.offset)
      let end = start + seg.bytes.count
      guard end <= mem.count else { throw .memoryAccessOutOfBounds }
      mem.replaceSubrange(start..<end, with: seg.bytes)
    }
    self.memory = mem

    // Wasm spec: the start function is called automatically at instantiation
    if let startIdx = module.start {
      _ = try call(functionIndex: Int(startIdx), args: [])
    }
  }

  // MARK: - Public

  /// Calls an exported function by name (UTF-8 bytes)
  mutating func callExport(nameBytes: [UInt8], args: [Value]) throws(WasmError) -> [Value] {
    guard let export = module.exports.first(where: { $0.nameBytes == nameBytes && $0.kind == .function }) else {
      throw .functionNotFound
    }
    return try call(functionIndex: Int(export.index), args: args)
  }

  /// Calls a function by its unified function index (including imports)
  mutating func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let importedCount = module.importedFunctionCount

    if functionIndex < importedCount {
      // Host function: pass a read-only view of memory
      return hostFunctions[functionIndex](args, memory)
    }

    // Local function: validate and run iteratively
    let localIdx = functionIndex - importedCount
    let typeIndex = Int(module.functions[localIdx])
    let funcType = module.types[typeIndex]
    guard args.count == funcType.params.count else {
      throw .argumentCountMismatch
    }

    return try runIterative(functionIndex: functionIndex, args: args)
  }

  // MARK: - Iterative Execution Engine

  /// Executes a Wasm function using an explicit frame + scope stack.
  /// No Swift recursion is used for Wasm function calls or control flow,
  /// so arbitrarily deep Wasm recursion does not overflow the Swift stack.
  private mutating func runIterative(
    functionIndex: Int,
    args: [Value]
  ) throws(WasmError) -> [Value] {

    var valueStack: [Value] = []
    var frames: [Frame] = []

    // Push a Wasm function frame.  Host functions are executed inline (no frame push).
    @inline(__always)
    func pushFrame(funcIdx: Int, callArgs: [Value]) throws(WasmError) {
      let importedCount = module.importedFunctionCount
      if funcIdx < importedCount {
        let result = hostFunctions[funcIdx](callArgs, memory)
        valueStack.append(contentsOf: result)
        return
      }
      let localIdx = funcIdx - importedCount
      let typeIdx = Int(module.functions[localIdx])
      let funcType = module.types[typeIdx]
      let body = module.code[localIdx]
      guard callArgs.count == funcType.params.count else { throw .argumentCountMismatch }
      var locals = callArgs
      for vt in body.locals {
        switch vt {
        case .i32: locals.append(.i32(0))
        case .f32: locals.append(.f32(0.0))
        default:   locals.append(.i32(0))
        }
      }
      let base = valueStack.count
      let topScope = Scope(instructions: body.instructions, ip: 0, kind: .topLevel, stackBase: base)
      frames.append(Frame(scopes: [topScope], locals: locals, stackBase: base, resultCount: funcType.results.count))
    }

    // Handle a branch: pop `depth` scopes, then process the target scope.
    @inline(__always)
    func handleBranch(depth: UInt32, fi: Int) throws(WasmError) {
      var d = Int(depth)
      // Discard intermediate scopes (the labels being "passed through")
      while d > 0 {
        guard !frames[fi].scopes.isEmpty else { throw .stackUnderflow }
        frames[fi].scopes.removeLast()
        d -= 1
      }
      // Target scope
      guard !frames[fi].scopes.isEmpty else { throw .stackUnderflow }
      let target = frames[fi].scopes.removeLast()
      switch target.kind {
      case .loop:
        // br to loop = restart: reset ip to 0, restore stack to scope entry
        valueStack.removeSubrange(target.stackBase...)
        var restarted = target
        restarted.ip = 0
        frames[fi].scopes.append(restarted)
      case .block, .ifElse:
        // br to block/if = exit: trim stack to scope base (keeping block arity values
        // above stackBase is not yet needed; all our tested blocks have void arity on br)
        valueStack.removeSubrange(target.stackBase...)
      case .topLevel:
        // br targeting function label = early return
        let resultCount = frames[fi].resultCount
        let frameBase = frames[fi].stackBase
        let results: [Value]
        if valueStack.count >= frameBase + resultCount {
          results = Array(valueStack.suffix(resultCount))
        } else {
          throw WasmError.stackUnderflow
        }
        valueStack.removeSubrange(frameBase...)
        valueStack.append(contentsOf: results)
        frames[fi].scopes.removeAll()
      }
    }

    try pushFrame(funcIdx: functionIndex, callArgs: args)

    while !frames.isEmpty {
      let fi = frames.count - 1

      // Frame done (all scopes exhausted)?
      if frames[fi].scopes.isEmpty {
        let resultCount = frames[fi].resultCount
        let frameBase = frames[fi].stackBase
        let results: [Value]
        if valueStack.count >= frameBase + resultCount {
          results = Array(valueStack.suffix(resultCount))
        } else if valueStack.count == frameBase && resultCount == 0 {
          results = []
        } else {
          throw WasmError.stackUnderflow
        }
        valueStack.removeSubrange(frameBase...)
        valueStack.append(contentsOf: results)
        frames.removeLast()
        continue
      }

      let si = frames[fi].scopes.count - 1

      // Current scope exhausted?
      if frames[fi].scopes[si].ip >= frames[fi].scopes[si].instructions.count {
        frames[fi].scopes.removeLast()
        continue
      }

      // Fetch next instruction
      let instr = frames[fi].scopes[si].instructions[frames[fi].scopes[si].ip]
      frames[fi].scopes[si].ip += 1

      // Execute instruction
      switch instr {

      case .localGet(let idx):
        valueStack.append(frames[fi].locals[Int(idx)])

      case .localSet(let idx):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        frames[fi].locals[Int(idx)] = valueStack.removeLast()

      case .globalGet(let idx):
        valueStack.append(globals[Int(idx)])

      case .globalSet(let idx):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        globals[Int(idx)] = valueStack.removeLast()

      case .i32Const(let value):
        valueStack.append(.i32(value))

      // --- i32 unary ---

      case .i32Eqz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(a == 0 ? 1 : 0))

      case .i32Clz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).leadingZeroBitCount)))

      case .i32Ctz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).trailingZeroBitCount)))

      case .i32Popcnt:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).nonzeroBitCount)))

      case .i32Extend8S:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(Int8(bitPattern: UInt8(a & 0xFF)))))

      case .i32Extend16S:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(Int16(bitPattern: UInt16(a & 0xFFFF)))))

      // --- i32 comparisons ---

      case .i32Eq:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))

      case .i32Ne:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))

      case .i32LtS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))

      case .i32LtU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) < UInt32(bitPattern: b) ? 1 : 0))

      case .i32GtS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))

      case .i32GtU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) > UInt32(bitPattern: b) ? 1 : 0))

      case .i32LeS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))

      case .i32LeU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) <= UInt32(bitPattern: b) ? 1 : 0))

      case .i32GeS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))

      case .i32GeU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) >= UInt32(bitPattern: b) ? 1 : 0))

      // --- i32 arithmetic ---

      case .i32Add:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a &+ b))

      case .i32Sub:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a &- b))

      case .i32Mul:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a &* b))

      case .i32DivS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        guard !(a == Int32.min && b == -1) else { throw .integerOverflow }
        valueStack.append(.i32(a / b))

      case .i32DivU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) / UInt32(bitPattern: b))))

      case .i32RemS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        // INT32_MIN % -1 would overflow in Swift; result is defined as 0 in Wasm
        valueStack.append(.i32(a == Int32.min && b == -1 ? 0 : a % b))

      case .i32RemU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) % UInt32(bitPattern: b))))

      // --- i32 bitwise ---

      case .i32And:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a & b))

      case .i32Or:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a | b))

      case .i32Xor:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a ^ b))

      case .i32Shl:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt32(bitPattern: b) & 31
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) << shift)))

      case .i32ShrS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = Int32(UInt32(bitPattern: b) & 31)
        valueStack.append(.i32(a >> shift))

      case .i32ShrU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt32(bitPattern: b) & 31
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) >> shift)))

      case .i32Rotl:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt32(bitPattern: b) & 31
        let ua = UInt32(bitPattern: a)
        let result = shift == 0 ? ua : (ua << shift | ua >> (32 - shift))
        valueStack.append(.i32(Int32(bitPattern: result)))

      case .i32Rotr:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
              case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt32(bitPattern: b) & 31
        let ua = UInt32(bitPattern: a)
        let result = shift == 0 ? ua : (ua >> shift | ua << (32 - shift))
        valueStack.append(.i32(Int32(bitPattern: result)))

      // --- f32 constant ---

      case .f32Const(let value):
        valueStack.append(.f32(value))

      // --- f32 comparisons (return i32) ---

      case .f32Eq:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))

      case .f32Ne:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))

      case .f32Lt:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))

      case .f32Gt:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))

      case .f32Le:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))

      case .f32Ge:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))

      // --- f32 unary ---

      case .f32Abs:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.magnitude))

      case .f32Neg:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(-a))

      case .f32Ceil:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.rounded(.up)))

      case .f32Floor:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.rounded(.down)))

      case .f32Trunc:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.rounded(.towardZero)))

      case .f32Nearest:
        // Wasm: round to nearest, ties-to-even (IEEE 754 roundTiesToEven)
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.rounded(.toNearestOrEven)))

      case .f32Sqrt:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.squareRoot()))

      // --- f32 binary arithmetic ---

      case .f32Add:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(a + b))

      case .f32Sub:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(a - b))

      case .f32Mul:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(a * b))

      case .f32Div:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(a / b))

      case .f32Min:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(wasmF32Min(a, b)))

      case .f32Max:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(wasmF32Max(a, b)))

      case .f32Copysign:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
              case .f32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f32(Float(signOf: b, magnitudeOf: a)))

      // --- memory access ---

      case .call(let funcIdx):
        let funcType = module.functionType(at: Int(funcIdx))
        let argCount = funcType.params.count
        guard valueStack.count >= argCount else { throw .stackUnderflow }
        let callArgs = Array(valueStack.suffix(argCount))
        valueStack.removeLast(argCount)
        try pushFrame(funcIdx: Int(funcIdx), callArgs: callArgs)

      // --- structured control flow ---

      case .block(_, let inner):
        let base = valueStack.count
        frames[fi].scopes.append(Scope(instructions: inner, ip: 0, kind: .block, stackBase: base))

      case .loop(_, let inner):
        let base = valueStack.count
        frames[fi].scopes.append(Scope(instructions: inner, ip: 0, kind: .loop, stackBase: base))

      case .ifElse(_, let thenBody, let elseBody):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw .typeMismatch }
        let body = cond != 0 ? thenBody : elseBody
        let base = valueStack.count
        frames[fi].scopes.append(Scope(instructions: body, ip: 0, kind: .ifElse, stackBase: base))

      case .br(let depth):
        try handleBranch(depth: depth, fi: fi)

      case .brIf(let depth):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw .typeMismatch }
        if cond != 0 {
          try handleBranch(depth: depth, fi: fi)
        }
      }
    }

    return valueStack
  }
}
