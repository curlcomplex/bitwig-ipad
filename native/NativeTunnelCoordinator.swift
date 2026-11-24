import Foundation
import NetworkExtension

@MainActor enum NativeTunnelCoordinator {
    static let consentCode = 1
    private static var manager: NETunnelProviderManager?
    private static var timer: Timer?
    private static var providerID: String { Bundle.main.bundleIdentifier! + ".tunnel" }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "BitwigLocalTunnel", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // An interrupted launch can leave a connected provider with a stale route.
    // Reconnect the already-authorized profile; never create or change a profile.
    static func reconnect(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let selected=manager else {ensureReady(allowConfiguration:false,completion:completion);return}
        selected.connection.stopVPNTunnel()
        let deadline=Date().addingTimeInterval(10)
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true){_ in
            MainActor.assumeIsolated {
                if selected.connection.status == .disconnected || selected.connection.status == .invalid {
                    timer?.invalidate();timer=nil;connect(selected,completion:completion)
                } else if Date()>deadline {
                    timer?.invalidate();timer=nil;completion(.failure(error(4,"The local developer tunnel did not disconnect for recovery.")))
                }
            }
        }
    }

    // Saving a new profile is permitted only by the app's explicit setup button.
    static func ensureReady(allowConfiguration: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, loadError in
            Task { @MainActor in
                if let loadError { completion(.failure(loadError)); return }
                let existing = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
                }
                guard let selected = existing, selected.isEnabled else {
                    guard allowConfiguration else {
                        completion(.failure(error(consentCode,
                            "Enable Bitwig’s local developer tunnel to prepare Java execution. It connects only to this iPad; no separate VPN app or remote server is used.")))
                        return
                    }
                    let selected = existing ?? NETunnelProviderManager()
                    let configuration = NETunnelProviderProtocol()
                    configuration.providerBundleIdentifier = providerID
                    configuration.serverAddress = "On-device only"
                    configuration.includeAllNetworks = false
                    selected.protocolConfiguration = configuration
                    selected.localizedDescription = "Bitwig Local Developer Tunnel"
                    selected.isEnabled = true
                    selected.saveToPreferences { saveError in
                        Task { @MainActor in
                            if let saveError { completion(.failure(saveError)); return }
                            selected.loadFromPreferences { reloadError in
                                Task { @MainActor in
                                    if let reloadError { completion(.failure(reloadError)); return }
                                    connect(selected, completion: completion)
                                }
                            }
                        }
                    }
                    return
                }
                connect(selected, completion: completion)
            }
        }
    }

    private static func connect(_ selected: NETunnelProviderManager, completion: @escaping (Result<Void, Error>) -> Void) {
        manager = selected
        if selected.connection.status == .connected { captureDiagnostics(selected);completion(.success(())); return }
        do { try selected.connection.startVPNTunnel() }
        catch { completion(.failure(error)); return }
        let deadline = Date().addingTimeInterval(30)
        var connecting = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let connectionStatus = selected.connection.status
                switch connectionStatus {
                case .connected:
                    timer?.invalidate(); timer = nil; captureDiagnostics(selected);completion(.success(()))
                case .connecting, .reasserting:
                    connecting = true
                case .invalid, .disconnected:
                    guard connectionStatus == .invalid || connecting else { break }
                    timer?.invalidate(); timer = nil
                    completion(.failure(error(2, "Bitwig’s local developer tunnel disconnected during startup.")))
                default: break
                }
                if timer != nil && Date() > deadline {
                    timer?.invalidate(); timer = nil
                    completion(.failure(error(3, "Bitwig’s local developer tunnel did not connect within 30 seconds.")))
                }
            }
        }
    }

    private static func captureDiagnostics(_ selected: NETunnelProviderManager) {
        for delay in [0.0, 5.0, 20.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let session = selected.connection as? NETunnelProviderSession else { return }
                try? session.sendProviderMessage(Data("status".utf8)) { data in
                    guard let data else { return }
                    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? data.write(to: documents.appendingPathComponent("native-tunnel.json"), options: .atomic)
                }
            }
        }
    }
}
