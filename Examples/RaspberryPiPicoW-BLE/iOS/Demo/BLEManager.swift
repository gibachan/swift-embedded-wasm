// The central BLE (Bluetooth Low Energy) logic class.
// The iPhone acts as a "Central" that scans for, connects to, and communicates with peripherals.

import CoreBluetooth  // Apple's BLE communication framework
import Observation

// NSObject is required because CoreBluetooth delegate protocols require NSObjectBase conformance.
@Observable
final class BLEManager: NSObject {

  // MARK: - CoreBluetooth Objects

  // CBCentralManager: makes the iPhone act as a BLE central (scanner/initiator).
  // The central is responsible for scanning, connecting to, and communicating with peripherals.
  private var central: CBCentralManager!

  // CBPeripheral: represents the target BLE device to connect to.
  // After connecting, services and characteristics are accessed through this object.
  private var peripheral: CBPeripheral?

  // CBCharacteristic: represents a "characteristic" on the peripheral.
  // A characteristic is the unit of data read/write in BLE — analogous to an endpoint in USB.
  private var characteristic: CBCharacteristic?

  // MARK: - State Properties (used for SwiftUI view updates)

  var isBluetoothOn = false  // whether Bluetooth is enabled on the iPhone
  var isConnected = false    // whether a peripheral is currently connected
  var isReady = false        // whether data can be sent (a writable characteristic was found)
  var log: [String] = []     // communication log displayed on screen for learning BLE behavior

  // Name of the peripheral to connect to. Matches against the advertisement name or device name.
  private let targetName = "PicoLED"

  // MARK: - Initialization

  override init() {
    super.init()
    // Creating CBCentralManager immediately starts monitoring Bluetooth state.
    // delegate: self → BLEManager receives all state changes and scan results
    // queue: nil → callbacks are delivered on the main thread (convenient for UI updates)
    central = CBCentralManager(delegate: self, queue: nil)
  }

  // MARK: - Data Transmission

  // Sends an instruction to the Pico to blink the LED `count` times.
  //
  // The Pico side (attWriteCallback) receives 4 bytes (Int32, little-endian) and
  // blinks the LED that many times via blink-loop.wasm.
  func sendBlinkCount(_ count: Int) {
    guard let peripheral, let characteristic else {
      log.append("❌ Not ready")
      return
    }
    let value = Int32(count)
    let bits = UInt32(bitPattern: value)
    let bytes: [UInt8] = [
      UInt8(bits & 0xFF),
      UInt8((bits >> 8) & 0xFF),
      UInt8((bits >> 16) & 0xFF),
      UInt8((bits >> 24) & 0xFF),
    ]
    peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    log.append("➡️ Blink \(count) times")
  }
}

// MARK: - CBCentralManagerDelegate
// Receives events from CBCentralManager: state changes, scan results, and connection results.
extension BLEManager: CBCentralManagerDelegate {
  // Called when the Bluetooth state changes (power on/off, permission changes, etc.)
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log.append("state: \(central.state.rawValue)")

    if central.state == .poweredOn {
      // Start scanning once Bluetooth is powered on.
      isBluetoothOn = true
      log.append("🔍 Start Scan")

      central.scanForPeripherals(
        withServices: nil,  // nil = scan for all devices regardless of advertised services
                            // pass specific service UUIDs to narrow the scan
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        // AllowDuplicates: true allows receiving repeated advertisement packets from the same device.
        // Set to false during background scanning to reduce battery consumption.
      )
    } else {
      isBluetoothOn = false
    }
  }

  // Called each time a peripheral is discovered during scanning.
  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String : Any],
                      rssi RSSI: NSNumber) {

    // advertisementData: contents of the advertisement packet broadcast by the peripheral.
    // CBAdvertisementDataLocalNameKey: the device name included in the advertisement packet
    //   (may differ from peripheral.name)
    let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
    let serviceUUID = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? String ?? "Unknown service UUID"

    // advertisementData contains only the information the peripheral explicitly advertises.
    // For example, if the peripheral advertises service UUIDs, you can match against
    // CBAdvertisementDataServiceUUIDsKey to filter for devices with a specific service.
    //   CBAdvertisementDataLocalNameKey: the peripheral's local name
    //   CBAdvertisementDataServiceUUIDsKey: advertised service UUIDs
    //   CBAdvertisementDataManufacturerDataKey: manufacturer-specific data

    let name = peripheral.name ?? "unknown"

    log.append("👀 Found: \(name) / adv: \(advName) / Service UUID: \(serviceUUID)")

    // Connect to the device whose advertisement name or device name matches targetName.
    if advName == targetName || name.contains(targetName) {
      log.append("✅ Target found")

      self.peripheral = peripheral
      // Setting delegate to self allows this class to receive subsequent service discovery events.
      peripheral.delegate = self

      // Stop scanning once the target device is found (saves battery).
      central.stopScan()
      // Begin connecting to the peripheral (completion is notified via didConnect).
      central.connect(peripheral)
    }
  }

  // Called when a connection is successfully established.
  func centralManager(_ central: CBCentralManager,
                      didConnect peripheral: CBPeripheral) {
    isConnected = true
    log.append("🔗 Connected")

    // Connecting alone is not enough to send data. The peripheral's "services" must be discovered first.
    // nil = discover all services (pass [CBUUID] to filter by specific UUIDs)
    peripheral.discoverServices(nil)
  }

  // Called when a connection attempt fails.
  func centralManager(_ central: CBCentralManager,
                      didFailToConnect peripheral: CBPeripheral,
                      error: Error?) {
    log.append("❌ Connect failed: \(error?.localizedDescription ?? "")")
  }

  // Called when the connection is lost (peripheral power-off, out of range, etc.)
  func centralManager(_ central: CBCentralManager,
                      didDisconnectPeripheral peripheral: CBPeripheral,
                      error: Error?) {
    isConnected = false
    isReady = false
    log.append("🔌 Disconnected")

    // Restart scanning after disconnection so the device is reconnected automatically when it returns.
    central.scanForPeripherals(withServices: nil)
  }
}

// MARK: - CBPeripheralDelegate
// Receives results of service and characteristic discovery from the peripheral.
extension BLEManager: CBPeripheralDelegate {

  // Called when service discovery completes.
  // BLE data hierarchy: peripheral → services (feature groups) → characteristics (data items)
  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverServices error: Error?) {

    guard let services = peripheral.services else { return }

    for service in services {
      log.append("📦 Service: \(service.uuid)")
      // Discover characteristics within each service.
      // nil = discover all characteristics
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  // Called when characteristic discovery completes.
  func peripheral(_ peripheral: CBPeripheral,
                  didDiscoverCharacteristicsFor service: CBService,
                  error: Error?) {

    guard let characteristics = service.characteristics else { return }

    for char in characteristics {
      log.append("🔧 Char: \(char.uuid)")

      // Each characteristic has "properties" (read, write, notify, etc.).
      // .write: write with response; .writeWithoutResponse: write without response.
      // A writable characteristic is required in order to send data.
      if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
        self.characteristic = char
        isReady = true  // write target confirmed, ready to send
        log.append("🎯 Writable characteristic found")
      }
    }
  }
}
