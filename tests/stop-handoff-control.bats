#!/usr/bin/env bats
# stop-handoff-control.sh — LLM judge of turn handoff on Stop.
# The judge is replaced via $HANDOFF_CTL_CMD: the live API is expensive and nondeterministic, and
# what is tested here is the hook's logic. A live run over the fixture corpus is gated by
# HANDOFF_CTL_LIVE=1.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/stop-handoff-control.sh"
  FX="$BATS_TEST_DIRNAME/fixtures"
  export HANDOFF_CTL_HOME="$BATS_TEST_TMPDIR/home"
  ST="$HANDOFF_CTL_HOME/state"
  export HANDOFF_CTL_LOG="$BATS_TEST_TMPDIR/verdicts.jsonl"
  export HANDOFF_CTL_DOWN_FILE="$BATS_TEST_TMPDIR/ctl-down"
  unset ANTHROPIC_API_KEY HANDOFF_CTL_API_KEY HANDOFF_CTL_CALIB HANDOFF_CTL_COMMIT_IN_DIALOG
  mkdir -p "$ST" "$HANDOFF_CTL_HOME/prompts"
}

# Judge mock: stores the request body in body.json and answers with the given JSON.
mkcontrol() {
  {
    echo '#!/bin/sh'
    echo "cat > \"$BATS_TEST_TMPDIR/body.json\""
    printf 'cat <<%s\n%s\n%s\n' "'JSONEOF'" "$1" "JSONEOF"
  } > "$BATS_TEST_TMPDIR/controller"
  chmod +x "$BATS_TEST_TMPDIR/controller"
  export HANDOFF_CTL_CMD="$BATS_TEST_TMPDIR/controller"
}

# Anthropic-shaped answer; a thinking block first, as reasoning models send it.
verdict() {
  jq -nc --arg v "$1" --argjson c "$2" --arg w "${3:-why}" --arg a "${4:-action}" \
    '{content:[{type:"thinking",thinking:"reasoning"},
               {type:"text",text:({verdict:$v,confidence:$c,why:$w,action:$a}|tostring)}]}'
}

# Mock with two answers: the obligation branch sends a different request and expects
# {ok,reason,impossible}.
mkcontrol2() {
  {
    echo '#!/bin/sh'
    echo "cat > \"$BATS_TEST_TMPDIR/body.json\""
    echo "if grep -q 'OPEN OBLIGATION FROM PREVIOUS TURN' \"$BATS_TEST_TMPDIR/body.json\"; then"
    printf 'cat <<%s\n%s\n%s\n' "'OBLEOF'" "$2" "OBLEOF"
    echo "else"
    printf 'cat <<%s\n%s\n%s\n' "'VEREOF'" "$1" "VEREOF"
    echo "fi"
  } > "$BATS_TEST_TMPDIR/controller"
  chmod +x "$BATS_TEST_TMPDIR/controller"
  export HANDOFF_CTL_CMD="$BATS_TEST_TMPDIR/controller"
}

obligation() {
  jq -nc --argjson ok "$1" --arg r "${2:-reason}" --argjson imp "${3:-false}" \
    '{content:[{type:"text",text:({ok:$ok,reason:$r,impossible:$imp}|tostring)}]}'
}

inp() {
  jq -n --arg m "$1" --argjson a "${2:-false}" \
    '{last_assistant_message:$m, stop_hook_active:$a, session_id:"t1"}'
}

run_hook() { inp "$1" "${2:-false}" | bash "$HOOK"; }

# Chain after our own block: .by-control alive, .cascade = number of blocks in the chain.
in_cascade() { : > "$ST/t1.by-control"; echo "$1" > "$ST/t1.cascade"; }

# ── cascade ────────────────────────────────────────────────────────────────────────────────

@test "a block opens the chain counter .cascade = 1" {
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  run_hook 'Next I will move the guard.' >/dev/null
  [ "$(cat "$ST/t1.cascade")" = "1" ]
}

@test "continuation after own block: MISSED_ACTION returns the turn a second time" {
  in_cascade 1
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced instead of acting' 'Run the search')"
  run run_hook '👉 Next: starting the log search.' true
  echo "$output" | jq -e '.decision == "block"'
  [ "$(cat "$ST/t1.cascade")" = "2" ]
}

@test "continuation after own block: DUMB_QUESTION returns the turn despite .controlled" {
  in_cascade 1; echo 1 > "$ST/t1.controlled"
  mkcontrol "$(verdict DUMB_QUESTION 0.95)"
  run run_hook '👉 Next: do X?' true
  echo "$output" | jq -e '.decision == "block"'
}

@test "continuation without own block (.by-control absent) — silent, judge not called" {
  mkcontrol "$(verdict MISSED_ACTION 0.99)"
  run run_hook '👉 Next: starting X.' true
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/body.json" ]
}

@test "continuation: an open obligation is not checked, the final is judged" {
  in_cascade 1
  jq -nc --argjson t "$(date +%s)" '{action:"a",why:"w",set_at:$t,iterations:0}' > "$ST/t1.obligation"
  mkcontrol "$(verdict OK 0.9)"
  run run_hook 'Did the search, here is the result.' true
  [ -f "$BATS_TEST_TMPDIR/body.json" ]
  [ "$(grep -c 'OPEN OBLIGATION FROM PREVIOUS TURN' "$BATS_TEST_TMPDIR/body.json")" -eq 0 ]
  [ -s "$ST/t1.obligation" ]
}

@test "third stop in a chain — no return, lesson goes to .missed with continued" {
  in_cascade 2
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced again' 'Run the search')"
  run run_hook '👉 Next: starting the search.' true
  [[ "$output" != *decision* ]]
  jq -e '.continued == 2' "$ST/t1.missed"
}

@test "continuation is logged with a continued field" {
  in_cascade 1
  mkcontrol "$(verdict OK 0.9)"
  run_hook 'Done, here is the output.' true >/dev/null
  tail -1 "$HANDOFF_CTL_LOG" | jq -e '.continued == 1'
}

