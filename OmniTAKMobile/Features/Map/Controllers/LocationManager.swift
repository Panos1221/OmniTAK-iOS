//
//  LocationManager.swift
//  OmniTAKMobile
//
//  Operator GPS source shared app-wide (LocationManager.shared).
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import SwiftUI
import CoreLocation

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var accuracy: Double = 0
    @Published var heading: CLHeading?
    @Published var course: Double = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Enable background location updates for navigation and position tracking
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true

        // Request authorization - start with when in use, then prompt for always
        requestLocationAuthorization()

        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Request location authorization with escalation to Always
    func requestLocationAuthorization() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        switch status {
        case .notDetermined:
            // First request when in use, then iOS will prompt for upgrade
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Request upgrade to Always for background operation
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            // Already have full access
            break
        case .denied, .restricted:
            // User denied - they'll need to enable in Settings
            print("[LocationManager] Location access denied or restricted")
        @unknown default:
            break
        }
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.authorizationStatus = status

            // If user just granted when-in-use, request always
            if status == .authorizedWhenInUse {
                // Slight delay before requesting upgrade
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    manager.requestAlwaysAuthorization()
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        accuracy = locations.last?.horizontalAccuracy ?? 0
        course = locations.last?.course ?? 0
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Location error: \(error.localizedDescription)")
    }
}
