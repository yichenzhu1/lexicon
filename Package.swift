// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lexicon",
    // Lexicon intentionally follows the current macOS SDK instead of carrying
    // compatibility code for older releases.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MdxKit", targets: ["MdxKit"]),
        .executable(name: "Lexicon", targets: ["Lexicon"]),
    ],
    targets: [
        .target(
            name: "CLzokay",
            path: "Sources/CLzokay",
            publicHeadersPath: "lzokay-c"
        ),
        .target(
            name: "MdxKit",
            dependencies: ["CLzokay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Lexicon",
            dependencies: ["MdxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command Line Tools ship neither XCTest nor swift-testing, so unit
        // tests run through this standalone executable: `swift run MdxKitTester`
        .executableTarget(
            name: "MdxKitTester",
            dependencies: ["MdxKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
