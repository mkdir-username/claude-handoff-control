#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../hooks/lib"
  export HANDOFF_CTL_HOME="$BATS_TEST_TMPDIR/home"
}

@test "rewake guard: stop_hook_active=true without pending wake-up → skip (0)" {
  source "$LIB/stop-rewake-guard.sh"
  run stop_rewake_should_skip true sid1 handoff-control
  [ "$status" -eq 0 ]
}

@test "rewake guard: stop_hook_active=false → judge (1)" {
  source "$LIB/stop-rewake-guard.sh"
  run stop_rewake_should_skip false sid1 handoff-control
  [ "$status" -eq 1 ]
}

@test "rewake guard: fresh pending wake-up is judged once, then skipped" {
  source "$LIB/stop-rewake-guard.sh"
  mkdir -p "$HANDOFF_CTL_HOME/rewake"
  date +%s > "$HANDOFF_CTL_HOME/rewake/sid2.rewake-pending"
  run stop_rewake_should_skip true sid2 handoff-control
  [ "$status" -eq 1 ]
  run stop_rewake_should_skip true sid2 handoff-control
  [ "$status" -eq 0 ]
}

@test "mask_secrets hides Anthropic and GitHub tokens" {
  source "$LIB/secret-patterns.sh"
  out=$(printf 'key sk-ant-api03-abcdefghijklmnopqrstuvwx and ghp_%s\n' "$(printf 'a%.0s' {1..36})" | mask_secrets)
  [[ "$out" != *sk-ant-api03* ]]
  [[ "$out" != *ghp_aaaa* ]]
  [[ "$out" == *"***"* ]]
}

@test "mask_secrets hides key=value but keeps \$VAR references" {
  source "$LIB/secret-patterns.sh"
  out=$(printf 'API_KEY=supersecret123 TOKEN=$MY_TOKEN\n' | mask_secrets)
  [[ "$out" == *"API_KEY=***"* ]]
  [[ "$out" == *'TOKEN=$MY_TOKEN'* ]]
}

@test "long_wait_seconds returns the largest sleep, ignores timeout" {
  source "$LIB/long-wait-detect.sh"
  [ "$(long_wait_seconds 'sleep 5; sleep 30')" = 30 ]
  [ "$(long_wait_seconds 'timeout 40 curl x')" = 0 ]
}
