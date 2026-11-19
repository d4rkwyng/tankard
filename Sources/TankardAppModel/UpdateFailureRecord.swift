import Foundation

/// 0.8.8 (final gauntlet, bug 3): the last `brew update` failure, saved
/// (`AppSettings.lastUpdateFailure`) so "Last refresh failed" survives a
/// relaunch: it stays until the next update or Dismiss, as it does within
/// a session. A brew update that succeeded after it (any of Tankard's:
/// `AppSettings.lastBrewUpdate`, such as a background check's) drops it.
struct UpdateFailureRecord: Codable, Equatable, Sendable {
    var error: StoreError
    var at: Date

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    @MainActor
    static func load(_ settings: AppSettings) -> StoreError? {
        guard let data = settings.lastUpdateFailure,
              let r = try? JSONDecoder().decode(UpdateFailureRecord.self, from: data) else { return nil }
        if let ok = settings.lastBrewUpdate, ok >= r.at {
            settings.lastUpdateFailure = nil
            return nil
        }
        return r.error
    }
}
