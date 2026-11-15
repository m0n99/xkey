import Foundation

final class SharedSettings {
    static let shared = SharedSettings()
    func getBrowserProfilesData() -> Data? { fatalError("Unexpected preferences read") }
    func setBrowserProfilesData(_ data: Data) -> Bool { fatalError("Unexpected preferences write") }
}
