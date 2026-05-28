# Ask

Ask is a personal AI assistant with two interfaces that share a single configuration:

1. **Ask CLI** -- an nvim-based chat interface (`src/ask/cli.py`)
2. **Ask Web** -- a native macOS app that opens the opencode web UI in a chromeless window (`ask-webkit/`)

Both read from `~/.config/ask/config.yml`.

---

## Interfaces

### Ask CLI

A terminal tool that turns nvim into an interactive AI chat. Write your message in a vim buffer, save with `:w`, and the response appears automatically.

```bash
ask            # new session
ask history    # resume a previous session via fzf
```

Sessions are stored as `.md` files in `~/ask-sessions/`. The CLI calls `opencode run` to get responses, sending the full conversation history each turn.

Requires: Python 3.10+, nvim, fzf.

```bash
cd src && python3 -m venv .venv && .venv/bin/pip install -e .
```

### Ask Web

A native macOS app that opens the opencode web UI in a chromeless window via a global keyboard shortcut. Built with Swift, AppKit, and WKWebView -- no Electron, no bundled Chromium.

Press `Ctrl+Shift+A` from anywhere in macOS to open or toggle the window.

Requires: Swift 5.9+ (Xcode 15+), opencode.

```bash
cd ask-webkit && swift build && swift run Ask
```

---

## Configuration

Auto-created on first run at `~/.config/ask/config.yml`:

```yaml
model: google/gemini-3.5-flash
sessions_dir: ~/ask-sessions
command: opencode run
shortcut: ctrl+shift+a

web:
  working_dir: ~/Documents/ASK
  port: 40973
  # password: mysecret  # uncomment to protect the web UI
```

### Config keys

| Key | Used by | Description |
|---|---|---|
| `model` | CLI + Web | Model ID in `provider/model` format (e.g. `google/gemini-3.5-flash`). CLI passes it to `--model`. Web writes it to `opencode.json` in the working directory. |
| `sessions_dir` | CLI | Directory where session `.md` files are saved. Supports `~`. |
| `command` | CLI | Shell command for the model backend (e.g. `opencode run`). |
| `shortcut` | Web | System-wide keyboard shortcut. Format: modifiers joined with `+`. |
| `web.working_dir` | Web | Project directory where `opencode serve` runs. Supports `~`. |
| `web.port` | Web | Local port for the opencode web server (1024--65535). |
| `web.password` | Web | Password to protect the web UI via `OPENCODE_SERVER_PASSWORD`. Leave empty or omit to disable. |

### Shortcut format

Modifiers: `ctrl`, `shift`, `alt` / `option`, `cmd` / `command`.
Keys: `a`--`z`, `0`--`9`, `space`, `return`, `escape`.

Examples: `ctrl+shift+a`, `cmd+shift+o`, `alt+shift+1`.

### System instructions

`~/.config/ask/instructions.md` is prepended to every CLI prompt as a system block. Default:

```
Be concise and direct. Avoid preamble or verbose explanations. Get to the point.
```

This file is only used by the CLI. The web interface uses opencode's own system instructions.

---

## Ask Web -- detailed behavior

### Startup

1. App launches as a regular macOS app (visible in Dock and Cmd+Tab).
2. Reads `~/.config/ask/config.yml`.
3. Validates that `web.working_dir` exists and is a directory.
4. Registers the global shortcut via Carbon `RegisterEventHotKey`.
5. Waits for shortcut press.

### On shortcut press

1. Config is re-read from disk (edits take effect without restarting).
2. Checks whether a server is already responding on `127.0.0.1:{port}` via HTTP HEAD.
3. If no server is running:
   - Writes/updates `opencode.json` in the working directory with the configured `model` (because `opencode serve` does not accept `--model`).
   - Spawns `opencode serve --hostname 127.0.0.1 --port {port}` with cwd set to `web.working_dir`.
   - Polls until the server responds (up to 10 seconds).
4. Opens or focuses a chromeless WKWebView window.
5. Loads `http://127.0.0.1:{port}/{base64url(working_dir)}/session` so the web UI opens directly on the configured project.

If the window is already visible, the shortcut hides it (toggle behavior).

### Project URL encoding

The opencode web SPA uses URL-safe base64 encoding of the directory path as a route slug. For example:

```
/Users/ffrison/Documents/ASK
```

becomes:

```
http://127.0.0.1:40973/L1VzZXJzL2Zmcmlzb24vRG9jdW1lbnRzL0FTSw/session
```

This is handled automatically by `OpencodeServer.projectURL`.

### Window behavior

- Chromeless: transparent titlebar, hidden title, content fills the full frame.
- `Esc` hides the window.
- Close button hides the window (does not destroy it).
- Window size and position are persisted via `NSWindow.setFrameAutosaveName`.
- Initial size: 80% screen width, 85% screen height, centered.