@test "stop_hook_active=true — silent (anti-loop)" {
  mkcontrol "$(verdict DUMB_QUESTION 0.99)"
  run run_hook 'Continue?' true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop_hook_active=true after an external wake-up — judged once (rewake marker)" {
  mkdir -p "$HANDOFF_CTL_HOME/rewake"
  date +%s > "$HANDOFF_CTL_HOME/rewake/t1.rewake-pending"
  mkcontrol "$(verdict DUMB_QUESTION 0.99)"
  run run_hook 'Continue?' true
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision"'
  run run_hook 'Continue?' true
  echo "$output" | grep -q '"decision"'
  run run_hook 'Continue?' true
  [ -z "$output" ]
}

@test "a stale wake-up marker does not divert the own-block continuation into the obligation" {
  mkdir -p "$HANDOFF_CTL_HOME/rewake"
  echo $(( $(date +%s) - 800 )) > "$HANDOFF_CTL_HOME/rewake/t1.rewake-pending"
  mkcontrol2 "$(verdict MISSED_ACTION 0.95 'waiting for critics' 'Collect the output')" "$(obligation false 'not closed')"
  run run_hook 'Waiting for critics.' false
  echo "$output" | jq -e '.decision == "block"'
  run run_hook 'Result not available yet.' true
  [ "$(jq -s -r '.[-1].verdict' "$HANDOFF_CTL_LOG")" = MISSED_ACTION ]
  jq -s -e '.[-1].continued == 1' "$HANDOFF_CTL_LOG"
}

# ── fail-open and provider ─────────────────────────────────────────────────────────────────

@test "judge unavailable — fail-open, turn not blocked" {
  export HANDOFF_CTL_CMD=/nonexistent/controller
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'decision'
}

@test "no API key and no stub — exit 0, empty stdout" {
  unset HANDOFF_CTL_CMD
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "judge silent twice in a row — visible warning naming the key, turn not blocked" {
  export HANDOFF_CTL_CMD=/nonexistent/controller
  run run_hook 'Continue?'
  [ -z "$output" ]
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.systemMessage | test("unreachable") and test("HANDOFF_CTL_API_KEY")'
  ! echo "$output" | grep -q 'decision'
}

@test "silent-judge warning at most once per 30 minutes" {
  export HANDOFF_CTL_CMD=/nonexistent/controller
  run run_hook 'a'; run run_hook 'b'
  echo "$output" | grep -q systemMessage
  run run_hook 'c'
  [ -z "$output" ]
}

@test "API error body (bad key) counts as judge down and surfaces the warning" {
  mkcontrol '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'
  run run_hook 'Continue?'
  [ -z "$output" ]
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.systemMessage | test("invalid x-api-key")'
  ! echo "$output" | grep -q 'decision'
}

@test "judge answers again — silence counter reset" {
  export HANDOFF_CTL_CMD=/nonexistent/controller
  run run_hook 'a'
  [ -f "$HANDOFF_CTL_DOWN_FILE" ]
  mkcontrol "$(verdict OK 0.95)"
  run run_hook 'a'
  [ ! -f "$HANDOFF_CTL_DOWN_FILE" ]
}

@test "invalid JSON from the judge — fail-open" {
  mkcontrol 'not json at all'
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'decision'
}

@test "non-numeric confidence — fail-open" {
  mkcontrol "$(jq -nc '{content:[{type:"text",text:({verdict:"DUMB_QUESTION",confidence:"high"}|tostring)}]}')"
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'decision'
}

@test "answer without a thinking block (non-reasoning model) is parsed" {
  mkcontrol "$(jq -nc '{content:[{type:"text",text:({verdict:"DUMB_QUESTION",confidence:0.95,why:"w",action:"a"}|tostring)}]}')"
  run run_hook 'Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "answer wrapped in a markdown fence is parsed" {
  mkcontrol "$(jq -nc '{content:[{type:"text",text:("```json\n" + ({verdict:"DUMB_QUESTION",confidence:0.95}|tostring) + "\n```")}]}')"
  run run_hook 'Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "request body carries the configured model" {
  export HANDOFF_CTL_MODEL=my-judge-model
  mkcontrol "$(verdict OK 0.99)"
  run_hook 'Done.' >/dev/null
  jq -e '.model == "my-judge-model"' "$BATS_TEST_TMPDIR/body.json"
}

@test "live path posts to HANDOFF_CTL_API_URL with x-api-key" {
  unset HANDOFF_CTL_CMD
  export HANDOFF_CTL_API_KEY=sk-test-key NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  export HANDOFF_CTL_API_URL="http://127.0.0.1:$PORT/v1/messages"
  timeout 15 python3 - "$PORT" "$BATS_TEST_TMPDIR/hit" 3>&- <<'PY' &
import http.server, sys
port, hit = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length') or 0))
        open(hit, 'w').write(f"{self.path} {self.headers.get('x-api-key')} {self.headers.get('anthropic-version')}")
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"content":[{"type":"text","text":"{\\"verdict\\":\\"OK\\",\\"confidence\\":0.9}"}]}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).handle_request()
PY
  sleep 0.3
  run run_hook 'Continue?'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/hit")" = "/v1/messages sk-test-key 2023-06-01" ]
}

@test "ANTHROPIC_API_KEY is the fallback key" {
  unset HANDOFF_CTL_CMD
  export ANTHROPIC_API_KEY=sk-fallback NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  export HANDOFF_CTL_API_URL="http://127.0.0.1:$PORT/v1/messages"
  timeout 15 python3 - "$PORT" "$BATS_TEST_TMPDIR/hit" 3>&- <<'PY' &
import http.server, sys
port, hit = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length') or 0))
        open(hit, 'w').write(self.headers.get('x-api-key'))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).handle_request()
PY
  sleep 0.3
  run run_hook 'Continue?'
  [ "$(cat "$BATS_TEST_TMPDIR/hit")" = "sk-fallback" ]
}

