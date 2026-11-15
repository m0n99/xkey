import Foundation

func testRepeatedMarkScenarios() {
    let settings = SharedSettings.shared
    let previous = (settings.spellCheckEnabled, settings.restoreIfWrongSpelling,
                    settings.instantRestoreOnWrongSpelling)
    defer {
        settings.spellCheckEnabled = previous.0
        settings.restoreIfWrongSpelling = previous.1
        settings.instantRestoreOnWrongSpelling = previous.2
    }
    settings.spellCheckEnabled = true
    settings.restoreIfWrongSpelling = true
    settings.instantRestoreOnWrongSpelling = true

    let defaults = Screen()
    check(defaults.engine.vRestoreAfterMarkCancel == 0, "repeated-mark restore defaults off")
    check(defaults.engine.vUndoAfterMarkCancel == 0, "manual undo defaults independently off")

    testRepeatedMarkInstant()
    testRepeatedMarkUppercase()
    testRepeatedMarkUppercaseAbbreviations()
    testRepeatedMarkHistory()
    testRepeatedMarkBoundary()
    testRepeatedMarkIndependence()
    testRepeatedMarkGuards()
    testRepeatedMarkOverflow()
    testRepeatedMarkDeferredGuards()
    testRepeatedMarkFalsePositives()
    testRepeatedMarkReset()
}

func testRepeatedMarkInstant() {
    let screen = Screen(prefix: "@")
    screen.engine.vRestoreAfterMarkCancel = 1
    let expected = ["@d", "@di", "@dì", "@diff"]
    var raw = ""
    for (index, char) in "diff".enumerated() {
        raw.append(char)
        let result = screen.key(char)
        check(screen.text == expected[index], "diff at \(raw): \(screen.text)")
        check(screen.rawMatches(raw), "diff raw chronology at \(raw)")
        if index == 3 {
            check(result.shouldConsume && result.backspaceCount == 2,
                  "second f consumes exactly once and replaces owned dì: \(result)")
            check(screen.engine.hookState.extCode == 5, "second f triggers instant restore")
        } else {
            check(screen.engine.hookState.extCode != 5, "no early diff restore at \(raw)")
        }
    }
    for char in "erence" {
        raw.append(char)
        screen.key(char)
        check(screen.text == "@" + raw && screen.rawMatches(raw), "literal difference at \(raw)")
        check(screen.engine.hookState.extCode != 5, "difference does not restore twice at \(raw)")
    }
    check(screen.dictionaryCalls == 0, "instant cancellation does not query dictionary")

    let traffic = Screen()
    traffic.engine.vRestoreAfterMarkCancel = 1
    traffic.type("traffic")
    check(traffic.text == "traffic" && traffic.rawMatches("traffic"), "traffic remains literal")
    check(traffic.dictionaryCalls == 0, "traffic does not query dictionary")

    let cases = [(0, "ass", "á"), (0, "aff", "à"), (0, "arr", "ả"),
                 (0, "axx", "ã"), (0, "ajj", "ạ"), (1, "a11", "á")]
    for (mode, keys, accented) in cases {
        let sample = Screen()
        sample.engine.vInputType = mode
        sample.engine.vRestoreAfterMarkCancel = 1
        sample.type(String(keys.dropLast()))
        check(sample.text == accented, "\(keys) applies its first mark: \(sample.text)")
        let result = sample.key(keys.last!)
        check(result.shouldConsume && result.backspaceCount == 1, "\(keys) replaces one accented glyph")
        check(sample.text == keys && sample.rawMatches(keys), "\(keys) restores exact raw keys: \(sample.text)")
        check(sample.dictionaryCalls == 0, "\(keys) avoids dictionary")
    }
}

func testRepeatedMarkUppercase() {
    let uppercase = Screen()
    uppercase.engine.vRestoreAfterMarkCancel = 1
    uppercase.type("DIFF")
    check(uppercase.text == "DIFF" && uppercase.rawMatches("DIFF"), "instant restore preserves uppercase raw")
    check(uppercase.engine.hookState.extCode == 5, "uppercase restores immediately on second F")
    check(uppercase.dictionaryCalls == 0, "uppercase cancellation avoids dictionary")
}

