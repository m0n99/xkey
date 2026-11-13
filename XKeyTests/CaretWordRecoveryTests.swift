import XCTest
@testable import XKey

final class CaretWordRecoveryTests: XCTestCase {
    private func report(_ word: String, _ engine: VNEngine, end: Bool = true,
                        anchored: Bool = true, selection: Int = 0, revision: UInt64? = nil) -> CaretWordReport {
        CaretWordReport(word: word, caretAtWordEnd: end, selectionAnchoredAtCaret: anchored,
                        selectionLength: selection, elementSignature: "field", appBundleId: nil,
                        expectedRevision: revision ?? engine.typingRevision)
    }

    private func type(_ text: String, into engine: VNEngine) {
        for character in text {
            _ = engine.handleKeyEvent(keyCode: VietnameseData.keyCode(for: character)!, character: character,
                                      isUppercase: false, hasOtherModifier: false)
        }
    }

    private func engine() -> VNEngine {
        let engine = VNEngine()
        engine.vCheckSpelling = 0
        engine.spellCheckVerdictOverride = { _ in false }
        return engine
    }

    private func assertRestores(_ engine: VNEngine, file: StaticString = #filePath, line: UInt = #line) {
        type("etsy", into: engine)
        XCTAssertEqual(engine.getCurrentWord(), "éty", file: file, line: line)
        engine.vCheckSpelling = 1
        let result = engine.processWordBreak(character: ".")
        XCTAssertTrue(result.shouldConsume, file: file, line: line)
        XCTAssertEqual(result.backspaceCount, 3, file: file, line: line)
        XCTAssertEqual(result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined(), "etsy.", file: file, line: line)
    }

    func testParserRequiresBoundariesAndRejectsDecomposedWord() {
        XCTAssertNil(CaretWordParser.parse(leftContext: "word", rightContext: "", leftContextStartsAtFieldStart: false, rightContextEndsAtFieldEnd: true))
        XCTAssertNil(CaretWordParser.parse(leftContext: "e\u{301}", rightContext: "", leftContextStartsAtFieldStart: true, rightContextEndsAtFieldEnd: true))
        XCTAssertNil(CaretWordParser.parse(leftContext: "word", rightContext: "", leftContextStartsAtFieldStart: true, rightContextEndsAtFieldEnd: false))
        let result = CaretWordParser.parse(leftContext: "a thử", rightContext: "x", leftContextStartsAtFieldStart: true, rightContextEndsAtFieldEnd: false)
        XCTAssertEqual(result?.word, "thử")
        XCTAssertEqual(result?.caretAtWordEnd, false)
    }

    func testEmptyBoundaryAfterClickAllowsFirstNewWordRestore() {
        let engine = engine()
        engine.resetWithCursorMoved()
        engine.focusChangedDuringTyping = true
        XCTAssertEqual(engine.recoverCaretWord(report("", engine)), .validated)
        XCTAssertFalse(engine.cursorMovedSinceReset)
        XCTAssertFalse(engine.focusChangedDuringTyping)
        assertRestores(engine)
    }

    func testExactMatchRetainsRawHistoryAndAllowsRestore() {
        let engine = engine()
        type("etsy", into: engine)
        let raw = engine.buffer.getKeystrokeSequence()
        engine.notifyFocusChanged()
        engine.cursorMovedSinceReset = true
        let pending = report(engine.getCurrentWord(), engine)
        XCTAssertEqual(engine.recoverCaretWord(pending), .validated)
        XCTAssertEqual(engine.recoverCaretWord(pending), .rejected(.staleRevision))
        XCTAssertEqual(engine.buffer.getKeystrokeSequence(), raw)
        engine.vCheckSpelling = 1
        let result = engine.processWordBreak(character: ".")
        XCTAssertTrue(result.shouldConsume)
        XCTAssertEqual(result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined(), "etsy.")
    }

    func testPartialWordStaysGuardedUntilNextWord() {
        let engine = engine()
        engine.resetWithCursorMoved()
        type("oof", into: engine)
        XCTAssertEqual(engine.recoverCaretWord(report("chồn", engine)), .rejected(.engineHasPartialWord))
        XCTAssertTrue(engine.cursorMovedSinceReset)
        engine.vCheckSpelling = 1
        XCTAssertFalse(engine.processWordBreak(character: " ").shouldConsume)
        engine.vCheckSpelling = 0
        assertRestores(engine)
    }

    func testRejectsOldWordAndInvalidReportsWithoutMutation() {
        let engine = engine()
        engine.resetWithCursorMoved()
        let revision = engine.typingRevision
        XCTAssertEqual(engine.recoverCaretWord(report("thư", engine)), .rejected(.wordMismatch))
        XCTAssertEqual(engine.recoverCaretWord(report("e\u{301}", engine)), .rejected(.wordMismatch))
        XCTAssertEqual(engine.recoverCaretWord(report("", engine, end: false)), .rejected(.midWordCaret))
        XCTAssertEqual(engine.recoverCaretWord(report("", engine, selection: 1)), .rejected(.selectionNotAnchored))
        XCTAssertEqual(engine.recoverCaretWord(report("", engine, anchored: false)), .rejected(.selectionNotAnchored))
        XCTAssertEqual(engine.typingRevision, revision)
        XCTAssertTrue(engine.buffer.isEmpty)
        XCTAssertTrue(engine.cursorMovedSinceReset)
        engine.vCodeTable = 1
        XCTAssertEqual(engine.recoverCaretWord(report("", engine)), .notApplicable)
    }

    func testEmptyBoundaryDiscardsHistoryButPreservesMacroAndDesync() {
        let engine = engine()
        type("abc", into: engine)
        _ = engine.processWordBreak(character: " ")
        XCTAssertGreaterThan(engine.history.count, 0)
        engine.cursorMovedSinceReset = true
        engine.focusChangedDuringTyping = true
        engine.bufferDesyncDetected = true
        engine.hookState.macroKey = [42]
        let pending = report("", engine)
        XCTAssertEqual(engine.recoverCaretWord(pending), .validated)
        XCTAssertEqual(engine.recoverCaretWord(pending), .rejected(.staleRevision))
        XCTAssertEqual(engine.history.count, 0)
        XCTAssertEqual(engine.hookState.macroKey, [42])
        XCTAssertTrue(engine.bufferDesyncDetected)
        _ = engine.processBackspace()
        XCTAssertTrue(engine.buffer.isEmpty)
        XCTAssertEqual(engine.history.count, 0)
    }

    func testEmptyNoopAndRevisionInvalidation() {
        let engine = engine()
        let revision = engine.typingRevision
        XCTAssertEqual(engine.recoverCaretWord(report("", engine)), .notApplicable)
        XCTAssertEqual(engine.typingRevision, revision)
        type("abc", into: engine)
        let beforeDelete = report(engine.getCurrentWord(), engine)
        _ = engine.processBackspace()
        XCTAssertFalse(engine.buffer.isEmpty)
        XCTAssertEqual(engine.recoverCaretWord(beforeDelete), .rejected(.staleRevision))
        let beforeClear = report(engine.getCurrentWord(), engine)
        engine.clearHistory()
        XCTAssertEqual(engine.recoverCaretWord(beforeClear), .rejected(.staleRevision))
    }

    func testNewSessionClearsFocusGuardWithSpellingDisabled() {
        let engine = engine()
        engine.focusChangedDuringTyping = true
        engine.startNewSession()
        XCTAssertFalse(engine.focusChangedDuringTyping)
    }
}
