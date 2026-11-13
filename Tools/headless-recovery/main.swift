import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

func makeEngine() -> VNEngine {
    let engine = VNEngine()
    engine.vCheckSpelling = 0
    engine.spellCheckVerdictOverride = { _ in false }
    return engine
}

func report(_ word: String, _ engine: VNEngine, revision: UInt64? = nil) -> CaretWordReport {
    CaretWordReport(word: word, caretAtWordEnd: true, selectionAnchoredAtCaret: true,
                    selectionLength: 0, elementSignature: "isolated", appBundleId: nil,
                    expectedRevision: revision ?? engine.typingRevision)
}

func press(_ key: Character, engine: VNEngine, screen: inout String) {
    guard let keyCode = VietnameseData.keyCode(for: key) else { fatalError("No key code for \(key)") }
    let result = engine.processKey(character: key, keyCode: keyCode, isUppercase: false)
    if result.shouldConsume {
        check(result.backspaceCount <= screen.count, "replacement fits visible word")
        screen = String(screen.dropLast(result.backspaceCount))
            + result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined()
    } else {
        screen.append(key)
    }
    check(screen == engine.getCurrentWord(), "screen and engine agree after \(key): \(screen)")
}

func parse(_ left: String, _ right: String = "", _ leftBounded: Bool = true, _ rightBounded: Bool = true) -> (word: String, caretAtWordEnd: Bool)? {
    CaretWordParser.parse(leftContext: left, rightContext: right,
                          leftContextStartsAtFieldStart: leftBounded,
                          rightContextEndsAtFieldEnd: rightBounded)
}

func readContext(_ text: String, selection: CFRange, role: String = "AXTextField",
                 subrole: String? = nil, editable: Bool = true, focused: Bool = true,
                 finalSelection: CFRange? = nil, readable: Bool = true,
                 ranges: ((CFRange) -> Void)? = nil) -> CaretWordReport? {
    var selectionReads = 0
    let provider = CaretWordAXReader.Provider(
        role: { role }, subrole: { subrole }, isEditable: { editable },
        selection: {
            selectionReads += 1
            return selectionReads == 1 ? selection : (finalSelection ?? selection)
        }, length: { text.utf16.count }, text: { range in
            ranges?(range)
            guard readable else { return nil }
            return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        }, isStillFocused: { focused })
    return CaretWordAXReader.read(provider, signature: "field", bundleId: "app", revision: 7)
}

check(parse("a thử")?.word == "thử", "parser returns bounded word")
check(parse("thử", "a")?.caretAtWordEnd == false, "parser marks mid-word caret")
check(parse("word", "", false) == nil, "parser rejects clipped left context")
check(parse("word", "", true, false) == nil, "parser rejects unbounded right context")
check(parse("e\u{301}") == nil, "parser rejects NFD")
check(parse("", "")?.word == "", "parser accepts known empty boundary")

do {
    var ranges: [CFRange] = []
    let text = String(repeating: " ", count: 90) + "hello"
    let result = readContext(text, selection: CFRange(location: 95, length: 0), ranges: { ranges.append($0) })
    check(result?.word == "hello" && result?.expectedRevision == 7, "injected reader returns word and revision")
    check(ranges.count == 1 && ranges[0].location == 31 && ranges[0].length == 64, "left read bounded to 64 UTF-16 units")
    ranges.removeAll()
    let rightText = "😀 hello " + String(repeating: " ", count: 40)
    let rightResult = readContext(rightText, selection: CFRange(location: 8, length: 0), ranges: { ranges.append($0) })
    check(rightResult?.word == "hello", "injected reader uses UTF-16 caret offsets")
    check(ranges.count == 2 && ranges[0].location == 0 && ranges[0].length == 8 && ranges[1].location == 8 && ranges[1].length == 16, "right read bounded to 16 UTF-16 units")
    let caret = CFRange(location: 3, length: 0)
    check(readContext("abc", selection: caret, subrole: "AXSecureTextField") == nil, "reader rejects secure field")
    check(readContext("abc", selection: caret, role: "AXButton") == nil, "reader rejects unsupported role")
    check(readContext("abc", selection: caret, editable: false) == nil, "reader rejects noneditable field")
    check(readContext("abc", selection: caret, focused: false) == nil, "reader rejects unfocused field")
    check(readContext("abc", selection: caret, readable: false) == nil, "reader rejects unreadable context")
    check(readContext("abc", selection: CFRange(location: 1, length: 1)) == nil, "reader rejects noncollapsed selection")
    check(readContext("abc", selection: CFRange(location: 1, length: 0)) == nil, "reader rejects mid-word caret")
    check(readContext("abc", selection: caret, finalSelection: CFRange(location: 2, length: 0)) == nil, "reader rejects moved selection")
    check(readContext("abc", selection: caret, finalSelection: CFRange(location: 3, length: 1)) == nil, "reader rejects newly selected text")
    check(readContext("e\u{301}", selection: CFRange(location: 2, length: 0)) == nil, "reader rejects NFD")
    check(readContext(String(repeating: "a", count: 65), selection: CFRange(location: 65, length: 0)) == nil, "reader rejects clipped word")
}

