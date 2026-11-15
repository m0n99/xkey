import XCTest
@testable import XKey

private final class CaretRetryHandler: KeyboardEventHandler {
    var onProof: ((Bool, RecoveryOutcome) -> Void)?
    override var canRecoverCaretWord: Bool { true }

    override func recoverCaretWord(_ report: CaretWordReport,
                                   nativeBackspaceProof: Bool = false) -> RecoveryOutcome {
        let outcome = engine.recoverCaretWord(report, nativeBackspaceProof: nativeBackspaceProof)
        onProof?(nativeBackspaceProof, outcome)
        return outcome
    }
}

final class CaretRecoveryRetryTests: XCTestCase {
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

    private func retrySource(_ handler: CaretRetryHandler,
                             active: @escaping () -> Bool = { true }) -> TapEventSource {
        let source = TapEventSource(handler: handler, isActiveHost: active)
        handler.engine.vCheckSpelling = 0
        source.recoveryEligibilityForTesting = { true }
        source.recoveryIdentityForTesting = { (42, "app") }
        return source
    }

    func testFreshRetryAppliesOnlyNewCollapsedAndSelectedReports() {
        for selected in [false, true] {
            let handler = CaretRetryHandler()
            let source = retrySource(handler)
            type("o", handler: handler)
            handler.engine.focusChangedDuringTyping = true
            let applied = expectation(description: "fresh proof applied")
            var scheduled: [UInt64] = []
            var reads = 0
            var appliedCount = 0
            var revisionAfterTyping: UInt64?
            source.onRecoveryScheduledForTesting = { scheduled.append($0) }
            handler.onProof = { native, outcome in
                XCTAssertFalse(native)
                XCTAssertEqual(outcome, .validated)
                appliedCount += 1
                applied.fulfill()
            }
            source.axPassReadForTesting = { generation, revision, native in
                XCTAssertFalse(native)
                reads += 1
                let first = reads == 1
                if first {
                    DispatchQueue.main.async {
                        self.type("b", handler: handler)
                        revisionAfterTyping = handler.typingRevision
                    }
                }
                var report = self.proofReport(first ? "o" : "ob", revision: revision!)
                if selected {
                    report = CaretWordReport(word: first ? "o" : "ob", caretAtWordEnd: true,
                        selectionAnchoredAtCaret: false, selectionLength: 3, elementSignature: "field",
                        appBundleId: "app", expectedRevision: revision!)
                    report.proofKind = .selectedSuffixReplacement(selectionLength: 3)
                }
                return (self.snapshot(generation), report)
            }
            source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
            wait(for: [applied], timeout: 5)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(appliedCount, 1, "stale report must never reach the engine")
            XCTAssertEqual(scheduled.count, 2)
            if scheduled.count == 2 {
                XCTAssertGreaterThan(scheduled[1], scheduled[0])
                XCTAssertEqual(scheduled[1], revisionAfterTyping)
            }
            XCTAssertFalse(handler.engine.focusChangedDuringTyping)
            XCTAssertEqual(handler.engine.selectionProofActive, selected)
            source.stopBackspaceProofForTesting()
        }
    }

