// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HeadphoneLabMenu",
  platforms: [.macOS("14.2")],
  targets: [
    .executableTarget(
      name: "HeadphoneLabMenu",
      dependencies: ["AudioUnitUIBridge"],
      path: "Sources/HeadphoneLabMenu",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .target(
      name: "AudioUnitUIBridge",
      path: "Sources/AudioUnitUIBridge",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AudioToolbox"),
      ]
    ),
    .testTarget(
      name: "AudioUnitUIBridgeTests",
      dependencies: ["AudioUnitUIBridge"],
      path: "Tests/AudioUnitUIBridgeTests",
      linkerSettings: [
        .linkedFramework("AVFoundation")
      ]
    ),
  ]
)
