#include <stdint.h>

// Symbols defined by .incbin in blink_loop_wasm.s.
// Embedded Swift cannot import incomplete array types (extern uint8_t[]),
// so these wrappers return typed values that Swift can import normally.
extern const uint8_t blink_loop_wasm_start[];
extern const uint8_t blink_loop_wasm_end[];

const uint8_t *blink_loop_wasm_ptr(void) {
    return blink_loop_wasm_start;
}

uint32_t blink_loop_wasm_len(void) {
    return (uint32_t)(blink_loop_wasm_end - blink_loop_wasm_start);
}
