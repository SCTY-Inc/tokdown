// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuBarRecorder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MenuBarRecorder", targets: ["MenuBarRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "MenuBarRecorder",
            path: "Sources/MenuBarRecorder",
            exclude: ["Resources/Info.plist", "Resources/MenuBarRecorder.entitlements"]
        )
    ]
)
