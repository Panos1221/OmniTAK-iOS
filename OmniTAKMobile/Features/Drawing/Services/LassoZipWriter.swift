//
//  LassoZipWriter.swift
//  OmniTAKMobile
//
//  Minimal ZIP archive writer for the lasso Mission Package exporter
//  (issue #16). Implements the subset of the ZIP spec we actually need:
//
//    • Store-only (no deflate) — Mission Package payloads are
//      small CoT XML files; trading off compression for zero
//      external deps is a fine call.
//    • Single segment, no encryption, no Zip64 — every entry must
//      fit in 4 GB which is comfortably true for any selection
//      anyone would lasso.
//    • UTF-8 file names — bit 11 of the general-purpose flags is
//      set so ATAK / WinTAK / iTAK readers treat the names as
//      UTF-8 rather than CP-437.
//
//  CRC-32 is the IEEE 802.3 polynomial 0xEDB88320, computed against a
//  table built once at first use. No `import zlib` so the build stays
//  free of system-framework module weirdness.
//

import Foundation

enum LassoZipWriter {

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - DOS time/date (DOS epoch = 1980)

    private struct DosDateTime { let date: UInt16; let time: UInt16 }

    private static func dosNow() -> DosDateTime {
        let cal = Calendar(identifier: .gregorian)
        let cmp = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max(1980, cmp.year ?? 1980) - 1980
        let date = UInt16(((year & 0x7F) << 9) | ((cmp.month ?? 1) << 5) | (cmp.day ?? 1))
        // Seconds in DOS time are 2-sec units (5 bits, max 29 = 58s).
        let time = UInt16(((cmp.hour ?? 0) << 11) | ((cmp.minute ?? 0) << 5) | ((cmp.second ?? 0) / 2))
        return DosDateTime(date: date, time: time)
    }

    // MARK: - Little-endian appenders

    private static func append(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
    private static func append(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    // MARK: - Entry

    private struct Entry {
        let name: String
        let nameBytes: Data
        let data: Data
        let crc: UInt32
        let dos: DosDateTime
        var localHeaderOffset: UInt32
    }

    // MARK: - Public API

    /// Pack the given (filename, contents) pairs into a single zip
    /// archive. Filenames may include forward-slash separators for
    /// nested paths (e.g. "cot/marker-1.cot").
    static func write(entries inputs: [(name: String, data: Data)]) -> Data {
        let dos = dosNow()
        var entries: [Entry] = inputs.map { (name, data) in
            Entry(
                name: name,
                nameBytes: Data(name.utf8),
                data: data,
                crc: crc32(data),
                dos: dos,
                localHeaderOffset: 0,
            )
        }

        // 1. Write local file headers + data.
        var out = Data()
        for i in 0..<entries.count {
            entries[i].localHeaderOffset = UInt32(out.count)

            // PK\x03\x04 — local file header signature.
            append(&out, UInt32(0x04034B50))
            append(&out, UInt16(20))                  // version needed: 2.0
            append(&out, UInt16(0x0800))              // gp flags: UTF-8 names
            append(&out, UInt16(0))                   // method: store
            append(&out, entries[i].dos.time)
            append(&out, entries[i].dos.date)
            append(&out, entries[i].crc)
            append(&out, UInt32(entries[i].data.count)) // compressed size = uncompressed
            append(&out, UInt32(entries[i].data.count))
            append(&out, UInt16(entries[i].nameBytes.count))
            append(&out, UInt16(0))                   // extra-field length
            out.append(entries[i].nameBytes)
            out.append(entries[i].data)
        }

        // 2. Write central directory.
        let cdStart = UInt32(out.count)
        for e in entries {
            // PK\x01\x02 — central directory file header signature.
            append(&out, UInt32(0x02014B50))
            append(&out, UInt16(20))                  // version made by
            append(&out, UInt16(20))                  // version needed
            append(&out, UInt16(0x0800))              // gp flags
            append(&out, UInt16(0))                   // method
            append(&out, e.dos.time)
            append(&out, e.dos.date)
            append(&out, e.crc)
            append(&out, UInt32(e.data.count))
            append(&out, UInt32(e.data.count))
            append(&out, UInt16(e.nameBytes.count))
            append(&out, UInt16(0))                   // extra field len
            append(&out, UInt16(0))                   // comment len
            append(&out, UInt16(0))                   // disk number
            append(&out, UInt16(0))                   // internal attrs
            append(&out, UInt32(0))                   // external attrs
            append(&out, e.localHeaderOffset)
            out.append(e.nameBytes)
        }
        let cdEnd = UInt32(out.count)
        let cdSize = cdEnd - cdStart

        // 3. End-of-central-dir record.
        append(&out, UInt32(0x06054B50))             // EOCD signature PK\x05\x06
        append(&out, UInt16(0))                       // this disk
        append(&out, UInt16(0))                       // disk with cd
        append(&out, UInt16(entries.count))           // entries on this disk
        append(&out, UInt16(entries.count))           // total entries
        append(&out, cdSize)
        append(&out, cdStart)
        append(&out, UInt16(0))                       // comment len

        return out
    }
}
