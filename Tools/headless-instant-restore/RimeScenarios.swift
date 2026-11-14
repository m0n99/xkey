import Foundation

func testRimeStatus() {
    typealias Validator = VowelSequenceValidator
    for vowel in VNVowel.allCases {
        for hasCoda in [false, true] {
            check(Validator.rimeStatus(for: [vowel], hasConsonantSuffix: hasCoda) == .valid,
                  "single vowel \(vowel) is valid with coda=\(hasCoda)")
        }
    }

    let openFamilies: [[VNVowel]] = [
        [.a, .i], [.a, .o], [.a, .u], [.a, .y], [.e, .o],
        [.i, .u], [.o, .i], [.u, .i], [.uHorn, .u],
        [.i, .eCircumflex, .u], [.u, .oCircumflex, .i]
    ]
    for vowels in openFamilies {
        check(Validator.rimeStatus(for: vowels, hasConsonantSuffix: false) != .impossible,
              "open family \(vowels) remains possible")
        check(Validator.rimeStatus(for: vowels, hasConsonantSuffix: true) == .impossible,
              "open family \(vowels) rejects a consonant coda")
    }

    let codaFamilies: [[VNVowel]] = [
        [.o, .a], [.o, .aBreve], [.o, .e], [.u, .aCircumflex],
        [.u, .eCircumflex], [.i, .eCircumflex], [.u, .oCircumflex],
        [.uHorn, .oHorn], [.u, .y], [.u, .y, .eCircumflex]
    ]
    for vowels in codaFamilies {
        check(Validator.rimeStatus(for: vowels, hasConsonantSuffix: true) != .impossible,
              "coda-compatible family \(vowels) remains possible")
    }
    for vowels: [VNVowel] in [[.i, .e], [.u, .o], [.u, .y, .e]] {
        for hasCoda in [false, true] {
            check(Validator.rimeStatus(for: vowels, hasConsonantSuffix: hasCoda) != .impossible,
                  "late shape remains possible for \(vowels), coda=\(hasCoda)")
        }
    }
}
