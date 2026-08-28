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

    class CheckUpdaterViewModel: ObservableObject {
        // MARK: Lifecycle

        init() {
            updater
                .publisher(for: \.automaticallyChecksForUpdates)
                .assign(to: &$autoChecksForUpdates)
        }

        // MARK: Internal

        @Published var autoChecksForUpdates = true {
            didSet {
                updater.automaticallyChecksForUpdates = autoChecksForUpdates
            }
        }

        // MARK: Private

        private let updater = MyConfiguration.shared.updater
    }

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Form {
            Section {
                FirstAndSecondLanguageSettingView()
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

                // Check for updates
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("check_for_updates")
                        Text("lastest_version \(lastestVersion ?? version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("check_now") {
                        MyConfiguration.shared.updater.checkForUpdates()
                    }
                }

                Toggle(isOn: $checkUpdaterViewModel.autoChecksForUpdates) {
                    Text("auto_check_update ")
                }

                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("setting.general.startup_and_update.include_beta")
                        Text("setting.general.startup_and_update.include_beta.description")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle(
                        isOn: $includeBetaUpdates.didSet(execute: { state in
                            logSettings(["include_beta_updates": state])
                            if state {
                                MyConfiguration.shared.updater.checkForUpdates()
                            }
                        })
                    ) {
                        EmptyView()
                    }
                    .labelsHidden()
                }

                Toggle(isOn: $enableBetaFeature) {
                    Text("setting.advance.enable_beta_feature")
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
        .task {
            lastestVersion = await fetchRepoLatestVersion(EZGithubRepoEasydict)
        }
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

    @StateObject private var checkUpdaterViewModel = CheckUpdaterViewModel()

    @State private var lastestVersion: String?

    // Query language
    @Default(.languageDetectOptimize) private var languageDetectOptimize
    @Default(.enableBetaFeature) private var enableBetaFeature

    // Auto copy

    @Default(.appearanceType) private var appearanceType
    @Default(.hideMenuBarIcon) private var hideMenuBarIcon
    @Default(.selectedMenuBarIcon) private var selectedMenuBarIcon
    @Default(.enableMarkdownRendering) private var enableMarkdownRendering

    @Default(.includeBetaUpdates) private var includeBetaUpdates

    // MARK: Raycast Integration

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

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

// MARK: - FirstAndSecondLanguageSettingView

private struct FirstAndSecondLanguageSettingView: View {
    // MARK: Internal

    var body: some View {
        Group {
            Picker("setting.general.language.first_language", selection: $firstLanguage) {
                ForEach(Language.allAvailableOptions, id: \.rawValue) { option in
                    Text(verbatim: "\(option.flagEmoji) \(option.localizedName)")
                        .tag(option)
                }
            }
            Picker("setting.general.language.second_language", selection: $secondLanguage) {
                ForEach(Language.allAvailableOptions, id: \.rawValue) { option in
                    Text(verbatim: "\(option.flagEmoji) \(option.localizedName)")
                        .tag(option)
                }
            }
        }
        .onChange(of: firstLanguage) { [firstLanguage] newValue in
            let oldValue = firstLanguage
            if newValue == secondLanguage {
                secondLanguage = oldValue
                languageDuplicatedAlert = .init(
                    duplicatedLanguage: newValue, setField: .second, setLanguage: oldValue
                )
            }
        }
        .onChange(of: secondLanguage) { [secondLanguage] newValue in
            let oldValue = secondLanguage
            if newValue == firstLanguage {
                firstLanguage = oldValue
                languageDuplicatedAlert = .init(
                    duplicatedLanguage: newValue, setField: .first, setLanguage: oldValue
                )
            }
        }
        .alert(
            "setting.general.language.duplicated_alert.title",
            isPresented: showLanguageDuplicatedAlert,
            presenting: languageDuplicatedAlert
        ) { _ in
        } message: { alert in
            Text(alert.description)
        }
    }

    // MARK: Private

    private struct LanguageDuplicateAlert: CustomStringConvertible {
        enum Field: CustomLocalizedStringResourceConvertible {
            case first
            case second

            // MARK: Internal

            var localizedStringResource: LocalizedStringResource {
                switch self {
                case .first:
                    "setting.general.language.duplicated_alert.field.first"
                case .second:
                    "setting.general.language.duplicated_alert.field.second"
                }
            }
        }

        let duplicatedLanguage: Language

        let setField: Field

        let setLanguage: Language

        var description: String {
            // First language should not be same as second language. (\(duplicatedLanguage))
            // \(setField) is replaced with \(setLanguage).
            String(
                localized:
                "setting.general.language.duplicated_alert \(duplicatedLanguage.localizedName)\(String(localized: setField.localizedStringResource))\(setLanguage.localizedName)"
            )
        }
    }

    @State private var languageDuplicatedAlert: LanguageDuplicateAlert?

    @Default(.firstLanguage) private var firstLanguage
    @Default(.secondLanguage) private var secondLanguage

    private var showLanguageDuplicatedAlert: Binding<Bool> {
        .init {
            languageDuplicatedAlert != nil
        } set: { newValue in
            if !newValue {
                languageDuplicatedAlert = nil
            }
        }
    }
}
