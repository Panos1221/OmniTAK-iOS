import SwiftUI
import MapKit
import WebKit
import CoreLocation

// MARK: - ATAK Tools Menu View
// Comprehensive tools menu with 5x4 grid layout matching ATAK interface

struct ATAKToolsView: View {
    @Binding var isPresented: Bool
    @Binding var showMeasurement: Bool  // Shared measurement state from MapViewController

    @ObservedObject private var pluginManager = PluginSettingsManager.shared
    @AppStorage("showDisabledTools") private var showDisabledTools: Bool = true

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    /// Filtered tools based on the toggle
    private var visibleTools: [ATAKTool] {
        if showDisabledTools {
            return ATAKTool.allTools
        } else {
            return ATAKTool.allTools.filter { pluginManager.isToolEnabled($0.id) }
        }
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with toggle
                ToolsHeader(
                    showDisabledTools: $showDisabledTools,
                    onClose: { isPresented = false }
                )

                // Tools Grid (5x4 layout)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(visibleTools) { tool in
                            let isEnabled = pluginManager.isToolEnabled(tool.id)
                            ToolButton(
                                tool: tool,
                                isEnabled: isEnabled,
                                action: {
                                    if isEnabled {
                                        handleToolSelection(tool)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func handleToolSelection(_ tool: ATAKTool) {
        switch tool.id {
        // Map-mode commands — these drive map state, not sheets, so they
        // keep their notification/binding wiring.
        case "drawing":
            // Reuse the existing radial-menu notification that opens the drawing tools panel
            NotificationCenter.default.post(name: .radialMenuOpenDrawingTools, object: nil)
            isPresented = false  // Dismiss tools menu so the drawing panel is visible
        case "measure":
            // Use the shared measurement overlay from MapViewController
            showMeasurement = true
            isPresented = false  // Dismiss tools menu
        case "lasso":
            // Issue #16 — activate freehand multi-select. Same
            // notification pattern as the drawing tool entry so
            // MapViewController owns the actual mode change.
            NotificationCenter.default.post(name: .startLassoMode, object: nil)
            isPresented = false  // Dismiss tools menu so the user can draw

        default:
            // Everything else routes through the single dispatcher
            // (ToolSheetHost via ToolRegistry) — exactly like
            // ToolsLauncherSheet and the customizable toolbar. Dismiss the
            // full-screen grid first, then post once it's off-screen.
            let id = tool.id
            isPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                NotificationCenter.default.post(name: .openToolSheet, object: nil, userInfo: ["id": id])
            }
        }
    }
}

// MARK: - Tools Header

struct ToolsHeader: View {
    @Binding var showDisabledTools: Bool
    let onClose: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.t("tools.grid.title"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .padding()

            // Toggle row
            HStack {
                Text(loc.t("tools.grid.showDisabled"))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)

                Spacer()

                Toggle("", isOn: $showDisabledTools)
                    .labelsHidden()
                    .scaleEffect(0.8)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.black)
    }
}

// MARK: - Tool Button

struct ToolButton: View {
    let tool: ATAKTool
    var isEnabled: Bool = true
    let action: () -> Void
    // Runtime i18n — the grid previously hardcoded English next to the
    // fully localized launcher. Titles/subtitles resolve through the same
    // tools.<id>.title/.subtitle keys ToolsLauncherSheet uses (with new
    // keys for the grid-only tools); LocalizationManager falls back to
    // the English catalog, then the key.
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Image(systemName: tool.iconName)
                        .font(.system(size: 32))
                        .foregroundColor(isEnabled ? .white : .gray.opacity(0.4))
                        .frame(height: 44)

                    Text(loc.t("tools.\(tool.id).title"))
                        .font(.system(size: 12))
                        .foregroundColor(isEnabled ? .white : .gray.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 32)
                }
                .accessibilityHint(Text(loc.t("tools.\(tool.id).subtitle")))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isEnabled ? Color(white: 0.15) : Color(white: 0.08))
                .overlay(
                    Rectangle()
                        .stroke(Color(white: 0.3), lineWidth: 0.5)
                )
                .overlay(
                    // Disabled overlay
                    Group {
                        if !isEnabled {
                            Color.black.opacity(0.3)
                        }
                    }
                )

                // "Beta" badge for disabled/experimental tools
                if !isEnabled {
                    Text(loc.t("tools.grid.beta"))
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(3)
                        .padding(4)
                }
            }
        }
        .disabled(!isEnabled)
    }
}

// MARK: - ATAK Tool Model

struct ATAKTool: Identifiable {
    let id: String
    let displayName: String
    let iconName: String
    let description: String

    /// Map-mode commands that live only in the grid (they drive map
    /// state via notifications/bindings, not sheets, so they aren't in
    /// ToolRegistry).
    private static let mapCommandTools: [ATAKTool] = [
        ATAKTool(id: "drawing", displayName: "Drawing", iconName: "pencil.tip.crop.circle", description: "Draw on map"),
        ATAKTool(id: "measure", displayName: "Measure", iconName: "ruler", description: "Distance and area measurement"),
        ATAKTool(id: "lasso", displayName: "Select", iconName: "lasso", description: "Multi-select features in a freehand region (long-press + drag)"),
    ]

