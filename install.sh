#!/usr/bin/env bash
# Installs claude-handoff-control into ~/.claude/handoff-control and registers its hooks in
# ~/.claude/settings.json. Idempotent; backs up settings.json before changing it.
set -euo pipefail

for tool in jq curl python3 perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install: '$tool' is required but not found in PATH" >&2; exit 1; }
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/handoff-control"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
  || { echo "install: $SETTINGS is not a valid JSON object — fix it first, nothing was changed" >&2; exit 1; }

mkdir -p "$DEST"
rm -rf "$DEST/hooks" "$DEST/rubrics"
cp -R "$SRC/hooks" "$SRC/rubrics" "$DEST/"
chmod +x "$DEST"/hooks/*.sh

cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"

STOP="bash \"$DEST/hooks/stop-handoff-control.sh\""
CACHE="bash \"$DEST/hooks/prompt-cache.sh\""
LESSON="bash \"$DEST/hooks/lesson-surface.sh\""

TMP=$(mktemp)
jq --arg stop "$STOP" --arg cache "$CACHE" --arg lesson "$LESSON" '
  def add($event; $cmd; $timeout):
    if ([.hooks[$event][]?.hooks[]?.command] | index($cmd)) then .
    else .hooks[$event] = ((.hooks[$event] // []) + [{hooks:[{type:"command", command:$cmd, timeout:$timeout}]}])
    end;
  .hooks = (.hooks // {})
  | add("Stop"; $stop; 120)
  | add("UserPromptSubmit"; $cache; 10)
  | add("UserPromptSubmit"; $lesson; 10)
' "$SETTINGS" > "$TMP" || { rm -f "$TMP"; echo "install: could not update $SETTINGS" >&2; exit 1; }
mv "$TMP" "$SETTINGS"

cat <<MSG
claude-handoff-control installed to $DEST
Hooks registered in $SETTINGS (backup saved next to it).

Next: give the judge an API key, e.g. in your shell profile:
  export DEEPSEEK_API_KEY=sk-...             # or HANDOFF_CTL_API_KEY
Optional: HANDOFF_CTL_MODEL (default deepseek-flash), HANDOFF_CTL_API_URL — any Anthropic
Messages–compatible endpoint.
Restart Claude Code for the hooks to load.
MSG
