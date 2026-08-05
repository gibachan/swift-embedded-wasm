/// Error type thrown by the interpreter (instantiation and execution)
enum InterpreterError: Error, Equatable, Sendable {
  case functionNotFound  // no export with the given name exists
  case argumentCountMismatch  // argument count does not match the type signature
  case stackUnderflow  // required value is not on the stack
  case importNotFound  // host does not provide a required import
  case memoryAccessOutOfBounds  // memory access is out of range
  case divisionByZero  // division by zero (e.g. div_u, rem_u)
  case integerOverflow  // signed division overflow (INT32_MIN / -1)
  case executionLimitExceeded  // instruction fuel exhausted (prevents infinite loops)
  case unreachableReached  // unreachable instruction executed (trap)
  case undefinedElement  // call_indirect: table index out of bounds or uninitialized
  case indirectCallTypeMismatch  // call_indirect: function type does not match expected type
  case invalidConversionToInteger  // trunc: NaN, Inf, or out-of-range float → integer (Wasm trap)
  case stackOverflow  // value stack, call stack, or label stack exceeded the fixed-size limit
  // the interpreter decodes opcodes/operands on the fly from rawBytes during
  // dispatch (WasmInterpreterEmbedded.swift, shared by macOS and Embedded) —
  // the same "ran out of bytes" condition can occur again here, at execution
  // time, reading from the already-parsed function body's raw byte range
  case unexpectedEnd
  // the interpreter decodes value-type / ref-type bytes on the fly at runtime
  // (e.g. block type / ref type bytes read during dispatch in
  // WasmInterpreterEmbedded.swift) — same decode failure, but discovered
  // during execution, not during the parse pass
  case invalidValueType(UInt8)
  // the interpreter's dispatch loop encounters an unknown opcode while
  // decoding bytecode on the fly at execution time
  // (WasmInterpreterEmbedded.swift dispatch)
  case invalidInstruction(UInt8)
  // the interpreter pops a value of the wrong type off the value stack at
  // runtime (WasmInteger.swift, dispatch loop in WasmInterpreterEmbedded.swift)
  // — a genuine runtime trap, independent of whether validation ran
  case typeMismatch
  // a table/element-segment count exceeds the runtime's fixed capacity during
  // module instantiation (WasmInterpreter.swift's init, e.g.
  // WasmLimits.maxTableElements, elements.count <= 64 checks) — a separate
  // limit enforced at a later phase than parsing
  case resourceLimitExceeded
}
