import Cocoa

enum CaretRecoveryApplyVerdict: Equatable {
    case applied, missingReport, invalidContext, staleRevision
}

enum PinnedFocusRead<Element> {
    case failed
    case success(Element?)

    func classificationElement(fallback: Element?) -> Element? {
        switch self {
        case .failed: return fallback
        case .success(let element): return element
        }
    }

    var proofElement: Element? {
        if case .success(let element) = self { return element }
        return nil
    }
}

struct FocusRecoveryEpisode {
    private(set) var revision: UInt64?
    private(set) var rearmCount = 0

    mutating func observe(revision: UInt64, guarded: Bool) {
        guard guarded else { reset(); return }
        if self.revision == nil || revision > self.revision! {
            self.revision = revision
            rearmCount = 0
        }
    }

    var canRearm: Bool { rearmCount < 3 }
    mutating func didRearm() { rearmCount += 1 }
    mutating func reset() { revision = nil; rearmCount = 0 }
}

struct CaretRecoveryFreshness: Equatable {
    let revision: UInt64
    let epoch: UInt64
    let generation: UInt64
    let isRunning: Bool
    let isActiveHost: Bool

    static func canTransferRecovery(old: CaretRecoveryFreshness, current: CaretRecoveryFreshness,
                                    pendingEpoch: UInt64, oldPID: pid_t?, pendingPID: pid_t?,
                                    currentPID: pid_t?, oldBundle: String?, pendingBundle: String?,
                                    currentBundle: String?, pendingHasRecovery: Bool, pendingBackspace: Bool,
                                    oldBackspace: Bool, backspacePending: Bool, retryCount: Int,
                                    desynced: Bool, hasSoftGuard: Bool) -> Bool {
        guard let pid = oldPID else { return false }
        return old.isRunning && old.isActiveHost && current.isRunning && current.isActiveHost &&
            old.epoch == current.epoch && pendingEpoch == old.epoch &&
            current.generation != old.generation && current.revision >= old.revision &&
            pid == pendingPID && pid == currentPID && oldBundle == pendingBundle && oldBundle == currentBundle &&
            !pendingHasRecovery && !pendingBackspace && !oldBackspace && !backspacePending &&
            retryCount < 3 && !desynced && hasSoftGuard
    }

    static func acceptFocusNotification(epoch: inout UInt64, isActiveHost: Bool,
                                        elapsed: TimeInterval, throttleInterval: TimeInterval) -> Bool {
        epoch &+= 1
        return isActiveHost && elapsed > throttleInterval
    }

    func matches(_ current: CaretRecoveryFreshness) -> Bool {
        isRunning && isActiveHost && current.isRunning && current.isActiveHost &&
            revision == current.revision && epoch == current.epoch && generation == current.generation
    }

