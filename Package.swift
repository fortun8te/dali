// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "beam",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "BeamCapture"),
        .target(name: "BeamEngine"),
        .executableTarget(name: "beam-capture", dependencies: ["BeamCapture"]),
        .executableTarget(name: "beam-engine", dependencies: ["BeamEngine"]),
        .testTarget(name: "BeamCaptureTests", dependencies: ["BeamCapture"]),
        .testTarget(name: "BeamEngineTests", dependencies: ["BeamEngine"]),
    ]
)
