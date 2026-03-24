import Foundation
import DeviceActivity
import FamilyControls

/// Layer 1 — DeviceActivity monitoring.
/// Tracks app usage time and frequency without reading screen content.
/// FamilyControls authorization is requested once; data flows via DeviceActivityReport.
///
/// Note: DeviceActivity framework requires a real device (not Simulator) and
/// FamilyControls entitlement. Authorization must be granted by the device owner.
final class DeviceActivityMonitor: @unchecked Sendable {

    private let center = DeviceActivityCenter()
    private let authCenter = AuthorizationCenter.shared

    // MARK: - Authorization

    func requestAuthorization() async throws {
        try await authCenter.requestAuthorization(for: .individual)
    }

    // MARK: - Start monitoring

    /// Begin monitoring all apps during waking hours (6am – 11pm).
    func startDailyMonitoring() throws {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 6, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 0),
            repeats: true
        )
        try center.startMonitoring(.daily, during: schedule)
    }

    /// Stop monitoring.
    func stopMonitoring() {
        center.stopMonitoring([.daily])
    }
}

// MARK: - Activity Extension names

extension DeviceActivityName {
    static let daily = DeviceActivityName("com.screenmind.daily")
}
