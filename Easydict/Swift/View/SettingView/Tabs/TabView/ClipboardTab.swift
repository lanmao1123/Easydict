//
//  ClipboardTab.swift
//  Easydict
//
//  Created by agent on 2026/8/28.
//  Copyright © 2026 izual. All rights reserved.
//

import SwiftUI

/// Settings for the clipboard history feature. The values are shared with
/// ClipboardMonitor's pruning pass through UserDefaults.
struct ClipboardTab: View {
    // MARK: Internal

    var body: some View {
        Form {
            Section {
                Picker("setting.clipboard.max_count", selection: $maxCount) {
                    ForEach(Self.countOptions, id: \.self) { count in
                        Text("clipboard.count_option \(count)").tag(count)
                    }
                }
                Picker("setting.clipboard.age_days", selection: $ageDays) {
                    ForEach(Self.ageOptions, id: \.self) { days in
                        Text("clipboard.days_option \(days)").tag(days)
                    }
                }
            } header: {
                Text("setting.sidebar.clipboard")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("setting.clipboard.storage")
                    Text(storePath)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("setting.clipboard.reveal") {
                            revealInFinder()
                        }
                        Button("setting.clipboard.choose") {
                            chooseDirectory()
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("setting.clipboard.storage_header")
            } footer: {
                Text("setting.clipboard.storage_desc")
            }
        }
        .formStyle(.grouped)
        .onAppear { storePath = activeStorePath() }
    }

    // MARK: Private

    private static let countOptions = [100, 200, 500, 1000]
    private static let ageOptions = [30, 90, 180, 365]

    // Defaults mirror ClipboardMonitor's pruning fallbacks (500 entries / 90d).
    @AppStorage("clipboardHistoryMaxCount") private var maxCount = 500
    @AppStorage("clipboardHistoryAgeDays") private var ageDays = 90

    @State private var storePath = ""

    private func activeStorePath() -> String {
        ClipboardMonitor.shared.store?.directory.path
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Easydict/Clipboard", isDirectory: true).path
            ?? ""
    }

    private func revealInFinder() {
        if let directory = ClipboardMonitor.shared.store?.directory {
            NSWorkspace.shared.open(directory)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = ClipboardMonitor.shared.store?.directory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            ClipboardMonitor.shared.changeStoreDirectory(to: url) { success in
                storePath = activeStorePath()
                if success {
                    UserDefaults.standard.set(url.path, forKey: ClipboardMonitor.storePathKey)
                    EZToast.showText(NSLocalizedString("setting.clipboard.moved", comment: ""))
                } else {
                    EZToast.showText(NSLocalizedString("setting.clipboard.move_failed", comment: ""))
                }
            }
        }
    }
}

#Preview {
    ClipboardTab()
}
