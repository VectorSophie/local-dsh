# shellcheck shell=bash
# Sourced by bin/local-dsh, install.sh and uninstall.sh. Bash only.
# Machine-specific values live in $LOCAL_DSH_HOME/config.env (written by install.sh, never in Git).
LOCAL_DSH_REPO=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
# The installed command wrappers set LOCAL_DSH_HOME, so several installs never share configuration.
LOCAL_DSH_HOME=${LOCAL_DSH_HOME:-$HOME/.local/share/local-dsh}
LOCAL_DSH_HOME=${LOCAL_DSH_HOME%/}
CONFIG=$LOCAL_DSH_HOME/config.env
# shellcheck disable=SC2034  # used by the scripts that source this file
RUN=$LOCAL_DSH_HOME/run
# shellcheck disable=SC2034
LOGS=$LOCAL_DSH_HOME/logs
# shellcheck source=../versions.env
. "$LOCAL_DSH_REPO/versions.env"

say() { printf '[local-dsh %s] %s\n' "$(date +%T)" "$*" >&2; }
warn() { say "WARNING: $*"; }
die() { say "ERROR: $*"; exit 1; }
[ -n "$LOCAL_DSH_HOME" ] || die "LOCAL_DSH_HOME must be a dedicated directory, not /"

source_config() {  # export every key of config.env
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG"
  set +a
}
load_config() {
  [ -f "$CONFIG" ] || die "not installed (no $CONFIG). Run: $LOCAL_DSH_REPO/install.sh"
  source_config
  export DSH_HOME DSH_TELEMETRY_DISABLED=1 LOCAL_DSH_KEY=local-placeholder-not-a-secret
  PATH=$NODE_DIR:$PATH
}

# catalog <model-id> <kind>: print matching catalog lines (tab-separated), without the kind/id columns
catalog() { awk -F'\t' -v k="$2" -v id="$1" '$1==k && $2==id {sub(/^[^\t]*\t[^\t]*\t/, ""); print}' "$LOCAL_DSH_REPO/models/catalog.tsv"; }
catalog_ids() { awk -F'\t' '$1=="model" {print $2}' "$LOCAL_DSH_REPO/models/catalog.tsv"; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
