import Foundation
import Testing
@testable import Cablehop

@Suite("Shell quoting")
struct QuotingTests {
    /// Every hostile filename must reach the shell as one literal argument, never as code.
    @Test(arguments: ["it's", "$(touch /tmp/cablehop-pwned)", "`id`", "a b\tc", "\"q\"", "x'; rm -rf / #", "émoji 📸.jpg", "--help", "*"])
    func roundTrips(_ name: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + ADB.quote(name)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == name)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/cablehop-pwned"))
    }
}

@Suite("Remote paths")
struct PathTests {
    @Test func safety() {
        #expect(RemotePath.isSafe("/sdcard/DCIM/a.jpg"))
        #expect(RemotePath.isSafe("/sdcard/..hidden"))
        #expect(!RemotePath.isSafe("/sdcard/../../etc"))
        #expect(!RemotePath.isSafe("/sdcard/./x"))
        #expect(!RemotePath.isSafe("relative/x"))
        #expect(!RemotePath.isSafe("/sdcard/a\nb"))
    }

    @Test func helpers() {
        #expect(RemotePath.isWithin("/sdcard/a/b", "/sdcard/a"))
        #expect(!RemotePath.isWithin("/sdcard/ab", "/sdcard/a"))
        #expect(RemotePath.isWithin("/x", "/"))
        #expect(RemotePath.normalize("/sdcard//DCIM///x") == "/sdcard/DCIM/x")
        #expect(RemotePath.parent("/sdcard") == "/")
        #expect(RemotePath.join("/", "a") == "/a")
        #expect(RemotePath.join("/sdcard", "a") == "/sdcard/a")
        #expect(RemotePath.protected.contains("/sdcard"))
    }

    @Test(arguments: ["", "  ", "a/b", ".", "..", "a\nb", String(repeating: "x", count: 300)])
    func rejectsBadNames(_ name: String) {
        #expect(throws: (any Error).self) { try RemotePath.validateName(name) }
    }

    @Test func trimsNames() throws {
        #expect(try RemotePath.validateName("  Holiday 2026  ") == "Holiday 2026")
    }
}

@Suite("adb output")
struct TransferOutputTests {
    @Test func percent() {
        #expect(TransferOutput.lastPercent(in: "\r[  5%] /sdcard/a\r[ 47%] /sdcard/a") == 47)
        #expect(TransferOutput.lastPercent(in: "[100%] x") == 100)
        #expect(TransferOutput.lastPercent(in: "no progress here") == nil)
    }

    @Test func messages() {
        #expect(TransferOutput.summary("[ 50%] x\r/sdcard/a.jpg: 1 file pulled, 0 skipped. 38.1 MB/s (123 bytes in 0.1s)\n")
                == "1 file pulled, 0 skipped. 38.1 MB/s (123 bytes in 0.1s)")
        #expect(TransferOutput.error("adb: error: failed to stat remote object '/x': No such file or directory\n")
                == "failed to stat remote object '/x': No such file or directory")
        #expect(TransferOutput.error("adb: failed to install a.apk: Failure [INSTALL_FAILED_OLDER_SDK]\n").contains("INSTALL_FAILED_OLDER_SDK"))
    }
}

@Suite("MTP wire format")
struct MTPWireTests {
    @Test func stringRoundTrip() {
        for value in ["", "DCIM", "Photo 📸 é.jpg"] {
            var w = MTPWriter()
            w.string(value)
            var r = MTPReader(w.data)
            #expect(r.string() == value)
        }
    }

    @Test func integersAreLittleEndian() {
        var w = MTPWriter()
        w.u16(0x1234)
        w.u32(0xDEADBEEF)
        #expect(Array(w.data) == [0x34, 0x12, 0xEF, 0xBE, 0xAD, 0xDE])
        var r = MTPReader(w.data)
        #expect(r.u16() == 0x1234)
        #expect(r.u32() == 0xDEADBEEF)
        #expect(r.remaining == 0)
    }

    @Test func truncatedDataIsSafe() {
        var r = MTPReader(Data([0x01]))
        #expect(r.u32() == 0)          // never reads past the end
        #expect(r.string() == "")
    }

    @Test func dates() {
        #expect(MTPReader.date("20260125T143005") != nil)
        #expect(MTPReader.date("20260125T143005.0Z") != nil)
        #expect(MTPReader.date("garbage") == nil)
    }

