#!/usr/bin/env bash
# session-notify.sh — macOS notifications on behalf of a Claude Code session.
# With many Ghostty tabs a notification has to say WHAT happened and WHERE, and a click has to
# take you there. Banner layout — the status reads in a split second by its colour:
#   🛑 HANDOFF  ·  Missed action   ← class label + 2–3 words; macOS keeps the double spaces around "·"
#    ❯ <session title>             ← leading en space (U+2002): macOS strips a plain one.
#                                    Same name as the Ghostty tab: last /rename, else last ai-title,
#                                    else the session folder
#   ─────────────────────          ← 21 × "─" fill ≥97% of the text field; 22 already wrap
#   <description, 1–2 lines>       ← only when given; longer is cut with an ellipsis
# The click runs ghostty-focus-session <transcript> <tty> and brings the session tab forward.
# The class (handoff/error/warn/info/done) sets label, icon and sound. Sound goes through afplay
# separately: a notification's own sound is muted by Notification Center settings, and a single
# system sound gets lost under music.
# Test hook: $HANDOFF_CTL_NOTIFY_CMD receives <title> <class> <headline> <body>.
# Silent under bats unless that is set. Turn everything off: HANDOFF_CTL_NOTIFY=0.

_SESSION_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

session_title() {   # <transcript>
  local tr="$1" t=""
  if [ -n "$tr" ] && [ -f "$tr" ]; then
    t=$(command grep -F '"type":"custom-title"' "$tr" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
    [ -n "$t" ] || t=$(command grep -F '"type":"ai-title"' "$tr" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
    # the session folder, not $PWD: the click calls this from a foreign cwd
    [ -n "$t" ] || t=$(command grep -m1 -o '"cwd":"[^"]*"' "$tr" 2>/dev/null | sed -E 's/.*"cwd":"([^"]*)"/\1/; s#.*/##')
  fi
  [ -n "$t" ] || t=$(basename "${PWD:-claude}")
  printf '%s' "$t"
}

# tty of the claude process that runs the hook: the click finds the tab by it even when the title
# is not unique (two sessions with the same ai-title) or not assigned yet.
_session_tty() {
  [ -n "${HANDOFF_CTL_NOTIFY_TTY+x}" ] && { printf '%s' "$HANDOFF_CTL_NOTIFY_TTY"; return 0; }
  local p=$$ comm tty
  while [ "${p:-1}" -gt 1 ]; do
    read -r comm tty <<<"$(ps -o comm=,tty= -p "$p" 2>/dev/null)"
    case "${comm##*/}" in
      claude*) [ "${tty:-??}" != "??" ] && printf '%s' "$tty"; return 0 ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 0
}

# The session tab is already in front of you — a "waiting for you" banner is just noise.
_session_tab_focused() {   # <title>
  [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "ghostty" ] \
    || return 1
  osascript -e 'on run argv' -e 'tell application "Ghostty"' \
    -e 'return (name of focused terminal of selected tab of front window) contains (item 1 of argv)' \
    -e 'end tell' -e 'end run' "$1" 2>/dev/null | command grep -qx true
}

# Class = priority. Sound only where you are needed. HANDOFF has its own signal so that every
# forced return is heard and recognised — the judge can be wrong, and you should know when it acts.
#   handoff — the judge returned the turn, Sosumi ×3
#   error   — something broke, Basso ×2
#   warn    — work waits for your action, one quiet Tink
#   info    — for your information, silent
#   done    — turn finished, silent
_session_sound() {   # <class> → "<sound> <repeats> [step, s]"
  case "$1" in
    handoff) echo "${HANDOFF_CTL_NOTIFY_SOUND:-Sosumi} 3 0.5" ;;
    error)   echo "Basso 2" ;;
    warn)    echo "Tink 1" ;;
    *)       echo "" ;;
  esac
}

_session_label() {   # <class> → label at the start of the headline
  case "$1" in
    handoff) echo "🛑 HANDOFF" ;;
    error)   echo "🔴 ERROR" ;;
    warn)    echo "🟡 WARN" ;;
    done)    echo "🟢 DONE" ;;
    *)       echo "🔵 INFO" ;;
  esac
}

