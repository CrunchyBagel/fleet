import Foundation
import CryptoKit
import Security

/// The phone's own ssh identity: one Ed25519 key, generated here, kept in
/// the Keychain, never leaving the device. Its public half is what
/// `fleet keys add` puts into authorized_keys on every Mac.
enum KeyStore {
    private static let service = "com.crunchybagel.fleet.ssh"
    private static let account = "ed25519"

    /// The private key, created on first use.
    static func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = read() { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.Signing.PrivateKey()
        try write(key.rawRepresentation)
        return key
    }
    static var hasKey: Bool { read() != nil }

    /// "ssh-ed25519 AAAA… fleet-<device>": the OpenSSH public key line.
    static func publicKeyLine() throws -> String {
        let key = try privateKey()
        var wire = Data()
        func str(_ d: Data) { var n = UInt32(d.count).bigEndian; wire.append(Data(bytes: &n, count: 4)); wire.append(d) }
        str(Data("ssh-ed25519".utf8))
        str(key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(wire.base64EncodedString()) \(comment)"
    }
    /// The key's comment: what `fleet keys rm` revokes by.
    static var comment: String {
        let raw = UIDeviceName.current.lowercased()
        let safe = raw.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "fleet-" + String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func read() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    private static func write(_ data: Data) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemDelete(q as CFDictionary)
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
}

/// Pinned host keys: trust on first use, then the same key or nothing.
/// Not secret (they are the hosts' public keys), so UserDefaults.
enum HostKeys {
    private static let key = "hostKeys"
    static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func pinned(_ host: String) -> String? { all[host] }
    static func pin(_ host: String, _ line: String) { var a = all; a[host] = line; all = a }
    static func forget(_ host: String) { var a = all; a[host] = nil; all = a }
    static func forgetAll() { all = [:] }
}

import UIKit
enum UIDeviceName { static var current: String { UIDevice.current.name } }
