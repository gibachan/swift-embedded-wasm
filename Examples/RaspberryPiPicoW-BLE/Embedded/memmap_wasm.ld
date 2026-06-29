/* memmap_wasm.ld — custom linker script for pico-ble (WebAssembly runtime)
 *
 * Derived from pico-sdk/src/rp2_common/pico_crt0/rp2040/memmap_default.ld.
 * Key change: moves Core 0 stack from SCRATCH_Y (4 KB) to the top of main
 * RAM (64 KB), giving the WebAssembly interpreter enough headroom for its
 * ~28 KB peak call chain (dispatchEmbedded + pushEmbeddedFrame + callers).
 *
 * Memory layout (RAM, 256 KB total at 0x20000000):
 *   .data / .bss / heap  — 0x20000000 upwards  (~161 KB currently)
 *   free gap             — available for heap growth
 *   Core 0 stack (64 KB) — 0x20030000–0x2003FFFF, grows DOWN
 *   [__StackTop = 0x20040000, __StackLimit = 0x20030000]
 *
 * SCRATCH_X (4 KB at 0x20040000) and SCRATCH_Y (4 KB at 0x20041000) are
 * left free for Core 1 or future use.
 */

MEMORY
{
    INCLUDE "pico_flash_region.ld"
    RAM(rwx) : ORIGIN =  0x20000000, LENGTH = 256k
    SCRATCH_X(rwx) : ORIGIN = 0x20040000, LENGTH = 4k
    SCRATCH_Y(rwx) : ORIGIN = 0x20041000, LENGTH = 4k
}

ENTRY(_entry_point)

