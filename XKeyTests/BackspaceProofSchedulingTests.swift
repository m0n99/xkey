import XCTest
@testable import XKey

private final class BackspaceProofHandler: KeyboardEventHandler {
    var onProof: ((Bool, RecoveryOutcome) -> Void)?
    override var canRecoverCaretWord: Bool { true }

    override func recoverCaretWord(_ report: CaretWordReport,
                                   nativeBackspaceProof: Bool = false) -> RecoveryOutcome {
        let outcome = engine.recoverCaretWord(report, nativeBackspaceProof: nativeBackspaceProof)
        onProof?(nativeBackspaceProof, outcome)
        return outcome
    }
}

final class BackspaceProofSchedulingTests: XCTestCase {
    func testTransientGeometryRearmsAndValidatesFreshNativeProof() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let applied = expectation(description: "fresh native proof")
        var reads = 0
        source.axPassReadForTesting = { generation, revision, native in
            XCTAssertTrue(native)
            reads += 1
            return (self.snapshot(generation), reads == 1 ? nil :
                self.proofReport("", revision: revision!, atStart: true, empty: true))
        }
        source.axPassDiagnosticForTesting = { _, _, _ in "caretNotAtWordEnd location=1" }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(handler.engine.needsBackspaceContextProof)
    }

    func testPermanentGeometryFailureStopsAfterThreeNativeReads() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let completed = expectation(description: "third failure")
        var reads = 0
        var armed = 0
        source.axPassReadForTesting = { generation, _, _ in
            reads += 1
            return (self.snapshot(generation), nil)
        }
        source.axPassDiagnosticForTesting = { _, _, _ in "selectionChanged location=0" }
        source.onLogEvent = { message in
            if message.hasPrefix("Native Backspace proof retry armed:") { armed += 1 }
            if message.hasPrefix("Caret recovery read:") && reads == 3 {
                DispatchQueue.main.async { completed.fulfill() }
            }
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(armed, 2)
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        XCTAssertTrue(handler.engine.needsBackspaceContextProof)
    }

    func testNewNativeDeleteResetsPendingRetryBudget() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let first = expectation(description: "first retry armed")
        let second = expectation(description: "second retry armed")
        let reset = expectation(description: "new delete restarted retry budget")
        var armed = 0
        source.axPassReadForTesting = { generation, _, _ in (self.snapshot(generation), nil) }
        source.axPassDiagnosticForTesting = { _, _, _ in "invalidBounds location=3" }
        source.onLogEvent = { message in
            if message.hasPrefix("Native Backspace proof retry armed:") {
                armed += 1
                if armed == 1 { first.fulfill() }
                if armed == 2 { second.fulfill() }
                if armed == 3 { reset.fulfill() }
            }
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [first, second], timeout: 5, enforceOrder: true)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [reset], timeout: 5)
        XCTAssertEqual(armed, 3)
    }

    func testNilGeometryDuringReadCannotRetryChangedContext() throws {
        for change in ["typing", "focus", "identity", "host", "stop", "registry", "desync"] {
            let handler = BackspaceProofHandler()
            var active = true
            var identity: (pid: pid_t?, bundleId: String?) = (42, "app")
            let source = TapEventSource(handler: handler, isActiveHost: { active })
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            source.backspaceProofIdentityForTesting = { (identity.pid, identity.bundleId) }
            source.recoveryIdentityForTesting = { identity }
            source.recoveryEligibilityForTesting = { true }
            defer { source.stopBackspaceProofForTesting() }
            let entered = expectation(description: "read entered \(change)")
            let finished = expectation(description: "read returned \(change)")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            source.axPassReadForTesting = { generation, _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (self.snapshot(generation), nil)
            }
            source.axPassDiagnosticForTesting = { _, _, _ in "caretNotAtWordEnd" }
            source.onLogEvent = { message in
                if message.hasPrefix("Caret recovery read:") { DispatchQueue.main.async { finished.fulfill() } }
            }
            _ = handler.engine.processBackspace()
            handler.onNativeBackspacePassedThrough?()
            source.settleBackspaceProofForTesting()
            wait(for: [entered], timeout: 5)
            switch change {
            case "typing": type("a", handler: handler)
            case "focus":
                source.focusElapsedForTesting = { 0 }
                source.recoveryEligibilityForTesting = { false }
                source.handleAXFocusChanged(AXUIElementCreateSystemWide())
            case "identity": identity.pid = 43
            case "host": active = false
            case "stop": source.stopBackspaceProofForTesting()
            case "registry": source.handleBrowserRegistryReload()
            default: handler.engine.bufferDesyncDetected = true
            }
            release.signal()
            wait(for: [finished], timeout: 5)
            XCTAssertFalse(source.hasPendingBackspaceProofForTesting, "\(change) must not retry a nil stale read")
        }
    }

    func testTypingDuringRetrySettleUsesFreshOwnedRevision() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let armed = expectation(description: "retry armed")
        let applied = expectation(description: "owned retry validates")
        var reads = 0
        source.axPassReadForTesting = { generation, revision, _ in
            reads += 1
            return (self.snapshot(generation), reads == 1 ? nil : self.proofReport("abc", revision: revision!))
        }
        source.axPassDiagnosticForTesting = { _, _, _ in "caretNotAtWordEnd" }
        source.onLogEvent = { message in
            if message.hasPrefix("Native Backspace proof retry armed:") { armed.fulfill() }
        }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [armed], timeout: 5)
        type("abc", handler: handler)
        let raw = handler.engine.buffer.getKeystrokeSequence()
        source.settleBackspaceProofForTesting()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(handler.engine.buffer.getKeystrokeSequence(), raw)
    }

    func testNewDeleteWhileReadInFlightOwnsTheNextProof() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let entered = expectation(description: "first delete read entered")
        let applied = expectation(description: "new delete proof applied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var reads = 0
        var retryArms = 0
        source.axPassReadForTesting = { generation, revision, _ in
            reads += 1
            if reads == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (self.snapshot(generation), nil)
            }
            return (self.snapshot(generation), self.proofReport("", revision: revision!, atStart: true, empty: true))
        }
        source.axPassDiagnosticForTesting = { _, _, _ in "invalidSelection location=-1" }
        source.onLogEvent = { message in
            if message.hasPrefix("Native Backspace proof retry armed:") { retryArms += 1 }
        }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [entered], timeout: 5)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        release.signal()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(retryArms, 0)
    }

    private func snapshot(_ generation: UInt64) -> TapEventSource.AXSnapshot {
        TapEventSource.AXSnapshot(generation: generation, focusedInfo: .empty,
                                  hasFocusedElement: false, overlayName: nil)
    }

    private func proofReport(_ word: String, revision: UInt64,
                             atStart: Bool = false, empty: Bool = false) -> CaretWordReport {
        CaretWordReport(word: word, caretAtWordEnd: true, selectionAnchoredAtCaret: true,
                        selectionLength: 0, elementSignature: "field", appBundleId: nil,
                        expectedRevision: revision, caretAtFieldStart: atStart, fieldIsEmpty: empty)
    }

    private func type(_ text: String, handler: KeyboardEventHandler) {
        for key in text {
            _ = handler.engine.processKey(character: key, keyCode: VietnameseData.keyCode(for: key)!,
                                          isUppercase: false)
        }
    }

    private func source(_ handler: KeyboardEventHandler) throws -> TapEventSource {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost application identity")
        }
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        handler.engine.vCheckSpelling = 0
        source.startBackspaceProofForTesting(pid: app.processIdentifier, bundleId: app.bundleIdentifier)
        return source
    }

    func testProofReadsNewRevisionAfterRetypingAndAppliesNativeLaneOffMain() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        let oldRevision = handler.typingRevision
        type("abc", handler: handler)
        let newRevision = handler.typingRevision
        XCTAssertGreaterThan(newRevision, oldRevision)
        let applied = expectation(description: "native proof applied")
        var reads = 0
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        source.axPassReadForTesting = { generation, revision, native in
            reads += 1
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(native)
            XCTAssertEqual(revision, newRevision)
            return (self.snapshot(generation), self.proofReport("abc", revision: revision!))
        }
        source.settleBackspaceProofForTesting()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(reads, 1, "successful first proof must not retry")
        XCTAssertFalse(handler.engine.needsBackspaceContextProof)
        XCTAssertFalse(handler.engine.cursorMovedSinceReset)
    }

    func testTypingDuringReadRejectsSnapshot() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let entered = expectation(description: "read entered")
        let rejected = expectation(description: "stale report rejected")
        let release = DispatchSemaphore(value: 0)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.axPassReadForTesting = { generation, revision, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (self.snapshot(generation), self.proofReport("", revision: revision!, atStart: true, empty: true))
        }
        handler.onProof = { _, _ in XCTFail("stale proof must not reach the engine") }
        source.onLogEvent = { message in
            if message.hasPrefix("Caret recovery apply rejected: stale/owner") { rejected.fulfill() }
        }
        source.settleBackspaceProofForTesting()
        wait(for: [entered], timeout: 5)
        type("a", handler: handler)
        release.signal()
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(handler.engine.needsBackspaceContextProof)
    }

    func testNativeLaneRejectsOldEmptyBoundaryAndPreservesHardDesync() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        let entered = expectation(description: "read entered")
        let applied = expectation(description: "proof reached engine")
        let release = DispatchSemaphore(value: 0)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.axPassReadForTesting = { generation, revision, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (self.snapshot(generation), self.proofReport("", revision: revision!))
        }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertNotEqual(outcome, .validated, "old-space empty boundary is not proof")
            applied.fulfill()
        }
        source.settleBackspaceProofForTesting()
        wait(for: [entered], timeout: 5)
        handler.engine.bufferDesyncDetected = true
        release.signal()
        wait(for: [applied], timeout: 5)
        XCTAssertTrue(handler.engine.cursorMovedSinceReset)
        XCTAssertTrue(handler.engine.bufferDesyncDetected)
    }

    func testBusyOrdinaryPassFinishesBookkeepingBeforeProofRead() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw XCTSkip("No frontmost application") }
        source.focusObserverFailedPID = app.processIdentifier
        let ordinaryStarted = expectation(description: "ordinary read entered")
        let bookkeeping = expectation(description: "ordinary bookkeeping applied")
        let proofRead = expectation(description: "proof read after bookkeeping")
        let release = DispatchSemaphore(value: 0)
        var didBookkeeping = false
        source.onNoFocusedElement = { didBookkeeping = true; bookkeeping.fulfill() }
        source.axPassReadForTesting = { generation, revision, native in
            XCTAssertFalse(Thread.isMainThread)
            if !native {
                ordinaryStarted.fulfill()
                _ = release.wait(timeout: .now() + 5)
            } else {
                DispatchQueue.main.async {
                    XCTAssertTrue(didBookkeeping)
                    proofRead.fulfill()
                }
            }
            return (self.snapshot(generation), revision.map { self.proofReport("", revision: $0, atStart: true) })
        }
        source.handleFocusCheck()
        wait(for: [ordinaryStarted], timeout: 5)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        release.signal()
        wait(for: [bookkeeping, proofRead], timeout: 5, enforceOrder: true)
    }

    func testIdleDrainWaitsForSettleAndBusyQueueKeepsCoalescedRequest() {
        let handler = KeyboardEventHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        source.backspaceProofIdentityForTesting = { (43, "app") }
        var scheduled = 0
        source.onBackspaceProofScheduledForTesting = { _ in scheduled += 1 }

        for _ in 0..<5 { handler.onNativeBackspacePassedThrough?() }
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        source.drainBackspaceProofForTesting()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting, "idle must not bypass settle")
        XCTAssertEqual(scheduled, 0)

        source.backspaceProofQueueBusyForTesting = true
        source.settleBackspaceProofForTesting()
        source.drainBackspaceProofForTesting()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting, "busy queue must retain the request")
        XCTAssertEqual(scheduled, 0)
        source.backspaceProofQueueBusyForTesting = false
        source.drainBackspaceProofForTesting()
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        XCTAssertEqual(scheduled, 0, "changed identity rejects the coalesced request")
    }

    func testIdentityAndHostChangesRejectSettledRequests() {
        for (pid, bundle, active) in [(pid_t(43), "app", true), (pid_t(42), "other", true),
                                      (pid_t(42), "app", false)] {
            var hostActive = true
            let handler = KeyboardEventHandler()
            let source = TapEventSource(handler: handler, isActiveHost: { hostActive })
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            source.backspaceProofIdentityForTesting = { (pid, bundle) }
            var scheduled = 0
            source.onBackspaceProofScheduledForTesting = { _ in scheduled += 1 }
            handler.onNativeBackspacePassedThrough?()
            hostActive = active
            source.settleBackspaceProofForTesting()
            XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
            XCTAssertEqual(scheduled, 0)
            source.stopBackspaceProofForTesting()
        }
    }

    func testStopAndFocusChangeCancelPendingTokens() {
        var active = true
        let handler = KeyboardEventHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { active })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        source.stopBackspaceProofForTesting()
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        XCTAssertNil(handler.onNativeBackspacePassedThrough)

        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        active = false
        source.handleAXFocusChanged(AXUIElementCreateSystemWide())
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        source.settleBackspaceProofForTesting()
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
    }
}

