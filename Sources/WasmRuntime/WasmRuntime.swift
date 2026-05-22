// Wasm バイナリのマジックナンバーとバージョン
// すべての .wasm ファイルは先頭 8 バイトがこの値になっている
public let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]   // "\0asm"
public let wasmVersion: [UInt8] = [0x01, 0x00, 0x00, 0x00]  // version 1
