import SwiftUI

struct ContentView: View {
  @State private var ble = BLEManager()

  var body: some View {
    VStack(spacing: 16) {
      // --- 状態表示 ---
      Text(ble.isBluetoothOn ? "Bluetooth ON" : "Bluetooth OFF")  // BluetoothのON/OFF
      Text(ble.isConnected ? "Connected" : "Disconnected")         // ペリフェラルへの接続状態
      Text(ble.isReady ? "Ready" : "Not Ready")                    // データ送信できる状態かどうか

      // --- 操作ボタン ---
      HStack {
        // "1" を送ることでLEDを点灯させる（ペリフェラル側で "1" を受信してLEDをONにする約束）
        Button("LED ON") {
          ble.sendLED(on: true)
        }
        .disabled(!ble.isReady) // 接続・準備完了前はボタンを無効化して誤操作を防ぐ

        Button("LED OFF") {
          ble.sendLED(on: false)
        }
        .disabled(!ble.isReady)
      }

      Divider()

      // --- 通信ログ ---
      // BLEの各フェーズ（スキャン→接続→サービス探索→送信）をログで可視化することで
      // BLEの動作の流れを学習しやすくする
      List(Array(ble.log.enumerated()), id: \.offset) { _, item in
        Text(item)
          .font(.system(size: 12))
      }
    }
    .padding()
  }
}
