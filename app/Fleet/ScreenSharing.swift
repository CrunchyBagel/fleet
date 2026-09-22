import Foundation
import Network

/// Screen Sharing to another Mac: over its own network when it answers there
/// (faster than the tailnet hop), and High Performance only when that can be
/// smooth. Everything it needs comes from `hosts info` (`lan_name`, `lan_ip`,
/// `lan_link`, `chip`), plus one TCP probe.
enum ScreenSharing {
    enum Mode { case highPerformance, standard }
    struct Target: Equatable {
        let address: String
        let mode: Mode
    }

    /// The vnc:// URL for Screen Sharing.app. The query is the app's own
    /// .vncloc format: it writes `?quality=adaptive&numVirtualDisplays=0` for
    /// a Standard session and `quality=high` for High Performance, so passing
    /// them presets the mode instead of asking. Addresses pass `valid_host`
    /// or come from `lan_info`, so URLComponents has nothing to reject.
    static func url(_ t: Target) -> URL? {
        var c = URLComponents()
        c.scheme = "vnc"
        c.host = t.address
        c.queryItems = [URLQueryItem(name: "quality", value: t.mode == .highPerformance ? "high" : "adaptive"),
                        URLQueryItem(name: "numVirtualDisplays", value: "0")]
        return c.url
    }

    /// Where to connect and how. The LAN name and IP are probed together on
    /// the Screen Sharing port; the name wins when both answer. High
    /// Performance needs the LAN to have answered, ethernet on both ends
    /// (a `lan_link` of "wifi" or unknown says no) and Apple silicon on both.
    static func plan(host: String, remote: HostInfo?, me: HostInfo?,
                     probe: @escaping @Sendable (String) async -> Bool = { await reachable($0) }) async -> Target {
        var address = host
        var onLAN = false
        let candidates = [remote?.lanName, remote?.lanIp].compactMap { $0 }.filter { !$0.isEmpty }
        if !candidates.isEmpty {
            let answers = await withTaskGroup(of: (Int, Bool).self, returning: [Bool].self) { group in
                for (i, a) in candidates.enumerated() { group.addTask { (i, await probe(a)) } }
                var out = Array(repeating: false, count: candidates.count)
                for await (i, ok) in group { out[i] = ok }
                return out
            }
            if let i = answers.firstIndex(of: true) { address = candidates[i]; onLAN = true }
        }
        let wired = onLAN && remote?.lanLink == "ethernet" && me?.lanLink == "ethernet"
        let silicon = (remote?.chip.hasPrefix("Apple") ?? false) && (me?.chip.hasPrefix("Apple") ?? false)
        return Target(address: address, mode: wired && silicon ? .highPerformance : .standard)
    }

    /// One TCP connect to the Screen Sharing port, cut off after `timeout`.
    /// A `.local` name resolves only on the same link, so this also says
    /// "same network"; an unresolvable name parks the connection in
    /// `.waiting`, which counts as no.
    static func reachable(_ host: String, port: UInt16 = 5900, timeout: Double = 1.5) async -> Bool {
        await withCheckedContinuation { cont in
            let q = DispatchQueue(label: "fleet.screensharing.probe")   // handler and timer share it: no race on `done`
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var done = false
            let finish: (Bool) -> Void = { ok in
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
