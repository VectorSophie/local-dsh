# local-dsh

Run the [DeepSeek Harness (dsh)](https://www.npmjs.com/package/@deepseek-ai/dsh) coding agent against a
**local** DeepSeek V4.1 Flash model on your own GPU server. No API keys, accounts or hosted models are used. Clone the
repo, run the installer once, then start the agent from any project directory:

```bash
cd ~/my-project
dsh-tui            # terminal UI (alias: dst)
```

The launcher starts the model server when it is needed, reusing one that is already running, and stops it when you
exit. The agent works in the directory you launched it from.

## Requirements

| | Minimum | Tested (see [Verification status](#verification-status)) |
|---|---|---|
| GPUs | NVIDIA CUDA GPUs, >= 80 GB VRAM in total for the default model. Only Blackwell (sm_120) with 2 GPUs has been tested; the installer builds for the detected compute capability, but other architectures and single-GPU setups are untested. | 2x RTX PRO 6000 Blackwell Max-Q, 96 GB each |
| RAM | 128 GiB (the 111 GB Engram table is memory-mapped) | 251 GiB |
| Disk | 190 GB for the default model | NVMe |
| OS | Linux x86-64 | Ubuntu 24.04.5 LTS |
| NVIDIA driver / CUDA toolkit | toolkit >= 12.8 for Blackwell (sm_120); `nvcc` | driver 610.57.04, CUDA 12.8 |
| Build tools | git, cmake >= 3.21, g++, curl, python3, flock/setsid (util-linux) | cmake 3.28.3, gcc 13.3, Python 3.12.3 |
| Node.js | >= 24.9 (required by dsh) | 24.21.0 |
| Optional | [task-spooler](https://github.com/justanhduc/task-spooler) (GPU build) reachable as `gpuq`, e.g. `ln -s "$(command -v ts)" ~/.local/bin/gpuq` | yes, through a site wrapper |

## Install

```bash
git clone https://github.com/VectorSophie/local-dsh.git
cd local-dsh
./install.sh --check     # hardware + dependency report; changes nothing
./install.sh             # guided install (or: ./install.sh --yes for the recommended answers)
```

The installer asks four questions:
- which GPUs to use (default: all);
- which model to install (default: the verified one that fits);
- where to keep the model (needs about 190 GB);
- whether to start the server through `gpuq`, asked only if a `gpuq` command exists.

It then:
1. builds `llama-server` from a pinned llama.cpp commit for your GPU architecture (about 10-30 minutes);
2. installs dsh and pnpm into an isolated npm prefix (nothing global), from the lockfile in `lock/dsh`. That fixes
   every transitive dependency's version and integrity hash;
3. writes the dsh profiles `headless`, `web` and `dsh-tui`, then checks that each one is routed to the local model
   with telemetry and hosted models off;
4. downloads the model. Downloads resume after an interruption, are SHA-256-checked, and the Engram shard link is
   created. If the files are already on disk, give that directory with `--model-dir` and they are verified, not
   downloaded;
5. writes the commands into `~/.local/bin` as three-line wrappers. Each wrapper records its install's location, so
   several installs on one account never read each other's configuration. A file with the same name that isn't one
   of this install's wrappers is left untouched and reported.

Re-running `install.sh` is safe: finished steps are skipped and interrupted ones resume. Useful options:
- `--model ID`
- `--model-dir DIR`
- `--gpus 0,1`
- `--scheduler direct|gpuq`
- `--port N`
- `--ctx N`
- `--bin-dir DIR`
- `--no-tui`
- `--verify-model size`: skip hashing files that are already present
- `--llama-repo PATH`: build from a local llama.cpp mirror
- `--reconfigure`

Everything machine-specific goes to `$LOCAL_DSH_HOME`, by default `~/.local/share/local-dsh`:
- `config.env`
- the builds and the isolated dsh install
- `dsh-home/`, which holds the dsh profiles and your sessions
- logs

Nothing is written into this repository.

## Commands

| Command | What it does |
|---|---|
| `dsh-tui` / `dst` | Terminal UI in the current directory (the primary interface). |
| `dsh-web` | Browser UI. It prints a tokenized `http://127.0.0.1:3080/?token=...` URL. From another machine, first run `ssh -L 3080:127.0.0.1:3080 <server>`. |
| `dsh-run "task"` | One headless agent task in the current directory. dsh options pass through, for example `--session-id` to resume. |
| `dsh-status` | Server health, who started it, active clients, GPU and RAM use. Read-only. |
| `dsh-stop` | Stops the server *local-dsh started*. A server it did not start is left alone. |
| `dsh-tui-raw` | The TUI without any server management, for troubleshooting. |

How the model server is managed:
- **Start:** each command checks for a healthy server with the right model and context on `127.0.0.1:$PORT`. If there
  is none, it starts one with the configured scheduler and waits for the model to load. The wait is bounded, shows
  progress, and Ctrl-C cancels it.
- **Shared:** several commands can use the same server, and the server stays up while any local-dsh client is running.
- **Stop:** a server started by local-dsh is stopped when the *last* local-dsh client exits. That covers a normal
  exit, Ctrl-C, a closed terminal or SSH session, and a failed start.
- **External servers:** a server that was already running when local-dsh attached to it is never stopped.

Schedulers (`SCHEDULER` in `config.env`):
- **`direct`** (default without gpuq): runs `llama-server` on the configured `CUDA_DEVICES`. If those GPUs lack the
  free memory the model needs, it refuses to start, naming the processes that hold the memory.
- **`gpuq`** (optional): submits the server as a task-spooler job and waits for the reservation. The job lasts exactly
  as long as the server. Each installation uses its own job label, `ldsh-<8 hex digits>`, derived from its install
  directory. **The launcher never removes (`gpuq -r`) or kills (`gpuq -k`) a job by number**, because ts numbers jobs
  from 0 again after its server restarts, so a number alone can't prove ownership. Instead:
  - a running job ends when the launcher stops the llama-server process it identified;
  - a job you cancelled while it waited for GPUs carries a cancel marker, and when dispatched it exits at once,
    holding the GPUs only for that moment;
  - if ownership can't be established, nothing is touched and a warning is printed.

  It never runs `gpuq -i` either: on a job that is still `allocating`, that crashed the ts server on the tested
  machine, twice. Avoid it yourself as well.

## Model catalog

`models/catalog.tsv` lists each model's Hugging Face repo, pinned revision, files with sizes and SHA-256 hashes, and
any links. `HF_ENDPOINT` selects a mirror.

| id | status | needs |
|---|---|---|
| `coder-iq2xxs` (default) | **verified** on GPU by this project | 72 GB VRAM + 111 GB Engram, memory-mapped from disk |
| `full-iq2xxs` | listed, **not tested** | 138 GB VRAM + the same Engram file |

The default context is 65536 tokens. The reason comes from an evaluation on the setup this project was derived from,
which used the same model, llama.cpp build and dsh version, but not local-dsh's scripts. There, one long
repository-navigation task ran out of context at 32K and passed at 64K. VRAM use was 73.2 GB at 64K across two GPUs.

## Plugins

The terminal UI is the third-party plugin [dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI) (MIT), pinned in
`versions.env`. It's installed only into the `dsh-tui` profile, from `lock/dsh-tui/pnpm-lock.yaml`, and isn't
vendored here. Install with `--no-tui` to
skip it; `dsh-web` and `dsh-run` don't need it. local-dsh changes four things in the TUI profile:
- **Model route:** pins the TUI to the local model and effort `high`; the plugin defaults to DeepSeek's hosted model.
- **Account sign-in:** disabled, as is session-log upload to DeepSeek.
- **Default preset:** declares the shipped `standard` preset without its web-search tool. With that tool, every
  session fails, because web search needs DeepSeek's API.
- **First-run wizard:** skipped (`~/.dsh-tui/onboarding.json`).

The TUI checks registry.npmjs.org for newer versions in the background. It installs nothing unless you run its
`/update` command. Don't, because `/update` would also replace the pinned dsh.

## Tests

```bash
tests/run-offline.sh      # no network, no GPU, no model; a few minutes. Runs on every push and PR (GitHub Actions)
tests/test-download.sh    # real Hugging Face download of one 5.8 MB file; about 1 minute
tests/gpu-smoke.sh        # after installing: one real agent task on the GPUs
```

- **Static checks:** shellcheck and `bash -n`.
- **Model catalog:** each model's files, first shard and links are consistent.
- **Preset generator:** run on a synthetic fixture; only the web-search row is removed.
- **Installer hardware detection:** run against a fake `nvidia-smi` (2x96 GB and 1x24 GB).
- **49 launcher lifecycle checks** (39 without task-spooler, as on CI): run with a mock `llama-server` and a mock `dsh`. They cover:
  - cold start, keeping the working directory as the workspace even inside a git repository;
  - passing arguments and exit codes through;
  - attaching to a server local-dsh did not start, and refusing a server with the wrong context;
  - Ctrl-C while loading, load failure and timeout, terminal hangup;
  - shared use by two clients, two launchers starting at once, and `dsh-stop`;
  - the VRAM guard and a missing TUI plugin;
  - the gpuq backend, on a private task-spooler socket and only when `ts` is installed: start, release, and
    cancelling while waiting for GPUs, and the queue server restarting while a launch waits.
- **Uninstall ownership:** with a fake install, it removes only that install's wrappers and builds, never a model
  directory outside the install, and it refuses `LOCAL_DSH_HOME=$HOME`.

## Verification status

| Behaviour | Mock-tested (offline suite) | Verified on the tested machine |
|---|---|---|
| Hardware/dependency detection, model fit | yes | yes (`install.sh --check` and the full install) |
| llama.cpp pinned build (sm_120) | n/a | yes |
| dsh + TUI plugin install, profile validation | profile checks only | yes |
| Model verify + Engram link (existing files) | n/a | yes (183 GB SHA-256) |
| Model download from Hugging Face | n/a | **pass** with a real 5.8 MB file from the pinned revision (`tests/test-download.sh`): interruption, resume, SHA-256 check, re-run without download, corrupt-partial and HTTP 404 handling. A full 183 GB download through local-dsh was not repeated; on this machine the files came from the reference setup, and the installer verified them. |
| Server lifecycle, `direct` scheduler | yes | **pass**: `dsh-run` started llama-server itself (inside a 2-GPU gpuq reservation, as this machine requires), model loaded in 14 s, task done, server stopped; 34 s in total |
| Server lifecycle, `gpuq` scheduler | yes (private queue) | **pass**: three launcher-owned jobs each reserved 2 GPUs, loaded the model and finished on exit. A launcher cancelled while its job was `allocating` removed the job. No leaked jobs, processes or state files. |
| `dsh-tui` tool call against the local model | mock dsh | **pass**: the footer showed `local-dsh-coder-iq2xxs`, a bash tool call wrote the expected file, double Ctrl+C exited 0, the server stopped. The TUI's only TCP peer was 127.0.0.1:8051. |
| `dsh-run` headless task | mock dsh | **pass** (`tests/gpu-smoke.sh`): the agent fixed a bug and ran the code; the server was stopped afterwards |
| `dsh-web` | mock dsh | **pass**: a real bash tool call through the browser UI, run in the release gate below. Ctrl-C stopped the server and released the gpuq job. |
| Single-GPU and non-Blackwell setups | n/a | **not tested** |
| `full-iq2xxs` model | n/a | **not tested** |

GPU validation: 2026-11-12 on the machine in [Requirements](#requirements), 64K context, model `coder-iq2xxs`.
A later fix to how the launcher tracks its server process (pid plus start time) was re-tested on the GPUs with
`tests/gpu-smoke.sh`, once per scheduler, with the same results.

**v0.1.0 release gate (same machine, code at `c4bba0a`):**
1. A clean install from a fresh clone, with a new `LOCAL_DSH_HOME`, the default `~/.local/bin`, and llama.cpp cloned
   from upstream GitHub and built. The existing model files were SHA-256-verified in place (183 GB in about 2
   minutes), not downloaded.
2. The installer created `dsh-web` and `dsh-run`. It skipped five command names already owned by another setup, as
   designed.
3. `dsh-web` reserved both GPUs through gpuq under the install's own label, and a real bash tool call through the
   browser UI wrote the expected file. Ctrl-C stopped the server and the job finished.
4. Afterwards there were no leftover processes, reservations or state files. A before/after comparison of user
   configuration showed only the two new launchers.

Two defects in the GPU validation script (a throwaway driver, not shipped) affected that run. Neither is a local-dsh
bug:
- **Simulated Ctrl-C never arrived.** The script sent SIGINT to `dsh-web` running as a background job of a
  non-interactive shell, and such jobs start with SIGINT ignored. The run was finished by ending the `dsh web`
  process, after which the launcher stopped the server and released the gpuq job normally. A real Ctrl-C in a
  terminal goes to the whole foreground process group and isn't affected.
- **Wrong install under test.** The first direct-scheduler attempt put another install's command wrappers on PATH.
  Those wrappers pin their own install, so that attempt used the gpuq scheduler and waited for GPUs held by its own
  reservation. Its launcher was cancelled, and its cleanup removed the waiting job. The step was then re-run
  correctly, and that run's result is the one reported above.

## Troubleshooting

- **`dsh-status` first.** It shows whether the server is healthy, who started it, and GPU and RAM use. The server log is
  `$LOCAL_DSH_HOME/logs/server-latest.log`.
- **"port answers but is not ..."**: something else is listening on `$PORT`, or a server is running with a
  different context. Stop that process yourself, or set another port: `./install.sh --port 8061`.
- **"only N MiB free on GPU(s)"** (direct scheduler): other processes hold GPU memory; the error lists them. Free
  the GPUs, or choose others with `./install.sh --gpus ...`.
- **Waiting for GPUs forever** (gpuq): other jobs hold the GPUs. `gpuq` shows the queue, and Ctrl-C cancels your
  request.
- **Never run `gpuq -i` (`ts -i`) on a job that is `queued` or `allocating`.**
  - *What happened:* on the tested machine (task-spooler GPU build 1522ab0), `gpuq -i <id>` on an `allocating` job
    crashed the ts server, twice. The next `gpuq` call silently started a new, empty server.
  - *Impact:* every queued and running job record and the finished-job history were lost, and job numbering
    restarted at 0. Processes of running jobs kept running, but the queue no longer tracked them or their
    reservation. A local-dsh launcher waiting for its job lost it. Killing an `allocating` job's ts runner process
    crashed a test ts server the same way.
  - *What local-dsh does:* never calls `gpuq -i`. It acts only on queue entries carrying its own install's label, which protects
    against job numbers being reused after a restart, and exits with "gpuq job N is no longer in the queue" when its
    job disappears.
  - *What you should do:* use only `gpuq` (list), `gpuq -s`, `gpuq -g` and `gpuq -c` to inspect jobs. If the queue
    was reset, check `nvidia-smi` for processes that still hold GPUs before submitting new work.
- **Server exits while loading:** read the server log. The usual causes are an out-of-memory error from too little
  VRAM, or a model directory without the Engram link; re-run `install.sh` to restore the link.
- **TUI shows `failed to create agent ... tool-web`:** the TUI profile was edited or reset. Re-run `install.sh`.
- **A model download stopped:** re-run `install.sh`; it resumes from the `.part` file. A permanent HTTP error, such as
  404 for a wrong revision or 401/403 for a gated repo, stops at once and prints the URL; check `HF_ENDPOINT` and any proxy. A hash mismatch keeps the
  partial file and asks you to delete it.
- **Plain dsh for debugging:** `DSH_HOME=$LOCAL_DSH_HOME/dsh-home $LOCAL_DSH_HOME/node-dsh-*/node_modules/.bin/dsh --profile headless --dump-config`.

## Updating and rollback

Each pinned llama.cpp commit and dsh version installs into its own directory
(`llama.cpp-build-<commit>`, `node-dsh-<version>`). Re-running `install.sh` keeps a timestamped `*.bak-*` copy of
every config file it changes. To roll back, return to the previous release and re-run the installer. The older
builds are still there, so it is quick:

```bash
git checkout <previous tag or commit>
./install.sh --yes
```

## Uninstall

```bash
./uninstall.sh                 # stop our server; remove our command links, builds and the isolated dsh install
./uninstall.sh --purge         # also delete $LOCAL_DSH_HOME (config, dsh sessions, logs)
./uninstall.sh --purge-models  # also delete the model directory
```

`uninstall.sh` acts on one installation, chosen by `LOCAL_DSH_HOME` (default `~/.local/share/local-dsh`). It removes
only that install's command wrappers, recognised by their marker line, and files under that directory.
`--purge-models` deletes the model's catalog files only when the model directory is inside the install directory;
a model directory elsewhere may be shared with another setup, so you delete it yourself. The TUI's per-user state
in `~/.dsh-tui` is left in place.

## Known limitations

- **Shared TUI state.** dsh-TUI keeps its preferences and history in `~/.dsh-tui`, and the location can't be changed
  without changing `HOME` for the agent too. Two local-dsh installs, or local-dsh and another dsh-TUI setup, on the
  same account share it. Choosing a model with the TUI's `/model` command is remembered there and overrides the
  installed route, so avoid `/model` when you run more than one setup.
- **Web UI workspace.** `dsh-web` doesn't take the current directory as its workspace; choose one in the browser.
  `dsh-tui` and `dsh-run` do use the current directory.
- **One model server per install.** `dsh-tui`, `dsh-web` and `dsh-run` from the same install share it. Two installs
  need different ports.

## What is not in Git

The following are kept out of the repository, both by design and through `.gitignore`:
- model files
- credentials (dsh's `.credentials.yaml`)
- tokens and `config.env`
- dsh profiles' installed packages
- sessions, logs, builds, caches and runtime files

The API key the launcher passes to dsh is a fixed placeholder; llama-server runs without authentication on
127.0.0.1.

## License

GPL-3.0; see `LICENSE`. Third-party components and their licenses are listed in `THIRD_PARTY.md`.
