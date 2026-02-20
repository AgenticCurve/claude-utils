# claude-utils

A zsh wrapper for the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) that adds **named sessions** with automatic setup, cleanup, and lifecycle management.

## The Problem

Claude Code generates random session slugs like `quiet-cooking-codd`. There's no way to create a named session in a single command from the CLI — you have to start a session interactively, then manually type `/rename`.

## What This Solves

```bash
# Create a named session in one command
claude --name my-feature --description "working on auth"

# Resume it later (native claude feature)
claude --resume my-feature

# List all named sessions in this directory
claude --sessions

# Delete a session and all its data
claude --sessions --delete my-feature
```

## Features

- **`--name <name>`** — Create a named session. Automatically seeds, renames (via PTY), clears context, and truncates the transcript so the session starts clean.
- **`--description <text>`** — Provide initial context when creating a named session (requires `--name`). Saved in the session mapping for reference.
- **`--sessions`** — List all named sessions in the current directory with their IDs, descriptions, and transcript paths.
- **`--sessions --delete <name>`** — Full cleanup: removes the transcript, debug logs, todos, file history, session env, tasks, telemetry, and history entries from `~/.claude/`.
- **Works with all native claude flags** — `--dangerously-skip-permissions`, `--model`, `-p`, `--fork-session`, `--worktree`, `--tmux`, `--session-id`, etc. Flags are properly separated and passed to all intermediate steps.
- **Fork support** — `claude --name fork-v2 --fork-session --resume original-session`
- **Worktree support** — `claude --name feature-x --worktree feature-branch`
- **Tmux support** — `claude --name feature-x --worktree feature-branch --tmux`
- **Duplicate detection** — Prevents creating two sessions with the same name.
- **Spinners** — Visual feedback during the seed/rename/clear setup steps.
- **Debug logging** — Set `CLAUDE_WRAPPER_DEBUG=1` to log all intermediate steps to `._claude/debug.log`.
- **Session mapping** — All named sessions are tracked in `._claude/session_mapping.json` with links to every `~/.claude/` storage location (transcript, debug, todos, file-history, session-env, tasks).
- **Zero passthrough overhead** — When `--name` is not used, all arguments pass directly to `claude` with no wrapping.

## Setup

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and on your `$PATH`
- `python3` (used for PTY-based slash command execution and JSON manipulation)
- `zsh` shell

### Installation

1. Clone this repo:

```bash
git clone <repo-url> /path/to/claude-utils
```

2. Set up the zsh autoload function. Create the file `~/.zsh_autoload_functions/claude`:

```bash
mkdir -p ~/.zsh_autoload_functions

cat > ~/.zsh_autoload_functions/claude << 'EOF'
claude() {
  source /path/to/claude-utils/claude-wrapper.zsh
  _claude_wrapper "$@"
}
EOF
```

3. Make sure `~/.zsh_autoload_functions` is in your `fpath` and `claude` is autoloaded. Add to your `~/.zshrc`:

```bash
fpath=( ~/.zsh_autoload_functions "${fpath[@]}" )
autoload -Uz claude
```

4. Reload your shell:

```bash
exec zsh
```

### Verify

```bash
# Should show native claude help + wrapper options at the bottom
claude --help

# Should pass through to claude normally (no overhead)
claude
```

## Usage

### Create a named session

```bash
claude --name my-feature
claude --name my-feature --description "building the auth system"
claude --name my-feature --description "auth system" implement JWT login
claude --name quick-task -p "list all TODO comments" --model sonnet
```

### Create a named session with extra flags

```bash
claude --dangerously-skip-permissions --name my-feature --description "auth"
claude --name my-feature --model haiku -p "summarize this file"
```

### Resume a named session

```bash
# Native claude feature — works because /rename was applied during setup
claude --resume my-feature
```

### Fork a named session

```bash
claude --name fork-v2 --fork-session --resume my-feature
```

### Worktree + named session

```bash
claude --name feature-x --worktree feature-branch
claude --name feature-x --worktree feature-branch --tmux
```

### List sessions

```bash
claude --sessions
```

Output:
```
Named sessions (2):

  my-feature
    ID:          a1b2c3d4-...
    Description: building the auth system
    Created:     2026-02-20T09:30:00Z
    Transcript:  ✓ /Users/you/.claude/projects/-Users-you-myproject/a1b2c3d4-....jsonl

  quick-task
    ID:          e5f6g7h8-...
    Description: -
    Created:     2026-02-20T10:00:00Z
    Transcript:  ✓ /Users/you/.claude/projects/-Users-you-myproject/e5f6g7h8-....jsonl

Resume with: claude --resume <name>
```

### Delete a session (full cleanup)

```bash
claude --sessions --delete my-feature
```

This removes all traces from:
- `._claude/session_mapping.json` and `._claude/projects/<name>.jsonl`
- `~/.claude/projects/<path>/<sid>.jsonl` (transcript)
- `~/.claude/projects/<path>/<sid>/` (subagents)
- `~/.claude/debug/<sid>.txt`
- `~/.claude/todos/<sid>-agent-*.json`
- `~/.claude/file-history/<sid>/`
- `~/.claude/session-env/<sid>/`
- `~/.claude/tasks/<sid>/`
- `~/.claude/telemetry/1p_failed_events.<sid>.*.json`
- Entries from `~/.claude/history.jsonl`

### Debug mode

```bash
CLAUDE_WRAPPER_DEBUG=1 claude --name test --description "debugging"
# Check ._claude/debug.log for detailed step-by-step output
```

## How It Works

When you run `claude --name my-session --description "context"`:

1. **Seed** — `claude -p --session-id <uuid> "context"` creates the session with a known UUID
2. **Rename** — A Python PTY spawns `claude --resume <uuid> "/rename my-session"` in a pseudo-terminal (required because slash commands only work in interactive mode with a TTY)
3. **Clear** — Same PTY approach runs `/clear` to wipe the setup context
4. **Truncate** — The `.jsonl` transcript is truncated so the session starts completely clean
5. **Launch** — `claude --resume <uuid>` opens the session for real use

The PTY approach was necessary because Claude Code's slash commands (`/rename`, `/clear`) only work in interactive mode with a connected terminal. Without a TTY, they fail with "Unknown skill". Python's `pty.fork()` creates a proper pseudo-terminal that makes claude believe it's running interactively.

## Session Data

Named sessions are tracked per-directory in `._claude/session_mapping.json`. Each entry includes links to all `~/.claude/` storage locations for easy reference:

```json
{
  "name": "my-feature",
  "session_id": "a1b2c3d4-...",
  "description": "building the auth system",
  "directory": "/Users/you/myproject",
  "created_at": "2026-02-20T09:30:00Z",
  "paths": {
    "transcript": "/Users/you/.claude/projects/-Users-you-myproject/a1b2c3d4-....jsonl",
    "debug": "/Users/you/.claude/debug/a1b2c3d4-....txt",
    "todos": "/Users/you/.claude/todos/a1b2c3d4-...-agent-a1b2c3d4-....json",
    "file_history": "/Users/you/.claude/file-history/a1b2c3d4-...",
    "session_env": "/Users/you/.claude/session-env/a1b2c3d4-...",
    "tasks": "/Users/you/.claude/tasks/a1b2c3d4-..."
  }
}
```

## Incompatible Flag Combinations

| Combination | Behavior |
|---|---|
| `--name` + `--no-session-persistence` | Error (contradictory) |
| `--name` + `--from-pr` | Error (use fork instead) |
| `--name` + `--fork-session` without `--resume` | Error (need a source session) |