@test "bypass file skips the judge once" {
  mkcontrol "$(verdict DUMB_QUESTION 0.99)"
  : > "$HANDOFF_CTL_HOME/skip"
  run run_hook 'Continue?'
  [[ "$output" != *decision* ]]
  [ ! -f "$HANDOFF_CTL_HOME/skip" ]
  run run_hook 'Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

# ── verdicts and thresholds ────────────────────────────────────────────────────────────────

@test "DUMB_QUESTION 0.97 — returns the turn, reason carries the judge's action" {
  mkcontrol "$(verdict DUMB_QUESTION 0.97 'named a default and handed back' 'Take user-42 and continue the login')"
  run run_hook 'Name the user, otherwise I take user-42.'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -r .reason | grep -q 'user-42'
}

@test "confidence 0.8 — below threshold, turn not returned" {
  mkcontrol "$(verdict DUMB_QUESTION 0.8)"
  run run_hook 'Map or Redis — both cover the scenario.'
  ! echo "$output" | grep -q 'decision'
}

@test "OK — silent" {
  mkcontrol "$(verdict OK 0.99 'needs approval' '-')"
  run run_hook 'Waiting for PR approval.'
  ! echo "$output" | grep -q 'decision'
}

@test "every verdict goes to the log" {
  mkcontrol "$(verdict OK 0.99)"
  run_hook 'Done.' >/dev/null
  grep -q '"verdict":"OK"' "$HANDOFF_CTL_LOG"
}

@test "DUMB_QUESTION in the next user turn returns the turn again" {
  mkcontrol "$(verdict DUMB_QUESTION 0.97)"
  run_hook 'Continue?' >/dev/null
  rm -f "$ST/t1.by-control" "$ST/t1.cascade"
  run run_hook 'Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "a block sets .controlled and .by-control" {
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  run_hook 'Next I will move the guard.' >/dev/null
  [ -s "$ST/t1.controlled" ]
  [ -f "$ST/t1.by-control" ]
}

# ── commit policy (opt-in) ─────────────────────────────────────────────────────────────────

COMMIT_FINAL='Tests are green.

```bash
git -C /r add a.sh && git -C /r commit -m "fix(hooks): guard P11"
```'

@test "commit policy off (default): judge demanding the commit blocks" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'prepared commits and handed them over' 'Run both git add/commit yourself')"
  run run_hook "$COMMIT_FINAL"
  echo "$output" | jq -e '.decision == "block"'
}

@test "commit policy on: judge demanding the commit — turn not returned" {
  export HANDOFF_CTL_COMMIT_IN_DIALOG=1
  mkcontrol "$(verdict MISSED_ACTION 0.95 'prepared commits and handed them over' 'Run both git add/commit yourself')"
  run run_hook "$COMMIT_FINAL"
  [ "$status" -eq 0 ]
  [[ "$output" != *decision* ]]
  grep -q '"suppressed":"commit_in_dialog"' "$HANDOFF_CTL_LOG"
}

@test "commit policy on: judge demanding something else — block stays" {
  export HANDOFF_CTL_COMMIT_IN_DIALOG=1
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a run and did not do it' 'Run the bats suite')"
  run run_hook "$COMMIT_FINAL"
  echo "$output" | jq -e '.decision == "block"'
}

@test "commit policy on: suppressed commit produces neither block nor lesson" {
  export HANDOFF_CTL_COMMIT_IN_DIALOG=1
  mkcontrol "$(verdict MISSED_ACTION 0.95 'prepared a commit' 'Run git commit yourself')"
  run run_hook "$COMMIT_FINAL"
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.missed" ]
}

# ── request body ───────────────────────────────────────────────────────────────────────────

@test "user prompt and turn tools go into the request body" {
  mkcontrol "$(verdict OK 0.99)"
  printf 'how does trace differ from callers?' > "$HANDOFF_CTL_HOME/prompts/t1.last-prompt"
  run_hook 'There is a difference: trace bridges dynamic hops.' >/dev/null
  grep -q 'USER REQUEST THIS TURN' "$BATS_TEST_TMPDIR/body.json"
  grep -q 'trace differ' "$BATS_TEST_TMPDIR/body.json"
  grep -q 'TOOLS CALLED THIS TURN' "$BATS_TEST_TMPDIR/body.json"
}

@test "a long final is cut to its tail" {
  mkcontrol "$(verdict OK 0.99)"
  local filler
  filler=$(for i in $(seq 1 300); do echo "report line number $i, nothing important"; done)
  local long_final="START-OF-WALL-abc123
${filler}
👉 END-OF-FINAL-xyz789: deploy to staging?"
  run run_hook "$long_final"
  [ "$status" -eq 0 ]
  grep -q "END-OF-FINAL-xyz789" "$BATS_TEST_TMPDIR/body.json"
  ! grep -q "START-OF-WALL-abc123" "$BATS_TEST_TMPDIR/body.json"
}

@test "tool names are pulled from the turn transcript" {
  mkcontrol "$(verdict OK 0.99)"
  TR="$BATS_TEST_TMPDIR/transcript.jsonl"
  jq -nc '{type:"user",message:{content:"fix the guard"}}'                                  >  "$TR"
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Edit"}]}}'            >> "$TR"
  jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"ok"}]}}'             >> "$TR"
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash"}]}}'            >> "$TR"
  jq -n --arg m 'Done, the guard is in place.' --arg t "$TR" \
    '{last_assistant_message:$m, stop_hook_active:false, session_id:"t1", transcript_path:$t}' \
    | bash "$HOOK" >/dev/null
  grep -q 'Bash,Edit' "$BATS_TEST_TMPDIR/body.json"
}

@test "judge gets the number of long waits and the turn duration" {
  mkcontrol "$(verdict OK 0.99)"
  TR="$BATS_TEST_TMPDIR/transcript.jsonl"
  jq -nc '{type:"user",timestamp:"2026-09-13T15:10:00.000Z",message:{content:"is it used?"}}' > "$TR"
  jq -nc '{type:"assistant",timestamp:"2026-09-13T15:10:05.000Z",message:{content:[{type:"tool_use",name:"Bash",input:{command:"rg -l morph ~/.mcp.json"}}]}}' >> "$TR"
  jq -nc '{type:"assistant",timestamp:"2026-09-13T15:11:20.000Z",message:{content:[{type:"tool_use",name:"Bash",input:{command:"{ sleep 60; } | morph-mcp"}}]}}' >> "$TR"
  jq -nc '{type:"assistant",timestamp:"2026-09-13T15:12:40.000Z",message:{content:[{type:"tool_use",name:"Bash",input:{command:"sleep 90",run_in_background:true}}]}}' >> "$TR"
  jq -n --arg m 'Not used since February.' --arg t "$TR" \
    '{last_assistant_message:$m, stop_hook_active:false, session_id:"t1", transcript_path:$t}' \
    | bash "$HOOK" >/dev/null
  grep -q 'LONG FOREGROUND WAITS: 1 (total 60 s)' "$BATS_TEST_TMPDIR/body.json"
  grep -q 'TURN DURATION: 160 s' "$BATS_TEST_TMPDIR/body.json"
}