_session_icon() {   # <class>
  local r=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
  case "$1" in
    handoff|error) echo "$r/AlertStopIcon.icns" ;;
    warn)          echo "$r/AlertCautionBadgeIcon.icns" ;;
    *)             echo "$r/ToolbarInfo.icns" ;;
  esac
}

# Emoji are stripped from the body: the banner carries one mark, the status colour. Past 90
# characters it would be a third banner line, so it is cut at a word with an ellipsis.
_session_body() {   # <text> → one line ≤90 characters, no emoji
  printf '%s' "$1" | tr '\n' ' ' \
    | perl -CSD -pe 's/[\p{Extended_Pictographic}\x{FE0F}\x{200D}\x{20E3}\x{1F1E6}-\x{1F1FF}]//g; s/ {2,}/ /g; s/^ +| +$//g;
                     if (length > 90) { $_ = substr($_, 0, 89); s/\s+\S*$//; $_ .= "\x{2026}" }'
}

_session_message() {   # <session title> <description> → text under the status headline
  printf ' ❯ %s' "$1"
  [ -n "$2" ] && printf '\n─────────────────────\n%s' "$2"
  return 0
}

session_notify() {   # <transcript> <class> <headline> <body>
  [ "${HANDOFF_CTL_NOTIFY:-1}" = "0" ] && return 0
  local tr="$1" kind="$2" head="$(_session_label "$2")  ·  $3" body title sid
  body=$(_session_body "$4")
  title=$(session_title "$tr")
  # Log of what was sent: without it "a notification arrived" cannot be matched to a session or hook.
  # Under bats only an explicitly set HANDOFF_CTL_NOTIFY_LOG is written.
  local nlog="${HANDOFF_CTL_NOTIFY_LOG:-}"
  [ -n "$nlog" ] || [ -n "${BATS_TEST_FILENAME:-}" ] \
    || nlog="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}/notify.jsonl"
  [ -n "$nlog" ] && mkdir -p "$(dirname "$nlog")" 2>/dev/null \
    && jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$kind" --arg h "$head" \
    --arg b "$body" --arg t "$title" --arg s "$(basename "${tr:-none}" .jsonl)" --arg c "$(basename "${0:-?}")" \
    '{ts:$ts,kind:$k,head:$h,body:$b,title:$t,session:$s,caller:$c}' >> "$nlog" 2>/dev/null
  if [ -n "${HANDOFF_CTL_NOTIFY_CMD:-}" ]; then
    "$HANDOFF_CTL_NOTIFY_CMD" "$title" "$kind" "$head" "$body" >/dev/null 2>&1 &
    return 0
  fi
  [ -n "${BATS_TEST_FILENAME:-}" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0   # not macOS
  sid=$(basename "${tr:-none}" .jsonl)
  local tty focus="$_SESSION_NOTIFY_DIR/ghostty-focus-session"
  tty=$(_session_tty)
  # All in the background: the hook waits for neither AppleScript nor sound.
  (
    case "$kind" in
      warn|info|done) _session_tab_focused "$title" && exit 0 ;;
    esac
    local tn
    tn=$(command -v terminal-notifier 2>/dev/null || true)
    [ -n "$tn" ] || { [ -x /opt/homebrew/bin/terminal-notifier ] && tn=/opt/homebrew/bin/terminal-notifier; }
    if [ -n "$tn" ]; then
      # group: a repeat of the same class in the same session replaces the old banner instead of stacking.
      "$tn" -title "$head" -message "$(_session_message "$title" "$body")" \
        -contentImage "$(_session_icon "$kind")" -group "cc-$sid-$kind" \
        -execute "$(printf '%q %q %s' "$focus" "$tr" "$tty")" >/dev/null 2>&1 &
    else
      # argv, not string substitution: quotes in the text would break the AppleScript. No click-to-focus.
      osascript -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' "$head" "$(_session_message "$title" "$body")" >/dev/null 2>&1 &
    fi
    set -- $(_session_sound "$kind")
    if [ -n "${1:-}" ]; then
      local snd="/System/Library/Sounds/$1.aiff" i
      for (( i = 0; i < ${2:-1}; i++ )); do afplay "$snd" & sleep "${3:-0.18}"; done
    fi
    wait
  ) >/dev/null 2>&1 &
  return 0
}
