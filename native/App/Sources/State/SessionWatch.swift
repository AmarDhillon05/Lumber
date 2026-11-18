// Notices when the app died in the foreground last time (a crash, or iOS
// killing it for memory) and what it was doing, so the next launch can say so
// instead of silently restarting.
//
// The marker lives in UserDefaults: "in the foreground, doing X". It's cleared
// to "background" whenever the app leaves the foreground, so being killed in
// the background or swiped away (which iOS does normally) never counts.

import Foundation

struct SessionMarker {
    struct State: Codable, Equatable {
        var foreground: Bool
        var activity: String
        var at: Double // ms since 1970
    }

    static let key = "lumber.session.marker"
    let defaults: UserDefaults

    func read() -> State? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    func write(_ s: State) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }
}

extension AppModel {
    static let idleActivity = "browsing the library"

    /// Call once at launch: reads how the last session ended, then marks this
    /// one as running in the foreground.
    func checkLastSession() {
        var parts: [String] = []
        if let last = sessionMarker.read(), last.foreground {
            parts.append("Lumber closed unexpectedly last time while \(last.activity).")
        }
        if let separation = services.separation.checkForCrash() {
            parts.append(separation)
        }
        crashNotice = parts.isEmpty ? nil : parts.joined(separator: " ")
        currentActivity = AppModel.idleActivity
        markSession(foreground: true)
    }

    /// What the app is doing right now, for the crash notice ("removing drums from …").
    func noteActivity(_ activity: String?) {
        currentActivity = activity ?? AppModel.idleActivity
        markSession(foreground: true)
    }

    func markSession(foreground: Bool) {
        sessionMarker.write(SessionMarker.State(foreground: foreground, activity: currentActivity, at: nowMs()))
    }

    func dismissCrashNotice() { crashNotice = nil }
}
