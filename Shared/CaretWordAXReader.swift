import Cocoa

struct CaretRecoveryFreshness: Equatable {
    let revision: UInt64
    let epoch: UInt64
    let generation: UInt64
    let isRunning: Bool
    let isActiveHost: Bool

    static func acceptFocusNotification(epoch: inout UInt64, isActiveHost: Bool,
                                        elapsed: TimeInterval, throttleInterval: TimeInterval) -> Bool {
        epoch &+= 1
        return isActiveHost && elapsed > throttleInterval
    }

    func matches(_ current: CaretRecoveryFreshness) -> Bool {
        isRunning && isActiveHost && current.isRunning && current.isActiveHost &&
            revision == current.revision && epoch == current.epoch && generation == current.generation
    }

    static func applyIfCurrent(report: CaretWordReport?, expected: CaretRecoveryFreshness,
                               current: CaretRecoveryFreshness,
                               expectedPID: pid_t?, currentPID: pid_t?,
                               expectedBundleId: String?, currentBundleId: String?,
                               apply: (CaretWordReport) -> Void) {
        guard let report = report, let expectedPID = expectedPID,
              expected.matches(current), expectedPID == currentPID,
              expectedBundleId == currentBundleId else { return }
        apply(report)
    }

    static func afterBookkeeping(expected: CaretRecoveryFreshness,
                                 current: () -> CaretRecoveryFreshness,
                                 bookkeeping: () -> Void) -> CaretRecoveryFreshness? {
        let wasFresh = expected.matches(current())
        bookkeeping()
        let after = current()
        guard wasFresh, after.isRunning, after.isActiveHost,
              after.epoch == expected.epoch, after.generation == expected.generation else { return nil }
        return after
    }
}

/// The provider is confined to the AX queue; it never reads application state.
struct CaretWordAXReader {
    struct Provider {
        let role: () -> String?
        let subrole: () -> String?
        let isEditable: () -> Bool
        let selection: () -> CFRange?
        let length: () -> Int?
        let text: (CFRange) -> String?
        let isStillFocused: () -> Bool
    }

    static func read(_ provider: Provider, signature: String, bundleId: String?,
                     revision: UInt64) -> CaretWordReport? {
        guard let role = provider.role(),
              ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXGroup", "AXWebArea"].contains(role),
              !role.localizedCaseInsensitiveContains("secure"),
              !(provider.subrole()?.localizedCaseInsensitiveContains("secure") ?? false),
              provider.isEditable(), provider.isStillFocused(),
              let selection = provider.selection(), selection.location >= 0, selection.length == 0,
              let length = provider.length(), length >= selection.location else { return nil }

        let leftLength = min(64, selection.location)
        let rightLength = min(16, length - selection.location)
        let leftRange = CFRange(location: selection.location - leftLength, length: leftLength)
        let rightRange = CFRange(location: selection.location, length: rightLength)
        guard let left = leftLength == 0 ? "" : provider.text(leftRange),
              let right = rightLength == 0 ? "" : provider.text(rightRange),
              left.utf16.count == leftLength, right.utf16.count == rightLength,
              let parsed = CaretWordParser.parse(leftContext: left, rightContext: right,
                                                leftContextStartsAtFieldStart: leftRange.location == 0,
                                                rightContextEndsAtFieldEnd: selection.location + rightLength == length),
              parsed.caretAtWordEnd,
              let finalSelection = provider.selection(),
              finalSelection.location == selection.location, finalSelection.length == selection.length,
              provider.isStillFocused() else { return nil }
        return CaretWordReport(word: parsed.word, caretAtWordEnd: true,
                               selectionAnchoredAtCaret: true, selectionLength: 0,
                               elementSignature: signature, appBundleId: bundleId,
                               expectedRevision: revision)
    }

    static func provider(element: AXUIElement, appElement: AXUIElement) -> Provider {
        Provider(role: { AXHelper.getString(element, attribute: kAXRoleAttribute) },
                 subrole: { AXHelper.getString(element, attribute: kAXSubroleAttribute) },
                 isEditable: {
                     var settable = DarwinBoolean(false)
                     return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
                 },
                 selection: { AXHelper.getRange(element, attribute: kAXSelectedTextRangeAttribute) },
                 length: { AXHelper.getInt(element, attribute: kAXNumberOfCharactersAttribute) },
                 text: { range in
                     var range = range
                     guard let value = AXValueCreate(.cfRange, &range) else { return nil }
                     var result: CFTypeRef?
                     guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success else { return nil }
                     return result as? String
                 },
                 isStillFocused: {
                     var value: CFTypeRef?
                     guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                           let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
                     return CFEqual(element, value)
                 })
    }
}
