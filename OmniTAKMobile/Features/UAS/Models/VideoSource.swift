//
//  VideoSource.swift
//  OmniTAKMobile
//
//  Source for the UAS live camera PIP. Three modes, mirroring the
//  Android sibling (OmniTAK-Android/.../data/uas/VideoSource.kt):
//
//   - none: no video. PIP not rendered.
//   - rtsp(URL): standard RTSP camera (most off-the-shelf vehicles).
//   - rawH264Udp(port): raw H264 Annex B NAL units delivered as UDP
//     datagrams. Compatible with RubyFPV's "Video Forward To USB
//     Device: Raw (H264)" output and similar long-range FPV ground
//     stations that don't expose RTSP.
//   - mpegTsUdp(port): H264 inside MPEG-TS over UDP. Same wire format
//     ATAK UAS Tool accepts and what the canonical RubyFPV gst
//     pipeline emits (h264parse → mpegtsmux → udpsink).
//
//  All three are decoded through libVLC (MobileVLCKit). libVLC's
//  url-scheme dispatch handles raw H264 over UDP and MPEG-TS over UDP
//  natively; RTSP uses its own demuxer. So we map every active source
//  to a libVLC-friendly URL and hand it off — the Kotlin sibling
//  splits raw H264 NALs in-app, but on iOS that machinery already
//  lives inside VLC and there's no reason to duplicate it.
//

import Foundation

enum VideoSource: Equatable {
    case none
    case rtsp(URL)
    case rawH264Udp(port: Int)
    case mpegTsUdp(port: Int)

    var isActive: Bool {
        if case .none = self { return false }
        return true
    }

    /// libVLC-compatible URL for the active source.
    /// `nil` for `.none`.
    var vlcURL: URL? {
        switch self {
        case .none:
            return nil
        case .rtsp(let url):
            return url
        case .rawH264Udp(let port):
            // h264:// forces the raw H264 demuxer regardless of how
            // libVLC's auto-detect classifies the stream. udp://@:port
            // binds to any interface (USB tether, Wi-Fi, LAN).
            return URL(string: "udp://@:\(port)/h264")
        case .mpegTsUdp(let port):
            return URL(string: "udp://@:\(port)")
        }
    }

    /// Operator-facing label, used in HUD chips and error messages.
    var displayName: String {
        switch self {
        case .none: return "Off"
        case .rtsp: return "RTSP"
        case .rawH264Udp: return "Raw H264 UDP"
        case .mpegTsUdp: return "MPEG-TS UDP"
        }
    }

    // MARK: - Validating factories. Port 0 / blank URL collapses to
    // `.none` so callers don't have to special-case empty input. The
    // labels are intentionally different from the enum cases above so
    // the compiler can distinguish them.

    static func rtsp(fromString string: String) -> VideoSource {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return .none }
        return .rtsp(url)
    }

    static func rawH264Udp(validating port: Int) -> VideoSource {
        guard (1...65535).contains(port) else { return .none }
        return .rawH264Udp(port: port)
    }

    static func mpegTsUdp(validating port: Int) -> VideoSource {
        guard (1...65535).contains(port) else { return .none }
        return .mpegTsUdp(port: port)
    }
}
