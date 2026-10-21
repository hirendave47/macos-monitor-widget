//
//  main.swift
//  System Rings
//
//  A macOS *desktop widget* — a frosted-glass panel pinned to the desktop
//  (above the wallpaper, behind normal windows) with live gauges for
//  CPU, Memory, GPU, Disk and Battery, plus mini sparklines and a stats
//  strip (power, temps, network, disk I/O, fans, uptime).
//
//  Companion to macos_monitor.py — shares the same mactop dependency for
//  Apple Silicon GPU/battery/power metrics, same ring thresholds
//  (>=70% yellow, >=90% red).
//
//  Data sources:
//    CPU     mach tick counters (host_processor_info)
//    RAM     host_statistics64 (active + wired + compressor pages)
//    GPU     `mactop --headless --count 2 --format json`
//    Disk    statfs("/")
//    Battery IOKit power sources (IOPS) + cached `ioreg` health details
//

import AppKit
import SwiftUI
import Darwin
import Foundation
import IOKit.ps
import ServiceManagement

// MARK: - Optional stderr debug logging (SYSTEMRINGS_DEBUG=1)

private let debugEnabled = ProcessInfo.processInfo.environment["SYSTEMRINGS_DEBUG"] == "1"
private func dbg(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    NSLog("[SystemRings] %@", message())
}

// MARK: - Preferences

private enum Prefs {
    static var floatOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "floatOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "floatOnTop") }
    }
    static var opacity: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "opacity")
            return v > 0.05 ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "opacity") }
    }
    static var interval: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "interval")
            return v >= 0.5 ? v : 2.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "interval") }
    }
    static var compact: Bool {
        get { UserDefaults.standard.bool(forKey: "compact") }
        set { UserDefaults.standard.set(newValue, forKey: "compact") }
    }
    static var scale: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "scale")
            return v >= 0.5 && v <= 2.0 ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "scale") }
    }
    static var widgetOrigin: NSPoint? {
        get {
            guard UserDefaults.standard.object(forKey: "widgetX") != nil else { return nil }
            return NSPoint(x: UserDefaults.standard.double(forKey: "widgetX"),
                           y: UserDefaults.standard.double(forKey: "widgetY"))
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(Double(v.x), forKey: "widgetX")
                UserDefaults.standard.set(Double(v.y), forKey: "widgetY")
            } else {
                UserDefaults.standard.removeObject(forKey: "widgetX")
                UserDefaults.standard.removeObject(forKey: "widgetY")
            }
        }
    }
}

// MARK: - Models

struct GaugeItem: Identifiable {
    let id: String
    let label: String
    var value: Double?                    // 0...100, nil = unavailable
    var detail: String
    var history: [Double] = []
    var icon: String = ""
    var colorOverride: Color? = nil       // e.g. teal while charging
}

struct BoardPart: Identifiable {
    let symbol: String
    let text: String
    var id: String { symbol + text }
}

struct BoardRow: Identifiable {
    let parts: [BoardPart]
    var id: String { parts.map(\.id).joined(separator: "|") }
}

/// Everything we enrich from the mactop JSON we are already fetching for GPU.
struct BoardStats {
    var isAvailable = false
    var totalPower: Double?
    var sysPower: Double?
    var dramBW: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var netDown: Double?     // MB/s
    var netUp: Double?       // MB/s
    var diskRead: Double?    // MB/s
    var diskWrite: Double?   // MB/s
    var fans: [Int] = []
    var battW: Double?
    var adapterW: Double?
    var pMHz: Int?

    static let empty = BoardStats()
}

struct BatteryInfo {
    var present = false
    var pct: Int?
    var charging = false
    var onAC = false
    var timeLeftSec: Int?
    var healthPct: Double?
    var cycles: Int?
    var tempC: Double?

    static let empty = BatteryInfo()
}

// MARK: - Colour helpers

private func usageColor(_ pct: Double) -> Color {
    if pct >= 90 { return Color(nsColor: .systemRed) }
    if pct >= 70 { return Color(nsColor: .systemYellow) }
    return Color(nsColor: .systemGreen)
}

private func batteryColor(pct: Double, charging: Bool) -> Color {
    if charging { return Color(nsColor: .systemTeal) }
    if pct < 20 { return Color(nsColor: .systemRed) }
    if pct < 40 { return Color(nsColor: .systemYellow) }
    return Color(nsColor: .systemGreen)
}

private func num(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

private func fmtHM(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    if h > 0 { return String(format: "%dh%02dm", h, m) }
    return String(format: "%dm", m)
}

private func fmtUptime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    let d = s / 86400
    let h = (s % 86400) / 3600
    let m = (s % 3600) / 60
    if d > 0 { return String(format: "%dd %dh", d, h) }
    if h > 0 { return String(format: "%dh %dm", h, m) }
    return String(format: "%dm", m)
}

