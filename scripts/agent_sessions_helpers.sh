# Resuming AI coding agent conversations: Claude Code (`claude`) and
# Antigravity CLI (`agy`).
#
# Save: a pane running one of these agents is saved with the command
#   <agent> <original flags> --resume <conversation id>
# where the id is the conversation the agent shows *right now* (it changes on
# /clear, /resume, ...), so several agents in the same directory each get their
# own conversation back. Restore replays that command like any other program.
#
# Where the current conversation id comes from (no agent hooks needed):
#   claude  $CLAUDE_CONFIG_DIR/sessions/<pid>.json, kept up to date by Claude Code
#   agy     the presence/<conversation id>.lock the agy process holds open

agent_sessions_enabled() {
	[ "$(get_tmux_option "$agent_sessions_option" "$default_agent_sessions")" == "on" ]
}

_agent_claude_dir() {
	echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

_agent_agy_dir() {
	echo "$HOME/.gemini/antigravity-cli"
}

# "pid<space>ppid<space>args" for every process; computed once per save.
agent_process_table() {
	ps -Ao pid=,ppid=,args=
}

# Descendants of a pane's shell as "pid<TAB>args", breadth first, so the agent
# is found before the shells and tools it spawns.
_agent_descendants() {
	local root="$1"
	local table="${AGENT_PS_TABLE:-$(agent_process_table)}"
	echo "$table" | awk -v root="$root" '
		{
			pid = $1; ppid = $2; $1 = ""; $2 = ""
			args[pid] = substr($0, 3)
			kids[ppid] = kids[ppid] " " pid
		}
		END {
			n = split(kids[root], level, " ")
			for (depth = 0; depth < 3 && n > 0; depth++) {
				m = 0
				for (i = 1; i <= n; i++) {
					p = level[i]
					print p "\t" args[p]
					c = split(kids[p], found, " ")
					for (j = 1; j <= c; j++) next_level[++m] = found[j]
				}
				for (i = 1; i <= m; i++) level[i] = next_level[i]
				n = m
			}
		}'
}

# Top-level string/number value of a flat JSON object.
_agent_json_value() {
	local file="$1"
	local key="$2"
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg k "$key" '.[$k] // empty | tostring' "$file" 2>/dev/null
	else
		# Top-level keys precede nested objects in these files, so the first
		# occurrence is the top-level one.
		grep -o "\"$key\":\"\{0,1\}[^\",}]*" "$file" 2>/dev/null |
			head -1 |
			sed "s/^\"$key\":\"\{0,1\}//"
	fi
}

_agent_open_files() {
	local pid="$1"
	if [ -d "/proc/$pid/fd" ]; then
		local fd
		for fd in /proc/"$pid"/fd/*; do
			readlink "$fd"
		done 2>/dev/null
	else
		lsof -n -P -a -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p'
	fi
}

# Sets AGENT_ID / AGENT_CWD and succeeds if pid is an interactive claude.
_agent_claude_session() {
	local pid="$1"
	local args="$2"
	local dir="$(_agent_claude_dir)"
	local file="$dir/sessions/$pid.json"
	[ -f "$file" ] || return 1
	# guard against a stale file whose pid got reused by another program
	[[ "$args" == *claude* ]] || return 1
	[ "$(_agent_json_value "$file" pid)" == "$pid" ] || return 1
	local kind="$(_agent_json_value "$file" kind)"
	[ -z "$kind" ] || [ "$kind" == "interactive" ] || return 1
	AGENT_ID="$(_agent_json_value "$file" sessionId)"
	AGENT_CWD="$(_agent_json_value "$file" cwd)"
	# a conversation without any message has no transcript and can't be resumed
	if [ -n "$AGENT_ID" ] && ! compgen -G "$dir/projects/*/$AGENT_ID.jsonl" >/dev/null; then
		AGENT_ID=""
	fi
	return 0
}

# Sets AGENT_ID / AGENT_CWD and succeeds if pid is agy.
_agent_agy_session() {
	local pid="$1"
	local args="$2"
	local first="${args%% *}"
	[ "${first##*/}" == "agy" ] || return 1
	local dir="$(_agent_agy_dir)"
	local path id newest=""
	while read -r path; do
		case "$path" in
			"$dir/presence/"*.lock)
				id="${path##*/}"
				id="${id%.lock}"
				local db="$dir/conversations/$id.db"
				if [ -f "$db" ] && { [ -z "$newest" ] || [ "$db" -nt "$newest" ]; }; then
					newest="$db"
				fi
				;;
		esac
	done <<< "$(_agent_open_files "$pid")"
	AGENT_ID=""
	if [ -n "$newest" ]; then
		AGENT_ID="${newest##*/}"
		AGENT_ID="${AGENT_ID%.db}"
	fi
	AGENT_CWD="" # agy's cwd is the pane's current path already
	return 0
}

