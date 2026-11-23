import CryptoKit
import Foundation
import Network

private enum PairingError: LocalizedError {
    case invalidExchange
    case declined

    var errorDescription: String? {
        switch self {
        case .invalidExchange:
            return "The pairing messages did not match. Start pairing again on both Macs."
        case .declined:
            return "Pairing canceled. No pairing was saved."
        }
    }
}

enum PairingRole: UInt8 {
    case macBook = 1
    case iMac = 2

    var peer: Self { self == .macBook ? .iMac : .macBook }
}

private struct PairingHandshake {
    static let revealLength = 64
    private static let domain = Data("Mac Extend pairing v1".utf8)
    private let role: PairingRole
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    init(role: PairingRole) { self.role = role }

    var reveal: Data { privateKey.publicKey.rawRepresentation + nonce }
    var commitment: Data { Self.commitment(role: role, reveal: reveal) }

    private static func commitment(role: PairingRole, reveal: Data) -> Data {
        Data(SHA256.hash(data: domain + Data([role.rawValue]) + reveal))
    }

    func derive(peerCommitment: Data, peerReveal: Data) throws -> PairingSecrets {
        guard peerReveal.count == Self.revealLength,
              peerCommitment == Self.commitment(role: role.peer, reveal: peerReveal) else {
            throw PairingError.invalidExchange
        }

        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerReveal.prefix(32))
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let transcript = role == .macBook ? reveal + peerReveal : peerReveal + reveal
        let salt = Data(SHA256.hash(data: Self.domain + transcript))

        func deriveKey(_ label: String, bytes: Int = 32) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Self.domain + Data(label.utf8), outputByteCount: bytes)
        }

        // The separate display code is short for humans. The session key remains 256 bits.
        let codeNumber = deriveKey("display code", bytes: 4).withUnsafeBytes { bytes in
            bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return PairingSecrets(code: String(format: "%06u", codeNumber % 1_000_000),
                              key: deriveKey("video TLS key"), confirmation: deriveKey("confirmation"))
    }
}

private struct PairingSecrets {
    let code: String
    let key: SymmetricKey
    let confirmation: SymmetricKey

    private func message(_ role: PairingRole) -> Data {
        Data("Mac Extend pairing v1 approved".utf8) + Data([role.rawValue])
    }

    func approval(for role: PairingRole) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(role), using: confirmation))
    }

    func verifyApproval(_ bytes: Data, from role: PairingRole) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: message(role), using: confirmation)
    }
}

private func beginPairing(_ connection: PeerConnection, role: PairingRole) throws -> PairingSecrets {
    try connection.start(operation: "connecting for pairing")
    let handshake = PairingHandshake(role: role)
    // Both sides commit before either reveals its public key and nonce.
    try connection.send(handshake.commitment, operation: "sending a pairing commitment")
    let commitment = try connection.receive(exactly: 32, seconds: 10, operation: "receiving a pairing commitment")
    try connection.send(handshake.reveal, operation: "sending pairing details")
    let reveal = try connection.receive(exactly: PairingHandshake.revealLength, seconds: 10,
                                        operation: "receiving pairing details")
    return try handshake.derive(peerCommitment: commitment, peerReveal: reveal)
}

private func finishPairing(_ connection: PeerConnection, role: PairingRole,
                           secrets: PairingSecrets) throws -> Data {
    try connection.send(secrets.approval(for: role), operation: "sending pairing approval")
    let peerApproval = try connection.receive(exactly: 32, seconds: 90,
                                              operation: "waiting for approval on the other Mac")
    guard secrets.verifyApproval(peerApproval, from: role.peer) else { throw PairingError.invalidExchange }
    return secrets.key.withUnsafeBytes { Data($0) }
}

final class MacPairingAttempt {
    private static let port = NWEndpoint.Port(rawValue: 49173)!
    private let endpoint: ThunderboltPeer
    private let role: PairingRole
    private let lock = NSLock()
    private var isCanceled = false
    private var cancellation: (() -> Void)?

    init(endpoint: ThunderboltPeer, role: PairingRole) {
        self.endpoint = endpoint
        self.role = role
    }

