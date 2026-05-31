#include <stdint.h>

#define WASM_RECV_BUF_SIZE (8 * 1024)
static uint8_t buf[WASM_RECV_BUF_SIZE];

uint8_t *wasm_recv_buf_ptr(void) { return buf; }
uint32_t wasm_recv_buf_size(void) { return WASM_RECV_BUF_SIZE; }
