import Foundation
import CoreLocation
import MapKit
import CoreData

/// Manages relaxation suggestions, geocoding, and travel-time calculation.
/// Travel times are computed via MapKit MKDirections (Apple Maps / AutoNavi).
public final class SuggestionEngine: @unchecked Sendable {

    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Fetch suggestions

    /// Return all enabled suggestions ordered by sortOrder.
    public func enabledSuggestions() async -> [SuggestionItem] {
        let ctx = persistence.container.viewContext
        let request = RelaxationSuggestion.fetchRequest()
        request.predicate = NSPredicate(format: "isEnabled == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        let results = (try? ctx.fetch(request)) ?? []
        return results.map { entity in
            SuggestionItem(
                id: entity.id ?? UUID(),
                title: entity.title ?? "",
                detail: entity.detail,
                address: entity.address,
                latitude: entity.latitude == 0 ? nil : entity.latitude,
                longitude: entity.longitude == 0 ? nil : entity.longitude,
                travelMinutes: entity.travelMinutes == 0 ? nil : Int(entity.travelMinutes)
            )
        }
    }

    // MARK: - Geocode and calculate travel times

    /// For all suggestions that have an address but no (or stale) travel time,
    /// geocode them and compute driving time from current location.
    public func refreshTravelTimes(from origin: CLLocation) async {
        let ctx = persistence.newBackgroundContext()
        await ctx.perform {
            let request = RelaxationSuggestion.fetchRequest()
            request.predicate = NSPredicate(format: "address != nil AND address != ''")
            guard let suggestions = try? ctx.fetch(request) else { return }
            Task {
                for suggestion in suggestions {
                    guard let address = suggestion.address, !address.isEmpty else { continue }
                    // Only refresh if stale (> 1 day old) or never computed
                    if let updated = suggestion.travelUpdatedAt,
                       Date().timeIntervalSince(updated) < 86400 { continue }
                    do {
                        let minutes = try await self.travelMinutes(from: origin, toAddress: address)
                        suggestion.travelMinutes = Int32(minutes)
                        suggestion.travelUpdatedAt = Date()
                        try? ctx.save()
                    } catch {
                        // Geocoding may fail offline — skip gracefully
                    }
                }
            }
        }
    }

    // MARK: - MapKit routing

    /// Geocode an address and return driving travel time in minutes.
    public func travelMinutes(from origin: CLLocation, toAddress address: String) async throws -> Int {
        // Step 1: Geocode the destination address
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.geocodeAddressString(address)
        guard let destination = placemarks.first?.location else {
            throw SuggestionError.geocodingFailed
        }

        // Step 2: MKDirections driving route
        let sourcePlacemark = MKPlacemark(coordinate: origin.coordinate)
        let destPlacemark = MKPlacemark(coordinate: destination.coordinate)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: sourcePlacemark)
        request.destination = MKMapItem(placemark: destPlacemark)
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        guard let route = response.routes.first else {
            throw SuggestionError.noRouteFound
        }
        return Int(route.expectedTravelTime / 60)
    }

    // MARK: - Errors

    public enum SuggestionError: Error {
        case geocodingFailed
        case noRouteFound
    }
}
