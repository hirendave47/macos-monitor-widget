#!/usr/bin/env python3
"""
macOS System Monitor — Apple Silicon (tuned for M5 Max) — local LLM inference
Requires: mactop (brew install mactop). No sudo needed.
Usage:
    python3 macos_monitor.py                # live mode (Ctrl+C to stop)
    python3 macos_monitor.py --once         # single snapshot
    python3 macos_monitor.py --compact      # one-line summary
    python3 macos_monitor.py -i 2           # refresh every 2 s
    python3 macos_monitor.py --csv run.csv  # also record every sample to CSV
"""

import sys
import os
import re
import csv
import json
import time
import signal
import shutil
import argparse
import plistlib
import subprocess
import unicodedata
import urllib.request
from collections import deque
from datetime import datetime
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────────
CPU_TEMP_WARN       = 80      # °C
CPU_TEMP_CRIT       = 95
GPU_TEMP_WARN       = 80
GPU_TEMP_CRIT       = 95
MEM_WARN_PCT        = 85      # %
SWAP_WARN_PCT       = 80
SWAP_GROWTH_WARN_GB = 1.0     # swap growth since monitor start
DISK_WARN_PCT       = 85
BATT_LOW_PCT        = 20
CHECK_INTERVAL      = 10      # seconds
HISTORY             = 60      # samples kept for sparklines / avg / peak
ALERT_COOLDOWN      = 300     # seconds between identical log alerts
LOG_FILE            = Path.home() / "macos-monitor.log"
ALERT_FILE          = Path.home() / "macos-alerts.log"
LLM_HINTS = ("ollama", "llama-server", "llama-cli", "llama-bench", "llamafile",
             "mlx_lm", "mlx-lm", "mlx_vlm", "lm studio", "lmstudio",
             "koboldcpp", "mistralrs", "vllm")
SKIP_EXE  = {"ps", "grep", "tail", "less", "cat", "vim", "nvim", "nano", "code"}

# ── ANSI colours ───────────────────────────────────────────────────────────────
R   = "\033[0;31m"
Y   = "\033[1;33m"
G   = "\033[0;32m"
B   = "\033[0;34m"
C   = "\033[0;36m"
M   = "\033[0;35m"
W   = "\033[1m"
DIM = "\033[2m"
NC  = "\033[0m"

WIDTH = 100   # inner box width, recalculated every frame from terminal size

def set_width():
    global WIDTH
    cols = shutil.get_terminal_size((104, 40)).columns
    WIDTH = max(76, min(cols - 2, 118))

# ── Small helpers ──────────────────────────────────────────────────────────────
def fnum(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default

def sh(cmd, timeout=3, raw=False):
    try:
        out = subprocess.check_output(cmd, timeout=timeout, stderr=subprocess.DEVNULL)
        return out if raw else out.decode(errors="replace")
    except Exception:
        return b"" if raw else ""

_CACHE = {}
def cached(key, ttl, fn):
    now = time.time()
    hit = _CACHE.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    val = fn()
    _CACHE[key] = (now, val)
    return val

# ── Logging ────────────────────────────────────────────────────────────────────
def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] {msg}\n")

_alert_last = {}
def log_alert(key, msg):
    now = time.time()
    if now - _alert_last.get(key, 0) < ALERT_COOLDOWN:
        return
    _alert_last[key] = now
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(ALERT_FILE, "a") as f:
        f.write(f"[{ts}] ALERT: {msg}\n")
    log(f"ALERT: {msg}")

# ── Colour / bar / sparkline ───────────────────────────────────────────────────
def temp_color(val, warn, crit):
    if val >= crit: return R
    if val >= warn: return Y
    return G

def usage_color(pct):
    if pct >= 90: return R
    if pct >= 70: return Y
    return G

def tfmt(v, warn=CPU_TEMP_WARN, crit=CPU_TEMP_CRIT):
    return f"{temp_color(v, warn, crit)}{v:.1f}°C{NC}"

def bar(pct, width=28, color=G):
    pct = max(0, min(100, int(round(pct))))
    filled = int(pct * width / 100)
    return f"[{color}{'█' * filled}{NC}{DIM}{'░' * (width - filled)}{NC}] {pct:3d}%"

SPARK = "▁▂▃▄▅▆▇█"
def spark(vals, lo=0.0, hi=None, width=32):
    v = list(vals)[-width:]
    if not v:
        return " " * width
    top = hi if hi is not None else max(v)
    span = (top - lo) or 1.0
    s = "".join(SPARK[max(0, min(7, int((x - lo) / span * 7.999)))] for x in v)
    return f"{C}{s}{NC}" + " " * (width - len(v))

class Track:
    def __init__(self):
        self.h = deque(maxlen=HISTORY)
        self.peak = 0.0
        self.total = 0.0
        self.cnt = 0
    def add(self, v):
        self.h.append(v)
        self.peak = max(self.peak, v)
        self.total += v
        self.cnt += 1
    @property
    def avg(self):
        return self.total / self.cnt if self.cnt else 0.0

TRK = {k: Track() for k in ("cpu", "gpu", "ane", "cpu_w", "gpu_w", "pkg_w", "bw",
                            "cpu_t", "gpu_t", "ram", "disk_r", "disk_w")}
