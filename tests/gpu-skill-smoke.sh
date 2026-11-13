#!/usr/bin/env bash
# One real-model skill smoke: discovery -> skill tool load -> instruction-following artifact.
# Requires an installed local-dsh and GPU access. Leaves no changes in the user's repositories.
set -euo pipefail

command -v dsh-run >/dev/null || { echo 'dsh-run not on PATH; install local-dsh first' >&2; exit 2; }
ROOT=$(mktemp -d /tmp/local-dsh-skill.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
cd "$ROOT"
git init -q
mkdir -p .agents/skills/local-dsh-skill-probe
TOKEN=$(python3 -I -c 'import secrets; print("SKILL_PROOF_" + secrets.token_hex(12))')
cat >.agents/skills/local-dsh-skill-probe/SKILL.md <<EOF_SKILL
---
name: local-dsh-skill-probe
description: Load this skill when checking whether local-dsh can discover and follow a skill.
---

To complete this probe, create a file named skill-proof.txt in the current workspace.
Its entire content must be this one line, with a trailing newline:

$TOKEN

Do not put anything else in that file.
EOF_SKILL
git add .agents && git -c user.email=skill-probe@example.invalid -c user.name=skill-probe commit -qm 'Add test skill'

echo 'Running skill probe with the real model (may start the GPU server)...'
if dsh-run --json --permission-mode workspace-write --approval-policy never \
  'Use the skill tool to load local-dsh-skill-probe, then follow its full instructions. Do not read its SKILL.md directly with filesystem tools. Finish after creating the required file.' \
  > "$ROOT/events.jsonl" 2> "$ROOT/stderr.log"; then
  echo 'Agent process exited successfully'
else
  echo 'FAIL: agent process returned a nonzero exit status' >&2
  tail -40 "$ROOT/stderr.log" >&2
  tail -10 "$ROOT/events.jsonl" >&2
  exit 1
fi

python3 -I - "$ROOT/events.jsonl" "$ROOT/skill-proof.txt" "$TOKEN" <<'PY'
import json
import pathlib
import sys

events_path, proof_path, expected = sys.argv[1:]
events = []
for n, line in enumerate(pathlib.Path(events_path).read_text(encoding='utf-8').splitlines(), 1):
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError as exc:
        raise SystemExit(f'FAIL: invalid JSON event at line {n}: {exc}')

calls = [e for e in events if e.get('type') == 'tool_call'
         and e.get('tool') == 'skill'
         and isinstance(e.get('input'), dict)
         and e['input'].get('name') == 'local-dsh-skill-probe']
assert calls, 'FAIL: no real skill-tool invocation in the event stream'
results = {e.get('callId'): e for e in events if e.get('type') == 'tool_result'}
assert any(results.get(call.get('callId'), {}).get('status') == 'completed'
           and expected in str(results[call['callId']].get('result', '')) for call in calls), \
       'FAIL: skill tool was called but its full instructions were not returned'
assert events and events[-1].get('type') == 'final', 'FAIL: no final run event'
assert (events[-1].get('reason') or {}).get('kind') == 'completed', 'FAIL: last turn was not completed'
actual = pathlib.Path(proof_path).read_text(encoding='utf-8') if pathlib.Path(proof_path).is_file() else None
assert actual == expected + '\n', f'FAIL: skill result not followed: {actual!r}'
print('PASS: skill discovered, loaded via the skill tool, and followed by the local model')
PY
