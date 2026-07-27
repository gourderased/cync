# lib/claude-wrapper.sh — overrides the `claude` and `codex` commands with
# shell functions that keep the cync installer, the user's config repo, and
# the per-tool config in sync before invoking the real binary.
#
# Sourced from the user's rc file via the cync marker block.

# The rc block exports CYNC_CONFIG_REPO. Machines set up before cync handled
# Codex export _claude_config_repo instead, and their rc block is only
# rewritten when the installer runs again — which may be never. Accept either,
# preferring the new name, so a machine keeps working until it's reinstalled.
: "${CYNC_CONFIG_REPO:=${_claude_config_repo-}}"
export CYNC_CONFIG_REPO

# Rendering instructions and linking Codex skills lives in its own file so
# lib/install.sh can reuse it at setup time.
if [ -n "${CYNC_DIR:-}" ] && [ -r "$CYNC_DIR/lib/sync-targets.sh" ]; then
  . "$CYNC_DIR/lib/sync-targets.sh"
fi

_cync_pull() {
  # $1 = friendly label for warnings, $2 = repo dir
  local label="$1" dir="$2" out before after
  [ -d "$dir/.git" ] || return 0
  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
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
    return 0
  fi
  # Say what just arrived — silent syncing makes "why did my settings
  # change?" a mystery. Quiet when nothing was pulled (the common case).
  after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    local n files
    n="$(git -C "$dir" rev-list --count "$before..$after" 2>/dev/null || echo '?')"
    files="$(git -C "$dir" diff --name-only "$before" "$after" 2>/dev/null | head -5 | tr '\n' ' ')"
    printf '\033[36m==>\033[0m cync: %s updated (%s commit(s)): %s\n' \
      "$label" "$n" "${files% }" >&2
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

# _cync_push_reminder — one-line nudge when the config repo has local work
# other machines can't see yet (uncommitted changes or unpushed commits).
# Local-only checks, no network. Runs on the throttled sync path so it
# doesn't nag on every single launch.
_cync_push_reminder() {
  local repo="${CYNC_CONFIG_REPO:-}"
  { [ -n "$repo" ] && [ -d "$repo/.git" ]; } || return 0
  local dirty ahead
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null | grep -c .)"
  ahead="$(git -C "$repo" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
  case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
  if [ "$dirty" -gt 0 ] || [ "$ahead" -gt 0 ]; then
    printf '\033[33m!!  cync: config repo has %s uncommitted change(s), %s unpushed commit(s) — run `cync-push` so other machines pick them up\033[0m\n' \
      "$dirty" "$ahead" >&2
  fi
  return 0
}

# _cync_do_sync — one full sync round, shared by claude(), codex() and cync-sync.
_cync_do_sync() {
  # Mark first so a second `claude` started moments later skips straight
  # to the binary instead of racing this shell's git pulls.
  _cync_mark_sync

  # 1) self-update the installer
  [ -n "${CYNC_DIR:-}" ] && _cync_pull "installer" "$CYNC_DIR"

  # 2) update the config repo
  [ -n "${CYNC_CONFIG_REPO:-}" ] && _cync_pull "config repo" "$CYNC_CONFIG_REPO"

  # 3) render per-tool instructions + link shared skills, now that the repo
  #    is current. Guarded because an older ~/.cync won't have the file yet.
  if command -v _cync_apply_config >/dev/null 2>&1; then
    _cync_apply_config || true
  fi

  # 4) refresh handoff notes and say whether this directory has one
  _cync_state_sync || true

  # 5) plugin upstream-update check — notify only (needs jq)
  _claude_refresh_plugins || true

  # 6) nudge if local config changes haven't been pushed yet
  _cync_push_reminder
  return 0
}

# _cync_state_clone — set the handoff store up on a machine that doesn't have
# it yet, so a new server picks up handoffs without a manual clone step. The
# step is easy to forget and failing to do it is invisible: work just silently
# doesn't carry over.
#
# The remote is derived from the config repo's origin — same host and owner,
# repo named after the destination directory. A machine that has one already
# has credentials for the other.
#
# The failure marker keeps a machine with no state repo (or no access) from
# making a network call on every launch. `cync-sync` clears it to retry.
_cync_state_clone() {
  local dest="$1"
  local marker="$HOME/.claude/cync-state-unavailable"
  [ -e "$dest" ] && return 1        # exists but isn't a git repo — leave it alone
  [ -f "$marker" ] && return 1

  local origin url
  origin="$(git -C "${CYNC_CONFIG_REPO:-.}" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$origin" ] || return 1
  url="${origin%/*}/$(basename "$dest").git"

  if ! git ls-remote "$url" HEAD >/dev/null 2>&1; then
    : > "$marker" 2>/dev/null
    return 1
  fi

  printf '\033[36m==>\033[0m cync: setting up handoff store from %s\n' "$url" >&2
  if git clone --quiet "$url" "$dest" 2>/dev/null; then
    printf '\033[36m==>\033[0m cync: handoff store ready at %s\n' "$dest" >&2
    return 0
  fi

  : > "$marker" 2>/dev/null
  printf '\033[33m!!\033[0m  cync: could not clone %s — handoffs from other machines will not appear here (`cync-sync` retries)\n' \
    "$url" >&2
  return 1
}