    /// Grid layout order. Sheet tools resolve through ToolRegistry (the
    /// single catalog), so name/icon/description live in ONE place.
    /// Map-engine toggle deliberately omitted from the grid — it lives
    /// in the slick Tools popup (ToolsLauncherSheet). Mode switchers
    /// don't belong in Full Tools.
    private static let gridOrder: [String] = [
        // Row 1 - Core Features
        "teams", "chat", "routes", "geofence", "tracks",
        // Row 2 - Data & Media
        "data", "video", "offline", "kml", "drawing", "measure", "lasso",
        // Row 3 - Tactical
        "alert", "pointer", "casevac", "nineline", "bloodhound",
        // Row 4 - Utilities & Reports
        "spotrep", "turnbyturn", "meshtastic",
        // Row 5 - Map-driven destinations (absorbed from removed navigation drawer)
        "contacts", "selfsa", "missionsync", "elevation", "los",
        // Row 6 - Hierarchy & Utilities
        "echelon", "adsb", "uas", "gotocoord", "plugins", "settings",
    ]

    static let allTools: [ATAKTool] = gridOrder.compactMap { id in
        if let command = mapCommandTools.first(where: { $0.id == id }) {
            return command
        }
        guard let descriptor = ToolRegistry.descriptor(for: id) else { return nil }
        return ATAKTool(
            id: descriptor.id,
            displayName: descriptor.displayName,
            iconName: descriptor.icon,
            description: descriptor.description
        )
    }
}

// MARK: - Sheet Wrapper Views

struct DataPackageSheetView: View {
    @Binding var isPresented: Bool
    @StateObject private var packageManager = DataPackageManager()

    var body: some View {
        DataPackageView(packageManager: packageManager, isPresented: $isPresented)
    }
}

struct PointDropperSheetView: View {
    @Binding var isPresented: Bool
    // Must observe the shared singleton the map renders from — newing up a
    // fresh PointDropperService here dropped markers into a throwaway object
    // the map never saw, so dropped points never appeared.
    @ObservedObject private var service = PointDropperService.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var mapCenterStore = MapCenterStore.shared

    var body: some View {
        PointDropperView(
            service: service,
            isPresented: $isPresented,
            currentLocation: location.location?.coordinate,
            mapCenter: mapCenterStore.center
        )
    }
}

struct BloodhoundSheetView: View {
    @StateObject private var bloodhoundService = BloodhoundService()
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    var body: some View {
        BloodhoundView(bloodhoundService: bloodhoundService, mapRegion: $mapRegion)
    }
}

// MARK: - Color Extension
// Color extension with hex initializer is defined in SharedUIComponents.swift

// MARK: - Cesium 3D Scene presenter

/// Full-screen wrapper around a WKWebView hosting CesiumJS with Google
/// Photorealistic 3D Tiles + Cesium World Terrain. The HTML loads
/// Cesium from cesium.com's CDN so we don't have to bundle the SDK.
struct CesiumScenePresenter: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CesiumWebView()
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(16)
            }
            .accessibilityLabel("Close 3D scene")
        }
        .background(Color.black)
    }
}

private struct CesiumWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false

        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://cesium.com/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Build-time injected from the gitignored Config.xcconfig — single source
    /// of truth is `CesiumIonConfig` (MapViewController.swift). Never hardcode.
    private static var cesiumIonToken: String { CesiumIonConfig.token }

    private static var html: String {
        """
        <!DOCTYPE html><html lang=\"en\"><head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover\">
        <link href=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Widgets/widgets.css\" rel=\"stylesheet\">
        <style>
          html,body{margin:0;padding:0;height:100%;width:100%;overflow:hidden;background:#000;color:#fff;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
          #cesiumContainer{position:absolute;inset:0}
          #loading{position:absolute;top:50%;left:0;right:0;text-align:center;transform:translateY(-50%);z-index:10;pointer-events:none}
          .dot{display:inline-block;width:12px;height:12px;border-radius:50%;background:#FFCC00;margin:0 4px;animation:p 1.4s infinite}
          .dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
          @keyframes p{0%,80%,100%{opacity:.3}40%{opacity:1}}
          .label{margin-top:16px;font-size:14px;opacity:.7}
          .cesium-viewer-bottom{display:none!important}
        </style></head><body>
        <div id=\"loading\"><span class=\"dot\"></span><span class=\"dot\"></span><span class=\"dot\"></span><div class=\"label\">Loading 3D world…</div></div>
        <div id=\"cesiumContainer\"></div>
        <script src=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Cesium.js\"></script>
        <script>
          Cesium.Ion.defaultAccessToken='\(cesiumIonToken)';
          (async()=>{
            const v=new Cesium.Viewer('cesiumContainer',{
              terrain:Cesium.Terrain.fromWorldTerrain(),
              animation:false,timeline:false,baseLayerPicker:false,geocoder:false,
              homeButton:false,sceneModePicker:false,navigationHelpButton:false,
              fullscreenButton:false,infoBox:false,selectionIndicator:false,
              creditContainer:document.createElement('div')
            });
            v.scene.skyAtmosphere.show=true;v.scene.globe.enableLighting=true;
            try{const t=await Cesium.createGooglePhotorealistic3DTileset();v.scene.primitives.add(t);}catch(e){console.warn('Photoreal unavailable:',e);}
            v.camera.flyTo({
              destination:Cesium.Cartesian3.fromDegrees(-77.0365,38.8977,5000),
              orientation:{heading:0,pitch:Cesium.Math.toRadians(-30),roll:0},
              duration:1.5,
              complete:()=>{const el=document.getElementById('loading');if(el)el.style.display='none';}
            });
          })().catch(e=>{const el=document.getElementById('loading');if(el)el.innerHTML='<div class=\"label\">3D scene failed: '+(e&&e.message?e.message:'unknown')+'</div>';});
        </script></body></html>
        """
    }
}