### Server lifecycle

- If the app starts the server, it owns the process and terminates it on app quit.
- If a server was already running on the port (started externally), the app reuses it and does not terminate it on quit.
- The opencode binary is resolved by checking, in order:
  1. `~/.opencode/bin/opencode`
  2. `/usr/local/bin/opencode`
  3. `/opt/homebrew/bin/opencode`
  4. Fallback: `/usr/bin/env opencode` (PATH lookup)

### Permissions

The global hotkey requires Accessibility permission on modern macOS.

**System Settings > Privacy & Security > Accessibility**

Add the `Ask` binary, or Terminal/iTerm if running via `swift run`.

---

## Project layout

```
.
├── README.md                          # this file
├── pyproject.toml                     # Python package definition (CLI)
├── fzf-browse.sh                      # standalone fzf file browser
├── src/
│   └── ask/
│       ├── __init__.py
│       └── cli.py                     # CLI: all logic in one file
└── ask-webkit/
    ├── Package.swift                  # Swift Package Manager manifest
    ├── README.md                      # Web app quick-start guide
    └── Sources/
        └── Ask/
            ├── main.swift             # App entry point, NSApplication setup
            ├── Config.swift           # YAML config loader, shortcut parser
            ├── HotKey.swift           # Carbon global hotkey registration
            ├── OpencodeServer.swift   # Server health check and process lifecycle
            └── WebWindow.swift        # Chromeless NSWindow + WKWebView
```

### Source files (Ask Web)

| File | Responsibility |
|---|---|
| `main.swift` | Creates `NSApplication` as a regular app (`.regular` activation policy), validates config, registers the global shortcut, handles shortcut events by ensuring the server is up and showing/hiding the window. |
| `Config.swift` | Reads `~/.config/ask/config.yml` using Yams. Creates the file with defaults if missing. Parses shortcut strings into Carbon modifier masks and virtual key codes. |
| `HotKey.swift` | Registers/unregisters a system-wide hotkey using Carbon `RegisterEventHotKey` and `InstallEventHandler`. Dispatches the callback to the main thread. |
| `OpencodeServer.swift` | Manages the opencode server process. Health-checks via HTTP HEAD. Starts `opencode serve` as a child process. Writes `opencode.json` to set the model. Provides `baseURL` and `projectURL`. Terminates owned processes on shutdown. |
| `WebWindow.swift` | Creates a chromeless `NSWindow` with `WKWebView`. Handles show/hide/toggle/focus. Monitors `Esc` to hide. Persists window frame. |

### Dependencies

**CLI (Python):**
- `click` -- command-line interface
- `pyyaml` -- YAML config parsing

**Web (Swift):**
- `Yams` -- YAML config parsing (only external dependency)
- AppKit, WebKit, Carbon -- macOS system frameworks

---

## Ask CLI -- detailed behavior

### Change detection

The CLI does not use mtime polling. It MD5-hashes the session file every 0.2s and compares against a cached hash:

- After writing a response, `state["hash"]` is updated in a `finally` block so the watcher does not re-trigger.
- Saving with no content changes produces the same hash and is ignored.
- A crash mid-write still runs `update_hash()` via `finally`.

### Threading model

```
main thread            watcher thread              consumer thread
───────────────        ──────────────              ───────────────
Popen(nvim)            poll hash every 0.2 s       wait on save_event
proc.wait()  ───────>  if hash changed:            clear save_event
stop_event.set()         update state["hash"]      process_save()
                         save_event.set()  ──────> update_hash()  (finally)
                                                   loop back to wait
```

- One consumer thread processes saves serially.
- `save_event` (threading.Event) is the signal; idempotent.
- `hash_lock` (threading.Lock) protects `state["hash"]`.

### nvim communication

nvim is started with a msgpack-RPC socket (`--listen /tmp/ask_{pid}.sock`). The CLI sends keystrokes via `nvim --server ... --remote-send` to lock/unlock the buffer and update the statusline.

### Multi-turn prompts

The full conversation history is sent on every turn as a single prompt to `opencode run`. This is stateless -- opencode has no memory between calls.

---

## Known limitations

- **CLI: no streaming** -- the buffer is locked until the full response arrives.
- **CLI: single session** -- each `ask` process owns one nvim instance.
- **CLI: text only** -- no file attachments.
- **CLI: prompt grows** -- all turns are resent; long conversations hit context limits.
- **Web: macOS only** -- uses AppKit, WKWebView, and Carbon APIs.
- **Web: no dock icon** -- the app runs as a background process; quit via Activity Monitor or `kill`.

---

## Autostart at login (Ask Web)

Create a LaunchAgent:

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
        <string>/path/to/ask-webkit/.build/release/Ask</string>
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

For a release build:

```bash
cd ask-webkit
swift build -c release
# binary at: .build/release/Ask
```
