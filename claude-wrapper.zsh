# claude-wrapper.zsh — Named session wrapper for Claude Code CLI
# Source: https://github.com/.../claude-utils
#
# Usage: claude --name my-session
#        claude --name my-session --description "this project is about apples"
#        claude --name yoyo --description "different greeting" tell me a yoyo story
#        claude --name apples -p "do something" --model sonnet
#        claude --name apples --session-id <your-uuid>
#        claude --name apples-v2 --fork-session --resume apples
#        claude --name feature-x --worktree feature-branch
#        claude --name feature-x --worktree feature-branch --tmux
#        claude --sessions                 (list named sessions)
#        claude --sessions --delete apples (delete a named session)
# Later: claude --resume my-session  (native claude feature)
# Note: --description requires --name. Without --name, everything passes through unchanged.
#
# Installation:
#   Add to ~/.zsh_autoload_functions/claude:
#     claude() { source /path/to/claude-utils/claude-wrapper.zsh; _claude_wrapper "$@" }
#   Or source directly in .zshrc:
#     source /path/to/claude-utils/claude-wrapper.zsh && alias claude='_claude_wrapper'

_claude_wrapper() {

  # Suppress job control notifications for background spinners
  setopt LOCAL_OPTIONS NO_MONITOR

  # Debug log file — set CLAUDE_WRAPPER_DEBUG=1 to enable
  local debug_log=""
  if [[ -n "$CLAUDE_WRAPPER_DEBUG" ]]; then
    debug_log="._claude/debug.log"
    mkdir -p "._claude"
    echo "=== claude wrapper debug $(date) ===" >> "$debug_log"
  fi

  __claude_debug() {
    [[ -n "$debug_log" ]] && echo "[$(date +%H:%M:%S)] $*" >> "$debug_log"
  }

  # --- Internal helpers ---

  __claude_spinner_pid=""

  __claude_spin() {
    local msg="$1"
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    printf "\033[0;36m%s\033[0m %s" "${spin_chars:0:1}" "$msg"
    (
      local i=0
      while true; do
        local c="${spin_chars:$((i % ${#spin_chars})):1}"
        printf "\r\033[0;36m%s\033[0m %s" "$c" "$msg"
        sleep 0.1
        ((i++))
      done
    ) &!
    __claude_spinner_pid=$!
  }

  __claude_spin_ok() {
    local msg="$1"
    if [[ -n "$__claude_spinner_pid" ]]; then
      kill "$__claude_spinner_pid" 2>/dev/null
      wait "$__claude_spinner_pid" 2>/dev/null
      __claude_spinner_pid=""
    fi
    printf "\r\033[K\033[0;32m✓\033[0m %s\n" "$msg"
  }

  __claude_spin_fail() {
    local msg="$1"
    if [[ -n "$__claude_spinner_pid" ]]; then
      kill "$__claude_spinner_pid" 2>/dev/null
      wait "$__claude_spinner_pid" 2>/dev/null
      __claude_spinner_pid=""
    fi
    printf "\r\033[K\033[0;31m✗\033[0m %s\n" "$msg"
  }

  # Run claude in a pseudo-TTY (required for slash commands like /rename, /clear)
  # Without a TTY, claude enters non-interactive mode and slash commands fail with
  # "Unknown skill". Uses python3 pty module to create a proper pseudo-terminal.
  # Args: timeout_secs claude_arg1 claude_arg2 ...
  __claude_pty_cmd() {
    local timeout="$1"
    shift
    local cmd_args=("$@")
    __claude_debug "pty_cmd: timeout=$timeout cmd=claude ${cmd_args[*]}"
    python3 - "$timeout" "${cmd_args[@]}" << 'PYEOF'
import pty, os, sys, signal, time, select

timeout = float(sys.argv[1])
cmd = ["claude"] + sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    # Child: exec claude
    os.execvp("claude", cmd)
    sys.exit(1)
else:
    # Parent: drain PTY output, then kill after timeout
    output_chunks = []
    end_time = time.time() + timeout
    while time.time() < end_time:
        remaining = end_time - time.time()
        if remaining <= 0:
            break
        r, _, _ = select.select([fd], [], [], min(remaining, 0.5))
        if r:
            try:
                data = os.read(fd, 4096)
                if not data:
                    break
                output_chunks.append(data)
            except OSError:
                break
    # Send SIGINT to gracefully stop claude
    try:
        os.kill(pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    # Brief drain after SIGINT
    drain_end = time.time() + 2
    while time.time() < drain_end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                data = os.read(fd, 4096)
                if not data:
                    break
                output_chunks.append(data)
            except OSError:
                break
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    # Write captured output to stdout for caller to inspect
    full_output = b"".join(output_chunks)
    sys.stdout.buffer.write(full_output)
PYEOF
  }

  # Run rename via PTY and verify it succeeded
  # $1=sid, $2=name, rest=extra flags
  __claude_rename() {
    local sid="$1" name="$2"
    shift 2
    __claude_debug "rename: resume $sid, name=$name, flags=$*"
    local output
    output=$(__claude_pty_cmd 8 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"

    # Check for failure indicators in the captured PTY output
    local clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)
    if echo "$clean" | grep -qi "Unknown skill"; then
      __claude_debug "rename: FAILED — 'Unknown skill' found in output"
      return 1
    fi
    if echo "$clean" | grep -qi "renamed\|Renamed"; then
      __claude_debug "rename: SUCCESS — rename confirmation found"
      return 0
    fi
    # Also check the transcript file for the rename event
    local encoded_path=$(echo "$(pwd)" | tr '/' '-')
    local transcript="$HOME/.claude/projects/${encoded_path}/${sid}.jsonl"
    if [[ -f "$transcript" ]]; then
      # Look at the last 10 lines for the rename command result
      local tail_content=$(tail -10 "$transcript" 2>/dev/null)
      if echo "$tail_content" | grep -q "Unknown skill.*rename"; then
        __claude_debug "rename: FAILED — 'Unknown skill' found in transcript"
        return 1
      fi
      if echo "$tail_content" | grep -q "command-name./rename"; then
        __claude_debug "rename: SUCCESS — /rename recognized as command in transcript"
        return 0
      fi
    fi
    # If we can't determine either way, assume success (PTY should make it work)
    __claude_debug "rename: ASSUMED SUCCESS — no failure indicators found"
    return 0
  }

  # In-directory variant of rename for worktree
  __claude_rename_in() {
    local dir="$1" sid="$2" name="$3"
    shift 3
    __claude_debug "rename_in ($dir): resume $sid, name=$name, flags=$*"
    local output
    output=$(cd "$dir" && __claude_pty_cmd 8 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename_in output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"

    local clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)
    if echo "$clean" | grep -qi "Unknown skill"; then
      __claude_debug "rename_in: FAILED"
      return 1
    fi
    __claude_debug "rename_in: ASSUMED SUCCESS"
    return 0
  }

  __claude_save_mapping() {
    local name="$1" sid="$2" description="$3" extra_note="$4"
    local cwd=$(pwd)
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    mkdir -p "._claude/projects"
    local mapping_file="._claude/session_mapping.json"
    [[ ! -f "$mapping_file" ]] && echo '[]' > "$mapping_file"

    local encoded_path=$(echo "$cwd" | tr '/' '-')
    local transcript="$HOME/.claude/projects/${encoded_path}/${sid}.jsonl"

    local claude_dir="$HOME/.claude"

    python3 -c "
import json, sys, os
sid = sys.argv[2]
claude_dir = sys.argv[9]
entry = {
    'name': sys.argv[1],
    'session_id': sid,
    'description': sys.argv[3] if sys.argv[3] else None,
    'directory': sys.argv[4],
    'created_at': sys.argv[5],
    'paths': {
        'transcript': sys.argv[7],
        'debug': os.path.join(claude_dir, 'debug', sid + '.txt'),
        'todos': os.path.join(claude_dir, 'todos', sid + '-agent-' + sid + '.json'),
        'file_history': os.path.join(claude_dir, 'file-history', sid),
        'session_env': os.path.join(claude_dir, 'session-env', sid),
        'tasks': os.path.join(claude_dir, 'tasks', sid),
    }
}
note = sys.argv[8] if len(sys.argv) > 10 and sys.argv[8] else None
if note:
    entry['note'] = note
with open(sys.argv[6], 'r') as f:
    data = json.load(f)
data.append(entry)
with open(sys.argv[6], 'w') as f:
    json.dump(data, f, indent=2)
" "$name" "$sid" "$description" "$cwd" "$timestamp" "$mapping_file" "$transcript" "$extra_note" "$claude_dir"

    ln -sf "$transcript" "._claude/projects/${name}.jsonl"
  }

  # --- Arg parsing ---
  # We separate args into:
  #   claude_flags: flags that ALL claude invocations need (--dangerously-skip-permissions, --model, etc.)
  #   user_prompt: positional args that are the user's actual prompt (only for final step)

  local name=""
  local description=""
  local user_has_print=false
  local user_has_fork=false
  local user_has_worktree=false
  local worktree_name=""
  local user_has_tmux=false
  local tmux_value=""
  local user_has_resume=false
  local resume_value=""
  local user_session_id=""
  local user_has_no_persist=false
  local user_has_from_pr=false
  local user_has_sessions=false
  local sessions_delete=""
  local user_has_help=false
  local claude_flags=()
  local user_prompt=()

  # Known flags that take a value argument
  local -A flags_with_value=(
    [--add-dir]=1 [--agent]=1 [--agents]=1 [--allowedTools]=1 [--allowed-tools]=1
    [--append-system-prompt]=1 [--betas]=1 [--debug-file]=1
    [--disallowedTools]=1 [--disallowed-tools]=1 [--effort]=1 [--fallback-model]=1
    [--file]=1 [--input-format]=1 [--json-schema]=1 [--max-budget-usd]=1
    [--mcp-config]=1 [--model]=1 [--output-format]=1 [--permission-mode]=1
    [--plugin-dir]=1 [--setting-sources]=1 [--settings]=1 [--system-prompt]=1
    [--tools]=1
  )

  # Known boolean flags (no value)
  local -A flags_boolean=(
    [--allow-dangerously-skip-permissions]=1 [--chrome]=1 [--no-chrome]=1
    [--dangerously-skip-permissions]=1 [--disable-slash-commands]=1
    [--ide]=1 [--include-partial-messages]=1 [--mcp-debug]=1
    [--replay-user-messages]=1 [--strict-mcp-config]=1 [--verbose]=1
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="$2"
        shift 2
        ;;
      --description)
        description="$2"
        shift 2
        ;;
      --sessions)
        user_has_sessions=true
        shift
        ;;
      --delete)
        sessions_delete="$2"
        shift 2
        ;;
      -p|--print)
        user_has_print=true
        shift
        ;;
      --fork-session)
        user_has_fork=true
        shift
        ;;
      -w|--worktree)
        user_has_worktree=true
        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
          worktree_name="$2"
          shift 2
        else
          shift
        fi
        ;;
      --worktree=*)
        user_has_worktree=true
        worktree_name="${1#--worktree=}"
        shift
        ;;
      --tmux)
        user_has_tmux=true
        shift
        ;;
      --tmux=*)
        user_has_tmux=true
        tmux_value="${1#--tmux=}"
        shift
        ;;
      -r|--resume)
        user_has_resume=true
        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
          resume_value="$2"
          shift 2
        else
          shift
        fi
        ;;
      -c|--continue)
        user_has_resume=true
        resume_value="__continue__"
        shift
        ;;
      --session-id)
        user_session_id="$2"
        shift 2
        ;;
      --no-session-persistence)
        user_has_no_persist=true
        shift
        ;;
      --from-pr)
        user_has_from_pr=true
        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
          claude_flags+=("--from-pr" "$2")
          shift 2
        else
          claude_flags+=("--from-pr")
          shift
        fi
        ;;
      -h|--help)
        user_has_help=true
        claude_flags+=("$1")
        shift
        ;;
      -d|--debug)
        # debug has optional filter value
        claude_flags+=("$1")
        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
          claude_flags+=("$2")
          shift 2
        else
          shift
        fi
        ;;
      -v|--version)
        claude_flags+=("$1")
        shift
        ;;
      *)
        # Check if it's a known flag with value
        if [[ -n "${flags_with_value[$1]}" ]]; then
          claude_flags+=("$1" "$2")
          shift 2
        elif [[ -n "${flags_boolean[$1]}" ]]; then
          claude_flags+=("$1")
          shift
        else
          # Not a known flag — it's part of the user's prompt
          user_prompt+=("$1")
          shift
        fi
        ;;
    esac
  done

  # --- --sessions ---
  if [[ "$user_has_sessions" == true ]]; then
    local mapping_file="._claude/session_mapping.json"
    if [[ ! -f "$mapping_file" ]]; then
      echo "No named sessions found in this directory."
      return 0
    fi

    if [[ -n "$sessions_delete" ]]; then
      local delete_result
      delete_result=$(python3 -c "
import json, sys
name = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    data = json.load(f)
matches = [e for e in data if e['name'] == name]
if not matches:
    print(f'No session found with name \"{name}\"', file=sys.stderr)
    sys.exit(1)
# Print transcript path and session_id for cleanup
for m in matches:
    print(m.get('transcript', m.get('paths', {}).get('transcript', '')))
    print(m.get('session_id', ''))
data = [e for e in data if e['name'] != name]
with open(sys.argv[2], 'w') as f:
    json.dump(data, f, indent=2)
" "$sessions_delete" "$mapping_file" 2>&1)
      local delete_rc=$?
      if [[ $delete_rc -ne 0 ]]; then
        echo "$delete_result" >&2
        return $delete_rc
      fi
      # Parse transcript path and session_id from python output
      local del_transcript=$(echo "$delete_result" | sed -n '1p')
      local del_sid=$(echo "$delete_result" | sed -n '2p')

      if [[ -n "$del_sid" ]]; then
        local claude_dir="$HOME/.claude"

        # 1. Symlink in ._claude/projects/
        rm -f "._claude/projects/${sessions_delete}.jsonl"

        # 2. Transcript .jsonl
        [[ -n "$del_transcript" && -f "$del_transcript" ]] && rm -f "$del_transcript"

        # 3. Subagent directory (same path without .jsonl)
        local del_subagent_dir="${del_transcript%.jsonl}"
        [[ -n "$del_subagent_dir" && -d "$del_subagent_dir" ]] && rm -rf "$del_subagent_dir"

        # 4. Todos
        rm -f "$claude_dir"/todos/${del_sid}-agent-*.json

        # 5. Debug log
        rm -f "$claude_dir/debug/${del_sid}.txt"

        # 6. File history
        [[ -d "$claude_dir/file-history/${del_sid}" ]] && rm -rf "$claude_dir/file-history/${del_sid}"

        # 7. Session env
        [[ -d "$claude_dir/session-env/${del_sid}" ]] && rm -rf "$claude_dir/session-env/${del_sid}"

        # 8. Tasks
        [[ -d "$claude_dir/tasks/${del_sid}" ]] && rm -rf "$claude_dir/tasks/${del_sid}"

        # 9. Telemetry failed events
        rm -f "$claude_dir"/telemetry/1p_failed_events.${del_sid}.*.json

        # 10. Remove entries from history.jsonl (in-place, preserve other sessions)
        if [[ -f "$claude_dir/history.jsonl" ]]; then
          python3 -c "
import json, sys
sid = sys.argv[1]
path = sys.argv[2]
with open(path, 'r') as f:
    lines = f.readlines()
with open(path, 'w') as f:
    for line in lines:
        try:
            d = json.loads(line)
            if d.get('sessionId') == sid:
                continue
        except (json.JSONDecodeError, KeyError):
            pass
        f.write(line)
" "$del_sid" "$claude_dir/history.jsonl"
        fi
      fi

      echo "Deleted session \"$sessions_delete\" (all session data removed)"
      return 0
    fi

    python3 -c "
import json, sys, os
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
if not data:
    print('No named sessions found.')
    sys.exit(0)
print(f'Named sessions ({len(data)}):')
print()
for e in data:
    desc = e.get('description') or '-'
    note = e.get('note') or ''
    note_str = f' ({note})' if note else ''
    # Support both old flat 'transcript' and new 'paths' format
    paths = e.get('paths', {})
    transcript = paths.get('transcript', e.get('transcript', ''))
    exists = '\u2713' if os.path.exists(transcript) else '\u2717'
    print(f'  {e[\"name\"]}')
    print(f'    ID:          {e[\"session_id\"]}')
    print(f'    Description: {desc}')
    print(f'    Created:     {e[\"created_at\"]}')
    print(f'    Transcript:  {exists} {transcript}{note_str}')
    print()
print('Resume with: claude --resume <name>')
" "$mapping_file"
    return $?
  fi

  # --- --help ---
  if [[ "$user_has_help" == true && -z "$name" ]]; then
    (command claude "${claude_flags[@]}")
    echo ""
    echo "Wrapper options (provided by claude shell function):"
    echo "  --name <name>                  Create a named session (auto seeds, renames, clears)"
    echo "  --description <text>           Initial context for the session (requires --name)"
    echo "  --sessions                     List all named sessions in the current directory"
    echo "  --sessions --delete <name>     Delete a named session from the mapping"
    echo ""
    echo "Examples:"
    echo "  claude --name my-feature --description \"working on auth\" implement login"
    echo "  claude --name my-feature -p \"list files\" --model sonnet"
    echo "  claude --name fork-v2 --fork-session --resume my-feature"
    echo "  claude --resume my-feature"
    echo "  claude --sessions"
    return $?
  fi

  # --- No --name: plain passthrough ---
  if [[ -z "$name" ]]; then
    if [[ -n "$description" ]]; then
      echo "Error: --description requires --name" >&2
      return 1
    fi
    local passthrough=()
    [[ "$user_has_print" == true ]] && passthrough+=("-p")
    [[ "$user_has_fork" == true ]] && passthrough+=("--fork-session")
    [[ "$user_has_no_persist" == true ]] && passthrough+=("--no-session-persistence")
    [[ -n "$user_session_id" ]] && passthrough+=("--session-id" "$user_session_id")
    if [[ "$user_has_resume" == true ]]; then
      if [[ "$resume_value" == "__continue__" ]]; then
        passthrough+=("--continue")
      elif [[ -n "$resume_value" ]]; then
        passthrough+=("--resume" "$resume_value")
      else
        passthrough+=("--resume")
      fi
    fi
    if [[ "$user_has_worktree" == true ]]; then
      if [[ -n "$worktree_name" ]]; then
        passthrough+=("--worktree" "$worktree_name")
      else
        passthrough+=("--worktree")
      fi
    fi
    if [[ "$user_has_tmux" == true ]]; then
      if [[ -n "$tmux_value" ]]; then
        passthrough+=("--tmux=$tmux_value")
      else
        passthrough+=("--tmux")
      fi
    fi
    command claude "${passthrough[@]}" "${claude_flags[@]}" "${user_prompt[@]}"
    return $?
  fi

  # --- --name is set: validate ---

  if [[ "$user_has_no_persist" == true ]]; then
    echo "Error: --no-session-persistence cannot be used with --name." >&2
    echo "--name creates a persistent named session, but --no-session-persistence" >&2
    echo "prevents sessions from being saved to disk. These are contradictory." >&2
    return 1
  fi

  if [[ "$user_has_from_pr" == true ]]; then
    echo "Error: --from-pr cannot be used with --name." >&2
    echo "Instead, resume the PR session first, then fork it with a name:" >&2
    echo "  claude --resume <pr-session> --fork-session --name <new-name>" >&2
    return 1
  fi

  # Duplicate check
  local mapping_file="._claude/session_mapping.json"
  if [[ -f "$mapping_file" ]]; then
    local dupe_check=$(python3 -c "
import json, sys
with open(sys.argv[2], 'r') as f:
    data = json.load(f)
if any(e['name'] == sys.argv[1] for e in data):
    print('duplicate')
" "$name" "$mapping_file" 2>/dev/null)
    if [[ "$dupe_check" == "duplicate" ]]; then
      echo "Error: a session named '$name' already exists." >&2
      echo "Use 'claude --sessions' to list or 'claude --sessions --delete $name' to remove it." >&2
      return 1
    fi
  fi

  local sid="${user_session_id:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"

  echo ""
  printf "\033[1mCreating named session: %s\033[0m\n" "$name"
  echo ""

  # === FORK PATH ===
  if [[ "$user_has_fork" == true ]]; then
    if [[ "$user_has_resume" != true || -z "$resume_value" || "$resume_value" == "__continue__" ]]; then
      echo "Error: --fork-session with --name requires --resume <session-name-or-id>" >&2
      return 1
    fi

    __claude_spin "Forking session from '$resume_value'..."
    command claude -p --resume "$resume_value" --fork-session --session-id "$sid" "${claude_flags[@]}" "hi" > /dev/null 2>&1
    __claude_spin_ok "Forked session from '$resume_value'"

    __claude_spin "Naming session '$name'..."
    if __claude_rename "$sid" "$name" "${claude_flags[@]}"; then
      __claude_spin_ok "Session named '$name'"
    else
      __claude_spin_fail "Failed to rename session to '$name'"
      echo "Error: rename failed. Resume manually: claude --resume $sid" >&2
      return 1
    fi

    __claude_save_mapping "$name" "$sid" "$description" "forked from $resume_value"
    echo ""

    if [[ "$user_has_print" == true ]]; then
      command claude -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
    else
      command claude --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
    fi
    return $?
  fi

  # === WORKTREE PATH ===
  if [[ "$user_has_worktree" == true ]]; then
    local wt_dir
    if [[ -n "$worktree_name" ]]; then
      wt_dir="../${worktree_name}"
    else
      wt_dir="../worktree-$(date +%s)"
    fi
    local branch_name="${worktree_name:-worktree-$(date +%s)}"

    __claude_spin "Creating git worktree '$branch_name'..."
    git worktree add "$wt_dir" -b "$branch_name" 2>/dev/null || \
    git worktree add "$wt_dir" "$branch_name" 2>/dev/null || {
      __claude_spin_fail "Failed to create git worktree"
      return 1
    }
    local abs_wt_dir=$(cd "$wt_dir" && pwd)
    __claude_spin_ok "Worktree at $abs_wt_dir (branch: $branch_name)"

    local seed_message="${description:-hi}"

    __claude_spin "Seeding session..."
    (cd "$abs_wt_dir" && command claude -p --session-id "$sid" "${claude_flags[@]}" "$seed_message") > /dev/null 2>&1
    __claude_spin_ok "Session seeded"

    __claude_spin "Naming session '$name'..."
    if __claude_rename_in "$abs_wt_dir" "$sid" "$name" "${claude_flags[@]}"; then
      __claude_spin_ok "Session named '$name'"
    else
      __claude_spin_fail "Failed to rename session to '$name'"
      echo "Error: rename failed. Resume manually: claude --resume $sid" >&2
      return 1
    fi

    # Save mapping in worktree dir
    mkdir -p "$abs_wt_dir/._claude/projects"
    local wt_mapping="$abs_wt_dir/._claude/session_mapping.json"
    [[ ! -f "$wt_mapping" ]] && echo '[]' > "$wt_mapping"
    local wt_encoded=$(echo "$abs_wt_dir" | tr '/' '-')
    local wt_transcript="$HOME/.claude/projects/${wt_encoded}/${sid}.jsonl"

    local wt_claude_dir="$HOME/.claude"

    python3 -c "
import json, sys, os
sid = sys.argv[2]
claude_dir = sys.argv[8]
entry = {
    'name': sys.argv[1],
    'session_id': sid,
    'description': sys.argv[3] if sys.argv[3] else None,
    'directory': sys.argv[4],
    'created_at': sys.argv[5],
    'paths': {
        'transcript': sys.argv[7],
        'debug': os.path.join(claude_dir, 'debug', sid + '.txt'),
        'todos': os.path.join(claude_dir, 'todos', sid + '-agent-' + sid + '.json'),
        'file_history': os.path.join(claude_dir, 'file-history', sid),
        'session_env': os.path.join(claude_dir, 'session-env', sid),
        'tasks': os.path.join(claude_dir, 'tasks', sid),
    }
}
with open(sys.argv[6], 'r') as f:
    data = json.load(f)
data.append(entry)
with open(sys.argv[6], 'w') as f:
    json.dump(data, f, indent=2)
" "$name" "$sid" "$description" "$abs_wt_dir" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$wt_mapping" "$wt_transcript" "$wt_claude_dir"
    ln -sf "$wt_transcript" "$abs_wt_dir/._claude/projects/${name}.jsonl"

    echo ""

    if [[ "$user_has_tmux" == true ]]; then
      local tmux_session="claude-${name}"
      if [[ -n "$tmux_value" && "$tmux_value" == "classic" ]]; then
        tmux new-session -d -s "$tmux_session" -c "$abs_wt_dir"
        tmux send-keys -t "$tmux_session" "command claude --resume \"$sid\" ${(q)claude_flags[*]} ${(q)user_prompt[*]}" Enter
        tmux attach -t "$tmux_session"
      else
        (cd "$abs_wt_dir" && command claude --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
      fi
    elif [[ "$user_has_print" == true ]]; then
      (cd "$abs_wt_dir" && command claude -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
    else
      (cd "$abs_wt_dir" && command claude --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
    fi
    return $?
  fi

  # === STANDARD PATH ===
  local seed_message="${description:-hi}"

  __claude_spin "Seeding session..."
  command claude -p --session-id "$sid" "${claude_flags[@]}" "$seed_message" > /dev/null 2>&1
  __claude_spin_ok "Session seeded"

  __claude_spin "Naming session '$name'..."
  if __claude_rename "$sid" "$name" "${claude_flags[@]}"; then
    __claude_spin_ok "Session named '$name'"
  else
    __claude_spin_fail "Failed to rename session to '$name'"
    echo "Error: rename failed. Resume manually: claude --resume $sid" >&2
    return 1
  fi

  __claude_save_mapping "$name" "$sid" "$description"
  echo ""

  if [[ "$user_has_print" == true ]]; then
    command claude -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
  else
    command claude --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
  fi
}
