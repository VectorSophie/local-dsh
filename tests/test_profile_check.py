"""Regression tests for the composed-profile skill checks, without dsh or GPUs.

Keep host-plane headless skills distinct from Web/TUI agent-preset skills.
"""
import pathlib
import subprocess
import sys

CHECK = pathlib.Path(__file__).resolve().parents[1] / "lib" / "check_profile.py"
ALIAS = "local-dsh-coder-iq2xxs"
CTX = "65536"
PORT = "8041"


def profile_yaml(profile, *, without=(), host_skills=True, registry=True):
    base = f"""- id: llm-pi-ai
  config:
    providers:
      local-dsh:
        baseURL: http://127.0.0.1:{PORT}/v1
        models:
          - id: {ALIAS}
            contextWindow: {CTX}
- id: agent-default-model
  config:
    provider: local-dsh
    model: {ALIAS}
    reasoningEffort: high
- id: llm-deepseek
  disabled: true
- id: llm-deepseek-account
  disabled: true
- id: session-telemetry-otel
  disabled: true
"""
    if registry:
        base += "- id: skill\n  name: '@deepseek-ai/dsh-skill'\n"
    for entry, package in (
        ("skill-filesystem", "@deepseek-ai/dsh-skill-filesystem"),
        ("tool-skill", "@deepseek-ai/dsh-tool-skill"),
    ):
        if entry not in without:
            base += f"- id: {entry}\n  name: '{package}'\n"
            if not host_skills:
                base += "  disabled: true\n"

    if profile in ("web", "dsh-tui"):
        base += "- id: deepseek-account\n  disabled: true\n"
        base += "- id: preset-standard\n  config:\n    id: standard\n    plugins:\n"
        for entry, package in (
            ("skill-filesystem", "@deepseek-ai/dsh-skill-filesystem"),
            ("tool-skill", "@deepseek-ai/dsh-tool-skill"),
        ):
            if f"preset-{entry}" not in without:
                base += f"      - id: {entry}\n        name: '{package}'\n"
    if profile == "dsh-tui":
        base += f"- id: dsh-tui\n  config:\n    model: {ALIAS}\n    provider: local-dsh\n"
    return base


def run(profile, expected, **kwargs):
    result = subprocess.run(
        [sys.executable, "-I", str(CHECK), profile, ALIAS, CTX, PORT],
        input=profile_yaml(profile, **kwargs),
        text=True,
        capture_output=True,
        check=False,
    )
    ok = result.returncode == 0
    assert ok == expected, (
        f"{profile}: expected {'PASS' if expected else 'FAIL'}, "
        f"got exit {result.returncode}: {result.stderr}"
    )


run("headless", True)
run("headless", False, without=("tool-skill",))
run("headless", False, without=("skill-filesystem",))
run("web", True, host_skills=False)
run("web", False, host_skills=False, without=("preset-tool-skill",))
run("web", False, host_skills=False, without=("preset-skill-filesystem",))
run("dsh-tui", True, host_skills=False)
run("dsh-tui", False, host_skills=False, without=("preset-tool-skill",))
run("dsh-tui", False, host_skills=False, without=("preset-skill-filesystem",))
run("dsh-tui", False, host_skills=False, registry=False)
print("PASS composed skill profile regression checks (10 cases)")
