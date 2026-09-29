#!/usr/bin/env bats

setup() {
  R="$BATS_TEST_DIRNAME/../rubrics"
  HOOK="$BATS_TEST_DIRNAME/../hooks/stop-handoff-control.sh"
}

@test "all three rubrics exist" {
  [ -s "$R/handoff-control.md" ] && [ -s "$R/obligation.md" ] && [ -s "$R/calibrator.md" ]
}

@test "controller rubric names every verdict and the JSON schema" {
  for v in OK DUMB_QUESTION MISSED_ACTION DELAYED_ANSWER UNFLAGGED_RISK; do grep -q "$v" "$R/handoff-control.md"; done
  grep -q '"verdict":' "$R/handoff-control.md"
  grep -q '"danger":' "$R/handoff-control.md"
}

@test "obligation rubric defines ok/reason/impossible" {
  grep -q '"ok":true|false' "$R/obligation.md"
  grep -q '"impossible":' "$R/obligation.md"
}

@test "calibrator answers yes or no" {
  grep -q 'yes or no' "$R/calibrator.md"
}

@test "rubrics contain no Cyrillic" {
  run perl -CSD -ne 'print if /\p{Cyrillic}/' "$R"/*.md
  [ -z "$output" ]
}

@test "field headers the rubric refers to are the ones the hook sends" {
  for h in 'USER REQUEST THIS TURN' 'TOOLS CALLED THIS TURN' 'CALL RESULTS' 'BLOCKED BY HOOKS' \
           'FAILED CALLS' 'LONG FOREGROUND WAITS' 'TURN DURATION' 'turn transcript unavailable'; do
    grep -q "$h" "$R/handoff-control.md"
    grep -q "$h" "$HOOK"
  done
  grep -q 'OPEN OBLIGATION' "$R/obligation.md"
  grep -q 'OPEN OBLIGATION FROM PREVIOUS TURN' "$HOOK"
}

@test "the obligation marker never appears in the controller rubric (mock routing depends on it)" {
  ! grep -q 'OPEN OBLIGATION FROM PREVIOUS TURN' "$R/handoff-control.md"
}
