#include <stdint.h>

#define WASM_ARENA_SIZE (96 * 1024)
static uint8_t arena_buf[WASM_ARENA_SIZE] __attribute__((aligned(8)));

uint8_t *wasm_arena_ptr(void) { return arena_buf; }
uint32_t wasm_arena_size(void) { return WASM_ARENA_SIZE; }
