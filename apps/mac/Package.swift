// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "LocalSwitch", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "LocalSwitch", targets: ["LocalSwitchMac"]),
    .executable(name: "LocalSwitchSmoke", targets: ["LocalSwitchSmoke"]),
  ],
  targets: [
    .target(name: "LocalSwitchCore"),
    .executableTarget(name: "LocalSwitchMac", dependencies: ["LocalSwitchCore"]),
    .executableTarget(name: "LocalSwitchSmoke", dependencies: ["LocalSwitchCore"]),
    .testTarget(name: "LocalSwitchCoreTests", dependencies: ["LocalSwitchCore"]),
    .testTarget(name: "LocalSwitchMacTests", dependencies: ["LocalSwitchMac", "LocalSwitchCore"]),
  ])
