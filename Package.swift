// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokDown",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "TokDown", targets: ["TokDown"])
    ],
    targets: [
        .executableTarget(
            name: "TokDown",
            path: "Sources/TokDown",
            exclude: [
                "Resources/Info.plist",
                "Resources/TokDown.entitlements",
                "Resources/TokDownIcon.svg",
                "Resources/TokDownIcon.png",
                "Resources/TokDownMenuIdle.svg",
                "Resources/TokDownMenuRecording.svg",
                "Resources/TokDownMenuTranscribing.svg"
            ]
        ),
        .testTarget(
            name: "TokDownTests",
            dependencies: ["TokDown"],
            path: "Tests/TokDownTests"
        )
    ]
)
