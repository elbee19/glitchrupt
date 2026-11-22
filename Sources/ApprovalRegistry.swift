import Foundation

/// Pure state machine. Callers provide monotonic uptime, so tests never sleep.
struct ApprovalRegistry {
    static let interval: TimeInterval = 900
    static let maximumCount = 256
    struct Context {
        var chatName: String?
        var reason: String?
        var chatID: String?
        var claudeSessionID: String?
        init(chatName: String? = nil, reason: String? = nil, chatID: String? = nil, claudeSessionID: String? = nil) {
            self.chatName = chatName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.chatID = chatID
            self.claudeSessionID = claudeSessionID
        }
        static func validText(_ text: String?, maximum: Int) -> Bool {
            guard let text else { return true }
            guard !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }) else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.unicodeScalars.count <= maximum
        }
        static func validClaudeSessionID(_ value: String?) -> Bool {
            guard let value else { return true }
            guard value.hasPrefix("local_") else { return false }
            return validChatID(String(value.dropFirst(6)))
        }
        static func validChatID(_ value: String?) -> Bool {
            guard let value else { return true }
            return UUID(uuidString: value)?.uuidString.lowercased() == value
        }
        /// The Claude desktop app's supported entry link for a Code session. Nil unless the ID is a validated local session.
        static func claudeContinueURL(sessionID: String) -> URL? {
            guard validClaudeSessionID(sessionID) else { return nil }
            var components = URLComponents()
            components.scheme = "claude"; components.host = "code"; components.path = "/continue"
            components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
            return components.url
        }
    }
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
        var context: Context
        let registeredAt: TimeInterval
        var nextReminderAt: TimeInterval
        var alertStatus: String
        var hasBeenClaimed: Bool
        /// A muted entry stays registered and keeps its key, but it is never claimed for a reminder.
        var muted = false
    }
    private(set) var entries: [String: Entry] = [:]
    var count: Int { entries.count }
    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 160 && key.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || "._:-".unicodeScalars.contains($0)
        }
    }
    /// False means this key already exists; its settings and deadline stay intact.
    @discardableResult mutating func register(_ key: String, settings: Settings, context: Context = Context(), now: TimeInterval) -> Bool {
        if entries[key] != nil {
            // Enrich legacy waits without replaying or moving their reminder deadline.
            if let name = context.chatName { entries[key]?.context.chatName = name }
            if let reason = context.reason { entries[key]?.context.reason = reason }
            if let chatID = context.chatID { entries[key]?.context.chatID = chatID; entries[key]?.context.claudeSessionID = nil }
            if let id = context.claudeSessionID { entries[key]?.context.claudeSessionID = id; entries[key]?.context.chatID = nil }
            return false
        }
        entries[key] = Entry(key: key, settings: settings, context: context, registeredAt: now, nextReminderAt: now, alertStatus: "queued", hasBeenClaimed: false)
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
    /// Explicit installer handover only; normal launches never restore waits.
    mutating func restore(_ key: String, settings: Settings, context: Context, remaining: TimeInterval, now: TimeInterval, muted: Bool = false) {
        guard entries[key] == nil else { return }
        entries[key] = Entry(key: key, settings: settings, context: context, registeredAt: now,
                             nextReminderAt: now + max(0, min(Self.interval, remaining)), alertStatus: "restored", hasBeenClaimed: true, muted: muted)
    }
    /// Returns false only when the key is unknown. Muting keeps the entry, its context, and its deadline.
    /// Unmuting a repeating entry starts a fresh interval, so time spent muted never becomes an immediate burst.
    /// An unclaimed one-shot has never played, so its single cue becomes due at once.
    @discardableResult mutating func setMuted(_ key: String, muted: Bool, now: TimeInterval) -> Bool {
        guard let entry = entries[key] else { return false }
        guard entry.muted != muted else { return true }
        entries[key]?.muted = muted
        if !muted { entries[key]?.nextReminderAt = entry.settings.repeats ? now + Self.interval : now }
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
    /// Coalesces all due approvals. Deadlines advance from now, without catch-up bursts. Muted entries are skipped.
    mutating func claimDue(now: TimeInterval) -> [Entry] {
        let due = entries.values.filter { !$0.muted && $0.nextReminderAt <= now && ($0.settings.repeats || !$0.hasBeenClaimed) }.sorted {
            $0.nextReminderAt == $1.nextReminderAt ? $0.key < $1.key : $0.nextReminderAt < $1.nextReminderAt
        }
        for entry in due {
            entries[entry.key]?.nextReminderAt = now + Self.interval
            entries[entry.key]?.hasBeenClaimed = true
        }
        return due
    }
    func hasAny(_ keys: [String]) -> Bool { keys.contains { entries[$0] != nil } }
    /// True while at least one of these keys is registered and not muted. Gates a pending second burst.
    func hasUnmuted(_ keys: [String]) -> Bool { keys.contains { entries[$0]?.muted == false } }
    mutating func record(_ status: String, keys: [String]) {
        for key in keys { entries[key]?.alertStatus = status }
    }
    func snapshot(now: TimeInterval) -> [[String: Any]] {
        entries.values.sorted { $0.key < $1.key }.map { entry in
            var value: [String: Any] = ["key": entry.key, "next_reminder_ms": (entry.settings.repeats ? max(0, Int(ceil((entry.nextReminderAt - now) * 1000))) : 0), "alert_status": entry.alertStatus, "preview": entry.settings.preview, "repeat": entry.settings.repeats, "muted": entry.muted]
            if let name = entry.context.chatName { value["chat_name"] = name }
            if let reason = entry.context.reason { value["reason"] = reason }
            if let chatID = entry.context.chatID { value["chat_id"] = chatID }
            if let id = entry.context.claudeSessionID { value["claude_session_id"] = id }
            return value
        }
    }
}
