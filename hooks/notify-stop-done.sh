#!/usr/bin/env bash
# Stop hook: "turn finished" in the same style as the other notifications — class label, session
# title, click focuses the session tab. Optional — installed by `./install.sh --notify`.
# Class done: green, silent, and skipped when the session tab is already in front of you.
# The body is the first line of the answer; it goes to the log, the banner shows status and name.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/session-notify.sh" 2>/dev/null || exit 0

INPUT=$(cat)
TR=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null) || exit 0
TR="${TR/#\~/$HOME}"
MSG=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null)

BODY=$(printf '%s\n' "$MSG" | sed -E 's/^[[:space:]#>*-]+//; s/\*\*|`//g' | awk 'NF { print; exit }')
session_notify "$TR" done "Turn finished" "${BODY:-Turn ended}"
exit 0