    @Test func propertyValues() throws {
        var w = MTPWriter()
        w.u32(42)
        w.string("name.jpg")
        var r = MTPReader(w.data)
        #expect(try r.value(of: 0x0006) as? UInt64 == 42)
        #expect(try r.value(of: 0xFFFF) as? String == "name.jpg")
        #expect(throws: (any Error).self) { _ = try r.value(of: 0x1234) }
    }
}

@Suite("Sorting")
struct SortTests {
    private func file(_ name: String, dir: Bool = false, size: Int64 = 0) -> RemoteFile {
        RemoteFile(path: "/sdcard/" + name, name: name, isDirectory: dir, size: size, modified: .distantPast)
    }

    @Test func foldersFirstNaturalOrder() {
        let files = [file("b10.txt"), file("Zoo", dir: true), file("b2.txt"), file("apps", dir: true)]
        #expect(FileSort().apply(files).map(\.name) == ["apps", "Zoo", "b2.txt", "b10.txt"])
    }

    @Test func bySizeDescending() {
        let files = [file("a", size: 1), file("b", size: 30), file("c", size: 5)]
        #expect(FileSort(key: .size, ascending: false).apply(files).map(\.name) == ["b", "c", "a"])
    }
}

@Suite("Local files")
struct LocalFileTests {
    @Test func recursiveListingSkipsHidden() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ddtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: tmp.appendingPathComponent("a.jpg"))
        try Data(count: 5).write(to: tmp.appendingPathComponent("sub/b.jpg"))
        try Data(count: 1).write(to: tmp.appendingPathComponent(".DS_Store"))
        #expect(LocalFiles.filesRecursive(in: tmp) == ["a.jpg": 10, "sub/b.jpg": 5])
    }

    @Test func quarantineIsRecursive() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ddtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("a.command")
        try Data("echo hi".utf8).write(to: file)
        Quarantine.mark(tmp)
        let props = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(props?[kLSQuarantineAgentNameKey as String] as? String == "Cablehop")
    }
}

@Suite("adb process control")
struct ProcessTests {
    @Test func timeoutKillsStuckCommand() async throws {
        guard ADB.path != nil else { return }
        let start = Date()
        await #expect(throws: (any Error).self) { _ = try await ADB.run(["wait-for-device"], timeout: 1.5) }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func cancellationStopsCommand() async throws {
        guard ADB.path != nil else { return }
        let task = Task { try await ADB.run(["wait-for-device"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(500))
        let cancelled = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(cancelled) < 1)
    }
}

@Suite("MTP uploads")
struct MTPUploadTests {
    /// Regression test for uploads stuck at 0%: a short USB packet before the end makes Android
    /// treat the file as finished, so only the final transfer may be a non-multiple of the packet size.
    @Test(arguments: [0, 1, 500, 511, 512, 1_048_564, 1_048_576, 1_048_588, 3_145_728 + 517, 60 * 1_048_576 + 333])
    func neverSendsAShortPacketMidFile(_ size: Int) {
        let chunk = 1 << 20
        let header = Data(repeating: 0xAA, count: 12)
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var framer = MTPOutFramer(header: header, chunk: chunk)
        var transfers: [Data] = []
        // Feed it the way the uploader does: 1 MB reads from the file.
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunk, payload.count)
            transfers += framer.append(payload.subdata(in: offset..<end))
            offset = end
        }
        if let last = framer.finish() { transfers.append(last) }

        for transfer in transfers.dropLast() {
            #expect(transfer.count % 512 == 0 && transfer.count % 1024 == 0)
        }
        #expect(transfers.reduce(Data(), +) == header + payload)
    }

    @Test func adbGetsATerminalTypeForProgress() async throws {
        unsetenv("TERM")  // like an app opened from Finder
        let runner = PTYProcess(executable: "/bin/sh", arguments: ["-c", "echo TERM=$TERM"])
        let output: String = await withCheckedContinuation { cont in
            runner.onExit = { _, out in cont.resume(returning: out) }
            try? runner.start()
        }
        #expect(output.contains("TERM=xterm-256color"))
    }
}

@Suite("Phone detection")
struct PhoneDetectionTests {
    @Test func acceptsPhonesFromEveryMaker() {
        // Pixel / AOSP: class 6 named "MTP"
        #expect(MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "MTP", vendor: 0x18D1))
        // Samsung, Xiaomi and others: vendor-specific class, labelled MTP
        #expect(MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0xFF, subclass: 0xFF, name: "MTP", vendor: 0x04E8))
        #expect(MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0xFF, subclass: 0xFF, name: "mtp interface", vendor: 0x2717))
        // A phone with no interface name, or in PTP mode
        #expect(MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "", vendor: 0x22B8))
        #expect(MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "PTP", vendor: 0x2A70))
    }