@test "session id with path characters does not escape the state dir" {
  mkcontrol "$(verdict DUMB_QUESTION 0.97)"
  jq -n '{last_assistant_message:"Continue?", stop_hook_active:false, session_id:"../../evil"}' | bash "$HOOK" >/dev/null
  [ ! -e "$HANDOFF_CTL_HOME/evil.cascade" ]
  [ -f "$ST/default.cascade" ]
}

# ── DELAYED_ANSWER and lessons ─────────────────────────────────────────────────────────────

@test "DELAYED_ANSWER does not return the turn, writes a marker with the reason" {
  mkcontrol "$(verdict DELAYED_ANSWER 0.95 'sleep 60 probes after a ready answer')"
  run run_hook 'Not used since February.'
  [ "$status" -eq 0 ]
  [[ "$output" != *decision* ]]
  [ -s "$ST/t1.delayed" ]
  jq -e '.ts > 0 and (.why | test("sleep 60"))' "$ST/t1.delayed"
  [ ! -f "$ST/t1.controlled" ]
}

@test "DELAYED_ANSWER 0.75 — below block threshold, marker still written" {
  mkcontrol "$(verdict DELAYED_ANSWER 0.75 'sleep 60 probes after a ready answer')"
  run run_hook 'Not used since February.'
  [[ "$output" != *decision* ]]
  [ -s "$ST/t1.delayed" ]
}

@test "DELAYED_ANSWER 0.5 — too unsure, no marker" {
  mkcontrol "$(verdict DELAYED_ANSWER 0.5)"
  run_hook 'Not used since February.' >/dev/null
  [ ! -f "$ST/t1.delayed" ]
}

@test "MISSED_ACTION 0.85 — below block threshold, lesson goes to .missed" {
  mkcontrol "$(verdict MISSED_ACTION 0.85 'named the next step and ended the turn' 'Do the named step now')"
  run run_hook '👉 Next: I will check the endpoint after Ready.'
  [[ "$output" != *decision* ]]
  jq -e '.ts > 0 and (.why | test("next step")) and (.action | test("Do the"))' "$ST/t1.missed"
}

@test "DUMB_QUESTION 0.86 — below block threshold, lesson goes to .missed" {
  mkcontrol "$(verdict DUMB_QUESTION 0.86 'asked about the next step instead of doing it' 'Do the step yourself')"
  run run_hook '👉 Next: remove the wrappers from agent sessions?'
  [[ "$output" != *decision* ]]
  jq -e '.ts > 0 and (.why | test("next step")) and (.action | test("Do the"))' "$ST/t1.missed"
}

@test "DUMB_QUESTION 0.95 after an earlier block in the session returns the turn again" {
  echo 1 > "$ST/t1.controlled"
  mkcontrol "$(verdict DUMB_QUESTION 0.95)"
  run run_hook '👉 Next: do X?'
  echo "$output" | jq -e '.decision == "block"'
  [ ! -f "$ST/t1.missed" ]
}

@test "lesson below threshold carries reason below" {
  mkcontrol "$(verdict DUMB_QUESTION 0.86)"
  run_hook '👉 Next: do X?' >/dev/null
  jq -e '.reason == "below"' "$ST/t1.missed"
}

@test "lesson in the cooldown window carries reason cooldown" {
  date +%s > "$ST/t1.ctl-cooldown"
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  run_hook '👉 Next: finishing the build.' >/dev/null
  jq -e '.reason == "cooldown"' "$ST/t1.missed"
}

@test "MISSED_ACTION 0.65 — too unsure, no lesson" {
  mkcontrol "$(verdict MISSED_ACTION 0.65)"
  run_hook 'Done.' >/dev/null
  [ ! -f "$ST/t1.missed" ]
}

@test "MISSED_ACTION with a block writes no duplicate lesson" {
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  run run_hook '👉 Next: finishing the build.'
  echo "$output" | jq -e '.decision == "block"'
  [ ! -f "$ST/t1.missed" ]
}

# ── obligation ─────────────────────────────────────────────────────────────────────────────

@test "a new MISSED_ACTION returns the turn with .controlled already set" {
  mkcontrol2 "$(verdict MISSED_ACTION 0.95 'announced a step' 'Finish the build')" "$(obligation true 'build finished')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  [ -s "$ST/t1.controlled" ]
  run_hook 'Build is green, output attached.' >/dev/null
  [ ! -f "$ST/t1.obligation" ]
  run run_hook '👉 Next: now finishing the linter.'
  echo "$output" | jq -e '.decision == "block"'
}

@test "DUMB_QUESTION after a MISSED_ACTION block also returns the turn" {
  mkcontrol2 "$(verdict MISSED_ACTION 0.95)" "$(obligation true 'closed')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  run_hook 'Build is green.' >/dev/null
  mkcontrol "$(verdict DUMB_QUESTION 0.97)"
  run run_hook 'Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "a MISSED_ACTION block opens an obligation with the action text" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step and ended the turn' 'Finish the build now')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  jq -e '.action == "Finish the build now" and .set_at > 0 and .iterations == 0' "$ST/t1.obligation"
}

@test "obligation met — dropped, turn not returned" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step' 'Finish the build now')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  mkcontrol2 "$(verdict OK 0.9)" "$(obligation true 'build finished, output attached')"
  run run_hook 'Build is green, here is the output.'
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.obligation" ]
  grep -q '"outcome":"met"' "$HANDOFF_CTL_LOG"
}

@test "obligation not met — turn returned again, counter grows" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step' 'Finish the build now')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  mkcontrol2 "$(verdict OK 0.9)" "$(obligation false 'never started the build')"
  run run_hook 'I will tell you about the build later.'
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -r .reason | grep -q 'Finish the build now'
  jq -e '.iterations == 1' "$ST/t1.obligation"
}