STATE = {"swap0": None}

def stat(t, unit="", dec=0):
    return f"{DIM}avg {t.avg:.{dec}f}{unit}  peak {t.peak:.{dec}f}{unit}{NC}"

# ── Width-safe box drawing ─────────────────────────────────────────────────────
TOKEN_RE = re.compile(r"(\033\[[0-9;?]*[A-Za-z])")

def cw(ch):
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1

def vlen(s):
    return sum(cw(c) for c in TOKEN_RE.sub("", s))

def fit(s, width):
    """Pad or truncate to exactly `width` visible columns, keeping ANSI codes intact."""
    out, n = [], 0
    for tok in TOKEN_RE.split(s):
        if TOKEN_RE.fullmatch(tok):
            out.append(tok)
            continue
        for ch in tok:
            w = cw(ch)
            if n + w > width:
                return "".join(out) + NC + " " * (width - n)
            out.append(ch)
            n += w
    return "".join(out) + NC + " " * (width - n)

def box(color, title, rows, double=False):
    tl, h, tr, v, bl, br = "╔═╗║╚╝" if double else "┌─┐│└┘"
    if title:
        fill = max(0, WIDTH - vlen(title) - 3)
        top = f"{color}{tl}{h} {W}{title}{NC}{color} {h * fill}{tr}{NC}"
    else:
        top = f"{color}{tl}{h * WIDTH}{tr}{NC}"
    out = [top]
    for r in rows:
        out.append(f"{color}{v}{NC}{fit(' ' + r, WIDTH)}{color}{v}{NC}")
    out.append(f"{color}{bl}{h * WIDTH}{br}{NC}")
    return out

# ── Dependencies ───────────────────────────────────────────────────────────────
def find_mactop():
    for p in (shutil.which("mactop"), "/opt/homebrew/bin/mactop",
              "/opt/homebrew/opt/mactop/bin/mactop", "/usr/local/bin/mactop"):
        if p and Path(p).exists():
            return p
    return None

MACTOP_BIN = find_mactop()

def check_deps():
    global MACTOP_BIN
    if MACTOP_BIN:
        return
    print(f"{Y}Missing dependency:{NC} mactop  →  brew install mactop")
    if shutil.which("brew") and input("Install now? [y/N] ").strip().lower() == "y":
        subprocess.run(["brew", "install", "mactop"], check=False)
        MACTOP_BIN = find_mactop()
    if not MACTOP_BIN:
        print(f"{R}mactop not found. Aborting.{NC}")
        sys.exit(1)

# ── Data sources ───────────────────────────────────────────────────────────────
def get_static():
    st = {"chip": sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip() or "Apple Silicon"}
    try:
        st["ram_gb"] = int(sh(["sysctl", "-n", "hw.memsize"]).strip()) / 1024 ** 3
    except ValueError:
        st["ram_gb"] = 0.0
    levels = {}
    for i in range(3):
        name = sh(["sysctl", "-n", f"hw.perflevel{i}.name"]).strip().lower()
        cnt = sh(["sysctl", "-n", f"hw.perflevel{i}.physicalcpu"]).strip()
        if name and cnt.isdigit():
            levels[name] = int(cnt)
    st["n_super"] = levels.get("super", 0)
    st["n_perf"]  = levels.get("performance", 0)
    st["n_eff"]   = levels.get("efficiency", 0)
    phys = sh(["sysctl", "-n", "hw.physicalcpu"]).strip()
    if not (st["n_super"] or st["n_perf"] or st["n_eff"]) and phys.isdigit():
        st["n_perf"] = int(phys)
    st["ncpu"] = st["n_super"] + st["n_perf"] + st["n_eff"]
    gc = re.search(r"Total Number of Cores:\s*(\d+)",
                   sh(["system_profiler", "SPDisplaysDataType"], timeout=15))
    st["gpu_cores"] = int(gc.group(1)) if gc else 0
    return st

def fetch_metrics():
    """Run mactop headless; take the 2nd sample so per-process deltas are valid."""
    for count in (2, 1):
        raw = sh([MACTOP_BIN, "--headless", "--count", str(count), "--format", "json"], timeout=20)
        try:
            data = json.loads(raw)
        except ValueError:
            continue
        if isinstance(data, list):
            data = data[-1] if data else {}
        if data:
            return data
    log("mactop fetch error")
    return {}

def get_uptime():
    m = re.search(r"sec = (\d+)", sh(["sysctl", "-n", "kern.boottime"]))
    if not m:
        return "?"
    up = int(time.time()) - int(m.group(1))
    d, rem = divmod(up, 86400)
    h, rem = divmod(rem, 3600)
    mi = rem // 60
    if d: return f"{d}d {h}h {mi}m"
    if h: return f"{h}h {mi}m"
    return f"{mi}m"

