#!/usr/bin/env bash
# Offline test suite: no network, no GPU, no model. Runs in a few minutes.
#   tests/run-offline.sh
set -uo pipefail
R=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
FAIL=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

# 1. static checks
if command -v shellcheck >/dev/null; then
  shellcheck -x -S warning "$R"/install.sh "$R"/uninstall.sh "$R"/bin/local-dsh "$R"/lib/*.sh "$R"/tests/run-offline.sh "$R"/tests/gpu-smoke.sh "$R"/tests/mock/nvidia-smi \
    && ok "shellcheck" || bad "shellcheck"
else echo "SKIP shellcheck (not installed)"; fi
for f in "$R"/install.sh "$R"/uninstall.sh "$R"/bin/local-dsh "$R"/lib/*.sh; do bash -n "$f" || bad "bash -n $f"; done

# 2. catalog: every model has files with size+sha256, its first shard is a file or link, link targets exist
python3 -I - "$R/models/catalog.tsv" <<'PY' && ok "model catalog consistent" || bad "model catalog"
import os, re, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
models = {r[1]: r for r in rows if r[0] == "model"}
assert models, "no models"
for mid, m in models.items():
    assert m[2] in ("verified", "unverified") and re.fullmatch(r"[0-9a-f]{40}", m[4]), m
    files = {r[2]: r for r in rows if r[0] == "file" and r[1] == mid}
    links = {r[2]: r[3] for r in rows if r[0] == "link" and r[1] == mid}
    assert files and all(re.fullmatch(r"[0-9a-f]{64}", f[4]) and int(f[3]) > 0 for f in files.values()), mid
    assert m[5] in files or m[5] in links, f"{mid}: first shard {m[5]} not listed"
    for l, t in links.items():
        assert os.path.normpath(os.path.join(os.path.dirname(l), t)) in files, f"{mid}: link {l} -> {t} dangling"
assert all(r[1] in models for r in rows), "row for an unknown model"
PY

# 2b. lockfiles pin exactly the versions in versions.env, from the public npm registry, with integrity hashes
python3 -I - "$R" <<'PY' && ok "lockfiles match versions.env" || bad "lockfiles"
import json, re, sys
r = sys.argv[1]
v = dict(re.findall(r"^(\w+)=(\S+)", open(f"{r}/versions.env").read(), re.M))
lock = json.load(open(f"{r}/lock/dsh/package-lock.json"))
pk = lock["packages"]
assert lock["packages"][""]["dependencies"] == json.load(open(f"{r}/lock/dsh/package.json"))["dependencies"]
assert pk["node_modules/@deepseek-ai/dsh"]["version"] == v["DSH_VERSION"] and pk["node_modules/pnpm"]["version"] == v["PNPM_VERSION"]
assert all(p.get("integrity") and p["resolved"].startswith("https://registry.npmjs.org/") for k, p in pk.items() if k and "resolved" in p)
tui = open(f"{r}/lock/dsh-tui/pnpm-lock.yaml").read()
assert f"specifier: {v['DSH_TUI_VERSION']}" in tui and f"version: {v['DSH_TUI_VERSION']}" in tui
assert not re.search(r"/home/|/data/|_authToken", json.dumps(lock) + tui)
PY

# 3. preset generator on a synthetic fixture
F=$R/tests/fixtures/standard.patch.yml
ins=$(python3 -I "$R/lib/preset_without_tool_web.py" "$F" insert) && pat=$(python3 -I "$R/lib/preset_without_tool_web.py" "$F" patch) \
  && ! grep -q tool-web <<<"$ins$pat" && grep -q "^- insert:" <<<"$ins" && grep -q "^- id: preset-standard" <<<"$pat" \
  && grep -q "compaction-basic" <<<"$pat" && grep -q "id: present" <<<"$ins" \
  && ok "preset generator removes only tool-web" || bad "preset generator"

# 4. installer hardware/dependency report with fake GPUs (changes nothing)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
out=$(PATH=$R/tests/mock:$PATH LOCAL_DSH_HOME=$T/h "$R/install.sh" --check 2>&1); rc=$?
if grep -q "coder-iq2xxs .*verified .*fits=yes" <<<"$out" && grep -q "GPU 1: RTX PRO 6000, 96 GB" <<<"$out"; then ok "installer --check: 2x96 GB fits the verified model (rc $rc)"
else bad "installer --check 2x96 GB"; echo "$out" | tail -15; fi
out=$(PATH=$R/tests/mock:$PATH MOCK_GPUS="RTX 4090:24564:24000:8.9" LOCAL_DSH_HOME=$T/h "$R/install.sh" --check 2>&1)
grep -q "coder-iq2xxs .*fits=no" <<<"$out" && ok "installer --check: 1x24 GB fits nothing" || { bad "installer --check 24 GB"; echo "$out" | tail -8; }
[ ! -e "$T/h" ] && ok "installer --check wrote nothing" || bad "installer --check created $T/h"

# 5. uninstall touches only what this installation owns
H=$T/inst; B=$T/bin; M=$T/shared-models; mkdir -p "$H/state" "$H/node-dsh-x" "$B" "$M/IQ2_XXS"
for f in IQ2_XXS/DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder-IQ2_XXS-00002-of-00006.gguf DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf; do echo x > "$M/$f"; done
printf 'MODEL_ID=coder-iq2xxs\nMODEL_DIR=%s\nDSH_HOME=%s/dsh-home\nNODE_DIR=/nonexistent\n' "$M" "$H" > "$H/config.env"
printf '#!/usr/bin/env bash\n# local-dsh command for LOCAL_DSH_HOME=%s\nexit 0\n' "$H" > "$B/dsh-tui"
printf '#!/usr/bin/env bash\n# local-dsh command for LOCAL_DSH_HOME=/some/other/install\nexit 0\n' > "$B/dst"
echo "foreign" > "$B/dsh-web"
printf '%s\n' "$B/dsh-tui" "$B/dst" "$B/dsh-web" > "$H/state/links.txt"
LOCAL_DSH_HOME=$H "$R/uninstall.sh" --purge-models > "$T/u1.log" 2>&1
if [ ! -e "$B/dsh-tui" ] && [ -e "$B/dst" ] && [ -e "$B/dsh-web" ] && [ ! -e "$H/node-dsh-x" ] && [ -e "$H/config.env" ] \
  && [ -e "$M/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf" ] && grep -q "may be shared" "$T/u1.log"; then
  ok "uninstall: removes only its own wrapper and builds; keeps another install's wrapper, foreign files and an outside model dir"
else bad "uninstall ownership"; cat "$T/u1.log"; ls -la "$B" "$M"; fi
mkdir -p "$H/models/IQ2_XXS" && echo x > "$H/models/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf" && echo keep > "$H/models/notes.txt"
sed -i "s|^MODEL_DIR=.*|MODEL_DIR=$H/models|" "$H/config.env"
LOCAL_DSH_HOME=$H "$R/uninstall.sh" --purge-models > "$T/u2.log" 2>&1
[ ! -e "$H/models/DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf" ] && [ -e "$H/models/notes.txt" ] \
  && ok "uninstall --purge-models: deletes only catalog files inside the install" || { bad "uninstall --purge-models"; cat "$T/u2.log"; }
LOCAL_DSH_HOME=$H "$R/uninstall.sh" --purge > "$T/u3.log" 2>&1
[ ! -e "$H" ] && [ -e "$M" ] && ok "uninstall --purge: removes the install directory only" || { bad "uninstall --purge"; cat "$T/u3.log"; }
LOCAL_DSH_HOME=$HOME "$R/uninstall.sh" --purge > "$T/u4.log" 2>&1 && bad "uninstall accepted LOCAL_DSH_HOME=\$HOME" || ok "uninstall refuses a non-dedicated LOCAL_DSH_HOME"

# 6. launcher lifecycle (mock server + mock dsh; gpuq backend only if task-spooler is present)
python3 -I "$R/tests/test_launcher.py" || FAIL=1

[ $FAIL = 0 ] && echo "ALL OFFLINE TESTS PASSED" || { echo "SOME OFFLINE TESTS FAILED"; exit 1; }
