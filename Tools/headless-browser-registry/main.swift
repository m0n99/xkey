import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let defaults = SharedBrowserRegistry()
private let expected: [BrowserProfileKind: [String]] = [
    .chromium: [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "org.chromium.Chromium",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi.snapshot",
        "ru.yandex.desktop.yandex-browser", "com.kagi.kagimacOS", "com.sigmaos.sigmaos.macos",
        "com.pushplaylabs.sidekick", "com.firstversionist.polypane", "ai.perplexity.comet",
        "com.duckduckgo.macos.browser", "com.openai.atlas", "net.imput.helium"
    ],
    .opera: ["com.opera.Opera", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
             "com.operasoftware.OperaAir", "com.opera.OperaNext"],
    .safari: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"],
    .commandBar: ["company.thebrowser.Browser", "company.thebrowser.Arc"],
    .commandBarAx: ["company.thebrowser.dia"],
    .firefox: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
               "org.waterfoxproject.waterfox", "io.gitlab.librewolf-community.librewolf", "one.ablaze.floorp",
               "org.torproject.torbrowser", "net.mullvad.mullvadbrowser"],
    .firefoxAx: ["app.zen-browser.zen"]
]

for (kind, identifiers) in expected {
    for identifier in identifiers {
        check(defaults.profile(for: identifier)?.kind == kind, "HEAD seed \(identifier) maps to \(kind)")
        check(defaults.profile(for: identifier.uppercased())?.kind == kind, "case-insensitive seed \(identifier)")
    }
}
let seedIDs = Set(BrowserProfilePresets.seed.keys.map { $0.lowercased() })
let expectedIDs = Set(expected.values.flatMap { $0 }.map { $0.lowercased() })
check(seedIDs == expectedIDs, "built-in IDs exactly match HEAD")
check(defaults.profile(for: "org.HongKongZiXun.MoreLogin") == nil, "MoreLogin is not a built-in")
check(defaults.profile(for: "com.opera.unregistered") == nil, "unknown Opera ID is not implicitly trusted")
check(defaults.profile(for: "unknown.example") == nil, "unknown ID is not a browser")
check(BrowserProfileKind.allCases.count == 7, "exactly seven profile kinds")
for kind in BrowserProfileKind.allCases {
    check(kind.id == kind.rawValue && kind.supportsSelectedSuffix == (kind == .chromium),
          "profile identity and selected-suffix capability for \(kind)")
}
let chrome = defaults.profile(for: "com.google.Chrome")!
check(chrome.exactDescriptions == ["Address and search bar", "Address field"], "Chromium descriptions")
check(chrome.domClasses == ["OmniboxViewViews", "BraveOmniboxViewViews", "AddressTextfieldView"], "Chromium classes")
check(defaults.profile(for: "com.apple.Safari")?.identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
      "Safari identifier")
check(defaults.profile(for: "company.thebrowser.Arc")?.identifier == "commandBarTextField", "command bar identifier")
check(defaults.profile(for: "company.thebrowser.dia")?.identifier == "commandBarTextField", "Dia identifier")
check(defaults.profile(for: "org.mozilla.firefox")?.identifier == "urlbar-input", "Firefox identifier")
check(defaults.profile(for: "app.zen-browser.zen")?.firefoxDescriptionPattern == "^Search with .+ or enter address$",
      "Zen description pattern")

var stored: Data?
var reads = 0
var writes = 0
let registry = SharedBrowserRegistry(readData: { reads += 1; return stored }, writeData: { stored = $0; writes += 1 })
check(reads == 0, "initialization does not read preferences")
check(!registry.reload(), "missing data leaves defaults unchanged")
let readCount = reads
for _ in 0..<1000 { _ = registry.profile(for: "com.google.Chrome") }
check(reads == readCount, "lookup never reads or decodes stored data")

