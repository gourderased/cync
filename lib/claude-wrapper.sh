# lib/claude-wrapper.sh — overrides the `claude` command with a shell function
# that keeps the cync installer, the user's config repo, and plugin caches in
# sync before invoking the real binary.
#
# Sourced from the user's rc file via the cync marker block.

_cync_pull() {
  # $1 = friendly label for warnings, $2 = repo dir
  local label="$1" dir="$2" out
  [ -d "$dir/.git" ] || return 0
  if ! out="$(git -C "$dir" pull --ff-only --quiet 2>&1)"; then
    printf '\033[33m!!  cync: skipping %s auto-sync (%s)\033[0m\n' \
      "$label" "$(printf '%s' "$out" | head -1)" >&2
    # Detached HEAD / no upstream fails on every launch — tell the user how
    # to actually silence it instead of warning forever.
    case "$out" in
      *"not currently on a branch"*|*"no tracking information"*)
        printf '\033[33m!!  cync: %s has no upstream branch — check out a tracking branch (e.g. `git -C %s checkout main`) to stop this warning\033[0m\n' \
          "$label" "$dir" >&2 ;;
    esac
  fi
}

# Throttle network sync so `claude` doesn't make a round of git pulls and
# `git ls-remote` calls on every single invocation. Defaults to once per
# 60 seconds; override with CYNC_SYNC_INTERVAL=<seconds> (use 0 to force
# every call, or `rm ~/.claude/cync-last-sync` for a one-shot bypass).
_cync_should_sync() {
  local marker="$HOME/.claude/cync-last-sync"
  local interval="${CYNC_SYNC_INTERVAL:-60}"
  # Non-numeric override (typo etc.) falls back to the default instead of
  # spraying arithmetic errors on every `claude` launch.
  case "$interval" in
    ''|*[!0-9]*) interval=60 ;;
  esac
  [ "$interval" -eq 0 ] && return 0
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
    # Mark first so a second `claude` started moments later skips straight
    # to the binary instead of racing this shell's git pulls.
    _cync_mark_sync

    # 1) self-update the installer
    [ -n "${CYNC_DIR:-}" ] && _cync_pull "installer" "$CYNC_DIR"

    # 2) update the config repo
    [ -n "${_claude_config_repo:-}" ] && _cync_pull "config repo" "$_claude_config_repo"

    # 3) plugin upstream-update check — notify only (needs jq)
    _claude_refresh_plugins || true
  fi

  # 4) invoke the real claude
  command claude "$@"
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

  # Catch a missing git identity up front — otherwise `git commit` fails with
  # an error this function used to misreport as "diverged or offline".
  if [ -z "$(git -C "$repo" config user.email 2>/dev/null)" ] \
  || [ -z "$(git -C "$repo" config user.name 2>/dev/null)" ]; then
    printf '\033[31mxx\033[0m  cync: git identity not set — run `git config --global user.name "You"` and `git config --global user.email you@example.com` first\n' >&2
    return 1
  fi

  if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    # Tree is clean, but an earlier run may have committed and then failed to
    # push (offline) — without this check that commit would sit unpushed
    # forever while cync-push keeps saying "nothing to push".
    local ahead
    ahead="$(git -C "$repo" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    if [ "$ahead" -gt 0 ]; then
      printf '\033[36m==>\033[0m cync: nothing new to commit — pushing %s earlier unpushed commit(s)\n' "$ahead"
      if git -C "$repo" push --quiet; then
        printf '\033[36m==>\033[0m cync: pushed\n'
        return 0
      fi
      printf '\033[31mxx\033[0m  cync: push failed (offline or diverged) — run `git -C %s pull --rebase` then retry\n' "$repo" >&2
      return 1
    fi
    printf '\033[36m==>\033[0m cync: nothing to push (working tree clean)\n'
    return 0
  fi

  local msg="${1:-cync-push from $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')}"

  printf '\033[36m==>\033[0m cync: pushing changes in %s\n' "$repo"
  if ! git -C "$repo" add -A || ! git -C "$repo" commit -m "$msg" --quiet; then
    printf '\033[31mxx\033[0m  cync: commit failed — fix the git error above and retry\n' >&2
    return 1
  fi
  if git -C "$repo" push --quiet; then
    printf '\033[36m==>\033[0m cync: pushed\n'
  else
    printf '\033[31mxx\033[0m  cync: committed locally but push failed (offline or diverged) — your changes are safe; run `git -C %s pull --rebase` then `cync-push` again\n' "$repo" >&2
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

# _claude_refresh_plugins — notify (never touch) when an enabled plugin's
# upstream HEAD has moved.
#
# History: cync used to `rm -rf` the plugin's cache dir here on a SHA change,
# assuming Claude Code would re-install it. It doesn't — installed_plugins.json
# kept saying "installed" while the cache was gone, so the plugin (e.g. a
# statusline) silently broke until a manual reinstall. Plugin install/cache is
# Claude Code's own responsibility; cync only surfaces "an update exists" and
# lets the user run `/plugin update` on their own schedule. No destructive ops.
_claude_refresh_plugins() {
  command -v jq >/dev/null 2>&1 || return 0

  local settings="$HOME/.claude/settings.json"
  [ -r "$settings" ] || return 0

  local state_dir="$HOME/.claude/plugin-sync-state"
  mkdir -p "$state_dir" 2>/dev/null || return 0

  local plugins
  plugins="$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$settings" 2>/dev/null)" || return 0
  [ -n "$plugins" ] || return 0

  local entry name marketplace repo remote_head local_head marker
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    # Split on the LAST `@`: marketplace names can't contain `@`, but a
    # plugin name theoretically could — `#*@` would mis-split `a@b@c`.
    name="${entry%@*}"
    marketplace="${entry##*@}"

    repo="$(jq -r --arg m "$marketplace" '
      (.extraKnownMarketplaces // {})[$m]
        | if . == null then empty
          else (.source.repo // empty)
          end
    ' "$settings" 2>/dev/null)"

    [ -n "$repo" ] || continue

    remote_head="$(git ls-remote "https://github.com/$repo.git" HEAD 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$remote_head" ] || continue

    marker="$state_dir/$name@$marketplace"
    local_head=""
    [ -r "$marker" ] && local_head="$(cat "$marker" 2>/dev/null || true)"

    # Only notify when we have a prior baseline AND it moved — never on the
    # first run (no baseline to compare). Update the marker either way so the
    # notice fires once per upstream change, not on every claude launch.
    if [ -n "$local_head" ] && [ "$remote_head" != "$local_head" ]; then
      printf '\033[36m==>\033[0m cync: %s has an upstream update (%s -> %s) — run `/plugin update` inside claude to refresh\n' \
        "$entry" "${local_head:0:7}" "${remote_head:0:7}" >&2
    fi
    printf '%s\n' "$remote_head" > "$marker"
  done <<< "$plugins"
}
