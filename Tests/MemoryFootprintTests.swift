import Foundation
import Testing

@Suite
struct MemoryFootprintTests {
    /// Never asserts a number: the value depends on the machine and on
    /// whatever else is running. Only the shape is contractual.
    @Test
    func sampleIsPositiveOrUnavailable() {
        let footprint = MemoryFootprint.sample(label: "test")
        #expect(footprint.label == "test")
        #expect(footprint.budgetBytes == MemoryFootprint.extensionBudgetBytes)
        if let phys = footprint.physFootprintBytes {
            #expect(phys > 0)
        }
        if let resident = footprint.residentBytes {
            #expect(resident > 0)
        }
    }

    @Test
    func budgetComparisonUsesPhysFootprint() {
        let under = footprint(phys: 59, budget: 100)
        #expect(under.isOverBudget == false)
        #expect(under.isNearBudget == false)
        #expect(under.fractionOfBudget == 0.59)

        let near = footprint(phys: 60, budget: 100)
        #expect(near.isOverBudget == false)
        #expect(near.isNearBudget)

        let over = footprint(phys: 101, budget: 100)
        #expect(over.isOverBudget)
    }

    @Test
    func missingFootprintIsNotTreatedAsOverBudget() {
        let unknown = MemoryFootprint(label: "none",
                                      timestamp: Date(),
                                      physFootprintBytes: nil,
                                      residentBytes: nil,
                                      availableBytes: nil,
                                      budgetBytes: 100)
        #expect(unknown.isOverBudget == false)
        #expect(unknown.isNearBudget == false)
        #expect(unknown.fractionOfBudget == nil)
    }

    @Test
    func zeroBudgetDoesNotDivideByZero() {
        let zero = footprint(phys: 10, budget: 0)
        #expect(zero.fractionOfBudget == nil)
        #expect(zero.isOverBudget)
    }

    @Test
    func traceKeepsThePeak() {
        var trace = MemoryTrace(budgetBytes: 100)
        trace.record(footprint(phys: 40, budget: 100))
        trace.record(footprint(phys: 90, budget: 100))
        trace.record(footprint(phys: 70, budget: 100))
        #expect(trace.peakPhysFootprintBytes == 90)
        #expect(trace.latest?.physFootprintBytes == 70)
        #expect(trace.isOverBudget == false)
        #expect(trace.isNearBudget)
    }

    @Test
    func traceFlagsAnOverBudgetPeak() {
        var trace = MemoryTrace(budgetBytes: 100)
        trace.record(footprint(phys: 40, budget: 100))
        trace.record(footprint(phys: 150, budget: 100))
        trace.record(footprint(phys: 20, budget: 100))
        #expect(trace.isOverBudget)
        #expect(trace.machineLine.contains("peak_phys=150"))
        #expect(trace.machineLine.contains("over=1"))
        #expect(trace.machineLine.contains("samples=3"))
    }

    @Test
    func traceDropsTheOldestSamples() {
        var trace = MemoryTrace(budgetBytes: 100)
        for index in 0..<(MemoryTrace.maximumSamples + 5) {
            trace.record(footprint(phys: Int64(index + 1), budget: 100))
        }
        #expect(trace.samples.count == MemoryTrace.maximumSamples)
        #expect(trace.samples.last?.physFootprintBytes == 37)
        #expect(trace.samples.first?.physFootprintBytes == 6)
    }

    @Test
    func phaseLinesCarryEveryField() {
        var trace = MemoryTrace(budgetBytes: 100)
        trace.record(MemoryFootprint(label: "before-engine",
                                     timestamp: Date(),
                                     physFootprintBytes: 10,
                                     residentBytes: 20,
                                     availableBytes: 30,
                                     budgetBytes: 100))
        #expect(trace.phaseLines.count == 1)
        #expect(trace.phaseLines[0].hasPrefix("FOOTPRINT phase=before-engine "))
        #expect(trace.phaseLines[0].contains("phys_footprint=10"))
        #expect(trace.phaseLines[0].contains("resident=20"))
        #expect(trace.phaseLines[0].contains("available=30"))
        #expect(trace.phaseLines[0].contains("over=0"))
        #expect(trace.machineLine.hasPrefix("FOOTPRINT summary "))
        #expect(trace.reportLines.count == 2)
    }

    @Test
    func unknownValuesAreWrittenAsMinusOne() {
        var trace = MemoryTrace(budgetBytes: 100)
        trace.record(MemoryFootprint(label: "none",
                                     timestamp: Date(),
                                     physFootprintBytes: nil,
                                     residentBytes: nil,
                                     availableBytes: nil,
                                     budgetBytes: 100))
        #expect(trace.phaseLines[0].contains("phys_footprint=-1"))
        #expect(trace.machineLine.contains("peak_phys=-1"))
    }

    @Test
    func anEmptyTraceHasNoPeak() {
        let trace = MemoryTrace(budgetBytes: 100)
        #expect(trace.peakPhysFootprintBytes == nil)
        #expect(trace.isOverBudget == false)
        #expect(trace.latest == nil)
        #expect(trace.machineLine.contains("peak_phys=-1"))
    }

    @Test
    func codableRoundTrip() throws {
        var trace = MemoryTrace(budgetBytes: 100)
        trace.record(footprint(phys: 42, budget: 100))
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(MemoryTrace.self, from: data)
        #expect(decoded == trace)
    }

    @Test
    func displayLineReportsTheShare() {
        let line = footprint(phys: 25, budget: 100).displayLine
        #expect(line.contains("25%"))
        #expect(MemoryFootprint(label: "none",
                               timestamp: Date(),
                               physFootprintBytes: nil,
                               residentBytes: nil,
                               availableBytes: nil,
                               budgetBytes: 100).displayLine == "Memory footprint unavailable")
    }

    private func footprint(phys: Int64, budget: Int64) -> MemoryFootprint {
        MemoryFootprint(label: "phase-\(phys)",
                        timestamp: Date(),
                        physFootprintBytes: phys,
                        residentBytes: phys,
                        availableBytes: nil,
                        budgetBytes: budget)
    }
}
