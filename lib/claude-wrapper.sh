# lib/claude-wrapper.sh — overrides the `claude` command with a shell function
# that keeps the cync installer, the user's config repo, and plugin caches in
# sync before invoking the real binary.
#
# Sourced from the user's rc file via the cync marker block.

_cync_pull() {
  # $1 = friendly label for warnings, $2 = repo dir
  local label="$1" dir="$2" out
  [ -d "$dir/.git" ] || return 0
  if ! out="$(cd "$dir" && git pull --ff-only --quiet 2>&1)"; then
    printf '\033[33m!!  cync: skipping %s auto-sync (%s)\033[0m\n' \
      "$label" "$(printf '%s' "$out" | head -1)" >&2
  fi
}

# Throttle network sync so `claude` doesn't make a round of git pulls and
# `git ls-remote` calls on every single invocation. Defaults to once per
# 60 seconds; override with CYNC_SYNC_INTERVAL=<seconds> (use 0 to force
# every call, or `rm ~/.claude/cync-last-sync` for a one-shot bypass).
_cync_should_sync() {
  local marker="$HOME/.claude/cync-last-sync"
  local interval="${CYNC_SYNC_INTERVAL:-60}"
  [ "$interval" -le 0 ] 2>/dev/null && return 0
  [ -f "$marker" ] || return 0
  local now mtime age
  now="$(date +%s)"
  # Linux GNU stat first (-c %Y), then macOS BSD (-f %m). Order matters:
  # GNU stat treats `-f` as "show filesystem info", which "succeeds" but
  # dumps multi-line FS metadata into mtime, then bash arithmetic chokes
  # on it. Trying -c first dodges that booby trap, and we sanity-check
  # the output is purely numeric before using it.
  mtime="$(stat -c %Y "$marker" 2>/dev/null \
        || stat -f %m "$marker" 2>/dev/null \
        || echo 0)"
  case "$mtime" in
    ''|*[!0-9]*) mtime=0 ;;
  esac
  age=$((now - mtime))
  [ "$age" -ge "$interval" ]
}

_cync_mark_sync() {
  mkdir -p "$HOME/.claude" 2>/dev/null || return 0
  : > "$HOME/.claude/cync-last-sync" 2>/dev/null || true
}

claude() {
  if _cync_should_sync; then
    # 1) self-update the installer
    [ -n "${CYNC_DIR:-}" ] && _cync_pull "installer" "$CYNC_DIR"

    # 2) update the config repo
    [ -n "${_claude_config_repo:-}" ] && _cync_pull "config repo" "$_claude_config_repo"

    # 3) plugin HEAD check + cache invalidation (needs jq)
    _claude_refresh_plugins || true

    _cync_mark_sync
  fi

  # 4) invoke the real claude
  command claude "$@"
  local rc=$?

  # 5) optional auto-push: opt-in via CYNC_AUTO_PUSH=1. Useful when you
  #    edit slash commands / agents inside the claude session and want
  #    them propagated to other machines without remembering to commit.
  if [ "${CYNC_AUTO_PUSH:-0}" = "1" ] \
     && [ -n "${_claude_config_repo:-}" ] \
     && [ -d "${_claude_config_repo}/.git" ]; then
    if [ -n "$(git -C "$_claude_config_repo" status --porcelain 2>/dev/null)" ]; then
      cync-push "auto-push after claude session on $(hostname)" >/dev/null 2>&1 || \
        printf '\033[33m!!  cync: auto-push failed — run `cync-push` manually\033[0m\n' >&2
    fi
  fi

  return "$rc"
}

# cync-push — stage, commit, and push everything in your config repo.
#   cync-push                       # auto message ("cync-push from <host> ...")
#   cync-push "add /foo command"    # custom message
# Exits cleanly with no-op message if the working tree is clean.
cync-push() {
  local repo="${_claude_config_repo:-}"
  if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
    printf '\033[31mxx\033[0m  cync: _claude_config_repo not set or not a git repo\n' >&2
    return 1
  fi

  if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    printf '\033[36m==>\033[0m cync: nothing to push (working tree clean)\n'
    return 0
  fi

  local msg="${1:-cync-push from $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')}"

  printf '\033[36m==>\033[0m cync: pushing changes in %s\n' "$repo"
  if ( cd "$repo" && git add -A && git commit -m "$msg" --quiet && git push --quiet ); then
    printf '\033[36m==>\033[0m cync: pushed\n'
  else
    printf '\033[31mxx\033[0m  cync: push failed (likely diverged or offline) — try `cd %s && git pull --rebase` then retry\n' "$repo" >&2
    return 1
  fi
}

# cync-status — quick view of what's currently uncommitted in the config repo.
cync-status() {
  local repo="${_claude_config_repo:-}"
  if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
    printf '\033[31mxx\033[0m  cync: _claude_config_repo not set or not a git repo\n' >&2
    return 1
  fi
  printf '\033[36m==>\033[0m cync: %s\n' "$repo"
  git -C "$repo" status --short --branch
}

_claude_refresh_plugins() {
  command -v jq >/dev/null 2>&1 || return 0

  local settings="$HOME/.claude/settings.json"
  [ -r "$settings" ] || return 0

  local state_dir="$HOME/.claude/plugin-sync-state"
  local cache_dir="$HOME/.claude/plugins/cache"
  mkdir -p "$state_dir"

  local plugins
  plugins="$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$settings" 2>/dev/null)" || return 0
  [ -n "$plugins" ] || return 0

  local entry name marketplace repo remote_head local_head
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="${entry%@*}"
    marketplace="${entry#*@}"

    repo="$(jq -r --arg m "$marketplace" '
      (.extraKnownMarketplaces // {})[$m]
        | if . == null then empty
          else (.source.repo // empty)
          end
    ' "$settings" 2>/dev/null)"

    [ -n "$repo" ] || continue

    remote_head="$(git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$remote_head" ] || continue

    local marker="$state_dir/$name@$marketplace"
    local_head=""
    [ -r "$marker" ] && local_head="$(cat "$marker" 2>/dev/null || true)"

    if [ "$remote_head" != "$local_head" ]; then
      if [ -d "$cache_dir/$name" ]; then
        rm -rf "$cache_dir/$name"
      fi
      printf '%s\n' "$remote_head" > "$marker"
    fi
  done <<< "$plugins"
}
