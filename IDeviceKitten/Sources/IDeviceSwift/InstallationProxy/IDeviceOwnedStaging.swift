import Foundation

// Records only UUID-named packages created by this app; supports retrying cleanup after interruption.
enum IDeviceOwnedStaging {
    private static let lock = NSLock()
    private static let key = "XSign.privateAFCStaging.v1"
    private static func valid(_ path: String) -> Bool {
        let prefix = "/PublicStaging/"
        guard path.hasPrefix(prefix), path.hasSuffix(".ipa") else { return false }
        return UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(4))) != nil
    }
    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).filter(valid)
    }
    static func add(_ path: String) {
        guard valid(path) else { return }
        lock.lock(); defer { lock.unlock() }
        var current = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !current.contains(path) { current.append(path) }
        UserDefaults.standard.set(current, forKey: key)
    }
    static func remove(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let current = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.set(current.filter { $0 != path }, forKey: key)
    }
}
