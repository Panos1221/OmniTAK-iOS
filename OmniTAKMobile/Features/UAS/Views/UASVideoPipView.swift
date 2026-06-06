//
//  UASVideoPipView.swift
//  OmniTAKMobile
//
//  Picture-in-picture live drone camera. Mirrors the Android sibling
//  UasVideoPip (Compose). Backed by MobileVLCKit (libVLC), which
//  handles all three transports we care about (RTSP, raw H264 over
//  UDP, MPEG-TS over UDP) through its url-scheme dispatch — VLC's
//  demuxer chain is the same one Foxbat's `gst-launch ... mpegtsmux`
//  pipeline is built around, so the wire formats interoperate
//  cleanly.
//
//  Lifecycle is owned by the player controller; the SwiftUI view just
//  binds the host UIView and observes buffering state. When the
//  composable leaves the hierarchy (drone disconnects, source set to
//  .none) the controller is released and libVLC tears down the
//  socket and decoder.
//
//  Falls back to a plain-text error view when MobileVLCKit is not
//  linked — same graceful-degrade pattern used by VLCPlayerView.
//

import SwiftUI

#if canImport(MobileVLCKit)
import MobileVLCKit

struct UASVideoPipView: View {
    let source: VideoSource
    var onDismiss: () -> Void = {}

    @StateObject private var controller = UASVideoController()
    @State private var expanded = false

    var body: some View {
        if !source.isActive {
            EmptyView()
        } else {
            ZStack(alignment: .topTrailing) {
                Color.black
                UASVideoViewRepresentable(controller: controller)
                    .onAppear { controller.start(source: source) }
                    .onChange(of: source) { new in controller.start(source: new) }
                    .onDisappear { controller.stop() }

                // LIVE indicator
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 1.0, green: 0.23, blue: 0.19))
                    .cornerRadius(4)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Action row
                HStack(spacing: 0) {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left"
                                                   : "arrow.up.left.and.arrow.down.right")
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                    }
                    Button {
                        controller.stop()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.3))

                // Error overlay (bottom-left)
                if let err = controller.errorMessage {
                    Text("\(source.displayName): \(err)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }
            }
            .frame(width: expanded ? 320 : 160)
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - VLC controller

final class UASVideoController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published var errorMessage: String?
    @Published var isBuffering = true

    let mediaPlayer = VLCMediaPlayer()
    private var currentSource: VideoSource = .none

    override init() {
        super.init()
        mediaPlayer.delegate = self
    }

    func start(source: VideoSource) {
        guard source.isActive else { stop(); return }
        currentSource = source
        errorMessage = nil
        isBuffering = true

        guard let url = source.vlcURL else {
            errorMessage = "Invalid source"
            isBuffering = false
            return
        }

        // libVLC options tuned for low-latency live UDP. `--network-caching=0`
        // disables the default 1 s pre-buffer; for raw H264 we ask the demuxer
        // to use the H264 path explicitly so it doesn't try to auto-detect
        // (which can take several seconds on a stream without container
        // markers).
        let media = VLCMedia(url: url)
        var options: [String] = ["--network-caching=50", "--clock-jitter=0", "--clock-synchro=0"]
        if case .rawH264Udp = source {
            options.append("--demux=h264")
        }
        for opt in options { media.addOption(opt) }
        mediaPlayer.media = media
        mediaPlayer.play()
    }

    func stop() {
        if mediaPlayer.isPlaying { mediaPlayer.stop() }
        mediaPlayer.media = nil
        currentSource = .none
        isBuffering = false
    }

    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        switch mediaPlayer.state {
        case .error:
            errorMessage = "playback error"
            isBuffering = false
        case .buffering, .opening:
            isBuffering = true
        case .playing:
            isBuffering = false
            errorMessage = nil
        default:
            break
        }
    }
}

struct UASVideoViewRepresentable: UIViewRepresentable {
    let controller: UASVideoController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        controller.mediaPlayer.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.mediaPlayer.drawable = uiView
    }
}

#else

// MobileVLCKit not linked — render a graceful instructional placeholder.
struct UASVideoPipView: View {
    let source: VideoSource
    var onDismiss: () -> Void = {}

    var body: some View {
        if !source.isActive {
            EmptyView()
        } else {
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.yellow)
                    Text("UAS video requires MobileVLCKit")
                        .font(.caption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text("Add the Swift package in Xcode → Package Dependencies")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            }
            .frame(width: 160)
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                        .padding(6)
                }
            }
        }
    }
}

#endif
