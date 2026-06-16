// Wasm stack machine interpreter — host type definitions and call dispatch
//
// Execution is performed by runIterativeEmbedded() in WasmInterpreterEmbedded.swift,
// which decodes opcodes on-the-fly from module.rawBytes using the pre-computed jump
// table (FunctionHandle.jumpTable) for O(1) control-flow resolution.
//
// This file contains: host function type definitions, HostImport, and the public
// call/callExport entry points that dispatch to the shared execution engine.

// MARK: - Host Function Types

/// Type of a host-provided function.
/// args: argument values, memory: read-only view of linear memory.
typealias HostFunction = ([Value], [UInt8]) -> [Value]

// TODO: Phase 4 — unify HostFunction and HostFunctionPtr into a single calling convention,
// eliminating the #if hasFeature(Embedded) branches throughout this file.
#if hasFeature(Embedded)
  /// @convention(c) function pointer for host-provided functions in Embedded builds.
  /// No heap allocation — host functions must use globals for any state they need.
  ///
  /// Parameters:
  ///   - args:        raw pointer to argument Values (reinterpret as UnsafePointer<Value> inside callee)
  ///   - argsCount:   number of arguments
  ///   - memory:      pointer to linear memory bytes (nil if no memory)
  ///   - memorySize:  number of bytes in linear memory
  ///   - results:     raw pointer to pre-allocated result buffer (nil if 0 results)
  ///
  /// UnsafeRawPointer / UnsafeMutableRawPointer are used instead of UnsafePointer<Value> /
  /// UnsafeMutablePointer<Value> because `Value` is a Swift enum and is not representable
  /// in @convention(c) function pointer signatures.
  typealias HostFunctionPtr =
    @convention(c) (
      UnsafeRawPointer?,
      Int32,
      UnsafeMutablePointer<UInt8>?,
      Int32,
      UnsafeMutableRawPointer?
    ) -> Void
#endif

/// Import bindings provided by the host at instantiation time.
///
/// Module and field names are `StaticString` (compile-time constants) so that
/// no heap allocation is required in Embedded Swift environments.
/// String literals are accepted directly without any change at the call site.
///
/// In non-Embedded builds, `functionDyn` and `memoryDyn` variants are also available
/// for test infrastructure that constructs names from runtime byte arrays.
/// In Embedded builds, `.function` accepts a `HostFunctionPtr` (@convention(c) pointer)
/// instead of a `HostFunction` closure to avoid heap allocation.
enum HostImport {
  #if hasFeature(Embedded)
    case function(StaticString, StaticString, HostFunctionPtr)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)  // (module, name, pages)
  #else
    case function(StaticString, StaticString, HostFunction)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)  // (module, name, pages)
    case functionDyn([UInt8], [UInt8], HostFunction)  // (moduleBytes, nameBytes, body)
    case memoryDyn([UInt8], [UInt8], UInt32)  // (moduleBytes, nameBytes, pages)
  #endif
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

// internal (no modifier) so that WasmInterpreterEmbedded.swift (a separate file in the same
// module) can reference LabelKind and Label.  swift-format's FileScopedDeclarationPrivacy rule
// converts 'fileprivate' → 'private' on file-scoped declarations, breaking cross-file access;
// 'internal' (implicit) is the correct level for intra-module sharing.
enum LabelKind {
  case block  // br exits; jump to continuationPc (past blockEnd)
  case loop  // br restarts; jump to continuationPc (= startPc); label stays on stack
  case ifElse  // br exits; same as block
}

struct Label {
  let kind: LabelKind
  let stackBase: Int  // value stack depth when this label was entered
  let brArity: Int  // values carried by br (block/if: result count; loop: param count)
  let continuationPc: Int  // where br to this label jumps:
  //   block/if: past blockEnd (= blockEndPc + 1)
  //   loop:     first body instruction (restart)
}

// block/loop/if arity is now pre-computed at parse time and stored directly in each
// Instruction case (brArity, paramCount fields). The blockArity() / loopBrArity()
// helpers that previously looked up module.types at runtime have been removed.

// MARK: - Interpreter

// Does not conform to Sendable because HostFunction (a closure) is not Sendable in non-Embedded builds.
struct WasmInterpreter {
  let module: WasmModule
  var memory: [UInt8]
  #if hasFeature(Embedded)
    // In Embedded builds, host functions are @convention(c) pointers — no heap allocation.
    // internal (no modifier) so WasmInterpreterEmbedded.swift (same module, separate file) can
    // access hostFunctions from runIterativeEmbedded.
    let hostFunctions: [HostFunctionPtr]
  #else
    let hostFunctions: [HostFunction]
  #endif
  // internal (no modifier) so that WasmInterpreterEmbedded.swift (same module, separate file)
  // can pass these as inout arguments to dispatchEmbedded.
  var globals: [Value]  // mutable global variable slots (global.get/set)
  // Tables store Value (.funcref or .externref) directly to support both funcref and externref tables.
  // The reftype of each slot is determined by the table's declared RefType.
  var tables: [[Value]]  // reference tables: tables[tableIdx][elemIdx]
  // Bit i = 1 means segment i has been dropped. Supports up to 64 segments.
  var droppedDataSegments: UInt64 = 0
  // Bit i = 1 means segment i has been dropped. Supports up to 64 segments.
  var droppedElementSegments: UInt64 = 0

  // MARK: - Init

