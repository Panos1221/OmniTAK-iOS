//
//  MeshtasticAdminCodec.swift
//  OmniTAK Mobile
//
//  Clean-room encoder for the Meshtastic `AdminMessage` — the protobuf carried
//  on the ADMIN_APP portnum (6) that writes channel + config settings to a
//  radio. This is the "apply an imported/created channel to the radio" half of
//  the channel-share feature (OmniTAK-iOS #101): the share codec produces the
//  URL/QR, this codec produces the bytes that program the local radio.
//
//  Closed-test feedback (PatoG1899): operators want to (a) create + share a
//  channel from inside OmniTAK and (b) constrain rebroadcast to the current /
//  known channel only. (b) is DeviceConfig.rebroadcast_mode = KNOWN_ONLY /
//  LOCAL_ONLY, set via AdminMessage.set_config.
//
//  Licensing: independent clean-room implementation. Protobuf field NUMBERS and
//  enum VALUES are an interface (facts from the published wire spec), not
//  copyrightable expression — we hand-roll the bytes here exactly as
//  TAKPacketV2Codec / ATAKPluginSerializer already do, copying NO GPL proto text
//  or Meshtastic-SDK code.
//
//  Wire layout (field numbers / enum values are facts):
//      AdminMessage.set_channel = 33  (Channel submessage)
//      AdminMessage.set_config  = 34  (Config submessage)
//      Channel{ index=1 (int32), settings=2 (ChannelSettings), role=3 (Role enum) }
//      ChannelSettings{ psk=2 (bytes), name=3 (string) }
//      Channel.Role: DISABLED=0, PRIMARY=1, SECONDARY=2
//      Config.device   = 1  (DeviceConfig submessage)
//      Config.position = 2  (PositionConfig submessage)
//      DeviceConfig{ role=1 (Role enum), rebroadcast_mode=6 (RebroadcastMode enum) }
//      DeviceConfig.Role: CLIENT=0, ROUTER=2, TRACKER=5, TAK=7, TAK_TRACKER=10
//      DeviceConfig.RebroadcastMode: ALL=0, LOCAL_ONLY=2, KNOWN_ONLY=3, NONE=4
//      PositionConfig{ position_broadcast_secs=1 (uint32) }
//

import Foundation

enum MeshtasticAdminCodec {

    /// Meshtastic PortNum for AdminMessage traffic.
    static let adminPortnum: UInt64 = 6

    // MARK: - Channel.Role (clean-room enum mirroring the wire values)

    enum ChannelRole: UInt64 {
        case disabled = 0
        case primary = 1
        case secondary = 2
    }

    // MARK: - DeviceConfig.Role (subset OmniTAK exposes)

    enum DeviceRole: UInt64, CaseIterable {
        case client = 0
        case router = 2
        case tracker = 5
        case tak = 7
        case takTracker = 10

        var displayName: String {
            switch self {
            case .client:     return "Client"
            case .router:     return "Router"
            case .tracker:    return "Tracker"
            case .tak:        return "TAK"
            case .takTracker: return "TAK Tracker"
            }
        }
    }

    // MARK: - DeviceConfig.RebroadcastMode (the PatoG1899 "scope" ask)

    enum RebroadcastMode: UInt64, CaseIterable {
        case all = 0
        case localOnly = 2
        case knownOnly = 3
        case none = 4

        var displayName: String {
            switch self {
            case .all:       return "All (default)"
            case .localOnly: return "Local mesh only"
            case .knownOnly: return "Known channels only"
            case .none:      return "None (no rebroadcast)"
            }
        }
    }

    // MARK: - set_channel

    /// Encode an `AdminMessage{ set_channel = Channel{...} }` payload.
    ///
    /// `psk` must be 0 bytes (no crypto), 1 byte (default-key shorthand), 16
    /// bytes (AES128) or 32 bytes (AES256); other lengths are passed through
    /// verbatim (the radio validates).
    static func encodeSetChannel(
        index: Int32,
        name: String,
        psk: Data,
        role: ChannelRole
    ) -> Data {
        // ChannelSettings { psk=2, name=3 }
        var settings = Data()
        if !psk.isEmpty {
            appendBytes(&settings, field: 2, value: psk)
        }
        if !name.isEmpty {
            appendBytes(&settings, field: 3, value: Data(name.utf8))
        }

        // Channel { index=1, settings=2, role=3 }
        var channel = Data()
        appendVarintField(&channel, field: 1, value: int32Varint(index)) // proto3 int32 = plain varint
        appendBytes(&channel, field: 2, value: settings)
        if role != .disabled {
            appendVarintField(&channel, field: 3, value: role.rawValue)
        }

        // AdminMessage { set_channel=33 }
        var admin = Data()
        appendBytes(&admin, field: 33, value: channel)
        return admin
    }

    // MARK: - set_config (device role + rebroadcast scope)

    /// Encode an `AdminMessage{ set_config = Config{ device = DeviceConfig{...} } }`
    /// payload carrying the device role and rebroadcast scope.
    static func encodeSetDeviceConfig(
        role: DeviceRole,
        rebroadcastMode: RebroadcastMode
    ) -> Data {
        // DeviceConfig { role=1, rebroadcast_mode=6 }
        var device = Data()
        appendVarintField(&device, field: 1, value: role.rawValue)
        appendVarintField(&device, field: 6, value: rebroadcastMode.rawValue)

        // Config { device=1 }
        var config = Data()
        appendBytes(&config, field: 1, value: device)

        // AdminMessage { set_config=34 }
        var admin = Data()
        appendBytes(&admin, field: 34, value: config)
        return admin
    }

    // MARK: - set_config (position broadcast interval)

    /// Encode an `AdminMessage{ set_config = Config{ position = PositionConfig{
    /// position_broadcast_secs } } }` payload.
    static func encodeSetPositionBroadcastInterval(seconds: UInt32) -> Data {
        // PositionConfig { position_broadcast_secs=1 }
        var position = Data()
        appendVarintField(&position, field: 1, value: UInt64(seconds))

        // Config { position=2 }
        var config = Data()
        appendBytes(&config, field: 2, value: position)

        // AdminMessage { set_config=34 }
        var admin = Data()
        appendBytes(&admin, field: 34, value: config)
        return admin
    }

    // MARK: - Wire helpers (independent clean-room implementation)

    private static func appendTag(_ d: inout Data, field: Int, wire: UInt8) {
        appendVarint(&d, UInt64(field) << 3 | UInt64(wire))
    }
    private static func appendVarint(_ d: inout Data, _ value: UInt64) {
        var v = value
        if v == 0 { d.append(0); return }
        while v > 0x7F { d.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        d.append(UInt8(v))
    }
    private static func appendVarintField(_ d: inout Data, field: Int, value: UInt64) {
        appendTag(&d, field: field, wire: 0); appendVarint(&d, value)
    }
    private static func appendBytes(_ d: inout Data, field: Int, value: Data) {
        appendTag(&d, field: field, wire: 2); appendVarint(&d, UInt64(value.count)); d.append(value)
    }

    /// proto3 `int32` is encoded as a plain varint, sign-extended to 64 bits for
    /// negatives. Channel indices are always >= 0 in practice, but this encodes
    /// correctly for the full int32 range.
    private static func int32Varint(_ v: Int32) -> UInt64 {
        return UInt64(bitPattern: Int64(v))
    }
}
