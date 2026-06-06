//
//  TWD97Converter.swift
//  OmniTAKMobile
//
//  TWD97 / TM2 zone 121 (Taiwan) converter — EPSG:3826
//  Transverse Mercator on the GRS80 ellipsoid.
//
//  Unlike BNG (which needs a Helmert datum shift to OSGB36), TWD97 is
//  referenced to GRS80/ITRF and is effectively identical to WGS84
//  (towgs84 = 0,0,0,0,0,0,0 — sub-metre difference), so no datum
//  transform is required. We project WGS84 lat/lon straight to/from TM2.
//
//  Projection parameters (EPSG:3826):
//    central meridian (lon0) = 121°E
//    scale factor (k0)       = 0.9999
//    false easting (E0)      = 250000 m
//    false northing (N0)     = 0 m
//    latitude of origin      = 0°
//
//  Digit input modes (what Gavin asked to compare):
//    .full7 — full absolute TM2 coordinate, 7 digits easting + 7 digits
//             northing at 1 m (e.g. "0250000 2543210"). Unambiguous, the
//             standard Taiwan survey ("二度分帶") input, but longer to type.
//    .grid5 — MGRS-style truncated reference: the last 5 digits of easting
//             and northing within the local 100 km cell (e.g. "50000 43210").
//             Shorter and matches MGRS muscle memory, but ambiguous outside
//             the local 100 km cell — parsing requires a reference coordinate
//             (the map centre) to recover the 100 km prefix.
//

import Foundation
import CoreLocation

// MARK: - TWD97 Converter

class TWD97Converter {

    // MARK: - GRS80 Ellipsoid Constants

    private static let a: Double = 6378137.0               // Semi-major axis
    private static let f: Double = 1.0 / 298.257222101     // Flattening
    private static let b: Double = 6378137.0 * (1.0 - 1.0 / 298.257222101) // Semi-minor axis
    private static let e2: Double = (2.0 / 298.257222101) - (1.0 / 298.257222101) * (1.0 / 298.257222101) // First eccentricity²

    // MARK: - TM2 zone 121 Projection Parameters

    private static let lat0: Double = 0.0                       // True origin latitude (equator)
    private static let lon0: Double = 121.0 * .pi / 180.0       // Central meridian (121°E)
    private static let N0: Double = 0.0                         // False northing
    private static let E0: Double = 250000.0                    // False easting
    private static let F0: Double = 0.9999                      // Scale factor on central meridian

    // MARK: - Taiwan Bounds (TM2 zone 121: main island + nearshore)
    // Kinmen/Matsu use zone 119 (EPSG:3825) and are intentionally excluded.

    private static let minLat: Double = 21.0
    private static let maxLat: Double = 26.5
    private static let minLon: Double = 119.0
    private static let maxLon: Double = 123.0

    // MARK: - Digit Input Mode

    enum DigitMode {
        case full7   // 7 + 7 absolute digits (1 m)
        case grid5   // 5 + 5 truncated digits within local 100 km cell (1 m)

        /// Number of digits shown per axis.
        var digits: Int {
            switch self {
            case .full7: return 7
            case .grid5: return 5
            }
        }

        var label: String {
            switch self {
            case .full7: return "7+7"
            case .grid5: return "5+5"
            }
        }
    }

    // MARK: - TWD97 Coordinate Structure

    struct TWD97Coordinate {
        let easting: Double      // Full absolute easting (metres)
        let northing: Double     // Full absolute northing (metres)
        let mode: DigitMode

        /// Formatted grid string for the selected digit mode.
        func formatted(withSpaces: Bool = true) -> String {
            switch mode {
            case .full7:
                let e = String(format: "%07d", Int(easting.rounded()))
                let n = String(format: "%07d", Int(northing.rounded()))
                return withSpaces ? "\(e) \(n)" : "\(e)\(n)"
            case .grid5:
                let e = Int(easting.rounded()) % 100000
                let n = Int(northing.rounded()) % 100000
                let eStr = String(format: "%05d", e)
                let nStr = String(format: "%05d", n)
                return withSpaces ? "\(eStr) \(nStr)" : "\(eStr)\(nStr)"
            }
        }
    }

    // MARK: - WGS84 Lat/Lon → TWD97 TM2 (forward, Redfearn series)

