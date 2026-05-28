# Ask

A native macOS app that opens the **opencode web UI** in a chromeless window via a global keyboard shortcut. Uses Apple's built-in WebKit (WKWebView) -- no Electron, no bundled Chromium.

---

## How it works

1. The app runs as a regular macOS app (visible in the Dock and Cmd+Tab).
2. Press the configured shortcut (default: `Ctrl+Shift+A`) from anywhere in macOS.
3. The app checks whether an opencode server is already running on the configured port.
4. If not, it starts one:
   ```bash
   opencode serve --hostname 127.0.0.1 --port 40973
   ```
5. A chromeless native window opens with the opencode web UI, focused on the configured project directory.
6. Press `Esc` to hide the window. Press the shortcut again to bring it back.

---

## Build

Requires Swift 5.9+ (ships with Xcode 15+).

```bash
cd ask-webkit
swift build
```

## Run

```bash
swift run Ask
```

Or run the built binary directly:

```bash
.build/debug/Ask
```

The app runs in the background. Press `Ctrl+Shift+A` to open the web UI.

---

## Configuration

Shared with the `ask` CLI at `~/.config/ask/config.yml`. The app uses these keys:

```yaml
model: google/gemini-3.5-flash
shortcut: ctrl+shift+a

web:
  working_dir: ~/Documents/ASK
  port: 40973
  # password: mysecret  # uncomment to protect the web UI
```

| Key | Description |
|---|---|
| `model` | Default model for new sessions. Set via a project-local `opencode.json` in the working directory. |
| `shortcut` | Global keyboard shortcut. Format: modifiers joined with `+`. Supported modifiers: `ctrl`, `shift`, `alt`/`option`, `cmd`/`command`. Key: any letter `a`-`z`, digit `0`-`9`, or `space`/`return`/`escape`. |
| `web.working_dir` | Working directory for `opencode serve`. This is the project opencode operates on. |
| `web.port` | Local port for the opencode web server (1024-65535). |
| `web.password` | Password to protect the web UI. When set, opencode's built-in HTTP auth is enabled via `OPENCODE_SERVER_PASSWORD`. Leave empty or omit to disable. |

If the config file does not exist, the app creates it with defaults on first run.

Config is re-read on every shortcut press, so edits take effect without restarting the app.

---

## Permissions

The app registers a global hotkey using Carbon APIs. On modern macOS, this may require:

**System Settings > Privacy & Security > Accessibility**

Add the `Ask` binary (or Terminal/iTerm if running via `swift run`).

If the shortcut fails to register, the app shows an alert with instructions.

---

## Window behavior

- **First press**: opens the chromeless window.
- **Subsequent presses**: toggles visibility (show/hide).
- **Esc**: hides the window.
- **Close button**: hides the window (does not destroy it).
- Window size and position are remembered across sessions.

---

## Architecture

```
ask-webkit/
  Package.swift              # Swift Package Manager manifest
  Sources/
    Ask/
      main.swift             # App entry point, NSApplication setup
      Config.swift           # YAML config loader, shortcut parser
      HotKey.swift           # Carbon global hotkey registration
      OpencodeServer.swift   # Server health check and process lifecycle
      WebWindow.swift        # Chromeless NSWindow + WKWebView
```

### Dependencies

- **Yams** (Swift YAML parser) -- only external dependency.
- **AppKit**, **WebKit**, **Carbon** -- macOS system frameworks.

### Server lifecycle

- The app checks the configured port with an HTTP HEAD request.
- If unreachable, it spawns `opencode serve` as a child process.
- If it started the server, it terminates it on app quit.
- If a server was already running (started externally), it reuses it and leaves it alone.

---

## Autostart at login (optional)

To have the app start automatically at login, create a LaunchAgent:

```bash
mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/com.ask.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ask</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/ask-webkit/.build/debug/Ask</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.ask.plist
```

Update the path to point to your built binary. For a release build:

```bash
swift build -c release
# binary at: .build/release/Ask
```
