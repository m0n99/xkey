import Cocoa

// Boundaries excluded from this CLI: no preferences, dictionaries, macro storage,
// accessibility reads, host behavior detection, or smart-switch persistence.
final class SharedSettings {
    static let shared = SharedSettings()
    var spellCheckEnabled = true
    var restoreIfWrongSpelling = true
    var instantRestoreOnWrongSpelling = true
    var modernStyle = true
    func isWordInUserDictionary(_ word: String) -> Bool { fatalError("Unexpected dictionary access") }
}

final class VNDictionaryManager {
    enum DictionaryStyle { case dauMoi, dauCu }
    static let shared = VNDictionaryManager()
    func isDictionaryLoaded(style: DictionaryStyle = .dauMoi) -> Bool { true }
    func isValidWord(_ word: String, style: DictionaryStyle) -> Bool { fatalError("Unexpected dictionary access") }
}

final class MacroManager {
    static var lookupCount = 0
    func findMacro(key: [UInt32]) -> [UInt32]? {
        Self.lookupCount += 1
        return [0x78]
    }
    func getCharacterCodeForDisplay(_ data: UInt32) -> UInt32 { fatalError("Unexpected macro display") }
}

final class AppBehaviorDetector {
    static let shared = AppBehaviorDetector()
    func isInBrowserAddressBar() -> Bool { fatalError("Unexpected host detection") }
}

enum AXHelper {
    static func getElement(_ element: AXUIElement, attribute: String) -> AXUIElement? { fatalError("Unexpected AX read") }
    static func getString(_ element: AXUIElement, attribute: String) -> String? { fatalError("Unexpected AX read") }
    static func getRange(_ element: AXUIElement, attribute: String) -> CFRange? { fatalError("Unexpected AX read") }
    static func getInt(_ element: AXUIElement, attribute: String) -> Int? { fatalError("Unexpected AX read") }
}
