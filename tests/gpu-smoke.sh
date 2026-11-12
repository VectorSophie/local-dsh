#!/usr/bin/env bash
# GPU smoke test of an installed local-dsh (uses the real model; takes ~1-3 minutes incl. model load).
# One headless agent task in a throwaway git repo, graded by running the code; then checks that the server
# local-dsh started for it was stopped again. Run it from anywhere: tests/gpu-smoke.sh
set -u
command -v dsh-run >/dev/null || { echo "dsh-run not on PATH (install.sh links it into ~/.local/bin)"; exit 2; }
W=$(mktemp -d /tmp/local-dsh-smoke.XXXXXX); trap 'rm -rf "$W"' EXIT
cd "$W" && git init -q && printf 'def add(a, b):\n    return a - b\n' > calc.py && git add . && git -c user.email=t@t -c user.name=t commit -qm init
before=$(dsh-status | grep -c '^server:   healthy')
t0=$SECONDS
dsh-run "calc.py has a bug: add() subtracts instead of adding. Fix it, then run: python3 -c 'import calc; print(calc.add(2, 3))'" \
  > "$W/run.log" 2>&1; rc=$?
echo "dsh-run exit $rc after $((SECONDS - t0)) s"
if python3 -c 'import calc; assert calc.add(2, 3) == 5 and calc.add(-1, 1) == 0'; then echo "PASS agent fixed calc.py"
else echo "FAIL calc.py not fixed"; tail -20 "$W/run.log"; exit 1; fi
after=$(dsh-status | grep -c '^server:   healthy')
if [ "$before" = 0 ] && [ "$after" = 0 ]; then echo "PASS server started for the task was stopped afterwards"
elif [ "$before" = 1 ]; then echo "INFO a server was already running; it was left running (expected)"
else echo "FAIL server still running after the task"; exit 1; fi
