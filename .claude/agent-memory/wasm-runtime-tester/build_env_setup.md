---
name: build-env-setup
description: Build environment paths and configurations for the WASM Runtime project
metadata:
  type: reference
---

## Pico SDK
- **Path**: `~/pico/pico-sdk`
- **Status**: Available and properly configured
- **Verified**: 2026-05-30

## Swift Toolchain
- **Installed via**: swiftly
- **Location**: `~/.swiftly/bin/swiftc`
- **Current Version**: Apple Swift 6.3.2 (swift-6.3.2-RELEASE)
- **Note**: embedded stdlib warning at `~/.swiftly/lib/swift/embedded` — not present in snapshot release. Can be resolved by installing main-snapshot toolchain if needed.

## BLE Example Location
- **Path**: `Examples/RaspberryPiPicoW-BLE/Embedded/`
- **Build Command**: `make build` (from this directory)
- **Default Board**: pico_w (can override with `PICO_BOARD=pico2_w`)
- **Output Artifacts**:
  - UF2 firmware: `build/pico-ble.uf2` (~968K)
  - ELF binary: `build/pico-ble.elf` (~2.5M)

## Test Command Quick Reference
- **Level 1** (macOS unit tests): `swift test -Xswiftc -DMACOS` — runs from project root
- **Level 2** (Embedded compilation): `make compile` — runs from project root, outputs `build/pico-wasm.o`
- **Level 3** (BLE link validation): `make build` — runs from `Examples/RaspberryPiPicoW-BLE/Embedded/`
