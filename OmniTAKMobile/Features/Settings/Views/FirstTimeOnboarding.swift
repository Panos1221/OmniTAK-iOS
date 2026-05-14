//
//  FirstTimeOnboarding.swift
//  OmniTAKMobile
//
//  Beautiful onboarding experience for first-time users
//

import SwiftUI

// MARK: - First Time Onboarding

struct FirstTimeOnboarding: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationManager
    @State private var currentPage = 0
    @State private var showEnrollment = false

    var onComplete: () -> Void = {}

    let pages = OnboardingPage.all

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button(action: {
                        onComplete()
                        dismiss()
                    }) {
                        Text(loc.t("onboarding.skip"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(hex: "#CCCCCC"))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Custom page indicator
                pageIndicator

                // Action button
                actionButton
            }
        }
        .fullScreenCover(isPresented: $showEnrollment) {
            SimpleEnrollView()
                .environmentObject(loc)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(currentPage == index ? Color(hex: "#FFFC00") : Color(hex: "#666666"))
                    .frame(width: currentPage == index ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.3), value: currentPage)
            }
        }
        .padding(.vertical, 24)
    }

    private var actionButton: some View {
        VStack(spacing: 12) {
            Button(action: {
                if currentPage < pages.count - 1 {
                    withAnimation {
                        currentPage += 1
                    }
                } else {
                    onComplete()
                    showEnrollment = true
                }
            }) {
                HStack {
                    Text(currentPage == pages.count - 1
                         ? loc.t("onboarding.getStarted")
                         : loc.t("onboarding.continue"))
                        .font(.system(size: 18, weight: .semibold))
                    if currentPage == pages.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(hex: "#FFFC00"))
                .cornerRadius(14)
            }

            if currentPage > 0 {
                Button(action: {
                    withAnimation {
                        currentPage -= 1
                    }
                }) {
                    Text(loc.t("onboarding.back"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "#CCCCCC"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
    }
}

// MARK: - Onboarding Page Model

struct OnboardingPage {
    let icon: String
    /// Localization keys — resolved through LocalizationManager in
    /// OnboardingPageView so the page re-renders on a live language
    /// switch. See Resources/*.lproj/Localizable.strings.
    let titleKey: String
    let descKey: String
    let color: Color
    let featureKeys: [String]

    static let all: [OnboardingPage] = [
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right",
            titleKey: "onboarding.page1.title",
            descKey: "onboarding.page1.desc",
            color: Color(hex: "#FFFC00"),
            featureKeys: [
                "onboarding.page1.feature1",
                "onboarding.page1.feature2",
                "onboarding.page1.feature3",
                "onboarding.page1.feature4"
            ]
        ),
        OnboardingPage(
            icon: "lock.shield.fill",
            titleKey: "onboarding.page2.title",
            descKey: "onboarding.page2.desc",
            color: Color(hex: "#00FF00"),
            featureKeys: [
                "onboarding.page2.feature1",
                "onboarding.page2.feature2",
                "onboarding.page2.feature3",
                "onboarding.page2.feature4"
            ]
        ),
        OnboardingPage(
            icon: "bolt.circle.fill",
            titleKey: "onboarding.page3.title",
            descKey: "onboarding.page3.desc",
            color: Color(hex: "#00BFFF"),
            featureKeys: [
                "onboarding.page3.feature1",
                "onboarding.page3.feature2",
                "onboarding.page3.feature3",
                "onboarding.page3.feature4"
            ]
        ),
        OnboardingPage(
            icon: "map.fill",
            titleKey: "onboarding.page4.title",
            descKey: "onboarding.page4.desc",
            color: Color(hex: "#FF6B35"),
            featureKeys: [
                "onboarding.page4.feature1",
                "onboarding.page4.feature2",
                "onboarding.page4.feature3",
                "onboarding.page4.feature4"
            ]
        )
    ]
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(page.color.opacity(0.15))
                    .frame(width: 140, height: 140)

                Circle()
                    .fill(page.color.opacity(0.25))
                    .frame(width: 100, height: 100)

                Image(systemName: page.icon)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(page.color)
            }

            // Title
            Text(loc.t(page.titleKey))
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Description
            Text(loc.t(page.descKey))
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "#CCCCCC"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)

            // Features
            VStack(spacing: 14) {
                ForEach(page.featureKeys, id: \.self) { featureKey in
                    FeatureRow(text: loc.t(featureKey), color: page.color)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
    }
}

struct FeatureRow: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.white)

            Spacer()
        }
    }
}

