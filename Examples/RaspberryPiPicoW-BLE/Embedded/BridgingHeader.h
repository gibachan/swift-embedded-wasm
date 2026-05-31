#pragma once

#include <stdint.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "btstack.h"
#include "ble/att_db_util.h"

uint8_t *wasm_recv_buf_ptr(void);
uint32_t wasm_recv_buf_size(void);
