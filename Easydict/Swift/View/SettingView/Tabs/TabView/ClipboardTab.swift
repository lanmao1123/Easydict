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
                Picker("setting.clipboard.image_max_count", selection: $imageMaxCount) {
                    ForEach(Self.imageCountOptions, id: \.self) { count in
                        if count == 0 {
                            Text("clipboard_count_unlimited").tag(count)
                        } else {
                            Text("clipboard.count_option \(count)").tag(count)
                        }
                    }
                }
            } header: {
                Text("setting.sidebar.clipboard")
            } footer: {
                Text("setting.clipboard.limits_desc")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("setting.clipboard.storage")
                    Text(storePath)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let storageSize {
                        Text("setting.clipboard.usage \(storageSize)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if storageSize == nil || isMovingStore {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("setting.clipboard.storage"))
                        }
                        Spacer()
                        Button("setting.clipboard.reveal") {
                            revealInFinder()
                        }
                        Button("setting.clipboard.choose") {
                            chooseDirectory()
                        }
                        .disabled(isMovingStore)
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
        .onAppear {
            storePath = activeStorePath()
        }
        .task(id: storePath) {
            storageSize = nil
            guard !storePath.isEmpty else { return }
            let directory = URL(fileURLWithPath: storePath, isDirectory: true)
            let calculation = Task.detached(priority: .utility) {
                Self.directorySize(directory)
            }
            let total = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard !Task.isCancelled, let total else { return }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            storageSize = formatter.string(fromByteCount: total)
        }
    }

    // MARK: Private

    private static let imageCountOptions = [0, 50, 100, 200, 500]

    // Zero means unlimited: image and text history are both kept locally.
    @AppStorage("clipboardImageMaxCount") private var imageMaxCount = 0

    @State private var storePath = ""
    @State private var storageSize: String?
    @State private var isMovingStore = false

    /// Stops enumerating as soon as the tab disappears or its directory changes.
    private static func directorySize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

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
            isMovingStore = true
            ClipboardMonitor.shared.changeStoreDirectory(to: url) { success in
                isMovingStore = false
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
