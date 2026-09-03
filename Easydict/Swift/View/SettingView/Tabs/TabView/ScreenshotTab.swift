//
//  ScreenshotTab.swift
//  Easydict
//
//  Created by agent on 2026/8/28.
//  Copyright © 2026 izual. All rights reserved.
//

import Defaults
import SFSafeSymbols
import SwiftUI

/// Settings for the capture suite: global shortcuts, capture behavior and
/// saving. The UserDefaults switches share keys with the capture engine
/// (Feature/MacshotCapture), which reads them directly.
struct ScreenshotTab: View {
    // MARK: Internal

    var body: some View {
        Form {
            Section {
                GlobalShortcutSettingView()
            } header: {
                Text("global_shortcut_setting")
            }

            Section {
                Toggle(isOn: $playCopySound) {
                    AdvancedTabItemView(
                        color: .orange,
                        icon: .speakerWave2Fill,
                        labelText: "setting.screenshot.sound",
                        subtitleText: "setting.screenshot.sound_desc"
                    )
                }
                Toggle(isOn: $captureCursor) {
                    AdvancedTabItemView(
                        color: .blue,
                        icon: .cursorarrow,
                        labelText: "setting.screenshot.capture_cursor",
                        subtitleText: "setting.screenshot.capture_cursor_desc"
                    )
                }
                Toggle(isOn: $doubleClickToCopy) {
                    AdvancedTabItemView(
                        color: .green,
                        icon: .docOnDoc,
                        labelText: "setting.screenshot.double_click_copy",
                        subtitleText: "setting.screenshot.double_click_copy_desc"
                    )
                }
                Toggle(isOn: $windowSnapEnabled) {
                    AdvancedTabItemView(
                        color: .purple,
                        icon: .rectangleDashed,
                        labelText: "setting.screenshot.window_snap",
                        subtitleText: "setting.screenshot.window_snap_desc"
                    )
                }
                Toggle(isOn: $rememberLastTool) {
                    AdvancedTabItemView(
                        color: .mint,
                        icon: .paintbrushPointed,
                        labelText: "setting.screenshot.remember_tool",
                        subtitleText: "setting.screenshot.remember_tool_desc"
                    )
                }
                Toggle(isOn: $isScreenshotTipLayerHidden) {
                    AdvancedTabItemView(
                        color: .gray,
                        icon: .lightbulbFill,
                        labelText: "setting.advance.hide_screenshot_tip_layer",
                        subtitleText: "setting.advance.hide_screenshot_tip_layer_desc"
                    )
                }
            } header: {
                Text("setting.screenshot.behavior")
            }

            Section {
                Picker("setting.screenshot.save_action", selection: $saveAction) {
                    Text("setting.screenshot.save_action.folder").tag(0)
                    Text("setting.screenshot.save_action.ask").tag(1)
                }

                if saveAction == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("setting.screenshot.save_directory")
                        Text(saveDirectoryPath)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Spacer()
                            Button("setting.screenshot.save_reveal") {
                                revealSaveDirectory()
                            }
                            Button("setting.screenshot.save_choose") {
                                chooseSaveDirectory()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("setting.screenshot.filename_template")
                    TextField(
                        "setting.screenshot.filename_placeholder",
                        text: $filenameTemplate
                    )
                    .textFieldStyle(.roundedBorder)
                    HStack(alignment: .firstTextBaseline) {
                        Text("setting.screenshot.filename_template_desc")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("setting.screenshot.filename_reset") {
                            filenameTemplate = FilenameFormatter.defaultTemplate
                        }
                    }
                }
                .padding(.vertical, 2)

                Picker("setting.screenshot.image_format", selection: $imageFormatRaw) {
                    ForEach(ImageEncoder.Format.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                Toggle(isOn: $downscaleRetina) {
                    AdvancedTabItemView(
                        color: .indigo,
                        icon: .photo,
                        labelText: "setting.screenshot.downscale_retina",
                        subtitleText: "setting.screenshot.downscale_retina_desc"
                    )
                }
            } header: {
                Text("setting.screenshot.save")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("setting.screenshot.pronunciation_prompt")
                    Text("setting.screenshot.pronunciation_prompt_desc")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextEditor(text: $pronunciationPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 170)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.15))
                        )
                    HStack {
                        Spacer()
                        Button("setting.screenshot.pronunciation_reset") {
                            pronunciationPrompt = PronunciationHelper.defaultPrompt
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("setting.screenshot.pronunciation")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Private

    // Engine-shared switches. Defaults mirror the engine's own fallbacks so
    // the UI matches behavior before the user ever touches a toggle.
    @AppStorage("playCopySound") private var playCopySound = true
    @AppStorage("captureCursor") private var captureCursor = false
    @AppStorage("doubleClickToCopy") private var doubleClickToCopy = true
    @AppStorage("windowSnapEnabled") private var windowSnapEnabled = true
    @AppStorage("rememberLastTool") private var rememberLastTool = true
    @AppStorage("downscaleRetina") private var downscaleRetina = false
    @AppStorage("imageFormat") private var imageFormatRaw = "png"

    // Engine-shared save preferences. Raw values mirror SaveActionPreference
    // (0 = save to folder, 1 = ask every time); the template and directory
    // are read by ImageSaveService/SaveDirectoryAccess on every save.
    @AppStorage(SaveActionPreference.userDefaultsKey) private var saveAction = 0
    @AppStorage(FilenameFormatter.userDefaultsKey) private var filenameTemplate = FilenameFormatter
        .defaultTemplate

    @State private var saveDirectoryPath = ""

    @Default(.isScreenshotTipLayerHidden) private var isScreenshotTipLayerHidden

    /// Prompt sent to the AI chain that renders Chinese phonetic hints for
    /// short sources; editable so domain terms (frameworks, team jargon)
    /// can be recognized the way the user's field actually says them.
    @Default(.dockPronunciationPrompt) private var pronunciationPrompt

    private func refreshSaveDirectoryPath() {
        saveDirectoryPath = (SaveDirectoryAccess.displayPath as NSString).expandingTildeInPath
    }

    private func revealSaveDirectory() {
        let url = SaveDirectoryAccess.resolve()
        NSWorkspace.shared.open(url)
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.save(url: url)
            refreshSaveDirectoryPath()
        }
    }
}

#Preview {
    ScreenshotTab()
}
