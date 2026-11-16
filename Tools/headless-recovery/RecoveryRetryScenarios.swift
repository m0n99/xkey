import Foundation

func runRecoveryRetryScenarios() {
    guardedOwnedWordStartScenarios()
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
    checkFocusResolutionAndTransfer()
    checkFocusRecoveryEpisode()
}

func guardedOwnedWordStartScenarios() {
    let data = VietnameseData()
    func request(guarded: Bool = true, wasEmpty: Bool = true, isEmpty: Bool = false,
                 key: UInt16 = VietnameseData.KEY_C, shortcut: Bool = false,
                 selected: Bool = false, desynced: Bool = false, overflow: Bool = false) -> Bool {
        CaretRecoveryFreshness.shouldRequestOwnedWordStart(
            guardedBefore: guarded, wasEmpty: wasEmpty, isEmpty: isEmpty,
            ordinaryLetter: !shortcut && data.isLetter(key), selectionProof: selected,
            desynced: desynced, overflow: overflow)
    }
    check(request(), "guarded empty-to-owned letter requests proof")
    check(!request(guarded: false) && !request(wasEmpty: false) && !request(isEmpty: true),
          "unguarded, continuation and empty results do not request proof")
    check(!request(shortcut: true) && !request(key: VietnameseData.KEY_DELETE) &&
          !request(key: VietnameseData.keyCode(for: " ") ?? 49) &&
          !request(key: VietnameseData.KEY_COMMA), "shortcut, delete, space and punctuation do not request proof")
    check(!request(selected: true) && !request(desynced: true) && !request(overflow: true),
          "suffix proof, desync and overflow do not request proof")

    for fromBackspace in [false, true] {
        let engine = makeEngine()
        if fromBackspace { exhaustEmptyHistory(engine) } else { engine.cursorMovedSinceReset = true }
        engine.vCheckSpelling = 1
        engine.vRestoreIfWrongSpelling = 1
        var screen = ""
        press("c", engine: engine, screen: &screen)
        let raw = engine.buffer.getKeystrokeSequence()
        check(engine.recoverCaretWord(report("oldc", engine)) != .validated,
              "generic proof rejects unowned prefix")
        check(engine.recoverCaretWord(report(screen, engine)) == .validated &&
              engine.buffer.getKeystrokeSequence() == raw, "generic exact owned word validates without changing raw keys")
        for key in "ase" { press(key, engine: engine, screen: &screen) }
        let result = engine.processWordBreak(character: " ")
        check(result.shouldConsume && result.newCharacters.map { $0.unicode(codeTable: .unicode) }.joined() == "case ",
              "owned word proof permits case restoration at boundary")
    }
    check(readContext("old", selection: CFRange(location: 1, length: 0)) == nil,
          "reader rejects existing word suffix")
    check(readContext("old", selection: CFRange(location: 1, length: 1)) == nil,
          "reader rejects ordinary noncollapsed selection")
}

private func checkFocusRecoveryEpisode() {
    var episode = FocusRecoveryEpisode()
    episode.observe(revision: 7, guarded: true)
    for _ in 0..<3 {
        check(episode.canRearm, "guarded episode permits bounded rearm")
        episode.didRearm()
    }
    check(!episode.canRearm, "fourth rearm is capped")
    episode.observe(revision: 7, guarded: true)
    check(!episode.canRearm, "unchanged revision cannot reset cap")
    episode.observe(revision: 6, guarded: true)
    check(!episode.canRearm, "older revision cannot reset cap")
    episode.observe(revision: 8, guarded: true)
    check(episode.canRearm && episode.rearmCount == 0, "revision progress resets cap")
    episode.didRearm()
    episode.observe(revision: 8, guarded: false)
    check(episode.revision == nil && episode.rearmCount == 0, "cleared guards reset episode")
    episode.observe(revision: 8, guarded: true)
    episode.didRearm()
    episode.reset()
    check(episode.rearmCount == 0 && episode.revision == nil, "validated proof resets episode")
}

private func checkFocusResolutionAndTransfer() {
    let failed = PinnedFocusRead<String>.failed
    let none = PinnedFocusRead<String>.success(nil)
    let editor = PinnedFocusRead<String>.success("editor")
    check(failed.classificationElement(fallback: "notification") == "notification" && failed.proofElement == nil,
          "failed pinned read uses notification for classification only")
    check(none.classificationElement(fallback: "notification") == nil && none.proofElement == nil,
          "successful nil pinned read does not use notification")
    check(editor.classificationElement(fallback: "notification") == "editor" && editor.proofElement == "editor",
          "pinned editor replaces autocomplete notification")

    let old = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)
    func eligible(current: CaretRecoveryFreshness? = nil, epoch: UInt64 = 2, oldPID: pid_t? = 42,
                  pendingPID: pid_t? = 42, pid: pid_t? = 42, bundle: String? = "app",
                  pendingBundle: String? = "app", pendingRecovery: Bool = false, pendingBackspace: Bool = false,
                  oldBackspace: Bool = false, backspacePending: Bool = false, count: Int = 0,
                  desynced: Bool = false, guardActive: Bool = true) -> Bool {
        CaretRecoveryFreshness.canTransferRecovery(old: old,
            current: current ?? .init(revision: 8, epoch: 2, generation: 4, isRunning: true, isActiveHost: true),
            pendingEpoch: epoch, oldPID: oldPID, pendingPID: pendingPID, currentPID: pid,
            oldBundle: "app", pendingBundle: pendingBundle, currentBundle: bundle,
            pendingHasRecovery: pendingRecovery, pendingBackspace: pendingBackspace, oldBackspace: oldBackspace,
            backspacePending: backspacePending, retryCount: count, desynced: desynced, hasSoftGuard: guardActive)
    }
    check(eligible() && eligible(count: 2), "compatible pending pass accepts bounded fresh transfer")
    let invalid = [eligible(epoch: 3), eligible(oldPID: nil), eligible(pendingPID: 43), eligible(pid: 43),
                   eligible(bundle: "other"), eligible(pendingBundle: "other"), eligible(pendingRecovery: true),
                   eligible(pendingBackspace: true), eligible(oldBackspace: true), eligible(backspacePending: true),
                   eligible(count: 3), eligible(desynced: true), eligible(guardActive: false),
                   eligible(current: .init(revision: 6, epoch: 2, generation: 4, isRunning: true, isActiveHost: true)),
                   eligible(current: .init(revision: 8, epoch: 3, generation: 4, isRunning: true, isActiveHost: true)),
                   eligible(current: .init(revision: 8, epoch: 2, generation: 3, isRunning: true, isActiveHost: true)),
                   eligible(current: .init(revision: 8, epoch: 2, generation: 4, isRunning: false, isActiveHost: true)),
                   eligible(current: .init(revision: 8, epoch: 2, generation: 4, isRunning: true, isActiveHost: false))]
    check(invalid.allSatisfy { !$0 }, "transfer rejects identity, freshness, proof, guard and budget changes")
    let start = CFAbsoluteTimeGetCurrent()
    var accepted = 0
    for _ in 0..<100_000 { if eligible() { accepted += 1 } }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    check(accepted == 100_000, "transfer decision remains deterministic")
    print("transfer decisions: 100000 in \(elapsed) seconds")
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
