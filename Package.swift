// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMacExtendedDisplay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "display-prototype", targets: ["DisplayPrototype"])],
    targets: [
        .target(
            name: "DisplayBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation"), .linkedFramework("Security")]
        ),
        .executableTarget(name: "DisplayPrototype", dependencies: ["DisplayBridge"])
    ]
)
