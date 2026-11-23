import AppKit
import AVFoundation
import CoreMedia
import Network

private final class ReceiverWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        if styleMask.contains(.fullScreen) {
            toggleFullScreen(nil)
        } else {
            performClose(nil)
        }
    }
}

private final class ReceiverController: NSObject, NSWindowDelegate {
    private let window: ReceiverWindow
    private let video = AVSampleBufferDisplayLayer()
    private let status = NSTextField(labelWithString: "Starting Thunderbolt listener…")
    private let listener: NWListener?
    private let link: WiredLink
    private let queue = DispatchQueue(label: "iMacExtendedDisplay.Receiver")
    private var active: PeerConnection?

    init(link: WiredLink, connect: Bool) throws {
        self.link = link
        listener = connect ? nil : try NWListener(using: link.parameters(listening: true))
        guard let screen = NSScreen.main else {
            throw WiredLinkError.configuration("No iMac screen is available.")
        }

        let frame = NSRect(x: 0, y: 0, width: min(820, screen.visibleFrame.width),
                           height: min(460, screen.visibleFrame.height))
        window = ReceiverWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false, screen: screen)
        super.init()
        window.title = "Mac Extend"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.center()
        window.delegate = self

        let canvas = NSView(frame: frame)
        canvas.wantsLayer = true
        video.frame = canvas.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        video.videoGravity = .resizeAspect
        canvas.layer?.addSublayer(video)
        status.textColor = .white
        status.font = .systemFont(ofSize: 20)
        status.alignment = .center
        status.maximumNumberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -16)
        ])
        window.contentView = canvas
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.stop(nil)
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let listener else {
            showStatus(link.endpoint.peer == nil ? "Finding the MacBook on Thunderbolt…" : "Connecting to \(link.peerDescription)…")
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    self.handle(try self.link.makeConnection())
                } catch {
                    let message = "\(error.localizedDescription) Start sharing on the MacBook and try again."
                    fail(message)
                }
            }
            return
        }
        listener.newConnectionHandler = { [weak self] incoming in
            guard let self else {
                incoming.cancel()
                return
            }
            guard self.link.matchesPeer(incoming.endpoint) else {
                let message = "Rejected \(incoming.endpoint). Expected MacBook at \(self.link.peerDescription)."
                DispatchQueue.main.async { self.showStatus(message) }
                incoming.cancel()
                return
            }
            self.handle(PeerConnection(incoming))
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let message: String
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                message = "Listening on \(self.link.local):\(port). Waiting for MacBook Pro…"
            case .waiting(let error):
                message = "Thunderbolt listener waiting: \(error.localizedDescription)"
            case .failed(let error):
                message = "Thunderbolt listener failed: \(error.localizedDescription)"
            default:
                return
            }
            DispatchQueue.main.async { self.showStatus(message) }
        }
        listener.start(queue: queue)
    }

    // Called on the receiver network queue.
    private func handle(_ connection: PeerConnection) {
        guard active == nil else {
            connection.cancel()
            return
        }
        active = connection
        DispatchQueue.main.async { self.showStatus("Checking the pairing key…") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let message: String
            do {
                try connection.start()
                DispatchQueue.main.async { self.showStatus("Encrypted connection ready. Waiting for video…") }
                try self.receive(connection)
                message = "Connection ended."
            } catch {
                message = error.localizedDescription
            }
            connection.cancel()
            DispatchQueue.main.async {
                self.video.flushAndRemoveImage()
                let next = self.listener == nil ? "Restart the receiver to reconnect." : "Waiting for MacBook Pro…"
                self.showStatus("\(message)  \(next)")
                self.queue.async { self.active = nil }
            }
        }
    }

    private func showStatus(_ message: String) {
        status.stringValue = message
        status.isHidden = false
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func receive(_ connection: PeerConnection) throws {
        var sequence: Int64 = 0
        while true {
            let sample = try VideoWire.unpack(connection.receiveFrame(), sequence: sequence)
            let firstFrame = sequence == 0
            sequence += 1
            VideoWire.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while true {
                let presented = try DispatchQueue.main.sync {
                    if video.status == .failed {
                        throw video.error ?? VideoWireError.invalidFrame
                    }
                    guard video.isReadyForMoreMediaData else { return false }
                    video.enqueue(sample)
                    status.isHidden = true
                    if firstFrame, window.isKeyWindow, !window.styleMask.contains(.fullScreen) {
                        window.toggleFullScreen(nil)
                    }
                    return true
                }
                if presented { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw WiredLinkError.timeout("waiting for the iMac display")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() {
        listener?.cancel()
        queue.sync { active?.cancel() }
        window.orderOut(nil)
    }
}

func runReceiver(_ link: WiredLink, connect: Bool) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let receiver = try ReceiverController(link: link, connect: connect)
    receiver.start()
    app.run()
    receiver.stop()
}

@available(macOS 14.4, *)
func checkPlayback(resolution: VideoResolution) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let frame = NSRect(x: 0, y: 0, width: 384, height: 216)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Mac Extend playback check"
    window.isReleasedWhenClosed = false
    window.center()
    let canvas = NSView(frame: frame)
    canvas.wantsLayer = true
    window.contentView = canvas
    let video = AVSampleBufferDisplayLayer()
    video.frame = canvas.bounds
    video.videoGravity = .resizeAspect
    canvas.layer?.addSublayer(video)
    window.orderFrontRegardless()
    defer { window.close() }

    let sample = try VideoWire.unpack(VideoWire.pack(makeEncodedTestFrame(resolution: resolution)), sequence: 0)
    VideoWire.setAttachment(kCMSampleAttachmentKey_DisplayImmediately, on: sample)
    video.enqueue(sample)
    _ = waitUntil(timeout: 5) { video.isReadyForDisplay || video.status == .failed }
    guard video.isReadyForDisplay else {
        throw video.error ?? WiredLinkError.timeout("rendering the test frame")
    }
    print("The receiver’s playback layer prepared a \(resolution.width) × \(resolution.height) H.264 frame for display.")
}
