#!/usr/bin/env bats

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/lesson-surface.sh"
  export HANDOFF_CTL_HOME="$BATS_TEST_TMPDIR/home"
  export HANDOFF_CTL_LOG="$BATS_TEST_TMPDIR/verdicts.jsonl"
  ST="$HANDOFF_CTL_HOME/state"
  mkdir -p "$ST"
}

fire() { echo '{"session_id":"t1"}' | bash "$HOOK"; }
ctx()  { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'; }

@test "a fresh DELAYED marker is delivered once and consumed" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"sleep 60 probes after a ready answer"}' > "$ST/t1.delayed"
  run fire
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"ANSWER DELAYED"* ]]
  [[ "$(ctx)" == *"sleep 60"* ]]
  [ ! -f "$ST/t1.delayed" ]
  run fire
  [ -z "$output" ]
}

@test "a stale marker is dropped silently" {
  jq -nc '{ts:1, why:"x"}' > "$ST/t1.delayed"
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$ST/t1.delayed" ]
}

@test "no marker — silence" {
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test ".missed delivers the MISSED_ACTION lesson and is consumed" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"announced a step and ended the turn", action:"Finish the build"}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"TURN HANDED BACK UNFINISHED"* ]]
  [[ "$(ctx)" == *"Finish the build"* ]]
  [ ! -f "$ST/t1.missed" ]
  run fire
  [ -z "$output" ]
}

@test "bg_pending lesson names background work, not the threshold" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"waited for critics", action:"Collect output", reason:"bg_pending"}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"background work"* ]]
  [[ "$(ctx)" != *"below the block threshold"* ]]
}

@test "a stale .missed is dropped silently" {
  jq -nc '{ts:1, why:"x", action:"y"}' > "$ST/t1.missed"
  run fire
  [ -z "$output" ]
  [ ! -f "$ST/t1.missed" ]
}

@test "an open obligation is a reminder and is NOT consumed" {
  jq -nc --argjson ts "$(date +%s)" '{action:"Finish the build", why:"announced", set_at:$ts, iterations:1}' > "$ST/t1.obligation"
  run fire
  [[ "$(ctx)" == *"OBLIGATION OPEN"* ]]
  [[ "$(ctx)" == *"Finish the build"* ]]
  [ -s "$ST/t1.obligation" ]
}

@test "lesson and open obligation arrive together in one block" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"postponed again", action:"Run the tests"}' > "$ST/t1.missed"
  jq -nc --argjson ts "$(date +%s)" '{action:"Finish the build", why:"announced", set_at:$ts, iterations:2}' > "$ST/t1.obligation"
  run fire
  [[ "$(ctx)" == *"Run the tests"* ]]
  [[ "$(ctx)" == *"Finish the build"* ]]
}

@test "a new user message supersedes the obligation" {
  jq -nc --argjson ts "$(date +%s)" '{action:"Finish the build", why:"announced", set_at:$ts, iterations:2}' > "$ST/t1.obligation"
  run bash -c 'echo "{\"session_id\":\"t1\",\"prompt\":\"switch to the demo now\"}" | bash "$0"' "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"OBLIGATION OPEN"* ]]
  [ ! -f "$ST/t1.obligation" ]
  [ "$(jq -r '.outcome' "$HANDOFF_CTL_LOG")" = "superseded" ]
}

@test "a background-task notification does not supersede the obligation" {
  jq -nc --argjson ts "$(date +%s)" '{action:"Finish the build", why:"announced", set_at:$ts, iterations:1}' > "$ST/t1.obligation"
  run bash -c 'jq -nc "{session_id:\"t1\", prompt:\"<task-notification>\n<task-id>b1</task-id>\"}" | bash "$0"' "$HOOK"
  [[ "$(ctx)" == *"OBLIGATION OPEN"* ]]
  [ -s "$ST/t1.obligation" ]
}

@test "lesson of a continued turn says the turn was already returned" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"announced", action:"do it", continued:2}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"already returned"* ]]
  [[ "$(ctx)" != *"below the block threshold"* ]]
}

@test "cooldown lesson names the pause, not the threshold" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"announced", action:"do it", continued:0, reason:"cooldown"}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"pause"* ]]
  [[ "$(ctx)" != *"below the block threshold"* ]]
}

@test "below-threshold lesson says so" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"announced", action:"do it", continued:0, reason:"below"}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"below the block threshold"* ]]
}

@test "UNFLAGGED_RISK lesson demands the responsible-zone flag, not 'finish it'" {
  jq -nc --argjson ts "$(date +%s)" '{ts:$ts, why:"deleted without checking", action:"Add the flag", continued:0, reason:"below", verdict:"UNFLAGGED_RISK"}' > "$ST/t1.missed"
  run fire
  [[ "$(ctx)" == *"DANGEROUS CHANGE WITHOUT A FLAG"* ]]
  [[ "$(ctx)" == *"Do not roll back"* ]]
  [[ "$(ctx)" != *"TURN HANDED BACK UNFINISHED"* ]]
}
