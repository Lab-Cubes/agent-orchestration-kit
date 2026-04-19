#!/usr/bin/env bash
# check-secrets.sh — scan for hardcoded secrets and personal paths
#
# Apache 2.0 — see LICENSE at repo root.
#
# Exits 0 if clean, 1 if any violation found.
# Emits GitHub Actions annotations (::error file=X,line=Y::) for CI and local use.
#
# Run locally before pushing:
#   ./scripts/check-secrets.sh
#
# Patterns blocked:
#   - Personal home directory paths: /Users/<user>/, /home/<user>/, /mnt/c/Users/<user>/
#   - Anthropic API keys: sk-ant-...
#   - OpenAI API keys: sk-proj-...
#   - GitHub tokens: ghp_, gho_, ghu_, ghs_
#   - AWS access keys: AKIA[A-Z0-9]{16}
#   - Discord bot tokens

set -uo pipefail

VIOLATIONS=0
SCRIPT_PATH="scripts/check-secrets.sh"
WORKFLOW_PATH=".github/workflows/secrets-check.yml"

emit_error() {
  local file="$1" line="$2" pattern_name="$3" match="$4"
  echo "::error file=${file},line=${line}::${pattern_name} detected: ${match}"
  VIOLATIONS=$((VIOLATIONS + 1))
}

scan_pattern() {
  local pattern_name="$1"
  local grep_pattern="$2"

  # git grep for tracked files; fall back to grep for untracked/pre-commit context
  if git rev-parse --git-dir > /dev/null 2>&1; then
    results=$(git grep -nP "$grep_pattern" -- \
      ":!${SCRIPT_PATH}" \
      ":!${WORKFLOW_PATH}" \
      ":!*.example.*" \
      ":!*.example" \
      2>/dev/null || true)
  else
    results=$(grep -rnP "$grep_pattern" . \
      --exclude="${SCRIPT_PATH##*/}" \
      --exclude="${WORKFLOW_PATH##*/}" \
      --exclude="*.example.*" \
      --exclude="*.example" \
      2>/dev/null || true)
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # format: file:linenum:content
    file=$(echo "$line" | cut -d: -f1)
    linenum=$(echo "$line" | cut -d: -f2)
    match=$(echo "$line" | cut -d: -f3- | sed 's/^[[:space:]]*//')
    emit_error "$file" "$linenum" "$pattern_name" "$match"
  done <<< "$results"
}

# Personal home-directory paths (any username)
scan_pattern "personal-path(macOS)"  '/Users/[^/[:space:]]+/'
scan_pattern "personal-path(Linux)"  '/home/[^/[:space:]]+/'
scan_pattern "personal-path(WSL)"    '/mnt/c/Users/[^/[:space:]]+/'

# API keys and tokens
scan_pattern "anthropic-key"   'sk-ant-[A-Za-z0-9_-]+'
scan_pattern "openai-key"      'sk-proj-[A-Za-z0-9_-]+'
scan_pattern "github-token"    'gh[pouhs]_[A-Za-z0-9]+'
scan_pattern "aws-access-key"  'AKIA[A-Z0-9]{16}'
scan_pattern "discord-token"   '(MT|NT|OT|NDC)[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}'

if [[ "$VIOLATIONS" -gt 0 ]]; then
  echo ""
  echo "check-secrets: $VIOLATIONS violation(s) found. Resolve before pushing."
  exit 1
else
  echo "check-secrets: clean."
  exit 0
fi
