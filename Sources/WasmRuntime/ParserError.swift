/// Error type thrown by the binary parser and validator
enum ParserError: Error, Equatable, Sendable {
  case invalidMagic  // magic bytes are not \0asm
  case invalidVersion  // version is not 1
  // byte stream ends prematurely while parsing the module's binary sections
  // (LEB128/bytes reader hits EOF during WasmParser)
  case unexpectedEnd
  // an unknown value-type byte is encountered while parsing type/local/global declarations
  case invalidValueType(UInt8)
  case invalidExportKind(UInt8)  // unknown export kind byte
  case invalidLimitType(UInt8)  // unknown limit type byte (memory/table)
  case invalidImportKind(UInt8)  // unknown import kind byte
  case invalidRefType(UInt8)  // unknown reference type byte (funcref/externref)
  case invalidMutability(UInt8)  // unknown global mutability byte
  case unsupportedElementSegment  // element segment format not yet supported
  // WasmParser itself decodes certain instructions eagerly while scanning code
  // bodies (e.g. constant expressions for global/element/data offsets) and
  // rejects unknown opcodes there
  case invalidInstruction(UInt8)
  case leb128Error(LEB128Error)  // LEB128 decode failure
  case malformedUTF8  // invalid UTF-8 sequence in a name field (e.g. custom section name)
  case malformedSectionId  // section id > 12 (not a known or custom section)
  case sectionSizeMismatch  // declared section size does not match consumed byte count
  case duplicateSection  // a known section (id 1-12) appears more than once
  case sectionOutOfOrder  // sections appear in non-ascending id order (custom sections excepted)
  case dataCountMismatch  // data count section value does not match the number of data segments
  case dataCountRequired  // memory.init or data.drop used without a data count section
  // WasmValidator (macOS-only static type checker) detects a type violation
  // while statically checking the module before any execution
  case typeMismatch
  // a section's item count exceeds the fixed-buffer capacity defined in
  // WasmLimits while parsing (WasmParser.swift)
  case resourceLimitExceeded
}
