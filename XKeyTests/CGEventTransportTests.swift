import CoreGraphics
import XCTest
@testable import XKey

final class CGEventTransportTests: XCTestCase {
    func testNormalizesKeyDownFieldsAndAllSupportedModifiers() throws {
        let event = try makeEvent(keyCode: 0x10, characters: "z")
        event.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand,
                       .maskSecondaryFn, .maskAlphaShift]
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        let normalized = try XCTUnwrap(CGEventTransport(sink: RecordingSink()).normalize(event, type: .keyDown))

        XCTAssertEqual(normalized.kind, .keyDown)
        XCTAssertEqual(normalized.keyCode, 0x10)
        XCTAssertEqual(normalized.characters, "z")
        XCTAssertEqual(normalized.modifiers,
                       [.control, .option, .shift, .command, .function, .capsLock])
        XCTAssertTrue(normalized.isRepeat)
    }

    func testNormalizesFlagsChangedWithoutTreatingItAsKeyDown() throws {
        let event = try makeEvent(keyCode: 0x38)
        event.flags = [.maskShift]

        let normalized = try XCTUnwrap(CGEventTransport(sink: RecordingSink()).normalize(event, type: .flagsChanged))

        XCTAssertEqual(normalized.kind, .flagsChanged)
        XCTAssertEqual(normalized.keyCode, 0x38)
        XCTAssertEqual(normalized.modifiers, [.shift])
        XCTAssertFalse(normalized.isRepeat)
    }

    func testIgnoresUnsupportedEventTypes() throws {
        let event = try makeEvent(keyCode: VietnameseData.KEY_A)

        XCTAssertNil(CGEventTransport(sink: RecordingSink()).normalize(event, type: .keyUp))
    }

    func testPassThroughCommitAndResetPreserveOriginalEventIdentity() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_A, characters: "a")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))

        XCTAssertTrue(transport.apply(.passThrough, event: normalized, originalEvent: event, proxy: nil) === event)
        XCTAssertTrue(transport.apply(.commit(text: "a"), event: normalized, originalEvent: event, proxy: nil) === event)
        XCTAssertTrue(transport.apply(.reset, event: normalized, originalEvent: event, proxy: nil) === event)
        XCTAssertEqual(sink.sessions.count, 1)
        XCTAssertEqual(sink.sessions.first?.cursorMoved, false)
        XCTAssertEqual(sink.sessions.first?.preserveMidSentence, true)
    }

    func testConsumeReturnsNilWithoutInjection() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_A, characters: "a")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))

        XCTAssertNil(transport.apply(.consume, event: normalized, originalEvent: event, proxy: nil))
        XCTAssertTrue(sink.injections.isEmpty)
    }

    func testNonReturnReplacementInjectsWithoutStartingNewSession() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_S, characters: "s")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))
        let characters = [VNCharacter(vowel: .a, tone: .acute)]
        let action = InputAction.replace(backspaces: 1, characters: characters, codeTable: .vniWindows)

        XCTAssertNil(transport.apply(action, event: normalized, originalEvent: event, proxy: nil))
        XCTAssertEqual(sink.injections, [Injection(backspaces: 1,
                                                   characters: characters,
                                                   codeTable: .vniWindows)])
        XCTAssertEqual(sink.calls, [.injection])
        XCTAssertNil(sink.injectionProfiles.first!)
    }

    func testCapturedProfileSurvivesSinkCapabilityChange() throws {
        let sink = RecordingSink()
        let info = InjectionMethodInfo(method: .fast, delays: (0, 0, 0), textSendingMethod: .chunked,
                                       description: "captured", needsEmptyCharPrefix: true)
        sink.capturedProfile = try XCTUnwrap(SelectedSuffixInjectionProfile(methodInfo: info))
        let transport = CGEventTransport(sink: sink)
        let captured = try XCTUnwrap(transport.captureSelectionNormalizationProfile())
        sink.capturedProfile = nil
        let event = try makeEvent(keyCode: VietnameseData.KEY_S, characters: "s")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))
        _ = transport.apply(.replace(backspaces: 1, text: "á"), event: normalized,
                            originalEvent: event, proxy: nil, selectionNormalizationProfile: captured)
        XCTAssertEqual(sink.injectionProfiles.count, 1)
        XCTAssertEqual(sink.injectionProfiles[0]?.methodInfo.description, "captured")
        XCTAssertTrue(sink.injectionProfiles[0]?.methodInfo.needsEmptyCharPrefix == true)
    }

    func testHandlerCapturesOnlyOncePerSelectedEvent() throws {
        let sink = RecordingSink()
        let handler = KeyboardEventHandler(transport: CGEventTransport(sink: sink))
        handler.engine.vCheckSpelling = 0
        let proxy = unsafeBitCast(UInt(1), to: CGEventTapProxy.self)
        let initialEvent = try makeEvent(keyCode: VietnameseData.keyCode(for: "o")!, characters: "o")
        _ = handler.processKeyEvent(initialEvent, type: .keyDown, proxy: proxy)
        XCTAssertEqual(sink.captureCount, 0, "ordinary events must not capture a selection profile")
        handler.engine.focusChangedDuringTyping = true
        var proof = CaretWordReport(word: "o", caretAtWordEnd: true, selectionAnchoredAtCaret: false,
                                    selectionLength: 3, elementSignature: "field", appBundleId: nil,
                                    expectedRevision: handler.engine.typingRevision)
        proof.proofKind = .selectedSuffixReplacement(selectionLength: 3)
        XCTAssertEqual(handler.engine.recoverCaretWord(proof), .validated)
        let info = InjectionMethodInfo(method: .fast, delays: (0, 0, 0), textSendingMethod: .chunked,
                                       description: "event snapshot", needsEmptyCharPrefix: true)
        sink.capturedProfile = try XCTUnwrap(SelectedSuffixInjectionProfile(methodInfo: info))
        sink.onInject = { [weak sink] in sink?.capturedProfile = nil }
        let transformEvent = try makeEvent(keyCode: VietnameseData.keyCode(for: "r")!, characters: "r")
        XCTAssertNil(handler.processKeyEvent(transformEvent, type: .keyDown, proxy: proxy))
        XCTAssertEqual(sink.captureCount, 1)
        XCTAssertEqual(sink.injections.count, 1, "replacement must not be dropped after engine mutation")
        XCTAssertEqual(sink.injectionProfiles.first??.methodInfo.description, "event snapshot")
        XCTAssertFalse(handler.engine.selectionNormalizationAvailable, "capability is event scoped")
        let nativeEvent = try makeEvent(keyCode: VietnameseData.keyCode(for: "d")!, characters: "d")
        XCTAssertTrue(handler.processKeyEvent(nativeEvent, type: .keyDown, proxy: proxy) === nativeEvent)
        XCTAssertEqual(sink.captureCount, 2, "each selected event captures once")
        XCTAssertEqual(sink.injections.count, 1,
                       "unsupported capture passes the native key instead of emitting a rewrite")
        XCTAssertTrue(handler.engine.selectionProofActive)
    }

    func testReturnReplacementInjectsBeforeStartingNewSession() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_RETURN, characters: "\r")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))
        let action = InputAction.replace(backspaces: 1,
                                         characters: [VNCharacter(character: "a")],
                                         codeTable: .unicode)

        XCTAssertNil(transport.apply(action, event: normalized, originalEvent: event, proxy: nil))
        XCTAssertEqual(sink.calls, [.injection, .session(cursorMoved: true,
                                                        preserveMidSentence: false)])
    }

    func testConsumedReturnStartsNewSession() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_RETURN, characters: "\n")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))

        XCTAssertNil(transport.apply(.consume, event: normalized, originalEvent: event, proxy: nil))
        XCTAssertEqual(sink.calls, [.session(cursorMoved: true,
                                             preserveMidSentence: false)])
    }

    func testCommandReturnResetDoesNotUseNewlineSessionMark() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: VietnameseData.KEY_RETURN, characters: "\r")
        event.flags = [.maskCommand]
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))

        XCTAssertTrue(transport.apply(.reset,
                                      event: normalized,
                                      originalEvent: event,
                                      proxy: nil) === event)
        XCTAssertEqual(sink.calls, [.session(cursorMoved: false,
                                             preserveMidSentence: true)])
    }

    func testUndoReplacementStartsFreshSessionWhileRegularReplacementDoesNot() throws {
        let sink = RecordingSink()
        let transport = CGEventTransport(sink: sink)
        let event = try makeEvent(keyCode: 0x35)
        let undo = InputEvent(kind: .undo, keyCode: nil, characters: nil, modifiers: [], isRepeat: false)

        _ = transport.apply(.replace(backspaces: 1,
                                     characters: [VNCharacter(character: "a")],
                                     codeTable: .unicode),
                            event: undo,
                            originalEvent: event,
                            proxy: nil)

        XCTAssertEqual(sink.sessions.count, 1)
        XCTAssertEqual(sink.sessions.first?.cursorMoved, false)
        XCTAssertEqual(sink.sessions.first?.preserveMidSentence, true)
    }

    func testOwnershipReleaseWaitsForPendingInjection() throws {
        let sink = BlockingInjectionSink()
        let transport = CGEventTransport(sink: sink)
        let handler = KeyboardEventHandler(transport: transport)
        let event = try makeEvent(keyCode: VietnameseData.KEY_S, characters: "s")
        let normalized = try XCTUnwrap(transport.normalize(event, type: .keyDown))
        _ = transport.apply(.replace(backspaces: 1, text: "á"),
                            event: normalized,
                            originalEvent: event,
                            proxy: nil)
        XCTAssertEqual(sink.injectionStarted.wait(timeout: .now() + 1), .success)

        let ownershipReleased = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            handler.releaseOwnership(afterPendingInjection: {
                ownershipReleased.signal()
            })
        }

        XCTAssertEqual(ownershipReleased.wait(timeout: .now() + 0.05), .timedOut)
        sink.allowInjectionToFinish.signal()
        XCTAssertEqual(ownershipReleased.wait(timeout: .now() + 1), .success)
    }

    private func makeEvent(keyCode: CGKeyCode, characters: String? = nil) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source,
                                         virtualKey: keyCode,
                                         keyDown: true))
        if let characters {
            var utf16 = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        }
        return event
    }
}

