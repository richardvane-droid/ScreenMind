import CoreData
import Foundation

/// Shared Core Data + CloudKit stack.
/// Uses NSPersistentCloudKitContainer for automatic iCloud sync.
public final class PersistenceController: @unchecked Sendable {

    // MARK: - Shared instance
    public static let shared = PersistenceController()

    /// In-memory store for unit tests and SwiftUI previews.
    public static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        // Seed preview data
        let ctx = controller.container.viewContext
        let record = AnxietyRecord(context: ctx)
        record.id = UUID()
        record.timestamp = Date()
        record.anxietyScore = 0.72
        record.platform = "mac"
        record.appName = "Safari"
        record.notificationSent = true
        record.dynamicThreshold = 0.6
        try? ctx.save()
        return controller
    }()

    // MARK: - Container
    public let container: NSPersistentCloudKitContainer

    // MARK: - Init
    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "ScreenMind")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // CloudKit container identifier — matches entitlements
            let description = container.persistentStoreDescriptions.first!
            description.cloudKitContainerOptions =
                NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.screenmind.app")
            // Enable remote change notifications
            description.setOption(true as NSNumber,
                                  forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }

        container.loadPersistentStores { _, error in
            if let error {
                // In production, log to OSLog and surface graceful error UI.
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Save helper
    public func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            // Replace with proper error handling / OSLog
            assertionFailure("Core Data save error: \(error)")
        }
    }

    /// Background context for write-heavy operations (OCR results, bulk inserts).
    public func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }
}