    /// Project a WGS84 coordinate to absolute TM2 easting/northing.
    /// Returns nil if outside the Taiwan (zone 121) bounds.
    static func latLonToTWD97(_ coord: CLLocationCoordinate2D, mode: DigitMode = .full7) -> TWD97Coordinate? {
        guard isWithinBounds(coord) else { return nil }
        let (easting, northing) = project(coord)
        return TWD97Coordinate(easting: easting, northing: northing, mode: mode)
    }

    /// Raw forward projection (no bounds check). Exposed for testing/round-trips.
    static func project(_ coord: CLLocationCoordinate2D) -> (easting: Double, northing: Double) {
        let lat = coord.latitude * .pi / 180.0
        let lon = coord.longitude * .pi / 180.0

        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let tanLat = tan(lat)

        let n = (a - b) / (a + b)
        let n2 = n * n
        let n3 = n * n * n

        let nu = a * F0 / sqrt(1 - e2 * sinLat * sinLat)
        let rho = a * F0 * (1 - e2) / pow(1 - e2 * sinLat * sinLat, 1.5)
        let eta2 = nu / rho - 1

        let Ma = (1 + n + (5.0 / 4.0) * n2 + (5.0 / 4.0) * n3) * (lat - lat0)
        let Mb = (3 * n + 3 * n2 + (21.0 / 8.0) * n3) * sin(lat - lat0) * cos(lat + lat0)
        let Mc = ((15.0 / 8.0) * n2 + (15.0 / 8.0) * n3) * sin(2 * (lat - lat0)) * cos(2 * (lat + lat0))
        let Md = (35.0 / 24.0) * n3 * sin(3 * (lat - lat0)) * cos(3 * (lat + lat0))
        let M = b * F0 * (Ma - Mb + Mc - Md)

        let I = M + N0
        let II = (nu / 2) * sinLat * cosLat
        let III = (nu / 24) * sinLat * pow(cosLat, 3) * (5 - tanLat * tanLat + 9 * eta2)
        let IIIA = (nu / 720) * sinLat * pow(cosLat, 5) * (61 - 58 * tanLat * tanLat + pow(tanLat, 4))
        let IV = nu * cosLat
        let V = (nu / 6) * pow(cosLat, 3) * (nu / rho - tanLat * tanLat)
        let VI = (nu / 120) * pow(cosLat, 5) * (5 - 18 * tanLat * tanLat + pow(tanLat, 4) + 14 * eta2 - 58 * tanLat * tanLat * eta2)

        let dLon = lon - lon0

        let northing = I + II * dLon * dLon + III * pow(dLon, 4) + IIIA * pow(dLon, 6)
        let easting = E0 + IV * dLon + V * pow(dLon, 3) + VI * pow(dLon, 5)

        return (easting, northing)
    }

    // MARK: - TWD97 TM2 → WGS84 Lat/Lon (inverse, Redfearn series)

