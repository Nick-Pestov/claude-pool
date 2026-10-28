// PoolBar: the M5 and the M1 in the menu bar (CPU share of each Mac's capacity, suggested moves), a menu with every
// Claude session on both Macs, and a popup on the Mac you're using when a session should move. Clicking the popup
// moves the session the way /change-computer does (`pool tab`): its window stays, the conversation resumes on the
// other Mac. The numbers and decisions come from `pool top --agent` (~/.local/bin/pool-top); this only draws them.
//
// Build: ~/.local/share/poolbar/build.sh (installs ~/Applications/PoolBar.app).
// Preview a card without touching the menu bar: open -n --env POOLBAR_DEMO=<seconds> ~/Applications/PoolBar.app

import AppKit
import ServiceManagement

let home = NSHomeDirectory()
let poolTop = home + "/.local/bin/pool-top"
let logPath = home + "/.local/state/pool/poolbar.log"
let shellEnv: [String: String] = {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = home
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    return env
}()
// The monitor's colours for the two Macs (categorical slots 1 and 2).
let macColor: [String: NSColor] = [
    "M5": NSColor(srgbRed: 0x39 / 255.0, green: 0x87 / 255.0, blue: 0xE5 / 255.0, alpha: 1),
    "M1": NSColor(srgbRed: 0xD9 / 255.0, green: 0x59 / 255.0, blue: 0x26 / 255.0, alpha: 1),
]

/// Runs `pool-top <args>` off the main thread and reports (succeeded, output) on it.
func poolTopRun(_ args: [String], _ done: ((Bool, String) -> Void)? = nil) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", poolTop] + args
        p.environment = shellEnv
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            DispatchQueue.main.async { done?(false, "\(error)") }
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { done?(p.terminationStatus == 0, text) }
    }
}

/// `pool top --agent`, restarted if it stops: one JSON line of state every two seconds.
final class Agent {
    private var process: Process?
    private var buffer = Data()
    private let onState: ([String: Any]) -> Void

    init(onState: @escaping ([String: Any]) -> Void) { self.onState = onState }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", poolTop, "--agent"]
        p.environment = shellEnv
        let out = Pipe()
        p.standardOutput = out
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let err = FileHandle(forWritingAtPath: logPath)
        err?.seekToEndOfFile()
        p.standardError = err ?? FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { DispatchQueue.main.async { self?.consume(d) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.start() }
        }
        do { try p.run(); process = p } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.start() }
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onState(obj) }
        }
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}

    convenience init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.state = checked ? .on : .off
    }

    @objc func fire() { handler() }
}