// MARK: - Native system samplers (no external dependencies)

enum SystemSampler {
    struct CPUReading {
        let pct: Double
        let load1: Double
    }

    /// Aggregate CPU utilization across all cores, from mach tick counters.
    /// Needs two calls to produce a delta; returns nil on the first call.
    static func cpuUsage(prev: inout (busy: Double, total: Double)?) -> CPUReading? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &cpuInfo, &cpuInfoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo, cpuCount > 0 else { return nil }
        defer {
            let size = vm_size_t(cpuCount) * vm_size_t(MemoryLayout<processor_cpu_load_info_data_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: UnsafeRawPointer(info))), size)
        }

        var busy = 0.0
        var total = 0.0
        for c in 0..<Int(cpuCount) {
            let base = c * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let sys  = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            busy  += user + sys + nice
            total += user + sys + nice + idle
        }

        guard let last = prev else {
            prev = (busy: busy, total: total)
            return nil
        }
        let dB = max(0, busy - last.busy)
        let dT = max(0, total - last.total)
        prev = (busy: busy, total: total)
        guard dT > 0 else { return nil }

        var la = [Double](repeating: 0, count: 1)
        var load1 = 0.0
        if getloadavg(&la, 1) == 1 { load1 = la[0] }
        return CPUReading(pct: dB / dT * 100, load1: load1)
    }

    /// RAM used = active + wired + compressor pages (Activity Monitor-style "used").
    static func memoryUsage() -> (pct: Double, usedGB: Double, totalGB: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                             / MemoryLayout<integer_t>.stride)
        var kr: kern_return_t = KERN_FAILURE
        withUnsafeMutableBytes(of: &stats) { raw in
            guard let base = raw.baseAddress else { return }
            kr = host_statistics64(mach_host_self(),
                                   HOST_VM_INFO64,
                                   base.assumingMemoryBound(to: integer_t.self),
                                   &count)
        }
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
        let usedBytes = (Double(stats.active_count)
                          + Double(stats.wire_count)
                          + Double(stats.compressor_page_count)) * pageSize
        let usedGB = usedBytes / 1024 / 1024 / 1024
        guard totalGB > 0 else { return nil }
        return (pct: usedGB / totalGB * 100, usedGB: usedGB, totalGB: totalGB)
    }

    /// Root volume capacity.
    static func diskUsage() -> (pct: Double, freeGB: Double, totalGB: Double)? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let bsize = Double(fs.f_bsize)
        let total = Double(fs.f_blocks) * bsize
        let avail = Double(fs.f_bavail) * bsize
        guard total > 0 else { return nil }
        let gb: (Double) -> Double = { $0 / 1024 / 1024 / 1024 }
        return (pct: (total - avail) / total * 100, freeGB: gb(avail), totalGB: gb(total))
    }
}

// MARK: - GPU + enrichment sampler (via mactop)

final class GPUSampler {

    private static let queue = DispatchQueue(label: "com.hiren.systemrings.gpu", qos: .utility)
    private var inFlight = false
    let mactopPath: String?

    init() {
        mactopPath = Self.findMactop()
    }

