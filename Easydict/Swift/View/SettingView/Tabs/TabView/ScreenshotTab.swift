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

    @Default(.isScreenshotTipLayerHidden) private var isScreenshotTipLayerHidden
}

#Preview {
    ScreenshotTab()
}
