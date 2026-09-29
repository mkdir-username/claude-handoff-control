#!/usr/bin/env bash
# Tells apart who extended the turn for Stop-hook controllers.
# stop_hook_active=true is set both by the controller's own block (repeat = loop) and by an
# external auto-resume after an API drop (Claude Code reports it the same way). A resumer that
# wants its turn judged drops $HANDOFF_CTL_HOME/rewake/<sid>.rewake-pending with an epoch;
# every consumer counts that marker once, so its own block on the same marker cannot loop.
# Without such a resumer the pending file never exists and this is a plain anti-loop guard.

# stop_rewake_should_skip <stop_hook_active> <session_id> <consumer>
# 0 — skip (anti-loop), 1 — judge the turn.
stop_rewake_should_skip() {
  local dir="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}/rewake"
  local pending="$dir/$2.rewake-pending" seen="$dir/$2.rewake-seen-$3" t
  t=$(cat "$pending" 2>/dev/null)
  if [ "$1" != "true" ]; then
    # Consume the marker on the first ordinary Stop: the resumed turn may have been interrupted
    # by the user, and a live marker would later be credited to a controller's own block.
    [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" > "$seen" 2>/dev/null
    return 1
  fi
  [[ "$t" =~ ^[0-9]+$ ]] || return 0
  [ $(( $(date +%s) - t )) -lt "${STOP_REWAKE_TTL:-900}" ] || return 0
  [ "$(cat "$seen" 2>/dev/null)" = "$t" ] && return 0
  echo "$t" > "$seen" 2>/dev/null || return 0
  return 1
}
