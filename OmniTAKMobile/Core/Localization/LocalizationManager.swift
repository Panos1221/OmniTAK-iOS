//
//  LocalizationManager.swift
//  OmniTAKMobile
//
//  Runtime language switching without an app restart.
//
//  iOS normally only picks up a language change on relaunch. This
//  manager swaps in a per-language `.lproj` bundle at runtime and,
//  being an ObservableObject, drives a SwiftUI re-render the instant
//  the language changes — so the picker in Settings takes effect
//  immediately.
//
//  ## Usage
//  Views that show localized text observe the manager and resolve
//  keys through it:
//
//      @EnvironmentObject private var loc: LocalizationManager
//      ...
//      Text(loc.t("onboarding.welcome.title"))
//
//  The `@EnvironmentObject` dependency is what makes the view
//  re-render when `setLanguage` fires. Inject it once at the app
//  root: `.environmentObject(LocalizationManager.shared)`.
//
//  Non-view code (formatters, services) can use the free function
//  `L("key")` — but those call sites won't auto-refresh on a live
//  switch; that's fine for one-shot strings.
//

import Foundation
import SwiftUI
import Combine

final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    /// Languages OmniTAK ships UI translations for. English is the
    /// base catalogue every other language falls back to.
    enum Language: String, CaseIterable, Identifiable {
        case english   = "en"
        case ukrainian = "uk"
        case polish    = "pl"
        case german    = "de"
        case french    = "fr"
        case spanish   = "es"

        var id: String { rawValue }

        /// Endonym — the language's name in its own language, which
        /// is what users scanning a language list expect to see.
        var displayName: String {
            switch self {
            case .english:   return "English"
            case .ukrainian: return "Українська"
            case .polish:    return "Polski"
            case .german:    return "Deutsch"
            case .french:    return "Français"
            case .spanish:   return "Español"
            }
        }

        /// Flag emoji for the picker. Ukrainian uses the UA flag;
        /// the rest map to the obvious nation.
        var flag: String {
            switch self {
            case .english:   return "🇬🇧"
            case .ukrainian: return "🇺🇦"
            case .polish:    return "🇵🇱"
            case .german:    return "🇩🇪"
            case .french:    return "🇫🇷"
            case .spanish:   return "🇪🇸"
            }
        }
    }

    /// The active language. SwiftUI views observing the manager
    /// re-render whenever this changes.
    @Published private(set) var current: Language

    /// Bundle for the active language's `.lproj`. Falls back to
    /// `.main` if the resource is missing (shouldn't happen once the
    /// catalogues are registered, but keeps the app rendering).
    private var activeBundle: Bundle

    /// English base bundle — the fallback for any key a translation
    /// catalogue hasn't filled in yet.
    private let baseBundle: Bundle

    private static let storageKey = "appLanguage"
    private static let keyMissingSentinel = "\u{0}__OMNITAK_KEY_MISSING__\u{0}"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        let initial = stored.flatMap(Language.init(rawValue:)) ?? Self.systemDefault()
        self.current = initial
        self.activeBundle = Self.bundle(for: initial)
        self.baseBundle = Self.bundle(for: .english)
    }

    /// Switch the app's language. Persists the choice, updates the
    /// active bundle, and updates `AppleLanguages` so anything that
    /// reads the system locale directly (date formatters,
    /// UIKit-hosted views) picks it up on next launch. The
    /// `@Published` change re-renders every observing SwiftUI view
    /// immediately — no restart for the SwiftUI surface.
    func setLanguage(_ language: Language) {
        guard language != current else { return }
        current = language
        activeBundle = Self.bundle(for: language)
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// Resolve a localization key against the active language,
    /// falling back to the English base catalogue, then to the key
    /// itself (so a missing string is visible in testing rather
    /// than rendering blank).
    func t(_ key: String) -> String {
        let value = activeBundle.localizedString(
            forKey: key, value: Self.keyMissingSentinel, table: nil
        )
        if value != Self.keyMissingSentinel {
            return value
        }
        // Active catalogue doesn't have this key — fall back to English.
        if current != .english {
            let baseValue = baseBundle.localizedString(
                forKey: key, value: Self.keyMissingSentinel, table: nil
            )
            if baseValue != Self.keyMissingSentinel {
                return baseValue
            }
        }
        return key
    }

    /// Resolve a key with `String(format:)` arguments — for strings
    /// carrying `%@` / `%d` placeholders.
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    // MARK: - Private

    private static func bundle(for language: Language) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let langBundle = Bundle(path: path) else {
            return .main
        }
        return langBundle
    }

    /// Best-effort match of the device's preferred language to one
    /// OmniTAK ships. Falls back to English.
    private static func systemDefault() -> Language {
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix(2)).lowercased()
            if let match = Language(rawValue: code) {
                return match
            }
        }
        return .english
    }
}

/// Free-function shortcut for non-view code (formatters, services,
/// log strings). Call sites using this do NOT auto-refresh on a
/// live language switch — use `loc.t(...)` with `@EnvironmentObject`
/// inside SwiftUI views that need to react.
func L(_ key: String) -> String {
    LocalizationManager.shared.t(key)
}
