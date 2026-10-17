// needle-mac — Apple-Writing-Tools-style text actions on macOS, served by
// any OpenAI-compatible LLM endpoint (local Strata / Ollama / llama.cpp, or
// a remote one). A resident menu-bar daemon: global hotkey -> capture the
// selection (synthesized Cmd+C) -> palette -> LLM -> result pasted back
// (Cmd+V) with the user's clipboard restored.
//
// Port of the needle-writes design (Hyprland/Wayland) to macOS AppKit:
//   ext_data_control  -> NSPasteboard + synthesized Cmd+C
//   virtual keyboard  -> CGEvent keystroke injection
//   fuzzel palette    -> native NSPanel palette
// Config format, action registry, prompts, output cleaning, and exit-code
// semantics follow the original.

import Cocoa
import Carbon.HIToolbox

// MARK: - Logging (a file: launchd stderr is easy to miss)

func log(_ message: String) {
    let line = "\(Date()): \(message)\n"
    let path = ("~/Library/Logs/needle-mac.log" as NSString).expandingTildeInPath
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// MARK: - Config

struct Config {
    // Primary: the local engine (Strata / Ollama / llama.cpp on this PC).
    var endpoint = "http://127.0.0.1:8080/v1"
    var model = "needle"
    var keyFile: String? = nil
    var keyVar = "API_KEY"
    var apiKeyEnv = ProcessInfo.processInfo.environment["NEEDLE_API_KEY"]
    // Secondary: any other OpenAI-compatible endpoint, used only when the
    // primary fails (engine error, HTTP failure, empty result).
    var fallbackEndpoint: String? = ProcessInfo.processInfo.environment["NEEDLE_FALLBACK_URL"]
    var fallbackModel = ProcessInfo.processInfo.environment["NEEDLE_FALLBACK_MODEL"] ?? "needle"
    var fallbackKeyFile: String? = nil
    var fallbackKeyVar = "API_KEY"
    var fallbackKeyEnv = ProcessInfo.processInfo.environment["NEEDLE_FALLBACK_API_KEY"]
    var pasteCombo = "cmd+v"
    var copyCombo = "cmd+c"
    var hotkey = "ctrl+opt+o"
    var hotkeyClipboard = "ctrl+opt+i"
    var maxTokens = 4096
    var timeoutSec = 120.0

    static let knownKeys: Set<String> = [
        "endpoint", "model", "key_file", "key_var",
        "fallback_endpoint", "fallback_model", "fallback_key_file", "fallback_key_var",
        "paste_combo", "copy_combo", "hotkey", "hotkey_clipboard", "max_tokens", "timeout",
    ]

    static func configPath() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base).appendingPathComponent("needle-mac/config")
    }

    // Parse one "KEY = VALUE" line's value: strip a whitespace-preceded " #",
    // honor quoting that keeps trailing spaces.
    static func parseValue(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            return String(v.dropFirst().dropLast())
        }
        if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 {
            return String(v.dropFirst().dropLast())
        }
        // unquoted: " #" starts a comment
        if let r = v.range(of: " #") { v = String(v[..<r.lowerBound]) }
        return v.trimmingCharacters(in: .whitespaces)
    }

    static func load() -> (Config?, String?) {
        var c = Config()
        let url = configPath()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (c, nil) }
        for (i, line0) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = line0.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                return (nil, "config line \(i + 1): expected KEY = VALUE: \(line)")
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = parseValue(String(line[line.index(after: eq)...]))
            if !knownKeys.contains(key) {
                // fail loud: an unknown key may be a typo in key_file
                return (nil, "config line \(i + 1): unknown key '\(key)'")
            }
            switch key {
            case "endpoint": c.endpoint = value
            case "model": c.model = value
            case "key_file": c.keyFile = (value as NSString).expandingTildeInPath
            case "key_var": c.keyVar = value
            case "fallback_endpoint": c.fallbackEndpoint = value
            case "fallback_model": c.fallbackModel = value
            case "fallback_key_file": c.fallbackKeyFile = (value as NSString).expandingTildeInPath
            case "fallback_key_var": c.fallbackKeyVar = value
            case "paste_combo": c.pasteCombo = value
            case "copy_combo": c.copyCombo = value
            case "hotkey": c.hotkey = value
            case "hotkey_clipboard": c.hotkeyClipboard = value
            case "max_tokens": c.maxTokens = min(max(Int(value) ?? c.maxTokens, 1), 32768)
            case "timeout": c.timeoutSec = Double(value) ?? c.timeoutSec
            default: break
            }
        }
        return (c, nil)
    }

    // The API key at runtime: env NEEDLE_API_KEY wins, else key_file/key_var.
    // Never logged.
    func resolveKey(primary: Bool = true) -> String? {
        if primary {
            if let k = apiKeyEnv, !k.isEmpty { return k }
            guard let path = keyFile, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return Self.keyFromEnvFile(text, names: [keyVar, "NEEDLE_API_KEY"])
        } else {
            if let k = fallbackKeyEnv, !k.isEmpty { return k }
            guard let path = fallbackKeyFile, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return Self.keyFromEnvFile(text, names: [fallbackKeyVar, "NEEDLE_API_KEY"])
        }
    }

    static func keyFromEnvFile(_ text: String, names: [String]) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
            if names.contains(k) {
                return parseValue(String(l[l.index(after: eq)...]))
            }
        }
        return nil
    }
}

