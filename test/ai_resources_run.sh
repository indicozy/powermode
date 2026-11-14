#!/usr/bin/env bash
# Tests for ai-resources against a fake state dir, fake nvidia-smi, fake /proc, fake taskset and
# fake pkill. Runs as a normal user and never touches the real state file.
# Usage: test/ai_resources_run.sh      exits 0 when every check passes.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AR=$HERE/../ai-resources
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
OUT=""
RC=0
ME=$(id -u)

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; echo "      got: $(printf '%s' "$OUT" | head -5)"; }

# check NAME EXPECTED: compare the whole output of the last command with EXPECTED.
check() {
  if [ "$OUT" = "$2" ]; then ok; else bad "$1 (want '$2')"; fi
}
# check_last NAME EXPECTED: compare only the last output line (the status line) with EXPECTED.
check_last() {
  if [ "$(printf '%s' "$OUT" | tail -n 1)" = "$2" ]; then ok; else bad "$1 (want last line '$2')"; fi
}
check_rc() {
  if [ "$RC" = "$2" ]; then ok; else bad "$1 exit $RC, want $2"; fi
}

# Fake nvidia-smi: GPU 0 is uuid aaa (5060 Ti), GPU 1 is uuid bbb (4060). Process 4242 runs on GPU 0.
mkdir -p "$T/bin"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/bin/sh
case "$*" in
  *--query-gpu=index,uuid*) printf '0, GPU-aaa\n1, GPU-bbb\n' ;;
  *--query-compute-apps*) printf 'GPU-aaa, 4242, python3\nGPU-bbb, 99, other\n' ;;
esac
exit 0
EOF
cat > "$T/bin/taskset" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_TASKSET_LOG"
case "$*" in *" 105") exit 1 ;; esac
exit 0
EOF
cat > "$T/bin/pkill" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_PKILL_LOG"
exit 0
EOF
chmod 0755 "$T/bin/"*

# Fake /proc: make_proc_entry PID COMM NICE UID writes stat and status files.
PROC_DIR=$T/proc
mkdir -p "$PROC_DIR"
make_proc_entry() {
  local pid=$1 comm=$2 nice=$3 uid=$4
  mkdir -p "$PROC_DIR/$pid"
  printf '%s (%s) S 1 %s %s 0 -1 4194560 0 0 0 0 0 0 0 0 20 %s 1 0 0 0\n' \
    "$pid" "$comm" "$pid" "$pid" "$nice" > "$PROC_DIR/$pid/stat"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" > "$PROC_DIR/$pid/status"
}
make_proc_entry 100 sleeper 19 "$ME"        # nice 19, ours: re-pinned
make_proc_entry 101 busy 0 "$ME"            # nice 0: left alone
make_proc_entry 102 nightly 19 0            # nice 19 but root's: left alone
make_proc_entry 104 "my (weird) app" 19 "$ME"  # nice 19 with parens and spaces in comm: re-pinned
make_proc_entry 105 flaky 19 "$ME"          # nice 19, taskset fails: attempted, not counted
mkdir -p "$PROC_DIR/103"                    # vanished mid-scan (no stat file): skipped
printf 'Name:\tgone\n' > "$PROC_DIR/103/status"

export AI_RESOURCES_NVIDIA_SMI=$T/bin/nvidia-smi
export AI_RESOURCES_TASKSET=$T/bin/taskset
export AI_RESOURCES_PKILL=$T/bin/pkill
export AI_RESOURCES_PROC=$PROC_DIR
export FAKE_TASKSET_LOG=$T/taskset.log
export FAKE_PKILL_LOG=$T/pkill.log
export AI_RESOURCES_STATE=$T/state/mode

# run_ar ARGS...: run ai-resources; sets OUT (stdout and stderr) and RC.
run_ar() {
  OUT=$("$AR" "$@" 2>&1)
  RC=$?
}

# Default: no state file means desk.
[ ! -e "$AI_RESOURCES_STATE" ] || { echo "precondition: state file exists"; exit 1; }
run_ar
check_last "default status" "desk cpus=8-19 gpus=1"; check_rc "default status" 0
run_ar status
check_last "status subcommand" "desk cpus=8-19 gpus=1"
run_ar mode;   check "default mode" "desk"
run_ar cpus;   check "default cpus" "8-19"
run_ar gpus;   check "default gpus" "1"
run_ar prefix; check "default prefix" "nice -n 19 taskset -c 8-19"
[ ! -e "$AI_RESOURCES_STATE" ] && ok || bad "read-only commands must not create the state file"

