// Local loopback packet swapping is based on LocalDevVPN by Stossy11 and
// the SideStore Team. See LocalDevVPN-LICENSE.txt bundled with this app.
import NetworkExtension

final class BitwigTunnelProvider: NEPacketTunnelProvider {
    private var stopping = false
    private let statsLock = NSLock()
    private var received = 0
    private var written = 0
    private var writeFailures = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        stopping = false
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.7.1.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { error in
            if error == nil { self.readPackets() }
            completionHandler(error)
        }
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, !self.stopping else { return }
            var reflected: [Data] = []
            var families: [NSNumber] = []
            for (index, original) in packets.enumerated() {
                guard protocols[index].int32Value == AF_INET, original.count >= 20,
                      original[0] >> 4 == 4 else { continue }
                var packet = original
                let source = Array(packet[12..<16])
                let destination = Array(packet[16..<20])
                packet.replaceSubrange(12..<16, with: destination)
                packet.replaceSubrange(16..<20, with: source)
                // Swapping endpoints preserves the IPv4 and TCP/UDP checksum sums.
                reflected.append(packet)
                families.append(protocols[index])
            }
            let accepted = self.packetFlow.writePackets(reflected, withProtocols: families)
            self.statsLock.lock()
            self.received += packets.count
            if accepted { self.written += reflected.count } else { self.writeFailures += 1 }
            self.statsLock.unlock()
            self.readPackets()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        statsLock.lock()
        let counts = ["packetsReceived": received, "packetsWritten": written, "writeFailures": writeFailures]
        statsLock.unlock()
        completionHandler?(try? JSONSerialization.data(withJSONObject: counts))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopping = true
        completionHandler()
    }
}
