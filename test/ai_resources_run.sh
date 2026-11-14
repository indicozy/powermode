#!/usr/bin/env bash
# Tests for ai-resources and ai-run against a fake state dir, fake nvidia-smi, fake /proc, fake
# taskset, fake pkill, fake systemctl, fake cgroup tree and fake systemd-run. Runs as a normal user
# and never touches the real state file, the real user manager or real affinities.
# Usage: test/ai_resources_run.sh      exits 0 when every check passes.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AR=$HERE/../ai-resources
ARUN=$HERE/../ai-run
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
OUT=""
RC=0
ME=$(id -u)
CG=/user.slice/user-1000.slice/user@1000.service/app.slice/ai.slice

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; echo "      got: $(printf '%s' "$OUT" | head -5)"; }

# check NAME EXPECTED: compare the whole output of the last command with EXPECTED.
check() {
  if [ "$OUT" = "$2" ]; then ok; else bad "$1 (want '$2')"; fi
}
# check_last NAME EXPECTED: compare only the last output line with EXPECTED.
check_last() {
  if [ "$(printf '%s' "$OUT" | tail -n 1)" = "$2" ]; then ok; else bad "$1 (want last line '$2')"; fi
}
check_rc() {
  if [ "$RC" = "$2" ]; then ok; else bad "$1 exit $RC, want $2"; fi
}
# check_file NAME FILE EXPECTED: the file's whole content equals EXPECTED.
check_file() {
  if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then ok; else bad "$1 (file $2 has '$(cat "$2" 2>/dev/null | tr '\n' ';')')"; fi
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
# Fake systemctl: logs every call; answers ControlGroup from FAKE_CG; fails set-property when FAKE_SYSTEMCTL_FAIL is set.
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "$*" in
  *"show -p ControlGroup"*) [ -n "${FAKE_CG:-}" ] && printf '%s\n' "$FAKE_CG"; exit 0 ;;
  *set-property*) if [ -n "${FAKE_SYSTEMCTL_FAIL:-}" ]; then echo "bus gone" >&2; exit 1; fi ;;
esac
exit 0
EOF
# Fake systemd-run: drops everything up to "--" and runs the command, unless FAKE_SD_FAIL is set.
cat > "$T/bin/systemd-run" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_SD_LOG"
[ -n "${FAKE_SD_FAIL:-}" ] && { echo "Failed to start transient scope" >&2; exit 1; }
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ "$#" -gt 0 ] && shift
exec "$@"
EOF
chmod 0755 "$T/bin/"*

# Fake cgroup tree for ai.slice: a controllers file and processes in the slice and a sub-scope.
make_cgroup() {
  local controllers=$1
  rm -rf "$T/cgroup"
  mkdir -p "$T/cgroup$CG/run-u1.scope"
  printf '%s\n' "$controllers" > "$T/cgroup$CG/cgroup.controllers"
  printf '201\n' > "$T/cgroup$CG/cgroup.procs"
  printf '202\n203\n' > "$T/cgroup$CG/run-u1.scope/cgroup.procs"
}

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
export AI_RESOURCES_SYSTEMCTL=$T/bin/systemctl
export AI_RESOURCES_CGROUP_ROOT=$T/cgroup
export AI_RESOURCES_UNIT_DIR=$T/units
export AI_RESOURCES_PROC=$PROC_DIR
export AI_RUN_SYSTEMD_RUN=$T/bin/systemd-run
export FAKE_TASKSET_LOG=$T/taskset.log
export FAKE_PKILL_LOG=$T/pkill.log
export FAKE_SYSTEMCTL_LOG=$T/systemctl.log
export FAKE_SD_LOG=$T/systemd-run.log
export AI_RESOURCES_STATE=$T/state/mode
unset FAKE_SYSTEMCTL_FAIL FAKE_SD_FAIL

# reset_logs: empty every fake call log.
reset_logs() { : > "$T/taskset.log"; : > "$T/pkill.log"; : > "$T/systemctl.log"; }

# run_ar ARGS...: run ai-resources; sets OUT (stdout and stderr) and RC.
run_ar() {
  OUT=$("$AR" "$@" 2>&1)
  RC=$?
}