    @discardableResult
    static func applyIfCurrent(report: CaretWordReport?, expected: CaretRecoveryFreshness,
                               current: CaretRecoveryFreshness,
                               expectedPID: pid_t?, currentPID: pid_t?,
                               expectedBundleId: String?, currentBundleId: String?,
                               apply: (CaretWordReport) -> Void) -> CaretRecoveryApplyVerdict {
        guard let report = report else { return .missingReport }
        guard let expectedPID = expectedPID, expected.isRunning, expected.isActiveHost,
              current.isRunning, current.isActiveHost, expected.epoch == current.epoch,
              expected.generation == current.generation, expectedPID == currentPID,
              expectedBundleId == currentBundleId else { return .invalidContext }
        guard current.revision == expected.revision else {
            return current.revision > expected.revision ? .staleRevision : .invalidContext
        }
        apply(report)
        return .applied
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
    struct OmniboxMetadata {
        let role: String?
        let description: String?
        let domClassList: [String]?
        let profile: ResolvedBrowserProfile?

        init(role: String?, description: String?, domClassList: [String]?,
             profile: ResolvedBrowserProfile? = nil) {
            self.role = role
            self.description = description
            self.domClassList = domClassList
            self.profile = profile
        }

        var isNativeOmnibox: Bool {
            guard role == "AXTextField", let profile = profile, profile.kind.supportsSelectedSuffix,
                  let description = description, !description.isEmpty,
                  profile.exactDescriptions.contains(description), let classes = domClassList else { return false }
            return classes.contains { !$0.isEmpty && profile.domClasses.contains($0) }
        }
    }

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
                     revision: UInt64, omniboxMetadata: OmniboxMetadata? = nil,
                     diagnostic: ((String) -> Void)? = nil) -> CaretWordReport? {
        func fail(_ reason: String) -> CaretWordReport? {
            diagnostic?(reason)
            return nil
        }
        let role = provider.role()
        if let reason = eligibilityFailure(provider, role: role) { return fail(reason) }
        let metadata = role == "AXTextField" ? omniboxMetadata : nil
        guard let (selection, length) = initialSelection(provider, omniboxMetadata: metadata,
                                                         diagnostic: diagnostic) else { return nil }

        let leftLength = min(64, selection.location)
        let rightLength = selection.length == 0 ? min(16, length - selection.location) : 0
        let leftRange = CFRange(location: selection.location - leftLength, length: leftLength)
        let rightRange = CFRange(location: selection.location, length: rightLength)
        guard let left = leftLength == 0 ? "" : provider.text(leftRange) else {
            return fail("textUnavailable side=left")
        }
        guard let right = rightLength == 0 ? "" : provider.text(rightRange) else {
            return fail("textUnavailable side=right")
        }
        guard left.utf16.count == leftLength, right.utf16.count == rightLength else {
            return fail("textLengthMismatch")
        }
        guard let parsed = CaretWordParser.parse(leftContext: left, rightContext: right,
                                                  leftContextStartsAtFieldStart: leftRange.location == 0,
                                                  rightContextEndsAtFieldEnd: selection.length > 0 ||
                                                      selection.location + rightLength == length)
        else {
            return fail("parserOrBoundaryFailure")
        }
        guard parsed.caretAtWordEnd else { return fail("caretNotAtWordEnd") }
        guard let finalSelection = provider.selection() else { return fail("finalSelectionUnavailable") }
        guard finalSelection.location == selection.location, finalSelection.length == selection.length else {
            return fail("selectionChanged location=\(finalSelection.location) length=\(finalSelection.length)")
        }
        guard provider.isStillFocused() else { return fail("focusChanged") }
        return CaretWordReport(word: parsed.word, caretAtWordEnd: true,
                               selectionAnchoredAtCaret: selection.length == 0, selectionLength: selection.length,
                               elementSignature: signature, appBundleId: bundleId,
                                expectedRevision: revision, caretAtFieldStart: selection.location == 0,
                                fieldIsEmpty: length == 0,
                                proofKind: selection.length == 0 ? .collapsedCaret :
                                    .selectedSuffixReplacement(selectionLength: selection.length))
    }

    private static func eligibilityFailure(_ provider: Provider, role: String?) -> String? {
        guard let role = role else { return "roleUnavailable" }
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXGroup", "AXWebArea"].contains(role) else {
            return "unsupportedRole role=\(role)"
        }
        guard !role.localizedCaseInsensitiveContains("secure"),
              !(provider.subrole()?.localizedCaseInsensitiveContains("secure") ?? false) else {
            return "secureField"
        }
        guard provider.isEditable() else { return "notEditable" }
        guard provider.isStillFocused() else { return "notFocused" }
        return nil
    }

    private static func initialSelection(_ provider: Provider, omniboxMetadata: OmniboxMetadata?,
                                         diagnostic: ((String) -> Void)?) -> (CFRange, Int)? {
        func fail(_ reason: String) -> (CFRange, Int)? {
            diagnostic?(reason)
            return nil
        }
        guard let selection = provider.selection() else { return fail("selectionUnavailable") }
        guard selection.location >= 0 else {
            return fail("invalidSelection location=\(selection.location) length=\(selection.length)")
        }
        guard selection.length == 0 || (selection.length > 0 && omniboxMetadata?.isNativeOmnibox == true) else {
            return fail("nonCollapsedSelection location=\(selection.location) length=\(selection.length)")
        }
        guard let length = provider.length() else { return fail("lengthUnavailable") }
        guard length >= selection.location else {
            return fail("invalidBounds location=\(selection.location) length=\(length)")
        }
        guard selection.length == 0 || selection.length == length - selection.location else {
            return fail("selectionNotAtFieldEnd location=\(selection.location) length=\(selection.length)")
        }
        return (selection, length)
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
