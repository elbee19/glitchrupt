import AppKit
import ScreenCaptureKit
import QuartzCore
import AVFoundation
import OSLog

let diagnosticLogger = Logger(subsystem: "local.glitchrupt.app", category: "lifecycle")
func log(_ text: String) { print(text); fflush(stdout); diagnosticLogger.notice("\(text, privacy: .public)") }
enum Failure: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let s): return s } }
}
struct Options {
    var agentMode = false
    var renderPath: String?
    var status = false
    var verifySounds = false
    var muted = false
    var soundChoice: SoundChoice?
    var duration = 0.6
    var intensity = 0.75
    var volume: Float = 0.28
    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            func next() throws -> String {
                i += 1
                guard i < args.count else { throw Failure.message("Missing value for \(arg)") }
                return args[i]
            }
            switch arg {
            case "--agent-mode": agentMode = true
            case "--preview": break
            case "--status": status = true
            case "--verify-sounds": verifySounds = true
            case "--mute": muted = true
            case "--sound":
                let value = try next()
                guard let choice = SoundChoice(id: value) else { throw Failure.message("Unknown crackle variant") }
                soundChoice = choice
            case "--render-preview": renderPath = try next()
            case "--duration":
                guard let value = Double(try next()), value.isFinite, (0.3...1).contains(value) else { throw Failure.message("Duration must be 0.3–1 seconds") }
                duration = value
            case "--volume":
                guard let value = Float(try next()), value.isFinite, (0...0.5).contains(value) else { throw Failure.message("Volume must be 0–0.5") }
                volume = value
            default: throw Failure.message("Unknown argument: \(arg)")
            }
            i += 1
        }
    }
}
struct CueSettings {
    let choice: SoundChoice
    let duration: Double
    let volume: Float
    let sound: Bool
}
func savePNG(_ image: CGImage, _ path: String) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.message("PNG encoding failed") }
    try data.write(to: URL(fileURLWithPath: path))
}

@MainActor final class Controller: NSObject, NSApplicationDelegate {
    let options: Options
    var window: NSWindow?
    var preview: EffectView?
    var overlays: [OverlayPanel] = []
    var timer: Timer?
    var busy = false
    var sound: GlitchSound?
    var soundEnabled: Bool
    var agentsEnabled: Bool
    var selectedSound: SoundChoice
    var activeSettings: CueSettings?
    var statusLabel: NSTextField?
    var soundDescription: NSTextField?
    var soundSelector: NSPopUpButton?
    var agentsToggle: NSButton?
    var playbackButtons: [NSButton] = []
    var menuItem: NSStatusItem?
    var agentsMenuItem: NSMenuItem?
    var receivedURL = false
    var soundFailure = false
    var lastAgentCueAt: CFTimeInterval?
    var seenRequests = Set<String>()
    var requestOrder: [String] = []
    var approvalRegistry = ApprovalRegistry()
    var approvalTimer: Timer?
    var approvalCountItem: NSMenuItem?
    var approvalDispatchScheduled = false
    var lastApprovalCueAt: CFTimeInterval?
    var approvalPairRunning = false
    var approvalEpisodeKeys = Set<String>()
    var manualSettings: CueSettings { CueSettings(choice: selectedSound, duration: options.duration, volume: options.volume, sound: soundEnabled) }
    var playbackSettings: CueSettings { activeSettings ?? manualSettings }
    var cooldownRemaining: Int {
        guard let lastAgentCueAt else { return 0 }
        return max(0, Int(ceil((5 - (CACurrentMediaTime() - lastAgentCueAt)) * 1000)))
    }

