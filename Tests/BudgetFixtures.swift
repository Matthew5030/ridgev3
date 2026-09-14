import Foundation

/// Explicit devices keep policy assertions independent of the build host and
/// other processes that happen to be running while the suite executes.
enum BudgetFixtures {
    static let mebibyte: Int64 = 1_048_576
    static let gibibyte: Int64 = 1_073_741_824
    static let basic = TerrainBudget.Context(
        physicalMemory: 4 * gibibyte,
        availableMemory: 2 * gibibyte,
        recommendedGPUWorkingSet: 2 * gibibyte,
        maximumBufferLength: 512 * mebibyte,
        gpuTier: .basic
    )
    static let capable = TerrainBudget.Context(
        physicalMemory: 12 * gibibyte,
        availableMemory: 8 * gibibyte,
        recommendedGPUWorkingSet: 6 * gibibyte,
        maximumBufferLength: gibibyte,
        gpuTier: .modern
    )
}
