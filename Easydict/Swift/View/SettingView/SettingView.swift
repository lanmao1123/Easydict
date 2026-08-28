//
//  SettingView.swift
//  Easydict
//
//  Created by Kyle on 2023/12/29.
//  Copyright © 2023 izual. All rights reserved.
//

import SwiftUI

// MARK: - SettingTab

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

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .screenshot: "camera.viewfinder"
        case .clipboard: "clipboard"
        case .ocr: "doc.text.magnifyingglass"
        case .shortcut: "command.square"
        case .service: "translate"
        case .about: "info.bubble"
        }
    }
}

// MARK: - SettingSidebarGroup

/// Sidebar sections in the Bob-style settings layout.
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
        .onChange(of: selection) { _ in
            resizeWindowFrame()
        }
    }

    func resizeWindowFrame() {
        guard let window else { return }

        // Disable zoom button, refer: https://stackoverflow.com/a/66039864/8378840
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Keep the settings page Windows all the same width to avoid strange animations.
        let maxWidth: Double = 900
        let height: Double = switch selection {
        case .about:
            300
        default:
            maxWidth * 0.8
        }

        let newSize = CGSize(width: maxWidth, height: height)

        let originalFrame = window.frame
        let newY = originalFrame.origin.y + originalFrame.size.height - newSize.height
        let newRect = NSRect(origin: CGPoint(x: originalFrame.origin.x, y: newY), size: newSize)

        window.setFrame(newRect, display: true, animate: false)
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

    private static let sidebarWidth: Double = 176

    @State private var selection = SettingTab.general
    @State private var window: NSWindow?

    /// Grouped nav list on the left; the selected row is an accent capsule
    /// with white text, matching the Bob settings layout.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SettingSidebarGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.titleKey)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 3)

                    ForEach(group.tabs) { tab in
                        sidebarRow(tab)
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: Self.sidebarWidth, alignment: .leading)
        .background(Color.gray.opacity(0.08))
    }

    private var contentArea: some View {
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Bob-style inset rounded cards for every Form-based tab.
        .formStyle(.grouped)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarRow(_ tab: SettingTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(tab.titleKey)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingView()
}
