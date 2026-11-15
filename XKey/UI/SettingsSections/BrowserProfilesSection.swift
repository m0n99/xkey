//
//  BrowserProfilesSection.swift
//  XKey
//
//  User-registered browser profiles in Advanced settings.
//  All reads/writes go through SharedBrowserRegistry — persistence and engine
//  invalidation belong to the registry; this view never touches UserDefaults
//  or Preferences fields directly.
//

import SwiftUI
import AppKit

// MARK: - Profile Preset Labels

@available(macOS 13.0, *)
extension BrowserProfileKind {
    var uiLabel: String {
        switch self {
        case .chromium: return "Chrome / Chromium"
        case .firefox: return "Firefox"
        case .firefoxAx: return "Firefox (AX / Zen)"
        case .safari: return "Safari"
        case .commandBar: return "Arc"
        case .commandBarAx: return "Dia (AX)"
        case .opera: return "Opera"
        }
    }

    var badgeColor: Color {
        switch self {
        case .chromium: return .blue
        case .firefox, .firefoxAx: return .orange
        case .safari: return .teal
        case .commandBar, .commandBarAx: return .purple
        case .opera: return .red
        }
    }
}

// MARK: - View Model

@available(macOS 13.0, *)
final class BrowserProfilesViewModel: ObservableObject {
    @Published private(set) var entries: [BrowserProfileEntry] = []

    private var reloadObserver: NSObjectProtocol?

    init() {
        reloadObserver = NotificationCenter.default.addObserver(
            forName: SharedBrowserRegistry.didReloadNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer = reloadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-reads the registry's in-memory custom entries. Never triggers IO.
    func refresh() {
        entries = SharedBrowserRegistry.shared.customEntries
    }

    /// Case-insensitive bundle identity, mirroring the registry's merge rule.
    func containsSameBundle(_ bundleIdentifier: String, excluding id: UUID? = nil) -> Bool {
        entries.contains {
            $0.id != id
                && $0.bundleIdentifier.compare(bundleIdentifier, options: .caseInsensitive) == .orderedSame
        }
    }

    func add(_ entry: BrowserProfileEntry) throws {
        try SharedBrowserRegistry.shared.add(entry)
    }

    func update(_ entry: BrowserProfileEntry) throws {
        try SharedBrowserRegistry.shared.update(entry)
    }

    func remove(id: UUID) throws {
        try SharedBrowserRegistry.shared.remove(id: id)
    }

    func toggle(_ entry: BrowserProfileEntry, enabled: Bool) throws {
        var updated = entry
        updated.enabled = enabled
        try SharedBrowserRegistry.shared.update(updated)
    }
}

// MARK: - Section

@available(macOS 13.0, *)
struct BrowserProfilesSection: View {
    @StateObject private var viewModel = BrowserProfilesViewModel()
    @State private var showAddSheet = false
    @State private var editingEntry: BrowserProfileEntry?
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        SettingsGroup(title: "Trình duyệt") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()

                    Button("Thêm trình duyệt", systemImage: "plus") {
                        showAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if viewModel.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("Chưa có trình duyệt tự thêm")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Trình duyệt mặc định vẫn được hỗ trợ.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    List {
                        ForEach(viewModel.entries) { entry in
                            BrowserProfileRow(entry: entry) {
                                editingEntry = entry
                            } onDelete: {
                                remove(entry)
                            } onToggle: { enabled in
                                toggle(entry, enabled: enabled)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: min(260, max(60, CGFloat(viewModel.entries.count) * 62)), maxHeight: 260)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            BrowserProfileEditorSheet(viewModel: viewModel, existingEntry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            BrowserProfileEditorSheet(viewModel: viewModel, existingEntry: entry)
        }
        .alert("Lỗi", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            viewModel.refresh()
        }
    }

    private func remove(_ entry: BrowserProfileEntry) {
        do {
            try viewModel.remove(id: entry.id)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func toggle(_ entry: BrowserProfileEntry, enabled: Bool) {
        do {
            try viewModel.toggle(entry, enabled: enabled)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Row

@available(macOS 13.0, *)
struct BrowserProfileRow: View {
    let entry: BrowserProfileEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovered = false
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .fontWeight(.medium)
                    .strikethrough(!entry.enabled)
                Text(entry.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            BehaviorBadge(text: entry.profile.uiLabel, color: entry.profile.badgeColor)

            Spacer()

            Toggle("Bật", isOn: Binding(
                get: { entry.enabled },
                set: onToggle
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Bật")

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.5)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? Color.gray.opacity(0.1) : Color.gray.opacity(0.03))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onAppear {
            loadAppIcon()
        }
    }

    private func loadAppIcon() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    BrowserProfilesSection()
        .padding()
        .frame(width: 700)
}
