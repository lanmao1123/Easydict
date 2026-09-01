//
//  GeneralTab.swift
//  Easydict
//
//  Created by Kyle on 2023/12/29.
//  Copyright © 2023 izual. All rights reserved.
//

import Defaults
import LaunchAtLogin
import SFSafeSymbols
import SwiftUI

// MARK: - GeneralTab

struct GeneralTab: View {
    // MARK: Internal

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Form {
            Section {
                Picker(
                    "setting.general.language.language_detect_optimize",
                    selection: $languageDetectOptimize
                ) {
                    ForEach(LanguageDetectOptimize.allCases, id: \.rawValue) { option in
                        Text(option.localizedStringResource)
                            .tag(option)
                    }
                }
            } header: {
                Text("setting.general.query_language.header")
            }

            Section {
                Picker("setting.general.language", selection: $languageState.language) {
                    ForEach(LanguageState.LanguageType.allCases, id: \.rawValue) { language in
                        Text(language.name)
                            .tag(language)
                    }
                }
                Picker(
                    "setting.general.appearance.light_dark_appearance", selection: $appearanceType
                ) {
                    ForEach(AppearanceType.allCases, id: \.rawValue) { option in
                        Text(option.title)
                            .tag(option)
                    }
                }

                LaunchAtLogin.Toggle {
                    Text("launch_at_startup")
                }
                .onChange(of: LaunchAtLogin.isEnabled) { newValue in
                    logSettings(["launch_at_startup": newValue])
                }

                Toggle(
                    isOn: $hideMenuBarIcon.didSet(execute: { state in
                        if state {
                            // user is not set input shortcut and selection shortcut not allow hide menu bar
                            if !shortcutsHaveSetuped {
                                Defaults[.hideMenuBarIcon] = false
                                showRefuseAlert = true
                            } else {
                                showHideMenuBarIconAlert = true
                            }
                        }
                    })
                ) {
                    Text("hide_menu_bar_icon")
                }
                Picker(
                    "modify_menubar_icon",
                    selection: $selectedMenuBarIcon
                ) {
                    ForEach(MenuBarIconType.allCases) { option in
                        Label {
                            EmptyView()
                        } icon: {
                            Image(option.rawValue)
                                .renderingMode(.template)
                        }
                        .labelStyle(.iconOnly)
                    }
                }

            } header: {
                Text("setting.general.app_setting.header")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("setting.general.raycast.title")
                    Text("setting.general.raycast.setup_guide")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("setting.general.raycast.header")
            }
        }
        .formStyle(.grouped)
        .alert("hide_menu_bar_icon", isPresented: $showRefuseAlert) {
            Button("ok") {
                showRefuseAlert = false
            }
        } message: {
            Text("refuse_hide_menu_bar_icon_msg")
        }
        .alert("hide_menu_bar_icon", isPresented: $showHideMenuBarIconAlert) {
            HStack {
                Button("ok") {
                    showHideMenuBarIconAlert = false
                }
                Button("cancel") {
                    Defaults[.hideMenuBarIcon] = false
                }
            }
        } message: {
            Text("hide_menu_bar_icon_msg")
        }
    }

    // MARK: Private

    // App setting
    @EnvironmentObject private var languageState: LanguageState
    @State private var showRefuseAlert = false
    @State private var showHideMenuBarIconAlert = false

    // Query language
    @Default(.languageDetectOptimize) private var languageDetectOptimize

    // Auto copy

    @Default(.appearanceType) private var appearanceType
    @Default(.hideMenuBarIcon) private var hideMenuBarIcon
    @Default(.selectedMenuBarIcon) private var selectedMenuBarIcon
    @Default(.enableMarkdownRendering) private var enableMarkdownRendering

    // MARK: Raycast Integration

    private var shortcutsHaveSetuped: Bool {
        // The translate shortcuts were removed with the feature strip; the
        // guard now keys off the always-present F1 capture shortcut.
        Defaults[.snipToolsEditShortcut] != nil
    }

    /// Opens the Easy Dictionary extension page. For an installed extension
    /// Raycast launches it; otherwise it shows the store install page, which
    /// is the closest thing to one-click integration Raycast allows.
    private func logSettings(_ parameters: [String: Any]) {
        AnalyticsService.logEvent(withName: "settings", parameters: parameters)
    }
}

#Preview {
    GeneralTab()
}