def get_vm():
    out = sh(["vm_stat"])
    ps = re.search(r"page size of (\d+)", out)
    ps = int(ps.group(1)) if ps else 16384
    def pages(label):
        mm = re.search(label + r":\s+(\d+)", out)
        return int(mm.group(1)) * ps / 1024 ** 3 if mm else 0.0
    return {"free": pages("Pages free"), "active": pages("Pages active"),
            "inactive": pages("Pages inactive"), "wired": pages("Pages wired down"),
            "compressor": pages("Pages occupied by compressor"),
            "cache": pages("File-backed pages")}

def get_pm():
    t = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", sh(["pmset", "-g", "therm"]))
    lpm = re.findall(r"lowpowermode\s+(\d)", sh(["pmset", "-g"]))
    return (int(t.group(1)) if t else 100, "1" in lpm)

def get_wired_limit():
    v = sh(["sysctl", "-n", "iogpu.wired_limit_mb"]).strip()
    return int(v) if v.isdigit() else None

def get_smart():
    mm = re.search(r"SMART Status:\s*(.+)", sh(["diskutil", "info", "/"], timeout=5))
    return mm.group(1).strip() if mm else "n/a"

def get_battery():
    try:
        b = plistlib.loads(sh(["ioreg", "-rn", "AppleSmartBattery", "-a"], raw=True))[0]
    except Exception:
        return {}
    cur = b.get("AppleRawMaxCapacity") or b.get("MaxCapacity") or 0
    des = b.get("DesignCapacity") or 0
    if des > 500 and cur > 100:
        health = cur / des * 100
    else:
        health = cur if 0 < cur <= 100 else 0
    tr = b.get("TimeRemaining")
    return {"health": health, "cur_mah": cur if cur > 100 else 0, "des_mah": des,
            "cycles": b.get("CycleCount"), "temp": fnum(b.get("Temperature")) / 100.0,
            "time_rem": tr if isinstance(tr, int) and 0 < tr < 6000 else None}

def get_ollama():
    """Returns list of loaded models, [] if none, None if the server is unreachable."""
    host = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
    if not host.startswith("http"):
        host = "http://" + host
    host = host.replace("0.0.0.0", "127.0.0.1").rstrip("/")
    try:
        with urllib.request.urlopen(host + "/api/ps", timeout=1.5) as r:
            return json.loads(r.read().decode()).get("models", [])
    except Exception:
        return None

def proc_name(cmd):
    mm = re.search(r"/([^/]+)\.app/", cmd)
    if mm:
        return mm.group(1)
    t = cmd.split()
    exe = os.path.basename(t[0])
    if exe.lower().startswith("python"):
        if "-m" in t and t.index("-m") + 1 < len(t):
            return t[t.index("-m") + 1]
        for a in t[1:]:
            if not a.startswith("-"):
                return os.path.basename(a)
    return exe

def get_llm_procs():
    out = sh(["ps", "-Ao", "pid=,pcpu=,rss=,command="])
    me = str(os.getpid())
    agg = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, cpu, rss, cmd = parts
        low = cmd.lower()
        if pid == me or "macos_monitor" in low or "mactop" in low:
            continue
        if not any(h in low for h in LLM_HINTS):
            continue
        if os.path.basename(cmd.split()[0]) in SKIP_EXE:
            continue
        a = agg.setdefault(proc_name(cmd), [0.0, 0.0, 0])
        a[0] += fnum(cpu)
        a[1] += fnum(rss) / 1024
        a[2] += 1
    return sorted(agg.items(), key=lambda kv: kv[1][1], reverse=True)[:5]

def fmt_dur(sec):
    sec = int(sec)
    if sec <= 0: return "now"
    h, r = divmod(sec, 3600)
    mi, s = divmod(r, 60)
    if h:  return f"{h}h{mi:02d}m"
    if mi: return f"{mi}m{s:02d}s"
    return f"{s}s"

def until_str(iso):
    try:
        s = re.sub(r"\.\d+", "", iso or "").replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        rem = (dt - datetime.now(dt.tzinfo)).total_seconds()
        return "pinned" if rem > 10 * 365 * 86400 else fmt_dur(rem)
    except Exception:
        return "?"

