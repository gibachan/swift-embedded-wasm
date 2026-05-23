// BLEManager.swift
// BLE（Bluetooth Low Energy）の中心的なロジックを担うクラス。
// iPhoneが「セントラル（Central）」として動作し、周辺機器（ペリフェラル）を探して接続・通信する。

import CoreBluetooth // Appleが提供するBLE通信フレームワーク
import Observation

// NSObject を継承しているのは、CoreBluetoothのデリゲート（後述）がNSObjectBaseのプロトコルを要求するため
@Observable
final class BLEManager: NSObject {

  // MARK: - CoreBluetooth オブジェクト

  // CBCentralManager: iPhoneをBLEのセントラル（親機・スキャン側）として機能させるクラス
  // セントラルはペリフェラルをスキャン・接続・通信する役割を持つ
  private var central: CBCentralManager!

  // CBPeripheral: 接続対象のBLEデバイス（ペリフェラル）を表すオブジェクト
  // 接続後はこのオブジェクトを通じてサービスやキャラクタリスティックを操作する
  private var peripheral: CBPeripheral?

  // CBCharacteristic: ペリフェラルが持つ「キャラクタリスティック」を表すオブジェクト
  // キャラクタリスティックはBLEにおけるデータの読み書き単位。USB でいうエンドポイントに相当する。
  private var characteristic: CBCharacteristic?

  // MARK: - 状態プロパティ（SwiftUIの画面表示に使われる）

  var isBluetoothOn = false  // iPhoneのBluetoothが有効かどうか
  var isConnected = false    // ペリフェラルに接続済みかどうか
  var isReady = false        // データを送信できる状態かどうか（書き込み可能なキャラクタリスティックが見つかったか）
  var log: [String] = []     // 通信ログ（画面に表示してBLEの動作を学習するため）

  // 接続したいペリフェラルの名前。広告名またはデバイス名がこれに一致するものを探す。
  private let targetName = "PicoLED"

  // MARK: - 初期化

  override init() {
    super.init()
    // CBCentralManager を生成すると同時にBluetoothの状態監視が始まる。
    // delegate: self → 状態変化やスキャン結果を自分自身（BLEManager）が受け取る
    // queue: nil → コールバックをメインスレッドで受け取る（UIの更新に便利）
    central = CBCentralManager(delegate: self, queue: nil)
  }

  // MARK: - データ送信

  // LED のON/OFFをPicoに送信する。
  //
  // Pico側（attWriteCallback）は8バイト（Int32 × 2, little-endian）を期待し、
  // 2値の合計が偶数なら LED ON、奇数なら LED OFF として動作する。
  //   LED ON  → a=0, b=0 → sum=0（偶数）
  //   LED OFF → a=1, b=0 → sum=1（奇数）
  func sendLED(on: Bool) {
    guard let peripheral, let characteristic else {
      log.append("❌ Not ready")
      return
    }
    let a: Int32 = on ? 0 : 1
    let b: Int32 = 0
    var bytes = [UInt8](repeating: 0, count: 8)
    bytes[0] = UInt8(UInt32(bitPattern: a) & 0xFF)
    bytes[1] = UInt8((UInt32(bitPattern: a) >> 8) & 0xFF)
    bytes[2] = UInt8((UInt32(bitPattern: a) >> 16) & 0xFF)
    bytes[3] = UInt8((UInt32(bitPattern: a) >> 24) & 0xFF)
    bytes[4] = UInt8(UInt32(bitPattern: b) & 0xFF)
    bytes[5] = UInt8((UInt32(bitPattern: b) >> 8) & 0xFF)
    bytes[6] = UInt8((UInt32(bitPattern: b) >> 16) & 0xFF)
    bytes[7] = UInt8((UInt32(bitPattern: b) >> 24) & 0xFF)
    peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    log.append("➡️ LED \(on ? "ON" : "OFF"): a=\(a), b=\(b)")
  }
}

// MARK: - CBCentralManagerDelegate
// CBCentralManager の各種イベント（状態変化・スキャン結果・接続結果）を受け取るデリゲート
extension BLEManager: CBCentralManagerDelegate {
  // Bluetoothの状態が変わったときに呼ばれる（電源ON/OFF、権限変更など）
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log.append("state: \(central.state.rawValue)")

