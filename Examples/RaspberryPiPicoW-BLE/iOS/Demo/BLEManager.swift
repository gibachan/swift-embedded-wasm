// The central BLE (Bluetooth Low Energy) logic class.
// The iPhone acts as a "Central" that scans for, connects to, and communicates with peripherals.

import CoreBluetooth  // Apple's BLE communication framework
import Observation

// NSObject is required because CoreBluetooth delegate protocols require NSObjectBase conformance.
@Observable
final class BLEManager: NSObject {

  // MARK: - CoreBluetooth Objects

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var characteristic: CBCharacteristic?

  // MARK: - State Properties

  var isBluetoothOn = false
  var isConnected = false
  var isReady = false
  var isSending = false
  var sendProgress: Double = 0  // 0.0 – 1.0
  var log: [String] = []

  // MARK: - Write queue for chunked WASM transfer

  private var writeQueue: [Data] = []
  private var totalPackets = 0

  private let targetName = "PicoLED"

  // MARK: - Initialization

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: nil)
  }

  // MARK: - WASM Transfer
  //
  // Protocol (single writable characteristic, command byte at index 0):
  //   0xF0  — start:   bytes[1..2] = total WASM size (UInt16 little-endian)
  //   0xF1  — chunk:   bytes[1..2] = write offset (UInt16 little-endian), bytes[3..] = data
  //   0xF2  — execute: (no payload)

  func sendWasm(_ data: Data) {
    guard let peripheral, !isSending else {
      log.append("❌ Not ready or already sending")
      return
    }
    guard data.count <= Int(UInt16.max) else {
      log.append("❌ WASM too large (max \(UInt16.max) bytes)")
      return
    }

    let maxPayload = peripheral.maximumWriteValueLength(for: .withResponse)
    // 3 bytes are used for cmd (1) + offset (2), leaving this many bytes for chunk data
    let chunkDataSize = max(1, maxPayload - 3)

    var queue: [Data] = []

    // 0xF0: announce total size
    let size = UInt16(data.count)
    queue.append(Data([0xF0, UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF)]))

    // 0xF1: data chunks
    var offset = 0
    while offset < data.count {
      let end = min(offset + chunkDataSize, data.count)
      let offsetU16 = UInt16(offset)
      var packet = Data([0xF1, UInt8(offsetU16 & 0xFF), UInt8((offsetU16 >> 8) & 0xFF)])
      packet.append(data[offset..<end])
      queue.append(packet)
      offset = end
    }

    // 0xF2: execute
    queue.append(Data([0xF2]))

    writeQueue = queue
    totalPackets = queue.count
    isSending = true
    sendProgress = 0
    log.append("➡️ Sending WASM (\(data.count) bytes, \(queue.count) packets)")
    processWriteQueue()
  }

  private func processWriteQueue() {
    guard !writeQueue.isEmpty, let peripheral, let characteristic else {
      finishSend()
      return
    }
    let packet = writeQueue.removeFirst()
    peripheral.writeValue(packet, for: characteristic, type: .withResponse)
  }

  private func finishSend() {
    isSending = false
    sendProgress = 1
    log.append("✅ WASM sent")
  }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log.append("state: \(central.state.rawValue)")
    if central.state == .poweredOn {
      isBluetoothOn = true
      log.append("🔍 Start Scan")
      central.scanForPeripherals(
        withServices: nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    } else {
      isBluetoothOn = false
    }
  }

  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any],
                      rssi RSSI: NSNumber) {
    let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
    let name = peripheral.name ?? "unknown"
    log.append("👀 Found: \(name) / adv: \(advName)")
    if advName == targetName || name.contains(targetName) {
      log.append("✅ Target found")
      self.peripheral = peripheral
      peripheral.delegate = self
      central.stopScan()
      central.connect(peripheral)
    }
  }

  func centralManager(_ central: CBCentralManager,
                      didConnect peripheral: CBPeripheral) {
    isConnected = true
    log.append("🔗 Connected")
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager,
                      didFailToConnect peripheral: CBPeripheral,
                      error: Error?) {
    log.append("❌ Connect failed: \(error?.localizedDescription ?? "")")
  }

  func centralManager(_ central: CBCentralManager,
                      didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    isConnected = false
    isReady = false
    isSending = false
    sendProgress = 0
    writeQueue.removeAll()
    self.peripheral = nil
    self.characteristic = nil
    log.append("🔌 Disconnected")
    central.scanForPeripherals(withServices: nil)
  }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverServices error: Error?) {
    guard let services = peripheral.services else { return }
    for service in services {
      log.append("📦 Service: \(service.uuid)")
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {
    guard let characteristics = service.characteristics else { return }
    for char in characteristics {
      log.append("🔧 Char: \(char.uuid)")
      if char.properties.contains(.write) {
        self.characteristic = char
        isReady = true
        log.append("🎯 Writable characteristic found")
      }
    }
  }

  // Called after each withResponse write completes — drives the write queue.
  func peripheral(_ peripheral: CBPeripheral,
                  didWriteValueFor characteristic: CBCharacteristic,
                  error: Error?) {
    if let error {
      log.append("❌ Write error: \(error.localizedDescription)")
      writeQueue.removeAll()
      isSending = false
      return
    }
    let sent = totalPackets - writeQueue.count
    sendProgress = Double(sent) / Double(totalPackets)
    processWriteQueue()
  }
}