# _cync_state_sync — pull the handoff store and point out a note for the
# directory the tool is being launched from.
#
# Handoffs are what carries work between machines and between Claude Code and
# Codex (session files can't: different schemas, and Claude's alone run to
# ~100MB). The nudge exists because the cost of missing one is redoing work —
# the user has no other signal that a previous session left instructions here.
#
# Opt out with CYNC_STATE_REPO="" in your rc file, outside the cync block.
_cync_state_sync() {
  local repo="${CYNC_STATE_REPO-$HOME/agent-state}"
  [ -n "$repo" ] || return 0

  if [ ! -d "$repo/.git" ]; then
    _cync_state_clone "$repo" || return 0
  fi

  _cync_pull "handoff store" "$repo"

  # Same slug rule the handoff skill uses: repo root when there is one, so a
  # note saved from a subdirectory is still found from the project root.
  local root rel slug
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  rel="${root#$HOME}"
  rel="${rel#/}"
  slug="$(printf '%s' "${rel:-home}" | tr '/' '_')"

  local note="$repo/$slug/handoff.md"
  [ -f "$note" ] || return 0

  # Show when it was written and by whom — a note from this machine minutes
  # ago means something different than one from a server last week.
  local stamp
  stamp="$(sed -n 's/^updated: *//p' "$note" 2>/dev/null | head -1)"
  printf '\033[36m==>\033[0m cync: 이 디렉토리에 인계 노트가 있다%s — 이어서 하려면 `handoff` 스킬\n' \
    "${stamp:+ ($stamp)}" >&2
  return 0
}

# The `command -v _cync_do_sync` guard covers shells that get the wrapper
# functions without the helpers they call. Claude Code's shell snapshots are
# one: they capture `claude`, `codex` and the cync-* commands but skip every
# function whose name starts with an underscore, so `claude` printed
# "command not found: _cync_should_sync" there before running the binary.
# Skipping the sync round is right in that situation anyway — a tool call
# shouldn't be making git pulls — so degrade quietly instead of warning.
# The guard has to be inline: a helper function would be filtered out too.
claude() {
  if command -v _cync_do_sync >/dev/null 2>&1 && _cync_should_sync; then
    _cync_do_sync
  fi

  # invoke the real claude
  command claude "$@"
}

# codex() — the same sync round as claude(). The throttle marker is shared on
# purpose: launching codex right after claude shouldn't re-pull config that was
# just fetched. The plugin check inside runs either way; its notice names
# claude explicitly, and it only fires when an upstream plugin actually moved.
codex() {
  if command -v _cync_do_sync >/dev/null 2>&1 && _cync_should_sync; then
    _cync_do_sync
  fi

  command codex "$@"
}

# cync-sync — force a sync round right now, ignoring the throttle. Handy
# right after pushing from another machine (beats the old workaround of
# `rm ~/.claude/cync-last-sync` + relaunching claude).
cync-sync() {
  # Unlike the launch path, an explicit sync request that can't run should say
  # why rather than quietly doing nothing. See the note above claude().
  if ! command -v _cync_do_sync >/dev/null 2>&1; then
    printf '\033[31mxx\033[0m  cync: helper functions not loaded in this shell — run `cync-sync` from an interactive shell\n' >&2
    return 1
  fi
  # An explicit sync is the retry path for a handoff store that couldn't be
  # cloned earlier — the launch path stops trying so it isn't hitting the
  # network every time.
  rm -f "$HOME/.claude/cync-state-unavailable" 2>/dev/null
  _cync_do_sync
  printf '\033[36m==>\033[0m cync: sync complete\n'
}

