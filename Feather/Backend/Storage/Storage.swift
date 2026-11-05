import CoreData
import Foundation
import Combine

final class Storage: ObservableObject {
    static let shared = Storage()
    let container: NSPersistentContainer
    @Published private(set) var isStoreLoaded = false
    @Published private(set) var storeLoadError: String?
    private var isLoadingStore = false

    init(inMemory: Bool = false, container suppliedContainer: NSPersistentContainer? = nil) {
        container = suppliedContainer ?? NSPersistentContainer(name: "Feather")
        if inMemory {
            container.persistentStoreDescriptions.first?.type = NSInMemoryStoreType
            container.persistentStoreDescriptions.first?.url = nil
        }
        container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true
        loadPersistentStore()
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var context: NSManagedObjectContext { container.viewContext }
    func saveContext() {
        context.perform { if self.context.hasChanges { try? self.context.save() } }
    }
    func saveContextNow() throws {
        try context.performAndWait { if context.hasChanges { try context.save() } }
    }
    func clearContext<T: NSManagedObject>(request: NSFetchRequest<T>) {
        guard let request = request as? NSFetchRequest<NSFetchRequestResult> else { return }
        _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: request))
    }
    func countContent<T: NSManagedObject>(for type: T.Type) -> String {
        "\((try? context.count(for: T.fetchRequest())) ?? 0)"
    }
    func retryLoadingStore() {
        guard !isStoreLoaded, !isLoadingStore else { return }
        loadPersistentStore()
    }
    private func loadPersistentStore() {
        guard !isLoadingStore else { return }
        isLoadingStore = true
        storeLoadError = nil
        container.loadPersistentStores { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingStore = false
                self.storeLoadError = error?.localizedDescription
                self.isStoreLoaded = error == nil
            }
        }
    }
}
