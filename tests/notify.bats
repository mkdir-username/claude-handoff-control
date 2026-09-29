#!/usr/bin/env bats
# Notifications: layout of the macOS banner, the status hooks, and the click that focuses the
# Ghostty tab of the session. Sending is replaced via $HANDOFF_CTL_NOTIFY_CMD: it receives
# <title> <class> <headline> <body>, one per line, into n.txt.

setup() {
  LIB="$BATS_TEST_DIRNAME/../hooks/lib"
  HOOKS="$BATS_TEST_DIRNAME/../hooks"
  TR="$BATS_TEST_TMPDIR/tr.jsonl"
  echo '{"type":"custom-title","customTitle":"My session"}' > "$TR"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/n.txt"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/send"
  chmod +x "$BATS_TEST_TMPDIR/send"
  export HANDOFF_CTL_NOTIFY_CMD="$BATS_TEST_TMPDIR/send"
  export HANDOFF_CTL_NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.jsonl"
}

wait_sent() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BATS_TEST_TMPDIR/n.txt" ] && break; sleep 0.1; done; }

# --- banner layout ---

# 21 × "─" is 545 px of the ~550 px text field: at least 97% of the width, 22 already wrap.
@test "layout: session line, full-width rule, description" {
  source "$LIB/session-notify.sh"
  run _session_message "My session" "Tool: Bash"
  [ "$output" = $' ❯ My session\n─────────────────────\nTool: Bash' ]
}

@test "layout: no description, only the session line" {
  source "$LIB/session-notify.sh"
  run _session_message "My session" ""
  [ "$output" = " ❯ My session" ]
}

@test "layout: a long description is cut to two banner lines and ends with an ellipsis" {
  source "$LIB/session-notify.sh"
  long=$(printf 'word %.0s' {1..40})
  run _session_body "$long"
  [ "$(printf '%s' "$output" | perl -CSD -ne 'print length')" -le 90 ]
  [[ "$output" == *"…" ]]
}

# The click runs the focus script from a foreign cwd: a fallback name from $PWD would pick the wrong tab.
@test "title: without ai/custom title it is the session folder, not \$PWD" {
  source "$LIB/session-notify.sh"
  echo '{"type":"user","cwd":"/home/x/work/EpsilonUI"}' > "$TR"
  cd /tmp
  run session_title "$TR"
  [ "$output" = "EpsilonUI" ]
}

@test "tty lookup walks up to the nearest claude ancestor without failing" {
  source "$LIB/session-notify.sh"
  run _session_tty
  [ "$status" -eq 0 ]
}

@test "HANDOFF_CTL_NOTIFY=0 sends nothing and logs nothing" {
  source "$LIB/session-notify.sh"
  HANDOFF_CTL_NOTIFY=0 session_notify "$TR" handoff "Missed action" "x"
  sleep 0.2
  [ ! -e "$BATS_TEST_TMPDIR/n.txt" ]
  [ ! -e "$HANDOFF_CTL_NOTIFY_LOG" ]
}

@test "every notification is logged as one jsonl line" {
  source "$LIB/session-notify.sh"
  session_notify "$TR" handoff "Missed action" "why"
  wait_sent
  jq -e '.kind == "handoff" and .title == "My session" and (.head | contains("HANDOFF")) and .session == "tr"' \
    "$HANDOFF_CTL_NOTIFY_LOG"
}

# --- Notification hook ---

fire_notification() {
  jq -nc --arg t "$1" --arg m "$2" --arg tr "$TR" \
    '{hook_event_name:"Notification", notification_type:$t, message:$m, session_id:"s1", transcript_path:$tr}' \
    | bash "$HOOKS/notify-notification.sh"
  wait_sent
}

@test "notification: permission_prompt names the tool" {
  fire_notification permission_prompt "Claude needs your permission to use Bash"
  run cat "$BATS_TEST_TMPDIR/n.txt"
  [ "${lines[0]}" = "My session" ]
  [ "${lines[1]}" = "warn" ]
  [ "${lines[2]}" = "🟡 WARN  ·  Permission needed" ]
  [[ "${lines[3]}" == *Bash* ]]
}

@test "notification: idle_prompt is info" {
  fire_notification idle_prompt "Claude is waiting for your input"
  run cat "$BATS_TEST_TMPDIR/n.txt"
  [ "${lines[1]}" = "info" ]
  [ "${lines[2]}" = "🔵 INFO  ·  Waiting for you" ]
}

@test "notification: an unknown type passes the message through" {
  fire_notification some_new_type "Something happened"
  [[ "$(cat "$BATS_TEST_TMPDIR/n.txt")" == *"Something happened"* ]]
}

@test "notification: garbage input exits 0 without a notification" {
  run bash -c "echo 'not json' | bash '$HOOKS/notify-notification.sh'"
  [ "$status" -eq 0 ]
  sleep 0.2
  [ ! -e "$BATS_TEST_TMPDIR/n.txt" ]
}

