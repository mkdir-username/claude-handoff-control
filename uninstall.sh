#!/usr/bin/env bash
# Removes claude-handoff-control hooks from ~/.claude/settings.json and deletes
# ~/.claude/handoff-control (hooks, rubrics, state and the verdict log).
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "uninstall: 'jq' is required" >&2; exit 1; }

DEST="$HOME/.claude/handoff-control"
SETTINGS="$HOME/.claude/settings.json"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  TMP=$(mktemp)
  jq --arg d "$DEST/hooks/" '
    if .hooks then
      .hooks |= with_entries(
        .value |= ( map(.hooks |= map(select((.command // "") | contains($d) | not)))
                    | map(select((.hooks | length) > 0)) ))
      | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$SETTINGS" > "$TMP" || { rm -f "$TMP"; echo "uninstall: could not update $SETTINGS — nothing removed" >&2; exit 1; }
  mv "$TMP" "$SETTINGS"
fi
rm -rf "$DEST"
echo "claude-handoff-control removed. Restart Claude Code."
