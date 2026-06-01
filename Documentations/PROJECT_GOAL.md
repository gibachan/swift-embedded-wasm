# Project Goals

## Target Hardware

| Category | Hardware |
|----------|----------|
| Primary | Raspberry Pi Pico 2 (RP2350) |
| Secondary | Raspberry Pi Pico W |

---

## Background and Motivation

In conventional embedded development, every new feature requires rebuilding and reflashing the firmware.

```text
Swift Source → Firmware Build → Flash (required every time)
```

By embedding a Wasm Runtime, new functionality can be added dynamically without changing the firmware.

```text
Embedded Swift Runtime (flashed once)
   ↓
Upload Wasm Script (only script replacement needed afterwards)
   ↓
Dynamic Execution
```

This enables:

- Post-deployment feature additions
- OTA script updates
- Sandboxed safe execution
- Plugin-style extensibility
- Scriptable Device capability

---

## The System to Build

Transfer a Wasm binary wirelessly from an iPhone app to a Raspberry Pi Pico, where an Embedded Swift Runtime dynamically executes it to control GPIO, OLED, and sensors.

```text
iPhone App
   │
   │ BLE / Wi-Fi (Wasm binary transfer)
   ▼
Raspberry Pi Pico 2 (RP2350)
   │
   │ Embedded Swift Runtime
   │   ├── Wasm Binary Parser
   │   ├── Wasm Interpreter
   │   │     ├── Stack Machine
   │   │     ├── Linear Memory
   │   │     └── Validation
   │   └── Host Function Layer
   │         ├── GPIO
   │         ├── OLED
   │         └── Sensor
   ▼
Hardware Control
```

---

## Deliverables

### 1. Wasm Binary Parser

A library that parses Wasm binary format (`.wasm`).

- LEB128 decoding
- Section parsing (Type / Function / Code / Export)
- Opcode decoding
- Embedded Swift constraints (minimized dynamic allocation)

### 2. Wasm Interpreter

A Stack Machine-based interpreter that executes parsed Wasm modules.

- Operand Stack / Call Stack / Frame management
- Instruction set: i32 / i64 / f32 / f64 full arithmetic, comparison, conversion; control flow; memory load/store; Bulk Memory/Table; reference types (Wasm 2.0 major subset)
- Type Validation (pre-execution static verification)
- Linear Memory (with bounds checking)

### 3. Host Function Layer

An API bridge for Wasm to control Pico hardware.

| Host API | Function |
|----------|----------|
| `digitalWrite(pin, value)` | GPIO output control |
| `digitalRead(pin)` | GPIO input read |
| `sleep(ms)` | Delay |
| `oledDrawText(x, y, text)` | OLED display |

### 4. Embedded Swift Runtime (runs on Pico)

Firmware that integrates the above components and runs on the Raspberry Pi Pico 2 (RP2350).

- Load, execute, and unload Wasm modules
- Dynamic switching between multiple Wasm apps
- Memory constraint support (Fixed-size / Arena Allocator)

### 5. iOS Controller App

A Swift iOS app for controlling the Pico from an iPhone.

- BLE-based Wasm binary transfer (Wi-Fi is future work)
- Real-time runtime log display
- Wasm script management
- OLED preview and device monitor

---

## Success Criteria

| Level | Condition |
|-------|-----------|
| **Minimum** | Execute Wasm on Pico and control GPIO from Wasm |
| **Intermediate** | Upload and execute Wasm from iPhone via BLE |
| **Final** | Operate as a Scriptable Device with dynamic switching between multiple Wasm apps |

---

## Future Extensions (Out of Scope)

The following directions are out of scope for this project but represent potential growth areas.

- **WASI subset**: Support for standard Wasm System Interface
- **Bytecode optimization**: Speedup via Predecode / Threaded Interpreter
- **Component Model**: Research and experimentation with the Wasm Component Model
- **Mini Scheduler**: Simple scheduling of multiple Wasm tasks
