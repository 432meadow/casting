// swift-tools-version: 6.0
import PackageDescription

let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "Casting",
    platforms: [.macOS(.v14)],
    targets: [
        // Tiny Objective-C shim so Swift can survive NSExceptions thrown by
        // NSPredicate / KVC when evaluating imported smart playlists.
        .target(name: "ObjCSupport", linkerSettings: [.linkedFramework("AVFoundation")]),
        .executableTarget(
            name: "Casting",
            dependencies: ["ObjCSupport"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CastingTests",
            dependencies: ["Casting"],
            // With only the Command Line Tools (no Xcode), swift-testing lives outside the default search path.
            swiftSettings: [.unsafeFlags(["-F", commandLineToolsFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", commandLineToolsFrameworks, "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
