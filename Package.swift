// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HeadphoneEQ",
  platforms: [.macOS("14.2")],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
  ],
  targets: [
    .executableTarget(
      name: "HeadphoneEQ",
      dependencies: [
        "AudioBridge",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/HeadphoneLabMenu",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Accelerate"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("ServiceManagement"),
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ]),
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
        .linkedFramework("AVFoundation"),
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@loader_path/../../..",
        ]),
      ]
    ),
  ]
)
