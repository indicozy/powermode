#!/usr/bin/env bash
# Tests for claude-hook against a fake state file, fake power file, fake lock and a temp seen dir.
# Never touches the real state, the real seen dir or the real /run/powermode.
# Usage: test/claude_hook_run.sh      exits 0 when every check passes.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK=$HERE/../claude-hook
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
OUT=""
RC=0

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; echo "      got: $(printf '%s' "$OUT" | head -c 300)"; }

export AI_RESOURCES_STATE=$T/state/mode
export AI_RESOURCES_SEEN_DIR=$T/seen
export POWERMODE_RUN_FILE=$T/run/powermode
export POWERMODE_LOCK_FILE=$T/config/lock
mkdir -p "$T/state" "$T/run"
printf 'silent\n' > "$POWERMODE_RUN_FILE"
printf 'desk\n' > "$AI_RESOURCES_STATE"
[ -e "$POWERMODE_LOCK_FILE" ] && { echo "precondition: lock exists"; exit 1; }

# run_hook SESSION EVENT: send a hook document on stdin; sets OUT and RC.
run_hook() {
  OUT=$(printf '{"session_id":"%s","hook_event_name":"%s","prompt":"x"}' "$1" "$2" | "$HOOK" 2>&1)
  RC=$?
}
# json_field KEY: the named field of the hook output in OUT, validated as JSON.
json_field() {
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
print(h[sys.argv[1]] if sys.argv[1] in h else "")
' "$1"
}

# First sight: JSON with the desk text, and the state is recorded.
run_hook s-first UserPromptSubmit
[ "$RC" = 0 ] && ok || bad "first call exit $RC"
[ "$(json_field hookEventName)" = UserPromptSubmit ] && ok || bad "first call event name"
ctx=$(json_field additionalContext)
case "$ctx" in *"desk — AI work may use CPUs 8-19 and GPU index 1 only"*"Power mode: silent"*) ok ;; *) bad "first call desk text: $ctx" ;; esac
case "$ctx" in *"ai-resources prefix"*"turbo needs explicit permission"*) ok ;; *) bad "first call guidance text" ;; esac
[ -f "$AI_RESOURCES_SEEN_DIR/s-first" ] && ok || bad "seen file not written"

# Identical state: nothing printed.
run_hook s-first UserPromptSubmit
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok || bad "unchanged state must print nothing"

# Same session, other event name: still unchanged, still silent.
run_hook s-first PostToolUse
[ -z "$OUT" ] && ok || bad "unchanged state on PostToolUse must print nothing"

# Change to away: CHANGED text, widened resources, no GPU 0 warning.
printf 'away\n' > "$AI_RESOURCES_STATE"
run_hook s-first PostToolUse
[ "$RC" = 0 ] && ok || bad "changed call exit $RC"
ctx=$(json_field additionalContext)
[ "$(json_field hookEventName)" = PostToolUse ] && ok || bad "changed event name"
case "$ctx" in *"Resources CHANGED by the owner: now away"*"You may use CPUs 0-19 and GPUs 0,1 for new work."*) ok ;; *) bad "changed to away text: $ctx" ;; esac
case "$ctx" in *"Stop or move"*) bad "away must not ask to move GPU 0 work" ;; *) ok ;; esac

# Back to desk: the GPU 0 instruction appears.
printf 'desk\n' > "$AI_RESOURCES_STATE"
run_hook s-first UserPromptSubmit
ctx=$(json_field additionalContext)
case "$ctx" in *"CHANGED by the owner: now desk"*"Stop or move any of your work on GPU 0 (RTX 5060 Ti) now"*) ok ;; *) bad "changed to desk text: $ctx" ;; esac

# A power-mode change alone is a change too; a lock is reported as locked.
printf 'turbo\n' > "$POWERMODE_RUN_FILE"
run_hook s-first UserPromptSubmit
ctx=$(json_field additionalContext)
case "$ctx" in *"Power mode: turbo"*) ok ;; *) bad "power change not reported: $ctx" ;; esac
mkdir -p "$(dirname "$POWERMODE_LOCK_FILE")"; printf 'silent\n' > "$POWERMODE_LOCK_FILE"
run_hook s-first UserPromptSubmit
ctx=$(json_field additionalContext)
case "$ctx" in *"locked to silent by the owner"*) ok ;; *) bad "lock not reported: $ctx" ;; esac
rm -f "$POWERMODE_LOCK_FILE"

# A new session sees the current state as first sight, even though s-first has seen it.
run_hook s-second UserPromptSubmit
ctx=$(json_field additionalContext)
case "$ctx" in *"Machine resources (live, set by the owner): desk"*) ok ;; *) bad "second session first sight: $ctx" ;; esac

# Missing power file reads as "?".
rm -f "$POWERMODE_RUN_FILE"
run_hook s-third UserPromptSubmit
ctx=$(json_field additionalContext)
case "$ctx" in *"Power mode: ?."*) ok ;; *) bad "missing power file: $ctx" ;; esac

# Garbage stdin: exit 0 and silent.
OUT=$(printf 'not json at all' | "$HOOK" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "garbage stdin must exit 0 silently"
OUT=$(printf '' | "$HOOK" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "empty stdin must exit 0 silently"
OUT=$(printf '[1,2]' | "$HOOK" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "array stdin must exit 0 silently"
run_hook s-x "bad event!"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "bad event name must exit 0 silently"
OUT=$(printf '{"session_id":"s-y"}' | "$HOOK" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "missing event name must exit 0 silently"

# Weird session id is sanitized: no path escape, the file is named by the cleaned id.
run_hook "../../evil id/../x" PostToolUse
[ "$RC" = 0 ] && ok || bad "weird session id exit $RC"
[ -f "$AI_RESOURCES_SEEN_DIR/evilidx" ] && ok || bad "sanitized seen file missing: $(ls -A "$AI_RESOURCES_SEEN_DIR")"
[ ! -e "$T/evil" ] && [ ! -e "$T/x" ] && ok || bad "session id escaped the seen dir"
[ -z "$(printf '%s' '{"session_id":"..."}' | "$HOOK" 2>&1)" ] && ok || bad "dots-only session id must be silent"

# The python JSON fallback gives the same answer as jq.
export AI_RESOURCES_HOOK_JSON=python
run_hook s-py UserPromptSubmit
[ "$RC" = 0 ] && [ "$(json_field hookEventName)" = UserPromptSubmit ] && ok || bad "python JSON path"
unset AI_RESOURCES_HOOK_JSON

echo "claude_hook_run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
