#!/usr/bin/env bash
# stop-handoff-control.sh — Stop hook: did the agent hand the turn back with work or with an excuse?
#
# A controller, not a reviewer: it never judges the quality of the work. It gets the names of the
# tools called and the outcomes of failed calls, never call arguments or successful output.
# An evasion returns {"decision":"block"} and Claude Code continues the SAME turn.
# A returned MISSED_ACTION becomes an obligation that is re-checked on every following Stop
# until it is met, declared impossible, stalls, or expires.
#
# Fail-open everywhere: no key, network error, garbage instead of JSON → exit 0 silently.
# The controller must never be able to break the end of a turn.
#
# Bypass: touch "$HANDOFF_CTL_HOME/skip" (valid 30 minutes, consumed on use).

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF_CTL_HOME="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}"
RUBRIC_DIR="${HANDOFF_CTL_RUBRIC_DIR:-$HOOK_DIR/../rubrics}"
RUBRIC="${HANDOFF_CTL_RUBRIC:-$RUBRIC_DIR/handoff-control.md}"
STATE_DIR="$HANDOFF_CTL_HOME/state"
HANDOFF_CTL_LOG="${HANDOFF_CTL_LOG:-$HANDOFF_CTL_HOME/verdicts.jsonl}"
THRESHOLD="${HANDOFF_CTL_THRESHOLD:-0.90}"
SOFT_THRESHOLD="${HANDOFF_CTL_SOFT_THRESHOLD:-0.80}"
API_URL="${HANDOFF_CTL_API_URL:-https://api.anthropic.com/v1/messages}"
API_KEY="${HANDOFF_CTL_API_KEY:-${ANTHROPIC_API_KEY:-}}"
MODEL="${HANDOFF_CTL_MODEL:-claude-haiku-4-5}"

INPUT=$(cat)
# shellcheck source=lib/stop-rewake-guard.sh
source "$HOOK_DIR/lib/stop-rewake-guard.sh"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || SESSION_ID=default
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

CONTINUED=0; CASCADE=0
if stop_rewake_should_skip "$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" \
  "$SESSION_ID" handoff-control; then
  # A continuation caused by this controller's own block is judged too: otherwise the turn
  # after a push ("👉 Next: starting the search") passes unseen.
  [ -f "$STATE_DIR/$SESSION_ID.by-control" ] || exit 0
  CASCADE=$(cat "$STATE_DIR/$SESSION_ID.cascade" 2>/dev/null); [[ "$CASCADE" =~ ^[0-9]+$ ]] || CASCADE=1
  CONTINUED=$CASCADE
fi

BYPASS="$HANDOFF_CTL_HOME/skip"
if [ -f "$BYPASS" ]; then
  MTIME=$(stat -f %m "$BYPASS" 2>/dev/null || stat -c %Y "$BYPASS" 2>/dev/null || date +%s)
  AGE=$(( $(date +%s) - MTIME )); rm -f "$BYPASS"
  [ "$AGE" -lt 1800 ] && { echo "handoff-control bypassed (${AGE}s)" >&2; exit 0; }
fi

LAST_TEXT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
{ [ -z "$LAST_TEXT" ] || [ "$LAST_TEXT" = "null" ]; } && exit 0
[ -f "$RUBRIC" ] || exit 0

# The judge is swappable so tests never hit the API while the live path stays the only one in use.
ask_controller() {
  if [ -n "${HANDOFF_CTL_CMD:-}" ]; then "$HANDOFF_CTL_CMD"; return; fi
  [ -n "$API_KEY" ] || return 1
  curl -s -m "${HANDOFF_CTL_TIMEOUT:-40}" "$API_URL" \
    -H "x-api-key: $API_KEY" -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" --data-binary @-
}

# Optional calibrator. Self-reported confidence of an LLM judge clusters at 0.85/0.90/0.95 and
# does not calibrate; a narrow yes/no question with reasoning off and top_logprobs gives a real
# distribution. Needs an OpenAI-compatible endpoint that returns logprobs, so it is off by default
# and only logged — it never changes the verdict.
ask_calibrator() {
  if [ -n "${HANDOFF_CTL_CALIB_CMD:-}" ]; then "$HANDOFF_CTL_CALIB_CMD"; return; fi
  [ -n "${HANDOFF_CTL_CALIB_URL:-}" ] || return 1
  curl -s -m "${HANDOFF_CTL_CALIB_TIMEOUT:-10}" "$HANDOFF_CTL_CALIB_URL" \
    -H "Authorization: Bearer ${HANDOFF_CTL_CALIB_KEY:-$API_KEY}" \
    -H "content-type: application/json" --data-binary @-
}

