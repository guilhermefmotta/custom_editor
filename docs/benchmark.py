#!/usr/bin/env python3
"""Idle CPU / RSS / open time / keystroke latency — editor vs. Emacs (ADR 0016).

Method and results: docs/benchmark.md. Run from the repository root:

    odin build . -out:/tmp/editor_bench -define:BENCH=true
    python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin
    python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --terminals 8
    python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --legacy   # always-render loop
    python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --keys 200
    python3 docs/benchmark.py plain  ./editor_old renderer.odin                 # any binary, CPU/RSS only
    python3 docs/benchmark.py emacs  /Applications/Emacs.app/Contents/MacOS/Emacs renderer.odin

Only the process this script starts is killed (SIGKILL, so the editor does
not write its session file). Nothing else is touched.
"""

import os
import re
import signal
import subprocess
import sys
import tempfile
import time

SETTLE_S = 5.0   # after the first frame: LSP / git / shells start up
WINDOW_S = 20.0  # idle measurement window


def cputime(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    parts = out.split(":")
    secs = float(parts[-1])
    if len(parts) >= 2:
        secs += 60 * float(parts[-2])
    if len(parts) >= 3:
        secs += 3600 * float(parts[-3])
    return secs


def ps_field(pid, field):
    out = subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return float(out) if out else None


def wait_for(pred, timeout):
    t = time.time()
    while time.time() - t < timeout:
        v = pred()
        if v:
            return v
        time.sleep(0.02)
    return None


def idle_window(pid):
    time.sleep(SETTLE_S)
    c0, t0 = cputime(pid), time.time()
    samples = []
    while time.time() - t0 < WINDOW_S:
        time.sleep(1.0)
        v = ps_field(pid, "%cpu")
        if v is not None:
            samples.append(v)
    c1, t1 = cputime(pid), time.time()
    rss_kb = ps_field(pid, "rss")
    return {
        "cpu_pct_cputime": 100.0 * (c1 - c0) / (t1 - t0),
        "cpu_pct_ps_avg": sum(samples) / max(1, len(samples)),
        "rss_mb": (rss_kb or 0) / 1024.0,
    }


def run_editor(binary, path, terminals=0, legacy=False, keys=0, bench=True):
    env = dict(os.environ)
    if terminals:
        env["EDITOR_BENCH_TERMINALS"] = str(terminals)
    if legacy:
        env["EDITOR_BENCH_EVENT_DRIVEN"] = "0"
    if keys:
        env["EDITOR_BENCH_KEYS"] = str(keys)
    log = tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False)
    t_launch = time.time()
    p = subprocess.Popen([binary, path], stdout=log, stderr=subprocess.STDOUT, env=env)
    res = {}
    try:
        def first_frame():
            with open(log.name) as f:
                m = re.search(r"BENCH first_frame since_main_ms=([\d.]+) wall_ms=(\d+)", f.read())
            return m
        if bench:
            m = wait_for(first_frame, 30)
            if m:
                res["open_ms"] = int(m.group(2)) - t_launch * 1000.0
                res["main_to_first_frame_ms"] = float(m.group(1))
        else:
            time.sleep(3)
        if keys:
            def done():
                with open(log.name) as f:
                    return re.search(rf"BENCH synth n={keys} p50=([\d.]+) p95=([\d.]+) max=([\d.]+)", f.read())
            m = wait_for(done, 4 + keys * 0.5 + 30)
            if m:
                res["synth_p50_ms"], res["synth_p95_ms"], res["synth_max_ms"] = map(float, m.groups())
        else:
            res.update(idle_window(p.pid))
    finally:
        p.send_signal(signal.SIGKILL)
        p.wait()
    with open(log.name) as f:
        for line in f:
            if line.startswith("BENCH idle") or line.startswith("BENCH terminals"):
                res.setdefault("log", []).append(line.strip())
    os.unlink(log.name)
    return res


def run_emacs(binary, path):
    out = tempfile.NamedTemporaryFile("w+", suffix=".txt", delete=False)
    out.close()
    # window-setup-hook runs after init and the initial frame is set up.
    elisp = (
        "(add-hook 'window-setup-hook (lambda () (with-temp-file \"%s\" "
        "(insert (format \"%%.3f %%s\" (float-time) (emacs-init-time \"%%.3f\")))))) " % out.name
    )
    t_launch = time.time()
    p = subprocess.Popen([binary, "--eval", elisp, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    res = {}
    try:
        def ready():
            s = open(out.name).read().strip()
            return s or None
        s = wait_for(ready, 60)
        if s:
            ts, init = s.split()
            res["open_ms"] = (float(ts) - t_launch) * 1000.0
            res["emacs_init_time_s"] = float(init)
        res.update(idle_window(p.pid))
    finally:
        p.send_signal(signal.SIGKILL)
        p.wait()
    os.unlink(out.name)
    return res


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    kind, binary, path = sys.argv[1:4]
    flags = sys.argv[4:]
    terminals = int(flags[flags.index("--terminals") + 1]) if "--terminals" in flags else 0
    keys = int(flags[flags.index("--keys") + 1]) if "--keys" in flags else 0
    if kind == "emacs":
        res = run_emacs(binary, path)
    else:
        res = run_editor(binary, path, terminals, "--legacy" in flags, keys, bench=(kind == "editor"))
    for k, v in res.items():
        if isinstance(v, float):
            print(f"{k}: {v:.2f}")
        elif isinstance(v, list):
            for line in v:
                print(f"  {line}")
        else:
            print(f"{k}: {v}")


if __name__ == "__main__":
    main()