// MARK: - Onboarding Manager

class OnboardingManager: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }
}

// MARK: - Quick Start Guide

struct QuickStartGuide: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationManager

    let guides = [
        QuickStartItem(
            icon: "qrcode.viewfinder",
            titleKey: "quickstart.item.qr.title",
            descKey: "quickstart.item.qr.desc",
            difficultyKey: "quickstart.difficulty.easiest",
            time: "< 30 sec",
            color: Color(hex: "#00FF00")
        ),
        QuickStartItem(
            icon: "wifi.circle.fill",
            titleKey: "quickstart.item.discover.title",
            descKey: "quickstart.item.discover.desc",
            difficultyKey: "quickstart.difficulty.easy",
            time: "< 1 min",
            color: Color(hex: "#00BFFF")
        ),
        QuickStartItem(
            icon: "bolt.circle.fill",
            titleKey: "quickstart.item.quick.title",
            descKey: "quickstart.item.quick.desc",
            difficultyKey: "quickstart.difficulty.easy",
            time: "< 2 min",
            color: Color(hex: "#FF6B35")
        ),
        QuickStartItem(
            icon: "keyboard",
            titleKey: "quickstart.item.manual.title",
            descKey: "quickstart.item.manual.desc",
            difficultyKey: "quickstart.difficulty.advanced",
            time: "~3 min",
            color: Color(hex: "#9B59B6")
        )
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 12) {
                            Image(systemName: "book.fill")
                                .font(.system(size: 48))
                                .foregroundColor(Color(hex: "#FFFC00"))

                            Text(loc.t("quickstart.title"))
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)

                            Text(loc.t("quickstart.subtitle"))
                                .font(.system(size: 15))
                                .foregroundColor(Color(hex: "#CCCCCC"))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)
                        .padding(.horizontal, 32)

                        // Guide items
                        VStack(spacing: 16) {
                            ForEach(guides, id: \.titleKey) { guide in
                                QuickStartItemView(item: guide)
                            }
                        }
                        .padding(.horizontal, 20)

                        // Help section
                        helpSection
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(loc.t("quickstart.done")) {
                        dismiss()
                    }
                    .foregroundColor(Color(hex: "#FFFC00"))
                }
            }
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(Color(hex: "#FFFC00"))
                Text(loc.t("quickstart.needHelp"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 12) {
                HelpLink(icon: "doc.text.fill", text: loc.t("quickstart.help.docs"), url: "https://docs.omnitak.com")
                HelpLink(icon: "person.2.fill", text: loc.t("quickstart.help.support"), url: "mailto:support@omnitak.com")
                HelpLink(icon: "video.fill", text: loc.t("quickstart.help.videos"), url: "https://youtube.com/@omnitak")
            }
        }
        .padding(20)
        .background(Color(white: 0.1))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

struct QuickStartItem {
    let icon: String
    /// Localization keys — resolved through LocalizationManager in
    /// QuickStartItemView. `time` stays a literal (numeric-ish, no
    /// catalogue key in the v1 scope).
    let titleKey: String
    let descKey: String
    let difficultyKey: String
    let time: String
    let color: Color
}

struct QuickStartItemView: View {
    let item: QuickStartItem
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 28))
                    .foregroundColor(item.color)
                    .frame(width: 56, height: 56)
                    .background(item.color.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(item.titleKey))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)

                    HStack(spacing: 12) {
                        Label(loc.t(item.difficultyKey), systemImage: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(item.color)

                        Label(item.time, systemImage: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#CCCCCC"))
                    }
                }

                Spacer()
            }

            Text(loc.t(item.descKey))
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#CCCCCC"))
                .lineSpacing(2)
        }
        .padding(16)
        .background(Color(white: 0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(item.color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct HelpLink: View {
    let icon: String
    let text: String
    let url: String

    var body: some View {
        Button(action: {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#FFFC00"))
                    .frame(width: 28)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#666666"))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FirstTimeOnboarding_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FirstTimeOnboarding()
            QuickStartGuide()
        }
        .environmentObject(LocalizationManager.shared)
        .preferredColorScheme(.dark)
    }
}
#endif