do {
    var state = CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)
    let expected = state
    let accepted = CaretRecoveryFreshness.afterBookkeeping(expected: expected, current: { state }) {
        state = CaretRecoveryFreshness(revision: 12, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)
    }
    check(accepted?.revision == 12 && accepted?.matches(state) == true, "bookkeeping revision is accepted")
    let staleStates = [
        CaretRecoveryFreshness(revision: 11, epoch: 2, generation: 3, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 10, epoch: 4, generation: 3, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 4, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3, isRunning: false, isActiveHost: true),
        CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3, isRunning: true, isActiveHost: false)
    ]
    for stale in staleStates {
        var didBookkeeping = false
        let result = CaretRecoveryFreshness.afterBookkeeping(expected: expected, current: { stale }) { didBookkeeping = true }
        check(result == nil && didBookkeeping && !expected.matches(stale), "stale typing/epoch/generation/stop/inactive cancels after bookkeeping")
    }
    check(accepted?.matches(CaretRecoveryFreshness(revision: 13, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)) == false, "typing after bookkeeping invalidates snapshot")
    state = expected
    let changed = CaretRecoveryFreshness.afterBookkeeping(expected: expected, current: { state }) {
        state = CaretRecoveryFreshness(revision: 11, epoch: 3, generation: 3, isRunning: true, isActiveHost: true)
    }
    check(changed == nil, "bookkeeping cannot hide epoch change")
}

do {
    let expected = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)
    let editable = readContext("hello", selection: CFRange(location: 5, length: 0))
    let observerSignature = "AXStaticText:observer"
    check(editable != nil && editable?.elementSignature != observerSignature, "observer signature differs from editable report")
    var applied = 0
    CaretRecoveryFreshness.applyIfCurrent(report: editable, expected: expected, current: expected,
                                         expectedPID: 42, currentPID: 42, expectedBundleId: "app", currentBundleId: "app") { _ in applied += 1 }
    check(applied == 1, "fresh editable report applies despite different observer signature")

    let staticText = readContext("hello", selection: CFRange(location: 5, length: 0), role: "AXStaticText")
    check(staticText == nil, "actual static text reader rejects report")
    CaretRecoveryFreshness.applyIfCurrent(report: staticText, expected: expected, current: expected,
                                         expectedPID: 42, currentPID: 42, expectedBundleId: "app", currentBundleId: "app") { _ in applied += 1 }
    check(applied == 1, "nil static text report cannot apply")
    let empty = readContext("", selection: CFRange(location: 0, length: 0))
    check(empty?.word == "", "editable empty boundary produces empty report")

    var epoch = expected.epoch
    let accepted = CaretRecoveryFreshness.acceptFocusNotification(epoch: &epoch, isActiveHost: true, elapsed: 0.1, throttleInterval: 0.5)
    check(!accepted && epoch == expected.epoch + 1, "throttled focus still advances epoch")
    let staleStates = [
        CaretRecoveryFreshness(revision: 7, epoch: epoch, generation: 3, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 8, epoch: 2, generation: 3, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 4, isRunning: true, isActiveHost: true),
        CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: false, isActiveHost: true),
        CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: true, isActiveHost: false)
    ]
    for stale in staleStates {
        CaretRecoveryFreshness.applyIfCurrent(report: editable, expected: expected, current: stale,
                                             expectedPID: 42, currentPID: 42, expectedBundleId: "app", currentBundleId: "app") { _ in applied += 1 }
    }
    CaretRecoveryFreshness.applyIfCurrent(report: editable, expected: expected, current: expected,
                                         expectedPID: 42, currentPID: 43, expectedBundleId: "app", currentBundleId: "app") { _ in applied += 1 }
    CaretRecoveryFreshness.applyIfCurrent(report: editable, expected: expected, current: expected,
                                         expectedPID: 42, currentPID: 42, expectedBundleId: "app", currentBundleId: "other") { _ in applied += 1 }
    CaretRecoveryFreshness.applyIfCurrent(report: editable, expected: expected, current: expected,
                                         expectedPID: nil, currentPID: nil, expectedBundleId: "app", currentBundleId: "app") { _ in applied += 1 }
    check(applied == 1, "stale epoch, revision, generation, running, host, PID or bundle cannot apply")
}

