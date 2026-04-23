#!/usr/bin/env bash
# lib/setup.sh — main setup flow.
# Invoked by the top-level install script after it has cloned ~/.cync.
set -euo pipefail

CYNC_DIR="${CYNC_DIR:-$HOME/.cync}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()   { printf '\033[31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisite checks
# ---------------------------------------------------------------------------
info "Checking prerequisites"

for bin in git node claude; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

if ! command -v gh >/dev/null 2>&1; then
  cat >&2 <<'EOF'
xx  gh (GitHub CLI) is required but not installed.

    Install it first:
      macOS:  brew install gh
      Linux:  see https://github.com/cli/cli/blob/trunk/docs/install_linux.md

    Then re-run this installer.
EOF
  exit 1
fi

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
bold ""
bold "Select a config repo"
bold "---------------------"

REPOS=()
while IFS= read -r line; do
  REPOS+=("$line")
done < <(gh repo list --limit 100 --json nameWithOwner,visibility,description \
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
printf '  [ Q] Quit\n\n'

read -r -p "Choice: " choice
[ -n "$choice" ] || die "no choice given"

if [[ "$choice" =~ ^[Qq]$ ]]; then
  info "Quitting"
  exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
  die "invalid choice: $choice"
fi

if [ "$choice" -eq "$CREATE_IDX" ]; then
  read -r -p "Repo name [claude-config]: " repo_name
  repo_name="${repo_name:-claude-config}"
  REPO="$GH_USER/$repo_name"

  info "Creating $REPO (private)"
  gh repo create "$REPO" --private --description "Claude Code config"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  info "Populating template files"
  gh repo clone "$REPO" "$tmpdir/repo"
  cp -a "$CYNC_DIR/template/." "$tmpdir/repo/"
  (
    cd "$tmpdir/repo"
    git add -A
    git -c user.email="${GIT_AUTHOR_EMAIL:-cync@local}" \
        -c user.name="${GIT_AUTHOR_NAME:-cync}" \
        commit -m "Initial config from cync template"
    git push -u origin HEAD
  )
  rm -rf "$tmpdir"
  trap - EXIT
else
  idx=$((choice - 1))
  [ "$idx" -ge 0 ] && [ "$idx" -lt "${#REPOS[@]}" ] || die "choice out of range: $choice"
  REPO="$(printf '%s' "${REPOS[$idx]}" | cut -f1)"
fi

info "Using config repo: $REPO"

# ---------------------------------------------------------------------------
# 4. Clone destination
# ---------------------------------------------------------------------------
default_dir="$HOME/$(basename "$REPO")"
read -r -p "Clone path [$default_dir]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$default_dir}"

if [ -d "$TARGET_DIR/.git" ]; then
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
bold ""
bold "Done!"
cat <<EOF

Next step — reload your shell so the 'claude' wrapper is active:

  source ~/.zshrc     # macOS / zsh
  source ~/.bashrc    # Linux / bash

Then just run:

  claude

EOF
