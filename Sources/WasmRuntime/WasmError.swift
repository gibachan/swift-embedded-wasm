/// Error type shared by the parser and interpreter
enum WasmError: Error, Equatable, Sendable {
  // --- Parser ---
  case invalidMagic  // magic bytes are not \0asm
  case invalidVersion  // version is not 1
  case unexpectedEnd  // byte stream ended prematurely
  case invalidValueType(UInt8)  // unknown value type byte
  case invalidExportKind(UInt8)  // unknown export kind byte
  case invalidLimitType(UInt8)  // unknown limit type byte (memory/table)
  case invalidImportKind(UInt8)  // unknown import kind byte
  case invalidRefType(UInt8)  // unknown reference type byte (funcref/externref)
  case invalidMutability(UInt8)  // unknown global mutability byte
  case unsupportedElementSegment  // element segment format not yet supported
  case invalidInstruction(UInt8)  // unknown opcode
  case leb128Error(LEB128Error)  // LEB128 decode failure

  // --- Interpreter ---
  case functionNotFound  // no export with the given name exists
  case argumentCountMismatch  // argument count does not match the type signature
  case stackUnderflow  // required value is not on the stack
  case typeMismatch  // value on the stack has the wrong type for the instruction
  case importNotFound  // host does not provide a required import
  case memoryAccessOutOfBounds  // memory access is out of range
  case divisionByZero  // division by zero (e.g. div_u, rem_u)
  case integerOverflow  // signed division overflow (INT32_MIN / -1)
  case executionLimitExceeded  // instruction fuel exhausted (prevents infinite loops)
  case unreachableReached  // unreachable instruction executed (trap)
  case undefinedElement  // call_indirect: table index out of bounds or uninitialized
  case indirectCallTypeMismatch  // call_indirect: function type does not match expected type
  case invalidConversionToInteger  // trunc: NaN, Inf, or out-of-range float → integer (Wasm trap)
}
