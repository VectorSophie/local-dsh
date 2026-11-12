#!/usr/bin/env bash
# Bounded real-network test of lib/fetch-model.sh against Hugging Face (about 15 MB of traffic, ~1 minute).
# Uses the default model's 5.8 MB first shard at the pinned revision through a one-file catalog in a temporary
# copy of the repo, so the real downloader code runs without fetching a model. Covers: interrupted download ->
# resume from .part, SHA-256 verification and stamp, re-run without download, corrupt partial (mismatch, .part
# kept), and a permanent HTTP error (fails fast instead of retrying). HF_ENDPOINT selects a mirror.
set -uo pipefail
# never in CI by accident: it needs the network (set LOCAL_DSH_NETWORK_TESTS=1 to run it there on purpose)
if [ "${CI:-}" = true ] && [ -z "${LOCAL_DSH_NETWORK_TESTS:-}" ]; then echo "SKIP network download test in CI"; exit 0; fi
R=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
T=$(mktemp -d /tmp/local-dsh-dl.XXXXXX); trap 'pkill -TERM -P $$ 2>/dev/null; rm -rf "$T"' EXIT
FAIL=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; FAIL=1; }
mkdir -p "$T/repo/models" && cp -r "$R/lib" "$R/versions.env" "$T/repo/"
src=$(awk -F'\t' '$1=="model" && $2=="coder-iq2xxs"' "$R/models/catalog.tsv")
f1=$(awk -F'\t' '$1=="file" && $2=="coder-iq2xxs" && $3 ~ /00001-of-00006/' "$R/models/catalog.tsv")
IFS=$'\t' read -r _ _ PATH1 SIZE SHA <<< "$f1"
{ printf '%s\n' "$src" | sed 's/\tcoder-iq2xxs\t/\tdltest\t/'; printf '%s\n' "$f1" | sed 's/\tcoder-iq2xxs\t/\tdltest\t/'; } > "$T/repo/models/catalog.tsv"
export LOCAL_DSH_HOME=$T/home
M=$T/models; F=$M/$PATH1
fetch() { "$T/repo/lib/fetch-model.sh" dltest "$M"; }

# 1. start, interrupt once some bytes arrived
setsid "$T/repo/lib/fetch-model.sh" dltest "$M" > "$T/1.log" 2>&1 & pid=$!
for _ in $(seq 1 300); do s=$(stat -c %s "$F.part" 2>/dev/null || echo 0); [ "$s" -gt 200000 ] && break; [ -e "$F" ] && break; sleep 0.1; done
kill -TERM -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null
part=$(stat -c %s "$F.part" 2>/dev/null || echo 0)
if [ -e "$F" ]; then echo "SKIP interruption: the 5.8 MB file finished before it could be interrupted (fast link)"
elif [ "$part" -gt 0 ] && [ "$part" -lt "$SIZE" ]; then ok "interrupted download left a partial file ($part of $SIZE bytes) and no final file"
else bad "interruption: .part=$part"; cat "$T/1.log"; fi

# 2. resume to completion; verified and renamed
fetch > "$T/2.log" 2>&1; rc=$?
if [ $rc = 0 ] && [ ! -e "$F.part" ] && [ "$(stat -c %s "$F")" = "$SIZE" ] && echo "$SHA  $F" | sha256sum -c --status; then
  ok "resumed download completed, SHA-256 matches the catalog, .part renamed"
else bad "resume (rc $rc)"; tail -5 "$T/2.log"; fi
grep -q "$PATH1" "$LOCAL_DSH_HOME/state/verified.tsv" && ok "verification stamp written outside the model directory" || bad "stamp"

# 3. re-run: no download, no re-hash
start=$SECONDS; fetch > "$T/3.log" 2>&1; rc=$?
[ $rc = 0 ] && grep -q "ok $PATH1" "$T/3.log" && ! grep -q downloading "$T/3.log" && [ $((SECONDS - start)) -lt 5 ] \
  && ok "re-run accepts the stamped file without downloading" || { bad "re-run"; cat "$T/3.log"; }

# 4. corrupt partial of full size: mismatch is reported, final file not created, .part kept for inspection
rm -f "$F"; head -c "$SIZE" /dev/zero > "$F.part"
fetch > "$T/4.log" 2>&1; rc=$?
[ $rc != 0 ] && grep -q "SHA-256 mismatch" "$T/4.log" && [ ! -e "$F" ] && [ -e "$F.part" ] \
  && ok "corrupt partial: SHA-256 mismatch reported, nothing installed, .part kept" || { bad "corrupt partial (rc $rc)"; cat "$T/4.log"; }
rm -f "$F.part"

# 5. permanent HTTP error (non-existent revision): fails fast with the status, no retry loop
sed -i 's/\t[0-9a-f]\{40\}\t/\t0000000000000000000000000000000000000000\t/' "$T/repo/models/catalog.tsv"
start=$SECONDS; timeout 120 "$T/repo/lib/fetch-model.sh" dltest "$T/models2" > "$T/5.log" 2>&1; rc=$?
[ $rc = 1 ] && grep -qE "HTTP 4[0-9][0-9]" "$T/5.log" && [ $((SECONDS - start)) -lt 60 ] \
  && ok "permanent HTTP error fails fast ($(grep -oE 'HTTP 4[0-9][0-9]' "$T/5.log" | head -1), $((SECONDS - start)) s)" || { bad "HTTP error handling (rc $rc)"; tail -3 "$T/5.log"; }

[ $FAIL = 0 ] && echo "DOWNLOAD TESTS PASSED" || { echo "DOWNLOAD TESTS FAILED"; exit 1; }
