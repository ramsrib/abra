// AbraShell — native macOS menu bar shell for abra.
//
// Owns only platform work: menu bar presence, global hotkey (Fn or right
// Option), mic capture, tones, paste injection. All features live in the
// Python engine, reached over the stdio JSON protocol (see ARCHITECTURE.md).
//
// Dev note: launched via `swift run` from a terminal, TCC attributes
// permissions (mic / accessibility / input monitoring) to the terminal —
// same grants the Python shell uses. A standalone .app identity comes with
// the bundle+signing step later in the roadmap.

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import ServiceManagement

// MARK: - engine location, resolved at runtime
// Priority: $ABRA_ENGINE_DIR → ~/.abra/engine (brew-install convention) →
// this source tree (dev builds from a checkout).

let repoRoot: URL = {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["ABRA_ENGINE_DIR"] {
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    let installed = fm.homeDirectoryForCurrentUser.appendingPathComponent(".abra/engine")
    if fm.fileExists(atPath: installed.appendingPathComponent("pyproject.toml").path) {
        return installed
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AbraShell
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // shells
        .deletingLastPathComponent()  // repo root
}()

func playTone(_ name: String) {
    let path = repoRoot.appendingPathComponent("abra/shell/assets/sounds/\(name)").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = [path]
    try? p.run()
}

// MARK: - engine client (stdio JSON protocol)

/// Append-only shell log — Finder-launched apps have no visible stderr, so
/// anything worth debugging later must land here.
let shellLog: FileHandle = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/abra-shell.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let h = try? FileHandle(forWritingTo: url) else { return .standardError }
    _ = try? h.seekToEnd()
    return h
}()

func slog(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    shellLog.write(Data("\(stamp) \(msg)\n".utf8))
    FileHandle.standardError.write(Data("\(msg)\n".utf8))  // visible in dev runs
}

final class EngineClient {
    private var process: Process?
    private var toEngine = Pipe()
    private var fromEngine = Pipe()
    private var buffer = Data()
    private var nextId = 0
    private let queue = DispatchQueue(label: "abra.engine.io")
    private var intentionalStop = false
    private var restartAttempts = 0
    private static let maxRestarts = 5

    var onReady: ((String) -> Void)?
    var onRestarting: (() -> Void)?
    var onGaveUp: (() -> Void)?

    /// Finder-launched apps don't inherit a shell PATH — locate uv directly.
    private func findUv() -> (String, [String]) {
        for c in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                  NSHomeDirectory() + "/.local/bin/uv"]
        where FileManager.default.isExecutableFile(atPath: c) {
            return (c, [])
        }
        return ("/usr/bin/env", ["uv"])  // terminal launch: PATH has it
    }

    func start() {
        intentionalStop = false
        buffer = Data()
        toEngine = Pipe()
        fromEngine = Pipe()
        let p = Process()
        let (uv, prefix) = findUv()
        p.currentDirectoryURL = repoRoot
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = prefix + ["run", "abra-engine"]
        p.standardInput = toEngine
        p.standardOutput = fromEngine
        p.standardError = shellLog  // engine diagnostics land in the log too
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.intentionalStop else { return }
            self.restartAttempts += 1
            guard self.restartAttempts <= Self.maxRestarts else {
                slog("engine exited (status \(proc.terminationStatus)) — "
                     + "giving up after \(Self.maxRestarts) consecutive failures")
                DispatchQueue.main.async { self.onGaveUp?() }
                return
            }
            // Exponential backoff so a persistently-broken engine doesn't
            // become a fork bomb: 1s, 2s, 4s, 8s, 16s, then give up.
            let delay = min(pow(2.0, Double(self.restartAttempts - 1)), 30)
            slog("engine exited (status \(proc.terminationStatus)) — "
                 + "restart \(self.restartAttempts)/\(Self.maxRestarts) in \(Int(delay))s")
            DispatchQueue.main.async { self.onRestarting?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
        }
        process = p
        do { try p.run() } catch {
            slog("engine failed to launch: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onRestarting?() }
            return
        }
        slog("engine started (pid \(p.processIdentifier))")
        queue.async { [self] in
            if let line = readLine() { // {"event":"ready",...}
                let model = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                    .flatMap { $0?["model"] as? String } ?? "?"
                restartAttempts = 0  // reached ready: healthy again
                DispatchQueue.main.async { self.onReady?(model) }
            }
        }
    }

    /// Blocking request/response; call from a background queue.
    /// nil means the engine never answered — distinct from an `ok: false` reply.
    func request(_ cmd: String, _ params: [String: Any] = [:]) -> [String: Any]? {
        queue.sync { [self] in
            guard let p = process, p.isRunning else {
                slog("\(cmd) skipped: engine not running")
                return nil
            }
            nextId += 1
            var req: [String: Any] = ["id": nextId, "cmd": cmd]
            req.merge(params) { _, given in given }
            let data = try! JSONSerialization.data(withJSONObject: req)
            toEngine.fileHandleForWriting.write(data + Data("\n".utf8))
            guard let line = readLine() else {
                slog("\(cmd): EOF from engine stdout")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else {
                slog("\(cmd): unparseable engine line: \(line.prefix(300))")
                return nil
            }
            return obj
        }
    }

    func transcribe(wav: URL, started: Double, ended: Double) -> [String: Any]? {
        request("transcribe", ["wav": wav.path, "started": started, "ended": ended])
    }

    private func readLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let chunk = fromEngine.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    func stop() {
        intentionalStop = true
        process?.terminate()
    }
}

// MARK: - dictionary window
// Pure UI over the engine's dictionary commands — the rules, the file and the
// matching all live in abra/engine/dictionary.py. Every mutation answers with
// the full list, so the table always shows what the engine will actually apply.

struct DictRule {
    let heard: String
    let replacement: String
    let builtin: Bool   // shipped in vocab.toml: shown, not editable

    init?(_ obj: Any) {
        guard let d = obj as? [String: Any],
              let heard = d["from"] as? String,
              let replacement = d["to"] as? String else { return nil }
        self.heard = heard
        self.replacement = replacement
        self.builtin = d["builtin"] as? Bool ?? false
    }
}

final class DictionaryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let engine: EngineClient
    private let work = DispatchQueue(label: "abra.dictionary")
    private var rules: [DictRule] = []
    private let table = NSTableView()
    private var removeButton: NSButton!
    private var window: NSWindow!

    init(engine: EngineClient) {
        self.engine = engine
        super.init()
        build()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        send("dictionary")
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "abra Dictionary"
        window.isReleasedWhenClosed = false   // reopened from the menu
        window.center()

        // Widths must total under the 456pt content area or the ⌾ marker
        // clips off the right edge instead of sitting beside its rule.
        for (id, title, width) in [("heard", "heard", 188.0),
                                   ("replacement", "replacement", 188.0),
                                   ("builtin", "", 24.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Table controls, macOS convention: a joined +/− pair tucked under the
        // table's left edge, the legend pushed to the opposite corner.
        let add = NSButton(title: "+", target: self, action: #selector(addRule))
        removeButton = NSButton(title: "−", target: self, action: #selector(removeRule))
        removeButton.isEnabled = false
        for b in [add, removeButton!] {
            b.bezelStyle = .smallSquare
            b.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 26),
                b.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        let legend = NSTextField(labelWithString: "⌾ built-in — your own rules override them")
        legend.textColor = .secondaryLabelColor
        legend.font = .systemFont(ofSize: 11)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.addView(add, in: .leading)
        controls.addView(removeButton, in: .leading)
        controls.setCustomSpacing(0, after: add)   // the pair reads as one control
        controls.addView(legend, in: .trailing)
        let content = NSStackView(views: [scroll, controls])
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = content
        // A vertical stack centers its children at their intrinsic width, so
        // the controls row has to be stretched to the table's width before
        // .trailing gravity has anywhere to push the legend.
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        ])
    }

    // -- engine round trips ------------------------------------------------

    private func send(_ cmd: String, _ params: [String: Any] = [:]) {
        work.async { [self] in
            let resp = engine.request(cmd, params)
            DispatchQueue.main.async { [self] in
                guard let resp else {
                    report("The engine isn't running — check the menu bar, "
                           + "or ~/Library/Logs/abra-shell.log")
                    return
                }
                guard resp["ok"] as? Bool == true else {
                    report(resp["error"] as? String ?? "the engine rejected that")
                    return
                }
                rules = (resp["rules"] as? [Any] ?? []).compactMap(DictRule.init)
                window.subtitle = (resp["path"] as? String).map {
                    $0.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                } ?? ""
                table.reloadData()
                removeButton.isEnabled = false
            }
        }
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Dictionary"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    @objc private func addRule() {
        let heard = NSTextField(frame: NSRect(x: 78, y: 30, width: 190, height: 22))
        heard.placeholderString = "ctu"
        let replacement = NSTextField(frame: NSRect(x: 78, y: 0, width: 190, height: 22))
        replacement.placeholderString = "CPU"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 52))
        for (y, title) in [(30.0, "abra heard:"), (0.0, "should be:")] {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 72, height: 18)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            fields.addSubview(label)
        }
        fields.addSubview(heard)
        fields.addSubview(replacement)

        let alert = NSAlert()
        alert.messageText = "Add a dictionary rule"
        alert.informativeText = "Whenever abra hears the first phrase, it pastes "
            + "the second instead. Case is ignored; whole words only."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Add Rule")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            send("dictionary_add", ["from": heard.stringValue,
                                    "to": replacement.stringValue])
        }
        alert.window.makeFirstResponder(heard)
    }

    @objc private func removeRule() {
        let row = table.selectedRow
        guard row >= 0, row < rules.count, !rules[row].builtin else { return }
        send("dictionary_remove", ["from": rules[row].heard])
    }

    // -- table -------------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        let rule = rules[row]
        let text: String
        switch column?.identifier.rawValue {
        case "heard": text = rule.heard
        case "replacement": text = rule.replacement
        default: text = rule.builtin ? "⌾" : ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = rule.builtin ? .secondaryLabelColor : .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        removeButton.isEnabled = row >= 0 && row < rules.count && !rules[row].builtin
    }
}

