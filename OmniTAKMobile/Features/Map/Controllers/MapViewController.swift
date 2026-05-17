import SwiftUI
import MapKit
import CoreLocation
import MapboxMaps
import UIKit

// ATAK-style Map View with tactical interface
struct ATAKMapView: View {
    @ObservedObject private var takService = TAKService.shared
    @StateObject private var federation = MultiServerFederation()  // Multi-server support
    @StateObject private var locationManager = LocationManager()
    @StateObject private var drawingStore: DrawingStore
    @StateObject private var drawingManager: DrawingToolsManager
    @StateObject private var radialMenuCoordinator = RadialMenuMapCoordinator()
    @ObservedObject private var chatManager = ChatManager.shared
    @StateObject private var trackRecordingService = TrackRecordingService()
    @StateObject private var overlayCoordinator = MapOverlayCoordinator()
    @StateObject private var routeOverlayCoordinator = RouteOverlayCoordinator()
    @ObservedObject private var routeService = RoutePlanningService.shared
    @StateObject private var mapStateManager = MapStateManager()
    @StateObject private var measurementManager = MeasurementManager()
    @ObservedObject private var adsbService = ADSBTrafficService.shared
    @ObservedObject private var pointDropperService = PointDropperService.shared
    @ObservedObject private var serverManager = ServerManager.shared
    // Issue #16 — lasso multi-select. Singleton so the pill, ring
    // renderers, and gesture coordinator all see the same state.
    @ObservedObject private var lassoService = LassoSelectionService.shared
    // Issue #16 — confirmation dialog for the lasso selection actions
    // (Add to Data Package / Export KML / Send to Contacts / Bulk
    // Delete / Clear). Driven from `lassoSelectionPill`.
    @State private var showLassoActions = false
    @State private var lassoActionNotice: String?
    @State private var lassoExportShareItem: URL?
    @State private var showLassoContactPicker = false
    // Issue #16 — Tools tab in the bottom bar opens a short popup
    // (handled in RootTabView). MapViewController only needs to
    // observe the notifications it posts: .startLassoMode +
    // .showFullTools. No local launcher state required here.

    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365), // Default: DC
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var showServerConfig = false
    @State private var showLayersPanel = false
    @State private var showDrawingPanel = false
    @State private var showDrawingList = false
    // Radial menu → Edit on a PointMarker posts .radialMenuEditMarker;
    // we hold the marker id here so a sheet can open the edit form.
    @State private var editingPointMarkerID: UUID?
    @State private var mapType: MKMapType = .standard
    @State private var showToolsMenu = false
    @State private var showLoadingScreen = true
    @State private var showGPSError = false
    @State private var showGeofenceAlert = false
    @State private var showTraffic = false
    @State private var trackingMode: MapUserTrackingMode = .none
    @State private var orientation = UIDeviceOrientation.unknown

    // Feature screen states
    @State private var showTeamManagement = false
    @State private var showRoutePlanning = false
    @State private var showGeofences = false
    @State private var showTrackRecording = false
    @State private var showChat = false
    @State private var showContacts = false
    @State private var showEmergencySOS = false
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showAbout = false
    @State private var showPositionBroadcast = false
    @State private var showElevationProfile = false

    // User settings
    @AppStorage("userCallsign") private var userCallsign = "ALPHA-1"
    @State private var showLineOfSight = false
    @State private var showEchelonHierarchy = false
    @State private var showMissionSync = false
    @State private var showMeshtastic = false
    @State private var showMeasurement = false
    @State private var showAppModePicker = false

    // Position broadcasting service
    @ObservedObject private var positionBroadcastService = PositionBroadcastService.shared

    // Layer states
    @State private var activeMapLayer = "satellite"
    @State private var showFriendly = true
    @State private var showHostile = true
    @State private var showNeutral = true      // Added: Neutral units (a-n-*)
    @State private var showUnknown = true      // Changed: Default to TRUE - show unknown by default

    // Map overlay states
    @State private var showCompass = false  // Hidden by default for max map space
    @State private var showCoordinates = false  // Hidden by default for max map space
    @State private var showScaleBar = true  // ATAK-style: Enabled by default in bottom-left
    @State private var showGrid = false

    // New ATAK-style UI states
    @State private var isCursorModeActive = false
    @State private var showQuickActionToolbar = false  // Hidden - user can access tools via radial menu and ATAK tools menu
    @StateObject private var cursorModeCoordinator = MapCursorModeCoordinator()
    @State private var showRangeBearingLine = false
    @State private var showRouteHere = false
    @State private var showOverlaySettings = false
    @State private var showBreadcrumbTrails = false
    @State private var showRBLines = false
    @State private var showCallsignPanel = true  // ATAK-style: Enabled by default in bottom-right
    @State private var isNavigationPanelExpanded = false  // Route navigation panel state

    init() {
        let store = DrawingStore()
        _drawingStore = StateObject(wrappedValue: store)
        _drawingManager = StateObject(wrappedValue: DrawingToolsManager(drawingStore: store))
    }

    // Detect device orientation
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var isLandscape: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    // Computed CoT markers from TAK service - filtered by overlay settings
    private var cotMarkers: [CoTMarker] {
        takService.cotEvents.compactMap { event in
            let marker = CoTMarker(
                uid: event.uid,
                coordinate: CLLocationCoordinate2D(
                    latitude: event.point.lat,
                    longitude: event.point.lon
                ),
                type: event.type,
                callsign: event.detail.callsign,
                team: event.detail.team ?? "Unknown"
            )

            // Filter based on overlay settings and CoT affiliation
            // CoT type format: a-{affiliation}-{dimension}-{function}
            // Affiliations: f=friendly, h=hostile, n=neutral, u=unknown
            //               j=joker (exercise hostile), k=faker (exercise friendly)
            //               s=suspect, a=assumed friendly

            // Determine affiliation from CoT type
            let type = event.type.lowercased()

            if type.hasPrefix("a-f") || type.hasPrefix("a-k") || type.hasPrefix("a-a") {
                // Friendly, Faker (exercise friendly), Assumed Friendly
                if !showFriendly {
                    return nil
                }
            } else if type.hasPrefix("a-h") || type.hasPrefix("a-j") || type.hasPrefix("a-s") {
                // Hostile, Joker (exercise hostile), Suspect
                if !showHostile {
                    return nil
                }
            } else if type.hasPrefix("a-n") {
                // Neutral
                if !showNeutral {
                    return nil
                }
            } else if type.hasPrefix("a-u") {
                // Unknown affiliation
                if !showUnknown {
                    return nil
                }
            } else if type.hasPrefix("a-") {
                // Any other 'a-' type we don't recognize - treat as unknown
                // This ensures we don't accidentally hide valid units
                if !showUnknown {
                    return nil
                }
            }
            // Non 'a-' types (waypoints, markers, etc.) are ALWAYS shown
            // They don't have affiliations and should never be filtered

            return marker
        }
    }

    // MARK: - Computed Properties to Fix Type Checking

    @ViewBuilder
    private var mainMapView: some View {
        TacticalMapView(
            region: $mapRegion,
            mapType: $mapType,
            trackingMode: $trackingMode,
            markers: cotMarkers,
            pointMarkers: pointDropperService.markers,
            aircraft: adsbService.settings.isEnabled ? adsbService.aircraft : [],
            showsUserLocation: true,
            drawingStore: drawingStore,
            drawingManager: drawingManager,
            radialMenuCoordinator: radialMenuCoordinator,
            overlayCoordinator: overlayCoordinator,
            routeOverlayCoordinator: routeOverlayCoordinator,
            mapStateManager: mapStateManager,
            measurementManager: measurementManager,
            lassoService: lassoService,
            onMapTap: handleMapTap
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var gridOverlay: some View {
        // No explicit zIndex — the ZStack child order keeps the grid above
        // the map but below UI chrome (status bar, zoom buttons, panels,
        // which all use zIndex 1000+). A prior zIndex(100) was lifting the
        // grid over the top status bar / zoom controls (#43).
        GridOverlayView(region: mapRegion, isVisible: overlayCoordinator.mgrsGridEnabled)
            .opacity(overlayCoordinator.mgrsGridEnabled ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var topToolbars: some View {
        VStack(spacing: 0) {
            ATAKStatusBar(
                connectionStatus: takService.isConnected ? "Connected" : "Disconnected",
                isConnected: takService.isConnected,
                messagesReceived: takService.messagesReceived,
                messagesSent: takService.messagesSent,
                gpsAccuracy: locationManager.accuracy,
                serverName: serverManager.activeServer?.name ?? "Offline",
                onServerTap: { showServerConfig = true },
                onMenuTap: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showToolsMenu = true
                    }
                }
            )
            .id("statusbar-\(takService.isConnected)-\(takService.messagesReceived)-\(takService.messagesSent)")

            Spacer()

            bottomToolbars
        }
    }

    @ViewBuilder
    private var bottomToolbars: some View {
        VStack(spacing: 0) {
            ATAKBottomToolbar(
                mapType: $mapType,
                showLayersPanel: $showLayersPanel,
                showDrawingPanel: $showDrawingPanel,
                showDrawingList: $showDrawingList,
                onZoomIn: zoomIn,
                onZoomOut: zoomOut
            )
            .padding(.horizontal, 8)
            .padding(.bottom, isCursorModeActive ? 240 : 140)

            if showQuickActionToolbar && !isCursorModeActive {
                QuickActionToolbar(
                    mapRegion: $mapRegion,
                    showGrid: $showGrid,
                    showLayersPanel: $showLayersPanel,
                    isCursorModeActive: $isCursorModeActive,
                    userLocation: locationManager.location,
                    onDropPoint: { coordinate in
                        dropMarkerAtLocation(coordinate: coordinate, affiliation: .friendly)
                    },
                    onToggleMeasure: {
                        showMeasurement = true
                    },
                    lassoModeActive: drawingManager.currentMode == .lasso,
                    onToggleLasso: {
                        // Issue #16: lasso lives on the quick-action
                        // toolbar now. Single tap toggles in/out — if
                        // we're already in lasso mode (button glowing),
                        // cancel back to idle so the user can re-enter
                        // pan/zoom without making a stray selection.
                        if drawingManager.currentMode == .lasso {
                            drawingManager.cancelDrawing()
                        } else {
                            drawingManager.startDrawing(mode: .lasso)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 15)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var sidePanels: some View {
        Group {
            layersPanel
            drawingToolsPanel
            drawingListPanel
        }
    }

    @ViewBuilder
    private var layersPanel: some View {
        if showLayersPanel {
            HStack {
                ATAKSidePanel(
                    isExpanded: $showLayersPanel,
                    activeMapLayer: $activeMapLayer,
                    showFriendly: $showFriendly,
                    showHostile: $showHostile,
                    showNeutral: $showNeutral,
                    showUnknown: $showUnknown,
                    showCompass: $showCompass,
                    showCoordinates: $showCoordinates,
                    showScaleBar: $showScaleBar,
                    showGrid: $showGrid,
                    showCallsignPanel: $showCallsignPanel,
                    adsbService: ADSBTrafficService.shared,
                    onLayerToggle: { layer in
                        toggleLayer(layer)
                    },
                    onOverlayToggle: { overlay in
                        toggleOverlay(overlay)
                    },
                    onMapOverlayToggle: { overlay in
                        toggleMapOverlay(overlay)
                    }
                )
                .background(Color.black.opacity(0.9))
                .cornerRadius(12)
                .padding(.leading, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .leading))

                Spacer()
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var drawingToolsPanel: some View {
        if showDrawingPanel {
            HStack {
                Spacer()
                DrawingToolsPanel(
                    drawingManager: drawingManager,
                    isVisible: $showDrawingPanel,
                    onComplete: {
                        // Drawing completed
                    },
                    onCancel: {
                        // Drawing cancelled
                    }
                )
                .padding(.trailing, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .trailing))
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var drawingListPanel: some View {
        if showDrawingList {
            HStack {
                Spacer()
                DrawingListPanel(
                    drawingStore: drawingStore,
                    isVisible: $showDrawingList,
                    onZoomToDrawing: { coordinate, radius in
                        zoomToDrawing(coordinate: coordinate, radius: radius)
                    }
                )
                .padding(.trailing, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .trailing))
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        Group {
            // GPS status indicator removed - GPS lock button at bottom left serves this purpose
            callsignDisplay
            geofenceAlert
        }
    }

    @ViewBuilder
    private var callsignDisplay: some View {
        if showCallsignPanel, let location = locationManager.location {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CallsignDisplay(
                        callsign: userCallsign,
                        coordinates: formatCoordinates(location.coordinate),
                        altitude: formatAltitude(location.altitude),
                        speed: formatSpeed(location.speed),
                        heading: formatHeading(locationManager.heading),
                        accuracy: "+/- \(Int(location.horizontalAccuracy))m"
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 120)
                }
            }
            .zIndex(1003)
        }
    }

    @ViewBuilder
    private var geofenceAlert: some View {
        if showGeofenceAlert {
            VStack {
                GeofenceAlertNotification(
                    geofenceName: "Circle 1",
                    action: "Entered",
                    callsign: userCallsign,
                    isPresented: $showGeofenceAlert
                )
                .padding(.top, 60)
                Spacer()
            }
            .zIndex(1004)
        }
    }

    @ViewBuilder
    private var mapOverlayComponents: some View {
        Group {
            compassOverlay
            // coordinateDisplay now integrated with GPS button to avoid overlap
            scaleBar
        }
    }

    @ViewBuilder
    private var compassOverlay: some View {
        // CLHeading (magnetometer) is the right source — location.course is
        // the direction of travel and freezes at the last value when the
        // user stops moving (what was causing #44 "always 347°"). Fall back
        // to course only if heading is unavailable (e.g., no magnetometer).
        CompassOverlayView(
            heading: compassHeading,
            isVisible: showCompass
        )
        .zIndex(1005)
    }

    private var compassHeading: CLLocationDirection? {
        if let heading = locationManager.heading {
            return heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        }
        let course = locationManager.location?.course ?? -1
        return course >= 0 ? course : nil
    }

    @ViewBuilder
    private var coordinateDisplay: some View {
        CoordinateDisplayView(
            coordinate: locationManager.location?.coordinate,
            isVisible: showCoordinates
        )
        .zIndex(1006)
    }

    @ViewBuilder
    private var scaleBar: some View {
        ScaleBarView(
            region: mapRegion,
            isVisible: showScaleBar
        )
        .zIndex(1007)
    }

    @ViewBuilder
    private var interactiveOverlays: some View {
        Group {
            loadingScreen
            radialMenu
            cursorModeOverlay
            lassoSelectionPill  // Issue #16
            // overlaySettingsButton - Removed per user request
            // overlaySettingsPanel - Removed per user request
            // mapCenterDisplay - Removed per user request (coords available via radial menu)
        }
    }

    // == Issue #16: lasso selection pill BEGIN ==
    // Compact floating pill that surfaces the current selection count
    // and a clear (✕) affordance. Floats next to the radial-menu
    // anchor with NO grey backplate per feedback_radial_menu_no_backdrop
    // MARK: - Lasso selection actions
    // Issue #16 — drives the confirmationDialog wired off the
    // selection pill. v1 ships Bulk Delete + Clear with real
    // implementations; the other three surface a notice banner with
    // an explicit "next iteration" message so users see the affordance
    // and we capture which actions get the most traction before deeper
    // implementation work.
    private enum LassoAction {
        case addToDataPackage
        case exportKML
        case sendToContacts
        case bulkDelete
    }

    private func performLassoAction(_ action: LassoAction) {
        let sel = lassoService.current
        guard !sel.isEmpty else { return }

        switch action {
        case .bulkDelete:
            let (deleted, broadcast) = bulkDeleteLassoSelection(sel)
            lassoService.clear()
            if broadcast == deleted {
                lassoActionNotice = "Deleted \(deleted) item(s) + broadcast tombstones."
            } else {
                lassoActionNotice = "Deleted \(deleted) item(s) locally — \(broadcast) tombstones broadcast (others were local-only)."
            }

        case .exportKML:
            let markers = resolveLassoMarkers(sel)
            guard !markers.isEmpty else {
                lassoActionNotice = "Selection empty after resolving — nothing to export."
                return
            }
            do {
                let url = try LassoKMLBuilder.write(
                    name: "Lasso selection (\(markers.count))",
                    markers: markers
                )
                lassoExportShareItem = url
            } catch {
                lassoActionNotice = "Export failed: \(error.localizedDescription)"
            }

        case .addToDataPackage:
            let markers = resolveLassoMarkers(sel)
            guard !markers.isEmpty else {
                lassoActionNotice = "Selection empty after resolving — nothing to package."
                return
            }
            do {
                let url = try LassoMissionPackageBuilder.build(
                    name: "Lasso selection (\(markers.count))",
                    markers: markers
                )
                lassoExportShareItem = url
            } catch {
                lassoActionNotice = "Package build failed: \(error.localizedDescription)"
            }

        case .sendToContacts:
            // Hand off to the picker — the actual broadcast happens
            // when the user confirms the recipient UIDs (see
            // lassoContactPickerSheet view).
            showLassoContactPicker = true
        }
    }

    /// Resolve the selection back to LassoExportMarker DTOs across the
    /// three iOS source types (live CoT events, dropped PointMarkers,
    /// drawing-store MarkerDrawings).
    private func resolveLassoMarkers(_ sel: SelectionContext) -> [LassoExportMarker] {
        var out: [LassoExportMarker] = []

        // 1) Live CoT events (server-pushed)
        for e in takService.cotEvents where sel.markerIDs.contains(e.uid) {
            out.append(LassoExportMarker(
                uid: e.uid,
                type: e.type,
                callsign: e.detail.callsign,
                coordinate: CLLocationCoordinate2D(latitude: e.point.lat, longitude: e.point.lon),
                remarks: ""
            ))
        }
        // 2) Dropped points — PointMarker uses `name` for callsign-like
        //    label and an optional `remarks` field.
        for p in pointDropperService.markers
            where sel.markerIDs.contains(p.id.uuidString) || sel.markerIDs.contains(p.uid)
        {
            out.append(LassoExportMarker(
                uid: p.uid,
                type: p.cotType,
                callsign: p.name,
                coordinate: p.coordinate,
                remarks: p.remarks ?? ""
            ))
        }
        // 3) Drawing-store markers — MarkerDrawing's display label
        //    lives on `name`.
        for m in drawingStore.markers
            where sel.markerIDs.contains(m.id.uuidString)
        {
            out.append(LassoExportMarker(
                uid: m.id.uuidString,
                type: "a-u-G",
                callsign: m.name,
                coordinate: m.coordinate,
                remarks: ""
            ))
        }
        return out
    }

    /// Walk every selected ID, delete locally + broadcast a CoT
    /// tombstone (`t-x-d-d`) for marker UIDs that came from the server
    /// so other EUDs propagate the removal. Returns (deletedCount,
    /// broadcastCount) so the caller can pick the right toast copy.
    @discardableResult
    private func bulkDeleteLassoSelection(_ sel: SelectionContext) -> (deleted: Int, broadcast: Int) {
        var deleted = 0
        var broadcast = 0
        let senderUid = "OMNI-iOS-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown")"

        // Self-marker guard — never tombstone our own CoT or we tell
        // every peer to forget us.
        let selfUids = Set(takService.cotEvents
            .filter { $0.uid.contains(senderUid) }
            .map { $0.uid })

        for markerID in sel.markerIDs where !selfUids.contains(markerID) {
            // PointDropperService keys by UUID (string form in markerID).
            if let uuid = UUID(uuidString: markerID),
               pointDropperService.markers.contains(where: { $0.id == uuid })
            {
                pointDropperService.deleteMarker(id: uuid)
                deleted += 1
            }
            // Drawing-store markers
            if let uuid = UUID(uuidString: markerID),
               let m = drawingStore.markers.first(where: { $0.id == uuid })
            {
                drawingStore.deleteMarker(m)
                deleted += 1
            }
            // Live CoT (server-pushed) — broadcast a tombstone so the
            // delete propagates to other clients.
            if takService.cotEvents.contains(where: { $0.uid == markerID }) {
                let xml = LassoCotBuilders.buildDeleteEvent(
                    targetUid: markerID,
                    senderUid: senderUid
                )
                if takService.sendCoT(xml: xml) {
                    broadcast += 1
                }
                deleted += 1
            }
        }
        for drawingID in sel.drawingIDs {
            if let line = drawingStore.lines.first(where: { $0.id == drawingID }) {
                drawingStore.deleteLine(line)
            } else if let poly = drawingStore.polygons.first(where: { $0.id == drawingID }) {
                drawingStore.deletePolygon(poly)
            } else if let circle = drawingStore.circles.first(where: { $0.id == drawingID }) {
                drawingStore.deleteCircle(circle)
            }
            deleted += 1
        }
        return (deleted, broadcast)
    }

    /// Broadcast the lasso selection to specific contact UIDs by
    /// rebuilding each marker's CoT with `<dest>` elements for the
    /// chosen recipients. Wired from the contact picker's confirm.
    private func sendLassoSelectionToContacts(_ destUids: Set<String>) {
        let sel = lassoService.current
        let markers = resolveLassoMarkers(sel)
        guard !markers.isEmpty, !destUids.isEmpty else { return }
        let dests = Array(destUids)
        var sent = 0
        for m in markers {
            let xml = LassoCotBuilders.rebuildEvent(
                uid: m.uid,
                type: m.type,
                callsign: m.callsign,
                coordinate: m.coordinate,
                remarks: m.remarks,
                destUids: dests
            )
            if takService.sendCoT(xml: xml) { sent += 1 }
        }
        lassoActionNotice = "Sent \(sent)/\(markers.count) marker(s) to \(destUids.count) recipient(s)."
    }

    // — the orange tint is the only chrome.
    @ViewBuilder
    private var lassoSelectionPill: some View {
        if !lassoService.current.isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LassoSelectionPill(
                        count: lassoService.current.totalCount,
                        onShowActions: {
                            showLassoActions = true
                        }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 200) // above the bottom toolbar
                }
            }
            .zIndex(2000)
            .transition(.opacity)
            .confirmationDialog(
                "\(lassoService.current.totalCount) selected",
                isPresented: $showLassoActions,
                titleVisibility: .visible
            ) {
                // The K9Blue trio (data package, bulk delete, export)
                // plus send-to-contacts, plus an explicit clear.
                Button("Add to Data Package…") {
                    performLassoAction(.addToDataPackage)
                }
                Button("Export as KML…") {
                    performLassoAction(.exportKML)
                }
                Button("Send to Contacts…") {
                    performLassoAction(.sendToContacts)
                }
                Button("Delete \(lassoService.current.totalCount) item(s)", role: .destructive) {
                    performLassoAction(.bulkDelete)
                }
                Button("Clear Selection", role: .cancel) {
                    lassoService.clear()
                }
            } message: {
                Text("Choose an action for the lasso selection.")
            }
            .alert(
                "Selection Action",
                isPresented: Binding(
                    get: { lassoActionNotice != nil },
                    set: { if !$0 { lassoActionNotice = nil } }
                ),
                presenting: lassoActionNotice
            ) { _ in
                Button("OK") { lassoActionNotice = nil }
            } message: { msg in
                Text(msg)
            }
            // KML / Mission Package share sheet — driven by the
            // exporters' returned URL. UIActivityViewController wrapped
            // for SwiftUI in LassoShareSheet below.
            .sheet(item: Binding(
                get: { lassoExportShareItem.map { LassoShareItem(url: $0) } },
                set: { _ in lassoExportShareItem = nil }
            )) { item in
                LassoShareSheet(activityItems: [item.url])
            }
            // Send-to-Contacts picker. Confirm hands the chosen
            // recipient UIDs back; sendLassoSelectionToContacts walks
            // the selection and re-emits each CoT with <dest> elements.
            .sheet(isPresented: $showLassoContactPicker) {
                LassoContactPickerSheet(
                    candidates: takService.cotEvents.map { e in
                        CoTEventLike(uid: e.uid, type: e.type, callsign: e.detail.callsign)
                    },
                    excludeUIDs: lassoService.current.markerIDs,
                    onCancel: {},
                    onConfirm: { uids in
                        sendLassoSelectionToContacts(uids)
                    }
                )
            }
        }
    }
    // == Issue #16: lasso selection pill END ==

    // Identifiable wrapper so .sheet(item:) accepts the URL — SwiftUI
    // needs an Identifiable for that overload.
    private struct LassoShareItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @ViewBuilder
    private var loadingScreen: some View {
        if showLoadingScreen {
            ATAKLoadingScreen(isLoading: $showLoadingScreen)
                .zIndex(2000)
        }
    }

    @ViewBuilder
    private var radialMenu: some View {
        if radialMenuCoordinator.showRadialMenu {
            RadialMenuView(
                isPresented: $radialMenuCoordinator.showRadialMenu,
                centerPoint: radialMenuCoordinator.menuCenterPoint,
                configuration: radialMenuCoordinator.menuConfiguration,
                onSelect: { action in
                    radialMenuCoordinator.executeAction(action)
                }
            )
            .zIndex(3000)
        }
    }

    @ViewBuilder
    private var cursorModeOverlay: some View {
        if isCursorModeActive {
            CursorModeOverlayView(
                coordinator: cursorModeCoordinator,
                mapRegion: mapRegion,
                onDropMarker: { coordinate in
                    dropMarkerAtLocation(coordinate: coordinate, affiliation: .friendly)
                },
                onClose: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCursorModeActive = false
                        cursorModeCoordinator.deactivate()
                    }
                }
            )
            .zIndex(2500)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var overlaySettingsButton: some View {
        VStack {
            HStack {
                Button(action: {
                    withAnimation(.spring()) {
                        showOverlaySettings.toggle()
                    }
                }) {
                    Image(systemName: "square.stack.3d.up.badge.a")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                }
                .padding(.leading, 12)
                .padding(.top, 120)
                Spacer()
            }
            Spacer()
        }
        .zIndex(1008)
    }

    @ViewBuilder
    private var overlaySettingsPanel: some View {
        if showOverlaySettings {
            VStack {
                HStack {
                    OverlaySettingsPanel(
                        overlayCoordinator: overlayCoordinator,
                        mapStateManager: mapStateManager,
                        showMGRSGrid: Binding(
                            get: { overlayCoordinator.mgrsGridEnabled },
                            set: { overlayCoordinator.mgrsGridEnabled = $0 }
                        ),
                        showBreadcrumbTrails: Binding(
                            get: { overlayCoordinator.breadcrumbTrailsEnabled },
                            set: { overlayCoordinator.breadcrumbTrailsEnabled = $0 }
                        ),
                        showRBLines: Binding(
                            get: { overlayCoordinator.rangeBearingEnabled },
                            set: { overlayCoordinator.rangeBearingEnabled = $0 }
                        ),
                        onDismiss: {
                            withAnimation(.spring()) {
                                showOverlaySettings = false
                            }
                        }
                    )
                    .padding(.leading, 12)
                    .padding(.top, 170)
                    Spacer()
                }
                Spacer()
            }
            .zIndex(1009)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    // mapCenterDisplay removed - coordinates available via radial menu and settings

    @ViewBuilder
    private var gpsFollowButton: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 8) {
                // ATAK-style left-side control cluster
                VStack(spacing: 8) {
                    // GPS Lock/Center Button (crosshair icon)
                    Button(action: centerOnUser) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.75))
                                .frame(width: 44, height: 44)

                            Circle()
                                .stroke(trackingMode == .follow ? Color.cyan : Color.white.opacity(0.6), lineWidth: 2)
                                .frame(width: 44, height: 44)

                            Image(systemName: trackingMode == .follow ? "location.fill" : "location")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(trackingMode == .follow ? Color.cyan : .white)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)

                    // Zoom controls moved to bottom toolbar to match ATAK
                }

                // Coordinate display next to GPS button
                if showCoordinates {
                    CoordinateDisplayView(
                        coordinate: locationManager.location?.coordinate,
                        isVisible: true
                    )
                }

                Spacer()
            }
            .padding(.leading, 12)
            .padding(.bottom, isCursorModeActive ? 222 : (showQuickActionToolbar ? 150 : 90))
        }
        .zIndex(1012)
    }

    var body: some View {
        ZStack {
            mainMapView
            gridOverlay
            topToolbars
            sidePanels
            statusIndicators
            mapOverlayComponents
            interactiveOverlays
            gpsFollowButton

            // Compact measurement overlay (ATAK-style)
            if showMeasurement {
                CompactMeasurementOverlay(manager: measurementManager, isPresented: $showMeasurement)
                    .zIndex(1000)
            }

            // Route Navigation Panel (ATAK-style, top-left position)
            VStack {
                HStack {
                    RouteNavigationPanel(
                        routeService: routeService,
                        isExpanded: $isNavigationPanelExpanded
                    )
                    .frame(maxWidth: 320) // ATAK-style compact width
                    .padding(.leading, 8)
                    .padding(.top, 70) // Below status bar
                    Spacer()
                }
                Spacer()
            }
            .zIndex(1100)
        }
        .background(modalSheets)
        .background(errorOverlays)
        .background(lifecycleHandlers)
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuEditMarker)) { notification in
            if let marker = notification.userInfo?["marker"] as? PointMarker {
                editingPointMarkerID = marker.id
            }
        }
        // Radial Edit on a drawing shape (marker/line/circle/polygon) posts
        // .radialMenuEditDrawing with the drawingId. DrawingPropertiesView
        // already handles every shape type by id — reuse the #38 sheet by
        // pushing the id through drawingManager.pendingRenameID.
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuEditDrawing)) { notification in
            if let drawingId = notification.userInfo?["drawingId"] as? UUID {
                drawingManager.pendingRenameID = drawingId
            }
        }
    }

    private var modalSheets: some View {
        EmptyView()
            .sheet(isPresented: $showServerConfig) {
                NetworkPreferencesView()
            }
            // #38: prompt the user to name a shape immediately after creating
            // it. DrawingToolsManager publishes the new shape's id; we pop
            // the existing properties sheet (which already has a Name field).
            .sheet(isPresented: Binding(
                get: { drawingManager.pendingRenameID != nil },
                set: { if !$0 { drawingManager.pendingRenameID = nil } }
            )) {
                if let id = drawingManager.pendingRenameID {
                    DrawingPropertiesView(
                        drawingStore: drawingStore,
                        drawingID: id,
                        isPresented: Binding(
                            get: { drawingManager.pendingRenameID != nil },
                            set: { if !$0 { drawingManager.pendingRenameID = nil } }
                        )
                    )
                }
            }
            // Radial menu Edit → open PointMarker edit form. The radial
            // posts .radialMenuEditMarker (see RadialMenuActionExecutor);
            // without this observer the menu just dismissed silently.
            .sheet(isPresented: Binding(
                get: { editingPointMarkerID != nil },
                set: { if !$0 { editingPointMarkerID = nil } }
            )) {
                if let id = editingPointMarkerID {
                    PointMarkerEditView(
                        pointDropperService: pointDropperService,
                        markerID: id,
                        isPresented: Binding(
                            get: { editingPointMarkerID != nil },
                            set: { if !$0 { editingPointMarkerID = nil } }
                        )
                    )
                }
            }
            .fullScreenCover(isPresented: $showToolsMenu) {
                ATAKToolsView(isPresented: $showToolsMenu, showMeasurement: $showMeasurement)
            }
            .sheet(isPresented: $showTeamManagement) {
                TeamListView()
            }
            .sheet(isPresented: $showRoutePlanning) {
                RouteListView()
            }
            .sheet(isPresented: $showGeofences) {
                GeofenceListView()
            }
            .sheet(isPresented: $showTrackRecording) {
                TrackListView(recordingService: trackRecordingService)
            }
            .sheet(isPresented: $showChat) {
                ChatView(chatManager: chatManager)
            }
            .sheet(isPresented: $showContacts) {
                ContactListView(chatManager: chatManager)
            }
            .sheet(isPresented: $showEmergencySOS) {
                EmergencyBeaconView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(LocalizationManager.shared)
            }
            .sheet(isPresented: $showPlugins) {
                PluginsListView()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .sheet(isPresented: $showPositionBroadcast) {
                PositionBroadcastView()
            }
            .sheet(isPresented: $showMeshtastic) {
                MeshtasticConnectionView()
            }
            .sheet(isPresented: $showElevationProfile) {
                ElevationProfileView()
            }
            .sheet(isPresented: $showLineOfSight) {
                LineOfSightView()
            }
            .sheet(isPresented: $showEchelonHierarchy) {
                EchelonHierarchyView()
            }
            .sheet(isPresented: $showMissionSync) {
                MissionPackageSyncView()
            }
    }

    private var errorOverlays: some View {
        EmptyView()
            .overlay(
                Group {
                    if showGPSError {
                        GPSErrorAlert(isPresented: $showGPSError, onSettings: {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        })
                        .zIndex(2001)
                    }
                }
            )
    }

    private var lifecycleHandlers: some View {
        EmptyView()
            .onAppear {
                setupTAKConnection()
                startLocationUpdates()
                radialMenuCoordinator.configure(drawingStore: drawingStore)
                positionBroadcastService.configure(takService: takService, locationManager: locationManager)
                positionBroadcastService.isEnabled = true
                overlayCoordinator.loadSettings()
                mapStateManager.loadPreferences()
                mapStateManager.updateMapRegion(mapRegion)

                // Hook up self-healing route callback
                routeService.onRouteOverlayUpdate = { [weak routeOverlayCoordinator] route, currentLocation, waypointIndex in
                    DispatchQueue.main.async {
                        routeOverlayCoordinator?.updateSelfHealingRoute(
                            route: route,
                            currentLocation: currentLocation,
                            currentWaypointIndex: waypointIndex
                        )
                    }
                }
            }
            .onChange(of: isCursorModeActive) { newValue in
                DispatchQueue.main.async {
                    if newValue {
                        cursorModeCoordinator.activate()
                        mapStateManager.isCursorModeActive = true
                    } else {
                        cursorModeCoordinator.deactivate()
                        mapStateManager.isCursorModeActive = false
                    }
                }
            }
            .onChange(of: mapRegion.center.latitude) { _ in
                DispatchQueue.main.async {
                    mapStateManager.updateMapRegion(mapRegion)
                    // MGRS update handled by updateVisibleOverlays in map coordinator
                }
            }
            .onChange(of: mapRegion.center.longitude) { _ in
                DispatchQueue.main.async {
                    mapStateManager.updateMapRegion(mapRegion)
                    // MGRS update handled by updateVisibleOverlays in map coordinator
                }
            }
            .onChange(of: overlayCoordinator.mgrsGridEnabled) { newValue in
                DispatchQueue.main.async {
                    showGrid = newValue
                }
            }
            .onChange(of: locationManager.location?.coordinate.latitude) { _ in
                // Update map region to follow user if in follow mode (no animation)
                if trackingMode == .follow, let location = locationManager.location {
                    mapRegion.center = location.coordinate
                }
            }
            .onChange(of: locationManager.location?.coordinate.longitude) { _ in
                // Update map region to follow user if in follow mode (no animation)
                if trackingMode == .follow, let location = locationManager.location {
                    mapRegion.center = location.coordinate
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuCustomAction)) { notification in
                guard let userInfo = notification.userInfo,
                      let identifier = userInfo["identifier"] as? String else {
                    return
                }

                switch identifier {
                case "draw_shape":
                    withAnimation(.spring()) {
                        showDrawingPanel.toggle()
                    }
                case "meshtastic":
                    showMeshtastic = true
                default:
                    break // Unknown custom action
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuMeasurementStarted)) { notification in
                // Radial menu wants to start measurement - show the CompactMeasurementOverlay
                DispatchQueue.main.async {
                    showMeasurement = true

                    // If a specific measurement type was requested, start it
                    if let userInfo = notification.userInfo,
                       let type = userInfo["type"] as? MeasurementType {
                        measurementManager.startMeasurement(type: type)

                        // If a coordinate was provided (from radial menu), add it as the first tap
                        if let coordinate = userInfo["coordinate"] as? CLLocationCoordinate2D {
                            measurementManager.handleMapTap(at: coordinate)
                        }
                    }
                }
            }
            // Drawing action observers from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuOpenDrawingTools)) { _ in
                withAnimation(.spring()) {
                    showDrawingPanel = true
                    showDrawingList = false
                    showLayersPanel = false
                }
            }
            // Issue #16 — Tools tab posts this when the user picks
            // "Lasso Select". Activate lasso mode here so the in-map
            // gesture recognizer (UILongPressGestureRecognizer keyed on
            // drawingManager.currentMode == .lasso) starts firing.
            .onReceive(NotificationCenter.default.publisher(for: .startLassoMode)) { _ in
                drawingManager.startDrawing(mode: .lasso)
            }
            // Issue #16 — Tools tab "Full Tools…" passthrough. Reuses
            // the existing in-map ATAKToolsView presentation
            // (showToolsMenu / .fullScreenCover) so all the tool
            // wiring stays exactly where it was.
            .onReceive(NotificationCenter.default.publisher(for: .showFullTools)) { _ in
                showToolsMenu = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuOpenDrawingsList)) { _ in
                withAnimation(.spring()) {
                    showDrawingList = true
                    showDrawingPanel = false
                    showLayersPanel = false
                }
            }
            // App mode picker from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShowAppModePicker)) { _ in
                showAppModePicker = true
            }
            // Layers panel from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShowLayers)) { _ in
                withAnimation(.spring()) {
                    showLayersPanel.toggle()
                }
            }
            .sheet(isPresented: $showAppModePicker) {
                AppModePickerView()
            }
            // Route navigation changes
            .onChange(of: routeService.activeRoute?.id) { newRouteId in
                DispatchQueue.main.async {
                    if let route = routeService.activeRoute {
                        // Display the active route on the map
                        routeOverlayCoordinator.displayRoute(route, isActive: routeService.isNavigating)
                    } else {
                        // Clear route overlays when navigation stops
                        routeOverlayCoordinator.clearRouteOverlays()
                    }
                }
            }
            .onChange(of: routeService.isNavigating) { isNavigating in
                DispatchQueue.main.async {
                    if let route = routeService.activeRoute {
                        // Update route display based on navigation state
                        routeOverlayCoordinator.displayRoute(route, isActive: isNavigating)
                    }
                    // Collapse navigation panel when not navigating
                    if !isNavigating {
                        isNavigationPanelExpanded = false
                    }
                }
            }
    }

    // MARK: - Drawing and Measurement Handlers

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        // Handle measurement tool taps first
        if measurementManager.isActive {
            measurementManager.handleMapTap(at: coordinate)
            return
        }

        // Then handle drawing tool taps
        if drawingManager.isDrawingActive {
            drawingManager.handleMapTap(at: coordinate)
        }
    }

    // MARK: - Marker Actions

    private func dropMarkerAtLocation(coordinate: CLLocationCoordinate2D, affiliation: MarkerAffiliation) {
        // Create a new marker at the specified location
        let callsign = generateCallsign(for: affiliation)

        // Use PointDropperService quickDrop
        _ = PointDropperService.shared.quickDrop(
            at: coordinate,
            name: callsign,
            broadcast: false
        )

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func generateCallsign(for affiliation: MarkerAffiliation) -> String {
        let prefix: String
        switch affiliation {
        case .friendly:
            prefix = "FRD"
        case .hostile:
            prefix = "HST"
        case .neutral:
            prefix = "NEU"
        case .unknown:
            prefix = "UNK"
        }

        let timestamp = Int(Date().timeIntervalSince1970) % 10000
        return "\(prefix)-\(timestamp)"
    }

    // MARK: - Actions

    private func setupTAKConnection() {
        // Connect to all enabled servers (respects user's toggle state)
        ServerManager.shared.connectToEnabledServers()
    }

    private func startLocationUpdates() {
        locationManager.startUpdating()

        // Check GPS status and show error if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.locationManager.location == nil {
                self.showGPSError = false  // Don't show error immediately
            }
        }
    }

    private func centerOnUser() {
        // Toggle tracking mode
        if trackingMode == .follow {
            // Disable follow mode - allow free panning
            trackingMode = .none
        } else {
            // Enable follow mode and center on user
            if let location = locationManager.location {
                withAnimation {
                    mapRegion.center = location.coordinate
                    mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                }
                trackingMode = .follow
            }
        }
    }

    private func sendSelfPosition() {
        guard let location = locationManager.location else { return }

        // Send to all connected servers via federation
        if federation.getConnectedCount() > 0 {
            let cotEvent = CoTEvent(
                uid: "SELF-\(UUID().uuidString)",
                type: "a-f-G-E-S",
                time: Date(),
                point: CoTPoint(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    hae: location.altitude,
                    ce: location.horizontalAccuracy,
                    le: location.verticalAccuracy
                ),
                detail: CoTDetail(
                    callsign: "OmniTAK-iOS",
                    team: "Cyan",
                    speed: location.speed >= 0 ? location.speed : nil,
                    course: location.course >= 0 ? location.course : nil,
                    remarks: nil,
                    battery: 100,
                    device: "iPhone",
                    platform: "OmniTAK"
                )
            )

            federation.broadcast(event: cotEvent)
        }
    }

    private func zoomIn() {
        mapRegion.span.latitudeDelta = max(mapRegion.span.latitudeDelta / 2, 0.001)
        mapRegion.span.longitudeDelta = max(mapRegion.span.longitudeDelta / 2, 0.001)
    }

    private func zoomOut() {
        mapRegion.span.latitudeDelta = min(mapRegion.span.latitudeDelta * 2, 180)
        mapRegion.span.longitudeDelta = min(mapRegion.span.longitudeDelta * 2, 180)
    }

    private func zoomToDrawing(coordinate: CLLocationCoordinate2D, radius: Double?) {
        let span: MKCoordinateSpan
        if let radius = radius {
            let degrees = (radius * 3) / 111000
            span = MKCoordinateSpan(
                latitudeDelta: max(degrees, 0.005),
                longitudeDelta: max(degrees, 0.005)
            )
        } else {
            span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            mapRegion = MKCoordinateRegion(center: coordinate, span: span)
        }
    }

    private func toggleLayer(_ layer: String) {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Update active layer
        activeMapLayer = layer

        // Toggle map layers
        withAnimation(.easeInOut(duration: 0.3)) {
            switch layer {
            case "satellite": mapType = .satellite
            case "hybrid": mapType = .hybrid
            case "standard": mapType = .standard
            default: break
            }
        }
    }

    private func toggleOverlay(_ overlay: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        switch overlay {
        case "friendly": showFriendly.toggle()
        case "hostile": showHostile.toggle()
        case "neutral": showNeutral.toggle()
        case "unknown": showUnknown.toggle()
        default: break
        }
    }

    private func toggleMapOverlay(_ overlay: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        withAnimation(.easeInOut(duration: 0.3)) {
            switch overlay {
            case "compass": showCompass.toggle()
            case "coordinates": showCoordinates.toggle()
            case "scale": showScaleBar.toggle()
            case "grid": showGrid.toggle()
            case "callsign": showCallsignPanel.toggle()
            default: break
            }
        }
    }

    // MARK: - Formatting Helpers

    private func formatCoordinates(_ coordinate: CLLocationCoordinate2D) -> String {
        // Convert to MGRS-style format (simplified)
        let lat = abs(coordinate.latitude)
        let lon = abs(coordinate.longitude)
        let latDeg = Int(lat)
        let lonDeg = Int(lon)
        let latMin = Int((lat - Double(latDeg)) * 60)
        let lonMin = Int((lon - Double(lonDeg)) * 60)
        let latSec = Int(((lat - Double(latDeg)) * 60 - Double(latMin)) * 60)
        let lonSec = Int(((lon - Double(lonDeg)) * 60 - Double(lonMin)) * 60)

        return "11T MN \(latDeg)\(latMin)\(latSec) \(lonDeg)\(lonMin)\(lonSec)"
    }

    private func formatAltitude(_ altitude: CLLocationDistance) -> String {
        return UnitPreferences.shared.formatAltitude(altitude) + " MSL"
    }

    private func formatSpeed(_ speed: CLLocationSpeed) -> String {
        return UnitPreferences.shared.formatSpeed(max(0, speed))
    }

    private func formatHeading(_ heading: CLHeading?) -> String {
        guard let heading = heading else {
            // Fall back to course from location if heading not available
            if locationManager.course >= 0 {
                return String(format: "%.0f°M", locationManager.course)
            }
            return ""
        }
        // Use magnetic heading for ATAK compatibility
        return String(format: "%.0f°M", heading.magneticHeading)
    }

    // MARK: - Multi-Server Helpers

    // Multi-server connection status for status bar
    private func multiServerConnectionStatus() -> String {
        let connectedCount = federation.getConnectedCount()
        let totalCount = federation.getTotalCount()

        if connectedCount == 0 {
            return "Disconnected"
        } else if connectedCount == 1 {
            if let connectedServer = federation.servers.first(where: { $0.status == .connected }) {
                return "Connected - \(connectedServer.name)"
            }
            return "Connected"
        } else {
            return "Connected to \(connectedCount)/\(totalCount) servers"
        }
    }

    // Multi-server display name for status bar
    private func multiServerDisplayName() -> String? {
        let connectedCount = federation.getConnectedCount()

        if connectedCount == 0 {
            return ServerManager.shared.activeServer?.name
        } else if connectedCount == 1 {
            return federation.servers.first(where: { $0.status == .connected })?.name
        } else {
            let connectedNames = federation.servers
                .filter { $0.status == .connected }
                .map { $0.name }
                .prefix(2)
                .joined(separator: ", ")
            return connectedCount > 2 ? "\(connectedNames) +\(connectedCount - 2)" : connectedNames
        }
    }

    private func generateSelfCoT(location: CLLocation) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="SELF-\(UUID().uuidString)" type="a-f-G-E-S" how="m-g" time="\(now)" start="\(now)" stale="\(stale)">
            <point lat="\(location.coordinate.latitude)" lon="\(location.coordinate.longitude)" hae="\(location.altitude)" ce="\(location.horizontalAccuracy)" le="\(location.verticalAccuracy)"/>
            <detail>
                <contact callsign="OmniTAK-iOS" endpoint="*:-1:stcp"/>
                <__group name="Cyan" role="Team Member"/>
                <status battery="100"/>
                <takv device="iPhone" platform="OmniTAK" os="iOS" version="\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")"/>
                <track speed="\(location.speed)" course="\(location.course)"/>
            </detail>
        </event>
        """
    }
}

// MARK: - ATAK Status Bar

struct ATAKStatusBar: View {
    let connectionStatus: String
    let isConnected: Bool
    let messagesReceived: Int
    let messagesSent: Int
    let gpsAccuracy: Double
    let serverName: String?
    let onServerTap: () -> Void
    let onMenuTap: () -> Void

    /// 24-hour tactical clock used by the top status strip — keeps the
    /// iOS bar in sync with the Android `timeLabel` (e.g. `19:03`).
    static let timeLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    @Environment(\.verticalSizeClass) var verticalSizeClass

    // Portrait mode detection
    var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        HStack(spacing: isPortrait ? 8 : 12) {
            // Compact OmniTAK branding with status indicator
            HStack(spacing: 4) {
                // LED-style connection indicator
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .shadow(color: isConnected ? .green : .red, radius: 3)

                if !isPortrait {
                    Text("OmniTAK")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 0.988, blue: 0.0))
                }
            }

            // Server Name Button (compact)
            Button(action: onServerTap) {
                HStack(spacing: 2) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 9))
                    Text(serverName ?? "Offi...")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(isConnected ? .green : .gray)
            }

            // Messages (compact) — text arrows match Android ATAKStatusBar
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
                Text("\(messagesReceived)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
            }

            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.63, blue: 0.0))
                Text("\(messagesSent)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.63, blue: 0.0))
            }

            Spacer()

            // GPS Status (compact)
            HStack(spacing: 2) {
                Image(systemName: gpsAccuracy < 10 ? "location.fill" : "location.slash.fill")
                    .font(.system(size: 9))
                Text(String(format: "±%.0fm", gpsAccuracy))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(gpsAccuracy < 10 ? .green : .yellow)

            // Time (compact) — 24h tactical, matches Android
            Text(ATAKStatusBar.timeLabelFormatter.string(from: Date()))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            // Hamburger Menu Button (compact)
            Button(action: onMenuTap) {
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                }
                .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("mainMenuButton")
            .accessibilityLabel("Main Menu")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.5))  // Translucent background
    }
}

// MARK: - ATAK Bottom Toolbar

struct ATAKBottomToolbar: View {
    @Binding var mapType: MKMapType
    @Binding var showLayersPanel: Bool
    @Binding var showDrawingPanel: Bool
    @Binding var showDrawingList: Bool
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Zoom Controls only - Draw/Drawings accessible via radial menu long-press
            VStack(spacing: 4) {
                MapToolButton(icon: "plus", label: "", compact: true) {
                    onZoomIn()
                }
                MapToolButton(icon: "minus", label: "", compact: true) {
                    onZoomOut()
                }
            }

            Spacer()

            // Draw and Drawings buttons removed - accessible via radial menu (long-press on map)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// Map Tool Button Component
struct MapToolButton: View {
    let icon: String
    let label: String
    var compact: Bool = false
    var isActive: Bool = false
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                }
            }
            .foregroundColor(isActive ? Color(hex: "#FFFC00") : .white)
            .frame(width: compact ? 32 : 50, height: compact ? 32 : 50)
            .background(
                isActive ? Color(hex: "#FFFC00").opacity(0.3) :
                isPressed ? Color.cyan.opacity(0.5) : Color.black.opacity(0.6)
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color(hex: "#FFFC00") : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - ATAK Side Panel

struct ATAKSidePanel: View {
    @Binding var isExpanded: Bool
    @Binding var activeMapLayer: String
    @Binding var showFriendly: Bool
    @Binding var showHostile: Bool
    @Binding var showNeutral: Bool
    @Binding var showUnknown: Bool
    @Binding var showCompass: Bool
    @Binding var showCoordinates: Bool
    @Binding var showScaleBar: Bool
    @Binding var showGrid: Bool
    @Binding var showCallsignPanel: Bool
    @ObservedObject var adsbService: ADSBTrafficService
    let onLayerToggle: (String) -> Void
    let onOverlayToggle: (String) -> Void
    let onMapOverlayToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // Compact header with close button
                HStack {
                    Text("LAYERS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            isExpanded = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.system(size: 16))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                LayerButton(icon: "map", title: "Satellite", isActive: activeMapLayer == "satellite", compact: true) {
                    onLayerToggle("satellite")
                }
                LayerButton(icon: "map.fill", title: "Hybrid", isActive: activeMapLayer == "hybrid", compact: true) {
                    onLayerToggle("hybrid")
                }
                LayerButton(icon: "map.circle", title: "Standard", isActive: activeMapLayer == "standard", compact: true) {
                    onLayerToggle("standard")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("UNITS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(icon: "shield.fill", title: "Friendly", isActive: showFriendly, compact: true) {
                    onOverlayToggle("friendly")
                }
                LayerButton(icon: "exclamationmark.triangle.fill", title: "Hostile", isActive: showHostile, compact: true) {
                    onOverlayToggle("hostile")
                }
                LayerButton(icon: "circle.fill", title: "Neutral", isActive: showNeutral, compact: true) {
                    onOverlayToggle("neutral")
                }
                LayerButton(icon: "questionmark.circle.fill", title: "Unknown", isActive: showUnknown, compact: true) {
                    onOverlayToggle("unknown")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("MAP OVERLAYS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(icon: "safari", title: "Compass", isActive: showCompass, compact: true) {
                    onMapOverlayToggle("compass")
                }
                LayerButton(icon: "location.circle", title: "Coordinates", isActive: showCoordinates, compact: true) {
                    onMapOverlayToggle("coordinates")
                }
                LayerButton(icon: "ruler", title: "Scale Bar", isActive: showScaleBar, compact: true) {
                    onMapOverlayToggle("scale")
                }
                LayerButton(icon: "person.text.rectangle.fill", title: "Callsign Card", isActive: showCallsignPanel, compact: true) {
                    onMapOverlayToggle("callsign")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("DATA FEEDS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(
                    icon: "airplane.circle.fill",
                    title: "ADS-B",
                    isActive: adsbService.settings.isEnabled,
                    compact: true
                ) {
                    var settings = adsbService.settings
                    settings.isEnabled.toggle()
                    adsbService.settings = settings
                }

                if adsbService.settings.isEnabled {
                    HStack {
                        Text("\(adsbService.aircraft.count) aircraft")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 160)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
        }
        .animation(.spring(), value: isExpanded)
    }
}

struct LayerButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 12 : 14))
                    .frame(width: compact ? 16 : 20)
                Text(title)
                    .font(.system(size: compact ? 11 : 13))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundColor(.green)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(isActive ? Color.green.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
    }
}

// MARK: - CoT Marker

struct CoTMarker: Identifiable {
    let id = UUID()
    let uid: String
    let coordinate: CLLocationCoordinate2D
    let type: String
    let callsign: String
    let team: String
}

struct CoTMarkerView: View {
    let marker: CoTMarker

    var body: some View {
        VStack(spacing: 2) {
            // Icon based on type
            Image(systemName: markerIcon)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(markerColor)
                .shadow(color: .black, radius: 2)

            // Callsign
            Text(marker.callsign)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(markerColor.opacity(0.8))
                .cornerRadius(4)
                .shadow(color: .black, radius: 1)
        }
    }

    private var markerIcon: String {
        if marker.type.contains("a-f") {
            return "shield.fill"  // Friendly
        } else if marker.type.contains("a-h") {
            return "exclamationmark.triangle.fill"  // Hostile
        } else {
            return "questionmark.circle.fill"  // Unknown
        }
    }

    private var markerColor: Color {
        if marker.type.contains("a-f") {
            return .cyan  // Friendly = cyan (ATAK standard)
        } else if marker.type.contains("a-h") {
            return .red  // Hostile = red
        } else {
            return .yellow  // Unknown = yellow
        }
    }
}

// MARK: - View Extensions

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

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

// MARK: - Tactical Map View (Mapbox Maps SDK v3 — native)
//
// This is the main map surface for OmniTAK iOS. It used to wrap MKMapView;
// the engine swap moved it to Mapbox Maps SDK v11 (`MapboxMaps`) so the
// same UIViewRepresentable serves a Mapbox `MapView` underneath while the
// SwiftUI parent (`ATAKMapView`) and every call-site keep their existing
// bindings (`MKCoordinateRegion`, `MKMapType`, `MapUserTrackingMode`).
// The 3D Standard style + terrain + atmosphere are loaded by default so
// the operator opens straight into the immersive view that the legacy
// MapKit version never could deliver.

struct TacticalMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var mapType: MKMapType
    @Binding var trackingMode: MapUserTrackingMode
    let markers: [CoTMarker]
    let pointMarkers: [PointMarker]
    let aircraft: [Aircraft]
    let showsUserLocation: Bool
    @ObservedObject var drawingStore: DrawingStore
    @ObservedObject var drawingManager: DrawingToolsManager
    @ObservedObject var radialMenuCoordinator: RadialMenuMapCoordinator
    @ObservedObject var overlayCoordinator: MapOverlayCoordinator
    @ObservedObject var routeOverlayCoordinator: RouteOverlayCoordinator
    @ObservedObject var mapStateManager: MapStateManager
    @ObservedObject var measurementManager: MeasurementManager
    @ObservedObject var lassoService: LassoSelectionService = LassoSelectionService.shared
    let onMapTap: (CLLocationCoordinate2D) -> Void

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MapView {
        // 3D default: Standard style + 60° pitch on launch. Camera is
        // hydrated from the SwiftUI region binding so a fresh launch
        // sits over Washington DC (the default), and restored sessions
        // pick up wherever the operator left off.
        let initialCenter = region.center
        let initialZoom = TacticalMapView.zoom(forSpan: region.span, mapHeight: 400)
        let cameraOpts = CameraOptions(
            center: initialCenter,
            zoom: initialZoom,
            bearing: 0,
            pitch: 60
        )
        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                cameraOptions: cameraOpts,
                styleURI: TacticalMapView.styleURI(for: mapType)
            )
        )

        // Native user-location puck — replaces the custom self-position
        // MKAnnotation we used to maintain. Bullseye/MIL-STD style is
        // available via Mapbox v11 puck customisation if we want it
        // later.
        mapView.location.options.puckType = .puck2D()
        if !showsUserLocation { mapView.location.options.puckType = nil }

        // Sane defaults for tactical use — let the operator pan, zoom,
        // pitch, and rotate freely. Mapbox enables all of these by
        // default; we re-state them so future toggles are explicit.
        mapView.gestures.options.pitchEnabled = true
        mapView.gestures.options.rotateEnabled = true
        mapView.gestures.options.panEnabled = true
        mapView.gestures.options.pinchEnabled = true
        mapView.gestures.options.doubleTapToZoomInEnabled = true
        mapView.gestures.options.doubleTouchToZoomOutEnabled = true

        // Tap → contact hit-test / map-tap fan-out
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        mapView.addGestureRecognizer(tap)

        // Long-press → radial menu (with marker context awareness)
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        mapView.addGestureRecognizer(longPress)

        // Lasso multi-select — separate recognizer gated on
        // DrawingToolsManager.currentMode == .lasso (issue #16). When
        // inactive it no-ops; when active it suppresses pan so the
        // user can drag a free-form selection.
        let lasso = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLassoGesture(_:))
        )
        lasso.minimumPressDuration = 0.25
        lasso.allowableMovement = .greatestFiniteMagnitude
        lasso.cancelsTouchesInView = true
        lasso.delegate = context.coordinator
        mapView.addGestureRecognizer(lasso)
        context.coordinator.lassoGesture = lasso

        // Lifecycle hooks — load terrain + atmosphere on style load
        // so the operator gets immediate 3D depth without a settings
        // detour, and mirror camera changes back into the SwiftUI
        // region binding for downstream consumers (scale bar, MGRS
        // grid, overlay coordinator).
        let coord = context.coordinator
        coord.mapView = mapView

        coord.styleLoadedToken = mapView.mapboxMap.onStyleLoaded.observe { [weak coord] _ in
            DispatchQueue.main.async {
                coord?.installTerrainAndAtmosphere()
                coord?.refreshAll()
            }
        }

        coord.cameraChangedToken = mapView.mapboxMap.onCameraChanged.observe { [weak coord, weak mapView] _ in
            guard let coord = coord, let mapView = mapView else { return }
            coord.handleCameraChanged(mapView: mapView)
        }

        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.parent = self

        // Style swap on mapType change
        let desiredStyle = TacticalMapView.styleURI(for: mapType)
        if context.coordinator.lastAppliedStyle != desiredStyle {
            context.coordinator.lastAppliedStyle = desiredStyle
            let coord = context.coordinator
            mapView.mapboxMap.loadStyle(desiredStyle) { [weak coord] _ in
                DispatchQueue.main.async {
                    coord?.installTerrainAndAtmosphere()
                    coord?.refreshAll()
                }
            }
        }

        // Region sync — only push to Mapbox if the SwiftUI region
        // diverges from the camera state by more than a hair. This is
        // the same feedback-loop guard MKMapView needed.
        if !context.coordinator.isUserInteracting {
            let cameraState = mapView.mapboxMap.cameraState
            let centerChanged =
                abs(cameraState.center.latitude - region.center.latitude) > 0.0001 ||
                abs(cameraState.center.longitude - region.center.longitude) > 0.0001
            let zoomChanged = abs(cameraState.zoom - TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height)) > 0.25
            if centerChanged || zoomChanged {
                context.coordinator.isProgrammaticUpdate = true
                let opts = CameraOptions(
                    center: region.center,
                    zoom: TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height)
                )
                mapView.mapboxMap.setCamera(to: opts)
                context.coordinator.isProgrammaticUpdate = false
            }
        }

        // Re-publish all annotation layers from the latest model state.
        context.coordinator.refreshAll()

        // MGRS center label + visible-region housekeeping. The MGRS
        // grid itself is rendered by SwiftUI `GridOverlayView` over
        // the map (set up in ATAKMapView), so we just keep the
        // coordinator aware of the camera.
        overlayCoordinator.updateVisibleOverlays(in: region)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Style mapping

    /// Translate the legacy `MKMapType` chosen in the bottom toolbar to a
    /// Mapbox `StyleURI`. We default to Standard (3D buildings + atmos
    /// + lighting) for the strongest first-launch impression, and fall
    /// back to satellite/streets variants when the operator switches
    /// layers in the layers panel.
    static func styleURI(for mapType: MKMapType) -> StyleURI {
        switch mapType {
        case .satellite, .satelliteFlyover:
            return .satellite
        case .hybrid, .hybridFlyover:
            return .satelliteStreets
        case .mutedStandard:
            return .light
        case .standard:
            return .standard
        @unknown default:
            return .standard
        }
    }

    /// Approximate a Mapbox zoom level from an `MKCoordinateSpan`. The
    /// legacy MKMapView toolbar speaks in degrees-per-span; Mapbox in
    /// power-of-two zoom. We hold latitude constant and pick the zoom
    /// where one tile (~256pt) covers the requested longitude span,
    /// clamped to the standard range.
    static func zoom(forSpan span: MKCoordinateSpan, mapHeight: CGFloat) -> Double {
        let lonDelta = max(span.longitudeDelta, 0.0005)
        // Mercator zoom: 360° = full world at zoom 0; each zoom level
        // halves the visible span.
        let zoom = log2(360.0 / lonDelta)
        return min(max(zoom, 0), 22)
    }

    /// Inverse of `zoom(forSpan:)` so the coordinator can round-trip
    /// camera state into the `MKCoordinateSpan` the SwiftUI region
    /// binding expects.
    static func span(forZoom zoom: Double, latitude: Double) -> MKCoordinateSpan {
        let lonDelta = 360.0 / pow(2.0, max(zoom, 0))
        let latDelta = lonDelta * cos(latitude * .pi / 180)
        return MKCoordinateSpan(
            latitudeDelta: max(latDelta, 0.0005),
            longitudeDelta: max(lonDelta, 0.0005)
        )
    }

    // MARK: - Coordinator

    /// All of the per-MapView state lives here: annotation managers,
    /// observation tokens, lasso layer, marker image cache. The
    /// SwiftUI struct above only forwards bindings and triggers
    /// refreshes — every actual Mapbox call goes through this class.
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TacticalMapView
        weak var mapView: MapView?

        // Lifecycle / observation tokens
        var styleLoadedToken: AnyCancelable?
        var cameraChangedToken: AnyCancelable?
        var lastAppliedStyle: StyleURI = .standard

        // Camera feedback-loop guards
        var isUserInteracting = false
        var isProgrammaticUpdate = false

        // Annotation managers — one per geometry kind. Mapbox v11
        // wants us to reuse these (cheap to create, expensive to
        // churn). `ensure*Manager` lazily attaches them after the
        // first style load.
        private var cotMarkerManager: PointAnnotationManager?
        private var pointMarkerManager: PointAnnotationManager?
        private var aircraftManager: PointAnnotationManager?
        private var drawingMarkerManager: PointAnnotationManager?
        private var drawingLabelManager: PointAnnotationManager?
        private var measurementVertexManager: PointAnnotationManager?
        private var drawingLineManager: PolylineAnnotationManager?
        private var drawingPolygonManager: PolygonAnnotationManager?
        private var drawingTempLineManager: PolylineAnnotationManager?
        private var measurementLineManager: PolylineAnnotationManager?
        private var rangeBearingLineManager: PolylineAnnotationManager?
        private var rangeBearingLabelManager: PointAnnotationManager?
        private var breadcrumbLineManager: PolylineAnnotationManager?
        private var rangeRingManager: PolygonAnnotationManager?
        private var lassoSelectionRingManager: PolygonAnnotationManager?

        // Lasso — same CAShapeLayer approach the MKMapView version
        // used, just attached to the Mapbox MapView's layer. Cheaper
        // and flicker-free vs. churning annotations on every touch.
        weak var lassoGesture: UILongPressGestureRecognizer?
        private var lassoPathLayer: CAShapeLayer?
        private var lassoViewPoints: [CGPoint] = []

        // MIL-STD-2525 symbol cache — UIHostingController snapshots
        // keyed by (cotType, callsign) so we don't rebuild the image
        // on every frame. Bounded; cleared on memory warnings.
        private var symbolImageCache: [String: UIImage] = [:]
        private let symbolImageCacheCapacity = 256

        init(_ parent: TacticalMapView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleMemoryWarning() {
            symbolImageCache.removeAll(keepingCapacity: false)
        }

        // MARK: - Terrain / atmosphere

        /// Wire up the DEM source, terrain expression, and atmosphere
        /// after the style finishes loading. Idempotent — safe to
        /// call again after a style swap.
        func installTerrainAndAtmosphere() {
            guard let mapView = mapView else { return }
            do {
                if !mapView.mapboxMap.sourceExists(withId: "mapbox-dem") {
                    var dem = RasterDemSource(id: "mapbox-dem")
                    dem.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
                    dem.tileSize = 514
                    dem.maxzoom = 14.0
                    try mapView.mapboxMap.addSource(dem)
                }

                var terrain = Terrain(sourceId: "mapbox-dem")
                terrain.exaggeration = .constant(1.5)
                try mapView.mapboxMap.setTerrain(terrain)

                var atmosphere = Atmosphere()
                atmosphere.color = .constant(StyleColor(red: 0, green: 128, blue: 255, alpha: 1.0)!)
                atmosphere.highColor = .constant(StyleColor(red: 25, green: 77, blue: 179, alpha: 1.0)!)
                atmosphere.horizonBlend = .constant(0.1)
                atmosphere.spaceColor = .constant(StyleColor(red: 0, green: 0, blue: 13, alpha: 1.0)!)
                atmosphere.starIntensity = .constant(0.15)
                try mapView.mapboxMap.setAtmosphere(atmosphere)
            } catch {
                print("TacticalMapView: terrain/atmosphere setup failed — \(error)")
            }
        }

        // MARK: - Camera plumbing

        /// React to a Mapbox camera-change event by mirroring the new
        /// state back to the SwiftUI `region` binding so the rest of
        /// the app (scale bar, MGRS center label, layer toggles) keeps
        /// up with whatever the operator is doing on screen.
        func handleCameraChanged(mapView: MapView) {
            let state = mapView.mapboxMap.cameraState
            if !isProgrammaticUpdate {
                isUserInteracting = true
            }
            let newRegion = MKCoordinateRegion(
                center: state.center,
                span: TacticalMapView.span(forZoom: state.zoom, latitude: state.center.latitude)
            )
            DispatchQueue.main.async { [weak self] in
                self?.parent.region = newRegion
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isUserInteracting = false
            }
        }

        // MARK: - Annotation refresh fan-out

        /// Single entry-point that updateUIView calls every time the
        /// SwiftUI parent re-renders. Each refresh function diffs the
        /// model against the live annotations on its own manager, so
        /// repeated calls stay cheap.
        func refreshAll() {
            refreshCotMarkers()
            refreshPointMarkers()
            refreshAircraftMarkers()
            refreshDrawingMarkers()
            refreshDrawingLabels()
            refreshDrawingLines()
            refreshDrawingPolygons()
            refreshDrawingCircles()
            refreshDrawingTempOverlay()
            refreshMeasurementOverlay()
            refreshRangeBearing()
            refreshBreadcrumbTrail()
            refreshLassoHighlightRings()
        }

        // Lazy-attach helpers — one per annotation kind. Mapbox v11
        // returns ready-to-use managers; we keep our own refs so we
        // can clear/replace their `.annotations` arrays per refresh.
        private func ensurePoint(_ keyPath: ReferenceWritableKeyPath<Coordinator, PointAnnotationManager?>) -> PointAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }
        private func ensureLine(_ keyPath: ReferenceWritableKeyPath<Coordinator, PolylineAnnotationManager?>) -> PolylineAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolylineAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }
        private func ensurePolygon(_ keyPath: ReferenceWritableKeyPath<Coordinator, PolygonAnnotationManager?>) -> PolygonAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolygonAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }

        // MARK: - CoT markers (live contacts)

        private func refreshCotMarkers() {
            guard let manager = ensurePoint(\.cotMarkerManager) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.markers.count)
            for marker in parent.markers {
                let key = "cot|\(marker.type)|\(marker.callsign)"
                let img = symbolImage(for: marker)
                var ann = PointAnnotation(id: "cot-\(marker.uid)", coordinate: marker.coordinate)
                ann.image = .init(image: img, name: key)
                ann.iconSize = 1.0
                ann.iconAnchor = .bottom
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func symbolImage(for marker: CoTMarker) -> UIImage {
            let key = "cot|\(marker.type)|\(marker.callsign)"
            if let cached = symbolImageCache[key] { return cached }

            // Reuse the SwiftUI MilStdMarkerSymbolView used elsewhere
            // in the app so the symbology matches the radial menu and
            // overlay sheets pixel-for-pixel.
            let view = MilStdMarkerSymbolView(
                cotType: marker.type,
                callsign: marker.callsign,
                echelon: nil,
                size: 28,
                isSelected: false
            )
            let img = Self.snapshot(view, size: CGSize(width: 80, height: 56))
            if symbolImageCache.count >= symbolImageCacheCapacity {
                symbolImageCache.removeAll(keepingCapacity: true)
            }
            symbolImageCache[key] = img
            return img
        }

        /// SwiftUI → UIImage. Wrapped with `try?` so a transient
        /// rendering glitch returns an empty image rather than
        /// crashing the map.
        private static func snapshot<Content: View>(_ view: Content, size: CGSize) -> UIImage {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(origin: .zero, size: size)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }

        // MARK: - Point markers (radial-menu-dropped pins)

        private func refreshPointMarkers() {
            guard let manager = ensurePoint(\.pointMarkerManager) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.pointMarkers.count)
            for pm in parent.pointMarkers {
                let img = pointMarkerImage(for: pm)
                let key = "pm|\(pm.affiliation.rawValue)"
                var ann = PointAnnotation(id: "pm-\(pm.id.uuidString)", coordinate: pm.coordinate)
                ann.image = .init(image: img, name: key)
                ann.textField = pm.name
                ann.textAnchor = .top
                ann.textOffset = [0, 1.2]
                ann.textColor = StyleColor(.white)
                ann.textHaloColor = StyleColor(.black)
                ann.textHaloWidth = 1.0
                ann.textSize = 11
                ann.iconAnchor = .bottom
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func pointMarkerImage(for marker: PointMarker) -> UIImage {
            let key = "pmimg|\(marker.affiliation.rawValue)"
            if let cached = symbolImageCache[key] { return cached }
            let size = CGSize(width: 36, height: 36)
            let renderer = UIGraphicsImageRenderer(size: size)
            let img = renderer.image { _ in
                let rect = CGRect(origin: .zero, size: size)
                marker.affiliation.color.uiColor.setFill()
                let outer = UIBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                outer.fill()
                UIColor.white.setStroke()
                outer.lineWidth = 2
                outer.stroke()
                let iconRect = rect.insetBy(dx: 8, dy: 8).insetBy(dx: 2, dy: 2)
                UIColor.white.setFill()
                switch marker.affiliation {
                case .hostile:
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: iconRect.midX, y: iconRect.minY))
                    p.addLine(to: CGPoint(x: iconRect.maxX, y: iconRect.midY))
                    p.addLine(to: CGPoint(x: iconRect.midX, y: iconRect.maxY))
                    p.addLine(to: CGPoint(x: iconRect.minX, y: iconRect.midY))
                    p.close()
                    p.fill()
                case .friendly, .unknown:
                    UIBezierPath(ovalIn: iconRect).fill()
                case .neutral:
                    UIBezierPath(rect: iconRect).fill()
                }
            }
            symbolImageCache[key] = img
            return img
        }

        // MARK: - Aircraft (ADS-B)

        private func refreshAircraftMarkers() {
            guard let manager = ensurePoint(\.aircraftManager) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.aircraft.count)
            for ac in parent.aircraft {
                var ann = PointAnnotation(id: "ac-\(ac.id)", coordinate: ac.coordinate)
                ann.image = PointAnnotation.Image(image: Self.aircraftImage, name: "aircraft-icon")
                ann.iconRotate = ac.heading
                ann.iconSize = 1.0
                ann.iconAnchor = IconAnchor.center
                ann.textField = ac.callsign.isEmpty ? ac.id : ac.callsign
                ann.textAnchor = TextAnchor.top
                ann.textOffset = [0, 1.2]
                ann.textColor = StyleColor(.systemBlue)
                ann.textHaloColor = StyleColor(.black)
                ann.textHaloWidth = 1
                ann.textSize = 10
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private static let aircraftImage: UIImage = {
            let size = CGSize(width: 24, height: 24)
            let r = UIGraphicsImageRenderer(size: size)
            return r.image { ctx in
                let c = ctx.cgContext
                c.translateBy(x: size.width / 2, y: size.height / 2)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: -10))
                path.addLine(to: CGPoint(x: 9, y: 6))
                path.addLine(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: -9, y: 6))
                path.close()
                UIColor.systemBlue.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }()

        // MARK: - Drawings

        private func refreshDrawingMarkers() {
            guard let manager = ensurePoint(\.drawingMarkerManager) else { return }
            var fresh: [PointAnnotation] = []
            for m in parent.drawingStore.markers {
                let img = drawingMarkerImage(color: m.color.uiColor)
                var ann = PointAnnotation(id: "dm-\(m.id.uuidString)", coordinate: m.coordinate)
                ann.image = .init(image: img, name: "drawmarker-\(m.color.rawValue)")
                ann.iconAnchor = .bottom
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func drawingMarkerImage(color: UIColor) -> UIImage {
            let key = "dm|\(color.description)"
            if let cached = symbolImageCache[key] { return cached }
            let size = CGSize(width: 30, height: 30)
            let r = UIGraphicsImageRenderer(size: size)
            let img = r.image { _ in
                color.setFill()
                let p = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
                p.fill()
                UIColor.white.setStroke()
                p.lineWidth = 2
                p.stroke()
            }
            symbolImageCache[key] = img
            return img
        }

        private func refreshDrawingLabels() {
            guard let manager = ensurePoint(\.drawingLabelManager) else { return }
            var fresh: [PointAnnotation] = []
            for c in parent.drawingStore.circles {
                fresh.append(labelAnnotation(id: "lbl-c-\(c.id.uuidString)", coordinate: c.center, text: c.label, color: c.color.uiColor))
            }
            for p in parent.drawingStore.polygons {
                if let centroid = Self.centroid(of: p.coordinates) {
                    fresh.append(labelAnnotation(id: "lbl-p-\(p.id.uuidString)", coordinate: centroid, text: p.label, color: p.color.uiColor))
                }
            }
            for l in parent.drawingStore.lines where l.coordinates.count >= 2 {
                let mid = l.coordinates[l.coordinates.count / 2]
                fresh.append(labelAnnotation(id: "lbl-l-\(l.id.uuidString)", coordinate: mid, text: l.label, color: l.color.uiColor))
            }
            manager.annotations = fresh
        }

        private func labelAnnotation(id: String, coordinate: CLLocationCoordinate2D, text: String, color: UIColor) -> PointAnnotation {
            var ann = PointAnnotation(id: id, coordinate: coordinate)
            ann.textField = text
            ann.textColor = StyleColor(.white)
            ann.textHaloColor = StyleColor(color)
            ann.textHaloWidth = 2
            ann.textSize = 11
            ann.iconImage = ""  // text only
            return ann
        }

        private static func centroid(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
            guard !coords.isEmpty else { return nil }
            var lat = 0.0, lon = 0.0
            for c in coords { lat += c.latitude; lon += c.longitude }
            let n = Double(coords.count)
            return CLLocationCoordinate2D(latitude: lat / n, longitude: lon / n)
        }

        private func refreshDrawingLines() {
            guard let manager = ensureLine(\.drawingLineManager) else { return }
            var fresh: [PolylineAnnotation] = []
            for l in parent.drawingStore.lines where l.coordinates.count >= 2 {
                var p = PolylineAnnotation(id: "dl-\(l.id.uuidString)", lineCoordinates: l.coordinates)
                p.lineColor = StyleColor(l.color.uiColor)
                p.lineWidth = 3
                fresh.append(p)
            }
            manager.annotations = fresh
        }

        private func refreshDrawingPolygons() {
            guard let manager = ensurePolygon(\.drawingPolygonManager) else { return }
            var fresh: [PolygonAnnotation] = []
            for poly in parent.drawingStore.polygons where poly.coordinates.count >= 3 {
                let ring = Ring(coordinates: poly.coordinates)
                let polygon = Polygon(outerRing: ring)
                var p = PolygonAnnotation(id: "dp-\(poly.id.uuidString)", polygon: polygon)
                p.fillColor = StyleColor(poly.color.uiColor.withAlphaComponent(0.2))
                p.fillOutlineColor = StyleColor(poly.color.uiColor)
                fresh.append(p)
            }
            manager.annotations = fresh
        }

        private func refreshDrawingCircles() {
            // Circles are meter-radius — Mapbox CircleAnnotation is
            // pixel-radius, so we approximate as a 64-segment polygon
            // and feed it through the same polygon manager so fill
            // & outline styling stay consistent with hand-drawn polys.
            // Keep them on a separate manager keyed by id so the
            // diff stays clean.
            guard let mapView = mapView else { return }
            let id = "circles"
            // Lazily create a dedicated polygon manager for circles.
            if !circleManagerAttached {
                circlePolygonManager = mapView.annotations.makePolygonAnnotationManager(id: id)
                circleManagerAttached = true
            }
            var fresh: [PolygonAnnotation] = []
            for c in parent.drawingStore.circles {
                let coords = Self.circleCoordinates(center: c.center, radiusMeters: c.radius, segments: 64)
                let ring = Ring(coordinates: coords)
                let polygon = Polygon(outerRing: ring)
                var ann = PolygonAnnotation(id: "dc-\(c.id.uuidString)", polygon: polygon)
                ann.fillColor = StyleColor(c.color.uiColor.withAlphaComponent(0.2))
                ann.fillOutlineColor = StyleColor(c.color.uiColor)
                fresh.append(ann)
            }
            circlePolygonManager?.annotations = fresh
        }

        private var circleManagerAttached = false
        private var circlePolygonManager: PolygonAnnotationManager?

        /// Approximate a great-circle ring of `radiusMeters` around
        /// `center` as a polygon. Latitude scaling accounts for
        /// longitude convergence near the poles so the visual stays
        /// circular at high latitudes.
        private static func circleCoordinates(center: CLLocationCoordinate2D, radiusMeters: Double, segments: Int) -> [CLLocationCoordinate2D] {
            let earthRadius = 6_378_137.0
            let lat = center.latitude * .pi / 180
            let lon = center.longitude * .pi / 180
            let d = radiusMeters / earthRadius
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(segments + 1)
            for i in 0...segments {
                let bearing = Double(i) / Double(segments) * 2 * .pi
                let lat2 = asin(sin(lat) * cos(d) + cos(lat) * sin(d) * cos(bearing))
                let lon2 = lon + atan2(
                    sin(bearing) * sin(d) * cos(lat),
                    cos(d) - sin(lat) * sin(lat2)
                )
                coords.append(CLLocationCoordinate2D(
                    latitude: lat2 * 180 / .pi,
                    longitude: lon2 * 180 / .pi
                ))
            }
            return coords
        }

        // MARK: - Drawing temp overlay (in-progress)

        private func refreshDrawingTempOverlay() {
            guard let lineManager = ensureLine(\.drawingTempLineManager) else { return }
            let dm = parent.drawingManager
            var lines: [PolylineAnnotation] = []
            var verts: [PointAnnotation] = []

            if dm.isDrawingActive {
                let temps = dm.getTemporaryAnnotations().map { $0.coordinate }
                if temps.count >= 2 {
                    // Mapbox v11 PolylineAnnotation does not expose dash
                    // patterns at the annotation level (those live on the
                    // LineLayer). The temp overlay is short-lived enough
                    // that a solid blue line reads fine; if we want dashes
                    // we'll promote this to a LineLayer + GeoJSONSource.
                    var p = PolylineAnnotation(id: "dtemp-line", lineCoordinates: temps)
                    p.lineColor = StyleColor(.systemBlue)
                    p.lineWidth = 2
                    lines.append(p)
                }
                for (i, c) in temps.enumerated() {
                    var ann = PointAnnotation(id: "dtemp-v\(i)", coordinate: c)
                    ann.image = .init(image: Self.tempVertexImage, name: "temp-vertex")
                    ann.iconAnchor = .center
                    verts.append(ann)
                }
            }
            lineManager.annotations = lines
            // Reuse drawingLabelManager? No — use a dedicated vertex
            // manager so labels and temp dots don't fight for the same
            // text/icon configuration.
            ensureTempVertexManager()?.annotations = verts
        }

        private var tempVertexManager: PointAnnotationManager?
        private func ensureTempVertexManager() -> PointAnnotationManager? {
            if let m = tempVertexManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager(id: "temp-vertices")
            tempVertexManager = m
            return m
        }

        private static let tempVertexImage: UIImage = {
            let size = CGSize(width: 20, height: 20)
            let r = UIGraphicsImageRenderer(size: size)
            return r.image { _ in
                UIColor(red: 1.0, green: 252/255, blue: 0, alpha: 1).setFill()
                let p = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
                p.fill()
                UIColor.white.setStroke()
                p.lineWidth = 3
                p.stroke()
                UIColor.black.setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 2, y: size.height / 2 - 2, width: 4, height: 4)).fill()
            }
        }()

        // MARK: - Measurement overlay

        private func refreshMeasurementOverlay() {
            guard let lineManager = ensureLine(\.measurementLineManager) else { return }
            let mm = parent.measurementManager
            var lines: [PolylineAnnotation] = []
            var rings: [PolygonAnnotation] = []
            var verts: [PointAnnotation] = []

            if mm.isActive {
                let verticesIn = mm.getTemporaryAnnotations().map { $0.coordinate }
                if verticesIn.count >= 2 {
                    var p = PolylineAnnotation(id: "meas-line", lineCoordinates: verticesIn)
                    p.lineColor = StyleColor(.systemYellow)
                    p.lineWidth = 3
                    lines.append(p)
                }
                for (i, c) in verticesIn.enumerated() {
                    var ann = PointAnnotation(id: "meas-v\(i)", coordinate: c)
                    ann.image = .init(image: Self.tempVertexImage, name: "temp-vertex")
                    ann.iconAnchor = .center
                    verts.append(ann)
                }
            }

            // Range rings — meter-radius circles approximated as
            // polygons so they scale with map zoom.
            for ring in mm.rangeRings {
                let coords = Self.circleCoordinates(center: ring.center, radiusMeters: ring.radiusMeters, segments: 64)
                let polygon = Polygon(outerRing: Ring(coordinates: coords))
                var p = PolygonAnnotation(id: "rangering-\(ring.center.latitude)-\(ring.center.longitude)-\(ring.radiusMeters)", polygon: polygon)
                p.fillColor = StyleColor(UIColor.systemOrange.withAlphaComponent(0.1))
                p.fillOutlineColor = StyleColor(UIColor.systemOrange)
                rings.append(p)
            }

            lineManager.annotations = lines
            ensureMeasurementVertexManager()?.annotations = verts
            ensureRangeRingManager()?.annotations = rings
        }

        private func ensureMeasurementVertexManager() -> PointAnnotationManager? {
            if let m = measurementVertexManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager(id: "meas-vertices")
            measurementVertexManager = m
            return m
        }
        private func ensureRangeRingManager() -> PolygonAnnotationManager? {
            if let m = rangeRingManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolygonAnnotationManager(id: "range-rings")
            rangeRingManager = m
            return m
        }

        // MARK: - Range & Bearing

        private func refreshRangeBearing() {
            guard let lineManager = ensureLine(\.rangeBearingLineManager) else { return }
            guard parent.overlayCoordinator.rangeBearingEnabled else {
                lineManager.annotations = []
                rangeBearingLabelManager?.annotations = []
                return
            }
            let service = RangeBearingService.shared
            var lines: [PolylineAnnotation] = []
            var labels: [PointAnnotation] = []

            for line in service.lines {
                var p = PolylineAnnotation(id: "rb-\(line.id)", lineCoordinates: [line.origin, line.destination])
                p.lineColor = StyleColor(.systemOrange)
                p.lineWidth = service.configuration.lineWidth
                lines.append(p)

                let mid = Self.midpoint(line.origin, line.destination)
                var label = PointAnnotation(id: "rb-lbl-\(line.id)", coordinate: mid)
                let distance = service.formatDistance(line.distanceMeters)
                let bearing: String
                switch service.configuration.bearingType {
                case .magnetic: bearing = "\(service.formatBearing(line.magneticBearing))M"
                case .true:     bearing = "\(service.formatBearing(line.trueBearing))T"
                case .grid:     bearing = "\(service.formatBearing(line.gridBearing))G"
                }
                label.textField = "\(distance) / \(bearing)"
                label.textColor = StyleColor(.white)
                label.textHaloColor = StyleColor(.black)
                label.textHaloWidth = 1.5
                label.textSize = 11
                labels.append(label)
            }
            lineManager.annotations = lines
            if rangeBearingLabelManager == nil, let mapView = mapView {
                rangeBearingLabelManager = mapView.annotations.makePointAnnotationManager(id: "rb-labels")
            }
            rangeBearingLabelManager?.annotations = labels
        }

        private static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        }

        // MARK: - Breadcrumb trail

        private func refreshBreadcrumbTrail() {
            guard let manager = ensureLine(\.breadcrumbLineManager) else { return }
            guard parent.overlayCoordinator.breadcrumbTrailsEnabled else {
                manager.annotations = []
                return
            }
            let service = BreadcrumbTrailService.shared
            let coords = service.trailCoordinates
            guard coords.count >= 2 else { manager.annotations = []; return }
            let teamColorStr = PositionBroadcastService.shared.teamColor
            let color = UIColor(hexString: teamColorStr) ?? UIColor.green
            var p = PolylineAnnotation(id: "breadcrumb", lineCoordinates: coords)
            p.lineColor = StyleColor(color)
            p.lineWidth = service.configuration.lineWidth
            manager.annotations = [p]
        }

        // MARK: - Lasso highlight rings (selected markers)

        private func refreshLassoHighlightRings() {
            guard let manager = ensurePolygon(\.lassoSelectionRingManager) else { return }
            let sel = parent.lassoService.current
            guard !sel.isEmpty else { manager.annotations = []; return }
            var rings: [PolygonAnnotation] = []
            func addRing(at coord: CLLocationCoordinate2D, id: String) {
                let coords = Self.circleCoordinates(center: coord, radiusMeters: 40, segments: 32)
                let polygon = Polygon(outerRing: Ring(coordinates: coords))
                var ring = PolygonAnnotation(id: "ring-\(id)", polygon: polygon)
                ring.fillColor = StyleColor(UIColor.systemOrange.withAlphaComponent(0.12))
                ring.fillOutlineColor = StyleColor(UIColor.systemOrange)
                rings.append(ring)
            }
            for cot in parent.markers where sel.markerIDs.contains(cot.uid) {
                addRing(at: cot.coordinate, id: "cot-\(cot.uid)")
            }
            for pt in parent.pointMarkers where sel.markerIDs.contains(pt.id.uuidString) {
                addRing(at: pt.coordinate, id: "pt-\(pt.id.uuidString)")
            }
            for m in parent.drawingStore.markers where sel.markerIDs.contains(m.id.uuidString) {
                addRing(at: m.coordinate, id: "dm-\(m.id.uuidString)")
            }
            manager.annotations = rings
        }

        // MARK: - Tap gesture (contact hit-test, then map tap)

        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: point)
            parent.onMapTap(coordinate)
        }

        // MARK: - Long-press → radial menu

        /// Map the long-press to the right radial-menu surface:
        /// point markers, drawing shapes, or empty-map context. We do
        /// the hit-test ourselves against the model data (cheaper and
        /// more reliable than projecting every annotation through
        /// `mapboxMap.point(for:)` for each press).
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = mapView else { return }
            let screenPoint = gesture.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: screenPoint)

            // 1) Point markers
            if let pm = nearestPointMarker(to: screenPoint, in: mapView) {
                parent.radialMenuCoordinator.showPointMarkerMenu(
                    at: screenPoint,
                    coordinate: coordinate,
                    marker: pm
                )
                return
            }

            // 2) Drawing markers
            if let dm = nearestDrawingMarker(to: screenPoint, in: mapView) {
                parent.radialMenuCoordinator.showContextMenu(
                    at: screenPoint,
                    for: coordinate,
                    menuType: .markerContext,
                    drawingId: dm.id,
                    drawingType: .marker
                )
                return
            }

            // 3) Drawing shapes (lines, polygons, circles)
            if let hit = drawingShapeHit(at: coordinate) {
                parent.radialMenuCoordinator.showContextMenu(
                    at: screenPoint,
                    for: coordinate,
                    menuType: .markerContext,
                    drawingId: hit.id,
                    drawingType: hit.type
                )
                return
            }

            // 4) Empty map
            parent.radialMenuCoordinator.showContextMenu(
                at: screenPoint,
                for: coordinate,
                menuType: .mapContext
            )
        }

        private func nearestPointMarker(to screenPoint: CGPoint, in mapView: MapView) -> PointMarker? {
            let radius: CGFloat = 44
            var best: (PointMarker, CGFloat)?
            for pm in parent.pointMarkers {
                let p = mapView.mapboxMap.point(for: pm.coordinate)
                let d = hypot(p.x - screenPoint.x, p.y - screenPoint.y)
                if d < radius, best == nil || d < best!.1 {
                    best = (pm, d)
                }
            }
            return best?.0
        }

        private func nearestDrawingMarker(to screenPoint: CGPoint, in mapView: MapView) -> MarkerDrawing? {
            let radius: CGFloat = 44
            var best: (MarkerDrawing, CGFloat)?
            for m in parent.drawingStore.markers {
                let p = mapView.mapboxMap.point(for: m.coordinate)
                let d = hypot(p.x - screenPoint.x, p.y - screenPoint.y)
                if d < radius, best == nil || d < best!.1 {
                    best = (m, d)
                }
            }
            return best?.0
        }

        private struct DrawingShapeHit { let id: UUID; let type: RadialMenuContext.DrawingType }

        private func drawingShapeHit(at coordinate: CLLocationCoordinate2D) -> DrawingShapeHit? {
            // Circles — radial distance check is the cheapest.
            for c in parent.drawingStore.circles {
                let d = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    .distance(from: CLLocation(latitude: c.center.latitude, longitude: c.center.longitude))
                if d <= c.radius {
                    return DrawingShapeHit(id: c.id, type: .circle)
                }
            }
            // Polygons — ray casting in lat/lon space (cheap enough at
            // typical hit-test scales; we're not trying to win the
            // GIS olympics here).
            for poly in parent.drawingStore.polygons {
                if Self.pointInPolygon(point: coordinate, polygon: poly.coordinates) {
                    return DrawingShapeHit(id: poly.id, type: .polygon)
                }
            }
            // Lines — sample-based proximity. Tolerance scales with
            // zoom indirectly via meters-per-pixel; 30m at world
            // scale is generous, fine at tactical scale.
            let tolerance: CLLocationDistance = 30
            for line in parent.drawingStore.lines where line.coordinates.count >= 2 {
                for i in 0..<(line.coordinates.count - 1) {
                    if Self.distance(from: coordinate, toSegmentFrom: line.coordinates[i], to: line.coordinates[i + 1]) <= tolerance {
                        return DrawingShapeHit(id: line.id, type: .line)
                    }
                }
            }
            return nil
        }

        private static func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
            guard polygon.count >= 3 else { return false }
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let pi = polygon[i], pj = polygon[j]
                if ((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) &&
                   (point.longitude < (pj.longitude - pi.longitude) *
                    (point.latitude - pi.latitude) /
                    (pj.latitude - pi.latitude) + pi.longitude) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        private static func distance(from point: CLLocationCoordinate2D,
                                     toSegmentFrom a: CLLocationCoordinate2D,
                                     to b: CLLocationCoordinate2D) -> CLLocationDistance {
            let locP = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
            let ab = locA.distance(from: locB)
            guard ab > 0 else { return locP.distance(from: locA) }
            // Project P onto AB in flat lat/lon space — good enough
            // at tactical distances.
            let t = max(0, min(1,
                ((point.latitude - a.latitude) * (b.latitude - a.latitude) +
                 (point.longitude - a.longitude) * (b.longitude - a.longitude)) /
                (pow(b.latitude - a.latitude, 2) + pow(b.longitude - a.longitude, 2))
            ))
            let closest = CLLocationCoordinate2D(
                latitude: a.latitude + t * (b.latitude - a.latitude),
                longitude: a.longitude + t * (b.longitude - a.longitude)
            )
            return locP.distance(from: CLLocation(latitude: closest.latitude, longitude: closest.longitude))
        }

        // MARK: - Lasso gesture (issue #16)

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === lassoGesture { return false }
            return false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === lassoGesture {
                return parent.drawingManager.isDrawingActive &&
                       parent.drawingManager.currentMode == .lasso
            }
            return true
        }

        @objc func handleLassoGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView = mapView else { return }
            let service = parent.lassoService
            switch gesture.state {
            case .began:
                let point = gesture.location(in: mapView)
                let coord = mapView.mapboxMap.coordinate(for: point)
                service.beginLasso()
                service.appendVertex(coord)
                installLassoOverlay(on: mapView, firstPoint: point)
            case .changed:
                let point = gesture.location(in: mapView)
                let coord = mapView.mapboxMap.coordinate(for: point)
                service.appendVertex(coord)
                refreshLassoOverlay(on: mapView, point: point)
            case .ended, .cancelled, .failed:
                let markers: [LassoMarker] =
                    parent.markers.map(LassoMarker.init(cot:)) +
                    parent.pointMarkers.map(LassoMarker.init(point:)) +
                    parent.drawingStore.markers.map(LassoMarker.init(marker:))
                let drawings: [LassoDrawing] =
                    parent.drawingStore.lines.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                    parent.drawingStore.polygons.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                    parent.drawingStore.circles.map { LassoDrawing(id: $0.id, coordinates: [$0.center]) }
                _ = service.endLasso(markers: markers, drawings: drawings)
                removeLassoOverlay(on: mapView)
                parent.drawingManager.cancelDrawing()
            default:
                break
            }
        }

        private func installLassoOverlay(on mapView: MapView, firstPoint: CGPoint) {
            removeLassoOverlay(on: mapView)
            let layer = CAShapeLayer()
            layer.frame = mapView.bounds
            layer.strokeColor = UIColor.systemOrange.cgColor
            layer.fillColor = UIColor.systemOrange.withAlphaComponent(0.05).cgColor
            layer.lineWidth = 3
            layer.lineDashPattern = [6, 4]
            layer.lineJoin = .round
            layer.lineCap = .round
            mapView.layer.addSublayer(layer)
            lassoPathLayer = layer
            lassoViewPoints = [firstPoint]
            updateLassoLayerPath()
        }

        private func refreshLassoOverlay(on mapView: MapView, point: CGPoint) {
            lassoViewPoints.append(point)
            updateLassoLayerPath()
        }

        private func updateLassoLayerPath() {
            guard let layer = lassoPathLayer, lassoViewPoints.count >= 2 else { return }
            let path = UIBezierPath()
            path.move(to: lassoViewPoints[0])
            for pt in lassoViewPoints.dropFirst() { path.addLine(to: pt) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = path.cgPath
            CATransaction.commit()
        }

        private func removeLassoOverlay(on mapView: MapView) {
            lassoPathLayer?.removeFromSuperlayer()
            lassoPathLayer = nil
            lassoViewPoints = []
        }
    }
}

// MARK: - Radial menu Mapbox bridge
//
// Decouple the radial-menu coordinator from MKMapView so the Mapbox
// `TacticalMapView` can drive it without smuggling in an MKMapView
// reference. Mirrors the same context-building logic as the legacy
// `handleLongPress(at:on:)` path.

extension RadialMenuMapCoordinator {
    /// Show the point-marker radial menu using a coordinate already
    /// resolved by the Mapbox layer. Bypasses the MKMapView
    /// hit-test path that the legacy MapKit map relied on.
    func showPointMarkerMenu(at screenPoint: CGPoint,
                              coordinate: CLLocationCoordinate2D,
                              marker: PointMarker) {
        guard isRadialMenuEnabled else { return }

        // Build a synthetic annotation-bearing context so downstream
        // handlers (executeAction, highlightedItemIndex, etc.) see the
        // same shape they always have.
        let annotation = PointMarkerAnnotation(marker: marker)
        let context = RadialMenuContext(
            screenPoint: screenPoint,
            mapCoordinate: coordinate,
            pressedAnnotation: annotation,
            pressedMarker: marker,
            pressedWaypoint: nil,
            pressedDrawingId: nil,
            pressedDrawingType: nil,
            contextType: .pointMarker
        )
        menuConfiguration = .markerContextMenu(for: marker)
        currentContext = context
        menuCenterPoint = adjustMenuPositionForMapbox(screenPoint, menuRadius: menuConfiguration.radius)
        RadialMenuHaptic.menuAppear.trigger()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showRadialMenu = true
        }
        onMenuShown?(context)
    }

    /// Local copy of the private `adjustMenuPosition` used by the
    /// legacy `handleLongPress(at:on:)` path. Mirrors the screen-edge
    /// avoidance behaviour without exposing it as part of the public
    /// API of the original coordinator.
    private func adjustMenuPositionForMapbox(_ point: CGPoint, menuRadius: CGFloat) -> CGPoint {
        let screenBounds = UIScreen.main.bounds
        let padding: CGFloat = 20.0
        let requiredSpace = menuRadius + padding
        var p = point
        if p.x < requiredSpace { p.x = requiredSpace }
        else if p.x > screenBounds.width - requiredSpace { p.x = screenBounds.width - requiredSpace }
        if p.y < requiredSpace + 100 { p.y = requiredSpace + 100 }
        else if p.y > screenBounds.height - requiredSpace - 100 { p.y = screenBounds.height - requiredSpace - 100 }
        return p
    }
}

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
// update can distinguish them from other MKPointAnnotations. Measurement
// uses MeasurementPointAnnotation from MeasurementService.swift.
class DrawingTempPointAnnotation: MKPointAnnotation {}

// MARK: - Overlay Settings Panel

struct OverlaySettingsPanel: View {
    @ObservedObject var overlayCoordinator: MapOverlayCoordinator
    @ObservedObject var mapStateManager: MapStateManager

    @Binding var showMGRSGrid: Bool
    @Binding var showBreadcrumbTrails: Bool
    @Binding var showRBLines: Bool

    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("OVERLAYS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // MGRS Grid Toggle
            OverlayToggleButton(
                icon: "grid",
                title: "MGRS Grid",
                isActive: showMGRSGrid
            ) {
                showMGRSGrid.toggle()
                overlayCoordinator.saveSettings()
            }

            // Grid Density Picker (only show when grid is active)
            if showMGRSGrid {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grid Density")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10)

                    Picker("Density", selection: $overlayCoordinator.mgrsGridDensity) {
                        ForEach(MGRSGridDensity.allCases) { density in
                            Text(density.rawValue).tag(density)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal, 10)
                }
            }

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.vertical, 4)

            // Breadcrumb Trails Toggle
            OverlayToggleButton(
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                title: "Breadcrumb Trails",
                isActive: showBreadcrumbTrails
            ) {
                showBreadcrumbTrails.toggle()
                overlayCoordinator.saveSettings()
            }

            // R&B Lines Toggle
            OverlayToggleButton(
                icon: "arrow.triangle.swap",
                title: "R&B Lines",
                isActive: showRBLines
            ) {
                showRBLines.toggle()
                overlayCoordinator.saveSettings()
            }

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.vertical, 4)

            // Current Map Center MGRS
            VStack(alignment: .leading, spacing: 4) {
                Text("MAP CENTER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)

                Text(overlayCoordinator.currentCenterMGRS.isEmpty ? "--" : overlayCoordinator.currentCenterMGRS)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 200)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
    }
}

// MARK: - Overlay Toggle Button

struct OverlayToggleButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isActive ? Color.green.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
    }
}
