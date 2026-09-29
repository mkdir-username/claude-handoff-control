#!/usr/bin/env bash
# Masks secrets in text that leaves the machine (error snippets sent to the judge).
# Patterns work in both ERE and perl: no \d, no POSIX classes.

SECRET_TOKEN_PATTERNS=(
  'Anthropic API key|sk-ant-[A-Za-z0-9_-]{20,}'
  'OpenAI API key|sk-(proj-)?[A-Za-z0-9_-]{20,}'
  'GitHub token|gh[pousr]_[A-Za-z0-9]{36,}'
  'GitHub fine-grained token|github_pat_[A-Za-z0-9_]{22,}'
  'JWT token|eyJ[A-Za-z0-9+/_-]{10,}\.[A-Za-z0-9+/._-]{10,}\.[A-Za-z0-9+/_-]{10,}'
  'Slack token|xox[baprs]-[0-9A-Za-z-]{10,}'
  'AWS access key|AKIA[0-9A-Z]{16}'
)

# Keeps the key name, drops the value. Only `=` and JSON form: a colon in prose
# ("token: expires soon") would eat words. `$VAR` after `=` is a reference, not a value.
read -r -d '' _SECRET_KV_PERL <<'PERL' || true
s#(Bearer\s+)[A-Za-z0-9._~+/-]{16,}=*#${1}***#gi;
s#\b((?:[A-Za-z0-9]+_)*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)\s*=\s*["']?)(?!\$)[^\s"'&,;]{6,}#${1}***#gi;
s#("(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)"\s*:\s*")[^"]{6,}"#${1}***"#gi;
PERL

# stdin → stdout
mask_secrets() {
  local prog="" entry
  for entry in "${SECRET_TOKEN_PATTERNS[@]}"; do
    prog+="s#${entry#*|}#***#g;"
  done
  perl -pe "${prog}${_SECRET_KV_PERL}"
}
