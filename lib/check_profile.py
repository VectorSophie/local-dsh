"""Check a composed dsh profile (`dsh --profile P --dump-config` on stdin) is routed to the local model only.

usage: dsh --profile P --dump-config | python3 -I check_profile.py P <model-alias> <ctx> <port>
"""
import re
import sys

p, alias, ctx, port = sys.argv[1:]
y = sys.stdin.read()


def row(entry_id):
    m = re.search(rf"^- id: {re.escape(entry_id)}\n((?:[ #].*\n?)*)", y, re.M)
    return m.group(1) if m else ""


checks = {
    "local baseURL": f"baseURL: http://127.0.0.1:{port}/v1" in row("llm-pi-ai"),
    "context window": f"contextWindow: {ctx}" in row("llm-pi-ai"),
    "default model": f"model: {alias}" in row("agent-default-model"),
    "reasoning high": "reasoningEffort: high" in row("agent-default-model"),
    "hosted DeepSeek off": "disabled: true" in row("llm-deepseek") and "disabled: true" in row("llm-deepseek-account"),
    "telemetry off": "disabled: true" in row("session-telemetry-otel"),
    "skill registry present": "name: '@deepseek-ai/dsh-skill'" in row("skill") and "disabled: true" not in row("skill"),
}
if p in ("web", "dsh-tui"):
    checks["standard preset without tool-web"] = "id: standard" in row("preset-standard") and "dsh-tool-web" not in row("preset-standard")
    checks["account sign-in off"] = "disabled: true" in row("deepseek-account")
# Headless loads its skill filesystem and tool in the host plane. Web and TUI
# use an agent-scoped standard preset; the host copies may be disabled there.
# In particular, do not require TUI host-plane rows to be enabled.
if p == "headless":
    checks["skill filesystem provider"] = "name: '@deepseek-ai/dsh-skill-filesystem'" in row("skill-filesystem") and "disabled: true" not in row("skill-filesystem")
    checks["skill loader tool"] = "name: '@deepseek-ai/dsh-tool-skill'" in row("tool-skill") and "disabled: true" not in row("tool-skill")
if p in ("web", "dsh-tui"):
    checks["standard preset skill filesystem provider"] = "name: '@deepseek-ai/dsh-skill-filesystem'" in row("preset-standard")
    checks["standard preset skill loader tool"] = "name: '@deepseek-ai/dsh-tool-skill'" in row("preset-standard")
if p == "dsh-tui":
    checks["TUI pinned to local model"] = f"model: {alias}" in row("dsh-tui") and "provider: local-dsh" in row("dsh-tui")
bad = [k for k, ok in checks.items() if not ok]
print(f"  {p}: {'ok' if not bad else 'FAILED: ' + ', '.join(bad)}", file=sys.stderr)
sys.exit(1 if bad else 0)
