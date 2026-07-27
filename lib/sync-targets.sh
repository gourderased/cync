# lib/sync-targets.sh — materialize config repo content into each tool's home.
#
# cync started out Claude-only, where every managed entry could be a plain
# symlink from ~/.claude into the config repo. Codex needs two things that a
# symlink can't express:
#
#   1. Its instruction file (~/.codex/AGENTS.md) has no import directive, so
#      shared instructions have to be concatenated into a real file. Claude
#      Code's CLAUDE.md is generated the same way to keep one source of truth.
#   2. ~/.codex/skills holds Codex's own .system/ skills, so the directory
#      itself can't be a symlink — each shared skill is linked individually.
#
# Sourced by lib/install.sh (setup) and lib/claude-wrapper.sh (every launch,
# right after the config repo pull). Safe to run repeatedly.
#
# Reads: _claude_config_repo

_cync_st_info() { printf '\033[36m==>\033[0m cync: %s\n' "$*"; }
_cync_st_warn() { printf '\033[33m!!\033[0m  cync: %s\n' "$*" >&2; }

# Only touch Codex's home when Codex is actually on this machine. Servers that
# only run Claude Code shouldn't grow a ~/.codex directory.
_cync_has_codex() {
  command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]
}

# _cync_render — concatenate repo-relative sources into a destination file.
#   $1     destination path
#   $2...  sources, relative to the config repo, joined in order
#
# Writes through a temp file so a failure mid-write can't leave a truncated
# instruction file behind, and skips the write entirely when the content is
# unchanged (keeps mtime stable, keeps the launch quiet).
_cync_render() {
  local dst="$1"; shift
  local repo="${_claude_config_repo:-}"
  local tmp src

  [ -n "$repo" ] || return 0
  for src in "$@"; do
    [ -r "$repo/$src" ] || return 0
  done

  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0

  tmp="$dst.cync-tmp.$$"
  {
    printf '<!-- 자동 생성됨. 이 파일을 직접 고치지 말 것. 소스: %s/instructions/ -->\n\n' "$repo"
    for src in "$@"; do
      cat "$repo/$src"
      printf '\n'
    done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

  # Compare only against a real file. When $dst is still the pre-render
  # symlink into the repo, cmp would follow it and could report a false match.
  if [ ! -L "$dst" ] && [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    return 0
  fi

  rm -f "$dst"
  if mv "$tmp" "$dst" 2>/dev/null; then
    _cync_st_info "rendered $dst"
  else
    rm -f "$tmp"
    _cync_st_warn "could not write $dst"
  fi
}

# _cync_link_codex_skills — link each shared skill into ~/.codex/skills.
#
# Per-entry rather than linking the whole directory: Codex ships its own
# skills under ~/.codex/skills/.system, and replacing the directory with a
# symlink would hide them.
_cync_link_codex_skills() {
  local repo="${_claude_config_repo:-}"
  local src_dir="$repo/skills"
  local dst_dir="$HOME/.codex/skills"
  local entry name dst target

  [ -n "$repo" ] && [ -d "$src_dir" ] || return 0
  mkdir -p "$dst_dir" 2>/dev/null || return 0

  # Link every skill directory the repo currently has. The trailing slash in
  # the glob keeps loose files (.gitkeep) out.
  for entry in "$src_dir"/*/; do
    [ -d "$entry" ] || continue
    name="${entry%/}"
    name="${name##*/}"
    dst="$dst_dir/$name"

    if [ -L "$dst" ]; then
      [ "$(readlink "$dst")" = "$src_dir/$name" ] && continue
      rm -f "$dst"
    elif [ -e "$dst" ]; then
      # A real directory of the same name is someone else's skill — a Codex
      # install or a manual copy. Leave it alone and say so.
      _cync_st_warn "$dst exists and isn't a cync symlink — skipping"
      continue
    fi

    ln -s "$src_dir/$name" "$dst" 2>/dev/null \
      && _cync_st_info "linked $dst" \
      || _cync_st_warn "could not link $dst"
  done

  # Drop links whose skill was deleted from the repo, so a removed skill
  # stops showing up in Codex instead of dangling.
  for dst in "$dst_dir"/*; do
    [ -L "$dst" ] || continue
    target="$(readlink "$dst" 2>/dev/null || true)"
    case "$target" in
      "$src_dir"/*)
        [ -d "$target" ] || { rm -f "$dst"; _cync_st_info "pruned stale link $dst"; }
        ;;
    esac
  done
}

# _cync_apply_config — everything that has to happen after the repo is current.
_cync_apply_config() {
  _cync_render "$HOME/.claude/CLAUDE.md" instructions/common.md instructions/claude.md

  if _cync_has_codex; then
    _cync_render "$HOME/.codex/AGENTS.md" instructions/common.md instructions/codex.md
    _cync_link_codex_skills
  fi
}
