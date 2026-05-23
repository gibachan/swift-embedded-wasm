// Global state shared between @main setup and BTstack callbacks
var hciEventCallbackRegistration = btstack_packet_callback_registration_t()
var ledCharHandle: UInt16 = 0
let ledPin = UInt32(CYW43_WL_GPIO_LED_PIN)

// Advertising payload: Flags (3 bytes) + Complete Local Name "PicoLED" (9 bytes)
//   [2, 0x01, 0x06]                    — AD type 0x01 Flags: LE General Discoverable, BR/EDR not supported
//   [8, 0x09, 'P','i','c','o','L','E','D'] — AD type 0x09 Complete Local Name (length byte = name + 1)
var advData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
    2, 0x01, 0x06,
    8, 0x09, 0x50, 0x69, 0x63, 0x6F, 0x4C, 0x45, 0x44
)

func startAdvertising() {
    withUnsafeMutableBytes(of: &advData) { bytes in
        gap_advertisements_set_data(
            UInt8(MemoryLayout.size(ofValue: advData)),
            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
        )
    }
    gap_advertisements_enable(1)
}

// HCI packet handler: re-advertise when the central disconnects
@_cdecl("packetHandler")
func packetHandler(
    _ packetType: UInt8, _ channel: UInt16,
    _ packet: UnsafeMutablePointer<UInt8>?, _ size: UInt16
) {
    guard packetType == 0x04 else { return }  // HCI_EVENT_PACKET
    guard hci_event_packet_get_type(packet) == 0x05 else { return }  // HCI_EVENT_DISCONNECTION_COMPLETE
    startAdvertising()
}

// ATT write handler: iPhone から 8 バイト (Int32 × 2, little-endian) を受信し
// i32-add.wasm で加算して偶数なら LED ON、奇数なら LED OFF
@_cdecl("attWriteCallback")
func attWriteCallback(
    _ conHandle: UInt16, _ attHandle: UInt16, _ transactionMode: UInt16,
    _ offset: UInt16, _ buffer: UnsafeMutablePointer<UInt8>?, _ bufferSize: UInt16
) -> Int32 {
    guard attHandle == ledCharHandle, let buffer, bufferSize >= 8 else { return 0 }

    // little-endian で Int32 × 2 をデコード
    let a = Int32(bitPattern: UInt32(buffer[0])
                            | UInt32(buffer[1]) << 8
                            | UInt32(buffer[2]) << 16
                            | UInt32(buffer[3]) << 24)
    let b = Int32(bitPattern: UInt32(buffer[4])
                            | UInt32(buffer[5]) << 8
                            | UInt32(buffer[6]) << 16
                            | UInt32(buffer[7]) << 24)
    runWasm(a: a, b: b)
    return 0
}

// i32-add.wasm を実行し、結果の偶奇で LED を制御する
func runWasm(a: Int32, b: Int32) {
    withUnsafeBytes(of: &i32AddWasm) { raw in
        let buf = UnsafeBufferPointer(
            start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
            count: i32AddWasmLen
        )
        var parser = WasmParser(buf)
        do throws(WasmError) {
            let module = try parser.parse()
            // callExport(name:) は String 比較が必要なため Embedded では使わない。
            // i32-add.wasm の関数インデックスは 0 固定なので直接指定する。
            let results = try WasmInterpreter(module: module)
                .call(functionIndex: 0, args: [.i32(a), .i32(b)])
            if case .i32(let n) = results.first {
                cyw43_arch_gpio_put(ledPin, n % 2 == 0)
            }
        } catch {
            // Wasm 実行エラー時は LED 状態を変えない（error は WasmError 型）
        }
    }
}

@main
struct Main {
    static func main() {
        guard cyw43_arch_init() == 0 else { return }

        // ── Build the GATT database at runtime ──────────────────────────────
        att_db_util_init()

        // Primary service: 12345678-1234-5678-1234-56789abcdef0 (big-endian)
        var svcUUID: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0
        )
        withUnsafeBytes(of: &svcUUID) { bytes in
            _ = att_db_util_add_service_uuid128(
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            )
        }

        // Write characteristic: 12345678-1234-5678-1234-56789abcdef1 (big-endian)
        // Properties: 0x0108 = ATT_PROPERTY_WRITE (0x08) | ATT_PROPERTY_DYNAMIC (0x100)
        var charUUID: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf1
        )
        withUnsafeBytes(of: &charUUID) { bytes in
            ledCharHandle = att_db_util_add_characteristic_uuid128(
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                0x0108,  // ATT_PROPERTY_WRITE | ATT_PROPERTY_DYNAMIC
                0, 0,    // ATT_SECURITY_NONE for read and write
                nil, 0
            )
        }

        // ── Initialise the BLE protocol stack ───────────────────────────────
        l2cap_init()
        sm_init()
        att_server_init(att_db_util_get_address(), nil, attWriteCallback)

        // ── Advertising ─────────────────────────────────────────────────────
        // Interval: 0x00A0 units × 0.625 ms = 100 ms
        var nullAddr: bd_addr_t = (0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &nullAddr) { bytes in
            gap_advertisements_set_params(
                0x00A0, 0x00A0,  // min/max interval
                0,               // adv type: undirected connectable
                0,               // direct address type (unused)
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                0x07,            // all three advertising channels
                0x00             // no filter policy
            )
        }
        startAdvertising()

        // ── Event handlers ──────────────────────────────────────────────────
        hciEventCallbackRegistration.callback = packetHandler
        hci_add_event_handler(&hciEventCallbackRegistration)
        att_server_register_packet_handler(packetHandler)

        // ── Power on and run forever ────────────────────────────────────────
        hci_power_control(HCI_POWER_ON)
        btstack_run_loop_execute()
    }
}
