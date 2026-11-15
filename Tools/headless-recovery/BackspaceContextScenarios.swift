import Foundation

func exhaustEmptyHistory(_ engine: VNEngine) {
    let result = engine.processBackspace()
    check(!result.shouldConsume, "empty backspace passes through")
    check(engine.cursorMovedSinceReset && !engine.bufferDesyncDetected,
          "exhausted history creates soft uncertainty, not hard desync")
    check(engine.needsBackspaceContextProof, "empty backspace requests proof")
}

func backspaceProducerScenarios() {
    let engine = makeEngine()
    exhaustEmptyHistory(engine)
    for _ in 0..<4 {
        check(!engine.processBackspace().shouldConsume, "repeated empty backspace passes through")
        check(engine.needsBackspaceContextProof && !engine.bufferDesyncDetected,
              "repeated empty backspace remains soft")
    }
    var screen = ""
    for key in "abc" { press(key, engine: engine, screen: &screen) }
    check(engine.needsBackspaceContextProof, "newly typed owned word still needs proof")
    let exact = report(screen, engine)
    check(engine.recoverCaretWord(exact, nativeBackspaceProof: true) == .validated,
          "exact owned word validates without field-start metadata")
    check(!engine.needsBackspaceContextProof && !engine.cursorMovedSinceReset,
          "owned word proof clears soft uncertainty")
}

func backspaceBoundaryScenarios() {
    for text in ["", " old"] {
        let engine = makeEngine()
        exhaustEmptyHistory(engine)
        guard let observed = readContext(text, selection: CFRange(location: 0, length: 0)) else {
            fatalError("Expected field-start report")
        }
        let proof = CaretWordReport(word: observed.word, caretAtWordEnd: observed.caretAtWordEnd,
                                    selectionAnchoredAtCaret: observed.selectionAnchoredAtCaret,
                                    selectionLength: observed.selectionLength,
                                    elementSignature: observed.elementSignature,
                                    appBundleId: observed.appBundleId, expectedRevision: engine.typingRevision,
                                    caretAtFieldStart: observed.caretAtFieldStart, fieldIsEmpty: observed.fieldIsEmpty)
        check(engine.recoverCaretWord(proof, nativeBackspaceProof: true) == .validated,
              "actual empty field or field start validates native proof")
        check(!engine.cursorMovedSinceReset && !engine.focusChangedDuringTyping && !engine.needsBackspaceContextProof,
              "native boundary proof clears soft guards")
        engine.vRestoreAfterMarkCancel = 1
        engine.vCheckSpelling = 1
        engine.vRestoreIfWrongSpelling = 1
        var screen = ""
        for key in "diff" { press(key, engine: engine, screen: &screen) }
        check(screen == "dif", "mark cancellation produces dif before boundary")
        let result = engine.processWordBreak(character: " ")
        check(result.shouldConsume && result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined() == "diff ",
              "restoration after mark cancellation works following proof")
    }
}

func backspaceInstantCancellationScenario() {
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    defer { settings.instantRestoreOnWrongSpelling = previous }
    settings.instantRestoreOnWrongSpelling = true

    let engine = makeEngine()
    exhaustEmptyHistory(engine)
    guard let observed = readContext("", selection: CFRange(location: 0, length: 0)) else {
        fatalError("Expected empty field report")
    }
    let proof = CaretWordReport(word: observed.word, caretAtWordEnd: observed.caretAtWordEnd,
                                selectionAnchoredAtCaret: observed.selectionAnchoredAtCaret,
                                selectionLength: observed.selectionLength,
                                elementSignature: observed.elementSignature,
                                appBundleId: observed.appBundleId, expectedRevision: engine.typingRevision,
                                caretAtFieldStart: observed.caretAtFieldStart, fieldIsEmpty: observed.fieldIsEmpty)
    check(engine.recoverCaretWord(proof, nativeBackspaceProof: true) == .validated,
          "native empty-field proof validates before instant cancellation")
    engine.vRestoreAfterMarkCancel = 1
    engine.vCheckSpelling = 1
    engine.vRestoreIfWrongSpelling = 1
    var screen = ""
    for key in "dif" { press(key, engine: engine, screen: &screen) }
    check(screen == "dì", "first f applies the mark")
    let result = engine.processKey(character: "f", keyCode: VietnameseData.keyCode(for: "f")!, isUppercase: false)
    check(result.shouldConsume && result.backspaceCount == 2, "second f immediately replaces owned dì")
    screen = String(screen.dropLast(result.backspaceCount))
        + result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined()
    let raw = "diff".map { RawKeystroke(keyCode: VietnameseData.keyCode(for: $0)!) }
    check(screen == "diff" && engine.buffer.getKeystrokeSequence() == raw,
          "instant cancellation produces diff and preserves raw diff")
}

