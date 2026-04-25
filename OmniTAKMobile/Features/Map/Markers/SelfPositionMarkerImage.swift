//
//  SelfPositionMarkerImage.swift
//  OmniTAKMobile
//
//  ATAK-style tactical bullseye rendered as a UIImage, used as the
//  custom MKAnnotationView image for MKUserLocation. Mirrors the
//  Android `ic_self_marker.xml` vector drawable so both clients show
//  the same self-position iconography.
//

import UIKit

enum SelfPositionMarkerImage {

    /// Tactical accent (Compose: TacticalAccent #4ADE80) — matches
    /// `accent.primary` in DESIGN_TOKENS.md.
    private static let tacticalAccent = UIColor(red: 74/255.0, green: 222/255.0, blue: 128/255.0, alpha: 1.0)

    /// Tactical dark navy (Compose: TacticalBackground #0A1628).
    private static let tacticalDark = UIColor(red: 10/255.0, green: 22/255.0, blue: 40/255.0, alpha: 1.0)

    /// 32×32 bullseye: dark outer ring → green fill → dark inner dot.
    /// Same proportions as Android `ic_self_marker.xml`.
    static let bullseye: UIImage = {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Outer dark ring (full bounds)
            tacticalDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 28, height: 28)).fill()

            // Tactical-accent green fill (inset 4 from edge)
            tacticalAccent.setFill()
            UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 24, height: 24)).fill()

            // Inner dark dot (5pt radius, centered)
            tacticalDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 10, height: 10)).fill()
        }
    }()
}
