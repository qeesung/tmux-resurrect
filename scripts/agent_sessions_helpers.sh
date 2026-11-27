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

# separates fields that may be empty (tab is IFS whitespace and would collapse)
_agent_sep=$'\x1f'

agent_sessions_enabled() {
	[ "$(get_tmux_option "$agent_sessions_option" "$default_agent_sessions")" == "on" ]
}

_agent_claude_dir() {
	echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

_agent_agy_dir() {
	echo "$HOME/.gemini/antigravity-cli"
}

agent_process_table() {
	if [ -n "${AGENT_PS_TABLE-}" ]; then
		echo "$AGENT_PS_TABLE"
	else
		ps -Ao pid=,ppid=,args=
	fi
}

# Processes that may be agents, as "pane_pid<TAB>depth<TAB>pid<TAB>args",
# shallowest first, for the given pane pids. One ps + awk for all panes; the
# shallowest match per pane is the agent itself, not a tool it spawned.
agent_candidates() {
	agent_process_table | awk -v roots="$*" '
		BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
		{
			pid = $1; ppid = $2; $1 = ""; $2 = ""
			args[pid] = substr($0, 3)
			parent[pid] = ppid
		}
		END {
			for (pid in args) {
				if (args[pid] !~ /claude|agy/) continue
				p = pid
				for (depth = 1; depth <= 3; depth++) {
					p = parent[p]
					if (p in root) { print p "\t" depth "\t" pid "\t" args[pid]; break }
				}
			}
		}' | sort -t "$(printf '\t')" -k1,1n -k2,2n
}

# Top-level values of a flat JSON object, joined by $_agent_sep.
_agent_json_fields() {
	local file="$1"
	shift
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg sep "$_agent_sep" \
			'. as $o | [$ARGS.positional[] | $o[.] // "" | tostring] | join($sep)' \
			"$file" --args "$@" 2>/dev/null
	else
		# Top-level keys precede nested objects in these files, so the first
		# occurrence of a key is the top-level one.
		local key out="" first=1
		for key in "$@"; do
			[ "$first" == 1 ] || out="$out$_agent_sep"
			first=0
			out="$out$(grep -o "\"$key\":\"\{0,1\}[^\",}]*" "$file" 2>/dev/null |
				head -1 | sed "s/^\"$key\":\"\{0,1\}//")"
		done
		echo "$out"
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
	local json_pid kind
	IFS="$_agent_sep" read -r json_pid kind AGENT_ID AGENT_CWD \
		<<< "$(_agent_json_fields "$file" pid kind sessionId cwd)"
	[ "$json_pid" == "$pid" ] || return 1
	[ -z "$kind" ] || [ "$kind" == "interactive" ] || return 1
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
	local path id db newest=""
	while read -r path; do
		case "$path" in
			"$dir/presence/"*.lock)
				id="${path##*/}"
				id="${id%.lock}"
				db="$dir/conversations/$id.db"
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
# Repeated flags are kept once: a shell alias such as
# `agy='agy --dangerously-skip-permissions'` adds its flags again on every
# restore. Fails for print mode, which is not an interactive session.
agent_rebuild_command() {
	local agent="$1"
	local args="$2"
	local -a argv
	local -a out
	read -ra argv <<< "$args"
	out=("$agent")
	local seen=$'\n'
	local i=1
	local n=${#argv[@]}
	local tok name next entry take
	while [ "$i" -lt "$n" ]; do
		tok="${argv[$i]}"
		name="${tok%%=*}"
		next="${argv[$((i + 1))]-}"
		take=1
		case "$name" in
			-p|--print|--prompt)
				return 1 ;;
			-c|--continue|--fork-session)
				take=0; i=$((i + 1)) ;;
			--session-id|--conversation|-n|--name)
				take=0
				if [[ "$tok" == *=* ]]; then i=$((i + 1)); else i=$((i + 2)); fi ;;
			-r|--resume|-w|--worktree|--teleport|--from-pr|--cloud)
				take=0
				if [[ "$tok" != *=* && -n "$next" && "$next" != -* ]]; then
					i=$((i + 2))
				else
					i=$((i + 1))
				fi ;;
		esac
		[ "$take" == 1 ] || continue
		if [[ "$tok" != -* ]]; then
			i=$((i + 1))
			continue
		fi
		if [[ "$tok" != *=* ]] && { { _agent_flag_takes_value "$tok" && [ -n "$next" ]; } ||
			{ _agent_flag_takes_optional_value "$tok" && [[ -n "$next" && "$next" != -* ]]; }; }; then
			entry="$tok $next"
			i=$((i + 2))
		else
			entry="$tok"
			i=$((i + 1))
		fi
		case "$seen" in
			*$'\n'"$entry"$'\n'*) continue ;;
		esac
		seen="$seen$entry"$'\n'
		if [ "$entry" == "$tok" ]; then
			out+=("$tok")
		else
			out+=("$tok" "$next")
		fi
	done
	printf '%q ' "${out[@]}" | sed 's/ $//'
}

# Sets AGENT_COMMAND (and AGENT_CWD when the agent knows its project dir) and
# succeeds if the pane runs a resumable agent. Uses $AGENT_CANDIDATES when the
# caller computed it for all panes at once.
agent_pane_command() {
	local pane_pid="$1"
	local candidates="${AGENT_CANDIDATES-$(agent_candidates "$pane_pid")}"
	local root depth pid args agent command
	AGENT_COMMAND=""
	AGENT_CWD=""
	while IFS=$'\t' read -r root depth pid args; do
		[ "$root" == "$pane_pid" ] || continue
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
	done <<< "$candidates"
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
