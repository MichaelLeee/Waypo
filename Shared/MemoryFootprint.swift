import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if os(iOS) && !targetEnvironment(simulator)
import os
#endif

/// One reading of this process's memory use.
///
/// `phys_footprint` is the number the system enforces a limit against, which is
/// what matters for a tunnel extension: it is the figure that decides whether
/// the process is terminated. `resident_size` is recorded alongside it because
/// the two diverge, and seeing both is what tells a compressor problem from an
/// allocation problem.
struct MemoryFootprint: Codable, Hashable, Sendable {
    /// The budget the extension is held to. Applies to iOS; recorded on every
    /// platform so a macOS run is measured against the same yardstick.
    static let extensionBudgetBytes: Int64 = 50 * 1024 * 1024
    /// Past this share of the budget, streaming per-connection buffers is the
    /// only safe way to add request interception.
    static let warningFraction = 0.6

    var label: String
    var timestamp: Date
    var physFootprintBytes: Int64?
    var residentBytes: Int64?
    /// Remaining headroom as reported by the system. iOS only: elsewhere the
    /// budget is the only limit, so there is nothing for the system to report.
    var availableBytes: Int64?
    var budgetBytes: Int64

    var fractionOfBudget: Double? {
        guard let physFootprintBytes, budgetBytes > 0 else { return nil }
        return Double(physFootprintBytes) / Double(budgetBytes)
    }

    var isOverBudget: Bool {
        guard let physFootprintBytes else { return false }
        return physFootprintBytes > budgetBytes
    }

    var isNearBudget: Bool {
        guard let fractionOfBudget else { return false }
        return fractionOfBudget >= Self.warningFraction
    }

    /// One compact line for the log view.
    var displayLine: String {
        guard let physFootprintBytes else { return "Memory footprint unavailable" }
        let budget = budgetBytes.formatted(.byteCount(style: .memory))
        guard let fractionOfBudget else {
            return "\(physFootprintBytes.formatted(.byteCount(style: .memory))) of \(budget)"
        }
        let percent = Int((fractionOfBudget * 100).rounded())
        return "\(physFootprintBytes.formatted(.byteCount(style: .memory))) of \(budget) (\(percent)%)"
    }

    static func sample(label: String,
                       budget: Int64 = extensionBudgetBytes,
                       now: Date = Date()) -> MemoryFootprint {
        let usage = currentUsage()
        return MemoryFootprint(label: label,
                               timestamp: now,
                               physFootprintBytes: usage.physFootprint,
                               residentBytes: usage.resident,
                               availableBytes: availableMemoryBytes(),
                               budgetBytes: budget)
    }

    #if canImport(Darwin)
    private static func currentUsage() -> (physFootprint: Int64?, resident: Int64?) {
        // The port is read here rather than held, so nothing non-Sendable
        // outlives the call.
        let task = mach_task_self_
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, nil) }
        let footprint = Int64(info.phys_footprint)
        let resident = Int64(info.resident_size)
        return (footprint > 0 ? footprint : nil, resident > 0 ? resident : nil)
    }
    #else
    private static func currentUsage() -> (physFootprint: Int64?, resident: Int64?) {
        (nil, nil)
    }
    #endif

    /// The system's own headroom figure, which accounts for the extension's
    /// lower limit rather than the device's free memory. Declared for device
    /// builds only: it is not part of the simulator runtime.
    static func availableMemoryBytes() -> Int64? {
        #if os(iOS) && !targetEnvironment(simulator)
        let available = os_proc_available_memory()
        return available > 0 ? Int64(available) : nil
        #else
        return nil
        #endif
    }
}

/// A bounded series of footprints plus the lines that report them.
///
/// Sampling is deliberately bounded: a trace that grew without limit would
/// itself be the leak it is meant to catch.
struct MemoryTrace: Codable, Hashable, Sendable {
    static let maximumSamples = 32

    var budgetBytes: Int64
    var samples: [MemoryFootprint] = []

    init(budgetBytes: Int64 = MemoryFootprint.extensionBudgetBytes) {
        self.budgetBytes = budgetBytes
    }

    mutating func mark(_ label: String, now: Date = Date()) {
        record(MemoryFootprint.sample(label: label, budget: budgetBytes, now: now))
    }

    mutating func record(_ footprint: MemoryFootprint) {
        samples.append(footprint)
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    var latest: MemoryFootprint? { samples.last }

    var peakPhysFootprintBytes: Int64? {
        samples.compactMap(\.physFootprintBytes).max()
    }

    var isOverBudget: Bool {
        guard let peak = peakPhysFootprintBytes else { return false }
        return peak > budgetBytes
    }

    var isNearBudget: Bool {
        guard let peak = peakPhysFootprintBytes, budgetBytes > 0 else { return false }
        return Double(peak) / Double(budgetBytes) >= MemoryFootprint.warningFraction
    }

    /// One line per reading, so a phase can be attributed to a moment.
    var phaseLines: [String] {
        samples.map { sample in
            "FOOTPRINT phase=\(sample.label)"
                + " phys_footprint=\(sample.physFootprintBytes ?? -1)"
                + " resident=\(sample.residentBytes ?? -1)"
                + " available=\(sample.availableBytes ?? -1)"
                + " budget=\(sample.budgetBytes)"
                + " over=\(sample.isOverBudget ? 1 : 0)"
        }
    }

    /// The line a script greps for. Unknown values are written as -1 rather
    /// than omitted so every field position is stable.
    var machineLine: String {
        "FOOTPRINT summary"
            + " peak_phys=\(peakPhysFootprintBytes ?? -1)"
            + " resident=\(latest?.residentBytes ?? -1)"
            + " available=\(latest?.availableBytes ?? -1)"
            + " budget=\(budgetBytes)"
            + " samples=\(samples.count)"
            + " over=\(isOverBudget ? 1 : 0)"
    }

    var reportLines: [String] { phaseLines + [machineLine] }
}
