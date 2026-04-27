# cync

[한국어 README](./README.ko.md)

One-line installer that keeps your [Claude Code](https://docs.anthropic.com/claude-code) configuration in sync across every machine you use.

**Tool** and **data** are deliberately kept separate:

- **Tool (public, shared)** — this repo, `gourderased/cync`. Holds the installer and the `claude` shell wrapper. Everyone installs from the same place.
- **Data (private, yours)** — your `settings.json`, `CLAUDE.md`, `commands/`, `agents/`, `skills/` live in a private repo on *your* GitHub account. cync just wires it up via symlinks and a shell wrapper.

## How it works

```
                    ┌──────────────────────────────────────────┐
                    │  GitHub                                  │
                    │                                          │
                    │  gourderased/cync         (PUBLIC)       │  ← installer
                    │  ├ install / uninstall                   │
                    │  ├ lib/{setup, install, uninstall,       │
                    │  │      claude-wrapper}.sh               │
                    │  └ template/                             │
                    │                                          │
                    │  <user>/<config-repo>     (PRIVATE)      │  ← your settings
                    │  ├ settings.json                         │
                    │  ├ CLAUDE.md                             │
                    │  └ commands/  agents/  skills/           │
                    └────────────────────┬─────────────────────┘
                                         │
                                         │  HTTPS via gh CLI
                                         │
            ┌─────────────┬──────────────┼──────────────┬─────────────┐
            ▼             ▼              ▼              ▼             ▼
       [Machine 1]   [Machine 2]    [Machine 3]      ...        [Machine N]

       ~/.cync/                       installer clone, auto-pulled by wrapper
       ~/<config-repo>/               private config clone, auto-pulled too
       ~/.claude/{settings.json,...}    → symlinks into ~/<config-repo>/
       ~/.zshrc | ~/.bashrc           BEGIN cync block sources the wrapper
```

Every time you run `claude`, the shell wrapper kicks in first:

```
$ claude
   │
   ▼   throttle: skip if last sync < 60s ago
   │
   ▼   git pull ~/.cync                 (latest installer)
   │   git pull ~/<config-repo>         (latest config from other machines)
   │   refresh enabled plugins          (HEAD check + cache invalidation)
   │
   ▼   command claude "$@"              (real Claude Code CLI takes over)
```

So when you tweak `settings.json` or add a slash command on one machine and push, the next `claude` on any other machine picks it up automatically — no manual sync, no per-machine drift.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gourderased/cync/main/install | bash
```

**Behind a corporate firewall that blocks `raw.githubusercontent.com`?** Use the git fallback — it goes through `github.com`, which is rarely blocked:

```bash
git clone https://github.com/gourderased/cync.git ~/.cync
bash ~/.cync/lib/setup.sh
```

The installer:

1. Clones itself into `~/.cync/`.
2. Checks every prerequisite at once and prints copy-paste install commands per distro for anything missing (`git`, `node`, `claude`, `gh`).
3. Runs `gh auth login` if you aren't authenticated yet — device-code flow that works on headless servers too.
4. Walks you through the interactive steps below.
5. Symlinks `~/.claude/{settings.json, CLAUDE.md, commands, agents, skills}` into your config repo.
6. Appends a managed block to `~/.zshrc` or `~/.bashrc` that sources the `claude` wrapper.

Reload your shell, then run `claude`.

## Setup flow

Each prompt sits inside its own visual section so it's hard to miss. Most steps default to the safe / common choice; pressing Enter is usually the right move.

### 1 — Pick your config repo

A numbered list of every repo on your GitHub account, plus a "Create new private repo" option and a quit option. Pick a number, or `Q` to bail without changes.

### 2 — Name your new repo *(create-new path only)*

Mandatory input with format validation. If a repo with that name already exists on your account, you're told inline and re-prompted — no failure deep into the flow.

### 3 — Seed the new repo *(create-new path, only when `~/.claude/` already has real files)*

cync notices you already have local Claude Code settings and asks how to populate the new repo:

- **`u` Use my existing settings (default)** — pushes your current `settings.json`, `CLAUDE.md`, etc. into the new repo. Missing entries fall back to the bundled template.
- **`t` Use the cync template only** — empty starter (model=opus, no permissions, no plugins). Your existing files move to `~/.claude/backups/`.

### 4 — Public-repo confirmation *(only when you select a public repo)*

If you select a public repo as your config, cync warns loudly and requires `y` to continue. Saves you from accidentally publishing API tokens or private prompts.

### 5 — Where to clone

Default is `~/<repo-name>`. The prompt loops on bad input — non-existent parent dir, existing directory that isn't a git repo, existing git repo with wrong origin — until you give a path it can actually use. `~/foo` is expanded to `$HOME/foo` automatically.

If you point at an existing clone whose history has diverged from origin (typical aftermath of a previous run that was cancelled and the GitHub repo recreated), cync detects it and offers `r` to reset, `p` to pick another path, or `a` to abort.

### 6 — Overwrite confirmation *(only when `~/.claude/` overlaps with the repo)*

If real files or foreign symlinks in `~/.claude/` overlap with the config repo, cync lists them and asks `[y/N]` before backing them up and replacing with symlinks. Defaults to no.

### 7 — Git identity *(only when `~/.gitconfig` is missing user.name or user.email)*

cync offers to fill these from your GitHub profile. Without them, your first manual commit (adding a slash command, editing CLAUDE.md) would fail with "Author identity unknown".

## Adding another machine

Run the same install command. In the menu, pick your existing config repo instead of "Create new". cync clones it, recreates the same symlinks, and registers the wrapper — everything you already set up is active immediately.

Corporate Linux server? Use the `git clone` fallback in **Install** above. Everything after the bootstrap is identical.

## Daily use

Just run `claude`. Before invoking the real binary, the wrapper:

1. `git pull --ff-only` on `~/.cync` (keeps the installer up-to-date).
2. `git pull --ff-only` on your config repo (picks up changes from other machines).
3. Checks `HEAD` of every plugin listed in `settings.json → enabledPlugins`. If a plugin's upstream has moved, its cached copy in `~/.claude/plugins/cache/` is wiped so Claude Code re-installs it on next launch.

If any network call fails (offline, slow, blocked), the wrapper prints a one-line yellow warning and continues — `claude` itself still launches.

### Sync throttle

To avoid hitting the network on every `claude` invocation, the wrapper throttles itself. If a sync ran less than 60 seconds ago, the next `claude` skips the network and goes straight to the binary.

```bash
# Skip the throttle once
rm ~/.claude/cync-last-sync && claude

# Always sync, no throttle
CYNC_SYNC_INTERVAL=0 claude

# Custom interval (seconds; default 60)
CYNC_SYNC_INTERVAL=300 claude        # at most every 5 minutes
```

Add `export CYNC_SYNC_INTERVAL=...` to your rc file (outside the `# BEGIN cync` block) to make it sticky.

## Layout

```
~/.cync/                                   # this repo, cloned (installer)
├── install                                # curl|bash entry point
├── uninstall                              # uninstall entry point
├── lib/
│   ├── setup.sh                           # interactive init/join flow
│   ├── install.sh                         # symlinks + rc block
│   ├── uninstall.sh                       # interactive teardown
│   └── claude-wrapper.sh                  # claude shell function
├── template/                              # seed for new config repos
└── tmp/                                   # ephemeral build dirs

~/<your-config-repo>/                      # your private repo, cloned (data)
├── settings.json
├── CLAUDE.md
├── commands/
├── agents/
└── skills/

~/.claude/                                 # what Claude Code reads
├── settings.json   -> ../<your-config-repo>/settings.json
├── CLAUDE.md       -> ../<your-config-repo>/CLAUDE.md
├── commands        -> ../<your-config-repo>/commands
├── agents          -> ../<your-config-repo>/agents
├── skills          -> ../<your-config-repo>/skills
├── cync-last-sync                         # throttle marker
└── plugin-sync-state/                     # per-plugin HEAD tracking
```

## Uninstalling

```bash
bash ~/.cync/uninstall
```

Two prompts:

1. **How should `~/.claude/` end up?**
   - **`m` Materialize (default)** — copy current settings as real files. `claude` keeps using the same configuration; it just stops auto-syncing from GitHub.
   - **`p` Purge** — remove the symlinks. `~/.claude/` becomes empty; `claude` starts from defaults next launch.
2. **Remove the local config repo clone?** Default is no.

Then it:

- Strips the `# BEGIN cync` block from `~/.zshrc` and `~/.bashrc`.
- Materializes or removes the symlinks (per your choice).
- Removes `~/.claude/plugin-sync-state/` and `~/.claude/cync-last-sync`.
- Removes `~/.cync/`.
- Optionally removes the local clone of your config repo.

**Your GitHub config repo is never touched.** Other machines connected to it keep working. Re-install any time with the same `curl | bash` line.

## Requirements

| Tool | Why it's needed | If missing |
|------|----------------|-----------|
| `git` | Clone / pull cync and your config repo. | Per-distro install hint. |
| `node` | Claude Code itself runs on Node.js. | Per-distro install hint. |
| `claude` | The binary cync wraps. | Direct install command. |
| `gh` | GitHub OAuth + repo CRUD. | Per-distro install hint with full repo-setup pipelines for apt/dnf. |
| `jq` *(optional)* | Plugin sync needs to read `enabledPlugins`. | Warning only — everything else still works. |

If you already use Claude Code, you almost certainly have `git`, `node`, and `claude`. The only new dependency is `gh`.

The installer collects all missing tools and reports them in one shot, so a fresh corporate server only needs one round of installs before re-running.

## Troubleshooting

**`Could not resolve host: raw.githubusercontent.com`** — your network blocks GitHub's CDN. Use the `git clone https://github.com/gourderased/cync.git ~/.cync` fallback shown in **Install**. `github.com` itself is rarely blocked.

**`claude` runs the real binary but no auto-pull happens.** The wrapper isn't loaded. Check `grep "BEGIN cync" ~/.zshrc` and reload the shell. `type claude` should print "claude is a shell function".

**`claude` startup feels slow.** Probably the wrapper hitting the network. Bump the throttle interval:
```bash
echo 'export CYNC_SYNC_INTERVAL=600' >> ~/.zshrc   # only sync every 10 min
```

**`fatal: Not possible to fast-forward` during clone path step.** Your local clone has commits not on origin (typically because the GitHub repo was recreated since you cloned it). The setup loop detects this and offers `r` to reset — pick that.

**Setup got cancelled mid-flow and now there's an empty repo on GitHub.** cync prints the URL on cancel. Either `gh repo delete <user>/<repo> --yes` to clean it up (needs the `delete_repo` scope — `gh auth refresh -h github.com -s delete_repo`), or just re-run setup and pick that repo from the menu.

**`Author identity unknown` when committing manually.** You skipped (or didn't see) the git-identity prompt at the end of setup. Set it now:
```bash
git config --global user.name  "your-name"
git config --global user.email "your-email"
```

**Plugin cache not refreshing.** Install `jq`. Without it, the plugin-sync step is silently skipped (other behavior unaffected).

**Wrong shell rc file.** The installer writes to `.zshrc` or `.bashrc` based on `$SHELL`. Other shells (fish, etc.) aren't auto-supported — switch `$SHELL` or source `~/.cync/lib/claude-wrapper.sh` from your shell's rc file manually.

## License

MIT
