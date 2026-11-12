#!/usr/bin/env bash
# Exec llama-server for the configured model. Run by the scheduler backend (direct: setsid child; gpuq: the job).
# exec keeps the PID, so $RUN/server.pid is the llama-server PID and a gpuq job lasts exactly as long as the server.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
load_config
mkdir -p "$RUN" "$LOGS"
[ -e "$MODEL_PATH" ] || die "model not found: $MODEL_PATH (run install.sh)"
# direct backend: pin the configured GPUs; under gpuq the scheduler already set CUDA_VISIBLE_DEVICES
[ "$SCHEDULER" = direct ] && [ -n "${CUDA_DEVICES:-}" ] && export CUDA_VISIBLE_DEVICES=$CUDA_DEVICES
split=(--split-mode none)
[ "${GPU_COUNT:-1}" -gt 1 ] && split=(--split-mode layer --tensor-split "$TENSOR_SPLIT")
LOG=$LOGS/server-$(date +%Y%m%d-%H%M%S).log
ln -sfn "$(basename "$LOG")" "$LOGS/server-latest.log"
echo $$ > "$RUN/server.pid"
# shellcheck disable=SC2086  # EXTRA_SERVER_ARGS is a deliberate word list
exec "$LLAMA_SERVER" -m "$MODEL_PATH" --alias "$MODEL_ALIAS" \
  --host 127.0.0.1 --port "$PORT" --ctx-size "$CTX" --parallel 1 \
  --n-gpu-layers 99 "${split[@]}" --flash-attn on \
  --jinja --reasoning on --reasoning-effort "$SERVER_EFFORT" --reasoning-format deepseek \
  --metrics --no-webui ${EXTRA_SERVER_ARGS:-} > "$LOG" 2>&1
