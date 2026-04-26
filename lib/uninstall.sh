#!/usr/bin/env bash
# lib/uninstall.sh — undo what cync set up on this machine.
#
# What it does:
#   1. Detects current cync state from rc files / env / disk
#   2. Asks how to handle ~/.claude symlinks (materialize vs purge)
#   3. Asks whether to remove the local config repo clone
#   4. Removes rc block, plugin sync state, and ~/.cync itself
#   5. NEVER touches the GitHub config repo
set -euo pipefail

# Reattach stdin to the controlling TTY so prompts work even when invoked
# via `bash <(curl ...)` or similar non-tty pipelines.
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
  exec </dev/tty
fi

bold()    { printf '\033[1m%s\033[0m\n' "$*"; }
info()    { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()    { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()     { printf '\033[31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

section() {
  local title="$*"
  local rule="================================================================"
  printf '\n\n'
  printf '\033[1;36m%s\033[0m\n' "$rule"
  printf '\033[1;36m  %s\033[0m\n' "$title"
  printf '\033[1;36m%s\033[0m\n' "$rule"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Phase 0 — state detection
# ---------------------------------------------------------------------------
CLAUDE_HOME="$HOME/.claude"
ENTRIES=(settings.json CLAUDE.md commands agents skills)

# Find rc files that contain a cync marker block
RC_FILES=()
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$rc" ] && grep -q "^# BEGIN cync" "$rc" 2>/dev/null; then
    RC_FILES+=("$rc")
  fi
done

# Pull a single export's value out of the marker block
extract_export() {
  local var="$1"; shift
  local f val
  for f in "$@"; do
    [ -f "$f" ] || continue
    val="$(awk -v v="$var" '
      /^# BEGIN cync/ { in_block = 1; next }
      /^# END cync/   { in_block = 0; next }
      in_block && $0 ~ "^export " v "=" {
        s = $0
        sub(/^export [A-Za-z_][A-Za-z0-9_]*="/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    ' "$f")"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  done
}

DETECTED_CYNC_DIR=""
DETECTED_CONFIG_REPO=""
if [ ${#RC_FILES[@]} -gt 0 ]; then
  DETECTED_CYNC_DIR="$(extract_export CYNC_DIR "${RC_FILES[@]}" || true)"
  DETECTED_CONFIG_REPO="$(extract_export _claude_config_repo "${RC_FILES[@]}" || true)"
fi

CYNC_DIR="${DETECTED_CYNC_DIR:-${CYNC_DIR:-$HOME/.cync}}"
CONFIG_REPO="${DETECTED_CONFIG_REPO:-${_claude_config_repo:-}}"

# Which ~/.claude entries are currently symlinks?
SYMLINKED_ENTRIES=()
for e in "${ENTRIES[@]}"; do
  [ -L "$CLAUDE_HOME/$e" ] && SYMLINKED_ENTRIES+=("$e")
done

# Bail early when there's literally nothing to clean up
if [ ${#RC_FILES[@]} -eq 0 ] \
   && [ ${#SYMLINKED_ENTRIES[@]} -eq 0 ] \
   && [ ! -d "$CYNC_DIR" ]; then
  info "Nothing to uninstall — cync isn't detected on this machine."
  exit 0
fi

# Best-effort GitHub repo name (purely for display)
get_repo_name() {
  local url="$1"
  url="${url%.git}"
  url="${url##*github.com[:/]}"
  printf '%s' "$url"
}
REPO_NAME=""
if [ -n "$CONFIG_REPO" ] && [ -d "$CONFIG_REPO/.git" ]; then
  remote_url="$(git -C "$CONFIG_REPO" remote get-url origin 2>/dev/null || true)"
  [ -n "$remote_url" ] && REPO_NAME="$(get_repo_name "$remote_url")"
fi

# ---------------------------------------------------------------------------
# Phase 1 — summary + initial confirmation
# ---------------------------------------------------------------------------
section "Uninstall cync"
echo "  This will undo what cync set up on this machine."
if [ -n "$REPO_NAME" ]; then
  echo "  Your GitHub repo ($REPO_NAME) is NEVER touched —"
  echo "  other machines connected to it keep working."
else
  echo "  Your GitHub repo is NEVER touched — only local files."
fi
echo
echo "  Detected:"
[ -d "$CYNC_DIR" ] && echo "    Installer:    $CYNC_DIR"
if [ -n "$CONFIG_REPO" ]; then
  if [ -n "$REPO_NAME" ]; then
    echo "    Config repo:  $CONFIG_REPO  (= $REPO_NAME)"
  else
    echo "    Config repo:  $CONFIG_REPO"
  fi
fi
if [ ${#SYMLINKED_ENTRIES[@]} -gt 0 ]; then
  echo "    Symlinks:     ${SYMLINKED_ENTRIES[*]}"
fi
if [ ${#RC_FILES[@]} -gt 0 ]; then
  for rc in "${RC_FILES[@]}"; do
    echo "    Shell hook:   $rc  (BEGIN cync block)"
  done
fi
echo

read -r -p "> Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "aborted"

# ---------------------------------------------------------------------------
# Phase 2 — Step 1: how to handle ~/.claude symlinks
# ---------------------------------------------------------------------------
SYMLINK_MODE=""
if [ ${#SYMLINKED_ENTRIES[@]} -gt 0 ]; then
  section "Step 1 of 2 — How should ~/.claude end up?"
  echo "  [m] Materialize (recommended)"
  echo "        Copy current settings as real files into ~/.claude/."
  echo "        claude keeps using the same settings, just without"
  echo "        auto-sync from GitHub."
  echo "  [p] Purge"
  echo "        Just remove the symlinks. ~/.claude/ becomes empty;"
  echo "        claude starts from defaults next launch."
  echo

  while [ -z "$SYMLINK_MODE" ]; do
    read -r -p "> Choice [m]: " choice
    choice="${choice:-m}"
    case "$choice" in
      m|M) SYMLINK_MODE="materialize" ;;
      p|P) SYMLINK_MODE="purge" ;;
      *)   warn "invalid choice '$choice' — type 'm' or 'p'" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# Phase 3 — Step 2: optionally remove the local config repo clone
# ---------------------------------------------------------------------------
REMOVE_CLONE="no"
if [ -n "$CONFIG_REPO" ] && [ -d "$CONFIG_REPO" ]; then
  section "Step 2 of 2 — Local config repo clone"
  if [ -n "$REPO_NAME" ]; then
    echo "  $CONFIG_REPO  (= $REPO_NAME)"
  else
    echo "  $CONFIG_REPO"
  fi
  echo
  echo "  Remove this directory? GitHub repo is untouched either way."
  echo

  read -r -p "> Remove? [y/N]: " r
  [[ "$r" =~ ^[Yy]$ ]] && REMOVE_CLONE="yes"
fi

# ---------------------------------------------------------------------------
# Phase 4 — execute
# ---------------------------------------------------------------------------
section "Removing cync"

# (1) Symlinks
if [ ${#SYMLINKED_ENTRIES[@]} -gt 0 ]; then
  for e in "${SYMLINKED_ENTRIES[@]}"; do
    src="$CLAUDE_HOME/$e"
    if [ "$SYMLINK_MODE" = "materialize" ]; then
      target="$(readlink "$src" 2>/dev/null || true)"
      if [ -n "$target" ] && [ -e "$target" ]; then
        rm "$src"
        # -R for directories, -L to dereference any nested symlinks too,
        # -p to preserve mode/timestamps. macOS BSD cp doesn't have -a in
        # the GNU sense, so spell it out.
        cp -RLp "$target" "$src"
        info "materialized ~/.claude/$e"
      else
        rm -f "$src"
        warn "skip materialize: ~/.claude/$e (broken symlink)"
      fi
    else
      rm -f "$src"
      info "removed symlink ~/.claude/$e"
    fi
  done
fi

# (2) rc block(s)
if [ ${#RC_FILES[@]} -gt 0 ]; then
  for rc in "${RC_FILES[@]}"; do
    tmp="$(mktemp)"
    tmp_clean="$tmp.clean"
    awk '
      /^# BEGIN cync/ { skip = 1; next }
      /^# END cync/   { skip = 0; next }
      skip != 1
    ' "$rc" > "$tmp"
    awk 'BEGIN{ blanks=0 }
         /^[[:space:]]*$/ { blanks++; next }
         { for (i = 0; i < blanks; i++) print ""; blanks = 0; print }
    ' "$tmp" > "$tmp_clean"
    mv "$tmp_clean" "$rc"
    rm -f "$tmp"
    info "removed BEGIN cync block from $rc"
  done
fi

# (3) plugin sync state
if [ -d "$CLAUDE_HOME/plugin-sync-state" ]; then
  rm -rf "$CLAUDE_HOME/plugin-sync-state"
  info "removed $CLAUDE_HOME/plugin-sync-state"
fi

# (4) local config repo clone (if requested)
if [ "$REMOVE_CLONE" = "yes" ]; then
  rm -rf "$CONFIG_REPO"
  info "removed $CONFIG_REPO"
fi

# (5) self-delete (last; bash already loaded the script into memory)
if [ -d "$CYNC_DIR" ]; then
  rm -rf "$CYNC_DIR"
  info "removed $CYNC_DIR"
fi

# ---------------------------------------------------------------------------
# Phase 5 — done
# ---------------------------------------------------------------------------
section "Done — cync removed"
if [ -n "$REPO_NAME" ]; then
  echo "  Your GitHub repo ($REPO_NAME) is untouched."
fi
cat <<'EOF'
  The 'claude' shell function is still in your *current* shell —
  start a new terminal (or `exec zsh` / `exec bash`) to drop it.

  To reinstall later:
    curl -fsSL https://raw.githubusercontent.com/gourderased/cync/main/install | bash

EOF
