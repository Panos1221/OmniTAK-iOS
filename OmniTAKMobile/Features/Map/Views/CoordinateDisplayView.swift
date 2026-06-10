import SwiftUI
import CoreLocation

// MARK: - Coordinate Display View
// ATAK-style coordinate display showing multiple formats (Lat/Lon, MGRS, UTM)

struct CoordinateDisplayView: View {
    let coordinate: CLLocationCoordinate2D?
    let isVisible: Bool
    @State private var selectedFormat: CoordinateFormat = .mgrs
    @State private var isExpanded: Bool = false

    var body: some View {
        if isVisible, let coordinate = coordinate {
            // Display inline - parent controls positioning
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    expandedCoordinateDisplay(for: coordinate)
                } else {
                    collapsedCoordinateDisplay(for: coordinate)
                }
            }
        }
    }

    private func collapsedCoordinateDisplay(for coordinate: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#00FFFF"))

            Text(selectedFormat.rawValue)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "#FFFC00"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = true
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }

    private func expandedCoordinateDisplay(for coordinate: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Format selector buttons - scrollable for better UX
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CoordinateFormat.allCases, id: \.self) { format in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedFormat = format
                            }
                            // Haptic feedback
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        }) {
                            VStack(spacing: 2) {
                                Text(format.rawValue)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(selectedFormat == format ? .black : .white)

                                // Show indicator for special formats
                                if format == .bng {
                                    Text("UK")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundColor(selectedFormat == format ? .black.opacity(0.7) : .white.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedFormat == format ? Color(hex: "#FFFC00") : Color.white.opacity(0.2))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(.bottom, 4)

            // Coordinate value display
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(selectedFormat.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gray)

                    // Special indicator for BNG
                    if selectedFormat == .bng {
                        Image(systemName: "map.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }

                Text(formatCoordinate(coordinate, format: selectedFormat))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#00FFFF"))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded = false
            }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }

    private func formatCoordinate(_ coordinate: CLLocationCoordinate2D, format: CoordinateFormat) -> String {
        switch format {
        case .latlon:
            return formatLatLon(coordinate)
        case .mgrs:
            return formatMGRS(coordinate)
        case .utm:
            return formatUTM(coordinate)
        case .bng:
            return formatBNG(coordinate)
        case .twd97:
            return formatTWD97(coordinate)
        }
    }

    // MARK: - Lat/Lon Formatting

    private func formatLatLon(_ coordinate: CLLocationCoordinate2D) -> String {
        let latDirection = coordinate.latitude >= 0 ? "N" : "S"
        let lonDirection = coordinate.longitude >= 0 ? "E" : "W"

        let lat = abs(coordinate.latitude)
        let lon = abs(coordinate.longitude)

        // Degrees, Minutes, Seconds format
        let latDeg = Int(lat)
        let latMin = Int((lat - Double(latDeg)) * 60)
        let latSec = Int(((lat - Double(latDeg)) * 60 - Double(latMin)) * 60)

        let lonDeg = Int(lon)
        let lonMin = Int((lon - Double(lonDeg)) * 60)
        let lonSec = Int(((lon - Double(lonDeg)) * 60 - Double(lonMin)) * 60)

        return String(format: "%02d°%02d'%02d\"%@ %03d°%02d'%02d\"%@",
                      latDeg, latMin, latSec, latDirection,
                      lonDeg, lonMin, lonSec, lonDirection)
    }

    // MARK: - MGRS Formatting

    private func formatMGRS(_ coordinate: CLLocationCoordinate2D) -> String {
        // Use the MGRSConverter for accurate conversion
        if MGRSConverter.isWithinMGRSBounds(coordinate) {
            return MGRSConverter.formatMGRS(coordinate, precision: .tenMeter, withSpaces: true)
        } else {
            return "Out of MGRS bounds"
        }
    }

    // MARK: - UTM Formatting

    private func formatUTM(_ coordinate: CLLocationCoordinate2D) -> String {
        // Use the MGRSConverter for accurate conversion
        return MGRSConverter.formatUTM(coordinate)
    }

    // MARK: - BNG Formatting

    private func formatBNG(_ coordinate: CLLocationCoordinate2D) -> String {
        // Use the BNGConverter for accurate conversion
        if BNGConverter.isWithinBNGBounds(coordinate) {
            return BNGConverter.formatBNG(coordinate, precision: .tenMeter, withSpaces: true)
        } else {
            return "Out of BNG bounds"
        }
    }

    // MARK: - TWD97 Formatting

    private func formatTWD97(_ coordinate: CLLocationCoordinate2D) -> String {
        // Full 7+7 absolute TM2 readout; entry sheet offers the 5+5 grid mode.
        return TWD97Converter.formatTWD97(coordinate, mode: .full7, withSpaces: true)
    }
}

// MARK: - Coordinate Format Enum

enum CoordinateFormat: String, CaseIterable {
    case latlon = "LAT/LON"
    case mgrs = "MGRS"
    case utm = "UTM"
    case bng = "BNG"
    case twd97 = "TWD97"

    var displayName: String {
        switch self {
        case .latlon:
            return "Latitude/Longitude"
        case .mgrs:
            return "Military Grid Reference System"
        case .utm:
            return "Universal Transverse Mercator"
        case .bng:
            return "British National Grid"
        case .twd97:
            return "TWD97 / TM2 (Taiwan)"
        }
    }
}

// MARK: - Preview

struct CoordinateDisplayView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.ignoresSafeArea()

            VStack(spacing: 40) {
                // Washington DC
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365),
                    isVisible: true
                )

                // Sydney, Australia
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
                    isVisible: true
                )

                // Tokyo, Japan
                CoordinateDisplayView(
                    coordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
                    isVisible: true
                )
            }
        }
    }
}
