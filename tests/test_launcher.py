"""Offline tests of bin/local-dsh (server lifecycle + commands) with a mock llama-server and a mock dsh.

The direct backend is always tested. The gpuq backend is tested only when task-spooler (`ts`, GPU build) is on
PATH, through a private socket and a scratch savelist: the shared queue is never used.
usage: python3 -I tests/test_launcher.py
"""
import json, os, shlex, shutil, signal, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOCK = os.path.join(REPO, "tests", "mock")
TMP = tempfile.mkdtemp(prefix="local-dsh test-")  # a space in every path: quoting is under test too
HOME_DIR = os.path.join(TMP, "home")
PORT = str(18000 + os.getpid() % 1000)
DSH_LOG = os.path.join(TMP, "dsh.ndjson")
WORK = os.path.join(TMP, "repo", "sub", "dir")
BIN = os.path.join(TMP, "bin")
results = []

os.makedirs(WORK); os.makedirs(BIN); os.makedirs(os.path.join(TMP, "nodebin"))
subprocess.run(["git", "init", "-q", os.path.join(TMP, "repo")], check=True)
for n in ("dsh-tui", "dsh-web", "dsh-run", "dsh-status", "dsh-stop", "dst"):
    os.symlink(os.path.join(REPO, "bin", "local-dsh"), os.path.join(BIN, n))


def write_config(scheduler="direct", tui=True):
    os.makedirs(HOME_DIR, exist_ok=True)
    cfg = dict(MODEL_ID="mock", MODEL_DIR=TMP, MODEL_PATH=os.path.join(MOCK, "llama-server"), MODEL_ALIAS="local-dsh-mock",
               MIN_VRAM_GB="80", SCHEDULER=scheduler, CUDA_DEVICES="0,1", GPU_COUNT="2", TENSOR_SPLIT="1,1", PORT=PORT,
               CTX="65536", SERVER_EFFORT="50", EXTRA_SERVER_ARGS="", QUEUE_WAIT="40", LOAD_WAIT="30",
               LLAMA_SERVER=os.path.join(MOCK, "llama-server"), NODE_DIR=os.path.join(TMP, "nodebin"),  # empty: must not shadow PATH
               DSH_BIN=os.path.join(MOCK, "dsh"), DSH_HOME=os.path.join(HOME_DIR, "dsh-home"))
    with open(os.path.join(HOME_DIR, "config.env"), "w") as f:
        f.writelines(f"{k}={shlex.quote(v)}\n" for k, v in cfg.items())  # as install.sh writes it
    tui_dir = os.path.join(cfg["DSH_HOME"], "profiles", "dsh-tui", "node_modules", "@deepseek-harness-tui", "dsh-tui")
    if tui:
        os.makedirs(tui_dir, exist_ok=True)
    elif os.path.isdir(tui_dir):
        shutil.rmtree(tui_dir)


ENV = dict(os.environ, LOCAL_DSH_HOME=HOME_DIR, MOCK_DSH_LOG=DSH_LOG, MOCK_PORT=PORT, LOCAL_DSH_SKIP_VRAM_CHECK="1",
           PATH=BIN + ":" + os.environ["PATH"])


def run(cmd, extra=None, args=(), cwd=WORK):
    def pre():
        signal.signal(signal.SIGINT, signal.SIG_DFL)  # a terminal user's Ctrl-C
    env = dict(ENV, **(extra or {}))
    env = {k: v for k, v in env.items() if v is not None}
    return subprocess.Popen([os.path.join(BIN, cmd), *args], cwd=cwd, env=env, preexec_fn=pre,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def finish(p, timeout=120):
    out, _ = p.communicate(timeout=timeout)
    return p.returncode, out


def healthy():
    return subprocess.run(["curl", "-sf", "--max-time", "2", f"http://127.0.0.1:{PORT}/health"], capture_output=True).returncode == 0


def mock_servers():
    out = subprocess.run(["pgrep", "-f", f"{MOCK}/llama-server -m"], capture_output=True, text=True).stdout.split()
    return [p for p in out if p != str(os.getpid())]


def records():
    try:
        return [json.loads(l) for l in open(DSH_LOG)]
    except FileNotFoundError:
        return []


def wait_for(pred, secs):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.3)
    return False


