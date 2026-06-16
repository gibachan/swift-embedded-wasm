# swift-embedded-wasm

[![CI](https://github.com/gibachan/swift-embedded-wasm/actions/workflows/ci.yml/badge.svg)](https://github.com/gibachan/swift-embedded-wasm/actions/workflows/ci.yml)

A WebAssembly Runtime implemented in Embedded Swift, targeting Raspberry Pi Pico 2 (RP2350).

Transfer a Wasm binary from an iPhone via BLE — the Embedded Swift Runtime on the Pico executes it dynamically to control GPIO, OLED, and sensors.

**Spec compliance (as of 2026-05-31):** 31,925 PASS / 0 FAIL out of 59,889 total test cases. See [SPEC_COMPLIANCE.md](Documentations/SPEC_COMPLIANCE.md) for details.

---

## Repository Structure

```
swift-embedded-wasm/
├── Sources/WasmRuntime/                      # Shared logic (compiles on both macOS and Pico)
├── Tests/WasmRuntimeTests/                   # macOS tests (swift test)
├── Examples/RaspberryPiPicoW-BLE/Embedded/  # BLE peripheral firmware (Pico W, CMake build)
├── Package.swift                             # macOS build definition (for development and testing)
└── Makefile                                  # Test and Embedded Swift validation targets
```

`Sources/WasmRuntime/` compiles on both macOS (SwiftPM) and Pico (Makefile `compile`).
For a full Pico build, see `Examples/RaspberryPiPicoW-BLE/Embedded/`.

---

## Build

### Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [swiftly](https://github.com/swiftlang/swiftly) | Swift toolchain manager | `curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh \| bash` |
| Swift 6.x (with embedded stdlib) | Embedded Swift compilation | `swiftly install latest` |

### macOS Tests (no Pico required)

```sh
swift test
```

Tests the shared logic in `Sources/WasmRuntime/` on macOS. The primary way to develop and verify without real hardware.

Two types of tests are included:

#### Unit Tests

Handwritten tests under `Tests/WasmRuntimeTests/` that verify parser and interpreter behaviour individually.

#### Spec Conformance Tests

Tests against the official [WebAssembly Spec Testsuite](https://github.com/WebAssembly/testsuite) to continuously verify spec compliance.

**Initial setup (requires `wabt`)**

```sh
brew install wabt       # installs wast2json
make spectest-gen       # converts .wast → JSON + .wasm (output to Tests/WasmRuntimeTests/spectest/)
```

After setup, the spectest is automatically included in `swift test`.

**Result meanings**

| Result | Meaning |
|--------|---------|
| PASS | Behaves as specified |
| SKIP | Cannot run — uses an unimplemented instruction or type |
| FAIL | Mismatch with spec (bug) |

Each time a new instruction is implemented, corresponding tests move from SKIP → PASS or FAIL. A FAIL indicates a spec mismatch.

**View per-file statistics**

Uncomment the following line in `SpectestTests.swift` to print pass/skip/fail counts per file:

```swift
// print("[\(file.name)] pass=\(runner.passCount) skip=\(runner.skipCount) fail=\(runner.failCount)")
```

**Clean generated files**

```sh
make spectest-clean
```

`Tests/WasmRuntimeTests/spectest/` is listed in `.gitignore`.

### Compile Only (no Pico SDK required)

```sh
make compile
```

Useful for verifying that the Embedded Swift toolchain is configured correctly.
On success, `build/pico-wasm.o` is generated.

### Full Build (.uf2 generation, Pico SDK required)

```sh
# Clone the Pico SDK (first time only)
git clone https://github.com/raspberrypi/pico-sdk ~/pico/pico-sdk
cd ~/pico/pico-sdk && git submodule update --init

# Build
make build
```

Generates `.elf` / `.bin` / `.uf2` under `build/`.

### Flash to Pico

1. Hold the BOOTSEL button while connecting via USB (mounts as `/Volumes/RPI-RP2`)
2. Run:

```sh
make flash
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PICO_SDK_PATH` | `~/pico/pico-sdk` | Path to the Pico SDK |
| `PICO_MOUNT` | `/Volumes/RPI-RP2` | Pico mount path |

```sh
# Custom paths
make build PICO_SDK_PATH=/path/to/pico-sdk
make flash PICO_MOUNT=/Volumes/RPI-RP2
```

---

## Examples

### `Examples/RaspberryPiPicoW-BLE/`

A complete end-to-end demo: transfer a Wasm binary from an iPhone to a Pico W over BLE and execute it.

See: [Examples/RaspberryPiPicoW-BLE/README.md](Examples/RaspberryPiPicoW-BLE/README.md)