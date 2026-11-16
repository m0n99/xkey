import XCTest
import ApplicationServices
@testable import XKey

private final class CaretRetryHandler: KeyboardEventHandler {
    var onProof: ((Bool, RecoveryOutcome) -> Void)?
    var forcedOutcome: RecoveryOutcome?
    override var canRecoverCaretWord: Bool { true }

    override func recoverCaretWord(_ report: CaretWordReport,
                                   nativeBackspaceProof: Bool = false) -> RecoveryOutcome {
        let outcome = forcedOutcome ?? engine.recoverCaretWord(report, nativeBackspaceProof: nativeBackspaceProof)
        onProof?(nativeBackspaceProof, outcome)
        return outcome
    }
}

private final class CaretChromeDetector: AppBehaviorDetector {
    override func getCurrentBundleId() -> String? { "com.google.Chrome" }
}

final class CaretRecoveryRetryTests: XCTestCase {
    func testOwnedWordStartQueuesFreshGenericProof() {
        for nativeHistory in [false, true] {
            let handler = CaretRetryHandler()
            let source = retrySource(handler)
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            defer { source.stopBackspaceProofForTesting() }
            if nativeHistory { _ = handler.engine.processBackspace() }
            else { handler.engine.cursorMovedSinceReset = true }
            type("c", handler: handler)
            let applied = expectation(description: "owned word validated")
            let started = DispatchTime.now().uptimeNanoseconds
            var reads = 0
            source.axPassReadForTesting = { generation, revision, native in
                reads += 1
                XCTAssertFalse(native)
                XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - started, 50_000_000,
                                            "the target must get the native-edit settle window before AX is read")
                return (self.snapshot(generation), self.proofReport("c", revision: revision!))
            }
            handler.onProof = { native, outcome in
                XCTAssertFalse(native)
                XCTAssertEqual(outcome, .validated)
                applied.fulfill()
            }
            handler.onGuardedOwnedWordStart?()
            wait(for: [applied], timeout: 5)
            XCTAssertEqual(reads, 1)
            XCTAssertFalse(handler.engine.cursorMovedSinceReset)
        }
    }

    func testQueuedOwnedWordDemandWaitsForNativeProofOrStaleRead() {
        for nativeSucceeds in [true, false] {
            let handler = CaretRetryHandler()
            let source = retrySource(handler)
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            source.backspaceProofIdentityForTesting = { (42, "app") }
            defer { source.stopBackspaceProofForTesting() }
            _ = handler.engine.processBackspace()
            handler.onNativeBackspacePassedThrough?()
            let applied = expectation(description: "native priority or generic fallback")
            let entered = nativeSucceeds ? nil : expectation(description: "native read entered")
            let callbackQueued = expectation(description: "demand observed")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var nativeReads = 0
            var genericReads = 0
            source.axPassReadForTesting = { generation, revision, native in
                if native {
                    nativeReads += 1
                    if !nativeSucceeds {
                        entered?.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                        return (self.snapshot(generation), nil)
                    }
                } else { genericReads += 1 }
                return (self.snapshot(generation), self.proofReport("c", revision: revision!))
            }
            handler.onProof = { native, outcome in
                XCTAssertEqual(native, nativeSucceeds)
                XCTAssertEqual(outcome, .validated)
                applied.fulfill()
            }
            if !nativeSucceeds {
                source.settleBackspaceProofForTesting()
                wait(for: [entered!], timeout: 5)
            }
            type("c", handler: handler)
            handler.onGuardedOwnedWordStart?()
            DispatchQueue.main.async { callbackQueued.fulfill() }
            wait(for: [callbackQueued], timeout: 5)
            if nativeSucceeds { source.settleBackspaceProofForTesting() }
            else { release.signal() }
            wait(for: [applied], timeout: 5)
            XCTAssertEqual(nativeReads, 1)
            XCTAssertEqual(genericReads, nativeSucceeds ? 0 : 1)
        }
    }

    func testStoppedSourceDiscardsQueuedOwnedWordDemand() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        handler.engine.cursorMovedSinceReset = true
        type("c", handler: handler)
        var schedules = 0
        source.onRecoveryScheduledForTesting = { _ in schedules += 1 }
        handler.onGuardedOwnedWordStart?()
        source.stopBackspaceProofForTesting()
        let drained = expectation(description: "queued callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(schedules, 0)
    }

    func testObserverResolvesPinnedEditorAndPreservesTransportProfile() throws {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        let notification = AXUIElementCreateApplication(41)
        let editor = AXUIElementCreateApplication(42)
        let resolved = expectation(description: "resolved editor snapshot")
        var reads = 0
        source.pinnedFocusReadForTesting = { _ in reads += 1; return .success(editor) }
        source.focusedInfoForTesting = { element in
            let isEditor = CFEqual(element, editor)
            return AppBehaviorDetector.FocusedElementInfo(element: element,
                role: isEditor ? "AXTextField" : "AXStaticText", subrole: nil,
                description: isEditor ? "Address and search bar" : nil,
                identifier: nil, domClasses: isEditor ? ["OmniboxViewViews"] : nil,
                roleDescription: nil)
        }
        var captured: TapEventSource.AXSnapshot?
        source.onAXSnapshotForTesting = { snapshot in captured = snapshot; resolved.fulfill() }
        source.handleAXFocusChanged(notification)
        wait(for: [resolved], timeout: 5)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(snapshot.resolvedElement), editor))
        XCTAssertEqual(snapshot.focusedInfo.role, "AXTextField")
        let detector = CaretChromeDetector()
        let method = detector.detectInjectionMethod(focusedInfo: snapshot.focusedInfo, resolvedOverlayName: .some(nil))
        XCTAssertEqual(method.description, "Chromium Address Bar")
        XCTAssertTrue(method.needsEmptyCharPrefix)
        XCTAssertNotNil(SelectedSuffixInjectionProfile(methodInfo: method))
    }

    func testPinnedReadFailureFallsBackButSuccessfulNilDoesNot() {
        for failure in [true, false] {
            let source = retrySource(CaretRetryHandler())
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            defer { source.stopBackspaceProofForTesting() }
            let notification = AXUIElementCreateApplication(41)
            let received = expectation(description: "focus resolution completed")
            var reads = 0
            source.pinnedFocusReadForTesting = { _ in
                reads += 1
                return failure ? .failed : .success(nil)
            }
            source.focusedInfoForTesting = { element in
                AppBehaviorDetector.FocusedElementInfo(element: element, role: "AXStaticText", subrole: nil,
                    description: nil, identifier: nil, roleDescription: nil)
            }
            source.onAXSnapshotForTesting = { snapshot in
                XCTAssertEqual(snapshot.hasFocusedElement, failure)
                if failure {
                    XCTAssertTrue(snapshot.resolvedElement.map { CFEqual($0, notification) } ?? false)
                    XCTAssertEqual(snapshot.focusedInfo.role, "AXStaticText")
                } else {
                    XCTAssertNil(snapshot.resolvedElement)
                }
                received.fulfill()
            }
            source.handleAXFocusChanged(notification)
            wait(for: [received], timeout: 5)
            XCTAssertEqual(reads, 1)
        }
    }

    func testFocusEpochRearmsAfterAcceptedAndThrottledBusyPasses() {
        for accepted in [true, false] {
            let handler = CaretRetryHandler()
            let source = retrySource(handler)
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            defer { source.stopBackspaceProofForTesting() }
            type("o", handler: handler)
            handler.engine.focusChangedDuringTyping = true
            let entered = expectation(description: "old recovery entered")
            let rearmed = expectation(description: "new epoch recovery scheduled")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var reads = 0
            var schedules = 0
            source.focusElapsedForTesting = { accepted ? 1 : 0 }
            source.onRecoveryScheduledForTesting = { _ in
                schedules += 1
                if schedules == 2 { rearmed.fulfill() }
            }
            source.axPassReadForTesting = { generation, revision, _ in
                reads += 1
                if reads == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
                return (self.snapshot(generation), nil)
            }
            source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
            wait(for: [entered], timeout: 5)
            source.handleAXFocusChanged(AXUIElementCreateApplication(42))
            XCTAssertEqual(schedules, 1)
            release.signal()
            wait(for: [rearmed], timeout: 5)
            XCTAssertEqual(schedules, 2)
            XCTAssertGreaterThanOrEqual(reads, accepted ? 2 : 1)
        }
    }

    func testThrottledRearmCapRejectsNonApplicableAndResetsOnProgress() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        defer { source.stopBackspaceProofForTesting() }
        type("o", handler: handler)
        handler.engine.focusChangedDuringTyping = true
        handler.forcedOutcome = .notApplicable
        source.focusElapsedForTesting = { 0 }
        var count = 0
        var reportWord = "o"
        var proof: XCTestExpectation?
        source.onRecoveryScheduledForTesting = { _ in count += 1 }
        handler.onProof = { _, _ in proof?.fulfill() }
        source.axPassReadForTesting = { generation, revision, _ in
            (self.snapshot(generation), self.proofReport(reportWord, revision: revision!))
        }
        for _ in 0..<3 {
            proof = expectation(description: "non-applicable proof")
            source.handleAXFocusChanged(AXUIElementCreateApplication(42))
            wait(for: [proof!], timeout: 5)
        }
        source.handleAXFocusChanged(AXUIElementCreateApplication(42))
        XCTAssertEqual(count, 3, "non-applicable proof must not reset the episode cap")
        type("b", handler: handler)
        proof = expectation(description: "revision progress permits another proof")
        source.handleAXFocusChanged(AXUIElementCreateApplication(42))
        wait(for: [proof!], timeout: 5)
        XCTAssertEqual(count, 4)
        handler.forcedOutcome = nil
        reportWord = "ob"
        proof = expectation(description: "actual validated proof")
        source.handleAXFocusChanged(AXUIElementCreateApplication(42))
        wait(for: [proof!], timeout: 5)
        XCTAssertFalse(handler.engine.focusChangedDuringTyping)
        handler.engine.focusChangedDuringTyping = true
        proof = expectation(description: "validated episode permits new rearm")
        source.handleAXFocusChanged(AXUIElementCreateApplication(42))
        wait(for: [proof!], timeout: 5)
        XCTAssertEqual(count, 6)
    }

    func testThrottledRearmRequiresGuardsAndActiveRunningHost() {
        let handler = CaretRetryHandler()
        var active = true
        let source = retrySource(handler, active: { active })
        source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
        source.focusElapsedForTesting = { 0 }
        var count = 0
        source.onRecoveryScheduledForTesting = { _ in count += 1 }
        let notification = AXUIElementCreateApplication(42)
        source.handleAXFocusChanged(notification)
        handler.engine.focusChangedDuringTyping = true
        handler.engine.bufferDesyncDetected = true
        source.handleAXFocusChanged(notification)
        handler.engine.bufferDesyncDetected = false
        active = false
        source.handleAXFocusChanged(notification)
        active = true
        source.stopBackspaceProofForTesting()
        source.handleAXFocusChanged(notification)
        XCTAssertEqual(count, 0)
    }

    func testBusyFocusDemandIsDiscardedAfterContextChanges() {
        for change in ["guards", "desync", "host", "stop", "identity"] {
            let handler = CaretRetryHandler()
            var active = true
            var identity: (pid: pid_t?, bundleId: String?) = (42, "app")
            let source = retrySource(handler, active: { active })
            source.recoveryIdentityForTesting = { identity }
            source.startBackspaceProofForTesting(pid: 42, bundleId: "app")
            defer { source.stopBackspaceProofForTesting() }
            type("o", handler: handler)
            handler.engine.focusChangedDuringTyping = true
            source.focusElapsedForTesting = { 0 }
            let entered = expectation(description: "old read entered: \(change)")
            let settled = expectation(description: "old read finished: \(change)")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var count = 0
            source.onRecoveryScheduledForTesting = { _ in count += 1 }
            source.onLogEvent = { message in
                if message.hasPrefix("Caret recovery read:") {
                    DispatchQueue.main.async { settled.fulfill() }
                }
            }
            source.axPassReadForTesting = { generation, _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (self.snapshot(generation), nil)
            }
            source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
            wait(for: [entered], timeout: 5)
            source.handleAXFocusChanged(AXUIElementCreateApplication(42))
            switch change {
            case "guards": handler.engine.focusChangedDuringTyping = false
            case "desync": handler.engine.bufferDesyncDetected = true
            case "host": active = false
            case "stop": source.stopBackspaceProofForTesting()
            default: identity.pid = 43
            }
            release.signal()
            wait(for: [settled], timeout: 5)
            XCTAssertEqual(count, 1, "\(change) must discard pending demand")
        }
    }

    func testSupersededProofTransfersToPendingPassWithFreshRead() {
        let handler = CaretRetryHandler()
        let source = retrySource(handler)
        defer { source.stopBackspaceProofForTesting() }
        type("o", handler: handler)
        handler.engine.focusChangedDuringTyping = true
        let entered = expectation(description: "old read entered")
        let applied = expectation(description: "fresh proof applied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var reads = 0
        var bookkeeping = 0
        source.axPassReadForTesting = { generation, revision, _ in
            reads += 1
            if reads == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return (self.snapshot(generation), self.proofReport(reads == 1 ? "o" : "ob", revision: revision!))
        }
        handler.onProof = { _, outcome in
            XCTAssertEqual(outcome, .validated)
            applied.fulfill()
        }
        source.scheduleCaretRecoveryForTesting(pid: 42, bundleId: "app")
        wait(for: [entered], timeout: 5)
        type("b", handler: handler)
        source.scheduleReplacementForTesting(pid: 42, bundleId: "app") { bookkeeping += 1 }
        release.signal()
        wait(for: [applied], timeout: 5)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(bookkeeping, 1)
        XCTAssertFalse(handler.engine.focusChangedDuringTyping)
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
