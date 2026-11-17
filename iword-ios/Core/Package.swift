// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IWordCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "IWordDomain", targets: ["IWordDomain"]),
        .library(name: "IWordStorage", targets: ["IWordStorage"])
    ],
    targets: [
        .target(name: "IWordDomain", path: "Domain"),
        .target(name: "IWordStorage", path: "Storage", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "IWordDomainTests", dependencies: ["IWordDomain"], path: "Tests/IWordDomainTests", resources: [.copy("Fixtures")]),
        .testTarget(name: "IWordStorageTests", dependencies: ["IWordStorage"], path: "Tests/IWordStorageTests")
    ]
)
