import Foundation

func runRecoveryRetryScenarios() {
    let expected = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3,
                                          isRunning: true, isActiveHost: true)
    let validReport = CaretWordReport(word: "word", caretAtWordEnd: true, selectionAnchoredAtCaret: true,
                                      selectionLength: 0, elementSignature: "field", appBundleId: "app",
                                      expectedRevision: 7)
    var applications = 0
    func attempt(_ report: CaretWordReport?, _ current: CaretRecoveryFreshness,
                 expectedPID: pid_t? = 42, pid: pid_t? = 42, bundle: String? = "app") -> CaretRecoveryApplyVerdict {
        CaretRecoveryFreshness.applyIfCurrent(report: report, expected: expected, current: current,
            expectedPID: expectedPID, currentPID: pid, expectedBundleId: "app", currentBundleId: bundle) { _ in
                applications += 1
            }
    }
    func state(_ revision: UInt64 = 8, _ epoch: UInt64 = 2, _ generation: UInt64 = 3,
               _ running: Bool = true, _ active: Bool = true) -> CaretRecoveryFreshness {
        CaretRecoveryFreshness(revision: revision, epoch: epoch, generation: generation,
                               isRunning: running, isActiveHost: active)
    }
    check(attempt(validReport, expected) == .applied && applications == 1, "fresh report applies exactly once")
    check(attempt(nil, expected) == .missingReport, "missing report is not retryable")
    check(attempt(nil, state()) == .missingReport, "missing report with newer revision is not retryable")
    check(attempt(validReport, state()) == .staleRevision, "newer revision alone requests fresh proof")
    check(attempt(validReport, state(6)) == .invalidContext, "older revision is not retryable")
    for changed in [state(8, 3), state(8, 2, 4), state(8, 2, 3, false), state(8, 2, 3, true, false)] {
        check(attempt(validReport, changed) == .invalidContext, "revision plus context change is not retryable")
    }
    check(attempt(validReport, state(), pid: 43) == .invalidContext, "revision plus PID change is not retryable")
    check(attempt(validReport, state(), bundle: "other") == .invalidContext,
          "revision plus bundle change is not retryable")
    check(attempt(validReport, state(), expectedPID: nil, pid: nil) == .invalidContext,
          "revision without pinned PID is not retryable")
    check(applications == 1, "no rejected report invokes apply")
    checkFreshProofPreservesRawKeys()
}

private func checkFreshProofPreservesRawKeys() {
    let engine = makeEngine()
    var screen = ""
    press("r", engine: engine, screen: &screen)
    engine.focusChangedDuringTyping = true
    let oldRevision = engine.typingRevision
    let oldReport = report(screen, engine)
    press("e", engine: engine, screen: &screen)
    let raw = engine.buffer.getKeystrokeSequence()
    let oldState = CaretRecoveryFreshness(revision: oldRevision, epoch: 1, generation: 1,
                                           isRunning: true, isActiveHost: true)
    let freshState = CaretRecoveryFreshness(revision: engine.typingRevision, epoch: 1, generation: 1,
                                             isRunning: true, isActiveHost: true)
    let staleVerdict = CaretRecoveryFreshness.applyIfCurrent(report: oldReport, expected: oldState, current: freshState,
        expectedPID: 42, currentPID: 42, expectedBundleId: "app", currentBundleId: "app") { _ in
            check(false, "old proof must not reach engine")
        }
    check(staleVerdict == .staleRevision && engine.focusChangedDuringTyping, "stale proof preserves focus guard")
    var outcome: RecoveryOutcome?
    let freshVerdict = CaretRecoveryFreshness.applyIfCurrent(report: report(screen, engine),
        expected: freshState, current: freshState, expectedPID: 42, currentPID: 42,
        expectedBundleId: "app", currentBundleId: "app") { outcome = engine.recoverCaretWord($0) }
    check(freshVerdict == .applied && outcome == .validated && !engine.focusChangedDuringTyping,
          "fresh owned-word proof clears the guard")
    check(engine.buffer.getKeystrokeSequence() == raw, "fresh proof preserves raw key chronology")
}
