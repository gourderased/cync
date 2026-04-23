# cync

One-line installer that keeps your [Claude Code](https://docs.anthropic.com/claude-code) configuration in sync across every machine you use.

**"Tool"** and **"data"** are kept separate on purpose:

- **Tool (public, shared):** this repo — `gourderased/cync` — holds the installer and the `claude` shell wrapper. Everyone installs from the same place.
- **Data (private, yours):** your settings (`settings.json`, `CLAUDE.md`, commands, agents, skills) live in a private repo in *your* GitHub account. cync just wires it up.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gourderased/cync/main/install | bash
```

The script will:

1. Clone itself into `~/.cync/`.
2. Make sure `git`, `node`, `claude`, and `gh` are on your `PATH`.
3. Run `gh auth login` if you aren't authenticated yet (browser OAuth).
4. Show a menu of your GitHub repos:
   - Pick an existing config repo, **or**
   - Create a new private `claude-config` repo, pre-populated from the bundled `template/`.
5. Clone (or pull) that repo to a path you choose (default `~/<repo-name>/`).
6. Symlink `~/.claude/{settings.json,CLAUDE.md,commands,agents,skills}` into the config repo.
7. Append a managed block to `~/.zshrc` or `~/.bashrc` that sources the `claude` wrapper.

Reload your shell afterward:

```bash
source ~/.zshrc     # macOS / zsh
source ~/.bashrc    # Linux / bash
```

## Daily use

Just run `claude`. The wrapper transparently does three things before handing off to the real CLI:

1. `git pull --ff-only` inside `~/.cync` (keeps this installer up-to-date).
2. `git pull --ff-only` inside your config repo (picks up settings you changed on another machine).
3. Checks the `HEAD` of every plugin listed in `settings.json → enabledPlugins`. If a plugin's upstream has moved, its cached copy in `~/.claude/plugins/cache/` is wiped so Claude Code reinstalls it on next launch.

All three steps fail silently — a network hiccup never blocks `claude` from starting.

## Layout

```
~/.cync/                         # this repo, cloned (installer)
├── install
├── lib/
│   ├── setup.sh
│   ├── install.sh
│   └── claude-wrapper.sh
└── template/                    # seed content for new config repos

~/<your-config-repo>/            # your private repo, cloned (data)
├── settings.json
├── CLAUDE.md
├── commands/
├── agents/
└── skills/

~/.claude/                       # what Claude Code reads
├── settings.json  -> ../<your-config-repo>/settings.json
├── CLAUDE.md      -> ../<your-config-repo>/CLAUDE.md
├── commands       -> ../<your-config-repo>/commands
├── agents         -> ../<your-config-repo>/agents
└── skills         -> ../<your-config-repo>/skills
```

## Adding another machine

Run the same `curl | bash` line. In the repo menu, pick your existing config repo instead of "Create new". cync clones it, re-creates the same symlinks, and you're done — everything you already set up is active immediately.

## Requirements

- `git`
- `node`
- `claude` (the [Claude Code](https://docs.anthropic.com/claude-code) CLI)
- `gh` ([GitHub CLI](https://cli.github.com/)) — install with `brew install gh` on macOS, or see the [Linux install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).
- `jq` (recommended; without it, plugin sync is skipped but everything else works)

## Troubleshooting

**`gh` is not installed.** The installer exits with an install hint. Install `gh`, then re-run the `curl | bash` line.

**`claude` runs the real binary but doesn't pull.** Check that the marker block was added to your rc file (`grep "BEGIN cync" ~/.zshrc`) and that you reloaded the shell. Run `type claude` — it should print "claude is a shell function".

**Existing files in `~/.claude/` before install.** They aren't overwritten; they're moved to `~/.claude/backups/pre-symlink-<timestamp>/` before the symlinks are created.

**Wrong shell rc file.** The installer picks `.zshrc` or `.bashrc` based on `$SHELL`. If you use a different shell, edit the marker block's `source` line to match, or symlink the rc file.

**Plugin cache not refreshing.** Make sure `jq` is installed. Without it, `_claude_refresh_plugins` is a no-op.

**Removing cync.** Delete the marker block from your rc file (everything between `# BEGIN cync` and `# END cync`), remove the symlinks in `~/.claude/`, and `rm -rf ~/.cync`. Your config repo is untouched.

## License

MIT
