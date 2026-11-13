import XCTest
@testable import XKey

final class CaretRecoveryTransportTests: XCTestCase {
    private func read(_ text: String, selection: CFRange, role: String = "AXTextField",
                      subrole: String? = nil, editable: Bool = true,
                      finalSelection: CFRange? = nil, readable: Bool = true,
                      focused: Bool = true, ranges: ((CFRange) -> Void)? = nil) -> CaretWordReport? {
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

    func testBoundedRangesAndEndOfField() {
        var ranges: [CFRange] = []
        let text = String(repeating: " ", count: 90) + "hello"
        let result = read(text, selection: CFRange(location: 95, length: 0), ranges: { ranges.append($0) })
        XCTAssertEqual(result?.word, "hello")
        XCTAssertEqual(result?.expectedRevision, 7)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.length, 64)
        var rightRanges: [CFRange] = []
        XCTAssertEqual(read("hello " + String(repeating: " ", count: 40),
                            selection: CFRange(location: 5, length: 0),
                            ranges: { rightRanges.append($0) })?.word, "hello")
        XCTAssertEqual(rightRanges.last?.length, 16)
    }

    func testRejectsUnsafeOrUnprovableReads() {
        let caret = CFRange(location: 3, length: 0)
        XCTAssertNil(read("abc", selection: caret, subrole: "AXSecureTextField"))
        XCTAssertNil(read("abc", selection: caret, editable: false))
        XCTAssertNil(read("abc", selection: caret, readable: false))
        XCTAssertNil(read("abc", selection: caret, focused: false))
        XCTAssertNil(read("abc", selection: CFRange(location: 1, length: 1)))
        XCTAssertNil(read("abc", selection: CFRange(location: 1, length: 0)))
        XCTAssertNil(read(String(repeating: "a", count: 65), selection: CFRange(location: 65, length: 0)))
        XCTAssertNil(read("e\u{301}", selection: CFRange(location: 2, length: 0)))
    }

    func testRejectsSelectionLocationOrLengthChange() {
        let caret = CFRange(location: 3, length: 0)
        XCTAssertNil(read("abc", selection: caret, finalSelection: CFRange(location: 2, length: 0)))
        XCTAssertNil(read("abc", selection: caret, finalSelection: CFRange(location: 3, length: 1)))
    }

    func testActualFocusedEditorReportAppliesRegardlessOfObserverSignature() {
        let observerSignature = "AXStaticText:autocomplete"
        let report = read("hello", selection: CFRange(location: 5, length: 0))
        XCTAssertNotNil(report)
        XCTAssertNotEqual(report?.elementSignature, observerSignature)
        let state = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3,
                                           isRunning: true, isActiveHost: true)
        var applied: CaretWordReport?
        CaretRecoveryFreshness.applyIfCurrent(report: report, expected: state, current: state,
                                             expectedPID: 42, currentPID: 42,
                                             expectedBundleId: "app", currentBundleId: "app") {
            applied = $0
        }
        XCTAssertEqual(applied, report)
        let staticText = read("hello", selection: CFRange(location: 5, length: 0), role: "AXStaticText")
        XCTAssertNil(staticText)
        applied = nil
        CaretRecoveryFreshness.applyIfCurrent(report: staticText, expected: state, current: state,
                                             expectedPID: 42, currentPID: 42,
                                             expectedBundleId: "app", currentBundleId: "app") {
            applied = $0
        }
        XCTAssertNil(applied)
    }

    func testEmptyBoundaryReport() {
        let report = read("", selection: CFRange(location: 0, length: 0))
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.word, "")
    }

    func testApplyRejectsFocusAppAndLifecycleChanges() {
        let report = read("hello", selection: CFRange(location: 5, length: 0))
        let state = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3,
                                           isRunning: true, isActiveHost: true)
        let changed = [
            CaretRecoveryFreshness(revision: 8, epoch: 2, generation: 3, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 7, epoch: 3, generation: 3, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 4, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: false, isActiveHost: true),
            CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3, isRunning: true, isActiveHost: false)
        ]
        var applications = 0
        func attempt(_ current: CaretRecoveryFreshness, pid: pid_t = 42, bundle: String = "app") {
            CaretRecoveryFreshness.applyIfCurrent(report: report, expected: state, current: current,
                                                 expectedPID: 42, currentPID: pid,
                                                 expectedBundleId: "app", currentBundleId: bundle) { _ in
                applications += 1
            }
        }
        for current in changed { attempt(current) }
        attempt(state, pid: 43)
        attempt(state, bundle: "other")
        XCTAssertEqual(applications, 0)
        attempt(state)
        XCTAssertEqual(applications, 1)
    }

    func testThrottledFocusNotificationInvalidatesPendingReport() {
        let expected = CaretRecoveryFreshness(revision: 7, epoch: 2, generation: 3,
                                              isRunning: true, isActiveHost: true)
        var epoch = expected.epoch
        XCTAssertFalse(CaretRecoveryFreshness.acceptFocusNotification(epoch: &epoch, isActiveHost: true,
                                                                      elapsed: 0, throttleInterval: 0.1))
        let current = CaretRecoveryFreshness(revision: 7, epoch: epoch, generation: 3,
                                             isRunning: true, isActiveHost: true)
        var applied = false
        CaretRecoveryFreshness.applyIfCurrent(report: read("", selection: CFRange(location: 0, length: 0)),
                                             expected: expected, current: current,
                                             expectedPID: 42, currentPID: 42,
                                             expectedBundleId: "app", currentBundleId: "app") { _ in
            applied = true
        }
        XCTAssertFalse(applied)
    }

    func testFocusBookkeepingCanAdvanceRevisionBeforeReaderIsScheduled() {
        var state = CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3,
                                           isRunning: true, isActiveHost: true)
        let trigger = state
        let result = CaretRecoveryFreshness.afterBookkeeping(expected: trigger, current: { state }) {
            state = CaretRecoveryFreshness(revision: 12, epoch: 2, generation: 3,
                                           isRunning: true, isActiveHost: true)
        }
        XCTAssertEqual(result?.revision, 12)
        XCTAssertTrue(result?.matches(state) == true)
        let afterTyping = CaretRecoveryFreshness(revision: 13, epoch: 2, generation: 3,
                                                isRunning: true, isActiveHost: true)
        XCTAssertFalse(result?.matches(afterTyping) ?? true)
    }

    func testInterveningEventsCancelRecoveryButNotFocusBookkeeping() {
        let expected = CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3,
                                              isRunning: true, isActiveHost: true)
        let staleStates = [
            CaretRecoveryFreshness(revision: 11, epoch: 2, generation: 3, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 10, epoch: 4, generation: 3, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 4, isRunning: true, isActiveHost: true),
            CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3, isRunning: false, isActiveHost: true),
            CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3, isRunning: true, isActiveHost: false)
        ]
        for stale in staleStates {
            var didBookkeeping = false
            XCTAssertNil(CaretRecoveryFreshness.afterBookkeeping(expected: expected, current: { stale }) {
                didBookkeeping = true
            })
            XCTAssertTrue(didBookkeeping)
            XCTAssertFalse(expected.matches(stale))
        }
    }

    func testBookkeepingCannotHideAContextChange() {
        var state = CaretRecoveryFreshness(revision: 10, epoch: 2, generation: 3,
                                           isRunning: true, isActiveHost: true)
        let expected = state
        XCTAssertNil(CaretRecoveryFreshness.afterBookkeeping(expected: expected, current: { state }) {
            state = CaretRecoveryFreshness(revision: 11, epoch: 3, generation: 3,
                                           isRunning: true, isActiveHost: true)
        })
    }
}