@test "obligation impossible — closed without a block, cooldown set" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step' 'Push the branch')"
  run_hook '👉 Next: pushing the branch.' >/dev/null
  mkcontrol2 "$(verdict OK 0.9)" "$(obligation false 'pushing is forbidden by the user policy' true)"
  run run_hook 'Push is forbidden, the command is in the dialog.'
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.obligation" ]
  [ -s "$ST/t1.ctl-cooldown" ]
  grep -q '"outcome":"impossible"' "$HANDOFF_CTL_LOG"
}

@test "obligation stalled — closed without a block after the iteration limit" {
  export HANDOFF_CTL_OBLIGATION_MAX_ITER=1
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step' 'Finish the build now')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  mkcontrol2 "$(verdict OK 0.9)" "$(obligation false 'never started the build')"
  run run_hook 'First refusal.'
  echo "$output" | jq -e '.decision == "block"'
  jq -e '.iterations == 1' "$ST/t1.obligation"
  run run_hook 'Second refusal, judge still unhappy.'
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.obligation" ]
  [ -s "$ST/t1.ctl-cooldown" ]
  grep -q '"outcome":"stalled"' "$HANDOFF_CTL_LOG"
}

@test "expired obligation closes without a block and without calling the judge" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step' 'Finish the build now')"
  run_hook '👉 Next: finishing the build.' >/dev/null
  jq -c '.set_at = 1' "$ST/t1.obligation" > "$BATS_TEST_TMPDIR/o" && mv "$BATS_TEST_TMPDIR/o" "$ST/t1.obligation"
  rm -f "$BATS_TEST_TMPDIR/body.json"
  run run_hook 'Working on something else.'
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.obligation" ]
  [ ! -f "$BATS_TEST_TMPDIR/body.json" ]
  grep -q '"outcome":"expired"' "$HANDOFF_CTL_LOG"
}

@test "during cooldown MISSED_ACTION is a lesson, not a block" {
  date +%s > "$ST/t1.ctl-cooldown"
  mkcontrol "$(verdict MISSED_ACTION 0.95 'announced a step again' 'Finish the build')"
  run run_hook '👉 Next: finishing the build.'
  [[ "$output" != *decision* ]]
  [ ! -f "$ST/t1.obligation" ]
  [ -s "$ST/t1.missed" ]
}

@test "an expired cooldown does not prevent a block" {
  echo 1 > "$ST/t1.ctl-cooldown"
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  run run_hook '👉 Next: finishing the build.'
  echo "$output" | jq -e '.decision == "block"'
}

# ── transcript anchor ──────────────────────────────────────────────────────────────────────

mktranscript() {
  T="$BATS_TEST_TMPDIR/transcript.jsonl"
  {
    echo '{"type":"user","message":{"content":"old question"}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}]}}'
    echo '{"type":"user","message":{"content":"new question"}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"output"}]}}'
  } > "$T"
  printf '%s' "$T"
}

@test "log carries the transcript anchor and the turn's line range" {
  mkcontrol "$(verdict OK 0.9)"
  T=$(mktranscript)
  jq -n --arg m 'done' --arg t "$T" \
    '{last_assistant_message:$m, stop_hook_active:false, session_id:"t1", transcript_path:$t}' \
    | bash "$HOOK"
  rec=$(tail -1 "$HANDOFF_CTL_LOG")
  [ "$(echo "$rec" | jq -r '.transcript')" = "$T" ]
  [ "$(echo "$rec" | jq -r '.lines')" = "3-5" ]
}

@test "no transcript — anchor empty, hook does not fail" {
  mkcontrol "$(verdict OK 0.9)"
  run run_hook 'done'
  [ "$status" -eq 0 ]
  rec=$(tail -1 "$HANDOFF_CTL_LOG")
  [ "$(echo "$rec" | jq -r '.transcript')" = "" ]
  [ "$(echo "$rec" | jq -r '.lines')" = "" ]
}

# ── background work in flight ──────────────────────────────────────────────────────────────

run_with_transcript() {   # $1 = final, $2 = transcript path
  jq -n --arg m "$1" --arg t "$2" \
    '{last_assistant_message:$m, stop_hook_active:false, session_id:"t1", transcript_path:$t}' \
    | bash "$HOOK"
}

# $1 — tool name, $2 — tool_result content as JSON, $3 — launch age in seconds.
mkbg() {
  local T="$BATS_TEST_TMPDIR/bg.jsonl" ts
  ts=$(jq -nr --argjson a "${3:-0}" '(now - $a) | floor | todate')
  jq -nc '{type:"user",message:{content:"build the plan"}}' > "$T"
  jq -nc --arg n "$1" '{type:"assistant",message:{content:[{type:"tool_use",id:"b1",name:$n,input:{}}]}}' >> "$T"
  jq -nc --arg ts "$ts" --argjson c "$2" \
    '{type:"user",timestamp:$ts,message:{content:[{type:"tool_result",tool_use_id:"b1",content:$c}]}}' >> "$T"
  printf '%s' "$T"
}

@test "bg 1. background Agent in flight — MISSED_ACTION is a bg_pending lesson" {
  mkcontrol "$(verdict MISSED_ACTION 0.9 'did not wait for reports' 'Collect the reports')"
  T=$(mkbg Agent '[{"type":"text","text":"Async agent launched successfully. agentId: x"}]')
  run run_with_transcript 'Waiting for scout reports, then I build the plan.' "$T"
  [[ "$output" != *decision* ]]
  grep -q '"suppressed":"bg_agents_pending"' "$HANDOFF_CTL_LOG"
  jq -e '.reason == "bg_pending"' "$ST/t1.missed"
  [ ! -f "$ST/t1.obligation" ]
}

@test "bg 2. continuation: Workflow launched before 'Stop hook feedback' still in flight" {
  mkcontrol "$(verdict MISSED_ACTION 0.9 'waiting for critics' 'Collect the output')"
  T=$(mkbg Workflow '"Workflow launched in background. Task ID: wz1"')
  jq -nc '{type:"user",isMeta:true,message:{content:"Stop hook feedback:\nTURN HANDOFF CONTROL"}}' >> "$T"
  run run_with_transcript 'The result is not available yet: Workflow still running.' "$T"
  ! echo "$output" | grep -q 'decision'
}

