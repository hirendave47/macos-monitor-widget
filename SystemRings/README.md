# System Rings — macOS Desktop Widget

A tiny macOS menu-bar app that places a **frosted-glass desktop widget** on your
wallpaper with live **circular (ring-style) utilization gauges** for:

| Ring | Source | Detail line |
|------|--------|-------------|
| CPU | mach tick counters (`host_processor_info`) | load avg · P-cluster GHz |
| Memory | `host_statistics64` (active + wired + compressed) | used / total GB |
| GPU | `mactop --headless --count 2 --format json` | GPU clock (MHz) |
| Disk | `statfs("/")` | free GB |
| Battery | IOKit power sources + cached `ioreg` | watts · time left · health |

Ring color thresholds mirror `macos_monitor.py` (`usage_color`):
**≥ 90 % red · ≥ 70 % yellow · green** otherwise. Battery turns **teal while
charging**, red < 20 %, yellow < 40 %.

```
  frosted-glass panel (vibrancy over your wallpaper)
  ⌀84px gradient rings w/ soft glow + 56-sample sparklines under each:

        ____          ____          ____          ____         ____
       /    \        /    \        /    \        /    \       /    \
      |  34% |      |  61% |      |  12% |      |  78% |     | 100% |
       \____/        \____/        \____/        \____/       \____/
        CPU          Memory         GPU           Disk         Battery
      3.4GHz        25/48 GB       812 MHz      free 190 GB    on AC
     load 3.2   ▁▂▃▄▄▆▆▅▃▂▁     ▁▁▂▇█▇▄▂▁▁   ▁▂▃▄▅▅▆▆▇█     ▁▃▅▇████

   ⚡ 38.4 W  ·  🧭 41.3 GB/s  ·  🌡 54°/49°
   🌐 ↓2.1 ↑0.3 MB/s  ·  💾 R 1.7 W 0.1 MB/s
   🔋 100% · h96% · 12 cyc  ·  1521/1478 rpm  ·  ⏱ 3d 4h
```

This is a true *desktop* widget (a panel pinned between the wallpaper and your
windows), **not** a Notification Center WidgetKit widget — deliberately, because
WidgetKit widgets are throttled and cannot show live GPU utilization. This one
refreshes every 1–5 s.

## Features

- **Five live rings** (CPU / Memory / GPU / Disk / Battery) with animated
  gradient strokes and soft glow; battery ring hides automatically on desktops
  without a battery.
- **Sparkline history** (last ~56 samples ≈ 2 min) under each ring.
- **Stats strip** powered by the mactop JSON we already fetch:
  package power (W) · DRAM bandwidth (GB/s) · CPU/GPU temps ·
  network down/up (MB/s) · disk read/write (MB/s) · fans (rpm) · uptime ·
  battery health + cycles.
- **Real frosted glass** (`NSVisualEffectView` .hudWindow vibrancy) so it looks
  right over any wallpaper.
- **Compact Mode** — rings + labels only (strips sparklines and the stats strip).
- **Hide / Show Widget** without quitting samplers (graphs stay warm).
- **Float on Top** ↔ **Pin to Desktop** — floating rides above everything;
  pinning (default) sits above the wallpaper *and the desktop icons* but below
  every app window. Sitting above the icon layer is what keeps the widget
  clickable and draggable on the bare desktop.
- The widget **never renders partially offscreen**: on launch/resizes it
  re-docks to the bottom-right of the main display whenever the panel would
  not fully fit at its saved position (also fixes older saves that were
  pushed half-way off the screen).
- **Widget Size** — Small 80 % / Medium 100 % / Large 120 % / XL 140 %;
  rings, fonts, sparklines and the stats strip all scale together. (Stored as
  the `scale` key in `defaults`.)
- **Copy Snapshot** — puts a plain-text stats block on the clipboard, handy for
  ticket notes or pairing with `macos_monitor.py --compact`.
- Menu-bar gauge icon is the control hub; the same menu opens on right-click.
- "Launch at Login" registers a real login item via `SMAppService`.
- Drag anywhere to move; position, opacity, interval, compact mode persist.

## Requirements