// MARK: - Actions (ported from needle-writes internal/action)

struct Action {
    let name: String
    let description: String
    let systemPrompt: String
    let temperature: Double
}

enum Actions {
    static let maxSelectionRunes = 20000
    private static let onlyText = "Output ONLY the resulting text with no preamble, no explanation, no quotes or code fences around it."

    static let builtins: [Action] = [
        Action(name: "proofread", description: "Fix spelling, grammar and punctuation, keep the voice",
               systemPrompt: "You are a meticulous copy editor. Correct spelling, grammar and punctuation in the user's text. Preserve the original wording, tone and meaning wherever possible. " + onlyText,
               temperature: 0.2),
        Action(name: "shorten", description: "Cut to roughly half the length, keep key information",
               systemPrompt: "Rewrite the user's text to about half its length while keeping every key fact and the overall meaning. " + onlyText,
               temperature: 0.4),
        Action(name: "professional", description: "Rewrite in a clear professional tone",
               systemPrompt: "Rewrite the user's text in a clear, professional tone suitable for workplace communication. Preserve the meaning and all facts. " + onlyText,
               temperature: 0.5),
        Action(name: "casual", description: "Rewrite in a friendly conversational tone",
               systemPrompt: "Rewrite the user's text in a friendly, conversational tone without losing its meaning. " + onlyText,
               temperature: 0.7),
        Action(name: "summarize", description: "Concise bullet-point summary",
               systemPrompt: "Summarize the user's text as concise bullet points covering the main ideas. " + onlyText,
               temperature: 0.3),
        Action(name: "translate-en", description: "Translate to English",
               systemPrompt: "Translate the user's text into natural English. If it is already English, return it unchanged. " + onlyText,
               temperature: 0.3),
        Action(name: "translate-el", description: "Translate to Greek",
               systemPrompt: "Translate the user's text into natural Modern Greek. " + onlyText,
               temperature: 0.3),
        Action(name: "agentify", description: "Rewrite as a clear, direct prompt for an AI agent",
               systemPrompt: "You convert the user's rough notes, dictation, or draft prompt into a clear, direct instruction for an AI agent. Capture the intent exactly: remove filler and ambiguity, keep every requirement, and phrase it as concise imperative prose. Do NOT add steps, scope, or detail the user did not imply or clearly need. Always write the result in English, translating when the input is another language. " + onlyText,
               temperature: 0.4),
        Action(name: "agentify+", description: "Full agent brief: context, steps, acceptance criteria",
               systemPrompt: "You convert the user's rough notes, dictation, or draft prompt into a well-structured instruction for an AI agent. First capture the intent exactly and resolve ambiguity. Then EXPAND it into a complete brief: the goal, relevant context and constraints, concrete steps or deliverables, and acceptance criteria that make the finished result verifiable. Keep the expansion faithful to what the user implied — never invent unrelated requirements. Always write the result in English, translating when the input is another language. " + onlyText,
               temperature: 0.6),
        Action(name: "publisher-opinion", description: "Original text, then a book publisher's opinion of it",
               systemPrompt: """
               You are an experienced book publisher's editor assessing a passage. \
               Reply in exactly two parts:
               1. The user's original text, reproduced verbatim (not one word changed).
               2. A blank line, then a short publisher's opinion of the passage: its market \
               fit and audience, editorial strengths, what weakens it, and a one-line verdict \
               (acquire / revise / pass) with the reason. Honest and specific, 80-150 words, \
               written in the same language as the passage.
               Output ONLY those two parts, no preamble or code fences.
               """,
               temperature: 0.5),
        Action(name: "book-reviewer", description: "Original text, then a novel/poetry reviewer's critique",
               systemPrompt: """
               You are a literary book reviewer who covers fiction and poetry. \
               Reply in exactly two parts:
               1. The user's original text, reproduced verbatim (not one word changed).
               2. A blank line, then a reviewer's critique of the passage as a work of \
               literature: voice and style, imagery and language, rhythm and sound (for \
               poetry) or characterization, scene craft and tension (for prose/novels), \
               what it does well, where it falls flat, and a closing one-line assessment. \
               Judge it seriously as a reader would — specific quotes from the passage as \
               evidence, no generic praise. 100-180 words, written in the same language as \
               the passage.
               Output ONLY those two parts, no preamble or code fences.
               """,
               temperature: 0.6),
    ]