# Explicit desk: writes the file, re-pins, refreshes the bar.
: > "$T/taskset.log"; : > "$T/pkill.log"
run_ar desk
check_last "desk output" "desk cpus=8-19 gpus=1"; check_rc "desk" 0
[ "$(cat "$AI_RESOURCES_STATE")" = desk ] && ok || bad "desk state file content"
[ "$(ls -A "$T/state")" = mode ] && ok || bad "atomic write left temp files: $(ls -A "$T/state")"
run_ar mode; check "desk mode" "desk"
run_ar prefix; check "desk prefix" "nice -n 19 taskset -c 8-19"
check_rc "desk prefix" 0

# Away: no re-pin, wider cpus and both GPUs.
: > "$T/taskset.log"; : > "$T/pkill.log"
run_ar away
check_last "away output" "away cpus=0-19 gpus=0,1"; check_rc "away" 0
[ ! -s "$T/taskset.log" ] && ok || bad "switching to away must not re-pin: $(cat "$T/taskset.log")"
run_ar mode;   check "away mode" "away"
run_ar cpus;   check "away cpus" "0-19"
run_ar gpus;   check "away gpus" "0,1"
run_ar prefix; check "away prefix" "nice -n 19 taskset -c 0-19"
run_ar status; check "away status" "away cpus=0-19 gpus=0,1"

# Toggle: away -> desk -> away.
run_ar toggle; check_last "toggle from away" "desk cpus=8-19 gpus=1"
run_ar toggle; check_last "toggle from desk" "away cpus=0-19 gpus=0,1"

# Invalid state file means desk.
printf 'bogus\n' > "$AI_RESOURCES_STATE"
run_ar status; check_last "invalid state status" "desk cpus=8-19 gpus=1"
run_ar mode;   check "invalid state mode" "desk"
printf 'AWAY\n' > "$AI_RESOURCES_STATE"
run_ar mode;   check "uppercase state is invalid" "desk"
printf '' > "$AI_RESOURCES_STATE"
run_ar mode;   check "empty state is desk" "desk"
printf 'away\n' > "$AI_RESOURCES_STATE"
run_ar mode;   check "away with newline" "away"

# Bogus arguments exit 2.
run_ar frobnicate; check_rc "bogus arg" 2
run_ar mode extra; check_rc "extra arg" 2
run_ar DESK;       check_rc "uppercase arg" 2

# The re-pin: only nice-19 processes of this uid are re-pinned, all threads, failures ignored.
printf 'away\n' > "$AI_RESOURCES_STATE"
: > "$T/taskset.log"; : > "$T/pkill.log"
run_ar desk
check "re-pin output" "re-pinned 2 nice-19 process(es) to CPUs 8-19
warning: GPU 0 (RTX 5060 Ti) is still in use by these processes (not stopped):
  pid 4242 python3
desk cpus=8-19 gpus=1"
check_rc "re-pin run" 0
got=$(sort "$T/taskset.log" | tr '\n' ';')
want=$(printf '%s\n' "-a -cp 8-19 100" "-a -cp 8-19 104" "-a -cp 8-19 105" | sort | tr '\n' ';')
[ "$got" = "$want" ] && ok || bad "taskset calls: got '$got' want '$want'"
grep -q -- '-USR1 -x i3status' "$T/pkill.log" && ok || bad "bar refresh not sent"

# Status and away never call taskset or pkill with state changes.
: > "$T/taskset.log"; : > "$T/pkill.log"
run_ar status
[ ! -s "$T/taskset.log" ] && [ ! -s "$T/pkill.log" ] && ok || bad "status must not re-pin or refresh the bar"

# Without a usable nvidia-smi, desk still works and prints no GPU warning.
OUT=$(AI_RESOURCES_NVIDIA_SMI=$T/missing/nvidia-smi "$AR" desk 2>&1); RC=$?
check_last "desk without nvidia-smi" "desk cpus=8-19 gpus=1"; check_rc "desk without nvidia-smi" 0

echo "ai_resources_run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
