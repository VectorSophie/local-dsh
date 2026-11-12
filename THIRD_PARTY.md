# Third-party components

local-dsh is licensed under the GNU GPL-3.0 (see `LICENSE`). It **vendors no third-party code**: every
component below is downloaded by `install.sh` from its upstream source, pinned to the version or revision in
`versions.env` / `models/catalog.tsv`, and installed outside this repository. The npm and pnpm lockfiles in `lock/`
fix every transitive dependency's version and integrity hash; they contain metadata only, no code. All licenses below are
GPL-3.0-compatible permissive licenses. Their license texts ship with the downloaded packages.

| Component | Pinned version | License | How it is obtained | Required? |
|---|---|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | commit `7d7f0287530b` (b12211) | MIT | `git clone` + local CUDA build | yes |
| [DeepSeek Harness `@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) | 0.2.2-rc.1 | MIT | `npm ci` (lock/dsh) into an isolated prefix | yes |
| [pnpm](https://pnpm.io) | 12.18.0 | MIT | `npm ci` (lock/dsh) into the same prefix | only for the TUI plugin |
| [dsh-TUI `@deepseek-harness-tui/dsh-tui`](https://github.com/ccch1mneyyy/dsh-TUI) | 0.19.0 | MIT | `pnpm install --frozen-lockfile` (lock/dsh-tui) into the `dsh-tui` dsh profile | optional (`--no-tui`) |
| [ISTA-DASLab DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder-GGUF](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-Coder-GGUF) | revision `54229d38` | MIT (model card) | resumable download, SHA-256 checked | default model |
| [ISTA-DASLab DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF) | revision `65d53bc8` | MIT (model card) | same | optional, untested |

Notes
- dsh-TUI is a community project, not part of the official DeepSeek Harness. local-dsh pins it and installs it
  only into its own dsh profile; `install.sh --no-tui` skips it (then use `dsh-web` or `dsh-run`).
- `lib/preset_without_tool_web.py` reads dsh's installed `standard` agent preset at install time and writes a
  copy without one row into the user's dsh profile. No dsh file is stored in this repository.
- The test fixture `tests/fixtures/standard.patch.yml` is a synthetic file written for this project.
- The model weights are not distributed here. Their use is governed by the upstream model cards (MIT, base
  model `deepseek-ai/DeepSeek-V4.1-Flash-1017`).