SECTIONS
{
    .flash_begin : {
        __flash_binary_start = .;
    } > FLASH

    .boot2 : {
        __boot2_start__ = .;
        KEEP (*(.boot2))
        __boot2_end__ = .;
    } > FLASH

    ASSERT(__boot2_end__ - __boot2_start__ == 256,
        "ERROR: Pico second stage bootloader must be 256 bytes in size")

    .text : {
        __logical_binary_start = .;
        KEEP (*(.vectors))
        KEEP (*(.binary_info_header))
        __binary_info_header_end = .;
        KEEP (*(.embedded_block))
        __embedded_block_end = .;
        KEEP (*(.reset))
        *(.init)
        *(EXCLUDE_FILE(*libgcc.a: *libc.a:*lib_a-mem*.o *libm.a:) .text*)
        *(.fini)
        *crtbegin.o(.ctors)
        *crtbegin?.o(.ctors)
        *(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
        *(SORT(.ctors.*))
        *(.ctors)
        *crtbegin.o(.dtors)
        *crtbegin?.o(.dtors)
        *(EXCLUDE_FILE(*crtend?.o *crtend.o) .dtors)
        *(SORT(.dtors.*))
        *(.dtors)
        . = ALIGN(4);
        PROVIDE_HIDDEN (__preinit_array_start = .);
        KEEP(*(SORT(.preinit_array.*)))
        KEEP(*(.preinit_array))
        PROVIDE_HIDDEN (__preinit_array_end = .);
        . = ALIGN(4);
        PROVIDE_HIDDEN (__init_array_start = .);
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN (__init_array_end = .);
        . = ALIGN(4);
        PROVIDE_HIDDEN (__fini_array_start = .);
        *(SORT(.fini_array.*))
        *(.fini_array)
        PROVIDE_HIDDEN (__fini_array_end = .);
        *(.eh_frame*)
        . = ALIGN(4);
    } > FLASH

    .rodata : {
        *(EXCLUDE_FILE(*libgcc.a: *libc.a:*lib_a-mem*.o *libm.a:) .rodata*)
        . = ALIGN(4);
        *(SORT_BY_ALIGNMENT(SORT_BY_NAME(.flashdata*)))
        . = ALIGN(4);
    } > FLASH

    .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } > FLASH

    __exidx_start = .;
    .ARM.exidx : { *(.ARM.exidx* .gnu.linkonce.armexidx.*) } > FLASH
    __exidx_end = .;

    . = ALIGN(4);
    __binary_info_start = .;
    .binary_info : {
        KEEP(*(.binary_info.keep.*))
        *(.binary_info.*)
    } > FLASH
    __binary_info_end = .;
    . = ALIGN(4);

    .ram_vector_table (NOLOAD): { *(.ram_vector_table) } > RAM

    .uninitialized_data (NOLOAD): {
        . = ALIGN(4);
        *(.uninitialized_data*)
    } > RAM

    .data : {
        __data_start__ = .;
        *(vtable)
        *(.time_critical*)
        *(.text*)
        . = ALIGN(4);
        *(.rodata*)
        . = ALIGN(4);
        *(.data*)
        . = ALIGN(4);
        *(.after_data.*)
        . = ALIGN(4);
        PROVIDE_HIDDEN (__mutex_array_start = .);
        KEEP(*(SORT(.mutex_array.*)))
        KEEP(*(.mutex_array))
        PROVIDE_HIDDEN (__mutex_array_end = .);
        . = ALIGN(4);
        *(.jcr)
        . = ALIGN(4);
    } > RAM AT> FLASH

    .tdata : {
        . = ALIGN(4);
        *(.tdata .tdata.* .gnu.linkonce.td.*)
        __tdata_end = .;
    } > RAM AT> FLASH
    PROVIDE(__data_end__ = .);

    __etext = LOADADDR(.data);

    .tbss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start__ = .;
        __tls_base = .;
        *(.tbss .tbss.* .gnu.linkonce.tb.*)
        *(.tcommon)
        __tls_end = .;
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __tbss_end = .;
        *(SORT_BY_ALIGNMENT(SORT_BY_NAME(.bss*)))
        *(COMMON)
        . = ALIGN(4);
        __bss_end__ = .;
    } > RAM

    .heap (NOLOAD): {
        __end__ = .;
        end = __end__;
        KEEP(*(.heap*))
    } > RAM

    /* Core 0 stack — placed in main RAM (64 KB) instead of SCRATCH_Y (4 KB).
     * The WebAssembly interpreter's peak call chain requires ~28 KB of stack.
     * 64 KB provides a comfortable safety margin.
     *
     * Force the location counter to 0x20030000 (= RAM top - 64 KB) so that
     * SIZEOF(.stack_dummy) = 65536 and the ASSERT below catches any BSS overflow.
     */
    . = ORIGIN(RAM) + LENGTH(RAM) - 65536;
    .stack_dummy (NOLOAD): {
        KEEP(*(.stack*))
    } > RAM

    .scratch_x : {
        __scratch_x_start__ = .;
        *(.scratch_x.*)
        . = ALIGN(4);
        __scratch_x_end__ = .;
    } > SCRATCH_X AT > FLASH
    __scratch_x_source__ = LOADADDR(.scratch_x);

    .scratch_y : {
        __scratch_y_start__ = .;
        *(.scratch_y.*)
        . = ALIGN(4);
        __scratch_y_end__ = .;
    } > SCRATCH_Y AT > FLASH
    __scratch_y_source__ = LOADADDR(.scratch_y);

    /* Core 1 stack (not used in this single-core build) */
    .stack1_dummy (NOLOAD): { *(.stack1*) } > SCRATCH_X

    .flash_end : {
        KEEP(*(.embedded_end_block*))
        PROVIDE(__flash_binary_end = .);
    } > FLASH

    /* Stack symbols — Core 0 stack now lives at the TOP of main RAM.
     * __StackTop    = top of RAM (initial SP for Core 0)
     * __StackBottom = __StackTop - SIZEOF(.stack_dummy)
     * __StackLimit  = __StackBottom (stop heap before stack)
     */
    __StackOneTop    = ORIGIN(SCRATCH_X) + LENGTH(SCRATCH_X);
    __StackOneBottom = __StackOneTop - SIZEOF(.stack1_dummy);
    __StackTop    = ORIGIN(RAM) + LENGTH(RAM);
    __StackBottom = __StackTop - SIZEOF(.stack_dummy);
    PROVIDE(__stack = __StackTop);

    /* Heap ends where the stack begins */
    __HeapLimit = __StackBottom;
    __StackLimit = __StackBottom;

    ASSERT(__StackBottom >= __bss_end__, "Stack overflows into BSS — increase RAM or reduce stack size")
    ASSERT(__binary_info_header_end - __logical_binary_start <= 256, "Binary info must be in first 256 bytes of the binary")

    PROVIDE (__heap_start = __end__);
    PROVIDE (__heap_end = __HeapLimit);
    PROVIDE( __tls_align = MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)) );
    PROVIDE( __tls_size_align = (__tls_size + __tls_align - 1) & ~(__tls_align - 1));
    PROVIDE( __arm32_tls_tcb_offset = MAX(8, __tls_align) );
    PROVIDE (_end = __end__);
    PROVIDE (__llvm_libc_heap_limit = __HeapLimit);
}
