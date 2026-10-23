// swift-tools-version: 6.0
import PackageDescription

// libpq is keg-only in Homebrew, so its paths are passed explicitly.
let libpqPrefix = "/opt/homebrew/opt/libpq"

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CLibPQ", providers: [.brew(["libpq"])]),
        .target(
            name: "TabulaCore",
            dependencies: ["CLibPQ"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(libpqPrefix)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(libpqPrefix)/lib"])]
        ),
        .executableTarget(
            name: "Tabula",
            dependencies: ["TabulaCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(libpqPrefix)/include"])]
        ),
        .testTarget(
            name: "TabulaCoreTests",
            dependencies: ["TabulaCore"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(libpqPrefix)/include"])]
        ),
    ]
)
