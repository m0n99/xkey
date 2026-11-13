import Foundation

struct CaretWordReport: Equatable {
    let word: String
    let caretAtWordEnd: Bool
    let selectionAnchoredAtCaret: Bool
    let selectionLength: Int
    let elementSignature: String
    let appBundleId: String?
    let expectedRevision: UInt64
}

enum RecoveryOutcome: Equatable {
    case notApplicable, validated
    case rejected(RecoveryRejection)
}

enum RecoveryRejection: Equatable {
    case staleRevision, wordMismatch, midWordCaret
    case selectionNotAnchored, engineHasPartialWord
}

enum CaretWordParser {
    static func parse(leftContext: String, rightContext: String,
                      leftContextStartsAtFieldStart: Bool,
                      rightContextEndsAtFieldEnd: Bool) -> (word: String, caretAtWordEnd: Bool)? {
        func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return false
            }
        }

        let left = leftContext.unicodeScalars
        let suffix = left.reversed().prefix(while: isWordScalar).reversed()
        let word = String(String.UnicodeScalarView(suffix))
        if suffix.count == left.count && !leftContextStartsAtFieldStart { return nil }
        // Swift String equality is canonically equivalent; compare scalar sequences instead.
        if !word.unicodeScalars.elementsEqual(word.precomposedStringWithCanonicalMapping.unicodeScalars) {
            return nil
        }
        guard let next = rightContext.unicodeScalars.first else {
            return rightContextEndsAtFieldEnd ? (word, true) : nil
        }
        return (word, !isWordScalar(next))
    }
}
