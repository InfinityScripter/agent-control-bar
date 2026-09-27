import CryptoKit
import Foundation

/// The prebuilt half of a GitHub release: the DMG the one-click update installs, and the two
/// numbers that prove a download is the file the release advertised.
///
/// Releases are ad-hoc signed — there is no Developer ID to verify against. The size and the
/// sha256 digest the releases API returns for each asset come over the same TLS connection as
/// the download would, so they are the check that a truncated, cached or swapped file never
/// gets mounted — not a defence against whoever controls the release itself. That defence is
/// the Ed25519 signature below: made in the Release workflow with a key that lives only in the
/// repository's secrets, checked here against the public half compiled into this binary.
enum UpdateFeed {
    /// Base64 of the raw 32-byte Ed25519 public key the one-click update requires a DMG to be
    /// signed with (tools/update-signing/sign.js; the private half is the UPDATE_SIGNING_KEY
    /// repository secret). Empty means signing is not set up yet: the DMG still has to match
    /// the advertised digest, but nothing proves the maintainer made it — and the Release
    /// workflow refuses to publish without a signature once this is filled in.
    static let signingKey = ""
    static var signingEnforced: Bool { !signingKey.isEmpty }

    struct ReleaseAsset: Equatable {
        let url: URL
        let size: Int
        /// Lowercase hex, without the `sha256:` prefix. dmgAsset() no longer offers an asset
        /// without one; nil survives only in a stored asset, and verify() refuses it.
        let sha256: String?
        /// The `<dmg>.sig` asset published next to the image, when the release carries one.
        var signatureURL: URL? = nil

        /// The shape the daily check keeps in UserDefaults next to `latestVersion`.
        var dictionary: [String: Any] {
            var d: [String: Any] = ["url": url.absoluteString, "size": size]
            if let sha256 { d["sha256"] = sha256 }
            if let signatureURL { d["signature"] = signatureURL.absoluteString }
            return d
        }

    }

    /// Where a release asset may be downloaded from: GitHub's own release-download route over
    /// https. The URL arrives inside the API answer, and without this a tampered answer could
    /// point the update at any host at all. (GitHub then redirects to its asset CDN; the digest
    /// and the signature, not the redirect target, are what vouch for the bytes.)
    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.path.contains("/releases/download/")
    }

    /// The first `.dmg` among a release's assets that comes from GitHub and carries a size and
    /// a sha256 digest. A size-less or digest-less entry is refused: the digest is what tells
    /// the advertised file from a cut-off or swapped one, and an update that cannot check it
    /// is not installed — the menu falls back to the release page instead.
    static func dmgAsset(in release: [String: Any]) -> ReleaseAsset? {
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        let byName: [String: URL] = Dictionary(assets.compactMap { a -> (String, URL)? in
            guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String,
                  let url = URL(string: s), isTrustedDownload(url) else { return nil }
            return (name, url)
        }, uniquingKeysWith: { first, _ in first })
        for a in assets {
            guard let name = a["name"] as? String, name.hasSuffix(".dmg"),
                  let url = byName[name],
                  let size = (a["size"] as? NSNumber)?.intValue, size > 0 else { continue }
            let digest = (a["digest"] as? String) ?? ""
            guard digest.hasPrefix("sha256:") else { continue }
            let sha = String(digest.dropFirst(7)).lowercased()
            guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { continue }
            return ReleaseAsset(url: url, size: size, sha256: sha, signatureURL: byName[name + ".sig"])
        }
        return nil
    }

    /// Why a releases/latest request named no release, in words for the About page.
    ///
    /// GitHub refuses in JSON too, so a missing `tag_name` alone would hide the reason. The one
    /// refusal worth its own words is the rate limit: 60 unauthenticated requests an hour per
    /// address, which a shared office network spends without this app. Its message is replaced
    /// rather than shown, because it carries the address GitHub saw, and this text is selectable
    /// for pasting into a bug report.
    static func checkProblem(status: Int, answer: [String: Any]?, error: Error?) -> String {
        if let error { return "No answer from GitHub: \(error.localizedDescription)" }
        let message = (answer?["message"] as? String) ?? ""
        if message.localizedCaseInsensitiveContains("rate limit") {
            return "GitHub allows 60 checks an hour from one network, and this one has used them up. "
                + "Try again later."
        }
        return message.isEmpty ? "GitHub answered \(status) without a release in it"
                               : "GitHub answered \(status): \(message)"
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// nil when the file is the asset; otherwise the reason it is not. Size first — one stat,
    /// and a mismatch there means the download is not worth reading, let alone hashing.
    static func verify(file: URL, against asset: ReleaseAsset) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        else { return "unreadable download" }
        if size != asset.size { return "size \(size), release says \(asset.size)" }
        guard let want = asset.sha256 else { return "the release advertises no sha256 for this file" }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "unreadable download" }
        let got = sha256Hex(of: data)
        if got != want { return "sha256 \(got), release says \(want)" }
        return nil
    }

    /// nil when `signature` (base64, as the `.sig` asset carries it) is a valid Ed25519
    /// signature of the file by `publicKey` (base64 of the raw 32 bytes); otherwise why not.
    static func verifySignature(file: URL, signature: String, publicKey: String) -> String? {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return "the update key built into this app is malformed" }
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64
        else { return "the signature file is malformed" }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "unreadable download" }
        return key.isValidSignature(sig, for: data) ? nil : "the signature does not match the update key"
    }
}

extension UpdateFeed.ReleaseAsset {
    /// In an extension so the memberwise `init(url:size:sha256:)` stays synthesized.
    init?(dictionary d: [String: Any]) {
        guard let s = d["url"] as? String, !s.isEmpty, let url = URL(string: s),
              let size = (d["size"] as? NSNumber)?.intValue, size > 0 else { return nil }
        self.init(url: url, size: size, sha256: d["sha256"] as? String,
                  signatureURL: (d["signature"] as? String).flatMap(URL.init(string:)))
    }
}
