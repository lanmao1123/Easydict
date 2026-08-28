//
//  ClipboardHistoryView.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

// MARK: - ClipboardMoveDirection

enum ClipboardMoveDirection {
    case up
    case down
}

// MARK: - ClipboardTimeFilter

enum ClipboardTimeFilter: String, CaseIterable {
    case week
    case all

    // MARK: Internal

    var since: Date? {
        guard self == .week else { return nil }
        return Date().addingTimeInterval(-7 * 24 * 3600)
    }
}

// MARK: - ClipboardHistoryViewModel

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    // MARK: Lifecycle

    init() {}

    // MARK: Internal

    struct DayGroup: Identifiable {
        let title: String
        let entries: [ClipboardEntry]

        var id: String { title }
    }

    @Published var entries: [ClipboardEntry] = []

    @Published var selectedID: Int64?

    @Published var searchText = "" {
        didSet {
            if oldValue != searchText { load() }
        }
    }

    @Published var kindFilter: ClipboardKindFilter = .all {
        didSet {
            if oldValue != kindFilter { load() }
        }
    }

    @Published var timeFilter: ClipboardTimeFilter = .week {
        didSet {
            if oldValue != timeFilter { load() }
        }
    }

    var selectedEntry: ClipboardEntry? {
        entries.first { $0.id == selectedID }
    }

    /// Day-grouped rows, newest first; titles are 今天 / 昨天 / YYYY-MM-DD.
    var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        var buckets: [(key: String, day: Date, entries: [ClipboardEntry])] = []
        for entry in entries {
            let startOfDay = calendar.startOfDay(for: entry.createdAt)
            if let last = buckets.last, last.day == startOfDay {
                buckets[buckets.count - 1].entries.append(entry)
            } else {
                buckets.append((Self.dayTitle(for: entry.createdAt), startOfDay, [entry]))
            }
        }
        return buckets.map { DayGroup(title: $0.key, entries: $0.entries) }
    }

    func load() {
        guard let store = ClipboardMonitor.shared.store else {
            entries = []
            return
        }

        do {
            let keyword = searchText.trimmingCharacters(in: .whitespaces)
            entries = try store.entries(
                since: timeFilter.since,
                keyword: keyword.isEmpty ? nil : keyword,
                kind: kindFilter
            )
        } catch {
            entries = []
        }

        if !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }

    func moveSelection(_ direction: ClipboardMoveDirection) {
        guard !entries.isEmpty else { return }
        guard let index = entries.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = entries.first?.id
            return
        }
        let next: Int
        switch direction {
        case .up: next = max(index - 1, 0)
        case .down: next = min(index + 1, entries.count - 1)
        @unknown default: return
        }
        selectedID = entries[next].id
    }

    func selectIndex(_ oneBased: Int) {
        guard entries.indices.contains(oneBased - 1) else { return }
        selectedID = entries[oneBased - 1].id
        confirmSelection()
    }

    func confirmSelection() {
        guard let entry = selectedEntry else { return }
        ClipboardManager.shared.select(entry)
    }

    func deleteSelected() {
        guard let entry = selectedEntry else { return }
        if ClipboardManager.shared.delete(entry) {
            load()
        }
    }

    // MARK: Private

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "clipboard_day_today")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "clipboard_day_yesterday")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - ClipboardHistoryView

/// Spotlight-style two-pane surface: search + filters on top, day-grouped
/// list on the left, preview of the selection on the right, shortcut hints
/// at the bottom.
struct ClipboardHistoryView: View {
    // MARK: Lifecycle