private struct Injection: Equatable {
    let backspaces: Int
    let characters: [VNCharacter]
    let codeTable: CodeTable
}

private enum SinkCall: Equatable {
    case injection
    case session(cursorMoved: Bool, preserveMidSentence: Bool)
}

private final class RecordingSink: CGEventInjectionSink {
    var prefersAsyncDirectInjection = false
    var debugCallback: ((String) -> Void)?
    var injections: [Injection] = []
    var sessions: [(cursorMoved: Bool, preserveMidSentence: Bool)] = []
    var calls: [SinkCall] = []
    var capturedProfile: SelectedSuffixInjectionProfile?
    var injectionProfiles: [SelectedSuffixInjectionProfile?] = []
    var captureCount = 0
    var onInject: (() -> Void)?

    func captureSelectionNormalizationProfile() -> SelectedSuffixInjectionProfile? {
        captureCount += 1
        return capturedProfile
    }

    func inject(backspaceCount: Int,
                characters: [VNCharacter],
                codeTable: CodeTable,
                proxy: CGEventTapProxy?,
                selectionNormalizationProfile: SelectedSuffixInjectionProfile?) {
        onInject?()
        injectionProfiles.append(selectionNormalizationProfile)
        injections.append(Injection(backspaces: backspaceCount,
                                    characters: characters,
                                    codeTable: codeTable))
        calls.append(.injection)
    }

