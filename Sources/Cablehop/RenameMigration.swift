import Foundation

/// Cablehop was called DroidDock up to version 1.3. Renaming changed its bundle identifier, so on first
/// launch this carries over the old app's settings, transfer history, saved syncs and caches, then
/// removes the old copies. Safe to run every launch: it does nothing once there's nothing left to move.
enum RenameMigration {
    static let oldBundleID = "app.droiddock.DroidDock"
    static let oldFolderName = "DroidDock"

    static func run() {
        moveSettings(from: oldBundleID, into: .standard)
        removeEmptySettingsFile(for: oldBundleID)
        moveCaches()
        removeOldWindowState()
    }

    /// macOS leaves a blank settings file behind after a domain is cleared; delete it once it's empty.
    static func removeEmptySettingsFile(for domain: String) {
        CFPreferencesAppSynchronize(domain as CFString)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let file = library.appendingPathComponent("Preferences/\(domain).plist")
        guard let data = try? Data(contentsOf: file),
              let contents = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              contents.isEmpty else { return }  // never delete a file that still holds settings
        try? FileManager.default.removeItem(at: file)
    }

    /// Copies every old setting that hasn't been set under the new name, then deletes the old settings file.
    static func moveSettings(from oldDomain: String, into defaults: UserDefaults) {
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            // Column layouts were saved under the old table name; let the new one start fresh.
            if key.contains(oldFolderName) { continue }
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: oldDomain)
    }

    /// Thumbnails and temporary copies lived in ~/Library/Caches/DroidDock.
    private static func moveCaches() {
        let fm = FileManager.default
        let old = Caches.root.deletingLastPathComponent().appendingPathComponent(oldFolderName, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if fm.fileExists(atPath: Caches.root.path) {
            try? fm.removeItem(at: old)  // only a cache; the new one already exists
        } else {
            try? fm.moveItem(at: old, to: Caches.root)
        }
    }

    /// macOS keeps window positions per app identifier; the old app's are no longer used.
    private static func removeOldWindowState() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let state = library.appendingPathComponent("Saved Application State/\(oldBundleID).savedState")
        try? FileManager.default.removeItem(at: state)
    }
}
