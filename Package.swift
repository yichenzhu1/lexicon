// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lexicon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MdxKit", targets: ["MdxKit"]),
        .executable(name: "Lexicon", targets: ["Lexicon"]),
    ],
    targets: [
        .target(
            name: "MdxKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Lexicon",
            dependencies: ["MdxKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ship neither XCTest nor swift-testing, so unit
        // tests run through this standalone executable: `swift run mdxkit-tests`
        .executableTarget(
            name: "MdxKitTester",
            dependencies: ["MdxKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
