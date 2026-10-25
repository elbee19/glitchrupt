import Foundation

/// Pure state machine. Callers provide monotonic uptime, so tests never sleep.
struct ApprovalRegistry {
    static let interval: TimeInterval = 900
    static let maximumCount = 256
    struct Settings {
        let variant: String
        let volume: Float
        let sound: Bool
        let preview: Bool
        let repeats: Bool
        init(variant: String, volume: Float, sound: Bool, preview: Bool, repeats: Bool = true) {
            self.variant = variant; self.volume = volume; self.sound = sound
            self.preview = preview; self.repeats = repeats
        }
    }
    struct Entry {
        let key: String
        let settings: Settings
        let registeredAt: TimeInterval
        var nextReminderAt: TimeInterval
        var alertStatus: String
        var hasBeenClaimed: Bool
    }
    private(set) var entries: [String: Entry] = [:]
    var count: Int { entries.count }
    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 160 && key.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || "._:-".unicodeScalars.contains($0)
        }
    }
    /// False means this key already exists; its settings and deadline stay intact.
    @discardableResult mutating func register(_ key: String, settings: Settings, now: TimeInterval) -> Bool {
        guard entries[key] == nil else { return false }
        entries[key] = Entry(key: key, settings: settings, registeredAt: now, nextReminderAt: now, alertStatus: "queued", hasBeenClaimed: false)
        return true
    }
    /// A fallback and a permission hook can describe the same human interruption.
    /// Adopt new due keys into the active/recent pair instead of queueing another pair.
    @discardableResult mutating func adoptRecentCue(_ key: String, now: TimeInterval, lastCueAt: TimeInterval?, active: Bool = false) -> Bool {
        guard let lastCueAt, now >= lastCueAt, active || now - lastCueAt < 5,
              let entry = entries[key], entry.nextReminderAt <= now else { return false }
        let sharedDeadline = lastCueAt + Self.interval
        entries[key]?.nextReminderAt = sharedDeadline > now ? sharedDeadline : now + Self.interval
        entries[key]?.alertStatus = "coalesced"
        entries[key]?.hasBeenClaimed = true
        return true
    }
    mutating func resolve(key: String? = nil, prefix: String? = nil) -> Int {
        let keys = entries.keys.filter { candidate in
            candidate == key || (prefix.map { candidate.hasPrefix($0) } ?? false)
        }
        for key in keys { entries.removeValue(forKey: key) }
        return keys.count
    }
    mutating func clear() { entries.removeAll() }
    /// Hook-only one-shot alerts never survive their attention episode.
    mutating func finishEpisode(_ keys: [String]) {
        for key in keys where entries[key]?.settings.repeats == false { entries.removeValue(forKey: key) }
    }
    /// Coalesces all due approvals. Deadlines advance from now, without catch-up bursts.
    mutating func claimDue(now: TimeInterval) -> [Entry] {
        let due = entries.values.filter { $0.nextReminderAt <= now && ($0.settings.repeats || !$0.hasBeenClaimed) }.sorted {
            $0.nextReminderAt == $1.nextReminderAt ? $0.key < $1.key : $0.nextReminderAt < $1.nextReminderAt
        }
        for entry in due {
            entries[entry.key]?.nextReminderAt = now + Self.interval
            entries[entry.key]?.hasBeenClaimed = true
        }
        return due
    }
    func hasAny(_ keys: [String]) -> Bool { keys.contains { entries[$0] != nil } }
    mutating func record(_ status: String, keys: [String]) {
        for key in keys { entries[key]?.alertStatus = status }
    }
    func snapshot(now: TimeInterval) -> [[String: Any]] {
        entries.values.sorted { $0.key < $1.key }.map {
            ["key": $0.key, "next_reminder_ms": ($0.settings.repeats ? max(0, Int(ceil(($0.nextReminderAt - now) * 1000))) : 0), "alert_status": $0.alertStatus, "preview": $0.settings.preview, "repeat": $0.settings.repeats]
        }
    }
}
