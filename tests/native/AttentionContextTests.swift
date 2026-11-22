import Foundation
@main struct AttentionContextTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1; precondition(condition(), label)
    }
    static func main() {
        typealias Context = ApprovalRegistry.Context
        check(Context.validText(nil, maximum: 100), "legacy optional context")
        for invalid in ["", "   ", "line\nbreak", "tab\t", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}"] {
            check(!Context.validText(invalid, maximum: 100), "reject invalid label")
        }
        check(Context.validText(String(repeating: "😀", count: 100), maximum: 100), "bound Unicode scalars rather than UTF16")
        check(!Context.validText(String(repeating: "😀", count: 101), maximum: 100), "reject excess scalars")
        let id = "00000000-0000-4000-8000-000000000001"
        check(Context.validChatID(id), "canonical chat UUID")
        for invalid in ["new", "codex://threads/" + id, id + "?prompt=bad", "00000000000040008000000000000001", "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"] {
            check(!Context.validChatID(invalid), "reject noncanonical link data")
        }
        check(Context.validClaudeSessionID("local_" + id), "valid Claude desktop session")
        for invalid in [id, "local_" + id + "?x=1", "claude://claude.ai/epitaxy/local_" + id] {
            check(!Context.validClaudeSessionID(invalid), "reject unsafe Claude identifiers")
        }
        var state = ApprovalRegistry()
        let settings = ApprovalRegistry.Settings(variant: "classic", volume: 0.28, sound: false, preview: true)
        _ = state.register("owned:one", settings: settings, now: 10)
        _ = state.claimDue(now: 10)
        let original = state.entries["owned:one"]!.nextReminderAt
        let context = Context(chatName: "  Example chat  ", reason: "Approve the example", chatID: id)
        check(!state.register("owned:one", settings: settings, context: context, now: 12), "metadata update does not re-register")
        check(state.entries["owned:one"]?.nextReminderAt == original, "metadata preserves reminder deadline")
        check(state.claimDue(now: 12).isEmpty, "metadata does not replay")
        let snapshot = state.snapshot(now: 12)[0]
        check(snapshot["chat_name"] as? String == "Example chat", "trimmed name reaches menu snapshot")
        check(snapshot["reason"] as? String == "Approve the example", "reason retained")
        check(snapshot["chat_id"] as? String == id, "chat identity retained")
        _ = state.register("owned:one", settings: settings, now: 13)
        check(state.entries["owned:one"]?.context.chatName == "Example chat", "legacy duplicate does not erase metadata")
        _ = state.register("peer:two", settings: settings, context: context, now: 14)
        check(state.resolve(key: "owned:one") == 1, "resolve removes one list entry")
        check(state.snapshot(now: 14).count == 1 && state.entries["peer:two"] != nil, "peer request survives")
        state.clear(); check(state.snapshot(now: 14).isEmpty, "clear removes list and context")
        state.restore("handover:one", settings: settings, context: context, remaining: 125, now: 1000)
        check(state.claimDue(now: 1124.999).isEmpty, "handover never replays initial cue")
        check(state.claimDue(now: 1125).map(\.key) == ["handover:one"], "handover preserves remaining deadline")
        check(state.entries["handover:one"]?.nextReminderAt == 2025, "restored reminder keeps normal900second interval")
        check(state.resolve(key: "handover:one") == 1, "handed-over request resolves normally")
        state.restore("handover:muted", settings: settings, context: context, remaining: 60, now: 2000, muted: true)
        check(state.entries["handover:muted"]?.muted == true, "handover carries a muted request")
        check(state.claimDue(now: 2100).isEmpty, "handed-over muted request stays silent")
        state.restore("handover:legacy", settings: settings, context: context, remaining: 60, now: 2000)
        check(state.entries["handover:legacy"]?.muted == false, "handover without muted is unmuted")
        check(Context.claudeContinueURL(sessionID: "local_" + id)?.absoluteString == "claude://code/continue?session=local_" + id,
              "Claude link uses the supported code continue route")
        check(Context.claudeContinueURL(sessionID: "local_" + id)?.query == "session=local_" + id, "Claude link carries only the session parameter")
        for invalid in [id, "local_" + id + "&extra=1", "local_not-a-uuid", "claude://claude.ai/epitaxy/local_" + id, ""] {
            check(Context.claudeContinueURL(sessionID: invalid) == nil, "Claude link refuses unvalidated session IDs")
        }
        print("Attention context assertions: \(count)")
    }
}