var notifications = 0
let observer = NotificationCenter.default.addObserver(forName: SharedBrowserRegistry.didReloadNotification,
                                                       object: nil, queue: nil) { notification in
    if notification.object as AnyObject? === registry { notifications += 1 }
}
defer { NotificationCenter.default.removeObserver(observer) }

func expectError(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, label) } catch { check(!error.localizedDescription.isEmpty, label) }
}

do {
    var entry = BrowserProfileEntry(name: "MoreLogin", bundleIdentifier: "org.HongKongZiXun.MoreLogin")
    try registry.add(entry)
    check(registry.profile(for: "ORG.HONGKONGZIXUN.MORELOGIN")?.kind == .chromium,
          "custom ID resolves case-insensitively")
    check(registry.customEntries == [entry] && writes == 1 && notifications == 1, "add publishes and persists once")
    check(!registry.reload() && notifications == 1, "unchanged reload does not notify")
    expectError("duplicate bundle rejected") {
        try registry.add(BrowserProfileEntry(name: "Duplicate", bundleIdentifier: "ORG.HONGKONGZIXUN.MORELOGIN"))
    }
    expectError("empty name rejected") {
        try registry.add(BrowserProfileEntry(name: " ", bundleIdentifier: "valid.app"))
    }
    expectError("invalid bundle rejected") {
        try registry.add(BrowserProfileEntry(name: "Bad", bundleIdentifier: "bad bundle"))
    }
    expectError("duplicate UUID rejected") {
        try registry.add(BrowserProfileEntry(id: entry.id, name: "Bad", bundleIdentifier: "other.app"))
    }
    entry.profile = .firefox
    try registry.update(entry)
    check(registry.profile(for: entry.bundleIdentifier)?.kind == .firefox, "edit changes profile")
    try registry.remove(id: entry.id)
    check(registry.profile(for: entry.bundleIdentifier) == nil, "remove custom ID")

    var override = BrowserProfileEntry(name: "Chrome override", bundleIdentifier: "COM.GOOGLE.CHROME", profile: .safari)
    try registry.add(override)
    check(registry.profile(for: "com.google.Chrome")?.kind == .safari, "custom entry overrides seed")
    override.enabled = false
    try registry.update(override)
    check(registry.profile(for: "com.google.Chrome") == nil, "disabled override shadows seed")
    try registry.remove(id: override.id)
    check(registry.profile(for: "com.google.Chrome") == chrome, "removal restores seed")

    let custom = BrowserProfileEntry(name: "Localized", bundleIdentifier: "example.localized",
        signature: BrowserSignatureOverrides(exactDescriptions: ["Barre d’adresse"], domClasses: ["CustomOmnibox"],
                                             identifier: "custom-id"))
    try registry.add(custom)
    let copy = SharedBrowserRegistry(readData: { stored }, writeData: { stored = $0 })
    check(copy.reload() && copy.customEntries == [custom], "round-trip restores custom entry")
    let resolved = copy.profile(for: custom.bundleIdentifier)
    check(resolved?.exactDescriptions == ["Barre d’adresse"] && resolved?.domClasses == ["CustomOmnibox"]
          && resolved?.identifier == "custom-id", "exact signature overrides round-trip")
    stored = Data("invalid".utf8)
    check(!copy.reload() && copy.customEntries == [custom], "corrupt data preserves last valid snapshot")
    expectError("corrupt stored data prevents destructive writes") { try copy.add(entry) }
    stored = nil
    check(copy.reload() && copy.customEntries.isEmpty && copy.profile(for: custom.bundleIdentifier) == nil,
          "missing data reloads defaults")
    let legacy = "[{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\","
        + "\"bundleIdentifier\":\"legacy.app\",\"profile\":\"chromium\"}]"
    stored = Data(legacy.utf8)
    check(copy.reload() && copy.customEntries.first?.enabled == true, "missing optional fields decode safely")
    if let failure = try concurrentReloadFailure() { check(false, failure) }
} catch {
    fputs("FAIL: unexpected registry error: \(error)\n", stderr)
    exit(1)
}
print("Browser registry scenarios passed")
