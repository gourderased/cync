# lib/claude-wrapper.sh — overrides the `claude` command with a shell function
# that keeps the cync installer, the user's config repo, and plugin caches in
# sync before invoking the real binary.
#
# Sourced from the user's rc file via the cync marker block.

claude() {
  # 1) self-update the installer
  if [ -n "${CYNC_DIR:-}" ] && [ -d "$CYNC_DIR/.git" ]; then
    (cd "$CYNC_DIR" && git pull --ff-only --quiet) >/dev/null 2>&1 || true
  fi

  # 2) update the config repo
  if [ -n "${_claude_config_repo:-}" ] && [ -d "$_claude_config_repo/.git" ]; then
    (cd "$_claude_config_repo" && git pull --ff-only --quiet) >/dev/null 2>&1 || true
  fi

  # 3) plugin HEAD check + cache invalidation (needs jq)
  _claude_refresh_plugins || true

  # 4) invoke the real claude
  command claude "$@"
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