# ── Normalise mactop JSON + extras into one flat dict ──────────────────────────
def parse(d, st):
    s    = d.get("soc_metrics") or {}
    tmp  = {t.get("group"): t for t in (d.get("temperatures") or [])}
    mem  = d.get("memory") or {}
    vols = d.get("volumes") or []
    nd   = d.get("net_disk") or {}
    bat  = d.get("battery") or {}
    ps   = d.get("power_supply") or {}
    def T(group, key="avg_celsius"):
        return fnum((tmp.get(group) or {}).get(key))

    m = {
        "s_pct": fnum(s.get("s_cluster_active")), "p_pct": fnum(s.get("p_cluster_active")),
        "s_mhz": int(fnum(s.get("s_cluster_freq_mhz"))), "p_mhz": int(fnum(s.get("p_cluster_freq_mhz"))),
        "gpu_pct": fnum(s.get("gpu_active")), "gpu_mhz": int(fnum(s.get("gpu_freq_mhz"))),
        "ane_pct": fnum(s.get("ane_active")),
        "cpu_w": fnum(s.get("cpu_power")), "gpu_w": fnum(s.get("gpu_power")),
        "ane_w": fnum(s.get("ane_power")), "dram_w": fnum(s.get("dram_power")),
        "sys_w": fnum(s.get("system_power")), "tot_w": fnum(s.get("total_power")),
        "dram_read": fnum(s.get("dram_read_bw_gbs")), "dram_write": fnum(s.get("dram_write_bw_gbs")),
        "dram_bw": fnum(s.get("dram_bw_combined_gbs")),
        "cpu_die_t": T("CPU Die") or fnum(s.get("cpu_temp")),
        "pcpu_t": T("CPU P-Core"), "pcpu_max": T("CPU P-Core", "max_celsius"),
        "scpu_t": T("CPU S-Core"),
        "gpu_t": T("GPU") or fnum(s.get("gpu_temp")),
        "mem_t": T("Memory"), "soc_t": T("SoC Package"),
        "ssd_t": T("SSD"), "nand_t": T("NAND"),
        "thermal_state": d.get("thermal_state") or "Unknown",
    }
    n = max(1, st["n_super"] + st["n_perf"])
    m["cpu_pct"] = (m["s_pct"] * st["n_super"] + m["p_pct"] * st["n_perf"]) / n \
        if st["n_super"] + st["n_perf"] else max(m["p_pct"], m["s_pct"])

    fans = d.get("fans") or []
    m["fans"] = [{"id": f.get("id", i), "rpm": int(fnum(f.get("rpm"))), "max": fnum(f.get("max_rpm"))}
                 for i, f in enumerate(fans)]
    m["fan0"] = m["fans"][0]["rpm"] if len(m["fans"]) > 0 else ""
    m["fan1"] = m["fans"][1]["rpm"] if len(m["fans"]) > 1 else ""

    total = fnum(mem.get("total"), 1) or 1
    GB = 1024 ** 3
    m.update({
        "ram_total_gb": total / GB, "ram_used_gb": fnum(mem.get("used")) / GB,
        "comp_gb": fnum(mem.get("compressed")) / GB,
        "swap_total_gb": fnum(mem.get("swap_total")) / GB, "swap_used_gb": fnum(mem.get("swap_used")) / GB,
        "pressure": mem.get("pressure_state") or "Normal",
        "pressure_pct": fnum(mem.get("pressure_approx")),
    })
    m["ram_pct"]  = m["ram_used_gb"] / m["ram_total_gb"] * 100
    m["swap_pct"] = m["swap_used_gb"] / m["swap_total_gb"] * 100 if m["swap_total_gb"] else 0.0

    v0 = vols[0] if vols else {}
    m.update({
        "disk_name": v0.get("name") or "Mac HD",
        "disk_used": fnum(v0.get("used_gb")), "disk_total": fnum(v0.get("total_gb")),
        "disk_pct": fnum(v0.get("used_percent")),
        "disk_r_mbs": fnum(nd.get("read_kbytes_per_sec")) / 1024,
        "disk_w_mbs": fnum(nd.get("write_kbytes_per_sec")) / 1024,
        "net_in_mbs": fnum(nd.get("in_bytes_per_sec")) / 1024 ** 2,
        "net_out_mbs": fnum(nd.get("out_bytes_per_sec")) / 1024 ** 2,
    })
    m.update({
        "batt_pct": int(fnum(bat.get("percent"))), "charging": bool(bat.get("charging")),
        "batt_w": fnum(bat.get("power_watts")), "adapter_w": fnum(ps.get("adapter_watts")),
    })
    m["procs"] = d.get("processes") or []
    return m

def collect(d, st):
    m = parse(d, st)
    m["vm"] = get_vm()
    m["speed_limit"], m["lpm"] = cached("pm", 10, get_pm)
    m["wired_limit_mb"] = cached("wl", 30, get_wired_limit)
    m["bx"] = cached("batt", 30, get_battery) or {}
    m["smart"] = cached("smart", 300, get_smart)
    m["ollama"] = get_ollama()
    m["llm_procs"] = get_llm_procs()
    m["ollama_models"] = ";".join(mo.get("name", "?") for mo in (m["ollama"] or []))

    if STATE["swap0"] is None:
        STATE["swap0"] = m["swap_used_gb"]
    m["swap_delta_gb"] = m["swap_used_gb"] - STATE["swap0"]

    for k, v in (("cpu", m["cpu_pct"]), ("gpu", m["gpu_pct"]), ("ane", m["ane_pct"]),
                 ("cpu_w", m["cpu_w"]), ("gpu_w", m["gpu_w"]), ("pkg_w", m["tot_w"]),
                 ("bw", m["dram_bw"]), ("cpu_t", m["cpu_die_t"]), ("gpu_t", m["gpu_t"]),
                 ("ram", m["ram_pct"]), ("disk_r", m["disk_r_mbs"]), ("disk_w", m["disk_w_mbs"])):
        TRK[k].add(v)
    return m

