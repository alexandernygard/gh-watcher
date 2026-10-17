import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var watched: [String] { didSet { defaults.set(watched, forKey: "watched") } }
    var rules: [NotificationRule] { didSet { save(rules, "rules") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") } }
    var quietStart: Int { didSet { defaults.set(quietStart, forKey: "quietStart") } }
    var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: "quietEnd") } }
    /// Seconds between polls of an idle watched repository.
    var baseInterval: Double { didSet { defaults.set(baseInterval, forKey: "baseInterval") } }
    /// Seconds between polls while a workflow is running in that repository.
    var activeInterval: Double { didSet { defaults.set(activeInterval, forKey: "activeInterval") } }
    /// Multiplier applied while GH Watcher is in the background.
    var backgroundMultiplier: Double { didSet { defaults.set(backgroundMultiplier, forKey: "backgroundMultiplier") } }
    var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    var menuBarShowsCount: Bool { didSet { defaults.set(menuBarShowsCount, forKey: "menuBarShowsCount") } }
    var didOnboard: Bool { didSet { defaults.set(didOnboard, forKey: "didOnboard") } }

    init() {
        defaults.register(defaults: [
            "notificationsEnabled": true,
            "quietHoursEnabled": false,
            "quietStart": 22,
            "quietEnd": 8,
            "baseInterval": 60.0,
            "activeInterval": 15.0,
            "backgroundMultiplier": 2.0,
            "showInDock": true,
            "menuBarShowsCount": true,
        ])
        watched = defaults.stringArray(forKey: "watched") ?? []
        rules = Self.load([NotificationRule].self, "rules", defaults) ?? NotificationRule.defaults
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        quietHoursEnabled = defaults.bool(forKey: "quietHoursEnabled")
        quietStart = defaults.integer(forKey: "quietStart")
        quietEnd = defaults.integer(forKey: "quietEnd")
        baseInterval = defaults.double(forKey: "baseInterval")
        activeInterval = defaults.double(forKey: "activeInterval")
        backgroundMultiplier = defaults.double(forKey: "backgroundMultiplier")
        showInDock = defaults.bool(forKey: "showInDock")
        menuBarShowsCount = defaults.bool(forKey: "menuBarShowsCount")
        didOnboard = defaults.bool(forKey: "didOnboard")
    }

    var inQuietHours: Bool {
        guard quietHoursEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: .now)
        return quietStart <= quietEnd ? (hour >= quietStart && hour < quietEnd) : (hour >= quietStart || hour < quietEnd)
    }

    func resetRules() { rules = NotificationRule.defaults }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
