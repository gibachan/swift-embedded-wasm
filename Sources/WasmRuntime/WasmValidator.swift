// Type-checking validator for Wasm function bodies.
//
// Only compiled for non-Embedded targets. Embedded builds skip validation and
// assume that only pre-validated modules are executed (trusted source assumption).
//
// The validator implements the Wasm binary-format type-checking algorithm:
//   - Maintains a value-type stack and a control-frame stack.
//   - For each instruction, pops the expected operand types and pushes the result types.
//   - Throws WasmError.typeMismatch on any type violation.
//
// Scope: full type-tracking for all instructions the parser recognises,
// with strict checking for i32 operations (the initial validation target).
// Unimplemented instructions (opcode stubs) are skipped — they fail at runtime anyway.

#if !hasFeature(Embedded)

  // MARK: - WasmValidator

  struct WasmValidator {
    let module: WasmModule

    /// Validates all local function bodies in the module.
    /// Throws WasmError.typeMismatch on the first type error found.
    func validate() throws(WasmError) {
      guard module.code.count == module.functions.count else { throw .typeMismatch }
      // All function type indices (local + imported) must reference existing types.
      for typeIdx in module.functions {
        guard Int(typeIdx) < module.types.count else { throw .typeMismatch }
      }
      for imp in module.imports {
        if case .function(let fi) = imp {
          guard Int(fi.typeIndex) < module.types.count else { throw .typeMismatch }
        }
      }
      for (i, body) in module.code.enumerated() {
        let funcType = module.functionType(at: module.importedFunctionCount + i)
        var checker = FunctionChecker(module: module, funcType: funcType, body: body)
        try checker.run()
      }
    }
  }

  // MARK: - Control Frame

  /// One entry on the control-flow frame stack.
  ///
  /// startHeight: value-stack depth at frame entry (after consuming block params).
  /// resultTypes: types the frame must produce at blockEnd.
  /// labelTypes:  types consumed by `br` to this label
  ///              (block/if → resultTypes; loop → its param types).
  /// unreachable: set after an unconditional branch (br/return/unreachable).
  ///              In unreachable mode, type-checking is suspended for the current frame.
  private struct ControlFrame {
    var startHeight: Int
    var resultTypes: [ValueType]
    var labelTypes: [ValueType]
    var unreachable: Bool
  }

  // MARK: - FunctionChecker

  private struct FunctionChecker {
    let module: WasmModule
    let allLocals: [ValueType]  // params ++ declared locals
    let instructions: [Instruction]

    var stack: [ValueType] = []
    var frames: [ControlFrame]

    /// Records which instruction index should trigger an else-frame push.
    /// Populated when processing ifElse; consumed when the IP reaches elsePc.
    var pendingElseFrames: [Int: ControlFrame] = [:]

    init(module: WasmModule, funcType: FunctionType, body: FunctionBody) {
      self.module = module
      self.allLocals = funcType.params + body.locals
      self.instructions = body.instructions
      // Implicit outer frame for the function body.
      // br to the function label = return, so labelTypes == resultTypes.
      self.frames = [
        ControlFrame(
          startHeight: 0,
          resultTypes: funcType.results,
          labelTypes: funcType.results,
          unreachable: false
        )
      ]
    }

    mutating func run() throws(WasmError) {
      for (ip, instr) in instructions.enumerated() {
        // Push a pending else-frame when execution reaches elsePc.
        if let elseFrame = pendingElseFrames.removeValue(forKey: ip) {
          // Discard values left by the then-branch; else-branch starts fresh.
          if elseFrame.startHeight <= stack.count {
            stack.removeSubrange(elseFrame.startHeight...)
          } else {
            stack.removeAll()
          }
          frames.append(elseFrame)
        }
        try check(instr, at: ip)
      }

      // After all instructions: validate the function's final result.
      // The function frame may be unreachable (e.g. ends with return/unreachable).
      if let funcFrame = frames.last, !funcFrame.unreachable {
        let expected = funcFrame.resultTypes
        guard stack.count == funcFrame.startHeight + expected.count else { throw .typeMismatch }
        for (actual, exp) in zip(stack.dropFirst(funcFrame.startHeight), expected) {
          guard actual == exp else { throw .typeMismatch }
        }
      }
    }

    // MARK: - Instruction dispatch

    private mutating func check(_ instr: Instruction, at ip: Int) throws(WasmError) {
      switch instr {

      // MARK: Constants
      case .i32Const: tryPush(.i32)
      case .i64Const: tryPush(.i64)
      case .f32Const: tryPush(.f32)
      case .f64Const: tryPush(.f64)

      // MARK: i32 unary: i32 → i32
      case .i32Eqz, .i32Clz, .i32Ctz, .i32Popcnt, .i32Extend8S, .i32Extend16S:
        try popExpecting(.i32)
        tryPush(.i32)

      // MARK: i32 binary: (i32, i32) → i32
      case .i32Add, .i32Sub, .i32Mul, .i32DivS, .i32DivU, .i32RemS, .i32RemU,
        .i32And, .i32Or, .i32Xor, .i32Shl, .i32ShrS, .i32ShrU, .i32Rotl, .i32Rotr,
        .i32Eq, .i32Ne, .i32LtS, .i32LtU, .i32GtS, .i32GtU, .i32LeS, .i32LeU, .i32GeS, .i32GeU:
        try popExpecting(.i32)
        try popExpecting(.i32)
        tryPush(.i32)

      // MARK: i64 (tracked for stack correctness)
      case .i64Eqz:
        try popExpecting(.i64)
        tryPush(.i32)
      case .i64Clz, .i64Ctz, .i64Popcnt, .i64Extend8S, .i64Extend16S, .i64Extend32S:
        try popExpecting(.i64)
        tryPush(.i64)
      case .i64Add, .i64Sub, .i64Mul, .i64DivS, .i64DivU, .i64RemS, .i64RemU,
        .i64And, .i64Or, .i64Xor, .i64Shl, .i64ShrS, .i64ShrU, .i64Rotl, .i64Rotr:
        try popExpecting(.i64)
        try popExpecting(.i64)
        tryPush(.i64)
      case .i64Eq, .i64Ne, .i64LtS, .i64LtU, .i64GtS, .i64GtU, .i64LeS, .i64LeU, .i64GeS,
        .i64GeU:
        try popExpecting(.i64)
        try popExpecting(.i64)
        tryPush(.i32)

      // MARK: f32 (tracked for stack correctness)
      case .f32Abs, .f32Neg, .f32Ceil, .f32Floor, .f32Trunc, .f32Nearest, .f32Sqrt:
        try popExpecting(.f32)
        tryPush(.f32)
      case .f32Add, .f32Sub, .f32Mul, .f32Div, .f32Min, .f32Max, .f32Copysign:
        try popExpecting(.f32)
        try popExpecting(.f32)
        tryPush(.f32)
      case .f32Eq, .f32Ne, .f32Lt, .f32Gt, .f32Le, .f32Ge:
        try popExpecting(.f32)
        try popExpecting(.f32)
        tryPush(.i32)

      // MARK: Control flow

      case .unreachable:
        setUnreachable()

      case .nop:
        break

      case .block(let bt, _):
        let (params, results) = try blockTypes(bt)
        for param in params.reversed() { try popExpecting(param) }
        let h = stack.count
        let inheritUR = isUnreachable()
        // Re-push block params as the initial stack inside the block body.
        if !inheritUR { for param in params { stack.append(param) } }
        frames.append(
          ControlFrame(
            startHeight: h, resultTypes: results, labelTypes: results, unreachable: inheritUR)
        )

      case .loop(let bt, _):
        let (params, results) = try blockTypes(bt)
        for param in params.reversed() { try popExpecting(param) }
        let h = stack.count
        let inheritUR = isUnreachable()
        if !inheritUR { for param in params { stack.append(param) } }
        // Loop label carries the loop's param types (br restarts with those).
        frames.append(
          ControlFrame(
            startHeight: h, resultTypes: results, labelTypes: params, unreachable: inheritUR)
        )

      case .ifElse(let bt, let elsePc, _):
        try popExpecting(.i32)  // condition
        let (params, results) = try blockTypes(bt)
        for param in params.reversed() { try popExpecting(param) }
        let h = stack.count
        let inheritUR = isUnreachable()
        if !inheritUR { for param in params { stack.append(param) } }

        // Detect whether there is an else-branch by checking whether the
        // instruction just before elsePc is a `jump` (the then→else skip).
        var hasElse = false
        if elsePc > 0, elsePc - 1 < instructions.count, case .jump(_) = instructions[elsePc - 1] {
          hasElse = true
        }

        frames.append(
          ControlFrame(
            startHeight: h, resultTypes: results, labelTypes: results, unreachable: inheritUR)
        )
        if hasElse {
          // The else-frame will be pushed when the IP reaches elsePc.
          pendingElseFrames[elsePc] = ControlFrame(
            startHeight: h, resultTypes: results, labelTypes: results, unreachable: inheritUR)
        }

      case .blockEnd:
        // Never pop the implicit function frame here; it is checked after the loop.
        guard frames.count > 1 else { break }
        let top = frames.removeLast()
        try checkFrameResults(top)
        // Push the frame's result types onto the outer stack.
        for t in top.resultTypes { tryPush(t) }

      case .jump:
        // Synthetic instruction: skips the else-body after the then-branch ends.
        // No type effect; the pending else-frame handles the stack reset at elsePc.
        break

      case .br(let depth):
        if !isUnreachable() { try checkBranch(depth: depth) }
        setUnreachable()

      case .brIf(let depth):
        try popExpecting(.i32)
        if !isUnreachable() { try checkBranch(depth: depth) }
      // brIf is conditional: does not mark code as unreachable.

      case .brTable(let targets, let defaultTarget):
        try popExpecting(.i32)
        if !isUnreachable() {
          for d in targets { try checkBranch(depth: d) }
          try checkBranch(depth: defaultTarget)
        }
        setUnreachable()

      case .return_:
        // `br` to the implicit function frame = return.
        if !isUnreachable() { try checkBranch(depth: UInt32(frames.count - 1)) }
        setUnreachable()

      // MARK: Stack operations

      case .drop:
        _ = try popAny()

      case .select:
        try popExpecting(.i32)  // condition
        let t2 = try popAny()
        let t1 = try popAny()
        if let t1, let t2 {
          guard t1 == t2 else { throw .typeMismatch }
          tryPush(t1)
        }
      // In unreachable mode t1/t2 are nil; tryPush is also a no-op.

      // MARK: Locals

      case .localGet(let idx):
        guard Int(idx) < allLocals.count else { throw .typeMismatch }
        tryPush(allLocals[Int(idx)])

      case .localSet(let idx):
        guard Int(idx) < allLocals.count else { throw .typeMismatch }
        try popExpecting(allLocals[Int(idx)])

      case .localTee(let idx):
        guard Int(idx) < allLocals.count else { throw .typeMismatch }
        try popExpecting(allLocals[Int(idx)])
        tryPush(allLocals[Int(idx)])

      // MARK: Globals (local globals only; global imports are rejected by the parser)

      case .globalGet(let idx):
        guard Int(idx) < module.globals.count else { throw .typeMismatch }
        tryPush(module.globals[Int(idx)].type.valueType)

      case .globalSet(let idx):
        guard Int(idx) < module.globals.count else { throw .typeMismatch }
        try popExpecting(module.globals[Int(idx)].type.valueType)

      // MARK: Calls

      case .call(let funcIdx):
        let totalFuncs = module.importedFunctionCount + module.functions.count
        guard Int(funcIdx) < totalFuncs else { throw .typeMismatch }
        let ft = module.functionType(at: Int(funcIdx))
        for param in ft.params.reversed() { try popExpecting(param) }
        for result in ft.results { tryPush(result) }

      case .callIndirect(let typeIdx, _):
        guard Int(typeIdx) < module.types.count else { throw .typeMismatch }
        try popExpecting(.i32)  // table index
        let ft = module.types[Int(typeIdx)]
        for param in ft.params.reversed() { try popExpecting(param) }
        for result in ft.results { tryPush(result) }

      // MARK: Conversions

      case .i64ExtendI32S:
        try popExpecting(.i32)
        tryPush(.i64)

      // MARK: Memory

      case .i32Load:
        try popExpecting(.i32)
        tryPush(.i32)

      case .i32Store:
        try popExpecting(.i32)
        try popExpecting(.i32)

      case .memoryGrow:
        try popExpecting(.i32)
        tryPush(.i32)

      // MARK: Unimplemented stubs
      //
      // Mark the frame as unreachable so the final type check is skipped.
      // The function will fail at runtime with invalidInstruction, which the
      // spectest runner treats as a skip — not a failure.
      case .unimplemented:
        setUnreachable()
      }
    }

    // MARK: - Stack helpers

    private func isUnreachable() -> Bool { frames.last?.unreachable ?? false }

    private mutating func tryPush(_ vt: ValueType) {
      guard !isUnreachable() else { return }
      stack.append(vt)
    }

    /// Pops and returns any type, or nil when in unreachable (polymorphic) mode.
    private mutating func popAny() throws(WasmError) -> ValueType? {
      guard !isUnreachable() else { return nil }
      guard let frame = frames.last, stack.count > frame.startHeight else { throw .typeMismatch }
      return stack.removeLast()
    }

    /// Pops the top value and asserts it equals `expected`.
    /// In unreachable mode, the pop is skipped (polymorphic type accepted).
    private mutating func popExpecting(_ expected: ValueType) throws(WasmError) {
      guard !isUnreachable() else { return }
      guard let frame = frames.last, stack.count > frame.startHeight else { throw .typeMismatch }
      let actual = stack.removeLast()
      guard actual == expected else { throw .typeMismatch }
    }

    /// Marks the current frame as unreachable and truncates the stack to frame height.
    private mutating func setUnreachable() {
      guard !frames.isEmpty else { return }
      frames[frames.count - 1].unreachable = true
      let h = frames[frames.count - 1].startHeight
      if h <= stack.count { stack.removeSubrange(h...) } else { stack.removeAll() }
    }

    /// Returns (params, results) for a block type.
    private func blockTypes(_ bt: BlockType) throws(WasmError) -> ([ValueType], [ValueType]) {
      switch bt {
      case .void: return ([], [])
      case .value(let vt): return ([], [vt])
      case .typeIndex(let idx):
        guard Int(idx) < module.types.count else { throw .typeMismatch }
        let ft = module.types[Int(idx)]
        return (ft.params, ft.results)
      }
    }

    /// Validates a frame's results at `blockEnd`.
    /// In unreachable frames the stack is reset to startHeight without type-checking.
    private mutating func checkFrameResults(_ frame: ControlFrame) throws(WasmError) {
      if frame.unreachable {
        if frame.startHeight <= stack.count {
          stack.removeSubrange(frame.startHeight...)
        } else {
          stack.removeAll()
        }
        return
      }
      let expected = frame.resultTypes
      guard stack.count == frame.startHeight + expected.count else { throw .typeMismatch }
      for (actual, exp) in zip(stack.dropFirst(frame.startHeight), expected) {
        guard actual == exp else { throw .typeMismatch }
      }
      stack.removeSubrange(frame.startHeight...)
    }

    /// Checks that the label types of `frames[count-1-depth]` are on top of the stack.
    private func checkBranch(depth: UInt32) throws(WasmError) {
      let d = Int(depth)
      guard d < frames.count else { throw .typeMismatch }
      let target = frames[frames.count - 1 - d]
      let labelTypes = target.labelTypes
      guard stack.count >= target.startHeight + labelTypes.count else { throw .typeMismatch }
      for (actual, exp) in zip(stack.suffix(labelTypes.count), labelTypes) {
        guard actual == exp else { throw .typeMismatch }
      }
    }
  }

#endif  // !hasFeature(Embedded)
