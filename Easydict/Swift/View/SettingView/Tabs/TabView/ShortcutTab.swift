//
//  ShortcutTab.swift
//  Easydict
//
//  Created by Sharker on 2024/1/21.
//  Copyright © 2024 izual. All rights reserved.
//

import SwiftUI
struct ShortcutTab: View {
    var body: some View {
        Form {
            Section {
                GlobalShortcutSettingView()
            } header: {
                Text("global_shortcut_setting")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ShortcutTab()
}
