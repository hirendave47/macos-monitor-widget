# System Rings — macOS Desktop Widget

A lightweight macOS menu-bar app that places a **frosted-glass desktop widget** on your wallpaper with live **circular utilization gauges**, purpose-built sub-charts, structured telemetry pills, interactive detail drawers, warning banners, multiple layouts/themes, and a live menu-bar readout.

| Ring | Source | Sub-Chart | Detail Line | Interactive Drawer |
|------|--------|-----------|-------------|--------------------|
| **CPU** | Mach tick counters (`host_processor_info`) + `sysctl` | Smooth cubic Bezier sparkline | P-cluster GHz · 1m load avg | Load 1/5/15m · P & E/S cluster MHz · CPU power · Top 4 CPU processes |
| **Memory** | `host_statistics64` + `vm.swapusage` + VM pressure | Smooth cubic Bezier sparkline | Used / Total GB | Wired · Active · Compressed · Free/Cache · Swap used/total GB |
| **GPU** | `mactop --headless --count 2 --format json` | Smooth cubic Bezier sparkline | GPU clock (MHz) | Clock · GPU power (W) · DRAM R/W bandwidth (GB/s) · ANE % & W |
| **Disk** | `statfs("/")` + `mactop` disk I/O | Capacity bar + live R/W pulse dots | Free GB | Used / Free / Capacity GB · Live Read/Write MB/s · SSD temp |
| **Battery** | IOKit `IOPS` + cached `ioreg` `AppleSmartBattery` | 5-cell segmented charge bar | Watts · Time left · AC state | Health % · mAh (cur/design) · Cycles · Power/Adapter W · Temp °C |

## What's New

### 1. Visual Polish & Layout Modes
- **Clean 12-o'clock Ring Arcs**: Rings start cleanly at 12 o'clock (`-90°`) with smooth linear gradients, subtle inner hairline tracks, and in-ring secondary micro-badges (e.g., CPU/GPU core temps, memory pressure/swap, free disk space, and AC status)—eliminating the two-tone stroke cap seam on low percentages.
- **No Truncated Subtitles**: Widened ring cards (`108px` base width) with adaptive font scaling and concise `1.6 GHz · L 1.6` formatting so subtitles never clip with `...`.
- **Purpose-Built Sub-Charts**:
  - **CPU, Memory & GPU**: Smooth cubic Bezier area sparklines with a baseline track and a live current-value dot.
  - **Disk**: Segmented storage capacity bar with live Read (`R`) and Write (`W`) activity indicator dots.
  - **Battery**: 5-cell segmented battery bar reflecting charge level and charging state.
- **Structured Telemetry Pills**: Bottom board metrics (Power `W`, DRAM Bandwidth `GB/s`, CPU/GPU Temps, ANE %, Network `↓/↑ MB/s`, Disk `R/W MB/s`, Swap `GB`, Battery Health/Cycles, Fan `rpm`, and Uptime) are rendered as frosted capsule pills with severity-tinted icons.
- **Three Layout Orientations**:
  - **Horizontal Strip (1×5)**: Classic wide desktop bar.
  - **Compact Grid (3×2)**: 3 rings on top + 2 below, ideal for screen corners.
  - **Vertical Sidebar**: Compact vertical stack with inline sparklines for docking along the left or right screen edge.
- **Five Color Themes**:
  - **Adaptive Status** (Green / Yellow ≥75% / Red ≥90% / Teal charging)
  - **Emerald Matrix**
  - **Cyber Cyan**
  - **Sunset Amber**
  - **Monochrome Glass**

### 2. Interactivity & Quick-Action Header Bar
- **Click to Expand Detail Drawer**: Click any ring (or any corresponding bottom telemetry pill) to open an inline detail drawer showing deep metrics (top CPU processes, Wired/Active/Compressed/Swap memory breakdown, DRAM Read/Write bandwidth, Disk I/O, or Battery mAh/cycles/watts). Click the ring again or `×` to close.
- **Double-Click for Activity Monitor**: Double-click any ring (or click the link inside the detail drawer) to launch macOS **Activity Monitor**.
- **On-Widget Quick-Action Header**: Shows your Apple Silicon chip name and status dot on the left, with one-click buttons on the right to cycle **Layout**, **Color Theme**, **Compact Mode**, **Copy Snapshot** (with green checkmark confirmation), and **Activity Monitor**. Can be toggled on/off from the menu.

### 3. Warnings & Live Menu Bar Readout
- **Live Warning Banner**: Automatically displays a high-visibility amber or red banner on the widget when thermal throttling (`Serious`/`Critical`), high CPU/GPU temperatures (≥85°C), memory pressure (`Warning`/`Critical`), swap growth (+1.0 GB since launch), low disk space (≥88%), or low battery (≤20% discharging) occurs.
- **Optional macOS Alert Notifications**: Enable **Warnings & Alerts → Send macOS Alert Notifications** in the menu to receive native desktop notifications (with a 5-minute cooldown per alert type).
- **Menu Bar Live Readout**: Choose what appears next to the menu-bar gauge icon under **Menu Bar Readout**:
  - *Icon Only*
  - *CPU & GPU %* (default, e.g. `12% · 9%`)
  - *CPU · RAM · GPU %*
  - *Power (W) & Temp (°C)*

## Build & Run

```bash
cd SystemRings
./build.sh
./run.sh restart
```

## Controls (`run.sh`)

```bash
./run.sh start     # launch the widget (builds first if no app bundle exists)
./run.sh stop      # stop/kill the widget (SIGTERM, then SIGKILL after ~3 s)
./run.sh restart   # stop, then start
./run.sh status    # print running/not-running with the pid
./run.sh build     # rebuild the app bundle only
```

## Preferences

Stored in `defaults` domain `com.hiren.systemrings`:
- `layoutMode` (`horizontal` | `grid` | `vertical`)
- `theme` (`adaptive` | `emerald` | `cyber` | `sunset` | `monochrome`)
- `menuBarReadout` (`iconOnly` | `cpuGpu` | `cpuRamGpu` | `powerTemp`)
- `showHeaderBar` (`true` | `false`)
- `alertsEnabled` (`true` | `false`)
- `desktopNotifications` (`true` | `false`)
- `floatOnTop`, `opacity`, `interval`, `compact`, `scale`, `widgetX`, `widgetY`