    func testStaleRetryStopsAfterFourReads() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        defer { source.stopBackspaceProofForTesting() }
        type("o", handler: handler)
        handler.engine.focusChangedDuringTyping = true
        let capped = expectation(description: "retry cap reached")
        var reads = 0
        var scheduled: [UInt64] = []
        source.onRecoveryScheduledForTesting = { scheduled.append($0) }
        handler.onProof = { _, _ in XCTFail("stale report must not be applied") }
        source.onLogEvent = { message in
            if message.hasPrefix("Caret recovery retry skipped: staleRevision cap=") { capped.fulfill() }
        }
        source.axPassReadForTesting = { generation, revision, _ in
            reads += 1
            DispatchQueue.main.async { self.type("b", handler: handler) }
            return (self.snapshot(generation), self.proofReport("o", revision: revision!))
        }
        source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
        wait(for: [capped], timeout: 5)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(scheduled.count, 4, "initial read plus three retries, never a fifth")
        XCTAssertTrue(zip(scheduled, scheduled.dropFirst()).allSatisfy { $0.0 < $0.1 })
        XCTAssertTrue(handler.engine.focusChangedDuringTyping)
    }

    func testHardDesyncAndWordBoundaryStopStaleRetries() {
        for hardDesync in [true, false] {
            let handler = CaretRetryHandler()
            let source = retrySource(handler)
            type("o", handler: handler)
            handler.engine.focusChangedDuringTyping = true
            let rejected = expectation(description: "stale report rejected")
            var scheduled = 0
            source.onRecoveryScheduledForTesting = { _ in scheduled += 1 }
            handler.onProof = { _, _ in XCTFail("stale report must not reach engine") }
            source.onLogEvent = { message in
                if message.hasPrefix("Caret recovery apply rejected: stale/owner") { rejected.fulfill() }
            }
            source.axPassReadForTesting = { generation, revision, _ in
                DispatchQueue.main.async {
                    if hardDesync {
                        self.type("b", handler: handler)
                        handler.engine.bufferDesyncDetected = true
                    } else {
                        _ = handler.engine.processWordBreak(character: " ")
                    }
                }
                return (self.snapshot(generation), self.proofReport("o", revision: revision!))
            }
            source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
            wait(for: [rejected], timeout: 5)
            XCTAssertEqual(scheduled, 1, "guard state must prevent retry")
            if hardDesync {
                XCTAssertTrue(handler.engine.bufferDesyncDetected)
            } else {
                XCTAssertFalse(handler.engine.focusChangedDuringTyping)
                XCTAssertFalse(handler.engine.cursorMovedSinceReset)
            }
            source.stopBackspaceProofForTesting()
        }
    }

    func testChangedOwnerHostStopOrRegistryRejectsStaleReadWithoutRetry() {
        for change in ["pid", "bundle", "host", "stop", "registry"] {
            let handler = CaretRetryHandler()
            var active = true
            var identity: (pid: pid_t?, bundleId: String?) = (42, "app")
            let source = retrySource(handler, active: { active })
            source.recoveryIdentityForTesting = { identity }
            type("o", handler: handler)
            handler.engine.focusChangedDuringTyping = true
            let rejected = expectation(description: "\(change) rejects old report")
            var scheduled = 0
            source.onRecoveryScheduledForTesting = { _ in scheduled += 1 }
            handler.onProof = { _, _ in XCTFail("changed context must not apply old proof") }
            source.onLogEvent = { message in
                if message.hasPrefix("Caret recovery apply rejected:") { rejected.fulfill() }
            }
            source.axPassReadForTesting = { generation, revision, _ in
                DispatchQueue.main.async {
                    self.type("b", handler: handler)
                    switch change {
                    case "pid": identity.pid = 43
                    case "bundle": identity.bundleId = "other"
                    case "host": active = false
                    case "stop": source.stopBackspaceProofForTesting()
                    default: source.handleBrowserRegistryReload()
                    }
                }
                return (self.snapshot(generation), self.proofReport("o", revision: revision!))
            }
            source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
            wait(for: [rejected], timeout: 5)
            XCTAssertEqual(scheduled, 1, "\(change) must not schedule a retry")
            source.stopBackspaceProofForTesting()
        }
    }

    func testStaleNativeBackspaceProofNeverStartsGenericRetry() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        source.backspaceProofIdentityForTesting = { (42, "app") }
        let rejected = expectation(description: "native stale report rejected")
        var genericSchedules = 0
        source.onRecoveryScheduledForTesting = { _ in genericSchedules += 1 }
        source.onLogEvent = { message in
            if message.hasPrefix("Caret recovery apply rejected: stale/owner") { rejected.fulfill() }
        }
        handler.onProof = { _, _ in XCTFail("stale native proof must not reach engine") }
        source.axPassReadForTesting = { generation, revision, native in
            XCTAssertTrue(native)
            DispatchQueue.main.async { self.type("a", handler: handler) }
            return (self.snapshot(generation), self.proofReport("", revision: revision!, atStart: true, empty: true))
        }
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        source.settleBackspaceProofForTesting()
        wait(for: [rejected], timeout: 5)
        XCTAssertEqual(genericSchedules, 0)
        XCTAssertTrue(handler.engine.needsBackspaceContextProof)
    }

    func testPendingNativeBackspaceProofPreemptsStaleGenericRetry() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        source.backspaceProofIdentityForTesting = { (42, "app") }
        source.backspaceProofQueueBusyForTesting = true
        type("o", handler: handler)
        handler.engine.focusChangedDuringTyping = true
        let entered = expectation(description: "generic proof read entered")
        let rejected = expectation(description: "generic stale proof rejected")
        let applied = expectation(description: "settled native proof applied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var genericSchedules = 0
        var nativeSchedules = 0
        source.onRecoveryScheduledForTesting = { _ in genericSchedules += 1 }
        source.onBackspaceProofScheduledForTesting = { _ in nativeSchedules += 1 }
        source.onLogEvent = { message in
            if message.hasPrefix("Caret recovery apply rejected: stale/owner") { rejected.fulfill() }
        }
        handler.onProof = { native, outcome in
            XCTAssertTrue(native, "old generic proof must not apply")
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        source.axPassReadForTesting = { generation, revision, native in
            if native {
                return (self.snapshot(generation),
                        self.proofReport("", revision: revision!, atStart: true, empty: true))
            }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (self.snapshot(generation), self.proofReport("o", revision: revision!))
        }
        source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
        wait(for: [entered], timeout: 5)
        _ = handler.engine.processBackspace()
        handler.onNativeBackspacePassedThrough?()
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)
        release.signal()
        wait(for: [rejected], timeout: 5)
        XCTAssertEqual(genericSchedules, 1, "stale generic proof must not overtake native settlement")
        XCTAssertEqual(nativeSchedules, 0)
        XCTAssertTrue(source.hasPendingBackspaceProofForTesting)

        source.settleBackspaceProofForTesting()
        source.backspaceProofQueueBusyForTesting = false
        source.drainBackspaceProofForTesting()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(nativeSchedules, 1)
        XCTAssertFalse(handler.engine.needsBackspaceContextProof)
    }

}