/// A view that reliably fires on a single click even though PoolBar is never the active app and the card is a
/// non-activating panel (where NSButton's target/action can swallow the first click). It tracks the mouse itself and
/// fires on mouse-up inside its bounds.
class Tap: NSView {
    var onTap: () -> Void = {}
    private var inside = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { inside = true }
    override func mouseDragged(with event: NSEvent) { inside = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        if inside && bounds.contains(convert(event.locationInWindow, from: nil)) { onTap() }
        inside = false
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A Tap that looks like a push button: a rounded fill with a centred label.
final class TapButton: Tap {
    init(_ title: String, accent: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = (accent ? NSColor.controlAccentColor : NSColor(white: 0.5, alpha: 0.22)).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: accent ? .semibold : .regular)
        label.textColor = accent ? .white : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: label.widthAnchor, constant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The card's text block. It is not a button: only the explicit Move / Not now / ✕ controls act, so a stray click on
/// the card never moves anything.
final class ClickArea: NSView {}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A notification-style card in the top-right corner of the screen the pointer is on. With buttons it asks; without
/// them it just reports progress.
final class Popup: NSObject {
    let key: String
    var moving = false
    private let panel: PopupPanel
    private let body: NSTextField
    private let buttons: NSStackView
    private let asks: Bool          // has Move / Not now (a suggestion), as opposed to a progress card
    private let closeButton: Tap
    private var timer: Timer?
    private let onMove: (Popup) -> Void
    private let onLater: (Popup) -> Void
    private let onTimeout: (Popup) -> Void

    init(key: String, title: String, name: String, text: String, button: String?, mac: String,
         onMove: @escaping (Popup) -> Void = { _ in }, onLater: @escaping (Popup) -> Void = { _ in },
         onTimeout: @escaping (Popup) -> Void = { _ in }) {
        self.key = key
        self.onMove = onMove
        self.onLater = onLater
        self.onTimeout = onTimeout
        let width: CGFloat = 360
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = macColor[mac] ?? .controlAccentColor
        dot.font = .systemFont(ofSize: 11)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [dot, titleLabel])
        header.spacing = 6
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - 28
        body.maximumNumberOfLines = 10
        let texts = NSStackView(views: [nameLabel, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let click = ClickArea()
        texts.translatesAutoresizingMaskIntoConstraints = false
        click.addSubview(texts)
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: click.leadingAnchor),
            texts.trailingAnchor.constraint(equalTo: click.trailingAnchor),
            texts.topAnchor.constraint(equalTo: click.topAnchor),
            texts.bottomAnchor.constraint(equalTo: click.bottomAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: width - 28),
        ])
        buttons = NSStackView()
        buttons.spacing = 8
        let outer = NSStackView(views: [header, click, buttons])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        outer.translatesAutoresizingMaskIntoConstraints = false
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.addSubview(outer)
        // ✕ in the card's top-right corner, like a notification's close button (a Tap, so the click always lands)
        closeButton = Tap()
        closeButton.toolTip = button == nil ? "Close" : "Dismiss for now"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let xcfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .secondaryLabelColor]))
        let xview = NSImageView(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(xcfg) ?? NSImage())
        xview.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addSubview(xview)
        effect.addSubview(closeButton)
        asks = button != nil
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: effect.topAnchor, constant: 7),
            closeButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -7),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            closeButton.subviews[0].centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeButton.subviews[0].centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: width - 28 - 24),
            outer.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            outer.topAnchor.constraint(equalTo: effect.topAnchor),
            outer.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            outer.widthAnchor.constraint(equalToConstant: width),
            click.widthAnchor.constraint(equalToConstant: width - 28),
            buttons.widthAnchor.constraint(equalToConstant: width - 28),
        ])
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        super.init()
        closeButton.onTap = { [weak self] in self?.closeClicked() }
        if let button = button {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let later = TapButton("Not now", accent: false)
            later.onTap = { [weak self] in self?.laterClicked() }
            let move = TapButton(button, accent: true)
            move.onTap = { [weak self] in self?.moveClicked() }
            for v in [spacer, later, move] { buttons.addArrangedSubview(v) }
        } else {
            buttons.isHidden = true
        }
    }

    func show(timeout: TimeInterval?) {
        resize()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        if let t = timeout {
            timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                if let s = self, !s.moving { s.onTimeout(s) }
            }
        }
    }

    /// Replace the text with progress or a result; closeAfter closes the card that many seconds later.
    func setStatus(_ text: String, closeAfter: TimeInterval? = nil) {
        guard !closed else { return }   // already gone (✕, or finished early): a late result doesn't bring it back
        body.stringValue = text
        buttons.isHidden = true
        resize()
        timer?.invalidate()
        if let t = closeAfter {
            timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.close() }
        }
    }

    private(set) var closed = false

    func close() {
        closed = true
        timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }

    private func resize() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
    }

    @objc private func moveClicked() { if !moving { onMove(self) } }
    @objc private func laterClicked() { onLater(self) }

    /// ✕: a suggestion is dismissed for now (the same short snooze as letting it time out); a progress card just
    /// closes while its move or close carries on.
    @objc private func closeClicked() {
        if asks && !moving { onTimeout(self) } else { close() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var agent: Agent!
    private var state: [String: Any] = [:]
    private var popup: Popup?
    private var handled: [String: Date] = [:]   // popups answered here, not shown again while the agent catches up
    private var cableCard: Popup?               // "Moving connections to the cable", closed once the link is all green

    private var popupsOn: Bool {
        get { UserDefaults.standard.object(forKey: "popups") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "popups") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let demo = ProcessInfo.processInfo.environment["POOLBAR_DEMO"] {   // preview a card, then quit
            let secs = Double(demo) ?? 20
            if ProcessInfo.processInfo.environment["POOLBAR_DEMO_KIND"] == "progress" {   // a card reporting progress
                let p = Popup(key: "demo", title: "Moving connections to the cable", name: "Thunderbolt cable", text: "",
                              button: nil, mac: "")
                p.show(timeout: nil)
                p.setStatus("Working on it…")
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
                return
            }
            let p = Popup(key: "demo", title: "Close what nobody is using? (M1)", name: "Preview: 2 idle things holding 450 MB",
                          text: "• [Build] - Verifying a deploy (M1): idle 1d, 321 MB\n"
                              + "• node apiserver.cjs, chrome-headless-shell (M1): no session, running 1d, 133 MB\n"
                              + "Conversations are kept. service's own processes are never closed.",
                          button: "Close them", mac: "M1", onMove: { $0.close() }, onLater: { $0.close() },
                          onTimeout: { $0.close() })
            p.show(timeout: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PoolBar"   // keeps the place you ⌘-drag it to
        item.button?.title = "pool …"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        agent = Agent { [weak self] s in self?.update(s) }
        agent.start()
    }

    func applicationWillTerminate(_ notification: Notification) { agent.stop() }

    private func update(_ s: [String: Any]) {
        state = s
        item.button?.title = ""
        item.button?.image = statusImage(s)
        item.button?.imagePosition = .imageOnly
        let link = (s["link"] as? [String: Any])?["text"] as? String
        item.button?.toolTip = (((s["macs"] as? [String]) ?? []) + (link.map { [$0] } ?? [])).joined(separator: "\n")
        handlePopup(s)
        if let card = cableCard, (s["link"] as? [String: Any])?["state"] as? String == "cable" {
            let speed = (s["link"] as? [String: Any])?["speed"] as? String
            card.setStatus("Everything is on the cable" + (speed.map { " · \($0)" } ?? "") + ".", closeAfter: 1.2)
            cableCard = nil
        }
    }

    /// One solid capsule per Mac in its colour, white text on it: the Mac, CPU (share of its capacity) and memory
    /// (share of its RAM in use), each after its symbol. A value past its limit turns into a white chip. A last
    /// capsule counts the suggested moves: red when one is pressing, grey for tidy-ups.
    private func statusImage(_ s: [String: Any]) -> NSImage {
        struct Part { let text: String; let symbol: String?; let hot: Bool; var dark = false }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let height: CGFloat = 18, pad: CGFloat = 7, gap: CGFloat = 5, icon: CGFloat = 12
        func pct(_ v: Any?) -> String {
            guard let n = v as? Int else { return "–" }
            return (n < 10 ? "\u{2007}" : "") + "\(n)%"   // a figure space keeps the width steady below 10%
        }
        var pills: [(fill: NSColor, parts: [Part])] = []
        for m in (s["title"] as? [[String: Any]]) ?? [] {
            let label = m["label"] as? String ?? "?"
            let fill = macColor[label] ?? .gray
            if m["pct"] is NSNull || m["pct"] == nil {
                pills.append((fill.withAlphaComponent(0.55), [Part(text: label, symbol: nil, hot: false),
                                                               Part(text: "away", symbol: nil, hot: false)]))
                continue
            }
            pills.append((fill, [Part(text: label, symbol: nil, hot: false),
                                 Part(text: pct(m["pct"]), symbol: "cpu.fill", hot: m["cpuHot"] as? Bool ?? false),
                                 Part(text: pct(m["mem"]), symbol: "memorychip.fill", hot: m["memHot"] as? Bool ?? false)]))
        }
        // Between the two Macs' capsules, the link joining them and how fast it is: green bolt and the round trip on the
        // Thunderbolt cable, yellow while connections move onto it, grey Wi-Fi and its round trip without it.
        if pills.count == 2, let link = s["link"] as? [String: Any], let state = link["state"] as? String {
            var speed = link["speed"] as? String ?? "–"
            while speed.count < 6 { speed = "\u{2007}" + speed }   // figure spaces keep the width steady
            let fill: NSColor = state == "cable" ? .systemGreen : state == "moving" ? .systemYellow : NSColor(white: 0.42, alpha: 1)
            pills.insert((fill, [Part(text: speed, symbol: state == "wifi" ? "wifi" : "bolt.fill", hot: false,
                                      dark: state == "moving")]), at: 1)
        }
        if pills.isEmpty { pills.append((.gray, [Part(text: "pool", symbol: nil, hot: false)])) }
        let count = s["count"] as? Int ?? 0
        if count > 0 {
            let urgent = (s["alert"] as? Int ?? 0) > 0
            pills.append((urgent ? .systemRed : NSColor(white: 0.36, alpha: 1),
                          [Part(text: "\(count)", symbol: "arrow.left.arrow.right", hot: false)]))
        }
        func symbol(_ name: String, _ color: NSColor) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)   // older systems lack some symbols
            return img?.withSymbolConfiguration(cfg)
        }
        func width(_ p: Part) -> CGFloat {
            let text = (p.text as NSString).size(withAttributes: [.font: font]).width
            return text + (p.symbol != nil ? icon + 3 : 0) + (p.hot ? 8 : 0)
        }
        let widths = pills.map { pill in pad * 2 + pill.parts.map(width).reduce(0, +) + gap * CGFloat(pill.parts.count - 1) }
        let total = widths.reduce(0, +) + 4 * CGFloat(pills.count - 1)
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (pill, w) in zip(pills, widths) {
                pill.fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: w, height: height),
                             xRadius: height / 2, yRadius: height / 2).fill()
                var cx = x + pad
                for part in pill.parts {
                    let pw = width(part)
                    let ink = part.hot ? pill.fill : part.dark ? NSColor.black.withAlphaComponent(0.8) : NSColor.white
                    if part.hot {
                        NSColor.white.setFill()
                        NSBezierPath(roundedRect: NSRect(x: cx - 1, y: 2.5, width: pw + 2, height: height - 5),
                                     xRadius: (height - 5) / 2, yRadius: (height - 5) / 2).fill()
                        cx += 4
                    }
                    if let name = part.symbol, let img = symbol(name, ink) {
                        let scale = min(icon / img.size.width, icon / img.size.height)
                        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
                        img.draw(in: NSRect(x: cx + (icon - size.width) / 2, y: (height - size.height) / 2,
                                            width: size.width, height: size.height))
                        cx += icon + 3
                    }
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                    let ts = (part.text as NSString).size(withAttributes: attrs)
                    (part.text as NSString).draw(at: NSPoint(x: cx, y: (height - ts.height) / 2 + 0.5), withAttributes: attrs)
                    cx += ts.width + (part.hot ? 4 : 0) + gap
                }
                x += w + 4
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// How the Macs are linked, as a round badge for the menu: green lightning bolt (Thunderbolt) (everything on the cable), yellow bolt (cable
    /// plugged in, connections still moving off Wi-Fi), grey Wi-Fi. Nil while one Mac hasn't reported (out of reach).
    private func linkBadge(_ s: [String: Any], size: CGFloat) -> NSImage? {
        guard let state = (s["link"] as? [String: Any])?["state"] as? String else { return nil }
        let (name, glyph, disc): (String, NSColor, NSColor) =
            state == "cable" ? ("bolt.circle.fill", .white, .systemGreen)
            : state == "moving" ? ("bolt.circle.fill", NSColor.black.withAlphaComponent(0.75), .systemYellow)
            : ("wifi.circle.fill", .white, NSColor(white: 0.42, alpha: 1))
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .heavy)   // heavy reads at 1x; lighter weights blur
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyph, disc]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let w = symbol.size.width * scale, h = symbol.size.height * scale
            symbol.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
        image.isTemplate = false
        return image
    }

    // popups

    private func handlePopup(_ s: [String: Any]) {
        let live = Set((s["live"] as? [String]) ?? [])
        if let p = popup, !p.moving, !live.contains(p.key) {   // dealt with elsewhere, or no longer needed
            p.close()
            popup = nil
        }
        handled = handled.filter { $0.value.timeIntervalSinceNow > -600 }
        guard popupsOn, popup == nil, let pop = s["popup"] as? [String: Any], let key = pop["key"] as? String,
              handled[key] == nil, let args = pop["args"] as? [String] else { return }
        let later = pop["later"] as? [String] ?? []
        let timeout = pop["timeout"] as? [String] ?? []
        let p = Popup(key: key, title: pop["title"] as? String ?? "pool",
                      name: pop["name"] as? String ?? "", text: pop["body"] as? String ?? "",
                      button: pop["button"] as? String ?? "OK", mac: pop["mac"] as? String ?? "",
                      onMove: { [weak self] p in self?.runMove(args, in: p) },
                      onLater: { [weak self] p in
                          if !later.isEmpty { poolTopRun(later) }
                          self?.finish(p)
                      },
                      onTimeout: { [weak self] p in
                          if !timeout.isEmpty { poolTopRun(timeout) }
                          self?.finish(p)
                      })
        popup = p
        p.show(timeout: 180)
    }

    private func finish(_ p: Popup) {
        handled[p.key] = Date()
        p.close()
        if popup === p { popup = nil }
    }

    /// Runs a popup's or menu item's action (a move, closing idle things, restarting service) and reports in the card.
    private func runMove(_ args: [String], in p: Popup) {
        p.moving = true
        handled[p.key] = Date()
        let verb = args.first ?? ""
        p.setStatus(verb == "--move" ? "Moving it… the window stays where it is and reconnects in a few seconds."
                    : verb == "--close" ? "Closing…" : "Working on it…")
        poolTopRun(args) { [weak self] ok, out in
            let first = out.split(separator: "\n").last.map(String.init) ?? ""
            p.setStatus(ok ? (first.isEmpty ? "Done." : first.replacingOccurrences(of: "pool: ", with: ""))
                           : "That didn't work: \(first.isEmpty ? "unknown error" : first)", closeAfter: ok ? 6 : 15)
            p.moving = false
            if self?.popup === p { self?.popup = nil }
        }
    }

    /// A move picked from the menu: no question first (the click was the decision), just a card that reports it.
    private func moveFromMenu(_ args: [String], name: String, dst: String) {
        runFromMenu(args, title: "Moving a Claude session to the \(dst)", name: name, mac: dst)
    }

    @discardableResult
    private func runFromMenu(_ args: [String], title: String, name: String, mac: String) -> Popup {
        let p = Popup(key: "menu-\(UUID().uuidString)", title: title, name: name, text: "", button: nil, mac: mac)
        p.show(timeout: nil)
        runMove(args, in: p)
        return p
    }

    // the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state
        let macs = (s["macs"] as? [String]) ?? ["Waiting for numbers from both Macs…"]
        for line in macs { menu.addItem(info(line)) }
        if let link = s["link"] as? [String: Any], let text = link["text"] as? String {
            let it: NSMenuItem
            if link["state"] as? String == "moving" {
                it = ActionItem("\(text): move them now") { [weak self] in
                    self?.cableCard = self?.runFromMenu(["--route-fix"], title: "Moving connections to the cable",
                                                        name: "Thunderbolt cable", mac: "")
                }
            } else {
                it = info(text)
            }
            it.image = linkBadge(s, size: 16)
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let recs = (s["recs"] as? [[String: Any]]) ?? []
        menu.addItem(info(recs.isEmpty ? "No moves suggested" : "Suggested moves", bold: true))
        for r in recs {
            guard let args = r["args"] as? [String] else { continue }
            let level = r["level"] as? Int ?? 2
            let text = r["text"] as? String ?? "Move"
            let busy = r["busy"] as? Bool ?? false
            let dst = text.hasSuffix("M1") ? "M1" : "M5"
            let it = ActionItem((level == 0 ? "! " : level == 1 ? "▲ " : "") + text + (busy ? "  (busy: cuts off its turn)" : "")) {
                [weak self] in self?.moveFromMenu(args, name: text, dst: dst)
            }
            it.toolTip = r["why"] as? String
            if #available(macOS 14.4, *) { it.subtitle = r["why"] as? String }
            menu.addItem(it)
        }
        for w in (s["warnings"] as? [String]) ?? [] {
            let it = info("!! " + w)
            if #available(macOS 14.4, *) { it.title = w.contains("runs 2 times") ? "!! Duplicate session" : "!! Note"; it.subtitle = w }
            menu.addItem(it)
        }
        if let b = s["service"] as? [String: Any], let text = b["text"] as? String {
            if b["up"] as? Bool ?? true {
                menu.addItem(info("● " + text))
            } else {
                menu.addItem(ActionItem("!! \(text): restart it") { [weak self] in
                    self?.runFromMenu(["--service-restart"], title: "Restarting service", name: "service", mac: "M1")
                })
            }
        }
        menu.addItem(.separator())
        let idle = (s["idle"] as? [[String: Any]]) ?? []
        menu.addItem(info(idle.isEmpty ? "Nothing idle to close" : "Idle, nobody using it (\(idle.count))", bold: true))
        for i in idle {
            guard let args = i["args"] as? [String] else { continue }
            let text = i["text"] as? String ?? "Close"
            let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            if #available(macOS 14.4, *) { it.subtitle = i["detail"] as? String }
            it.toolTip = i["detail"] as? String
            let sub = NSMenu()
            sub.addItem(ActionItem("Close it") { [weak self] in
                self?.runFromMenu(args, title: "Closing", name: text, mac: "")
            })
            if let keep = i["keep"] as? [String] { sub.addItem(ActionItem("Keep it, ask again tomorrow") { poolTopRun(keep) }) }
            if let keep = i["keepWeek"] as? [String] { sub.addItem(ActionItem("Keep it for a week") { poolTopRun(keep) }) }
            it.submenu = sub
            menu.addItem(it)
        }
        if idle.count > 1, let all = s["closeAll"] as? [String] {
            menu.addItem(ActionItem("Close all \(idle.count)") { [weak self] in
                self?.runFromMenu(all, title: "Closing idle things", name: "\(idle.count) idle things", mac: "")
            })
        }
        menu.addItem(.separator())
        let sessions = (s["sessions"] as? [String: [[String: Any]]]) ?? [:]
        for mac in ["M5", "M1"] {
            let rows = sessions[mac] ?? []
            let parent = NSMenuItem(title: "Sessions on the \(mac) (\(rows.count))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let pinned = rows.filter { $0["pinned"] as? Bool ?? false }
            for row in rows where !(row["pinned"] as? Bool ?? false) { sub.addItem(sessionItem(row, mac: mac)) }
            if !pinned.isEmpty {
                if sub.numberOfItems > 0 { sub.addItem(.separator()) }
                let group = NSMenuItem(title: "service + pinned work, pinned to the M1 (\(pinned.count))", action: nil, keyEquivalent: "")
                let gsub = NSMenu()
                for row in pinned { gsub.addItem(info(row["text"] as? String ?? "")) }
                group.submenu = gsub
                sub.addItem(group)
            }
            if rows.isEmpty { sub.addItem(info("none")) }
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open the monitor (pool top)") { poolTopRun(["--window"]) })
        menu.addItem(ActionItem("Show popups for suggested moves", checked: popupsOn) { [weak self] in
            self?.popupsOn.toggle()
            if !(self?.popupsOn ?? true) { self?.popup?.close(); self?.popup = nil }
        })
        menu.addItem(ActionItem("Open at login", checked: SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                let p = Popup(key: "login", title: "PoolBar", name: "Couldn't change Open at login",
                              text: "\(error.localizedDescription) Add PoolBar in System Settings > General > Login Items instead.",
                              button: nil, mac: "M5")
                p.show(timeout: nil)
                p.setStatus("\(error.localizedDescription) Add PoolBar in System Settings > General > Login Items instead.", closeAfter: 12)
            }
        })
        menu.addItem(ActionItem("Quit PoolBar") { NSApp.terminate(nil) })
    }

    private func sessionItem(_ row: [String: Any], mac: String) -> NSMenuItem {
        let text = row["text"] as? String ?? ""
        let sid = row["sid"] as? String ?? ""
        let suggested = row["suggested"] as? Bool ?? false
        let dstMac = mac == "M5" ? "M1" : "M5"
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if suggested {   // the session a move is suggested for: bold, with a → badge in the destination Mac's colour
            it.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, macColor[dstMac] ?? .controlAccentColor]))
            it.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Suggested move")?
                .withSymbolConfiguration(cfg)
            it.toolTip = "Suggested: move to the \(dstMac)"
        }
        let sub = NSMenu()
        sub.autoenablesItems = false
        if let mv = row["move"] as? [String: Any], let args = mv["args"] as? [String] {
            let dst = mac == "M5" ? "M1" : "M5"
            sub.addItem(ActionItem(mv["text"] as? String ?? "Move") { [weak self] in
                self?.moveFromMenu(args, name: text, dst: dst)
            })
        } else {
            sub.addItem(info("Can't be moved from here"))
        }
        sub.addItem(.separator())
        let tier = row["tier"] as? String ?? "float"
        let auto = row["auto"] as? Bool ?? true
        sub.addItem(info("Tier: \(tier)\(auto ? " (pool's guess: \(row["why"] as? String ?? ""))" : " (you set it)")", bold: true))
        for (name, label) in [("home", "Home: keep on the M5, it goes home with you"),
                              ("float", "Float: wherever there's room"),
                              ("m1", "M1: not important, run it on the M1"),
                              ("auto", "Let pool guess")] {
            let checked = name == "auto" ? auto : (!auto && tier == name)
            sub.addItem(ActionItem(label, checked: checked) { poolTopRun(["--tier", sid, name]) })
        }
        it.submenu = sub
        return it
    }

    private func info(_ text: String, bold: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        if bold {
            it.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        }
        return it
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: weight) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
