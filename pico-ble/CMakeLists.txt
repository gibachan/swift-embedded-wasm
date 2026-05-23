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

add_executable(pico-ble
    Main.swift
    WasmBinary.swift
    posix_memalign.c
    ${WASM_RUNTIME_DIR}/LEB128.swift
    ${WASM_RUNTIME_DIR}/WasmError.swift
    ${WASM_RUNTIME_DIR}/WasmModule.swift
    ${WASM_RUNTIME_DIR}/WasmParser.swift
    ${WASM_RUNTIME_DIR}/WasmInterpreter.swift
    ${WASM_RUNTIME_DIR}/WasmRuntime.swift
)

set_target_properties(pico-ble PROPERTIES LINKER_LANGUAGE CXX)

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