    func waitForInjectionComplete() {}

    func markNewSession(cursorMoved: Bool, preserveMidSentence: Bool) {
        sessions.append((cursorMoved, preserveMidSentence))
        calls.append(.session(cursorMoved: cursorMoved,
                              preserveMidSentence: preserveMidSentence))
    }

    func resetMidSentenceFlag() {}
    func clearMethodCache() {}
}

private final class BlockingInjectionSink: CGEventInjectionSink {
    var prefersAsyncDirectInjection = false
    var debugCallback: ((String) -> Void)?
    let injectionStarted = DispatchSemaphore(value: 0)
    let allowInjectionToFinish = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)

    func captureSelectionNormalizationProfile() -> SelectedSuffixInjectionProfile? { nil }

    func inject(backspaceCount: Int,
                characters: [VNCharacter],
                codeTable: CodeTable,
                proxy: CGEventTapProxy?,
                selectionNormalizationProfile: SelectedSuffixInjectionProfile?) {
        DispatchQueue.global().async {
            self.injectionStarted.signal()
            self.allowInjectionToFinish.wait()
            self.completed.signal()
        }
    }

    func waitForInjectionComplete() {
        completed.wait()
    }

    func markNewSession(cursorMoved: Bool, preserveMidSentence: Bool) {}
    func resetMidSentenceFlag() {}
    func clearMethodCache() {}
}