TMP_FINAL=$(mktemp) || exit 0
trap 'rm -f "$TMP_FINAL"' EXIT
if [ "${#LAST_TEXT}" -gt 3200 ]; then
  { echo "…(beginning of the final omitted, tail shown)…"
    printf '%s' "$LAST_TEXT" | python3 -c 'import sys; s=sys.stdin.read(); sys.stdout.write(s[-3000:])' 2>/dev/null
  } > "$TMP_FINAL" 2>/dev/null || printf '%s' "$LAST_TEXT" > "$TMP_FINAL"
else
  printf '%s' "$LAST_TEXT" > "$TMP_FINAL"
fi

# Without the user's request a direct answer to a question reads as "the agent did nothing".
# Written by prompt-cache.sh on UserPromptSubmit.
PROMPT_FILE="$HANDOFF_CTL_HOME/prompts/$SESSION_ID.last-prompt"
USER_PROMPT=$(head -c 1500 "$PROMPT_FILE" 2>/dev/null || true)

# The current turn: everything after the last REAL user message — a user record carrying a
# tool_result is a tool reply, not a new turn.
TURN=""
LINES=""
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TURN=$(jq -s '
    [ .[] | select(.type=="user" or .type=="assistant") ] as $m
    | ( $m
        | map( .type=="user"
               and ( (.message.content|type)=="string"
                     or ( (.message.content|type)=="array"
                          and ([ .message.content[]? | select(.type=="tool_result") ] | length) == 0 ) ) )
        | rindex(true) ) as $i
    | $m[ (if $i == null then 0 else $i end) : ]' "$TRANSCRIPT" 2>/dev/null) || TURN=""
  # Anchor to the source: the log keeps only a slice of the final text. JSONL line numbers
  # address the whole turn, including tool output, for a local retro. Nothing of it leaves.
  LINE_FROM=$(jq -n -r '[ inputs
      | select(.type=="user"
               and ( (.message.content|type)=="string"
                     or ( (.message.content|type)=="array"
                          and ([ .message.content[]? | select(.type=="tool_result") ] | length) == 0 ) ) )
      | input_line_number ] | last // 1' "$TRANSCRIPT" 2>/dev/null) || LINE_FROM=""
  LINE_TO=$(awk 'END{print NR}' "$TRANSCRIPT" 2>/dev/null) || LINE_TO=""
  [ -n "$LINE_FROM" ] && [ -n "$LINE_TO" ] && LINES="$LINE_FROM-$LINE_TO"
fi
# The judge needs the fact that Bash and Edit were called, not their content.
TOOLS=$(printf '%s' "$TURN" | jq -r '..|objects|select(.type=="tool_use")|.name' 2>/dev/null \
        | sort -u | paste -sd, - )

# Background work launched after the last real user message and not yet reported back.
# Not $TURN: a continuation after a block starts with an isMeta "Stop hook feedback" record and the
# turn slice no longer sees the launch. A launch is recognised by the START of a tool_result (a grep
# printing the phrase is not a launch); completion by <tool-use-id> outside assistant text and tool
# output (a literal in a Read result must not close a live launch).
bg_pending() {
  { [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; } || { echo 0; return; }
  command grep -qE 'Async agent launched|Command running in background with ID:|Workflow launched in background' \
    "$TRANSCRIPT" 2>/dev/null || { echo 0; return; }
  jq -Rn -r --argjson now "$(date +%s)" --argjson win "${HANDOFF_CTL_BG_WINDOW:-3600}" '
    [inputs | fromjson?] as $recs
    | ([ $recs[] | select(.type != "assistant")
         | select((.message.content? | if type == "array" then any(.[]; .type? == "tool_result") else false end) | not)
         | tostring | [scan("<tool-use-id>([^<]+)</tool-use-id>")[]] | .[] ] | unique) as $done
    | ([ $recs | to_entries[]
         | select(.value.type == "user" and (.value.isMeta // false) != true)
         | select(.value.message.content as $c
             | (($c|type) == "string" and ($c|startswith("<task-notification>")|not))
               or (($c|type) == "array" and ([$c[]? | select(.type? == "tool_result")] | length) == 0))
         | .key ] | last // -1) as $from
    | [ $recs[($from + 1):][] | select(.type == "user")
        | (.timestamp // "" | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? // 0) as $t
        | select($now - $t < $win)
        | .message.content? | arrays | .[] | select(.type? == "tool_result")
        | select((if (.content|type) == "string" then .content
                  else ([.content[]? | .text? // empty] | first // "") end)
                 | test("^(Async agent launched|Command running in background with ID:|Workflow launched in background)"))
        | .tool_use_id ] | unique
    | map(select(. as $id | $done | index($id) | not)) | length' "$TRANSCRIPT" 2>/dev/null || echo 0
}

# Names are not enough where the judge must decide "the action is impossible": it has to check
# the agent's claim. Failed calls live in the transcript — tool_result.is_error joined to tool_use
# by id. A hook block and a failed command are kept apart: the first proves a ban, the second a
# technical failure. Call arguments never leave: .inp only counts "distinct" inside unique.
# Error text does leave, so it goes through mask_secrets.
# shellcheck source=lib/secret-patterns.sh
source "$HOOK_DIR/lib/secret-patterns.sh" 2>/dev/null || mask_secrets() { cat; }
FAILS=$(printf '%s' "$TURN" | jq -r '
  ( [ .[] | .message.content? | arrays | .[] | select(.type=="tool_use") ]
    | map({key:.id, value:{name:.name, inp:(.input|tojson|.[0:120])}}) | from_entries ) as $c
  | [ .[] | .message.content? | arrays | .[] | select(.type=="tool_result" and .is_error==true)
      | { name: ($c[.tool_use_id].name // "?"), inp: ($c[.tool_use_id].inp // ""),
          err: ((if (.content|type)=="string" then .content else (.content|tojson) end)
                | gsub("\\s+";" ") | .[0:120]),
          hook: ((if (.content|type)=="string" then .content else (.content|tojson) end)
                 | test("PreToolUse:|PostToolUse:")) } ]
  | { blocked: [.[]|select(.hook)], failed: [.[]|select(.hook|not)] }
  | "BLOCKED BY HOOKS: \(.blocked|length) (distinct \([.blocked[]|.name+.inp]|unique|length))"
    + ([.blocked[-6:][] | "\n  ⛔ \(.name) → \(.err)"] | join(""))
    + "\nFAILED CALLS: \(.failed|length) (distinct \([.failed[]|.name+.inp]|unique|length))"
    + ([.failed[-6:][]  | "\n  ✗ \(.name) → \(.err)"] | join(""))' 2>/dev/null \
  | mask_secrets) || FAILS=""
# Empty evidence is ambiguous: no failures, or no transcript. The rubric reads emptiness as
# "the agent did not try", so the difference must be spelled out.
[ -n "$TURN" ] || FAILS="turn transcript unavailable — absence of failures cannot be judged"

# Fail-open is silent: a dead endpoint would let every turn pass unchecked for hours. A single
# network blip is not noise-worthy — warn from the second miss in a row, at most every 30 minutes.
CTL_DOWN_FILE="${HANDOFF_CTL_DOWN_FILE:-$STATE_DIR/ctl-down}"
ctl_up() { rm -f "$CTL_DOWN_FILE" 2>/dev/null; }
ctl_down() {
  local now n=0 since="" warned=0 at
  now=$(date +%s)
  [ -f "$CTL_DOWN_FILE" ] && read -r n since warned < "$CTL_DOWN_FILE"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [[ "$since" =~ ^[0-9]+$ ]] || since=$now
  [[ "$warned" =~ ^[0-9]+$ ]] || warned=0
  n=$(( n + 1 ))
  if [ "$n" -ge 2 ] && [ $(( now - warned )) -ge 1800 ]; then
    warned=$now
    at=$(date -d "@$since" +%H:%M 2>/dev/null || date -r "$since" +%H:%M 2>/dev/null)
    jq -nc --arg m "⚠️ handoff-control: judge unreachable $n times in a row since $at — turns go unchecked. Check HANDOFF_CTL_API_KEY / HANDOFF_CTL_API_URL." \
      '{systemMessage:$m}'
  fi
  mkdir -p "$(dirname "$CTL_DOWN_FILE")" 2>/dev/null
  echo "$n $since $warned" > "$CTL_DOWN_FILE" 2>/dev/null
  exit 0
}

# shellcheck source=lib/long-wait-detect.sh
source "$HOOK_DIR/lib/long-wait-detect.sh" 2>/dev/null || long_wait_seconds() { echo 0; }
WAITS=0; WAIT_SUM=0
while IFS= read -r cmd; do
  n=$(long_wait_seconds "$cmd")
  [ "$n" -ge "${LONG_WAIT_MIN:-15}" ] && { WAITS=$((WAITS + 1)); WAIT_SUM=$((WAIT_SUM + n)); }
done < <(printf '%s' "$TURN" | jq -r '..|objects|select(.type=="tool_use" and .name=="Bash" and (.input.run_in_background != true))|.input.command // empty|gsub("\n";" ")' 2>/dev/null)
TURN_SEC=$(printf '%s' "$TURN" | jq -r '[.[]?.timestamp // empty | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601] | if length > 1 then (max - min | floor) else 0 end' 2>/dev/null)

mkdir -p "$(dirname "$HANDOFF_CTL_LOG")" 2>/dev/null || true

# ── Obligation ────────────────────────────────────────────────────────────────────────────
# A verdict that returned the turn does not vanish: it lives on as a condition checked on every
# following Stop until closed. Met → drop it; not met → return the turn, at most MAX_ITER times;
# impossible → close it and let the agent stop. The TTL exists because nothing else cleans state:
# an obligation on an abandoned topic would otherwise return turns forever.
OBL_FILE="$STATE_DIR/$SESSION_ID.obligation"
OBL_RUBRIC="${HANDOFF_CTL_OBLIGATION_RUBRIC:-$RUBRIC_DIR/obligation.md}"
OBL_ACTION=""; OBL_WHY=""; OBL_SET=0; OBL_ITER=0

obl_record() {   # <outcome> <reason> <blocked>
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$SESSION_ID" \
    --arg o "$1" --arg r "$2" --argjson b "$3" \
    --arg a "$OBL_ACTION" --argjson i "$OBL_ITER" \
    '{ts:$ts,session:$s,verdict:"OBLIGATION",outcome:$o,reason:$r,
      action:$a,iterations:$i,blocked:$b}' >> "$HANDOFF_CTL_LOG" 2>/dev/null || true
}

if [ "$CONTINUED" = "0" ] && [ -s "$OBL_FILE" ]; then
  OBL_ACTION=$(jq -r '.action // ""'   "$OBL_FILE" 2>/dev/null)
  OBL_WHY=$(jq -r    '.why // ""'      "$OBL_FILE" 2>/dev/null)
  OBL_SET=$(jq -r    '.set_at // 0'    "$OBL_FILE" 2>/dev/null)
  OBL_ITER=$(jq -r   '.iterations // 0' "$OBL_FILE" 2>/dev/null)
  [[ "$OBL_SET"  =~ ^[0-9]+$ ]] || OBL_SET=0
  [[ "$OBL_ITER" =~ ^[0-9]+$ ]] || OBL_ITER=0
  OBL_AGE=$(( $(date +%s) - OBL_SET ))

  if [ -z "$OBL_ACTION" ] || [ "$OBL_AGE" -ge "${HANDOFF_CTL_OBLIGATION_TTL:-3600}" ]; then
    rm -f "$OBL_FILE"
    obl_record expired "obligation older than TTL (${OBL_AGE}s)" false
    exit 0
  fi
  [ -f "$OBL_RUBRIC" ] || exit 0

  # Background work launched for the obligation is still running: judging now is premature, and
  # an attempt spent on waiting would eat the MAX_ITER ceiling. The TTL keeps running.
  if [ "$(bg_pending)" -gt 0 ]; then
    obl_record deferred_bg "background work of this turn has not reported yet" false
    exit 0
  fi

  OBL_BODY=$(jq -n --rawfile rubric "$OBL_RUBRIC" --rawfile final "$TMP_FINAL" \
    --arg model "$MODEL" --arg act "$OBL_ACTION" --arg prompt "${USER_PROMPT:-—}" \
    --arg tools "${TOOLS:-—}" --arg fails "${FAILS:-—}" \
    '{model:$model, max_tokens:1000, system:$rubric,
      messages:[{role:"user", content:
        ("OPEN OBLIGATION FROM PREVIOUS TURN:\n<<<\n" + $act + "\n>>>\n\n" +
         "USER REQUEST THIS TURN:\n<<<\n" + $prompt + "\n>>>\n\n" +
         "TOOLS CALLED THIS TURN: " + $tools + "\n\n" +
         "CALL RESULTS:\n" + $fails + "\n\n" +
         "FINAL MESSAGE TO THE USER:\n<<<\n" + $final + "\n>>>")}]}' 2>/dev/null) || exit 0

  OBL_RAW=$(printf '%s' "$OBL_BODY" | ask_controller 2>/dev/null) || ctl_down
  [ -n "$OBL_RAW" ] || ctl_down
  ctl_up
  OBL_JSON=$(printf '%s' "$OBL_RAW" \
    | jq -r '[.content[]? | select(.type=="text") | .text] | join("")' 2>/dev/null) || exit 0
  OBL_JSON=$(printf '%s' "$OBL_JSON" | sed -E 's/^```[a-z]*//; s/```$//' | tr -d '\r')
  # Fail-open: no parseable answer — the obligation stays open, the counter does not grow.
  echo "$OBL_JSON" | jq -e 'has("ok")' >/dev/null 2>&1 || exit 0

  OBL_OK=$(echo "$OBL_JSON" | jq -r '.ok')
  OBL_REASON=$(echo "$OBL_JSON" | jq -r '.reason // ""')
  OBL_IMP=$(echo "$OBL_JSON" | jq -r '.impossible // false')

  if [ "$OBL_OK" = "true" ]; then
    rm -f "$OBL_FILE"
    obl_record met "$OBL_REASON" false
    exit 0
  fi

  # The agent hit a justified ban: release the pressure instead of pushing again at the same
  # spot. The cooldown also softens the next MISSED_ACTION into a lesson.
  if [ "$OBL_IMP" = "true" ]; then
    rm -f "$OBL_FILE"
    date +%s > "$STATE_DIR/$SESSION_ID.ctl-cooldown" 2>/dev/null
    obl_record impossible "$OBL_REASON" false
    exit 0
  fi

  # Ceiling. The judge sees only the current turn: work done a turn earlier does not exist for it,
  # and it may keep a compound obligation open forever. After MAX_ITER returns the expected value
  # of another push is zero — close it as stalled.
  if [ "$OBL_ITER" -ge "${HANDOFF_CTL_OBLIGATION_MAX_ITER:-3}" ]; then
    rm -f "$OBL_FILE"
    date +%s > "$STATE_DIR/$SESSION_ID.ctl-cooldown" 2>/dev/null
    obl_record stalled "$OBL_ITER returns did not move it: $OBL_REASON" false
    exit 0
  fi

  OBL_ITER=$(( OBL_ITER + 1 ))
  jq -nc --arg a "$OBL_ACTION" --arg w "$OBL_WHY" --argjson t "$OBL_SET" --argjson i "$OBL_ITER" \
    '{action:$a, why:$w, set_at:$t, iterations:$i}' > "$OBL_FILE" 2>/dev/null
  obl_record unmet "$OBL_REASON" true
  : > "$STATE_DIR/$SESSION_ID.by-control"

  jq -n --arg r "OBLIGATION FROM THE PREVIOUS TURN IS NOT CLOSED (hook stop-handoff-control, attempt $OBL_ITER):
[$OBL_ACTION]: $OBL_REASON

Do it now, in this same turn, and answer with the result. The user may be away from the
terminal — when they come back they should see finished work, not a promise.
If the action is truly impossible — it hits a ban, needs a live human or an unavailable
resource — say so in one line with proof (command + output): the obligation will be dropped
and the turn will not be returned again." \
    '{decision:"block", reason:$r}'
  exit 0
fi

BODY=$(jq -n --rawfile rubric "$RUBRIC" --rawfile final "$TMP_FINAL" \
  --arg model "$MODEL" --arg prompt "${USER_PROMPT:-—}" --arg tools "${TOOLS:-—}" \
  --arg waits "$WAITS" --arg wsum "$WAIT_SUM" --arg dur "${TURN_SEC:-0}" --arg fails "${FAILS:-—}" \
  '{model:$model, max_tokens:1000, system:$rubric,
    messages:[{role:"user", content:
      ("USER REQUEST THIS TURN:\n<<<\n" + $prompt + "\n>>>\n\n" +
       "TOOLS CALLED THIS TURN: " + $tools + "\n\n" +
       "CALL RESULTS:\n" + $fails + "\n\n" +
       "LONG FOREGROUND WAITS: " + $waits + " (total " + $wsum + " s), TURN DURATION: " + $dur + " s\n\n" +
       "FINAL MESSAGE TO THE USER:\n<<<\n" + $final + "\n>>>")}]}' \
  2>/dev/null) || exit 0

RAW=$(printf '%s' "$BODY" | ask_controller 2>/dev/null) || ctl_down
[ -n "$RAW" ] || ctl_down
ctl_up

VERDICT_JSON=$(printf '%s' "$RAW" \
  | jq -r '[.content[]? | select(.type=="text") | .text] | join("")' 2>/dev/null) || exit 0
# Judges sometimes wrap JSON in a markdown fence even when told not to.
VERDICT_JSON=$(printf '%s' "$VERDICT_JSON" | sed -E 's/^```[a-z]*//; s/```$//' | tr -d '\r')
echo "$VERDICT_JSON" | jq -e '.verdict and .confidence' >/dev/null 2>&1 || exit 0

VERDICT=$(echo "$VERDICT_JSON" | jq -r '.verdict')
CONF=$(echo "$VERDICT_JSON" | jq -r '.confidence')
WHY=$(echo "$VERDICT_JSON" | jq -r '.why // ""')
ACTION=$(echo "$VERDICT_JSON" | jq -r '.action // ""')
[[ "$CONF" =~ ^[0-9]*\.?[0-9]+$ ]] || exit 0

# The calibrator is asked only where its question is defined. DELAYED_ANSWER is not an evasion
# (the answer was delivered), so "evasion or not?" would say "no" and hide the lesson.
CALIB=""; CALIB_STATUS=""; CALIB_PROMPT="${HANDOFF_CTL_CALIB_PROMPT:-$RUBRIC_DIR/calibrator.md}"
case "$VERDICT" in
  MISSED_ACTION|DUMB_QUESTION)
    if [ "${HANDOFF_CTL_CALIB:-0}" != "0" ] && [ -f "$CALIB_PROMPT" ]; then
      CALIB_BODY=$(jq -n --rawfile sys "$CALIB_PROMPT" --rawfile final "$TMP_FINAL" \
        --arg model "${HANDOFF_CTL_CALIB_MODEL:-$MODEL}" \
        --arg prompt "${USER_PROMPT:-—}" --arg tools "${TOOLS:-—}" \
        '{model:$model, max_tokens:4, reasoning_effort:"none",
          logprobs:true, top_logprobs:8,
          messages:[{role:"system", content:$sys},
                    {role:"user", content:
                      ("USER REQUEST: " + $prompt + "\nTOOLS CALLED: " + $tools +
                       "\n\nFINAL:\n<<<\n" + $final + "\n>>>")}]}' 2>/dev/null)
      CALIB_RAW=$(printf '%s' "$CALIB_BODY" | ask_calibrator 2>/dev/null) || CALIB_RAW=""
      if [ -z "$CALIB_RAW" ]; then
        CALIB_STATUS="failed"
      else
        # Guard: if reasoning leaks back in, the distribution saturates and the number is useless.
        RT=$(printf '%s' "$CALIB_RAW" | jq -r '.usage.completion_tokens_details.reasoning_tokens // 0' 2>/dev/null)
        [[ "$RT" =~ ^[0-9]+$ ]] || RT=0
        if [ "$RT" -gt 0 ]; then
          CALIB_STATUS="reasoning_leaked"
        else
          CALIB=$(printf '%s' "$CALIB_RAW" | jq -r '
            (.choices[0].logprobs.content[0].top_logprobs // []) as $t
            | if ($t|length) == 0 then empty else
                ($t[0]) as $top
                | if   ($top.token|test("^[[:space:]]*(yes|Yes|YES)$")) then ($top.logprob|exp)
                  elif ($top.token|test("^[[:space:]]*(no|No|NO)$"))    then (1 - ($top.logprob|exp))
                  else empty end
                | .*1000|round/1000
              end' 2>/dev/null) || CALIB=""
          [ -n "$CALIB" ] && CALIB_STATUS="ok" || CALIB_STATUS="unparsed"
        fi
      fi
    fi
    ;;
esac

ABOVE=$(awk -v c="$CONF" -v t="$THRESHOLD" 'BEGIN{print (c+0 >= t+0) ? 1 : 0}')
# No "one block per session" limit: stop_hook_active already prevents a repeat inside one cascade,
# so the turn is returned at most once per user message plus one continuation.
BLOCKED=false
if [ "$VERDICT" != "OK" ] && [ "$ABOVE" = "1" ]; then
  case "$VERDICT" in
    MISSED_ACTION)
      # Debounce after a closed "impossible": while the window is fresh the verdict is a lesson.
      COOL=$(cat "$STATE_DIR/$SESSION_ID.ctl-cooldown" 2>/dev/null)
      [[ "$COOL" =~ ^[0-9]+$ ]] || COOL=0
      [ $(( $(date +%s) - COOL )) -ge "${HANDOFF_CTL_COOLDOWN:-600}" ] && BLOCKED=true
      ;;
    DELAYED_ANSWER) ;;
    *) BLOCKED=true ;;
  esac
fi

# Continuation after our own block: the cooldown does not apply — the agent was already pushed in
# this chain. Ceiling: one repeated return per chain.
if [ "$CONTINUED" != "0" ]; then
  BLOCKED=false
  { [ "$VERDICT" = "MISSED_ACTION" ] || [ "$VERDICT" = "DUMB_QUESTION" ] || [ "$VERDICT" = "UNFLAGGED_RISK" ]; } \
    && [ "$ABOVE" = "1" ] && [ "$CASCADE" -lt 2 ] && BLOCKED=true
fi

# The answer is already with the user: returning the turn would only prolong the wait. The lesson
# goes to the next turn via lesson-surface.sh; a lower threshold because a false lesson costs one
# line of context, not a returned turn.
if [ "$VERDICT" = "DELAYED_ANSWER" ]; then
  BLOCKED=false
  DELAYED_ABOVE=$(awk -v c="$CONF" -v t="${HANDOFF_CTL_DELAYED_THRESHOLD:-0.70}" 'BEGIN{print (c+0 >= t+0) ? 1 : 0}')
  [ "$DELAYED_ABOVE" = "1" ] && jq -nc --argjson ts "$(date +%s)" --arg w "$WHY" '{ts:$ts, why:$w}' \
    > "$STATE_DIR/$SESSION_ID.delayed" 2>/dev/null
fi

# Opt-in policy: the user wants commits handed over as a ready command in the dialog. A judge
# demanding "run the commit yourself" would break that policy, and the rubric alone does not hold
# it reliably. Only a commit demand is suppressed; any other demand next to the command still blocks.
SUPPRESSED=""
if [ "$BLOCKED" = "true" ] && [ "${HANDOFF_CTL_COMMIT_IN_DIALOG:-0}" = "1" ] \
   && printf '%s' "$LAST_TEXT" | command grep -qE 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit' \
   && printf '%s' "$ACTION" | command grep -qi 'commit'; then
  BLOCKED=false
  SUPPRESSED="commit_in_dialog"
fi

# Background work of this turn is still running: it cannot be awaited inside the turn, and its
# notification will open the next turn, which is judged in full. MISSED_ACTION only — background
# work does not excuse a filler question. The verdict travels as a bg_pending lesson.
if [ "$BLOCKED" = "true" ] && [ -z "$SUPPRESSED" ] && [ "$VERDICT" = "MISSED_ACTION" ] \
   && [ "$(bg_pending)" -gt 0 ]; then
  BLOCKED=false
  SUPPRESSED="bg_agents_pending"
fi

# Responsible zone: the agent did something dangerous after a spike and asks "ok / not ok" about
# the result — a legitimate handoff (rubric OK-6), not a filler question. The judge leans to
# DUMB_QUESTION when in doubt, so the flag is checked here by its shape. A marker without evidence
# and rollback suppresses nothing, otherwise it would be a universal bypass. Only the tail of the
# final outside ``` blocks counts: quoting the format in an explanation does not suppress.
# "Evidence:" must show a command and its result — a bare "checked" does not pass.
FLAG_TAIL=$(printf '%s' "$LAST_TEXT" | awk '/^[[:space:]]*```/{f=!f; next} !f' | tail -n 20)
# All parts must sit in one block: the marker line and the contiguous lines below it.
FLAG_BLOCK=$(printf '%s\n' "$FLAG_TAIL" | awk '/RESPONSIBLE ZONE/{b=""; on=1} on && /^[[:space:]]*$/{on=0} on{b=b $0 "\n"} END{printf "%s", b}')
# Not gated on BLOCKED: a legitimate flag below the threshold must not become a lesson either.
if [ -z "$SUPPRESSED" ] && [ "$VERDICT" = "DUMB_QUESTION" ] && [ -n "$FLAG_BLOCK" ] \
   && printf '%s' "$FLAG_BLOCK" | command grep -qE 'Evidence:.*(`[^`]+`|[^[:space:]]+[[:space:]].*(→|->|=>))' \
   && printf '%s' "$FLAG_BLOCK" | command grep -qE '(Rollback|Awaiting decision):[[:space:]]*[^[:space:]]{3,}'; then
  BLOCKED=false
  SUPPRESSED="responsible_flag_in_dialog"
fi

# No block — the verdict must not just sit in the log: the lesson reaches the next turn through
# lesson-surface.sh. Lower threshold for the same reason as DELAYED_ANSWER.
if { [ "$VERDICT" = "MISSED_ACTION" ] || [ "$VERDICT" = "DUMB_QUESTION" ] || [ "$VERDICT" = "UNFLAGGED_RISK" ]; } \
   && [ "$BLOCKED" != "true" ] \
   && { [ -z "$SUPPRESSED" ] || [ "$SUPPRESSED" = "bg_agents_pending" ]; }; then
  SOFT_ABOVE=$(awk -v c="$CONF" -v t="$SOFT_THRESHOLD" 'BEGIN{print (c+0 >= t+0) ? 1 : 0}')
  # The lesson names the real reason for not returning the turn.
  if [ "$SUPPRESSED" = "bg_agents_pending" ]; then REASON=bg_pending
  elif [ "$ABOVE" != "1" ]; then REASON=below
  elif [ "$CONTINUED" != "0" ]; then REASON=ceiling
  else REASON=cooldown
  fi
  [ "$SOFT_ABOVE" = "1" ] && jq -nc --argjson ts "$(date +%s)" --arg w "$WHY" --arg a "$ACTION" \
    --argjson cont "$CONTINUED" --arg r "$REASON" --arg v "$VERDICT" \
    '{ts:$ts, why:$w, action:$a, continued:$cont, reason:$r, verdict:$v}' > "$STATE_DIR/$SESSION_ID.missed" 2>/dev/null
fi

# Every verdict is logged: the OK/block distribution is what thresholds and the rubric are tuned on.
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$SESSION_ID" \
  --arg v "$VERDICT" --argjson c "$CONF" --arg w "$WHY" --arg a "$ACTION" \
  --argjson b "$BLOCKED" --arg sup "$SUPPRESSED" --arg t "$(printf '%s' "$LAST_TEXT" | head -c 400)" \
  --arg tr "${TRANSCRIPT:-}" --arg ln "${LINES:-}" \
  --arg cs "${CALIB_STATUS:-}" --arg cal "${CALIB:-}" --argjson cont "$CONTINUED" \
  '{ts:$ts,session:$s,verdict:$v,confidence:$c,why:$w,action:$a,blocked:$b,suppressed:$sup,
    transcript:$tr,lines:$ln,tail:$t}
   + (if $cont > 0 then {continued:$cont}        else {} end)
   + (if $cs  != "" then {calib_status:$cs}        else {} end)
   + (if $cal != "" then {calibrated:($cal|tonumber)} else {} end)' \
  >> "$HANDOFF_CTL_LOG" 2>/dev/null || true

[ "$BLOCKED" = "true" ] || exit 0

# A dangerous action in the push: a judge once demanded "delete it" from an agent that had
# misjudged liveness. The spike protocol is attached deterministically — LLM wording does not
# reproduce between runs. Two anchors: the judge's danger field and a word list over action/why.
DANGER=$(echo "$VERDICT_JSON" | jq -r '.danger // false' 2>/dev/null)
is_dangerous() {
  printf '%s' "$1" | command grep -qiE '\b(delet|remov|drop|purg|strip|cut out|rip out|clean ?up|prune)|dead code|\bdead\b|logic-crop'
}
DANGEROUS=false
{ [ "$DANGER" = "true" ] || is_dangerous "$ACTION $WHY"; } && DANGEROUS=true

date +%s > "$STATE_DIR/$SESSION_ID.controlled"
# Number of returns by this hook in the current stop chain: a continued turn is judged, but can be
# returned at most once more.
echo $(( ${CASCADE:-0} + 1 )) > "$STATE_DIR/$SESSION_ID.cascade"
# A returned turn opens an obligation: the next Stop asks "is the named action closed?" rather than
# "did it evade again?" — and keeps asking until it is. A dangerous action never becomes an
# obligation: after a spike the right outcome may be "alive — not deleting", and the obligation
# would repeat "delete" up to the ceiling.
[ "$VERDICT" = "MISSED_ACTION" ] && [ "$DANGEROUS" != "true" ] && jq -nc --arg a "$ACTION" --arg w "$WHY" \
  --argjson t "$(date +%s)" '{action:$a, why:$w, set_at:$t, iterations:0}' \
  > "$STATE_DIR/$SESSION_ID.obligation" 2>/dev/null
: > "$STATE_DIR/$SESSION_ID.by-control"

DANGER_PROTOCOL="
The action is dangerous — spike first, then decide:
1. Check liveness with tools: find every reference (grep across the whole repo, call graph /
   LSP references, dead-code analyzer, dynamic lookups such as templates or reflection).
   \"Not referenced\" through one channel is not proof.
2. ALIVE in any channel → do not delete; report where it is used.
3. DEAD in every channel → do it and end the final with a block:
   ⚠️ RESPONSIBLE ZONE — <what was removed>
      Evidence: \`<command>\` → <result>
      Rollback: <command>
      Ok / not ok?
4. UNKNOWN or irreversible → do not do it; ask with AskUserQuestion and show the evidence."

if [ "$VERDICT" = "UNFLAGGED_RISK" ]; then
  REASON="TURN HANDOFF CONTROL (hook stop-handoff-control, verdict $VERDICT, confidence $CONF):
a dangerous operation was handed over without a responsible-zone flag.

Why: $WHY
Action: Do not roll back. $ACTION
$DANGER_PROTOCOL"
else
  REASON="TURN HANDOFF CONTROL (hook stop-handoff-control, verdict $VERDICT, confidence $CONF):
the turn was handed back with an excuse although the action was available to you.

Why: $WHY
Action: $ACTION

Do it now, in this same turn, and answer with the result. The user may be away from the
terminal — when they come back they should see finished work, not a question.
If the action is truly impossible, say in one line what exactly failed (command + output),
and only then hand the turn back."
  [ "$DANGEROUS" = "true" ] && REASON="$REASON
$DANGER_PROTOCOL"
fi

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