# ── Warnings ───────────────────────────────────────────────────────────────────
def get_warnings(m, st):
    w = []
    if m["cpu_die_t"] > CPU_TEMP_WARN:
        w.append(("cpu_t", f"CPU die temp high: {m['cpu_die_t']:.1f}°C (warn {CPU_TEMP_WARN}, crit {CPU_TEMP_CRIT})"))
    if m["gpu_t"] > GPU_TEMP_WARN:
        w.append(("gpu_t", f"GPU temp high: {m['gpu_t']:.1f}°C (warn {GPU_TEMP_WARN}, crit {GPU_TEMP_CRIT})"))
    if m["speed_limit"] < 100:
        w.append(("throttle", f"Thermal throttling: CPU speed limit {m['speed_limit']}%"))
    if m["thermal_state"] in ("Serious", "Critical"):
        w.append(("tstate", f"Thermal state: {m['thermal_state']}"))
    if m["lpm"]:
        w.append(("lpm", "Low Power Mode is ON — GPU/CPU performance reduced"))
    if m["ram_pct"] > MEM_WARN_PCT:
        w.append(("ram", f"RAM usage high: {m['ram_pct']:.1f}% (warn {MEM_WARN_PCT}%)"))
    if m["pressure"] in ("Warning", "Critical"):
        w.append(("press", f"Memory pressure: {m['pressure']}"))
    if m["swap_pct"] > SWAP_WARN_PCT:
        w.append(("swap", f"Swap usage {m['swap_pct']:.0f}% — model/context may not fit in RAM"))
    if m["swap_delta_gb"] >= SWAP_GROWTH_WARN_GB:
        w.append(("swapgrow", f"Swap grew {m['swap_delta_gb']:+.1f} GB since monitor start"))
    if m["disk_pct"] > DISK_WARN_PCT:
        w.append(("disk", f"Disk usage high: {m['disk_pct']:.1f}% (warn {DISK_WARN_PCT}%)"))
    if not m["charging"] and m["adapter_w"] <= 0:
        if m["batt_pct"] < BATT_LOW_PCT:
            w.append(("batt", f"Battery low: {m['batt_pct']}% and not charging"))
        if m["gpu_pct"] > 50:
            w.append(("onbatt", "Heavy GPU load on battery — plug in for full performance"))
    for mo in (m["ollama"] or []):
        size, vram = fnum(mo.get("size")), fnum(mo.get("size_vram"))
        if size and vram / size < 0.98:
            w.append(("split_" + str(mo.get("name")),
                      f"Ollama '{mo.get('name')}' only {vram / size * 100:.0f}% on GPU — rest runs on CPU (slow)"))
    return w

# ══════════════════════════════════════════════════════════════════════════════
# Display sections (each returns a list of lines)
# ══════════════════════════════════════════════════════════════════════════════
def display_header(m, st):
    gpu = f"{st['gpu_cores']}-core GPU" if st["gpu_cores"] else "GPU"
    src = f"AC {m['adapter_w']:.0f} W" if m["adapter_w"] > 0 else "Battery"
    tcol = {"Nominal": G, "Fair": Y, "Serious": R, "Critical": R}.get(m["thermal_state"], C)
    rows = [
        f"{W}macOS System Monitor — {st['chip']}{NC}  "
        f"{DIM}({st['ncpu']}-core CPU · {gpu} · {st['ram_gb']:.0f} GB){NC}",
        f"{datetime.now():%Y-%m-%d %H:%M:%S}  │  Uptime: {get_uptime()}  │  Power: {src}"
        f"  │  Thermal: {tcol}{m['thermal_state']}{NC}",
    ]
    return box(C, "", rows, double=True)

def display_warnings(warns):
    if not warns:
        return []
    rows = [f"{R}! {msg}{NC}" for _, msg in warns]
    return box(R, "WARNINGS", rows, double=True)

