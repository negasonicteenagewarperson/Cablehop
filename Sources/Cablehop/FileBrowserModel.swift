import Foundation
import Observation

@MainActor
@Observable
final class FileBrowserModel {
    let serial: String
    private(set) var path = "/sdcard"
    private(set) var files: [RemoteFile] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var error: String?
    var showHidden = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// Results of a phone-wide search; nil when not searching everywhere.
    private(set) var searchResults: [RemoteFile]?
    private(set) var isSearching = false
    /// Items copied or cut inside the phone, waiting to be pasted.
    private(set) var clipboard: (items: [RemoteFile], cut: Bool)?
    /// The pasteboard changeCount right after our copy, so a later Finder copy wins on paste.
    @ObservationIgnored var clipboardChangeCount = -1

    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Everything currently on screen, for looking up selected IDs.
    var loadedFiles: [RemoteFile] { files + (searchResults ?? []) }

    init(serial: String) { self.serial = serial }

    func loadIfNeeded() { if !hasLoaded { refresh() } }

    func navigate(to newPath: String) {
        guard newPath != path else { refresh(); return }
        backStack.append(path)
        forwardStack.removeAll()
        setPath(newPath)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        setPath(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        setPath(next)
    }

    func goUp() {
        guard path != "/" else { return }
        navigate(to: RemotePath.parent(path))
    }

    private func setPath(_ newPath: String) {
        path = newPath
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        files = []
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        let target = path
        isLoading = true
        loadTask = Task {
            do {
                let list = try await list(target)
                guard !Task.isCancelled, target == path else { return }
                files = list
                error = nil
            } catch {
                guard !Task.isCancelled, target == path else { return }
                files = []
                self.error = error.localizedDescription
                Log.warning("Couldn't open \(target): \(error.localizedDescription)", .files)
            }
            isLoading = false
            hasLoaded = true
        }
    }

    /// The contents of any phone folder, without navigating to it.
    func list(_ dir: String) async throws -> [RemoteFile] {
        if let fs = Phones.mtp(serial) {
            return try await onBackground { try fs.list(dir) }
        }
        return try await ADB.listDirectory(serial: serial, path: dir)
    }

    /// Names of the files being uploaded that already exist in the destination folder. Phone storage
    /// ignores letter case, so "Photo.JPG" counts as a match for "photo.jpg".
    nonisolated static func uploadConflicts(_ urls: [URL], existing: [RemoteFile]) -> Set<String> {
        let taken = Set(existing.map { $0.name.lowercased() })
        return Set(urls.map(\.lastPathComponent).filter { taken.contains($0.lowercased()) })
    }

    // MARK: Phone-wide search

    func searchEverywhere(_ query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { clearSearch(); return }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))  // debounce typing
            guard !Task.isCancelled else { return }
            let results = (try? await ADB.search(serial: serial, root: "/sdcard", query: query)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchResults = nil
        isSearching = false
    }

    // MARK: Phone clipboard

    func copy(_ items: [RemoteFile], cut: Bool) {
        clipboard = items.isEmpty ? nil : (items, cut)
    }

