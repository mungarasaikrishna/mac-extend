import AppKit
import CoreGraphics
import CryptoKit
import Network

private final class DesktopApp: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 550),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
    )
    private let role = NSPopUpButton()
    private let address = NSTextField()
    private let addressLabel = NSTextField(labelWithString: "")
    private let addressRow = NSStackView()
    private let manualAddress = NSButton(checkboxWithTitle: "Enter Thunderbolt address manually", target: nil, action: nil)
    private let localAddress = NSTextField(labelWithString: "")
    private let spacing = NSPopUpButton()
    private let sizeRow = NSStackView()
    private let resolutionChoice = NSPopUpButton()
    private let resolutionRow = NSStackView()
    private let pairButton = NSButton()
    private let pairStatus = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton()
    private let recordingButton = NSButton()
    private let recordingStatus = NSTextField(labelWithString: "")
    private var resettingRecording = false
    private weak var recordingRow: NSStackView?
    private let importButton = NSButton()
    private let exportButton = NSButton()
    private var pairing: MacPairingAttempt?
    private var cancelingPairing = false
    private var worker: Process?
    private var workerPipe: Pipe?
    private var stopping = false
    private var pendingOutput = Data()
    private var reportedProblem: String?

    private var isSender: Bool { role.indexOfSelectedItem == 0 }
    private var addressPreference: String { isSender ? "iMacAddress" : "MacBookAddress" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Mac Extend"
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(labelWithString: "Mac Extend")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.textColor = .secondaryLabelColor
        role.addItems(withTitles: ["MacBook · Share my display", "iMac · Show the extended display"])
        #if arch(x86_64)
        let receiverDefault = true
        #else
        let receiverDefault = false
        #endif
        let receiverRole = UserDefaults.standard.object(forKey: "receiverRole") as? Bool ?? receiverDefault
        role.selectItem(at: receiverRole ? 1 : 0)
        role.target = self
        role.action = #selector(changeRole)

        manualAddress.target = self
        manualAddress.action = #selector(refreshConnection)
        addressRow.orientation = .horizontal
        addressRow.spacing = 10
        addressRow.addArrangedSubview(addressLabel)
        addressRow.addArrangedSubview(address)
        address.placeholderString = "169.254.x.x"
        address.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        address.delegate = self
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        localAddress.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshConnection))

        spacing.addItems(withTitles: ["Standard", "Large", "Extra large"])
        spacing.selectItem(at: min(2, max(0, UserDefaults.standard.integer(forKey: "textSize"))))
        spacing.target = self
        spacing.action = #selector(changeSize)
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 12
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Text size"))
        sizeRow.addArrangedSubview(spacing)

        resolutionChoice.addItems(withTitles: VideoResolution.allCases.map(\.title))
        let savedResolution = UserDefaults.standard.string(forKey: "videoResolution")
        let selectedResolution = savedResolution.flatMap(VideoResolution.init(rawValue:)) ?? .standard
        resolutionChoice.selectItem(withTitle: selectedResolution.title)
        resolutionChoice.target = self
        resolutionChoice.action = #selector(changeResolution)
        resolutionRow.orientation = .horizontal
        resolutionRow.spacing = 12
        resolutionRow.addArrangedSubview(NSTextField(labelWithString: "Resolution"))
        resolutionRow.addArrangedSubview(resolutionChoice)

        pairButton.title = "Pair Macs…"
        pairButton.target = self
        pairButton.action = #selector(togglePairing)
        importButton.title = "Import Pairing File…"
        importButton.target = self
        importButton.action = #selector(importKey)
        exportButton.title = "Export Pairing File…"
        exportButton.target = self
        exportButton.action = #selector(exportKey)
        recordingButton.title = "Screen Recording…"
        recordingButton.target = self
        recordingButton.action = #selector(showRecordingOptions)
        recordingStatus.textColor = .secondaryLabelColor
        let recordingRow = row([recordingButton, recordingStatus])
        recordingRow.setAccessibilityIdentifier("ScreenRecordingControls")
        action.target = self
        action.action = #selector(toggleConnection)
        action.keyEquivalent = "\r"
        status.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        let pairing = row([pairStatus, pairButton])
        let pairingFiles = row([importButton, exportButton])
        let panel = NSStackView(views: [
            row([title, versionLabel]), row([NSTextField(labelWithString: "This Mac"), role]),
            row([localAddress, refresh]), manualAddress, addressRow, sizeRow, resolutionRow,
            separator, pairing, pairingFiles, recordingRow, status, action
        ])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 15
        panel.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            status.widthAnchor.constraint(equalTo: panel.widthAnchor),
            separator.widthAnchor.constraint(equalTo: panel.widthAnchor)
        ])
        window.contentView = content
        self.recordingRow = recordingRow
        changeRole()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private var bridge: (String, IPv4Address)? {
        if let preferred = try? ThunderboltPeer.localAddress(on: "bridge0") {
            return ("bridge0", preferred)
        }
        guard let interfaces = if_nameindex() else { return nil }
        defer { if_freenameindex(interfaces) }
        var current = interfaces
        while current.pointee.if_index != 0, let namePointer = current.pointee.if_name {
            let name = String(cString: namePointer)
            if name.hasPrefix("bridge"), let ip = try? ThunderboltPeer.localAddress(on: name) {
                return (name, ip)
            }
            current += 1
        }
        return nil
    }

    private func storedKey() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("iMac Extended Display", isDirectory: true)
        return directory.appendingPathComponent("pairing.key")
    }

    private func readKey(_ url: URL) throws -> Data {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Data(base64Encoded: text), key.count == 32 else {
            throw WiredLinkError.configuration("This is not a valid pairing file.")
        }
        return key
    }

    private func writeKey(_ key: Data, to url: URL) throws {
        try Data((key.base64EncodedString() + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveKey(_ key: Data) throws -> URL {
        let url = try storedKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writeKey(key, to: url)
        return url
    }

    private func availableKey() -> URL? {
        if let stored = try? storedKey(), (try? readKey(stored)) != nil { return stored }
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("pairing.key")
        if (try? readKey(adjacent)) != nil { return adjacent }
        return nil
    }

    private func senderKey() throws -> URL {
        if let existing = availableKey() { return existing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try saveKey(key)
    }

    @objc private func changeRole() {
        UserDefaults.standard.set(!isSender, forKey: "receiverRole")
        addressLabel.stringValue = isSender ? "iMac IP address" : "MacBook IP address"
        address.stringValue = UserDefaults.standard.string(forKey: addressPreference) ?? ""
        sizeRow.isHidden = !isSender
        resolutionRow.isHidden = !isSender
        status.stringValue = isSender
            ? "Start sharing here first, then connect on the iMac."
            : "Start sharing on the MacBook, then click Connect here."
        refreshConnection()
    }

    @objc private func changeSize() {
        UserDefaults.standard.set(spacing.indexOfSelectedItem, forKey: "textSize")
    }

    @objc private func changeResolution() {
        let resolution = VideoResolution.allCases[resolutionChoice.indexOfSelectedItem]
        UserDefaults.standard.set(resolution.rawValue, forKey: "videoResolution")
    }

    @objc private func refreshConnection() {
        localAddress.stringValue = bridge.map { "Your Thunderbolt IP  \($0.1)" } ?? "Thunderbolt IP unavailable"
        let hasKey = availableKey() != nil
        let idle = worker == nil && pairing == nil && !resettingRecording
        pairStatus.stringValue = hasKey ? "Pairing saved" : "Pairing needed"
        pairButton.title = pairing == nil ? "Pair Macs…" : "Cancel Pairing"
        pairButton.isEnabled = worker == nil && !cancelingPairing && !resettingRecording
        role.isEnabled = idle
        spacing.isEnabled = idle
        resolutionChoice.isEnabled = idle
        manualAddress.isEnabled = idle
        addressRow.isHidden = manualAddress.state != .on
        address.isEnabled = idle
        importButton.isEnabled = idle
        exportButton.isEnabled = idle && (isSender || hasKey)
        action.title = worker == nil ? (isSender ? "Start Sharing" : "Connect") : "Stop"
        action.isEnabled = !stopping && pairing == nil && !resettingRecording
        recordingRow?.isHidden = !isSender
        recordingButton.isEnabled = idle
        refreshRecordingStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshRecordingStatus()
    }

    private func refreshRecordingStatus() {
        guard isSender else { return }
        recordingStatus.stringValue = CGPreflightScreenCaptureAccess() ? "Access enabled" : "Access needed"
    }

    @objc private func showRecordingOptions() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording"
        alert.informativeText = "Enable Mac Extend in System Settings. If access is already enabled but sharing still asks for it after an update, reset Mac Extend’s permission, reopen this copy, and enable it again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Reset Mac Extend Permission")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.openRecordingSettings()
            case .alertSecondButtonReturn:
                self?.resetRecordingPermission()
            default:
                break
            }
        }
    }

    private func openRecordingSettings() {
        if !CGPreflightScreenCaptureAccess(), CGRequestScreenCaptureAccess() {
            refreshRecordingStatus()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        status.stringValue = "Enable Mac Extend in Screen & System Audio Recording, then quit and reopen this copy."
    }

    private func resetRecordingPermission() {
        guard isSender, worker == nil, pairing == nil, !resettingRecording,
              let identifier = Bundle.main.bundleIdentifier else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", identifier]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        reset.terminationHandler = { [weak self] process in
            let success = process.terminationReason == .exit && process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.resettingRecording = false
                self.refreshConnection()
                if success { self.recordingStatus.stringValue = "Reopen to grant access" }
                self.status.stringValue = success
                    ? "Permission reset. Quit and reopen this copy, then click Start Sharing to grant access again."
                    : "macOS could not reset access. Open Screen Recording settings to manage Mac Extend’s permission."
            }
        }
        do {
            try reset.run()
            resettingRecording = true
            status.stringValue = "Resetting Mac Extend’s Screen Recording permission…"
            refreshConnection()
        } catch {
            status.stringValue = "Could not start the permission reset. Open Screen Recording settings to manage access."
        }
    }

    @objc private func togglePairing() {
        if let pairing {
            cancelingPairing = true
            pairing.cancel()
            status.stringValue = "Canceling pairing…"
            refreshConnection()
            return
        }
        guard let (interface, peer) = connectionSettings() else { return }

        do {
            let endpoint = try ThunderboltPeer(interfaceName: interface, peerAddress: peer)
            let attempt = MacPairingAttempt(endpoint: endpoint, role: isSender ? .macBook : .iMac)
            pairing = attempt
            status.stringValue = isSender ? "Opening pairing on the MacBook…" : "Connecting to the MacBook for pairing…"
            refreshConnection()
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.pairing = nil
                    self.cancelingPairing = false
                    self.refreshConnection()
                }
                do {
                    let key = try await attempt.run(ready: { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.pairing === attempt else { return }
                            self.status.stringValue = "Ready. Click Pair Macs on the iMac."
                        }
                    }, confirm: { [weak self] code in
                        await self?.confirmPairing(code) ?? false
                    })
                    if self.cancelingPairing { throw CancellationError() }
                    _ = try self.saveKey(key)
                    self.status.stringValue = self.isSender
                        ? "Paired. Click Start Sharing here, then Connect on the iMac."
                        : "Paired. Once the MacBook starts sharing, click Connect."
                } catch is CancellationError {
                    self.status.stringValue = "Pairing canceled. No pairing was saved."
                } catch {
                    self.status.stringValue = self.cancelingPairing
                        ? "Pairing canceled. No pairing was saved." : error.localizedDescription
                }
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @MainActor
    private func confirmPairing(_ code: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = code
        alert.informativeText = "Compare this code on both Macs. Confirm on both only if the codes match. This saves the new pairing on this Mac."
        let matches = alert.addButton(withTitle: "Codes Match")
        matches.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let result = await alert.beginSheetModal(for: window)
        if result == .alertFirstButtonReturn {
            status.stringValue = "Waiting for confirmation on the other Mac…"
            return true
        }
        return false
    }

    @objc private func importKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the pairing file exported from the MacBook."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                _ = try self.saveKey(self.readKey(url))
                self.refreshConnection()
            } catch {
                self.status.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func exportKey() {
        do {
            let source: URL
            if isSender {
                source = try senderKey()
            } else {
                guard let existing = availableKey() else { return }
                source = existing
            }
            let key = try readKey(source)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "pairing.key"
            panel.message = "Copy this file privately to the iMac and import it there."
            panel.beginSheetModal(for: window) { [weak self] result in
                guard let self, result == .OK, let url = panel.url else { return }
                do {
                    try self.writeKey(key, to: url)
                    self.status.stringValue = "Pairing file saved. Import it in the app on the iMac."
                    self.refreshConnection()
                } catch {
                    self.status.stringValue = error.localizedDescription
                }
            }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func toggleConnection() {
        if let worker {
            stopping = true
            worker.interrupt()
            refreshConnection()
            status.stringValue = "Stopping…"
            return
        }
        guard let (interface, peer) = connectionSettings() else { return }
        guard let key = availableKey() else {
            status.stringValue = "Click Pair Macs on both computers first."
            return
        }
        if isSender, !CGPreflightScreenCaptureAccess() {
            openRecordingSettings()
            guard CGPreflightScreenCaptureAccess() else { return }
        }
        do {
            try launchWorker(interface: interface, peer: peer, key: key)
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    private func connectionSettings() -> (interface: String, peer: String?)? {
        window.makeFirstResponder(nil)
        guard let (interface, local) = bridge else {
            status.stringValue = "Connect the Thunderbolt cable, then click Refresh."
            return nil
        }
        guard manualAddress.state == .on else { return (interface, nil) }
        let peer = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = IPv4Address(peer), ip.rawValue.prefix(2).elementsEqual([169, 254]) else {
            status.stringValue = "Enter the other Mac’s Thunderbolt IP. It starts with 169.254."
            return nil
        }
        guard ip != local else {
            status.stringValue = "Enter the other Mac’s IP. You entered this Mac’s address."
            return nil
        }
        UserDefaults.standard.set(peer, forKey: addressPreference)
        return (interface, peer)
    }

    private func launchWorker(interface: String, peer: String?, key: URL) throws {
        let task = Process()
        task.executableURL = Bundle.main.executableURL
        task.arguments = [isSender ? "--send-listen" : "--receive-connect", interface, peer ?? "auto", key.path]
        if isSender {
            let resolution = VideoResolution.allCases[resolutionChoice.indexOfSelectedItem]
            let textSize = ["standard", "large", "extra-large"][spacing.indexOfSelectedItem]
            task.arguments?.append(contentsOf: ["--text-size", textSize, "--resolution", resolution.rawValue])
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pendingOutput.removeAll(keepingCapacity: true)
        reportedProblem = nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, let task, self.worker === task else { return }
                self.consumeOutput(data)
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            DispatchQueue.main.async {
                guard let self, let task, self.worker === task else { return }
                self.workerPipe?.fileHandleForReading.readabilityHandler = nil
                if let leftover = try? self.workerPipe?.fileHandleForReading.readToEnd() {
                    self.consumeOutput(leftover)
                }
                let stopped = self.stopping || task.terminationStatus == 0
                self.worker = nil
                self.workerPipe = nil
                self.stopping = false
                self.status.stringValue = stopped ? "Disconnected." : (self.reportedProblem ?? "Connection ended. Check both Macs and try again.")
                self.refreshConnection()
            }
        }
        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        worker = task
        workerPipe = pipe
        status.stringValue = isSender ? "Starting the extended display…"
            : (peer == nil ? "Finding the MacBook on Thunderbolt…" : "Connecting to the MacBook…")
        refreshConnection()
    }

    private func consumeOutput(_ data: Data) {
        pendingOutput.append(data)
        while let end = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<end], as: UTF8.self)
            pendingOutput.removeSubrange(...end)
            if line.hasPrefix("Listening on") {
                status.stringValue = "Ready. Click Connect on the iMac."
            } else if line.hasPrefix("Connected.") || line.hasPrefix("Encrypted connection ready.") {
                status.stringValue = "Connected."
            } else if line.hasPrefix("Video: "), !stopping {
                status.stringValue = line
            } else if line.contains("Screen Recording permission") {
                reportedProblem = "Open Screen Recording in Mac Extend to grant access or reset a stale permission."
            } else if line.hasPrefix("Timed out") {
                reportedProblem = line.contains("Start sharing") ? line
                    : "Connection timed out. Check the Thunderbolt cable and start sharing on the MacBook first."
            } else if line.contains("Restart the receiver") || line.hasSuffix("failed.") {
                reportedProblem = line
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        pairing?.cancel()
        worker?.interrupt()
    }
}

func runDesktopApp(check: Bool = false) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = DesktopApp()
    application.delegate = delegate
    if check {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard application.windows.contains(where: { $0.title == "Mac Extend" && $0.isVisible }) else {
                fail("The desktop app did not open its connection window.")
            }
            print("The desktop app opened its connection window.")
            exit(EXIT_SUCCESS)
        }
    }
    application.run()
    withExtendedLifetime(delegate) {}
}
