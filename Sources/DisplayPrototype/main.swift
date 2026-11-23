import CoreGraphics
import CryptoKit
import Dispatch
import DisplayBridge
import Foundation

func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return condition()
}

func isListedOnline(_ id: CGDirectDisplayID) -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return true }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return true }
    return displays.prefix(Int(count)).contains(id)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EXIT_FAILURE)
}

if Bundle.main.bundleURL.pathExtension == "app" {
    setlinebuf(stdout)
    if CommandLine.arguments.count == 1 {
        runDesktopApp()
        exit(EXIT_SUCCESS)
    }
}
if CommandLine.arguments.dropFirst().elementsEqual(["--check-app-ui"]) {
    runDesktopApp(check: true)
    exit(EXIT_SUCCESS)
}

private enum TextSize: String {
    case standard
    case large
    case extraLarge = "extra-large"

    func dimensions(for resolution: VideoResolution) -> (width: UInt32, height: UInt32, hiDPI: Bool) {
        switch self {
        case .standard:
            if resolution == .native4K { return (2048, 1152, true) }
            return (2560, 1440, false)
        case .large: return (1920, 1080, true)
        case .extraLarge: return (1600, 900, true)
        }
    }
}

private func takeOption(_ name: String, from arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index > 0, arguments.indices.contains(index + 1),
          !arguments[(index + 1)...].contains(name) else {
        fail("Provide one value for \(name).")
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

var commandArguments = Array(CommandLine.arguments.dropFirst())
private var textSize = TextSize.standard
if let value = takeOption("--text-size", from: &commandArguments) {
    guard let requested = TextSize(rawValue: value),
          ["--send", "--send-listen", "--check", "--check-capture", "--check-capture-encode", "--check-stream"]
            .contains(commandArguments[0]) else {
        fail("Append --text-size standard|large|extra-large to a sender or display check command.")
    }
    textSize = requested
}

var resolution = VideoResolution.standard
if let value = takeOption("--resolution", from: &commandArguments) {
    guard let requested = VideoResolution(rawValue: value),
          ["--send", "--send-listen", "--check", "--check-capture", "--check-capture-encode", "--check-stream",
           "--check-transport", "--check-codec", "--check-encoder", "--check-playback"].contains(commandArguments[0]) else {
        fail("Append --resolution 1440p|4k to a sender or video check command.")
    }
    resolution = requested
}
let arguments = commandArguments
if arguments == ["--check-pairing"] {
    do {
        try checkPairing()
        exit(EXIT_SUCCESS)
    } catch {
        fail(error.localizedDescription)
    }
}
if arguments == ["--make-key"] {
    let key = SymmetricKey(size: .bits256)
    print(key.withUnsafeBytes { Data($0).base64EncodedString() })
    exit(EXIT_SUCCESS)
}

if arguments.first == "--bridge-address" {
    guard arguments.count <= 2 else { fail("Usage: display-prototype --bridge-address [bridge-interface]") }
    do {
        print(try ThunderboltPeer.localAddress(on: arguments.dropFirst().first ?? "bridge0"))
        exit(EXIT_SUCCESS)
    } catch {
        fail(error.localizedDescription)
    }
}

let sendListening = arguments.first == "--send-listen"
let receiveConnecting = arguments.first == "--receive-connect"
let sending = arguments.first == "--send" || sendListening
let receiving = arguments.first == "--receive" || receiveConnecting
let checkingLink = arguments.first == "--check-link"
var wiredLink: WiredLink?
if sending || receiving || checkingLink {
    guard arguments.count == 4 else {
        fail("Usage: display-prototype --send|--send-listen|--receive|--receive-connect|--check-link <bridge-interface> <peer-ipv4> <pairing-file>")
    }
    do {
        let peer = (sendListening || receiveConnecting) && arguments[2] == "auto" ? nil : arguments[2]
        let link = try WiredLink(interfaceName: arguments[1], peerAddress: peer, keyFile: arguments[3])
        if receiving {
            try runReceiver(link, connect: receiveConnecting)
            exit(EXIT_SUCCESS)
        }
        if checkingLink {
            print("Checking \(link.peerDescription):\(WiredLink.port.rawValue) from \(link.local)%\(link.interface.name)…")
            fflush(stdout)
            let connection = try link.makeConnection()
            try connection.start()
            connection.cancel()
            print("Thunderbolt TCP and TLS pairing passed.")
            exit(EXIT_SUCCESS)
        }
        wiredLink = link
    } catch {
        fail(error.localizedDescription)
    }
}
if arguments == ["--check-playback"] {
    if #available(macOS 14.4, *) {
        do {
            try checkPlayback(resolution: resolution)
            exit(EXIT_SUCCESS)
        } catch {
            fail(error.localizedDescription)
        }
    }
    fail("The playback diagnostic requires macOS 14.4 or later.")
}
if arguments == ["--check-transport"] {
    do {
        try checkTransport(resolution: resolution)
        try checkWiredVideoLoopback(resolution: resolution)
        exit(EXIT_SUCCESS)
    } catch {
        fail(error.localizedDescription)
    }
}
let roundTripRequested = arguments == ["--check-codec"]
if arguments == ["--check-encoder"] || roundTripRequested {
    do {
        try checkEncoder(resolution: resolution, roundTrip: roundTripRequested)
        exit(EXIT_SUCCESS)
    } catch {
        fail(error.localizedDescription)
    }
}
let encodeCapturedFrame = arguments == ["--check-capture-encode"]
let streamRequested = arguments == ["--check-stream"] || sending
let captureRequested = arguments == ["--check-capture"] || encodeCapturedFrame || streamRequested
guard arguments.isEmpty || arguments == ["--check"] || captureRequested else {
    fail("Usage: display-prototype [--check | --check-capture | --check-encoder | --check-capture-encode | --check-stream | --check-codec | --check-transport | --check-pairing | --check-playback | --make-key | --bridge-address] or --send|--send-listen|--receive|--receive-connect|--check-link <bridge-interface> <peer-ipv4> <pairing-file>")
}

@MainActor
final class CaptureResult {
    var result: Result<String, Error>?
}

var captureFailure: String?

do {
    let dimensions = textSize.dimensions(for: resolution)
    let hiDPI = dimensions.hiDPI
    let streamWidth = resolution.width
    let streamHeight = resolution.height
    let session = try autoreleasepool {
        try VirtualDisplaySession.start(withWidth: dimensions.width, height: dimensions.height, hiDPI: hiDPI)
    }
    let id = session.displayID
    guard waitUntil(timeout: 5, condition: { CGDisplayIsActive(id) != 0 }),
          let mode = CGDisplayCopyDisplayMode(id),
          mode.width == Int(dimensions.width), mode.height == Int(dimensions.height),
          mode.pixelWidth == Int(dimensions.width) * (hiDPI ? 2 : 1),
          mode.pixelHeight == Int(dimensions.height) * (hiDPI ? 2 : 1),
          CGDisplayIsInMirrorSet(id) == 0, id != CGMainDisplayID() else {
        session.stop()
        fail("macOS did not expose the requested virtual mode as an active extended desktop.")
    }

    guard abs(mode.refreshRate - 60) < 0.1 else {
        session.stop()
        fail("The virtual display reported an unexpected refresh rate: \(mode.refreshRate) Hz.")
    }

    print("Active extended display \(id): \(mode.pixelWidth) × \(mode.pixelHeight) pixels")
    print("Reported refresh rate: \(mode.refreshRate) Hz")
    if hiDPI {
        print("Text size: \(textSize.rawValue), looks like \(mode.width) × \(mode.height); video stream \(streamWidth) × \(streamHeight).")
    }
    if captureRequested {
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated {
                let state = CaptureResult()
                let task = Task { @MainActor in
                    do {
                        if streamRequested {
                            state.result = .success(try await checkStream(
                                displayID: id, width: streamWidth, height: streamHeight, link: wiredLink,
                                listen: sendListening
                            ))
                        } else {
                            state.result = .success(try await checkCapture(
                                displayID: id, width: streamWidth, height: streamHeight,
                                encode: encodeCapturedFrame
                            ))
                        }
                    } catch is CancellationError {
                        state.result = .success("Streaming stopped.")
                    } catch {
                        state.result = .failure(error)
                    }
                }

                let interrupt: DispatchSourceSignal?
                if sending {
                    signal(SIGINT, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
                    source.setEventHandler { task.cancel() }
                    source.resume()
                    interrupt = source
                } else {
                    interrupt = nil
                }
                defer { interrupt?.cancel() }

                if waitUntil(timeout: sending ? .infinity : 45, condition: { state.result != nil }) {
                    switch state.result {
                    case .success(let message):
                        print(message)
                    case .failure(let error):
                        captureFailure = error.localizedDescription
                    case nil:
                        break
                    }
                } else {
                    task.cancel()
                    captureFailure = "Timed out waiting for the capture check."
                }
            }
        } else {
            captureFailure = "The sender capture check requires macOS 14 or later."
        }
    } else if arguments.isEmpty {
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
        interrupt.resume()
        print("Open System Settings > Displays to inspect the arrangement. Press Control-C to stop.")
        fflush(stdout)
        CFRunLoopRun()
        interrupt.cancel()
    }

    session.stop()
    guard waitUntil(timeout: 5, condition: { !isListedOnline(id) }) else {
        fail("macOS still reports the virtual display online after releasing it.")
    }
    print("Virtual display removed.")
    if let captureFailure { fail(captureFailure) }
} catch {
    fail(error.localizedDescription)
}