func typeRestorableWord(_ engine: VNEngine) {
    var screen = ""
    for key in "etsy" { press(key, engine: engine, screen: &screen) }
    check(screen == "éty", "real etsy typing produces éty")
}

func checkPeriodRestore(_ engine: VNEngine) {
    engine.vCheckSpelling = 1
    let result = engine.processWordBreak(character: ".")
    check(result.shouldConsume && result.backspaceCount == 3, "period restores the complete transformed word")
    check(result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined() == "etsy.", "period restores real raw etsy plus punctuation")
}

do {
    let engine = makeEngine()
    // Activation advances the epoch and resets the engine before capturing the trigger.
    engine.resetWithCursorMoved()
    let trigger = CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                                         isRunning: true, isActiveHost: true)
    func current() -> CaretRecoveryFreshness {
        CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                               isRunning: true, isActiveHost: true)
    }
    var didBookkeeping = false
    let scheduled = CaretRecoveryFreshness.afterBookkeeping(expected: trigger, current: current) {
        didBookkeeping = true
        engine.notifyFocusChanged()
    }
    check(didBookkeeping && scheduled?.revision == engine.typingRevision, "activation bookkeeping preserves its own revision change")
    var validated = false
    if let scheduled = scheduled {
        CaretRecoveryFreshness.applyIfCurrent(report: report("", engine), expected: scheduled, current: current(),
                                             expectedPID: 42, currentPID: 42,
                                             expectedBundleId: "notes", currentBundleId: "notes") {
            validated = engine.recoverCaretWord($0) == .validated
        }
    }
    check(validated && !engine.cursorMovedSinceReset, "activation empty boundary validates without a mouse click")
    var screen = ""
    for key in "verbose" { press(key, engine: engine, screen: &screen) }
    check(screen == "vẻbose", "verbose reproduces transformed Notes word")
    engine.vCheckSpelling = 1
    let result = engine.processWordBreak(character: " ")
    check(result.shouldConsume && result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined() == "verbose ",
          "first verbose after activation restores at space")
}

do {
    let engine = makeEngine()
    engine.resetWithCursorMoved()
    let trigger = CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                                         isRunning: true, isActiveHost: true)
    var screen = ""
    press("v", engine: engine, screen: &screen)
    var didBookkeeping = false
    let scheduled = CaretRecoveryFreshness.afterBookkeeping(expected: trigger, current: {
        CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                               isRunning: true, isActiveHost: true)
    }) {
        didBookkeeping = true
        engine.notifyFocusChanged()
    }
    check(didBookkeeping && scheduled == nil, "typing cancels activation recovery but not bookkeeping")
    var applied = false
    let current = CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                                        isRunning: true, isActiveHost: true)
    let inactive = CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                                         isRunning: true, isActiveHost: false)
    for (state, pid, bundle) in [(current, pid_t(43), "notes"), (current, pid_t(42), "other"), (inactive, pid_t(42), "notes")] {
        CaretRecoveryFreshness.applyIfCurrent(report: report("", engine), expected: current, current: state,
                                             expectedPID: 42, currentPID: pid,
                                             expectedBundleId: "notes", currentBundleId: bundle) { _ in applied = true }
    }
    check(!applied && engine.cursorMovedSinceReset, "app or host change cancels activation recovery")
}