// MARK: - mic capture (one engine, session-long; armed flag gates it)
// Every AVAudioEngine call runs on `queue`, never on main: a start() that
// never returned once froze the whole app (main thread parked in
// AdaptToIOBufferSize while CoreAudio spun re-reading the HW format, sampled
// 2026-09-22 after three weeks of uptime and device churn). Each call gets a
// watchdog; one that doesn't return in time reports the HAL as wedged.

final class AudioCapture {
    static let sampleRate: Double = 16_000
    /// Generous: a Bluetooth mic can take a second or two to switch profiles.
    static let wedgeTimeout: TimeInterval = 6

    /// Fires on main, once, when an engine call hasn't returned in time.
    var onWedged: ((String) -> Void)?
    /// Fires on main when capture is unusable (rebuilds exhausted).
    var onUnavailable: ((String) -> Void)?

    private let queue = DispatchQueue(label: "abra.audio")
    private let files = DispatchQueue(label: "abra.audio.files")  // serial: keeps clip order
    private var engine: AVAudioEngine?          // queue-only
    private var configObserver: NSObjectProtocol?  // queue-only
    private var rebuildPending = false          // queue-only
    private var rebuildFailures = 0             // queue-only
    private var wedged = false                  // main-only
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: 1,
                                          interleaved: false)!
    private var samples: [Float] = []
    private var armed = false
    private let lock = NSLock()

    /// Build the tap; the engine itself starts/pauses per clip so the macOS
    /// mic-in-use indicator only shows while the hotkey is held.
    /// (AVAudioEngine doesn't have PortAudio's start/stop deadlock — that rule
    /// is specific to the Python shell.) Completion runs on main.
    func start(completion: @escaping (Error?) -> Void) {
        run("startup") { [self] in
            do {
                try build()
                // Verify the mic works (and trigger the permission prompt)
                // once at startup, then release it until the hotkey is held.
                try engine?.start()
                engine?.pause()
                watchDefaultInput()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    // Capture state changes ride the audio queue with the engine calls, so a
    // quick release→press can't have the release's pause land on the new clip.

    /// `started` runs on main once the mic is actually live (or failed to go live).
    func arm(started: @escaping (Bool) -> Void) {
        run("start") { [self] in
            lock.lock(); samples = []; armed = true; lock.unlock()
            let ok = (try? engine?.start()) != nil  // nil engine or a throw
            if !ok { slog("audio: engine failed to start for capture") }
            DispatchQueue.main.async { started(ok) }  // lights the mic indicator
        }
    }

    /// Abort a capture without producing audio (hotkey used in a combo).
    func cancelCapture() {
        run("pause") { [self] in
            engine?.pause()
            lock.lock(); armed = false; samples = []; lock.unlock()
        }
    }

    /// Disarm and write captured audio to a temp wav; completion (on main)
    /// gets nil if the clip was too short.
    func disarmToWav(minSeconds: Double, completion: @escaping (URL?) -> Void) {
        run("pause") { [self] in
            engine?.pause()  // releases the mic; indicator goes dark
            lock.lock()
            armed = false
            let captured = samples
            lock.unlock()
            // File work is outside the watched call: slow disk isn't a HAL wedge.
            files.async { [self] in
                let url = writeWav(captured, minSeconds: minSeconds)
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    // MARK: engine lifecycle (queue-only)

    /// (Re)create the engine and its tap. The tap format comes from the
    /// current input device, so this reruns whenever that device changes —
    /// a session-long engine otherwise keeps a stale view of the hardware.
    /// The old engine stays in place unless the new one is fully set up.
    private func build() throws {
        let fresh = AVAudioEngine()
        let input = fresh.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "abra", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no usable input device"])
        }
        let outFormat = outFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [self] buf, _ in
            lock.lock(); defer { lock.unlock() }
            guard armed else { return }
            let ratio = AudioCapture.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if let data = out.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                               count: Int(out.frameLength)))
            }
        }
        fresh.prepare()

        if let old = engine {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
        engine = fresh
        // The notification means this engine stopped and uninitialized itself
        // (Apple docs), so every one it posts needs a rebuild. Observing only
        // `fresh` means a retired engine can't trigger one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: fresh, queue: nil
        ) { [weak self, weak fresh] _ in
            self?.queue.async {
                // Removing the observer doesn't cancel a callback already queued.
                guard let self, let fresh, self.engine === fresh else { return }
                self.scheduleRebuild("engine configuration changed")
            }
        }
    }

    private func watchDefaultInput() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in
            self?.scheduleRebuild("default input device changed")
        }
    }

    /// Device changes arrive in bursts (and often as both a HAL and an engine
    /// notification); coalesce them into one rebuild. A failed rebuild (the
    /// new device not ready yet, mid-churn) retries with backoff: 1s…16s.
    private func scheduleRebuild(_ reason: String, delay: TimeInterval = 0.3) {
        guard !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            rebuildPending = false
            run("rebuild") { [self] in
                slog("audio: \(reason) — rebuilding capture engine")
                do {
                    try build()
                    lock.lock(); let recording = armed; lock.unlock()
                    if recording { try engine?.start() }
                    rebuildFailures = 0
                } catch {
                    rebuildFailures += 1
                    guard rebuildFailures <= 5 else {
                        slog("audio: rebuild failed: \(error.localizedDescription) — "
                             + "giving up until the next device change")
                        rebuildFailures = 0
                        DispatchQueue.main.async { [self] in
                            onUnavailable?("mic unavailable after device change — see ~/Library/Logs/abra-shell.log")
                        }
                        return
                    }
                    let retry = pow(2.0, Double(rebuildFailures - 1))
                    slog("audio: rebuild failed: \(error.localizedDescription) — "
                         + "retry \(rebuildFailures)/5 in \(Int(retry))s")
                    scheduleRebuild("retry after failed rebuild", delay: retry)
                }
            }
        }
    }

    /// Run an engine call on the audio queue under a watchdog. The clock
    /// starts when the call starts, not when it's queued, so waiting behind a
    /// slow (but healthy) rebuild isn't mistaken for a wedge. A wedged HAL
    /// call can't be interrupted, so the watchdog only reports it.
    private func run(_ what: String, _ op: @escaping () -> Void) {
        queue.async { [self] in
            let group = DispatchGroup()
            group.enter()
            let began = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wedgeTimeout) { [self] in
                guard group.wait(timeout: .now()) == .timedOut, !wedged else { return }
                wedged = true
                onWedged?(what)
            }
            op()
            group.leave()
            let took = Date().timeIntervalSince(began)
            if took >= Self.wedgeTimeout {
                // Late but alive: re-arm the watchdog for the next real wedge.
                DispatchQueue.main.async { [self] in
                    slog("audio: \(what) returned after \(Int(took))s")
                    wedged = false
                }
            }
        }
    }

    private func writeWav(_ captured: [Float], minSeconds: Double) -> URL? {
        guard Double(captured.count) / AudioCapture.sampleRate >= minSeconds else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abra-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: AVAudioFrameCount(captured.count))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(captured.count)
        captured.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: captured.count)
        }
        try? file.write(from: buf)
        return url
    }
}

