#!/usr/bin/env bats

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/prompt-cache.sh"
  export HANDOFF_CTL_HOME="$BATS_TEST_TMPDIR/home"
}

@test "stores the user prompt for the Stop hook" {
  jq -nc '{session_id:"t1", prompt:"fix the login test"}' | bash "$HOOK"
  [ "$(cat "$HANDOFF_CTL_HOME/prompts/t1.last-prompt")" = "fix the login test" ]
}

@test "a background-task notification is not a user prompt" {
  jq -nc '{session_id:"t1", prompt:"fix it"}' | bash "$HOOK"
  jq -nc '{session_id:"t1", prompt:"<task-notification>\n<status>completed</status>"}' | bash "$HOOK"
  [ "$(cat "$HANDOFF_CTL_HOME/prompts/t1.last-prompt")" = "fix it" ]
}

@test "empty prompt — nothing written, exit 0" {
  run bash -c 'echo "{\"session_id\":\"t1\"}" | bash "$0"' "$HOOK"
  [ "$status" -eq 0 ]
  [ ! -f "$HANDOFF_CTL_HOME/prompts/t1.last-prompt" ]
}

@test "prompts older than two days are swept" {
  mkdir -p "$HANDOFF_CTL_HOME/prompts"
  : > "$HANDOFF_CTL_HOME/prompts/old.last-prompt"
  touch -t 202001010000 "$HANDOFF_CTL_HOME/prompts/old.last-prompt"
  jq -nc '{session_id:"t1", prompt:"x"}' | bash "$HOOK"
  [ ! -f "$HANDOFF_CTL_HOME/prompts/old.last-prompt" ]
}

@test "session id with path characters stays inside the prompts dir" {
  jq -nc '{session_id:"../../evil", prompt:"x"}' | bash "$HOOK"
  [ ! -e "$HANDOFF_CTL_HOME/evil.last-prompt" ]
  [ -f "$HANDOFF_CTL_HOME/prompts/default.last-prompt" ]
}