# --- Stop "turn finished" hook ---

fire_done() {
  jq -nc --arg m "$1" --arg tr "$TR" \
    '{hook_event_name:"Stop", session_id:"s1", transcript_path:$tr, last_assistant_message:$m}' \
    | bash "$HOOKS/notify-stop-done.sh"
  wait_sent
}

@test "done: green DONE, session title" {
  fire_done "Fixed the hook"
  run cat "$BATS_TEST_TMPDIR/n.txt"
  [ "${lines[0]}" = "My session" ]
  [ "${lines[1]}" = "done" ]
  [ "${lines[2]}" = "🟢 DONE  ·  Turn finished" ]
}

@test "done: body is the first non-empty line without markdown or emoji" {
  fire_done $'\n## ✅ What changed in the **hook** ⚠️\n\nmore'
  run cat "$BATS_TEST_TMPDIR/n.txt"
  [ "${lines[3]}" = "What changed in the hook" ]
}

@test "done: empty message still notifies with a fallback body" {
  fire_done ""
  run cat "$BATS_TEST_TMPDIR/n.txt"
  [ "${lines[3]}" = "Turn ended" ]
}

@test "done: garbage input exits 0" {
  run bash -c "echo 'not json' | bash '$HOOKS/notify-stop-done.sh'"
  [ "$status" -eq 0 ]
}

# --- click → Ghostty tab ---
# osascript is stubbed: by its last argument it returns a terminal snapshot, an id for the marker,
# or "focused".

focus_setup() {
  BIN="$LIB/ghostty-focus-session"
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  export GFS_DEV_DIR="$BATS_TEST_TMPDIR/dev"; mkdir -p "$GFS_DEV_DIR"
  cat > "$STUB/osascript" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
printf '%s\n' "\$last" >> "$BATS_TEST_TMPDIR/calls.txt"
case "\$last" in
  "return o") printf 'ID1\t◐ other\nID2\t✳ Old name\n' ;;
  cc-focus-*) [ -f "$BATS_TEST_TMPDIR/no-match" ] || echo ID2 ;;
  *) printf '%s' "\$last" > "$BATS_TEST_TMPDIR/arg.txt"; echo focused ;;
esac
EOF
  chmod +x "$STUB/osascript"
}

run_bin() { PATH="$STUB:$PATH" "$BIN" "$@"; }

@test "focus: the session custom title goes to osascript" {
  focus_setup
  { echo '{"type":"ai-title","aiTitle":"Auto"}'; echo '{"type":"custom-title","customTitle":"My \"title\" with quotes"}'; } > "$TR"
  run run_bin "$TR"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/arg.txt")" = 'My "title" with quotes' ]
}

@test "focus: a path with a space arrives whole" {
  focus_setup
  mkdir -p "$BATS_TEST_TMPDIR/a b"; T2="$BATS_TEST_TMPDIR/a b/tr.jsonl"
  echo '{"type":"ai-title","aiTitle":"With space"}' > "$T2"
  run run_bin "$T2"
  [ "$(cat "$BATS_TEST_TMPDIR/arg.txt")" = 'With space' ]
}

@test "focus: with tty — marker in the title, focus by terminal id, old name restored" {
  focus_setup
  echo '{"type":"ai-title","aiTitle":"Shared name"}' > "$TR"
  : > "$GFS_DEV_DIR/ttys042"
  run run_bin "$TR" ttys042
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/arg.txt")" = ID2 ]
  tok=$(command grep -ao 'cc-focus-[0-9-]*' "$GFS_DEV_DIR/ttys042" | head -1)
  [ -n "$tok" ]
  [ "$(cat "$GFS_DEV_DIR/ttys042")" = "$(printf '\033]2;%s\007\033]2;%s\007' "$tok" '✳ Old name')" ]
  run jq -r 'select(.click) | .method' "$HANDOFF_CTL_NOTIFY_LOG"
  [ "$output" = tty ]
}

@test "focus: Ghostty did not see the marker — falls back to title" {
  focus_setup
  echo '{"type":"ai-title","aiTitle":"Fallback"}' > "$TR"
  : > "$GFS_DEV_DIR/ttys042"; touch "$BATS_TEST_TMPDIR/no-match"
  GFS_TTY_TRIES=2 run run_bin "$TR" ttys042
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/arg.txt")" = 'Fallback' ]
  run jq -r 'select(.click) | .method' "$HANDOFF_CTL_NOTIFY_LOG"
  [ "$output" = title ]
}

@test "focus: tty missing — straight to title, no marker written" {
  focus_setup
  echo '{"type":"ai-title","aiTitle":"No tty"}' > "$TR"
  run run_bin "$TR" ttys099
  [ "$(cat "$BATS_TEST_TMPDIR/arg.txt")" = 'No tty' ]
  ! command grep -q cc-focus "$BATS_TEST_TMPDIR/calls.txt"
}
