#!/usr/bin/env bash
# fzf-browse: fuzzy-find files in a folder, open or copy to clipboard.
#   ENTER  — open selected file in $EDITOR (fallback: vi)
#   TAB    — copy file path to clipboard and print a message
#   /term  — prefix query with / to switch to regex search

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [OPTIONS] [FOLDER]"
  echo ""
  echo "  FOLDER        Directory to search (default: current directory)"
  echo ""
  echo "Options:"
  echo "  -e EXT        File extension filter, e.g. md (default: all files)"
  echo "  -h            Show this help"
  echo ""
  echo "Keybindings:"
  echo "  ENTER         Open selected file in \$EDITOR"
  echo "  TAB           Copy file path to clipboard"
  echo "  /query        Regex search inside files; plain query = literal"
  exit 0
}

EXT="*"

while getopts ":e:h" opt; do
  case $opt in
    e) EXT="$OPTARG" ;;
    h) usage ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

FOLDER="${1:-.}"
FOLDER="$(cd "$FOLDER" && pwd)"

if ! command -v fzf &>/dev/null; then
  echo "Error: fzf is not installed." >&2
  exit 1
fi

# Detect clipboard command
if command -v pbcopy &>/dev/null; then
  CLIP_CMD="pbcopy"
elif command -v xclip &>/dev/null; then
  CLIP_CMD="xclip -selection clipboard"
elif command -v xsel &>/dev/null; then
  CLIP_CMD="xsel --clipboard --input"
elif command -v wl-copy &>/dev/null; then
  CLIP_CMD="wl-copy"
else
  echo "Warning: no clipboard tool found (pbcopy/xclip/xsel/wl-copy). TAB copy will not work." >&2
  CLIP_CMD="cat"
fi

EDITOR="${EDITOR:-vi}"

# Export so fzf's sh -c subshells can resolve them at runtime.
export BROWSE_ROOT="$FOLDER"
export BROWSE_EXT="$EXT"

# Single-quoted: bash never expands these; fzf substitutes {} and {q},
# then sh expands $BROWSE_ROOT/$BROWSE_EXT from the environment.
RELOAD_CMD='q={q}; if [ -z "$q" ]; then find "$BROWSE_ROOT" -type f -name "*.$BROWSE_EXT" | sort | sed "s|^$BROWSE_ROOT/||"; else case "$q" in /*) p="${q#/}"; gf="-Ei";; *) p="$q"; gf="-Fi";; esac; { grep -rl $gf --include="*.$BROWSE_EXT" -- "$p" "$BROWSE_ROOT" 2>/dev/null; find "$BROWSE_ROOT" -type f -name "*.$BROWSE_EXT" 2>/dev/null | grep $gf -- "$p"; } | sort -u | sed "s|^$BROWSE_ROOT/||"; fi'

# {} must be assigned to a variable first: fzf wraps it in single quotes
# (e.g. '.git/foo'), which is valid shell quoting when standalone but becomes
# a literal ' character when embedded inside "…".
PREVIEW_CMD='q={q}; rel={}; f="$BROWSE_ROOT/$rel"; if [ -n "$q" ]; then case "$q" in /*) p="${q#/}"; gf="-Ei";; *) p="$q"; gf="-Fi";; esac; grep --color=always $gf -C 3 -- "$p" "$f" 2>/dev/null || cat "$f"; else cat "$f"; fi'

TAB_CMD='rel={}; printf "%s" "$BROWSE_ROOT/$rel" | '"$CLIP_CMD"' && printf "Copied to clipboard: %s\n" "$BROWSE_ROOT/$rel" >/dev/tty'

INITIAL_LIST="$(find "$FOLDER" -type f -name "*.$EXT" | sort | sed "s|^$FOLDER/||")"

if [ -z "$INITIAL_LIST" ]; then
  echo "No files found in $FOLDER"
  exit 0
fi

HEADER="$(printf '%s\nENTER: open in editor · TAB: copy path · /term: regex search' "$FOLDER")"

SELECTED="$(printf '%s' "$INITIAL_LIST" | fzf \
  --disabled \
  --bind "change:reload:$RELOAD_CMD" \
  --bind "tab:execute-silent[$TAB_CMD]+abort" \
  --preview "$PREVIEW_CMD" \
  --preview-window "right:60%:wrap" \
  --header "$HEADER" \
  || true)"

if [ -n "$SELECTED" ]; then
  "$EDITOR" "$BROWSE_ROOT/$SELECTED"
fi
