import Foundation
import CryptoKit
import Citadel
import NIOSSH
import NIOCore

/// Runs `fleet` on a Mac over ssh. One connection per host, reopened when it
/// drops. Commands are built the way the CLI builds them for remotes: the
/// PATH that ssh's non-interactive shell lacks is set first, and every
/// argument is single-quoted for the remote shell.
actor SSHRunner {
    struct RemoteError: LocalizedError {
        let host: String, message: String
        var errorDescription: String? { "\(host): \(message)" }
    }
    struct HostKeyChanged: LocalizedError {
        let host: String
        var errorDescription: String? { "\(host): its ssh host key changed. If you reinstalled macOS there, forget the pinned key in Settings; otherwise do not connect." }
    }
    /// The two failures a phone actually hits, said plainly.
    struct Unreachable: LocalizedError {
        let host: String, underlying: String
        var errorDescription: String? { "Could not reach \(host). Is Tailscale on this phone connected, and is \"\(host)\" the Mac's tailnet name with Remote Login on? (\(underlying))" }
    }
    struct NotAuthorized: LocalizedError {
        let host: String, username: String
        var errorDescription: String? { "\(host) does not accept this phone's key for \"\(username)\". On any Mac, run the fleet keys add command shown in Settings, and check the username." }
    }

    private var clients: [String: SSHClient] = [:]
    let username: String
    init(username: String) { self.username = username }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func fleet(_ args: [String]) -> String {
        "export PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" FLEET_NO_SPINNER=1; \"$HOME/bin/fleet\" "
            + args.map(shq).joined(separator: " ")
    }

    /// `fleet <args>` on `host`; stdout, or stdout+stderr when `tolerate`
    /// (doctor-style commands exit 1 to mean "something to fix").
    func fleet(on host: String, _ args: [String], tolerate: Bool = false, timeout: Duration = .seconds(20)) async throws -> String {
        try await run(on: host, SSHRunner.fleet(args), tolerate: tolerate, timeout: timeout)
    }

    func run(on host: String, _ command: String, tolerate: Bool = false, timeout: Duration = .seconds(20)) async throws -> String {
        let client = try await connection(to: host)
        do {
            return try await withTimeout(timeout, host: host) {
                try await SSHRunner.exec(client, command, tolerate: tolerate, host: host)
            }
        } catch let e as RemoteError {
            throw e
        } catch {
            // Anything else is the connection: drop it so the next call reconnects.
            clients[host] = nil
            try? await client.close()
            throw error
        }
    }

    private static func exec(_ client: SSHClient, _ command: String, tolerate: Bool, host: String) async throws -> String {
        var out = "", err = ""
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let b): out += String(buffer: b)
                case .stderr(let b): err += String(buffer: b)
                }
            }
        } catch is SSHClient.CommandFailed {
            if tolerate { return out + err }
            throw RemoteError(host: host, message: err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "command failed" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// Connect with the phone's key. Trust on first use: the first connection
    /// accepts the host's key and pins its Ed25519 host key line; later ones
    /// require that key.
    private func connection(to host: String) async throws -> SSHClient {
        if let c = clients[host], c.isConnected { return c }
        let key = try KeyStore.privateKey()
        let auth = SSHAuthenticationMethod.ed25519(username: username, privateKey: key)
        let validator: SSHHostKeyValidator
        if let pinned = HostKeys.pinned(host) {
            validator = .trustedKeys([try NIOSSHPublicKey(openSSHPublicKey: pinned)])
        } else {
            validator = .acceptAnything()
        }
        let client: SSHClient
        do {
            client = try await SSHClient.connect(host: host, port: 22, authenticationMethod: auth, hostKeyValidator: validator,
                                                 reconnect: .never, connectTimeout: .seconds(6))
        } catch SSHClientError.allAuthenticationOptionsFailed {
            throw NotAuthorized(host: host, username: username)
        } catch {
            if HostKeys.pinned(host) != nil, "\(error)".lowercased().contains("host key") { throw HostKeyChanged(host: host) }
            let text = "\(error)".replacingOccurrences(of: "NIOPosix.", with: "").replacingOccurrences(of: "NIOCore.", with: "")
            throw Unreachable(host: host, underlying: String(text.prefix(80)))
        }
        if HostKeys.pinned(host) == nil {
            let line = try await SSHRunner.exec(client, "cat /etc/ssh/ssh_host_ed25519_key.pub", tolerate: true, host: host)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ssh-ed25519 ") { HostKeys.pin(host, line) }
        }
        clients[host] = client
        return client
    }

    func disconnectAll() async {
        for (_, c) in clients { try? await c.close() }
        clients = [:]
    }

    private func withTimeout<T: Sendable>(_ d: Duration, host: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: d); throw RemoteError(host: host, message: "no answer in \(d.components.seconds)s") }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }
}