func testRepeatedMarkUppercaseAbbreviations() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    defer { settings.instantRestoreOnWrongSpelling = previous }
    for instant in [false, true] {
        settings.instantRestoreOnWrongSpelling = instant
        for skip in [0, 1] {
            let screen = Screen()
            screen.engine.vRestoreAfterMarkCancel = 1
            screen.engine.vSkipRestoreForUppercaseVietnameseAbbreviations = skip
            screen.type("AAFF")
            let expected = instant && skip == 0 ? "AAFF" : "ÂF"
            check(screen.text == expected && screen.rawMatches("AAFF"),
                  "AAFF instant=\(instant) skip=\(skip) while typing: \(screen.text)")
            screen.boundary(" ")
            let boundaryExpected = skip == 1 ? "ÂF " : "AAFF "
            check(screen.text == boundaryExpected,
                  "AAFF instant=\(instant) skip=\(skip) at boundary: \(screen.text)")
            if skip == 1 {
                check(screen.dictionaryCalls == 0, "protected AAFF avoids dictionary")
            }

            let baseline = Screen()
            baseline.engine.vSkipRestoreForUppercaseVietnameseAbbreviations = skip
            baseline.type("DDAFF")
            check(baseline.text == "ĐAF", "DDAFF baseline preserves stroke: \(baseline.text)")
            let stroke = Screen()
            stroke.engine.vRestoreAfterMarkCancel = 1
            stroke.engine.vSkipRestoreForUppercaseVietnameseAbbreviations = skip
            stroke.type("DDAFF")
            check(stroke.text == baseline.text &&
                  stroke.engine.buffer.getKeystrokeSequence() == baseline.engine.buffer.getKeystrokeSequence(),
                  "DDAFF instant=\(instant) skip=\(skip) preserves stroke and raw: \(stroke.text)")
            stroke.boundary(" ")
            check(stroke.text == "ĐAF " && stroke.dictionaryCalls == 0,
                  "protected DDAFF at boundary instant=\(instant) skip=\(skip): \(stroke.text)")
        }
    }
}

func testRepeatedMarkHistory() {
    let history = Screen()
    history.engine.vRestoreAfterMarkCancel = 1
    history.type("diff")
    history.boundary(" ")
    history.backspace()
    check(history.text == "diff" && history.rawMatches("diff"), "history recovers restored diff")
    history.type("erence")
    check(history.text == "difference" && history.rawMatches("difference"),
          "history continuation stays literal")
}

func testRepeatedMarkBoundary() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    settings.instantRestoreOnWrongSpelling = false
    defer { settings.instantRestoreOnWrongSpelling = previous }
    for delimiter: Character in [" ", ",", "."] {
        let screen = Screen(prefix: "@", verdict: true)
        screen.engine.vRestoreAfterMarkCancel = 1
        let expected = ["@d", "@di", "@dì", "@dif"]
        var raw = ""
        for (index, char) in "diff".enumerated() {
            raw.append(char)
            let result = screen.key(char)
            check(screen.text == expected[index], "boundary diff at \(raw): \(screen.text)")
            check(screen.rawMatches(raw), "boundary diff raw chronology at \(raw)")
            check(screen.engine.hookState.extCode != 5, "boundary mode never instant restores")
            if index == 3 {
                check(result.shouldConsume && result.backspaceCount == 1,
                      "boundary mode cancels mark once: \(result)")
            }
        }
        let result = screen.boundary(delimiter)
        check(result.shouldConsume && result.backspaceCount == 3,
              "boundary replaces only owned dif for \(delimiter): \(result)")
        check(screen.text == "@diff\(delimiter)", "boundary restores exactly one delimiter: \(screen.text)")
        check(screen.dictionaryCalls == 0, "witnessed boundary cancellation skips dictionary")
    }
}