// MARK: - paste injection

func pasteAtCursor(_ text: String) {
    let pb = NSPasteboard.general
    let old = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)

    let src = CGEventSource(stateID: .hidSystemState)
    let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)  // 'v'
    let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
    vDown?.flags = .maskCommand
    vUp?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        if let old {
            pb.clearContents()
            pb.setString(old, forType: .string)
        }
    }
}

// MARK: - global hotkey via CGEventTap

enum Hotkey: String, CaseIterable {
    case fn = "Fn"
    case rightOption = "Right Option (⌥)"
    case rightCommand = "Right Command (⌘)"

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }

    static var saved: Hotkey {
        Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .fn
    }
}

final class HotkeyTap {
    var hotkey: Hotkey = .saved
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key was pressed while the hotkey was held — the user is doing a
    /// combo (Fn+arrow, ⌘+c, …), not dictating. Cancel without transcribing.
    var onCombo: (() -> Void)?
    private var tap: CFMachPort?
    private var holding = false

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                if me.holding {
                    me.holding = false
                    DispatchQueue.main.async { me.onCombo?() }
                }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == me.hotkey.keyCode {
                let pressed = event.flags.contains(me.hotkey.flag)
                if pressed && !me.holding {
                    me.holding = true
                    DispatchQueue.main.async { me.onPress?() }
                } else if !pressed && me.holding {
                    me.holding = false
                    DispatchQueue.main.async { me.onRelease?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!  // visible only while starting or on error
    private let engineClient = EngineClient()
    private let audio = AudioCapture()
    private let hotkey = HotkeyTap()
    private let work = DispatchQueue(label: "abra.transcribe")
    private var engineReady = false
    private var dictionaryWindow: DictionaryWindow?  // built on first open
    private var pendingStartTone: DispatchWorkItem?
    private var startTonePlayed = false
    private let launchedAt = Date()
    private var recording = false  // hotkey held; guards stale audio callbacks
    private var captureId = 0
    private var captureFailed = false  // this press's mic never came up

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let hotkeyMenu = NSMenu()
        for choice in Hotkey.allCases {
            let item = NSMenuItem(title: choice.rawValue,
                                  action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == Hotkey.saved ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyItem)
        menu.setSubmenu(hotkeyMenu, for: hotkeyItem)
        let dictionaryItem = NSMenuItem(title: "Dictionary…",
                                        action: #selector(openDictionary), keyEquivalent: "")
        dictionaryItem.target = self
        menu.addItem(dictionaryItem)
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit abra", action: #selector(quit),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon("hourglass", help: "abra: setting up…")

        // Direct-download users may not have the engine yet — explain instead
        // of dying when its process exits.
        if !FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("pyproject.toml").path) {
            let alert = NSAlert()
            alert.messageText = "abra needs its engine"
            alert.informativeText = """
            The transcription engine wasn't found on this Mac.

            Easiest fix — install via Homebrew (sets up everything):
                brew install ramsrib/tap/abra

            Or set it up manually:
                git clone https://github.com/ramsrib/abra ~/.abra/engine
                cd ~/.abra/engine && uv sync
            """
            alert.addButton(withTitle: "Open Setup Guide")
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/ramsrib/abra#install")!)
            }
            exit(1)
        }

        // Engine needs no permissions — start it now so the model loads (or
        // downloads, on first run) while the permission prompts play out.
        statusLine.title = "setting up…"
        engineClient.onReady = { [self] _ in
            engineReady = true
            statusLine.isHidden = true
            setIcon("mic", help: "abra: ready")
        }
        engineClient.onRestarting = { [self] in
            engineReady = false
            statusLine.title = "engine restarting…"
            statusLine.isHidden = false
            setIcon("hourglass", help: "abra: engine restarting…")
        }
        engineClient.onGaveUp = { [self] in
            engineReady = false
            fail("engine keeps crashing — see ~/Library/Logs/abra-shell.log")
        }
        engineClient.start()

        // One permission prompt at a time: simultaneous mic + accessibility
        // dialogs clobber each other (answering one dismisses the other,
        // forcing a quit-and-reopen). Mic first; the rest after it resolves.
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.finishSetup() }
        }
    }


