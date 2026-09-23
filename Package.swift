// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tetris3D",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TetrisCore"),
        .target(name: "MetaGame", dependencies: ["TetrisCore"]),
        .executableTarget(name: "Tetris3D", dependencies: ["TetrisCore", "MetaGame"]),
        .testTarget(name: "TetrisCoreTests", dependencies: ["TetrisCore"]),
        .testTarget(name: "MetaGameTests", dependencies: ["MetaGame", "TetrisCore"]),
    ]
)
