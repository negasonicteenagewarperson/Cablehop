import AppKit
import CryptoKit
import Observation

/// Where Cablehop lives online.
enum AppInfo {
    static let repository = "negasonicteenagewarperson/Cablehop"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let issuesURL = URL(string: "https://github.com/\(repository)/issues")!
    static let newIssueURL = URL(string: "https://github.com/\(repository)/issues/new/choose")!
    static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Release downloads must come from here; anything else is refused.
    static let downloadPrefix = "https://github.com/\(repository)/releases/download/"

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
}

/// A version like "2.0" or "v2.0.1", compared number by number.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let numbers = trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.map { $0! }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

struct Release: Decodable, Identifiable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let size: Int
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease, assets
    }

    var id: String { tagName }
    var version: AppVersion? { AppVersion(tagName) }
    var diskImage: Asset? { assets.first { $0.name.hasPrefix("Cablehop-") && $0.name.hasSuffix(".dmg") } }
    var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }
    var signature: Asset? { assets.first { $0.name == "SHA256SUMS.txt.sig" } }
}

/// Checks GitHub for new releases and installs them.
///
/// Safety checks before anything is installed:
/// - downloads only from this project's GitHub releases, over HTTPS;
/// - the release's checksum list must carry a valid signature from Cablehop's release key, which never
///   leaves the developer's Mac, so a compromised GitHub account alone can't push an update;
/// - the disk image must match the SHA-256 checksum in that signed list;
/// - the app inside must be Cablehop (same bundle identifier), the advertised version, and pass
///   `codesign --verify --deep --strict`.
/// If the app can't be replaced in place (e.g. it's running from the disk image, or the folder isn't
/// writable), the disk image is opened so the person can drag it to Applications themselves.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// Public half of the release signing key (see Scripts/sign-release.swift).
    static let releasePublicKey = "PUGLgiwkERfBPuSdEz7potOxIOm46p9E8McTE5Xi2Lk="

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    /// What the update window shows; nil when it's closed.
    var phase: Phase = .idle
    var isPresented = false

    private let defaults = UserDefaults.standard
    static let autoCheckKey = "autoCheckForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { withMutation(keyPath: \.automaticallyChecks) { defaults.set(newValue, forKey: Self.autoCheckKey) } }
    }

    var lastChecked: Date? {
        get { access(keyPath: \.lastChecked); return defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { withMutation(keyPath: \.lastChecked) { defaults.set(newValue, forKey: Self.lastCheckKey) } }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral  // no cookies or cache on disk
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Cablehop/\(AppInfo.version) (macOS)"]
        return URLSession(configuration: config)
    }()

    /// Called at launch: checks quietly at most once a day, and only says something if there's an update.
    func checkInBackgroundIfDue() {
        guard automaticallyChecks else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = phase { isPresented = true; return }
        if case .installing = phase { isPresented = true; return }
        if userInitiated { phase = .checking; isPresented = true }
        Log.info("Checking for updates (current \(AppInfo.version))", .update)
        do {
            var request = URLRequest(url: AppInfo.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError("No response from GitHub.") }
            guard http.statusCode == 200 else {
                throw UpdateError(http.statusCode == 403 || http.statusCode == 429
                    ? "GitHub is limiting requests right now. Try again in a little while."
                    : "GitHub answered with an error (\(http.statusCode)).")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastChecked = Date()
            guard let current = AppVersion(AppInfo.version), let latest = release.version,
                  !release.draft, !release.prerelease, latest > current, release.diskImage != nil else {
                Log.info("Up to date (latest release \(release.tagName))", .update)
                if userInitiated { phase = .upToDate } else { phase = .idle }
                return
            }
            Log.info("Update available: \(release.tagName)", .update)
            if !userInitiated && defaults.string(forKey: Self.skippedKey) == latest.description {
                Log.info("Skipping \(latest) as requested", .update)
                return
            }
            phase = .available(release)
            isPresented = true
        } catch {
            Log.warning("Update check failed: \(error.localizedDescription)", .update)
            if userInitiated { phase = .failed(Self.message(for: error)) }
        }
    }

    func skip(_ release: Release) {
        if let v = release.version { defaults.set(v.description, forKey: Self.skippedKey) }
        dismiss()
    }

    func dismiss() {
        isPresented = false
        if case .downloading = phase { return }
        if case .installing = phase { return }
        phase = .idle
    }

    func install(_ release: Release) {
        if let transfers = TransferManager.current, transfers.activeCount > 0 {
            phase = .failed("Finish or cancel the transfers in progress, then install the update.")
            return
        }
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: Release) async {
        guard let dmgAsset = release.diskImage, let sumsAsset = release.checksums, let expected = release.version else {
            phase = .failed("This release is missing its installer or checksum file.")
            return
        }
        guard let signatureAsset = release.signature else {
            phase = .failed("This release isn't signed, so Cablehop won't install it automatically. You can download it from GitHub instead.")
            return
        }
        let work = Caches.temp.appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            Log.info("Downloading \(dmgAsset.name)", .update)
            phase = .downloading(release, progress: 0)
            let sums = try await download(sumsAsset, to: work, progress: { _ in })
            let signature = try await download(signatureAsset, to: work, progress: { _ in })
            guard try Self.verifySignature(of: Data(contentsOf: sums), signature: Data(contentsOf: signature),
                                           publicKey: Self.releasePublicKey) else {
                throw UpdateError("This update isn't signed by Cablehop's release key, so it wasn't installed.")
            }
            Log.info("Release signature verified", .update)
            let dmg = try await download(dmgAsset, to: work) { [weak self] fraction in
                self?.phase = .downloading(release, progress: fraction)
            }
            phase = .installing(release)

            // 1. The download must match the checksum published with the release.
            let expectedHash = try Self.checksum(for: dmgAsset.name, in: String(contentsOf: sums, encoding: .utf8))
            let actualHash = try await Self.sha256(of: dmg)
            guard actualHash == expectedHash else {
                throw UpdateError("The download is damaged or has been tampered with (checksum mismatch), so it wasn't installed.")
            }
            Log.info("Checksum verified", .update)

            // 2. Open the disk image and check the app inside.
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            var mounted = true
            func unmount() async {
                guard mounted else { return }
                mounted = false
                _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            }
            let newApp = mount.appendingPathComponent("Cablehop.app")
            let current = Bundle.main.bundleURL
            let staging = current.deletingLastPathComponent().appendingPathComponent(".Cablehop-update-\(UUID().uuidString).app")
            do {
                try Self.validate(newApp, expectedVersion: expected)
                try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
                Log.info("New app verified (\(expected))", .update)
                if Self.canReplace(current) {
                    try await Self.run("/usr/bin/ditto", [newApp.path, staging.path])
                }
                await unmount()
            } catch {
                await unmount()
                try? FileManager.default.removeItem(at: staging)
                throw error
            }

            // 3. Replace this copy of the app, or hand the disk image to the person.
            guard Self.canReplace(current) else {
                Log.info("Can't replace \(current.path) in place; opening the disk image instead", .update)
                let kept = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(dmgAsset.name)
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.moveItem(at: dmg, to: kept)
                NSWorkspace.shared.open(kept)
                phase = .failed("Cablehop can't update itself from where it's running. The new version has been saved to your Downloads folder and opened: drag Cablehop onto Applications to finish.")
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(current, withItemAt: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            Log.info("Installed \(expected); relaunching", .update)
            LogStore.shared.flush()
            Self.relaunch(current)
        } catch {
            Log.error("Update failed: \(error.localizedDescription)", .update)
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Steps

    private func download(_ asset: Release.Asset, to folder: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard asset.browserDownloadURL.absoluteString.hasPrefix(AppInfo.downloadPrefix) else {
            throw UpdateError("Refusing to download from an unexpected address.")
        }
        let (bytes, response) = try await session.bytes(from: asset.browserDownloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw UpdateError("The download failed.")
        }
        let destination = folder.appendingPathComponent(asset.name)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let total = max(asset.size, 1)
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try file.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                progress(Double(written) / Double(total))
            }
            if written + buffer.count > 512 * 1024 * 1024 { throw UpdateError("The download is far larger than expected.") }
        }
        try file.write(contentsOf: buffer)
        written += buffer.count
        guard written == asset.size else { throw UpdateError("The download was incomplete.") }
        progress(1)
        return destination
    }

    /// Finds the hash for `fileName` in a `shasum -a 256` listing.
    nonisolated static func checksum(for fileName: String, in listing: String) throws -> String {
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let hash = parts[0].lowercased()
            if name == fileName, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        throw UpdateError("The release's checksum file doesn't list \(fileName).")
    }

    /// Checks an Ed25519 signature (base64 text) over `data`.
    nonisolated static func verifySignature(of data: Data, signature: Data, publicKey: String) throws -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let sigData = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        return key.isValidSignature(sigData, for: data)
    }

    nonisolated static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// The new app must be Cablehop itself, at the version the release says.
    nonisolated static func validate(_ app: URL, expectedVersion: AppVersion) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier ?? "app.cablehop.Cablehop",
              let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
              version == expectedVersion else {
            throw UpdateError("The downloaded app isn't the expected version of Cablehop, so it wasn't installed.")
        }
    }

    /// In-place updates need a normal, writable location (not the disk image or a quarantine copy).
    nonisolated static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        guard app.pathExtension == "app", !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: path)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { cont.resume(throwing: error); return }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    let name = (tool as NSString).lastPathComponent
                    cont.resume(throwing: UpdateError("\(name) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
        }
    }

    /// Opens the freshly installed copy once this one has quit.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as an argument, never spliced into the script.
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if (error as? URLError)?.code == .notConnectedToInternet { return "You're offline. Connect to the internet and try again." }
        return error.localizedDescription
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
