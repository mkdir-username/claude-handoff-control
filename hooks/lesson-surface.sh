#!/usr/bin/env bash
# UserPromptSubmit: delivers to the next turn what stop-handoff-control.sh cannot say — Stop-hook
# stdout never reaches the model, only additionalContext does. Three state files, one producer:
#   <sid>.delayed    — DELAYED_ANSWER lesson, consumed
#   <sid>.missed     — evasion below the block threshold / in cooldown / past the ceiling, consumed
#   <sid>.obligation — open obligation reminder, NOT consumed: it lives until the controller
#                      closes it or the user sends a new message
set -uo pipefail
HANDOFF_CTL_HOME="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}"
STATE_DIR="$HANDOFF_CTL_HOME/state"
HANDOFF_CTL_LOG="${HANDOFF_CTL_LOG:-$HANDOFF_CTL_HOME/verdicts.jsonl}"
DELIVER_MAX="${HANDOFF_CTL_DELIVER_MAX:-900}"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || SESSION_ID=default
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
PARTS=""

add_part() {
  if [ -n "$PARTS" ]; then PARTS="$PARTS
"; fi
  PARTS="$PARTS$1"
}

fresh() {   # <ts> <window>
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  [ $(( $(date +%s) - $1 )) -le "$2" ]
}

DELAYED="$STATE_DIR/$SESSION_ID.delayed"
if [ -f "$DELAYED" ]; then
  TS=$(jq -r '.ts // 0'  "$DELAYED" 2>/dev/null)
  WHY=$(jq -r '.why // ""' "$DELAYED" 2>/dev/null)
  rm -f "$DELAYED"
  if fresh "$TS" "$DELIVER_MAX"; then
    add_part "⏳ ANSWER DELAYED — the previous turn kept the user waiting on long probes although the answer was already found. $WHY
From now on: answer a question with what is already verified, marking what is not. Refinement goes to a background command, a background agent, or after the answer."
  fi
fi

MISSED="$STATE_DIR/$SESSION_ID.missed"
if [ -f "$MISSED" ]; then
  TS=$(jq -r '.ts // 0'          "$MISSED" 2>/dev/null)
  WHY=$(jq -r '.why // ""'       "$MISSED" 2>/dev/null)
  ACT=$(jq -r '.action // ""'    "$MISSED" 2>/dev/null)
  CONT=$(jq -r '.continued // 0' "$MISSED" 2>/dev/null)
  REASON=$(jq -r '.reason // ""' "$MISSED" 2>/dev/null)
  VERD=$(jq -r '.verdict // ""'  "$MISSED" 2>/dev/null)
  rm -f "$MISSED"
  if [[ "$CONT" =~ ^[1-9] ]]; then
    NOBLOCK="The turn was already returned in this chain and the continuation announced instead of acting again.
The return ceiling is exhausted, so this is only a lesson. Same rule:"
  elif [ "$REASON" = "bg_pending" ]; then
    NOBLOCK="The turn was not returned because background work was running and waiting for its notification is legitimate. If the demand above is not about that work — same rule:"
  elif [ "$REASON" = "cooldown" ]; then
    NOBLOCK="The turn was not returned only because of the controller's pause after a recent \"impossible\". Same rule:"
  else
    NOBLOCK="The turn was not returned only because the controller's confidence was below the block threshold. Same rule:"
  fi
  if [ "$VERD" = "UNFLAGGED_RISK" ] && fresh "$TS" "$DELIVER_MAX"; then
    add_part "⚠️ DANGEROUS CHANGE WITHOUT A FLAG — the turn-handoff controller reviewed the previous final: $WHY
Do not roll back. Verify what was removed with tools (find every reference, call graph, dead-code
analyzer) and end your next final with a ⚠️ RESPONSIBLE ZONE block: what was removed,
\"Evidence:\" command → result, \"Rollback:\" command, and \"Ok / not ok?\"."
  elif fresh "$TS" "$DELIVER_MAX"; then
    add_part "⚠️ TURN HANDED BACK UNFINISHED — the turn-handoff controller reviewed the previous final: $WHY
What you should have done yourself: $ACT
$NOBLOCK
a step you named, that is available to you and reversible, is done in the same turn, not announced
with a \"👉 Next\" line. The user may be away from the terminal — they should come back to work,
not to a promise."
  fi
fi

OBL="$STATE_DIR/$SESSION_ID.obligation"
# A real user message supersedes the obligation: the user saw the handed-back turn and set the
# course. The obligation judge sees only the current turn and would keep an old action open across
# a topic change up to the return ceiling. Background-task notifications are not the user.
if [ -s "$OBL" ] && [ -n "$PROMPT" ] && [[ "$PROMPT" != "<task-notification"* ]]; then
  OBL_ACT=$(jq -r '.action // ""' "$OBL" 2>/dev/null)
  rm -f "$OBL"
  mkdir -p "$(dirname "$HANDOFF_CTL_LOG")" 2>/dev/null
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$SESSION_ID" --arg a "$OBL_ACT" \
    '{ts:$ts,session:$s,verdict:"OBLIGATION",outcome:"superseded",
      reason:"new user message",action:$a,blocked:false}' >> "$HANDOFF_CTL_LOG" 2>/dev/null
fi
if [ -s "$OBL" ]; then
  SET_AT=$(jq -r '.set_at // 0'     "$OBL" 2>/dev/null)
  ACT=$(jq -r    '.action // ""'    "$OBL" 2>/dev/null)
  ITER=$(jq -r   '.iterations // 0' "$OBL" 2>/dev/null)
  if [ -n "$ACT" ] && fresh "$SET_AT" "${HANDOFF_CTL_OBLIGATION_TTL:-3600}"; then
    add_part "⛔ OBLIGATION OPEN (turn returns so far: $ITER) — $ACT
It is checked at EVERY end of turn and drops by itself once the action is done.
If it is impossible — hits a ban, needs a live human or an unavailable resource —
say so in one line with proof: the obligation closes and will not repeat."
  fi
fi

[ -n "$PARTS" ] || exit 0
jq -n --arg c "$PARTS" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
