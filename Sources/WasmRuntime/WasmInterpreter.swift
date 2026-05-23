// Wasm Stack Machine インタプリタ
//
// Wasm はスタックマシン: 命令はオペランドをスタックから取り出し、
// 結果をスタックに積む。関数の引数と宣言済みローカル変数は
// インデックスで参照できる "locals" 配列として扱う。
//
// 構造的制御フロー（block / loop / br）:
//   br は ControlFlow.br(n) としてシグナルを呼び出し元へ伝播させる。
//   block: br(0) でブロックを抜ける（前向きジャンプ）
//   loop:  br(0) でループ先頭に戻る（後ろ向きジャンプ）
//   より外側のラベルを対象とする br(n>0) は depth を 1 減らして上位へ渡す。

// br シグナルの伝播に使うファイルスコープの型
private enum ControlFlow {
  case proceed      // 通常の次命令へ進む
  case br(UInt32)   // ラベル深さ n へのブランチシグナル
}

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
    _ = try run(body.instructions, locals: &locals, stack: &stack)
    return Array(stack.suffix(resultCount))
  }

  /// 命令列を実行し、ControlFlow を返す。
  ///
  /// br / br_if がトリガーされると .br(n) を返し、呼び出し元（block/loop ハンドラ）が
  /// n を 1 減らしながら上位に伝播させる。n==0 が自分自身のブロックへの br を意味する。
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

      case .block(_, let inner):
        // block: br(0) → このブロックを抜ける（前向きジャンプ）
        switch try run(inner, locals: &locals, stack: &stack) {
        case .proceed: break
        case .br(0):   break              // ブロックを正常終了
        case .br(let n): return .br(n - 1) // 外側ラベルへ伝播
        }

      case .loop(_, let inner):
        // loop: br(0) → ループ先頭に戻る（後ろ向きジャンプ）
        //        それ以外 → fall-through（ループ終了）
        loopHead: while true {
          switch try run(inner, locals: &locals, stack: &stack) {
          case .proceed:   break loopHead    // ボディ完走 → ループ終了
          case .br(0):     continue loopHead // ループ先頭へ
          case .br(let n): return .br(n - 1) // 外側ラベルへ伝播
          }
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
