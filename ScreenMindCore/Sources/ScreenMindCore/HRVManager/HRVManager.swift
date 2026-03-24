import Foundation
import HealthKit

/// Reads HRV (SDNN) from HealthKit and manages the 30-day rolling baseline.
/// Works on both macOS (13+) and iOS (17+).
public final class HRVManager: @unchecked Sendable {

    private let healthStore = HKHealthStore()
    private var baseline30d: Double = 30.0  // ms, default until we have real data

    // MARK: - Public API

    /// Request HealthKit authorisation.
    /// Call once at app launch.
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HRVError.healthKitUnavailable
        }
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        try await healthStore.requestAuthorization(toShare: [], read: [sdnnType])
    }

    /// Fetch the most recent SDNN sample.
    public func latestHRV() async throws -> HRVSnapshot {
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sdnnType,
                                     predicate: nil,
                                     limit: 1,
                                     sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(throwing: HRVError.noDataAvailable)
                    return
                }
                let sdnn = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                continuation.resume(returning: HRVSnapshot(sdnn: sdnn,
                                                           timestamp: sample.endDate))
            }
            healthStore.execute(query)
        }
    }

    /// Fetch 30-day average SDNN and cache it.
    public func refreshBaseline() async throws {
        let sdnnType = HKQuantityType(.heartRateVariabilitySDNN)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        let predicate = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: .now)
        let stats: HKStatistics = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: sdnnType,
                                         quantitySamplePredicate: predicate,
                                         options: .discreteAverage) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                guard let stats else {
                    continuation.resume(throwing: HRVError.noDataAvailable); return
                }
                continuation.resume(returning: stats)
            }
            healthStore.execute(query)
        }
        if let avg = stats.averageQuantity() {
            baseline30d = avg.doubleValue(for: HKUnit.secondUnit(with: .milli))
        }
    }

    /// Dynamic threshold multiplier based on current HRV vs 30-day baseline.
    /// Formula: multiplier = clamp(currentHRV / baseline, 0.4, 1.6)
    public func dynamicMultiplier(currentSDNN: Double) -> Double {
        let raw = currentSDNN / max(baseline30d, 1.0)
        return min(max(raw, 0.4), 1.6)
    }

    // MARK: - Errors

    public enum HRVError: Error {
        case healthKitUnavailable
        case noDataAvailable
    }
}