func testRepeatedMarkIndependence() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    defer { settings.instantRestoreOnWrongSpelling = previous }
    for instant in [false, true] {
        settings.instantRestoreOnWrongSpelling = instant
        let screen = Screen()
        screen.engine.vUndoAfterMarkCancel = 1
        screen.type("diff")
        check(screen.text == "dif" && screen.rawMatches("diff"), "option off preserves dif")
        check(screen.engine.canUndoTyping(), "manual undo enabled independently")
        let result = screen.undo()
        check(result.shouldConsume && result.backspaceCount == 3 && screen.text == "diff",
              "manual undo restores diff: \(screen.text)")
    }
    settings.instantRestoreOnWrongSpelling = true
    let screen = Screen()
    screen.engine.vRestoreAfterMarkCancel = 1
    check(screen.engine.vUndoAfterMarkCancel == 0, "automatic option does not enable manual undo")
}

func testRepeatedMarkGuards() {
    let settings = SharedSettings.shared
    let guards: [(String, (VNEngine) -> Void)] = [
        ("cursor", { $0.cursorMovedSinceReset = true }),
        ("focus", { $0.focusChangedDuringTyping = true }),
        ("desync", { $0.bufferDesyncDetected = true }),
        ("spelling", { $0.vCheckSpelling = 0 }),
        ("temporary spelling", { $0.vTempOffSpelling = 1 }),
        ("temporary engine", { $0.vTempOffEngine = 1 }),
        ("parent restore", { $0.vRestoreIfWrongSpelling = 0 })
    ]
    for (name, disable) in guards {
        let screen = Screen(prefix: "@")
        screen.engine.vRestoreAfterMarkCancel = 1
        screen.type("dif")
        disable(screen.engine)
        screen.key("f")
        check(screen.text.hasPrefix("@") && screen.text != "@diff",
              "\(name) vetoes witnessed restore: \(screen.text)")
    }
    for disable in ["spell", "restore"] {
        let screen = Screen(prefix: "@")
        screen.engine.vRestoreAfterMarkCancel = 1
        screen.type("dif")
        if disable == "spell" {
            settings.spellCheckEnabled = false
        } else {
            settings.restoreIfWrongSpelling = false
        }
        screen.key("f")
        check(screen.text.hasPrefix("@") && screen.text != "@diff", "\(disable) setting vetoes restore")
        settings.spellCheckEnabled = true
        settings.restoreIfWrongSpelling = true
    }
}

func testRepeatedMarkOverflow() {
    let screen = Screen(prefix: "@")
    screen.engine.vRestoreAfterMarkCancel = 1
    screen.type("dif")
    let buffer = screen.engine.buffer
    let code = VietnameseData.keyCode(for: "f")!
    for _ in 0..<TypingBuffer.MAX_SIZE {
        let modifier = buffer.addModifier(at: 0, keystroke: RawKeystroke(keyCode: code))
        buffer.recordKeystroke(modifier)
    }
    screen.key("f")
    check(screen.engine.hookState.extCode != 5 && screen.text.hasPrefix("@"),
          "raw overflow vetoes restoration and preserves prefix: \(screen.text)")

    let full = Screen(prefix: "@")
    full.engine.vRestoreAfterMarkCancel = 1
    full.type(String(repeating: "b", count: TypingBuffer.MAX_SIZE + 1))
    check(full.engine.buffer.hasOverflow, "visible buffer overflow fixture")
    full.type("af")
    full.key("f")
    check(full.engine.hookState.extCode != 5 && full.text.hasPrefix("@"),
          "buffer overflow does not restore unowned text")
}