    static func findMactop() -> String? {
        let candidates = ["/opt/homebrew/bin/mactop",
                          "/opt/homebrew/opt/mactop/bin/mactop",
                          "/usr/local/bin/mactop"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = String(dir) + "/mactop"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    func refresh(_ done: @escaping (_ pct: Double?, _ detail: String, _ board: BoardStats) -> Void) {
        guard !inFlight else { return }
        guard let path = mactopPath else {
            DispatchQueue.main.async { done(nil, "no mactop", BoardStats.empty) }
            return
        }
        inFlight = true
        Self.queue.async { [weak self] in
            defer { self?.inFlight = false }
            let result = Self.runMactop(path)
            DispatchQueue.main.async { done(result.pct, result.detail, result.board) }
        }
    }

    private static func runMactop(_ path: String) -> (pct: Double?, detail: String, board: BoardStats) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--headless", "--count", "2", "--format", "json"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility

        do { try process.run() } catch { return (nil, "mactop error", BoardStats.empty) }

        let killer = DispatchWorkItem { [weak process] in
            if let p = process, p.isRunning { p.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: killer)

        let data = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        killer.cancel()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, "parse error", BoardStats.empty)
        }

        var samples: [[String: Any]] = []
        if let array = parsed as? [[String: Any]], !array.isEmpty {
            samples = array
        } else if let dict = parsed as? [String: Any] {
            samples = [dict]
        }
        guard let last = samples.last else { return (nil, "parse error", BoardStats.empty) }

        // ---- GPU ----
        var pct: Double?
        var gpuDetail = ""
        if let soc = last["soc_metrics"] as? [String: Any] {
            if let active = num(soc["gpu_active"]) {
                pct = active
            }
            let mhz = Int(num(soc["gpu_freq_mhz"]) ?? 0)
            gpuDetail = mhz > 0 ? String(format: "%d MHz", mhz) : "mactop"
        }
        if gpuDetail.isEmpty { gpuDetail = "no gpu metric" }

        // ---- Board enrichment ----
        var board = BoardStats()
        if let soc = last["soc_metrics"] as? [String: Any] {
            board.isAvailable = true
            board.totalPower = num(soc["total_power"])
            board.sysPower = num(soc["system_power"])
            board.dramBW = num(soc["dram_bw_combined_gbs"])
            board.pMHz = Int(num(soc["p_cluster_freq_mhz"]) ?? 0)

            var tempMap: [String: Double] = [:]
            if let temps = last["temperatures"] as? [[String: Any]] {
                for t in temps {
                    if let g = t["group"] as? String, let v = num(t["avg_celsius"]) {
                        tempMap[g] = v
                    }
                }
            }
            board.cpuTemp = tempMap["CPU Die"] ?? num(soc["cpu_temp"])
            board.gpuTemp = tempMap["GPU"] ?? num(soc["gpu_temp"])
        }

        if let nd = last["net_disk"] as? [String: Any] {
            board.netDown = num(nd["in_bytes_per_sec"]).map { $0 / 1024 / 1024 }
            board.netUp = num(nd["out_bytes_per_sec"]).map { $0 / 1024 / 1024 }
            board.diskRead = num(nd["read_kbytes_per_sec"]).map { $0 / 1024 }
            board.diskWrite = num(nd["write_kbytes_per_sec"]).map { $0 / 1024 }
        }

        if let fans = last["fans"] as? [[String: Any]] {
            board.fans = fans.compactMap { f in
                Int(num(f["rpm"]) ?? 0)
            }.filter { $0 > 0 }
        }

        if let bat = last["battery"] as? [String: Any] {
            board.battW = num(bat["power_watts"])
        }
        if let ps = last["power_supply"] as? [String: Any] {
            board.adapterW = num(ps["adapter_watts"])
        }

        if !board.isAvailable { gpuDetail = "no soc data" }
        return (pct, gpuDetail, board)
    }
}

// MARK: - Battery sampler (native IOPS + cached ioreg health details)

final class BatterySampler {

    private static let queue = DispatchQueue(label: "com.hiren.systemrings.batt", qos: .utility)
    private var inFlight = false
    private var ioregCache: [String: Any]?
    private var ioregFetched: TimeInterval = 0

    func refresh(_ done: @escaping (BatteryInfo) -> Void) {
        guard !inFlight else { return }
        inFlight = true
        Self.queue.async { [weak self] in
            guard let self = self else { return }
            defer { self.inFlight = false }

            var info = Self.iopsReading() ?? BatteryInfo.empty
            if !info.present {
                DispatchQueue.main.async { done(BatteryInfo.empty) }
                return
            }
            let details = self.ioregDetails()   // reads system info
            if let cycles = Self.intOf(details["CycleCount"]) { info.cycles = cycles }
            if let temp = Self.numOf(details["Temperature"]), temp > 0 { info.tempC = temp / 100 }
            let cur = Self.numOf(details["AppleRawMaxCapacity"]) ?? Self.numOf(details["MaxCapacity"]) ?? 0
            let design = Self.numOf(details["DesignCapacity"]) ?? 0
            if design > 500 && cur > 100 {
                info.healthPct = cur / design * 100
            } else if cur > 0 && cur <= 100 {
                info.healthPct = cur
            }
            DispatchQueue.main.async { done(info) }
        }
    }

    private func ioregDetails() -> [String: Any] {
        if let cached = ioregCache, Date.timeIntervalSinceReferenceDate - ioregFetched < 60 {
            return cached
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rn", "AppleSmartBattery", "-a"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ioregCache ?? [:] }
        let data = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let array = (try? PropertyListSerialization.propertyList(from: data,
                                                                    options: [],
                                                                    format: nil)) as? [[String: Any]],
           let first = array.first {
            ioregCache = first
            ioregFetched = Date.timeIntervalSinceReferenceDate
        }
        return ioregCache ?? [:]
    }

    private static func numOf(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
    private static func intOf(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    private static func iopsReading() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)
                    .map({ $0.takeUnretainedValue() as NSDictionary }) as? [String: Any] else {
                continue
            }
            guard (desc["Type"] as? String) == "InternalBattery" else { continue }

            var info = BatteryInfo()
            info.present = true
            // NOTE: the key really is "Current Capacity" (with a space) —
            // "CurrentCapacity" silently yields nil.
            info.pct = Int(num(desc["Current Capacity"]) ?? 0)
            info.charging = (desc["Is Charging"] as? Bool) ?? false
            info.onAC = (desc["Power Source State"] as? String) == "AC Power"

            let remaining = IOPSGetTimeRemainingEstimate()
            if remaining.isFinite && remaining >= 0 {
                info.timeLeftSec = Int(remaining)
            }
            return info
        }
        return nil
    }
}

