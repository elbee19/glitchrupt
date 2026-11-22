import AppKit
import QuartzCore

@MainActor extension Controller {
    var approvalNow: TimeInterval { CACurrentMediaTime() }
    /// Owned, fresh, private one-time handover; never a crash-recovery file.
    func restoreApprovalHandover(_ path: String) {
        struct Handover: Decodable { let created_at: Double; let entries: [Item] }
        struct Item: Decodable {
            let key: String; let variant: String; let volume: Float; let sound: Bool; let preview: Bool
            let next_reminder_ms: Int; let chat_name: String?; let reason: String?; let chat_id: String?; let claude_session_id: String?
            let muted: Bool? // Optional for handovers written before per-request mute existed; missing means false.
        }
        let url = URL(fileURLWithPath: path)
        do {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.deletingLastPathComponent().standardizedFileURL == requestDirectory.standardizedFileURL,
                  url.pathExtension == "json", name.hasPrefix("handover-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { throw Failure.message("Invalid handover location") }
            try prepareRequestDirectory()
            let data = try readPrivateRequest(url)
            let handover = try JSONDecoder().decode(Handover.self, from: data)
            let elapsed = Date().timeIntervalSince1970 - handover.created_at
            guard elapsed >= 0, elapsed < 30, handover.entries.count <= ApprovalRegistry.maximumCount else { throw Failure.message("Invalid handover") }
            var restored = ApprovalRegistry()
            for item in handover.entries {
                guard ApprovalRegistry.validKey(item.key), SoundChoice(id: item.variant) != nil,
                      item.volume.isFinite, (0...0.5).contains(item.volume), (0...900000).contains(item.next_reminder_ms),
                      ApprovalRegistry.Context.validText(item.chat_name, maximum: 100),
                      ApprovalRegistry.Context.validText(item.reason, maximum: 240),
                      ApprovalRegistry.Context.validChatID(item.chat_id), ApprovalRegistry.Context.validClaudeSessionID(item.claude_session_id),
                      item.chat_id == nil || item.claude_session_id == nil else { throw Failure.message("Invalid handover entry") }
                let context = ApprovalRegistry.Context(chatName: item.chat_name, reason: item.reason, chatID: item.chat_id, claudeSessionID: item.claude_session_id)
                restored.restore(item.key, settings: .init(variant: item.variant, volume: item.volume, sound: item.sound, preview: item.preview),
                                 context: context, remaining: Double(item.next_reminder_ms) / 1000 - elapsed, now: approvalNow, muted: item.muted ?? false)
            }
            try FileManager.default.removeItem(at: url)
            approvalRegistry = restored
            log("APPROVAL_HANDOVER_COMPLETE count=\(restored.count)")
        } catch { log("APPROVAL_HANDOVER_REJECTED") }
    }

    func updatePendingCount() {
        approvalCountItem?.title = "Waiting for input (\(approvalRegistry.count))"
        rebuildPendingRequestsMenu()
        if attentionBanner.isVisible {
            attentionBanner.update(entries: visibleAttentionEntries())
        }
        menuItem?.button?.toolTip = "Glitchrupt · \(approvalRegistry.count) pending approval\(approvalRegistry.count == 1 ? "" : "s")"
    }
    /// Muted requests drop out of the banner; they stay in the menu list until resolved.
    func visibleAttentionEntries() -> [ApprovalRegistry.Entry] {
        approvalRegistry.entries.values.filter { attentionBannerKeys.contains($0.key) && !$0.muted }.sorted { $0.registeredAt < $1.registeredAt || ($0.registeredAt == $1.registeredAt && $0.key < $1.key) }
    }
    func presentAttentionBanner(keys: [String]) {
        attentionBannerKeys = Set(keys)
        attentionBanner.show(entries: visibleAttentionEntries(), open: { [weak self] key in self?.openAttentionRequest(key) },
                             mute: { [weak self] action in self?.applyAttentionMute(action) })
    }
    /// Banner Mute actions. Each one dismisses the banner first (done by the banner itself).
    func applyAttentionMute(_ action: AttentionMuteAction) {
        switch action {
        case .request(let key): _ = approvalRegistry.setMuted(key, muted: true, now: approvalNow)
        case .allAgentCuesForOneHour: startTimedAgentMute(for: 3600)
        case .pauseAgentCues: setAgentsEnabled(false)
        }
        updatePendingCount()
    }
    func rebuildPendingRequestsMenu() {
        guard let menu = pendingRequestsMenu else { return }
        menu.removeAllItems()
        let entries = approvalRegistry.entries.values.sorted { $0.registeredAt < $1.registeredAt || ($0.registeredAt == $1.registeredAt && $0.key < $1.key) }
        if entries.isEmpty {
            menu.addItem(NSMenuItem(title: "No pending requests", action: nil, keyEquivalent: "")); return
        }
        for entry in entries {
            let name = entry.context.chatName ?? "Unnamed agent · \(String(entry.key.prefix(36)))"
            let item = NSMenuItem(title: entry.muted ? "\(name) (muted)" : name, action: #selector(openPendingRequest(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.key
            item.toolTip = entry.context.reason ?? entry.key
            let details = NSMenu()
            let reason = NSMenuItem(title: String((entry.context.reason ?? "No description supplied").prefix(90)), action: nil, keyEquivalent: "")
            reason.toolTip = entry.context.reason; details.addItem(reason)
            let open = NSMenuItem(title: entry.context.chatID == nil && entry.context.claudeSessionID == nil ? "View request…" : "Open chat", action: #selector(openPendingRequest(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = entry.key; details.addItem(open)
            let mute = NSMenuItem(title: entry.muted ? "Unmute this request" : "Mute this request", action: #selector(togglePendingRequestMute(_:)), keyEquivalent: "")
            mute.target = self; mute.representedObject = entry.key; details.addItem(mute)
            let stop = NSMenuItem(title: "Stop this reminder", action: #selector(dismissPendingRequest(_:)), keyEquivalent: "")
            stop.target = self; stop.representedObject = entry.key; details.addItem(stop)
            item.submenu = details; menu.addItem(item)
        }
    }
    @objc func openPendingRequest(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { openAttentionRequest(key) }
    }
    @objc func dismissPendingRequest(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        _ = approvalRegistry.resolve(key: key); updatePendingCount()
    }
    @objc func togglePendingRequestMute(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let entry = approvalRegistry.entries[key] else { return }
        _ = approvalRegistry.setMuted(key, muted: !entry.muted, now: approvalNow); updatePendingCount()
    }
    func openAttentionRequest(_ key: String) {
        guard let entry = approvalRegistry.entries[key] else { return }
        if let id = entry.context.chatID, ApprovalRegistry.Context.validChatID(id),
           let url = URL(string: "codex://threads/\(id)"), NSWorkspace.shared.open(url) { return }
        if let id = entry.context.claudeSessionID, let url = ApprovalRegistry.Context.claudeContinueURL(sessionID: id),
           NSWorkspace.shared.open(url) { return }
        let alert = NSAlert()
        alert.messageText = entry.context.chatName ?? "Agent needs your input"
        alert.informativeText = (entry.context.reason ?? "The caller did not provide a description or chat link.") + "\n\nRequest key: " + key + "\n\nOpening or dismissing this view does not approve the request."
        alert.addButton(withTitle: "Close"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func previewAttentionBanner() {
        let settings = ApprovalRegistry.Settings(variant: "classic", volume: 0, sound: false, preview: true)
        let context = ApprovalRegistry.Context(chatName: "Example chat needs you", reason: "This is a banner preview. No response is needed.")
        let entry = ApprovalRegistry.Entry(key: "preview:banner", settings: settings, context: context, registeredAt: approvalNow, nextReminderAt: approvalNow, alertStatus: "preview", hasBeenClaimed: true)
        attentionBanner.show(entries: [entry], open: { _ in }, mute: { _ in })
    }
    @objc func clearPendingApprovals() {
        approvalRegistry.clear(); updatePendingCount()
        statusLabel?.stringValue = "Pending approval reminders cleared."
    }
    @objc func previewApprovalPair() {
        let settings = CueSettings(choice: selectedSound, duration: 0.6, volume: options.volume, sound: soundEnabled)
        _ = executeCue(settings: settings, previewOnly: true, delay: 0, pair: approvalPair, gapMS: approvalGapMS) { [weak self] result in
            self?.statusLabel?.stringValue = result["status"] as? String == "completed" ? "Attention pattern preview complete" : "Approval preview could not complete."
        }
    }
    func approvalSuppression(preview: Bool) -> String? {
        guard agentCuesActive else { return "muted" }
        if !preview {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "reduce_motion" }
            if !CGPreflightScreenCaptureAccess() { return "permission_required" }
        }
        return nil
    }
    func scheduleApprovalDispatch() {
        guard !approvalDispatchScheduled else { return }
        approvalDispatchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.approvalDispatchScheduled = false; self.processDueApprovals()
        }
    }
    func processDueApprovals() {
        // Busy/cooldown are transient; defer the same due group without queueing effects.
        guard !busy, cooldownRemaining == 0 else { return }
        let due = approvalRegistry.claimDue(now: approvalNow)
        guard let first = due.first, let choice = SoundChoice(id: first.settings.variant) else { return }
        let keys = due.map(\.key)
        if let status = approvalSuppression(preview: first.settings.preview) {
            approvalRegistry.record(status, keys: keys)
            if status != "muted" { presentAttentionBanner(keys: keys) }
            approvalRegistry.finishEpisode(keys); updatePendingCount(); return
        }
        let settings = CueSettings(choice: choice, duration: 0.6, volume: first.settings.volume, sound: first.settings.sound && soundEnabled)
        attentionBanner.dismiss()
        approvalEpisodeKeys = Set(keys)
        let accepted = executeCue(settings: settings, previewOnly: first.settings.preview, delay: 0, pair: approvalPair, gapMS: approvalGapMS, shouldContinue: { [weak self] in
            guard let self else { return false }
            return self.agentCuesActive && self.approvalRegistry.hasUnmuted(Array(self.approvalEpisodeKeys))
        }) { [weak self] result in
            guard let self else { return }
            self.approvalPairRunning = false
            self.approvalRegistry.record(result["status"] as? String ?? "error", keys: Array(self.approvalEpisodeKeys))
            self.approvalRegistry.finishEpisode(Array(self.approvalEpisodeKeys))
            if result["status"] as? String == "completed", self.agentCuesActive {
                self.presentAttentionBanner(keys: Array(self.approvalEpisodeKeys))
            }
            self.updatePendingCount()
            log("APPROVAL_PAIR_COMPLETE pending=\(self.approvalRegistry.count) status=\(result["status"] as? String ?? "error")")
        }
        if accepted {
            approvalPairRunning = true
            approvalEpisodeKeys = Set(keys)
            lastApprovalCueAt = approvalNow
            lastAgentCueAt = lastApprovalCueAt
            approvalRegistry.record("playing", keys: keys)
        }
        updatePendingCount()
    }
}
