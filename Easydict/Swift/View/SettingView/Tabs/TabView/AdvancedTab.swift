//
//  AdvancedTab.swift
//  Easydict
//
//  Created by tisfeng on 2024/1/23.
//  Copyright © 2024 izual. All rights reserved.
//

import Defaults
import SFSafeSymbols
import SwiftUI

struct AdvancedTab: View {
    // MARK: Internal

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enableBetaFeature) {
                    AdvancedTabItemView(
                        color: .blue,
                        icon: .hammerFill,
                        labelText: "setting.advance.enable_beta_feature"
                    )
                }
            }

            // OCR settings section
            Section {
                Toggle(isOn: $enableYoudaoOCR) {
                    AdvancedTabItemView(
                        color: .blue,
                        icon: .circleRectangleFilledPatternDiagonalline,
                        labelText: "setting.advance.enable_youdao_ocr",
                        subtitleText: "setting.advance.enable_youdao_ocr_desc"
                    )
                }
                Toggle(isOn: $enableOCRTextNormalization) {
                    AdvancedTabItemView(
                        color: .green,
                        icon: .docViewfinder,
                        labelText: "setting.advance.enable_ocr_text_normalization",
                        subtitleText: "setting.advance.enable_ocr_text_normalization_desc"
                    )
                }

                Toggle(isOn: $isScreenshotTipLayerHidden) {
                    AdvancedTabItemView(
                        color: .purple,
                        icon: .lightbulbFill,
                        labelText: "setting.advance.hide_screenshot_tip_layer",
                        subtitleText: "setting.advance.hide_screenshot_tip_layer_desc"
                    )
                }
            } header: {
                Text("setting.advance.header.ocr_settings")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Private

    @Default(.enableBetaFeature) private var enableBetaFeature

    @Default(.enableYoudaoOCR) private var enableYoudaoOCR
    @Default(.enableOCRTextNormalization) private var enableOCRTextNormalization
    @Default(.isScreenshotTipLayerHidden) private var isScreenshotTipLayerHidden
}

#Preview {
    AdvancedTab()
}
