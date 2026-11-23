import CryptoKit
import Foundation
import Network

struct ThunderboltDiscovery {
    static let pairing = Self(type: "_macext-pair._tcp")
    let type: String
    let token: String?

    init(type: String, key: SymmetricKey? = nil) {
        self.type = type
        token = key.map {
            HMAC<SHA256>.authenticationCode(for: Data("Mac Extend discovery v1".utf8), using: $0)
                .prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    var service: NWListener.Service {
        var record = NWTXTRecord()
        if let token { record["pair"] = token }
        return NWListener.Service(name: nil, type: type, txtRecord: record)
    }

    func find(on interface: NWInterface, onCancel: ((@escaping () -> Void) throws -> Void)?) throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.requiredInterface = interface
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: parameters)
        let found = NetworkResult<NWEndpoint>()
        defer { browser.cancel() }
        browser.browseResultsChangedHandler = { results, _ in
            let matches = results.filter { result in
                guard result.interfaces.contains(where: { $0.index == interface.index }) else { return false }
                guard let token else { return true }
                guard case .bonjour(let record) = result.metadata else { return false }
                return record["pair"] == token
            }
            if matches.count == 1, let match = matches.first { found.complete(.success(match.endpoint)) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { found.complete(.failure(error)) }
        }
        browser.start(queue: DispatchQueue(label: "MacExtend.Discovery"))
        try onCancel? {
            found.complete(.failure(CancellationError()))
            browser.cancel()
        }
        return try found.wait(seconds: 15, operation: "finding the MacBook on Thunderbolt")
    }
}

extension ThunderboltPeer {
    func remoteEndpoint(port: NWEndpoint.Port, discovery: ThunderboltDiscovery,
                        onCancel: ((@escaping () -> Void) throws -> Void)? = nil) throws -> NWEndpoint {
        if let peer { return .hostPort(host: .ipv4(peer), port: port) }
        return try discovery.find(on: interface, onCancel: onCancel)
    }
}
