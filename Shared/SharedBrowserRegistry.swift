import Foundation

enum BrowserProfileKind: String, Codable, CaseIterable, Identifiable {
    case chromium, firefox, firefoxAx, safari, commandBar, commandBarAx, opera

    var id: String { rawValue }
    var supportsSelectedSuffix: Bool { self == .chromium }
}

struct BrowserSignatureOverrides: Codable, Equatable {
    var exactDescriptions: [String]?
    var domClasses: [String]?
    var identifier: String?

    init(exactDescriptions: [String]? = nil, domClasses: [String]? = nil, identifier: String? = nil) {
        self.exactDescriptions = exactDescriptions
        self.domClasses = domClasses
        self.identifier = identifier
    }
}

struct BrowserProfileEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bundleIdentifier: String
    var profile: BrowserProfileKind
    var enabled: Bool
    var signature: BrowserSignatureOverrides?

    init(id: UUID = UUID(), name: String, bundleIdentifier: String, profile: BrowserProfileKind = .chromium,
         enabled: Bool = true, signature: BrowserSignatureOverrides? = nil) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.profile = profile
        self.enabled = enabled
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, profile, enabled, signature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        profile = try container.decode(BrowserProfileKind.self, forKey: .profile)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        signature = try container.decodeIfPresent(BrowserSignatureOverrides.self, forKey: .signature)
    }
}

struct ResolvedBrowserProfile: Equatable {
    let kind: BrowserProfileKind
    let exactDescriptions: [String]
    let domClasses: [String]
    let identifier: String?
    let firefoxDescriptionPattern: String?
}

enum BrowserProfilePresets {
    static let chromiumDescriptions = ["Address and search bar", "Address field"]
    static let chromiumDOMClasses = ["OmniboxViewViews", "BraveOmniboxViewViews", "AddressTextfieldView"]
    static let firefoxDescriptionPattern = "^Search with .+ or enter address$"

    static func resolve(_ kind: BrowserProfileKind,
                        signature: BrowserSignatureOverrides? = nil) -> ResolvedBrowserProfile {
        let descriptions: [String] = kind == .chromium || kind == .opera ? chromiumDescriptions : []
        let classes: [String] = kind == .chromium || kind == .opera ? chromiumDOMClasses : []
        let identifier: String?
        switch kind {
        case .firefox, .firefoxAx: identifier = "urlbar-input"
        case .safari: identifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
        case .commandBar, .commandBarAx: identifier = "commandBarTextField"
        case .chromium, .opera: identifier = nil
        }
        return ResolvedBrowserProfile(
            kind: kind,
            exactDescriptions: signature?.exactDescriptions ?? descriptions,
            domClasses: signature?.domClasses ?? classes,
            identifier: signature?.identifier ?? identifier,
            firefoxDescriptionPattern: kind == .firefox || kind == .firefoxAx ? firefoxDescriptionPattern : nil
        )
    }

    static let seed: [String: BrowserProfileKind] = {
        let groups: [(BrowserProfileKind, [String])] = [
            (.chromium, [
                "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "org.chromium.Chromium",
                "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
                "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                "com.microsoft.edgemac.Canary", "com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi.snapshot",
                "ru.yandex.desktop.yandex-browser", "com.kagi.kagimacOS", "com.sigmaos.sigmaos.macos",
                "com.pushplaylabs.sidekick", "com.firstversionist.polypane", "ai.perplexity.comet",
                "com.duckduckgo.macos.browser", "com.openai.atlas", "net.imput.helium"
            ]),
            (.opera, ["com.opera.Opera", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
                      "com.operasoftware.OperaAir", "com.opera.OperaNext"]),
            (.safari, ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
            (.commandBar, ["company.thebrowser.Browser", "company.thebrowser.Arc"]),
            (.commandBarAx, ["company.thebrowser.dia"]),
            (.firefox, ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
                        "org.waterfoxproject.waterfox", "io.gitlab.librewolf-community.librewolf", "one.ablaze.floorp",
                        "org.torproject.torbrowser", "net.mullvad.mullvadbrowser"]),
            (.firefoxAx, ["app.zen-browser.zen"])
        ]
        var result: [String: BrowserProfileKind] = [:]
        for (kind, identifiers) in groups {
            for identifier in identifiers { result[identifier] = kind }
        }
        return result
    }()
}

enum BrowserRegistryError: LocalizedError {
    case invalidBundleIdentifier(String)
    case invalidName
    case duplicateBundleIdentifier(String)
    case duplicateID(UUID)
    case entryNotFound(UUID)
    case invalidStoredData(String)
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let value): return "Invalid browser bundle identifier: \(value)"
        case .invalidName: return "Browser name must not be empty."
        case .duplicateBundleIdentifier(let value): return "Duplicate browser bundle identifier: \(value)"
        case .duplicateID(let id): return "Duplicate browser entry ID: \(id)"
        case .entryNotFound(let id): return "Browser entry not found: \(id)"
        case .invalidStoredData(let reason): return "Invalid stored browser profiles: \(reason)"
        case .saveFailed: return "Could not save browser profiles."
        }
    }
}

