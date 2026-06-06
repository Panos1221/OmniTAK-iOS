//
//  GybDetectorView.swift
//  OmniTAKMobile
//
//  Connection UI for the gyb_detect external drone detector. Mirrors the
//  omni-COT ATAK plugin dashboard: scan for the detector, tap to connect,
//  watch live status (connected device, battery, drones detected). Presented
//  as a modal from Settings so it never carves into the full-screen map.
//
//  Unlike the ATAK plugin (Bluetooth Classic SPP, pair in OS Settings first),
//  this connects in-app over BLE GATT — no Settings detour, same flow on iOS
//  and Android.
//

import SwiftUI

struct GybDetectorView: View {
    @ObservedObject private var manager = GybManager.shared
    @ObservedObject private var client = GybManager.shared.client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                statusSection
                devicesSection
                aboutSection
            }
            .navigationTitle("gyb Detector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if client.isScanning {
                        Button("Stop") { client.stopScanning() }
                    } else {
                        Button("Scan") { client.startScanning() }
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Connection")
                Spacer()
                if client.isConnected {
                    Label(client.connectedDeviceName ?? "Connected", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundColor(.green)
                } else {
                    Text("Disconnected").foregroundColor(.secondary)
                }
            }
            if client.isConnected {
                HStack {
                    Text("Battery")
                    Spacer()
                    Text(manager.batteryLevel.map { "\(Int($0 * 100))%" } ?? "—")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Drones detected")
                    Spacer()
                    Text("\(manager.droneCount)").foregroundColor(.secondary)
                }
                Button(role: .destructive) {
                    client.disconnect()
                } label: {
                    Text("Disconnect")
                }
            }
        }
    }

    private var devicesSection: some View {
        Section(client.isScanning ? "Scanning…" : "Detectors") {
            if client.discoveredDevices.isEmpty {
                Text(client.isScanning ? "Looking for gyb detectors nearby" : "Tap Scan to find your gyb detector")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(client.discoveredDevices) { device in
                Button {
                    client.connect(to: device)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("\(device.signalStrength) · \(device.rssi) dBm")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if client.connectedDeviceName == device.name && client.isConnected {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("The gyb detector catches WiFi-beacon Remote ID — the drone broadcasts your phone can't see on its own — and streams them here over Bluetooth. Detected drones appear on the map alongside the phone's own Bluetooth Remote ID picks.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let model = manager.deviceModel {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(model + (manager.deviceSerial.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