# cync-push — stage, commit, and push everything in your config repo.
#   cync-push                       # auto message ("cync-push from <host> ...")
#   cync-push "add /foo command"    # custom message
# Exits cleanly with no-op message if the working tree is clean.
cync-push() {
  local repo="${CYNC_CONFIG_REPO:-}"
  if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
    printf '\033[31mxx\033[0m  cync: CYNC_CONFIG_REPO not set or not a git repo\n' >&2
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
    return 0
  fi
  # Push rejected. Most common cause: another machine pushed first, so the
  # remote moved ahead of us (diverged). Auto-rebase our commit on top and
  # retry once — silent when the two machines touched different files. Falls
  # through to the manual path on a real conflict (same file, same lines) or
  # when we're simply offline (the pull below also fails).
  printf '\033[33m!!\033[0m  cync: push rejected (remote advanced or offline) — trying pull --rebase\n' >&2
  if git -C "$repo" pull --rebase --quiet && git -C "$repo" push --quiet; then
    printf '\033[36m==>\033[0m cync: pushed after rebase\n'
    return 0
  fi
  printf '\033[31mxx\033[0m  cync: auto-rebase failed — your commit is safe locally. If offline, retry later; if there is a merge conflict, resolve it in %s (git status), then run `git -C %s rebase --continue` and `cync-push` again\n' "$repo" "$repo" >&2
  return 1
}

