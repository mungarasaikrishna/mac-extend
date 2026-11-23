import CoreMedia
import CryptoKit
import Foundation
import Network
import DisplayBridge

func pairedTLSParameters(key: SymmetricKey) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    ConfigurePairedTLS(tls.securityProtocolOptions, key.withUnsafeBytes { Data($0) })
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
}

private final class TransportProbe {
    private let queue = DispatchQueue(label: "iMacExtendedDisplay.TransportProbe")
    private let finished = DispatchSemaphore(value: 0)
    private let listener: NWListener
    private let clientKey: SymmetricKey
    private let payload: Data
    private var client: NWConnection?
    private var server: NWConnection?
    private var result: Result<Int, Error>?

    init(serverKey: SymmetricKey, clientKey: SymmetricKey, payload: Data) throws {
        let parameters = pairedTLSParameters(key: serverKey)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.clientKey = clientKey
        self.payload = payload
    }

    func run() throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.connect(port: port) }
            case .failed(let error):
                self.complete(.failure(error))
            default:
                break
            }
        }
        listener.start(queue: queue)

        let wait = finished.wait(timeout: .now() + 8)
        return try queue.sync {
            defer {
                listener.cancel()
                client?.cancel()
                server?.cancel()
            }
            guard wait == .success, let result else {
                throw TransportProbeError.timedOut
            }
            return try result.get()
        }
    }

    private func connect(port: NWEndpoint.Port) {
        let connection = NWConnection(host: "127.0.0.1", port: port,
                                      using: pairedTLSParameters(key: clientKey))
        client = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.send(content: self.payload, completion: .contentProcessed { error in
                    if let error { self.complete(.failure(error)) }
                })
            case .failed(let error), .waiting(let error):
                self.complete(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard server == nil else {
            connection.cancel()
            return
        }
        server = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.receive(minimumIncompleteLength: self.payload.count,
                                   maximumLength: self.payload.count) { data, _, _, error in
                    if let error {
                        self.complete(.failure(error))
                    } else if data == self.payload {
                        self.complete(.success(self.payload.count))
                    } else {
                        self.complete(.failure(TransportProbeError.invalidPayload))
                    }
                }
            case .failed(let error):
                self.complete(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func complete(_ result: Result<Int, Error>) {
        guard self.result == nil else { return }
        self.result = result
        finished.signal()
    }
}

private enum TransportProbeError: LocalizedError {
    case timedOut
    case invalidPayload
    case wrongKeyAccepted

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The local TLS check timed out."
        case .invalidPayload: return "The local TLS listener received an unexpected payload."
        case .wrongKeyAccepted: return "TLS accepted a client with the wrong pairing key."
        }
    }
}

func checkTransport(resolution: VideoResolution) throws {
    let sample = try makeEncodedTestFrame(resolution: resolution)
    guard let block = CMSampleBufferGetDataBuffer(sample) else { throw EncoderProbeError.noOutput }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { throw EncoderProbeError.noOutput }
    var payload = Data(count: length)
    try requireSuccess(payload.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        guard let destination = buffer.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                          destination: destination)
    }, "Copy compressed payload")

    let pairingKey = SymmetricKey(size: .bits256)
    let bytes = try TransportProbe(serverKey: pairingKey, clientKey: pairingKey, payload: payload).run()
    print("Paired TLS transferred and verified \(bytes) H.264 bytes over loopback.")

    do {
        _ = try TransportProbe(serverKey: pairingKey, clientKey: SymmetricKey(size: .bits256),
                               payload: payload).run()
    } catch let error as NWError {
        guard case .tls = error else { throw error }
        print("TLS rejected the mismatched pairing key.")
        return
    }
    throw TransportProbeError.wrongKeyAccepted
}