    private func finishSetup() {
        // Menu/window work often runs alongside the installed Abra.app, and
        // both event taps see the same Fn press — two recordings, two pastes.
        // ABRA_NO_HOTKEY=1 brings up the UI and engine only.
        if ProcessInfo.processInfo.environment["ABRA_NO_HOTKEY"] == "1" {
            slog("ABRA_NO_HOTKEY=1 — hotkey and mic off, UI only")
            return
        }

        // Accessibility prompt (needed for paste injection), after mic settled.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        audio.onUnavailable = { [self] msg in fail(msg) }
        audio.onWedged = { [self] what in
            slog("audio: \(what) hung >\(Int(AudioCapture.wedgeTimeout))s — CoreAudio wedged")
            relaunchForAudio()
        }
        audio.start { [self] error in
            if let error {
                fail("mic unavailable: \(error.localizedDescription)")
                return
            }
            startHotkey()
        }
    }

    /// A CoreAudio call that never returns can't be unstuck in-process; a
    /// fresh process can. Only from the installed bundle, and not if we just
    /// launched (a wedge at startup would otherwise relaunch forever).
    private func relaunchForAudio() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Date().timeIntervalSince(launchedAt) > 60 else {
            fail("audio stuck — quit and relaunch abra")
            return
        }
        slog("audio: relaunching \(bundle.path)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundle.path]
        do { try p.run() } catch {
            slog("audio: relaunch helper failed: \(error.localizedDescription)")
            fail("audio stuck — quit and relaunch abra")
            return
        }
        engineClient.stop()
        _exit(0)  // exit() runs teardown that can block on the wedged HAL
    }

