//
//  MeshCoreChannelCodec.swift
//  OmniTAK Mobile
//
//  Clean-room encoder/decoder for MeshCore channel share links:
//      meshcore://channel/add?name=<name>&secret=<hex-16-bytes>
//
//  This is MeshCore's analogue to the Meshtastic `meshtastic.org/e/#...` URL.
//  Closed-test feedback (PatoG1899) + Grant: operators want to create and
//  share a channel from inside OmniTAK across BOTH mesh transports.
//
//  Format (MeshCore docs/qr_codes.md):
//    - scheme/host/path: meshcore://channel/add
//    - name:   channel name, URL-encoded
//    - secret: lowercase hex of the 16-byte channel secret. Omitted/empty for
//              the public channel (index 0, no secret).
//
//  Licensing: independent clean-room implementation from the public URL spec.
//

import Foundation

struct MeshCoreChannel: Equatable {
    var name: String
    /// 16-byte channel secret. Empty for the public channel (no crypto).
    var secret: Data
}

enum MeshCoreChannelCodec {

    static let scheme = "meshcore"
    static let channelAddPath = "channel/add"

    // MARK: - Encode

    static func encodeURL(_ ch: MeshCoreChannel) -> String {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "channel"
        comps.path = "/add"
        var items = [URLQueryItem(name: "name", value: ch.name)]
        if !ch.secret.isEmpty {
            items.append(URLQueryItem(name: "secret", value: hex(ch.secret)))
        }
        comps.queryItems = items
        // URLComponents encodes "+" in a value as a literal plus inside a query,
        // but spaces become "%20" which is what we want; keep its output.
        return comps.string ?? "\(scheme)://channel/add"
    }

    // MARK: - Decode

    /// Parse a `meshcore://channel/add?...` link. Returns nil for any other
    /// scheme/host/path or a malformed secret.
    static func decodeURL(_ input: String) -> MeshCoreChannel? {
        guard let comps = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == scheme else { return nil }
        // host="channel", path="/add"  (tolerate path with/without leading slash)
        let host = comps.host?.lowercased()
        let path = comps.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == "channel", path == "add" else { return nil }

        let items = comps.queryItems ?? []
        let name = items.first(where: { $0.name == "name" })?.value ?? ""
        let secretHex = items.first(where: { $0.name == "secret" })?.value ?? ""

        let secret: Data
        if secretHex.isEmpty {
            secret = Data()
        } else if let s = dehex(secretHex) {
            secret = s
        } else {
            return nil // malformed secret
        }
        return MeshCoreChannel(name: name, secret: secret)
    }

    // MARK: - hex helpers

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func dehex(_ s: String) -> Data? {
        let chars = Array(s)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}