    static func get(_ name: String) -> Action? {
        builtins.first { $0.name == name }
    }
}

// Output post-filtering: strip LLM preamble lines, wrapping fences, quotes.
enum Cleaner {
    private static let preambleRE = try! NSRegularExpression(
        pattern: "(?i)^(?:here(?:'|\\u2019)?s|here is|here are|sure,? here (?:is|are)|below (?:is|are)|the (?:corrected|proofread|rewritten|shortened|summarized|translated|improved|resulting) (?:text|version|result|is|following))[^\\n]*:?\\s*\\n+\\s*|^(?:certainly|of course|no problem)\\s*[!?.]*:?\\s*\\n+\\s*")
    private static let fenceLangTags: Set<String> = [
        "text", "txt", "plain", "code", "output", "markdown", "md", "html", "css",
        "json", "yaml", "yml", "toml", "xml", "csv", "go", "python", "py", "js",
        "javascript", "ts", "typescript", "jsx", "tsx", "bash", "sh", "shell",
        "zsh", "sql", "rust", "c", "cpp", "h", "java", "kotlin", "ruby", "php",
        "diff", "mermaid", "dot",
    ]

    static func clean(_ out: String) -> String {
        var s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..., in: s)
        if let m = preambleRE.firstMatch(in: s, range: range),
           let r = Range(m.range, in: s) {
            s = String(s[r.upperBound...])
        }
        if s.hasPrefix("```") && s.hasSuffix("```") && s.components(separatedBy: "```").count == 3 {
            var rest = String(s.dropFirst(3).dropLast(3))
            if let nl = rest.firstIndex(of: "\n") {
                let tag = String(rest[..<nl]).trimmingCharacters(in: .whitespaces).lowercased()
                if tag.isEmpty || fenceLangTags.contains(tag) {
                    let stripped = String(rest[rest.index(after: nl)...])
                    if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rest = stripped
                    }
                }
            }
            s = rest
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 &&
           !s.dropFirst().dropLast().contains("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Engine (OpenAI-compatible chat completions)

final class Engine {
    let cfg: Config

    init(_ cfg: Config) { self.cfg = cfg }

    // Returns the cleaned result and which endpoint served it ("primary" or
    // "fallback"), or throws EngineError(message). The primary (local)
    // engine is tried first; the fallback only when the primary fails.
    struct EngineError: Error { let message: String }
    struct Result { let text: String; let source: String }

    func run(action: Action, text: String) async throws -> Result {
        let runes = Array(text)
        if runes.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EngineError(message: "empty selection")
        }
        if runes.count > Actions.maxSelectionRunes {
            throw EngineError(message: "selection too large: \(runes.count) runes (max \(Actions.maxSelectionRunes))")
        }
        do {
            let out = try await complete(action: action, text: text,
                                         endpoint: cfg.endpoint, model: cfg.model,
                                         key: cfg.resolveKey(primary: true))
            return Result(text: out, source: "primary")
        } catch let e as EngineError where cfg.fallbackEndpoint != nil {
            // local engine failed: try the secondary endpoint once
            log("WARNING: selection sent to fallback endpoint \(cfg.fallbackEndpoint!) — text leaves this machine")
            do {
                let out = try await complete(action: action, text: text,
                                             endpoint: cfg.fallbackEndpoint!, model: cfg.fallbackModel,
                                             key: cfg.resolveKey(primary: false))
                return Result(text: out, source: "fallback")
            } catch let e2 as EngineError {
                throw EngineError(message: "primary: \(e.message); fallback: \(e2.message)")
            }
        } catch let e where cfg.fallbackEndpoint != nil {
            // a transport failure (server down, timeout) also falls back
            log("WARNING: selection sent to fallback endpoint \(cfg.fallbackEndpoint!) — text leaves this machine")
            do {
                let out = try await complete(action: action, text: text,
                                             endpoint: cfg.fallbackEndpoint!, model: cfg.fallbackModel,
                                             key: cfg.resolveKey(primary: false))
                return Result(text: out, source: "fallback")
            } catch let e2 as EngineError {
                throw EngineError(message: "primary: \(e.localizedDescription); fallback: \(e2.message)")
            }
        }
    }

    private func complete(action: Action, text: String, endpoint: String, model: String, key: String?, maxTokens: Int? = nil) async throws -> String {
        let budget = maxTokens ?? cfg.maxTokens
        guard let base = URL(string: endpoint) else { throw EngineError(message: "bad endpoint: \(endpoint)") }
        var url = base
        url.appendPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = cfg.timeoutSec
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": action.temperature,
            "max_tokens": budget,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineError(message: "engine HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw EngineError(message: "engine returned no content")
        }
        // thinking models spend the budget on reasoning before answering: a
        // "length" finish means the visible answer was cut off. Retry once
        // with a doubled budget (up to 4x the configured one).
        if (first["finish_reason"] as? String) == "length" && budget < cfg.maxTokens * 4 {
            log("engine hit the token budget (\(budget)); retrying doubled")
            return try await complete(action: action, text: text, endpoint: endpoint, model: model,
                                      key: key, maxTokens: budget * 2)
        }
        let out = Cleaner.clean(content)
        if out.isEmpty { throw EngineError(message: "engine returned an empty result") }
        return out
    }
}

// MARK: - Capture & delivery (NSPasteboard + CGEvent)

final class Input {
    // Parse "ctrl+shift+v" style combos into (modifiers, keycode).
    static func parseCombo(_ s: String) -> (NSEvent.ModifierFlags, Int)? {
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in s.lowercased().split(separator: "+") {
            switch part {
            case "ctrl", "control": mods.insert(.control)
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            default: key = String(part)
            }
        }
        guard let k = key, let code = Self.keycode(k) else { return nil }
        return (mods, code)
    }

