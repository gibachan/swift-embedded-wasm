/// パーサーとインタプリタが共通で使うエラー型
public enum WasmError: Error, Equatable, Sendable {
  // --- パーサー ---
  case invalidMagic                     // マジックバイトが \0asm でない
  case invalidVersion                   // バージョンが 1 でない
  case unexpectedEnd                    // バイト列が途中で終了
  case invalidValueType(UInt8)          // 未知の value type バイト
  case invalidExportKind(UInt8)         // 未知の export kind バイト
  case invalidInstruction(UInt8)        // 未知の opcode
  case leb128Error(LEB128Error)         // LEB128 デコード失敗
  
  // --- インタプリタ ---
  case functionNotFound                 // 指定名の export が存在しない
  case argumentCountMismatch            // 引数の個数が型シグネチャと不一致
  case stackUnderflow                   // 必要な値がスタックにない
  case typeMismatch                     // スタック上の値の型が命令と不一致
}
