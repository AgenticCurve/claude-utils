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

  # Hardcoded path to the real claude binary (avoids infinite loop when
  # this wrapper is installed as 'claude' on PATH)
  local CLAUDE_BIN="/opt/homebrew/bin/claude"

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
    python3 - "$timeout" "$CLAUDE_BIN" "${cmd_args[@]}" << 'PYEOF'
import pty, os, sys, signal, time, select

timeout = float(sys.argv[1])
claude_bin = sys.argv[2]
cmd = [claude_bin] + sys.argv[3:]

pid, fd = pty.fork()
if pid == 0:
    # Child: exec claude
    os.execvp(cmd[0], cmd)
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
  __claude_check_rename() {
    local output="$1" sid="$2"
    # Check PTY output for success/failure
    local clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)
    if echo "$clean" | grep -qi "Unknown skill"; then
      __claude_debug "rename: FAILED — 'Unknown skill' in output"
      return 1
    fi
    if echo "$clean" | grep -qi "renamed\|Renamed"; then
      __claude_debug "rename: SUCCESS — confirmed in output"
      return 0
    fi
    # Check the transcript file
    local encoded_path=$(echo "$(pwd)" | tr '/' '-')
    local transcript="$HOME/.claude/projects/${encoded_path}/${sid}.jsonl"
    if [[ -f "$transcript" ]]; then
      local tail_content=$(tail -10 "$transcript" 2>/dev/null)
      if echo "$tail_content" | grep -q "Unknown skill.*rename"; then
        __claude_debug "rename: FAILED — 'Unknown skill' in transcript"
        return 1
      fi
      if echo "$tail_content" | grep -q "command-name./rename"; then
        __claude_debug "rename: SUCCESS — confirmed in transcript"
        return 0
      fi
    fi
    # Could not verify — return 2 (indeterminate)
    __claude_debug "rename: INDETERMINATE — no confirmation found"
    return 2
  }

  __claude_rename() {
    local sid="$1" name="$2"
    shift 2
    __claude_debug "rename: resume $sid, name=$name, flags=$*"

    # Attempt 1
    local output
    output=$(__claude_pty_cmd 12 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"
    __claude_check_rename "$output" "$sid"
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 1 ]] && return 1

    # Attempt 2 (indeterminate result — retry once)
    __claude_debug "rename: retrying..."
    sleep 1
    output=$(__claude_pty_cmd 15 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename retry output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"
    __claude_check_rename "$output" "$sid"
    rc=$?
    [[ $rc -eq 0 ]] && return 0

    # Both attempts failed or indeterminate
    __claude_debug "rename: FAILED after retry"
    return 1
  }

  # In-directory variant of rename for worktree
  __claude_rename_in() {
    local dir="$1" sid="$2" name="$3"
    shift 3
    __claude_debug "rename_in ($dir): resume $sid, name=$name, flags=$*"

    # Attempt 1
    local output
    output=$(cd "$dir" && __claude_pty_cmd 12 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename_in output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"
    (cd "$dir" && __claude_check_rename "$output" "$sid")
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 1 ]] && return 1

    # Attempt 2
    __claude_debug "rename_in: retrying..."
    sleep 1
    output=$(cd "$dir" && __claude_pty_cmd 15 --resume "$sid" "$@" "/rename $name" 2>/dev/null)
    __claude_debug "rename_in retry output: $(echo "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)"
    (cd "$dir" && __claude_check_rename "$output" "$sid")
    rc=$?
    [[ $rc -eq 0 ]] && return 0

    __claude_debug "rename_in: FAILED after retry"
    return 1
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
    'summary': None,
    'last_summarized_on': None,
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
  local sessions_with_summary=false
  local user_has_summary=""
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
      --with-summary)
        sessions_with_summary=true
        shift
        ;;
      --summary)
        user_has_summary="$2"
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
        rm -f "$claude_dir"/todos/${del_sid}-agent-*.json 2>/dev/null

        # 5. Debug log
        rm -f "$claude_dir/debug/${del_sid}.txt"

        # 6. File history
        [[ -d "$claude_dir/file-history/${del_sid}" ]] && rm -rf "$claude_dir/file-history/${del_sid}"

        # 7. Session env
        [[ -d "$claude_dir/session-env/${del_sid}" ]] && rm -rf "$claude_dir/session-env/${del_sid}"

        # 8. Tasks
        [[ -d "$claude_dir/tasks/${del_sid}" ]] && rm -rf "$claude_dir/tasks/${del_sid}"

        # 9. Telemetry failed events
        rm -f "$claude_dir"/telemetry/1p_failed_events.${del_sid}.*.json 2>/dev/null

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
from datetime import datetime, timezone

with open(sys.argv[1], 'r') as f:
    data = json.load(f)
