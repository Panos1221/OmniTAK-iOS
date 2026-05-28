//
//  UASConnectView.swift
//  OmniTAKMobile
//
//  UAS Quick Connect screen. Mirrors the Android UASScreen layout:
//  transport + host/port + callsign for the MAVLink endpoint, then a
//  three-chip Video Source picker (RTSP / Raw H264 UDP / MPEG-TS UDP)
//  with a dynamic field per mode.
//
//  Reachable via the tools menu — see RootTabView's BarItem dispatch
//  for the `.command(.uasConnect)` shortcut wiring.
//

import SwiftUI

struct UASConnectView: View {
    @ObservedObject var manager = UASManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = "127.0.0.1"
    @State private var portText: String = "14550"
    @State private var callsign: String = "OmniTAK-UAS"

    @State private var videoMode: VideoMode = .rtsp
    @State private var rtspText: String = ""
    @State private var rawUdpPortText: String = "5000"
    @State private var tsUdpPortText: String = "5010"

    private enum VideoMode: String, CaseIterable, Identifiable {
        case rtsp = "RTSP"
        case rawH264 = "Raw H264 UDP"
        case mpegTs = "MPEG-TS UDP"
        var id: String { rawValue }
    }

    private var isConnected: Bool { manager.state.isConnected() }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Connect any MAVLink vehicle — drone (UAS), ground rover (UGV), or boat (USV). PX4 / ArduPilot. The platform type is auto-detected; map adapts (Fly/Drive Here, altitude, marker). CoT flows to every operator on the active TAK server.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("MAVLink endpoint") {
                    TextField("Host", text: $host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        TextField("Port", text: $portText)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                        TextField("Callsign", text: $callsign)
                    }
                }

                Section("Video") {
                    Picker("Source", selection: $videoMode) {
                        ForEach(VideoMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: videoMode) { new in
                        applyVideoMode(new)
                    }

                    switch videoMode {
                    case .rtsp:
                        TextField("rtsp://10.0.2.2:8555/test", text: $rtspText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onChange(of: rtspText) { new in
                                manager.videoSource = .rtsp(fromString: new)
                            }
                    case .rawH264:
                        HStack {
                            Text("UDP port")
                            Spacer()
                            TextField("5000", text: $rawUdpPortText)
                                .keyboardType(.numberPad)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: rawUdpPortText) { new in
                                    let p = Int(new) ?? 0
                                    manager.videoSource = .rawH264Udp(validating: p)
                                }
                        }
                        Text("Raw H264 Annex B over UDP. Compatible with RubyFPV \"Video Forward To USB Device: Raw (H264)\" and similar long-range FPV ground stations. libVLC decodes directly.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    case .mpegTs:
                        HStack {
                            Text("UDP port")
                            Spacer()
                            TextField("5010", text: $tsUdpPortText)
                                .keyboardType(.numberPad)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: tsUdpPortText) { new in
                                    let p = Int(new) ?? 0
                                    manager.videoSource = .mpegTsUdp(validating: p)
                                }
                        }
                        Text("MPEG-TS over UDP. Same wire format ATAK UAS Tool accepts. Use with the canonical RubyFPV gst pipeline (h264parse → mpegtsmux → udpsink).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if let err = manager.lastError {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .navigationTitle("Vehicle Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    if isConnected {
                        Button(role: .destructive) {
                            manager.disconnect()
                        } label: { Text("Disconnect").bold() }
                    } else {
                        Button {
                            let port = Int(portText) ?? 14550
                            manager.connect(host: host, port: port, callsign: callsign)
                        } label: { Text("Connect").bold() }
                        .disabled(host.isEmpty || manager.connecting)
                    }
                }
            }
            .onAppear { applyVideoMode(videoMode) }
        }
    }

    private func applyVideoMode(_ mode: VideoMode) {
        switch mode {
        case .rtsp:
            manager.videoSource = .rtsp(fromString: rtspText)
        case .rawH264:
            manager.videoSource = .rawH264Udp(validating: Int(rawUdpPortText) ?? 5000)
        case .mpegTs:
            manager.videoSource = .mpegTsUdp(validating: Int(tsUdpPortText) ?? 5010)
        }
    }
}
