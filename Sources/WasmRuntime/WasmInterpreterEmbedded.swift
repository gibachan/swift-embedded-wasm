// Embedded-only on-the-fly interpreter for the Wasm stack machine.
//
// Phase 4: eliminates the per-call [Instruction] allocation that the Phase 3 lazy-decode
// path produced.  Instead, opcodes are decoded directly from module.rawBytes as execution
// proceeds, using the pre-computed jump table (FunctionHandle.jumpTable) for O(1)
// control-flow target resolution.
//
// Locals are stored on the shared value stack starting at localBase, which means zero
// extra heap allocation per call beyond what the value stack already holds.
//
// The macOS path (runIterative with Frame/instructions/locals) is untouched.

#if hasFeature(Embedded)

  // MARK: - BinaryReader

  /// Zero-allocation byte reader over a fixed UnsafeBufferPointer<UInt8>.
  ///
  /// Used by the on-the-fly decoder to read opcodes and LEB128 immediates directly
  /// from the module's raw binary buffer without any intermediate allocation.
  struct BinaryReader {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int

    @inline(__always)
    mutating func readByte() throws(WasmError) -> UInt8 {
      guard offset < buffer.count else { throw WasmError.unexpectedEnd }
      let b = buffer[offset]
      offset &+= 1
      return b
    }

    /// Unsigned LEB128 → UInt32
    @inline(__always)
    mutating func readU32() throws(WasmError) -> UInt32 {
      var result: UInt32 = 0
      var shift: UInt = 0
      while true {
        let byte = try readByte()
        result |= UInt32(byte & 0x7F) << shift
        if byte & 0x80 == 0 { return result }
        shift += 7
        if shift >= 35 { throw WasmError.unexpectedEnd }
      }
    }

    /// Signed LEB128 → Int32 (used for i32.const and block type s33)
    @inline(__always)
    mutating func readS32() throws(WasmError) -> Int32 {
      var result: Int32 = 0
      var shift = 0
      var byte: UInt8 = 0
      while true {
        byte = try readByte()
        result |= Int32(byte & 0x7F) &<< shift
        shift += 7
        if byte & 0x80 == 0 { break }
        if shift > 35 { throw WasmError.unexpectedEnd }
      }
      // Sign extend
      if shift < 32 && (byte & 0x40) != 0 {
        result |= ~Int32(0) &<< shift
      }
      return result
    }

    /// Signed LEB128 → Int64 (used for i64.const)
    @inline(__always)
    mutating func readS64() throws(WasmError) -> Int64 {
      var result: Int64 = 0
      var shift = 0
      var byte: UInt8 = 0
      while true {
        byte = try readByte()
        result |= Int64(byte & 0x7F) &<< shift
        shift += 7
        if byte & 0x80 == 0 { break }
        if shift > 70 { throw WasmError.unexpectedEnd }
      }
      // Sign extend
      if shift < 64 && (byte & 0x40) != 0 {
        result |= ~Int64(0) &<< shift
      }
      return result
    }

    /// 4-byte little-endian IEEE 754 float (f32.const)
    @inline(__always)
    mutating func readF32() throws(WasmError) -> Float {
      let b0 = UInt32(try readByte())
      let b1 = UInt32(try readByte())
      let b2 = UInt32(try readByte())
      let b3 = UInt32(try readByte())
      return Float(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }

    /// 8-byte little-endian IEEE 754 double (f64.const)
    @inline(__always)
    mutating func readF64() throws(WasmError) -> Double {
      let b0 = UInt64(try readByte())
      let b1 = UInt64(try readByte())
      let b2 = UInt64(try readByte())
      let b3 = UInt64(try readByte())
      let b4 = UInt64(try readByte())
      let b5 = UInt64(try readByte())
      let b6 = UInt64(try readByte())
      let b7 = UInt64(try readByte())
      let bits =
        b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48)
        | (b7 << 56)
      return Double(bitPattern: bits)
    }

    /// Block type (s33 encoding): negative → value type or void, non-negative → type index
    @inline(__always)
    mutating func readBlockType() throws(WasmError) -> BlockType {
      let raw = try readS32()
      if raw >= 0 { return .typeIndex(UInt32(raw)) }
      let byte = UInt8(raw & 0x7F)
      if byte == 0x40 { return .void }
      guard let vt = ValueType(rawValue: byte) else { throw WasmError.invalidValueType(byte) }
      return .value(vt)
    }
  }

  // MARK: - EmbeddedFrame

  /// Call frame for the Embedded on-the-fly interpreter.
  ///
  /// Locals are stored on the shared value stack starting at localBase.
  /// Parameters are already there (pushed by the caller); additional declared
  /// locals are zero-initialised by pushEmbeddedFrame() and appended immediately after.
  ///
  /// ip is an absolute byte offset into module.rawBytes (= WasmModule.rawBytes).
  /// jumpCursor is a monotonically-advancing index into FunctionHandle.jumpTable;
  /// it is advanced by 1 each time a block/loop/if opcode is decoded, giving O(1)
  /// lookup without scanning.
  private struct EmbeddedFrame {
    var ip: UInt32  // absolute byte offset in module.rawBytes
    var jumpCursor: Int  // monotonic index into handle.jumpTable
    let handleIdx: Int  // index into module.code
    let localBase: Int  // index of first local (= first param) on valueStack
    let localCount: Int  // total locals (params + declared); valueStack depth at body start
    let resultCount: Int  // number of return values
    // TODO: Embedded Phase 5 — replace [Label] with fixed-size buffer
    var labels: [Label]  // TODO: Embedded Phase 5 — fixed buffer
  }

  // MARK: - WasmInterpreter Embedded extension

  extension WasmInterpreter {

    // MARK: jumpCursorForIp

    /// Binary search: first index in jumpTable where entry.instrOffset >= ip.
    /// Called when ip changes non-sequentially (branch taken, function return, etc.).
    private func jumpCursorForIp(_ ip: UInt32, in jumpTable: [JumpEntry]) -> Int {
      var lo = 0
      var hi = jumpTable.count
      while lo < hi {
        let mid = lo &+ (hi &- lo) / 2
        if jumpTable[mid].instrOffset < ip { lo = mid &+ 1 } else { hi = mid }
      }
      return lo
    }

    // MARK: runIterativeEmbedded

    /// On-the-fly Embedded interpreter.  Replaces the Phase 3 lazy-decode path.
    ///
    /// Value stack layout within a frame:
    ///   [localBase ..< localBase + localCount]  → parameters + declared locals
    ///   [localBase + localCount ...]             → operand stack for this frame
    ///
    /// Exclusivity note: mutable interpreter state (memory, globals, tables,
    /// droppedDataSegments, droppedElementSegments) is extracted into local variables at
    /// the top of this function.  All closures and dispatchEmbedded operate on those local
    /// variables exclusively, which avoids overlapping-access violations that would arise if
    /// both a closure capturing `self` and an `inout` parameter pointing into `self` were
    /// live at the same time.  The local variables are written back to `self` before return.
    mutating func runIterativeEmbedded(
      functionIndex: Int,
      args: [Value],
      fuelLimit: Int = 10_000_000
    ) throws(WasmError) -> [Value] {

      var valueStack: [Value] = []
      var frames: [EmbeddedFrame] = []
      var fuel = fuelLimit

      // Extract mutable state into local variables to eliminate exclusivity conflicts.
      // dispatchEmbedded receives these as inout; pushEmbeddedFrame closes over them directly.
      // Written back to self at the end (defer block).
      var localMemory = memory
      var localGlobals = globals
      var localTables = tables
      var localDroppedData = droppedDataSegments
      var localDroppedElem = droppedElementSegments
      defer {
        memory = localMemory
        globals = localGlobals
        tables = localTables
        droppedDataSegments = localDroppedData
        droppedElementSegments = localDroppedElem
      }

      // MARK: pushEmbeddedFrame

      /// Push a call frame for a local Wasm function.
      /// argCount arguments must already be on the top of valueStack.
      /// Closes over localMemory (local var, not self.memory) to avoid exclusivity conflicts
      /// when dispatchEmbedded holds &localMemory concurrently.
      @inline(__always)
      func pushEmbeddedFrame(funcIdx: Int, argCount: Int) throws(WasmError) {
        guard valueStack.count >= argCount else { throw WasmError.stackUnderflow }
        let importedCount = module.importedFunctionCount
        if funcIdx < importedCount {
          // Host function: dispatch via @convention(c) pointer (Embedded path)
          let argsStart = valueStack.count - argCount
          let resultCount = module.functionType(at: funcIdx).results.count
          precondition(
            resultCount <= 8,
            "HostFunctionPtr: resultCount exceeds 8-slot result buffer")
          withUnsafeTemporaryAllocation(of: Value.self, capacity: 8) { resultsBuf in
            valueStack.withUnsafeBytes { stackRaw in
              let argsRaw: UnsafeRawPointer? =
                stackRaw.baseAddress.map {
                  $0.advanced(by: argsStart * MemoryLayout<Value>.stride)
                }
              let resultsRaw: UnsafeMutableRawPointer? =
                resultCount > 0 ? UnsafeMutableRawPointer(resultsBuf.baseAddress!) : nil
              localMemory.withUnsafeMutableBytes { memBuf in
                let memPtr = memBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let memLen = Int32(memBuf.count)
                hostFunctions[funcIdx](argsRaw, Int32(argCount), memPtr, memLen, resultsRaw)
              }
            }
            valueStack.removeLast(argCount)
            for i in 0..<resultCount { valueStack.append(resultsBuf[i]) }
          }
          return
        }

        let localIdx = funcIdx - importedCount
        guard localIdx < module.code.count else { throw WasmError.functionNotFound }
        let handle = module.code[localIdx]
        let typeIdx = Int(module.functions[localIdx])
        let funcType = module.types[typeIdx]
        guard argCount == funcType.params.count else { throw WasmError.argumentCountMismatch }

        let localBase = valueStack.count - argCount

        // Zero-initialise declared locals (not parameters) directly on the value stack
        for vt in handle.locals {
          switch vt {
          case .i32: valueStack.append(.i32(0))
          case .i64: valueStack.append(.i64(0))
          case .f32: valueStack.append(.f32(0))
          case .f64: valueStack.append(.f64(0))
          case .funcref: valueStack.append(.funcref(nil))
          case .externref: valueStack.append(.externref(nil))
          }
        }

        let localCount = argCount + handle.locals.count
        frames.append(
          EmbeddedFrame(
            ip: handle.codeOffset,
            jumpCursor: 0,
            handleIdx: localIdx,
            localBase: localBase,
            localCount: localCount,
            resultCount: funcType.results.count,
            labels: []))
      }

      // MARK: embeddedReturn

      /// Pop the current frame, sliding return values down to localBase.
      @inline(__always)
      func embeddedReturn(fi: Int) throws(WasmError) {
        let resultCount = frames[fi].resultCount
        let localBase = frames[fi].localBase
        guard valueStack.count >= localBase + resultCount else {
          throw WasmError.stackUnderflow
        }
        let src = valueStack.count - resultCount
        for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((localBase + resultCount)...)
        frames.removeLast()
      }

      // MARK: handleEmbeddedBranch

      /// Execute a br(depth) — slides br-arity values to target label's stack base,
      /// pops labels, and updates ip + jumpCursor.
      @inline(__always)
      func handleEmbeddedBranch(depth: UInt32, fi: Int) throws(WasmError) {
        let d = Int(depth)
        let labelCount = frames[fi].labels.count

        if d >= labelCount {
          // Branch to the function's implicit outer label = early return
          let resultCount = frames[fi].resultCount
          let localBase = frames[fi].localBase
          let src = valueStack.count - resultCount
          guard src >= localBase else { throw WasmError.stackUnderflow }
          for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
          valueStack.removeSubrange((localBase + resultCount)...)
          frames[fi].labels.removeAll()
          // Signal frame done: set ip past end of code
          let handle = module.code[frames[fi].handleIdx]
          frames[fi].ip = handle.codeOffset &+ handle.codeSize
          return
        }

        let targetIdx = labelCount - 1 - d
        let target = frames[fi].labels[targetIdx]

        // Slide br-arity values to target's stackBase in-place (no temp array)
        let src = valueStack.count - target.brArity
        guard src >= target.stackBase else { throw WasmError.stackUnderflow }
        for i in 0..<target.brArity { valueStack[target.stackBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((target.stackBase + target.brArity)...)

        switch target.kind {
        case .loop:
          // Keep the loop label; pop only intermediary labels above it
          frames[fi].labels.removeSubrange((targetIdx + 1)...)
          let newIp = UInt32(target.continuationPc)
          frames[fi].ip = newIp
          frames[fi].jumpCursor = jumpCursorForIp(
            newIp, in: module.code[frames[fi].handleIdx].jumpTable)
        case .block, .ifElse:
          // Pop the target label and all above it
          frames[fi].labels.removeSubrange(targetIdx...)
          let newIp = UInt32(target.continuationPc)
          frames[fi].ip = newIp
          frames[fi].jumpCursor = jumpCursorForIp(
            newIp, in: module.code[frames[fi].handleIdx].jumpTable)
        }
      }

      // MARK: Seed and run

      valueStack.append(contentsOf: args)
      try pushEmbeddedFrame(funcIdx: functionIndex, argCount: args.count)

      while !frames.isEmpty {
        let fi = frames.count - 1
        let handle = module.code[frames[fi].handleIdx]
        let codeEnd = handle.codeOffset &+ handle.codeSize

        // Frame done when ip reaches (or passes) end of function body
        if frames[fi].ip >= codeEnd {
          try embeddedReturn(fi: fi)
          continue
        }

        fuel -= 1
        if fuel < 0 { throw WasmError.executionLimitExceeded }

        // Phase 4 Part A: read the opcode byte and advance ip BEFORE calling dispatchEmbedded.
        //
        // We read the opcode inside withUnsafeBytes (a non-escaping borrow of self.module),
        // store it in a local, then call dispatchEmbedded OUTSIDE the closure.
        // This avoids an exclusivity violation: withUnsafeBytes borrows self (via module),
        // while dispatchEmbedded is mutating and needs exclusive write access to self.
        //
        // In Part B, dispatchEmbedded will also need to read LEB128 immediates.  Those bytes
        // will be extracted here (pre-copied into a small local buffer) so that dispatchEmbedded
        // can work without holding the withUnsafeBytes borrow.
        //
        // ip-commit protocol:
        //   - dispatchEmbedded sets frames[fi].ip = nextIp before returning for sequential ops.
        //   - For control-flow (br, call, return), dispatchEmbedded overrides ip itself.
        //   - We always pass `nextIp` (the byte offset immediately after the opcode byte) so that
        //     sequential opcodes can commit it with a single assignment.
        var opcodeErr: WasmError? = nil
        var opcode: UInt8 = 0
        var nextIp: UInt32 = frames[fi].ip
        module.rawBytes.withUnsafeBytes { rawBuf throws(Never) in
          let typedBuf = rawBuf.bindMemory(to: UInt8.self)
          var reader = BinaryReader(buffer: typedBuf, offset: Int(frames[fi].ip))
          do throws(WasmError) {
            opcode = try reader.readByte()
            nextIp = UInt32(reader.offset)
          } catch {
            opcodeErr = error
          }
        }
        if let e = opcodeErr { throw e }

        // Dispatch outside withUnsafeBytes so dispatchEmbedded can access module.rawBytes.
        // Pass local variable references (not self.xxx) to avoid exclusivity violations:
        // the pushEmbeddedFrame closure already closes over the same local variables, so
        // there is no overlap between the closure borrow and the inout borrows.
        try dispatchEmbedded(
          opcode: opcode,
          nextIp: nextIp,
          fi: fi,
          valueStack: &valueStack,
          frames: &frames,
          memory: &localMemory,
          globals: &localGlobals,
          tables: &localTables,
          droppedData: &localDroppedData,
          droppedElem: &localDroppedElem,
          pushEmbeddedFrame: pushEmbeddedFrame,
          handleEmbeddedBranch: handleEmbeddedBranch)
      }

      return valueStack
    }

    // MARK: embeddedBlockArity / embeddedLoopBrArity

    /// Returns (brArity, paramCount) for a block/if block type.
    ///
    /// brArity = result count (values carried on br or fall-through exit from the block).
    /// paramCount = parameter count (values already on the stack when the block is entered).
    private func embeddedBlockArity(_ bt: BlockType) -> (brArity: Int, paramCount: Int) {
      switch bt {
      case .void: return (0, 0)
      case .value: return (1, 0)
      case .typeIndex(let i):
        guard Int(i) < module.types.count else { return (0, 0) }
        let ft = module.types[Int(i)]
        return (ft.results.count, ft.params.count)
      }
    }

    /// Returns the br-arity for a loop block type.
    ///
    /// For loops, br restarts with the loop's input parameters, so brArity == paramCount.
    private func embeddedLoopBrArity(_ bt: BlockType) -> Int {
      switch bt {
      case .void: return 0
      case .value: return 0
      case .typeIndex(let i):
        guard Int(i) < module.types.count else { return 0 }
        return module.types[Int(i)].params.count
      }
    }

    // MARK: dispatchEmbedded

    /// Execute the already-decoded opcode.
    ///
    /// `nextIp` is the byte offset immediately after the opcode byte.  For sequential (non-branch)
    /// instructions, dispatchEmbedded sets frames[fi].ip = nextIp before returning.
    /// For control-flow instructions, dispatchEmbedded overrides frames[fi].ip with the branch
    /// target directly.
    ///
    /// Immediate bytes are read here using local inline functions that index directly into
    /// module.rawBytes starting at nextIp.  The cursor is local to this method so there is
    /// no borrow conflict with the caller's withUnsafeBytes borrow (which is already released
    /// before dispatchEmbedded is called).
    ///
    // dispatchEmbedded is NOT mutating so that it does not require exclusive access to `self`,
    // which would conflict with the pushEmbeddedFrame / handleEmbeddedBranch closures that
    // already capture `self` for reading (module, hostFunctions).
    //
    // Instructions that mutate interpreter state (memory writes, global.set, etc.)
    // receive that state explicitly as inout parameters rather than going through self —
    // consistent with the exclusivity constraint.
    private func dispatchEmbedded(
      opcode: UInt8,
      nextIp: UInt32,
      fi: Int,
      valueStack: inout [Value],
      frames: inout [EmbeddedFrame],
      memory: inout [UInt8],
      globals: inout [Value],
      tables: inout [[Value]],
      droppedData: inout UInt64,
      droppedElem: inout UInt64,
      pushEmbeddedFrame: (Int, Int) throws(WasmError) -> Void,
      handleEmbeddedBranch: (UInt32, Int) throws(WasmError) -> Void
    ) throws(WasmError) {

      // Cursor for reading LEB128 immediates that follow the opcode byte.
      // Starts at nextIp (the byte immediately after the opcode).
      // Each readXxxLocal() advances cursor in-place.
      var cursor = Int(nextIp)

      // Inline immediate readers — index directly into module.rawBytes (a [UInt8]).
      // Using @inline(__always) local functions rather than closures to avoid heap capture.
      // No `inout self` needed: module.rawBytes is a let stored property, readable through
      // the non-mutating self captured by dispatchEmbedded.

      @inline(__always)
      func readByteLocal() throws(WasmError) -> UInt8 {
        guard cursor < module.rawBytes.count else { throw WasmError.unexpectedEnd }
        let b = module.rawBytes[cursor]
        cursor &+= 1
        return b
      }

      @inline(__always)
      func readU32Local() throws(WasmError) -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt = 0
        while true {
          let b = try readByteLocal()
          result |= UInt32(b & 0x7F) << shift
          if b & 0x80 == 0 { return result }
          shift += 7
          if shift >= 35 { throw WasmError.unexpectedEnd }
        }
      }

      @inline(__always)
      func readS32Local() throws(WasmError) -> Int32 {
        var result: Int32 = 0
        var shift = 0
        var byte: UInt8 = 0
        while true {
          byte = try readByteLocal()
          result |= Int32(byte & 0x7F) &<< shift
          shift += 7
          if byte & 0x80 == 0 { break }
          if shift > 35 { throw WasmError.unexpectedEnd }
        }
        if shift < 32 && (byte & 0x40) != 0 { result |= ~Int32(0) &<< shift }
        return result
      }

      @inline(__always)
      func readS64Local() throws(WasmError) -> Int64 {
        var result: Int64 = 0
        var shift = 0
        var byte: UInt8 = 0
        while true {
          byte = try readByteLocal()
          result |= Int64(byte & 0x7F) &<< shift
          shift += 7
          if byte & 0x80 == 0 { break }
          if shift > 70 { throw WasmError.unexpectedEnd }
        }
        if shift < 64 && (byte & 0x40) != 0 { result |= ~Int64(0) &<< shift }
        return result
      }

      @inline(__always)
      func readBlockTypeLocal() throws(WasmError) -> BlockType {
        let raw = try readS32Local()
        if raw >= 0 { return .typeIndex(UInt32(raw)) }
        let byte = UInt8(raw & 0x7F)
        if byte == 0x40 { return .void }
        guard let vt = ValueType(rawValue: byte) else { throw WasmError.invalidValueType(byte) }
        return .value(vt)
      }

      // MARK: Opcode dispatch

      switch opcode {

      // MARK: Control — unreachable / nop

      case 0x00:  // unreachable
        throw WasmError.unreachableReached

      case 0x01:  // nop
        frames[fi].ip = nextIp

      // MARK: Control — block (0x02)

      case 0x02:
        let bt = try readBlockTypeLocal()
        let (brArity, paramCount) = embeddedBlockArity(bt)
        let handle = module.code[frames[fi].handleIdx]
        // Consume the jump table entry for this block opcode (monotonic cursor).
        // entry.instrOffset == byte position of the 0x02 opcode itself.
        let entry = handle.jumpTable[frames[fi].jumpCursor]
        frames[fi].jumpCursor += 1
        // entry.target1 = byte position of first instruction after blockEnd (br-continuation).
        frames[fi].labels.append(
          Label(
            kind: .block,
            stackBase: valueStack.count - paramCount,
            brArity: brArity,
            continuationPc: Int(entry.target1)))
        frames[fi].ip = UInt32(cursor)

      // MARK: Control — loop (0x03)

      case 0x03:
        let bt = try readBlockTypeLocal()
        let loopBrArity = embeddedLoopBrArity(bt)
        let (_, paramCount) = embeddedBlockArity(bt)
        let handle = module.code[frames[fi].handleIdx]
        let entry = handle.jumpTable[frames[fi].jumpCursor]
        frames[fi].jumpCursor += 1
        // entry.target1 = byte position of first instruction in the loop body (br restarts here).
        frames[fi].labels.append(
          Label(
            kind: .loop,
            stackBase: valueStack.count - paramCount,
            brArity: loopBrArity,
            continuationPc: Int(entry.target1)))
        frames[fi].ip = UInt32(cursor)

      // MARK: Control — if (0x04)

      case 0x04:
        let bt = try readBlockTypeLocal()
        let (brArity, paramCount) = embeddedBlockArity(bt)
        let handle = module.code[frames[fi].handleIdx]
        let entry = handle.jumpTable[frames[fi].jumpCursor]
        frames[fi].jumpCursor += 1
        // entry.target1 = byte position of the else clause start (or endPc when no else).
        // entry.target2 = byte position after end (br-continuation); 0 if no else clause.
        // When there is no else, the label continuation = target1 (= endPc).
        let continuationPc = entry.target2 != 0 ? Int(entry.target2) : Int(entry.target1)
        frames[fi].labels.append(
          Label(
            kind: .ifElse,
            stackBase: valueStack.count - paramCount,
            brArity: brArity,
            continuationPc: continuationPc))
        // Pop condition and branch to else-start if false.
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        if cond == 0 {
          // Jump to else clause (or to the end when there is no else).
          let target = entry.target1
          frames[fi].ip = target
          frames[fi].jumpCursor = jumpCursorForIp(
            target, in: module.code[frames[fi].handleIdx].jumpTable)
        } else {
          frames[fi].ip = UInt32(cursor)
        }

      // MARK: Control — else (0x05)

      case 0x05:
        // Reached by normal fall-through from the then-body into the else opcode.
        // Jump to the continuation PC stored in the current (if/else) label, then pop it.
        guard !frames[fi].labels.isEmpty else { throw WasmError.stackUnderflow }
        let contPc = UInt32(frames[fi].labels.removeLast().continuationPc)
        frames[fi].ip = contPc
        frames[fi].jumpCursor = jumpCursorForIp(
          contPc, in: module.code[frames[fi].handleIdx].jumpTable)

      // MARK: Control — end (0x0B)

      case 0x0B:
        if !frames[fi].labels.isEmpty {
          // Normal fall-through exit from block/loop/if: pop the innermost label.
          frames[fi].labels.removeLast()
          frames[fi].ip = nextIp
        } else {
          // Final end of the function body — signal frame done by setting ip past codeEnd.
          let handle = module.code[frames[fi].handleIdx]
          frames[fi].ip = handle.codeOffset &+ handle.codeSize
        }

      // MARK: Control — br (0x0C)

      case 0x0C:
        let depth = try readU32Local()
        // Set ip past the immediate so that handleEmbeddedBranch can overwrite it correctly
        // for the non-early-return path; early-return sets ip to codeEnd anyway.
        frames[fi].ip = UInt32(cursor)
        try handleEmbeddedBranch(depth, fi)

      // MARK: Control — br_if (0x0D)

      case 0x0D:
        let depth = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        if cond != 0 {
          frames[fi].ip = UInt32(cursor)
          try handleEmbeddedBranch(depth, fi)
        } else {
          frames[fi].ip = UInt32(cursor)
        }

      // MARK: Control — br_table (0x0E)

      case 0x0E:
        let count = try readU32Local()
        // TODO: Embedded Phase 5 — replace with a stack-allocated fixed-size buffer.
        var targets: [UInt32] = []
        for _ in 0..<count { targets.append(try readU32Local()) }
        let default_ = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let idx) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ui = UInt32(bitPattern: idx)
        let depth = ui < count ? targets[Int(ui)] : default_
        frames[fi].ip = UInt32(cursor)
        try handleEmbeddedBranch(depth, fi)

      // MARK: Control — return (0x0F)

      case 0x0F:
        let resultCount = frames[fi].resultCount
        let localBase = frames[fi].localBase
        let src = valueStack.count - resultCount
        guard src >= localBase else { throw WasmError.stackUnderflow }
        for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
        valueStack.removeSubrange((localBase + resultCount)...)
        frames[fi].labels.removeAll()
        let handle = module.code[frames[fi].handleIdx]
        frames[fi].ip = handle.codeOffset &+ handle.codeSize

      // MARK: Control — call (0x10)

      case 0x10:
        let funcIdx = try readU32Local()
        let funcType = module.functionType(at: Int(funcIdx))
        let argCount = funcType.params.count
        guard valueStack.count >= argCount else { throw WasmError.stackUnderflow }
        frames[fi].ip = UInt32(cursor)
        try pushEmbeddedFrame(Int(funcIdx), argCount)

      // MARK: Control — call_indirect (0x11)

      case 0x11:
        let typeIdx = try readU32Local()
        let tableIdxOp = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let elemIdx) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let eIdx = Int(elemIdx)
        let ti = Int(tableIdxOp)
        guard ti < tables.count else { throw WasmError.undefinedElement }
        let tbl = tables[ti]
        guard eIdx >= 0 && eIdx < tbl.count else { throw WasmError.undefinedElement }
        guard case .funcref(let optFuncIdx) = tbl[eIdx], let resolvedFuncIdx = optFuncIdx else {
          throw WasmError.undefinedElement
        }
        let expectedType = module.types[Int(typeIdx)]
        let actualType = module.functionType(at: Int(resolvedFuncIdx))
        guard
          expectedType.params.count == actualType.params.count
            && expectedType.results.count == actualType.results.count
        else { throw WasmError.indirectCallTypeMismatch }
        for i in 0..<expectedType.params.count {
          guard expectedType.params[i] == actualType.params[i] else {
            throw WasmError.indirectCallTypeMismatch
          }
        }
        for i in 0..<expectedType.results.count {
          guard expectedType.results[i] == actualType.results[i] else {
            throw WasmError.indirectCallTypeMismatch
          }
        }
        let argCount = expectedType.params.count
        guard valueStack.count >= argCount else { throw WasmError.stackUnderflow }
        frames[fi].ip = UInt32(cursor)
        try pushEmbeddedFrame(Int(resolvedFuncIdx), argCount)

      // MARK: Parametric — drop (0x1A) / select (0x1B)

      case 0x1A:  // drop
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        valueStack.removeLast()
        frames[fi].ip = nextIp

      case 0x1B:  // select
        guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
        guard case .i32(let cond) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let v2 = valueStack.removeLast()
        let v1 = valueStack.removeLast()
        valueStack.append(cond != 0 ? v1 : v2)
        frames[fi].ip = nextIp

      // MARK: Local variables (0x20-0x22)

      case 0x20:  // local.get
        let idx = try readU32Local()
        valueStack.append(valueStack[frames[fi].localBase + Int(idx)])
        frames[fi].ip = UInt32(cursor)

      case 0x21:  // local.set
        let idx = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        valueStack[frames[fi].localBase + Int(idx)] = valueStack.removeLast()
        frames[fi].ip = UInt32(cursor)

      case 0x22:  // local.tee
        let idx = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        valueStack[frames[fi].localBase + Int(idx)] = valueStack.last!
        frames[fi].ip = UInt32(cursor)

      // MARK: Global variables (0x23-0x24)

      case 0x23:  // global.get
        let idx = try readU32Local()
        valueStack.append(globals[Int(idx)])
        frames[fi].ip = UInt32(cursor)

      case 0x24:  // global.set
        let idx = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        globals[Int(idx)] = valueStack.removeLast()
        frames[fi].ip = UInt32(cursor)

      // MARK: Table (0x25-0x26)

      case 0x25:  // table.get
        let tableIdx25 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let idx) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ti25 = Int(tableIdx25)
        guard ti25 < tables.count else { throw WasmError.undefinedElement }
        let i25 = Int(UInt32(bitPattern: idx))
        guard i25 < tables[ti25].count else { throw WasmError.undefinedElement }
        valueStack.append(tables[ti25][i25])
        frames[fi].ip = UInt32(cursor)

      case 0x26:  // table.set
        let tableIdx26 = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        let refVal = valueStack.removeLast()
        guard case .i32(let idx) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ti26 = Int(tableIdx26)
        guard ti26 < tables.count else { throw WasmError.undefinedElement }
        let tableRefType = ti26 < module.tables.count ? module.tables[ti26].refType : .funcRef
        switch (tableRefType, refVal) {
        case (.funcRef, .funcref), (.externRef, .externref): break
        default: throw WasmError.typeMismatch
        }
        let i26 = Int(UInt32(bitPattern: idx))
        guard i26 < tables[ti26].count else { throw WasmError.undefinedElement }
        tables[ti26][i26] = refVal
        frames[fi].ip = UInt32(cursor)

      // MARK: Memory loads (0x28-0x35)

      case 0x28:  // i32.load
        _ = try readU32Local()  // align (ignored)
        let offset28 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea28 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset28)
        guard ea28 + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p28 = Int(ea28)
        let v28 =
          UInt32(memory[p28]) | (UInt32(memory[p28 + 1]) << 8)
          | (UInt32(memory[p28 + 2]) << 16) | (UInt32(memory[p28 + 3]) << 24)
        valueStack.append(.i32(Int32(bitPattern: v28)))
        frames[fi].ip = UInt32(cursor)

      case 0x29:  // i64.load
        _ = try readU32Local()  // align (ignored)
        let offset29 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea29 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset29)
        guard ea29 + 8 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p29 = Int(ea29)
        let v29 =
          UInt64(memory[p29]) | (UInt64(memory[p29 + 1]) << 8)
          | (UInt64(memory[p29 + 2]) << 16) | (UInt64(memory[p29 + 3]) << 24)
          | (UInt64(memory[p29 + 4]) << 32) | (UInt64(memory[p29 + 5]) << 40)
          | (UInt64(memory[p29 + 6]) << 48) | (UInt64(memory[p29 + 7]) << 56)
        valueStack.append(.i64(Int64(bitPattern: v29)))
        frames[fi].ip = UInt32(cursor)

      case 0x2A:  // f32.load
        _ = try readU32Local()  // align (ignored)
        let offset2A = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2A = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2A)
        guard ea2A + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p2A = Int(ea2A)
        let bits2A =
          UInt32(memory[p2A]) | (UInt32(memory[p2A + 1]) << 8)
          | (UInt32(memory[p2A + 2]) << 16) | (UInt32(memory[p2A + 3]) << 24)
        valueStack.append(.f32(Float(bitPattern: bits2A)))
        frames[fi].ip = UInt32(cursor)

      case 0x2B:  // f64.load
        _ = try readU32Local()  // align (ignored)
        let offset2B = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2B = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2B)
        guard ea2B + 8 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p2B = Int(ea2B)
        let bits2B =
          UInt64(memory[p2B]) | (UInt64(memory[p2B + 1]) << 8)
          | (UInt64(memory[p2B + 2]) << 16) | (UInt64(memory[p2B + 3]) << 24)
          | (UInt64(memory[p2B + 4]) << 32) | (UInt64(memory[p2B + 5]) << 40)
          | (UInt64(memory[p2B + 6]) << 48) | (UInt64(memory[p2B + 7]) << 56)
        valueStack.append(.f64(Double(bitPattern: bits2B)))
        frames[fi].ip = UInt32(cursor)

      case 0x2C:  // i32.load8_s
        _ = try readU32Local()  // align (ignored)
        let offset2C = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2C = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2C)
        guard ea2C + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        valueStack.append(.i32(Int32(Int8(bitPattern: memory[Int(ea2C)]))))
        frames[fi].ip = UInt32(cursor)

      case 0x2D:  // i32.load8_u
        _ = try readU32Local()  // align (ignored)
        let offset2D = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2D = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2D)
        guard ea2D + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        valueStack.append(.i32(Int32(memory[Int(ea2D)])))
        frames[fi].ip = UInt32(cursor)

      case 0x2E:  // i32.load16_s
        _ = try readU32Local()  // align (ignored)
        let offset2E = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2E = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2E)
        guard ea2E + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p2E = Int(ea2E)
        let raw2E = UInt16(memory[p2E]) | (UInt16(memory[p2E + 1]) << 8)
        valueStack.append(.i32(Int32(Int16(bitPattern: raw2E))))
        frames[fi].ip = UInt32(cursor)

      case 0x2F:  // i32.load16_u
        _ = try readU32Local()  // align (ignored)
        let offset2F = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea2F = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2F)
        guard ea2F + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p2F = Int(ea2F)
        let raw2F = UInt16(memory[p2F]) | (UInt16(memory[p2F + 1]) << 8)
        valueStack.append(.i32(Int32(raw2F)))
        frames[fi].ip = UInt32(cursor)

      case 0x30:  // i64.load8_s
        _ = try readU32Local()  // align (ignored)
        let offset30 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea30 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset30)
        guard ea30 + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        valueStack.append(.i64(Int64(Int8(bitPattern: memory[Int(ea30)]))))
        frames[fi].ip = UInt32(cursor)

      case 0x31:  // i64.load8_u
        _ = try readU32Local()  // align (ignored)
        let offset31 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea31 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset31)
        guard ea31 + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        valueStack.append(.i64(Int64(memory[Int(ea31)])))
        frames[fi].ip = UInt32(cursor)

      case 0x32:  // i64.load16_s
        _ = try readU32Local()  // align (ignored)
        let offset32 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea32 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset32)
        guard ea32 + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p32 = Int(ea32)
        let raw32 = UInt16(memory[p32]) | (UInt16(memory[p32 + 1]) << 8)
        valueStack.append(.i64(Int64(Int16(bitPattern: raw32))))
        frames[fi].ip = UInt32(cursor)

      case 0x33:  // i64.load16_u
        _ = try readU32Local()  // align (ignored)
        let offset33 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea33 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset33)
        guard ea33 + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p33 = Int(ea33)
        let raw33 = UInt16(memory[p33]) | (UInt16(memory[p33 + 1]) << 8)
        valueStack.append(.i64(Int64(raw33)))
        frames[fi].ip = UInt32(cursor)

      case 0x34:  // i64.load32_s
        _ = try readU32Local()  // align (ignored)
        let offset34 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea34 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset34)
        guard ea34 + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p34 = Int(ea34)
        let raw34 =
          UInt32(memory[p34]) | (UInt32(memory[p34 + 1]) << 8)
          | (UInt32(memory[p34 + 2]) << 16) | (UInt32(memory[p34 + 3]) << 24)
        valueStack.append(.i64(Int64(Int32(bitPattern: raw34))))
        frames[fi].ip = UInt32(cursor)

      case 0x35:  // i64.load32_u
        _ = try readU32Local()  // align (ignored)
        let offset35 = try readU32Local()
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea35 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset35)
        guard ea35 + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p35 = Int(ea35)
        let raw35 =
          UInt32(memory[p35]) | (UInt32(memory[p35 + 1]) << 8)
          | (UInt32(memory[p35 + 2]) << 16) | (UInt32(memory[p35 + 3]) << 24)
        valueStack.append(.i64(Int64(raw35)))
        frames[fi].ip = UInt32(cursor)

      // MARK: Memory stores (0x36-0x3E)

      case 0x36:  // i32.store
        _ = try readU32Local()  // align (ignored)
        let offset36 = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea36 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset36)
        guard ea36 + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p36 = Int(ea36)
        let u36 = UInt32(bitPattern: value)
        memory[p36] = UInt8(u36 & 0xFF)
        memory[p36 + 1] = UInt8((u36 >> 8) & 0xFF)
        memory[p36 + 2] = UInt8((u36 >> 16) & 0xFF)
        memory[p36 + 3] = UInt8((u36 >> 24) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x37:  // i64.store
        _ = try readU32Local()  // align (ignored)
        let offset37 = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea37 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset37)
        guard ea37 + 8 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p37 = Int(ea37)
        let u37 = UInt64(bitPattern: value)
        memory[p37] = UInt8(u37 & 0xFF)
        memory[p37 + 1] = UInt8((u37 >> 8) & 0xFF)
        memory[p37 + 2] = UInt8((u37 >> 16) & 0xFF)
        memory[p37 + 3] = UInt8((u37 >> 24) & 0xFF)
        memory[p37 + 4] = UInt8((u37 >> 32) & 0xFF)
        memory[p37 + 5] = UInt8((u37 >> 40) & 0xFF)
        memory[p37 + 6] = UInt8((u37 >> 48) & 0xFF)
        memory[p37 + 7] = UInt8((u37 >> 56) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x38:  // f32.store
        _ = try readU32Local()  // align (ignored)
        let offset38 = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea38 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset38)
        guard ea38 + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p38 = Int(ea38)
        let u38 = value.bitPattern
        memory[p38] = UInt8(u38 & 0xFF)
        memory[p38 + 1] = UInt8((u38 >> 8) & 0xFF)
        memory[p38 + 2] = UInt8((u38 >> 16) & 0xFF)
        memory[p38 + 3] = UInt8((u38 >> 24) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x39:  // f64.store
        _ = try readU32Local()  // align (ignored)
        let offset39 = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea39 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset39)
        guard ea39 + 8 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p39 = Int(ea39)
        let u39 = value.bitPattern
        memory[p39] = UInt8(u39 & 0xFF)
        memory[p39 + 1] = UInt8((u39 >> 8) & 0xFF)
        memory[p39 + 2] = UInt8((u39 >> 16) & 0xFF)
        memory[p39 + 3] = UInt8((u39 >> 24) & 0xFF)
        memory[p39 + 4] = UInt8((u39 >> 32) & 0xFF)
        memory[p39 + 5] = UInt8((u39 >> 40) & 0xFF)
        memory[p39 + 6] = UInt8((u39 >> 48) & 0xFF)
        memory[p39 + 7] = UInt8((u39 >> 56) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x3A:  // i32.store8
        _ = try readU32Local()  // align (ignored)
        let offset3A = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea3A = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3A)
        guard ea3A + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        memory[Int(ea3A)] = UInt8(UInt32(bitPattern: value) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x3B:  // i32.store16
        _ = try readU32Local()  // align (ignored)
        let offset3B = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea3B = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3B)
        guard ea3B + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p3B = Int(ea3B)
        let u3B = UInt32(bitPattern: value)
        memory[p3B] = UInt8(u3B & 0xFF)
        memory[p3B + 1] = UInt8((u3B >> 8) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x3C:  // i64.store8
        _ = try readU32Local()  // align (ignored)
        let offset3C = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea3C = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3C)
        guard ea3C + 1 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        memory[Int(ea3C)] = UInt8(UInt64(bitPattern: value) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x3D:  // i64.store16
        _ = try readU32Local()  // align (ignored)
        let offset3D = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea3D = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3D)
        guard ea3D + 2 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p3D = Int(ea3D)
        let u3D = UInt64(bitPattern: value)
        memory[p3D] = UInt8(u3D & 0xFF)
        memory[p3D + 1] = UInt8((u3D >> 8) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      case 0x3E:  // i64.store32
        _ = try readU32Local()  // align (ignored)
        let offset3E = try readU32Local()
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let value) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard case .i32(let addr) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let ea3E = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3E)
        guard ea3E + 4 <= UInt64(memory.count) else { throw WasmError.memoryAccessOutOfBounds }
        let p3E = Int(ea3E)
        let u3E = UInt64(bitPattern: value)
        memory[p3E] = UInt8(u3E & 0xFF)
        memory[p3E + 1] = UInt8((u3E >> 8) & 0xFF)
        memory[p3E + 2] = UInt8((u3E >> 16) & 0xFF)
        memory[p3E + 3] = UInt8((u3E >> 24) & 0xFF)
        frames[fi].ip = UInt32(cursor)

      // MARK: memory.size / memory.grow (0x3F-0x40)

      case 0x3F:  // memory.size
        _ = try readByteLocal()  // reserved byte (must be 0x00)
        let pages3F = Int32(memory.count / 65536)
        valueStack.append(.i32(pages3F))
        frames[fi].ip = UInt32(cursor)

      case 0x40:  // memory.grow
        _ = try readByteLocal()  // reserved byte (must be 0x00)
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let delta) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        let pageSize40 = 65536
        let oldPages40 = memory.count / pageSize40
        let oldPagesI32_40 = Int32(oldPages40)
        // Treat delta as unsigned: a negative i32 bit pattern becomes a huge u32 value.
        let n40 = Int(UInt32(bitPattern: delta))
        let newByteCount40 = UInt64(n40) * UInt64(pageSize40)
        let newPages40 = oldPages40 + n40
        let memMax40: UInt32? = module.memories.first?.max
        let exceedsMax40: Bool
        if let maxPages = memMax40 {
          exceedsMax40 = newPages40 > Int(maxPages)
        } else {
          // No declared max: Wasm spec hard-limits to 65536 pages (4 GiB).
          exceedsMax40 = newPages40 > 65536
        }
        // newByteCount40 > Int.max means the allocation would overflow Int on 32-bit targets.
        if newByteCount40 > UInt64(Int.max) || exceedsMax40 {
          valueStack.append(.i32(-1))
        } else {
          memory.append(contentsOf: repeatElement(0, count: Int(newByteCount40)))
          valueStack.append(.i32(oldPagesI32_40))
        }
        frames[fi].ip = UInt32(cursor)

      // MARK: Constants (0x41-0x44)

      case 0x41:  // i32.const
        let value = try readS32Local()
        valueStack.append(.i32(value))
        frames[fi].ip = UInt32(cursor)

      case 0x42:  // i64.const
        let value = try readS64Local()
        valueStack.append(.i64(value))
        frames[fi].ip = UInt32(cursor)

      case 0x43:  // f32.const  (4 raw bytes LE — IEEE 754 bit pattern)
        let b0_43 = UInt32(try readByteLocal())
        let b1_43 = UInt32(try readByteLocal())
        let b2_43 = UInt32(try readByteLocal())
        let b3_43 = UInt32(try readByteLocal())
        valueStack.append(
          .f32(Float(bitPattern: b0_43 | (b1_43 << 8) | (b2_43 << 16) | (b3_43 << 24))))
        frames[fi].ip = UInt32(cursor)

      case 0x44:  // f64.const  (8 raw bytes LE — IEEE 754 bit pattern)
        let c0_44 = UInt64(try readByteLocal())
        let c1_44 = UInt64(try readByteLocal())
        let c2_44 = UInt64(try readByteLocal())
        let c3_44 = UInt64(try readByteLocal())
        let c4_44 = UInt64(try readByteLocal())
        let c5_44 = UInt64(try readByteLocal())
        let c6_44 = UInt64(try readByteLocal())
        let c7_44 = UInt64(try readByteLocal())
        let bits44 =
          c0_44 | (c1_44 << 8) | (c2_44 << 16) | (c3_44 << 24) | (c4_44 << 32) | (c5_44 << 40)
          | (c6_44 << 48) | (c7_44 << 56)
        valueStack.append(.f64(Double(bitPattern: bits44)))
        frames[fi].ip = UInt32(cursor)

      // MARK: i32 comparisons (0x45-0x4F)

      case 0x45:  // i32.eqz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == 0 ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x46:  // i32.eq
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x47:  // i32.ne
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x48:  // i32.lt_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x49:  // i32.lt_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) < UInt32(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4A:  // i32.gt_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4B:  // i32.gt_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) > UInt32(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4C:  // i32.le_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4D:  // i32.le_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) <= UInt32(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4E:  // i32.ge_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x4F:  // i32.ge_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt32(bitPattern: a) >= UInt32(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      // MARK: i64 comparisons (0x50-0x5A)

      case 0x50:  // i64.eqz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == 0 ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x51:  // i64.eq
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x52:  // i64.ne
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x53:  // i64.lt_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x54:  // i64.lt_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) < UInt64(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x55:  // i64.gt_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x56:  // i64.gt_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) > UInt64(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x57:  // i64.le_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x58:  // i64.le_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) <= UInt64(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x59:  // i64.ge_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x5A:  // i64.ge_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(UInt64(bitPattern: a) >= UInt64(bitPattern: b) ? 1 : 0))
        frames[fi].ip = nextIp

      // MARK: f32 comparisons (0x5B-0x60)

      case 0x5B:  // f32.eq
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x5C:  // f32.ne
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x5D:  // f32.lt
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x5E:  // f32.gt
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x5F:  // f32.le
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x60:  // f32.ge
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))
        frames[fi].ip = nextIp

      // MARK: f64 comparisons (0x61-0x66)

      case 0x61:  // f64.eq
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a == b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x62:  // f64.ne
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a != b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x63:  // f64.lt
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a < b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x64:  // f64.gt
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a > b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x65:  // f64.le
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a <= b ? 1 : 0))
        frames[fi].ip = nextIp

      case 0x66:  // f64.ge
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a >= b ? 1 : 0))
        frames[fi].ip = nextIp

      // MARK: i32 unary / arithmetic / bitwise (0x67-0x78)

      case 0x67:  // i32.clz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).leadingZeroBitCount)))
        frames[fi].ip = nextIp

      case 0x68:  // i32.ctz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).trailingZeroBitCount)))
        frames[fi].ip = nextIp

      case 0x69:  // i32.popcnt
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(UInt32(bitPattern: a).nonzeroBitCount)))
        frames[fi].ip = nextIp

      case 0x6A:  // i32.add
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a &+ b))
        frames[fi].ip = nextIp

      case 0x6B:  // i32.sub
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a &- b))
        frames[fi].ip = nextIp

      case 0x6C:  // i32.mul
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a &* b))
        frames[fi].ip = nextIp

      case 0x6D:  // i32.div_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        guard !(a == Int32.min && b == -1) else { throw WasmError.integerOverflow }
        valueStack.append(.i32(a / b))
        frames[fi].ip = nextIp

      case 0x6E:  // i32.div_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) / UInt32(bitPattern: b))))
        frames[fi].ip = nextIp

      case 0x6F:  // i32.rem_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i32(a == Int32.min && b == -1 ? 0 : a % b))
        frames[fi].ip = nextIp

      case 0x70:  // i32.rem_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) % UInt32(bitPattern: b))))
        frames[fi].ip = nextIp

      case 0x71:  // i32.and
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a & b))
        frames[fi].ip = nextIp

      case 0x72:  // i32.or
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a | b))
        frames[fi].ip = nextIp

      case 0x73:  // i32.xor
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i32(a ^ b))
        frames[fi].ip = nextIp

      case 0x74:  // i32.shl
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift74 = UInt32(bitPattern: b) & 31
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) << shift74)))
        frames[fi].ip = nextIp

      case 0x75:  // i32.shr_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift75 = Int32(UInt32(bitPattern: b) & 31)
        valueStack.append(.i32(a >> shift75))
        frames[fi].ip = nextIp

      case 0x76:  // i32.shr_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift76 = UInt32(bitPattern: b) & 31
        valueStack.append(.i32(Int32(bitPattern: UInt32(bitPattern: a) >> shift76)))
        frames[fi].ip = nextIp

      case 0x77:  // i32.rotl
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift77 = UInt32(bitPattern: b) & 31
        let ua77 = UInt32(bitPattern: a)
        let result77 = shift77 == 0 ? ua77 : (ua77 << shift77 | ua77 >> (32 - shift77))
        valueStack.append(.i32(Int32(bitPattern: result77)))
        frames[fi].ip = nextIp

      case 0x78:  // i32.rotr
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i32(let b) = valueStack.removeLast(),
          case .i32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift78 = UInt32(bitPattern: b) & 31
        let ua78 = UInt32(bitPattern: a)
        let result78 = shift78 == 0 ? ua78 : (ua78 >> shift78 | ua78 << (32 - shift78))
        valueStack.append(.i32(Int32(bitPattern: result78)))
        frames[fi].ip = nextIp

      // MARK: i64 unary / arithmetic / bitwise (0x79-0x8A)

      case 0x79:  // i64.clz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).leadingZeroBitCount)))
        frames[fi].ip = nextIp

      case 0x7A:  // i64.ctz
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).trailingZeroBitCount)))
        frames[fi].ip = nextIp

      case 0x7B:  // i64.popcnt
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(UInt64(bitPattern: a).nonzeroBitCount)))
        frames[fi].ip = nextIp

      case 0x7C:  // i64.add
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a &+ b))
        frames[fi].ip = nextIp

      case 0x7D:  // i64.sub
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a &- b))
        frames[fi].ip = nextIp

      case 0x7E:  // i64.mul
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a &* b))
        frames[fi].ip = nextIp

      case 0x7F:  // i64.div_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        guard !(a == Int64.min && b == -1) else { throw WasmError.integerOverflow }
        valueStack.append(.i64(a / b))
        frames[fi].ip = nextIp

      case 0x80:  // i64.div_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) / UInt64(bitPattern: b))))
        frames[fi].ip = nextIp

      case 0x81:  // i64.rem_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i64(a == Int64.min && b == -1 ? 0 : a % b))
        frames[fi].ip = nextIp

      case 0x82:  // i64.rem_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        guard b != 0 else { throw WasmError.divisionByZero }
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) % UInt64(bitPattern: b))))
        frames[fi].ip = nextIp

      case 0x83:  // i64.and
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a & b))
        frames[fi].ip = nextIp

      case 0x84:  // i64.or
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a | b))
        frames[fi].ip = nextIp

      case 0x85:  // i64.xor
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.i64(a ^ b))
        frames[fi].ip = nextIp

      case 0x86:  // i64.shl
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift86 = UInt64(bitPattern: b) & 63
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) << shift86)))
        frames[fi].ip = nextIp

      case 0x87:  // i64.shr_s
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift87 = Int64(UInt64(bitPattern: b) & 63)
        valueStack.append(.i64(a >> shift87))
        frames[fi].ip = nextIp

      case 0x88:  // i64.shr_u
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift88 = UInt64(bitPattern: b) & 63
        valueStack.append(.i64(Int64(bitPattern: UInt64(bitPattern: a) >> shift88)))
        frames[fi].ip = nextIp

      case 0x89:  // i64.rotl
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift89 = UInt64(bitPattern: b) & 63
        let ua89 = UInt64(bitPattern: a)
        let result89 = shift89 == 0 ? ua89 : (ua89 << shift89 | ua89 >> (64 - shift89))
        valueStack.append(.i64(Int64(bitPattern: result89)))
        frames[fi].ip = nextIp

      case 0x8A:  // i64.rotr
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .i64(let b) = valueStack.removeLast(),
          case .i64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        let shift8A = UInt64(bitPattern: b) & 63
        let ua8A = UInt64(bitPattern: a)
        let result8A = shift8A == 0 ? ua8A : (ua8A >> shift8A | ua8A << (64 - shift8A))
        valueStack.append(.i64(Int64(bitPattern: result8A)))
        frames[fi].ip = nextIp

      // MARK: f32 unary / arithmetic (0x8B-0x98)

      case 0x8B:  // f32.abs
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.magnitude))
        frames[fi].ip = nextIp

      case 0x8C:  // f32.neg
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(-a))
        frames[fi].ip = nextIp

      case 0x8D:  // f32.ceil
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.rounded(.up)))
        frames[fi].ip = nextIp

      case 0x8E:  // f32.floor
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.rounded(.down)))
        frames[fi].ip = nextIp

      case 0x8F:  // f32.trunc
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.rounded(.towardZero)))
        frames[fi].ip = nextIp

      case 0x90:  // f32.nearest
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.rounded(.toNearestOrEven)))
        frames[fi].ip = nextIp

      case 0x91:  // f32.sqrt
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a.squareRoot()))
        frames[fi].ip = nextIp

      case 0x92:  // f32.add
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a + b))
        frames[fi].ip = nextIp

      case 0x93:  // f32.sub
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a - b))
        frames[fi].ip = nextIp

      case 0x94:  // f32.mul
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a * b))
        frames[fi].ip = nextIp

      case 0x95:  // f32.div
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f32(a / b))
        frames[fi].ip = nextIp

      case 0x96:  // f32.min
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        // Wasm f32.min: propagates NaN; treats -0 < +0
        let min96: Float
        if a.isNaN || b.isNaN {
          min96 = .nan
        } else if a == 0 && b == 0 {
          min96 = (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0
        } else {
          min96 = a < b ? a : b
        }
        valueStack.append(.f32(min96))
        frames[fi].ip = nextIp

      case 0x97:  // f32.max
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        // Wasm f32.max: propagates NaN; treats +0 > -0
        let max97: Float
        if a.isNaN || b.isNaN {
          max97 = .nan
        } else if a == 0 && b == 0 {
          max97 = (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0
        } else {
          max97 = a > b ? a : b
        }
        valueStack.append(.f32(max97))
        frames[fi].ip = nextIp

      case 0x98:  // f32.copysign
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f32(let b) = valueStack.removeLast(),
          case .f32(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(signOf: b, magnitudeOf: a)))
        frames[fi].ip = nextIp

      // MARK: f64 unary / arithmetic (0x99-0xA6)

      case 0x99:  // f64.abs
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.magnitude))
        frames[fi].ip = nextIp

      case 0x9A:  // f64.neg
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(-a))
        frames[fi].ip = nextIp

      case 0x9B:  // f64.ceil
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.rounded(.up)))
        frames[fi].ip = nextIp

      case 0x9C:  // f64.floor
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.rounded(.down)))
        frames[fi].ip = nextIp

      case 0x9D:  // f64.trunc
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.rounded(.towardZero)))
        frames[fi].ip = nextIp

      case 0x9E:  // f64.nearest
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.rounded(.toNearestOrEven)))
        frames[fi].ip = nextIp

      case 0x9F:  // f64.sqrt
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a.squareRoot()))
        frames[fi].ip = nextIp

      case 0xA0:  // f64.add
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a + b))
        frames[fi].ip = nextIp

      case 0xA1:  // f64.sub
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a - b))
        frames[fi].ip = nextIp

      case 0xA2:  // f64.mul
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f64(a * b))
        frames[fi].ip = nextIp

      case 0xA3:  // f64.div
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        // f64.div follows IEEE 754: division by zero yields ±infinity, not a trap.
        valueStack.append(.f64(a / b))
        frames[fi].ip = nextIp

      case 0xA4:  // f64.min
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        // Wasm f64.min: propagates NaN; treats -0 < +0
        let minA4: Double
        if a.isNaN || b.isNaN {
          minA4 = .nan
        } else if a == 0 && b == 0 {
          minA4 = (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0
        } else {
          minA4 = a < b ? a : b
        }
        valueStack.append(.f64(minA4))
        frames[fi].ip = nextIp

      case 0xA5:  // f64.max
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        // Wasm f64.max: propagates NaN; treats +0 > -0
        let maxA5: Double
        if a.isNaN || b.isNaN {
          maxA5 = .nan
        } else if a == 0 && b == 0 {
          maxA5 = (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0
        } else {
          maxA5 = a > b ? a : b
        }
        valueStack.append(.f64(maxA5))
        frames[fi].ip = nextIp

      case 0xA6:  // f64.copysign
        guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
        guard case .f64(let b) = valueStack.removeLast(),
          case .f64(let a) = valueStack.removeLast()
        else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(signOf: b, magnitudeOf: a)))
        frames[fi].ip = nextIp

      // MARK: Conversion instructions (0xA7-0xC4)

      case 0xA7:  // i32.wrap_i64 — keep lower 32 bits of i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(truncatingIfNeeded: a)))
        frames[fi].ip = nextIp

      case 0xA8:  // i32.trunc_f32_s — f32 → signed i32; traps on NaN, Inf, out-of-range
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a >= -2_147_483_648.0 && a < 2_147_483_648.0
        else { throw WasmError.invalidConversionToInteger }
        valueStack.append(.i32(Int32(a)))
        frames[fi].ip = nextIp

      case 0xA9:  // i32.trunc_f32_u — f32 → unsigned i32; values in (-1,0) truncate to 0
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a > -1.0 && a < 4_294_967_296.0 else { throw WasmError.invalidConversionToInteger }
        let u32A9: UInt32 = a < 0.0 ? 0 : UInt32(a)
        valueStack.append(.i32(Int32(bitPattern: u32A9)))
        frames[fi].ip = nextIp

      case 0xAA:  // i32.trunc_f64_s — f64 → signed i32; values in (-2147483649,-2147483648] are valid
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a > -2_147_483_649.0 && a < 2_147_483_648.0
        else { throw WasmError.invalidConversionToInteger }
        valueStack.append(.i32(Int32(a)))
        frames[fi].ip = nextIp

      case 0xAB:  // i32.trunc_f64_u — f64 → unsigned i32; values in (-1,0) truncate to 0
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a > -1.0 && a < 4_294_967_296.0 else { throw WasmError.invalidConversionToInteger }
        let u32AB: UInt32 = a < 0.0 ? 0 : UInt32(a)
        valueStack.append(.i32(Int32(bitPattern: u32AB)))
        frames[fi].ip = nextIp

      case 0xAC:  // i64.extend_i32_s — sign-extend i32 to i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(a)))
        frames[fi].ip = nextIp

      case 0xAD:  // i64.extend_i32_u — zero-extend i32 to i64 (treat i32 as UInt32)
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(UInt32(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xAE:  // i64.trunc_f32_s — f32 → signed i64; -2^63 is exactly representable in f32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a >= -9_223_372_036_854_775_808.0 && a < 9_223_372_036_854_775_808.0
        else { throw WasmError.invalidConversionToInteger }
        valueStack.append(.i64(Int64(a)))
        frames[fi].ip = nextIp

      case 0xAF:  // i64.trunc_f32_u — f32 → unsigned i64; values in (-1,0) truncate to 0
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a > -1.0 && a < 18_446_744_073_709_551_616.0
        else { throw WasmError.invalidConversionToInteger }
        let u64AF: UInt64 = a < 0.0 ? 0 : UInt64(a)
        valueStack.append(.i64(Int64(bitPattern: u64AF)))
        frames[fi].ip = nextIp

      case 0xB0:  // i64.trunc_f64_s — f64 → signed i64; lower bound -2^63 is exactly representable
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a >= -9_223_372_036_854_775_808.0 && a < 9_223_372_036_854_775_808.0
        else { throw WasmError.invalidConversionToInteger }
        valueStack.append(.i64(Int64(a)))
        frames[fi].ip = nextIp

      case 0xB1:  // i64.trunc_f64_u — f64 → unsigned i64; values in (-1,0) truncate to 0
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        guard !a.isNaN && !a.isInfinite else { throw WasmError.invalidConversionToInteger }
        guard a > -1.0 && a < 18_446_744_073_709_551_616.0
        else { throw WasmError.invalidConversionToInteger }
        let u64B1: UInt64 = a < 0.0 ? 0 : UInt64(a)
        valueStack.append(.i64(Int64(bitPattern: u64B1)))
        frames[fi].ip = nextIp

      case 0xB2:  // f32.convert_i32_s — signed i32 to f32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(a)))
        frames[fi].ip = nextIp

      case 0xB3:  // f32.convert_i32_u — unsigned i32 (stored as signed i32) to f32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(UInt32(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xB4:  // f32.convert_i64_s — signed i64 to f32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(a)))
        frames[fi].ip = nextIp

      case 0xB5:  // f32.convert_i64_u — unsigned i64 (stored as signed i64) to f32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(UInt64(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xB6:  // f32.demote_f64 — reduce f64 to f32 (may lose precision; NaN/Inf preserved)
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(a)))
        frames[fi].ip = nextIp

      case 0xB7:  // f64.convert_i32_s — signed i32 to f64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(a)))
        frames[fi].ip = nextIp

      case 0xB8:  // f64.convert_i32_u — unsigned i32 (stored as signed i32) to f64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(UInt32(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xB9:  // f64.convert_i64_s — signed i64 to f64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(a)))
        frames[fi].ip = nextIp

      case 0xBA:  // f64.convert_i64_u — unsigned i64 (stored as signed i64) to f64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(UInt64(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xBB:  // f64.promote_f32 — extend f32 to f64 (exact; NaN/Inf preserved)
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(a)))
        frames[fi].ip = nextIp

      case 0xBC:  // i32.reinterpret_f32 — reinterpret IEEE 754 bit pattern of f32 as i32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(bitPattern: a.bitPattern)))
        frames[fi].ip = nextIp

      case 0xBD:  // i64.reinterpret_f64 — reinterpret IEEE 754 bit pattern of f64 as i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(bitPattern: a.bitPattern)))
        frames[fi].ip = nextIp

      case 0xBE:  // f32.reinterpret_i32 — reinterpret i32 bits as f32 IEEE 754 value
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f32(Float(bitPattern: UInt32(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xBF:  // f64.reinterpret_i64 — reinterpret i64 bits as f64 IEEE 754 value
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.f64(Double(bitPattern: UInt64(bitPattern: a))))
        frames[fi].ip = nextIp

      case 0xC0:  // i32.extend8_s — sign-extend low 8 bits of i32 to full i32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(Int8(bitPattern: UInt8(a & 0xFF)))))
        frames[fi].ip = nextIp

      case 0xC1:  // i32.extend16_s — sign-extend low 16 bits of i32 to full i32
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i32(Int32(Int16(bitPattern: UInt16(a & 0xFFFF)))))
        frames[fi].ip = nextIp

      case 0xC2:  // i64.extend8_s — sign-extend low 8 bits of i64 to full i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(Int8(bitPattern: UInt8(a & 0xFF)))))
        frames[fi].ip = nextIp

      case 0xC3:  // i64.extend16_s — sign-extend low 16 bits of i64 to full i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(Int16(bitPattern: UInt16(a & 0xFFFF)))))
        frames[fi].ip = nextIp

      case 0xC4:  // i64.extend32_s — sign-extend low 32 bits of i64 to full i64
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        guard case .i64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
        valueStack.append(.i64(Int64(Int32(bitPattern: UInt32(a & 0xFFFF_FFFF)))))
        frames[fi].ip = nextIp

      // MARK: Reference instructions (0xD0-0xD2)

      case 0xD0:  // ref.null  immediate: reftype (1 byte: 0x70=funcref, 0x6F=externref)
        let refTypeByte = try readByteLocal()
        switch refTypeByte {
        case 0x70: valueStack.append(.funcref(nil))
        case 0x6F: valueStack.append(.externref(nil))
        default: throw WasmError.invalidValueType(refTypeByte)
        }
        frames[fi].ip = UInt32(cursor)

      case 0xD1:  // ref.is_null  no immediate
        // Pops any reference type; pushes 1 if null, 0 if non-null.
        guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
        switch valueStack.removeLast() {
        case .funcref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
        case .externref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
        default: throw WasmError.typeMismatch
        }
        frames[fi].ip = nextIp

      case 0xD2:  // ref.func  immediate: funcIdx (u32)
        // Pushes a non-null funcref for the given function index.
        let funcIdxD2 = try readU32Local()
        let totalFunctions = module.importedFunctionCount + module.functions.count
        guard Int(funcIdxD2) < totalFunctions else { throw WasmError.functionNotFound }
        valueStack.append(.funcref(funcIdxD2))
        frames[fi].ip = UInt32(cursor)

      // MARK: 0xFC prefix — saturating trunc + bulk memory + table ops

      case 0xFC:
        let subOpcode = try readU32Local()
        switch subOpcode {

        // --- saturating truncation (sub-opcodes 0-7, no further immediates) ---

        case 0:  // i32.trunc_sat_f32_s
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC0: Int32
          if a.isNaN {
            satFC0 = 0
          } else if a < -2_147_483_648.0 {
            satFC0 = Int32.min
          } else if a >= 2_147_483_648.0 {
            satFC0 = Int32.max
          } else {
            satFC0 = Int32(a)
          }
          valueStack.append(.i32(satFC0))
          frames[fi].ip = UInt32(cursor)

        case 1:  // i32.trunc_sat_f32_u
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC1: UInt32
          if a.isNaN || a < 0.0 {
            satFC1 = 0
          } else if a >= 4_294_967_296.0 {
            satFC1 = UInt32.max
          } else {
            satFC1 = UInt32(a)
          }
          valueStack.append(.i32(Int32(bitPattern: satFC1)))
          frames[fi].ip = UInt32(cursor)

        case 2:  // i32.trunc_sat_f64_s
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC2: Int32
          if a.isNaN {
            satFC2 = 0
          } else if a < -2_147_483_648.0 {
            satFC2 = Int32.min
          } else if a >= 2_147_483_648.0 {
            satFC2 = Int32.max
          } else {
            satFC2 = Int32(a)
          }
          valueStack.append(.i32(satFC2))
          frames[fi].ip = UInt32(cursor)

        case 3:  // i32.trunc_sat_f64_u
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC3: UInt32
          if a.isNaN || a < 0.0 {
            satFC3 = 0
          } else if a >= 4_294_967_296.0 {
            satFC3 = UInt32.max
          } else {
            satFC3 = UInt32(a)
          }
          valueStack.append(.i32(Int32(bitPattern: satFC3)))
          frames[fi].ip = UInt32(cursor)

        case 4:  // i64.trunc_sat_f32_s
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC4: Int64
          if a.isNaN {
            satFC4 = 0
          } else if a < -9_223_372_036_854_775_808.0 {
            satFC4 = Int64.min
          } else if a >= 9_223_372_036_854_775_808.0 {
            satFC4 = Int64.max
          } else {
            satFC4 = Int64(a)
          }
          valueStack.append(.i64(satFC4))
          frames[fi].ip = UInt32(cursor)

        case 5:  // i64.trunc_sat_f32_u
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f32(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC5: UInt64
          if a.isNaN || a < 0.0 {
            satFC5 = 0
          } else if a >= 18_446_744_073_709_551_616.0 {
            satFC5 = UInt64.max
          } else {
            satFC5 = UInt64(a)
          }
          valueStack.append(.i64(Int64(bitPattern: satFC5)))
          frames[fi].ip = UInt32(cursor)

        case 6:  // i64.trunc_sat_f64_s
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC6: Int64
          if a.isNaN {
            satFC6 = 0
          } else if a < -9_223_372_036_854_775_808.0 {
            satFC6 = Int64.min
          } else if a >= 9_223_372_036_854_775_808.0 {
            satFC6 = Int64.max
          } else {
            satFC6 = Int64(a)
          }
          valueStack.append(.i64(satFC6))
          frames[fi].ip = UInt32(cursor)

        case 7:  // i64.trunc_sat_f64_u
          guard !valueStack.isEmpty else { throw WasmError.stackUnderflow }
          guard case .f64(let a) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let satFC7: UInt64
          if a.isNaN || a < 0.0 {
            satFC7 = 0
          } else if a >= 18_446_744_073_709_551_616.0 {
            satFC7 = UInt64.max
          } else {
            satFC7 = UInt64(a)
          }
          valueStack.append(.i64(Int64(bitPattern: satFC7)))
          frames[fi].ip = UInt32(cursor)

        // --- bulk memory operations ---

        case 8:  // memory.init  immediates: dataidx (u32), reserved u32 (must be 0)
          let segIdxFC8 = try readU32Local()
          _ = try readU32Local()  // reserved (ignored)
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let src) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let siFC8 = Int(segIdxFC8)
          guard siFC8 < module.data.count else { throw WasmError.memoryAccessOutOfBounds }
          let copyCountFC8 = Int(UInt32(bitPattern: n))
          let srcOffFC8 = Int(UInt32(bitPattern: src))
          let dstOffFC8 = Int(UInt32(bitPattern: dst))
          // A dropped segment has effective length 0.
          let segLenFC8 =
            droppedData & (UInt64(1) << siFC8) != 0 ? 0 : module.data[siFC8].bytes.count
          // Bounds check: applied unconditionally (n=0 with out-of-range src/dst still traps).
          guard srcOffFC8 + copyCountFC8 <= segLenFC8 else {
            throw WasmError.memoryAccessOutOfBounds
          }
          guard dstOffFC8 + copyCountFC8 <= memory.count else {
            throw WasmError.memoryAccessOutOfBounds
          }
          if copyCountFC8 > 0 {
            let segBytes = module.data[siFC8].bytes
            for i in 0..<copyCountFC8 {
              memory[dstOffFC8 + i] = segBytes[srcOffFC8 + i]
            }
          }
          frames[fi].ip = UInt32(cursor)

        case 9:  // data.drop  immediate: dataidx (u32)
          let segIdxFC9 = try readU32Local()
          let siFC9 = Int(segIdxFC9)
          guard siFC9 < module.data.count else { throw WasmError.memoryAccessOutOfBounds }
          droppedData |= UInt64(1) << siFC9
          frames[fi].ip = UInt32(cursor)

        case 10:  // memory.copy  immediates: dst_memidx (u32=0), src_memidx (u32=0)
          _ = try readU32Local()  // dst memory index (reserved, must be 0)
          _ = try readU32Local()  // src memory index (reserved, must be 0)
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let src) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let copyCountFC10 = Int(UInt32(bitPattern: n))
          let srcOffFC10 = Int(UInt32(bitPattern: src))
          let dstOffFC10 = Int(UInt32(bitPattern: dst))
          // Bounds check: applied unconditionally.
          guard srcOffFC10 + copyCountFC10 <= memory.count else {
            throw WasmError.memoryAccessOutOfBounds
          }
          guard dstOffFC10 + copyCountFC10 <= memory.count else {
            throw WasmError.memoryAccessOutOfBounds
          }
          if copyCountFC10 > 0 {
            // Overlap-safe copy (memmove semantics).
            // Copy forward when dst <= src or regions do not overlap;
            // backward when dst > src and regions overlap to avoid clobbering src bytes.
            memory.withUnsafeMutableBytes { buf in
              let base = buf.baseAddress!
              if dstOffFC10 <= srcOffFC10 || dstOffFC10 >= srcOffFC10 + copyCountFC10 {
                base.advanced(by: dstOffFC10).copyMemory(
                  from: base.advanced(by: srcOffFC10), byteCount: copyCountFC10)
              } else {
                let dstPtr = base.advanced(by: dstOffFC10).assumingMemoryBound(to: UInt8.self)
                let srcPtr = base.advanced(by: srcOffFC10).assumingMemoryBound(to: UInt8.self)
                for i in stride(from: copyCountFC10 - 1, through: 0, by: -1) {
                  dstPtr.advanced(by: i).pointee = srcPtr.advanced(by: i).pointee
                }
              }
            }
          }
          frames[fi].ip = UInt32(cursor)

        case 11:  // memory.fill  immediate: memidx (u32=0)
          _ = try readU32Local()  // memory index (reserved, must be 0)
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let val) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let fillCountFC11 = Int(UInt32(bitPattern: n))
          let dstOffFC11 = Int(UInt32(bitPattern: dst))
          // Bounds check: applied unconditionally.
          guard dstOffFC11 + fillCountFC11 <= memory.count else {
            throw WasmError.memoryAccessOutOfBounds
          }
          if fillCountFC11 > 0 {
            let byteFC11 = UInt8(UInt32(bitPattern: val) & 0xFF)
            // initializeMemory compiles to a single memset call.
            memory.withUnsafeMutableBytes { buf in
              _ = buf.baseAddress!.advanced(by: dstOffFC11)
                .initializeMemory(as: UInt8.self, repeating: byteFC11, count: fillCountFC11)
            }
          }
          frames[fi].ip = UInt32(cursor)

        // --- table bulk operations ---

        case 12:  // table.init  immediates: elemidx (u32), tableidx (u32)
          let elemIdxFC12 = try readU32Local()
          let tableIdxFC12 = try readU32Local()
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let src) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let eiFC12 = Int(elemIdxFC12)
          let tiFC12 = Int(tableIdxFC12)
          guard eiFC12 < module.elements.count else { throw WasmError.undefinedElement }
          guard tiFC12 < tables.count else { throw WasmError.undefinedElement }
          let copyCountFC12 = Int(UInt32(bitPattern: n))
          // A dropped element segment has effective length 0.
          let elemLenFC12 =
            droppedElem & (UInt64(1) << eiFC12) != 0
            ? 0 : module.elements[eiFC12].functionIndices.count
          let srcOffFC12 = Int(UInt32(bitPattern: src))
          let dstOffFC12 = Int(UInt32(bitPattern: dst))
          // Bounds check: applied unconditionally.
          guard srcOffFC12 + copyCountFC12 <= elemLenFC12 else { throw WasmError.undefinedElement }
          guard dstOffFC12 + copyCountFC12 <= tables[tiFC12].count else {
            throw WasmError.undefinedElement
          }
          if copyCountFC12 > 0 {
            let elemsFC12 = module.elements[eiFC12].functionIndices
            let tableRefTypeFC12 =
              tiFC12 < module.tables.count ? module.tables[tiFC12].refType : .funcRef
            for i in 0..<copyCountFC12 {
              tables[tiFC12][dstOffFC12 + i] =
                tableRefTypeFC12 == .externRef
                ? .externref(elemsFC12[srcOffFC12 + i]) : .funcref(elemsFC12[srcOffFC12 + i])
            }
          }
          frames[fi].ip = UInt32(cursor)

        case 13:  // elem.drop  immediate: elemidx (u32)
          let elemIdxFC13 = try readU32Local()
          let eiFC13 = Int(elemIdxFC13)
          guard eiFC13 < module.elements.count else { throw WasmError.undefinedElement }
          droppedElem |= UInt64(1) << eiFC13
          frames[fi].ip = UInt32(cursor)

        case 14:  // table.copy  immediates: dst_tableidx (u32), src_tableidx (u32)
          let dstIdxFC14 = try readU32Local()
          let srcIdxFC14 = try readU32Local()
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let src) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let diFC14 = Int(dstIdxFC14)
          let siFC14 = Int(srcIdxFC14)
          guard diFC14 < tables.count && siFC14 < tables.count else {
            throw WasmError.undefinedElement
          }
          let copyCountFC14 = Int(UInt32(bitPattern: n))
          let srcOffFC14 = Int(UInt32(bitPattern: src))
          let dstOffFC14 = Int(UInt32(bitPattern: dst))
          // Bounds check: applied unconditionally.
          guard srcOffFC14 + copyCountFC14 <= tables[siFC14].count else {
            throw WasmError.undefinedElement
          }
          guard dstOffFC14 + copyCountFC14 <= tables[diFC14].count else {
            throw WasmError.undefinedElement
          }
          if copyCountFC14 > 0 {
            if diFC14 == siFC14 {
              // Same table: overlap-safe copy (memmove semantics).
              if dstOffFC14 <= srcOffFC14 || dstOffFC14 >= srcOffFC14 + copyCountFC14 {
                for i in 0..<copyCountFC14 {
                  tables[diFC14][dstOffFC14 + i] = tables[siFC14][srcOffFC14 + i]
                }
              } else {
                for i in stride(from: copyCountFC14 - 1, through: 0, by: -1) {
                  tables[diFC14][dstOffFC14 + i] = tables[siFC14][srcOffFC14 + i]
                }
              }
            } else {
              // Different tables: no aliasing possible; always copy forward.
              for i in 0..<copyCountFC14 {
                tables[diFC14][dstOffFC14 + i] = tables[siFC14][srcOffFC14 + i]
              }
            }
          }
          frames[fi].ip = UInt32(cursor)

        case 15:  // table.grow  immediate: tableidx (u32)
          let tableIdxFC15 = try readU32Local()
          guard valueStack.count >= 2 else { throw WasmError.stackUnderflow }
          guard case .i32(let delta) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          // Accept any reference type (funcref or externref) as the fill value.
          let refValFC15 = valueStack.removeLast()
          switch refValFC15 {
          case .funcref, .externref: break
          default: throw WasmError.typeMismatch
          }
          let tiFC15 = Int(tableIdxFC15)
          guard tiFC15 < tables.count else { throw WasmError.undefinedElement }
          let nFC15 = Int(UInt32(bitPattern: delta))
          let oldSizeFC15 = Int32(tables[tiFC15].count)
          // Overflow guard: if n alone overflows Int, growth is impossible.
          guard nFC15 <= Int.max - tables[tiFC15].count else {
            valueStack.append(.i32(-1))
            frames[fi].ip = UInt32(cursor)
            break
          }
          let newSizeFC15 = tables[tiFC15].count + nFC15
          let tableMaxFC15 = tiFC15 < module.tables.count ? module.tables[tiFC15].max : nil
          if let maxPages = tableMaxFC15, newSizeFC15 > Int(maxPages) {
            valueStack.append(.i32(-1))
          } else {
            tables[tiFC15].append(contentsOf: [Value](repeating: refValFC15, count: nFC15))
            valueStack.append(.i32(oldSizeFC15))
          }
          frames[fi].ip = UInt32(cursor)

        case 16:  // table.size  immediate: tableidx (u32)
          let tableIdxFC16 = try readU32Local()
          let tiFC16 = Int(tableIdxFC16)
          guard tiFC16 < tables.count else { throw WasmError.undefinedElement }
          valueStack.append(.i32(Int32(tables[tiFC16].count)))
          frames[fi].ip = UInt32(cursor)

        case 17:  // table.fill  immediate: tableidx (u32)
          let tableIdxFC17 = try readU32Local()
          guard valueStack.count >= 3 else { throw WasmError.stackUnderflow }
          guard case .i32(let n) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let fillRefFC17 = valueStack.removeLast()
          guard case .i32(let dst) = valueStack.removeLast() else { throw WasmError.typeMismatch }
          let tiFC17 = Int(tableIdxFC17)
          guard tiFC17 < tables.count else { throw WasmError.undefinedElement }
          // Verify the fill value type matches the table's declared refType.
          let tableFillRefTypeFC17 =
            tiFC17 < module.tables.count ? module.tables[tiFC17].refType : .funcRef
          switch (tableFillRefTypeFC17, fillRefFC17) {
          case (.funcRef, .funcref), (.externRef, .externref): break
          default: throw WasmError.typeMismatch
          }
          let dstOffFC17 = Int(UInt32(bitPattern: dst))
          let fillCountFC17 = Int(UInt32(bitPattern: n))
          // Bounds check: applied unconditionally.
          guard dstOffFC17 + fillCountFC17 <= tables[tiFC17].count else {
            throw WasmError.undefinedElement
          }
          for i in 0..<fillCountFC17 {
            tables[tiFC17][dstOffFC17 + i] = fillRefFC17
          }
          frames[fi].ip = UInt32(cursor)

        default:
          throw WasmError.invalidInstruction(0xFC)
        }

      // MARK: Default — unimplemented opcode

      default:
        throw WasmError.invalidInstruction(opcode)
      }
    }
  }

#endif
