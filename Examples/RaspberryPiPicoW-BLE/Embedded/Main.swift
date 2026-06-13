// Global state shared between @main setup and BTstack callbacks
var hciEventCallbackRegistration = btstack_packet_callback_registration_t()
var ledCharHandle: UInt16 = 0
let ledPin = UInt32(CYW43_WL_GPIO_LED_PIN)

// WASM receive state
var wasmRecvLen: UInt32 = 0       // bytes written into the receive buffer so far
var wasmRecvExpected: UInt32 = 0  // total byte count declared by 0xF0 command

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

// ATT write handler: command-byte state machine for WASM transfer and execution.
//
// Protocol:
//   0xF0  — WASM transfer start: bytes[1..2] = total size (UInt16 little-endian)
//   0xF1  — WASM chunk:          bytes[1..2] = write offset (UInt16 little-endian),
//                                bytes[3..]  = data
//   0xF2  — Execute received WASM (no payload)
@_cdecl("attWriteCallback")
func attWriteCallback(
    _ conHandle: UInt16, _ attHandle: UInt16, _ transactionMode: UInt16,
    _ offset: UInt16, _ buffer: UnsafeMutablePointer<UInt8>?, _ bufferSize: UInt16
) -> Int32 {
    guard attHandle == ledCharHandle, let buffer, bufferSize >= 1 else { return 0 }

    let cmd = buffer[0]
    switch cmd {
    case 0xF0:
        // Transfer start — read expected total size from bytes[1..2]
        guard bufferSize >= 3 else { return 0 }
        let totalSize = UInt32(buffer[1]) | UInt32(buffer[2]) << 8
        wasmRecvExpected = totalSize
        wasmRecvLen = 0

    case 0xF1:
        // Chunk — bytes[1..2] = write offset, bytes[3..] = data
        guard bufferSize >= 4 else { return 0 }
        let writeOffset = UInt32(buffer[1]) | UInt32(buffer[2]) << 8
        let dataLen = UInt32(bufferSize) - 3
        guard let destBase = wasm_recv_buf_ptr() else { return 0 }
        let bufCapacity = wasm_recv_buf_size()
        // Bounds check: reject writes that fall outside either the declared size or the static buffer
        guard wasmRecvExpected > 0,
              writeOffset + dataLen <= wasmRecvExpected,
              writeOffset + dataLen <= bufCapacity else { return 0 }
        let dest = destBase.advanced(by: Int(writeOffset))
        let src = buffer.advanced(by: 3)
        for i in 0..<Int(dataLen) {
            dest[i] = src[i]
        }
        // Update received length to the highest byte written
        let newEnd = writeOffset + dataLen
        if newEnd > wasmRecvLen {
            wasmRecvLen = newEnd
        }

    case 0xF2:
        // Execute only when all expected bytes have been received
        guard wasmRecvExpected > 0, wasmRecvLen == wasmRecvExpected else { return 0 }
        executeReceivedWasm()

    default:
        break
    }

    return 0
}

// Host function for the "env::blink" import.
// Uses @convention(c) via HostFunctionPtr — no capture, no heap allocation.
// Reads ledPin from the global declared at the top of this file.
// args/results are UnsafeRawPointer because Value (Swift enum) is not @convention(c)-representable.
@_cdecl("hostBlink")
func hostBlink(
  _ args: UnsafeRawPointer?, _ argsCount: Int32,
  _ memory: UnsafeMutablePointer<UInt8>?, _ memorySize: Int32,
  _ results: UnsafeMutableRawPointer?
) {
  cyw43_arch_gpio_put(ledPin, true)
  sleep_ms(300)
  cyw43_arch_gpio_put(ledPin, false)
  sleep_ms(300)
}

// Execute the WASM binary that has been written into the static receive buffer.
// The WASM module is expected to export a single entry-point function with no
// parameters, located at the first local function index (after all imports).
// Host import: env::blink — toggles the LED on for 300 ms then off for 300 ms.
func executeReceivedWasm() {
    guard wasmRecvLen > 0, let ptr = wasm_recv_buf_ptr() else { return }
    let wasmBuf = UnsafeBufferPointer<UInt8>(start: ptr, count: Int(wasmRecvLen))
    var parser = WasmParser(wasmBuf)
    do throws(WasmError) {
        let module = try parser.parse()
        let hostImports: [HostImport] = [
            .function("env", "blink", hostBlink),
        ]
        // importedFunctionCount: number of imported functions.
        // The first local function begins immediately after that index.
        var interp = try WasmInterpreter(module: module, hostImports: hostImports)
        let runFuncIdx = module.importedFunctionCount
        let runArgs: [Value] = module.functionType(at: runFuncIdx).params.map { vt in
            switch vt {
            case .i32: return .i32(0)
            case .i64: return .i64(0)
            case .f32: return .f32(0)
            case .f64: return .f64(0)
            case .funcref: return .funcref(nil)
            case .externref: return .externref(nil)
            }
        }
        _ = try interp.call(functionIndex: runFuncIdx, args: runArgs)
    } catch {
        // On WASM error, leave the LED unchanged
    }
    // Reset transfer state so the next 0xF0 starts fresh
    wasmRecvLen = 0
    wasmRecvExpected = 0
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
