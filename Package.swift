// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-embedded-wasm",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "WasmRuntime",
            path: "Sources/WasmRuntime"
        ),
        .testTarget(
            name: "WasmRuntimeTests",
            dependencies: ["WasmRuntime"],
            path: "Tests/WasmRuntimeTests"
        ),
    ]
)