/// Background battery reads run through the sampler's utility queue.

// MARK: - View model

final class Monitor: ObservableObject {
    @Published var items: [GaugeItem] = [
        GaugeItem(id: "cpu",  label: "CPU",    value: nil, detail: "starting…", icon: "cpu"),
        GaugeItem(id: "mem",  label: "Memory", value: nil, detail: "starting…", icon: "memorychip"),
        GaugeItem(id: "gpu",  label: "GPU",    value: nil, detail: "waiting…",  icon: "sparkles"),
        GaugeItem(id: "disk", label: "Disk",   value: nil, detail: "starting…", icon: "internaldrive"),
    ]
    @Published var rows: [BoardRow] = []
    @Published var compact: Bool = Prefs.compact
    @Published var scale: Double = Prefs.scale

    private var cpuPrev: (busy: Double, total: Double)?
    private var histories: [String: [Double]] = [:]
    private let gpuSampler = GPUSampler()
    private let batterySampler = BatterySampler()
    private var gpuPct: Double?
    private var gpuDetail = "waiting…"
    private var board = BoardStats.empty
    private var battery: BatteryInfo?
    private let historyLimit = 56

    func tick() {
        var out: [GaugeItem] = []
        // ── CPU ──
        if let cpu = SystemSampler.cpuUsage(prev: &cpuPrev) {
            let pct = cpu.pct.clamped()
            pushHistory("cpu", pct)
            var detail = String(format: "load %.1f", cpu.load1)
            if let mhz = board.pMHz, mhz > 0 {
                detail += String(format: " · %.1f GHz", Double(mhz) / 1000)
            }
            out.append(make("cpu", label: "CPU", value: pct, detail: detail, icon: "cpu"))
        } else if let old = items.first(where: { $0.id == "cpu" }) {
            out.append(old)
        }

        // ── Memory ──
        if let mem = SystemSampler.memoryUsage() {
            let pct = mem.pct.clamped()
            pushHistory("mem", pct)
            out.append(make("mem", label: "Memory", value: pct,
                            detail: String(format: "%.1f / %.0f GB", mem.usedGB, mem.totalGB),
                            icon: "memorychip"))
        } else if let old = items.first(where: { $0.id == "mem" }) {
            out.append(old)
        }

        // ── GPU (latest mactop sample) ──
        out.append(make("gpu", label: "GPU", value: gpuPct?.clamped(), detail: gpuDetail, icon: "sparkles"))

        // ── Disk ──
        if let disk = SystemSampler.diskUsage() {
            let pct = disk.pct.clamped()
            pushHistory("disk", pct)
            out.append(make("disk", label: "Disk", value: pct,
                            detail: String(format: "free %.0f GB", disk.freeGB),
                            icon: "internaldrive"))
        } else if let old = items.first(where: { $0.id == "disk" }) {
            out.append(old)
        }

        // ── Battery (appended only when present) ──
        if battery?.present == true {
            pushHistory("batt", batteryItem().value ?? 0)
            out.append(make("batt", label: "Battery",
                            value: batteryItem().value,
                            detail: batteryItem().detail,
                            icon: batteryItem().icon,
                            colorOverride: batteryItem().colorOverride))
        }

        items = out
        recomputeRows()
        dbg("tick: items=\(out.map { "\($0.id)=\(String(format: "%.0f", $0.value ?? -1))" }.joined(separator: " ")) rows=\(rows.count)")
        batterySampler.refresh { [weak self] info in
            dbg("battery: present=\(info.present) pct=\(info.pct.map(String.init) ?? "nil") charging=\(info.charging) onAC=\(info.onAC) health=\(info.healthPct.map { String(format: "%.0f", $0) } ?? "nil")")
            guard let self = self else { return }
            self.battery = info.present ? info : nil
            if let b = self.battery {
                self.pushHistory("batt", Double(b.pct ?? 0))
            }
            self.syncBatteryItem()
            self.recomputeRows()
        }
        gpuSampler.refresh { [weak self] pct, detail, stats in
            guard let self = self else { return }
            if stats.isAvailable { self.board = stats }
            self.gpuDetail = detail
            if let pct = pct {
                self.gpuPct = pct
                self.pushHistory("gpu", pct.clamped())
            }
            self.syncGPUItem()
            self.recomputeRows()
        }
    }