# cync-doctor — read-only health check of the whole cync wiring. One line
# per check (ok / !! warning / xx broken); exits non-zero when something
# is actually broken. Touches nothing; the only network call is one
# `git ls-remote` to test reachability.
cync-doctor() {
  # NB: never `local path` here — in zsh `path` is tied to $PATH, and making
  # it local empties PATH for the whole function (every external command
  # becomes "not found").
  local repo="${CYNC_CONFIG_REPO:-}" fail=0 name link target

  # 1) env wiring
  if [ -n "${CYNC_DIR:-}" ] && [ -d "${CYNC_DIR:-}" ]; then
    printf '\033[32mok\033[0m  CYNC_DIR → %s\n' "$CYNC_DIR"
  else
    printf '\033[31mxx\033[0m  CYNC_DIR unset or missing — re-run the cync installer\n'; fail=$((fail+1))
  fi
  if [ -n "$repo" ] && [ -d "$repo/.git" ]; then
    printf '\033[32mok\033[0m  config repo → %s\n' "$repo"
  else
    printf '\033[31mxx\033[0m  CYNC_CONFIG_REPO unset or not a git repo (%s)\n' "${repo:-empty}"; fail=$((fail+1))
    repo=""
  fi

  # 2) rc-file marker block
  if grep -qs 'BEGIN cync' "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
    printf '\033[32mok\033[0m  cync block present in rc file\n'
  else
    printf '\033[31mxx\033[0m  no cync marker block in ~/.zshrc or ~/.bashrc — wrapper won'\''t load in new shells\n'; fail=$((fail+1))
  fi

  # 3) ~/.claude symlinks point into the config repo.
  # CLAUDE.md is not in this list — it's generated from instructions/, not
  # symlinked. It's checked in step 3b along with Codex's AGENTS.md.
  for name in settings.json commands agents skills; do
    link="$HOME/.claude/$name"
    if [ ! -L "$link" ]; then
      printf '\033[31mxx\033[0m  ~/.claude/%s is not a symlink — machine is detached from the config repo for this file\n' "$name"; fail=$((fail+1))
    elif [ ! -e "$link" ]; then
      printf '\033[31mxx\033[0m  ~/.claude/%s is a BROKEN symlink (target missing)\n' "$name"; fail=$((fail+1))
    else
      target="$(readlink "$link")"
      if [ -n "$repo" ]; then
        case "$target" in
          "$repo"|"$repo"/*) printf '\033[32mok\033[0m  ~/.claude/%s → repo\n' "$name" ;;
          *) printf '\033[33m!!\033[0m  ~/.claude/%s points outside the config repo (%s)\n' "$name" "$target" ;;
        esac
      else
        printf '\033[32mok\033[0m  ~/.claude/%s is a symlink (repo unknown, target unchecked)\n' "$name"
      fi
    fi
  done

  # 3b) generated instruction files, and the skills shared with Codex.
  # A stale generated file means a machine is running instructions that no
  # longer match the repo — invisible unless something checks for it.
  local gen
  for gen in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"; do
    if [ -L "$gen" ]; then
      printf '\033[33m!!\033[0m  %s is still a symlink — pre-rendering install; open a new shell to migrate\n' "${gen#$HOME/}"
    elif [ ! -f "$gen" ]; then
      # Only Claude's is mandatory; Codex may simply not be installed here.
      case "$gen" in
        *".codex/"*) command -v codex >/dev/null 2>&1 \
            && { printf '\033[31mxx\033[0m  codex is installed but %s is missing\n' "${gen#$HOME/}"; fail=$((fail+1)); } ;;
        *) printf '\033[31mxx\033[0m  %s missing — instructions are not loading\n' "${gen#$HOME/}"; fail=$((fail+1)) ;;
      esac
    elif grep -q '자동 생성됨' "$gen" 2>/dev/null; then
      printf '\033[32mok\033[0m  %s generated from instructions/\n' "${gen#$HOME/}"
    else
      printf '\033[33m!!\033[0m  %s exists but was not generated by cync — hand edits are overwritten on the next sync\n' "${gen#$HOME/}"
    fi
  done

  if [ -n "$repo" ] && [ -d "$HOME/.codex" ]; then
    local linked=0 skill
    for skill in "$HOME/.codex/skills"/*; do
      [ -L "$skill" ] || continue
      case "$(readlink "$skill" 2>/dev/null)" in
        "$repo/skills/"*) linked=$((linked+1)) ;;
      esac
    done
    printf '\033[32mok\033[0m  %s skill(s) shared into ~/.codex/skills\n' "$linked"
  fi

  # 3c) handoff store — how work moves between machines and tools
  local state="${CYNC_STATE_REPO-$HOME/agent-state}"
  if [ -z "$state" ]; then
    printf '\033[32mok\033[0m  handoff store disabled (CYNC_STATE_REPO is empty)\n'
  elif [ -d "$state/.git" ]; then
    printf '\033[32mok\033[0m  handoff store → %s\n' "$state"
  elif [ -f "$HOME/.claude/cync-state-unavailable" ]; then
    printf '\033[33m!!\033[0m  handoff store at %s could not be set up — `cync-sync` retries; work from other machines will not appear until it succeeds\n' "$state"
  else
    printf '\033[33m!!\033[0m  no handoff store at %s yet — the next launch will try to clone it\n' "$state"
  fi

  # 4) repo branch health + local state
  if [ -n "$repo" ]; then
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null 2>&1; then
      printf '\033[31mxx\033[0m  config repo is on a detached HEAD — auto-sync can'\''t fast-forward; `git -C %s checkout main`\n' "$repo"; fail=$((fail+1))
    elif ! git -C "$repo" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      printf '\033[31mxx\033[0m  config repo branch has no upstream — `git -C %s branch --set-upstream-to origin/main`\n' "$repo"; fail=$((fail+1))
    else
      printf '\033[32mok\033[0m  config repo on a tracking branch (%s)\n' "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    local dirty ahead
    dirty="$(git -C "$repo" status --porcelain 2>/dev/null | grep -c .)"
    ahead="$(git -C "$repo" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
    case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    if [ "$dirty" -gt 0 ] || [ "$ahead" -gt 0 ]; then
      printf '\033[33m!!\033[0m  unsynced local work: %s uncommitted, %s unpushed — run `cync-push`\n' "$dirty" "$ahead"
    else
      printf '\033[32mok\033[0m  no unsynced local work\n'
    fi
    # 5) remote reachability (the one network call)
    if git -C "$repo" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
      printf '\033[32mok\033[0m  remote reachable\n'
    else
      printf '\033[33m!!\033[0m  remote unreachable (offline, or credentials expired?) — pulls/pushes will fail until this recovers\n'
    fi
  fi

  # 6) optional tooling
  if command -v jq >/dev/null 2>&1; then
    printf '\033[32mok\033[0m  jq installed (plugin update notices active)\n'
  else
    printf '\033[33m!!\033[0m  jq missing — plugin update notices are silently disabled\n'
  fi

  # 7) sync marker age
  local marker="$HOME/.claude/cync-last-sync" mtime age
  if [ -f "$marker" ]; then
    mtime="$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0)"
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    age=$(( $(date +%s) - mtime ))
    printf '\033[32mok\033[0m  last sync attempt %ss ago (throttle: %ss)\n' "$age" "${CYNC_SYNC_INTERVAL:-60}"
  else
    printf '\033[33m!!\033[0m  no sync marker — next `claude` (or `cync-sync`) will sync\n'
  fi

  if [ "$fail" -eq 0 ]; then
    printf '\033[36m==>\033[0m cync: healthy\n'
  else
    printf '\033[31mxx\033[0m  cync: %s problem(s) found above\n' "$fail" >&2
  fi
  return "$fail"
}

# cync-status — quick view of the config repo: uncommitted work, how far
# ahead/behind the remote we are (after a fetch), and what landed recently.
cync-status() {
  local repo="${CYNC_CONFIG_REPO:-}"
  if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
    printf '\033[31mxx\033[0m  cync: CYNC_CONFIG_REPO not set or not a git repo\n' >&2
    return 1
  fi
  printf '\033[36m==>\033[0m cync: %s\n' "$repo"
  # Fetch so the ahead/behind counts below reflect the actual remote, not
  # whatever we last happened to pull. Stale view is better than no view.
  git -C "$repo" fetch --quiet 2>/dev/null \
    || printf '\033[33m!!\033[0m  fetch failed (offline?) — counts below may be stale\n' >&2
  git -C "$repo" status --short --branch
  printf '\033[36m==>\033[0m recent commits:\n'
  git -C "$repo" log --oneline -3 2>/dev/null
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