@test "bg 3. notification for another task as a string — remaining work still in flight" {
  mkcontrol "$(verdict MISSED_ACTION 0.9 'waiting' 'Collect the reports')"
  T=$(mkbg Agent '[{"type":"text","text":"Async agent launched successfully."}]')
  jq -nc '{type:"user",message:{content:"<task-notification>\n<tool-use-id>other</tool-use-id>\n<status>completed</status>\n</task-notification>"}}' >> "$T"
  run run_with_transcript 'One scout is back, waiting for the rest.' "$T"
  ! echo "$output" | grep -q 'decision'
}

@test "bg 4. notification as a queued_command attachment — not in flight, block stays" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'did not collect' 'Collect the output')"
  T=$(mkbg Workflow '"Workflow launched in background. Task ID: wz1"')
  jq -nc '{type:"attachment",attachment:{type:"queued_command",prompt:"<task-notification>\n<task-id>wz1</task-id>\n<tool-use-id>b1</tool-use-id>\n<status>completed</status>\n</task-notification>"}}' >> "$T"
  run run_with_transcript 'Waiting for critics.' "$T"
  echo "$output" | jq -e '.decision == "block"'
}

@test "bg 5. launch phrase inside ordinary command output is not a launch" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'did not do it' 'Do it')"
  T=$(mkbg Bash '"343:  content:\"Workflow launched in background. Task ID: x\""')
  run run_with_transcript 'Did half of it.' "$T"
  echo "$output" | jq -e '.decision == "block"'
}

@test "bg 6. work launched before a new user message (watcher) does not mute the controller" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'did not do it' 'Do it')"
  T=$(mkbg Bash '"Command running in background with ID: w1"')
  jq -nc '{type:"user",message:{content:"next question"}}' >> "$T"
  run run_with_transcript 'Will do it later.' "$T"
  echo "$output" | jq -e '.decision == "block"'
}

@test "bg 7. a literal <tool-use-id> in Read output does not close a live launch" {
  mkcontrol "$(verdict MISSED_ACTION 0.9 'waiting' 'Collect')"
  T=$(mkbg Workflow '"Workflow launched in background. Task ID: wz1"')
  jq -nc --arg ts "$(jq -nr 'now|floor|todate')" \
    '{type:"user",timestamp:$ts,message:{content:[{type:"tool_result",tool_use_id:"r1",content:"plan.md:141 <tool-use-id>b1</tool-use-id>"}]}}' >> "$T"
  run run_with_transcript 'Waiting for critics.' "$T"
  ! echo "$output" | grep -q 'decision'
}

@test "bg 8. launch older than the window without a notification — blocks again" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'waiting' 'Collect')"
  T=$(mkbg Agent '[{"type":"text","text":"Async agent launched successfully."}]' 7200)
  run run_with_transcript 'Waiting for reports.' "$T"
  echo "$output" | jq -e '.decision == "block"'
}

@test "bg 9. DUMB_QUESTION with work in flight is not suppressed" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'filler question' 'Decide yourself')"
  T=$(mkbg Workflow '"Workflow launched in background. Task ID: wz1"')
  run run_with_transcript 'While critics run — shall I also start the linter?' "$T"
  echo "$output" | jq -e '.decision == "block"'
}

@test "obligation with work in flight is deferred: no judge, no attempt" {
  mkcontrol2 "$(verdict OK 0.9)" "$(obligation false 'not collected')"
  jq -nc --argjson t "$(date +%s)" '{action:"Collect the critics output",why:"waited",set_at:$t,iterations:0}' \
    > "$ST/t1.obligation"
  T=$(mkbg Workflow '"Workflow launched in background. Task ID: wz1"')
  run run_with_transcript 'Critics are still running.' "$T"
  [[ "$output" != *decision* ]]
  [ ! -f "$BATS_TEST_TMPDIR/body.json" ]
  jq -e '.iterations == 0' "$ST/t1.obligation"
  jq -s -e '.[-1].outcome == "deferred_bg"' "$HANDOFF_CTL_LOG"
}

# ── evidence ───────────────────────────────────────────────────────────────────────────────

mkfailtranscript() {
  T="$BATS_TEST_TMPDIR/fails.jsonl"
  {
    jq -nc '{type:"user",      message:{content:"fix the test"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"tool_use",id:"a1",name:"Bash",input:{command:"git push origin main"}}]}}'
    jq -nc '{type:"user",      message:{content:[{type:"tool_result",tool_use_id:"a1",is_error:true,content:"PreToolUse:Bash hook error: push is forbidden by policy"}]}}'
    jq -nc '{type:"assistant", message:{content:[{type:"tool_use",id:"a2",name:"Bash",input:{command:"bats hooks/__tests__"}}]}}'
    jq -nc '{type:"user",      message:{content:[{type:"tool_result",tool_use_id:"a2",is_error:true,content:"Exit code 1\nnot ok 3 obligation"}]}}'
  } > "$T"
  printf '%s' "$T"
}

sent_body() { jq -r '.messages[0].content' "$BATS_TEST_TMPDIR/body.json"; }

@test "evidence: a hook block and a failed command reach the judge as separate lists" {
  mkcontrol "$(verdict OK 0.95)"
  run_with_transcript 'Done.' "$(mkfailtranscript)"
  BODY=$(sent_body)
  [[ "$BODY" == *"BLOCKED BY HOOKS: 1"* ]]
  [[ "$BODY" == *"FAILED CALLS: 1"* ]]
  [[ "$BODY" == *"push is forbidden by policy"* ]]
  [[ "$BODY" == *"not ok 3"* ]]
}

@test "evidence: a secret in failed command output does not reach the judge" {
  mkcontrol "$(verdict OK 0.95)"
  SECRET="sk-ant""-oat01-QQQQWWWWEEEERRRRTTTT"
  T="$BATS_TEST_TMPDIR/secret.jsonl"
  {
    jq -nc '{type:"user",      message:{content:"call the api"}}'
    jq -nc '{type:"assistant", message:{content:[{type:"tool_use",id:"s1",name:"Bash",input:{command:"curl api"}}]}}'
    jq -nc --arg s "$SECRET" '{type:"user", message:{content:[{type:"tool_result",tool_use_id:"s1",is_error:true,content:("Exit code 22 token=" + $s)}]}}'
  } > "$T"
  run_with_transcript 'Done.' "$T"
  BODY=$(sent_body)
  [[ "$BODY" != *"$SECRET"* ]]
  [[ "$BODY" == *"FAILED CALLS: 1"* ]]
}

