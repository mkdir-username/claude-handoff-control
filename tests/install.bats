#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  export HOME="$BATS_TEST_TMPDIR/h"
  mkdir -p "$HOME/.claude"
  S="$HOME/.claude/settings.json"
  DEST="$HOME/.claude/handoff-control"
}

cmds() { jq -r --arg e "$1" '[.hooks[$e][]?.hooks[]?.command] | .[]' "$S"; }

@test "install into missing settings.json registers one Stop and two UserPromptSubmit hooks" {
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [ "$(cmds Stop)" = "bash \"$DEST/hooks/stop-handoff-control.sh\"" ]
  [ "$(cmds UserPromptSubmit | grep -c "$DEST/hooks/")" -eq 2 ]
  [ -x "$DEST/hooks/stop-handoff-control.sh" ] || [ -f "$DEST/hooks/stop-handoff-control.sh" ]
  [ -f "$DEST/rubrics/handoff-control.md" ]
  [ -f "$DEST/hooks/lib/secret-patterns.sh" ]
}

@test "existing foreign hooks and settings are preserved" {
  jq -n '{model:"opus", hooks:{Stop:[{hooks:[{type:"command",command:"bash /x/other-stop.sh"}]}],
          PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash /x/pre.sh"}]}]}}' > "$S"
  bash "$REPO/install.sh" >/dev/null
  cmds Stop | grep -qx 'bash /x/other-stop.sh'
  [ "$(cmds Stop | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(jq -r '.model' "$S")" = "opus" ]
  [ "$(cmds PreToolUse)" = "bash /x/pre.sh" ]
}

@test "second install does not duplicate entries" {
  bash "$REPO/install.sh" >/dev/null
  bash "$REPO/install.sh" >/dev/null
  [ "$(cmds Stop | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cmds UserPromptSubmit | wc -l | tr -d ' ')" -eq 2 ]
}

@test "install backs up an existing settings.json" {
  echo '{"model":"x"}' > "$S"
  bash "$REPO/install.sh" >/dev/null
  ls "$HOME/.claude"/settings.json.bak-* >/dev/null
  [ "$(jq -r .model "$(ls "$HOME/.claude"/settings.json.bak-* | head -1)")" = "x" ]
}

@test "install refuses invalid settings.json without touching it" {
  echo '{broken' > "$S"
  run bash "$REPO/install.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$S")" = "{broken" ]
}

@test "uninstall removes only its own entries and its directory" {
  jq -n '{hooks:{Stop:[{hooks:[{type:"command",command:"bash /x/other-stop.sh"}]}]}}' > "$S"
  bash "$REPO/install.sh" >/dev/null
  run bash "$REPO/uninstall.sh"
  [ "$status" -eq 0 ]
  [ "$(cmds Stop)" = "bash /x/other-stop.sh" ]
  [ -z "$(cmds UserPromptSubmit)" ]
  [ ! -d "$DEST" ]
}

@test "missing jq — exit 1 with a message" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in bash cp mkdir rm mv date cat chmod dirname; do ln -s "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
  run env PATH="$BATS_TEST_TMPDIR/bin" bash "$REPO/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq"* ]]
}

@test "installed hook runs end-to-end with a stub judge" {
  bash "$REPO/install.sh" >/dev/null
  printf '#!/bin/sh\ncat >/dev/null\necho %s\n' \
    "'{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"verdict\\\":\\\"DUMB_QUESTION\\\",\\\"confidence\\\":0.95,\\\"why\\\":\\\"w\\\",\\\"action\\\":\\\"Run the tests\\\"}\"}]}'" \
    > "$BATS_TEST_TMPDIR/judge"
  chmod +x "$BATS_TEST_TMPDIR/judge"
  run bash -c 'jq -n "{last_assistant_message:\"Want me to run the tests?\", stop_hook_active:false, session_id:\"s1\"}" \
    | HANDOFF_CTL_CMD="$0" bash "$1"' "$BATS_TEST_TMPDIR/judge" "$DEST/hooks/stop-handoff-control.sh"
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -r .reason | grep -q 'Run the tests'
}

@test "uninstall that cannot rewrite settings.json keeps the installed hooks" {
  bash "$REPO/install.sh" >/dev/null
  echo '{"hooks":"not-an-object"}' > "$S"
  run bash "$REPO/uninstall.sh"
  [ "$status" -eq 1 ]
  [ -d "$DEST/hooks" ]
  [ "$(jq -r .hooks "$S")" = "not-an-object" ]
}
