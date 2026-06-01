# wasm/

This directory contains WebAssembly text format (`.wat`) files used for verifying and testing the Runtime.

## File Structure

| File | Description |
|---|---|
| `*.wat` | WebAssembly text format source files |
| `*.wasm` | Binaries converted from `.wat` via `wat2wasm` (generated, not tracked by git) |

## Prerequisites

Requires the `wat2wasm` command from [wabt](https://github.com/WebAssembly/wabt).

```sh
brew install wabt
```

## Usage

```sh
# Move to the wasm/ directory
cd wasm

# Convert all .wat files to .wasm
make

# Convert a specific file
make i32-add.wasm

# Delete generated .wasm files
make clean
```

## Adding .wat Files

1. Create a `<name>.wat` file in this directory
2. Run `make` to generate `<name>.wasm`