    /// Plain-text snapshot for clipboard ("Copy Snapshot" menu action).
    func snapshotText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["System Rings — " + formatter.string(from: Date())]
        for item in items {
            if let v = item.value {
                lines.append(String(format: "%@ %.0f%% — %@", item.label, v, item.detail))
            } else {
                lines.append("\(item.label) — \(item.detail)")
            }
        }
        if board.isAvailable {
            if let w = board.totalPower ?? board.sysPower {
                lines.append(String(format: "Power %.1f W", w))
            }
            if let bw = board.dramBW {
                lines.append(String(format: "DRAM %.1f GB/s", bw))
            }
            if let c = board.cpuTemp, let g = board.gpuTemp {
                lines.append(String(format: "Temps CPU %.1f°c / GPU %.1f°c", c, g))
            }
            if let d = board.netDown, let u = board.netUp {
                lines.append(String(format: "Network ↓%.1f ↑%.1f MB/s", d, u))
            }
            if let r = board.diskRead, let w = board.diskWrite {
                lines.append(String(format: "Disk I/O R %.1f / W %.1f MB/s", r, w))
            }
        }
        if !board.fans.isEmpty {
            lines.append("Fans " + board.fans.prefix(2).map(String.init).joined(separator: ", ") + " rpm")
        }
        lines.append("Uptime " + fmtUptime(ProcessInfo.processInfo.systemUptime))
        return lines.joined(separator: "\n")
    }

    // MARK: Internals

    private func make(_ id: String, label: String, value: Double?, detail: String,
                      icon: String, colorOverride: Color? = nil) -> GaugeItem {
        GaugeItem(id: id, label: label, value: value, detail: detail,
                  history: history(id), icon: icon, colorOverride: colorOverride)
    }

    private func pushHistory(_ id: String, _ value: Double) {
        var h = histories[id] ?? []
        h.append(value)
        if h.count > historyLimit {
            h.removeFirst(h.count - historyLimit)
        }
        histories[id] = h
    }

    private func history(_ id: String) -> [Double] {
        histories[id] ?? []
    }

    private func syncGPUItem() {
        if let i = items.firstIndex(where: { $0.id == "gpu" }) {
            items[i] = make("gpu", label: "GPU", value: gpuPct?.clamped(),
                            detail: gpuDetail, icon: "sparkles")
        }
    }

    private func syncBatteryItem() {
        guard battery?.present == true else { return }
        let item = batteryItem()
        if let i = items.firstIndex(where: { $0.id == "batt" }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    private func batteryItem() -> GaugeItem {
        guard let b = battery, b.present else {
            return GaugeItem(id: "batt", label: "Battery", value: nil, detail: "no battery",
                             icon: "battery.100")
        }
        let pct = Double(b.pct ?? 0)
        let icon = b.charging ? "bolt.fill"
            : (pct >= 60 ? "battery.100" : (pct >= 30 ? "battery.50" : "battery.25"))
        return GaugeItem(id: "batt", label: "Battery",
                         value: min(100, max(0, pct)),
                         detail: batteryDetail(b),
                         history: history("batt"),
                         icon: icon,
                         colorOverride: batteryColor(pct: pct, charging: b.charging))
    }

    private func batteryDetail(_ b: BatteryInfo) -> String {
        if b.charging {
            if let w = board.battW, w > 0.05 { return String(format: "+%.1f W", w) }
            if let adapter = board.adapterW, adapter > 0.05 { return String(format: "+%.0f W", adapter) }
            return "charging"
        }
        if b.onAC { return "on AC" }
        var parts: [String] = []
        if let w = board.battW, abs(w) > 0.05 {
            parts.append(String(format: "-%.1f W", abs(w)))
        }
        if let s = b.timeLeftSec, s > 0 { parts.append(fmtHM(s)) }
        if parts.isEmpty {
            if let h = b.healthPct {
                parts.append(String(format: "health %.0f%%", h))
            } else if let w = board.battW {
                parts.append(String(format: "%.1f W", abs(w)))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func recomputeRows() {
        var rows: [BoardRow] = []

        var r1: [BoardPart] = []
        if let w = board.totalPower ?? board.sysPower, w > 0.05 {
            r1.append(BoardPart(symbol: "bolt", text: String(format: "%.1f W", w)))
        }
        if let bw = board.dramBW, bw > 0.5 {
            r1.append(BoardPart(symbol: "speedometer", text: String(format: "%.1f GB/s", bw)))
        }
        if let ct = board.cpuTemp, let gt = board.gpuTemp, ct > 0 || gt > 0 {
            r1.append(BoardPart(symbol: "thermometer", text: String(format: "%.0f°/%.0f°", ct, gt)))
        }
        if !r1.isEmpty { rows.append(BoardRow(parts: r1)) }

        var r2: [BoardPart] = []
        if let d = board.netDown, let u = board.netUp, d > 0.0005 || u > 0.0005 {
            r2.append(BoardPart(symbol: "network",
                                text: String(format: "↓%.1f ↑%.1f MB/s", d, u)))
        }
        if let r = board.diskRead, let w = board.diskWrite, r > 0.0005 || w > 0.0005 {
            r2.append(BoardPart(symbol: "externaldrive",
                                text: String(format: "R %.1f W %.1f MB/s", r, w)))
        }
        if !r2.isEmpty { rows.append(BoardRow(parts: r2)) }

        var r3: [BoardPart] = []
        if let b = battery, b.present {
            var bits: [String] = []
            if let p = b.pct { bits.append("\(p)%") }
            if let h = b.healthPct { bits.append(String(format: "h%.0f%%", h)) }
            if let c = b.cycles { bits.append("\(c) cyc") }
            if !bits.isEmpty {
                r3.append(BoardPart(symbol: b.charging ? "bolt" : "battery.100",
                                    text: bits.joined(separator: " · ")))
            }
        }
        if !board.fans.isEmpty {
            let rpms = board.fans.prefix(2).map(String.init).joined(separator: "/")
            r3.append(BoardPart(symbol: "wind", text: rpms + " rpm"))
        }
        r3.append(BoardPart(symbol: "clock",
                            text: fmtUptime(ProcessInfo.processInfo.systemUptime)))
        if !r3.isEmpty { rows.append(BoardRow(parts: r3)) }

        self.rows = rows
    }
}

private extension Double {
    func clamped() -> Double { min(100, max(0, self)) }
}

// MARK: - Views

struct Sparkline: View {
    let data: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard data.count > 1 else { return }
            let step = size.width / CGFloat(data.count - 1)
            var line = Path()
            for (i, v) in data.enumerated() {
                let t = max(0, min(1, v / 100))
                let x = CGFloat(i) * step
                let y = size.height - CGFloat(t) * (size.height - 2) - 1
                if i == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.22)))
            context.stroke(line, with: .color(color.opacity(0.85)), lineWidth: 1.25)
        }
    }
}

