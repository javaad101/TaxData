// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaxData",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "TaxData", targets: ["TaxData"]),
    ],
    targets: [
        .target(
            name: "TaxData",
            path: "Sources/TaxData",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
