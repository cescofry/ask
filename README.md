# Commander

A minimal CLI tool that turns **nvim into an interactive Claude chat interface**. Write your message in a vim buffer, save with `:w`, and the response appears automatically — no browser, no GUI, just your editor.

---

## How it works

```
commander
```

1. A timestamped session file is created in `~/commander-sessions/`.
2. nvim opens that file with a `👤 User` header ready for input.
3. You type your message and save (`:w`).
4. Commander detects the change, locks the buffer, calls Claude, and appends the response under a `🤖 Agent` header.
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

The parser uses `startswith` on the prefix (`━━━━ 👤 User` / `━━━━ 🤖 Agent`), so the timestamp in the middle is ignored during parsing. A line of pure `━` characters is treated as a closing ruler and skipped.

Session files are valid Markdown — timestamps serve as visual separators.

---

## Commands

```bash
commander            # open a new session
commander history    # pick a previous session with fzf
```

`history` uses `fzf` with a `cat` preview. Selecting a session opens it in nvim with the full watcher set up, so the conversation can continue from where it left off.

---

## Installation

Requires Python 3.10+, nvim, and fzf.

```bash
# inside the project directory
python3 -m venv .venv
.venv/bin/pip install -e .
```

The entry point `.venv/bin/commander` is ready to use. Add it to your PATH or alias it:

```bash
alias commander='/path/to/.venv/bin/commander'
```

---

## Configuration

Auto-created on first run at `~/.config/commander/config.yml`:

```yaml
model: haiku
sessions_dir: ~/commander-sessions
command: aifx agent run claude
```

| Key | Description |
|---|---|
| `model` | Model alias or full ID passed to `--model`. Accepts short aliases (`haiku`, `sonnet`, `opus`) or full names (`claude-sonnet-4-6`). |
| `sessions_dir` | Where session `.md` files are saved. Supports `~` expansion. |
| `command` | The shell command used to invoke Claude. Split on spaces and called via `subprocess` (no shell). Required because `claude` is typically a shell alias. |

### System instructions

`~/.config/commander/instructions.md` is prepended to every prompt as a `<system>` block. Default:

```
Be concise and direct. Avoid preamble or verbose explanations. Get to the point.
```

Edit this file to change Claude's default behaviour across all sessions.

---

## Architecture

### Project layout

```
src/
  commander/
    __init__.py      # empty
    cli.py           # all logic
pyproject.toml
```

Single-file implementation — everything lives in `cli.py`.

### Change detection

Commander does **not** use mtime polling. Instead it hashes the session file with MD5 every 0.2 s and compares against a cached hash:

- After Python writes the response, `cached_hash` is updated immediately — so the watcher sees no change on the next poll and does not re-trigger.
- A `:w` with no edits produces the same hash → no trigger (impossible to guarantee with mtime).
- The hash is also updated in the `finally` block of the consumer, so a crash mid-write doesn't leave the watcher in a broken state.

### Threading model

```
main thread                 watcher thread              consumer thread
───────────────             ──────────────              ───────────────
Popen(nvim)                 poll hash every 0.2s        wait on save_event
proc.wait()  ──────────>    if hash changed:            clear save_event
stop_event.set()              update cached_hash        process_save()
                              save_event.set()  ──────> update_hash()
                                                        loop
```

- **One consumer thread** processes saves serially — no parallel Claude calls.
- `save_event` is a `threading.Event`. If a save arrives while Claude is running, the event is already set; the consumer picks it up immediately on the next loop.
- `hash_lock` (a `threading.Lock`) protects `state["hash"]` shared between the watcher loop and `update_hash()`.

### nvim communication

Commander controls nvim via its RPC socket (`--listen` / `--server`):

```python
# start nvim with a socket
nvim --listen /tmp/commander_<pid>.sock session.md

# send keystrokes from Python
nvim --server /tmp/commander_<pid>.sock --remote-send "<cmd>setlocal nomodifiable<cr>"
```

**While processing** (buffer locked, statusline changed):
```
<Esc><cmd>setlocal nomodifiable<cr><cmd>set statusline=🤖\ Processing...<cr>
```

**After response is written** (buffer unlocked, file reloaded, cursor at end):
```
<cmd>setlocal modifiable<cr><cmd>e!<cr><cmd>normal! G<cr><cmd>startinsert<cr><cmd>set statusline=Commander\ [%f]\ %m<cr>
```

The statusline is used instead of `echo` for the loading indicator because a second `echo` on top of nvim's own write confirmation (`"file" NL, NNB written`) triggers "Press ENTER or type command to continue".

### Multi-turn prompt construction

The full conversation history is sent on every turn as a single prompt to `claude -p`. It is formatted with a system block followed by `Human:` / `Assistant:` pairs:

```
<system>
Be concise and direct. ...
</system>