def check(name, cond, detail=None):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + (f"   [{detail}]" if detail is not None and not cond else ""), flush=True)


def clean(tag):
    ok = wait_for(lambda: not mock_servers() and not healthy(), 40)
    owner = os.path.exists(os.path.join(HOME_DIR, "run", "server.owner"))
    check(f"{tag}: no server left, no owner record", ok and not owner, f"servers={mock_servers()} owner={owner}")


def external_server(ctx="65536"):
    p = subprocess.Popen([os.path.join(MOCK, "llama-server"), "-m", "x", "--port", PORT, "--ctx-size", ctx, "--alias", "local-dsh-mock"],
                         env=dict(ENV, MOCK_LOAD_DELAY="0"), stdout=subprocess.DEVNULL)
    assert wait_for(healthy, 10)
    return p


def direct_tests():
    write_config("direct")
    # cold start: server started, TUI in exactly this directory, server stopped on exit
    rc, out = finish(run("dsh-tui"))
    r = records()[-1] if records() else {}
    check("tui cold start: rc 0", rc == 0, out[-500:])
    check("tui: argv is the dsh-tui profile", r.get("argv") == ["--profile", "dsh-tui"], r)
    check("tui: cwd kept and workspace target = launch dir (not the git root)", r.get("cwd") == WORK and r.get("target") == WORK, r)
    check("tui: local model served while running, telemetry env off", r.get("model") == "local-dsh-mock" and r.get("telemetry_off") == "1", r)
    clean("tui cold start")
    rc, out = finish(run("dst", args=["--resume", "abc"]))
    r = records()[-1]
    check("dst alias passes args, no workspace target with args", rc == 0 and r.get("argv") == ["--profile", "dsh-tui", "--resume", "abc"] and r.get("target") is None, r)
    clean("dst")
    rc, out = finish(run("dsh-web"))
    check("dsh-web: web profile, --no-open", rc == 0 and records()[-1]["argv"] == ["--profile", "web", "--no-open"], records()[-1])
    clean("dsh-web")
    rc, out = finish(run("dsh-run", extra={"MOCK_RC": "3"}, args=["fix it"]))
    check("dsh-run: headless profile, task passed, exit code 3 propagated", rc == 3 and records()[-1]["argv"] == ["--profile", "headless", "fix it"], out[-300:])
    clean("dsh-run")
    rc, out = finish(run("dsh-run"))
    check("dsh-run without a task: usage error, nothing started", rc != 0 and "usage" in out and not mock_servers())

    # attach to a server local-dsh did not start: left running
    srv = external_server()
    rc, out = finish(run("dsh-run", args=["t"]))
    check("attach: rc 0, says it will leave the server", rc == 0 and "did not start" in out, out[-300:])
    check("attach: external server still running", healthy() and srv.poll() is None)
    rc, out = finish(run("dsh-stop"))
    check("dsh-stop refuses a server it did not start", "not started by local-dsh" in out and healthy(), out)
    srv.terminate(); srv.wait()
    clean("attach")

    srv = external_server(ctx="8192")
    rc, out = finish(run("dsh-run", args=["t"]))
    check("wrong context on the port: refused, server untouched", rc != 0 and healthy() and srv.poll() is None, out[-300:])
    srv.terminate(); srv.wait()
    clean("wrong-ctx")

    # interruptions and failures
    p = run("dsh-run", extra={"MOCK_LOAD_DELAY": "60"}, args=["t"])
    wait_for(lambda: bool(mock_servers()), 20); time.sleep(2)
    p.send_signal(signal.SIGINT); rc, out = finish(p)
    check("Ctrl-C while loading: rc 130", rc == 130, out[-300:])
    clean("ctrl-c loading")
    rc, out = finish(run("dsh-run", extra={"MOCK_FAIL": "1"}, args=["t"]))
    check("server fails while loading: rc 1, clear message", rc == 1 and "exited while loading" in out, out[-300:])
    clean("load failure")
    rc, out = finish(run("dsh-run", extra={"MOCK_LOAD_DELAY": "120"}, args=["t"]), 90)
    check("load timeout: rc 1", rc == 1 and "not healthy" in out, out[-300:])
    clean("load timeout")
    p = run("dsh-tui", extra={"MOCK_SLEEP": "60"})
    wait_for(lambda: len(records()) and healthy(), 30); time.sleep(1)
    p.send_signal(signal.SIGHUP); finish(p)
    clean("terminal hangup during the TUI")

    # several clients: the server stays until the last local-dsh client exits
    n0 = len(records())
    a = run("dsh-tui", extra={"MOCK_SLEEP": "12"})
    wait_for(lambda: len(records()) > n0, 30)
    rc_b, out_b = finish(run("dsh-run", extra={"MOCK_SLEEP": "1"}, args=["t"]))
    check("second client reuses the running local-dsh server", rc_b == 0 and "using the running local-dsh server" in out_b, out_b[-300:])
    check("second client exits first: server left for the other client", healthy() and "leaving the server running" in out_b, out_b[-300:])
    rc_a, out_a = finish(a)
    check("last client exits: rc 0 and server stopped", rc_a == 0 and "server stopped" in out_a, out_a[-300:])
    clean("two clients")

    # concurrent cold starts: one server
    a = run("dsh-run", extra={"MOCK_LOAD_DELAY": "4", "MOCK_SLEEP": "5"}, args=["t"])
    b = run("dsh-run", extra={"MOCK_SLEEP": "1"}, args=["t"])
    rc_a, out_a = finish(a); rc_b, out_b = finish(b)
    starts = (out_a + out_b).count("starting llama-server")
    check("two launchers at once: exactly one server started, both rc 0", starts == 1 and rc_a == 0 and rc_b == 0, out_a[-200:] + out_b[-200:])
    clean("concurrent")

    # dsh-stop while a client runs
    n0 = len(records())
    a = run("dsh-tui", extra={"MOCK_SLEEP": "8"})
    wait_for(lambda: len(records()) > n0, 30)
    rc, out = finish(run("dsh-stop"))
    check("dsh-stop stops the local-dsh server (warns about the client)", "server stopped" in out and "still using" in out and wait_for(lambda: not healthy(), 10), out)
    finish(a)
    clean("dsh-stop")

    # VRAM guard and missing plugin
    rc, out = finish(run("dsh-run", extra={"LOCAL_DSH_SKIP_VRAM_CHECK": None, "PATH": MOCK + ":" + ENV["PATH"],
                                            "MOCK_GPUS": "A:97887:20000:12.0;B:97887:20000:12.0"}, args=["t"]))
    check("direct: refuses when the GPUs lack free memory, starts nothing", rc != 0 and "MiB free" in out and not mock_servers(), out[-300:])
    clean("vram guard")
    write_config("direct", tui=False)
    rc, out = finish(run("dsh-tui"))
    check("dsh-tui without the plugin: clear error, nothing started", rc != 0 and "--with-tui" in out and not mock_servers(), out[-300:])
    write_config("direct")
    rc, out = finish(run("dsh-status"))
    check("dsh-status runs", rc == 0 and "server:   not running" in out, out)


