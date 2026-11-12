#!/usr/bin/env bash
# Download (resumable), verify and link one catalog model.
# usage: fetch-model.sh <model-id> <model-dir> [full|size]
#   full (default): every file is SHA-256 checked once; the result is stamped in $LOCAL_DSH_HOME/state
#   size: files already present are accepted on exact size (downloads are always hashed)
# Downloads go to <file>.part (curl -C - resumes after any interruption, including re-running install.sh) and
# are renamed only after the size and the pinned SHA-256 match. HF_ENDPOINT selects a mirror.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
ID=$1; DIR=$2; VERIFY=${3:-full}
STAMPS=$LOCAL_DSH_HOME/state/verified.tsv
mkdir -p "$DIR" "$(dirname "$STAMPS")"; touch "$STAMPS"
IFS=$'\t' read -r _status REPO REV _first _ < <(catalog "$ID" model) || die "unknown model id: $ID"
BASE=${HF_ENDPOINT:-https://huggingface.co}/$REPO/resolve/$REV

stamped() { grep -qxF "$1"$'\t'"$2"$'\t'"$(stat -Lc %Y "$1")"$'\t'"$3" "$STAMPS"; }
stamp() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(stat -Lc %Y "$1")" "$3" >> "$STAMPS"; }

fetch() {  # path size sha
  local f=$DIR/$1 try have rc
  mkdir -p "$(dirname "$f")"
  for try in $(seq 1 200); do
    have=$(stat -c %s "$f.part" 2>/dev/null || echo 0)
    [ "$have" -ge "$2" ] && break
    # -C - resumes; the low-speed abort turns a stalled connection into a retry
    code=$(curl -fL -C - --connect-timeout 30 --speed-limit 10000 --speed-time 120 --progress-bar \
      -w '%{http_code}' -o "$f.part" "$BASE/$1")
    rc=$?; [ $rc = 0 ] && continue
    # a permanent HTTP error (wrong revision/path, gated or missing repo) is not worth 200 retries
    case $code in 408|429) ;; 4??) die "$1: HTTP $code from $BASE/$1 (not retrying; check the catalog revision, HF_ENDPOINT or proxy)" ;; esac
    say "curl exit $rc at $(stat -c %s "$f.part" 2>/dev/null || echo 0) bytes; retry $try in 20 s (safe to interrupt and re-run)"
    sleep 20
  done
  [ "$(stat -c %s "$f.part" 2>/dev/null)" = "$2" ] || die "$1: size mismatch after retries (partial file kept: $f.part)"
  say "verifying SHA-256 of $1"
  echo "$3  $f.part" | sha256sum -c --status || die "$1: SHA-256 mismatch (partial file kept: $f.part; delete it to restart)"
  mv "$f.part" "$f"; stamp "$f" "$2" "$3"
}

while IFS=$'\t' read -r path size sha; do
  f=$DIR/$path
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    have=$(stat -c %s "$f")
    [ "$have" = "$size" ] || die "$path exists with $have bytes, expected $size; move it away and re-run"
    if [ "$VERIFY" = size ] || stamped "$f" "$size" "$sha"; then say "ok $path"; continue; fi
    say "verifying SHA-256 of existing $path ($((size / 1000000000)) GB)"
    echo "$sha  $f" | nice -n 19 sha256sum -c --status || die "$path: SHA-256 mismatch; move it away and re-run to download"
    stamp "$f" "$size" "$sha"; say "ok $path"
  else
    say "downloading $path ($((size / 1000000000)) GB) from $REPO@${REV:0:8}"
    fetch "$path" "$size" "$sha"
  fi
done < <(catalog "$ID" file)

while IFS=$'\t' read -r link target; do
  l=$DIR/$link
  if [ -L "$l" ] && [ "$(readlink "$l")" = "$target" ]; then say "ok link $link"; continue; fi
  [ -e "$l" ] && die "$link exists and is not the expected link to $target"
  ln -s "$target" "$l" && say "linked $link -> $target"
done < <(catalog "$ID" link)
say "model $ID complete in $DIR"
