//
//  LassoContactPickerSheet.swift
//  OmniTAKMobile
//
//  Issue #16 — picker for "Send Lasso Selection to Contacts." Shows
//  every live CoT contact (from TAKService.cotEvents) as a tappable
//  row; the caller receives the chosen UIDs back so the send path
//  can route the lasso selection via `<dest>` elements.
//
//  Mirrors the Android ContactPickerDialog.kt — Material 3 there,
//  SwiftUI sheet here, same shape.
//

import SwiftUI

struct LassoContactPickerSheet: View {
    let candidates: [CoTEventLike]
    /// UIDs to hide from the picker — typically the lasso selection
    /// itself (don't send markers to themselves).
    let excludeUIDs: Set<String>
    let onCancel: () -> Void
    let onConfirm: (Set<String>) -> Void

    @State private var selected: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var visibleCandidates: [CoTEventLike] {
        candidates
            .filter { !excludeUIDs.contains($0.uid) }
            .sorted { ($0.callsign ?? $0.uid).localizedCaseInsensitiveCompare($1.callsign ?? $1.uid) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            Group {
                if visibleCandidates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No contacts available")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Wait for at least one peer to appear on the map.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visibleCandidates) { c in
                        ContactPickerRow(
                            contact: c,
                            isSelected: selected.contains(c.uid),
                        ) {
                            if selected.contains(c.uid) {
                                selected.remove(c.uid)
                            } else {
                                selected.insert(c.uid)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Send to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Send" : "Send to \(selected.count)") {
                        onConfirm(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - Row

private struct ContactPickerRow: View {
    let contact: CoTEventLike
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? Color(hex: "#FF9500") : Color.secondary)
                Circle()
                    .fill(affiliationColor(for: contact.type))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.callsign?.isEmpty == false ? contact.callsign! : contact.uid)
                        .foregroundColor(.primary)
                        .font(.system(size: 15, weight: .medium))
                    Text(contact.uid.prefix(20))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func affiliationColor(for type: String) -> Color {
        let parts = type.split(separator: "-")
        guard parts.count >= 2, let first = parts[1].first else { return .gray }
        return switch first {
        case "f": Color(red: 0, green: 1, blue: 0.4)
        case "h": Color(red: 1, green: 0.25, blue: 0.25)
        case "n": Color(red: 0.83, green: 0.69, blue: 0.4)
        case "u": Color(red: 1, green: 0.8, blue: 0)
        default: .gray
        }
    }
}

// MARK: - Identifiable wrapper

/// Thin adapter so callers can hand `CoTEvent` (or any source type
/// with these fields) into the picker without coupling this view to
/// the concrete CoT model.
struct CoTEventLike: Identifiable, Hashable {
    let uid: String
    let type: String
    let callsign: String?
    var id: String { uid }
}
