import AppKit
import QuartzCore

@MainActor extension Controller {
    var approvalNow: TimeInterval { CACurrentMediaTime() }
    func updatePendingCount() {
        approvalCountItem?.title = "Pending approvals: \(approvalRegistry.count)"
        menuItem?.button?.toolTip = "Glitchrupt · \(approvalRegistry.count) pending approval\(approvalRegistry.count == 1 ? "" : "s")"
    }
    @objc func clearPendingApprovals() {
        approvalRegistry.clear(); updatePendingCount()
        statusLabel?.stringValue = "Pending approval reminders cleared."
    }
    @objc func previewApprovalPair() {
        let settings = CueSettings(choice: selectedSound, duration: 0.6, volume: options.volume, sound: soundEnabled)
        _ = executeCue(settings: settings, previewOnly: true, delay: 0, pair: true) { [weak self] result in
            self?.statusLabel?.stringValue = result["status"] as? String == "completed" ? "Approval preview complete · 600 ms + 200 ms gap + 600 ms" : "Approval preview could not complete."
        }
    }
    func approvalSuppression(preview: Bool) -> String? {
        guard agentsEnabled else { return "muted" }
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
            approvalRegistry.record(status, keys: keys); approvalRegistry.finishEpisode(keys); updatePendingCount(); return
        }
        let settings = CueSettings(choice: choice, duration: 0.6, volume: first.settings.volume, sound: first.settings.sound && soundEnabled)
        approvalEpisodeKeys = Set(keys)
        let accepted = executeCue(settings: settings, previewOnly: first.settings.preview, delay: 0, pair: true, shouldContinue: { [weak self] in
            guard let self else { return false }
            return self.agentsEnabled && self.approvalRegistry.hasAny(Array(self.approvalEpisodeKeys))
        }) { [weak self] result in
            guard let self else { return }
            self.approvalPairRunning = false
            self.approvalRegistry.record(result["status"] as? String ?? "error", keys: Array(self.approvalEpisodeKeys))
            self.approvalRegistry.finishEpisode(Array(self.approvalEpisodeKeys))
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