func testRepeatedMarkDeferredGuards() {
    let settings = SharedSettings.shared
    let previous = (settings.spellCheckEnabled, settings.restoreIfWrongSpelling,
                    settings.instantRestoreOnWrongSpelling)
    defer {
        settings.spellCheckEnabled = previous.0
        settings.restoreIfWrongSpelling = previous.1
        settings.instantRestoreOnWrongSpelling = previous.2
    }
    settings.spellCheckEnabled = true
    settings.restoreIfWrongSpelling = true
    settings.instantRestoreOnWrongSpelling = true

    let recovered = Screen(prefix: "@", verdict: true)
    recovered.engine.vRestoreAfterMarkCancel = 1
    recovered.type("dif")
    recovered.engine.focusChangedDuringTyping = true
    recovered.key("f")
    check(recovered.text == "@dif", "focus vetoes immediate cancellation restore: \(recovered.text)")
    recovered.engine.focusChangedDuringTyping = false
    recovered.boundary(" ")
    check(recovered.text == "@diff ", "safe boundary restores deferred cancellation: \(recovered.text)")
    check(recovered.dictionaryCalls == 0, "safe deferred cancellation skips dictionary")

    settings.instantRestoreOnWrongSpelling = false
    let guards: [(String, (VNEngine) -> Void)] = [
        ("cursor", { $0.cursorMovedSinceReset = true }),
        ("focus", { $0.focusChangedDuringTyping = true }),
        ("desync", { $0.bufferDesyncDetected = true }),
        ("spelling", { $0.vCheckSpelling = 0 }),
        ("temporary spelling", { $0.vTempOffSpelling = 1 }),
        ("temporary engine", { $0.vTempOffEngine = 1 }),
        ("parent restore", { $0.vRestoreIfWrongSpelling = 0 }),
        ("spell setting", { _ in settings.spellCheckEnabled = false }),
        ("restore setting", { _ in settings.restoreIfWrongSpelling = false })
    ]
    for (name, disable) in guards {
        settings.spellCheckEnabled = true
        settings.restoreIfWrongSpelling = true
        let screen = Screen(prefix: "@", verdict: true)
        screen.engine.vRestoreAfterMarkCancel = 1
        screen.type("diff")
        check(screen.text == "@dif", "\(name) deferred guard fixture: \(screen.text)")
        disable(screen.engine)
        screen.boundary(" ")
        check(screen.text.hasPrefix("@") && screen.text != "@diff ",
              "\(name) vetoes deferred restoration: \(screen.text)")
    }
}

func testRepeatedMarkFalsePositives() {
    for (keys, expected) in [("asz", "a"), ("tiee", "tiê"), ("tieengs", "tiếng"),
                             ("ddawsk", "đắk"), ("khuyru", "khuỷu")] {
        let screen = Screen()
        screen.engine.vRestoreAfterMarkCancel = 1
        for char in keys {
            screen.key(char)
            check(screen.engine.hookState.extCode != 5, "\(keys) has no cancellation restore")
        }
        check(screen.text == expected, "\(keys) remains Vietnamese or explicit removal: \(screen.text)")
    }
    for keys in ["aaa", "ddd"] {
        let baseline = Screen()
        let enabled = Screen()
        enabled.engine.vRestoreAfterMarkCancel = 1
        baseline.type(keys)
        enabled.type(keys)
        check(enabled.engine.buffer.getKeystrokeSequence() == baseline.engine.buffer.getKeystrokeSequence(),
              "\(keys) preserves existing normalized raw history")
    }
}

func testRepeatedMarkReset() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    settings.instantRestoreOnWrongSpelling = false
    defer { settings.instantRestoreOnWrongSpelling = previous }
    let edited = Screen(verdict: true)
    edited.engine.vRestoreAfterMarkCancel = 1
    edited.type("aff")
    edited.backspace()
    edited.key("s")
    edited.boundary(" ")
    check(edited.text == "á ", "backspace invalidates old cancellation witness: \(edited.text)")

    let fresh = Screen(verdict: true)
    fresh.engine.vRestoreAfterMarkCancel = 1
    fresh.type("aff")
    fresh.boundary(" ")
    fresh.type("as")
    fresh.boundary(" ")
    check(fresh.text == "aff á ", "new word does not inherit cancellation witness: \(fresh.text)")
}