if not data:
    print('No named sessions found.')
    sys.exit(0)

# Get last-modified time from transcript file for each entry
for e in data:
    paths = e.get('paths', {})
    transcript = paths.get('transcript', e.get('transcript', ''))
    try:
        mtime = os.path.getmtime(transcript)
        e['_mtime'] = mtime
        e['_modified'] = datetime.fromtimestamp(mtime, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except OSError:
        e['_mtime'] = 0
        e['_modified'] = '-'

# Sort by last modified, most recent first
data.sort(key=lambda e: e['_mtime'], reverse=True)

print(f'Named sessions ({len(data)}):')
print()
for e in data:
    desc = e.get('description') or '-'
    note = e.get('note') or ''
    note_str = f' ({note})' if note else ''
    paths = e.get('paths', {})
    transcript = paths.get('transcript', e.get('transcript', ''))
    exists = '\u2713' if os.path.exists(transcript) else '\u2717'
    print(f'  {e[\"name\"]}')
    print(f'    ID:          {e[\"session_id\"]}')
    print(f'    Description: {desc}')
    print(f'    Created:     {e[\"created_at\"]}')
    print(f'    Modified:    {e[\"_modified\"]}')
    print(f'    Transcript:  {exists} {transcript}{note_str}')
    if sys.argv[2] == '1':
        summary = e.get('summary') or '-'
        summarized_on = e.get('last_summarized_on') or 'never'
        print(f'    Summary:     {summary}')
        print(f'    Summarized:  {summarized_on}')
    print()
print('Resume with: claude --resume <name>')
" "$mapping_file" "$([[ "$sessions_with_summary" == true ]] && echo 1 || echo 0)"
    return $?
  fi

  # --- --summary ---
  if [[ -n "$user_has_summary" ]]; then
    local mapping_file="._claude/session_mapping.json"
    if [[ ! -f "$mapping_file" ]]; then
      echo "No named sessions found in this directory." >&2
      return 1
    fi

    # Look up session by name or ID
    local lookup_result
    lookup_result=$(python3 -c "
import json, sys
lookup = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    data = json.load(f)
for e in data:
    if e['name'] == lookup or e['session_id'] == lookup:
        print(e['session_id'])
        print(e['name'])
        sys.exit(0)
print('not_found', file=sys.stderr)
sys.exit(1)
" "$user_has_summary" "$mapping_file" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Error: no session found matching '$user_has_summary'" >&2
      return 1
    fi

    local orig_sid=$(echo "$lookup_result" | sed -n '1p')
    local orig_name=$(echo "$lookup_result" | sed -n '2p')
    local temp_sid=$(uuidgen | tr '[:upper:]' '[:lower:]')

    echo ""
    printf "\033[1mSummarizing session: %s\033[0m\n" "$orig_name"
    echo ""

    # Fork the session into a temporary one
    __claude_spin "Forking session for summary..."
    "$CLAUDE_BIN" -p --resume "$orig_sid" --fork-session --session-id "$temp_sid" "${claude_flags[@]}" "hi" > /dev/null 2>&1
    __claude_spin_ok "Session forked"

    # Ask the fork for a summary
    __claude_spin "Generating summary..."
    local summary_output
    summary_output=$("$CLAUDE_BIN" -p --resume "$temp_sid" "${claude_flags[@]}" \
      "Give a concise summary (2-4 sentences) of what was done in this session so far. Focus on the key tasks, decisions, and outcomes. Output ONLY the summary text, no formatting or prefixes." 2>/dev/null)
    __claude_spin_ok "Summary generated"

    # Clean up the temporary fork (all traces)
    __claude_spin "Cleaning up temporary fork..."
    local claude_dir="$HOME/.claude"
    local encoded_path=$(echo "$(pwd)" | tr '/' '-')
    local temp_transcript="$HOME/.claude/projects/${encoded_path}/${temp_sid}.jsonl"
    [[ -f "$temp_transcript" ]] && rm -f "$temp_transcript"
    local temp_subagent="${temp_transcript%.jsonl}"
    [[ -d "$temp_subagent" ]] && rm -rf "$temp_subagent"
    rm -f "$claude_dir"/todos/${temp_sid}-agent-*.json 2>/dev/null
    rm -f "$claude_dir/debug/${temp_sid}.txt"
    [[ -d "$claude_dir/file-history/${temp_sid}" ]] && rm -rf "$claude_dir/file-history/${temp_sid}"
    [[ -d "$claude_dir/session-env/${temp_sid}" ]] && rm -rf "$claude_dir/session-env/${temp_sid}"
    [[ -d "$claude_dir/tasks/${temp_sid}" ]] && rm -rf "$claude_dir/tasks/${temp_sid}"
    rm -f "$claude_dir"/telemetry/1p_failed_events.${temp_sid}.*.json 2>/dev/null
    # Remove from history.jsonl
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
" "$temp_sid" "$claude_dir/history.jsonl"
    fi
    __claude_spin_ok "Temporary fork cleaned up"

    # Update the mapping with the summary
    python3 -c "
import json, sys
from datetime import datetime, timezone
lookup = sys.argv[1]
summary = sys.argv[2]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(sys.argv[3], 'r') as f:
    data = json.load(f)
for e in data:
    if e['name'] == lookup or e['session_id'] == lookup:
        e['summary'] = summary
        e['last_summarized_on'] = now
        break
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2)
" "$user_has_summary" "$summary_output" "$mapping_file"

    echo ""
    printf "\033[1mSummary:\033[0m %s\n" "$summary_output"
    return 0
  fi

  # --- --help ---
  if [[ "$user_has_help" == true && -z "$name" ]]; then
    ("$CLAUDE_BIN" "${claude_flags[@]}")
    echo ""
    echo "Wrapper options (provided by claude shell function):"
    echo "  --name <name>                  Create a named session (auto seeds, renames, clears)"
    echo "  --description <text>           Initial context for the session (requires --name)"
    echo "  --sessions                     List all named sessions in the current directory"
    echo "  --sessions --with-summary      List sessions including their summaries"
    echo "  --sessions --delete <name>     Delete a named session from the mapping"
    echo "  --summary <name|id>            Generate a summary for a session"
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
        local resolved_resume="$resume_value"
        # When -p is used, claude requires a UUID — resolve name to session ID
        if [[ "$user_has_print" == true && ! "$resume_value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
          local mapping_file="._claude/session_mapping.json"
          if [[ -f "$mapping_file" ]]; then
            local sid_lookup
            sid_lookup=$(python3 -c "
import json, sys
lookup = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    data = json.load(f)
for e in data:
    if e['name'] == lookup or e['session_id'] == lookup:
        print(e['session_id'])
        sys.exit(0)
sys.exit(1)
" "$resume_value" "$mapping_file" 2>/dev/null)
            if [[ $? -eq 0 && -n "$sid_lookup" ]]; then
              resolved_resume="$sid_lookup"
            else
              echo "Error: --resume with -p requires a session ID (UUID), but '$resume_value' is not a UUID." >&2
              echo "Could not find a named session '$resume_value' in ._claude/session_mapping.json to resolve." >&2
              echo "Use 'claude --sessions' to list available named sessions." >&2
              return 1
            fi
          else
            echo "Error: --resume with -p requires a session ID (UUID), but '$resume_value' is not a UUID." >&2
            echo "No session mapping found (._claude/session_mapping.json does not exist)." >&2
            echo "Use 'claude --name <name>' to create a named session first." >&2
            return 1
          fi
        fi
        passthrough+=("--resume" "$resolved_resume")
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
    "$CLAUDE_BIN" "${passthrough[@]}" "${claude_flags[@]}" "${user_prompt[@]}"
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
    "$CLAUDE_BIN" -p --resume "$resume_value" --fork-session --session-id "$sid" "${claude_flags[@]}" "hi" > /dev/null 2>&1
    __claude_spin_ok "Forked session from '$resume_value'"
    sleep 1

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
      "$CLAUDE_BIN" -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
    else
      "$CLAUDE_BIN" --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
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
    (cd "$abs_wt_dir" && "$CLAUDE_BIN" -p --session-id "$sid" "${claude_flags[@]}" "$seed_message") > /dev/null 2>&1
    __claude_spin_ok "Session seeded"
    sleep 1

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
        tmux send-keys -t "$tmux_session" "$CLAUDE_BIN --resume \"$sid\" ${(q)claude_flags[*]} ${(q)user_prompt[*]}" Enter
        tmux attach -t "$tmux_session"
      else
        (cd "$abs_wt_dir" && "$CLAUDE_BIN" --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
      fi
    elif [[ "$user_has_print" == true ]]; then
      (cd "$abs_wt_dir" && "$CLAUDE_BIN" -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
    else
      (cd "$abs_wt_dir" && "$CLAUDE_BIN" --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}")
    fi
    return $?
  fi

  # === STANDARD PATH ===
  local seed_message="${description:-hi}"

  __claude_spin "Seeding session..."
  "$CLAUDE_BIN" -p --session-id "$sid" "${claude_flags[@]}" "$seed_message" > /dev/null 2>&1
  __claude_spin_ok "Session seeded"
  sleep 1

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
    "$CLAUDE_BIN" -p --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
  else
    "$CLAUDE_BIN" --resume "$sid" "${claude_flags[@]}" "${user_prompt[@]}"
  fi
}
