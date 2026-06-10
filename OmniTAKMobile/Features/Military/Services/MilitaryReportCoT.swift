//
//  MilitaryReportCoT.swift
//  OmniTAKMobile
//
//  Shared CoT build + send pipeline for the military report views
//  (9-Line CAS, MEDEVAC, SPOTREP). Previously each view carried a
//  line-for-line clone of the envelope builder and the send/haptics
//  block — and the copy-paste had frozen MEDEVAC's CoT type
//  (b-r-f-h-c) into all three reports.
//

import Foundation
import UIKit
import os

enum MilitaryReportCoT {

    /// CoT types per report, chosen against the codebase's own type
    /// catalog (MarkerCoTGenerator.CoTTypes) and TAK conventions:
    /// - MEDEVAC/CASEVAC: b-r-f-h-c — the standard casevac request type
    ///   (ATAK Medline; the repo's federation layer maps the b-r-f-h-c
    ///   prefix to casevac).
    /// - 9-Line CAS: a-h-G — ATAK's fires workflow attaches the nine-line
    ///   to the hostile target marker (an atom), so the request plots a
    ///   hostile ground target at the target coordinates with the <cas>
    ///   detail riding along. (CoTTypes.hostileGround family.)
    /// - SPOTREP: b-m-p-w — the codebase's own CoTTypes.spotReport
    ///   constant ("Waypoint/Spot"); receivers render a map point at the
    ///   observed location with the <spotrep> detail attached.
    enum ReportType: String {
        case medevac = "b-r-f-h-c"
        case nineLineCAS = "a-h-G"
        case spotrep = "b-m-p-w"
    }

    /// Build a report CoT event. The shared envelope matches what all
    /// three views previously emitted: how=h-g-i-g-o, 1 hour stale,
    /// unknown accuracy point at the report location.
    ///
    /// - Parameters:
    ///   - uid: Report UID (e.g. "MEDEVAC-{id}").
    ///   - type: Report CoT type.
    ///   - senderCallsign: Contact callsign (escaped here).
    ///   - lat/lon: Report location.
    ///   - reportDetail: Report-specific detail children — caller
    ///     escapes its own field content via String.xmlEscaped.
    ///   - remarks: Free-text remarks (escaped here).
    static func buildReportEvent(
        uid: String,
        type: ReportType,
        senderCallsign: String,
        lat: Double,
        lon: Double,
        reportDetail: String,
        remarks: String
    ) -> String {
        let detail = """
                <contact callsign="\(senderCallsign.xmlEscaped)"/>
        \(reportDetail)
                <remarks>\(remarks.xmlEscaped)</remarks>
        """
        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: type.rawValue,
            how: "h-g-i-g-o",
            staleAfter: 3600,
            lat: lat,
            lon: lon,
            detail: detail
        )
    }

    /// Send a report through TAKService with the shared logging and
    /// haptic feedback. Returns true on success so the caller can
    /// drive its sent/error alert state.
    @discardableResult
    static func sendReport(xml: String, logTag: String) -> Bool {
        let success = TAKService.shared.sendCoT(xml: xml)
        Logger.military.info("\(logTag, privacy: .public) send success=\(success, privacy: .public)")

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(success ? .success : .error)
        return success
    }
}
