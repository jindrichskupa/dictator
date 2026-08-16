#!/bin/sh
# Called by Claude Code hooks with one argument: the state word.
# Writes "<state> <timestamp>" for the dictator session named by $DICTATOR_ID.
#
# Two rules matter here:
#   - sessions dictator did not create have no DICTATOR_ID, and must be left alone
#   - a non-zero exit blocks Claude Code, so every path exits 0
[ -n "${DICTATOR_ID:-}" ] || exit 0
[ -n "${1:-}" ] || exit 0

root=${DICTATOR_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/dictator}
mkdir -p "$root/state" 2>/dev/null || exit 0
printf '%s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$root/state/$DICTATOR_ID.status" 2>/dev/null
exit 0
