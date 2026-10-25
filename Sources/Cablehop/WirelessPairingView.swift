import SwiftUI
import CoreImage.CIFilterBuiltins

struct WirelessPairingView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case qr = "QR Code", code = "Pairing Code", cable = "USB → Wi-Fi", manual = "IP Address"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .qr

    var body: some View {
        VStack(spacing: 18) {
            Text("Connect Wirelessly").font(.title2.bold())
            Picker("Method", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .qr: QRPairingPane(onConnected: { dismiss() })
                case .code: CodePairingPane(onConnected: { dismiss() })
                case .cable: CablePane(onConnected: { dismiss() })
                case .manual: ManualPane(onConnected: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)

            HStack {
                Text("Your phone and Mac must be on the same Wi-Fi network.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

private enum PairPhase { case waiting, working, done, failed }

private struct StatusLine: View {
    let phase: PairPhase
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .waiting, .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Text(text).foregroundStyle(phase == .failed ? .red : .primary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Steps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: QR

private struct QRPairingPane: View {
    @Environment(DeviceManager.self) private var dm
    let onConnected: () -> Void

    @State private var serviceName = "cablehop-" + randomAlphanumeric(6)
    @State private var password = randomAlphanumeric(12)
    @State private var phase = PairPhase.waiting
    @State private var status = "Waiting for your phone to scan…"

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(nsImage: QRCode.image(for: "WIFI:T:ADB;S:\(serviceName);P:\(password);;"))
                .interpolation(.none)
                .resizable()
                .frame(width: 210, height: 210)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 14) {
                Text("On your phone").font(.headline)
                Steps(steps: [
                    "Open Settings › Developer options",
                    "Tap Wireless debugging and turn it on",
                    "Tap “Pair device with QR code”",
                    "Scan this code",
                ])
                Divider()
                StatusLine(phase: phase, text: status)
                if phase == .failed {
                    Button("Try Again") {
                        serviceName = "cablehop-" + randomAlphanumeric(6)
                        password = randomAlphanumeric(12)
                    }
                }
            }
        }
        .task(id: serviceName) { await waitForScan() }
    }

    private func waitForScan() async {
        phase = .waiting
        status = "Waiting for your phone to scan…"
        while !Task.isCancelled {
            let services = await dm.mdnsServices()
            if let service = services.first(where: { $0.isPairing && $0.name == serviceName }) {
                phase = .working
                status = "Pairing with \(service.host)…"
                do {
                    try await dm.pair(address: service.address, code: password)
                    status = "Paired! Connecting…"
                    try await dm.connectAfterPairing(host: service.host)
                    phase = .done
                    status = "Connected"
                    try? await Task.sleep(for: .seconds(0.8))
                    onConnected()
                } catch {
                    phase = .failed
                    status = error.localizedDescription
                }
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return NSImage()
        }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: Pairing code

private struct CodePairingPane: View {
    @Environment(DeviceManager.self) private var dm
    let onConnected: () -> Void

    @State private var address = ""
    @State private var code = ""
    @State private var discovered: [MDNSService] = []
    @State private var phase: PairPhase?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Steps(steps: [
                "On your phone: Developer options › Wireless debugging › “Pair device with pairing code”",
                "Enter the IP address & port and the 6-digit code it shows",
            ])
            if !discovered.isEmpty {
                HStack {
                    Text("Found:").foregroundStyle(.secondary)
                    ForEach(discovered, id: \.self) { service in
                        Button(service.address) { address = service.address }
                    }
                }
            }
            Form {
                TextField("IP address & port", text: $address, prompt: Text("192.168.1.20:37099"))
                TextField("Pairing code", text: $code, prompt: Text("123456"))
            }
            .formStyle(.grouped)
            .frame(height: 120)
            HStack {
                Button("Pair & Connect") { Task { await pair() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty || code.count < 6 || phase == .working)
                if let phase { StatusLine(phase: phase, text: status) }
            }
        }
        .task {
            while !Task.isCancelled {
                let found = await dm.mdnsServices().filter(\.isPairing)
                if found != discovered { discovered = found }
                if address.isEmpty, let first = found.first { address = first.address }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func pair() async {
        let target = address.trimmingCharacters(in: .whitespaces)
        phase = .working
        status = "Pairing…"
        do {
            try await dm.pair(address: target, code: code.trimmingCharacters(in: .whitespaces))
            status = "Paired! Connecting…"
            try await dm.connectAfterPairing(host: String(target.split(separator: ":").first ?? ""))
            phase = .done
            status = "Connected"
            try? await Task.sleep(for: .seconds(0.8))
            onConnected()
        } catch {
            phase = .failed
            status = error.localizedDescription
        }
    }
}

// MARK: USB → Wi-Fi

private struct CablePane: View {
    @Environment(DeviceManager.self) private var dm
    let onConnected: () -> Void
    @State private var phase: PairPhase?
    @State private var status = ""

    private var usbDevices: [Device] { dm.devices.filter { !$0.isWireless && $0.state == .device } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Works on any Android version. Plug the phone in once, switch it to Wi-Fi, then unplug the cable. The phone forgets this mode when it restarts. Your phone still has to approve this Mac, but avoid using this mode on public Wi-Fi.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if usbDevices.isEmpty {
                ContentUnavailableView("No phone plugged in", systemImage: "cable.connector",
                                       description: Text("Connect your phone with a USB cable and allow USB debugging."))
            } else {
                ForEach(usbDevices) { device in
                    HStack {
                        Image(systemName: "iphone.gen3")
                        VStack(alignment: .leading) {
                            Text(dm.displayName(for: device))
                            Text(dm.info[device.serial]?.wifiIP.map { "Wi-Fi IP \($0)" } ?? "Not on Wi-Fi")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch to Wi-Fi") { Task { await switchDevice(device) } }
                            .disabled(phase == .working)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let phase { StatusLine(phase: phase, text: status) }
        }
    }

    private func switchDevice(_ device: Device) async {
        phase = .working
        status = "Switching to Wi-Fi…"
        do {
            try await dm.switchToWiFi(device)
            phase = .done
            status = "Connected over Wi-Fi. You can unplug the cable now."
            try? await Task.sleep(for: .seconds(1.5))
            onConnected()
        } catch {
            phase = .failed
            status = error.localizedDescription
        }
    }
}

// MARK: Manual

private struct ManualPane: View {
    @Environment(DeviceManager.self) private var dm
    let onConnected: () -> Void
    @State private var address = ""
    @State private var phase: PairPhase?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For a phone you've already paired: enter the IP address & port shown at the top of its Wireless debugging screen.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack {
                TextField("IP address & port", text: $address, prompt: Text("192.168.1.20:41235"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect(address) } }
                Button("Connect") { Task { await connect(address) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(address.isEmpty || phase == .working)
            }
            if !dm.recentAddresses.isEmpty {
                Text("Recent").font(.headline)
                ForEach(dm.recentAddresses, id: \.self) { recent in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(recent).monospacedDigit()
                        Spacer()
                        Button("Reconnect") { Task { await connect(recent) } }
                    }
                }
            }
            if let phase { StatusLine(phase: phase, text: status) }
        }
    }

    private func connect(_ target: String) async {
        let target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        phase = .working
        status = "Connecting to \(target)…"
        do {
            try await dm.connect(target.contains(":") ? target : target + ":5555")
            phase = .done
            status = "Connected"
            try? await Task.sleep(for: .seconds(0.8))
            onConnected()
        } catch {
            phase = .failed
            status = error.localizedDescription
        }
    }
}
