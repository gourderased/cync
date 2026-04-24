#!/usr/bin/env bash
# lib/install.sh — symlink ~/.claude entries into the config repo and
# register a marker block in the user's shell rc file. Idempotent.
#
# Inputs (exported by setup.sh):
#   CYNC_DIR              path to ~/.cync
#   _claude_config_repo   path to the user's config repo clone
set -euo pipefail

: "${CYNC_DIR:?CYNC_DIR not set}"
: "${_claude_config_repo:?_claude_config_repo not set}"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

CLAUDE_HOME="$HOME/.claude"
mkdir -p "$CLAUDE_HOME"

# ---------------------------------------------------------------------------
# 1. Symlinks
# ---------------------------------------------------------------------------
ENTRIES=(settings.json CLAUDE.md commands agents skills)

backup_dir=""
for entry in "${ENTRIES[@]}"; do
  src="$_claude_config_repo/$entry"
  dst="$CLAUDE_HOME/$entry"

  [ -e "$src" ] || continue

  if [ -L "$dst" ]; then
    current="$(readlink "$dst")"
    if [ "$current" = "$src" ]; then
      info "symlink ok: ~/.claude/$entry"
      continue
    fi
    rm "$dst"
  elif [ -e "$dst" ]; then
    if [ -z "$backup_dir" ]; then
      backup_dir="$CLAUDE_HOME/backups/pre-symlink-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$backup_dir"
      warn "backing up existing ~/.claude entries to $backup_dir"
    fi
    mv "$dst" "$backup_dir/"
  fi

  ln -s "$src" "$dst"
  info "symlinked ~/.claude/$entry -> $src"
done

# ---------------------------------------------------------------------------
# 2. Rc file marker block
# ---------------------------------------------------------------------------
shell_name="$(basename "${SHELL:-/bin/bash}")"
case "$shell_name" in
  zsh)  rc_file="$HOME/.zshrc" ;;
  bash) rc_file="$HOME/.bashrc" ;;
  *)    die "unsupported shell: '$shell_name' — cync only supports bash and zsh. Switch \$SHELL or manually source lib/claude-wrapper.sh from your shell's rc file." ;;
esac

touch "$rc_file"

tmp_rc="$(mktemp)"
tmp_rc_clean="$tmp_rc.clean"
trap 'rm -f "$tmp_rc" "$tmp_rc_clean"' EXIT

# 1) strip any existing cync block
awk '
  /^# BEGIN cync/ { skip = 1; next }
  /^# END cync/   { skip = 0; next }
  skip != 1
' "$rc_file" > "$tmp_rc"

# 2) drop trailing blank lines so the new block sits cleanly at EOF
# (portable for-loop instead of `while (n--)`, which some older awks choke on)
awk 'BEGIN{ blanks=0 }
     /^[[:space:]]*$/ { blanks++; next }
     { for (i = 0; i < blanks; i++) print ""; blanks = 0; print }
' "$tmp_rc" > "$tmp_rc_clean"
mv "$tmp_rc_clean" "$tmp_rc"

# 3) append the managed block
{
  [ -s "$tmp_rc" ] && echo ""
  cat <<EOF
# BEGIN cync (managed by lib/install.sh — do not edit between markers)
export CYNC_DIR="$CYNC_DIR"
export _claude_config_repo="$_claude_config_repo"
source "\$CYNC_DIR/lib/claude-wrapper.sh"
# END cync
EOF
} >> "$tmp_rc"

mv "$tmp_rc" "$rc_file"
trap - EXIT
info "updated $rc_file with cync marker block"
