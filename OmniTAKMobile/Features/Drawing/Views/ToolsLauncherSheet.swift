//
//  ToolsLauncherSheet.swift
//  OmniTAKMobile
//
//  Issue #16 — small bottom-sheet popup launched from the map's
//  floating wrench button. Map stays visible behind it
//  (presentationDetents .height(220) + .medium). Two rows: the
//  marquee "Lasso Select" + a passthrough to the full 5x4 tools grid.
//
//  Design contract: map is the most important part of the app and
//  must remain visible while choosing a tool. This sheet sits at the
//  bottom edge, taking ~220pt by default, and supports
//  presentationBackgroundInteraction so the user can still pan/zoom
//  the underlying map without dismissing.
//

import SwiftUI

struct ToolsLauncherSheet: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Marquee row — Lasso Select is the K9Blue SAR primary
            // ask. Bigger tap target, orange tint to match the
            // in-progress lasso outline.
            Button(action: onLasso) {
                HStack(spacing: 14) {
                    Image(systemName: "lasso")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.orange)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lasso Select")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Long-press + drag on the map to multi-select")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, 70)

            // Passthrough to the full 5x4 grid. Useful when the
            // user wants Measure / Drawing / CASEVAC / etc. without
            // navigating up to whatever existing entry point ATAK
            // tools has.
            Button(action: onFullTools) {
                HStack(spacing: 14) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Tools…")
                            .font(.system(size: 17))
                            .foregroundColor(.primary)
                        Text("Drawing, Measure, CASEVAC, Routes, and more")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

#if DEBUG
struct ToolsLauncherSheet_Previews: PreviewProvider {
    static var previews: some View {
        ToolsLauncherSheet(onLasso: {}, onFullTools: {})
            .preferredColorScheme(.dark)
    }
}
#endif