final class SharedBrowserRegistry {
    static let shared = SharedBrowserRegistry()
    static let didReloadNotification = Notification.Name("SharedBrowserRegistry.didReload")

    private struct Snapshot: Equatable {
        let entries: [BrowserProfileEntry]
        let profiles: [String: ResolvedBrowserProfile]
    }

    private let lock = NSLock()
    private let reloadLock = NSLock()
    private let readData: () -> Data?
    private let writeData: (Data) throws -> Void
    private var snapshot: Snapshot

    init(readData: @escaping () -> Data? = { SharedSettings.shared.getBrowserProfilesData() },
         writeData: @escaping (Data) throws -> Void = { data in
             guard SharedSettings.shared.setBrowserProfilesData(data) else { throw BrowserRegistryError.saveFailed }
         }) {
        self.readData = readData
        self.writeData = writeData
        snapshot = Self.compile([])
    }

    var customEntries: [BrowserProfileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.entries
    }

    func profile(for bundleIdentifier: String) -> ResolvedBrowserProfile? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.profiles[bundleIdentifier] ?? snapshot.profiles[bundleIdentifier.lowercased()]
    }

    @discardableResult
    func reload() -> Bool {
        reloadLock.lock()
        let entries: [BrowserProfileEntry]
        do {
            entries = try loadEntries()
        } catch {
            reloadLock.unlock()
            NSLog("Browser registry reload failed: %@", error.localizedDescription)
            return false
        }
        let next = Self.compile(entries)
        lock.lock()
        let changed = snapshot != next
        if changed { snapshot = next }
        lock.unlock()
        reloadLock.unlock()
        if changed { NotificationCenter.default.post(name: Self.didReloadNotification, object: self) }
        return changed
    }

    func add(_ entry: BrowserProfileEntry) throws {
        precondition(Thread.isMainThread, "Browser registry mutations must run on the main thread")
        var entries = try loadEntries()
        entries.append(entry)
        try save(entries)
    }

    func update(_ entry: BrowserProfileEntry) throws {
        precondition(Thread.isMainThread, "Browser registry mutations must run on the main thread")
        var entries = try loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw BrowserRegistryError.entryNotFound(entry.id)
        }
        entries[index] = entry
        try save(entries)
    }

    func remove(id: UUID) throws {
        precondition(Thread.isMainThread, "Browser registry mutations must run on the main thread")
        var entries = try loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw BrowserRegistryError.entryNotFound(id)
        }
        entries.remove(at: index)
        try save(entries)
    }

    private func loadEntries() throws -> [BrowserProfileEntry] {
        guard let data = readData() else { return [] }
        do {
            let entries = try JSONDecoder().decode([BrowserProfileEntry].self, from: data)
            try Self.validate(entries)
            return entries
        } catch {
            throw BrowserRegistryError.invalidStoredData(error.localizedDescription)
        }
    }

    private func save(_ entries: [BrowserProfileEntry]) throws {
        try Self.validate(entries)
        let data = try JSONEncoder().encode(entries)
        try writeData(data)
        reload()
    }

    private static func validate(_ entries: [BrowserProfileEntry]) throws {
        var identifiers = Set<String>()
        var ids = Set<UUID>()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for entry in entries {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserRegistryError.invalidName
            }
            let parts = entry.bundleIdentifier.components(separatedBy: ".")
            guard parts.count >= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
                throw BrowserRegistryError.invalidBundleIdentifier(entry.bundleIdentifier)
            }
            guard identifiers.insert(entry.bundleIdentifier.lowercased()).inserted else {
                throw BrowserRegistryError.duplicateBundleIdentifier(entry.bundleIdentifier)
            }
            guard ids.insert(entry.id).inserted else { throw BrowserRegistryError.duplicateID(entry.id) }
        }
    }

    private static func compile(_ entries: [BrowserProfileEntry]) -> Snapshot {
        var profiles: [String: ResolvedBrowserProfile] = [:]
        for (identifier, kind) in BrowserProfilePresets.seed {
            profiles[identifier.lowercased()] = BrowserProfilePresets.resolve(kind)
        }
        for entry in entries {
            let key = entry.bundleIdentifier.lowercased()
            if entry.enabled {
                profiles[key] = BrowserProfilePresets.resolve(entry.profile, signature: entry.signature)
            } else {
                profiles.removeValue(forKey: key)
            }
        }
        for identifier in BrowserProfilePresets.seed.keys {
            if let profile = profiles[identifier.lowercased()] { profiles[identifier] = profile }
        }
        for entry in entries where entry.enabled {
            profiles[entry.bundleIdentifier] = profiles[entry.bundleIdentifier.lowercased()]
        }
        return Snapshot(entries: entries, profiles: profiles)
    }
}
