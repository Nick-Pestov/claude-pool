// ClaudePool (single-Mac menu bar app): a menu bar readout of this Mac's CPU and memory and every Claude Code session's cost, with a
// menu to close idle sessions and leftover processes. It draws what `claude-pool --agent` prints; it does nothing on
// its own and sends nothing anywhere.
//
// Build: menubar/build.sh (installs ~/Applications/ClaudePool.app). Preview a card: open -n --env POOLBAR_DEMO=12 …

import AppKit

let home = NSHomeDirectory()
let claudePool = home + "/.local/bin/claude-pool"
let logPath = home + "/.local/state/claude-pool/menubar.log"
let shellEnv: [String: String] = {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = home
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    return env
}()
let accent = NSColor(srgbRed: 0.22, green: 0.47, blue: 0.84, alpha: 1)

func claudePoolRun(_ args: [String], _ done: ((Bool, String) -> Void)? = nil) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", claudePool] + args
        p.environment = shellEnv
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { DispatchQueue.main.async { done?(false, "\(error)") }; return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { done?(p.terminationStatus == 0, text) }
    }
}

/// `claude-pool --agent`, restarted if it stops: one JSON line of state every two seconds.
final class Agent {
    private var process: Process?
    private var buffer = Data()
    private let onState: ([String: Any]) -> Void
    init(onState: @escaping ([String: Any]) -> Void) { self.onState = onState }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", claudePool, "--agent"]
        p.environment = shellEnv
        let out = Pipe()
        p.standardOutput = out
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        let err = FileHandle(forWritingAtPath: logPath); err?.seekToEndOfFile()
        p.standardError = err ?? FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { DispatchQueue.main.async { self?.consume(d) } }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.start() } }
        do { try p.run(); process = p } catch { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.start() } }
    }
    func stop() { process?.terminationHandler = nil; process?.terminate() }
    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onState(obj) }
        }
    }
}

final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler; self.target = self
    }
    @objc func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var agent: Agent!
    private var state: [String: Any] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudePool"
        item.button?.title = "pool …"
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        agent = Agent { [weak self] s in self?.update(s) }
        agent.start()
    }
    func applicationWillTerminate(_ n: Notification) { agent.stop() }

    private func update(_ s: [String: Any]) {
        state = s
        item.button?.image = statusImage(s)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = s["summary"] as? String
    }

    /// A rounded capsule: CPU (share of all cores) and memory (share of RAM), each after a small icon; red chip when
    /// past its limit; a trailing count of idle things you could close.
    private func statusImage(_ s: [String: Any]) -> NSImage {
        let title = s["title"] as? [String: Any] ?? [:]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let h: CGFloat = 18, pad: CGFloat = 7, gap: CGFloat = 5, icon: CGFloat = 12
        func pct(_ v: Any?) -> String { (v as? Int).map { ($0 < 10 ? "\u{2007}" : "") + "\($0)%" } ?? "–" }
        let hot = title["hot"] as? Bool ?? false
        struct Part { let text: String; let symbol: String }
        var parts = [Part(text: pct(title["pct"]), symbol: "cpu.fill"), Part(text: pct(title["mem"]), symbol: "memorychip.fill")]
        let idle = title["idle"] as? Int ?? 0
        func symbol(_ name: String, _ color: NSColor) -> NSImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        func width(_ p: Part) -> CGFloat { (p.text as NSString).size(withAttributes: [.font: font]).width + icon + 3 }
        var widths: [(NSColor, [Part], CGFloat)] = []
        let mainW = pad * 2 + parts.map(width).reduce(0, +) + gap * CGFloat(parts.count - 1)
        widths.append((hot ? .systemRed : accent, parts, mainW))
        if idle > 0 {
            let p = [Part(text: "\(idle)", symbol: "trash.fill")]
            widths.append((NSColor(white: 0.36, alpha: 1), p, pad * 2 + width(p[0])))
        }
        let total = widths.map { $0.2 }.reduce(0, +) + 4 * CGFloat(widths.count - 1)
        let image = NSImage(size: NSSize(width: ceil(total), height: h), flipped: false) { _ in
            var x: CGFloat = 0
            for (fill, ps, w) in widths {
                fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
                var cx = x + pad
                for part in ps {
                    if let img = symbol(part.symbol, .white) {
                        let sc = min(icon / img.size.width, icon / img.size.height)
                        let sz = NSSize(width: img.size.width * sc, height: img.size.height * sc)
                        img.draw(in: NSRect(x: cx + (icon - sz.width) / 2, y: (h - sz.height) / 2, width: sz.width, height: sz.height))
                        cx += icon + 3
                    }
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                    let ts = (part.text as NSString).size(withAttributes: attrs)
                    (part.text as NSString).draw(at: NSPoint(x: cx, y: (h - ts.height) / 2 + 0.5), withAttributes: attrs)
                    cx += ts.width + gap
                }
                x += w + 4
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func info(_ text: String, bold: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: ""); it.isEnabled = false
        if bold { it.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]) }
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state
        menu.addItem(info(s["summary"] as? String ?? "Starting…"))
        menu.addItem(.separator())
        let idle = (s["idle"] as? [[String: Any]]) ?? []
        menu.addItem(info(idle.isEmpty ? "Nothing idle to close" : "Idle, nobody using it (\(idle.count))", bold: true))
        for i in idle {
            let text = i["text"] as? String ?? "Close"
            if let args = i["args"] as? [String] {
                let it = ActionItem(text) { [weak self] in self?.runClose(args, name: text) }
                if #available(macOS 14.4, *) { it.subtitle = i["detail"] as? String }
                it.toolTip = i["detail"] as? String
                menu.addItem(it)
            } else {
                let it = info(text)
                if #available(macOS 14.4, *) { it.subtitle = i["detail"] as? String }
                menu.addItem(it)
            }
        }
        if idle.count > 1, let all = s["closeAll"] as? [String] {
            menu.addItem(ActionItem("Close all \(idle.filter { $0["args"] != nil }.count)") { [weak self] in
                self?.runClose(all, name: "idle things")
            })
        }
        menu.addItem(.separator())
        let sessions = (s["sessions"] as? [[String: Any]]) ?? []
        let sub = NSMenu()
        for row in sessions { sub.addItem(info(row["text"] as? String ?? "")) }
        if sessions.isEmpty { sub.addItem(info("none")) }
        let parent = NSMenuItem(title: "Claude sessions (\(sessions.count))", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open the monitor (claude-pool)") {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal", claudePool]; try? p.run()
        })
        menu.addItem(ActionItem("Quit ClaudePool") { NSApp.terminate(nil) })
    }

    private func runClose(_ args: [String], name: String) {
        claudePoolRun(args) { ok, out in
            let msg = out.split(separator: "\n").last.map(String.init) ?? ""
            let n = NSUserNotification(); n.title = ok ? "Closed" : "Couldn't close"
            n.informativeText = msg.isEmpty ? name : msg
            NSUserNotificationCenter.default.deliver(n)
        }
    }
}

extension NSFont { func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) } }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
