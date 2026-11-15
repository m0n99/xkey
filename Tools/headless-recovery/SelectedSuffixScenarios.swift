import Foundation

private let registry = SharedBrowserRegistry()
private let chromiumProfile = registry.profile(for: "com.google.Chrome")
private let omnibox = CaretWordAXReader.OmniboxMetadata(
    role: "AXTextField", description: "Address and search bar", domClassList: ["OmniboxViewViews"],
    profile: chromiumProfile)

private func selectedReport(_ word: String, _ engine: VNEngine, length: Int = 3) -> CaretWordReport {
    var result = CaretWordReport(word: word, caretAtWordEnd: true, selectionAnchoredAtCaret: false,
                                 selectionLength: length, elementSignature: "field", appBundleId: nil,
                                 expectedRevision: engine.typingRevision)
    result.proofKind = .selectedSuffixReplacement(selectionLength: length)
    return result
}

private func selectedRead(_ text: String, selection: CFRange,
                          metadata: CaretWordAXReader.OmniboxMetadata? = omnibox,
                          role: String = "AXTextField", subrole: String? = nil,
                          editable: Bool = true, focused: Bool = true,
                          finalSelection: CFRange? = nil,
                          ranges: ((CFRange) -> Void)? = nil) -> CaretWordReport? {
    var selections = 0
    let provider = CaretWordAXReader.Provider(
        role: { role }, subrole: { subrole }, isEditable: { editable },
        selection: {
            selections += 1
            return selections == 1 ? selection : (finalSelection ?? selection)
        }, length: { text.utf16.count }, text: { range in
            ranges?(range)
            return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        }, isStillFocused: { focused })
    return CaretWordAXReader.read(provider, signature: "field", bundleId: "app", revision: 7,
                                  omniboxMetadata: metadata)
}