    static func keycode(_ name: String) -> Int? {
        if name.count == 1, let c = name.first {
            let map: [Character: Int] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
                "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
                "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
                "j": 38, "k": 40, "n": 45, "m": 46,
            ]
            return map[c]
        }
        return nil
    }

    static func sendCombo(_ combo: String) -> Bool {
        guard let (mods, code) = parseCombo(combo) else { return false }
        // a dedicated source: the combined session state still holds the
        // physical Option/Control the user is holding when we synthesize,
        // which turns Cmd+C into Cmd+Opt+Ctrl+C for the target app.
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let rawMods = mods.rawValue
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else { return false }
        down.flags = CGEventFlags(rawValue: UInt64(rawMods))
        up.flags = CGEventFlags(rawValue: UInt64(rawMods))
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    static func pasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func pasteboardChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    static func setPasteboardString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // Snapshot the general pasteboard (string content; enough for text work).
    static func snapshotPasteboard() -> String? { pasteboardString() }
}

// MARK: - Accessibility selection (the Easydict / Apple-Writing-Tools way)
//
// Read the focused element's AXSelectedText directly — no synthesized Cmd+C,
// no clipboard touched. Replace it by SETTING AXSelectedText — no Cmd+V
// either. Both need the Accessibility grant; the simulated-key path stays as
// fallback for apps with broken AX (browsers, some Electron apps).

enum AXSelection {
    // (focused element of the frontmost app, selected text) or nil
    static func read() -> (element: AXUIElement, text: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return (element, text)
    }

    // replace the selection in place (Apple Writing Tools' mechanism)
    static func replace(_ element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // the element must still belong to the app we captured from, and the app
    // must still be frontmost — otherwise deliver via the paste path instead
    static func stillValid(_ element: AXUIElement, pid: pid_t?) -> Bool {
        guard let pid, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == pid else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focused as! AXUIElement, element)
    }
}

// MARK: - Palette (native NSPanel)

// Filter field that forwards palette navigation keys to the panel.
final class PaletteField: NSTextField {
    weak var palette: Palette?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let p = palette, p.handleFieldKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if let p = palette, p.handleFieldKey(event) { return }
        super.keyDown(with: event)
    }
}