  /// Instantiates the module.
  ///
  /// - hostImports: host-provided functions and memories required by the module's imports.
  ///   Throws .importNotFound if an import is declared but no matching HostImport is given.
  init(module: WasmModule, hostImports: [HostImport] = []) throws(WasmError) {
    self.module = module

    // Match host functions to imports, preserving import order.
    // fi.module / fi.name are [UInt8]; StaticString cases use withUTF8Buffer for
    // zero-copy byte comparison without Unicode normalisation.
    #if hasFeature(Embedded)
      // Embedded path: host functions are @convention(c) pointers — no heap-captured closures.
      var funcs: [HostFunctionPtr] = []
      for imp in module.imports {
        guard case .function(let fi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var body: HostFunctionPtr?
          switch hi {
          case .function(let m, let n, let fn):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { fi.module.elementsEqual(mBuf) && fi.name.elementsEqual($0) }
            }
            if matches { body = fn }
          case .memory: break
          }
          if let fn = body {
            funcs.append(fn)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      self.hostFunctions = funcs
    #else
      var funcs: [HostFunction] = []
      for imp in module.imports {
        guard case .function(let fi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var body: HostFunction?
          switch hi {
          case .function(let m, let n, let fn):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { fi.module.elementsEqual(mBuf) && fi.name.elementsEqual($0) }
            }
            if matches { body = fn }
          case .functionDyn(let mBytes, let nBytes, let fn):
            if fi.module.elementsEqual(mBytes) && fi.name.elementsEqual(nBytes) { body = fn }
          default: break
          }
          if let fn = body {
            funcs.append(fn)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      self.hostFunctions = funcs
    #endif
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
        var matchedPages: UInt32?
        switch hi {
        case .memory(let m, let n, let pages):
          let matches = m.withUTF8Buffer { mBuf in
            n.withUTF8Buffer { mi.module.elementsEqual(mBuf) && mi.name.elementsEqual($0) }
          }
          if matches { matchedPages = pages }
        #if !hasFeature(Embedded)
          case .memoryDyn(let mBytes, let nBytes, let pages):
            if mi.module.elementsEqual(mBytes) && mi.name.elementsEqual(nBytes) {
              matchedPages = pages
            }
        #endif
        default: break
        }
        if let pages = matchedPages {
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
    // UInt64 bitmap supports at most 64 data segments.
    guard module.data.count <= 64 else { throw .resourceLimitExceeded }
    self.droppedDataSegments = 0  // all bits clear = no segments dropped

    // Active element segments are treated as dropped after instantiation per Wasm spec §4.5.4.
    // Declarative segments (flags=3, 7) are also pre-dropped — they exist only to make
    // ref.func instructions valid, and must never be accessible via table.init.
    // flags=5 is passive (not declarative) and remains available for table.init.
    // Only true passive segments (isPassive==true, isDeclarative==false) remain available
    // for table.init at runtime.
    // UInt64 bitmap supports at most 64 element segments.
    guard module.elements.count <= 64 else { throw .resourceLimitExceeded }
    var droppedElems: UInt64 = 0
    for (i, seg) in module.elements.enumerated() {
      if !seg.isPassive || seg.isDeclarative { droppedElems |= UInt64(1) << i }
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
      let export = module.exports.first(where: {
        $0.nameBytes.elementsEqual(nameBytes) && $0.kind == .function
      })
    else {
      throw .functionNotFound
    }
    return try call(functionIndex: Int(export.index), args: args)
  }

  /// Calls a function by its unified function index (including imports)
  mutating func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let importedCount = module.importedFunctionCount

    if functionIndex < importedCount {
      // Host function: dispatch via the appropriate calling convention
      #if hasFeature(Embedded)
        return callHostFunction(index: functionIndex, args: args)
      #else
        return hostFunctions[functionIndex](args, memory)
      #endif
    }

    // Local function: validate and run iteratively
    let localIdx = functionIndex - importedCount
    let typeIndex = Int(module.functions[localIdx])
    let funcType = module.types[typeIndex]
    guard args.count == funcType.params.count else {
      throw .argumentCountMismatch
    }

    return try runIterativeEmbedded(functionIndex: functionIndex, args: args)
  }

  // MARK: - Embedded Host Function Dispatch

  #if hasFeature(Embedded)
    /// Calls a host function by index using the @convention(c) HostFunctionPtr interface.
    ///
    /// This helper is used by `call(functionIndex:args:)` in Embedded builds to avoid
    /// heap-captured closures. Arguments are passed via UnsafeBufferPointer and results
    /// are read from a fixed 8-slot stack buffer.
    ///
    /// Limitation: host functions returning more than 8 values are not supported in Embedded.
    private mutating func callHostFunction(index: Int, args: [Value]) -> [Value] {
      let resultCount = module.functionType(at: index).results.count
      // Fixed 8-slot result buffer; host functions returning >8 values are unsupported in
      // Embedded builds. Guard against out-of-bounds writes at runtime.
      precondition(
        resultCount <= 8,
        "HostFunctionPtr: resultCount \(resultCount) exceeds 8-slot result buffer — not supported in Embedded"
      )
      // withUnsafeTemporaryAllocation guarantees correct alignment and stride for Value
      // elements — unlike a homogeneous tuple, whose layout Swift does not formally guarantee.
      var results: [Value] = []
      withUnsafeTemporaryAllocation(of: Value.self, capacity: 8) { resultsBuf in
        args.withUnsafeBytes { argsRaw in
          let argsPtr: UnsafeRawPointer? = argsRaw.baseAddress
          let resultsRaw: UnsafeMutableRawPointer? =
            resultCount > 0 ? UnsafeMutableRawPointer(resultsBuf.baseAddress!) : nil
          memory.withUnsafeMutableBytes { memBuf in
            let memPtr = memBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let memLen = Int32(memBuf.count)
            // Pass args as UnsafeRawPointer — callee reinterprets to UnsafePointer<Value>.
            hostFunctions[index](argsPtr, Int32(args.count), memPtr, memLen, resultsRaw)
          }
        }
        for i in 0..<resultCount {
          results.append(resultsBuf[i])
        }
      }
      return results
    }
  #endif
}
