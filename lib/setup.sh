#!/usr/bin/env bash
# lib/setup.sh — main setup flow.
# Invoked by the top-level install script after it has cloned ~/.cync.
set -euo pipefail

CYNC_DIR="${CYNC_DIR:-$HOME/.cync}"

# Keep prompts working when invoked via `curl ... | bash` (stdin is the pipe,
# not a terminal). Reattach stdin to the controlling TTY if one is actually
# openable — the `-r` flag can report yes while the device still fails to open
# (e.g. inside sandboxes), so probe it in a subshell before redirecting.
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
  exec </dev/tty
fi

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()   { printf '\033[31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# section — print a strong visual divider so each interactive prompt clearly
# stands apart from the surrounding logs. Modeled on Homebrew/rustup-init style:
# scrolls (preserves history) but with a heading bar that's hard to miss.
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
# 1. Prerequisite checks
# ---------------------------------------------------------------------------
info "Checking prerequisites"

# require_bin <command> <hint-block>
# Prints a friendly multi-line hint when the binary is missing, so first-time
# users know exactly how to install each prerequisite instead of guessing.
require_bin() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    {
      printf '\033[31mxx\033[0m  %s is required but not installed.\n\n' "$bin"
      printf '%s\n\n' "$hint"
      printf '    Then re-run this installer.\n'
    } >&2
    exit 1
  fi
}

require_bin git "    Install:
      macOS:  xcode-select --install   (or: brew install git)
      Linux:  apt install git          (or: yum install git / pacman -S git)"

require_bin node "    Install via nvm (recommended) or your distro's package:
      macOS:  brew install node       (or: nvm install --lts)
      Linux:  apt install nodejs npm  (or: nvm install --lts)
      Docs:   https://nodejs.org/"

require_bin claude "    Install Claude Code:
      curl -fsSL https://claude.ai/install.sh | bash
      (or: npm install -g @anthropic-ai/claude-code)
      Docs: https://docs.anthropic.com/claude-code"

require_bin gh "    Install GitHub CLI:
      macOS:  brew install gh
      Linux:  see https://github.com/cli/cli/blob/trunk/docs/install_linux.md"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found — plugin sync will be skipped at runtime (non-fatal)."
fi

# ---------------------------------------------------------------------------
# 2. gh authentication
# ---------------------------------------------------------------------------
if gh auth status >/dev/null 2>&1; then
  info "gh already authenticated"
else
  info "Launching gh auth login (browser OAuth)"
  gh auth login --hostname github.com --git-protocol https --web
fi

GH_USER="$(gh api user --jq .login)"
[ -n "$GH_USER" ] || die "could not determine GitHub user"
info "Authenticated as $GH_USER"

# ---------------------------------------------------------------------------
# 3. Pick or create the config repo
# ---------------------------------------------------------------------------
section "Pick your config repo"
echo "  Use an existing repo as your Claude Code config, or create a new"
echo "  private one. Pick a number, or Q to quit."
echo

REPOS=()
while IFS= read -r line; do
  REPOS+=("$line")
done < <(gh repo list --limit 1000 --json nameWithOwner,visibility,description \
  --jq '.[] | "\(.nameWithOwner)\t\(.visibility)\t\(.description // "")"')

i=1
for line in "${REPOS[@]}"; do
  name="$(printf '%s' "$line" | cut -f1)"
  vis="$(printf '%s'  "$line" | cut -f2 | tr '[:upper:]' '[:lower:]')"
  desc="$(printf '%s' "$line" | cut -f3)"
  printf '  [%2d] %-40s (%s)%s\n' "$i" "$name" "$vis" "${desc:+  — $desc}"
  i=$((i+1))
done
CREATE_IDX=$i
printf '  [%2d] *** Create new private repo ***\n' "$CREATE_IDX"
printf '  [ Q] Quit\n'
echo

read -r -p "> Choice: " choice
[ -n "$choice" ] || die "no choice given"

if [[ "$choice" =~ ^[Qq]$ ]]; then
  info "Quitting"
  exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
  die "invalid choice: $choice"
fi

REPO_VISIBILITY=""

