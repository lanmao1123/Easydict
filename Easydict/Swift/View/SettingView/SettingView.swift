//
//  SettingView.swift
//  Easydict
//
//  Created by Kyle on 2023/12/29.
//  Copyright © 2023 izual. All rights reserved.
//

import SFSafeSymbols
import SwiftUI

// MARK: - SettingTab

/// The existing settings destinations and their localized navigation labels.
enum SettingTab: Int, Identifiable {
    case general
    case screenshot
    case clipboard
    case ocr
    case shortcut
    case service
    case about

    // MARK: Internal

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "setting_general"
        case .screenshot: "setting.sidebar.screenshot"
        case .clipboard: "setting.sidebar.clipboard"
        case .ocr: "setting.sidebar.ocr"
        case .shortcut: "shortcut"
        case .service: "setting.sidebar.translate"
        case .about: "setting.about"
        }
    }

    var symbol: SFSymbol {
        switch self {
        case .general: .gearshape
        case .screenshot: .cameraViewfinder
        case .clipboard: .clipboard
        case .ocr: .docTextMagnifyingglass
        case .shortcut: .commandSquare
        case .service: .characterBubble
        case .about: .infoCircle
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .screenshot: .blue
        case .clipboard: .orange
        case .ocr: .purple
        case .shortcut: .pink
        case .service: .green
        case .about: .indigo
        }
    }
}

// MARK: - SettingSidebarGroup

/// Groups related settings while keeping every destination visible.
private enum SettingSidebarGroup: String, CaseIterable, Identifiable {
    case general
    case features
    case other

    // MARK: Internal

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "setting.sidebar.general"
        case .features: "setting.sidebar.features"
        case .other: "setting.sidebar.other"
        }
    }

    var tabs: [SettingTab] {
        switch self {
        case .general: [.general]
        case .features: [.screenshot, .clipboard, .ocr, .shortcut, .service]
        case .other: [.about]
        }
    }
}

// MARK: - SettingView

/// A stable settings window with keyboard-accessible navigation and grouped forms.
struct SettingView: View {
    // MARK: Internal

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .background(
            WindowAccessor(window: $window.didSet(execute: { _ in
                // reset frame when first launch
                resizeWindowFrame()
            }))
        )
    }

    func resizeWindowFrame() {
        guard let window else { return }

        // Disable zoom button, refer: https://stackoverflow.com/a/66039864/8378840
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Keep every destination at the same size: shrinking About used to
        // clip the navigation and make switching pages move the window.
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let newSize = CGSize(
            width: min(900, visibleFrame.width),
            height: min(720, visibleFrame.height)
        )
        let originalFrame = window.frame
        let origin = CGPoint(
            x: min(max(originalFrame.minX, visibleFrame.minX), visibleFrame.maxX - newSize.width),
            y: min(max(originalFrame.maxY - newSize.height, visibleFrame.minY), visibleFrame.maxY - newSize.height)
        )
        window.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
        // macOS 27: keep the sidebar below the title bar by removing the
        // `.fullSizeContentView` style SwiftUI keeps after resize. Older macOS
        // versions are unaffected.
        // Refer: https://github.com/tisfeng/Easydict/pull/1258#issuecomment-5186918247
        if #available(macOS 27.0, *) {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.styleMask.remove(.resizable)
    }

    // MARK: Private

    private static let sidebarWidth: Double = 196

    @State private var selection = SettingTab.general
    @State private var window: NSWindow?

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SettingSidebarGroup.allCases) { group in
                Section {
                    ForEach(group.tabs) { tab in
                        Label {
                            Text(tab.titleKey)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                        } icon: {
                            Image(systemSymbol: tab.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(tab.color.gradient, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .padding(.vertical, 4)
                        .tag(tab)
                    }
                } header: {
                    Text(group.titleKey)
                }
            }
        }
        .listStyle(.sidebar)
        .padding(.top, 8)
        .frame(width: Self.sidebarWidth)
    }

    private var contentArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemSymbol: selection.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(selection.color)
                Text(selection.titleKey)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .general: GeneralTab()
        case .screenshot: ScreenshotTab()
        case .clipboard: ClipboardTab()
        case .ocr: OCRTab()
        case .shortcut: ShortcutTab()
        case .service: ServiceTab()
        case .about: AboutTab()
        }
    }
}

#Preview {
    SettingView()
}