def display_soc(m, st):
    bw = max(10, min(40, WIDTH - 48))
    rows = []

    # CPU
    rows.append(f"{W}CPU  {st['n_super']} Super + {st['n_perf']} Performance cores{NC}")
    for label, n, pct, mhz in (("Super", st["n_super"], m["s_pct"], m["s_mhz"]),
                               ("Perf",  st["n_perf"],  m["p_pct"], m["p_mhz"])):
        if n or pct:
            col = usage_color(pct)
            rows.append(f"  {label:<6}({n:>2}c) {col}{pct:5.1f}%{NC} @ {C}{mhz:4d} MHz{NC}  " + bar(pct, bw, col))
    rows.append(f"  Overall {C}{m['cpu_pct']:5.1f}%{NC}  {spark(TRK['cpu'].h, 0, 100)}  {stat(TRK['cpu'], '%')}")
    rows.append(f"  Temp    Die {tfmt(m['cpu_die_t'])}  P-core {tfmt(m['pcpu_t'])} (max {tfmt(m['pcpu_max'])})"
                f"  S-core {tfmt(m['scpu_t'], 70, 85)}  {DIM}peak die {TRK['cpu_t'].peak:.1f}°C{NC}")
    rows.append("")

    # GPU
    gc = f"{st['gpu_cores']}-core " if st["gpu_cores"] else ""
    rows.append(f"{W}GPU  Apple {gc}· Metal (llama.cpp / mlx / Ollama){NC}")
    rows.append(f"  Usage   {G}{m['gpu_pct']:5.1f}%{NC} @ {C}{m['gpu_mhz']:4d} MHz{NC}  " + bar(m["gpu_pct"], bw, G))
    rows.append(f"  History {spark(TRK['gpu'].h, 0, 100)}  {stat(TRK['gpu'], '%')}")
    rows.append(f"  Temp    {tfmt(m['gpu_t'], GPU_TEMP_WARN, GPU_TEMP_CRIT)} {DIM}(peak {TRK['gpu_t'].peak:.1f}°C){NC}"
                f"   Power {C}{m['gpu_w']:.2f} W{NC} {DIM}(peak {TRK['gpu_w'].peak:.1f} W){NC}")
    rows.append("")

    # ANE
    rows.append(f"{W}ANE  Apple Neural Engine (Core ML){NC}")
    rows.append(f"  Active  {C}{m['ane_pct']:5.1f}%{NC}  Power {C}{m['ane_w']:.2f} W{NC}  " + bar(m["ane_pct"], bw, C))
    rows.append("")

    # Power
    rows.append(f"{W}Power{NC}")
    rows.append(f"  CPU {C}{m['cpu_w']:.2f} W{NC}  GPU {C}{m['gpu_w']:.2f} W{NC}  ANE {C}{m['ane_w']:.2f} W{NC}"
                f"  DRAM {C}{m['dram_w']:.2f} W{NC}")
    rows.append(f"  System {C}{m['sys_w']:.1f} W{NC}  Total {C}{m['tot_w']:.1f} W{NC}"
                f"  {spark(TRK['pkg_w'].h, 0, None, 24)}  {stat(TRK['pkg_w'], ' W', 1)}")
    rows.append("")

    # Memory bandwidth
    rows.append(f"{W}Unified Memory Bandwidth  {DIM}(LLM token generation is bandwidth-bound){NC}")
    rows.append(f"  Read {C}{m['dram_read']:6.1f}{NC}  Write {C}{m['dram_write']:6.1f}{NC}"
                f"  Combined {C}{m['dram_bw']:6.1f} GB/s{NC}")
    rows.append(f"  History {spark(TRK['bw'].h, 0, None)}  {stat(TRK['bw'], ' GB/s', 1)}")
    rows.append("")

    # Thermals
    tcol = {"Nominal": G, "Fair": Y, "Serious": R, "Critical": R}.get(m["thermal_state"], C)
    lim = m["speed_limit"]
    lcol = G if lim >= 100 else (Y if lim >= 80 else R)
    rows.append(f"{W}Thermals{NC}  State {tcol}{m['thermal_state']}{NC}  CPU speed limit {lcol}{lim}%{NC}")
    rows.append(f"  Mem {tfmt(m['mem_t'], 60, 75)}  SoC {C}{m['soc_t']:.1f}°C{NC}"
                f"  SSD {C}{m['ssd_t']:.1f}°C{NC}  NAND {C}{m['nand_t']:.1f}°C{NC}")
    if m["fans"]:
        parts = []
        for f in m["fans"]:
            pct = f" ({f['rpm'] / f['max'] * 100:.0f}%)" if f["max"] else ""
            parts.append(f"Fan{f['id']} {C}{f['rpm']} rpm{NC}{pct}")
        rows.append("  " + "   ".join(parts))
    return box(B, f"SoC — {st['chip']}", rows)

def display_memory(m, st):
    bw = max(10, min(40, WIDTH - 50))
    vm = m["vm"]
    mc, sc = usage_color(m["ram_pct"]), usage_color(m["swap_pct"])
    pc = {"Normal": G, "Warning": Y, "Critical": R}.get(m["pressure"], G)
    rows = [
        f"  RAM Used  {mc}{m['ram_used_gb']:5.1f} GB{NC} / {m['ram_total_gb']:.1f} GB  " + bar(m["ram_pct"], bw, mc),
        f"  History   {spark(TRK['ram'].h, 0, 100)}  {stat(TRK['ram'], '%')}",
        f"  Pressure  {pc}{m['pressure']}{NC} ({pc}{m['pressure_pct']:.0f}%{NC})"
        f"   Compressed {C}{m['comp_gb']:.2f} GB{NC}",
        f"  Swap      {sc}{m['swap_used_gb']:5.1f} GB{NC} / {m['swap_total_gb']:.1f} GB  " + bar(m["swap_pct"], bw, sc)
        + f"  {DIM}Δ {m['swap_delta_gb']:+.1f} GB{NC}",
    ]
    if vm:
        rows.append(f"  Breakdown {M}Wired {vm['wired']:.1f}{NC}  Active {vm['active']:.1f}  Inactive {vm['inactive']:.1f}"
                    f"  Cache {vm['cache']:.1f}  Free {vm['free']:.1f} {DIM}(GB){NC}")
        wl = m["wired_limit_mb"]
        wl_txt = "default (macOS auto)" if not wl else f"{wl / 1024:.1f} GB"
        rows.append(f"  GPU wired {M}{vm['wired']:.1f} GB{NC} in use  limit: {C}{wl_txt}{NC}"
                    f"  {DIM}(sudo sysctl iogpu.wired_limit_mb=N to raise){NC}")
    return box(G, f"Memory  (Unified — {m['ram_total_gb']:.0f} GB)", rows)

