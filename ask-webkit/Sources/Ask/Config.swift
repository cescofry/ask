import Carbon
import Foundation
import Yams

// ---------------------------------------------------------------------------
// Config model
// ---------------------------------------------------------------------------

struct WebConfig {
    var workingDir: String
    var port: Int
    var password: String
}

struct AppConfig {
    var model: String
    var sessionsDir: String
    var command: String
    var shortcut: String
    var web: WebConfig
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

private let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/ask")
private let configFile = configDir.appendingPathComponent("config.yml")

private let defaultConfig = AppConfig(
    model: "google/gemini-3.5-flash",
    sessionsDir: "~/ask-sessions",
    command: "opencode run",
    shortcut: "ctrl+shift+a",
    web: WebConfig(
        workingDir: NSHomeDirectory() + "/Documents/ASK",
        port: 40973,
        password: ""
    )
)

private let defaultYAML = """
model: google/gemini-3.5-flash
sessions_dir: ~/ask-sessions
command: opencode run
shortcut: ctrl+shift+a

web:
  working_dir: ~/Documents/ASK
  port: 40973
  # password: mysecret  # uncomment to protect the web UI
"""

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

func loadConfig() -> AppConfig {
    let fm = FileManager.default

    // Ensure directory exists
    if !fm.fileExists(atPath: configDir.path) {
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    // Create default config if missing
    if !fm.fileExists(atPath: configFile.path) {
        try? defaultYAML.write(to: configFile, atomically: true, encoding: .utf8)
        return defaultConfig
    }

    // Read and parse
    guard let contents = try? String(contentsOf: configFile, encoding: .utf8),
          let yaml = try? Yams.load(yaml: contents) as? [String: Any]
    else {
        return defaultConfig
    }

    let model = yaml["model"] as? String ?? defaultConfig.model
    let sessionsDir = yaml["sessions_dir"] as? String ?? defaultConfig.sessionsDir
    let command = yaml["command"] as? String ?? defaultConfig.command
    let shortcut = yaml["shortcut"] as? String ?? defaultConfig.shortcut

    var webConfig = defaultConfig.web
    if let web = yaml["web"] as? [String: Any] {
        if let wd = web["working_dir"] as? String {
            webConfig.workingDir = (wd as NSString).expandingTildeInPath
        }
        if let p = web["port"] as? Int, (1024...65535).contains(p) {
            webConfig.port = p
        }
        if let pw = web["password"] as? String, !pw.isEmpty {
            webConfig.password = pw
        }
    }

    return AppConfig(
        model: model,
        sessionsDir: sessionsDir,
        command: command,
        shortcut: shortcut,
        web: webConfig
    )
}

// ---------------------------------------------------------------------------
// Shortcut parser
// ---------------------------------------------------------------------------

struct ParsedShortcut {
    var modifiers: UInt32  // Carbon modifier mask
    var keyCode: UInt32    // Carbon virtual key code
}

func parseShortcut(_ shortcut: String) -> ParsedShortcut? {
    let parts = shortcut.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 2 else { return nil }

    var modifiers: UInt32 = 0
    var key: String?

    for part in parts {
        switch part {
        case "ctrl", "control":
            modifiers |= UInt32(controlKey)
        case "shift":
            modifiers |= UInt32(shiftKey)
        case "alt", "option":
            modifiers |= UInt32(optionKey)
        case "cmd", "command":
            modifiers |= UInt32(cmdKey)
        default:
            key = part
        }
    }

    guard let k = key, let code = keyCodeMap[k] else { return nil }
    return ParsedShortcut(modifiers: modifiers, keyCode: code)
}

// Map of key names to Carbon virtual key codes
private let keyCodeMap: [String: UInt32] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
    "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
    "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
    "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
    "space": 0x31, "return": 0x24, "escape": 0x35,
]
