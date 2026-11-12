#!/usr/bin/env bash
# local-dsh guided installer. Safe to re-run: every step is skipped when already done, interrupted downloads
# and builds resume, and regenerated config files keep a *.bak-<timestamp> copy of what they replace.
#
#   ./install.sh                 interactive (asks for model, model directory, GPUs, scheduler)
#   ./install.sh --yes           accept the recommended answers
#   ./install.sh --check         hardware + dependency report only; changes nothing
#
# Options: --model ID  --model-dir DIR  --gpus 0,1  --scheduler direct|gpuq  --port N  --ctx N
#          --bin-dir DIR (default ~/.local/bin)  --no-tui  --skip-model  --verify-model full|size
#          --llama-repo URL|PATH (git mirror)  --reconfigure (ignore the saved config.env)
# Env: LOCAL_DSH_HOME (default ~/.local/share/local-dsh): config, builds, dsh home, sessions, logs.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/common.sh"

YES=0 CHECK=0 WITH_TUI=1 SKIP_MODEL=0 RECONF=0 VERIFY=full BIN_DIR=$HOME/.local/bin
O_MODEL='' O_MODEL_DIR='' O_GPUS='' O_SCHED='' O_PORT='' O_CTX='' LLAMA_REPO=$LLAMA_CPP_REPO
while [ $# -gt 0 ]; do
  case $1 in
    --yes|-y) YES=1 ;; --check) CHECK=1 ;; --no-tui) WITH_TUI=0 ;; --with-tui) WITH_TUI=1 ;;
    --skip-model) SKIP_MODEL=1 ;; --reconfigure) RECONF=1 ;;
    --model) O_MODEL=$2; shift ;; --model-dir) O_MODEL_DIR=$2; shift ;; --gpus) O_GPUS=$2; shift ;;
    --scheduler) O_SCHED=$2; shift ;; --port) O_PORT=$2; shift ;; --ctx) O_CTX=$2; shift ;;
    --bin-dir) BIN_DIR=$2; shift ;; --verify-model) VERIFY=$2; shift ;; --llama-repo) LLAMA_REPO=$2; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
STATE=$LOCAL_DSH_HOME/state
step() { printf '\n== %s\n' "$*" >&2; }
ask() {  # ask <prompt> <default>: prints the answer
  local a
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then echo "$2"; return; fi
  read -r -p "$1 [$2]: " a < /dev/tty; echo "${a:-$2}"
}
backup_write() {  # backup_write <file> < content: replace only when different, keeping a timestamped copy
  local tmp; tmp=$(mktemp); cat > "$tmp"
  # dsh creates profiles with a comments-only "[]" patch; that stub is not worth a backup
  if [ -f "$1" ] && ! cmp -s "$tmp" "$1" && [ "$(grep -v '^ *#' "$1" | tr -d ' \n')" != "[]" ]; then
    cp -p "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"; say "updated $1 (previous copy kept)"
  fi
  mv "$tmp" "$1"
}

# ---------------------------------------------------------------- 1. hardware and dependencies
step "Hardware"
GPU_LINES=$(nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null || true)
[ -n "$GPU_LINES" ] || die "no NVIDIA GPU visible (nvidia-smi failed). local-dsh needs CUDA GPUs with >= 80 GB total VRAM."
echo "$GPU_LINES" | awk -F', ' '{printf "  GPU %s: %s, %.0f GB, compute %s\n", $1, $2, $3/1024, $4}' >&2
DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' "${LOCAL_DSH_MEMINFO:-/proc/meminfo}")   # override: tests only
echo "  driver $DRIVER, RAM ${RAM_GB} GiB, $(nproc) CPU threads, $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")" >&2

