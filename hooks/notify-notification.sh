#!/usr/bin/env bash
# Notification hook: Claude Code's own notifications, re-sent with the session title and a click
# that focuses the session tab in Ghostty. Optional — installed by `./install.sh --notify`.
# To avoid duplicates, turn off Claude Code's native channel: "preferredNotifChannel":
# "notifications_disabled" in settings.json. Notification hooks still fire with it.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/session-notify.sh" 2>/dev/null || exit 0

INPUT=$(cat)
TYPE=$(jq -r '.notification_type // empty' <<<"$INPUT" 2>/dev/null) || exit 0
MSG=$(jq -r '.message // empty' <<<"$INPUT" 2>/dev/null)
TR=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
TR="${TR/#\~/$HOME}"
[ -n "$TYPE$MSG" ] || exit 0

KIND=info; HEAD="Claude Code"; BODY="$MSG"
case "$TYPE" in
  permission_prompt|worker_permission_prompt)
    KIND=warn; HEAD="Permission needed"
    tool=$(sed -nE 's/.*permission to use (.+)$/\1/p' <<<"$MSG")
    BODY="${tool:+Tool: $tool}"; BODY="${BODY:-$MSG}"
    [ "$TYPE" = worker_permission_prompt ] && HEAD="Worker needs permission" ;;
  idle_prompt)
    HEAD="Waiting for you"; BODY="" ;;
  agent_needs_input)
    KIND=warn; HEAD="Agent needs an answer" ;;
  elicitation_dialog|elicitation_url_dialog)
    KIND=warn; HEAD="Form to fill in" ;;
  agent_completed)
    HEAD="Agent finished" ;;
  auth_success)
    HEAD="Signed in" ;;
  push_notification)
    KIND=warn; HEAD="Message from Claude" ;;
  quota_auto_resume_fired)
    HEAD="Limit reset" ;;
  quota_auto_resume_stale|quota_auto_resume_disabled)
    KIND=warn; HEAD="Auto-resume did not fire" ;;
  model_refusal_fallback)
    KIND=warn; HEAD="Model refused" ;;
  computer_use_enter|computer_use_exit)
    exit 0 ;;
esac

session_notify "$TR" "$KIND" "$HEAD" "$BODY"
exit 0
