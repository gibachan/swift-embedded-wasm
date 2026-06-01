// Embedded Swift's swift_allocObject uses posix_memalign to allocate heap memory.
// The Pico SDK's newlib configuration does not include this function, so we provide
// a wrapper around malloc.
//
// Pico's malloc guarantees 8-byte alignment, which satisfies the alignment
// requirement of Swift on Cortex-M0+ (max 8 bytes), so the alignment argument
// can be safely ignored.

#include <stddef.h>
#include <stdlib.h>

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    (void)alignment;
    void *ptr = malloc(size);
    if (!ptr) return 12; // ENOMEM
    *memptr = ptr;
    return 0;
}