def display_storage(m):
    bw = 20
    dc = usage_color(m["disk_pct"])
    free = max(0.0, m["disk_total"] - m["disk_used"])
    smart_col = G if m["smart"].lower().startswith("verified") else Y
    rows = [
        f"  Disk  {m['disk_name']:<10.10} {dc}{m['disk_used']:7.1f} GB{NC} / {m['disk_total']:.0f} GB  " + bar(m["disk_pct"], bw, dc),
        f"  SSD   Temp {C}{m['ssd_t']:.1f}°C{NC}  NAND {C}{m['nand_t']:.1f}°C{NC}"
        f"  SMART {smart_col}{m['smart']}{NC}  Free {C}{free:.0f} GB{NC}",
        f"  I/O   {G}R {m['disk_r_mbs']:7.2f} MB/s{NC} {DIM}(peak {TRK['disk_r'].peak:.0f}){NC}"
        f"   {Y}W {m['disk_w_mbs']:7.2f} MB/s{NC} {DIM}(peak {TRK['disk_w'].peak:.0f}){NC}",
        f"  Net   {G}↓ {m['net_in_mbs']:7.3f} MB/s{NC}   {Y}↑ {m['net_out_mbs']:7.3f} MB/s{NC}",
    ]
    return box(Y, "Storage & Network", rows)

def display_battery(m):
    bx = m["bx"]
    pct, adapter = m["batt_pct"], m["adapter_w"]
    if m["charging"]:
        bc, state = C, "Charging"
    elif adapter > 0:
        bc, state = G, "On AC (not charging)"
    else:
        bc = R if pct < 20 else (Y if pct < 40 else G)
        state = "Discharging"
    watts = abs(m["batt_w"])
    rem = ""
    if bx.get("time_rem") and not m["charging"] and adapter <= 0:
        rem = f"  ~{bx['time_rem'] // 60}h {bx['time_rem'] % 60:02d}m left"
    rows = [
        f"  Charge  {bc}{pct:3d}%{NC}  {state}{rem}  " + bar(pct, 24, bc),
        f"  Power   {C}{watts:.1f} W{NC} {'in' if m['charging'] else 'draw'}   Adapter {C}{adapter:.0f} W{NC}",
    ]
    if bx:
        hcol = G if bx["health"] >= 85 else (Y if bx["health"] >= 75 else R)
        mah = f" ({bx['cur_mah']}/{bx['des_mah']} mAh)" if bx["cur_mah"] and bx["des_mah"] else ""
        rows.append(f"  Health  {hcol}{bx['health']:.0f}%{NC}{mah}  Cycles {C}{bx['cycles']}{NC}"
                    f"  Temp {C}{bx['temp']:.1f}°C{NC}")
    return box(M, "Battery & Power", rows)

def display_llm(m):
    rows = []
    g = m["gpu_pct"]
    if g < 5:
        act = f"{DIM}● idle{NC}"
    elif g < 40:
        act = f"{Y}● light{NC}"
    else:
        act = f"{G}● HEAVY — inference likely active{NC}"
    rows.append(f"{W}Activity{NC}  {act}  {DIM}(GPU {g:.0f}% · {m['dram_bw']:.0f} GB/s){NC}")
    rows.append("")

    rows.append(f"{W}Ollama{NC}  {DIM}(loaded models){NC}")
    mods = m["ollama"]
    if mods is None:
        rows.append(f"  {DIM}server not reachable{NC}")
    elif not mods:
        rows.append(f"  {DIM}no models loaded{NC}")
    else:
        for mo in mods:
            size, vram = fnum(mo.get("size")), fnum(mo.get("size_vram"))
            pct = vram / size * 100 if size else 0
            col = G if pct >= 98 else (Y if pct >= 50 else R)
            det = mo.get("details") or {}
            rows.append(f"  {G}●{NC} {W}{mo.get('name', '?')}{NC}  {det.get('parameter_size', '')} "
                        f"{det.get('quantization_level', '')}".rstrip())
            u = until_str(mo.get("expires_at"))
            rows.append(f"      {size / 1024 ** 3:.1f} GB  {col}{pct:.0f}% GPU{NC}"
                        f"  ctx {mo.get('context_length') or '?'}  "
                        + ("stays loaded" if u == "pinned" else f"unloads in {u}"))
    if m["llm_procs"]:
        rows.append("")
        rows.append(f"{W}LLM runtimes detected{NC}")
        for name, (cpu, rss, n) in m["llm_procs"]:
            rows.append(f"  {G}●{NC} {name:<22.22} {usage_color(cpu)}{cpu:6.1f}%{NC} cpu  {rss:7.0f} MB rss  "
                        f"{DIM}{n} proc{'s' if n > 1 else ''}{NC}")

    procs = sorted(m["procs"],
                   key=lambda p: max(fnum(p.get("cpu_percent")), fnum(p.get("gpu_ms_per_sec")) / 10),
                   reverse=True)[:6]
    rows.append("")
    rows.append(f"{W}Top Processes{NC}  {DIM}(by CPU / GPU load){NC}")
    for p in procs:
        cpu, mem = fnum(p.get("cpu_percent")), fnum(p.get("memory_percent"))
        gpu_ms, rss = fnum(p.get("gpu_ms_per_sec")), fnum(p.get("rss_kb")) / 1024
        rows.append(f"  {(p.get('command') or '?'):<22.22} {usage_color(cpu)}{cpu:5.1f}%{NC} cpu"
                    f"  {mem:4.1f}% mem  {C}{gpu_ms:5.0f}ms/s{NC} gpu  {rss:5.0f}MB rss")
    return box(C, "LLM Inference & Processes", rows)