func backspaceUnownedScenarios() {
    let engine = makeEngine()
    exhaustEmptyHistory(engine)
    guard let stale = readContext("old ", selection: CFRange(location: 4, length: 0)) else {
        fatalError("Expected empty boundary after old text")
    }
    let staleReport = CaretWordReport(word: stale.word, caretAtWordEnd: stale.caretAtWordEnd,
                                      selectionAnchoredAtCaret: stale.selectionAnchoredAtCaret,
                                      selectionLength: stale.selectionLength, elementSignature: stale.elementSignature,
                                      appBundleId: stale.appBundleId, expectedRevision: engine.typingRevision,
                                      caretAtFieldStart: stale.caretAtFieldStart, fieldIsEmpty: stale.fieldIsEmpty)
    check(!staleReport.caretAtFieldStart && !staleReport.fieldIsEmpty, "old-space boundary is not field start or empty")
    check(engine.recoverCaretWord(staleReport, nativeBackspaceProof: true) != .validated,
          "native proof rejects stale old-space boundary")
    check(engine.needsBackspaceContextProof, "stale boundary leaves guards in place")
    check(engine.recoverCaretWord(report("old", engine), nativeBackspaceProof: true) == .rejected(.wordMismatch),
          "native proof never imports an old word")
    var screen = ""
    for key in "abc" { press(key, engine: engine, screen: &screen) }
    let partial = engine.recoverCaretWord(report("oldabc", engine), nativeBackspaceProof: true)
    check(partial == .rejected(.engineHasPartialWord),
          "native proof rejects an unowned prefix")
    let legacy = makeEngine()
    exhaustEmptyHistory(legacy)
    check(legacy.recoverCaretWord(report("", legacy)) == .validated,
          "default mouse and focus lane accepts the existing empty boundary")
}

func backspaceHardDesyncScenarios() {
    let engine = makeEngine()
    engine.bufferDesyncDetected = true
    _ = engine.processBackspace()
    check(engine.bufferDesyncDetected && !engine.needsBackspaceContextProof,
          "empty delete preserves hard desync and does not request proof")
    let empty = readContext("", selection: CFRange(location: 0, length: 0))!
    let proof = CaretWordReport(word: empty.word, caretAtWordEnd: true, selectionAnchoredAtCaret: true,
                                selectionLength: 0, elementSignature: "field", appBundleId: nil,
                                expectedRevision: engine.typingRevision, caretAtFieldStart: true, fieldIsEmpty: true)
    _ = engine.recoverCaretWord(proof, nativeBackspaceProof: true)
    check(engine.bufferDesyncDetected, "proof cannot clear hard desync")
    _ = engine.processWordBreak(character: " ")
    check(!engine.bufferDesyncDetected, "normal word boundary resets hard desync")

    let guarded = makeEngine()
    var screen = ""
    for key in "abc" { press(key, engine: guarded, screen: &screen) }
    _ = guarded.processWordBreak(character: " ")
    guarded.cursorMovedSinceReset = true
    guarded.bufferDesyncDetected = true
    _ = guarded.processBackspace()
    check(guarded.bufferDesyncDetected, "guarded history clear preserves hard desync")
}

func backspaceReaderMetadataScenarios() {
    for (text, location, atStart, empty, expectedTextReads) in [
        ("", 0, true, true, 0), (" old", 0, true, false, 1),
        ("old ", 4, false, false, 1), ("😀 ", 3, false, false, 1)
    ] {
        var selections = 0
        var lengths = 0
        var texts = 0
        let provider = CaretWordAXReader.Provider(
            role: { "AXTextField" }, subrole: { nil }, isEditable: { true },
            selection: { selections += 1; return CFRange(location: location, length: 0) },
            length: { lengths += 1; return text.utf16.count },
            text: { range in
                texts += 1
                return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            }, isStillFocused: { true })
        let observed = CaretWordAXReader.read(provider, signature: "field", bundleId: nil, revision: 1)
        check(observed?.caretAtFieldStart == atStart && observed?.fieldIsEmpty == empty,
              "reader metadata reflects UTF-16 selection and field length")
        check(selections == 2 && lengths == 1 && texts == expectedTextReads,
              "reader metadata adds no selection, length or text reads")
    }
}

func runBackspaceContextScenarios() {
    backspaceProducerScenarios()
    backspaceBoundaryScenarios()
    backspaceInstantCancellationScenario()
    backspaceUnownedScenarios()
    backspaceHardDesyncScenarios()
    backspaceReaderMetadataScenarios()
}
