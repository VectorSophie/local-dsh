#!/usr/bin/env bash
# Remove one local-dsh installation (the one at $LOCAL_DSH_HOME, default ~/.local/share/local-dsh).
#   ./uninstall.sh                  stop the server this install started; remove its commands, builds and dsh install
#                                   (keeps config.env, dsh-home with your sessions, logs and the model files)
#   ./uninstall.sh --purge          also delete $LOCAL_DSH_HOME itself (config, sessions, logs)
#   ./uninstall.sh --purge-models   also delete this model's catalog files, only if the model directory is
#                                   inside $LOCAL_DSH_HOME (a directory elsewhere may be shared; delete it yourself)
# Only resources this installation owns are touched: command wrappers carrying its marker line, files under
# $LOCAL_DSH_HOME, and the server recorded in its own run/server.owner.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"
PURGE=0 MODELS=0
for a in "$@"; do case $a in --purge) PURGE=1 ;; --purge-models) MODELS=1 ;; *) die "unknown option $a" ;; esac; done
[ -f "$CONFIG" ] || die "no local-dsh installation at $LOCAL_DSH_HOME (no config.env); set LOCAL_DSH_HOME"
case $LOCAL_DSH_HOME in "$HOME"|/|/home|/data|"") die "refusing: LOCAL_DSH_HOME=$LOCAL_DSH_HOME is not a dedicated directory" ;; esac
source_config

[ -f "$RUN/server.owner" ] && LOCAL_DSH_HOME=$LOCAL_DSH_HOME "$LOCAL_DSH_REPO/bin/local-dsh" dsh-stop
MARK="# local-dsh command for LOCAL_DSH_HOME=$LOCAL_DSH_HOME"
if [ -f "$LOCAL_DSH_HOME/state/links.txt" ]; then
  while read -r l; do
    if [ -f "$l" ] && [ ! -L "$l" ] && [ "$(sed -n 2p "$l")" = "$MARK" ]; then rm -f "$l" && say "removed $l"
    elif [ -L "$l" ] && [ "$(readlink "$l")" = "$LOCAL_DSH_REPO/bin/local-dsh" ]; then rm -f "$l" && say "removed $l"
    elif [ -e "$l" ]; then say "kept $l (not this installation's)"; fi
  done < "$LOCAL_DSH_HOME/state/links.txt"
  rm -f "$LOCAL_DSH_HOME/state/links.txt"
fi
rm -rf "${LOCAL_DSH_HOME:?}/llama.cpp" "${LOCAL_DSH_HOME:?}"/llama.cpp-build-* "${LOCAL_DSH_HOME:?}"/node-dsh-*
say "removed the llama.cpp build and the isolated dsh install"

if [ "$MODELS" = 1 ]; then
  d=$(readlink -f "$MODEL_DIR")
  case $d/ in
    "$(readlink -f "$LOCAL_DSH_HOME")"/*)
      while IFS=$'\t' read -r path _ _; do rm -f "$d/$path" "$d/$path.part"; done < <(catalog "$MODEL_ID" file)
      while IFS=$'\t' read -r link _; do [ -L "$d/$link" ] && rm -f "$d/$link"; done < <(catalog "$MODEL_ID" link)
      say "removed the $MODEL_ID files from $d" ;;
    *) warn "not deleting $d: it is outside $LOCAL_DSH_HOME and may be shared. Remove it yourself if unused." ;;
  esac
fi
if [ "$PURGE" = 1 ]; then rm -rf "${LOCAL_DSH_HOME:?}" && say "removed $LOCAL_DSH_HOME"
else say "kept $CONFIG, $DSH_HOME (sessions) and logs; --purge removes them"; fi
say "the TUI's per-user state (~/.dsh-tui) is shared by every dsh-tui on this account and was left in place"
