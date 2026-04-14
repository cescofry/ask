# Ask

A minimal CLI tool that turns **nvim into an interactive Claude chat interface**. Write your message in a vim buffer, save with `:w`, and the response appears automatically — no browser, no GUI, just your editor.

---

## How it works

```
ask
```

1. A timestamped session file is created in `~/ask-sessions/`.
2. nvim opens that file with a `👤 User` header ready for input.
3. You type your message and save (`:w`).
4. Ask detects the change, locks the buffer, calls Claude, and appends the response under a `🤖 Agent` header.
5. The buffer reloads, cursor lands at the new `👤 User` section, insert mode is active.
6. Repeat.

---

## Buffer format

Every session is a plain `.md` file. Turns are delimited by timestamp rulers:

```
━━━━ 👤 User  14:32 ━━━━━━━━━━━━━━━━━━━━

Your message here.

━━━━ 🤖 Agent  14:32 ━━━━━━━━━━━━━━━━━━━━

Claude's response here.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━ 👤 User  14:33 ━━━━━━━━━━━━━━━━━━━━

Your follow-up here.
```

- `━━━━ 👤 User  HH:MM ━━━━━━━━━━━━━━━━━━━━` — opens a user turn
- `━━━━ 🤖 Agent  HH:MM ━━━━━━━━━━━━━━━━━━━━` — opens an agent turn
- `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━` — closes an agent turn (40 `━` chars)

The parser uses `startswith` on the prefix (`━━━━ 👤 User` / `━━━━ 🤖 Agent`), so the timestamp is ignored during parsing. A line of pure `━` characters is treated as a closing ruler and skipped. Session files are valid Markdown.

---

## Commands

```bash
ask            # open a new session
ask history    # pick a previous session with fzf
```

`history` uses `fzf` with a `cat` preview. Selecting a session opens it in nvim with the full watcher active, so the conversation can continue from where it left off.

---

## Installation

Requires Python 3.10+, nvim, and fzf.

```bash
# inside the project directory
python3 -m venv .venv
.venv/bin/pip install -e .
```

The entry point `.venv/bin/ask` is ready to use. Add it to your PATH or alias it:

```bash
alias ask='/path/to/.venv/bin/ask'
```

---

## Configuration

Auto-created on first run at `~/.config/ask/config.yml`:

```yaml
model: haiku
sessions_dir: ~/ask-sessions
command: aifx agent run claude
```

| Key | Description |
|---|---|
| `model` | Model alias or full ID passed to `--model`. Accepts short aliases (`haiku`, `sonnet`, `opus`) or full names (`claude-sonnet-4-6`). |
| `sessions_dir` | Where session `.md` files are saved. Supports `~` expansion. |
| `command` | Shell command used to invoke Claude, split on spaces and called directly (no shell). Required because `claude` is typically a shell alias rather than a binary. |

### System instructions

`~/.config/ask/instructions.md` is prepended to every prompt as a system block. Default:

```
Be concise and direct. Avoid preamble or verbose explanations. Get to the point.
```

Edit this file to change Claude's default behaviour across all sessions.

---

## Architecture

### Project layout

```
src/
  ask/
    __init__.py      # empty
    cli.py           # all logic
pyproject.toml
README.md
```

Single-file implementation — everything lives in `cli.py`.

### Change detection

Ask does **not** use mtime polling. Instead it MD5-hashes the session file every 0.2 s and compares against a cached hash:

- After Python writes the response, `state["hash"]` is updated immediately in a `finally` block — so the watcher sees no change on the next poll and does not re-trigger.
- A `:w` with no content changes produces the same hash → no trigger. This is impossible to guarantee with mtime alone.
- A crash mid-write still runs `update_hash()` via `finally`, so the watcher never gets stuck seeing a stale hash.

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

Key properties:

- **One consumer thread** — saves are processed serially; no parallel Claude calls.
- `save_event` (`threading.Event`) is the signal. Setting it is idempotent — if a save arrives while Claude is running, the flag is already raised and the consumer picks it up on the next iteration.
- `hash_lock` (`threading.Lock`) protects `state["hash"]` against concurrent reads/writes between the watcher loop and `update_hash()`.

### nvim communication

Ask controls nvim via its msgpack-RPC socket:

```bash
# nvim started with a socket
nvim --listen /tmp/ask_<pid>.sock session.md

# Python sends keystrokes
nvim --server /tmp/ask_<pid>.sock --remote-send "<cmd>setlocal nomodifiable<cr>"
```

**While processing** — buffer locked, statusline updated:
```
<Esc><cmd>setlocal nomodifiable<cr><cmd>set statusline=🤖 Processing...<cr>
```

**After response written** — buffer unlocked, file reloaded, cursor at end in insert mode:
```
<cmd>setlocal modifiable<cr><cmd>e!<cr><cmd>normal! G<cr><cmd>startinsert<cr><cmd>set statusline=Ask [%f] %m<cr>
```

The statusline is used for the loading indicator rather than `echo` because nvim's own write confirmation (`"file" NL, NNB written`) is already in the command area — a second `echo` on top of it triggers "Press ENTER or type command to continue", which blocks input.

### Multi-turn prompt construction

The entire conversation history is sent on every turn as a single prompt to `claude -p`. Format:

```
<system>
{contents of ~/.config/ask/instructions.md}
</system>Human: first user message
Assistant: first agent response

Human: follow-up message
```

This is a stateless pattern — `claude -p` has no memory between calls. All context must be re-sent each turn. For very long sessions this grows the prompt, but for typical chat sessions it is negligible.

---

## Known limitations

- **No streaming** — Claude is called synchronously. The buffer is locked until the full response arrives.
- **Single session at a time** — each `ask` process owns one nvim instance and one socket.
- **No attachment support** — text-only sessions.
- **Prompt grows with history** — all turns are resent each time; very long conversations will hit model context limits.

---

## Potential future work

- **Streaming responses** — write tokens to the file incrementally as Claude generates them, using `--output-format stream-json`.
- **Session titles** — auto-generate a short title from the first user message and display it in the fzf history picker.
- **Named sessions** — `ask --name "my-session"` to open or resume a named session instead of a timestamp.
- **Multiple models per session** — allow switching model mid-conversation via a buffer command (e.g. `:Ask model sonnet`).
- **Syntax highlighting** — a vim ftplugin that highlights `━━━━ 👤 User` / `━━━━ 🤖 Agent` rulers in distinct colours.
- **pynvim integration** — replace `nvim --remote-send` subprocess calls with the `pynvim` library for more reliable bidirectional RPC.
- **Interrupt in-flight request** — allow `<C-c>` in nvim to cancel a running Claude call.
