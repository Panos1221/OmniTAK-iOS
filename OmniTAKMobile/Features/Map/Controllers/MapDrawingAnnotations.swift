//
//  MapDrawingAnnotations.swift
//  OmniTAKMobile
//
//  MKAnnotation classes for drawing-store shapes on the 2D engine.
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import MapKit
import CoreLocation
import UIKit

// MARK: - Drawing Marker Annotation

class DrawingMarkerAnnotation: NSObject, MKAnnotation {
    let marker: MarkerDrawing
    var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(marker: MarkerDrawing) {
        self.marker = marker
        self.coordinate = marker.coordinate
        self.title = marker.label
        self.subtitle = "Marker"
        super.init()
    }
}

// MARK: - Drawing Label Annotation (for shapes)

class DrawingLabelAnnotation: NSObject, MKAnnotation {
    let ownerID: UUID
    var coordinate: CLLocationCoordinate2D
    var label: String
    var color: DrawingColor

    init(ownerID: UUID, coordinate: CLLocationCoordinate2D, label: String, color: DrawingColor) {
        self.ownerID = ownerID
        self.coordinate = coordinate
        self.label = label
        self.color = color
        super.init()
    }
}

// Tagged annotation for in-progress drawing points so the diff-based
// update can distinguish them from other MKPointAnnotations. Live
// measurement rendering goes through MeasurementManager and
// CompactMeasurementOverlay, which use their own annotation handling.
class DrawingTempPointAnnotation: MKPointAnnotation {}
