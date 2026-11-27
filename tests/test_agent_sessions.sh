#!/usr/bin/env bash
# Unit tests for scripts/agent_sessions_helpers.sh. Needs only bash, no tmux:
#   bash tests/test_agent_sessions.sh

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/../scripts/agent_sessions_helpers.sh"

FAILURES=0

check() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" == "$actual" ]; then
		echo "ok   $name"
	else
		echo "FAIL $name"
		echo "     expected: $expected"
		echo "     actual:   $actual"
		FAILURES=$((FAILURES + 1))
	fi
}

check_fails() {
	local name="$1"
	shift
	if "$@" >/dev/null; then
		echo "FAIL $name (expected failure)"
		FAILURES=$((FAILURES + 1))
	else
		echo "ok   $name"
	fi
}

# --- agent_rebuild_command ---------------------------------------------------

check "drops -r with id" "claude --dangerously-skip-permissions" \
	"$(agent_rebuild_command claude 'claude --dangerously-skip-permissions -r 7180b908-8a26-4584-b65e-aa9a8e412458')"
check "drops bare -r" "claude --model opus" \
	"$(agent_rebuild_command claude 'claude -r --model opus')"
check "drops positional prompt" "claude --model opus" \
	"$(agent_rebuild_command claude 'claude --model opus fix the bug')"
check "drops continue" "claude --permission-mode plan" \
	"$(agent_rebuild_command claude 'claude -c --permission-mode plan')"
check "drops one-shot flags" "claude" \
	"$(agent_rebuild_command claude 'claude --resume=abc -w feature --session-id 1234 --fork-session -n name')"
check "keeps optional value" "claude --debug api" \
	"$(agent_rebuild_command claude 'claude --debug api')"
check "agy resume and mode" "agy --mode plan" \
	"$(agent_rebuild_command agy '/Users/me/.local/bin/agy --resume abc --mode plan')"
check "agy conversation" "agy --dangerously-skip-permissions" \
	"$(agent_rebuild_command agy 'agy --conversation abc --dangerously-skip-permissions')"
check_fails "print mode is not restored" agent_rebuild_command claude 'claude -p hello'
check_fails "agy print mode is not restored" agent_rebuild_command agy 'agy --print hello'

quoted="$(agent_rebuild_command claude 'claude --settings {"a":1}')"
eval "set -- $quoted"
check "shell quoting round-trips" '{"a":1}' "$3"

# --- _agent_json_value -------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
json="$TMP_DIR/sample.json"
echo '{"pid":200,"sessionId":"top","cwd":"/work/a","kind":"interactive","formerNames":[{"name":"x","sessionId":"old"}]}' > "$json"

check "json via jq" "top" "$(_agent_json_value "$json" sessionId)"
check "json number" "200" "$(_agent_json_value "$json" pid)"
no_jq() {
	command() { [ "$2" == "jq" ] && return 1; builtin command "$@"; }
	_agent_json_value "$@"
}
check "json without jq" "top" "$(no_jq "$json" sessionId)"
check "json number without jq" "200" "$(no_jq "$json" pid)"
check "json path without jq" "/work/a" "$(no_jq "$json" cwd)"

# --- agent_pane_command ------------------------------------------------------

export CLAUDE_CONFIG_DIR="$TMP_DIR/claude"
HOME="$TMP_DIR/home"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-work-a" \
	"$HOME/.gemini/antigravity-cli/conversations" "$HOME/.gemini/antigravity-cli/presence"

echo '{"pid":200,"sessionId":"S1","cwd":"/work/a","kind":"interactive"}' > "$CLAUDE_CONFIG_DIR/sessions/200.json"
touch "$CLAUDE_CONFIG_DIR/projects/-work-a/S1.jsonl"
echo '{"pid":250,"sessionId":"EMPTY","cwd":"/work/b","kind":"interactive"}' > "$CLAUDE_CONFIG_DIR/sessions/250.json"
echo '{"pid":600,"sessionId":"P1","cwd":"/work/a","kind":"interactive"}' > "$CLAUDE_CONFIG_DIR/sessions/600.json"
echo '{"pid":800,"sessionId":"STALE","cwd":"/work/a","kind":"interactive"}' > "$CLAUDE_CONFIG_DIR/sessions/800.json"
touch "$HOME/.gemini/antigravity-cli/conversations/C1.db"

_agent_open_files() {
	[ "$1" == "400" ] && echo "$HOME/.gemini/antigravity-cli/presence/C1.lock"
	[ "$1" == "450" ] && echo "$HOME/.gemini/antigravity-cli/presence/NO-DB.lock"
	return 0
}

AGENT_PS_TABLE="100 1 -zsh
200 100 claude --dangerously-skip-permissions
201 200 /bin/zsh -c sleep 1
150 1 -zsh
250 150 claude
300 1 -zsh
400 300 /Users/me/.local/bin/agy --dangerously-skip-permissions
350 1 -zsh
450 350 agy
500 1 -zsh
600 500 claude -p hello
700 1 -zsh
800 700 vim notes"

agent_pane_command 100
check "claude pane" "claude --dangerously-skip-permissions --resume S1" "$AGENT_COMMAND"
check "claude cwd" "/work/a" "$AGENT_CWD"
agent_pane_command 150
check "claude without transcript starts fresh" "claude" "$AGENT_COMMAND"
agent_pane_command 300
check "agy pane" "agy --dangerously-skip-permissions --resume C1" "$AGENT_COMMAND"
agent_pane_command 350
check "agy without conversation starts fresh" "agy" "$AGENT_COMMAND"
check_fails "claude print pane is kept as is" agent_pane_command 500
check_fails "stale session file with reused pid" agent_pane_command 700
check_fails "pane without agent" agent_pane_command 999

# --- is_agent_resume_command -------------------------------------------------

check_fails "vim is not an agent" is_agent_resume_command "vim notes"
check_fails "print mode is not replayed" is_agent_resume_command "claude -p hello"
is_agent_resume_command "claude --resume S1" && check "claude resume command" ok ok
is_agent_resume_command "/opt/bin/agy --resume C1" && check "agy resume command" ok ok

if [ "$FAILURES" -gt 0 ]; then
	echo "$FAILURES failure(s)"
	exit 1
fi
echo "all passed"
