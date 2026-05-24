#pragma once

#include <stdint.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "btstack.h"
#include "ble/att_db_util.h"

const uint8_t *blink_loop_wasm_ptr(void);
uint32_t blink_loop_wasm_len(void);