    init(viewModel: ClipboardHistoryViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Internal

    @ObservedObject var viewModel: ClipboardHistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footerHints
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                /*
                 The panel floats over arbitrary content; a hairline border in
                 the adaptive label color keeps the edge readable on white
                 pages (light mode) and dark pages (dark mode) alike.
                 */
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.30), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.30), radius: 18, y: 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Private

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "clipboard_filter_placeholder"),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))

            Picker("time", selection: $viewModel.timeFilter) {
                Text(String(localized: "clipboard_time_week")).tag(ClipboardTimeFilter.week)
                Text(String(localized: "clipboard_time_all")).tag(ClipboardTimeFilter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            Picker("kind", selection: $viewModel.kindFilter) {
                Text(String(localized: "clipboard_type_all")).tag(ClipboardKindFilter.all)
                Text(String(localized: "clipboard_type_text")).tag(ClipboardKindFilter.text)
                Text(String(localized: "clipboard_type_image")).tag(ClipboardKindFilter.image)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 86)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "clipboard_empty"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                entryList
                Divider()
                previewPane
                    .frame(minWidth: 300, maxWidth: 380)
            }
        }
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.groupedEntries) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                ClipboardRowView(
                                    entry: entry,
                                    isSelected: entry.id == viewModel.selectedID
                                )
                                .onTapGesture { viewModel.selectedID = entry.id }
                                .contextMenu {
                                    Button(String(localized: "clipboard_delete_item")) {
                                        viewModel.selectedID = entry.id
                                        viewModel.deleteSelected()
                                    }
                                }
                                .id(entry.id)
                            }
                        } header: {
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.selectedID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let entry = viewModel.selectedEntry {
            ClipboardPreviewPane(entry: entry)
        } else {
            Color.clear
        }
    }

    private var footerHints: some View {
        HStack(spacing: 14) {
            hintBadge("return", text: String(localized: "clipboard_hint_paste"))
            hintBadge("delete.forward", text: String(localized: "clipboard_hint_delete"))
            hintBadge("escape", text: String(localized: "clipboard_hint_close"))
            Spacer()
            if !ClipboardAutoPaster.isAccessibilityGranted {
                Button(String(localized: "clipboard_enable_autopaste")) {
                    ClipboardAutoPaster.openAccessibilitySettings()
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hintBadge(_ symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - ClipboardRowView

private struct ClipboardRowView: View {
    // MARK: Internal

    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 52, height: 38)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let app = entry.sourceApp {
                        Image(systemName: "app")
                            .font(.system(size: 9))
                        Text(app)
                            .font(.system(size: 11))
                    }
                    Spacer()
                    Text(Self.relativeTime.localizedString(for: entry.createdAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: Private

    private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var rowTitle: String {
        if !entry.preview.isEmpty { return entry.preview }
        return entry.kind == .image
            ? ClipboardStore.imagePreviewTitle(width: entry.pixelWidth, height: entry.pixelHeight)
            : ""
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .image,
           let url = ClipboardMonitor.shared.store?.thumbImageURL(for: entry)
           ?? ClipboardMonitor.shared.store?.imageURL(for: entry),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: entry.kind == .image ? "photo" : "doc.text")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ClipboardPreviewPane

private struct ClipboardPreviewPane: View {
    // MARK: Internal

    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            infoList
                .padding(12)
        }
    }

    // MARK: Private

    private static let absoluteTime: DateFormatter = {
        let formatter = DateFormatter()
        // Minute precision: seconds add noise without value in a history list.
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .text:
            /*
             A plain NSTextView, not SwiftUI Text: users need to select a few
             words out of the preview to copy, and text selection inside this
             key-window panel proved unreliable with the SwiftUI wrapper.
             The fill frame keeps text anchored at the top of the pane.
             */
            SelectableTextView(text: entry.text ?? entry.preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        case .image:
            if let url = ClipboardMonitor.shared.store?.imageURL(for: entry),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            } else {
                Text(String(localized: "clipboard_image_missing"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var infoList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.kind == .image, let w = entry.pixelWidth, let h = entry.pixelHeight {
                infoRow(String(localized: "clipboard_info_dimensions"), value: "\(w)×\(h)")
            }
            infoRow(
                String(localized: "clipboard_info_size"),
                value: ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
            )
            if let app = entry.sourceApp {
                infoRow(String(localized: "clipboard_info_source"), value: app)
            }
            infoRow(
                String(localized: "clipboard_info_time"),
                value: Self.absoluteTime.string(from: entry.createdAt)
            )
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
        }
    }
}

// MARK: - SelectableTextView

/// Read-only AppKit text view for the preview pane: natively selectable so
/// users can highlight and copy individual words out of a history entry.
private struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        /*
         Bare NSTextView shrinks to its content height with the bottom-left
         origin fixed, so it drifts to the bottom of the pane. As a scroll
         view's document it stays anchored to the top and long text scrolls.
         */
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