_agent_flag_takes_value() {
	case "$1" in
		--add-dir|--agent|--agents|--append-system-prompt|--autocompact|\
		--allowedTools|--allowed-tools|--disallowedTools|--disallowed-tools|\
		--betas|--debug-file|--effort|--environment|--fallback-model|--file|\
		--input-format|--json-schema|--max-budget-usd|--mcp-config|--model|\
		--output-format|--permission-mode|--permission-prompts|--plugin-dir|\
		--plugin-url|--remote-control-session-name-prefix|--setting-sources|\
		--settings|--system-prompt|--system-prompt-snapshot|--tools|--mode|\
		--project|--log-file|--print-timeout)
			return 0 ;;
	esac
	return 1
}

_agent_flag_takes_optional_value() {
	case "$1" in
		-d|--debug|--prompt-suggestions|--remote-control)
			return 0 ;;
	esac
	return 1
}

# Prints "<agent> <flags>" rebuilt from a full command line: resume selectors
# and one-shot actions are dropped (the caller appends its own --resume), as
# are positional arguments, i.e. an initial prompt that must not run again.
# Fails for print mode, which is not an interactive session.
agent_rebuild_command() {
	local agent="$1"
	local args="$2"
	local -a argv
	local -a out
	read -ra argv <<< "$args"
	out=("$agent")
	local i=1
	local n=${#argv[@]}
	local tok name next
	while [ "$i" -lt "$n" ]; do
		tok="${argv[$i]}"
		name="${tok%%=*}"
		next="${argv[$((i + 1))]-}"
		case "$name" in
			-p|--print|--prompt)
				return 1 ;;
			-c|--continue|--fork-session)
				i=$((i + 1)) ;;
			--session-id|--conversation|-n|--name)
				if [[ "$tok" == *=* ]]; then i=$((i + 1)); else i=$((i + 2)); fi ;;
			-r|--resume|-w|--worktree|--teleport|--from-pr|--cloud)
				if [[ "$tok" != *=* && -n "$next" && "$next" != -* ]]; then
					i=$((i + 2))
				else
					i=$((i + 1))
				fi ;;
			*)
				if [[ "$tok" != -* ]]; then
					i=$((i + 1))
				elif [[ "$tok" != *=* ]] && _agent_flag_takes_value "$tok" && [ -n "$next" ]; then
					out+=("$tok" "$next")
					i=$((i + 2))
				elif [[ "$tok" != *=* ]] && _agent_flag_takes_optional_value "$tok" &&
					[[ -n "$next" && "$next" != -* ]]; then
					out+=("$tok" "$next")
					i=$((i + 2))
				else
					out+=("$tok")
					i=$((i + 1))
				fi ;;
		esac
	done
	printf '%q ' "${out[@]}" | sed 's/ $//'
}

# Sets AGENT_COMMAND (and AGENT_CWD when the agent knows its project dir) and
# succeeds if the pane runs a resumable agent.
agent_pane_command() {
	local pane_pid="$1"
	local pid args agent command
	AGENT_COMMAND=""
	AGENT_CWD=""
	while IFS=$'\t' read -r pid args; do
		[ -n "$pid" ] || continue
		AGENT_ID=""
		AGENT_CWD=""
		if _agent_claude_session "$pid" "$args"; then
			agent="claude"
		elif _agent_agy_session "$pid" "$args"; then
			agent="agy"
		else
			continue
		fi
		command="$(agent_rebuild_command "$agent" "$args")" || return 1
		if [ -n "$AGENT_ID" ]; then
			command="$command --resume $AGENT_ID"
		fi
		AGENT_COMMAND="$command"
		return 0
	done <<< "$(_agent_descendants "$pane_pid")"
	return 1
}

# Restore side: was this pane command written by agent_pane_command?
is_agent_resume_command() {
	local command="$1"
	local first="${command%% *}"
	case "${first##*/}" in
		claude|agy) ;;
		*) return 1 ;;
	esac
	case " $command " in
		*" -p "*|*" --print "*|*" --prompt "*) return 1 ;;
	esac
	return 0
}