struct RingGauge: View {
    let item: GaugeItem
    let compact: Bool
    let scale: CGFloat

    private var ringSize: CGFloat { 84 * scale }
    private var lineW: CGFloat { 11 * scale }
    /// Circle diameter chosen so the stroked outer edge stays inside the ring
    /// box (never clipped by panel corners), with a little glow breathing room.
    private var diameter: CGFloat { ringSize - lineW - 6 * scale }

    private var fraction: CGFloat {
        item.value.map { CGFloat($0.clamped() / 100) } ?? 0
    }
    private var ringColor: Color {
        item.colorOverride
            ?? (item.value.map(usageColor) ?? Color(nsColor: .disabledControlTextColor))
    }
    private var centerText: String {
        item.value.map { "\(Int($0.clamped().rounded()))%" } ?? "–"
    }

    var body: some View {
        VStack(spacing: 6 * scale) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .frame(width: diameter, height: diameter)
                Circle()
                    .trim(from: 0.2499, to: max(0.2501, 0.25 + fraction))
                    .stroke(
                        AngularGradient(colors: [ringColor.opacity(0.55), ringColor],
                                        center: .center,
                                        startAngle: .degrees(-90),
                                        endAngle: .degrees(-90 + 360.0 * Double(max(0.02, fraction)))),
                        style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: ringColor.opacity(0.4), radius: 3.5 * scale)
                Text(centerText)
                    .font(.system(size: 15.5 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(item.value == nil
                                     ? Color.white.opacity(0.45)
                                     : Color.white)
            }
            .frame(width: ringSize, height: ringSize)
            .animation(.easeOut(duration: 0.5), value: fraction)

            if !compact {
                Sparkline(data: item.history, color: ringColor)
                    .frame(width: 84 * scale, height: 14 * scale)
            }

            VStack(spacing: 3 * scale) {
                HStack(spacing: 4 * scale) {
                    if !item.icon.isEmpty {
                        Image(systemName: item.icon)
                            .font(.system(size: 10 * scale, weight: .semibold))
                            .foregroundColor(ringColor.opacity(0.95))
                    }
                    Text(item.label)
                        .font(.system(size: 11.5 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                }
                Text(item.detail)
                    .font(.system(size: max(7.5, 9 * scale), weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: 100 * scale)
    }
}

struct BoardView: View {
    let rows: [BoardRow]
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 5 * scale) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0),
                                              .white.opacity(0.22),
                                              .white.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            ForEach(rows) { row in
                HStack(spacing: 8 * scale) {
                    ForEach(Array(row.parts.enumerated()), id: \.offset) { idx, part in
                        HStack(spacing: 4 * scale) {
                            Image(systemName: part.symbol)
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            Text(part.text)
                                .font(.system(size: max(8, 10 * scale), weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.78))
                        }
                        if idx < row.parts.count - 1 {
                            Circle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 2.5 * scale, height: 2.5 * scale)
                        }
                    }
                }
            }
        }
        .padding(.top, 6 * scale)
    }
}

