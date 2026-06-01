# RaspberryPiPicoW-BLE

This example demonstrates a WebAssembly runtime built with Embedded Swift running on a Raspberry Pi Pico W. A WASM file is transferred from an iOS app to the Pico W over BLE and executed by the WASM runtime, causing the onboard LED to blink.

<video src="https://github.com/user-attachments/assets/59177287-436a-430d-8c04-f2e32f57579b" width="400" controls></video>

## Requirements

* A Raspberry Pi Pico W or Pico 2W board.
* The following tools and resources for building the Embedded firmware:
  * A checkout of the [pico-sdk](https://github.com/raspberrypi/pico-sdk.git), with git submodules checked out.
  * CMake and Ninja.
  * The [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads).
  * Swift 6.3.1 or later.
* Xcode for building the iOS companion app.

## Structure

| Directory | Description |
|-----------|-------------|
| `Embedded/` | Embedded Swift firmware for the Pico W — BLE peripheral logic and WASM execution |
| `iOS/` | iOS companion app — discovers the device over BLE and transfers WASM binaries |

## Building the Firmware

* Edit the environment variables in `Embedded/build.sh` to match your local paths, then run:

```
$ cd Embedded
$ ./build.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PICO_BOARD` | `pico_w` | Use `pico2_w` for Pico 2W |
| `PICO_SDK_PATH` | `~/pico/pico-sdk` | Path to your pico-sdk checkout |
| `PICO_TOOLCHAIN_PATH` | `/opt/homebrew` | Path to the Arm toolchain |
| `SWIFT_TOOLCHAIN` | `~/Library/Developer/Toolchains/swift-6.3.1-RELEASE.xctoolchain/usr` | Path to the Swift toolchain |

* If you modify `CMakeLists.txt`, clean the build directory before rebuilding:

```
$ rm -rf Embedded/build && ./Embedded/build.sh
```

## Flashing the Firmware

* Connect the Pico W in BOOTSEL mode (hold the BOOTSEL button while plugging in via USB).
* Copy the UF2 firmware to the Mass Storage device:

```
$ cp Embedded/build/pico-ble.uf2 /Volumes/RP2040   # Pico W
$ cp Embedded/build/pico-ble.uf2 /Volumes/RP2350   # Pico 2W
```

## Building the iOS App

* Open `iOS/Demo.xcodeproj` in Xcode.
* Select your target device and build.

## Running

1. Flash the firmware to the Pico W.
2. Launch the iOS app — it will automatically discover and connect to `PicoLED` over BLE.
3. Select a WASM module from the list and tap **Send**.
4. After the transfer completes, the Pico's LED will blink as defined by the WASM module.
