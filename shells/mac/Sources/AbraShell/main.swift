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
    try? h.seekToEnd()
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

    var onReady: ((String) -> Void)?
    var onRestarting: (() -> Void)?

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
            slog("engine exited (status \(proc.terminationStatus)) — restarting in 1s")
            DispatchQueue.main.async { self.onRestarting?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
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
                DispatchQueue.main.async { self.onReady?(model) }
            }
        }
    }

    /// Blocking request/response; call from a background queue.
    func transcribe(wav: URL, started: Double, ended: Double) -> [String: Any]? {
        queue.sync { [self] in
            guard let p = process, p.isRunning else {
                slog("transcribe skipped: engine not running")
                return nil
            }
            nextId += 1
            let req: [String: Any] = ["id": nextId, "cmd": "transcribe",
                                      "wav": wav.path, "started": started, "ended": ended]
            let data = try! JSONSerialization.data(withJSONObject: req)
            toEngine.fileHandleForWriting.write(data + Data("\n".utf8))
            guard let line = readLine() else {
                slog("transcribe: EOF from engine stdout")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else {
                slog("transcribe: unparseable engine line: \(line.prefix(300))")
                return nil
            }
            return obj
        }
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

// MARK: - mic capture (one engine, session-long; armed flag gates it)

final class AudioCapture {
    static let sampleRate: Double = 16_000
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter!
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: 1,
                                          interleaved: false)!
    private var samples: [Float] = []
    private var armed = false
    private let lock = NSLock()

    /// Install the tap once; the engine itself starts/pauses per clip so the
    /// macOS mic-in-use indicator only shows while the hotkey is held.
    /// (AVAudioEngine doesn't have PortAudio's start/stop deadlock — that rule
    /// is specific to the Python shell.)
    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
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
        engine.prepare()
        // Verify the mic works (and trigger the permission prompt) once at
        // startup, then release it until the hotkey is held.
        try engine.start()
        engine.pause()
    }

    func arm() {
        lock.lock(); samples = []; armed = true; lock.unlock()
        try? engine.start()  // resumes IO; lights the mic indicator
    }

    /// Abort a capture without producing audio (hotkey used in a combo).
    func cancelCapture() {
        engine.pause()
        lock.lock(); armed = false; samples = []; lock.unlock()
    }

    /// Disarm and write captured audio to a temp wav. Returns nil if too short.
    func disarmToWav(minSeconds: Double) -> URL? {
        engine.pause()  // releases the mic; indicator goes dark
        lock.lock()
        armed = false
        let captured = samples
        lock.unlock()
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
    private var pendingStartTone: DispatchWorkItem?
    private var startTonePlayed = false

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
        engineClient.start()

        // One permission prompt at a time: simultaneous mic + accessibility
        // dialogs clobber each other (answering one dismisses the other,
        // forcing a quit-and-reopen). Mic first; the rest after it resolves.
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.finishSetup() }
        }
    }


    private func finishSetup() {
        // Accessibility prompt (needed for paste injection), after mic settled.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        do { try audio.start() } catch {
            fail("mic unavailable: \(error.localizedDescription)")
            return
        }

        guard hotkey.start() else {
            fail("event tap refused — grant Input Monitoring, then relaunch")
            return
        }
        hotkey.onPress = { [self] in
            guard engineReady else { return }
            audio.arm()
            setIcon("mic.fill", help: "abra: recording")
            // Delay the start tone slightly: if the hotkey turns out to be
            // part of a combo (Fn+arrow etc.), the cancel arrives first and
            // combos stay completely silent. Capture is armed from t=0, so
            // no speech is lost.
            startTonePlayed = false
            let tone = DispatchWorkItem { [self] in
                startTonePlayed = true
                playTone("record-start.wav")
            }
            pendingStartTone = tone
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: tone)
        }
        hotkey.onCombo = { [self] in
            pendingStartTone?.cancel()
            pendingStartTone = nil
            audio.cancelCapture()
            setIcon("mic", help: "abra: ready")
        }
        hotkey.onRelease = { [self] in
            guard engineReady else { return }
            pendingStartTone?.cancel()
            pendingStartTone = nil
            if startTonePlayed {
                playTone("record-stop.wav")
            }
            let ended = Date().timeIntervalSince1970
            guard let wav = audio.disarmToWav(minSeconds: 0.4) else {
                setIcon("mic", help: "abra: ready (clip too short)")
                return
            }
            setIcon("waveform", help: "abra: transcribing…")
            work.async { [self] in
                let resp = engineClient.transcribe(wav: wav, started: ended, ended: ended)
                try? FileManager.default.removeItem(at: wav)
                DispatchQueue.main.async { [self] in
                    if let resp, resp["ok"] as? Bool == true,
                       let text = resp["text"] as? String, !text.isEmpty {
                        let ms = (resp["stt_ms"] as? Double).map { String(Int($0)) } ?? "?"
                        statusLine.isHidden = true  // clear any earlier warning
                        setIcon("mic", help: "abra: ready (\(ms)ms) — \(text)")
                        pasteAtCursor(text)
                    } else {
                        fail(resp?["error"] as? String ?? "no response from engine")
                    }
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
