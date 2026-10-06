// Lumi — a tiny dragon-unicorn desktop pet for macOS.
// Native shell: a transparent floating window hosting web/index.html,
// a Spotify watcher (AppleScript), and a Claude chat bridge.

import Cocoa
import WebKit
import Security

// MARK: - Window

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

let compactSize = NSSize(width: 250, height: 270)
let chatSize = NSSize(width: 360, height: 620)

// MARK: - Keychain (API key storage)

enum Keychain {
    static let service = "com.lumipet.app"
    static let account = "anthropic-api-key"

    static func save(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Spotify

final class Spotify {
    static let bundleID = "com.spotify.client"
    private let queue = DispatchQueue(label: "lumi.spotify")

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Spotify.bundleID).isEmpty
    }

    /// Calls back on the main thread with a dictionary describing the player.
    func poll(_ done: @escaping ([String: Any]) -> Void) {
        guard isRunning else { done(["state": "off"]); return }
        queue.async {
            let src = """
            tell application id "com.spotify.client"
              set s to player state as string
              if s is "stopped" then return "stopped"
              set t to current track
              return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (id of t) & linefeed & ((player position * 1000) as integer) & linefeed & (duration of t)
            end tell
            """
            var err: NSDictionary?
            let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
            var info: [String: Any] = ["state": "stopped"]
            if let err = err {
                let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                info = ["state": code == -1743 ? "denied" : "error", "code": code]
            } else if let text = result?.stringValue {
                let parts = text.components(separatedBy: "\n")
                if parts.count >= 6 {
                    info = [
                        "state": parts[0],
                        "track": parts[1],
                        "artist": parts[2],
                        "id": parts[3],
                        "positionMs": Int(parts[4]) ?? 0,
                        "durationMs": Int(parts[5]) ?? 0,
                    ]
                }
            }
            DispatchQueue.main.async { done(info) }
        }
    }

    func command(_ cmd: String) {
        guard isRunning else { return }
        let verb: String
        switch cmd {
        case "next": verb = "next track"
        case "previous": verb = "previous track"
        default: verb = "playpause"
        }
        queue.async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application id \"com.spotify.client\" to \(verb)")?
                .executeAndReturnError(&err)
        }
    }
}

// MARK: - Claude chat

final class ClaudeChat {
    static let persona = """
    You are Lumi, a tiny, sweet dragon-unicorn who lives on the user's desktop. \
    You have glossy midnight scales, big glowing eyes, a pastel rainbow mane and a pearly horn. \
    You love music and dance to whatever the user plays on Spotify. \
    Keep replies short and warm (usually 1-3 sentences), playful but genuinely helpful. \
    Plain text only, no markdown headings. An occasional emoji is fine.
    """

    var cliSessionID: String?
    var cliHasSession = false

    static func findCLI() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func resetSession() {
        cliSessionID = nil
        cliHasSession = false
    }

    /// messages: [{role, content}] full history (used by API backend).
    func send(messages: [[String: String]], nowPlaying: String?, done: @escaping (String?, String?) -> Void) {
        let backend = UserDefaults.standard.string(forKey: "backend") ?? "auto"
        let key = Keychain.load()
        let useAPI = backend == "api" || (backend == "auto" && key != nil)
        if useAPI {
            guard let key = key, !key.isEmpty else {
                done(nil, "I need an Anthropic API key first — tap ⚙︎ to add one.")
                return
            }
            sendAPI(key: key, messages: messages, nowPlaying: nowPlaying, done: done)
        } else if let cli = ClaudeChat.findCLI() {
            let last = messages.last?["content"] ?? ""
            sendCLI(path: cli, text: last, nowPlaying: nowPlaying, done: done)
        } else {
            done(nil, "I need a way to talk to Claude! Tap ⚙︎ to add an Anthropic API key (or install Claude Code).")
        }
    }

    private func systemPrompt(_ nowPlaying: String?) -> String {
        if let np = nowPlaying, !np.isEmpty {
            return ClaudeChat.persona + "\nRight now the user is listening to: \(np)."
        }
        return ClaudeChat.persona
    }

