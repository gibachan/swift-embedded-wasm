cmake_minimum_required(VERSION 3.29)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

# Embedded Swift では wholemodule が必須（未使用コードの完全除去のため）
set(CMAKE_Swift_COMPILATION_MODE wholemodule)

# ベアメタルターゲット向けコンパイラ検証をスキップ
set(CMAKE_Swift_COMPILER_WORKS YES)

project(pico-ble)
pico_sdk_init()
enable_language(Swift)

set(WASM_RUNTIME_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../Sources/WasmRuntime)

# ── Wasm binary pipeline ────────────────────────────────────────────────────
set(BLINK_LOOP_WASM_SRC
    ${CMAKE_CURRENT_SOURCE_DIR}/../Tests/WasmRuntimeTests/wasm/blink-loop.wasm)

# [C] Build-time validation: fail the build if the wasm is malformed.
find_program(WASM_VALIDATE wasm-validate)
if(WASM_VALIDATE)
    add_custom_command(
        OUTPUT  ${CMAKE_CURRENT_BINARY_DIR}/blink-loop.wasm.validated
        COMMAND ${WASM_VALIDATE} ${BLINK_LOOP_WASM_SRC}
        COMMAND ${CMAKE_COMMAND} -E touch
                ${CMAKE_CURRENT_BINARY_DIR}/blink-loop.wasm.validated
        DEPENDS ${BLINK_LOOP_WASM_SRC}
        COMMENT "Validating blink-loop.wasm"
    )
    add_custom_target(validate-wasm DEPENDS
        ${CMAKE_CURRENT_BINARY_DIR}/blink-loop.wasm.validated)
else()
    message(WARNING "wasm-validate not found; skipping wasm validation")
endif()

# [B] Size optimization: run wasm-opt -Oz before embedding when available.
find_program(WASM_OPT wasm-opt)
if(WASM_OPT)
    set(BLINK_LOOP_WASM_PATH ${CMAKE_CURRENT_BINARY_DIR}/blink-loop.opt.wasm)
    add_custom_command(
        OUTPUT  ${BLINK_LOOP_WASM_PATH}
        COMMAND ${WASM_OPT} -Oz --strip-debug
                ${BLINK_LOOP_WASM_SRC} -o ${BLINK_LOOP_WASM_PATH}
        DEPENDS ${BLINK_LOOP_WASM_SRC}
        COMMENT "Optimizing blink-loop.wasm with wasm-opt"
    )
else()
    message(WARNING "wasm-opt not found; embedding unoptimized wasm")
    set(BLINK_LOOP_WASM_PATH ${BLINK_LOOP_WASM_SRC})
endif()

# Embed blink-loop.wasm via .incbin: configure_file substitutes the absolute
# path so the assembler can find the file regardless of build directory.
configure_file(blink_loop_wasm.s.in
               ${CMAKE_CURRENT_BINARY_DIR}/blink_loop_wasm.s
               @ONLY)

# [A] Dependency tracking: tell ninja that the object file also depends on
# the wasm binary, so changing the wasm triggers reassembly without a full
# clean rebuild.
set_source_files_properties(
    ${CMAKE_CURRENT_BINARY_DIR}/blink_loop_wasm.s
    PROPERTIES OBJECT_DEPENDS ${BLINK_LOOP_WASM_PATH}
)

add_executable(pico-ble
    Main.swift
    ${CMAKE_CURRENT_BINARY_DIR}/blink_loop_wasm.s
    wasm_symbols.c
    posix_memalign.c
    ${WASM_RUNTIME_DIR}/LEB128.swift
    ${WASM_RUNTIME_DIR}/WasmError.swift
    ${WASM_RUNTIME_DIR}/WasmModule.swift
    ${WASM_RUNTIME_DIR}/WasmParser.swift
    ${WASM_RUNTIME_DIR}/WasmInterpreter.swift
    ${WASM_RUNTIME_DIR}/WasmRuntime.swift
)

set_target_properties(pico-ble PROPERTIES LINKER_LANGUAGE CXX)

# Ensure wasm pipeline steps complete before the assembler runs.
if(WASM_VALIDATE)
    add_dependencies(pico-ble validate-wasm)
endif()
if(WASM_OPT)
    add_custom_target(optimize-wasm DEPENDS ${BLINK_LOOP_WASM_PATH})
    add_dependencies(pico-ble optimize-wasm)
endif()

target_link_libraries(pico-ble
    pico_stdlib hardware_uart hardware_gpio
    pico_cyw43_arch_lwip_poll
    pico_btstack_ble
    pico_btstack_cyw43
)

target_include_directories(pico-ble PUBLIC ${CMAKE_CURRENT_LIST_DIR}/include)

# pico_standard_link が持つ C 専用フラグを Swift コンパイラに渡さないようにする
set_target_properties(pico_standard_link PROPERTIES INTERFACE_COMPILE_OPTIONS "")
target_compile_options(pico_standard_link INTERFACE "$<$<COMPILE_LANGUAGE:C>:SHELL: -ffunction-sections -fdata-sections>")

# Pico SDK の依存ライブラリから C プリプロセッサ定義を再帰収集して Swift に渡す
# （CMake は C 定義を自動的に swiftc に渡さないため手動で収集が必要）
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

pico_add_extra_outputs(pico-ble)