    if central.state == .poweredOn {
      // BluetoothがONになったらスキャン開始
      isBluetoothOn = true
      log.append("🔍 Start Scan")

      central.scanForPeripherals(
        withServices: nil, // nil = すべてのサービスを持つデバイスをスキャン対象にする
                           // 特定のサービスUUIDを指定すれば絞り込みが可能
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        // AllowDuplicates: true にすると同じデバイスの広告パケットを繰り返し受信できる
        // バックグラウンドでのスキャン時はfalseにしないとバッテリーを消費しやすい
      )
    } else {
      isBluetoothOn = false
    }
  }

  // スキャン中にペリフェラルが見つかるたびに呼ばれる
  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String : Any],
                      rssi RSSI: NSNumber) {

    // advertisementData: ペリフェラルが定期的に発信している広告パケットの中身
    // CBAdvertisementDataLocalNameKey: 広告パケットに含まれるデバイス名（peripheral.name と異なる場合がある）
    let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
    let serviceUUID = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? String ?? "Unknown service UUID"

    // advertisementDataには、Peripheralデバイスがあらかじめ公開している情報のみが含まれています。例えばサービスUUIDを公開している場合に限り、CBAdvertisementDataServiceUUIDsKeyを通じてそのUUIDと照合し、特定のサービスを持つデバイスのみを検出することが可能です。
    // CBAdvertisementDataLocalNameKey：Peripheralデバイスのローカル名
    // CBAdvertisementDataServiceUUIDsKey：アドバタイズされているサービスUUID
    // CBAdvertisementDataManufacturerDataKey：メーカー固有のデータ

    let name = peripheral.name ?? "unknown"

    log.append("👀 Found: \(name) / adv: \(advName) / Service UUID: \(serviceUUID)")

    // 広告名またはデバイス名が targetName と一致するデバイスを接続対象とする
    if advName == targetName || name.contains(targetName) {
      log.append("✅ Target found")

      self.peripheral = peripheral
      // デリゲートを self にすることで、以降のサービス探索などのイベントをここで受け取れる
      peripheral.delegate = self

      // 目的のデバイスが見つかったのでスキャンを止める（バッテリー節約）
      central.stopScan()
      // ペリフェラルへの接続を開始する（接続完了は didConnect で通知される）
      central.connect(peripheral)
    }
  }

  // 接続に成功したときに呼ばれる
  func centralManager(_ central: CBCentralManager,
                      didConnect peripheral: CBPeripheral) {
    isConnected = true
    log.append("🔗 Connected")

    // 接続しただけではデータを送れない。まずペリフェラルが持つ「サービス」を探索する必要がある。
    // nil = すべてのサービスを探索（特定のUUIDに絞る場合は [CBUUID] を渡す）
    peripheral.discoverServices(nil)
  }

  // 接続に失敗したときに呼ばれる
  func centralManager(_ central: CBCentralManager,
                      didFailToConnect peripheral: CBPeripheral,
                      error: Error?) {
    log.append("❌ Connect failed: \(error?.localizedDescription ?? "")")
  }

  // 接続が切れたときに呼ばれる（ペリフェラル側の電源断や距離超過など）
  func centralManager(_ central: CBCentralManager,
                      didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    isConnected = false
    isReady = false
    log.append("🔌 Disconnected")

    // 切断後に再スキャンを開始して、デバイスが戻ってきたら自動で再接続できるようにする
    central.scanForPeripherals(withServices: nil)
  }
}

// MARK: - CBPeripheralDelegate
// ペリフェラルのサービス・キャラクタリスティック探索結果を受け取るデリゲート
extension BLEManager: CBPeripheralDelegate {

  // サービスの探索が完了したときに呼ばれる
  // BLEのデータ構造: ペリフェラル → サービス（機能グループ） → キャラクタリスティック（データ項目）
  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverServices error: Error?) {

    guard let services = peripheral.services else { return }

    for service in services {
      log.append("📦 Service: \(service.uuid)")
      // 各サービスの中にあるキャラクタリスティックをさらに探索する
      // nil = すべてのキャラクタリスティックを対象にする
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  // キャラクタリスティックの探索が完了したときに呼ばれる
  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {

    guard let characteristics = service.characteristics else { return }

    for char in characteristics {
      log.append("🔧 Char: \(char.uuid)")

      // キャラクタリスティックには「プロパティ（読み取り・書き込み・通知など）」が設定されている
      // .write: 書き込み（応答あり）、.writeWithoutResponse: 書き込み（応答なし）
      // データを送信するには書き込み可能なキャラクタリスティックを使う必要がある
      if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
        self.characteristic = char
        isReady = true // 書き込み先が確定したので送信可能になった
        log.append("🎯 Writable characteristic found")
      }
    }
  }
}
