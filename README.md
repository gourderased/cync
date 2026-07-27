# cync

[한국어 README](./README.ko.md)

One-line installer that keeps your [Claude Code](https://docs.anthropic.com/claude-code) and [Codex CLI](https://developers.openai.com/codex) configuration in sync across every machine you use.

**Tool** and **data** are deliberately kept separate:

- **Tool (public, shared)** — this repo, `gourderased/cync`. Holds the installer and the `claude` shell wrapper. Everyone installs from the same place.
- **Data (private, yours)** — your `settings.json`, `instructions/`, `commands/`, `agents/`, `skills/` live in a private repo on *your* GitHub account. cync just wires it up via symlinks and a shell wrapper.

## What is shared between the two tools

Claude Code and Codex use different config formats. cync shares only what a single file can serve to both; the rest stays per-tool.

| Item | Shared | How |
|---|---|---|
| `skills/` | yes | both tools read the same `SKILL.md` format -> symlink |
| `instructions/common.md` | yes | rendered into `CLAUDE.md` and `AGENTS.md` |
| `agents/`, `commands/`, `settings.json` | no | formats differ, managed per tool |

Instructions are *generated* rather than symlinked because Codex's `AGENTS.md` has no import directive — the shared part has to be concatenated into a real file.

```
instructions/common.md + instructions/claude.md  ->  ~/.claude/CLAUDE.md
instructions/common.md + instructions/codex.md   ->  ~/.codex/AGENTS.md
```

Don't edit the generated files; they're overwritten on the next launch. Edit `instructions/` instead.

`~/.codex/skills` holds Codex's own `.system/` skills, so cync links each shared skill individually rather than replacing the directory.

## How it works

```
                    ┌──────────────────────────────────────────┐
                    │  GitHub                                  │
                    │                                          │
                    │  gourderased/cync         (PUBLIC)       │  ← installer
                    │  ├ install / uninstall                   │
                    │  ├ lib/{setup, install, uninstall,       │
                    │  │      claude-wrapper, sync-targets}.sh │
                    │  └ template/                             │
                    │                                          │
                    │  <user>/<config-repo>     (PRIVATE)      │  ← your settings
                    │  ├ settings.json                         │
                    │  ├ instructions/{common,claude,codex}.md │
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
   │   check enabled plugins            (HEAD check, notify on update)
   │
   ▼   command claude "$@"              (real Claude Code CLI takes over)
```

So when you tweak `settings.json` or add a slash command on one machine and push, the next `claude` on any other machine picks it up automatically — no manual sync, no per-machine drift.

## Handoffs

Notes that carry work between machines and between the two CLIs live in
`~/agent-state`. Session files can't do this job: the two tools use different
jsonl schemas, and Claude's sessions alone approach 100MB. A short markdown
note per project carries the part that matters.

- A machine without the store **clones it on first launch**. The remote is
  derived from the config repo's origin: same account, repo named after the
  destination directory.
- If it isn't reachable, cync tries once and leaves a marker so it isn't
  hitting the network on every launch. `cync-sync` retries.
- When the current directory has a note, launching prints one line about it.
- To opt out, put `export CYNC_STATE_REPO=""` in your rc file, outside the
  cync block.

Reading and writing the notes is the config repo's `handoff` skill.

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
5. Symlinks `~/.claude/{settings.json, commands, agents, skills}` into your config repo.
6. Renders `~/.claude/CLAUDE.md` from `instructions/`. If Codex is installed, also renders `~/.codex/AGENTS.md` and links the shared skills.
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

- **`u` Use my existing settings (default)** — pushes your current `settings.json`, `commands/`, etc. into the new repo. Missing entries fall back to the bundled template. (`CLAUDE.md` is excluded — it's generated, so the template's `instructions/` goes in instead.)
- **`t` Use the cync template only** — empty starter (model=opus, no permissions, no plugins). Your existing files move to `~/.claude/backups/`.

### 4 — Public-repo confirmation *(only when you select a public repo)*

If you select a public repo as your config, cync warns loudly and requires `y` to continue. Saves you from accidentally publishing API tokens or private prompts.

### 5 — Where to clone

Default is `~/<repo-name>`. The prompt loops on bad input — non-existent parent dir, existing directory that isn't a git repo, existing git repo with wrong origin — until you give a path it can actually use. `~/foo` is expanded to `$HOME/foo` automatically.

If you point at an existing clone whose history has diverged from origin (typical aftermath of a previous run that was cancelled and the GitHub repo recreated), cync detects it and offers `r` to reset, `p` to pick another path, or `a` to abort.

### 6 — Overwrite confirmation *(only when `~/.claude/` overlaps with the repo)*

If real files or foreign symlinks in `~/.claude/` overlap with the config repo, cync lists them and asks `[y/N]` before backing them up and replacing with symlinks. Defaults to no.

### 7 — Git identity *(only when `~/.gitconfig` is missing user.name or user.email)*

cync offers to fill these from your GitHub profile. Without them, your first manual commit (adding a slash command, editing `instructions/`) would fail with "Author identity unknown".

## Adding another machine

Run the same install command. In the menu, pick your existing config repo instead of "Create new". cync clones it, recreates the same symlinks, and registers the wrapper — everything you already set up is active immediately.

Corporate Linux server? Use the `git clone` fallback in **Install** above. Everything after the bootstrap is identical.

## Daily use

Just run `claude`. Before invoking the real binary, the wrapper:

1. `git pull --ff-only` on `~/.cync` (keeps the installer up-to-date).
2. `git pull --ff-only` on your config repo (picks up changes from other machines).
3. Checks `HEAD` of every plugin listed in `settings.json → enabledPlugins`. If a plugin's upstream has moved, cync prints a one-line notice suggesting `/plugin update` — it never touches the plugin cache or registry itself (that's Claude Code's job).

If any network call fails (offline, slow, blocked), the wrapper prints a one-line yellow warning and continues — `claude` itself still launches.

### Sync throttle

To avoid hitting the network on every `claude` invocation, the wrapper throttles itself. If a sync ran less than 60 seconds ago, the next `claude` skips the network and goes straight to the binary.

```bash
# Skip the throttle once (sync right now, without launching claude)
cync-sync

# Always sync, no throttle
CYNC_SYNC_INTERVAL=0 claude

# Custom interval (seconds; default 60)
CYNC_SYNC_INTERVAL=300 claude        # at most every 5 minutes
```

Add `export CYNC_SYNC_INTERVAL=...` to your rc file (outside the `# BEGIN cync` block) to make it sticky.

### Pushing changes back

When you add a slash command, edit `instructions/`, or drop a new subagent into your config repo, those edits land in the repo. To propagate them to other machines, you have to push. cync ships two helpers to skip the manual `cd ... && git add && git commit && git push` dance:

```bash
cync-status                        # uncommitted work, ahead/behind remote, recent commits
cync-push                          # auto-message: "cync-push from <host> at <time>"
cync-push "add /foo command"       # custom message
cync-sync                          # pull everything right now (skips the throttle)
cync-doctor                        # read-only health check of the whole wiring
```

`cync-push` exits cleanly with `nothing to push` when the working tree is clean, and surfaces a clear hint if the push failed (network down, diverged branch, etc.) — including picking up a commit that was left unpushed by an earlier offline failure. Run it whenever you want your changes to land on GitHub — that's the only step.

And if you forget: the wrapper prints a one-line reminder on `claude` launch whenever the config repo has uncommitted or unpushed work, and tells you which files just arrived when an auto-pull brings in changes from another machine.

## Layout

```
~/.cync/                                   # this repo, cloned (installer)
├── install                                # curl|bash entry point
├── uninstall                              # uninstall entry point
├── lib/
│   ├── setup.sh                           # interactive init/join flow
│   ├── install.sh                         # symlinks + rc block
│   ├── uninstall.sh                       # interactive teardown
│   ├── claude-wrapper.sh                  # claude / codex shell functions
│   └── sync-targets.sh                    # instruction rendering + Codex skill links
├── template/                              # seed for new config repos
└── tmp/                                   # ephemeral build dirs

~/<your-config-repo>/                      # your private repo, cloned (data)
├── settings.json                          # Claude only
├── instructions/
│   ├── common.md                          # both tools
│   ├── claude.md                          # Claude only
│   └── codex.md                           # Codex only
├── commands/                              # Claude only
├── agents/                                # Claude only
└── skills/                                # shared

~/.claude/                                 # what Claude Code reads
├── settings.json   -> ../<your-config-repo>/settings.json
├── CLAUDE.md                              # generated (common + claude)
├── commands        -> ../<your-config-repo>/commands
├── agents          -> ../<your-config-repo>/agents
├── skills          -> ../<your-config-repo>/skills
├── cync-last-sync                         # throttle marker (shared with codex)
└── plugin-sync-state/                     # per-plugin HEAD tracking

~/.codex/                                  # what Codex reads
├── AGENTS.md                              # generated (common + codex)
└── skills/
    ├── .system/                           # Codex's own skills (untouched)
    └── <skill>     -> ../<your-config-repo>/skills/<skill>
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

## License

MIT