    private func sendAPI(key: String, messages: [[String: String]], nowPlaying: String?,
                         done: @escaping (String?, String?) -> Void) {
        let model = UserDefaults.standard.string(forKey: "model") ?? "claude-opus-5-5"
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt(nowPlaying),
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": messages,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, error in
            var reply: String?
            var failure: String?
            defer { DispatchQueue.main.async { done(reply, failure) } }
            if let error = error { failure = "Couldn't reach Claude: \(error.localizedDescription)"; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failure = "Got a strange answer from Claude."; return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
                failure = status == 401 ? "That API key didn't work — check it in ⚙︎." : "Claude error: \(msg)"
                return
            }
            if json["stop_reason"] as? String == "refusal" {
                failure = "Hmm, I can't help with that one."; return
            }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            reply = text.isEmpty ? "…" : text
        }.resume()
    }

    private func sendCLI(path: String, text: String, nowPlaying: String?,
                         done: @escaping (String?, String?) -> Void) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumi/chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if cliSessionID == nil { cliSessionID = UUID().uuidString.lowercased(); cliHasSession = false }
        var args = ["-p", "--output-format", "json", "--tools", "", "--setting-sources", ""]
        if cliHasSession {
            args += ["--resume", cliSessionID!]
        } else {
            args += ["--session-id", cliSessionID!, "--append-system-prompt", ClaudeChat.persona]
        }
        var prompt = text
        if let np = nowPlaying, !np.isEmpty { prompt = "[Now playing on Spotify: \(np)]\n\(text)" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = Pipe()

        DispatchQueue.global().async {
            do { try proc.run() } catch {
                DispatchQueue.main.async { done(nil, "Couldn't start Claude Code: \(error.localizedDescription)") }
                return
            }
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            timeout.cancel()

            var reply: String?, failure: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let result = json["result"] as? String ?? ""
                if json["is_error"] as? Bool == true {
                    failure = result.contains("login") || result.contains("logged in")
                        ? "Claude Code isn't logged in. Run `claude` in Terminal and log in, or add an API key in ⚙︎."
                        : "Claude Code said: \(result)"
                } else {
                    reply = result
                }
            } else {
                failure = "Claude Code didn't answer (timed out?). You can add an API key in ⚙︎ instead."
            }
            DispatchQueue.main.async {
                if reply != nil { self.cliHasSession = true }
                done(reply, failure)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: PetPanel!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    let spotify = Spotify()
    let chat = ClaudeChat()

    var hitRects: [NSRect] = []     // in web coordinates (origin top-left)
    var chatOpen = false
    var dragging = false
    var nowPlaying: String?
    var mouseTimer: Timer?
    var spotifyTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "lumi")

        let frame = NSRect(origin: initialOrigin(), size: compactSize)
        window = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        web = WKWebView(frame: NSRect(origin: .zero, size: compactSize), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        window.contentView = web

        let webDir = Bundle.main.resourceURL!.appendingPathComponent("web")
        web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)

        window.orderFrontRegardless()
        setupStatusItem()

        // Make transparent areas click-through: only the pet (and bubbles) catch the mouse.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        spotifyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollSpotify()
        }
    }

    func initialOrigin() -> NSPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "posX") != nil {
            let p = NSPoint(x: d.double(forKey: "posX"), y: d.double(forKey: "posY"))
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -50, dy: -50).contains(p) }) {
                return p
            }
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - compactSize.width - 40, y: vf.minY + 20)
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lumi")
        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Chat with Lumi", action: #selector(menuChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show / Hide Lumi", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Play / Pause", action: #selector(menuPlayPause), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Next Track", action: #selector(menuNext), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Lumi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func menuChat() { window.orderFrontRegardless(); js("lumi.openChat()") }
    @objc func menuSettings() { window.orderFrontRegardless(); js("lumi.openChat('settings')") }
    @objc func menuToggle() { window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless() }
    @objc func menuPlayPause() { spotify.command("playpause") }
    @objc func menuNext() { spotify.command("next") }

    // MARK: Click-through

    func updateClickThrough() {
        if chatOpen || dragging {
            if window.ignoresMouseEvents { window.ignoresMouseEvents = false }
            return
        }
        let m = NSEvent.mouseLocation
        let f = window.frame
        let p = NSPoint(x: m.x - f.minX, y: f.height - (m.y - f.minY))
        let inside = hitRects.contains { $0.contains(p) }
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
    }

    // MARK: Spotify

    func pollSpotify() {
        spotify.poll { [weak self] info in
            guard let self = self else { return }
            if let t = info["track"] as? String, let a = info["artist"] as? String, info["state"] as? String == "playing" {
                self.nowPlaying = "\"\(t)\" by \(a)"
            } else {
                self.nowPlaying = nil
            }
            self.send("onSpotify", info)
        }
    }

    // MARK: Bridge

    func js(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }

    func send(_ fn: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return }
        js("window.lumi && lumi.\(fn)(\(s))")
    }

    func sendConfig() {
        send("onConfig", [
            "hasKey": Keychain.load() != nil,
            "hasCLI": ClaudeChat.findCLI() != nil,
            "backend": UserDefaults.standard.string(forKey: "backend") ?? "auto",
        ])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendConfig()
        debugSnapshotIfRequested()
    }

    /// Developer aid: `Lumi --snapshot out.png [--chat] [--vibe]` saves a picture of the pet.
    func debugSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        if args.contains("--vibe") {
            send("onSpotify", ["state": "playing", "track": "Midnight City", "artist": "M83", "id": "spotify:track:demo"])
        }
        if args.contains("--chat") { js("lumi.openChat()") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.web.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                }
            }
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "hitRects":
            let rects = body["rects"] as? [[Double]] ?? []
            hitRects = rects.filter { $0.count == 4 }.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }

        case "dragStart":
            dragging = true

        case "drag":
            let dx = body["dx"] as? Double ?? 0, dy = body["dy"] as? Double ?? 0
            var o = window.frame.origin
            o.x += dx; o.y -= dy
            window.setFrameOrigin(o)

        case "dragEnd":
            dragging = false
            UserDefaults.standard.set(window.frame.minX, forKey: "posX")
            UserDefaults.standard.set(window.frame.minY, forKey: "posY")

        case "setMode":
            let open = body["mode"] as? String == "chat"
            chatOpen = open
            resize(to: open ? chatSize : compactSize)
            if open { window.makeKey() }

        case "chat":
            let id = body["id"] as? Int ?? 0
            let msgs = body["messages"] as? [[String: String]] ?? []
            chat.send(messages: msgs, nowPlaying: nowPlaying) { [weak self] reply, error in
                var payload: [String: Any] = ["id": id]
                if let r = reply { payload["text"] = r }
                if let e = error { payload["error"] = e }
                self?.send("onChatReply", payload)
            }

        case "newChat":
            chat.resetSession()

        case "saveKey":
            let key = (body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { Keychain.delete() } else { Keychain.save(key) }
            sendConfig()

        case "setBackend":
            UserDefaults.standard.set(body["backend"] as? String ?? "auto", forKey: "backend")
            sendConfig()

        case "spotify":
            spotify.command(body["action"] as? String ?? "playpause")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pollSpotify() }

        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" || url.scheme == "x-apple.systempreferences" {
                NSWorkspace.shared.open(url)
            }

        case "contextMenu":
            buildMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        case "quit":
            NSApp.terminate(nil)

        default: break
        }
    }

    /// Resize keeping the pet's bottom-center anchored, clamped to the screen.
    func resize(to size: NSSize) {
        let f = window.frame
        var o = NSPoint(x: f.midX - size.width / 2, y: f.minY)
        if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
            o.x = min(max(o.x, vf.minX), vf.maxX - size.width)
            o.y = min(max(o.y, vf.minY), vf.maxY - size.height)
        }
        window.setFrame(NSRect(origin: o, size: size), display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