# No cpuset on the slice (no cgroup yet): prefix pins with taskset, no AllowedCPUs.
make_cgroup "cpu memory pids"
export FAKE_CG=$CG

# Default: no state file means desk.
[ ! -e "$AI_RESOURCES_STATE" ] || { echo "precondition: state file exists"; exit 1; }
run_ar
check_last "default status" "desk cpus=8-19 gpus=1"; check_rc "default status" 0
run_ar status
check_last "status subcommand" "desk cpus=8-19 gpus=1"
run_ar mode;   check "default mode" "desk"
run_ar cpus;   check "default cpus" "8-19"
run_ar gpus;   check "default gpus" "1"
run_ar prefix; check "default prefix (no cpuset)" "ai-run nice -n 19 taskset -c 8-19"
[ ! -e "$AI_RESOURCES_STATE" ] && ok || bad "read-only commands must not create the state file"

# Slice not running yet (no ControlGroup): no cpuset, so the prefix pins with taskset.
FAKE_CG="" run_ar prefix; check "prefix when slice has no cgroup" "ai-run nice -n 19 taskset -c 8-19"

# Prefix with cpuset: the slice limits CPUs itself, so no taskset in the prefix.
make_cgroup "cpu cpuset memory pids"
run_ar prefix; check "prefix with cpuset" "ai-run nice -n 19"; check_rc "prefix with cpuset" 0
make_cgroup "cpu memory pids"
run_ar prefix; check "prefix without cpuset again" "ai-run nice -n 19 taskset -c 8-19"

# Explicit desk: writes the file, re-pins, refreshes the bar.
reset_logs
run_ar desk
check_last "desk output" "desk cpus=8-19 gpus=1"; check_rc "desk" 0
[ "$(cat "$AI_RESOURCES_STATE")" = desk ] && ok || bad "desk state file content"
[ "$(ls -A "$T/state")" = mode ] && ok || bad "atomic write left temp files: $(ls -A "$T/state")"
run_ar mode; check "desk mode" "desk"
run_ar prefix; check "desk prefix" "ai-run nice -n 19 taskset -c 8-19"
check_rc "desk prefix" 0

# Away: wider cpus and both GPUs; the re-pin widens jobs back to 0-19.
reset_logs
run_ar away
check_last "away output" "away cpus=0-19 gpus=0,1"; check_rc "away" 0
got=$(sort "$T/taskset.log" | tr '\n' ';')
want=$(printf '%s\n' "-a -cp 0-19 100" "-a -cp 0-19 104" "-a -cp 0-19 105" "-a -cp 0-19 201" "-a -cp 0-19 202" "-a -cp 0-19 203" | sort | tr '\n' ';')
[ "$got" = "$want" ] && ok || bad "away re-pin calls: got '$got' want '$want'"
run_ar mode;   check "away mode" "away"
run_ar cpus;   check "away cpus" "0-19"
run_ar gpus;   check "away gpus" "0,1"
run_ar prefix; check "away prefix" "ai-run nice -n 19 taskset -c 0-19"
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

# Desk re-pin: nice-19 processes of this uid and ai.slice processes go to CPUs 8-19; failures ignored.
printf 'away\n' > "$AI_RESOURCES_STATE"
reset_logs
run_ar desk
check "desk output" "re-pinned 3 process(es) in ai.slice to CPUs 8-19
re-pinned 2 nice-19 process(es) to CPUs 8-19
warning: GPU 0 (RTX 5060 Ti) is still in use by these processes (not stopped):
  pid 4242 python3
desk cpus=8-19 gpus=1"
check_rc "desk re-pin run" 0
got=$(sort "$T/taskset.log" | tr '\n' ';')
want=$(printf '%s\n' "-a -cp 8-19 100" "-a -cp 8-19 104" "-a -cp 8-19 105" "-a -cp 8-19 201" "-a -cp 8-19 202" "-a -cp 8-19 203" | sort | tr '\n' ';')
[ "$got" = "$want" ] && ok || bad "taskset calls: got '$got' want '$want'"
grep -q -- '-USR1 -x i3status' "$T/pkill.log" && ok || bad "bar refresh not sent"
grep -q set-property "$FAKE_SYSTEMCTL_LOG" && bad "no cpuset: systemctl must not set AllowedCPUs" || ok

