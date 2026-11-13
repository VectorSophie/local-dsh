# Skills in local-dsh

local-dsh runs the standard DeepSeek Harness skill stack. It does not implement a second skill loader:
- `@deepseek-ai/dsh-skill`: registry
- `@deepseek-ai/dsh-skill-filesystem`: discover local skill directories
- `@deepseek-ai/dsh-tool-skill`: publish the catalog and expose the model-facing `skill` tool

The installer keeps the skill rows from dsh's shipped profiles and standard agent preset. It disables hosted routes and the web tool, not skills. Every installed profile is checked for the expected skill wiring. That static check is **not** evidence that the local model will choose to load or follow any specific skill.

## Add an existing skill

A skill consists of a `SKILL.md` file with YAML frontmatter. For example, inside a Git project:

```text
my-project/
  .git/
  .agents/
    skills/
      my-procedure/
        SKILL.md
        references/       # optional
        scripts/          # optional
```

```markdown
---
name: my-procedure
description: Use this skill to carry out the procedure in this project.
---

Instructions go here.
```

The filesystem provider's default search roots are, in priority order:

| Scope | Root |
|---|---|
| Project | `<git-root>/.dsh/skills/` |
| Project, shared | `<git-root>/.agents/skills/` |
| Custom | `customSkillDirs` configured on the filesystem provider |
| Current local-dsh installation | `$DSH_HOME/skills/` |
| User, shared | `~/.agents/skills/` (or `$DSH_AGENTS_HOME/skills/`) |

For local-dsh, `DSH_HOME` normally resolves to `~/.local/share/local-dsh/dsh-home`, not `~/.dsh`. A separate local-dsh installation gets its own DSH home.

The provider expects a **direct child** `<name>/SKILL.md` bundle or `<name>.md` under a scanned root, not an arbitrarily nested `**/SKILL.md`. Skills need valid frontmatter, including a kebab-case name and a description. Existing independent skills can be copied into a scanned root or symlinked when their resources and relative paths remain valid. No Claude Code configuration, MCP server, or hosted model is required.

Not every benchmark defines a SKILL.md format. AgentDojo, for example, also uses environments, tasks, and tools. Those components do not automatically become skills: only actual skill instruction bundles belong in a skill root. Keep dataset and tool adapters separate from skill discovery.

## Verify the installed profiles

Run `./install.sh` after checking out changes so it regenerates and validates the installed profiles; it preserves the existing model files and pinned dependency versions.

The installer checks:

1. The skill registry is present in each composed profile.
2. Headless and TUI retain a filesystem provider plus the model-facing `skill` tool.
3. Web's `standard` agent preset retains its filesystem provider and tool, even though the shared host-plane tool may be disabled there.

Run the offline checks, which do not need a GPU:

```bash
tests/run-offline.sh
```

After installation, run the real-model acceptance test:

```bash
bash tests/gpu-skill-smoke.sh
```

It creates a temporary Git repository and a synthetic, harmless `SKILL.md`. Its randomized proof string appears **only inside the skill body**, not in the prompt or description. The headless agent must:

1. See and invoke the named `skill` tool (confirmed from `dsh-run --json` `tool_call` events).
2. Receive the full skill body (confirmed from the matching `tool_result`).
3. Write a file containing exactly the randomized proof, demonstrating that the model acted on the loaded instructions.
4. Finish successfully.

The test runs with `workspace-write` and `approval-policy never`. A failed run prints diagnostic events and exits nonzero. It leaves the tested user's repositories untouched. This is a **positive-path skill smoke**, not a security or poisoning-resistance benchmark.

For a UI check, open `dst` or `dsh-web` from a project containing a skill. Ask it to load that named skill; inspect its tool call history. The headless smoke does not substitute for an end-to-end UI verification.

## External experiments and untrusted skills

The repository is a local model launcher, not a full benchmark harness. Point an experiment at the project's normal skill root, then keep test cases, expected outcomes, and observations in the experiment's own workspace. Separate **catalog discovery**, **successful tool loading**, and **behavior after loading** in logs; an agent saying it followed a skill is not proof that it called the tool.

Treat third-party and deliberately poisoned skills as untrusted instructions, not configuration to execute on your daily development machine. Use a disposable workspace without secrets, review requested commands and resource files, and constrain network and filesystem access appropriate to the experiment. A passing smoke test does not establish that malicious skill content is harmless.
