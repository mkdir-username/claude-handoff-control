#!/usr/bin/env bash
# UserPromptSubmit: caches the user's last prompt for stop-handoff-control.sh — the Stop event does
# not carry it, and without it a direct answer to a question reads as "the agent did nothing".
set -u
HANDOFF_CTL_HOME="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}"
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || SESSION_ID=default
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
# A background-task notification arrives through the same event but is not the user's request.
[[ "$PROMPT" == "<task-notification"* ]] && exit 0
DIR="$HANDOFF_CTL_HOME/prompts"
mkdir -p "$DIR" 2>/dev/null || exit 0
find "$DIR" -name '*.last-prompt' -mtime +2 -delete 2>/dev/null
printf '%s' "$PROMPT" > "$DIR/$SESSION_ID.last-prompt" 2>/dev/null
exit 0