if [ "$choice" -eq "$CREATE_IDX" ]; then
  section "Name your new private repo"
  echo "  Examples: claude-config, my-claude-setup, dotfiles-claude"
  echo "  Allowed:  letters, digits, '.', '_', '-'  (must start with letter/digit)"
  echo

  repo_name=""
  while [ -z "$repo_name" ]; do
    read -r -p "> Repo name: " repo_name
    if [ -z "$repo_name" ]; then
      warn "repo name is required"
      continue
    fi
    if ! [[ "$repo_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "invalid repo name '$repo_name' — use letters, digits, '.', '_', '-' and start with letter/digit"
      repo_name=""
      continue
    fi
    # Pre-flight: a repo with this name already on GitHub would make
    # `gh repo create` fail with a non-obvious error and abort the script.
    # Catch it here and let the user pick another name.
    if gh repo view "$GH_USER/$repo_name" >/dev/null 2>&1; then
      warn "$GH_USER/$repo_name already exists on GitHub — pick a different name (or quit with Ctrl+C and re-run setup to select it from the menu)"
      repo_name=""
      continue
    fi
  done
  REPO="$GH_USER/$repo_name"
  REPO_VISIBILITY="private"

  info "Creating $REPO (private)"
  gh repo create "$REPO" --private --description "Claude Code config"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Pick sane commit author: prefer the user's existing git config, then the
  # authenticated GitHub user's profile, then GitHub's noreply email as a
  # last-resort fallback so we never leave a bogus "cync@local" in history.
  gh_name="$(gh api user --jq '.name // ""' 2>/dev/null || true)"
  gh_email="$(gh api user --jq '.email // ""' 2>/dev/null || true)"
  gh_id="$(gh api user --jq '.id // empty' 2>/dev/null || true)"
  git_name="$(git config --global user.name 2>/dev/null || true)"
  git_email="$(git config --global user.email 2>/dev/null || true)"

  commit_name="${git_name:-${gh_name:-$GH_USER}}"
  if [ -n "$git_email" ]; then
    commit_email="$git_email"
  elif [ -n "$gh_email" ]; then
    commit_email="$gh_email"
  elif [ -n "$gh_id" ]; then
    commit_email="${gh_id}+${GH_USER}@users.noreply.github.com"
  else
    commit_email="${GH_USER}@users.noreply.github.com"
  fi

  info "Populating template files (author: $commit_name <$commit_email>)"
  gh repo clone "$REPO" "$tmpdir/repo"
  cp -a "$CYNC_DIR/template/." "$tmpdir/repo/"
  (
    cd "$tmpdir/repo"
    git add -A
    git -c user.email="$commit_email" \
        -c user.name="$commit_name" \
        commit -m "Initial config from cync template"
    git push -u origin HEAD
  )
  rm -rf "$tmpdir"
  trap - EXIT
else
  idx=$((choice - 1))
  [ "$idx" -ge 0 ] && [ "$idx" -lt "${#REPOS[@]}" ] || die "choice out of range: $choice"
  REPO="$(printf '%s' "${REPOS[$idx]}" | cut -f1)"
  REPO_VISIBILITY="$(printf '%s' "${REPOS[$idx]}" | cut -f2 | tr '[:upper:]' '[:lower:]')"
fi

info "Using config repo: $REPO"

# Warn loudly if the user pointed cync at a public repo — settings and
# CLAUDE.md can contain tokens, usernames, or private prompts they don't
# want on the open internet.
if [ "$REPO_VISIBILITY" = "public" ]; then
  section "⚠  This repo is PUBLIC"
  echo "  $REPO is publicly visible on GitHub."
  echo "  Your settings.json, CLAUDE.md, commands, agents, and skills"
  echo "  will be readable by anyone on the internet."
  echo
  confirm=""
  read -r -p "> Continue anyway? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "aborted — pick or create a private repo instead"
fi

# ---------------------------------------------------------------------------
# 4. Clone destination
# ---------------------------------------------------------------------------
section "Where should this machine clone the repo?"
default_dir="$HOME/$(basename "$REPO")"
echo "  Default: $default_dir"
echo "  Press Enter to use the default, or type a different path."
echo

read -r -p "> Clone path: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$default_dir}"

if [ -d "$TARGET_DIR/.git" ]; then
  # Make sure the existing clone is actually $REPO — otherwise `git pull` would
  # either fail cryptically or silently update the wrong repo.
  current_url="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"
  expected_https="https://github.com/$REPO.git"
  expected_ssh="git@github.com:$REPO.git"
  expected_https_noext="https://github.com/$REPO"
  if [ -z "$current_url" ]; then
    die "$TARGET_DIR has a .git directory but no 'origin' remote — fix the repo or pick a different path"
  fi
  case "$current_url" in
    "$expected_https"|"$expected_ssh"|"$expected_https_noext") ;;
    *) die "$TARGET_DIR is a git repo but its origin is '$current_url', not '$REPO' — remove it or pick a different path" ;;
  esac
  info "Existing clone at $TARGET_DIR — pulling"
  (cd "$TARGET_DIR" && git pull --ff-only)
elif [ -e "$TARGET_DIR" ]; then
  die "$TARGET_DIR already exists and is not a git repo — remove it or pick a different path"
else
  info "Cloning $REPO into $TARGET_DIR"
  gh repo clone "$REPO" "$TARGET_DIR"
fi

# ---------------------------------------------------------------------------
# 5. Run install.sh (symlinks + rc file marker)
# ---------------------------------------------------------------------------
export CYNC_DIR
export _claude_config_repo="$TARGET_DIR"

info "Running lib/install.sh"
bash "$CYNC_DIR/lib/install.sh"

# ---------------------------------------------------------------------------
# 6. Done
# ---------------------------------------------------------------------------
section "Done — one more step"
cat <<EOF
  Reload your shell so the 'claude' wrapper takes effect:

    source ~/.zshrc       # macOS / zsh
    source ~/.bashrc      # Linux / bash

  Or just open a new terminal. Then:

    claude

  Config repo:  $REPO
  Clone path:   $TARGET_DIR

EOF
