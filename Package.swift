// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RetinaLink",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RetinaLinkCore", targets: ["RetinaLinkCore"]),
        .library(name: "RetinaLinkEngine", targets: ["RetinaLinkEngine"]),
        .executable(name: "retinalink-bench", targets: ["RetinaLinkBench"]),
        .executable(name: "RetinaLinkApp", targets: ["RetinaLinkApp"]),
        .executable(name: "RetinaLinkReceiverApp", targets: ["RetinaLinkReceiverApp"]),
    ],
    targets: [
        .target(
            name: "CVirtualDisplay",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        .target(name: "RetinaLinkCore"),
        .target(name: "RetinaLinkEngine", dependencies: ["CVirtualDisplay", "RetinaLinkCore"]),
        .executableTarget(name: "RetinaLinkBench", dependencies: ["RetinaLinkCore", "RetinaLinkEngine"]),
        .executableTarget(name: "RetinaLinkApp", dependencies: ["RetinaLinkEngine"]),
        .executableTarget(name: "RetinaLinkReceiverApp", dependencies: ["RetinaLinkEngine"]),
        .testTarget(name: "RetinaLinkCoreTests", dependencies: ["RetinaLinkCore"]),
    ]
)