final class Palette: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let table = NSTableView()
    private let filter = PaletteField()
    private let preview = NSTextField(labelWithString: "")
    private var items: [(display: String, action: Action)] = []
    private var onPick: ((Action) -> Void)?
    private var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu          // above the frontmost app's windows
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        filter.placeholderString = "action…"
        filter.translatesAutoresizingMaskIntoConstraints = false
        filter.delegate = self      // live filtering as you type
        filter.palette = self       // forward arrows/Enter/Esc/Cmd+digits
        filter.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        preview.font = NSFont.systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingHead
        preview.maximumNumberOfLines = 1
        preview.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.width = 540
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        table.target = self
        table.action = #selector(confirm)          // single click picks
        table.doubleAction = #selector(confirm)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(preview)
        content.addSubview(filter)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            filter.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4),
            filter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            filter.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        contentView = content
        delegate = self   // NSWindow calls windowDidResignKey on its delegate
    }

    // show() with the already-captured text previewed at the top
    func show(actions: [Action], captured: String,
              onPick: @escaping (Action) -> Void, onCancel: @escaping () -> Void) {
        let nameWidth = actions.map { $0.name.count }.max() ?? 12
        items = actions.map { ("\($0.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)) — \($0.description)", $0) }
        self.onPick = onPick
        self.onCancel = onCancel
        let oneLine = captured.replacingOccurrences(of: "\n", with: " ")
        preview.stringValue = "▸ " + String(oneLine.prefix(120)) + (oneLine.count > 120 ? "…" : "")
        filter.stringValue = ""
        applyFilter()
        // center near the mouse, clamped below the menu bar
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let sf = screen?.frame {
            let x = min(max(mouse.x - 280, sf.minX + 20), sf.maxX - 580)
            let top = sf.maxY - 25 - 340            // 25pt below the menu bar
            let y = min(max(mouse.y - 170, sf.minY + 20), top)
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        makeFirstResponder(filter)
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    // Keys arriving in the filter field that belong to the palette.
    func handleFieldKey(_ event: NSEvent) -> Bool {
        // Cmd+1..9 quick-pick the Nth visible row
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let n = Int(chars), n >= 1, n <= 9, n <= shown.count {
            table.selectRowIndexes(IndexSet(integer: n - 1), byExtendingSelection: false)
            pick()
            return true
        }
        switch event.keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            pick(); return true
        case UInt16(kVK_Escape):
            // first Esc clears the filter, second Esc cancels the palette
            if !filter.stringValue.isEmpty { filter.stringValue = ""; applyFilter() }
            else { cancelOperation(nil) }
            return true
        case UInt16(kVK_UpArrow):
            move(-1); return true
        case UInt16(kVK_DownArrow):
            move(1); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        let cur = max(table.selectedRow, 0)
        let next = max(0, min(shown.count - 1, cur + delta))
        guard shown.isEmpty || next != cur || table.selectedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func confirm() { pick() }

    private func applyFilter() {
        let q = filter.stringValue.lowercased()
        // match against name and description, not the padded display line
        let visible = items.filter {
            q.isEmpty
            || $0.action.name.lowercased().contains(q)
            || $0.action.description.lowercased().contains(q)
        }
        shown = visible
        table.reloadData()
        if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    private var shown: [(display: String, action: Action)] = []

    // the table's content: without these the palette shows an empty list
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < shown.count else { return nil }
        return shown[row].display
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    // an NSPanel with .nonactivatingPanel must still accept key focus
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func pick() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let action = shown[row].action
        orderOut(nil)
        onPick?(action)
    }

    // Esc outside the field, and focus loss, both cancel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onCancel?()
    }

    // NSWindowDelegate-style: NSWindow calls these on itself; no override.
    func windowDidResignKey(_ notification: Notification) {
        // clicking another app while the palette is open dismisses it
        if isVisible { orderOut(nil); onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if handleFieldKey(event) { return }
        super.keyDown(with: event)
    }
}

// MARK: - Hotkey (CGEvent tap: sees AND swallows the combo, so it never
// leaks to the frontmost app. Carbon handlers swallowed each other; NSEvent
// monitors cannot consume the event.)

final class Hotkey {
    final class Box {
        let want: CGEventFlags
        let code: Int
        let action: () -> Void
        var port: CFMachPort?
        init(_ w: CGEventFlags, _ c: Int, _ a: @escaping () -> Void) { want = w; code = c; action = a }
    }

    private var tap: CFMachPort?
    private var box: Box?

    // combo like "ctrl+opt+o"
    func register(_ combo: String, action: @escaping () -> Void) -> Bool {
        // re-registering: tear the old tap down first (no double-fire, no leak)
        if let old = tap {
            CGEvent.tapEnable(tap: old, enable: false)
            if let b = box {
                CFMachPortInvalidate(old)
                Unmanaged<Hotkey.Box>.fromOpaque(Unmanaged.passUnretained(b).toOpaque()).release()
            }
            tap = nil
            box = nil
        }
        guard let (mods, code) = Input.parseCombo(combo) else { return false }
        let b = Box(CGEventFlags(rawValue: UInt64(mods.rawValue)), code, action)
        box = b
        let ptr = Unmanaged.passRetained(b).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, refcon in
                // a disabled tap leaks every combo to the app: re-arm it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let bx = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
                        if let p = bx.port { CGEvent.tapEnable(tap: p, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown, let refcon else { return Unmanaged.passUnretained(event) }
                let bx = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
                let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                let evCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if evCode == bx.code, event.flags.intersection(relevant) == bx.want {
                    // consume NOW and hand the work to the main queue: the
                    // tap is serviced on the main run loop, and anything
                    // slow here (usleep polling) blocks event processing,
                    // times the tap out, and leaks the combo to the app.
                    DispatchQueue.main.async { bx.action() }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: ptr) else {
            Unmanaged<Box>.fromOpaque(ptr).release()
            return false
        }
        tap = t
        b.port = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}

// MARK: - Services menu (the Apple-Writing-Tools-style context menu)
//
// Each action is registered in the bundle's Info.plist NSServices: any app's
// text-field right-click menu shows Services > needle: <action>. The client
// app hands over the selection on an NSPasteboard and inserts whatever we
// write back on the returned pasteboard — no keystroke injection, no
// Accessibility permission on this path. The handler returns immediately and
// fills the returned pasteboard when the engine answers (documented async
// service pattern; the client waits for it).

final class ServiceHandler: NSObject {
    weak var app: AppDelegate?

    @objc func svcProofread(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("proofread", pboard, error: error)
    }
    @objc func svcShorten(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("shorten", pboard, error: error)
    }
    @objc func svcProfessional(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("professional", pboard, error: error)
    }
    @objc func svcCasual(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("casual", pboard, error: error)
    }
    @objc func svcSummarize(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("summarize", pboard, error: error)
    }
    @objc func svcTranslateEn(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("translate-en", pboard, error: error)
    }
    @objc func svcTranslateEl(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("translate-el", pboard, error: error)
    }
    @objc func svcAgentify(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("agentify", pboard, error: error)
    }
    @objc func svcAgentifyPlus(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("agentify+", pboard, error: error)
    }
    @objc func svcPublisherOpinion(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("publisher-opinion", pboard, error: error)
    }
    @objc func svcBookReviewer(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) -> NSPasteboard {
        handle("book-reviewer", pboard, error: error)
    }

    private func handle(_ name: String, _ pboard: NSPasteboard, error: NSErrorPointer) -> NSPasteboard {
        let out = NSPasteboard()
        guard let action = Actions.get(name),
              let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let error {
                error.pointee = NSError(domain: "needle-mac", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "needle: nothing selected"])
            }
            return out
        }
        // Return the (still empty) reply pasteboard right away and fill it
        // when the engine answers: the client app waits for its content
        // before inserting (the documented async-service pattern).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let engine = self.app?.engine else { return }
            Task {
                do {
                    let r = try await engine.run(action: action, text: text)
                    out.clearContents()
                    out.setString(r.text, forType: .string)
                    await MainActor.run { self.app?.noteResult(action: name, source: r.source) }
                } catch let e as Engine.EngineError {
                    // leave the pasteboard empty: the client inserts nothing
                    await MainActor.run { self.app?.noteResult(action: name, source: "failed: \(e.message)") }
                } catch {
                    await MainActor.run { self.app?.noteResult(action: name, source: "failed") }
                }
            }
        }
        return out
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg: Config!
    var engine: Engine!
    var statusItem: NSStatusItem!
    var palette: Palette!
    var hotkey = Hotkey()
    var hotkeyClip = Hotkey()
    var services = ServiceHandler()
    var busy = false
    var noPaste = false
    var hold = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let (loaded, err) = Config.load()
        guard let c = loaded else {
            FileHandle.standardError.write("needle-mac: \((err ?? "config error"))\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        cfg = c
        engine = Engine(c)
        // Services menu: the app's right-click > Services entries (the
        // Apple-Writing-Tools-style path; needs no Accessibility grant).
        services.app = self
        NSApp.servicesProvider = services

        // CLI overrides
        let args = CommandLine.arguments
        if args.contains("--no-paste") { noPaste = true }
        if args.contains("--hold") { hold = true }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✎"
        statusItem.button?.toolTip = "\(c.endpoint) · \(c.model)"
        let menu = NSMenu()
        menu.delegate = self        // refresh the Accessibility row on open
        let state = NSMenuItem(title: "endpoint: \(c.endpoint) · \(c.model)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        for a in Actions.builtins {
            let it = NSMenuItem(title: a.name, action: #selector(runFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = a.name
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let acc = NSMenuItem(title: "Accessibility: checking…", action: nil, keyEquivalent: "")
        acc.isEnabled = false
        acc.identifier = NSUserInterfaceItemIdentifier("ax")
        menu.addItem(acc)
        let grant = NSMenuItem(title: "Grant Accessibility permission…", action: #selector(promptAccessibility), keyEquivalent: "")
        grant.target = self
        grant.identifier = NSUserInterfaceItemIdentifier("grant")
        menu.addItem(grant)
        menu.addItem(NSMenuItem(title: "Open Accessibility settings", action: #selector(openAXSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        palette = Palette()
        if !hotkey.register(c.hotkey, action: { [weak self] in self?.openPalette(clipboardOnly: false) }) {
            FileHandle.standardError.write("needle-mac: could not register hotkey '\(c.hotkey)'\n".data(using: .utf8)!)
        }
        if !hotkeyClip.register(c.hotkeyClipboard, action: { [weak self] in self?.openPalette(clipboardOnly: true) }) {
            FileHandle.standardError.write("needle-mac: could not register hotkey '\(c.hotkeyClipboard)'\n".data(using: .utf8)!)
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            FileHandle.standardError.write("needle-mac: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)\n".data(using: .utf8)!)
        }
        // --demo: open the palette right away (lets the tool be screenshotted
        // and QA'd without a real selection)
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.palette.show(actions: Actions.builtins, captured: "demo: this text would be your selection",
                                   onPick: { _ in }, onCancel: {})
            }
        }
    }

    // refresh the Accessibility row every time the menu opens
    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        if let acc = menu.items.first(where: { $0.identifier?.rawValue == "ax" }) {
            acc.title = trusted ? "Accessibility: granted" : "Accessibility: NOT granted"
        }
        if let grant = menu.items.first(where: { $0.identifier?.rawValue == "grant" }) {
            grant.isHidden = trusted
        }
    }

    // macOS adds the app to the Accessibility list (toggle off) when we ask
    // for permission with the prompt option — this is the only supported way
    // to make the entry appear.
    @objc func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            finish(message: "Accessibility already granted", code: 0)
        } else {
            log("prompting for Accessibility; the app should now appear in the list (enable its toggle)")
            finish(message: "needle-mac added to the Accessibility list — enable its toggle, then it works immediately", code: 2)
        }
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func runFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let a = Actions.get(name), !busy else { return }
        // menu path: act on what is already on the clipboard (the header row
        // in the menu says so); no Cmd+C synthesis here.
        guard let clip = Input.pasteboardString(),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(message: "clipboard is empty — copy the text first", code: 2)
            return
        }
        runAction(a, selection: clip, axElement: nil, frontApp: NSWorkspace.shared.frontmostApplication, clipboardOnly: false)
    }

    func openPalette(clipboardOnly: Bool) {
        log("hotkey fired (clipboardOnly=\(clipboardOnly), ax=\(AXIsProcessTrusted()))")
        guard !busy else {
            // the user pressed the hotkey again: tell them we are still working
            flashStatus("✎ …")
            return
        }
        if !AXIsProcessTrusted() {
            log("no Accessibility permission — cannot synthesize Cmd+C")
            finish(message: "Accessibility permission missing — enable needle-mac in System Settings, then quit & reopen it", code: 4)
            return
        }
        // Capture BEFORE the palette takes focus. Primary path (Easydict /
        // Apple Writing Tools style): read AXSelectedText from the focused
        // element — no clipboard round-trip. Fallback: synthesize the copy
        // combo against the frontmost app (browsers and some Electron apps
        // do not expose AXSelectedText).
        // The capture runs on a background queue: the AX read is a
        // cross-process call and the Cmd+C fallback polls with sleeps —
        // blocking the main thread would stall the event tap that services
        // our own hotkeys.
        let frontApp = NSWorkspace.shared.frontmostApplication
        busy = true
        startBusyAnimation()
        let copyCombo = cfg.copyCombo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var axElement: AXUIElement?
            var text: String?
            if let (element, axText) = AXSelection.read(),
               !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                axElement = element
                text = axText
                log("captured \(axText.count) chars via AXSelectedText")
            } else {
                // changeCount, not string equality: copying text identical to
                // the current clipboard still advances the board.
                let before = Input.pasteboardChangeCount()
                _ = Input.sendCombo(copyCombo)
                for _ in 0..<10 {
                    usleep(60_000)
                    if NSPasteboard.general.changeCount != before,
                       let now = Input.pasteboardString(),
                       !now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = now; break }
                }
                if text != nil { log("captured via Cmd+C fallback") }
            }
            // No text: the app may ignore synthesized Cmd+C. Do NOT silently
            // fall back to the stale clipboard (it would rewrite the wrong
            // text); say so instead.
            guard let sel = text else {
                log("capture failed: no AXSelectedText and pasteboard unchanged after Cmd+C")
                self.finish(message: "could not capture a selection — select text first (or copy it, then use the menu)", code: 2)
                return
            }
            DispatchQueue.main.async {
                self.busy = false
                self.stopBusyAnimation()
                self.palette.show(actions: Actions.builtins, captured: sel,
                                  onPick: { [weak self] a in self?.runAction(a, selection: sel, axElement: axElement, frontApp: frontApp, clipboardOnly: clipboardOnly) },
                                  onCancel: {})
            }
        }
    }

    // run the engine on an already-captured selection, then deliver
    func runAction(_ action: Action, selection: String, axElement: AXUIElement?, frontApp: NSRunningApplication?, clipboardOnly: Bool) {
        guard !busy else { return }
        busy = true
        startBusyAnimation()
        let pasteCombo = cfg.pasteCombo
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.engine.run(action: action, text: selection)
                // re-activate the app the user was in before delivering;
                // wait without blocking the main thread (the event tap runs
                // on its run loop)
                frontApp?.activate()
                try? await Task.sleep(nanoseconds: 150_000_000)
                await MainActor.run {
                    self.deliver(r.text, axElement: axElement, frontPID: frontApp?.processIdentifier, pasteCombo: pasteCombo, source: r.source, clipboardOnly: clipboardOnly)
                }
            } catch let e as Engine.EngineError {
                self.finish(message: "\(action.name) failed — \(e.message)", code: 1)
            } catch {
                self.finish(message: "\(action.name) failed — \(error.localizedDescription)", code: 1)
            }
        }
    }

    // MARK: busy feedback + cancel

    private var busyTimer: Timer?
    private var busyDots = 0

    func startBusyAnimation() {
        busyDots = 0
        busyTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.busyDots = (self.busyDots + 1) % 4
            self.statusItem.button?.title = "✎" + String(repeating: ".", count: self.busyDots)
        }
    }

    func stopBusyAnimation() {
        busyTimer?.invalidate()
        busyTimer = nil
    }

    func deliver(_ result: String, axElement: AXUIElement?, frontPID: pid_t?, pasteCombo: String, source: String, clipboardOnly: Bool = false) {
        let t0 = Date()
        if noPaste || hold || clipboardOnly {
            // leave the result on the clipboard; do not restore
            Input.setPasteboardString(result)
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            finish(message: "\(noPaste || clipboardOnly ? "clipboard" : "result") in \(secs)s (\(source)) — paste it yourself", code: 0)
            return
        }
        // Primary delivery (Apple Writing Tools style): set AXSelectedText on
        // the element we captured from — replaces the selection in place, no
        // keystrokes, no clipboard touched. Re-verify the element still
        // belongs to the app we captured from: the LLM call can take minutes
        // and the user may have switched fields or apps meanwhile.
        if let el = axElement, AXSelection.stillValid(el, pid: frontPID),
           AXSelection.replace(el, with: result) {
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            log("delivered via AXSelectedText")
            finish(message: "done in \(secs)s (\(source))", code: 0)
            return
        }
        // Fallback: clipboard + synthesized paste, then restore.
        let before = Input.snapshotPasteboard()
        Input.setPasteboardString(result)
        let ourCC = Input.pasteboardChangeCount()
        if !Input.sendCombo(pasteCombo) {
            finish(message: "could not inject the paste combo", code: 4)
            return
        }
        // Give the target app time to consume the pasteboard, then restore
        // only if nobody else claimed the board after our claim (changeCount,
        // not string equality: the app may paste rich text or identical text).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if Input.pasteboardChangeCount() == ourCC, let b = before {
                Input.setPasteboardString(b)
            }
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            self?.finish(message: "done in \(secs)s (\(source))", code: 0)
        }
    }

    // A note for the Services-menu path (no paste delivery there).
    func noteResult(action: String, source: String) {
        if source.hasPrefix("failed") {
            finish(message: "\(action) \(source)", code: 1)
        } else {
            finish(message: "\(action) done (\(source))", code: 0)
        }
    }

    func finish(message: String, code: Int) {
        DispatchQueue.main.async {
            self.busy = false
            self.stopBusyAnimation()
            self.statusItem.button?.title = code == 0 ? "✎ ✓" : "✎ !"
            self.notify(message, code: code)
            if code != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.statusItem.button?.title = "✎"
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.statusItem.button?.title = "✎"
                }
            }
        }
    }

    // brief status-item flash without touching busy state
    func flashStatus(_ title: String) {
        statusItem.button?.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.busy else { return }
            self.statusItem.button?.title = "✎"
        }
    }

    func notify(_ message: String, code: Int) {
        let n = NSUserNotification()
        n.title = "needle-mac"
        n.informativeText = message
        NSUserNotificationCenter.default.deliver(n)
    }
}

