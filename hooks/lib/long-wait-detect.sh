#!/usr/bin/env bash
# Longest pause in seconds from `sleep N` in a command line.
# `timeout N` is a ceiling, not a pause, so it is not counted.
long_wait_seconds() {
  local n
  n=$(printf '%s' "$1" \
      | command grep -oE '(^|[^[:alnum:]_-])sleep[[:space:]]+[0-9]+' \
      | command grep -oE '[0-9]+$' | sort -n | tail -1)
  echo "${n:-0}"
}