    @Test func leavesOtherDevicesAlone() {
        // iPhones and iPads speak PTP too: Photos owns those
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "PTP", vendor: 0x05AC))
        // A phone's USB debugging (adb) interface
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0xFF, subclass: 0x42, name: "ADB Interface", vendor: 0x18D1))
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0xFF, subclass: 0x42, name: "MTP", vendor: 0x18D1))
        // Unlabelled vendor interfaces (could be anything)
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0xFF, subclass: 0xFF, name: "", vendor: 0x04E8))
        // Digital cameras (Canon, Nikon, Sony)
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "", vendor: 0x04A9))
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x06, subclass: 1, name: "", vendor: 0x054C))
        // Mass storage, audio, etc.
        #expect(!MTPDiscovery.isPhoneTransferInterface(interfaceClass: 0x08, subclass: 6, name: "MTP", vendor: 0x18D1))
    }

    @Test func phonesWithoutSerialNumbersStayTheSameDevice() {
        let a = MTPDiscovery.Candidate(service: 0, usbSerial: "", vendorID: 0x2717, locationID: 0x0010_0000, productName: "Phone")
        let b = MTPDiscovery.Candidate(service: 0, usbSerial: "", vendorID: 0x2717, locationID: 0x0010_0000, productName: "Phone")
        #expect(a.key == b.key && !a.key.isEmpty)
        let pixel = MTPDiscovery.Candidate(service: 0, usbSerial: "5A080DLCQ002HU", vendorID: 0x18D1, locationID: 1, productName: "Pixel")
        #expect(pixel.key == "5A080DLCQ002HU")  // matches the adb serial, so USB debugging takes over cleanly
    }

    @Test func brokenPropertyListsCanNotHideFiles() {
        let folder = MTPObject(handle: 10, storage: 1, parent: 0xFFFFFFFF, name: "DCIM", isFolder: true, size: 0, modified: .distantPast)
        let photo = MTPObject(handle: 11, storage: 1, parent: 10, name: "a.jpg", isFolder: false, size: 5, modified: .distantPast)
        let stray = MTPObject(handle: 99, storage: 1, parent: 42, name: "elsewhere.jpg", isFolder: false, size: 5, modified: .distantPast)
        // The phone returned the folder itself plus an unrelated item: only real children are kept,
        // and handle 12 (missing from the list) is left for a one-by-one lookup.
        let index = MTPConnection.index([folder, photo, stray], keeping: [11, 12])
        #expect(index.keys.sorted() == [11])
    }
}

@Suite("Rename from DroidDock")
struct RenameMigrationTests {
    @Test func movesSettingsAndRemovesTheOldFile() throws {
        let oldDomain = "cablehop.tests.old.\(UUID().uuidString)"
        let newDomain = "cablehop.tests.new.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: newDomain))
        defer {
            defaults.removePersistentDomain(forName: newDomain)
            defaults.removePersistentDomain(forName: oldDomain)
        }
        defaults.setPersistentDomain([
            "downloadFolder": "/Users/me/Phone",
            "syncJobs": Data([1, 2, 3]),
            "viewMode": "grid",
            "NSTableView Columns DroidDockFileTable": ["old layout"],
        ], forName: oldDomain)
        defaults.set("list", forKey: "viewMode")  // already chosen in the new app: keep it

        RenameMigration.moveSettings(from: oldDomain, into: defaults)

        #expect(defaults.string(forKey: "downloadFolder") == "/Users/me/Phone")
        #expect(defaults.data(forKey: "syncJobs") == Data([1, 2, 3]))
        #expect(defaults.string(forKey: "viewMode") == "list")
        #expect(defaults.object(forKey: "NSTableView Columns DroidDockFileTable") == nil)
        #expect((defaults.persistentDomain(forName: oldDomain) ?? [:]).isEmpty)  // old settings gone
    }

    @Test func doesNothingWithoutOldSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "cablehop.tests.empty.\(UUID().uuidString)"))
        RenameMigration.moveSettings(from: "cablehop.tests.missing.\(UUID().uuidString)", into: defaults)
        #expect(defaults.dictionaryRepresentation()["downloadFolder"] == nil)
    }
}
