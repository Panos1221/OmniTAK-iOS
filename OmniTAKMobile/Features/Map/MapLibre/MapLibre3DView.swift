//
//  MapLibre3DView.swift
//  OmniTAKMobile
//
//  UIViewRepresentable wrapping the Mapbox Maps SDK v3 MapView with
//  terrain + atmosphere support. Type names preserved for source-compat
//  with existing call sites.
//

import SwiftUI
import MapboxMaps
import CoreLocation
import UIKit

// MARK: - Map View

struct MapLibre3DView: UIViewRepresentable {
    @ObservedObject var service: MapLibreService
    @Binding var camera: MapLibreCamera

    var onMapTap: ((CLLocationCoordinate2D) -> Void)?

    func makeUIView(context: Context) -> MapView {
        let cameraOpts = CameraOptions(
            center: camera.center,
            zoom: camera.zoom,
            bearing: camera.bearing,
            pitch: CGFloat(camera.pitch)
        )
        let initOpts = MapInitOptions(
            cameraOptions: cameraOpts,
            styleURI: service.currentStyle.styleURI
        )
        let mapView = MapView(frame: .zero, mapInitOptions: initOpts)

        // User-location puck (2D for now; 3D puck available via .puck3D())
        mapView.location.options.puckType = .puck2D()

        // Observe style + camera lifecycle via Mapbox signals
        let coord = context.coordinator
        coord.styleLoadedToken = mapView.mapboxMap.onStyleLoaded.observe { [weak service] _ in
            DispatchQueue.main.async {
                service?.isMapLoaded = true
                if service?.is3DEnabled == true {
                    service?.configureTerrain()
                }
            }
        }

        coord.cameraChangedToken = mapView.mapboxMap.onCameraChanged.observe { [weak mapView] _ in
            guard let mapView else { return }
            let state = mapView.mapboxMap.cameraState
            DispatchQueue.main.async {
                coord.parent.camera.center  = state.center
                coord.parent.camera.zoom    = state.zoom
                coord.parent.camera.bearing = state.bearing
                coord.parent.camera.pitch   = Double(state.pitch)
            }
        }

        let tap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)

        service.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MapView, context _: Context) {
        let current = mapView.mapboxMap.cameraState
        let changed =
            current.center.latitude  != camera.center.latitude  ||
            current.center.longitude != camera.center.longitude ||
            current.zoom    != camera.zoom    ||
            current.bearing != camera.bearing ||
            Double(current.pitch) != camera.pitch

        if changed {
            let opts = CameraOptions(
                center: camera.center,
                zoom: camera.zoom,
                bearing: camera.bearing,
                pitch: CGFloat(camera.pitch)
            )
            mapView.camera.ease(to: opts, duration: 0.3)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: MapLibre3DView
        var styleLoadedToken: AnyCancelable?
        var cameraChangedToken: AnyCancelable?

        init(_ parent: MapLibre3DView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: point)
            parent.onMapTap?(coordinate)
        }
    }
}

// MARK: - Camera State

struct MapLibreCamera: Equatable {
    var center: CLLocationCoordinate2D
    var zoom: Double
    var bearing: Double
    var pitch: Double

    static func == (lhs: MapLibreCamera, rhs: MapLibreCamera) -> Bool {
        lhs.center.latitude  == rhs.center.latitude  &&
        lhs.center.longitude == rhs.center.longitude &&
        lhs.zoom    == rhs.zoom    &&
        lhs.bearing == rhs.bearing &&
        lhs.pitch   == rhs.pitch
    }

    static let defaultCamera = MapLibreCamera(
        center: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365),
        zoom: 12, bearing: 0, pitch: 0
    )

    static let terrain3DCamera = MapLibreCamera(
        center: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365),
        zoom: 14, bearing: 0, pitch: 60
    )
}

// MARK: - Preview

struct MapLibre3DView_Previews: PreviewProvider {
    static var previews: some View {
        MapLibre3DView(
            service: MapLibreService.shared,
            camera: .constant(.defaultCamera)
        )
        .ignoresSafeArea()
    }
}
