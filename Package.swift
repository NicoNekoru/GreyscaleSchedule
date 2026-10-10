// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreyscaleSchedule",
    platforms: [.macOS("26.0")],
    products: [.library(name: "GreyscaleCore", targets: ["GreyscaleCore"])],
    targets: [
        .target(name: "GreyscaleCore", path: "Sources/GreyscaleSchedule",
                exclude: ["main.swift", "AppDelegate.swift", "ControlExtension.swift",
                          "GreyscaleControlIntent.swift"],
                sources: ["SharedConfiguration.swift", "DisplayState.swift", "DisplayFilter.swift",
                          "ControlRequest.swift", "ControlService.swift", "ProcessRunner.swift",
                          "ControlRequestAgent.swift", "Schedule.swift", "ControlIdentity.swift",
                          "ControlCenterIntegration.swift"]),
        .testTarget(name: "GreyscaleCoreTests", dependencies: ["GreyscaleCore"], path: "Tests")
    ]
)
