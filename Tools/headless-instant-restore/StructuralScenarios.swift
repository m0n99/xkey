import Foundation

func testStructuralRestore() {
    for (keys, trigger) in [("music", 4), ("MUSIC", 4), ("MuSiC", 4),
                            ("expression", 2), ("dispute", 4)] {
        for orthography in [0, 1] {
            let screen = Screen(prefix: "@")
            screen.engine.vUseModernOrthography = orthography
            var typed = ""
            for (index, char) in keys.enumerated() {
                typed.append(char)
                screen.key(char)
                let instant = screen.engine.hookState.extCode == 5
                if index < trigger {
                    check(!instant, "\(keys) has no premature restore at \(typed)")
                } else if index == trigger {
                    check(instant, "\(keys) restores at \(typed)")
                } else {
                    check(!instant, "\(keys) restores only once at \(typed)")
                }
                if index >= trigger {
                    check(screen.text == "@" + typed && screen.rawMatches(typed),
                          "\(keys) literal continuation and raw case at \(typed): \(screen.text)")
                }
            }
        }
    }

    let screen = Screen()
    screen.engine.vInputType = 1
    screen.type("mu1i")
    check(screen.engine.hookState.extCode != 5, "VNI mu1i remains possible")
    screen.key("c")
    check(screen.engine.hookState.extCode == 5 && screen.text == "mu1ic",
          "VNI consumed digit is restored in raw order: \(screen.text)")
    check(screen.rawMatches("mu1ic"), "VNI raw history includes digit metadata")
}

func testDisabledBoundaryRestore() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    defer { settings.instantRestoreOnWrongSpelling = previous }
    for boundary: Character in [" ", "."] {
        for word in ["exp", "music", "dispute"] {
            settings.instantRestoreOnWrongSpelling = false
            let screen = Screen()
            for char in word {
                screen.key(char)
                check(screen.engine.hookState.extCode != 5, "OFF \(word) does not restore before \(boundary)")
            }
            check(screen.text != word, "OFF keeps transformed prefix before boundary: \(screen.text)")
            screen.boundary(boundary)
            check(screen.text == "\(word)\(boundary)", "OFF restores on boundary: \(screen.text)")
            screen.type("tieengs")
            check(screen.text == "\(word)\(boundary)tiếng", "next Vietnamese word after OFF boundary: \(screen.text)")
        }
    }
}

func testRawModifierOrder() {
    for (mode, keys) in [(0, "afas"), (0, "tieengs"), (0, "ddawsk"), (1, "mu1i")] {
        let screen = Screen()
        screen.engine.vInputType = mode
        var typed = ""
        for char in keys {
            typed.append(char)
            screen.key(char)
            check(screen.rawMatches(typed), "raw modifier order after \(typed) in mode \(mode)")
        }
    }
}

func testConsumedVniMark() {
    let screen = Screen()
    screen.engine.vInputType = 1
    for char in "mat1" {
        screen.key(char)
        check(screen.engine.hookState.extCode != 5, "VNI mat1 stays valid before final mark")
    }
    check(screen.text == "mát", "VNI mat1 produces mát: \(screen.text)")
    let result = screen.key("2")
    check(screen.engine.hookState.extCode == 5 && result.shouldConsume && result.backspaceCount == 3,
          "VNI final mark restores by consuming key and deleting three glyphs: \(result)")
    check(screen.text == "mat12" && screen.rawMatches("mat12"),
          "VNI restore retains the consumed mark in raw order: \(screen.text)")
    screen.key("z")
    check(screen.text == "mat12z" && screen.rawMatches("mat12z"),
          "VNI continuation stays literal after consumed mark restore: \(screen.text)")
}

func testVietnamesePrefixes() {
    let cases = [("tiee", "tiê"), ("tieesng", "tiếng"), ("tieengs", "tiếng"),
                 ("tiengse", "tiếng"), ("thuongwr", "thưởng"), ("khuyru", "khuỷu"),
                 ("quyts", "quýt"), ("gieengs", "giếng"), ("ddawsk", "đắk")]
    for mode in [0, 2, 3] {
        for (keys, expected) in cases {
            let screen = Screen()
            screen.engine.vInputType = mode
            screen.engine.vQuickTelex = 1
            screen.engine.vUseModernOrthography = 1
            for char in keys {
                screen.key(char)
                check(screen.engine.hookState.extCode != 5, "\(keys) mode \(mode) stays Vietnamese at \(char)")
            }
            check(screen.text == expected, "\(keys) mode \(mode) -> \(expected): \(screen.text)")
        }
    }
}

func testModifierCancellation() {
    for keys in ["afass", "muss", "ass", "aass"] {
        let screen = Screen()
        for char in keys {
            screen.key(char)
            check(screen.engine.hookState.extCode != 5, "\(keys) does not instant-restore during cancellation")
        }
        check(screen.dictionaryCalls == 0, "\(keys) cancellation avoids dictionary")
    }
}