// MARK: - main

// Subcommands mirror needle-writes: `needle-mac <action>` runs one action
// against the running daemon? No — the daemon owns the hotkey; direct
// actions here run in-process (useful from scripts and keybinds).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

let args = CommandLine.arguments
if args.count >= 2, args[1] == "-list" {
    for a in Actions.builtins { print("\(a.name) — \(a.description)") }
    exit(0)
}
if args.count >= 2, args[1] != "daemon" {
    guard let a = Actions.get(args[1]) else {
        FileHandle.standardError.write("needle-mac: unknown action '\(args[1])' (see -list)\n".data(using: .utf8)!)
        exit(64)
    }
    // one-shot: read text from stdin (or the pasteboard), run, print/claim
    let (loaded, err) = Config.load()
    guard let c = loaded else {
        FileHandle.standardError.write("needle-mac: \((err ?? "config error"))\n".data(using: .utf8)!)
        exit(64)
    }
    let engine = Engine(c)
    var text = ""
    if isatty(0) == 0 { text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    else { text = Input.pasteboardString() ?? "" }
    let sem = DispatchSemaphore(value: 0)
    var code = 1
    Task {
        do {
            let r = try await engine.run(action: a, text: text)
            Input.setPasteboardString(r.text)
            print(r.text)
            code = 0
        } catch let e as Engine.EngineError {
            FileHandle.standardError.write("needle-mac: \(e.message)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("needle-mac: \(error)\n".data(using: .utf8)!)
        }
        sem.signal()
    }
    sem.wait()
    exit(Int32(code))
}
app.run()