struct WidgetView: View {
    @ObservedObject var monitor: Monitor
    var onResize: (() -> Void)? = nil

    private var scale: CGFloat { CGFloat(monitor.scale) }

    private var panelWidth: CGFloat {
        let count = CGFloat(max(1, monitor.items.count))
        return scale * (32 + count * 100 + max(0, count - 1) * 12)
    }

    var body: some View {
        VStack(spacing: 10 * scale) {
            HStack(spacing: 12 * scale) {
                ForEach(monitor.items) { item in
                    RingGauge(item: item, compact: monitor.compact, scale: scale)
                }
            }
            if !monitor.compact && !monitor.rows.isEmpty {
                BoardView(rows: monitor.rows, scale: scale)
            }
        }
        .padding(16 * scale)
        .overlay(
            RoundedRectangle(cornerRadius: 26 * scale, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .frame(width: panelWidth)
        .onChange(of: monitor.items.count) { _ in onResize?() }
        .onChange(of: monitor.compact) { _ in onResize?() }
        .onChange(of: monitor.scale) { _ in onResize?() }
    }
}

/// Hosting view: left-drag to move the widget, right-click for the control menu.
final class DragHostingView: NSHostingView<WidgetView> {
    var contextMenuProvider: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        menu.popUp(positioning: nil,
                   at: convert(event.locationInWindow, from: nil),
                   in: self)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let monitor = Monitor()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var timer: DispatchSourceTimer?
    private var hostingView: DragHostingView?
    private var fxView: NSVisualEffectView?
    private var isHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "floatOnTop": false,
            "opacity": 1.0,
            "interval": 2.0,
            "compact": false,
            "scale": 1.0,
        ])
        monitor.compact = Prefs.compact
        monitor.scale = Prefs.scale
        setupWindow()
        applyWindowLevel()
        applyContentSize()
        installStatusItem()
        startTimer()
        monitor.tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        timer = nil
    }

    // MARK: Window

    private func setupWindow() {
        let hosting = DragHostingView(rootView: WidgetView(
            monitor: monitor,
            onResize: { [weak self] in self?.scheduleResize() }))
        hostingView = hosting

        // Frosted glass behind the SwiftUI content, blended with the wallpaper.
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 26
        fx.layer?.masksToBounds = true
        fxView = fx

        let container = NSView()
        container.addSubview(fx)
        container.addSubview(hosting)

        let startSize = NSSize(width: 460, height: 170)
        let win = NSWindow(contentRect: NSRect(origin: defaultOrigin(size: startSize),
                                               size: startSize),
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.isMovableByWindowBackground = true
        win.alphaValue = CGFloat(Prefs.opacity)
        win.delegate = self
        win.contentView = container
        hosting.contextMenuProvider = { [weak self] in self?.buildMenu() }
        window = win
    }

    private func defaultOrigin(size: NSSize) -> NSPoint {
        guard let vf = NSScreen.main?.visibleFrame else { return NSPoint(x: 40, y: 40) }
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24)
    }

    /// Restores the saved position when it still fully fits on a screen,
    /// otherwise docks the widget bottom-right of the main display.
    private func positionWindow() {
        guard let win = window else { return }
        let size = win.frame.size
        var origin: NSPoint?
        if let saved = Prefs.widgetOrigin {
            let rect = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }) {
                origin = saved
            }
        }
        if origin == nil {
            origin = defaultOrigin(size: size)
        }
        win.setFrameOrigin(origin!)
    }

    private func saveFrame() {
        if let f = window?.frame {
            Prefs.widgetOrigin = NSPoint(x: f.origin.x, y: f.origin.y)
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func applyWindowLevel() {
        guard let win = window else { return }
        if Prefs.floatOnTop {
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            // Above the wallpaper AND Finder's desktop-icon layer (which spans
            // the whole screen and otherwise swallows all mouse clicks), but
            // below normal app windows — keeps the widget interactive.
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        win.orderFrontRegardless()
    }

    private func applyContentSize() {
        guard let win = window, let host = hostingView, let fx = fxView else { return }
        let fit = host.fittingSize
        dbg("applyContentSize: fit=\(fit) scale=\(monitor.scale) compact=\(monitor.compact) items=\(monitor.items.count)")
        // Floor guards only against degenerate (zero) fitting sizes.
        let size = NSSize(width: max(fit.width, 280), height: max(fit.height, 120))
        win.setContentSize(size)
        // Re-anchor: saved position if it fully fits, else bottom-right default
        // (preserving the old top-left while the panel grows would push it
        // off the right edge of the screen).
        positionWindow()
        if let container = win.contentView {
            container.frame = NSRect(origin: .zero, size: size)
            fx.frame = container.bounds
            host.frame = container.bounds
        }
        // Keep the glass corner radius in sync with the panel size.
        fx.layer?.cornerRadius = 26 * CGFloat(monitor.scale)
    }

    private func scheduleResize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.applyContentSize()
        }
    }

    // MARK: Menu-bar item (also used as the widget's right-click menu)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "gauge",
                                 accessibilityDescription: "System Rings") {
                button.image = img
            } else {
                button.title = "◉"
            }
            button.toolTip = "System Rings"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let modeTitle = Prefs.floatOnTop ? "Pin to Desktop (behind windows)"
                                          : "Float on Top (above windows)"
        let mode = NSMenuItem(title: modeTitle,
                              action: #selector(toggleFloatMode(_:)), keyEquivalent: "t")
        mode.target = self
        menu.addItem(mode)

        let opacityMenu = NSMenu(title: "Opacity")
        for preset in [1.0, 0.8, 0.6, 0.4] {
            let it = NSMenuItem(title: "\(Int(preset * 100))%",
                                action: #selector(setOpacity(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = preset
            it.state = abs(Prefs.opacity - preset) < 0.01 ? .on : .off
            opacityMenu.addItem(it)
        }
        let opacityHeader = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityHeader.submenu = opacityMenu
        menu.addItem(opacityHeader)

        let sizeMenu = NSMenu(title: "Widget Size")
        let sizePresets: [(title: String, value: Double)] = [
            ("Small · 80%", 0.8),
            ("Medium · 100%", 1.0),
            ("Large · 120%", 1.2),
            ("Extra Large · 140%", 1.4),
        ]
        for preset in sizePresets {
            let it = NSMenuItem(title: preset.title,
                                action: #selector(setScale(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = preset.value
            it.state = abs(Prefs.scale - preset.value) < 0.01 ? .on : .off
            sizeMenu.addItem(it)
        }
        let sizeHeader = NSMenuItem(title: "Widget Size", action: nil, keyEquivalent: "")
        sizeHeader.submenu = sizeMenu
        menu.addItem(sizeHeader)

        let rateMenu = NSMenu(title: "Refresh Rate")
        for seconds in [1.0, 2.0, 5.0] {
            let it = NSMenuItem(title: seconds == 1 ? "1 second" : "\(Int(seconds)) seconds",
                                action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = seconds
            it.state = abs(Prefs.interval - seconds) < 0.01 ? .on : .off
            rateMenu.addItem(it)
        }
        let rateHeader = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        rateHeader.submenu = rateMenu
        menu.addItem(rateHeader)

        let reset = NSMenuItem(title: "Reset Position",
                               action: #selector(resetPosition(_:)), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let visibility = NSMenuItem(title: isHidden ? "Show Widget" : "Hide Widget",
                                    action: #selector(toggleHidden(_:)), keyEquivalent: "h")
        visibility.target = self
        menu.addItem(visibility)

        let compact = NSMenuItem(title: "Compact Mode",
                                 action: #selector(toggleCompact(_:)), keyEquivalent: "c")
        compact.target = self
        compact.state = Prefs.compact ? .on : .off
        menu.addItem(compact)

        let copy = NSMenuItem(title: "Copy Snapshot",
                              action: #selector(copySnapshot(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit System Rings",
                              action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // MARK: Actions

    @objc private func toggleFloatMode(_ sender: NSMenuItem) {
        Prefs.floatOnTop.toggle()
        applyWindowLevel()
        refreshMenu()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double {
            Prefs.opacity = v
            window?.alphaValue = CGFloat(v)
            refreshMenu()
        }
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double {
            Prefs.scale = v
            monitor.scale = v
            scheduleResize()
            refreshMenu()
        }
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double {
            Prefs.interval = v
            startTimer()
            refreshMenu()
        }
    }

    @objc private func resetPosition(_ sender: NSMenuItem) {
        if let win = window {
            win.setFrameOrigin(defaultOrigin(size: win.frame.size))
            saveFrame()
        }
        refreshMenu()
    }

    @objc private func toggleHidden(_ sender: NSMenuItem) {
        guard let win = window else { return }
        if isHidden {
            applyWindowLevel()
        } else {
            win.orderOut(nil)
        }
        isHidden.toggle()
        refreshMenu()
    }

    @objc private func toggleCompact(_ sender: NSMenuItem) {
        let newVal = !Prefs.compact
        Prefs.compact = newVal
        monitor.compact = newVal
        scheduleResize()
        refreshMenu()
    }

    @objc private func copySnapshot(_ sender: NSMenuItem) {
        let text = monitor.snapshotText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change “Launch at Login”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: Timer

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        let seconds = max(0.5, Prefs.interval)
        source.schedule(deadline: .now() + seconds, repeating: .seconds(Int(seconds.rounded())))
        source.setEventHandler { [weak self] in
            self?.monitor.tick()
        }
        source.resume()
        timer = source
    }
}

// MARK: - Entry point

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)   // no Dock icon; menu-bar item + desktop widget
app.run()
