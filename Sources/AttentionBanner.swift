import AppKit

/// Choices in the banner's Mute control. `request` carries the key of the request the banner shows.
enum AttentionMuteAction {
    case request(String)
    case allAgentCuesForOneHour
    case pauseAgentCues
}

/// Passive local UI. Text is caller-supplied, bounded, and never persisted or logged.
@MainActor final class AttentionBanner {
    private var panel: NSPanel?
    private var expiry: Timer?
    private var entries: [ApprovalRegistry.Entry] = []
    private var openRequest: ((String) -> Void)?
    private var muteRequest: ((AttentionMuteAction) -> Void)?
    private var hovered = false
    var isVisible: Bool { panel?.isVisible == true }

    func show(entries: [ApprovalRegistry.Entry], open: @escaping (String) -> Void, mute: @escaping (AttentionMuteAction) -> Void) {
        guard !entries.isEmpty else { dismiss(); return }
        self.entries = entries; openRequest = open; muteRequest = mute
        render()
        if let panel {
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 18, y: area.maxY - panel.frame.height - 18))
            }
            panel.orderFrontRegardless()
        }
        scheduleExpiry()
    }
    func update(entries: [ApprovalRegistry.Entry]) {
        guard isVisible else { return }
        guard !entries.isEmpty else { dismiss(); return }
        self.entries = entries; render()
    }
    func dismiss() { expiry?.invalidate(); expiry = nil; panel?.orderOut(nil); entries = []; hovered = false }
    private func scheduleExpiry() {
        expiry?.invalidate()
        guard !hovered else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }
    private func render() {
        guard let entry = entries.first else { return }
        let window = panel ?? BannerPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        let content = BannerSurface(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        content.material = .hudWindow; content.blendingMode = .withinWindow; content.state = .active
        content.wantsLayer = true; content.layer?.cornerRadius = 16; content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1; content.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.6).cgColor
        content.onHover = { [weak self] inside in self?.hovered = inside; self?.scheduleExpiry() }
        func label(_ text: String, _ frame: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.maximumNumberOfLines = frame.height > 30 ? 2 : 1
            field.lineBreakMode = .byTruncatingTail; content.addSubview(field)
        }
        label("ϟ  GLITCHRUPT · INPUT NEEDED", NSRect(x: 18, y: 148, width: 345, height: 18), size: 10, weight: .bold, secondary: true)
        label(entry.context.chatName ?? "An agent needs your input", NSRect(x: 18, y: 115, width: 375, height: 27), size: 18, weight: .semibold)
        label(entry.context.reason ?? "The caller did not include a description. View the request for its key.", NSRect(x: 18, y: 62, width: 380, height: 44), size: 13)
        // Preview banners have no Mute control, so their footer keeps the full width.
        let isPreview = entry.alertStatus == "preview"
        let footer = entries.count > 1 ? "\(entries.count) requests · more in menu bar" : "Stays in menu bar until resolved"
        label(footer, NSRect(x: 18, y: 20, width: isPreview ? 245 : 184, height: 18), size: 10, secondary: true)
        let button = NSButton(title: isPreview ? "Got it" : (entry.context.chatID == nil && entry.context.claudeSessionID == nil ? "View request" : "Open chat"), target: self, action: #selector(openFirst))
        button.frame = NSRect(x: 300, y: 14, width: 103, height: 32); button.bezelStyle = .rounded
        button.setAccessibilityLabel(entry.context.chatID == nil && entry.context.claudeSessionID == nil ? "View pending request" : "Open requesting chat")
        content.addSubview(button)
        if !isPreview {
            // Pull-down: the first item is the button title; the rest are the choices.
            let mute = NSPopUpButton(frame: NSRect(x: 210, y: 14, width: 84, height: 32), pullsDown: true)
            mute.bezelStyle = .rounded
            mute.addItem(withTitle: "Mute")
            let choices: [(String, Selector)] = [("Mute this request", #selector(muteThisRequest)),
                                                 ("Mute all for 1 hour", #selector(muteAllForOneHour)),
                                                 ("Pause all agent cues", #selector(pauseAgentCues))]
            for (title, action) in choices {
                mute.addItem(withTitle: title)
                mute.lastItem?.target = self; mute.lastItem?.action = action
            }
            mute.setAccessibilityLabel("Mute options for the pending request")
            content.addSubview(mute)
        }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss banner")!, target: self, action: #selector(closeBanner))
        close.frame = NSRect(x: 383, y: 144, width: 22, height: 22); close.isBordered = false
        close.setAccessibilityLabel("Dismiss banner; keep request pending"); content.addSubview(close)
        window.contentView = content; panel = window
    }
    @objc private func openFirst() { guard let key = entries.first?.key else { return }; openRequest?(key); dismiss() }
    @objc private func muteThisRequest() {
        guard let key = entries.first?.key else { return }
        dismiss(); muteRequest?(.request(key))
    }
    @objc private func muteAllForOneHour() { dismiss(); muteRequest?(.allAgentCuesForOneHour) }
    @objc private func pauseAgentCues() { dismiss(); muteRequest?(.pauseAgentCues) }
    @objc private func closeBanner() { dismiss() }
}

private final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor private final class BannerSurface: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
