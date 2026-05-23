// swift-tools-version: 6.3
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

package.targets.forEach { target in
  var settings = target.swiftSettings ?? []
  settings.append(contentsOf: [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
  ])
  target.swiftSettings = settings
}
