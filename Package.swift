// swift-tools-version: 6.0
import PackageDescription

let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "Casting",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates from GitHub releases (see scripts/release.sh and .github/workflows/release.yml).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        // Tiny Objective-C shim so Swift can survive NSExceptions thrown by
        // NSPredicate / KVC when evaluating imported smart playlists.
        .target(name: "ObjCSupport", linkerSettings: [.linkedFramework("AVFoundation")]),
        .executableTarget(
            name: "Casting",
            dependencies: ["ObjCSupport", .product(name: "Sparkle", package: "Sparkle")],
            // scripts/bundle.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.linkedLibrary("sqlite3"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
