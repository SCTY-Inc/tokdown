// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokDownMobile",
    platforms: [.iOS(.v18)],
    targets: [
        .executableTarget(
            name: "TokDownMobile",
            path: "Sources/TokDownMobile"
        )
    ]
)
