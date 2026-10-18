// Minimal swift-testing runner for machines with only the Command Line Tools.
// SwiftPM's helper there only drives XCTest, so `swift test` builds swift-testing suites but
// never runs them. This loads the built test bundle and hands control to swift-testing.
import Foundation
import Testing

guard let bundle = ProcessInfo.processInfo.environment["TEST_BUNDLE_BINARY"],
      dlopen(bundle, RTLD_NOW) != nil else {
    FileHandle.standardError.write(Data("Can't load test bundle: \(String(cString: dlerror()))\n".utf8))
    exit(2)
}
await Testing.__swiftPMEntryPoint() as Never
