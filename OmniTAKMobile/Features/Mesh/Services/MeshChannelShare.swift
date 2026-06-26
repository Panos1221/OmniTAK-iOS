//
//  MeshChannelShare.swift
//  OmniTAK Mobile
//
//  Cross-transport entry point for "scan a QR / paste a link to join a
//  channel". Detects whether a shared channel link is Meshtastic or MeshCore
//  and decodes it with the matching clean-room codec, so the settings screen
//  has one call regardless of which mesh the operator is on.
//

import Foundation

enum MeshChannelImport: Equatable {
    case meshtastic([MeshChannel])
    case meshcore(MeshCoreChannel)
}

/// Which mesh family a channel share belongs to. Named `MeshShareTransport` to
/// avoid colliding with the byte-level `MeshTransport` link protocol in
/// MeshFramework.swift.
enum MeshShareTransport: String {
    case meshtastic
    case meshcore
}

enum MeshChannelShare {

    /// Parse any supported channel-share link/QR payload.
    /// MeshCore links are `meshcore://channel/add?...`; Meshtastic links are
    /// `https://meshtastic.org/e/#...` (or a bare base64url fragment).
    static func parse(_ input: String) -> MeshChannelImport? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // MeshCore first — its scheme is unambiguous.
        if let mc = MeshCoreChannelCodec.decodeURL(s) {
            return .meshcore(mc)
        }
        if let mt = MeshtasticChannelCodec.decodeURL(s), !mt.isEmpty {
            return .meshtastic(mt)
        }
        return nil
    }

    /// Build a share link for the active transport.
    static func shareURL(transport: MeshShareTransport,
                         meshtastic: [MeshChannel] = [],
                         meshcore: MeshCoreChannel? = nil) -> String? {
        switch transport {
        case .meshtastic:
            return meshtastic.isEmpty ? nil : MeshtasticChannelCodec.encodeURL(meshtastic)
        case .meshcore:
            return meshcore.map { MeshCoreChannelCodec.encodeURL($0) }
        }
    }
}
