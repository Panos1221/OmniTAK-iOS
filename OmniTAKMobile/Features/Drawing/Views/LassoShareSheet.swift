//
//  LassoShareSheet.swift
//  OmniTAKMobile
//
//  Issue #16 — thin UIViewControllerRepresentable around
//  UIActivityViewController so SwiftUI's `.sheet(item:)` can hand off
//  the exported KML or Mission Package zip from
//  LassoExporters.swift to the system share sheet. Identical pattern
//  to the existing Track / data-package share flows; kept local to
//  the lasso feature so the wiring is one obvious place.
//

import SwiftUI
import UIKit

struct LassoShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
