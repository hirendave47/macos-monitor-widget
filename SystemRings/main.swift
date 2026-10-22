//
//  main.swift
//  System Rings
//
//  A macOS *desktop widget* — a frosted-glass panel pinned to the desktop
//  (above the wallpaper, behind normal windows) with live gauges for
//  CPU, Memory, GPU, Disk and Battery, plus sparklines/capacity bars,
//  structured telemetry pills, an interactive detail drawer, thermal/swap
//  warning banners, multiple layout orientations, color themes, and a
//  live menu-bar readout.
//
//  Companion to macos_monitor.py — shares the same mactop dependency for
//  Apple Silicon GPU/battery/power metrics, with native Mach/sysctl/IOKit
//  samplers for instant responsiveness.
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

// MARK: - Enums & Theme / Layout Modes

enum LayoutMode: String, CaseIterable {
    case horizontal = "horizontal"
    case grid       = "grid"
    case vertical   = "vertical"

    var title: String {
        switch self {
        case .horizontal: return "Horizontal Strip (1×5)"
        case .grid:       return "Compact Grid (3×2)"
        case .vertical:   return "Vertical Sidebar"
        }
    }

    var icon: String {
        switch self {
        case .horizontal: return "rectangle.grid.1x2"
        case .grid:       return "square.grid.2x2"
        case .vertical:   return "sidebar.right"
        }
    }

    func next() -> LayoutMode {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .horizontal }
        return all[(idx + 1) % all.count]
    }
}

enum WidgetTheme: String, CaseIterable {
    case adaptive   = "adaptive"
    case emerald    = "emerald"
    case cyber      = "cyber"
    case sunset     = "sunset"
    case monochrome = "monochrome"

    var title: String {
        switch self {
        case .adaptive:   return "Adaptive Status (Green/Yellow/Red)"
        case .emerald:    return "Emerald Matrix"
        case .cyber:      return "Cyber Cyan"
        case .sunset:     return "Sunset Amber"
        case .monochrome: return "Monochrome Glass"
        }
    }

    func next() -> WidgetTheme {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .adaptive }
        return all[(idx + 1) % all.count]
    }

    func ringColor(for pct: Double, id: String, charging: Bool = false) -> Color {
        if id == "batt" && charging {
            return Color(red: 0.20, green: 0.86, blue: 0.82)
        }
        if id == "batt" {
            if pct < 20 { return Color(nsColor: .systemRed) }
            if pct < 35 { return Color(nsColor: .systemYellow) }
        } else {
            if pct >= 90 { return Color(nsColor: .systemRed) }
            if pct >= 75 && self == .adaptive { return Color(nsColor: .systemYellow) }
        }
        switch self {
        case .adaptive:
            return Color(red: 0.22, green: 0.84, blue: 0.45)
        case .emerald:
            return pct >= 80
                ? Color(red: 0.98, green: 0.78, blue: 0.22)
                : Color(red: 0.16, green: 0.92, blue: 0.56)
        case .cyber:
            switch id {
            case "cpu":  return Color(red: 0.18, green: 0.85, blue: 0.98)
            case "mem":  return Color(red: 0.45, green: 0.58, blue: 1.00)
            case "gpu":  return Color(red: 0.72, green: 0.42, blue: 1.00)
            case "disk": return Color(red: 0.22, green: 0.92, blue: 0.80)
            default:     return Color(red: 0.28, green: 0.95, blue: 0.65)
            }
        case .sunset:
            switch id {
            case "cpu":  return Color(red: 1.00, green: 0.62, blue: 0.22)
            case "mem":  return Color(red: 1.00, green: 0.45, blue: 0.42)
            case "gpu":  return Color(red: 0.98, green: 0.76, blue: 0.24)
            case "disk": return Color(red: 0.95, green: 0.52, blue: 0.35)
            default:     return Color(red: 0.45, green: 0.88, blue: 0.52)
            }
        case .monochrome:
            return Color.white.opacity(0.92)
        }
    }

    var accentColor: Color {
        switch self {
        case .adaptive, .emerald: return Color(red: 0.22, green: 0.86, blue: 0.48)
        case .cyber:              return Color(red: 0.22, green: 0.86, blue: 0.98)
        case .sunset:             return Color(red: 1.00, green: 0.65, blue: 0.25)
        case .monochrome:         return Color.white.opacity(0.88)
        }
    }
}

enum MenuBarReadout: String, CaseIterable {
    case iconOnly = "iconOnly"
    case cpuGpu   = "cpuGpu"
    case cpuRamGpu = "cpuRamGpu"
    case powerTemp = "powerTemp"

    var title: String {
        switch self {
        case .iconOnly:  return "Icon Only"
        case .cpuGpu:    return "CPU & GPU %"
        case .cpuRamGpu: return "CPU · RAM · GPU %"
        case .powerTemp: return "Power (W) & Temp (°C)"
        }
    }
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
    static var layoutMode: LayoutMode {
        get {
            guard let s = UserDefaults.standard.string(forKey: "layoutMode"),
                  let m = LayoutMode(rawValue: s) else { return .horizontal }
            return m
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "layoutMode") }
    }
    static var theme: WidgetTheme {
        get {
            guard let s = UserDefaults.standard.string(forKey: "theme"),
                  let t = WidgetTheme(rawValue: s) else { return .adaptive }
            return t
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }
    static var menuBarReadout: MenuBarReadout {
        get {
            guard let s = UserDefaults.standard.string(forKey: "menuBarReadout"),
                  let r = MenuBarReadout(rawValue: s) else { return .cpuGpu }
            return r
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarReadout") }
    }
    static var showHeaderBar: Bool {
        get {
            if UserDefaults.standard.object(forKey: "showHeaderBar") == nil { return true }
            return UserDefaults.standard.bool(forKey: "showHeaderBar")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showHeaderBar") }
    }
    static var alertsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "alertsEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "alertsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "alertsEnabled") }
    }
    static var desktopNotifications: Bool {
        get { UserDefaults.standard.bool(forKey: "desktopNotifications") }
        set { UserDefaults.standard.set(newValue, forKey: "desktopNotifications") }
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

enum MiniChartStyle {
    case sparkline
    case storageBar(usedGB: Double, totalGB: Double, rMBs: Double, wMBs: Double)
    case batteryCells(pct: Double, charging: Bool, onAC: Bool)
}

struct GaugeItem: Identifiable {
    let id: String
    let label: String
    var value: Double?                    // 0...100, nil = unavailable
    var innerSubtext: String = ""         // tiny text under % inside ring
    var detail: String                    // primary subtitle
    var subDetail: String = ""            // secondary subtitle (e.g. peak/avg or freq)
    var history: [Double] = []
    var icon: String = ""
    var charging: Bool = false
    var chartStyle: MiniChartStyle = .sparkline
}

enum PillSeverity {
    case normal
    case accent
    case warning
    case critical
}

struct BoardPart: Identifiable {
    let symbol: String
    let label: String
    let text: String
    var severity: PillSeverity = .normal
    var targetRingId: String? = nil
    var id: String { symbol + label + text }
}

struct BoardRow: Identifiable {
    let parts: [BoardPart]
    var id: String { parts.map(\.id).joined(separator: "|") }
}

struct ProcessEntry: Identifiable {
    let id: String
    let name: String
    let cpuPct: Double
    let memMB: Double
    let gpuMs: Double
}

struct AlertBanner: Identifiable {
    let id: String
    let icon: String
    let message: String
    let isCritical: Bool
}

struct MemoryBreakdown {
    var pct: Double = 0
    var usedGB: Double = 0
    var totalGB: Double = 0
    var wiredGB: Double = 0
    var activeGB: Double = 0
    var compressedGB: Double = 0
    var cacheGB: Double = 0
    var freeGB: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var pressure: String = "Normal"
}

struct DiskBreakdown {
    var pct: Double = 0
    var usedGB: Double = 0
    var freeGB: Double = 0
    var totalGB: Double = 0
    var volumeName: String = "Macintosh HD"
}

/// Enriched metrics from mactop JSON.
struct BoardStats {
    var isAvailable = false
    var totalPower: Double?
    var sysPower: Double?
    var cpuPower: Double?
    var gpuPower: Double?
    var anePower: Double?
    var dramPower: Double?
    var anePct: Double?
    var dramBW: Double?
    var dramReadBW: Double?
    var dramWriteBW: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var memTemp: Double?
    var thermalState: String?
    var netDown: Double?     // MB/s
    var netUp: Double?       // MB/s
    var diskRead: Double?    // MB/s
    var diskWrite: Double?   // MB/s
    var fans: [Int] = []
    var battW: Double?
    var adapterW: Double?
    var pMHz: Int?
    var sMHz: Int?
    var pPct: Double?
    var sPct: Double?
    var gpuMHz: Int?
    var topProcesses: [ProcessEntry] = []

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
    var curMah: Int?
    var designMah: Int?
    var watts: Double?

    static let empty = BatteryInfo()
}

// MARK: - Formatting helpers

private func num(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

private func fmtHM(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
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

private extension Double {
    func clamped() -> Double { min(100, max(0, self)) }
}

// MARK: - Native system samplers (zero external dependencies)

enum SystemSampler {
    struct CPUReading {
        let pct: Double
        let load1: Double
        let load5: Double
        let load15: Double
    }

    static let chipName: String = {
        sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
    }()

    static let coreSummary: String = {
        let total = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let p0 = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let p1 = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        if p0 > 0 && p1 > 0 {
            return "\(total) cores (\(p0)P + \(p1)E)"
        }
        return "\(total) cores"
    }()

    static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var val64: Int64 = 0
        var size64 = MemoryLayout<Int64>.size
        if sysctlbyname(name, &val64, &size64, nil, 0) == 0 { return Int(val64) }
        var val32: Int32 = 0
        var size32 = MemoryLayout<Int32>.size
        if sysctlbyname(name, &val32, &size32, nil, 0) == 0 { return Int(val32) }
        return nil
    }

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

        var la = [Double](repeating: 0, count: 3)
        let n = getloadavg(&la, 3)
        let l1  = n >= 1 ? la[0] : 0
        let l5  = n >= 2 ? la[1] : 0
        let l15 = n >= 3 ? la[2] : 0
        return CPUReading(pct: dB / dT * 100, load1: l1, load5: l5, load15: l15)
    }

    static func memoryBreakdown() -> MemoryBreakdown? {
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
        let toGB: (UInt64) -> Double = { Double($0) * pageSize / 1024 / 1024 / 1024 }
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
        guard totalGB > 0 else { return nil }

        let activeGB = toGB(UInt64(stats.active_count))
        let wiredGB  = toGB(UInt64(stats.wire_count))
        let compGB   = toGB(UInt64(stats.compressor_page_count))
        let cacheGB  = toGB(UInt64(stats.external_page_count + stats.purgeable_count))
        let freeGB   = max(0, totalGB - (activeGB + wiredGB + compGB))
        let usedGB   = activeGB + wiredGB + compGB

        var swapUsedGB = 0.0
        var swapTotalGB = 0.0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapTotalGB = Double(swap.xsu_total) / 1024 / 1024 / 1024
            swapUsedGB  = Double(swap.xsu_used)  / 1024 / 1024 / 1024
        }

        var pressureLevel: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pSize, nil, 0)
        let pressure: String
        switch pressureLevel {
        case 4:  pressure = "Critical"
        case 2:  pressure = "Warning"
        default: pressure = "Normal"
        }

        return MemoryBreakdown(
            pct: (usedGB / totalGB * 100).clamped(),
            usedGB: usedGB,
            totalGB: totalGB,
            wiredGB: wiredGB,
            activeGB: activeGB,
            compressedGB: compGB,
            cacheGB: cacheGB,
            freeGB: freeGB,
            swapUsedGB: swapUsedGB,
            swapTotalGB: swapTotalGB,
            pressure: pressure
        )
    }

    static func diskBreakdown() -> DiskBreakdown? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let bsize = Double(fs.f_bsize)
        let total = Double(fs.f_blocks) * bsize
        let avail = Double(fs.f_bavail) * bsize
        guard total > 0 else { return nil }
        let gb: (Double) -> Double = { $0 / 1024 / 1024 / 1024 }
        let totalGB = gb(total)
        let freeGB  = gb(avail)
        let usedGB  = max(0, totalGB - freeGB)
        let volName = FileManager.default.displayName(atPath: "/")
        return DiskBreakdown(
            pct: (usedGB / totalGB * 100).clamped(),
            usedGB: usedGB,
            freeGB: freeGB,
            totalGB: totalGB,
            volumeName: volName.isEmpty ? "Macintosh HD" : volName
        )
    }

    static func nativeThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Nominal"
        }
    }
}

