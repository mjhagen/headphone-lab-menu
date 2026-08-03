// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HeadphoneEQ",
  platforms: [.macOS("14.2")],
  targets: [
    .executableTarget(
      name: "HeadphoneEQ",
      dependencies: ["AudioBridge"],
      path: "Sources/HeadphoneLabMenu",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Accelerate"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .target(
      name: "AudioBridge",
      path: "Sources/AudioUnitUIBridge",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AudioToolbox"),
      ]
    ),
    .testTarget(
      name: "HeadphoneEQTests",
      dependencies: ["AudioBridge", "HeadphoneEQ"],
      path: "Tests",
      linkerSettings: [
        .linkedFramework("AVFoundation")
      ]
    ),
  ]
)