do {
    let engine = makeEngine()
    engine.resetWithCursorMoved()
    engine.focusChangedDuringTyping = true
    check(engine.recoverCaretWord(report("", engine)) == .validated, "empty boundary after click validates")
    check(!engine.cursorMovedSinceReset && !engine.focusChangedDuringTyping, "empty boundary clears cursor and focus guards")
    typeRestorableWord(engine)
    checkPeriodRestore(engine)
}

do {
    let engine = makeEngine()
    typeRestorableWord(engine)
    let raw = engine.buffer.getKeystrokeSequence()
    engine.notifyFocusChanged()
    engine.cursorMovedSinceReset = true
    let pending = report(engine.getCurrentWord(), engine)
    check(engine.recoverCaretWord(pending) == .validated, "exact visible word validates")
    check(engine.recoverCaretWord(pending) == .rejected(.staleRevision), "exact validation invalidates report")
    check(engine.buffer.getKeystrokeSequence() == raw && raw.count == 4, "exact match retains real raw history")
    checkPeriodRestore(engine)
}

do {
    let engine = makeEngine()
    engine.resetWithCursorMoved()
    var screen = ""
    for key in "oof" { press(key, engine: engine, screen: &screen) }
    check(engine.recoverCaretWord(report("chồn", engine)) == .rejected(.engineHasPartialWord), "partial word cannot validate against full existing text")
    check(engine.cursorMovedSinceReset, "partial word stays guarded")
    engine.vCheckSpelling = 1
    check(!engine.processWordBreak(character: " ").shouldConsume, "partial word is not restored")
    engine.vCheckSpelling = 0
    typeRestorableWord(engine)
    checkPeriodRestore(engine)
}

do {
    let engine = makeEngine()
    engine.resetWithCursorMoved()
    let revision = engine.typingRevision
    check(engine.recoverCaretWord(report("thư", engine)) == .rejected(.wordMismatch), "existing text is not imported")
    check(engine.recoverCaretWord(report("e\u{301}", engine)) == .rejected(.wordMismatch), "NFD report is rejected")
    check(engine.typingRevision == revision && engine.buffer.isEmpty && engine.cursorMovedSinceReset, "rejections leave state unchanged")
}

do {
    let engine = makeEngine()
    var screen = ""
    for key in "abc" { press(key, engine: engine, screen: &screen) }
    _ = engine.processWordBreak(character: " ")
    check(engine.buffer.isEmpty && engine.history.count > 0, "word break saves old history")
    engine.cursorMovedSinceReset = true
    engine.focusChangedDuringTyping = true
    engine.bufferDesyncDetected = true
    engine.hookState.macroKey = [42]
    let pending = report("", engine)
    check(engine.recoverCaretWord(pending) == .validated, "empty boundary clears stale history")
    check(engine.recoverCaretWord(pending) == .rejected(.staleRevision), "empty validation invalidates report")
    check(engine.history.count == 0 && engine.hookState.macroKey == [42] && engine.bufferDesyncDetected, "empty boundary preserves macro and desync")
    check(!engine.cursorMovedSinceReset && !engine.focusChangedDuringTyping, "empty boundary clears guards")
    _ = engine.processBackspace()
    check(engine.buffer.isEmpty && engine.history.count == 0, "backspace cannot resurrect discarded history")
}

do {
    let engine = makeEngine()
    let revision = engine.typingRevision
    check(engine.recoverCaretWord(report("", engine)) == .notApplicable && engine.typingRevision == revision, "clean empty boundary does not churn revision")
    var screen = ""
    for key in "abc" { press(key, engine: engine, screen: &screen) }
    let beforeDelete = report(screen, engine)
    _ = engine.processBackspace()
    check(!engine.buffer.isEmpty && engine.recoverCaretWord(beforeDelete) == .rejected(.staleRevision), "backspace invalidates pending report with nonempty buffer")
    let beforeClear = report(engine.getCurrentWord(), engine)
    engine.clearHistory()
    check(engine.recoverCaretWord(beforeClear) == .rejected(.staleRevision), "clearHistory invalidates pending report")
    engine.focusChangedDuringTyping = true
    engine.startNewSession()
    check(!engine.focusChangedDuringTyping, "new session clears old focus guard")
}

print("Headless production-engine recovery checks passed")
