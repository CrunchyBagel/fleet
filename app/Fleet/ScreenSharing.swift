import Foundation
import Network

/// Screen Sharing to another Mac: over its own network when it answers there
/// (faster than the tailnet hop), High Performance only when that can be
/// smooth, and Full Quality whenever the LAN answered. Everything it needs comes from `hosts info` (`lan_name`, `lan_ip`,
/// `lan_link`, `chip`), plus one TCP probe.
enum ScreenSharing {
    /// High Performance, else Standard at Full or Adaptive Quality (the
    /// View menu's choice; Adaptive trades sharpness for a thin link).
    enum Mode { case highPerformance, full, adaptive }
    struct Target: Equatable {
        let address: String
        let mode: Mode
    }

    /// The vnc:// URL for Screen Sharing.app. The query is the app's own
    /// .vncloc format (`?quality=high&numVirtualDisplays=<n>`, or
    /// `?quality=full|adaptive&numVirtualDisplays=0` for Standard), so passing
    /// it presets the mode instead of asking. High needs a count of at least
    /// 1: with 0, or with the key left out, Screen Sharing logs "pro mode with
    /// no virtual displays - gets standard mode" and does exactly that (seen
    /// in its log both ways); with 1 it logs "promode 1" and configures the
    /// virtual display on the server. One display is its own default; two is
    /// a View-menu choice the owner can still make. Addresses pass
    /// `valid_host` or come from `lan_info`, so URLComponents has nothing to reject.
    static func url(_ t: Target) -> URL? {
        var c = URLComponents()
        c.scheme = "vnc"
        c.host = t.address
        switch t.mode {
        case .highPerformance:
            c.queryItems = [URLQueryItem(name: "quality", value: "high"),
                            URLQueryItem(name: "numVirtualDisplays", value: "1")]
        case .full, .adaptive:
            c.queryItems = [URLQueryItem(name: "quality", value: t.mode == .full ? "full" : "adaptive"),
                            URLQueryItem(name: "numVirtualDisplays", value: "0")]
        }
        return c.url
    }

    /// Where to connect and how. The LAN name and IP are probed together on
    /// the Screen Sharing port; the IP wins when both answer, because a
    /// `.local` name makes Screen Sharing resolve over mDNS and try Kerberos
    /// on every link-local IPv6 address first (a minute, seen). High
    /// Performance needs the LAN to have answered, ethernet on both ends
    /// (a `lan_link` of "wifi" or unknown says no) and Apple silicon on both;
    /// otherwise the LAN gets Full Quality and the tailnet Adaptive.
    static func plan(host: String, remote: HostInfo?, me: HostInfo?,
                     probe: @escaping @Sendable (String) async -> Bool = { await reachable($0) }) async -> Target {
        var address = host
        var onLAN = false
        let candidates = [remote?.lanIp, remote?.lanName].compactMap { $0 }.filter { !$0.isEmpty }
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
        return Target(address: address, mode: wired && silicon ? .highPerformance : onLAN ? .full : .adaptive)
    }

    /// Touch the local network once, at launch, so macOS settles Local Network
    /// access then and not on the first Screen Sharing click. The probe below
    /// fails at once while that is pending (the connection parks in `.waiting`
    /// with "Local network prohibited") and the click falls back to the
    /// tailnet name: on a fresh Mac, where the prompt comes up too late to
    /// answer, and after every rebuild, where the new binary's UUID makes the
    /// system re-check an existing Allow (a few ms, still too late). A TCP
    /// connect to a link-local address is local network use by definition
    /// and needs no LAN address, which the app does not have yet at launch;
    /// nobody answers, and it is dropped after a moment. (A Bonjour browse
    /// for `_rfb._tcp` was tried first: it does not go through the check.)
    static func requestLocalNetworkAccess() {
        let conn = NWConnection(host: "169.254.1.1", port: 5900, using: .tcp)
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: DispatchQueue(label: "fleet.screensharing.localnetwork"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { conn.cancel() }
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