def find_task_spooler():
    for ts in (shutil.which("ts"), os.path.expanduser("~/.local/bin/ts")):
        if ts and os.path.exists(ts):
            h = subprocess.run([ts, "-h"], capture_output=True, text=True).stdout
            if "Task Spooler" in h and "--gpus" in h:
                return ts
    return None


def gpuq_tests(ts):
    shim_dir = os.path.join(TMP, "shim"); os.makedirs(shim_dir)
    sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", TMP), f"ldt{os.getpid()}.sock")
    with open(os.path.join(shim_dir, "gpuq"), "w") as f:  # private queue; never the shared one
        f.write(f"#!/usr/bin/env bash\nexport TS_SOCKET={sock} TS_SLOTS=2 TS_SAVELIST={TMP}/queue.dump\nexec {ts} \"$@\"\n")
    os.chmod(os.path.join(shim_dir, "gpuq"), 0o755)
    env = dict(PATH=shim_dir + ":" + ENV["PATH"])
    q = lambda *a: subprocess.run(["gpuq", *a], env=dict(ENV, **env), capture_output=True, text=True).stdout.strip()
    q("--set_gpu_free_perc", "1")  # this private server only: mock jobs may run while real GPUs are busy
    jobs = lambda: [l.split() for l in q().splitlines()[1:] if l.strip()]
    unfinished = lambda: [j for j in jobs() if j[1] != "finished"]
    try:
        write_config("gpuq")
        rc, out = finish(run("dsh-run", extra=env, args=["t"]))
        check("gpuq: cold start, rc 0, job labelled local-dsh", rc == 0 and "requested 2 GPU(s) from gpuq" in out and any("local-dsh" in " ".join(j) for j in jobs()), out[-400:])
        check("gpuq: job finished after the client exits", wait_for(lambda: not unfinished(), 30), jobs())
        clean("gpuq cold start")
        blocker = q("-L", "other-job", "-G", "2", "sleep", "300")
        wait_for(lambda: any(j[0] == blocker and j[1] == "running" for j in jobs()), 30)
        p = run("dsh-run", extra=env, args=["t"]); time.sleep(8)
        p.send_signal(signal.SIGINT); rc, out = finish(p)
        check("gpuq: Ctrl-C while waiting for GPUs -> rc 130, job removed or marked", rc == 130 and ("removed gpuq job" in out or "cancel marker" in out), out[-400:])
        check("gpuq: the other job is untouched", any(j[0] == blocker and j[1] == "running" for j in jobs()), jobs())
        q("-k", blocker)
        check("gpuq: a cancelled job exits at dispatch without a server", wait_for(lambda: not unfinished(), 40) and not mock_servers(), jobs())
        run_dir = os.path.join(HOME_DIR, "run")
        check("gpuq: cancel markers cleaned up", not [x for x in os.listdir(run_dir) if x.startswith("cancel-")], os.listdir(run_dir))
        clean("gpuq cancel")
        # the queue server restarts while we wait (all jobs forgotten): exit with a clear error, do not hang
        blocker = q("-L", "other-job", "-G", "2", "sleep", "300")
        wait_for(lambda: any(j[0] == blocker and j[1] == "running" for j in jobs()), 30)
        blocker_pid = q("-p", blocker)  # killed by pid below: the restarted server no longer knows the job
        p = run("dsh-run", extra=env, args=["t"]); time.sleep(8)
        q("-K"); time.sleep(1); q("--set_gpu_free_perc", "1")  # private server only
        t0 = time.time(); rc, out = finish(p, 60)
        check("gpuq: queue restarted while waiting -> clear error within seconds",
              rc == 1 and "no longer in the queue" in out and time.time() - t0 < 30, out[-300:])
        if blocker_pid.isdigit():
            try:
                os.kill(int(blocker_pid), signal.SIGTERM)
            except ProcessLookupError:
                pass
        clean("gpuq queue restart")
    finally:
        q("-K")


if __name__ == "__main__":
    try:
        direct_tests()
        ts = find_task_spooler()
        if ts:
            gpuq_tests(ts)
        else:
            print("SKIP gpuq backend tests: task-spooler with GPU support not found")
    finally:
        for pid in mock_servers():
            os.kill(int(pid), signal.SIGTERM)
        shutil.rmtree(TMP, ignore_errors=True)
    print(f"\n{sum(ok for _, ok in results)}/{len(results)} launcher checks passed")
    sys.exit(0 if all(ok for _, ok in results) else 1)
