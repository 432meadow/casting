import Foundation
import ObjCSupport

/// Smart playlist rules: archived NSPredicates evaluated against `Track` via KVC.
enum SmartPredicate {
    static func unarchive(_ data: Data) throws -> NSPredicate {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        // decodeTopLevelObject reports corrupt archives as Swift errors instead of raising NSExceptions.
        let decoded = try unarchiver.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        guard let result = decoded as? NSPredicate else {
            throw DatabaseError(message: "Archive does not contain an NSPredicate")
        }
        result.allowEvaluation()
        return result
    }

    /// Archives a predicate for storage in the `playlist` table.
    static func archive(_ predicate: NSPredicate) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: predicate, requiringSecureCoding: false)
    }

    /// Filters `tracks`, turning Objective-C exceptions (e.g. type mismatches) into a Swift error.
    static func evaluate(_ predicate: NSPredicate, on tracks: [Track]) throws -> [Track] {
        var exception: NSError?
        guard let matches = MMFilterWithPredicate(tracks, predicate, &exception) as? [Track] else {
            throw exception ?? DatabaseError(message: "Smart playlist evaluation failed")
        }
        return matches
    }
}
