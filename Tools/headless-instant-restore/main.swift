import Foundation

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

final class Screen {
    let engine = VNEngine()
    var text: String
    var dictionaryCalls = 0

    init(prefix: String = "", verdict: Bool = false) {
        text = prefix
        engine.vCheckSpelling = 1
        engine.spellCheckVerdictOverride = { [weak self] _ in
            self?.dictionaryCalls += 1
            return verdict
        }
    }

    @discardableResult
    func key(_ char: Character) -> VNEngine.ProcessResult {
        guard let code = VietnameseData.keyCode(for: Character(char.lowercased())) else {
            fatalError("No key code for \(char)")
        }
        let calls = dictionaryCalls
        let result = engine.processKey(character: char, keyCode: code, isUppercase: char.isUppercase)
        check(dictionaryCalls == calls, "no per-key dictionary lookup for \(char)")
        apply(result, native: String(char))
        return result
    }

    func type(_ keys: String) {
        for char in keys { key(char) }
    }

    func boundary(_ char: Character) {
        apply(engine.processWordBreak(character: char), native: String(char))
    }

    func backspace() {
        let result = engine.processBackspace()
        apply(result, native: "", deleteNative: true)
    }

    private func apply(_ result: VNEngine.ProcessResult, native: String, deleteNative: Bool = false) {
        if result.shouldConsume {
            check(result.backspaceCount <= text.count, "replacement fits screen: \(text)")
            text = String(text.dropLast(result.backspaceCount))
                + result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined()
        } else if deleteNative {
            if !text.isEmpty { text.removeLast() }
        } else {
            text += native
        }
    }

    func rawMatches(_ keys: String) -> Bool {
        let expected = keys.map { char in
            RawKeystroke(keyCode: VietnameseData.keyCode(for: Character(char.lowercased()))!,
                         isCaps: char.isUppercase)
        }
        return engine.buffer.getKeystrokeSequence() == expected
    }
}

func testExpression() {
    let screen = Screen()
    screen.key("e")
    check(screen.text == "e", "e remains e, got \(screen.text)")
    screen.key("x")
    check(screen.text == "ẽ", "x applies ngã, got \(screen.text)")
    let calls = screen.dictionaryCalls
    let result = screen.key("p")
    check(result.shouldConsume && result.backspaceCount == 1,
          "p consumes and deletes exactly one visible character: \(result)")
    check(screen.text == "exp", "p immediately restores exp, got \(screen.text)")
    check(screen.dictionaryCalls == calls, "ordinary append does not evaluate dictionary")
    check(screen.rawMatches("exp"), "restored buffer retains owned raw exp")
    screen.key("r")
    check(screen.text == "expr", "r stays literal after restore, got \(screen.text)")
    screen.type("ession")
    check(screen.text == "expression", "continued expression stays literal, got \(screen.text)")
    check(screen.rawMatches("expression"), "expression raw order retained")
}

func testEnglishWords() {
    for word in ["text", "next", "verbose", "ExpRession", "eXpRession"] {
        let screen = Screen()
        screen.type(word)
        check(screen.text == word, "\(word) remains raw immediately, got \(screen.text)")
        check(screen.rawMatches(word), "\(word) raw sequence preserves case and order")
    }
}

func testIncrementalWords() {
    let cases: [(String, [String])] = [
        ("text", ["t", "te", "tẽ", "text"]),
        ("next", ["n", "ne", "nẽ", "next"]),
        ("verbose", ["v", "ve", "vẻ", "verb", "verbo", "verbos", "verbose"])
    ]
    for (keys, expected) in cases {
        let screen = Screen()
        for (char, visible) in zip(keys, expected) {
            screen.key(char)
            check(screen.text == visible, "\(keys) after \(char): expected \(visible), got \(screen.text)")
        }
    }
}

func testMarkTriggeredRestore() {
    for verdict in [false, true] {
        let screen = Screen(verdict: verdict)
        screen.type("afas")
        check(screen.text == "ấ", "afas remains structurally valid: \(screen.text)")
        check(screen.rawMatches("afas"), "afas retains the final modifier in raw history")
        check(screen.dictionaryCalls == 0, "afas does not consult the dictionary")
    }
}

