import Foundation
import Testing
@testable import Casting

@Suite struct SmartPredicateTests {
    @Test func smartPredicateTypeMismatchIsAnErrorNotACrash() throws {
        let track = Track(id: 1)
        track.title = "x"
        // Comparing a string property with a number operator raises an NSException inside Foundation.
        let predicate = NSPredicate(format: "title > 5")
        #expect(throws: (any Error).self) { try SmartPredicate.evaluate(predicate, on: [track]) }
    }

    @Test func unknownPredicateKeysDoNotCrash() throws {
        let track = Track(id: 1)
        track.albumArtist = "Various"
        #expect(NSPredicate(format: "albumartist == 'Various'").evaluate(with: track))
        #expect(!NSPredicate(format: "someFutureKey == 'x'").evaluate(with: track))
    }
}