    /// Convert absolute TM2 easting/northing to WGS84 lat/lon.
    static func twd97ToLatLon(easting: Double, northing: Double) -> CLLocationCoordinate2D {
        let n = (a - b) / (a + b)
        let n2 = n * n
        let n3 = n * n * n

        var lat = lat0
        var M: Double = 0

        // Iterate latitude until the meridional arc matches the northing.
        repeat {
            lat = ((northing - N0 - M) / (a * F0)) + lat

            let Ma = (1 + n + (5.0 / 4.0) * n2 + (5.0 / 4.0) * n3) * (lat - lat0)
            let Mb = (3 * n + 3 * n2 + (21.0 / 8.0) * n3) * sin(lat - lat0) * cos(lat + lat0)
            let Mc = ((15.0 / 8.0) * n2 + (15.0 / 8.0) * n3) * sin(2 * (lat - lat0)) * cos(2 * (lat + lat0))
            let Md = (35.0 / 24.0) * n3 * sin(3 * (lat - lat0)) * cos(3 * (lat + lat0))
            M = b * F0 * (Ma - Mb + Mc - Md)

        } while abs(northing - N0 - M) >= 0.00001

        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let tanLat = tan(lat)

        let nu = a * F0 / sqrt(1 - e2 * sinLat * sinLat)
        let rho = a * F0 * (1 - e2) / pow(1 - e2 * sinLat * sinLat, 1.5)
        let eta2 = nu / rho - 1

        let tanLat2 = tanLat * tanLat
        let tanLat4 = tanLat2 * tanLat2
        let tanLat6 = tanLat4 * tanLat2

        let VII = tanLat / (2 * rho * nu)
        let VIII = tanLat / (24 * rho * pow(nu, 3)) * (5 + 3 * tanLat2 + eta2 - 9 * tanLat2 * eta2)
        let IX = tanLat / (720 * rho * pow(nu, 5)) * (61 + 90 * tanLat2 + 45 * tanLat4)
        let X = 1.0 / (cosLat * nu)
        let XI = 1.0 / (cosLat * 6 * pow(nu, 3)) * (nu / rho + 2 * tanLat2)
        let XII = 1.0 / (cosLat * 120 * pow(nu, 5)) * (5 + 28 * tanLat2 + 24 * tanLat4)
        let XIIA = 1.0 / (cosLat * 5040 * pow(nu, 7)) * (61 + 662 * tanLat2 + 1320 * tanLat4 + 720 * tanLat6)

        let dE = easting - E0

        let latRad = lat - VII * dE * dE + VIII * pow(dE, 4) - IX * pow(dE, 6)
        let lonRad = lon0 + X * dE - XI * pow(dE, 3) + XII * pow(dE, 5) - XIIA * pow(dE, 7)

        return CLLocationCoordinate2D(
            latitude: latRad * 180.0 / .pi,
            longitude: lonRad * 180.0 / .pi
        )
    }

    // MARK: - Parsing typed input

    /// Parse typed easting/northing strings into a coordinate.
    /// - full7: strings are full absolute metres (7 digits each).
    /// - grid5: strings are truncated to the local 100 km cell; `reference`
    ///   (typically the current map centre) recovers the 100 km prefix.
    ///   If no reference is supplied, the centre of Taiwan is assumed.
    static func parse(eastingText: String,
                      northingText: String,
                      mode: DigitMode,
                      reference: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D? {
        let eClean = eastingText.trimmingCharacters(in: .whitespaces)
        let nClean = northingText.trimmingCharacters(in: .whitespaces)
        guard let eVal = Double(eClean), let nVal = Double(nClean) else { return nil }
        guard eVal >= 0, nVal >= 0 else { return nil }

        let easting: Double
        let northing: Double

        switch mode {
        case .full7:
            easting = eVal
            northing = nVal
        case .grid5:
            // Recover the 100 km prefix from the reference coordinate.
            let ref = reference ?? CLLocationCoordinate2D(latitude: 23.7, longitude: 121.0)
            let (refE, refN) = project(ref)
            let e100 = floor(refE / 100000.0) * 100000.0
            let n100 = floor(refN / 100000.0) * 100000.0
            // Keep only the local part of the typed value (guard against >5 digits).
            easting = e100 + eVal.truncatingRemainder(dividingBy: 100000.0)
            northing = n100 + nVal.truncatingRemainder(dividingBy: 100000.0)
        }

        let coord = twd97ToLatLon(easting: easting, northing: northing)
        guard coord.latitude.isFinite, coord.longitude.isFinite else { return nil }
        return coord
    }

    // MARK: - Formatting helpers

    static func formatTWD97(_ coordinate: CLLocationCoordinate2D,
                            mode: DigitMode = .full7,
                            withSpaces: Bool = true) -> String {
        guard let twd = latLonToTWD97(coordinate, mode: mode) else {
            return "Out of TWD97 bounds"
        }
        return twd.formatted(withSpaces: withSpaces)
    }

    // MARK: - Validation

    static func isWithinBounds(_ coordinate: CLLocationCoordinate2D) -> Bool {
        return coordinate.latitude >= minLat && coordinate.latitude <= maxLat &&
               coordinate.longitude >= minLon && coordinate.longitude <= maxLon
    }
}

// MARK: - Extensions

extension CLLocationCoordinate2D {
    /// Convert to a TWD97 grid string in the given digit mode.
    func toTWD97(mode: TWD97Converter.DigitMode = .full7) -> String {
        TWD97Converter.formatTWD97(self, mode: mode)
    }

    /// Whether this coordinate falls inside the TWD97 (zone 121) bounds.
    var isWithinTWD97Bounds: Bool {
        TWD97Converter.isWithinBounds(self)
    }
}
