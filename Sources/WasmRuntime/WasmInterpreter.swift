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

// Wasm f64.min: propagates NaN; treats -0 < +0
private func wasmF64Min(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
  return Swift.min(a, b)
}

// Wasm f64.max: propagates NaN; treats +0 > -0
private func wasmF64Max(_ a: Double, _ b: Double) -> Double {
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
  var memory: [UInt8]
  private let hostFunctions: [HostFunction]
  private var globals: [Value]  // mutable global variable slots (global.get/set)
  // Tables store Value (.funcref or .externref) directly to support both funcref and externref tables.
  // The reftype of each slot is determined by the table's declared RefType.
  private var tables: [[Value]]  // reference tables: tables[tableIdx][elemIdx]
  // TODO: Embedded — replace with fixed-size buffer
  private var droppedDataSegments: [Bool]  // true = segment has been dropped via data.drop
  // TODO: Embedded — replace with fixed-size buffer
  private var droppedElementSegments: [Bool]  // true = segment has been dropped via elem.drop

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

    // Build per-table arrays from the Table section; one entry per declared table.
    // Each table slot holds a Value (.funcref or .externref) matching the table's declared refType.
    // Only active segments are applied at instantiation; passive segments are skipped
    // and remain available for use by table.init / elem.drop at runtime.
    var tbls: [[Value]] = module.tables.map { tbl in
      let nullVal: Value = tbl.refType == .externRef ? .externref(nil) : .funcref(nil)
      return [Value](repeating: nullVal, count: Int(tbl.min))
    }
    for seg in module.elements {
      guard !seg.isPassive else { continue }  // passive segments are not applied at instantiation
      let ti = Int(seg.tableIndex)
      guard ti < tbls.count else { throw .memoryAccessOutOfBounds }
      let start = Int(seg.offset)
      // Use the table's declared refType to produce the correct Value variant.
      let refType = module.tables[ti].refType
      for (i, funcIdx) in seg.functionIndices.enumerated() {
        let pos = start + i
        guard pos < tbls[ti].count else { throw .memoryAccessOutOfBounds }
        tbls[ti][pos] = refType == .externRef ? .externref(funcIdx) : .funcref(funcIdx)
      }
    }
    self.tables = tbls

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

    // Allocate memory and initialize it from active data segments only (1 page = 64 KiB).
    // Passive segments (offset == nil) are retained in module.data for use by memory.init
    // at runtime; they are not applied at instantiation.
    var mem = [UInt8](repeating: 0, count: Int(memPageCount) * 65536)
    for seg in module.data {
      guard let offset = seg.offset else { continue }  // skip passive segments
      let start = Int(offset)
      let end = start + seg.bytes.count
      guard start >= 0 && end <= mem.count else { throw .memoryAccessOutOfBounds }
      mem.replaceSubrange(start..<end, with: seg.bytes)
    }
    self.memory = mem
    // TODO: Embedded — replace with fixed-size buffer
    self.droppedDataSegments = [Bool](repeating: false, count: module.data.count)
    // TODO: Embedded — replace with fixed-size buffer
    // Active element segments are treated as dropped after instantiation per Wasm spec §4.5.4.
    // Declarative segments (flags=3, 5, 7) are also pre-dropped — they exist only to make
    // ref.func instructions valid, and must never be accessible via table.init.
    // Only true passive segments (isPassive==true, isDeclarative==false) remain available
    // for table.init at runtime.
    var droppedElems = [Bool](repeating: false, count: module.elements.count)
    for (i, seg) in module.elements.enumerated() {
      if !seg.isPassive || seg.isDeclarative { droppedElems[i] = true }
    }
    self.droppedElementSegments = droppedElems

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
        case .f64: locals.append(.f64(0.0))
        case .funcref: locals.append(.funcref(nil))  // nil = null reference per Wasm spec default
        case .externref: locals.append(.externref(nil))  // nil = null reference per Wasm spec default
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

      case .f64Const(let value):
        valueStack.append(.f64(value))

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

      // MARK: f64 Comparisons

      case .f64Eq:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))

      case .f64Ne:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))

      case .f64Lt:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))

      case .f64Gt:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))

      case .f64Le:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))

      case .f64Ge:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))

      // MARK: f64 Unary

      case .f64Abs:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.magnitude))

      case .f64Neg:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(-a))

      case .f64Ceil:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.rounded(.up)))

      case .f64Floor:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.rounded(.down)))

      case .f64Trunc:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.rounded(.towardZero)))

      case .f64Nearest:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.rounded(.toNearestOrEven)))

      case .f64Sqrt:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(a.squareRoot()))

      // MARK: f64 Binary Arithmetic

      case .f64Add:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(a + b))

      case .f64Sub:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(a - b))

      case .f64Mul:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(a * b))

      case .f64Div:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        // f64.div follows IEEE 754: division by zero yields ±infinity, not a trap.
        valueStack.append(.f64(a / b))

      case .f64Min:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(wasmF64Min(a, b)))

      case .f64Max:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(wasmF64Max(a, b)))

      case .f64Copysign:
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw .typeMismatch }
        valueStack.append(.f64(Double(signOf: b, magnitudeOf: a)))

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

      // MARK: Conversions

      // --- wrap / extend ---

      case .i32WrapI64:
        // i32.wrap_i64: keep the lower 32 bits of an i64 value.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(truncatingIfNeeded: a)))

      case .i64ExtendI32S:
        // i64.extend_i32_s: sign-extend a 32-bit integer to 64 bits.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(a)))

      case .i64ExtendI32U:
        // i64.extend_i32_u: zero-extend a 32-bit integer to 64 bits (treat i32 as UInt32).
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(UInt32(bitPattern: a))))

      // --- trunc (trapping) ---

      case .i32TruncF32S:
        // i32.trunc_f32_s: convert f32 to signed i32; traps on NaN, Inf, or out-of-range.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a >= -2147483648.0 && a < 2147483648.0 else { throw .invalidConversionToInteger }
        valueStack.append(.i32(Int32(a)))

      case .i32TruncF32U:
        // i32.trunc_f32_u: convert f32 to unsigned i32 stored as i32 bit-pattern.
        // Traps on NaN, Inf, values <= -1.0, or values >= 2^32.
        // Values in (-1, 0) truncate toward zero to 0 — valid, not a trap.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a > -1.0 && a < 4294967296.0 else { throw .invalidConversionToInteger }
        // For a in (-1, 0), UInt32(a) would trap in Swift; truncation toward zero gives 0.
        let u32: UInt32 = a < 0.0 ? 0 : UInt32(a)
        valueStack.append(.i32(Int32(bitPattern: u32)))

      case .i32TruncF64S:
        // i32.trunc_f64_s: convert f64 to signed i32; traps on NaN, Inf, or out-of-range.
        // Lower bound: a > -2147483649.0 because f64 values in (-2147483649, -2147483648]
        // truncate toward zero to values >= INT32_MIN and are thus valid.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a > -2147483649.0 && a < 2147483648.0 else { throw .invalidConversionToInteger }
        valueStack.append(.i32(Int32(a)))

      case .i32TruncF64U:
        // i32.trunc_f64_u: convert f64 to unsigned i32 stored as i32 bit-pattern.
        // Values in (-1, 0) truncate toward zero to 0 — valid, not a trap.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a > -1.0 && a < 4294967296.0 else { throw .invalidConversionToInteger }
        // For a in (-1, 0), UInt32(a) would trap in Swift; truncation toward zero gives 0.
        let u32: UInt32 = a < 0.0 ? 0 : UInt32(a)
        valueStack.append(.i32(Int32(bitPattern: u32)))

      case .i64TruncF32S:
        // i64.trunc_f32_s: convert f32 to signed i64; traps on NaN, Inf, or out-of-range.
        // -2^63 is exactly representable in f32 and valid; -2^63 as f32 is -9223372036854775808.0.
        // The next smaller representable f32 is -9223372036854775808.0 * 2 (out of range).
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a >= -9223372036854775808.0 && a < 9223372036854775808.0
        else { throw .invalidConversionToInteger }
        valueStack.append(.i64(Int64(a)))

      case .i64TruncF32U:
        // i64.trunc_f32_u: convert f32 to unsigned i64 stored as i64 bit-pattern.
        // Values in (-1, 0) truncate toward zero to 0 — valid, not a trap.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a > -1.0 && a < 18446744073709551616.0 else { throw .invalidConversionToInteger }
        // For a in (-1, 0), UInt64(a) would trap in Swift; truncation toward zero gives 0.
        let u64f32: UInt64 = a < 0.0 ? 0 : UInt64(a)
        valueStack.append(.i64(Int64(bitPattern: u64f32)))

      case .i64TruncF64S:
        // i64.trunc_f64_s: convert f64 to signed i64; traps on NaN, Inf, or out-of-range.
        // The lower bound is exactly -2^63 = INT64_MIN, which f64 can represent exactly
        // and converts to Int64.min. The next more-negative f64 (-9223372036854777856.0)
        // would truncate below INT64_MIN and must trap.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a >= -9223372036854775808.0 && a < 9223372036854775808.0
        else { throw .invalidConversionToInteger }
        valueStack.append(.i64(Int64(a)))

      case .i64TruncF64U:
        // i64.trunc_f64_u: convert f64 to unsigned i64 stored as i64 bit-pattern.
        // Values in (-1, 0) truncate toward zero to 0 — valid, not a trap.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw .invalidConversionToInteger }
        guard a > -1.0 && a < 18446744073709551616.0 else { throw .invalidConversionToInteger }
        // For a in (-1, 0), UInt64(a) would trap in Swift; truncation toward zero gives 0.
        let u64f64: UInt64 = a < 0.0 ? 0 : UInt64(a)
        valueStack.append(.i64(Int64(bitPattern: u64f64)))

      // --- convert (integer → float) ---

      case .f32ConvertI32S:
        // f32.convert_i32_s: signed i32 to f32.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(a)))

      case .f32ConvertI32U:
        // f32.convert_i32_u: unsigned i32 (stored as signed i32) to f32.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(UInt32(bitPattern: a))))

      case .f32ConvertI64S:
        // f32.convert_i64_s: signed i64 to f32.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(a)))

      case .f32ConvertI64U:
        // f32.convert_i64_u: unsigned i64 (stored as signed i64) to f32.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(UInt64(bitPattern: a))))

      case .f64ConvertI32S:
        // f64.convert_i32_s: signed i32 to f64.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(a)))

      case .f64ConvertI32U:
        // f64.convert_i32_u: unsigned i32 (stored as signed i32) to f64.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(UInt32(bitPattern: a))))

      case .f64ConvertI64S:
        // f64.convert_i64_s: signed i64 to f64.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(a)))

      case .f64ConvertI64U:
        // f64.convert_i64_u: unsigned i64 (stored as signed i64) to f64.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(UInt64(bitPattern: a))))

      // --- demote / promote ---

      case .f32DemoteF64:
        // f32.demote_f64: reduce f64 to f32 (may lose precision; NaN/Inf preserved).
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(a)))

      case .f64PromoteF32:
        // f64.promote_f32: extend f32 to f64 (exact; NaN/Inf preserved).
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(a)))

      // --- reinterpret ---

      case .i32ReinterpretF32:
        // i32.reinterpret_f32: reinterpret the IEEE 754 bit pattern of f32 as i32.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i32(Int32(bitPattern: a.bitPattern)))

      case .i64ReinterpretF64:
        // i64.reinterpret_f64: reinterpret the IEEE 754 bit pattern of f64 as i64.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.i64(Int64(bitPattern: a.bitPattern)))

      case .f32ReinterpretI32:
        // f32.reinterpret_i32: reinterpret i32 bits as a f32 IEEE 754 value.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f32(Float(bitPattern: UInt32(bitPattern: a))))

      case .f64ReinterpretI64:
        // f64.reinterpret_i64: reinterpret i64 bits as a f64 IEEE 754 value.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        valueStack.append(.f64(Double(bitPattern: UInt64(bitPattern: a))))

      // --- saturating trunc (0xFC prefix): clamp instead of trap ---

      case .i32TruncSatF32S:
        // i32.trunc_sat_f32_s: f32 → signed i32, NaN→0, Inf→INT32_MAX, -Inf→INT32_MIN.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: Int32
        if a.isNaN {
          result = 0
        } else if a < -2147483648.0 {
          result = Int32.min
        } else if a >= 2147483648.0 {
          result = Int32.max
        } else {
          result = Int32(a)
        }
        valueStack.append(.i32(result))

      case .i32TruncSatF32U:
        // i32.trunc_sat_f32_u: f32 → unsigned i32 (as i32 bits), NaN→0, clamp to [0, UINT32_MAX].
        // Any negative value (including (-1,0)) clamps to 0; UInt32(a) is unsafe for negatives.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: UInt32
        if a.isNaN || a < 0.0 {
          result = 0
        } else if a >= 4294967296.0 {
          result = UInt32.max
        } else {
          result = UInt32(a)
        }
        valueStack.append(.i32(Int32(bitPattern: result)))

      case .i32TruncSatF64S:
        // i32.trunc_sat_f64_s: f64 → signed i32, NaN→0, Inf→INT32_MAX, -Inf→INT32_MIN.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: Int32
        if a.isNaN {
          result = 0
        } else if a < -2147483648.0 {
          result = Int32.min
        } else if a >= 2147483648.0 {
          result = Int32.max
        } else {
          result = Int32(a)
        }
        valueStack.append(.i32(result))

      case .i32TruncSatF64U:
        // i32.trunc_sat_f64_u: f64 → unsigned i32 (as i32 bits), NaN→0, clamp to [0, UINT32_MAX].
        // Any negative value (including (-1,0)) clamps to 0; UInt32(a) is unsafe for negatives.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: UInt32
        if a.isNaN || a < 0.0 {
          result = 0
        } else if a >= 4294967296.0 {
          result = UInt32.max
        } else {
          result = UInt32(a)
        }
        valueStack.append(.i32(Int32(bitPattern: result)))

      case .i64TruncSatF32S:
        // i64.trunc_sat_f32_s: f32 → signed i64, NaN→0, Inf→INT64_MAX, -Inf→INT64_MIN.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: Int64
        if a.isNaN {
          result = 0
        } else if a < -9223372036854775808.0 {
          result = Int64.min
        } else if a >= 9223372036854775808.0 {
          result = Int64.max
        } else {
          result = Int64(a)
        }
        valueStack.append(.i64(result))

      case .i64TruncSatF32U:
        // i64.trunc_sat_f32_u: f32 → unsigned i64 (as i64 bits), NaN→0, clamp to [0, UINT64_MAX].
        // Any negative value (including (-1,0)) clamps to 0; UInt64(a) is unsafe for negatives.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: UInt64
        if a.isNaN || a < 0.0 {
          result = 0
        } else if a >= 18446744073709551616.0 {
          result = UInt64.max
        } else {
          result = UInt64(a)
        }
        valueStack.append(.i64(Int64(bitPattern: result)))

      case .i64TruncSatF64S:
        // i64.trunc_sat_f64_s: f64 → signed i64, NaN→0, Inf→INT64_MAX, -Inf→INT64_MIN.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: Int64
        if a.isNaN {
          result = 0
        } else if a < -9223372036854775808.0 {
          result = Int64.min
        } else if a >= 9223372036854775808.0 {
          result = Int64.max
        } else {
          result = Int64(a)
        }
        valueStack.append(.i64(result))

      case .i64TruncSatF64U:
        // i64.trunc_sat_f64_u: f64 → unsigned i64 (as i64 bits), NaN→0, clamp to [0, UINT64_MAX].
        // Any negative value (including (-1,0)) clamps to 0; UInt64(a) is unsafe for negatives.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw .typeMismatch }
        let result: UInt64
        if a.isNaN || a < 0.0 {
          result = 0
        } else if a >= 18446744073709551616.0 {
          result = UInt64.max
        } else {
          result = UInt64(a)
        }
        valueStack.append(.i64(Int64(bitPattern: result)))

      // MARK: Memory

      case .i32Load(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let value =
          UInt32(memory[ea]) | (UInt32(memory[ea + 1]) << 8) | (UInt32(memory[ea + 2]) << 16)
          | (UInt32(memory[ea + 3]) << 24)
        valueStack.append(.i32(Int32(bitPattern: value)))

      case .i64Load(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 8 <= memory.count else { throw .memoryAccessOutOfBounds }
        let value =
          UInt64(memory[ea]) | (UInt64(memory[ea + 1]) << 8) | (UInt64(memory[ea + 2]) << 16)
          | (UInt64(memory[ea + 3]) << 24) | (UInt64(memory[ea + 4]) << 32)
          | (UInt64(memory[ea + 5]) << 40) | (UInt64(memory[ea + 6]) << 48)
          | (UInt64(memory[ea + 7]) << 56)
        valueStack.append(.i64(Int64(bitPattern: value)))

      case .f32Load(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let bits =
          UInt32(memory[ea]) | (UInt32(memory[ea + 1]) << 8) | (UInt32(memory[ea + 2]) << 16)
          | (UInt32(memory[ea + 3]) << 24)
        // Float(bitPattern:) reinterprets the raw IEEE 754 bit pattern, preserving NaN payloads.
        valueStack.append(.f32(Float(bitPattern: bits)))

      case .f64Load(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 8 <= memory.count else { throw .memoryAccessOutOfBounds }
        let bits =
          UInt64(memory[ea]) | (UInt64(memory[ea + 1]) << 8) | (UInt64(memory[ea + 2]) << 16)
          | (UInt64(memory[ea + 3]) << 24) | (UInt64(memory[ea + 4]) << 32)
          | (UInt64(memory[ea + 5]) << 40) | (UInt64(memory[ea + 6]) << 48)
          | (UInt64(memory[ea + 7]) << 56)
        // Double(bitPattern:) reinterprets the raw IEEE 754 bit pattern, preserving NaN payloads.
        valueStack.append(.f64(Double(bitPattern: bits)))

      case .i32Load8S(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        // Sign-extend 8-bit to 32-bit via Int8 reinterpretation then widen.
        valueStack.append(.i32(Int32(Int8(bitPattern: memory[ea]))))

      case .i32Load8U(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        // Zero-extend: UInt8 → Int32 always produces a non-negative value.
        valueStack.append(.i32(Int32(memory[ea])))

      case .i32Load16S(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw = UInt16(memory[ea]) | (UInt16(memory[ea + 1]) << 8)
        // Sign-extend 16-bit to 32-bit via Int16 reinterpretation then widen.
        valueStack.append(.i32(Int32(Int16(bitPattern: raw))))

      case .i32Load16U(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw = UInt16(memory[ea]) | (UInt16(memory[ea + 1]) << 8)
        // Zero-extend: UInt16 → Int32 always produces a non-negative value.
        valueStack.append(.i32(Int32(raw)))

      case .i64Load8S(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        valueStack.append(.i64(Int64(Int8(bitPattern: memory[ea]))))

      case .i64Load8U(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        valueStack.append(.i64(Int64(memory[ea])))

      case .i64Load16S(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw = UInt16(memory[ea]) | (UInt16(memory[ea + 1]) << 8)
        valueStack.append(.i64(Int64(Int16(bitPattern: raw))))

      case .i64Load16U(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw = UInt16(memory[ea]) | (UInt16(memory[ea + 1]) << 8)
        valueStack.append(.i64(Int64(raw)))

      case .i64Load32S(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw =
          UInt32(memory[ea]) | (UInt32(memory[ea + 1]) << 8) | (UInt32(memory[ea + 2]) << 16)
          | (UInt32(memory[ea + 3]) << 24)
        valueStack.append(.i64(Int64(Int32(bitPattern: raw))))

      case .i64Load32U(_, let offset):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let raw =
          UInt32(memory[ea]) | (UInt32(memory[ea + 1]) << 8) | (UInt32(memory[ea + 2]) << 16)
          | (UInt32(memory[ea + 3]) << 24)
        valueStack.append(.i64(Int64(raw)))

      case .i32Store(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let u = UInt32(bitPattern: value)
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)
        memory[ea + 2] = UInt8((u >> 16) & 0xFF)
        memory[ea + 3] = UInt8((u >> 24) & 0xFF)

      case .i64Store(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 8 <= memory.count else { throw .memoryAccessOutOfBounds }
        let u = UInt64(bitPattern: value)
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)
        memory[ea + 2] = UInt8((u >> 16) & 0xFF)
        memory[ea + 3] = UInt8((u >> 24) & 0xFF)
        memory[ea + 4] = UInt8((u >> 32) & 0xFF)
        memory[ea + 5] = UInt8((u >> 40) & 0xFF)
        memory[ea + 6] = UInt8((u >> 48) & 0xFF)
        memory[ea + 7] = UInt8((u >> 56) & 0xFF)

      case .f32Store(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f32(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        // bitPattern reinterprets the IEEE 754 representation without any conversion.
        let u = value.bitPattern
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)
        memory[ea + 2] = UInt8((u >> 16) & 0xFF)
        memory[ea + 3] = UInt8((u >> 24) & 0xFF)

      case .f64Store(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .f64(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 8 <= memory.count else { throw .memoryAccessOutOfBounds }
        // bitPattern reinterprets the IEEE 754 representation without any conversion.
        let u = value.bitPattern
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)
        memory[ea + 2] = UInt8((u >> 16) & 0xFF)
        memory[ea + 3] = UInt8((u >> 24) & 0xFF)
        memory[ea + 4] = UInt8((u >> 32) & 0xFF)
        memory[ea + 5] = UInt8((u >> 40) & 0xFF)
        memory[ea + 6] = UInt8((u >> 48) & 0xFF)
        memory[ea + 7] = UInt8((u >> 56) & 0xFF)

      case .i32Store8(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        // Store only the low 8 bits; upper bits are silently discarded per the Wasm spec.
        memory[ea] = UInt8(UInt32(bitPattern: value) & 0xFF)

      case .i32Store16(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        // Store only the low 16 bits; upper bits are silently discarded per the Wasm spec.
        let u = UInt32(bitPattern: value)
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)

      case .i64Store8(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 1 <= memory.count else { throw .memoryAccessOutOfBounds }
        memory[ea] = UInt8(UInt64(bitPattern: value) & 0xFF)

      case .i64Store16(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 2 <= memory.count else { throw .memoryAccessOutOfBounds }
        let u = UInt64(bitPattern: value)
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)

      case .i64Store32(_, let offset):
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw .typeMismatch }
        let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
        guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
        let u = UInt64(bitPattern: value)
        memory[ea] = UInt8(u & 0xFF)
        memory[ea + 1] = UInt8((u >> 8) & 0xFF)
        memory[ea + 2] = UInt8((u >> 16) & 0xFF)
        memory[ea + 3] = UInt8((u >> 24) & 0xFF)

      case .memorySize:
        // memory.size: [] → [i32]
        // Pushes the current number of pages in linear memory.
        // 1 page = 65536 bytes; result is always a non-negative i32.
        let pageCount = Int32(memory.count / 65536)
        valueStack.append(.i32(pageCount))

      case .memoryGrow:
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let delta) = valueStack.removeLast() else { throw .typeMismatch }
        let pageSize = 65536
        let oldPages = memory.count / pageSize
        let oldPagesI32 = Int32(oldPages)
        // delta is a u32 argument packed into i32; treat as unsigned.
        // A negative i32 bit pattern becomes a huge u32, which will exceed any max — safe.
        let n = Int(UInt32(bitPattern: delta))
        let newPages = oldPages + n
        // Guard against Int overflow before multiplying (important on 32-bit targets).
        let overflows = n > Int.max / pageSize
        // Check the memory's declared maximum limit (from MemoryType.max, in pages).
        let memMax: UInt32? = module.memories.first?.max
        let exceedsMax: Bool
        if let maxPages = memMax {
          exceedsMax = newPages > Int(maxPages)
        } else {
          // No declared max: Wasm spec hard-limits to 65536 pages (4 GiB).
          exceedsMax = newPages > 65536
        }
        if overflows || exceedsMax {
          valueStack.append(.i32(-1))
        } else {
          memory.append(contentsOf: [UInt8](repeating: 0, count: n * pageSize))
          valueStack.append(.i32(oldPagesI32))
        }

      // MARK: Table

      case .tableGet(let tableIdx):
        // table.get: [i32] → [funcref | externref]
        // Pops an i32 element index, pushes the reference stored at that table slot.
        // The returned Value type (.funcref or .externref) matches the table's declared refType.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let idx) = valueStack.removeLast() else { throw .typeMismatch }
        let ti = Int(tableIdx)
        guard ti < tables.count else { throw .undefinedElement }
        // Convert the signed i32 stack value to an unsigned element index.
        // Negative values become large UInt32 values and will fail the bounds check.
        let i = Int(UInt32(bitPattern: idx))
        guard i < tables[ti].count else { throw .undefinedElement }
        // Tables now store Value directly — push the stored value as-is.
        valueStack.append(tables[ti][i])

      case .tableSet(let tableIdx):
        // table.set: [i32, funcref | externref] → []
        // Pops a reference value then an i32 element index; stores the ref into the table.
        // Stack order: [..., i32_idx, ref_val] — ref is on top.
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        let refVal = valueStack.removeLast()
        guard case .i32(let idx) = valueStack.removeLast() else { throw .typeMismatch }
        let ti = Int(tableIdx)
        guard ti < tables.count else { throw .undefinedElement }
        // Verify the value type matches the table's declared refType (Wasm spec §3.4.9).
        // funcRef tables accept only .funcref values; externRef tables accept only .externref.
        let tableRefType = ti < module.tables.count ? module.tables[ti].refType : .funcRef
        switch (tableRefType, refVal) {
        case (.funcRef, .funcref), (.externRef, .externref): break
        default: throw WasmError.typeMismatch
        }
        let i = Int(UInt32(bitPattern: idx))
        guard i < tables[ti].count else { throw .undefinedElement }
        tables[ti][i] = refVal

      // MARK: Reference instructions

      case .refNull(let refType):
        // ref.null reftype: [] → [funcref | externref]
        // Pushes a null reference of the appropriate type.
        switch refType {
        case .funcRef: valueStack.append(.funcref(nil))
        case .externRef: valueStack.append(.externref(nil))
        }

      case .refIsNull:
        // ref.is_null: [funcref | externref] → [i32]
        // Pops any reference type; pushes 1 if null, 0 if non-null.
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        switch valueStack.removeLast() {
        case .funcref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
        case .externref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
        default: throw WasmError.typeMismatch
        }

      case .refFunc(let funcIdx):
        // ref.func x: [] → [funcref]
        // Pushes a non-null funcref for function index x.
        // The function index must be within the valid range (imports + local functions).
        let totalFunctions = module.importedFunctionCount + module.functions.count
        guard Int(funcIdx) < totalFunctions else { throw .functionNotFound }
        valueStack.append(.funcref(funcIdx))

      // MARK: call_indirect

      case .callIndirect(let typeIdx, let tableIdxOp):
        guard !valueStack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let elemIdx) = valueStack.removeLast() else { throw .typeMismatch }
        let eIdx = Int(elemIdx)
        let ti = Int(tableIdxOp)
        guard ti < tables.count else { throw .undefinedElement }
        let tbl = tables[ti]
        // Tables now store Value; extract the funcref index from the slot.
        // Null funcref (.funcref(nil)) or an externref in a funcref table both trap.
        guard eIdx >= 0 && eIdx < tbl.count else { throw .undefinedElement }
        guard case .funcref(let optFuncIdx) = tbl[eIdx], let funcIdx = optFuncIdx else {
          throw .undefinedElement
        }
        let expectedType = module.types[Int(typeIdx)]
        let actualType = module.functionType(at: Int(funcIdx))
        guard
          expectedType.params.count == actualType.params.count
            && expectedType.results.count == actualType.results.count
        else { throw .indirectCallTypeMismatch }
        for (e, a) in zip(expectedType.params, actualType.params) {
          guard e == a else { throw .indirectCallTypeMismatch }
        }
        for (e, a) in zip(expectedType.results, actualType.results) {
          guard e == a else { throw .indirectCallTypeMismatch }
        }
        let argCount = expectedType.params.count
        guard valueStack.count >= argCount else { throw .stackUnderflow }
        let callArgs = Array(valueStack.suffix(argCount))
        valueStack.removeLast(argCount)
        try pushFrame(funcIdx: Int(funcIdx), callArgs: callArgs)

      // MARK: Bulk Memory

      case .memoryInit(let segIdx):
        // memory.init x: [dst: i32, src: i32, n: i32] → []
        //
        // Copies n bytes from data segment x (starting at src offset within the segment)
        // into linear memory (starting at dst address).
        //
        // Trap conditions (per Wasm spec, checked unconditionally regardless of n):
        //   - segment index out of bounds
        //   - src + n > |seg|  (including n=0 cases where src > segLen)
        //   - dst + n > |mem|  (including n=0 cases where dst > memLen)
        //   - dropped segment: treated as having length 0, so any non-zero (src+n) traps
        //
        // Wasm spec §3.4.10: the bounds check is s+n > |data| OR d+n > |mem|,
        // not guarded by n > 0. A zero-length copy with out-of-range src or dst still traps.
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let src) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let si = Int(segIdx)
        guard si < module.data.count else { throw .memoryAccessOutOfBounds }
        let copyCount = Int(UInt32(bitPattern: n))
        let srcOff = Int(UInt32(bitPattern: src))
        let dstOff = Int(UInt32(bitPattern: dst))
        // A dropped segment has effective length 0; avoid allocating an empty array.
        let segLen = droppedDataSegments[si] ? 0 : module.data[si].bytes.count
        // Bounds check: applies unconditionally (n=0 with out-of-range src/dst still traps).
        guard srcOff + copyCount <= segLen else { throw .memoryAccessOutOfBounds }
        guard dstOff + copyCount <= memory.count else { throw .memoryAccessOutOfBounds }
        if copyCount > 0 {
          // Only reached when !droppedDataSegments[si] (segLen > 0 implied by bounds check above).
          let segBytes = module.data[si].bytes
          for i in 0..<copyCount {
            memory[dstOff + i] = segBytes[srcOff + i]
          }
        }

      case .dataDrop(let segIdx):
        // data.drop x: [] → []
        //
        // Marks data segment x as dropped. Subsequent memory.init from this segment
        // will trap (even for n == 0, per spec errata: a dropped segment has length 0,
        // so any access including zero-length is valid only if src == 0 && n == 0).
        // Dropping an already-dropped segment is a no-op (idempotent).
        let si = Int(segIdx)
        guard si < droppedDataSegments.count else { throw .memoryAccessOutOfBounds }
        droppedDataSegments[si] = true

      case .memoryCopy:
        // memory.copy: [dst: i32, src: i32, n: i32] → []
        //
        // Copies n bytes from memory[src..src+n) into memory[dst..dst+n).
        // Overlapping regions are handled correctly (memmove semantics):
        //   - If dst <= src or regions do not overlap: copy forward.
        //   - If dst > src and regions overlap: copy backward to avoid clobbering src bytes.
        //
        // Bounds check is applied unconditionally (even when n == 0):
        //   - src + n > memory.count → trap
        //   - dst + n > memory.count → trap
        // This mirrors the Wasm spec §3.4.10 semantics for memory.copy.
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let src) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let copyCount = Int(UInt32(bitPattern: n))
        let srcOff = Int(UInt32(bitPattern: src))
        let dstOff = Int(UInt32(bitPattern: dst))
        // Bounds check: applies unconditionally (n=0 with out-of-range dst/src still traps).
        guard srcOff + copyCount <= memory.count else { throw .memoryAccessOutOfBounds }
        guard dstOff + copyCount <= memory.count else { throw .memoryAccessOutOfBounds }
        if copyCount > 0 {
          // Overlap-safe copy: copy forward when dst <= src or regions do not overlap,
          // backward when dst > src and the regions overlap (avoids overwriting src bytes).
          if dstOff <= srcOff || dstOff >= srcOff + copyCount {
            for i in 0..<copyCount { memory[dstOff + i] = memory[srcOff + i] }
          } else {
            for i in stride(from: copyCount - 1, through: 0, by: -1) {
              memory[dstOff + i] = memory[srcOff + i]
            }
          }
        }

      case .memoryFill:
        // memory.fill: [dst: i32, val: i32, n: i32] → []
        //
        // Fills n bytes of linear memory starting at dst with the low 8 bits of val.
        //
        // Bounds check is applied unconditionally (even when n == 0):
        //   - dst + n > memory.count → trap
        // This mirrors the Wasm spec §3.4.10 semantics.
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let val) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let fillCount = Int(UInt32(bitPattern: n))
        let dstOff = Int(UInt32(bitPattern: dst))
        // Bounds check: applies unconditionally (n=0 with out-of-range dst still traps).
        guard dstOff + fillCount <= memory.count else { throw .memoryAccessOutOfBounds }
        if fillCount > 0 {
          let byte = UInt8(UInt32(bitPattern: val) & 0xFF)
          for i in 0..<fillCount { memory[dstOff + i] = byte }
        }

      case .tableInit(let elemIdx, let tableIdx):
        // table.init e t: [dst: i32, src: i32, n: i32] → []
        //
        // Copies n funcref entries from element segment e (starting at src within the segment)
        // into table t (starting at dst). Passive segments must not have been dropped.
        //
        // Trap conditions (checked unconditionally regardless of n):
        //   - element segment index out of bounds
        //   - table index out of bounds
        //   - dropped segment: effective length is 0
        //   - src + n > |segment|
        //   - dst + n > |table|
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let src) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let ei = Int(elemIdx)
        let ti = Int(tableIdx)
        guard ei < module.elements.count else { throw .undefinedElement }
        guard ti < tables.count else { throw .undefinedElement }
        let copyCount = Int(UInt32(bitPattern: n))
        // A dropped element segment has effective length 0.
        let elemLen = droppedElementSegments[ei] ? 0 : module.elements[ei].functionIndices.count
        let srcOff = Int(UInt32(bitPattern: src))
        let dstOff = Int(UInt32(bitPattern: dst))
        // Bounds check: applies unconditionally (n=0 with out-of-range src/dst still traps).
        guard srcOff + copyCount <= elemLen else { throw .undefinedElement }
        guard dstOff + copyCount <= tables[ti].count else { throw .undefinedElement }
        if copyCount > 0 {
          let elems = module.elements[ei].functionIndices
          // element segment stores UInt32? indices; convert to the appropriate Value for the table.
          // Use the table's declared refType to produce the correct .funcref or .externref variant.
          let tableRefType = ti < module.tables.count ? module.tables[ti].refType : .funcRef
          for i in 0..<copyCount {
            tables[ti][dstOff + i] =
              tableRefType == .externRef
              ? .externref(elems[srcOff + i]) : .funcref(elems[srcOff + i])
          }
        }

      case .elemDrop(let elemIdx):
        // elem.drop x: [] → []
        //
        // Marks element segment x as dropped. Subsequent table.init from this segment
        // treats it as having length 0. Dropping an already-dropped segment is idempotent.
        let ei = Int(elemIdx)
        guard ei < droppedElementSegments.count else { throw .undefinedElement }
        droppedElementSegments[ei] = true

      case .tableCopy(let dstTableIdx, let srcTableIdx):
        // table.copy d s: [dst: i32, src: i32, n: i32] → []
        //
        // Copies n entries from table s (starting at src) into table d (starting at dst).
        // Overlapping regions within the same table are handled safely (memmove semantics).
        //
        // Bounds check is applied unconditionally (even when n == 0):
        //   - src + n > |table_s| → trap
        //   - dst + n > |table_d| → trap
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let src) = valueStack.removeLast() else { throw .typeMismatch }
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let di = Int(dstTableIdx)
        let si = Int(srcTableIdx)
        guard di < tables.count && si < tables.count else { throw .undefinedElement }
        let copyCount = Int(UInt32(bitPattern: n))
        let srcOff = Int(UInt32(bitPattern: src))
        let dstOff = Int(UInt32(bitPattern: dst))
        // Bounds check: applies unconditionally.
        guard srcOff + copyCount <= tables[si].count else { throw .undefinedElement }
        guard dstOff + copyCount <= tables[di].count else { throw .undefinedElement }
        if copyCount > 0 {
          if di == si {
            // Same table: overlap-safe copy (memmove semantics).
            // Copy forward when dst <= src or regions do not overlap;
            // backward when dst > src and regions overlap.
            if dstOff <= srcOff || dstOff >= srcOff + copyCount {
              for i in 0..<copyCount { tables[di][dstOff + i] = tables[si][srcOff + i] }
            } else {
              for i in stride(from: copyCount - 1, through: 0, by: -1) {
                tables[di][dstOff + i] = tables[si][srcOff + i]
              }
            }
          } else {
            // Different tables: no aliasing possible; always copy forward.
            for i in 0..<copyCount { tables[di][dstOff + i] = tables[si][srcOff + i] }
          }
        }

      case .tableGrow(let tableIdx):
        // table.grow t: [funcref | externref, i32] → [i32]
        // Stack (top first): n (i32 delta), ref (initial reference value).
        // Extends the table by n entries initialised to ref.
        // Returns the old table size on success, or -1 on failure.
        // Fails when the result would exceed the table's declared maximum.
        guard valueStack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let delta) = valueStack.removeLast() else { throw .typeMismatch }
        // Accept any reference type (funcref or externref) as the fill value.
        let refVal = valueStack.removeLast()
        // Validate that the value is a reference type (funcref or externref); i32/i64/f32/f64 are invalid.
        switch refVal {
        case .funcref, .externref: break
        default: throw WasmError.typeMismatch
        }
        let ti = Int(tableIdx)
        guard ti < tables.count else { throw .undefinedElement }
        // delta is encoded as u32 packed into i32; treat as unsigned.
        let n = Int(UInt32(bitPattern: delta))
        let oldSize = Int32(tables[ti].count)
        // Overflow guard: if n alone overflows Int, growth is impossible.
        guard n <= Int.max - tables[ti].count else {
          valueStack.append(.i32(-1))
          break
        }
        let newSize = tables[ti].count + n
        // Check the table's declared maximum limit if present.
        let tableMax = ti < module.tables.count ? module.tables[ti].max : nil
        if let maxPages = tableMax, newSize > Int(maxPages) {
          // Growth would exceed the declared maximum: return -1 (failure sentinel).
          valueStack.append(.i32(-1))
        } else {
          tables[ti].append(contentsOf: [Value](repeating: refVal, count: n))
          valueStack.append(.i32(oldSize))
        }

      case .tableSize(let tableIdx):
        // table.size t: [] → [i32]
        // Pushes the current number of elements in the specified table.
        let ti = Int(tableIdx)
        guard ti < tables.count else { throw .undefinedElement }
        valueStack.append(.i32(Int32(tables[ti].count)))

      case .tableFill(let tableIdx):
        // table.fill t: [i32, funcref | externref, i32] → []
        // Stack (top first): n (i32 fill count), ref (reference value), dst (i32 start index).
        guard valueStack.count >= 3 else { throw .stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else { throw .typeMismatch }
        let fillRef = valueStack.removeLast()
        guard case .i32(let dst) = valueStack.removeLast() else { throw .typeMismatch }
        let ti = Int(tableIdx)
        guard ti < tables.count else { throw .undefinedElement }
        // Verify the fill value type matches the table's declared refType (Wasm spec §3.4.9).
        // funcRef tables accept only .funcref values; externRef tables accept only .externref.
        let tableFillRefType = ti < module.tables.count ? module.tables[ti].refType : .funcRef
        switch (tableFillRefType, fillRef) {
        case (.funcRef, .funcref), (.externRef, .externref): break
        default: throw WasmError.typeMismatch
        }
        // Treat dst and n as unsigned (packed into i32).
        let dstOff = Int(UInt32(bitPattern: dst))
        let fillCount = Int(UInt32(bitPattern: n))
        // Bounds check: dst + n must not exceed table size; checked unconditionally.
        // Zero-length fill is valid only when dst <= table size.
        guard dstOff + fillCount <= tables[ti].count else {
          throw .undefinedElement
        }
        for i in 0..<fillCount {
          tables[ti][dstOff + i] = fillRef
        }

      case .unimplemented(let op):
        throw WasmError.invalidInstruction(op)
      }
    }

    return valueStack
  }
}
