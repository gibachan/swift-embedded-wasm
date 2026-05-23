// Wasm stack machine interpreter
//
// Wasm is a stack machine: instructions pop operands from the stack and push results.
// Function arguments and declared local variables are stored in a "locals" array
// accessible by index.
//
// Structured control flow (block / loop / br):
//   br propagates as a ControlFlow.br(n) signal up through callers.
//   block/if: br(0) exits the block (forward jump)
//   loop:     br(0) jumps back to the loop head (backward jump)
//   br(n>0) targeting an outer label is forwarded as br(n-1).

// MARK: - Host Function Types

/// Type of a host-provided function.
/// args: argument values, memory: read-only view of linear memory.
typealias HostFunction = ([Value], [UInt8]) -> [Value]

/// Import bindings provided by the host at instantiation time
enum HostImport {
  case function(String, String, HostFunction)  // (module, name, body)
  case memory(String, String, UInt32)          // (module, name, pages)
}

// File-scoped type used to propagate br signals
private enum ControlFlow {
  case proceed      // advance to the next instruction normally
  case br(UInt32)   // branch signal targeting label depth n
}

// MARK: - Interpreter

// Does not conform to Sendable because HostFunction (a closure) is not Sendable.
struct WasmInterpreter {
  let module: WasmModule
  let memory: [UInt8]
  private let hostFunctions: [HostFunction]

  // MARK: - Init

  /// Instantiates the module.
  ///
  /// - hostImports: host-provided functions and memories required by the module's imports.
  ///   Throws .importNotFound if an import is declared but no matching HostImport is given.
  init(module: WasmModule, hostImports: [HostImport] = []) throws(WasmError) {
    self.module = module

    // Match host functions to imports, preserving import order
    var funcs: [HostFunction] = []
    for imp in module.imports {
      guard case .function(let fi) = imp else { continue }
      let modStr = String(decoding: fi.module, as: UTF8.self)
      let nameStr = String(decoding: fi.name, as: UTF8.self)
      var found = false
      for hi in hostImports {
        guard case .function(let m, let n, let body) = hi else { continue }
        if m == modStr && n == nameStr {
          funcs.append(body)
          found = true
          break
        }
      }
      guard found else { throw .importNotFound }
    }
    self.hostFunctions = funcs

    // Determine memory size: prefer imported memory, fall back to local memory definition
    var memPageCount: UInt32 = 0
    for imp in module.imports {
      guard case .memory(let mi) = imp else { continue }
      let modStr = String(decoding: mi.module, as: UTF8.self)
      let nameStr = String(decoding: mi.name, as: UTF8.self)
      var found = false
      for hi in hostImports {
        guard case .memory(let m, let n, let pages) = hi else { continue }
        if m == modStr && n == nameStr {
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
  func callExport(nameBytes: [UInt8], args: [Value]) throws(WasmError) -> [Value] {
    guard let export = module.exports.first(where: { $0.nameBytes == nameBytes && $0.kind == .function }) else {
      throw .functionNotFound
    }
    return try call(functionIndex: Int(export.index), args: args)
  }

  /// Calls a function by its unified function index (including imports)
  func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let importedCount = module.importedFunctionCount

    if functionIndex < importedCount {
      // Host function: pass a read-only view of memory
      return hostFunctions[functionIndex](args, memory)
    }

    // Local function
    let localIdx = functionIndex - importedCount
    let typeIndex = Int(module.functions[localIdx])
    let funcType = module.types[typeIndex]
    let body = module.code[localIdx]

    guard args.count == funcType.params.count else {
      throw .argumentCountMismatch
    }

    var locals = args
    for _ in body.locals { locals.append(.i32(0)) }

    return try execute(body: body, locals: &locals, resultCount: funcType.results.count)
  }

  // MARK: - Execution

  private func execute(
    body: FunctionBody,
    locals: inout [Value],
    resultCount: Int
  ) throws(WasmError) -> [Value] {
    var stack: [Value] = []
    _ = try run(body.instructions, locals: &locals, stack: &stack)
    return Array(stack.suffix(resultCount))
  }

  /// Executes an instruction sequence and returns a ControlFlow signal.
  private func run(
    _ instructions: [Instruction],
    locals: inout [Value],
    stack: inout [Value]
  ) throws(WasmError) -> ControlFlow {
    for instruction in instructions {
      switch instruction {

      case .localGet(let idx):
        stack.append(locals[Int(idx)])

      case .localSet(let idx):
        guard !stack.isEmpty else { throw .stackUnderflow }
        locals[Int(idx)] = stack.removeLast()

      case .i32Const(let value):
        stack.append(.i32(value))

      case .i32Add:
        guard stack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = stack.removeLast(),
              case .i32(let a) = stack.removeLast()
        else { throw .typeMismatch }
        stack.append(.i32(a &+ b))

      case .i32Eq:
        guard stack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = stack.removeLast(),
              case .i32(let a) = stack.removeLast()
        else { throw .typeMismatch }
        stack.append(.i32(a == b ? 1 : 0))

      case .i32GeS:
        guard stack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = stack.removeLast(),
              case .i32(let a) = stack.removeLast()
        else { throw .typeMismatch }
        stack.append(.i32(a >= b ? 1 : 0))

      case .i32RemU:
        // Unsigned remainder: reinterpret the Int32 bit patterns as UInt32
        guard stack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = stack.removeLast(),
              case .i32(let a) = stack.removeLast()
        else { throw .typeMismatch }
        guard b != 0 else { throw .divisionByZero }
        let result = UInt32(bitPattern: a) % UInt32(bitPattern: b)
        stack.append(.i32(Int32(bitPattern: result)))

      case .call(let funcIdx):
        let funcType = module.functionType(at: Int(funcIdx))
        let argCount = funcType.params.count
        guard stack.count >= argCount else { throw .stackUnderflow }
        let args = Array(stack.suffix(argCount))
        stack.removeLast(argCount)
        let results = try call(functionIndex: Int(funcIdx), args: args)
        stack.append(contentsOf: results)

      case .block(_, let inner):
        // block: br(0) exits the block (forward jump)
        switch try run(inner, locals: &locals, stack: &stack) {
        case .proceed:   break
        case .br(0):     break
        case .br(let n): return .br(n - 1)
        }

      case .loop(_, let inner):
        // loop: br(0) jumps back to the loop head (backward jump)
        loopHead: while true {
          switch try run(inner, locals: &locals, stack: &stack) {
          case .proceed:   break loopHead
          case .br(0):     continue loopHead
          case .br(let n): return .br(n - 1)
          }
        }

      case .ifElse(_, let thenBody, let elseBody):
        // if/else has the same label behavior as block: br(0) exits the if block
        guard !stack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = stack.removeLast() else { throw .typeMismatch }
        let branch = cond != 0 ? thenBody : elseBody
        switch try run(branch, locals: &locals, stack: &stack) {
        case .proceed:   break
        case .br(0):     break
        case .br(let n): return .br(n - 1)
        }

      case .br(let n):
        return .br(n)

      case .brIf(let n):
        guard !stack.isEmpty else { throw .stackUnderflow }
        guard case .i32(let cond) = stack.removeLast() else { throw .typeMismatch }
        if cond != 0 { return .br(n) }
      }
    }
    return .proceed
  }
}
