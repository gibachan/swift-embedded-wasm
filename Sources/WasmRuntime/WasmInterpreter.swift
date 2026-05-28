// Wasm stack machine interpreter — flat bytecode execution engine
//
// Wasm is a stack machine: instructions pop operands from the stack and push results.
// Function arguments and declared local variables are stored in a "locals" array
// accessible by index.
//
// Structured control flow (block / loop / if):
//   Each nested scope pushes a Label onto a per-frame label stack.
//   br(n) finds the label at depth n:
//     block / if  — pop the label and all above it; jump to continuationPc (past blockEnd)
//     loop        — keep the label; pop only the intermediaries; jump to startPc (restart)
//   blockEnd pops the top label (normal fall-through exit from block/loop/if).
//
// Flat bytecode:
//   All instructions live in one flat array per function. block/loop/if carry pre-computed
//   integer PCs baked in by the parser (no indirect enum cases, no heap allocation for nesting).
//   jump(pc) is an unconditional branch emitted by the parser to skip the else body in if/else.
//
// Function calls:
//   An explicit frame stack is used so that arbitrarily deep Wasm recursion does not
//   overflow the Swift call stack. Each frame owns its label stack and locals; the
//   value stack is shared across all frames.

// MARK: - Host Function Types

/// Type of a host-provided function.
/// args: argument values, memory: read-only view of linear memory.
typealias HostFunction = ([Value], [UInt8]) -> [Value]

/// Import bindings provided by the host at instantiation time
enum HostImport {
  case function(String, String, HostFunction)  // (module, name, body)
  case memory(String, String, UInt32)  // (module, name, pages)
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

// MARK: - Label (replaces Scope)

private enum LabelKind {
  case block  // br exits; jump to continuationPc (past blockEnd)
  case loop  // br restarts; jump to continuationPc (= startPc); label stays on stack
  case ifElse  // br exits; same as block
}

private struct Label {
  let kind: LabelKind
  let stackBase: Int  // value stack depth when this label was entered
  let brArity: Int  // values carried by br (block/if: result count; loop: param count)
  let continuationPc: Int  // where br to this label jumps:
  //   block/if: past blockEnd (= blockEndPc + 1)
  //   loop:     first body instruction (restart)
}

// MARK: - Frame

private struct Frame {
  let instructions: [Instruction]  // flat function body; shared with module.code (no copy)
  var ip: Int
  var labels: [Label]
  var locals: [Value]
  let stackBase: Int  // value stack depth when this frame was entered
  let resultCount: Int  // number of return values
}

// MARK: - Block arity helpers

private func blockArity(_ bt: BlockType, types: [FunctionType]) -> Int {
  switch bt {
  case .void: return 0
  case .value: return 1
  case .typeIndex(let idx):
    guard Int(idx) < types.count else { return 0 }
    return types[Int(idx)].results.count
  }
}

// For loop br: carries param count (not result count).
// In MVP loops have no params; multi-value loops carry params on branch.
private func loopBrArity(_ bt: BlockType, types: [FunctionType]) -> Int {
  switch bt {
  case .void, .value: return 0
  case .typeIndex(let idx):
    guard Int(idx) < types.count else { return 0 }
    return types[Int(idx)].params.count
  }
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
    guard
      let export = module.exports.first(where: { $0.nameBytes == nameBytes && $0.kind == .function }
      )
    else {
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

  /// Executes a Wasm function using an explicit frame + label stack.
  /// No Swift recursion is used for Wasm function calls or control flow.
  private mutating func runIterative(
    functionIndex: Int,
    args: [Value],
    fuelLimit: Int = 10_000_000
  ) throws(WasmError) -> [Value] {

    var valueStack: [Value] = []
    var frames: [Frame] = []
    var fuel = fuelLimit

    // Push a Wasm function frame. Host functions are executed inline (no frame push).
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
        case .i64: locals.append(.i64(0))
        case .f32: locals.append(.f32(0.0))
        case .f64: locals.append(.i32(0))  // f64 not implemented; placeholder
        }
      }
      frames.append(
        Frame(
          instructions: body.instructions,
          ip: 0,
          labels: [],
          locals: locals,
          stackBase: valueStack.count,
          resultCount: funcType.results.count))
    }

