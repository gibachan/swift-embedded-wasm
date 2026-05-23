// Embedded Swift の swift_allocObject は posix_memalign を使ってヒープを確保する。
// Pico SDK の newlib 構成にはこの関数が含まれていないため、malloc でラップして提供する。
//
// Pico の malloc は 8 バイトアライメントを保証しており、Cortex-M0+ 上の Swift が
// 要求するアライメント（最大 8 バイト）を満たすため、alignment 引数は無視してよい。

#include <stddef.h>
#include <stdlib.h>

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    (void)alignment;
    void *ptr = malloc(size);
    if (!ptr) return 12; // ENOMEM
    *memptr = ptr;
    return 0;
}