// MARK: - GPU + enrichment sampler (via mactop + native ps fallback)

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
            Self.queue.async { [weak self] in
                defer { self?.inFlight = false }
                var fallback = BoardStats.empty
                fallback.topProcesses = Self.fetchPsTopProcesses()
                DispatchQueue.main.async { done(nil, "no mactop", fallback) }
            }
            inFlight = true
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
        board.thermalState = last["thermal_state"] as? String

        if let soc = last["soc_metrics"] as? [String: Any] {
            board.isAvailable = true
            board.totalPower  = num(soc["total_power"])
            board.sysPower    = num(soc["system_power"])
            board.cpuPower    = num(soc["cpu_power"])
            board.gpuPower    = num(soc["gpu_power"])
            board.anePower    = num(soc["ane_power"])
            board.dramPower   = num(soc["dram_power"])
            board.anePct      = num(soc["ane_active"])
            board.dramBW      = num(soc["dram_bw_combined_gbs"])
            board.dramReadBW  = num(soc["dram_read_bw_gbs"])
            board.dramWriteBW = num(soc["dram_write_bw_gbs"])
            board.pMHz        = Int(num(soc["p_cluster_freq_mhz"]) ?? 0)
            board.sMHz        = Int(num(soc["s_cluster_freq_mhz"]) ?? 0)
            board.pPct        = num(soc["p_cluster_active"])
            board.sPct        = num(soc["s_cluster_active"])
            board.gpuMHz      = Int(num(soc["gpu_freq_mhz"]) ?? 0)

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
            board.ssdTemp = tempMap["SSD"] ?? tempMap["NAND"]
            board.memTemp = tempMap["Memory"]
        }

        if let nd = last["net_disk"] as? [String: Any] {
            board.netDown   = num(nd["in_bytes_per_sec"]).map { $0 / 1024 / 1024 }
            board.netUp     = num(nd["out_bytes_per_sec"]).map { $0 / 1024 / 1024 }
            board.diskRead  = num(nd["read_kbytes_per_sec"]).map { $0 / 1024 }
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

        if let procs = last["processes"] as? [[String: Any]], !procs.isEmpty {
            var parsedProcs: [ProcessEntry] = []
            for (idx, p) in procs.enumerated() {
                let rawName = (p["command"] as? String) ?? (p["name"] as? String) ?? "?"
                let clean = URL(fileURLWithPath: rawName).lastPathComponent
                if clean == "mactop" || clean == "SystemRings" { continue }
                let cpu = num(p["cpu_percent"]) ?? 0
                let rssMB = (num(p["rss_kb"]) ?? 0) / 1024.0
                let gpuMs = num(p["gpu_ms_per_sec"]) ?? 0
                parsedProcs.append(ProcessEntry(id: "\(idx)-\(clean)",
                                                name: clean,
                                                cpuPct: cpu,
                                                memMB: rssMB,
                                                gpuMs: gpuMs))
            }
            board.topProcesses = parsedProcs
        }

        if board.topProcesses.isEmpty {
            board.topProcesses = fetchPsTopProcesses()
        }

        if !board.isAvailable { gpuDetail = "no soc data" }
        return (pct, gpuDetail, board)
    }

    private static func fetchPsTopProcesses() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        var entries: [ProcessEntry] = []
        for (idx, line) in out.split(separator: "\n").prefix(12).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3,
                  let cpu = Double(parts[0]),
                  let rssKB = Double(parts[1]) else { continue }
            let cmdPath = String(parts[2])
            let name = URL(fileURLWithPath: cmdPath).lastPathComponent
            if name == "ps" || name == "mactop" || name == "SystemRings" { continue }
            entries.append(ProcessEntry(id: "ps-\(idx)-\(name)",
                                        name: name,
                                        cpuPct: cpu,
                                        memMB: rssKB / 1024.0,
                                        gpuMs: 0))
            if entries.count >= 5 { break }
        }
        return entries
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
            let details = self.ioregDetails()
            if let cycles = Self.intOf(details["CycleCount"]) { info.cycles = cycles }
            if let temp = Self.numOf(details["Temperature"]), temp > 0 { info.tempC = temp / 100 }
            let cur = Self.numOf(details["AppleRawMaxCapacity"]) ?? Self.numOf(details["MaxCapacity"]) ?? 0
            let design = Self.numOf(details["DesignCapacity"]) ?? 0
            if cur > 100 { info.curMah = Int(cur) }
            if design > 100 { info.designMah = Int(design) }
            if design > 500 && cur > 100 {
                info.healthPct = cur / design * 100
            } else if cur > 0 && cur <= 100 {
                info.healthPct = cur
            }
            if let v = Self.numOf(details["Voltage"]),
               let a = Self.numOf(details["InstantAmperage"]) {
                let w = (v * a) / 1_000_000.0
                if abs(w) < 250 { info.watts = w }
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

// MARK: - View model

final class Monitor: ObservableObject {
    @Published var items: [GaugeItem] = [
        GaugeItem(id: "cpu",  label: "CPU",    value: nil, detail: "starting…", icon: "cpu"),
        GaugeItem(id: "mem",  label: "Memory", value: nil, detail: "starting…", icon: "memorychip"),
        GaugeItem(id: "gpu",  label: "GPU",    value: nil, detail: "waiting…",  icon: "sparkles"),
        GaugeItem(id: "disk", label: "Disk",   value: nil, detail: "starting…", icon: "internaldrive"),
    ]
    @Published var rows: [BoardRow] = []
    @Published var warnings: [AlertBanner] = []
    @Published var selectedRingId: String? = nil
    @Published var compact: Bool = Prefs.compact
    @Published var scale: Double = Prefs.scale
    @Published var layoutMode: LayoutMode = Prefs.layoutMode
    @Published var theme: WidgetTheme = Prefs.theme
    @Published var showHeaderBar: Bool = Prefs.showHeaderBar
    @Published var alertsEnabled: Bool = Prefs.alertsEnabled
    @Published var copiedFeedback: Bool = false

    // Latest detailed telemetry for the interactive detail drawer & menu bar
    @Published var latestCPU: SystemSampler.CPUReading?
    @Published var latestMem: MemoryBreakdown?
    @Published var latestDisk: DiskBreakdown?
    @Published var board = BoardStats.empty
    @Published var battery: BatteryInfo?

    var onMenuBarUpdate: (() -> Void)?

    private var cpuPrev: (busy: Double, total: Double)?
    private var histories: [String: [Double]] = [:]
    private var peaks: [String: Double] = [:]
    private var sums: [String: (total: Double, count: Int)] = [:]
    private var initialSwapGB: Double?
    private var lastNotificationTime: [String: TimeInterval] = [:]

    private let gpuSampler = GPUSampler()
    private let batterySampler = BatterySampler()
    private var gpuPct: Double?
    private var gpuDetail = "waiting…"
    private let historyLimit = 56

    func avgAndPeak(for id: String) -> (avg: Double, peak: Double)? {
        guard let s = sums[id], s.count > 0, let p = peaks[id] else { return nil }
        return (avg: s.total / Double(s.count), peak: p)
    }

    func tick() {
        var out: [GaugeItem] = []

        // ── CPU ──
        if let cpu = SystemSampler.cpuUsage(prev: &cpuPrev) {
            latestCPU = cpu
            let pct = cpu.pct.clamped()
            pushHistory("cpu", pct)
            let detail: String
            if let mhz = board.pMHz, mhz > 0 {
                detail = String(format: "%.1f GHz · L %.1f", Double(mhz) / 1000.0, cpu.load1)
            } else {
                detail = String(format: "load %.1f · %.1f", cpu.load1, cpu.load5)
            }
            let inner = board.cpuTemp.map { String(format: "%.0f°C", $0) } ?? ""
            let sub = avgAndPeak(for: "cpu").map { String(format: "avg %.0f%% · pk %.0f%%", $0.avg, $0.peak) } ?? ""
            out.append(GaugeItem(id: "cpu", label: "CPU", value: pct,
                                 innerSubtext: inner, detail: detail, subDetail: sub,
                                 history: history("cpu"), icon: "cpu", chartStyle: .sparkline))
        } else if let old = items.first(where: { $0.id == "cpu" }) {
            out.append(old)
        }

        // ── Memory ──
        if let mem = SystemSampler.memoryBreakdown() {
            latestMem = mem
            if initialSwapGB == nil { initialSwapGB = mem.swapUsedGB }
            let pct = mem.pct.clamped()
            pushHistory("mem", pct)
            let detail = String(format: "%.1f / %.0f GB", mem.usedGB, mem.totalGB)
            let inner = mem.swapUsedGB > 0.1 ? String(format: "sw %.1fG", mem.swapUsedGB) : mem.pressure
            let sub = String(format: "wired %.1fG · comp %.1fG", mem.wiredGB, mem.compressedGB)
            out.append(GaugeItem(id: "mem", label: "Memory", value: pct,
                                 innerSubtext: inner, detail: detail, subDetail: sub,
                                 history: history("mem"), icon: "memorychip", chartStyle: .sparkline))
        } else if let old = items.first(where: { $0.id == "mem" }) {
            out.append(old)
        }

        // ── GPU (latest mactop sample) ──
        let gpuInner = board.gpuTemp.map { String(format: "%.0f°C", $0) } ?? ""
        let gpuSub = board.gpuPower.map { String(format: "%.1f W", $0) }
            ?? (avgAndPeak(for: "gpu").map { String(format: "avg %.0f%% · pk %.0f%%", $0.avg, $0.peak) } ?? "")
        out.append(GaugeItem(id: "gpu", label: "GPU", value: gpuPct?.clamped(),
                             innerSubtext: gpuInner, detail: gpuDetail, subDetail: gpuSub,
                             history: history("gpu"), icon: "sparkles", chartStyle: .sparkline))

        // ── Disk ──
        if let disk = SystemSampler.diskBreakdown() {
            latestDisk = disk
            let pct = disk.pct.clamped()
            pushHistory("disk", pct)
            let r = board.diskRead ?? 0
            let w = board.diskWrite ?? 0
            let inner = String(format: "%.0fG free", disk.freeGB)
            let detail = String(format: "free %.0f GB", disk.freeGB)
            let sub = (r > 0.05 || w > 0.05)
                ? String(format: "R %.1f · W %.1f MB/s", r, w)
                : String(format: "%.0f / %.0f GB", disk.usedGB, disk.totalGB)
            out.append(GaugeItem(id: "disk", label: "Disk", value: pct,
                                 innerSubtext: inner, detail: detail, subDetail: sub,
                                 history: history("disk"), icon: "internaldrive",
                                 chartStyle: .storageBar(usedGB: disk.usedGB, totalGB: disk.totalGB, rMBs: r, wMBs: w)))
        } else if let old = items.first(where: { $0.id == "disk" }) {
            out.append(old)
        }

        // ── Battery (appended only when present) ──
        if battery?.present == true {
            let bItem = batteryItem()
            pushHistory("batt", bItem.value ?? 0)
            out.append(bItem)
        }

        items = out
        recomputeRowsAndWarnings()
        onMenuBarUpdate?()

        dbg("tick: items=\(out.map { "\($0.id)=\(String(format: "%.0f", $0.value ?? -1))" }.joined(separator: " ")) rows=\(rows.count)")

        batterySampler.refresh { [weak self] info in
            guard let self = self else { return }
            self.battery = info.present ? info : nil
            if let b = self.battery {
                self.pushHistory("batt", Double(b.pct ?? 0))
            }
            self.syncBatteryItem()
            self.recomputeRowsAndWarnings()
            self.onMenuBarUpdate?()
        }

        gpuSampler.refresh { [weak self] pct, detail, stats in
            guard let self = self else { return }
            if stats.isAvailable {
                self.board = stats
            } else if !stats.topProcesses.isEmpty {
                self.board.topProcesses = stats.topProcesses
            }
            self.gpuDetail = detail
            if let pct = pct {
                self.gpuPct = pct
                self.pushHistory("gpu", pct.clamped())
            }
            self.syncGPUItem()
            self.recomputeRowsAndWarnings()
            self.onMenuBarUpdate?()
        }
    }

    /// Plain-text snapshot for clipboard ("Copy Snapshot").
    func snapshotText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["System Rings (\(SystemSampler.chipName)) — " + formatter.string(from: Date())]
        for item in items {
            if let v = item.value {
                lines.append(String(format: "%@ %.0f%% — %@", item.label, v, item.detail))
            } else {
                lines.append("\(item.label) — \(item.detail)")
            }
        }
        if let mem = latestMem {
            lines.append(String(format: "Memory Breakdown: Wired %.1f GB · Active %.1f GB · Compressed %.1f GB · Swap %.1f/%.1f GB (%@)",
                                mem.wiredGB, mem.activeGB, mem.compressedGB, mem.swapUsedGB, mem.swapTotalGB, mem.pressure))
        }
        if board.isAvailable {
            if let w = board.totalPower ?? board.sysPower {
                lines.append(String(format: "Power %.1f W", w))
            }
            if let bw = board.dramBW {
                lines.append(String(format: "DRAM %.1f GB/s", bw))
            }
            if let c = board.cpuTemp, let g = board.gpuTemp {
                lines.append(String(format: "Temps CPU %.1f°C / GPU %.1f°C", c, g))
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

    func copySnapshotToClipboard() {
        let text = snapshotText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            withAnimation(.easeInOut(duration: 0.2)) {
                self?.copiedFeedback = false
            }
        }
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func menuBarTitle(for mode: MenuBarReadout) -> String {
        switch mode {
        case .iconOnly:
            return ""
        case .cpuGpu:
            let c = latestCPU.map { String(format: "%d%%", Int($0.pct.rounded())) } ?? "–"
            let g = gpuPct.map { String(format: "%d%%", Int($0.rounded())) } ?? "–"
            return " \(c) · \(g)"
        case .cpuRamGpu:
            let c = latestCPU.map { String(format: "%d%%", Int($0.pct.rounded())) } ?? "–"
            let m = latestMem.map { String(format: "%d%%", Int($0.pct.rounded())) } ?? "–"
            let g = gpuPct.map { String(format: "%d%%", Int($0.rounded())) } ?? "–"
            return " \(c) · \(m) · \(g)"
        case .powerTemp:
            var parts: [String] = []
            if let w = board.totalPower ?? board.sysPower, w > 0.05 {
                parts.append(String(format: "%.1fW", w))
            }
            if let t = board.cpuTemp, t > 0 {
                parts.append(String(format: "%.0f°C", t))
            }
            if parts.isEmpty, let c = latestCPU {
                parts.append(String(format: "%d%%", Int(c.pct.rounded())))
            }
            return parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        }
    }

    // MARK: Internals

    private func pushHistory(_ id: String, _ value: Double) {
        var h = histories[id] ?? []
        h.append(value)
        if h.count > historyLimit {
            h.removeFirst(h.count - historyLimit)
        }
        histories[id] = h
        peaks[id] = max(peaks[id] ?? 0, value)
        let cur = sums[id] ?? (0, 0)
        sums[id] = (cur.total + value, cur.count + 1)
    }

    private func history(_ id: String) -> [Double] {
        histories[id] ?? []
    }

    private func syncGPUItem() {
        if let i = items.firstIndex(where: { $0.id == "gpu" }) {
            let gpuInner = board.gpuTemp.map { String(format: "%.0f°C", $0) } ?? ""
            let gpuSub = board.gpuPower.map { String(format: "%.1f W", $0) }
                ?? (avgAndPeak(for: "gpu").map { String(format: "avg %.0f%% · pk %.0f%%", $0.avg, $0.peak) } ?? "")
            items[i] = GaugeItem(id: "gpu", label: "GPU", value: gpuPct?.clamped(),
                                 innerSubtext: gpuInner, detail: gpuDetail, subDetail: gpuSub,
                                 history: history("gpu"), icon: "sparkles", chartStyle: .sparkline)
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
        let pct = Double(b.pct ?? 0).clamped()
        let icon = b.charging ? "bolt.fill"
            : (pct >= 60 ? "battery.100" : (pct >= 30 ? "battery.50" : "battery.25"))
        let inner = b.charging ? "⚡ AC" : (b.onAC ? "AC" : (b.healthPct.map { String(format: "h%.0f%%", $0) } ?? ""))
        let sub = b.cycles.map { "\($0) cyc" } ?? ""
        return GaugeItem(id: "batt", label: "Battery",
                         value: pct,
                         innerSubtext: inner,
                         detail: batteryDetail(b),
                         subDetail: sub,
                         history: history("batt"),
                         icon: icon,
                         charging: b.charging,
                         chartStyle: .batteryCells(pct: pct, charging: b.charging, onAC: b.onAC))
    }

    private func batteryDetail(_ b: BatteryInfo) -> String {
        if b.charging {
            if let w = board.battW ?? b.watts, abs(w) > 0.05 { return String(format: "+%.1f W", abs(w)) }
            if let adapter = board.adapterW, adapter > 0.05 { return String(format: "+%.0f W AC", adapter) }
            return "charging"
        }
        if b.onAC { return "on AC" }
        var parts: [String] = []
        if let w = board.battW ?? b.watts, abs(w) > 0.05 {
            parts.append(String(format: "-%.1f W", abs(w)))
        }
        if let s = b.timeLeftSec, s > 0 { parts.append(fmtHM(s)) }
        if parts.isEmpty {
            if let h = b.healthPct {
                parts.append(String(format: "health %.0f%%", h))
            }
        }
        return parts.isEmpty ? "battery" : parts.joined(separator: " · ")
    }

    private func recomputeRowsAndWarnings() {
        var newRows: [BoardRow] = []

        // Row 1: Power · Bandwidth · Temperatures · ANE
        var r1: [BoardPart] = []
        if let w = board.totalPower ?? board.sysPower, w > 0.05 {
            r1.append(BoardPart(symbol: "bolt.fill", label: "PWR",
                                text: String(format: "%.1f W", w),
                                severity: w > 60 ? .warning : .accent,
                                targetRingId: "cpu"))
        }
        if let bw = board.dramBW, bw > 0.05 {
            r1.append(BoardPart(symbol: "memorychip", label: "BW",
                                text: String(format: "%.1f GB/s", bw),
                                severity: bw > 100 ? .accent : .normal,
                                targetRingId: "gpu"))
        }
        if let ct = board.cpuTemp, let gt = board.gpuTemp, ct > 0 || gt > 0 {
            let maxT = max(ct, gt)
            let sev: PillSeverity = maxT >= 92 ? .critical : (maxT >= 78 ? .warning : .normal)
            r1.append(BoardPart(symbol: "thermometer.medium", label: "TEMP",
                                text: String(format: "%.0f°/%.0f°", ct, gt),
                                severity: sev,
                                targetRingId: "cpu"))
        }
        if let ane = board.anePct, ane >= 1.0 {
            r1.append(BoardPart(symbol: "brain.head.profile", label: "ANE",
                                text: String(format: "%.0f%%", ane),
                                severity: .accent,
                                targetRingId: "gpu"))
        }
        if !r1.isEmpty { newRows.append(BoardRow(parts: r1)) }

        // Row 2: Network · Disk I/O · Swap
        var r2: [BoardPart] = []
        if let d = board.netDown, let u = board.netUp {
            r2.append(BoardPart(symbol: "network", label: "NET",
                                text: String(format: "↓%.1f ↑%.1f MB/s", d, u),
                                severity: (d + u) > 5 ? .accent : .normal))
        }
        if let r = board.diskRead, let w = board.diskWrite {
            r2.append(BoardPart(symbol: "internaldrive", label: "I/O",
                                text: String(format: "R %.1f W %.1f MB/s", r, w),
                                severity: (r + w) > 50 ? .accent : .normal,
                                targetRingId: "disk"))
        }
        if let mem = latestMem, mem.swapUsedGB > 0.05 {
            let sev: PillSeverity = mem.swapUsedGB > 4.0 ? .warning : .normal
            r2.append(BoardPart(symbol: "arrow.left.arrow.right", label: "SWAP",
                                text: String(format: "%.1f GB", mem.swapUsedGB),
                                severity: sev,
                                targetRingId: "mem"))
        }
        if !r2.isEmpty { newRows.append(BoardRow(parts: r2)) }

        // Row 3: Battery Health/Cycles · Fans · Uptime
        var r3: [BoardPart] = []
        if let b = battery, b.present {
            var bits: [String] = []
            if let p = b.pct { bits.append("\(p)%") }
            if let h = b.healthPct { bits.append(String(format: "h%.0f%%", h)) }
            if let c = b.cycles { bits.append("\(c) cyc") }
            if !bits.isEmpty {
                r3.append(BoardPart(symbol: b.charging ? "bolt.batteryblock.fill" : "battery.100",
                                    label: "BAT",
                                    text: bits.joined(separator: " · "),
                                    severity: .normal,
                                    targetRingId: "batt"))
            }
        }
        if !board.fans.isEmpty {
            let rpms = board.fans.prefix(2).map(String.init).joined(separator: "/")
            let maxFan = board.fans.max() ?? 0
            r3.append(BoardPart(symbol: "wind", label: "FAN",
                                text: rpms + " rpm",
                                severity: maxFan > 3800 ? .warning : .normal,
                                targetRingId: "cpu"))
        }
        r3.append(BoardPart(symbol: "clock", label: "UP",
                            text: fmtUptime(ProcessInfo.processInfo.systemUptime),
                            severity: .normal))
        if !r3.isEmpty { newRows.append(BoardRow(parts: r3)) }

        self.rows = newRows

        // ── Compute active warnings ──
        var activeWarnings: [AlertBanner] = []
        let tState = board.thermalState ?? SystemSampler.nativeThermalState()
        if tState == "Serious" || tState == "Critical" {
            activeWarnings.append(AlertBanner(
                id: "thermal_state",
                icon: "flame.fill",
                message: "Thermal state is \(tState) — performance may be throttled",
                isCritical: tState == "Critical"))
        }
        if let ct = board.cpuTemp, ct >= 85 {
            activeWarnings.append(AlertBanner(
                id: "cpu_temp",
                icon: "thermometer.high",
                message: String(format: "High CPU temperature: %.0f°C", ct),
                isCritical: ct >= 95))
        }
        if let gt = board.gpuTemp, gt >= 85 {
            activeWarnings.append(AlertBanner(
                id: "gpu_temp",
                icon: "thermometer.high",
                message: String(format: "High GPU temperature: %.0f°C", gt),
                isCritical: gt >= 95))
        }
        if let mem = latestMem {
            if mem.pressure == "Warning" || mem.pressure == "Critical" {
                activeWarnings.append(AlertBanner(
                    id: "mem_pressure",
                    icon: "exclamationmark.triangle.fill",
                    message: "Memory pressure: \(mem.pressure) (\(Int(mem.pct))% used)",
                    isCritical: mem.pressure == "Critical"))
            }
            if let swap0 = initialSwapGB, (mem.swapUsedGB - swap0) >= 1.0 {
                activeWarnings.append(AlertBanner(
                    id: "swap_growth",
                    icon: "memorychip",
                    message: String(format: "Swap grew +%.1f GB since launch (%.1f GB used)",
                                    mem.swapUsedGB - swap0, mem.swapUsedGB),
                    isCritical: false))
            }
        }
        if let disk = latestDisk, disk.pct >= 88 {
            activeWarnings.append(AlertBanner(
                id: "disk_high",
                icon: "internaldrive.fill",
                message: String(format: "Disk space low: %.0f GB free (%.0f%% used)", disk.freeGB, disk.pct),
                isCritical: disk.pct >= 95))
        }
        if let b = battery, b.present, !b.charging, !b.onAC, let pct = b.pct, pct <= 20 {
            activeWarnings.append(AlertBanner(
                id: "batt_low",
                icon: "battery.25",
                message: "Battery low (\(pct)%) — connect power adapter",
                isCritical: pct <= 10))
        }

        self.warnings = activeWarnings
        if Prefs.desktopNotifications {
            for w in activeWarnings {
                maybePostDesktopNotification(w)
            }
        }
    }

    private func maybePostDesktopNotification(_ banner: AlertBanner) {
        let now = Date.timeIntervalSinceReferenceDate
        if let last = lastNotificationTime[banner.id], now - last < 300 {
            return
        }
        lastNotificationTime[banner.id] = now
        let title = banner.isCritical ? "System Rings — Critical Alert" : "System Rings — Warning"
        let body = banner.message.replacingOccurrences(of: "\"", with: "'")
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
    }
}

// MARK: - Views

struct Sparkline: View {
    let data: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            // Subtle baseline track
            var track = Path()
            track.move(to: CGPoint(x: 0, y: size.height - 1))
            track.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            context.stroke(track, with: .color(Color.white.opacity(0.10)), lineWidth: 1)

            guard data.count > 1 else { return }
            let step = size.width / CGFloat(data.count - 1)
            var pts: [CGPoint] = []
            for (i, v) in data.enumerated() {
                let t = max(0, min(1, v / 100))
                let x = CGFloat(i) * step
                let y = size.height - CGFloat(t) * (size.height - 3) - 1.5
                pts.append(CGPoint(x: x, y: y))
            }

            var line = Path()
            line.move(to: pts[0])
            for i in 1..<pts.count {
                let prev = pts[i - 1]
                let cur  = pts[i]
                let midX = (prev.x + cur.x) * 0.5
                line.addCurve(to: cur,
                              control1: CGPoint(x: midX, y: prev.y),
                              control2: CGPoint(x: midX, y: cur.y))
            }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.32), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(color.opacity(0.92)), lineWidth: 1.4)

            if let last = pts.last {
                let dotRect = CGRect(x: last.x - 2.2, y: last.y - 2.2, width: 4.4, height: 4.4)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
            }
        }
    }
}

