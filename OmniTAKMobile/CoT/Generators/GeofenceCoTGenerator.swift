//
//  GeofenceCoTGenerator.swift
//  OmniTAKMobile
//
//  Generate CoT messages for geofence events
//

import Foundation
import CoreLocation

class GeofenceCoTGenerator {

    static func generateEventCoT(for event: GeofenceEvent, callsign: String) -> String {
        // Determine event type code
        let typeCode: String
        switch event.eventType {
        case .entry:
            typeCode = "b-a-o-tbl" // Alert - observe
        case .exit:
            typeCode = "b-a-o-can" // Alert - canceled
        case .dwell:
            typeCode = "b-a-o-opn" // Alert - open
        }

        let uid = "GEOFENCE-\(event.geofenceId.uuidString)-\(event.id.uuidString)"

        let dwellInfo: String
        if let duration = event.dwellDuration {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            dwellInfo = "\(minutes)m \(seconds)s"
        } else {
            dwellInfo = "N/A"
        }

        let eventDescription: String
        switch event.eventType {
        case .entry:
            eventDescription = "Entered geofence '\(event.geofenceName)'"
        case .exit:
            eventDescription = "Exited geofence '\(event.geofenceName)' (dwell: \(dwellInfo))"
        case .dwell:
            eventDescription = "Dwell threshold exceeded in '\(event.geofenceName)' (\(dwellInfo))"
        }

        let detail = """
                <contact callsign="\(callsign.xmlEscaped)"/>
                <remarks>\(eventDescription.xmlEscaped)</remarks>
                <__geofence id="\(event.geofenceId.uuidString)" name="\(event.geofenceName.xmlEscaped)" event="\(event.eventType.rawValue)" userId="\(event.userId)"/>
                <link uid="\(event.userId)" type="a-f-G" relation="p-p"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: typeCode,
            how: "h-g-i-g-o",
            start: event.timestamp,
            staleAfter: 3600, // 1 hour stale
            coordinate: event.coordinate,
            detail: detail
        )
    }

    static func generateGeofenceDefinitionCoT(for geofence: Geofence, callsign: String) -> String {
        let uid = "GEOFENCE-DEF-\(geofence.id.uuidString)"

        // Center point for the geofence
        let centerLat: Double
        let centerLon: Double

        switch geofence.type {
        case .circle:
            centerLat = geofence.center?.latitude ?? 0
            centerLon = geofence.center?.longitude ?? 0
        case .polygon:
            if let coords = geofence.polygonCoordinates, !coords.isEmpty {
                let avgLat = coords.map { $0.latitude }.reduce(0, +) / Double(coords.count)
                let avgLon = coords.map { $0.longitude }.reduce(0, +) / Double(coords.count)
                centerLat = avgLat
                centerLon = avgLon
            } else {
                centerLat = 0
                centerLon = 0
            }
        }

        var detail = """
                <contact callsign="\(callsign.xmlEscaped)"/>
                <remarks>Geofence: \(geofence.name.xmlEscaped)</remarks>
                <shape>
        """

        if geofence.type == .circle, let _ = geofence.center, let radius = geofence.radius {
            detail += """
                        <ellipse major="\(radius)" minor="\(radius)" angle="0"/>
            """
        } else if geofence.type == .polygon, let coords = geofence.polygonCoordinates {
            for coord in coords {
                detail += """
                            <polyline><vertex lat="\(coord.latitude)" lon="\(coord.longitude)"/></polyline>
                """
            }
        }

        detail += """
                </shape>
                <__geofencedef id="\(geofence.id.uuidString)" name="\(geofence.name.xmlEscaped)" type="\(geofence.type.rawValue)" color="\(geofence.color.hexColor)" active="\(geofence.isActive)" alertEntry="\(geofence.alertOnEntry)" alertExit="\(geofence.alertOnExit)" dwellThreshold="\(geofence.dwellTimeThreshold)"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: "u-d-c-c",
            how: "h-e",
            staleAfter: 86400, // 24 hour stale
            lat: centerLat,
            lon: centerLon,
            detail: detail
        )
    }
}