    func cancel() {
        lock.lock()
        isCanceled = true
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    private func onCancel(_ action: @escaping () -> Void) throws {
        lock.lock()
        let canceled = isCanceled
        if !canceled { cancellation = action }
        lock.unlock()
        if canceled {
            action()
            throw CancellationError()
        }
    }

    func run(ready: @escaping () -> Void, confirm: @escaping (String) async -> Bool) async throws -> Data {
        defer { cancel() }
        let (connection, secrets) = try await Task.detached(priority: .userInitiated) {
            let connection = try self.connect(ready: ready)
            try self.onCancel { connection.cancel() }
            let secrets = try beginPairing(connection, role: self.role)
            return (connection, secrets)
        }.value

        guard await confirm(secrets.code) else { throw PairingError.declined }
        return try await Task.detached(priority: .userInitiated) {
            try finishPairing(connection, role: self.role, secrets: secrets)
        }.value
    }

    private func connect(ready: @escaping () -> Void) throws -> PeerConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if role == .iMac {
            let remote = try endpoint.remoteEndpoint(port: Self.port, discovery: .pairing, onCancel: onCancel)
            return PeerConnection(NWConnection(to: remote,
                                               using: endpoint.bind(parameters)))
        }
        let listener = try NWListener(using: endpoint.bind(parameters, port: Self.port))
        if endpoint.peer == nil { listener.service = ThunderboltDiscovery.pairing.service }
        defer { listener.cancel() }
        let accepted = NetworkResult<NWConnection>()
        listener.newConnectionHandler = { connection in
            if !self.endpoint.matchesPeer(connection.endpoint) || !accepted.complete(.success(connection)) {
                connection.cancel()
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready()
            case .failed(let error), .waiting(let error): accepted.complete(.failure(error))
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "MacExtend.PairingListener"))
        try onCancel {
            accepted.complete(.failure(CancellationError()))
            listener.cancel()
        }
        return try PeerConnection(accepted.wait(seconds: 90, operation: "waiting for the iMac to pair"))
    }
}

func checkPairing() throws {
    let macBook = PairingHandshake(role: .macBook)
    let iMac = PairingHandshake(role: .iMac)
    let a = try macBook.derive(peerCommitment: iMac.commitment, peerReveal: iMac.reveal)
    let b = try iMac.derive(peerCommitment: macBook.commitment, peerReveal: macBook.reveal)
    guard a.code == b.code, a.code.count == 6, a.key == b.key,
          a.verifyApproval(b.approval(for: .iMac), from: .iMac),
          !a.verifyApproval(a.approval(for: .macBook), from: .iMac) else {
        throw PairingError.invalidExchange
    }

    var mutatedReveal = iMac.reveal
    mutatedReveal[32] ^= 1
    do {
        _ = try macBook.derive(peerCommitment: iMac.commitment, peerReveal: mutatedReveal)
        throw WiredLinkError.configuration("A changed pairing reveal was accepted.")
    } catch PairingError.invalidExchange {}

    let impostor = PairingHandshake(role: .iMac)
    let c = try impostor.derive(peerCommitment: macBook.commitment, peerReveal: macBook.reveal)
    guard !a.verifyApproval(c.approval(for: .iMac), from: .iMac) else {
        throw PairingError.invalidExchange
    }
    print("Pairing derives the same code and key on both peers and rejects altered reveals and invalid approvals.")
    try checkPairingLoopback()
}

private func checkPairingLoopback() throws {
    let listenerParameters = NWParameters.tcp
    listenerParameters.requiredInterfaceType = .loopback
    listenerParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: listenerParameters)
    defer {
        listener.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    let serverResult = NetworkResult<(code: String, key: Data)>()
    listener.newConnectionHandler = { incoming in
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = PeerConnection(incoming)
            defer { connection.cancel() }
            serverResult.complete(Result {
                let secrets = try beginPairing(connection, role: .macBook)
                return try (secrets.code, finishPairing(connection, role: .macBook, secrets: secrets))
            })
        }
    }
    let port: NWEndpoint.Port = try awaitNetwork("starting the pairing test", seconds: 5) { finish in
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { finish(.success(port)) }
            case .waiting(let error), .failed(let error): finish(.failure(error))
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "MacExtend.PairingTest"))
    }

    let clientParameters = NWParameters.tcp
    clientParameters.requiredInterfaceType = .loopback
    let client = PeerConnection(NWConnection(host: "127.0.0.1", port: port, using: clientParameters))
    defer { client.cancel() }
    let secrets = try beginPairing(client, role: .iMac)
    let key = try finishPairing(client, role: .iMac, secrets: secrets)
    let other = try serverResult.wait(seconds: 5, operation: "checking the paired key")
    guard secrets.code == other.code, key == other.key else { throw PairingError.invalidExchange }
    print("Both loopback peers confirmed the displayed code and derived the same key.")
    try checkWiredVideoLoopback(resolution: .standard, key: SymmetricKey(data: key))
}
