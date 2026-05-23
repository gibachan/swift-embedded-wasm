// Wasm Stack Machine インタプリタ
//
// Wasm はスタックマシン: 命令はオペランドをスタックから取り出し、
// 結果をスタックに積む。関数の引数と宣言済みローカル変数は
// インデックスで参照できる "locals" 配列として扱う。
//
// 実行フロー（例: i32-add(3, 4)）:
//   locals = [3, 4]   ← 引数で初期化
//   local.get 0 → stack: [3]
//   local.get 1 → stack: [3, 4]
//   i32.add     → stack: [7]    ← pop 2, push (3+4)
//   end         → return stack top 1 value = [7]

struct WasmInterpreter: Sendable {
  let module: WasmModule

  // Wasm 仕様: start 関数はインスタンス化時に自動実行される。
  // start が失敗した場合はインスタンス化そのものを失敗として扱う。
  init(module: WasmModule) throws(WasmError) {
    self.module = module
    if let startIdx = module.start {
      _ = try call(functionIndex: Int(startIdx), args: [])
    }
  }
  
  // MARK: - Public
  
  /// エクスポート名（UTF-8 バイト列）で関数を呼び出す
  ///
  /// String の == 比較は Unicode 正規化テーブルを要求するため使用しない。
  /// nameBytes どうしのバイト比較で照合する。
  func callExport(nameBytes: [UInt8], args: [Value]) throws(WasmError) -> [Value] {
    guard let export = module.exports.first(where: { $0.nameBytes == nameBytes && $0.kind == .function }) else {
      throw .functionNotFound
    }
    return try call(functionIndex: Int(export.index), args: args)
  }
  
  /// 関数インデックスで関数を呼び出す
  func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let typeIndex = Int(module.functions[functionIndex])
    let funcType = module.types[typeIndex]
    let body = module.code[functionIndex]
    
    guard args.count == funcType.params.count else {
      throw .argumentCountMismatch
    }
    
    // locals = 引数 + 関数内宣言のローカル変数（ゼロ初期化）
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
    
    for instruction in body.instructions {
      switch instruction {
        
      case .localGet(let idx):
        stack.append(locals[Int(idx)])
        
      case .i32Add:
        guard stack.count >= 2 else { throw .stackUnderflow }
        guard case .i32(let b) = stack.removeLast(),
              case .i32(let a) = stack.removeLast()
        else { throw .typeMismatch }
        // &+ で整数オーバーフローを Wasm 仕様通りにラップアラウンド
        stack.append(.i32(a &+ b))
        
      case .end:
        break
      }
    }
    
    return Array(stack.suffix(resultCount))
  }
}