    // Handle a branch to label at `depth` levels from the top of the label stack.
    //
    // br semantics:
    //   - Save the top brArity values (carried to the target label).
    //   - Trim the value stack back to the target label's stackBase.
    //   - Push the saved values.
    //   - For block/if: pop the target label (and all above), jump to continuationPc.
    //   - For loop:     keep the target label (pop only above it), jump to continuationPc.
    //   - If depth >= label count: target is the function's implicit outer label → return.
    @inline(__always)
    func handleBranch(depth: UInt32, fi: Int) throws(WasmError) {
      let d = Int(depth)
      let labelCount = frames[fi].labels.count

      if d >= labelCount {
        // Branch to function's implicit outer label = early return
        let resultCount = frames[fi].resultCount
        let frameBase = frames[fi].stackBase
        let src = valueStack.count - resultCount
        for i in 0..<resultCount { valueStack[frameBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((frameBase + resultCount)...)
        frames[fi].labels.removeAll()
        frames[fi].ip = frames[fi].instructions.count  // signal frame done
        return
      }

      let targetIdx = labelCount - 1 - d
      let target = frames[fi].labels[targetIdx]

      // Slide br-arity values to target's stackBase in-place (no temp array)
      let src = valueStack.count - target.brArity
      for i in 0..<target.brArity { valueStack[target.stackBase + i] = valueStack[src + i] }
      valueStack.removeSubrange((target.stackBase + target.brArity)...)

      switch target.kind {
      case .loop:
        // Keep the loop label; pop only intermediary labels above it.
        // Jump to startPc to restart the loop body.
        frames[fi].labels.removeSubrange((targetIdx + 1)...)
        frames[fi].ip = target.continuationPc
      case .block, .ifElse:
        // Pop the target label and all above it; jump past the block's blockEnd.
        frames[fi].labels.removeSubrange(targetIdx...)
        frames[fi].ip = target.continuationPc
      }
    }

    try pushFrame(funcIdx: functionIndex, callArgs: args)

    while !frames.isEmpty {
      let fi = frames.count - 1

      // Frame done (instruction pointer past the end of the flat body)?
      if frames[fi].ip >= frames[fi].instructions.count {
        let resultCount = frames[fi].resultCount
        let frameBase = frames[fi].stackBase
        guard valueStack.count >= frameBase + resultCount else { throw WasmError.stackUnderflow }
        let src = valueStack.count - resultCount
        for i in 0..<resultCount { valueStack[frameBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((frameBase + resultCount)...)
        frames.removeLast()
        continue
      }

      // Fetch and advance instruction pointer
      fuel -= 1
      if fuel < 0 { throw WasmError.executionLimitExceeded }
      let instr = frames[fi].instructions[frames[fi].ip]
      frames[fi].ip += 1

      // Execute instruction
      switch instr {

      // MARK: Locals / Globals

      case .localGet(let idx):
        valueStack.append(frames[fi].locals[Int(idx)])

      case .localSet(let idx):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        frames[fi].locals[Int(idx)] = valueStack.removeLast()

      case .localTee(let idx):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        frames[fi].locals[Int(idx)] = valueStack.last!

      case .globalGet(let idx):
        valueStack.append(globals[Int(idx)])

      case .globalSet(let idx):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        globals[Int(idx)] = valueStack.removeLast()

      // MARK: Constants

      case .i32Const(let value):
        valueStack.append(.i32(value))

      case .i64Const(let value):
        valueStack.append(.i64(value))

      case .f32Const(let value):
        valueStack.append(.f32(value))

      // MARK: Flat Control Flow

      case .block(let bt, let endPc):
        // Push a label. endPc is the continuation PC for br (past the blockEnd).
        let brArity = blockArity(bt, types: module.types)
        let paramCount = loopBrArity(bt, types: module.types)
        frames[fi].labels.append(
          Label(
            kind: .block,
            stackBase: valueStack.count - paramCount,
            brArity: brArity,
            continuationPc: endPc))

      case .loop(let bt, let startPc):
        // Push a label. startPc is where br(0) restarts the loop.
        let brArity = loopBrArity(bt, types: module.types)
        frames[fi].labels.append(
          Label(
            kind: .loop,
            stackBase: valueStack.count - brArity,
            brArity: brArity,
            continuationPc: startPc))

      case .ifElse(let bt, let elsePc, let endPc):
        // Pop condition; jump to elsePc if false. Push a label for both paths.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw .typeMismatch }
        let brArity = blockArity(bt, types: module.types)
        let paramCount = loopBrArity(bt, types: module.types)
        frames[fi].labels.append(
          Label(
            kind: .ifElse,
            stackBase: valueStack.count - paramCount,
            brArity: brArity,
            continuationPc: endPc))
        if cond == 0 { frames[fi].ip = elsePc }

      case .blockEnd:
        // Normal fall-through exit from block/loop/if: just pop the label.
        // The value stack is left as-is; Wasm type discipline ensures correct depth.
        frames[fi].labels.removeLast()

      case .jump(let targetPc):
        // Unconditional jump (used to skip the else body after the then body completes).
        frames[fi].ip = targetPc

      case .br(let depth):
        try handleBranch(depth: depth, fi: fi)

      case .brIf(let depth):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw .typeMismatch }
        if cond != 0 {
          try handleBranch(depth: depth, fi: fi)
        }

      case .brTable(let labels, let default_):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let idx) = valueStack.removeLast() else { throw .typeMismatch }
        let i = Int(idx)
        let depth = (i >= 0 && i < labels.count) ? labels[i] : default_
        try handleBranch(depth: depth, fi: fi)

      case .unreachable:
        throw WasmError.unreachableReached

      case .nop:
        break

      case .return_:
        let resultCount = frames[fi].resultCount
        let frameBase = frames[fi].stackBase
        let src = valueStack.count - resultCount
        for i in 0..<resultCount { valueStack[frameBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((frameBase + resultCount)...)
        frames[fi].labels.removeAll()
        frames[fi].ip = frames[fi].instructions.count  // signal frame done

      case .drop:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        valueStack.removeLast()

      case .select:
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw .typeMismatch }
        let v2 = valueStack.removeLast()
        let v1 = valueStack.removeLast()
        valueStack.append(cond != 0 ? v1 : v2)

      case .call(let funcIdx):
        let funcType = module.functionType(at: Int(funcIdx))
        let argCount = funcType.params.count
        guard valueStack.count >= argCount else { throw .stackUnderflow }
        let callArgs = Array(valueStack.suffix(argCount))
        valueStack.removeLast(argCount)
        try pushFrame(funcIdx: Int(funcIdx), callArgs: callArgs)

      // MARK: i32 Unary

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

      // MARK: i32 Comparisons

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

      // MARK: i32 Arithmetic

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
        valueStack.append(.i32(a == Int32.min && b == -1 ? 0 : a % b))

      case .i32RemU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) % UInt32(bitPattern: b))))

      // MARK: i32 Bitwise

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

      // MARK: f32 Comparisons

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

      // MARK: f32 Unary

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
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.rounded(.toNearestOrEven)))

      case .f32Sqrt:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(a.squareRoot()))

      // MARK: f32 Binary Arithmetic

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

      // MARK: i64 Unary

      case .i64Eqz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(a == 0 ? 1 : 0))

      case .i64Clz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).leadingZeroBitCount)))

      case .i64Ctz:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).trailingZeroBitCount)))

      case .i64Popcnt:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).nonzeroBitCount)))

      case .i64Extend8S:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(Int8(bitPattern: UInt8(a & 0xFF)))))

      case .i64Extend16S:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(Int16(bitPattern: UInt16(a & 0xFFFF)))))

      case .i64Extend32S:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(Int32(bitPattern: UInt32(a & 0xFFFF_FFFF)))))

      // MARK: i64 Comparisons

      case .i64Eq:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))

      case .i64Ne:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))

      case .i64LtS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))

      case .i64LtU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) < UInt64(bitPattern: b) ? 1 : 0))

      case .i64GtS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))

      case .i64GtU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) > UInt64(bitPattern: b) ? 1 : 0))

      case .i64LeS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))

      case .i64LeU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) <= UInt64(bitPattern: b) ? 1 : 0))

      case .i64GeS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))

      case .i64GeU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) >= UInt64(bitPattern: b) ? 1 : 0))

      // MARK: i64 Arithmetic

      case .i64Add:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a &+ b))

      case .i64Sub:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a &- b))

      case .i64Mul:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a &* b))

      case .i64DivS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        guard !(a == Int64.min && b == -1) else { throw .integerOverflow }
        valueStack.append(.i64(a / b))

      case .i64DivU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) / UInt64(bitPattern: b))))

      case .i64RemS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i64(a == Int64.min && b == -1 ? 0 : a % b))

      case .i64RemU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) % UInt64(bitPattern: b))))

      // MARK: i64 Bitwise

      case .i64And:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a & b))

      case .i64Or:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a | b))

      case .i64Xor:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i64(a ^ b))

      case .i64Shl:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt64(bitPattern: b) & 63
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) << shift)))

      case .i64ShrS:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = Int64(UInt64(bitPattern: b) & 63)
        valueStack.append(.i64(a >> shift))

      case .i64ShrU:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt64(bitPattern: b) & 63
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) >> shift)))

      case .i64Rotl:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt64(bitPattern: b) & 63
        let ua = UInt64(bitPattern: a)
        let result = shift == 0 ? ua : (ua << shift | ua >> (64 - shift))
        valueStack.append(.i64(Int64(bitPattern: result)))

      case .i64Rotr:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        let shift = UInt64(bitPattern: b) & 63
        let ua = UInt64(bitPattern: a)
        let result = shift == 0 ? ua : (ua >> shift | ua << (64 - shift))
        valueStack.append(.i64(Int64(bitPattern: result)))

      case .unimplemented(let op):
        throw WasmError.invalidInstruction(op)
      }
    }

    return valueStack
  }
}