    init(options: Options) {
        self.options = options
        UserDefaults.standard.register(defaults: ["agentsEnabled": true])
        soundEnabled = !options.muted
        agentsEnabled = UserDefaults.standard.bool(forKey: "agentsEnabled")
        selectedSound = options.soundChoice ?? SoundChoice(rawValue: UserDefaults.standard.integer(forKey: "soundChoice")) ?? .classic
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.status { log("screenRecording=\(CGPreflightScreenCaptureAccess()) reducedMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"); NSApp.terminate(nil); return }
        if options.verifySounds {
            do {
                for choice in SoundChoice.allCases {
                    let file = try AVAudioFile(forReading: choice.url())
                    guard file.length == 26460, file.processingFormat.sampleRate == 44100, file.processingFormat.channelCount == 2 else { throw Failure.message("Invalid sound format") }
                    log("SOUND_RESOURCE_OK variant=\(choice.id) frames=\(file.length)")
                }
            } catch { log("ERROR \(error)"); exit(1) }
            NSApp.terminate(nil); return
        }
        if let path = options.renderPath {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                let renderer = try GlitchRenderer(image: fixture())
                for (name, progress) in [("original", 0.0), ("glitch", 0.46), ("settled", 1.0)] {
                    let ctx = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    renderer.draw(ctx, rect: CGRect(x: 0, y: 0, width: 1440, height: 900), progress: progress, intensity: options.intensity)
                    try savePNG(ctx.makeImage()!, path + "/" + name + ".png")
                }
                log("RENDERED synthetic fixtures; no desktop captured")
            } catch { log("ERROR \(error)"); exit(1) }
            NSApp.terminate(nil); return
        }
        setupMenuBar()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processDueApprovals() }
        }
        if !options.agentMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                if let self, !self.receivedURL { self.showTester() }
            }
        }
        log("APP_READY version=0.3.0 agent_mode=\(options.agentMode)")
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        for url in urls { handleRequestURL(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTester(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { approvalTimer?.invalidate(); approvalRegistry.clear(); cleanUp(); sound?.shutDown() }
    func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let imageURL = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"), let image = NSImage(contentsOf: imageURL) {
            image.isTemplate = true; image.size = NSSize(width: 18, height: 18)
            item.button?.image = image; item.button?.setAccessibilityLabel("Glitchrupt")
        } else { item.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Glitchrupt") }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Glitchrupt…", action: #selector(openTester), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let enabled = NSMenuItem(title: "Agent cues enabled", action: #selector(toggleAgentsFromMenu), keyEquivalent: "")
        enabled.target = self; enabled.state = agentsEnabled ? .on : .off
        menu.addItem(enabled); agentsMenuItem = enabled
        menu.addItem(.separator())
        let count = NSMenuItem(title: "Pending approvals: 0", action: nil, keyEquivalent: "")
        menu.addItem(count); approvalCountItem = count
        let pair = NSMenuItem(title: "Preview approval pair (600 + 200 + 600 ms)", action: #selector(previewApprovalPair), keyEquivalent: "")
        pair.target = self; menu.addItem(pair)
        let clear = NSMenuItem(title: "Clear pending approval reminders", action: #selector(clearPendingApprovals), keyEquivalent: "")
        clear.target = self; menu.addItem(clear)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Glitchrupt", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        item.menu = menu; menuItem = item
    }
    @objc func openTester() { showTester() }
    func showTester() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        do {
            let renderer = try GlitchRenderer(image: fixture())
            let height = min(810, (NSScreen.main?.visibleFrame.height ?? 900) - 45)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            win.title = "Glitchrupt — digital attention cues"; win.center(); win.isReleasedWhenClosed = false
            let view = EffectView(frame: NSRect(x: 0, y: 210, width: 960, height: height - 210), renderer: renderer)
            win.contentView!.addSubview(view); preview = view
            func label(_ text: String, _ frame: NSRect, secondary: Bool = false) -> NSTextField {
                let field = NSTextField(labelWithString: text); field.frame = frame
                if secondary { field.textColor = .secondaryLabelColor }
                win.contentView!.addSubview(field); return field
            }
            _ = label("Crackle", NSRect(x: 24, y: 171, width: 95, height: 22))
            let selector = NSPopUpButton(frame: NSRect(x: 130, y: 165, width: 390, height: 32), pullsDown: false)
            for choice in SoundChoice.allCases { selector.addItem(withTitle: choice.title); selector.lastItem?.tag = choice.rawValue }
            selector.target = self; selector.action = #selector(selectSound(_:)); selector.setAccessibilityLabel("Crackle variant")
            win.contentView!.addSubview(selector); soundSelector = selector
            let audioToggle = NSButton(checkboxWithTitle: "Sound enabled", target: self, action: #selector(toggleSound(_:)))
            audioToggle.state = soundEnabled ? .on : .off; audioToggle.frame = NSRect(x: 550, y: 168, width: 165, height: 28)
            win.contentView!.addSubview(audioToggle)
            _ = label("600 ms each", NSRect(x: 795, y: 171, width: 140, height: 22), secondary: true)
            soundDescription = label(selectedSound.detail, NSRect(x: 24, y: 138, width: 910, height: 22), secondary: true)
            let enable = NSButton(checkboxWithTitle: "Allow agent cues", target: self, action: #selector(toggleAgents(_:)))
            enable.state = agentsEnabled ? .on : .off; enable.frame = NSRect(x: 24, y: 100, width: 230, height: 28)
            win.contentView!.addSubview(enable); agentsToggle = enable
            _ = label("At least 5 seconds between agent cues. Manual previews still work while paused.", NSRect(x: 270, y: 104, width: 665, height: 22), secondary: true)
            statusLabel = label("Choose a crackle and play the preview, or compare all five inside this window.", NSRect(x: 24, y: 65, width: 910, height: 22))
            let labels = [("Play preview", #selector(playPreview)), ("Compare all five", #selector(compareAll)), ("Test desktop", #selector(playDesktop)), ("Screen access…", #selector(requestPermission)), ("Quit", #selector(quit))]
            for (i, entry) in labels.enumerated() {
                let button = NSButton(title: entry.0, target: self, action: entry.1)
                button.bezelStyle = .rounded; button.frame = NSRect(x: 24 + i * 186, y: 18, width: 168, height: 34)
                win.contentView!.addSubview(button); if i < 3 { playbackButtons.append(button) }
            }
            showSelection(); window = win; win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            log("TESTER_READY")
        } catch { log("ERROR \(error)") }
    }
    func setBusy(_ value: Bool) { busy = value; soundSelector?.isEnabled = !value; playbackButtons.forEach { $0.isEnabled = !value } }
    func showSelection() { soundSelector?.selectItem(withTag: selectedSound.rawValue); soundDescription?.stringValue = selectedSound.detail }
    @objc func selectSound(_ sender: NSPopUpButton) {
        guard !busy, let choice = SoundChoice(rawValue: sender.selectedTag()) else { showSelection(); return }
        selectedSound = choice; UserDefaults.standard.set(choice.rawValue, forKey: "soundChoice"); showSelection()
        statusLabel?.stringValue = "Selected \(choice.name). Play preview to hear it."
    }
    @objc func toggleSound(_ sender: NSButton) { soundEnabled = sender.state == .on; if !soundEnabled { sound?.shutDown(); sound = nil } }
    @objc func toggleAgents(_ sender: NSButton) { setAgentsEnabled(sender.state == .on) }
    @objc func toggleAgentsFromMenu() { setAgentsEnabled(!agentsEnabled) }
    func setAgentsEnabled(_ value: Bool) {
        agentsEnabled = value; UserDefaults.standard.set(value, forKey: "agentsEnabled")
        agentsToggle?.state = value ? .on : .off; agentsMenuItem?.state = value ? .on : .off
        statusLabel?.stringValue = value ? "Agent cues enabled." : "Agent cues paused. Manual previews remain available."
    }
    @objc func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        statusLabel?.stringValue = "Enable Glitchrupt in macOS Screen Recording settings, then reopen if requested."
    }
    @objc func quit() { cleanUp(); NSApp.terminate(nil) }
    @objc func playPreview() {
        _ = executeCue(settings: manualSettings, previewOnly: true, delay: 0) { [weak self] result in
            self?.statusLabel?.stringValue = result["status"] as? String == "completed" ? "Preview complete · \(self?.selectedSound.name ?? "") · 600 ms" : "Preview could not complete."
        }
    }
    @objc func playDesktop() {
        _ = executeCue(settings: manualSettings, previewOnly: false, delay: 3) { [weak self] result in
            self?.statusLabel?.stringValue = result["status"] as? String == "completed" ? "Desktop cue complete. All overlays removed." : "Desktop cue needs access or is unavailable."
        }
    }
    @objc func compareAll() {
        guard !busy else { return }
        setBusy(true); let original = selectedSound
        Task { @MainActor in
            for choice in SoundChoice.allCases {
                selectedSound = choice; showSelection()
                statusLabel?.stringValue = "Comparing \(choice.title) · 600 ms"
                prepareSound()
                if let preview {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        animate(views: [preview]) { [weak self] in self?.finishSound(); continuation.resume() }
                    }
                }
                log("COMPARE_OPTION_COMPLETE variant=\(choice.id)")
                if choice != .stutter { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
            selectedSound = original; showSelection(); setBusy(false)
            statusLabel?.stringValue = "All five complete. Choose your favorite crackle."
            log("COMPARE_COMPLETE count=5")
        }
    }
    func prepareSound() {
        soundFailure = false
        let settings = playbackSettings
        guard settings.sound, sound == nil else { return }
        do { sound = try GlitchSound(choice: settings.choice, duration: settings.duration, volume: settings.volume) }
        catch { soundFailure = true; log("SOUND_UNAVAILABLE") }
    }
    func finishSound() {
        guard let previous = sound else { return }; sound = nil
        let tail = max(0.1, previous.engine.outputNode.presentationLatency + 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { previous.shutDown() }
    }
    func cleanUp() { timer?.invalidate(); timer = nil; for panel in overlays { panel.orderOut(nil); panel.close() }; overlays.removeAll() }
    @discardableResult func executeCue(settings: CueSettings, previewOnly: Bool, delay: Double, pair: Bool = false, shouldContinue: @escaping @MainActor () -> Bool = { true }, completion: @escaping @MainActor ([String: Any]) -> Void) -> Bool {
        let base: [String: Any] = ["variant": settings.choice.id, "duration_ms": Int(settings.duration * 1000), "mode": previewOnly ? "preview" : "desktop"]
        func reject(_ status: String) { var result = base; result["status"] = status; completion(result) }
        guard !busy else { reject("busy"); return false }
        if !previewOnly {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { reject("reduce_motion"); return false }
            guard CGPreflightScreenCaptureAccess() else { reject("permission_required"); return false }
        }
        if previewOnly { showTester() }
        setBusy(true); activeSettings = settings; prepareSound()
        statusLabel?.stringValue = delay > 0 ? "Starting a desktop cue in 3 seconds…" : "Playing \(settings.choice.name)…"
        Task { @MainActor in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                var burstsCompleted = 0
                if previewOnly {
                    guard let preview else { throw Failure.message("Preview unavailable") }
                    var firstStartedAt = CACurrentMediaTime(); var firstEndedAt = firstStartedAt
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        animate(views: [preview], onStart: { firstStartedAt = $0 }) { firstEndedAt = CACurrentMediaTime(); continuation.resume() }
                    }; burstsCompleted = 1
                    if pair {
                        if try await playSecondApprovalBurst(views: [preview], firstStartedAt: firstStartedAt, firstEndedAt: firstEndedAt, previewOnly: true, shouldContinue: shouldContinue) { burstsCompleted = 2 }
                    }
                } else { burstsCompleted = try await captureAndPlay(pair: pair, shouldContinue: shouldContinue) }
                let audioPlayed = settings.sound && !soundFailure
                cleanUp(); finishSound(); activeSettings = nil; setBusy(false)
                var result = base; result["status"] = pair && burstsCompleted < 2 ? "cancelled" : "completed"; result["sound"] = audioPlayed
                if pair { result["bursts_completed"] = burstsCompleted; result["gap_ms"] = 200 }
                if soundFailure { result["warning"] = "Audio unavailable; visual cue completed" }
                statusLabel?.stringValue = "Cue complete · \(settings.choice.name) · \(Int(settings.duration * 1000)) ms"
                completion(result); log("CUE_COMPLETE mode=\(previewOnly ? "preview" : "desktop") variant=\(settings.choice.id) overlays=0")
            } catch {
                cleanUp(); sound?.shutDown(); sound = nil; activeSettings = nil; setBusy(false)
                var result = base; result["status"] = "error"; result["error"] = "Capture or rendering failed"; completion(result)
                log("CUE_FAILED")
            }
        }
        return true
    }
    func captureAndPlay(pair: Bool = false, shouldContinue: @escaping @MainActor () -> Bool = { true }) async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var ready: [(NSScreen, GlitchRenderer)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let config = SCStreamConfiguration(); let scale = min(1.0, 1920.0 / Double(display.width))
            config.width = max(1, Int(Double(display.width) * scale)); config.height = max(1, Int(Double(display.height) * scale)); config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            ready.append((screen, try GlitchRenderer(image: image)))
        }
        guard !ready.isEmpty else { throw Failure.message("No capturable displays") }
        if pair && (!shouldContinue() || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { return 0 }
        var views: [EffectView] = []
        for (screen, renderer) in ready {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true; panel.isOpaque = true; panel.hasShadow = false; panel.isReleasedWhenClosed = false
            let view = EffectView(frame: NSRect(origin: .zero, size: screen.frame.size), renderer: renderer)
            panel.contentView = view; overlays.append(panel); views.append(view); panel.orderFrontRegardless()
        }
        log("DESKTOP_START displays=\(views.count) click_through=true")
        var firstStartedAt = CACurrentMediaTime(); var firstEndedAt = firstStartedAt
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animate(views: views, onStart: { firstStartedAt = $0 }) { firstEndedAt = CACurrentMediaTime(); continuation.resume() }
        }
        if pair {
            if try await playSecondApprovalBurst(views: views, firstStartedAt: firstStartedAt, firstEndedAt: firstEndedAt, previewOnly: false, shouldContinue: shouldContinue) { return 2 }
        }
        return 1
    }
    func playSecondApprovalBurst(views: [EffectView], firstStartedAt: CFTimeInterval, firstEndedAt: CFTimeInterval, previewOnly: Bool, shouldContinue: @escaping @MainActor () -> Bool) async throws -> Bool {
        finishSound()
        if !previewOnly { for panel in overlays { panel.orderOut(nil) } }
        // Restore the screen and prepare audio inside the gap, then wait only its remainder.
        // The deadline is anchored to burst one's completion, never to audio setup completion.
        for view in views { view.progress = 0; view.needsDisplay = true; view.displayIfNeeded() }
        guard shouldContinue(), previewOnly || !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        prepareSound()
        let remaining = firstEndedAt + 0.2 - CACurrentMediaTime()
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        guard shouldContinue(), previewOnly || !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        if !previewOnly { for panel in overlays { panel.orderFrontRegardless() } }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animate(views: views, onStart: { started in
                let elapsed = (started - firstEndedAt) * 1000
                log("PAIR_GAP elapsed_ms=\(Int(elapsed.rounded())) target_ms=200 slip_ms=\(max(0, Int((elapsed - 200).rounded())))")
            }) { continuation.resume() }
        }
        log("PAIR_DURATION elapsed_ms=\(Int(((CACurrentMediaTime() - firstStartedAt) * 1000).rounded())) target_ms=1400")
        return true
    }
    func animate(views: [EffectView], onStart: (@MainActor (CFTimeInterval) -> Void)? = nil, completion: @escaping @MainActor () -> Void) {
        let settings = playbackSettings
        if settings.sound { sound?.play() }
        let start = CACurrentMediaTime(); onStart?(start); var frames = 0; var finished = false
        let finish: @MainActor () -> Void = { [weak self] in
            guard !finished else { return }; finished = true; self?.timer?.invalidate(); self?.timer = nil
            log("ANIMATION frames=\(frames) elapsed_ms=\(Int(((CACurrentMediaTime() - start) * 1000).rounded())) target_ms=\(Int(settings.duration * 1000))")
            completion()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] clock in
            MainActor.assumeIsolated {
                guard self != nil else { clock.invalidate(); return }
                let progress = min(1, (CACurrentMediaTime() - start) / settings.duration)
                for view in views { view.progress = progress; view.needsDisplay = true; view.displayIfNeeded() }; frames += 1
                if progress >= 1 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.duration + 0.75) { [weak self] in
            guard !finished else { return }; self?.cleanUp(); log("WATCHDOG_REMOVED_OVERLAY"); finish()
        }
    }
}

@main struct GlitchruptApp {
    @MainActor static func main() {
        let options: Options
        do { options = try Options(Array(CommandLine.arguments.dropFirst())) }
        catch { log("ERROR \(error)"); exit(64) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let controller = Controller(options: options); app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