extension BackspaceProofSchedulingTests {
    func testRegistryChangeCancelsPendingProofAndInvalidatesSelectedOwnership() {
        let handler = KeyboardEventHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        type("o", handler: handler)
        var report = CaretWordReport(word: "o", caretAtWordEnd: true, selectionAnchoredAtCaret: false,
                                     selectionLength: 3, elementSignature: "field", appBundleId: "app",
                                     expectedRevision: handler.typingRevision)
        report.proofKind = .selectedSuffixReplacement(selectionLength: 3)
        XCTAssertEqual(handler.engine.recoverCaretWord(report), .validated)
        XCTAssertTrue(handler.engine.selectionProofActive)
        handler.engine.bufferDesyncDetected = true
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)

        source.handleBrowserRegistryReload()

        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        XCTAssertFalse(handler.engine.selectionProofActive)
        XCTAssertTrue(handler.engine.bufferDesyncDetected)
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting, "registry reload preserves cached identity")
    }

    func testRegistryChangeRejectsInFlightProofWithoutAXReads() {
        let handler = BackspaceProofHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        source.backspaceProofIdentityForTesting = { (42, "app") }
        source.recoveryEligibilityForTesting = { true }
        let entered = expectation(description: "proof read entered")
        let rejected = expectation(description: "old proof rejected")
        let release = DispatchSemaphore(value: 0)
        source.axPassReadForTesting = { generation, revision, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (self.snapshot(generation), self.proofReport("", revision: revision!, atStart: true, empty: true))
        }
        handler.onProof = { _, _ in XCTFail("registry change must reject old proof") }
        source.onLogEvent = { message in
            if message.hasPrefix("Caret recovery apply rejected: stale generation") { rejected.fulfill() }
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [entered], timeout: 5)
        source.handleBrowserRegistryReload()
        release.signal()
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(handler.engine.needsBackspaceContextProof)
    }

    func testOldDeactivationPreservesNewIdentityAndQueuedProof() {
        let handler = KeyboardEventHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "old")
        defer { source.stopBackspaceProofForTesting() }
        source.recordFrontmostApplicationIdentity(pid: 43, bundleId: "new")
        source.backspaceProofIdentityForTesting = { (43, "new") }
        source.backspaceProofQueueBusyForTesting = true
        handler.onNativeBackspacePassedThrough?()
        source.recordFrontmostApplicationIdentity(pid: 43, bundleId: "new")
        source.handleApplicationDeactivation(pid: 42)
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)

        _ = handler.engine.processBackspace()
        source.recoveryEligibilityForTesting = { true }
        source.axPassReadForTesting = { generation, _, _ in (self.snapshot(generation), nil) }
        var scheduled = 0
        source.onBackspaceProofScheduledForTesting = { _ in scheduled += 1 }
        source.settleBackspaceProofForTesting()
        source.backspaceProofQueueBusyForTesting = false
        source.drainBackspaceProofForTesting()
        XCTAssertEqual(scheduled, 1)
    }

    func testOwnerDeactivationClearsIdentityAndPendingProof() {
        let handler = KeyboardEventHandler()
        let source = TapEventSource(handler: handler, isActiveHost: { true })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        source.handleApplicationDeactivation(pid: 42)
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
        handler.onNativeBackspacePassedThrough?()
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)
    }

    func testOrdinaryAXPassHealsIdentityForNativeProof() throws {
        let handler = BackspaceProofHandler()
        let source = try source(handler)
        defer { source.stopBackspaceProofForTesting() }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw XCTSkip("No frontmost application") }
        source.focusObserverFailedPID = app.processIdentifier
        source.handleApplicationDeactivation(pid: app.processIdentifier)
        handler.onNativeBackspacePassedThrough?()
        XCTAssertFalse(source.hasPendingBackspaceProofForTesting)

        let ordinaryStarted = expectation(description: "ordinary read entered")
        let proofApplied = expectation(description: "healed native proof applied")
        let release = DispatchSemaphore(value: 0)
        source.axPassReadForTesting = { generation, revision, native in
            if !native {
                ordinaryStarted.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return (self.snapshot(generation), revision.map {
                self.proofReport("", revision: $0, atStart: true, empty: true)
            })
        }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native)
            XCTAssertEqual(outcome, .validated)
            proofApplied.fulfill()
        }
        source.handleFocusCheck()
        wait(for: [ordinaryStarted], timeout: 5)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        source.settleBackspaceProofForTesting()
        release.signal()
        wait(for: [proofApplied], timeout: 5)
    }

}
