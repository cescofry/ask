"""Ask — nvim-based Claude chat interface."""

from __future__ import annotations

import hashlib
import shlex
import os
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import click
import yaml

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RULER_CHAR = "━"
RULER = RULER_CHAR * 28
USER_PREFIX = "👤 USER"
AGENT_PREFIX = "🤖 AGENT"
CLOSING_RULER = RULER


def make_ruler_header(role: str) -> str:
    label = " 👤 USER" if role == "user" else " 🤖 AGENT"
    return f"{RULER}\n{label}\n{RULER}"

CONFIG_DIR = Path("~/.config/ask").expanduser()
CONFIG_FILE = CONFIG_DIR / "config.yml"
INSTRUCTIONS_FILE = CONFIG_DIR / "instructions.md"

DEFAULT_CONFIG = {
    "model": "haiku",
    "sessions_dir": "~/ask-sessions",
    "command": "aifx agent run claude",
}

DEFAULT_INSTRUCTIONS = (
    "Be concise and direct. Avoid preamble or verbose explanations. "
    "Get to the point.\n"
)

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------


def ensure_defaults() -> None:
    """Create ~/.config/ask/ with defaults if missing."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if not CONFIG_FILE.exists():
        CONFIG_FILE.write_text(yaml.dump(DEFAULT_CONFIG, default_flow_style=False))

    if not INSTRUCTIONS_FILE.exists():
        INSTRUCTIONS_FILE.write_text(DEFAULT_INSTRUCTIONS)


def load_config() -> dict:
    ensure_defaults()
    with open(CONFIG_FILE) as f:
        cfg = yaml.safe_load(f) or {}
    # Fill missing keys with defaults
    for key, val in DEFAULT_CONFIG.items():
        cfg.setdefault(key, val)
    return cfg


# ---------------------------------------------------------------------------
# Buffer parsing and prompt building
# ---------------------------------------------------------------------------


def parse_buffer(content: str) -> list[tuple[str, str]]:
    """Return [(role, text), ...] where role is 'user' or 'agent'."""
    sections: list[tuple[str, str]] = []
    current_role: str | None = None
    current_lines: list[str] = []

    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith(USER_PREFIX):
            if current_role is not None:
                sections.append((current_role, "\n".join(current_lines).strip()))
            current_role = "user"
            current_lines = []
        elif stripped.startswith(AGENT_PREFIX):
            if current_role is not None:
                sections.append((current_role, "\n".join(current_lines).strip()))
            current_role = "agent"
            current_lines = []
        elif stripped and all(c == RULER_CHAR for c in stripped):
            pass  # skip closing rulers
        elif current_role is not None:
            current_lines.append(line)

    if current_role is not None:
        sections.append((current_role, "\n".join(current_lines).strip()))

    return sections


def build_prompt(sections: list[tuple[str, str]], instructions: str) -> str:
    """Build a full-history prompt to pass to claude -p."""
    parts: list[str] = []
    if instructions.strip():
        parts.append(f"<system>\n{instructions.strip()}\n</system>")

    for role, text in sections:
        if not text:
            continue
        prefix = "Human" if role == "user" else "Assistant"
        parts.append(f"{prefix}: {text}")

    return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Claude invocation
# ---------------------------------------------------------------------------


def call_claude(prompt: str, model: str, command: str) -> str:
    """Run the configured claude command and return the response text."""
    cmd = command.split() + ["-p", prompt, "--model", model, "--no-session-persistence"]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd="/tmp")
    if result.returncode != 0:
        err = result.stderr.strip() or result.stdout.strip()
        return f"[Error calling Claude: {err}]"
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# nvim control
# ---------------------------------------------------------------------------


def nvim_send(socket_path: str, keys: str) -> None:
    """Send keystrokes to a running nvim instance via its RPC socket."""
    subprocess.run(
        ["nvim", "--server", socket_path, "--remote-send", keys],
        capture_output=True,
    )


def nvim_set_loading(socket_path: str) -> None:
    nvim_send(
        socket_path,
        r"<Esc><cmd>setlocal nomodifiable<cr>"
        r"<cmd>set statusline=🤖\ Processing...<cr>",
    )


def nvim_set_done(socket_path: str) -> None:
    nvim_send(
        socket_path,
        r"<cmd>setlocal modifiable<cr>"
        r"<cmd>e!<cr>"
        r"<cmd>normal! G<cr>"
        r"<cmd>startinsert<cr>"
        r"<cmd>set statusline=Ask\ [%f]\ %m<cr>",
    )


# ---------------------------------------------------------------------------
# Save processing
# ---------------------------------------------------------------------------


def process_save(
    session_file: Path,
    socket_path: str,
    model: str,
    command: str,
    instructions: str,
) -> None:
    """Read the current file, call Claude if there is a pending user message, append response."""
    content = session_file.read_text()
    sections = parse_buffer(content)

    # Only act when the last section is non-empty user text
    if not sections or sections[-1][0] != "user" or not sections[-1][1]:
        return

    nvim_set_loading(socket_path)

    prompt = build_prompt(sections, instructions)
    response = call_claude(prompt, model, command)

    new_content = (
        content.rstrip()
        + f"\n\n{make_ruler_header('agent')}\n\n{response}\n\n"
        + f"{CLOSING_RULER}\n\n"
        + f"{make_ruler_header('user')}\n\n"
    )
    session_file.write_text(new_content)

    nvim_set_done(socket_path)


# ---------------------------------------------------------------------------
# mtime watcher
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# File hash helpers
# ---------------------------------------------------------------------------


def file_hash(path: Path) -> str:
    """Return MD5 hex digest of the file's bytes."""
    return hashlib.md5(path.read_bytes()).hexdigest()