# Status never re-pins or refreshes the bar.
reset_logs
run_ar status
[ ! -s "$T/taskset.log" ] && [ ! -s "$T/pkill.log" ] && ok || bad "status must not re-pin or refresh the bar"

# Without a usable nvidia-smi, desk still works and prints no GPU warning.
OUT=$(AI_RESOURCES_NVIDIA_SMI=$T/missing/nvidia-smi "$AR" desk 2>&1); RC=$?
check_last "desk without nvidia-smi" "desk cpus=8-19 gpus=1"; check_rc "desk without nvidia-smi" 0

# With cpuset on ai.slice: apply sets AllowedCPUs to the state's CPUs.
make_cgroup "cpu cpuset memory pids"
printf 'desk\n' > "$AI_RESOURCES_STATE"
reset_logs
run_ar apply; check_rc "apply desk with cpuset" 0
grep -qx -- "--user set-property ai.slice AllowedCPUs=8-19" "$FAKE_SYSTEMCTL_LOG" && ok || bad "desk AllowedCPUs missing: $(cat "$FAKE_SYSTEMCTL_LOG")"
run_ar away; check_rc "away with cpuset" 0
grep -qx -- "--user set-property ai.slice AllowedCPUs=0-19" "$FAKE_SYSTEMCTL_LOG" && ok || bad "away AllowedCPUs missing: $(cat "$FAKE_SYSTEMCTL_LOG")"
run_ar prefix; check "prefix with cpuset after away" "ai-run nice -n 19"

# A failing systemctl never fails the state change: warning on stderr, state still written.
export FAKE_SYSTEMCTL_FAIL=1
run_ar desk; check_rc "desk with failing systemctl" 0
printf '%s' "$OUT" | grep -q "warning: could not set AllowedCPUs=8-19" && ok || bad "missing warning for failing set-property"
check_file "state written despite systemctl failure" "$AI_RESOURCES_STATE" "desk"
unset FAKE_SYSTEMCTL_FAIL
make_cgroup "cpu memory pids"

# Setup: links the unit into the unit dir, reloads, starts the slice, applies the state.
rm -rf "$T/units"
reset_logs
printf 'desk\n' > "$AI_RESOURCES_STATE"
run_ar setup; check_rc "setup" 0
[ -L "$T/units/ai.slice" ] && [ "$(readlink -f "$T/units/ai.slice")" = "$(readlink -f "$HERE/../systemd/ai.slice")" ] && ok || bad "setup did not link the unit"
grep -qx -- "--user daemon-reload" "$FAKE_SYSTEMCTL_LOG" && ok || bad "setup did not daemon-reload"
grep -qx -- "--user start ai.slice" "$FAKE_SYSTEMCTL_LOG" && ok || bad "setup did not start ai.slice"
check_last "setup prints state" "desk cpus=8-19 gpus=1"

# Apply never mutates the state file and needs no arguments beyond its name.
printf 'away\n' > "$AI_RESOURCES_STATE"
run_ar apply; check_rc "apply" 0
check_file "apply leaves state alone" "$AI_RESOURCES_STATE" "away"

# ai-run: runs the command inside a scope with the right slice; propagates the exit status.
reset_logs
: > "$FAKE_SD_LOG"
OUT=$("$ARUN" sh -c 'exit 3' 2>&1); RC=$?
check_rc "ai-run propagates exit status" 3
grep -q -- "--user --scope --quiet --slice=ai.slice --collect -- sh -c exit 3" "$FAKE_SD_LOG" && ok || bad "ai-run scope args: $(cat "$FAKE_SD_LOG")"
OUT=$("$ARUN" echo hello 2>&1); RC=$?
check "ai-run runs the command" "hello"; check_rc "ai-run ok" 0
OUT=$(FAKE_SD_FAIL=1 "$ARUN" echo fallback 2>&1); RC=$?
check "ai-run fallback runs without scope" "ai-run: warning: could not start an ai.slice scope (no user systemd bus?); running without it
fallback"
check_rc "ai-run fallback" 0
OUT=$("$ARUN" 2>&1); RC=$?
check_rc "ai-run without command" 2

echo "ai_resources_run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