def display_footer(args, live):
    csv_txt = f"  ·  CSV: {args.csv}" if args.csv else ""
    return box(DIM, "", [f"Refresh {args.interval:g}s  ·  Log: {LOG_FILE.name}{csv_txt}  ·  Ctrl+C to stop"])

def compact_line(m, st):
    mods = f"  LLM: {m['ollama_models']}" if m["ollama_models"] else ""
    return (f"{W}{st['chip']}:{NC} "
            f"CPU {m['cpu_pct']:.0f}%/{tfmt(m['cpu_die_t'])}  "
            f"GPU {m['gpu_pct']:.0f}%/{tfmt(m['gpu_t'], GPU_TEMP_WARN, GPU_TEMP_CRIT)}  "
            f"Pwr {C}{m['tot_w']:.0f}W{NC}  BW {C}{m['dram_bw']:.0f}GB/s{NC}  "
            f"RAM {usage_color(m['ram_pct'])}{m['ram_pct']:.0f}%{NC}  "
            f"Swap {usage_color(m['swap_pct'])}{m['swap_used_gb']:.1f}G{NC}  "
            f"Disk {usage_color(m['disk_pct'])}{m['disk_pct']:.0f}%{NC}  "
            f"Batt {C}{m['batt_pct']}%{NC}  {m['thermal_state']}{mods}")

# ── CSV recording ──────────────────────────────────────────────────────────────
CSV_FIELDS = ["cpu_pct", "s_pct", "p_pct", "gpu_pct", "gpu_mhz", "ane_pct", "cpu_w", "gpu_w",
              "ane_w", "dram_w", "sys_w", "tot_w", "dram_read", "dram_write", "dram_bw",
              "cpu_die_t", "gpu_t", "ram_used_gb", "swap_used_gb", "pressure",
              "disk_r_mbs", "disk_w_mbs", "net_in_mbs", "net_out_mbs", "fan0", "fan1",
              "speed_limit", "batt_pct", "ollama_models"]

def write_csv(path, m):
    new = not Path(path).exists()
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["timestamp"] + CSV_FIELDS)
        w.writerow([datetime.now().isoformat(timespec="seconds")] +
                   [round(m[k], 3) if isinstance(m.get(k), float) else m.get(k, "") for k in CSV_FIELDS])

# ── Main ───────────────────────────────────────────────────────────────────────
def clear_screen():
    sys.stdout.write("\033[H\033[2J\033[3J\033]1337;ClearScrollback\a")
    sys.stdout.flush()
    try:
        os.system("clear")
    except Exception:
        pass
    sys.stdout.flush()

def paint(lines, live):
    if live:
        clear_screen()
        sys.stdout.write("\033[H" + "".join(l + "\033[K\n" for l in lines) + "\033[J")
    else:
        sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()

def main():
    parser = argparse.ArgumentParser(description="macOS System Monitor — Apple Silicon / LLM inference")
    parser.add_argument("-o", "--once", "--oneshot", action="store_true", help="Display once and exit")
    parser.add_argument("-c", "--compact", action="store_true", help="One-line summary and exit")
    parser.add_argument("-i", "--interval", type=float, default=CHECK_INTERVAL, help="Refresh seconds")
    parser.add_argument("--csv", metavar="FILE", help="Append every sample to a CSV file")
    args = parser.parse_args()

    check_deps()
    st = get_static()
    live = not (args.once or args.compact)

    def _stop(sig, frame):
        if live:
            sys.stdout.write("\033[?25h")
        print(f"\n{C}Monitor stopped.{NC}")
        log("macOS monitor stopped")
        sys.exit(0)
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    log("macOS monitor started")
    if live:
        sys.stdout.write("\033[?25l\033[2J")

    while True:
        t0 = time.time()
        set_width()
        d = fetch_metrics()
        if not d:
            if not live:
                print(f"{R}Failed to get metrics from mactop.{NC}", file=sys.stderr)
                sys.exit(1)
            paint([f"{R}Failed to get metrics from mactop — retrying…{NC}"], True)
            time.sleep(args.interval)
            continue

        m = collect(d, st)
        warns = get_warnings(m, st)
        for key, msg in warns:
            log_alert(key, msg)
        if args.csv:
            write_csv(args.csv, m)

        if args.compact:
            print(compact_line(m, st))
            return

        frame = (display_header(m, st) + display_warnings(warns) + display_soc(m, st)
                 + display_memory(m, st) + display_storage(m) + display_battery(m)
                 + display_llm(m))
        if live:
            frame += display_footer(args, live)
        paint(frame, live)
        if not live:
            return
        time.sleep(max(0.2, args.interval - (time.time() - t0)))

if __name__ == "__main__":
    main()