func testMacroPrefix() {
    let screen = Screen()
    screen.engine.vUseMacro = 1
    screen.boundary("!")
    let prefix = screen.engine.hookState.macroKey
    screen.type("exp")
    check(screen.text == "!exp", "punctuation prefix survives restore: \(screen.text)")
    check(!prefix.isEmpty && screen.engine.hookState.macroKey.starts(with: prefix),
          "macro punctuation prefix preserved")
    let raw = Array(screen.engine.hookState.macroKey.suffix(3))
    let expected = "exp".map { UInt32(VietnameseData.keyCode(for: $0)!) }
    check(raw == expected, "macro key retains raw exp after restore: \(raw)")
}

func testPrefixAndCaseSafety() {
    let screen = Screen(prefix: "@")
    screen.key("E")
    screen.key("x")
    check(screen.text == "@Ẽ", "mixed-case tone before restore: \(screen.text)")
    let result = screen.key("P")
    check(result.shouldConsume && result.backspaceCount == 1, "mixed-case restore deletes only owned glyph")
    check(screen.text == "@ExP" && screen.rawMatches("ExP"),
          "mixed-case restore preserves prefix and raw order: \(screen.text)")
    screen.backspace()
    check(screen.text == "@Ex", "backspace after mixed-case restore preserves prefix: \(screen.text)")
}

func testFlags() {
    let settings = SharedSettings.shared
    defer {
        settings.spellCheckEnabled = true
        settings.restoreIfWrongSpelling = true
        settings.instantRestoreOnWrongSpelling = true
    }
    let cases: [(String, (VNEngine) -> Void)] = [
        ("spellcheck setting", { _ in settings.spellCheckEnabled = false }),
        ("restore setting", { _ in settings.restoreIfWrongSpelling = false }),
        ("instant setting", { _ in settings.instantRestoreOnWrongSpelling = false }),
        ("vCheckSpelling", { $0.vCheckSpelling = 0 }),
        ("vRestoreIfWrongSpelling", { $0.vRestoreIfWrongSpelling = 0 }),
        ("vTempOffSpelling", { $0.vTempOffSpelling = 1 }),
        ("vTempOffEngine", { $0.vTempOffEngine = 1 })
    ]
    for (name, disable) in cases {
        settings.spellCheckEnabled = true
        settings.restoreIfWrongSpelling = true
        settings.instantRestoreOnWrongSpelling = true
        let screen = Screen()
        screen.type("ex")
        disable(screen.engine)
        let result = screen.key("p")
        check(!result.shouldConsume || screen.text != "exp", "\(name) vetoes new restore: \(screen.text), \(result)")
    }
}

func testVietnameseAndCancellation() {
    for (keys, expected) in [("tiee", "tiê"), ("tieengs", "tiếng"), ("khuyru", "khuỷu"),
                             ("ddawsk", "đắk"), ("asnh", "ánh")] {
        let screen = Screen()
        screen.type(keys)
        check(screen.text == expected, "Vietnamese \(keys) -> \(expected), got \(screen.text)")
    }
    for (keys, expected) in [("ass", "as"), ("aass", "âs")] {
        let screen = Screen()
        screen.type(keys)
        check(screen.text == expected, "intentional cancellation \(keys) -> \(expected), got \(screen.text)")
    }
}

func testOwnershipGuards() {
    let guards: [(String, (VNEngine) -> Void)] = [
        ("cursor", { $0.cursorMovedSinceReset = true }),
        ("focus", { $0.focusChangedDuringTyping = true }),
        ("desync", { $0.bufferDesyncDetected = true })
    ]
    for (name, setGuard) in guards {
        let screen = Screen(prefix: "old")
        screen.type("ex")
        setGuard(screen.engine)
        let result = screen.key("p")
        check(screen.text.hasPrefix("old"), "\(name) preserves unowned prefix: \(screen.text)")
        check(!result.shouldConsume || screen.text != "oldexp", "\(name) vetoes restore: \(screen.text)")
        screen.boundary(" ")
        screen.type("exp")
        check(screen.text.hasSuffix(" exp"), "\(name) fresh word eligible: \(screen.text)")
    }
}

