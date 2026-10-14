import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaSwiftPluginStore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import _CryptoExtras

/// Trust rules for self-update. The server only ever replaces its program with a file that
///  1. is a GitHub release asset of SirStig/NovaSwift (tag `server-v<version>`),
///  2. is named in `server-update.json`, whose RSA signature (`server-update.json.sig`, made with the same key that
///     signs the game's updates: scripts/release-sign.sh) verifies against the public key built into this program, and
///  3. matches the size and SHA-256 recorded in that signed manifest.
/// An unsigned or mis-signed release is refused, never installed "just this once".
public enum ServerUpdateTrust {
    /// The game updater's public key (godot/updater/update_pubkey.pem). Keep equal; a test checks it.
    public static let publicKeyPEM = """
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsxd+RqoocTHT5QSLrR3b
7shSVvFq+dTNEBG3i1TLDZi88nLHOFzjkH6SEwQzXO8+7Gw1mdda62tONrsTTBGR
aGHxsyqN1ZhgCsDPfSU3ZP9vF40qNIUT9U+UZqyDz3zaewzCGjKqKaWffdGfMaIM
7G/hqUmktETckYuq+DxB9OTkqLHHnet5Tty/1x7Ks346CIDc2t+k6yMJ1WjKfGfz
ummEQCJ5vxGR7QLdjRA3jkahOsdcCmaVC+mbEYtm8dq7elOc+5/G9zKuQwubYa99
FQBEOJ+6OHHvV8A4XlWRSkbHGlibeatNKAHI0gUDKBcIFv0A+Iu+8hUtNWeiy8uR
N0S6ANpnI0mm3J0MvikqgYhaW0ITJNB2PJXc+/aSgiMVcoOsh2pqH226dwkXqPAD
Te4xG05ElJc9nUxJrVjCV+weqx2tureZoLGaJcXbZjfpu7upAGDezIaavozMJzPG
20tC82X0LkE4ePkD1e6eOBsv9fVkxRzNvXAujLPg/furmsuBsGzRXPVKzmNUuAk5
Sa9OKQkFyrry+EPHfbsJulsA5bo1YRTDVctgdf3iaCUowYtJQ6mBDPs+0cGl33eB
x0PUhioQ/sZlrBFjpsrdKew7aOJtFbF+uQeBiHJ4OZK+DQwVWAoPA7+atejV6Szq
6wJxmz2+XgbZTiNvvv8j3L8CAwEAAQ==
-----END PUBLIC KEY-----
"""
    public static let manifestAsset = "server-update.json"
    public static let signatureAsset = "server-update.json.sig"
    public static let maxManifestBytes = 64 * 1024
    public static let maxArchiveBytes: Int64 = 200 * 1_000_000

    public struct AssetInfo: Equatable { public var asset: String; public var size: Int64; public var sha256: String }
    public struct Manifest: Equatable {
        public var version: String
        public var platforms: [String: AssetInfo]
    }

    /// RSA PKCS#1 v1.5 + SHA-256 over the exact bytes of the manifest (what `openssl dgst -sha256 -sign` produces).
    public static func verify(manifest: Data, signature: Data, publicKeyPEM pem: String = ServerUpdateTrust.publicKeyPEM) -> Bool {
        guard manifest.count <= maxManifestBytes, signature.count >= 128, signature.count <= 1024,
              let key = try? _RSA.Signing.PublicKey(pemRepresentation: pem) else { return false }
        return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: manifest, padding: .insecurePKCS1v1_5)
    }

    public static func parse(_ data: Data) -> Manifest? {
        guard data.count <= maxManifestBytes, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = o["version"] as? String, !version.isEmpty, version.count <= 32,
              let platforms = o["platforms"] as? [String: Any] else { return nil }
        var out: [String: AssetInfo] = [:]
        for (k, v) in platforms {
            guard let d = v as? [String: Any], let asset = d["asset"] as? String, let sha = d["sha256"] as? String,
                  let size = (d["size"] as? NSNumber)?.int64Value, size > 0,
                  sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { continue }
            out[k] = AssetInfo(asset: asset, size: size, sha256: sha.lowercased())
        }
        return Manifest(version: version, platforms: out)
    }

    /// Only https://github.com/SirStig/NovaSwift/releases/download/server-v<version>/<file> (GitHub then redirects to its
    /// CDN; the signature and checksum, not the host, are what make the bytes trustworthy).
    public static func isTrustedAssetURL(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", u.host == "github.com" else { return false }
        let p = u.path
        return p.hasPrefix("/SirStig/NovaSwift/releases/download/\(ServerVersion.tagPrefix)") && !p.contains("..") && u.query == nil
    }
}