    /// Copies or moves the clipboard into `dir` on the phone itself; nothing travels over the cable.
    ///
    /// Like Finder, it never overwrites: copying into the same folder makes "Name copy", and items
    /// that already exist at the destination are skipped and reported.
    func paste(into dir: String) async throws {
        guard let clipboard else { return }
        for item in clipboard.items where RemotePath.isWithin(dir, item.path) {
            throw ADBError.failed("Can't paste “\(item.name)” inside itself.")
        }
        let items = clipboard.items.filter { !(clipboard.cut && $0.parentPath == dir) }
        guard !items.isEmpty else { return }

        var taken = Set(try await ADB.listDirectory(serial: serial, path: dir).map(\.name))
        var skipped: [String] = []
        var commands: [String] = []
        for item in items {
            var name = item.name
            if taken.contains(name) {
                guard !clipboard.cut && item.parentPath == dir else { skipped.append(name); continue }
                name = Self.copyName(for: name, avoiding: taken)
            }
            taken.insert(name)
            let source = ADB.quote(item.path), target = ADB.quote(RemotePath.join(dir, name))
            // Re-check on the phone in case something appeared since we listed the folder.
            let op = clipboard.cut ? "mv -- \(source) \(target)" : "cp -R -- \(source) \(target)"
            commands.append("if [ -e \(target) ]; then echo \(ADB.quote("__SKIP__|" + item.name)); else \(op) || echo \(ADB.quote("__FAIL__|" + item.name)); fi")
        }

        var failed: [String] = []
        for chunk in stride(from: 0, to: commands.count, by: 40).map({ Array(commands[$0..<min($0 + 40, commands.count)]) }) {
            let r = try await ADB.run(["-s", serial, "shell", chunk.joined(separator: "; ")], timeout: 600)
            for line in r.out.split(separator: "\n") {
                if line.hasPrefix("__SKIP__|") { skipped.append(String(line.dropFirst(9))) }
                if line.hasPrefix("__FAIL__|") { failed.append(String(line.dropFirst(9))) }
            }
        }
        if clipboard.cut { self.clipboard = nil }
        refresh()

        if !failed.isEmpty {
            throw ADBError.failed("Couldn't \(clipboard.cut ? "move" : "copy"): \(failed.joined(separator: ", ")).")
        }
        if !skipped.isEmpty {
            throw ADBError.failed("Skipped \(skipped.count) item\(skipped.count == 1 ? "" : "s") that already exist in that folder: \(skipped.prefix(5).joined(separator: ", "))\(skipped.count > 5 ? "…" : "").")
        }
    }

    /// "Photo.jpg" → "Photo copy.jpg", then "Photo copy 2.jpg", …
    private static func copyName(for name: String, avoiding taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? name : (name as NSString).deletingPathExtension
        let suffix = base == name ? "" : "." + ext
        var n = 1
        while true {
            let candidate = base + (n == 1 ? " copy" : " copy \(n)") + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: File operations

    func makeFolder(named name: String) async throws {
        let name = try RemotePath.validateName(name)
        if let fs = Phones.mtp(serial) {
            let dir = path
            try await onBackground { try fs.makeFolder(in: dir, named: name) }
            refresh()
            return
        }
        let target = ADB.quote(RemotePath.join(path, name))
        let out = try await ADB.shell(serial, "if [ -e \(target) ]; then echo __EXISTS__; else mkdir -- \(target); fi")
        if out.contains("__EXISTS__") { throw ADBError.failed("“\(name)” already exists here.") }
        refresh()
    }

    func rename(_ file: RemoteFile, to newName: String) async throws {
        let name = try RemotePath.validateName(newName)
        guard name != file.name else { return }
        if let fs = Phones.mtp(serial) {
            try await onBackground { try fs.rename(file.path, to: name) }
            searchResults = nil
            refresh()
            return
        }
        let target = ADB.quote(RemotePath.join(RemotePath.parent(file.path), name))
        // Case-only renames (photo.jpg → Photo.jpg) are fine; anything else must not clobber.
        let caseOnly = name.lowercased() == file.name.lowercased()
        let out = try await ADB.shell(serial, caseOnly
            ? "mv -- \(ADB.quote(file.path)) \(target)"
            : "if [ -e \(target) ]; then echo __EXISTS__; else mv -- \(ADB.quote(file.path)) \(target); fi")
        if out.contains("__EXISTS__") { throw ADBError.failed("“\(name)” already exists. Choose a different name.") }
        searchResults = nil
        refresh()
    }

    func delete(_ items: [RemoteFile]) async throws {
        guard !items.isEmpty else { return }
        if let bad = items.first(where: { RemotePath.protected.contains($0.path) || !RemotePath.isSafe($0.path) }) {
            throw ADBError.failed("Cablehop won't delete “\(bad.name)” because it's an important system folder.")
        }
        if let fs = Phones.mtp(serial) {
            let paths = items.map(\.path)
            try await onBackground { try fs.delete(paths) }
        } else {
            try await ADB.shell(serial, "rm -rf -- " + items.map { ADB.quote($0.path) }.joined(separator: " "))
        }
        let deleted = Set(items.map(\.path))
        searchResults?.removeAll { deleted.contains($0.path) }
        refresh()
    }
}