func testBoundariesAndEdit() {
    for boundary: Character in [" ", "!"] {
        let screen = Screen()
        screen.type("exp")
        screen.boundary(boundary)
        screen.type("tieengs")
        check(screen.text == "exp\(boundary)tiếng", "\(boundary) ends literal bypass: \(screen.text)")
    }
    for reset in ["reset", "session", "focus"] {
        let screen = Screen()
        screen.type("exp")
        switch reset {
        case "reset": screen.engine.reset()
        case "session": screen.engine.startNewSession()
        default: screen.engine.notifyFocusChanged(); screen.engine.startNewSession()
        }
        screen.text += " "
        screen.type("tieengs")
        check(screen.text == "exp tiếng", "\(reset) clears bypass: \(screen.text)")
    }
    let screen = Screen()
    screen.type("expr")
    screen.backspace()
    check(screen.text == "exp", "backspace edits restored word: \(screen.text)")
    screen.boundary(" ")
    screen.type("tieengs")
    check(screen.text == "exp tiếng", "fresh word works after backspace: \(screen.text)")
}

func testOverflow() {
    let screen = Screen()
    screen.type("ex")
    let buffer = screen.engine.buffer
    let code = VietnameseData.keyCode(for: "x")!
    for _ in 0..<TypingBuffer.MAX_SIZE {
        let modifier = buffer.addModifier(at: 0, keystroke: RawKeystroke(keyCode: code))
        buffer.recordKeystroke(modifier)
    }
    check(screen.text == "ẽ" && screen.engine.hasVietnameseProcessing(), "overflow fixture is transformed")
    check(buffer.count == 1 && buffer.getKeystrokeSequence().count > TypingBuffer.MAX_SIZE,
          "overflow fixture has few entries but too many raw modifiers")
    let before = screen.text
    let result = screen.key("p")
    check(screen.text == before + "p", "overflow retains pending native key once: \(screen.text)")
    check(!result.shouldConsume && result.backspaceCount == 0, "overflow vetoes replacement and deletion")
}

func testInputModes() {
    for mode in [0, 2, 3] {
        let screen = Screen()
        screen.engine.vInputType = mode
        screen.engine.vQuickTelex = 1
        screen.type("expr")
        check(screen.text == "expr" && screen.rawMatches("expr"),
              "Telex mode \(mode) restores expr: \(screen.text)")
    }
    let screen = Screen()
    screen.engine.vInputType = 1
    screen.type("e4p")
    check(screen.text == "e4p" && screen.rawMatches("e4p"), "VNI restores e4p: \(screen.text)")
}

func testLiteralHistory() {
    let screen = Screen()
    screen.type("expr")
    screen.boundary(" ")
    check(screen.text == "expr ", "space after restored word: \(screen.text)")
    screen.backspace()
    check(screen.text == "expr", "backspace removes space: \(screen.text)")
    check(screen.engine.getCurrentWord() == "expr" && screen.rawMatches("expr"),
          "history restores literal word and raw keys")
    screen.type("ession")
    check(screen.text == "expression" && screen.rawMatches("expression"),
          "typing after history restore remains literal: \(screen.text)")
}

testExpression()
testEnglishWords()
testIncrementalWords()
testMarkTriggeredRestore()
testMacroPrefix()
testPrefixAndCaseSafety()
testFlags()
testVietnameseAndCancellation()
testOwnershipGuards()
testBoundariesAndEdit()
testOverflow()
testInputModes()
testLiteralHistory()
testRimeStatus()
testStructuralRestore()
testDisabledBoundaryRestore()
testVietnamesePrefixes()
testModifierCancellation()
testRawModifierOrder()
testConsumedVniMark()
if failures > 0 {
    print("\(failures) instant-restore checks failed")
    exit(1)
}
print("Headless instant-restore checks passed")