- macOS 13+ (uses `SMAppService` for "Launch at Login")
- Xcode Command Line Tools: `xcode-select --install`
- `mactop` for GPU + power/thermal/network enrichment: `brew install mactop`
  (same dependency as `macos_monitor.py`; without it the GPU ring shows `– / no mactop`
  and the stats strip shows fewer rows — CPU/RAM/Disk/Battery keep working natively)
- Apple Silicon for GPU metrics (M1/M2/M3/M4/M5…); battery ring needs a laptop.

## Build & run

```bash
cd SystemRings
./build.sh
open build/SystemRings.app
```

The widget appears in the **bottom-right corner** of the main display.

## Start / stop / restart (`run.sh`)

```bash
./run.sh start     # launch the widget (builds first if no app bundle exists)
./run.sh stop      # stop/kill the widget (SIGTERM, then SIGKILL after ~3 s)
./run.sh restart   # stop, then start
./run.sh status    # print running/not-running with the pid
./run.sh build     # rebuild the app bundle only
./run.sh help
```

Notes:
- `start` when *already running* simply points at the running pid (no double launch).
- `stop` first tries a graceful `SIGTERM` and escalates to `SIGKILL` if needed.
- If **Launch at Login** is enabled, the widget comes back at the next login —
  toggle that off in the widget's menu first if you want it gone for good.

## Using the widget

- **Move it:** left-click-drag anywhere on the panel.
- **Controls:** right-click the widget or click the menu-bar gauge icon:
  - *Pin to Desktop* / *Float on Top*
  - *Opacity* — 100 / 80 / 60 / 40 %
  - *Refresh Rate* — 1 s, 2 s (default), 5 s
  - *Widget Size* — 80 / 100 / 120 / 140 %
  - *Reset Position*
  - *Hide Widget* / *Show Widget*
  - *Compact Mode*
  - *Copy Snapshot*
  - *Launch at Login*
  - *Quit System Rings*
- Preferences live in `defaults` domain `com.hiren.systemrings`
  (`floatOnTop`, `opacity`, `interval`, `compact`, `widgetX`, `widgetY`).

## First run notes

- The app is stamped `LSUIElement`: it lives only in the menu bar + on your
  desktop (no Dock icon).
- The first CPU sample needs two timer ticks to compute deltas, so the CPU ring
  fills ~2 s after launch.
- The GPU ring spawns a short-lived `mactop` process every refresh (exactly how
  `macos_monitor.py` fetches metrics); CPU/RAM/Disk/Battery are sampled natively
  with no extra child processes. Battery health/cycles come from a cached
  `ioreg` read (refreshed every 60 s).

## Troubleshooting

- **Ring values look wrong / ordering weird?** Run the binary manually with
  diagnostics on to see every sample on stderr:

  ```bash
  SYSTEMRINGS_DEBUG=1 build/SystemRings.app/Contents/MacOS/SystemRings
  ```

  It logs each tick (`cpu/mem/gpu/disk/batt` readings) and every window resize
  (fitting size, scale, item count).

- Widget fell somewhere you don't like? *Reset Position* re-docks it
  bottom-right of the main display.
- GPU ring shows `–`? `brew install mactop`, then wait for the next refresh
  (GPU detail line will read the clock, e.g. `812 MHz`).

## Reset preferences / uninstall

```bash
pkill SystemRings
rm -rf ~/Applications/SystemRings.app  # or wherever you keep it
defaults delete com.hiren.systemrings
rm -rf SystemRings/build
```

("Launch at Login" will be removed if you toggle it off before deleting the app,
or can be removed manually in System Settings → General → Login Items.)

## Relationship to `macos_monitor.py`

| | `macos_monitor.py` | System Rings |
|---|---|---|
| UI | Full-screen terminal dashboard | Persistent desktop rings + stats strip |
| GPU data | `mactop --headless` | same command, parsed natively |
| CPU/RAM/Disk | mactop JSON | native system calls (no subprocess) |
| Battery | `ioreg` AppleSmartBattery | IOKit IOPS + same `ioreg` health logic |
| Thresholds | 70 % / 90 % | same |

Both are self-contained and can run side by side.