step "Dependencies"
MISSING=()
need() { if command -v "$1" >/dev/null; then echo "  ok   $1" >&2; else echo "  MISSING $1 ($2)" >&2; MISSING+=("$1"); fi; }
need git "apt install git"; need curl "apt install curl"; need python3 "apt install python3"
need cmake "apt install cmake (>= 3.21)"; need g++ "apt install build-essential"; need flock "util-linux"; need setsid "util-linux"
NVCC=$(command -v nvcc || ls -d /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$NVCC" ]; then echo "  ok   nvcc ($("$NVCC" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p'), $NVCC)" >&2
else echo "  MISSING nvcc (CUDA toolkit; >= 12.8 for Blackwell sm_120)" >&2; MISSING+=(nvcc); fi
if command -v node >/dev/null && version_ge "$(node -v | tr -d v)" "$NODE_MIN"; then echo "  ok   node $(node -v)" >&2
else echo "  MISSING node >= $NODE_MIN (found: $(node -v 2>/dev/null || echo none)); e.g. nvm install 24" >&2; MISSING+=(node); fi
command -v npm >/dev/null || { echo "  MISSING npm (ships with node)" >&2; MISSING+=(npm); }
if command -v gpuq >/dev/null; then echo "  found gpuq (optional shared GPU queue)" >&2; else echo "  no gpuq (optional; servers run directly)" >&2; fi

if [ "$CHECK" = 1 ]; then
  step "Models (fit for all GPUs on this machine)"
  TOTAL_VRAM=$(echo "$GPU_LINES" | awk -F', ' '{s+=$3} END {printf "%d", s/1024}')
  catalog_ids | while read -r id; do
    IFS=$'\t' read -r st _ _ _ vram ram disk desc < <(catalog "$id" model)
    fit=yes; [ "$TOTAL_VRAM" -ge "$vram" ] && [ "$RAM_GB" -ge "$ram" ] || fit=no
    printf '  %-14s %-10s fits=%-3s needs %s GB VRAM, %s GiB RAM, %s GB disk\n      %s\n' "$id" "$st" "$fit" "$vram" "$ram" "$disk" "$desc" >&2
  done
  [ ${#MISSING[@]} = 0 ] && say "check passed" || { say "missing: ${MISSING[*]}"; exit 1; }
  exit 0
fi
[ ${#MISSING[@]} = 0 ] || die "install the missing dependencies first: ${MISSING[*]}"

# ---------------------------------------------------------------- 2. configuration
step "Configuration ($CONFIG)"
mkdir -p "$LOCAL_DSH_HOME" "$STATE" "$RUN" "$LOGS"
if [ -f "$CONFIG" ] && [ "$RECONF" = 0 ]; then source_config; say "reusing saved answers (--reconfigure to change)"; fi
ALL_GPUS=$(echo "$GPU_LINES" | cut -d, -f1 | paste -sd,)
CUDA_DEVICES=${O_GPUS:-${CUDA_DEVICES:-$(ask "GPUs to use (comma-separated indices)" "$ALL_GPUS")}}
[[ $CUDA_DEVICES =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--gpus must be comma-separated GPU indices, got: $CUDA_DEVICES"
for g in ${CUDA_DEVICES//,/ }; do echo "$GPU_LINES" | cut -d, -f1 | grep -qx "$g" || die "GPU $g does not exist (have: $ALL_GPUS)"; done
GPU_COUNT=$(echo "$CUDA_DEVICES" | tr ',' '\n' | grep -c .)
SEL_VRAM=$(echo "$GPU_LINES" | awk -F', ' -v sel=",$CUDA_DEVICES," 'index(sel, ","$1",") {s+=$3} END {printf "%d", s/1024}')
echo "  selected GPUs $CUDA_DEVICES: $SEL_VRAM GB VRAM" >&2

DEFAULT_MODEL=
while read -r id; do
  IFS=$'\t' read -r st _ _ _ vram ram disk desc < <(catalog "$id" model)
  fit=no; [ "$SEL_VRAM" -ge "$vram" ] && [ "$RAM_GB" -ge "$ram" ] && fit=yes
  printf '  %-14s %-10s fits=%-3s %s\n' "$id" "$st" "$fit" "$desc" >&2
  [ -z "$DEFAULT_MODEL" ] && [ "$fit" = yes ] && [ "$st" = verified ] && DEFAULT_MODEL=$id
done < <(catalog_ids)
MODEL_ID=${O_MODEL:-${MODEL_ID:-$(ask "Model" "${DEFAULT_MODEL:-coder-iq2xxs}")}}
IFS=$'\t' read -r M_STATUS _ _ M_FIRST MIN_VRAM_GB M_RAM M_DISK _ < <(catalog "$MODEL_ID" model) || die "unknown model: $MODEL_ID"
[ "$SEL_VRAM" -ge "$MIN_VRAM_GB" ] || warn "$MODEL_ID needs about $MIN_VRAM_GB GB VRAM; selected GPUs have $SEL_VRAM GB (loading will likely fail)"
[ "$RAM_GB" -ge "$M_RAM" ] || warn "$MODEL_ID wants >= $M_RAM GiB RAM (Engram file is memory-mapped); this machine has $RAM_GB GiB"
[ "$M_STATUS" = verified ] || warn "$MODEL_ID is not GPU-tested by this project"
MODEL_DIR=${O_MODEL_DIR:-${MODEL_DIR:-$(ask "Model directory (needs ~$M_DISK GB)" "$LOCAL_DSH_HOME/models/$MODEL_ID")}}
if [ -n "$O_SCHED" ]; then SCHEDULER=$O_SCHED
elif [ -z "${SCHEDULER:-}" ]; then
  if command -v gpuq >/dev/null; then SCHEDULER=$(ask "Schedule the model server through gpuq? (gpuq/direct)" gpuq); else SCHEDULER=direct; fi
fi
case $SCHEDULER in direct|gpuq) ;; *) die "scheduler must be direct or gpuq" ;; esac
PORT=${O_PORT:-${PORT:-8041}}; CTX=${O_CTX:-${CTX:-65536}}
[[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "--port must be 1024-65535, got: $PORT"
[[ $CTX =~ ^[0-9]+$ ]] && [ "$CTX" -ge 4096 ] || die "--ctx must be a number >= 4096, got: $CTX"
MODEL_ALIAS=local-dsh-$MODEL_ID
TENSOR_SPLIT=$(printf "1%.0s," $(seq "$GPU_COUNT")); TENSOR_SPLIT=${TENSOR_SPLIT%,}
CUDA_ARCHS=$(echo "$GPU_LINES" | awk -F', ' -v sel=",$CUDA_DEVICES," 'index(sel, ","$1",") {gsub(/\./, "", $4); print $4}' | sort -u | paste -sd';')
NODE_PREFIX=$LOCAL_DSH_HOME/node-dsh-$DSH_VERSION
LLAMA_BUILD=$LOCAL_DSH_HOME/llama.cpp-build-${LLAMA_CPP_COMMIT:0:12}
# config.env is sourced by bash, so every value is written shell-quoted (paths may contain spaces)
{
  echo "# local-dsh machine configuration, written by install.sh. Edit and re-run install.sh to apply."
  for kv in "MODEL_ID=$MODEL_ID" "MODEL_DIR=$MODEL_DIR" "MODEL_PATH=$MODEL_DIR/$M_FIRST" "MODEL_ALIAS=$MODEL_ALIAS" \
    "MIN_VRAM_GB=$MIN_VRAM_GB" "SCHEDULER=$SCHEDULER" "CUDA_DEVICES=$CUDA_DEVICES" "GPU_COUNT=$GPU_COUNT" \
    "TENSOR_SPLIT=$TENSOR_SPLIT" "PORT=$PORT" "CTX=$CTX" "SERVER_EFFORT=50" "EXTRA_SERVER_ARGS=${EXTRA_SERVER_ARGS:-}" \
    "QUEUE_WAIT=${QUEUE_WAIT:-1800}" "LOAD_WAIT=${LOAD_WAIT:-900}" "LLAMA_SERVER=$LLAMA_BUILD/bin/llama-server" \
    "NODE_DIR=$(dirname "$(command -v node)")" "DSH_BIN=$NODE_PREFIX/node_modules/.bin/dsh" "DSH_HOME=$LOCAL_DSH_HOME/dsh-home"; do
    v=${kv#*=}; printf '%s=%s\n' "${kv%%=*}" "${v@Q}"
  done
} | backup_write "$CONFIG"
source_config

# ---------------------------------------------------------------- 3. llama.cpp (pinned, isolated build)
step "llama.cpp ${LLAMA_CPP_COMMIT:0:12} -> $LLAMA_BUILD"
if [ -x "$LLAMA_SERVER" ] && [ "$(cat "$LLAMA_BUILD/.local-dsh-commit" 2>/dev/null)" = "$LLAMA_CPP_COMMIT" ]; then
  say "already built"
else
  SRC=$LOCAL_DSH_HOME/llama.cpp
  [ -d "$SRC/.git" ] || git clone --no-checkout "$LLAMA_REPO" "$SRC"
  git -C "$SRC" cat-file -e "$LLAMA_CPP_COMMIT^{commit}" 2>/dev/null || git -C "$SRC" fetch --depth 1 origin "$LLAMA_CPP_COMMIT" \
    || git -C "$SRC" fetch origin
  git -C "$SRC" -c advice.detachedHead=false checkout -f "$LLAMA_CPP_COMMIT"
  say "building llama-server for CUDA arch $CUDA_ARCHS (10-30 minutes; re-running resumes)"
  cmake -S "$SRC" -B "$LLAMA_BUILD" -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DLLAMA_CURL=OFF \
    -DCMAKE_CUDA_COMPILER="$NVCC" -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS" > "$LOGS/llama-cmake.log" 2>&1 \
    || { tail -20 "$LOGS/llama-cmake.log"; die "cmake failed (log: $LOGS/llama-cmake.log)"; }
  nice cmake --build "$LLAMA_BUILD" --target llama-server -j "$(nproc)" > "$LOGS/llama-build.log" 2>&1 \
    || { tail -20 "$LOGS/llama-build.log"; die "build failed (log: $LOGS/llama-build.log)"; }
  echo "$LLAMA_CPP_COMMIT" > "$LLAMA_BUILD/.local-dsh-commit"
fi
"$LLAMA_SERVER" --version 2>&1 | grep -m1 version >&2 || true

# ---------------------------------------------------------------- 4. dsh (pinned, isolated npm prefix)
step "dsh $DSH_VERSION -> $NODE_PREFIX"
if [ -x "$DSH_BIN" ] && [ "$("$DSH_BIN" --version 2>/dev/null)" = "$DSH_VERSION" ]; then say "already installed"
else
  # exact dependency tree from lock/dsh (versions + integrity hashes), not whatever is newest today
  mkdir -p "$NODE_PREFIX"
  cp "$LOCAL_DSH_REPO/lock/dsh/package.json" "$LOCAL_DSH_REPO/lock/dsh/package-lock.json" "$NODE_PREFIX/"
  npm ci --prefix "$NODE_PREFIX" --no-audit --no-fund --loglevel=error
  [ "$("$DSH_BIN" --version)" = "$DSH_VERSION" ] || die "dsh $DSH_VERSION did not install correctly"
fi

# ---------------------------------------------------------------- 5. dsh home and profiles
step "dsh profiles in $DSH_HOME"
export DSH_HOME DSH_TELEMETRY_DISABLED=1 LOCAL_DSH_KEY=local-placeholder-not-a-secret
PATH=$NODE_DIR:$PATH
mkdir -p "$DSH_HOME/profiles"
render() { sed -e "s|@PORT@|$PORT|g" -e "s|@CTX@|$CTX|g" -e "s|@ALIAS@|$MODEL_ALIAS|g" -e "s|@MODEL_NAME@|$MODEL_ID (local-dsh)|g" "$LOCAL_DSH_REPO/templates/$1"; }
render home.patch.yml | backup_write "$DSH_HOME/cordis.patch.yml"
for p in headless web; do "$DSH_BIN" --profile "$p" --dump-config > /dev/null 2>&1 || die "dsh could not initialize the $p profile"; done
PRESET=$(find "$NODE_PREFIX/node_modules" -path '*dsh-web-app/presets/standard.patch.yml' | head -1)
[ -n "$PRESET" ] || die "dsh-web-app standard preset not found in $NODE_PREFIX"
{ render web.patch.yml; python3 -I "$LOCAL_DSH_REPO/lib/preset_without_tool_web.py" "$PRESET" patch; } | backup_write "$DSH_HOME/profiles/web/cordis.patch.yml"

if [ "$WITH_TUI" = 1 ]; then
  step "TUI plugin $DSH_TUI_PACKAGE@$DSH_TUI_VERSION (third-party, MIT) -> profile dsh-tui"
  T=$DSH_HOME/profiles/dsh-tui; mkdir -p "$T"
  backup_write "$T/package.json" <<EOF
{
  "name": "dsh-profile-dsh-tui",
  "private": true,
  "dependencies": { "$DSH_TUI_PACKAGE": "$DSH_TUI_VERSION" },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "$DSH_TUI_PACKAGE"] } }
}
EOF
  printf 'packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n' | backup_write "$T/pnpm-workspace.yaml"
  { render dsh-tui.patch.yml; python3 -I "$LOCAL_DSH_REPO/lib/preset_without_tool_web.py" "$PRESET" insert; } | backup_write "$T/cordis.patch.yml"
  if [ "$(node -p 'require(process.argv[1]).version' "$T/node_modules/$DSH_TUI_PACKAGE/package.json" 2>/dev/null)" = "$DSH_TUI_VERSION" ]; then say "already installed"
  else
    cp "$LOCAL_DSH_REPO/lock/dsh-tui/pnpm-lock.yaml" "$T/pnpm-lock.yaml"   # exact tree + integrity hashes
    (cd "$T" && "$NODE_PREFIX/node_modules/.bin/pnpm" install --frozen-lockfile --ignore-scripts --reporter=append-only) \
      || die "TUI plugin install failed"
  fi
  # skip the TUI's first-run account/API-key wizard (its documented completion marker)
  [ -f "$HOME/.dsh-tui/onboarding.json" ] || { mkdir -p "$HOME/.dsh-tui"; printf '{\n  "completed": true,\n  "version": 1\n}\n' > "$HOME/.dsh-tui/onboarding.json"; }
fi

step "Validating composed profiles"
for p in headless web $([ "$WITH_TUI" = 1 ] && echo dsh-tui); do
  out=$("$DSH_BIN" --profile "$p" --dump-config 2>/dev/null) || die "profile $p does not compose"
  python3 -I "$LOCAL_DSH_REPO/lib/check_profile.py" "$p" "$MODEL_ALIAS" "$CTX" "$PORT" <<<"$out" || die "profile $p is not routed to the local model"
done

# ---------------------------------------------------------------- 6. model
if [ "$SKIP_MODEL" = 1 ]; then step "Model: skipped (--skip-model)"
else step "Model $MODEL_ID -> $MODEL_DIR"; "$LOCAL_DSH_REPO/lib/fetch-model.sh" "$MODEL_ID" "$MODEL_DIR" "$VERIFY"; fi

# ---------------------------------------------------------------- 7. commands
step "Commands in $BIN_DIR"
mkdir -p "$BIN_DIR"
# Each command is a 3-line wrapper that pins this install's LOCAL_DSH_HOME; its marker line is how
# install.sh and uninstall.sh recognise files they own. Anything else with the same name is left alone.
MARK="# local-dsh command for LOCAL_DSH_HOME=$LOCAL_DSH_HOME"
for n in dsh-tui dst dsh-web dsh-run dsh-status dsh-stop dsh-tui-raw; do
  l=$BIN_DIR/$n
  body=$(printf '#!/usr/bin/env bash\n%s\nexport LOCAL_DSH_HOME=%q\nexec %q %q "$@"\n' "$MARK" "$LOCAL_DSH_HOME" "$LOCAL_DSH_REPO/bin/local-dsh" "$n")
  if [ -f "$l" ] && [ ! -L "$l" ] && [ "$(sed -n 2p "$l")" = "$MARK" ]; then
    [ "$(cat "$l")" = "$body" ] && echo "  ok   $n" >&2 || { printf '%s\n' "$body" > "$l"; echo "  upd  $n" >&2; }
  elif [ -L "$l" ] && [ "$(readlink "$l")" = "$LOCAL_DSH_REPO/bin/local-dsh" ]; then   # pre-0.1.0 symlink from this repo
    rm "$l"; printf '%s\n' "$body" > "$l"; chmod +x "$l"; echo "  upd  $n (symlink replaced)" >&2
  elif [ -e "$l" ] || [ -L "$l" ]; then echo "  SKIP $n: $l exists and belongs to something else (left untouched)" >&2; continue
  else printf '%s\n' "$body" > "$l"; chmod +x "$l"; echo "  new  $n" >&2; fi
  grep -qxF "$l" "$STATE/links.txt" 2>/dev/null || echo "$l" >> "$STATE/links.txt"
done
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on PATH; add it (e.g. in ~/.profile) to use the commands" ;; esac

step "Done"
cat >&2 <<EOF
  cd <your project> && dsh-tui      terminal UI (starts the model server; stops it when you exit)
  dsh-web                           browser UI on 127.0.0.1 (SSH: ssh -L 3080:127.0.0.1:3080 <host>)
  dsh-run "fix the failing test"    one headless task in the current directory
  dsh-status / dsh-stop             inspect / stop the server local-dsh started
  scheduler: $SCHEDULER, GPUs: $CUDA_DEVICES, model: $MODEL_ID, context: $CTX, config: $CONFIG
EOF
