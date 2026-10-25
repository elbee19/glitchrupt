import AppKit
import Foundation
import Darwin
import QuartzCore

struct AgentRequest: Decodable {
    let id: String
    let action: String
    let variant: String?
    let duration_ms: Int?
    let volume: Double?
    let sound: Bool?
    let preview: Bool?
    let key: String?
    let key_prefix: String?
    let `repeat`: Bool?
}

@MainActor extension Controller {
    var requestDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glitchrupt/requests", isDirectory: true)
    }
    func prepareRequestDirectory() throws {
        let files = FileManager.default
        for directory in [requestDirectory.deletingLastPathComponent(), requestDirectory] {
            if !files.fileExists(atPath: directory.path) {
                try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let attrs = try files.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw Failure.message("Unsafe request directory")
            }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        // Remove only old, owned bridge files; never an active request.
        for file in try files.contentsOfDirectory(at: requestDirectory, includingPropertiesForKeys: nil) {
            let parts = file.lastPathComponent.split(separator: ".")
            guard let first = parts.first, UUID(uuidString: String(first)) != nil,
                  file.pathExtension == "json" || file.pathExtension == "tmp",
                  let attrs = try? files.attributesOfItem(atPath: file.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > 60 else { continue }
            try? files.removeItem(at: file)
        }
    }
    func readPrivateRequest(_ path: URL) throws -> Data {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.message("Cannot open request") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= 16384,
              abs(Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)) < 30 else {
            throw Failure.message("Invalid request file")
        }
        let data = try handle.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384 else { throw Failure.message("Request too large") }
        return data
    }
    func writeResponse(_ id: String, _ value: [String: Any]) {
        var result = value; result["request_id"] = id
        do {
            let directory = requestDirectory
            try prepareRequestDirectory()
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            let temporary = directory.appendingPathComponent("\(id).\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.message("Cannot write response") }
            let destination = directory.appendingPathComponent("\(id).response.json")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: temporary); return }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch { log("RESPONSE_WRITE_FAILED") }
    }
    func handleRequestURL(_ url: URL) {
        guard url.scheme == "glitchrupt", url.host == "request", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2, let uuid = UUID(uuidString: url.lastPathComponent) else { return }
        let id = uuid.uuidString.lowercased()
        let response = requestDirectory.appendingPathComponent("\(id).response.json")
        if FileManager.default.fileExists(atPath: response.path) { return }
        if seenRequests.contains(id) { writeResponse(id, ["status": "error", "error": "duplicate_request"]); return }
        let path = requestDirectory.appendingPathComponent("\(id).request.json")
        do {
            try prepareRequestDirectory()
            let data = try readPrivateRequest(path)
            let allowed: Set<String> = ["id", "action", "variant", "duration_ms", "volume", "sound", "preview", "key", "key_prefix", "repeat"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw Failure.message("Invalid request fields") }
            let request = try JSONDecoder().decode(AgentRequest.self, from: data)
            guard UUID(uuidString: request.id) == uuid else { throw Failure.message("Request ID mismatch") }
            seenRequests.insert(id); requestOrder.append(id)
            if requestOrder.count > 1024 { seenRequests.remove(requestOrder.removeFirst()) }
            if request.action == "status" {
                writeResponse(id, ["status": "ready", "permission": CGPreflightScreenCaptureAccess(), "reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                   "agents_enabled": agentsEnabled, "busy": busy, "cooldown_remaining_ms": cooldownRemaining,
                                   "app_version": "0.3.0", "pending_count": approvalRegistry.count, "variants": SoundChoice.allCases.map(\.id), "tester_visible": window?.isVisible ?? false])
                return
            }
            if request.action == "pending" {
                guard Set(object.keys).isSubset(of: ["id", "action"]) else { throw Failure.message("Invalid pending fields") }
                writeResponse(id, ["status": "pending", "pending_count": approvalRegistry.count, "entries": approvalRegistry.snapshot(now: approvalNow)])
                return
            }
            if request.action == "resolve" {
                guard Set(object.keys).isSubset(of: ["id", "action", "key", "key_prefix"]),
                      (request.key == nil) != (request.key_prefix == nil),
                      ApprovalRegistry.validKey(request.key ?? request.key_prefix ?? "") else { throw Failure.message("Invalid resolve key") }
                let removed = approvalRegistry.resolve(key: request.key, prefix: request.key_prefix)
                updatePendingCount()
                writeResponse(id, ["status": "resolved", "removed_count": removed, "pending_count": approvalRegistry.count])
                return
            }
            if request.action == "wait" {
                guard Set(object.keys).isSubset(of: ["id", "action", "key", "variant", "volume", "sound", "preview", "repeat"]),
                      let key = request.key, ApprovalRegistry.validKey(key),
                      let variant = SoundChoice(id: request.variant ?? "classic") else { throw Failure.message("Invalid wait fields") }
                let volume = request.volume ?? 0.28
                guard volume.isFinite, (0...0.5).contains(volume) else { throw Failure.message("Settings out of bounds") }
                guard approvalRegistry.entries[key] != nil || approvalRegistry.count < ApprovalRegistry.maximumCount else {
                    writeResponse(id, ["status": "error", "error": "Too many pending approvals"]); return
                }
                let settings = ApprovalRegistry.Settings(variant: variant.id, volume: Float(volume), sound: request.sound ?? true, preview: request.preview ?? false, repeats: request.`repeat` ?? true)
                let now = approvalNow
                let added = approvalRegistry.register(key, settings: settings, now: now)
                let adopted = added && approvalRegistry.adoptRecentCue(key, now: now, lastCueAt: lastApprovalCueAt, active: approvalPairRunning)
                if adopted { approvalEpisodeKeys.insert(key) }
                let repeats = approvalRegistry.entries[key]?.settings.repeats ?? settings.repeats
                if adopted && !approvalPairRunning { approvalRegistry.finishEpisode([key]) }
                updatePendingCount()
                let status = adopted ? "coalesced" : (added ? (approvalSuppression(preview: settings.preview) ?? "queued") : (approvalRegistry.entries[key]?.alertStatus ?? "queued"))
                writeResponse(id, ["status": "waiting", "key": key, "pending_count": approvalRegistry.count, "repeat_interval_ms": 900000, "burst_duration_ms": 600, "gap_ms": 200, "alert_status": status, "duplicate": !added, "repeat": repeats])
                if added && !adopted { scheduleApprovalDispatch() }
                return
            }
            guard Set(object.keys).isSubset(of: ["id", "action", "variant", "duration_ms", "volume", "sound", "preview"]) else { throw Failure.message("Invalid signal fields") }
            guard request.action == "signal", let variant = SoundChoice(id: request.variant ?? "classic") else { throw Failure.message("Invalid action or variant") }
            let ms = request.duration_ms ?? 600; let volume = request.volume ?? 0.28
            guard (300...1000).contains(ms), volume.isFinite, (0...0.5).contains(volume) else { throw Failure.message("Settings out of bounds") }
            let previewOnly = request.preview ?? false
            let base: [String: Any] = ["variant": variant.id, "duration_ms": ms, "mode": previewOnly ? "preview" : "desktop"]
            func suppress(_ status: String) { var result = base; result["status"] = status; result["cooldown_remaining_ms"] = cooldownRemaining; writeResponse(id, result) }
            guard agentsEnabled else { suppress("muted"); return }
            guard !busy else { suppress("busy"); return }
            guard cooldownRemaining == 0 else { suppress("cooldown"); return }
            let settings = CueSettings(choice: variant, duration: Double(ms) / 1000, volume: Float(volume), sound: (request.sound ?? true) && soundEnabled)
            let accepted = executeCue(settings: settings, previewOnly: previewOnly, delay: 0) { [weak self] result in self?.writeResponse(id, result) }
            if accepted { lastAgentCueAt = CACurrentMediaTime() }
        } catch { writeResponse(id, ["status": "error", "error": "Invalid, missing, or expired request"]); log("REQUEST_REJECTED") }
    }
}
