import CoreData
import Foundation
import Combine

final class Storage: ObservableObject {
    static let shared = Storage()
    let container: NSPersistentContainer
    @Published private(set) var isStoreLoaded = false
    @Published private(set) var storeLoadError: String?
    private var isLoadingStore = false
    private let usesPrivateFiles: Bool

    init(inMemory: Bool = false, container suppliedContainer: NSPersistentContainer? = nil) {
        usesPrivateFiles = !inMemory
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
    private func preparePrivateStorage() {
        guard usesPrivateFiles else { isLoadingStore = false; isStoreLoaded = true; return }
        Task {
            do {
                try await Task.detached(priority: .utility) { try XSignPrivateFiles.migrateLegacyDirectories() }.value
                try await MainActor.run { try self.migrateSigningPasswords() }
                await MainActor.run { self.isLoadingStore = false; self.isStoreLoaded = true }
            } catch {
                await MainActor.run {
                    self.isLoadingStore = false
                    self.storeLoadError = error.localizedDescription
                }
            }
        }
    }
    private func loadPersistentStore() {
        guard !isLoadingStore else { return }
        isLoadingStore = true
        storeLoadError = nil
        if !container.persistentStoreCoordinator.persistentStores.isEmpty {
            preparePrivateStorage()
            return
        }
        container.loadPersistentStores { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.isLoadingStore = false
                    self.storeLoadError = error.localizedDescription
                } else { self.preparePrivateStorage() }
            }
        }
    }
}
