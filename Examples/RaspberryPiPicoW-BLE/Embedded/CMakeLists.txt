cmake_minimum_required(VERSION 3.29)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

# wholemodule is required for Embedded Swift (ensures complete elimination of unused code)
set(CMAKE_Swift_COMPILATION_MODE wholemodule)

# Skip compiler verification for bare-metal targets
set(CMAKE_Swift_COMPILER_WORKS YES)

project(pico-ble)
pico_sdk_init()
enable_language(Swift)

set(WASM_RUNTIME_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../Sources/WasmRuntime)

file(GLOB WASM_RUNTIME_SOURCES "${WASM_RUNTIME_DIR}/*.swift")

add_executable(pico-ble
    Main.swift
    wasm_recv_buf.c
    wasm_arena.c
    posix_memalign.c
    ${WASM_RUNTIME_SOURCES}
)

set_target_properties(pico-ble PROPERTIES LINKER_LANGUAGE CXX)

target_link_libraries(pico-ble
    pico_stdlib hardware_uart hardware_gpio
    pico_cyw43_arch_lwip_poll
    pico_btstack_ble
    pico_btstack_cyw43
)

target_include_directories(pico-ble PUBLIC ${CMAKE_CURRENT_LIST_DIR}/include)

# Prevent C-only flags from pico_standard_link from being passed to the Swift compiler
set_target_properties(pico_standard_link PROPERTIES INTERFACE_COMPILE_OPTIONS "")
target_compile_options(pico_standard_link INTERFACE "$<$<COMPILE_LANGUAGE:C>:SHELL: -ffunction-sections -fdata-sections>")

# Recursively collect C preprocessor definitions from Pico SDK dependencies and pass them to Swift
# (CMake does not automatically forward C definitions to swiftc, so manual collection is required)

set_property(GLOBAL PROPERTY visited_targets "")
set_property(GLOBAL PROPERTY compilerdefs_list "")

function(gather_compile_definitions_recursive target)
    get_property(visited_targets GLOBAL PROPERTY visited_targets)
    if (${target} MATCHES "\\\$<" OR ${target} MATCHES "::@" OR ${target} IN_LIST visited_targets)
        return()
    endif()
    list(APPEND visited_targets ${target})
    set_property(GLOBAL PROPERTY visited_targets "${visited_targets}")

    get_target_property(target_definitions ${target} INTERFACE_COMPILE_DEFINITIONS)
    if (target_definitions)
        get_property(compilerdefs_list GLOBAL PROPERTY compilerdefs_list)
        list(APPEND compilerdefs_list ${target_definitions})
        set_property(GLOBAL PROPERTY compilerdefs_list "${compilerdefs_list}")
    endif()

    get_target_property(target_linked_libs ${target} INTERFACE_LINK_LIBRARIES)
    if (target_linked_libs)
        foreach(linked_target ${target_linked_libs})
            gather_compile_definitions_recursive(${linked_target})
        endforeach()
    endif()
endfunction()

gather_compile_definitions_recursive(pico-ble)
get_property(COMPILE_DEFINITIONS GLOBAL PROPERTY compilerdefs_list)
get_property(INCLUDES GLOBAL PROPERTY includes_list)

list(REMOVE_DUPLICATES COMPILE_DEFINITIONS)
list(PREPEND COMPILE_DEFINITIONS "")
string(REPLACE "$<TARGET_PROPERTY:PICO_TARGET_BINARY_TYPE>" "$<TARGET_PROPERTY:pico-ble,PICO_TARGET_BINARY_TYPE>" COMPILE_DEFINITIONS "${COMPILE_DEFINITIONS}")
string(REPLACE ";" " -Xcc -D" COMPILE_DEFINITIONS "${COMPILE_DEFINITIONS}")

set(IMPLICIT_INCLUDES)
foreach(dir ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
    string(CONCAT IMPLICIT_INCLUDES ${IMPLICIT_INCLUDES} "-Xcc ")
    string(CONCAT IMPLICIT_INCLUDES ${IMPLICIT_INCLUDES} "-I${dir} ")
endforeach()
foreach(dir ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
    string(CONCAT IMPLICIT_INCLUDES ${IMPLICIT_INCLUDES} "-Xcc ")
    string(CONCAT IMPLICIT_INCLUDES ${IMPLICIT_INCLUDES} "-I${dir} ")
endforeach()

target_compile_options(pico-ble PUBLIC
    "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
        -target armv6m-none-none-eabi
        -enable-experimental-feature Embedded
        -enable-experimental-feature Extern
        -enable-upcoming-feature NonisolatedNonsendingByDefault
        -enable-upcoming-feature InferIsolatedConformances
        -parse-as-library
        -module-name pico_ble

        -Xcc -fshort-enums
        -Xfrontend -function-sections
        -Xcc -I${CMAKE_CURRENT_LIST_DIR}/include
        -import-bridging-header ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
        ${COMPILE_DEFINITIONS}
        ${IMPLICIT_INCLUDES}
    >")

# Use a custom linker script that moves Core 0 stack to main RAM (64 KB).
# The default SCRATCH_Y allocation is only 4 KB; the WebAssembly interpreter
# requires ~28 KB of stack depth (dispatchEmbedded + pushEmbeddedFrame + callers).
pico_set_linker_script(pico-ble ${CMAKE_CURRENT_LIST_DIR}/memmap_wasm.ld)

# 64 KB Core 0 stack (matches the reserved region in memmap_wasm.ld).
# pico_crt0 is an INTERFACE library: crt0.S compiles as part of pico-ble,
# so PRIVATE definitions reach the assembler correctly.
target_compile_definitions(pico-ble PRIVATE PICO_STACK_SIZE=65536)

pico_add_extra_outputs(pico-ble)