@test "evidence: no transcript — the judge is told evidence is unavailable" {
  mkcontrol "$(verdict OK 0.95)"
  run run_hook 'Done.'
  [ "$status" -eq 0 ]
  [[ "$(sent_body)" == *"turn transcript unavailable"* ]]
}

@test "evidence: call arguments never leave" {
  mkcontrol "$(verdict OK 0.95)"
  run_with_transcript 'Done.' "$(mkfailtranscript)"
  BODY=$(sent_body)
  [[ "$BODY" != *"git push origin main"* ]]
  [[ "$BODY" != *"bats hooks/__tests__"* ]]
}

# ── calibrator (optional) ──────────────────────────────────────────────────────────────────

mkcalib() {   # $1 = argmax token, $2 = its logprob, $3 = alternative logprob, $4 = reasoning_tokens
  ALT=$([ "$1" = "yes" ] && echo "no" || echo "yes")
  {
    echo '#!/bin/sh'
    echo "cat > \"$BATS_TEST_TMPDIR/calib-body.json\""
    printf 'cat <<%s\n%s\n%s\n' "'CEOF'" "$(jq -nc --arg t "$1" --arg alt "$ALT" \
      --argjson a "$2" --argjson b "$3" --argjson rt "${4:-0}" \
      '{choices:[{message:{content:$t},
                  logprobs:{content:[{token:$t,logprob:$a,
                    top_logprobs:[{token:$t,logprob:$a},{token:$alt,logprob:$b}]}]}}],
        usage:{completion_tokens_details:{reasoning_tokens:$rt}}}')" "CEOF"
  } > "$BATS_TEST_TMPDIR/calibrator"
  chmod +x "$BATS_TEST_TMPDIR/calibrator"
  export HANDOFF_CTL_CALIB_CMD="$BATS_TEST_TMPDIR/calibrator"
}

lastrec() { tail -1 "$HANDOFF_CTL_LOG"; }

@test "calibrator is off by default" {
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  mkcalib "yes" -0.002 -6.2
  run run_hook 'will fix the fixture'
  [ ! -f "$BATS_TEST_TMPDIR/calib-body.json" ]
  [ "$(lastrec | jq -r '.calib_status // "none"')" = "none" ]
}

@test "calibrator: on MISSED_ACTION the measured confidence is logged" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  mkcalib "yes" -0.002 -6.2
  run run_hook 'will fix the fixture'
  rec=$(lastrec)
  [ "$(echo "$rec" | jq -r '.calib_status')" = "ok" ]
  awk -v c="$(echo "$rec" | jq -r '.calibrated')" 'BEGIN{exit !(c > 0.99)}'
}

@test "calibrator: not called on OK" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict OK 0.95)"
  mkcalib "no" -0.001 -7
  run run_hook 'done, tests green'
  [ ! -f "$BATS_TEST_TMPDIR/calib-body.json" ]
}

@test "calibrator: not called on DELAYED_ANSWER" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict DELAYED_ANSWER 0.85)"
  mkcalib "no" -0.001 -7
  run run_hook 'answer: X differs from Y in this way'
  [ ! -f "$BATS_TEST_TMPDIR/calib-body.json" ]
  [ -s "$ST/t1.delayed" ]
}

@test "calibrator: failure — self-reported confidence decides, failure visible in log" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  export HANDOFF_CTL_CALIB_CMD=/bin/false
  run run_hook 'will fix the fixture'
  rec=$(lastrec)
  [ "$(echo "$rec" | jq -r '.calibrated // "none"')" = "none" ]
  [ "$(echo "$rec" | jq -r '.calib_status')" = "failed" ]
  [ "$(echo "$rec" | jq -r '.blocked')" = "true" ]
}

@test "calibrator: leaked reasoning — number dropped" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  mkcalib "yes" -0.000001 -14 178
  run run_hook 'will fix the fixture'
  rec=$(lastrec)
  [ "$(echo "$rec" | jq -r '.calibrated // "none"')" = "none" ]
  [ "$(echo "$rec" | jq -r '.calib_status')" = "reasoning_leaked" ]
}

@test "calibrator: argmax 'no' — confidence is one minus its probability" {
  export HANDOFF_CTL_CALIB=1
  mkcontrol "$(verdict MISSED_ACTION 0.95)"
  mkcalib "no" -0.15 -2.02
  run run_hook 'will fix the fixture'
  awk -v c="$(lastrec | jq -r '.calibrated')" 'BEGIN{exit !(c > 0.10 && c < 0.20)}'
}

# ── dangerous actions and the responsible-zone flag ────────────────────────────────────────

@test "a push to delete carries the spike and flag protocol" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'named a deletion and did not do it' 'Delete heightVars and *_h')"
  run run_hook 'The height model is dead. Deleting next turn.'
  echo "$output" | jq -r .reason | grep -q 'RESPONSIBLE ZONE'
  echo "$output" | jq -r .reason | grep -q 'spike first'
}

@test "danger:true from the judge without dictionary words — protocol still attached" {
  mkcontrol "$(jq -nc '{content:[{type:"text",text:({verdict:"MISSED_ACTION",confidence:0.95,why:"not finished",action:"Tidy up the height model",danger:true}|tostring)}]}')"
  run run_hook 'The height model needs tidying.'
  echo "$output" | jq -r .reason | grep -q 'RESPONSIBLE ZONE'
}

@test "a push to a harmless action carries no protocol" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'did not run' 'Run bats')"
  run run_hook 'I will run the tests later.'
  echo "$output" | jq -e '.decision == "block"'
  ! echo "$output" | jq -r .reason | grep -q 'RESPONSIBLE ZONE'
}

@test "deadlock and contract in the push — not a dangerous action" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'not finished' 'Fix the deadlock and run the validator on the contract')"
  run run_hook 'Will look later.'
  echo "$output" | jq -e '.decision == "block"'
  [[ "$(echo "$output" | jq -r .reason)" != *"RESPONSIBLE ZONE"* ]]
}