    private func startHotkey() {
        guard hotkey.start() else {
            fail("event tap refused — grant Input Monitoring, then relaunch")
            return
        }
        hotkey.onPress = { [self] in
            guard engineReady else { return }
            captureId += 1
            let id = captureId
            recording = true
            captureFailed = false
            startTonePlayed = false
            setIcon("mic.fill", help: "abra: recording")
            audio.arm { [self] live in
                guard id == captureId else { return }  // superseded by a newer press
                guard live else {
                    captureFailed = true
                    recording = false
                    fail("mic failed to start — see ~/Library/Logs/abra-shell.log")
                    return
                }
                guard recording else { return }  // released or cancelled already
                // Delay the start tone slightly: if the hotkey turns out to be
                // part of a combo (Fn+arrow etc.), the cancel arrives first and
                // combos stay completely silent. The tone follows the mic going
                // live, so speech after it is always captured.
                let tone = DispatchWorkItem { [self] in
                    startTonePlayed = true
                    playTone("record-start.wav")
                }
                pendingStartTone = tone
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: tone)
            }
        }
        hotkey.onCombo = { [self] in
            recording = false
            pendingStartTone?.cancel()
            pendingStartTone = nil
            audio.cancelCapture()
            setIcon("mic", help: "abra: ready")
        }
        hotkey.onRelease = { [self] in
            // Always release the mic, even if the engine died mid-clip; only
            // transcription needs it. A press that never armed (engine not
            // ready yet, or already cancelled as a combo) has nothing to release.
            let armed = recording || captureFailed
            recording = false
            guard armed else { return }
            pendingStartTone?.cancel()
            pendingStartTone = nil
            if startTonePlayed {
                playTone("record-stop.wav")
            }
            let ended = Date().timeIntervalSince1970
            let id = captureId
            audio.disarmToWav(minSeconds: 0.4) { [self] wav in
                guard let wav else {
                    // Only the latest capture owns the icon, and a failed start
                    // already shows its own error.
                    if isCurrent(id), !captureFailed {
                        setIcon("mic", help: "abra: ready (clip too short)")
                    }
                    return
                }
                guard engineReady else {
                    try? FileManager.default.removeItem(at: wav)
                    return
                }
                transcribe(wav, ended: ended, id: id)
            }
        }
    }

    /// The icon belongs to the newest capture, and to none while one is recording.
    private func isCurrent(_ id: Int) -> Bool { id == captureId && !recording }

    private func transcribe(_ wav: URL, ended: TimeInterval, id: Int) {
        if isCurrent(id) { setIcon("waveform", help: "abra: transcribing…") }
        work.async { [self] in
            let resp = engineClient.transcribe(wav: wav, started: ended, ended: ended)
            try? FileManager.default.removeItem(at: wav)
            DispatchQueue.main.async { [self] in
                if let resp, resp["ok"] as? Bool == true {
                    // The engine answered, so any earlier warning is stale —
                    // even when the clip was silence and there's nothing to paste.
                    statusLine.isHidden = true
                    let text = resp["text"] as? String ?? ""
                    guard !text.isEmpty else {
                        if isCurrent(id) { setIcon("mic", help: "abra: ready (heard nothing)") }
                        return
                    }
                    let ms = (resp["stt_ms"] as? Double).map { String(Int($0)) } ?? "?"
                    if isCurrent(id) { setIcon("mic", help: "abra: ready (\(ms)ms) — \(text)") }
                    pasteAtCursor(text)
                } else {
                    fail(resp?["error"] as? String ?? "no response from engine")
                }
            }
        }
    }

    private func setIcon(_ symbol: String, help: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "abra")
        statusItem.button?.toolTip = help
    }

    private func fail(_ msg: String) {
        FileHandle.standardError.write(Data("abra shell: \(msg)\n".utf8))
        statusLine.title = "⚠ \(msg)"
        statusLine.isHidden = false
        setIcon("mic.badge.xmark", help: "abra: \(msg)")
    }

    @objc private func openDictionary() {
        if dictionaryWindow == nil { dictionaryWindow = DictionaryWindow(engine: engineClient) }
        dictionaryWindow?.show()
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = Hotkey(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: "hotkey")
        hotkey.hotkey = choice
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()  // needs the .app bundle
                sender.state = .on
            }
        } catch {
            fail("launch-at-login: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        engineClient.stop()
        // Same rule as the Python shell: never "cleanly" stop audio on the
        // way out; the OS reclaims everything.
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineClient.stop()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
