//
//  Storage+Imported.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Imported Apps
extension Storage {
    @MainActor
    func deleteInterruptedImport(uuid: String) {
        let request = NSFetchRequest<Imported>(entityName: "Imported")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        if let app = (try? context.fetch(request))?.first { deleteApp(for: app) }
    }

	func addImported(
		uuid: String,
		source: URL? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = Imported(context: context)
		
		new.uuid = uuid
		new.source = source
		new.date = Date()
		// could possibly be nil, but thats fine.
		new.identifier = appIdentifier
		new.name = appName
		new.icon = appIcon
		new.version = appVersion
		
        do {
            try saveContextNow()
            generator.impactOccurred()
            completion(nil)
        } catch {
            context.delete(new)
            completion(error)
        }
	}
}
