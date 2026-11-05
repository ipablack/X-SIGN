import CoreData
extension CatalogLoadingTests {
    @MainActor static func checkStorageRecovery() async throws {
        func container(_ url: URL? = nil) -> NSPersistentContainer {
            let model = NSManagedObjectModel()
            let entity = NSEntityDescription()
            entity.name = "Fixture"; entity.managedObjectClassName = "NSManagedObject"
            let attribute = NSAttributeDescription()
            attribute.name = "name"; attribute.attributeType = .stringAttributeType; attribute.isOptional = false
            entity.properties = [attribute]; model.entities = [entity]
            let result = NSPersistentContainer(name: "Fixture", managedObjectModel: model)
            result.persistentStoreDescriptions = [url.map { NSPersistentStoreDescription(url: $0) } ?? NSPersistentStoreDescription()]
            return result
        }
        func settle(_ value: Storage) async throws {
            for _ in 0..<500 {
                if value.isStoreLoaded || value.storeLoadError != nil { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CheckFailure("Persistent store never finished loading")
        }
        let memory = Storage(inMemory: true, container: container())
        try await settle(memory)
        try require(memory.isStoreLoaded)
        let object = NSEntityDescription.insertNewObject(forEntityName: "Fixture", into: memory.context)
        object.setValue("saved", forKey: "name"); try memory.saveContextNow()
        try require(!memory.context.hasChanges)
        _ = NSEntityDescription.insertNewObject(forEntityName: "Fixture", into: memory.context)
        var saveFailed = false
        do { try memory.saveContextNow() } catch { saveFailed = true }
        try require(saveFailed); memory.context.rollback()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let original = Data("keep existing file".utf8); try original.write(to: parent)
        let disk = Storage(container: container(parent.appendingPathComponent("Fixture.sqlite")))
        try await settle(disk)
        try require(!disk.isStoreLoaded && disk.storeLoadError != nil)
        let preserved = try Data(contentsOf: parent)
        try require(preserved == original, "Load failure deleted an existing file")
        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("preserved"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        disk.retryLoadingStore(); try await settle(disk)
        try require(disk.isStoreLoaded && disk.storeLoadError == nil)
        for store in disk.container.persistentStoreCoordinator.persistentStores {
            try disk.container.persistentStoreCoordinator.remove(store)
        }
        print("PASS: real Core Data save errors, preservation on load failure and retry of the same persistent store")
    }
}