/// Replaces the flat sparkline under Disk with a capacity bar + live R/W activity indicator.
struct StorageBarView: View {
    let pct: Double
    let color: Color
    let rMBs: Double
    let wMBs: Double
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2 * scale) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let fillW = max(4, w * CGFloat(pct.clamped() / 100))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [color.opacity(0.65), color],
                                           startPoint: .leading,
                                           endPoint: .trailing)
                        )
                        .frame(width: fillW, height: h)
                }
            }
            .frame(height: 5.5 * scale)

            HStack(spacing: 5 * scale) {
                HStack(spacing: 2 * scale) {
                    Circle()
                        .fill(rMBs > 0.05 ? color : Color.white.opacity(0.22))
                        .frame(width: 4 * scale, height: 4 * scale)
                    Text("R")
                        .font(.system(size: 6.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
                HStack(spacing: 2 * scale) {
                    Circle()
                        .fill(wMBs > 0.05 ? Color.orange : Color.white.opacity(0.22))
                        .frame(width: 4 * scale, height: 4 * scale)
                    Text("W")
                        .font(.system(size: 6.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
    }
}

/// Replaces the flat sparkline under Battery with a 5-cell segmented battery bar.
struct BatteryCellsView: View {
    let pct: Double
    let charging: Bool
    let color: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 3 * scale) {
            ForEach(0..<5, id: \.self) { idx in
                let cellMin = Double(idx) * 20.0
                let cellFill = max(0, min(1, (pct - cellMin) / 20.0))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                            .fill(color.opacity(charging ? 0.95 : 0.85))
                            .frame(width: geo.size.width * CGFloat(cellFill))
                    }
                }
                .frame(height: 6.5 * scale)
            }
        }
        .padding(.vertical, 3.5 * scale)
    }
}

struct RingGauge: View {
    let item: GaugeItem
    let compact: Bool
    let scale: CGFloat
    let theme: WidgetTheme
    let isSelected: Bool
    var onSelect: () -> Void
    var onDoubleTap: () -> Void

    private var ringSize: CGFloat { 86 * scale }
    private var lineW: CGFloat { 10.5 * scale }
    private var diameter: CGFloat { ringSize - lineW - 6 * scale }

    private var fraction: CGFloat {
        item.value.map { CGFloat($0.clamped() / 100) } ?? 0
    }
    private var ringColor: Color {
        guard let v = item.value else { return Color(nsColor: .disabledControlTextColor) }
        return theme.ringColor(for: v, id: item.id, charging: item.charging)
    }
    private var centerText: String {
        item.value.map { "\(Int($0.clamped().rounded()))%" } ?? "–"
    }

    var body: some View {
        VStack(spacing: 5 * scale) {
            ZStack {
                // Outer subtle track
                Circle()
                    .stroke(Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round))
                    .frame(width: diameter, height: diameter)

                // Inner decorative hairline
                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    .frame(width: diameter - lineW - 4 * scale,
                           height: diameter - lineW - 4 * scale)

                // Active progress arc starting cleanly at 12 o'clock (-90°)
                // without any angular gradient seam inside the round cap!
                if fraction > 0.001 {
                    Circle()
                        .trim(from: 0, to: max(0.015, fraction))
                        .stroke(
                            LinearGradient(
                                colors: [ringColor.opacity(0.72), ringColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: lineW, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                        .shadow(color: ringColor.opacity(0.38), radius: 4 * scale)
                }

                VStack(spacing: 1 * scale) {
                    Text(centerText)
                        .font(.system(size: 15.5 * scale, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(item.value == nil
                                         ? Color.white.opacity(0.45)
                                         : Color.white)
                    if !compact && !item.innerSubtext.isEmpty {
                        Text(item.innerSubtext)
                            .font(.system(size: max(7, 8 * scale), weight: .semibold, design: .monospaced))
                            .foregroundColor(ringColor.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: ringSize, height: ringSize)
            .animation(.easeOut(duration: 0.45), value: fraction)

            if !compact {
                Group {
                    switch item.chartStyle {
                    case .sparkline:
                        Sparkline(data: item.history, color: ringColor)
                    case let .storageBar(_, _, rMBs, wMBs):
                        StorageBarView(pct: item.value ?? 0, color: ringColor,
                                       rMBs: rMBs, wMBs: wMBs, scale: scale)
                    case let .batteryCells(pct, charging, _):
                        BatteryCellsView(pct: pct, charging: charging,
                                         color: ringColor, scale: scale)
                    }
                }
                .frame(width: 88 * scale, height: 15 * scale)
            }

            VStack(spacing: 2.5 * scale) {
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
                    .font(.system(size: max(8, 9.2 * scale), weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.vertical, 6 * scale)
        .padding(.horizontal, 4 * scale)
        .frame(width: 108 * scale)
        .background(
            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.11) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                .strokeBorder(isSelected ? ringColor.opacity(0.65) : Color.white.opacity(0.05), lineWidth: 1.1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
    }
}

/// Compact horizontal row card used when LayoutMode == .vertical
struct VerticalRingRow: View {
    let item: GaugeItem
    let compact: Bool
    let scale: CGFloat
    let theme: WidgetTheme
    let isSelected: Bool
    var onSelect: () -> Void
    var onDoubleTap: () -> Void

    private var ringColor: Color {
        guard let v = item.value else { return Color(nsColor: .disabledControlTextColor) }
        return theme.ringColor(for: v, id: item.id, charging: item.charging)
    }
    private var fraction: CGFloat {
        item.value.map { CGFloat($0.clamped() / 100) } ?? 0
    }
    private var centerText: String {
        item.value.map { "\(Int($0.clamped().rounded()))%" } ?? "–"
    }

    var body: some View {
        HStack(spacing: 10 * scale) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 6.5 * scale, lineCap: .round))
                if fraction > 0.001 {
                    Circle()
                        .trim(from: 0, to: max(0.015, fraction))
                        .stroke(ringColor,
                                style: StrokeStyle(lineWidth: 6.5 * scale, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(centerText)
                    .font(.system(size: 10.5 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
            }
            .frame(width: 44 * scale, height: 44 * scale)

            VStack(alignment: .leading, spacing: 2 * scale) {
                HStack(spacing: 4 * scale) {
                    Image(systemName: item.icon)
                        .font(.system(size: 9.5 * scale, weight: .semibold))
                        .foregroundColor(ringColor)
                    Text(item.label)
                        .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                    Spacer()
                    if !item.innerSubtext.isEmpty {
                        Text(item.innerSubtext)
                            .font(.system(size: 8.5 * scale, weight: .semibold, design: .monospaced))
                            .foregroundColor(ringColor.opacity(0.9))
                    }
                }
                Text(item.detail)
                    .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !compact {
                    Sparkline(data: item.history, color: ringColor)
                        .frame(height: 10 * scale)
                }
            }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .frame(width: 225 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .strokeBorder(isSelected ? ringColor.opacity(0.65) : Color.white.opacity(0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) { onSelect() }
    }
}

/// Top quick-action bar with chip identity and one-click controls.
struct HeaderBarView: View {
    @ObservedObject var monitor: Monitor
    var onLayoutChange: () -> Void
    var onCompactToggle: () -> Void
    var onThemeChange: () -> Void

    private var scale: CGFloat { CGFloat(monitor.scale) }

    var body: some View {
        HStack(spacing: 8 * scale) {
            HStack(spacing: 5 * scale) {
                Circle()
                    .fill(monitor.warnings.isEmpty ? monitor.theme.accentColor : Color.orange)
                    .frame(width: 6.5 * scale, height: 6.5 * scale)
                    .shadow(color: (monitor.warnings.isEmpty ? monitor.theme.accentColor : Color.orange).opacity(0.6),
                            radius: 3 * scale)
                Text(SystemSampler.chipName)
                    .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                if let selected = monitor.selectedRingId {
                    Text("· \(selected.uppercased())")
                        .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(monitor.theme.accentColor)
                }
            }

            Spacer(minLength: 8 * scale)

            HStack(spacing: 4 * scale) {
                HeaderIconButton(icon: monitor.layoutMode.icon,
                                 help: "Switch Layout (\(monitor.layoutMode.title))",
                                 scale: scale,
                                 action: onLayoutChange)
                HeaderIconButton(icon: "paintpalette",
                                 help: "Switch Theme (\(monitor.theme.title))",
                                 scale: scale,
                                 action: onThemeChange)
                HeaderIconButton(icon: monitor.compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                 help: monitor.compact ? "Expand Details" : "Compact Mode",
                                 scale: scale,
                                 action: onCompactToggle)
                HeaderIconButton(icon: monitor.copiedFeedback ? "checkmark" : "doc.on.doc",
                                 help: "Copy System Snapshot",
                                 scale: scale,
                                 tint: monitor.copiedFeedback ? .green : nil,
                                 action: { monitor.copySnapshotToClipboard() })
                HeaderIconButton(icon: "waveform.path.ecg.rectangle",
                                 help: "Open Activity Monitor",
                                 scale: scale,
                                 action: { monitor.openActivityMonitor() })
            }
        }
        .padding(.horizontal, 6 * scale)
        .padding(.bottom, 2 * scale)
    }
}

struct HeaderIconButton: View {
    let icon: String
    let help: String
    let scale: CGFloat
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5 * scale, weight: .semibold))
                .foregroundColor(tint ?? .white.opacity(0.75))
                .frame(width: 20 * scale, height: 18 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// High-visibility warning banner for thermal throttling, high swap growth, memory pressure, or low battery.
struct WarningBannerView: View {
    let warnings: [AlertBanner]
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 4 * scale) {
            ForEach(warnings.prefix(2)) { w in
                let tint = w.isCritical ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange)
                HStack(spacing: 6 * scale) {
                    Image(systemName: w.icon)
                        .font(.system(size: 9.5 * scale, weight: .bold))
                        .foregroundColor(tint)
                    Text(w.message)
                        .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 4.5 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .fill(tint.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .strokeBorder(tint.opacity(0.45), lineWidth: 1)
                )
            }
        }
    }
}

/// Interactive detail drawer shown when a user clicks any ring or pill badge.
struct DetailDrawerView: View {
    @ObservedObject var monitor: Monitor
    let ringId: String
    let scale: CGFloat
    var onClose: () -> Void

    private var accent: Color { monitor.theme.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack {
                Text(drawerTitle)
                    .font(.system(size: 10.5 * scale, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                Spacer()
                Button(action: { monitor.openActivityMonitor() }) {
                    HStack(spacing: 3 * scale) {
                        Text("Activity Monitor")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 8.5 * scale, weight: .medium, design: .rounded))
                    .foregroundColor(accent.opacity(0.9))
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            switch ringId {
            case "cpu":
                cpuDetails
            case "mem":
                memoryDetails
            case "gpu":
                gpuDetails
            case "disk":
                diskDetails
            case "batt":
                batteryDetails
            default:
                EmptyView()
            }
        }
        .padding(10 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var drawerTitle: String {
        switch ringId {
        case "cpu":  return "CPU Telemetry · \(SystemSampler.coreSummary)"
        case "mem":  return "Unified Memory & Swap Breakdown"
        case "gpu":  return "Apple Silicon GPU & Bandwidth"
        case "disk": return "Storage Volume (\(monitor.latestDisk?.volumeName ?? "Macintosh HD"))"
        case "batt": return "Battery & Power Adapter Telemetry"
        default:     return "Details"
        }
    }

    @ViewBuilder
    private var cpuDetails: some View {
        let cpu = monitor.latestCPU
        let b = monitor.board
        HStack(spacing: 12 * scale) {
            DetailMetricBox(label: "LOAD (1/5/15m)",
                            value: cpu.map { String(format: "%.2f · %.2f · %.2f", $0.load1, $0.load5, $0.load15) } ?? "–",
                            scale: scale)
            if let pMHz = b.pMHz, pMHz > 0 {
                DetailMetricBox(label: "P-CLUSTER",
                                value: String(format: "%.0f%% @ %.2f GHz", b.pPct ?? 0, Double(pMHz) / 1000.0),
                                scale: scale)
            }
            if let sMHz = b.sMHz, sMHz > 0 {
                DetailMetricBox(label: "S/E-CLUSTER",
                                value: String(format: "%.0f%% @ %.2f GHz", b.sPct ?? 0, Double(sMHz) / 1000.0),
                                scale: scale)
            }
            if let w = b.cpuPower {
                DetailMetricBox(label: "CPU POWER",
                                value: String(format: "%.2f W", w),
                                scale: scale)
            }
        }
        if !b.topProcesses.isEmpty {
            Text("TOP PROCESSES")
                .font(.system(size: 8 * scale, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
                .padding(.top, 2 * scale)
            ForEach(b.topProcesses.prefix(4)) { p in
                HStack {
                    Text(p.name)
                        .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%% CPU", p.cpuPct))
                        .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                        .foregroundColor(accent)
                    Text(String(format: "%.0f MB", p.memMB))
                        .font(.system(size: 8.5 * scale, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 56 * scale, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var memoryDetails: some View {
        if let m = monitor.latestMem {
            HStack(spacing: 10 * scale) {
                DetailMetricBox(label: "WIRED", value: String(format: "%.1f GB", m.wiredGB), scale: scale)
                DetailMetricBox(label: "ACTIVE", value: String(format: "%.1f GB", m.activeGB), scale: scale)
                DetailMetricBox(label: "COMPRESSED", value: String(format: "%.1f GB", m.compressedGB), scale: scale)
                DetailMetricBox(label: "FREE / CACHE", value: String(format: "%.1f / %.1fG", m.freeGB, m.cacheGB), scale: scale)
                DetailMetricBox(label: "SWAP USED", value: String(format: "%.1f / %.1fG", m.swapUsedGB, m.swapTotalGB), scale: scale)
            }
        }
    }

    @ViewBuilder
    private var gpuDetails: some View {
        let b = monitor.board
        HStack(spacing: 10 * scale) {
            DetailMetricBox(label: "CLOCK", value: b.gpuMHz.map { "\($0) MHz" } ?? "–", scale: scale)
            DetailMetricBox(label: "GPU POWER", value: b.gpuPower.map { String(format: "%.2f W", $0) } ?? "–", scale: scale)
            DetailMetricBox(label: "DRAM READ/WRITE",
                            value: (b.dramReadBW != nil && b.dramWriteBW != nil)
                                ? String(format: "R %.1f · W %.1f GB/s", b.dramReadBW!, b.dramWriteBW!)
                                : (b.dramBW.map { String(format: "%.1f GB/s", $0) } ?? "–"),
                            scale: scale)
            DetailMetricBox(label: "ANE", value: b.anePct.map { String(format: "%.0f%% (%.2fW)", $0, b.anePower ?? 0) } ?? "0%", scale: scale)
        }
    }

    @ViewBuilder
    private var diskDetails: some View {
        if let d = monitor.latestDisk {
            let b = monitor.board
            HStack(spacing: 10 * scale) {
                DetailMetricBox(label: "USED", value: String(format: "%.1f GB (%.0f%%)", d.usedGB, d.pct), scale: scale)
                DetailMetricBox(label: "FREE", value: String(format: "%.1f GB", d.freeGB), scale: scale)
                DetailMetricBox(label: "CAPACITY", value: String(format: "%.0f GB", d.totalGB), scale: scale)
                DetailMetricBox(label: "LIVE I/O",
                                value: String(format: "R %.1f · W %.1f MB/s", b.diskRead ?? 0, b.diskWrite ?? 0),
                                scale: scale)
                if let t = b.ssdTemp, t > 0 {
                    DetailMetricBox(label: "SSD TEMP", value: String(format: "%.0f°C", t), scale: scale)
                }
            }
        }
    }

    @ViewBuilder
    private var batteryDetails: some View {
        if let bat = monitor.battery {
            let b = monitor.board
            HStack(spacing: 10 * scale) {
                DetailMetricBox(label: "HEALTH",
                                value: bat.healthPct.map { String(format: "%.0f%%", $0) } ?? "–",
                                scale: scale)
                DetailMetricBox(label: "CAPACITY",
                                value: (bat.curMah != nil && bat.designMah != nil)
                                    ? "\(bat.curMah!) / \(bat.designMah!) mAh"
                                    : "\(bat.pct ?? 0)%",
                                scale: scale)
                DetailMetricBox(label: "CYCLES",
                                value: bat.cycles.map { "\($0)" } ?? "–",
                                scale: scale)
                DetailMetricBox(label: "POWER / ADAPTER",
                                value: String(format: "%.1f W / %.0f W AC",
                                              abs(b.battW ?? bat.watts ?? 0),
                                              b.adapterW ?? 0),
                                scale: scale)
                if let t = bat.tempC, t > 0 {
                    DetailMetricBox(label: "TEMP", value: String(format: "%.1f°C", t), scale: scale)
                }
            }
        }
    }
}

struct DetailMetricBox: View {
    let label: String
    let value: String
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(label)
                .font(.system(size: 7.5 * scale, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 5 * scale)
        .background(
            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

/// Structured frosted pill badges for the bottom telemetry board.
struct BoardView: View {
    let rows: [BoardRow]
    let scale: CGFloat
    let theme: WidgetTheme
    let isVertical: Bool
    var onSelectRing: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 6 * scale) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0),
                                              .white.opacity(0.20),
                                              .white.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .padding(.bottom, 2 * scale)

            if isVertical {
                VStack(alignment: .leading, spacing: 5 * scale) {
                    ForEach(rows.flatMap(\.parts)) { part in
                        TelemetryPill(part: part, scale: scale, theme: theme, fullWidth: true) {
                            if let ringId = part.targetRingId { onSelectRing?(ringId) }
                        }
                    }
                }
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 6 * scale) {
                        ForEach(row.parts) { part in
                            TelemetryPill(part: part, scale: scale, theme: theme, fullWidth: false) {
                                if let ringId = part.targetRingId { onSelectRing?(ringId) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4 * scale)
    }
}

struct TelemetryPill: View {
    let part: BoardPart
    let scale: CGFloat
    let theme: WidgetTheme
    let fullWidth: Bool
    let action: () -> Void

    private var iconColor: Color {
        switch part.severity {
        case .critical: return Color(nsColor: .systemRed)
        case .warning:  return Color(nsColor: .systemYellow)
        case .accent:   return theme.accentColor
        case .normal:   return Color.white.opacity(0.62)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5 * scale) {
                Image(systemName: part.symbol)
                    .font(.system(size: 8.8 * scale, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(part.text)
                    .font(.system(size: max(8, 9.5 * scale), weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                if fullWidth { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                Capsule()
                    .fill(Color.white.opacity(part.severity == .critical ? 0.16 : 0.065))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        part.severity == .critical
                            ? Color.red.opacity(0.5)
                            : Color.white.opacity(0.09),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct WidgetView: View {
    @ObservedObject var monitor: Monitor
    var onResize: (() -> Void)? = nil
    var onMenuSync: (() -> Void)? = nil

    private var scale: CGFloat { CGFloat(monitor.scale) }

    private var panelWidth: CGFloat {
        switch monitor.layoutMode {
        case .horizontal:
            let count = CGFloat(max(1, monitor.items.count))
            return scale * (32 + count * 108 + max(0, count - 1) * 8)
        case .grid:
            let cols: CGFloat = min(3, CGFloat(max(1, monitor.items.count)))
            return scale * (32 + cols * 108 + max(0, cols - 1) * 10)
        case .vertical:
            return scale * 255
        }
    }

    private func toggleRing(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if monitor.selectedRingId == id {
                monitor.selectedRingId = nil
            } else {
                monitor.selectedRingId = id
            }
        }
        onResize?()
    }

    var body: some View {
        VStack(spacing: 8 * scale) {
            if monitor.showHeaderBar {
                HeaderBarView(
                    monitor: monitor,
                    onLayoutChange: {
                        let next = monitor.layoutMode.next()
                        Prefs.layoutMode = next
                        monitor.layoutMode = next
                        onResize?()
                        onMenuSync?()
                    },
                    onCompactToggle: {
                        let next = !monitor.compact
                        Prefs.compact = next
                        monitor.compact = next
                        onResize?()
                        onMenuSync?()
                    },
                    onThemeChange: {
                        let next = monitor.theme.next()
                        Prefs.theme = next
                        monitor.theme = next
                        onMenuSync?()
                    }
                )
            }

            // Rings section across 3 layout orientations
            switch monitor.layoutMode {
            case .horizontal:
                HStack(spacing: 8 * scale) {
                    ForEach(monitor.items) { item in
                        RingGauge(item: item,
                                  compact: monitor.compact,
                                  scale: scale,
                                  theme: monitor.theme,
                                  isSelected: monitor.selectedRingId == item.id,
                                  onSelect: { toggleRing(item.id) },
                                  onDoubleTap: { monitor.openActivityMonitor() })
                    }
                }
            case .grid:
                let topRow = Array(monitor.items.prefix(3))
                let bottomRow = Array(monitor.items.dropFirst(3))
                VStack(spacing: 8 * scale) {
                    HStack(spacing: 10 * scale) {
                        ForEach(topRow) { item in
                            RingGauge(item: item,
                                      compact: monitor.compact,
                                      scale: scale,
                                      theme: monitor.theme,
                                      isSelected: monitor.selectedRingId == item.id,
                                      onSelect: { toggleRing(item.id) },
                                      onDoubleTap: { monitor.openActivityMonitor() })
                        }
                    }
                    if !bottomRow.isEmpty {
                        HStack(spacing: 10 * scale) {
                            ForEach(bottomRow) { item in
                                RingGauge(item: item,
                                          compact: monitor.compact,
                                          scale: scale,
                                          theme: monitor.theme,
                                          isSelected: monitor.selectedRingId == item.id,
                                          onSelect: { toggleRing(item.id) },
                                          onDoubleTap: { monitor.openActivityMonitor() })
                            }
                        }
                    }
                }
            case .vertical:
                VStack(spacing: 6 * scale) {
                    ForEach(monitor.items) { item in
                        VerticalRingRow(item: item,
                                        compact: monitor.compact,
                                        scale: scale,
                                        theme: monitor.theme,
                                        isSelected: monitor.selectedRingId == item.id,
                                        onSelect: { toggleRing(item.id) },
                                        onDoubleTap: { monitor.openActivityMonitor() })
                    }
                }
            }

            // Active Warning Banner
            if monitor.alertsEnabled && !monitor.warnings.isEmpty {
                WarningBannerView(warnings: monitor.warnings, scale: scale)
            }

            // Interactive Detail Drawer when a ring is clicked
            if let selected = monitor.selectedRingId {
                DetailDrawerView(monitor: monitor,
                                 ringId: selected,
                                 scale: scale,
                                 onClose: { toggleRing(selected) })
            }

            // Bottom Structured Telemetry Pills
            if !monitor.compact && !monitor.rows.isEmpty {
                BoardView(rows: monitor.rows,
                          scale: scale,
                          theme: monitor.theme,
                          isVertical: monitor.layoutMode == .vertical,
                          onSelectRing: { id in toggleRing(id) })
            }
        }
        .padding(15 * scale)
        .overlay(
            RoundedRectangle(cornerRadius: 26 * scale, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.24),
                                            Color.white.opacity(0.08)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
        .frame(width: panelWidth)
        .onChange(of: monitor.items.count) { _ in onResize?() }
        .onChange(of: monitor.compact) { _ in onResize?() }
        .onChange(of: monitor.scale) { _ in onResize?() }
        .onChange(of: monitor.layoutMode) { _ in onResize?() }
        .onChange(of: monitor.selectedRingId) { _ in onResize?() }
        .onChange(of: monitor.warnings.count) { _ in onResize?() }
        .onChange(of: monitor.showHeaderBar) { _ in onResize?() }
    }
}

/// Custom borderless window that can become key so SwiftUI buttons, hover states, and tap gestures work on first click.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view: supports both clicking SwiftUI controls/rings AND dragging anywhere to move the widget.
final class DragHostingView: NSHostingView<WidgetView> {
    var contextMenuProvider: (() -> NSMenu?)?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownPoint {
            let cur = event.locationInWindow
            if hypot(cur.x - start.x, cur.y - start.y) > 4 {
                didDrag = true
                mouseDownPoint = nil
                window?.performDrag(with: event)
                return
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        if !didDrag {
            super.mouseUp(with: event)
        }
        didDrag = false
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
    private var window: WidgetWindow?
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
            "layoutMode": LayoutMode.horizontal.rawValue,
            "theme": WidgetTheme.adaptive.rawValue,
            "menuBarReadout": MenuBarReadout.cpuGpu.rawValue,
            "showHeaderBar": true,
            "alertsEnabled": true,
            "desktopNotifications": false,
        ])
        monitor.compact = Prefs.compact
        monitor.scale = Prefs.scale
        monitor.layoutMode = Prefs.layoutMode
        monitor.theme = Prefs.theme
        monitor.showHeaderBar = Prefs.showHeaderBar
        monitor.alertsEnabled = Prefs.alertsEnabled
        monitor.onMenuBarUpdate = { [weak self] in
            self?.updateStatusItemAppearance()
        }

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
            onResize: { [weak self] in self?.scheduleResize() },
            onMenuSync: { [weak self] in self?.refreshMenu() }
        ))
        hostingView = hosting

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

        let startSize = NSSize(width: 500, height: 190)
        let win = WidgetWindow(contentRect: NSRect(origin: defaultOrigin(size: startSize),
                                                   size: startSize),
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.isMovableByWindowBackground = false
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
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        win.orderFrontRegardless()
    }

    private func applyContentSize() {
        guard let win = window, let host = hostingView, let fx = fxView else { return }
        let fit = host.fittingSize
        dbg("applyContentSize: fit=\(fit) scale=\(monitor.scale) compact=\(monitor.compact) layout=\(monitor.layoutMode.rawValue)")
        let size = NSSize(width: max(fit.width, 220), height: max(fit.height, 110))
        win.setContentSize(size)
        positionWindow()
        if let container = win.contentView {
            container.frame = NSRect(origin: .zero, size: size)
            fx.frame = container.bounds
            host.frame = container.bounds
        }
        fx.layer?.cornerRadius = 26 * CGFloat(monitor.scale)
    }

    private func scheduleResize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.applyContentSize()
        }
    }

    // MARK: Menu-bar item & live readout

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusItemAppearance()
        item.menu = buildMenu()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                             accessibilityDescription: "System Rings")
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "System Rings") {
            button.image = img
            button.imagePosition = .imageLeading
        }
        let text = monitor.menuBarTitle(for: Prefs.menuBarReadout)
        if text.isEmpty {
            button.title = ""
        } else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: font]
            )
        }
        button.toolTip = "System Rings — \(SystemSampler.chipName)"
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
        updateStatusItemAppearance()
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

        // Layout submenu
        let layoutMenu = NSMenu(title: "Layout")
        for l in LayoutMode.allCases {
            let it = NSMenuItem(title: l.title,
                                action: #selector(setLayoutMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.state = (Prefs.layoutMode == l) ? .on : .off
            layoutMenu.addItem(it)
        }
        let layoutHeader = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutHeader.submenu = layoutMenu
        menu.addItem(layoutHeader)

        // Color Theme submenu
        let themeMenu = NSMenu(title: "Color Theme")
        for t in WidgetTheme.allCases {
            let it = NSMenuItem(title: t.title,
                                action: #selector(setTheme(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.rawValue
            it.state = (Prefs.theme == t) ? .on : .off
            themeMenu.addItem(it)
        }
        let themeHeader = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
        themeHeader.submenu = themeMenu
        menu.addItem(themeHeader)

        // Menu Bar Readout submenu
        let mbMenu = NSMenu(title: "Menu Bar Readout")
        for r in MenuBarReadout.allCases {
            let it = NSMenuItem(title: r.title,
                                action: #selector(setMenuBarReadout(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = r.rawValue
            it.state = (Prefs.menuBarReadout == r) ? .on : .off
            mbMenu.addItem(it)
        }
        let mbHeader = NSMenuItem(title: "Menu Bar Readout", action: nil, keyEquivalent: "")
        mbHeader.submenu = mbMenu
        menu.addItem(mbHeader)

        // Opacity submenu
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

        // Widget Size submenu
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

        // Refresh Rate submenu
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

        // Alerts submenu
        let alertsMenu = NSMenu(title: "Warnings & Alerts")
        let bannerToggle = NSMenuItem(title: "Show On-Widget Warning Banner",
                                      action: #selector(toggleAlertsBanner(_:)), keyEquivalent: "")
        bannerToggle.target = self
        bannerToggle.state = Prefs.alertsEnabled ? .on : .off
        alertsMenu.addItem(bannerToggle)

        let notifToggle = NSMenuItem(title: "Send macOS Alert Notifications",
                                     action: #selector(toggleDesktopNotifications(_:)), keyEquivalent: "")
        notifToggle.target = self
        notifToggle.state = Prefs.desktopNotifications ? .on : .off
        alertsMenu.addItem(notifToggle)

        let alertsHeader = NSMenuItem(title: "Warnings & Alerts", action: nil, keyEquivalent: "")
        alertsHeader.submenu = alertsMenu
        menu.addItem(alertsHeader)

        let reset = NSMenuItem(title: "Reset Position",
                               action: #selector(resetPosition(_:)), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let visibility = NSMenuItem(title: isHidden ? "Show Widget" : "Hide Widget",
                                    action: #selector(toggleHidden(_:)), keyEquivalent: "h")
        visibility.target = self
        menu.addItem(visibility)

        let headerToggle = NSMenuItem(title: "Show Quick-Action Header",
                                      action: #selector(toggleHeaderBar(_:)), keyEquivalent: "")
        headerToggle.target = self
        headerToggle.state = Prefs.showHeaderBar ? .on : .off
        menu.addItem(headerToggle)

        let compact = NSMenuItem(title: "Compact Mode",
                                 action: #selector(toggleCompact(_:)), keyEquivalent: "c")
        compact.target = self
        compact.state = Prefs.compact ? .on : .off
        menu.addItem(compact)

        let copy = NSMenuItem(title: "Copy Snapshot",
                              action: #selector(copySnapshot(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let actMon = NSMenuItem(title: "Open Activity Monitor",
                                action: #selector(openActivityMonitorAction(_:)), keyEquivalent: "")
        actMon.target = self
        menu.addItem(actMon)

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

    @objc private func setLayoutMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = LayoutMode(rawValue: raw) {
            Prefs.layoutMode = mode
            monitor.layoutMode = mode
            scheduleResize()
            refreshMenu()
        }
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let t = WidgetTheme(rawValue: raw) {
            Prefs.theme = t
            monitor.theme = t
            refreshMenu()
        }
    }

    @objc private func setMenuBarReadout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let r = MenuBarReadout(rawValue: raw) {
            Prefs.menuBarReadout = r
            refreshMenu()
        }
    }

    @objc private func toggleHeaderBar(_ sender: NSMenuItem) {
        let next = !Prefs.showHeaderBar
        Prefs.showHeaderBar = next
        monitor.showHeaderBar = next
        scheduleResize()
        refreshMenu()
    }

    @objc private func toggleAlertsBanner(_ sender: NSMenuItem) {
        let next = !Prefs.alertsEnabled
        Prefs.alertsEnabled = next
        monitor.alertsEnabled = next
        scheduleResize()
        refreshMenu()
    }

    @objc private func toggleDesktopNotifications(_ sender: NSMenuItem) {
        Prefs.desktopNotifications.toggle()
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
        monitor.copySnapshotToClipboard()
    }

    @objc private func openActivityMonitorAction(_ sender: NSMenuItem) {
        monitor.openActivityMonitor()
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
