# UART

## What is UART?

UART (Universal Asynchronous Receiver/Transmitter) is a serial communication protocol that transmits data one bit at a time over two wires.

```
Pico                    PC
TX ──────────────────→ RX   (Pico sends data to PC)
RX ←────────────────── TX   (PC sends data to Pico)
GND ─────────────────── GND (shared ground)
```

- Data is sent **one bit at a time in sequence** (serial = in a line)
- No clock signal is required — both sides agree on a fixed speed called the **baud rate** (e.g., 115200 bits per second)
- "Asynchronous" means the timing of transmission and reception is not synchronized by an external signal; instead, each side independently tracks timing based on the agreed baud rate

---

## How It Works on the Pico

The Raspberry Pi Pico (RP2350) exposes its UART over USB as a **USB CDC (Communications Device Class)** serial port. This means a single USB cable is enough — no extra hardware needed.

```swift
// Embedded Swift + Pico SDK
stdio_init_all()           // Initialize USB CDC / UART
print("Hello from Pico!")  // Appears in the serial monitor on your PC
```

On the PC side, open the serial port with a terminal tool:

```bash
# macOS
screen /dev/tty.usbmodem* 115200

# or with minicom
minicom -b 115200 -D /dev/tty.usbmodem*
```

---

## Why UART Matters for This Project

The Pico has no display. UART is the **only way to observe what is happening at runtime**.

Typical uses in this project:

| Use case | Example output |
|---|---|
| Confirm the firmware is running | `"Hello from Embedded Swift"` |
| Print Wasm execution results | `"result: 7"` |
| Report errors and traps | `"trap: memoryAccessOutOfBounds at pc=42"` |
| Show module load progress | `"module loaded: 3 functions, 1 memory"` |

Without UART, the only feedback is whether the LED is on or off — making it nearly impossible to debug the Wasm runtime on real hardware.

---

## Role in the TODO

The first hardware verification task is:

> **Confirm that log output appears over UART**
>
> Use `stdio_init_all()` and `print()` to send `"Hello from Embedded Swift\n"` over USB CDC.
> Receiving it in a serial monitor confirms that Embedded Swift code is actually executing on the Pico.

This is the minimal proof that the firmware was flashed correctly and the runtime environment works before testing anything Wasm-related.
