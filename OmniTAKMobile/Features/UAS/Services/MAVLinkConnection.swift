//
//  MAVLinkConnection.swift
//  OmniTAKMobile
//
//  UDP transport for the MAVLink codec. Talks to a vehicle / SITL /
//  GCS-style listener on `host:port` (typical PX4-SITL: 127.0.0.1:14550;
//  Android-emulator-to-host bridge: 10.0.2.2:14550).
//
//  We send a 1 Hz HEARTBEAT so the autopilot's link-loss timer doesn't
//  trip, and continuously read whatever frames the vehicle emits. Each
//  parsed message is handed to [onMessage] on the connection queue;
//  it's the caller's job to hop to the main actor before mutating
//  @Published state.
//

import Foundation
import Network

final class MAVLinkConnection {
    enum Transport { case udp /* TCP intentionally omitted for v1 */ }

    private let queue = DispatchQueue(label: "soy.engindearing.mavlink", qos: .userInitiated)
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var seq: UInt8 = 0
    private var rxBuffer: [UInt8] = []

    /// Called for every parsed message. Invoked on the connection
    /// queue, NOT the main thread.
    var onMessage: ((ParsedMessage) -> Void)?

    /// Called on connection state transitions (ready / failed / etc.).
    /// Invoked on the connection queue.
    var onStateChange: ((NWConnection.State) -> Void)?

    func connect(host: String, port: Int) {
        disconnect()
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            onStateChange?(.failed(.posix(.EINVAL)))
            return
        }
        let conn = NWConnection(host: nwHost, port: nwPort, using: .udp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
            if case .ready = state {
                self?.startHeartbeat()
                self?.startReceive()
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: true)
    }

    /// Send a COMMAND_LONG to the vehicle. Caller picks command id +
    /// the 7 float params per MAVLink spec.
    func sendCommandLong(
        targetSystem: UInt8,
        targetComponent: UInt8,
        command: UInt16,
        params: [Float] = Array(repeating: 0, count: 7)
    ) {
        let frame = MAVLinkCodec.encodeCommandLong(
            seq: nextSeq(),
            targetSystem: targetSystem,
            targetComponent: targetComponent,
            command: command,
            params: params
        )
        send(frame)
    }

    // MARK: - Private

    private func send(_ frame: [UInt8]) {
        guard let conn = connection else { return }
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    private func nextSeq() -> UInt8 {
        defer { seq = seq &+ 1 }
        return seq
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(MAVLinkCodec.encodeHeartbeat(seq: self.nextSeq()))
        }
        t.resume()
        heartbeatTimer = t
    }

    private func startReceive() {
        guard let conn = connection else { return }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(contentsOf: data)
                self.drainFrames()
            }
            if error == nil {
                // Re-arm the receive loop. NWConnection.receiveMessage
                // is one-shot; we recur until the connection is torn
                // down.
                self.startReceive()
            }
        }
    }

    private func drainFrames() {
        var cursor = 0
        while let (msg, consumed) = MAVLinkCodec.parseFrame(rxBuffer, offset: cursor) {
            // `consumed` is bytes-consumed-from-`cursor`, not from
            // start-of-buffer. Advance the cursor and let the message
            // out.
            cursor += consumed
            switch msg {
            case .unknown(let id, _) where id == 0:
                // Sentinel for "frame we couldn't validate" — already
                // skipped past; nothing to deliver.
                continue
            default:
                onMessage?(msg)
            }
        }
        if cursor > 0 {
            rxBuffer.removeFirst(min(cursor, rxBuffer.count))
        }
        // Cap the buffer at 64 KB to bound memory if the link goes
        // sideways and we accumulate garbage between valid frames.
        if rxBuffer.count > 65_536 {
            rxBuffer.removeFirst(rxBuffer.count - 65_536)
        }
    }
}
