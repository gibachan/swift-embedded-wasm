// Wasm Stack Machine インタプリタ
//
// Wasm はスタックマシン: 命令はオペランドをスタックから取り出し、
// 結果をスタックに積む。関数の引数と宣言済みローカル変数は
// インデックスで参照できる "locals" 配列として扱う。
//
// 構造的制御フロー（block / loop / br）:
//   br は ControlFlow.br(n) としてシグナルを呼び出し元へ伝播させる。
//   block/if: br(0) でブロックを抜ける（前向きジャンプ）
//   loop:     br(0) でループ先頭に戻る（後ろ向きジャンプ）
//   より外側のラベルを対象とする br(n>0) は depth を 1 減らして上位へ渡す。

// MARK: - Host Function Types

/// ホスト側が提供する関数の型。
/// args: 引数値の配列、memory: 読み取り専用の linear memory バイト列。
typealias HostFunction = ([Value], [UInt8]) -> [Value]

/// インスタンス化時に渡すホスト側のインポート定義
enum HostImport {
  case function(String, String, HostFunction)  // (module, name, body)
  case memory(String, String, UInt32)          // (module, name, pages)
}

// br シグナルの伝播に使うファイルスコープの型
private enum ControlFlow {
  case proceed      // 通常の次命令へ進む
  case br(UInt32)   // ラベル深さ n へのブランチシグナル
}

// MARK: - Interpreter

// HostFunction（クロージャ）を保持するため Sendable には準拠しない。
struct WasmInterpreter {
  let module: WasmModule
  let memory: [UInt8]
  private let hostFunctions: [HostFunction]

  // MARK: - Init

  /// module をインスタンス化する。
  ///
  /// - hostImports: Wasm モジュールが import する関数・メモリをホスト側から提供する。
  ///   インポートが宣言されているのに対応する HostImport がない場合は .importNotFound を投げる。
  init(module: WasmModule, hostImports: [HostImport] = []) throws(WasmError) {
    self.module = module

    // インポート順序を保って host 関数を対応付ける
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

    // Memory サイズを決定する（インポート優先、なければローカル定義を使用）
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

    // Data section の内容で memory を初期化する（1 ページ = 64 KiB）
    var mem = [UInt8](repeating: 0, count: Int(memPageCount) * 65536)
    for seg in module.data {
      let start = Int(seg.offset)
      let end = start + seg.bytes.count
      guard end <= mem.count else { throw .memoryAccessOutOfBounds }
      mem.replaceSubrange(start..<end, with: seg.bytes)
    }
    self.memory = mem

    // Wasm 仕様: start 関数はインスタンス化時に自動実行される
    if let startIdx = module.start {
      _ = try call(functionIndex: Int(startIdx), args: [])
    }
  }

  // MARK: - Public

  /// エクスポート名（UTF-8 バイト列）で関数を呼び出す
  func callExport(nameBytes: [UInt8], args: [Value]) throws(WasmError) -> [Value] {
    guard let export = module.exports.first(where: { $0.nameBytes == nameBytes && $0.kind == .function }) else {
      throw .functionNotFound
    }
    return try call(functionIndex: Int(export.index), args: args)
  }

  /// 関数インデックス（インポート含む統合インデックス）で関数を呼び出す
  func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let importedCount = module.importedFunctionCount

    if functionIndex < importedCount {
      // ホスト関数: memory の読み取りアクセスを渡す
      return hostFunctions[functionIndex](args, memory)
    }

    // ローカル関数
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

  /// 命令列を実行し、ControlFlow を返す。
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

      case .i32RemU:
        // 符号なし余り: Int32 のビットパターンを UInt32 として解釈して計算する
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
        // block: br(0) → このブロックを抜ける（前向きジャンプ）
        switch try run(inner, locals: &locals, stack: &stack) {
        case .proceed:   break
        case .br(0):     break
        case .br(let n): return .br(n - 1)
        }

      case .loop(_, let inner):
        // loop: br(0) → ループ先頭に戻る（後ろ向きジャンプ）
        loopHead: while true {
          switch try run(inner, locals: &locals, stack: &stack) {
          case .proceed:   break loopHead
          case .br(0):     continue loopHead
          case .br(let n): return .br(n - 1)
          }
        }

      case .ifElse(_, let thenBody, let elseBody):
        // if/else は block と同じラベル挙動: br(0) でブロックを抜ける
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
