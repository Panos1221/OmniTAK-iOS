//
//  GybBLEClient.swift
//  OmniTAKMobile
//
//  CoreBluetooth central for the gyb_detect drone detector. Mirrors the
//  MeshtasticBLEClient pattern (scan by service UUID → connect → discover →
//  subscribe to a notify characteristic) but the gyb stream is plain
//  newline-delimited JSON, not protobuf.
//
//  The firmware (ghostnet-fw/src/gatt_link.cpp) chunks each JSON object into
//  20-byte notifications and terminates it with '\n'. We buffer inbound bytes
//  and emit one `onLine` callback per complete object. iOS cannot use the
//  legacy Bluetooth Classic SPP link the ATAK plugin used, so BLE GATT is the
//  only viable transport here — and it pairs in-app with no Settings detour.
//

import Foundation
import CoreBluetooth
import os

enum GybBLEUUID {
    static let service = CBUUID(string: "e3f1b8a0-9c1d-4a2e-9b00-67796236d701")
    static let detection = CBUUID(string: "e3f1b8a0-9c1d-4a2e-9b00-67796236d702")
}

@MainActor
final class GybBLEClient: NSObject, ObservableObject {

    // Reuses the Meshtastic-defined DiscoveredBLEDevice value type.
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var connectedDeviceName: String?

    /// One callback per reassembled JSON line off the GATT stream.
    var onLine: ((String) -> Void)?

    private let log = Logger(subsystem: "com.omnitak.mobile", category: "gyb")
    private let deviceNamePrefix = "gyb_detect"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxBuffer = Data()

    /// Last connected peripheral UUID for auto-reconnect.
    private static let lastDeviceKey = "gyb_last_device_uuid"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scan

    func startScanning() {
        guard central.state == .poweredOn else {
            log.info("startScanning deferred — central not powered on")
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        // Filter by the gyb service UUID — the firmware advertises it.
        central.scanForPeripherals(
            withServices: [GybBLEUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log.info("scanning for gyb detectors")
    }

    func stopScanning() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    // MARK: - Connect

    func connect(to device: DiscoveredBLEDevice) {
        stopScanning()
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
        log.info("connecting to \(device.name, privacy: .public)")
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        rxBuffer.removeAll()
        isConnected = false
        connectedDeviceName = nil
    }

    /// Try to silently reconnect to the last paired detector at launch.
    func reconnectLast() {
        guard central.state == .poweredOn,
              let uuidStr = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let uuid = UUID(uuidString: uuidStr) else { return }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
            log.info("auto-reconnecting to last gyb detector")
        }
    }

    // MARK: - RX reassembly

    private func ingest(_ data: Data) {
        rxBuffer.append(data)
        // Split on newline; emit each complete line, keep the remainder.
        while let nl = rxBuffer.firstIndex(of: 0x0A) {
            let lineData = rxBuffer.subdata(in: rxBuffer.startIndex..<nl)
            rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onLine?(trimmed) }
        }
        // Guard against a runaway buffer if a '\n' never arrives.
        if rxBuffer.count > 8192 { rxBuffer.removeAll() }
    }
}

// MARK: - CBCentralManagerDelegate

extension GybBLEClient: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.reconnectLast()
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                self.isConnected = false
                self.isScanning = false
            @unknown default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "gyb detector"
        // Defensive: only surface gyb-named devices even though we filter by
        // service UUID (some adverts omit the name in the primary packet).
        let name = advName
        Task { @MainActor in
            guard name.lowercased().hasPrefix(self.deviceNamePrefix) || peripheral.name == nil
                    || (peripheral.name?.lowercased().hasPrefix(self.deviceNamePrefix) ?? false) else {
                // Still allow service-matched devices through even if unnamed.
                return
            }
            let device = DiscoveredBLEDevice(id: peripheral.identifier, name: name,
                                             rssi: RSSI.intValue, peripheral: peripheral)
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[idx] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            self.connectedDeviceName = peripheral.name
            self.rxBuffer.removeAll()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
            peripheral.discoverServices([GybBLEUUID.service])
            self.log.info("connected; discovering gyb service")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.connectedDeviceName = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.connectedDeviceName = nil
            self.rxBuffer.removeAll()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GybBLEClient: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == GybBLEUUID.service {
            peripheral.discoverCharacteristics([GybBLEUUID.detection], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == GybBLEUUID.detection {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == GybBLEUUID.detection,
              let value = characteristic.value else { return }
        Task { @MainActor in
            self.ingest(value)
        }
    }
}