@test "a dangerous MISSED_ACTION does not open a 'delete' obligation" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'named a deletion' 'Delete heightVars and *_h')"
  run run_hook 'The height model is dead. Deleting next turn.'
  echo "$output" | jq -e '.decision == "block"'
  [ ! -f "$ST/t1.obligation" ]
}

@test "UNFLAGGED_RISK 0.92 — turn returned demanding the flag, no obligation" {
  mkcontrol "$(verdict UNFLAGGED_RISK 0.92 'deleted without a flag' 'Add the flag')"
  run run_hook 'Deleted the height model entirely.'
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -r .reason | grep -q 'Do not roll back'
  [ ! -f "$ST/t1.obligation" ]
}

@test "UNFLAGGED_RISK below the block threshold is a lesson with its verdict" {
  mkcontrol "$(verdict UNFLAGGED_RISK 0.85 'deleted without a flag' 'Add the flag')"
  run run_hook 'Deleted the height model entirely.'
  [[ "$output" != *decision* ]]
  [ "$(jq -r .verdict "$ST/t1.missed")" = "UNFLAGGED_RISK" ]
}

FLAG_OK='Removed video_h.

⚠️ RESPONSIBLE ZONE — removed the template variable video_h
   Evidence: `rg -n video_h .` → 0 matches, call graph 0 callers
   Rollback: git revert 1a2b3c4
   Ok / not ok?'

@test "flag with evidence and rollback suppresses DUMB_QUESTION" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'asked ok/not ok' 'Do not ask')"
  run run_hook "$FLAG_OK"
  [[ "$output" != *decision* ]]
  grep -q '"suppressed":"responsible_flag_in_dialog"' "$HANDOFF_CTL_LOG"
}

@test "Awaiting decision instead of Rollback also counts" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'asked' 'Do it')"
  run run_hook $'Checked X.\n\n⚠️ RESPONSIBLE ZONE — X looks dead\n   Evidence: `rg -n X .` → 0 matches\n   Awaiting decision: dynamic lookup via config cannot be ruled out\n   Ok / not ok?'
  [[ "$output" != *decision* ]]
}

@test "marker without evidence — block stays" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'question' 'Do it')"
  run run_hook '⚠️ RESPONSIBLE ZONE — cleaning the height model. Continue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "evidence without a command ('checked') — block stays" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'question' 'Do it')"
  run run_hook $'Removed X.\n\n⚠️ RESPONSIBLE ZONE — removed X\n   Evidence: checked\n   Rollback: git revert 1a2b3c4\n   Ok / not ok?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "marker, evidence and rollback in different paragraphs — block stays" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'question' 'Do it')"
  run run_hook $'⚠️ RESPONSIBLE ZONE — cleaning the height model\n\nThen looked at logs.\n\nEvidence: `rg video_h` → 0\n\nOn another note: Rollback: git revert 1a2b3c4\nContinue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "flag inside a fenced block (quoting the format) — block stays" {
  mkcontrol "$(verdict DUMB_QUESTION 0.95 'question' 'Do it')"
  run run_hook $'The format is:\n```\n⚠️ RESPONSIBLE ZONE — <what>\n   Evidence: `rg x` → DEAD\n   Rollback: git revert x\n```\nContinue?'
  echo "$output" | jq -e '.decision == "block"'
}

@test "flag does not suppress MISSED_ACTION" {
  mkcontrol "$(verdict MISSED_ACTION 0.95 'tests failed' 'Fix the test')"
  run run_hook "$FLAG_OK"
  echo "$output" | jq -e '.decision == "block"'
}

@test "flag also suppresses DUMB_QUESTION below threshold — no lesson written" {
  mkcontrol "$(verdict DUMB_QUESTION 0.85 'asked ok/not ok' 'Do not ask')"
  run run_hook "$FLAG_OK"
  [ ! -f "$ST/t1.missed" ]
}

# ── live corpus (opt-in) ───────────────────────────────────────────────────────────────────

# Burns API and is nondeterministic, hence gated. A mismatch is fixed in the rubric, not the hook.
@test "live judge on the fixture corpus" {
  [ -n "${HANDOFF_CTL_LIVE:-}" ] || skip "set HANDOFF_CTL_LIVE=1 and HANDOFF_CTL_API_KEY"
  unset HANDOFF_CTL_CMD
  export HANDOFF_CTL_API_KEY="${HANDOFF_CTL_LIVE_KEY:-}"
  export HANDOFF_CTL_TIMEOUT="${HANDOFF_CTL_TIMEOUT:-90}"
  local fails=0
  while IFS=$'\t' read -r name want; do
    [ -n "$name" ] || continue
    rm -f "$ST"/t1.*
    [ -f "$FX/$name.prompt" ] && cp "$FX/$name.prompt" "$HANDOFF_CTL_HOME/prompts/t1.last-prompt" \
                              || rm -f "$HANDOFF_CTL_HOME/prompts/t1.last-prompt"
    local got conf n0 n1
    n0=$(test -f "$HANDOFF_CTL_LOG" && wc -l < "$HANDOFF_CTL_LOG" || echo 0)
    jq -n --rawfile m "$FX/$name.txt" '{last_assistant_message:$m, stop_hook_active:false, session_id:"t1"}' \
      | bash "$HOOK" >/dev/null
    n1=$(test -f "$HANDOFF_CTL_LOG" && wc -l < "$HANDOFF_CTL_LOG" || echo 0)
    if [ "$n1" = "$n0" ]; then
      echo "# FAIL $name — fail-open: no log record (network or key)" >&3
      fails=$(( fails + 1 )); continue
    fi
    got=$(tail -1 "$HANDOFF_CTL_LOG" | jq -r .verdict)
    conf=$(tail -1 "$HANDOFF_CTL_LOG" | jq -r .confidence)
    if [ "$got" = "$want" ] || { [ "$want" = "OK" ] && awk -v c="$conf" 'BEGIN{exit !(c+0 < 0.9)}'; }; then
      echo "# ok   $name → $got ($conf)" >&3
    else
      echo "# FAIL $name → $got ($conf), expected $want" >&3
      fails=$(( fails + 1 ))
    fi
  done < "$FX/expected.tsv"
  [ "$fails" -eq 0 ]
}
