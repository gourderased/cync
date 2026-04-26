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

section() {
  local title="$*"
  local rule="================================================================"
  printf '\n\n'
  printf '\033[1;36m%s\033[0m\n' "$rule"
  printf '\033[1;36m  %s\033[0m\n' "$title"
  printf '\033[1;36m%s\033[0m\n' "$rule"
  printf '\n'
}

CLAUDE_HOME="$HOME/.claude"
mkdir -p "$CLAUDE_HOME"

# ---------------------------------------------------------------------------
# 1. Symlinks
# ---------------------------------------------------------------------------
ENTRIES=(settings.json CLAUDE.md commands agents skills)

# 1a. Pre-scan: figure out which entries would actually change so we can warn
#     the user before we touch anything destructive. Two flavors of "existing":
#       - real files/dirs   → will be moved to a timestamped backup
#       - foreign symlinks  → will be unlinked (the link target itself stays
#                              wherever it lived; only the link is replaced)
real_entries=()
extlink_entries=()    # parallel array, each item formatted "<name>|<old-target>"
for entry in "${ENTRIES[@]}"; do
  src="$_claude_config_repo/$entry"
  dst="$CLAUDE_HOME/$entry"

  [ -e "$src" ] || continue

  if [ -L "$dst" ]; then
    current="$(readlink "$dst")"
    [ "$current" = "$src" ] && continue   # already correctly linked
    extlink_entries+=("$entry|$current")
  elif [ -e "$dst" ]; then
    real_entries+=("$entry")
  fi
done

if [ ${#real_entries[@]} -gt 0 ] || [ ${#extlink_entries[@]} -gt 0 ]; then
  section "Existing Claude Code settings detected"
  echo "  Found local settings on this machine that overlap with the config repo:"
  echo

  for e in "${real_entries[@]}"; do
    if [ -d "$CLAUDE_HOME/$e" ]; then
      printf '    %-16s (existing directory, will be backed up)\n' "$e/"
    else
      printf '    %-16s (existing file, will be backed up)\n' "$e"
    fi
  done
  for entry in "${extlink_entries[@]}"; do
    name="${entry%%|*}"
    target="${entry#*|}"
    printf '    %-16s (symlink → %s, link will be replaced)\n' "$name" "$target"
  done

  echo
  echo "  These will be replaced with symlinks into your config repo:"
  echo "    $_claude_config_repo"
  echo
  if [ ${#real_entries[@]} -gt 0 ]; then
    echo "  Backup: ~/.claude/backups/pre-symlink-<timestamp>/"
    echo "          (the originals are moved there, nothing is deleted)"
  fi
  if [ ${#extlink_entries[@]} -gt 0 ]; then
    echo "  Note:   foreign symlinks aren't backed up — only the link reference"
    echo "          is dropped. The actual file at the target stays in place."
  fi
  echo

  read -r -p "> Continue? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "aborted — no changes made"
fi

# 1b. Apply: same logic as the pre-scan, but actually perform the moves and links.
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
      info "backing up existing ~/.claude entries to $backup_dir"
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

# Use ~/.cync/tmp so the temp file lives on the same filesystem as the rc
# file — that keeps the final `mv` atomic. Fall back to system mktemp if
# ~/.cync/tmp is somehow unavailable.
mkdir -p "$CYNC_DIR/tmp" 2>/dev/null || true
if [ -d "$CYNC_DIR/tmp" ] && [ -w "$CYNC_DIR/tmp" ]; then
  tmp_rc="$(mktemp "$CYNC_DIR/tmp/rc-XXXXXX")"
else
  tmp_rc="$(mktemp)"
fi
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