# ---------------------------------------------------------------------------
# mtime watcher
# ---------------------------------------------------------------------------


def watch_file(
    session_file: Path,
    socket_path: str,
    model: str,
    command: str,
    instructions: str,
    stop_event: threading.Event,
) -> None:
    """Poll the session file's hash every 0.2 s and drive a serial consumer."""
    # Shared mutable state protected by hash_lock
    state = {"hash": file_hash(session_file)}
    hash_lock = threading.Lock()
    save_event = threading.Event()

    def update_hash() -> None:
        """Sync cached hash to current file content (called after each write)."""
        with hash_lock:
            state["hash"] = file_hash(session_file)

    def consumer() -> None:
        while not stop_event.is_set():
            save_event.wait()
            save_event.clear()  # clear early so any save during processing is captured
            try:
                process_save(session_file, socket_path, model, command, instructions)
            except Exception as exc:
                print(f"ask: error during processing: {exc}", file=sys.stderr)
                try:
                    nvim_send(
                        socket_path,
                        r"<cmd>setlocal modifiable<cr>"
                        r"<cmd>set statusline=Ask\ [%f]\ %m<cr>",
                    )
                except Exception:
                    pass
            finally:
                # Always sync hash after a consumer run so our own writes
                # don't look like user changes on the next poll.
                update_hash()

    threading.Thread(target=consumer, daemon=True).start()

    while not stop_event.is_set():
        time.sleep(0.2)
        try:
            current = file_hash(session_file)
        except FileNotFoundError:
            break

        with hash_lock:
            if current != state["hash"]:
                state["hash"] = current   # mark as seen before signalling
                save_event.set()


# ---------------------------------------------------------------------------
# Session management
# ---------------------------------------------------------------------------

VIM_INIT_CMDS = [
    # No echo in the autocmd — a second message on top of the write confirmation
    # triggers "Press ENTER or type command to continue".
    # The Python mtime watcher handles everything; statusline shows state.
    r"set statusline=Ask\ [%f]\ %m",
]


def open_session(session_file: Path, cfg: dict, is_new: bool = False) -> None:
    """Launch nvim with the Ask watcher setup and watch for saves."""
    instructions = INSTRUCTIONS_FILE.read_text()
    model: str = cfg["model"]
    command: str = cfg["command"]

    socket_path = f"/tmp/ask_{os.getpid()}.sock"

    nvim_cmd = ["nvim", "--listen", socket_path, str(session_file)]
    for cmd in VIM_INIT_CMDS:
        nvim_cmd += ["-c", cmd]

    stop_event = threading.Event()
    watcher = threading.Thread(
        target=watch_file,
        args=(session_file, socket_path, model, command, instructions, stop_event),
        daemon=True,
    )

    proc = subprocess.Popen(nvim_cmd)
    # Give nvim a moment to start and create the socket
    time.sleep(0.5)
    watcher.start()

    proc.wait()
    stop_event.set()


def new_session(cfg: dict) -> None:
    sessions_dir = Path(cfg["sessions_dir"]).expanduser()
    sessions_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session_file = sessions_dir / f"{timestamp}.md"
    session_file.write_text(f"{make_ruler_header('user')}\n\n")

    open_session(session_file, cfg, is_new=True)


def pick_history(cfg: dict) -> None:
    sessions_dir = Path(cfg["sessions_dir"]).expanduser()
    sessions = sorted(sessions_dir.glob("*.md"), reverse=True)

    if not sessions:
        click.echo("No sessions found.")
        return

    initial_list = "\n".join(str(s) for s in sessions)
    sd = shlex.quote(str(sessions_dir))

    reload_cmd = (
        f'q={{q}}; '
        f'[ -z "$q" ] && find {sd} -maxdepth 1 -name "*.md" -type f | sort -r || '
        f'{{ case "$q" in '
        f'  /*) p="${{q#/}}"; gf="-Ei";; '
        f'  *) p="$q"; gf="-Fi";; '
        f'esac; '
        f'{{ grep -rl $gf --include="*.md" -- "$p" {sd} 2>/dev/null; '
        f'find {sd} -maxdepth 1 -name "*.md" -type f 2>/dev/null | grep $gf -- "$p"; '
        f'}} | sort -ur; }}'
    )

    preview_cmd = (
        'q={q}; f={}; '
        'if [ -n "$q" ]; then '
        '  case "$q" in '
        '    /*) p="${q#/}"; gf="-Ei";; '
        '    *) p="$q"; gf="-Fi";; '
        '  esac; '
        '  grep --color=always $gf -C 3 -- "$p" "$f" || cat "$f"; '
        'else '
        '  cat "$f"; '
        'fi'
    )

    result = subprocess.run(
        [
            "fzf",
            "--disabled",
            "--bind", f"change:reload:{reload_cmd}",
            "--preview", preview_cmd,
            "--preview-window", "right:60%:wrap",
        ],
        input=initial_list,
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        selected = Path(result.stdout.strip())
        open_session(selected, cfg)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


@click.group(invoke_without_command=True)
@click.pass_context
def main(ctx: click.Context) -> None:
    """Ask — nvim-based Claude chat interface."""
    if ctx.invoked_subcommand is None:
        cfg = load_config()
        new_session(cfg)


@main.command()
def history() -> None:
    """Open a previous session."""
    cfg = load_config()
    pick_history(cfg)
