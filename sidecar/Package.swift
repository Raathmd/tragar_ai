// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TragarCoreAI",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(
      name: "TragarCoreAI",
      path: "Sources/TragarCoreAI",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
