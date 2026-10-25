import AppKit
import IOKit
import Observation


@MainActor
@Observable
final class DeviceManager {
    var devices: [Device] = []
    var info: [String: DeviceInfo] = [:]
    var selectedSerial: String?
    let adbMissing = ADB.path == nil

    @ObservationIgnored private var browsers: [String: FileBrowserModel] = [:]
    @ObservationIgnored private var infoFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var selectedDevice: Device? { devices.first { $0.serial == selectedSerial } }

    var recentAddresses: [String] {
        get { access(keyPath: \.recentAddresses); return UserDefaults.standard.stringArray(forKey: "recentAddresses") ?? [] }
        set {
            withMutation(keyPath: \.recentAddresses) {
                UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: "recentAddresses")
            }
        }
    }

    /// Why a file-transfer phone couldn't be opened (e.g. another app has it), by device serial.
    var mtpErrors: [String: String] = [:]
    @ObservationIgnored private var mtpOpening: Set<String> = []
    @ObservationIgnored private var mtpRetryAt: [String: Date] = [:]
    @ObservationIgnored private var mtpCheckingLock: Set<String> = []
    /// When each phone last had its USB connection reset, so a phone that stays unresponsive isn't reset in a loop.
    @ObservationIgnored private var mtpLastReset: [String: Date] = [:]

    init() {
        // File transfer (MTP) works without adb, so always poll; adb is just skipped when missing.
        pollTask = Task { [weak self] in
            if ADB.path != nil { _ = try? await ADB.run(["start-server"]) }
            while !Task.isCancelled {
                await self?.refresh()
                // Check often while you're using the app, rarely when it's in the background.
                try? await Task.sleep(for: .seconds(NSApp?.isActive == false ? 6 : 1.5))
            }
        }
    }

    func browser(for serial: String) -> FileBrowserModel {
        if let model = browsers[serial] { return model }
        let model = FileBrowserModel(serial: serial)
        browsers[serial] = model
        return model
    }

    func displayName(for device: Device) -> String {
        if let model = info[device.serial]?.model, !model.isEmpty { return model }
        if !device.listedModel.isEmpty { return device.listedModel }
        return device.serial
    }

    func refresh() async {
        var list: [Device] = []
        if !adbMissing, let r = try? await ADB.run(["devices", "-l"], timeout: 10) {
            for line in r.out.split(separator: "\n") {
                if line.hasPrefix("List of") || line.hasPrefix("*") { continue }
                let cols = line.split(whereSeparator: \.isWhitespace)
                guard cols.count >= 2 else { continue }
                let model = cols.first { $0.hasPrefix("model:") }
                    .map { $0.dropFirst(6).replacingOccurrences(of: "_", with: " ") } ?? ""
                list.append(Device(serial: String(cols[0]), state: DeviceState(raw: String(cols[1])), listedModel: model))
            }
        }
        // Cablehop's adb commands need Android 6.0 (API 23) or later; older phones should use File transfer.
        for index in list.indices where list[index].state == .device {
            if let sdk = info[list[index].serial]?.sdk, sdk > 0, sdk < 23 { list[index].state = .unsupported }
        }
        list += refreshMTP(adbDevices: list)
        if list != devices { devices = list }

        if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = list.first(where: { $0.state == .device })?.serial ?? list.first?.serial
        }

        for device in list where device.state == .device || device.state == .unsupported {
            if let fetched = infoFetchedAt[device.serial], Date().timeIntervalSince(fetched) < 30 { continue }
            infoFetchedAt[device.serial] = Date()
            Task {
                let fresh: DeviceInfo?
                if let fs = Phones.mtp(device.serial) {
                    fresh = try? await onBackground { fs.deviceInfo() }
                } else {
                    fresh = try? await ADB.deviceInfo(serial: device.serial)
                }
                if let fresh, info[device.serial] != fresh { info[device.serial] = fresh }
            }
        }
    }

    /// Finds phones in "File transfer" mode and opens an MTP session for each. A phone that also has
    /// USB debugging on is used through adb instead, since that unlocks every feature.
    private func refreshMTP(adbDevices: [Device]) -> [Device] {
        let candidates = MTPDiscovery.candidates()
        defer { candidates.forEach { IOObjectRelease($0.service) } }
        var result: [Device] = []
        var present = Set<String>()

        for candidate in candidates {
            let serial = "mtp:" + candidate.key
            present.insert(serial)
            if !candidate.usbSerial.isEmpty,
               adbDevices.contains(where: { $0.serial == candidate.usbSerial && $0.state == .device }) {
                Phones.close(serial)
                continue
            }
            if let fs = Phones.mtp(serial), fs.isBroken {
                // The session got stuck mid-way and couldn't be recovered: reset the USB link and reopen.
                Phones.close(serial)
                resetUSB(candidate.key, serial: serial)
                result.append(Device(serial: serial, state: .connecting, listedModel: fs.displayName, transport: .mtp))
                continue
            }
            if let fs = Phones.mtp(serial) {
                if fs.isLocked { recheckLock(serial, fs) }
                result.append(Device(serial: serial, state: fs.isLocked ? .locked : .device,
                                     listedModel: fs.displayName, transport: .mtp))
                continue
            }
            let failed = mtpErrors[serial] != nil
            result.append(Device(serial: serial, state: failed ? .unavailable : .connecting,
                                 listedModel: candidate.productName, transport: .mtp))
            if mtpOpening.contains(serial) || (mtpRetryAt[serial] ?? .distantPast) > Date() { continue }
            open(candidate, serial: serial)
        }

        for serial in Phones.serials where !present.contains(serial) { Phones.close(serial) }
        for serial in Array(mtpErrors.keys) where !present.contains(serial) { mtpErrors[serial] = nil }
        return result
    }

    private func open(_ candidate: MTPDiscovery.Candidate, serial: String) {
        mtpOpening.insert(serial)
        IOObjectRetain(candidate.service)
        let service = candidate.service, usbSerial = candidate.usbSerial, vendor = candidate.vendorID, key = candidate.key
        Task {
            let result: Result<MTPFileSystem, Error>
            do {
                result = .success(try await onBackground {
                    defer { IOObjectRelease(service) }
                    let conn = MTPConnection(service: service, usbSerial: usbSerial, vendorID: vendor)
                    try conn.open()
                    let fs = MTPFileSystem(conn: conn)
                    try? fs.loadStorages()
                    return fs
                })
            } catch {
                result = .failure(error)
            }
            mtpOpening.remove(serial)
            switch result {
            case .success(let fs):
                Phones.register(serial, fs)
                mtpErrors[serial] = nil
            case .failure(MTPError.unresponsive) where (mtpLastReset[serial] ?? .distantPast) < Date().addingTimeInterval(-60):
                // Usually a session left stuck by an interrupted copy: reset the USB link once and try again.
                resetUSB(key, serial: serial)
            case .failure(let error):
                mtpErrors[serial] = error.localizedDescription
                mtpRetryAt[serial] = Date().addingTimeInterval(5)
            }
            await refresh()
        }
    }

    /// Android reveals storage over MTP only once the phone is unlocked, so keep asking.
    private func recheckLock(_ serial: String, _ fs: MTPFileSystem) {
        guard !mtpCheckingLock.contains(serial) else { return }
        mtpCheckingLock.insert(serial)
        Task {
            _ = try? await onBackground { try fs.loadStorages() }
            mtpCheckingLock.remove(serial)
            if !fs.isLocked {
                infoFetchedAt[serial] = nil
                browsers[serial]?.refresh()
                await refresh()
            }
        }
    }

    private func resetUSB(_ candidateKey: String, serial: String) {
        mtpLastReset[serial] = Date()
        mtpRetryAt[serial] = Date().addingTimeInterval(4)  // give the phone time to come back
        DispatchQueue.global(qos: .userInitiated).async { MTPDiscovery.resetDevice(candidateKey) }
    }

    func retryMTP(_ serial: String) {
        mtpErrors[serial] = nil
        mtpRetryAt[serial] = nil
        Task { await refresh() }
    }

    func refreshInfo(_ serial: String) {
        infoFetchedAt[serial] = nil
        Task { await refresh() }
    }

    // MARK: Wireless

    func mdnsServices() async -> [MDNSService] { await ADB.mdnsServices() }

    func pair(address: String, code: String) async throws {
        let r = try await ADB.run(["pair", address, code])
        guard r.combined.localizedCaseInsensitiveContains("successfully paired") else {
            throw ADBError.failed(r.combined.isEmpty ? "Pairing failed." : r.combined)
        }
    }

    func connect(_ address: String) async throws {
        let r = try await ADB.run(["connect", address])
        let text = r.combined
        guard text.hasPrefix("connected to") || text.contains("already connected") else {
            throw ADBError.failed(text.isEmpty ? "Couldn't connect to \(address)." : text)
        }
        recentAddresses = [address] + recentAddresses.filter { $0 != address }
        await refresh()
        if devices.contains(where: { $0.serial == address }) { selectedSerial = address }
    }

    func disconnect(_ device: Device) async {
        _ = try? await ADB.run(["disconnect", device.serial])
        await refresh()
    }

    /// After a successful `adb pair`, waits for adb's mDNS auto-connect, or connects manually.
    func connectAfterPairing(host: String) async throws {
        for attempt in 0..<12 {
            await refresh()
            if let service = await mdnsServices().first(where: { $0.isConnect && $0.host == host }) {
                if let device = devices.first(where: {
                    ($0.serial.hasPrefix(service.name) || $0.serial == service.address) && $0.state == .device
                }) {
                    selectedSerial = device.serial
                    return
                }
                if attempt >= 3 {
                    try await connect(service.address)
                    return
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ADBError.failed("Paired, but the phone's connection port wasn't found. Use the “IP Address” tab with the IP & port shown on the phone's Wireless debugging screen.")
    }

    /// Classic `adb tcpip 5555` switch for a phone that's plugged in over USB. Works on any Android version.
    func switchToWiFi(_ device: Device) async throws {
        var ip = info[device.serial]?.wifiIP
        if ip == nil { ip = try await ADB.deviceInfo(serial: device.serial).wifiIP }
        guard let ip else { throw ADBError.failed("The phone isn't connected to Wi-Fi.") }
        let r = try await ADB.run(["-s", device.serial, "tcpip", "5555"])
        guard r.code == 0 else { throw ADBError.failed(r.combined) }
        var lastError: Error?
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1.5))
            do { try await connect("\(ip):5555"); return } catch { lastError = error }
        }
        throw lastError ?? ADBError.failed("Couldn't connect to \(ip):5555.")
    }
}
