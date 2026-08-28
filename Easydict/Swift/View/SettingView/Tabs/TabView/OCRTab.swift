//
//  OCRTab.swift
//  Easydict
//
//  Created by agent on 2026/8/28.
//  Copyright © 2026 izual. All rights reserved.
//

import Defaults
import SFSafeSymbols
import SwiftUI

/// Settings for the OCR feature: silent-OCR auto copy plus recognition
/// providers and text post-processing.
struct OCRTab: View {
    // MARK: Internal

    var body: some View {
        Form {
            Section {
                Toggle("auto_copy_ocr_text", isOn: $autoCopyOCRText)
            } header: {
                Text("setting.general.auto_copy.header")
            }

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
            } header: {
                Text("setting.advance.header.ocr_settings")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Private

    @Default(.autoCopyOCRText) private var autoCopyOCRText
    @Default(.enableYoudaoOCR) private var enableYoudaoOCR
    @Default(.enableOCRTextNormalization) private var enableOCRTextNormalization
}

#Preview {
    OCRTab()
}
