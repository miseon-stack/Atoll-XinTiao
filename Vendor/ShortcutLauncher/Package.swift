// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ShortcutLauncher",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "ShortcutLauncherCore",
      targets: ["ShortcutLauncherCore"]
    ),
    .library(
      name: "ShortcutLauncherUI",
      targets: ["ShortcutLauncherUI"]
    ),
    .executable(
      name: "ShortcutLauncherHostDemo",
      targets: ["ShortcutLauncherHostDemo"]
    ),
    .executable(
      name: "ShortcutLauncherIntegrationFixture",
      targets: ["ShortcutLauncherIntegrationFixture"]
    ),
  ],
  targets: [
    .target(
      name: "ShortcutLauncherCore"
    ),
    .target(
      name: "ShortcutLauncherUI",
      dependencies: ["ShortcutLauncherCore"]
    ),
    .executableTarget(
      name: "ShortcutLauncherHostDemo",
      dependencies: [
        "ShortcutLauncherCore",
        "ShortcutLauncherUI",
      ],
      path: "HostDemo/ShortcutLauncherHostDemo"
    ),
    .executableTarget(
      name: "ShortcutLauncherIntegrationFixture",
      dependencies: [
        "ShortcutLauncherCore",
        "ShortcutLauncherUI",
      ],
      path: "IntegrationFixture"
    ),
    .testTarget(
      name: "ShortcutLauncherCoreTests",
      dependencies: ["ShortcutLauncherCore"]
    ),
    .testTarget(
      name: "ShortcutLauncherUITests",
      dependencies: [
        "ShortcutLauncherCore",
        "ShortcutLauncherUI",
      ]
    ),
    .testTarget(
      name: "ShortcutLauncherPublicAPITests",
      dependencies: [
        "ShortcutLauncherCore",
        "ShortcutLauncherUI",
      ]
    ),
  ]
)
