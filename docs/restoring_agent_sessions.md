# Restoring AI coding agent conversations

Resume the exact conversation of every [Claude Code](https://claude.com/claude-code)
(`claude`) and Antigravity CLI (`agy`) pane after a reboot:

    set -g @resurrect-agent-sessions 'on'

No `@resurrect-processes` entry is needed for these programs.

### What gets saved

For a pane running one of the agents, the saved command becomes

    <agent> <original flags> --resume <conversation id>

where the id is the conversation the agent shows **at save time**, not the one
it was started with: `/clear`, `/resume` and new conversations are followed.
Several agents in the same directory each get their own conversation back,
which `claude -c` / `agy -c` ("most recent conversation here") cannot do.

When rebuilding the command:

- flags such as `--dangerously-skip-permissions` or `--model opus` are kept,
- resume selectors (`-c`, `-r <id>`, `--session-id`, ...) and one-shot actions
  (`-w`, `--teleport`, ...) are dropped,
- an initial prompt (`claude "fix the bug"`) is dropped so it does not run
  again,
- print mode (`-p`) is not an interactive session and is left alone,
- an agent that has no message yet is restarted without `--resume`.

Claude Code panes are restored in the conversation's project directory.

### Where the conversation id comes from

No agent hooks or extra configuration are involved:

- `claude`: `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` (default `~/.claude`),
  which Claude Code keeps up to date with its current `sessionId`.
- `agy`: the `~/.gemini/antigravity-cli/presence/<conversation id>.lock` file
  the agy process holds open (read with `lsof`, or `/proc` on Linux).

Both are internal files of the respective CLIs; if a future version changes
them, the pane falls back to starting the agent without `--resume`.

Like every restored program, the command is only replayed into panes created by
the restore, never into panes that already existed.