private func selectedReaderScenarios() {
    var ranges: [CFRange] = []
    let text = String(repeating: " ", count: 70) + "o" + "suggestion"
    let selection = CFRange(location: 71, length: 10)
    let result = selectedRead(text, selection: selection, ranges: { ranges.append($0) })
    check(result?.word == "o" && result?.selectionLength == 10 && result?.selectionAnchoredAtCaret == false,
          "selected reader retains actual selection geometry")
    check(result?.proofKind == .selectedSuffixReplacement(selectionLength: 10), "selected reader reports proof kind")
    check(ranges.count == 1 && ranges[0].location == 7 && ranges[0].length == 64,
          "selected reader reads bounded prefix only, never native suffix")

    let canonical = CFRange(location: 1, length: 3)
    let wrongMetadata: [CaretWordAXReader.OmniboxMetadata?] = [
        nil,
        .init(role: "AXTextField", description: "Address and search bar", domClassList: ["OmniboxViewViews"]),
        .init(role: "AXTextArea", description: "Address and search bar", domClassList: ["OmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Page title", domClassList: ["OmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address", domClassList: ["OmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Search", domClassList: ["OmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address and search bar", domClassList: [], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address and search bar", domClassList: [""], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address and search bar", domClassList: ["OmniboxViewViews"], profile: registry.profile(for: "com.apple.Safari")),
        .init(role: "AXTextField", description: "Address and search bar", domClassList: ["NotBraveOmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address and search bar",
              domClassList: ["custom.BraveOmniboxViewViews"], profile: chromiumProfile),
        .init(role: "AXTextField", description: "Address and search bar", domClassList: ["NotOmniboxViewViews"], profile: chromiumProfile)
    ]
    for metadata in wrongMetadata {
        check(selectedRead("oabc", selection: canonical, metadata: metadata) == nil,
              "selected reader rejects missing or noncanonical actual-field metadata")
    }
    var stored: Data?
    let customRegistry = SharedBrowserRegistry(readData: { stored }, writeData: { stored = $0 })
    do {
        var custom = BrowserProfileEntry(name: "Custom", bundleIdentifier: "example.browser",
            signature: BrowserSignatureOverrides(exactDescriptions: ["Barre d’adresse"], domClasses: ["CustomOmnibox"]))
        try customRegistry.add(custom)
        let localized = CaretWordAXReader.OmniboxMetadata(role: "AXTextField", description: "Barre d’adresse",
            domClassList: ["CustomOmnibox"], profile: customRegistry.profile(for: custom.bundleIdentifier))
        check(selectedRead("oabc", selection: canonical, metadata: localized)?.word == "o",
              "configured exact localized description and class are eligible")
        let nearLocalized = CaretWordAXReader.OmniboxMetadata(role: "AXTextField", description: "Barre d’adresse ",
            domClassList: ["CustomOmnibox"], profile: customRegistry.profile(for: custom.bundleIdentifier))
        check(selectedRead("oabc", selection: canonical, metadata: nearLocalized) == nil,
              "localized description must match exactly")
        custom.enabled = false
        try customRegistry.update(custom)
        let disabled = CaretWordAXReader.OmniboxMetadata(role: "AXTextField", description: "Barre d’adresse",
            domClassList: ["CustomOmnibox"], profile: customRegistry.profile(for: custom.bundleIdentifier))
        check(selectedRead("oabc", selection: canonical, metadata: disabled) == nil,
              "disabled profile cannot authorize selected proof")
    } catch {
        check(false, "custom registry fixture setup succeeds")
    }
    check(selectedRead("oabc!", selection: canonical) == nil, "selected suffix must end at field end")
    check(selectedRead("oabc", selection: canonical, finalSelection: CFRange(location: 1, length: 2)) == nil,
          "selected reader rejects unstable selection")
    check(selectedRead("oabc", selection: canonical, focused: false) == nil, "selected reader rejects unstable focus")
    check(selectedRead("oabc", selection: canonical, subrole: "AXSecureTextField") == nil,
          "selected reader rejects secure field")
    check(selectedRead("oabc", selection: canonical, editable: false) == nil,
          "selected reader rejects noneditable field")
    check(selectedRead("oabc", selection: canonical, role: "AXTextArea") == nil,
          "selected reader rejects wrong actual role")
    check(selectedRead("e\u{301}abc", selection: CFRange(location: 2, length: 3)) == nil, "selected reader rejects NFD")
    check(selectedRead(String(repeating: "a", count: 65) + "xyz", selection: CFRange(location: 65, length: 3)) == nil,
          "selected reader rejects clipped prefix")
}

private func braveSelectedFlow(_ keys: String, expected: [String]) {
    let engine = makeEngine()
    engine.vCheckSpelling = 1
    engine.vRestoreIfWrongSpelling = 1
    var screen = ""
    press("o", engine: engine, screen: &screen)
    engine.cursorMovedSinceReset = true
    engine.focusChangedDuringTyping = true
    let raw = engine.buffer.getKeystrokeSequence()
    let text = "o" + String(repeating: "x", count: 68)
    let selection = CFRange(location: 1, length: 68)
    let metadata = CaretWordAXReader.OmniboxMetadata(role: "AXTextField", description: "Address and search bar",
                                                     domClassList: ["BraveOmniboxViewViews"],
                                                     profile: registry.profile(for: "com.brave.Browser"))
    var selections = 0
    var lengths = 0
    var focuses = 0
    var ranges: [CFRange] = []
    let provider = CaretWordAXReader.Provider(
        role: { "AXTextField" }, subrole: { nil }, isEditable: { true },
        selection: { selections += 1; return selection },
        length: { lengths += 1; return text.utf16.count },
        text: { range in
            ranges.append(range)
            return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        }, isStillFocused: { focuses += 1; return true })
    guard let result = CaretWordAXReader.read(provider, signature: "brave", bundleId: "com.brave.Browser",
                                              revision: engine.typingRevision, omniboxMetadata: metadata) else {
        check(false, "Brave actual field produces selected proof")
        return
    }
    check(result.word == "o" && result.selectionLength == 68 && !result.selectionAnchoredAtCaret
          && result.proofKind == .selectedSuffixReplacement(selectionLength: 68),
          "Brave proof retains actual selected geometry")
    check(selections == 2 && lengths == 1 && focuses == 2 && ranges.count == 1
          && ranges[0].location == 0 && ranges[0].length == 1,
          "Brave proof performs only bounded left read and standard geometry checks")
    check(engine.recoverCaretWord(result) == .validated && !engine.cursorMovedSinceReset
          && !engine.focusChangedDuringTyping && engine.buffer.getKeystrokeSequence() == raw,
          "Brave reader proof clears soft guards without changing raw input")
    for (key, word) in zip(keys, expected) {
        engine.selectionNormalizationAvailable = true
        press(key, engine: engine, screen: &screen)
        engine.selectionNormalizationAvailable = false
        check(screen == word && engine.selectionProofActive, "Brave selected flow reaches \(word)")
    }
}

private func selectedRecoveryScenarios() {
    let empty = makeEngine()
    empty.resetWithCursorMoved()
    check(empty.recoverCaretWord(selectedReport("old", empty)) != .validated && empty.buffer.isEmpty,
          "selected recovery cannot import an old word")
    check(empty.recoverCaretWord(selectedReport("", empty)) != .validated && !empty.selectionProofActive,
          "selected recovery cannot validate an empty owned word")
    let engine = makeEngine()
    var screen = ""
    press("o", engine: engine, screen: &screen)
    engine.focusChangedDuringTyping = true
    check(engine.recoverCaretWord(selectedReport("old", engine)) != .validated,
          "selected recovery rejects partial ownership")
    check(engine.recoverCaretWord(selectedReport("o", engine), nativeBackspaceProof: true) != .validated,
          "native Backspace proof never accepts selected suffix")
    var malformed = selectedReport("o", engine)
    malformed.proofKind = .selectedSuffixReplacement(selectionLength: 2)
    check(engine.recoverCaretWord(malformed) != .validated, "selected proof length must equal actual selection")
    check(engine.recoverCaretWord(selectedReport("o", engine)) == .validated && engine.selectionProofActive,
          "selected proof validates exact owned word")
    check(!engine.focusChangedDuringTyping, "selected proof clears soft focus guard")
    let raw = engine.buffer.getKeystrokeSequence()
    check(engine.recoverCaretWord(report("o", engine)) != .rejected(.selectionNotAnchored)
          && engine.selectionProofActive,
          "collapsed validation does not erase selected ownership")
    check(engine.buffer.getKeystrokeSequence() == raw, "proof preserves raw chronology")
    engine.bufferDesyncDetected = true
    engine.invalidateSelectedSuffixProof()
    check(!engine.selectionProofActive && engine.bufferDesyncDetected && engine.cursorMovedSinceReset,
          "native edit invalidation preserves hard desync")

    let overflow = makeEngine()
    for _ in 0..<40 {
        _ = overflow.processKey(character: "b", keyCode: VietnameseData.keyCode(for: "b")!, isUppercase: false)
    }
    check(overflow.buffer.hasOverflow, "overflow fixture exceeds engine buffer")
    check(overflow.recoverCaretWord(selectedReport(overflow.getCurrentWord(), overflow)) != .validated,
          "selected recovery rejects overflow")
}

private func selectedRestorationFlow() {
    let engine = makeEngine()
    engine.vCheckSpelling = 1
    engine.vRestoreIfWrongSpelling = 1
    var screen = ""
    press("o", engine: engine, screen: &screen)
    engine.focusChangedDuringTyping = true
    check(engine.recoverCaretWord(selectedReport("o", engine)) == .validated, "flow starts with selected proof")
    for (key, expected) in [(Character("r"), "ỏ"), ("d", "ord"), ("e", "orde"), ("r", "order")] {
        engine.selectionNormalizationAvailable = true
        press(key, engine: engine, screen: &screen)
        engine.selectionNormalizationAvailable = false
        check(screen == expected, "selected proof flow reaches \(expected)")
        check(engine.selectionProofActive, "selected proof remains active after \(expected)")
        if expected == "ord" {
            check(engine.buffer.getKeystrokeSequence().count == 3, "raw rebuild retains original chronology")
            _ = engine.recoverCaretWord(report("ord", engine))
            check(engine.selectionProofActive, "collapsed proof cannot clear marker after raw rebuild")
        }
    }
    check(engine.selectionProofActive, "selected requirement remains word scoped")
}

private func selectedVetoFlow() {
    let veto = makeEngine()
    var vetoScreen = ""
    press("o", engine: veto, screen: &vetoScreen)
    veto.focusChangedDuringTyping = true
    check(veto.recoverCaretWord(selectedReport("o", veto)) == .validated, "veto fixture has selected proof")
    press("r", engine: veto, screen: &vetoScreen)
    check(vetoScreen == "or" && veto.selectionProofActive && veto.buffer.getKeystrokeSequence().count == 2,
          "unavailable capability records native literal once and retains proof")
    let beforeUndo = veto.buffer.getKeystrokeSequence()
    check(!veto.undoTyping().shouldConsume && veto.selectionProofActive
          && veto.buffer.getKeystrokeSequence() == beforeUndo,
          "unavailable capability vetoes undo without changing ownership or raw input")
    veto.selectionNormalizationAvailable = true
    press("d", engine: veto, screen: &vetoScreen)
    veto.selectionNormalizationAvailable = false
    check(veto.selectionProofActive && vetoScreen == "ord", "capability can recover on later event")
    let boundary = veto.processWordBreak(character: " ")
    check(!boundary.shouldConsume && !veto.selectionProofActive, "unavailable boundary is native and ends ownership")
}

private func selectedInterruptedFlow() {
    let interrupted = makeEngine()
    interrupted.vCheckSpelling = 1
    interrupted.vRestoreIfWrongSpelling = 1
    var interruptedScreen = ""
    press("o", engine: interrupted, screen: &interruptedScreen)
    interrupted.focusChangedDuringTyping = true
    check(interrupted.recoverCaretWord(selectedReport("o", interrupted)) == .validated, "interrupted fixture has proof")
    interrupted.selectionNormalizationAvailable = true
    press("r", engine: interrupted, screen: &interruptedScreen)
    interrupted.selectionNormalizationAvailable = false
    check(interruptedScreen == "ỏ", "interrupted fixture contains transformed owned prefix")
    press("d", engine: interrupted, screen: &interruptedScreen)
    let rawOrd = "ord".map { RawKeystroke(keyCode: VietnameseData.keyCode(for: $0)!) }
    check(interruptedScreen == "ỏd" && interrupted.buffer.getKeystrokeSequence() == rawOrd
          && interrupted.selectionProofActive,
          "unavailable d passes once and retains transformed prefix and raw ord")
    interrupted.selectionNormalizationAvailable = true
    press("e", engine: interrupted, screen: &interruptedScreen)
    interrupted.selectionNormalizationAvailable = false
    let rawOrde = "orde".map { RawKeystroke(keyCode: VietnameseData.keyCode(for: $0)!) }
    check(interruptedScreen == "orde" && interrupted.buffer.getKeystrokeSequence() == rawOrde
          && interrupted.selectionProofActive,
          "later capability restores orde without losing the native key or proof")

    let deletion = makeEngine()
    var deletionScreen = ""
    press("o", engine: deletion, screen: &deletionScreen)
    deletion.focusChangedDuringTyping = true
    check(deletion.recoverCaretWord(selectedReport("o", deletion)) == .validated, "delete fixture has selected proof")
    deletion.bufferDesyncDetected = true
    check(!deletion.processBackspace().shouldConsume && !deletion.selectionProofActive && deletion.bufferDesyncDetected,
          "native Backspace invalidates selected ownership and preserves hard desync")
}

private func selectedHardDesyncBoundaryScenario() {
    let engine = makeEngine()
    var screen = ""
    press("o", engine: engine, screen: &screen)
    engine.focusChangedDuringTyping = true
    check(engine.recoverCaretWord(selectedReport("o", engine)) == .validated, "boundary fixture has selected proof")
    engine.bufferDesyncDetected = true
    engine.selectionNormalizationAvailable = true
    _ = engine.processWordBreak(character: " ")
    engine.selectionNormalizationAvailable = false
    check(!engine.selectionProofActive && !engine.bufferDesyncDetected,
          "normal space boundary clears selected ownership and hard desync")
}

func runSelectedSuffixScenarios() {
    selectedReaderScenarios()
    selectedRecoveryScenarios()
    let settings = SharedSettings.shared
    let previous = settings.instantRestoreOnWrongSpelling
    defer { settings.instantRestoreOnWrongSpelling = previous }
    settings.instantRestoreOnWrongSpelling = true
    selectedRestorationFlow()
    selectedVetoFlow()
    selectedInterruptedFlow()
    selectedHardDesyncBoundaryScenario()
    braveSelectedFlow("rder", expected: ["ỏ", "ord", "orde", "order"])
    braveSelectedFlow("rber", expected: ["ỏ", "orb", "orbe", "orber"])
}
