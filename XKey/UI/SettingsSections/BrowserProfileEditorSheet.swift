//
//  BrowserProfileEditorSheet.swift
//  XKey
//
//  Add/edit sheet for user-registered browser profiles. Persists through
//  SharedBrowserRegistry only (see BrowserProfilesSection.swift for the list UI).
//

import SwiftUI
import AppKit

@available(macOS 13.0, *)
struct BrowserProfileEditorSheet: View {
    @ObservedObject var viewModel: BrowserProfilesViewModel
    let existingEntry: BrowserProfileEntry?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bundleIdentifier = ""
    @State private var profile: BrowserProfileKind = .chromium
    @State private var enabled = true

    @State private var showAdvanced = false
    @State private var identifierText = ""
    @State private var descriptionsText = ""
    @State private var domClassesText = ""

    @State private var showAppPicker = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private var isEditing: Bool { existingEntry != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Sửa trình duyệt" : "Thêm trình duyệt")
                    .font(.headline)
                Spacer()
                Button("Hủy") {
                    dismiss()
                }
                Button("Lưu") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox(label: Label("Ứng dụng", systemImage: "app.badge")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, height: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    TextField("Tên hiển thị", text: $name)
                                        .textFieldStyle(.roundedBorder)
                                    Text(bundleIdentifier.isEmpty ? " " : bundleIdentifier)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            Button("Chọn ứng dụng") {
                                showAppPicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox(label: Label("Kiểu nhận diện", systemImage: "square.stack.3d.up")) {
                        Picker("", selection: $profile) {
                            ForEach(BrowserProfileKind.allCases) { kind in
                                Text(kind.uiLabel).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .padding(.vertical, 4)
                    }

                    DisclosureGroup("Nhận diện thanh địa chỉ (nâng cao)", isExpanded: $showAdvanced) {
                        advancedFields
                            .padding(.top, 8)
                            .padding(.leading, 20)
                    }

                    if isEditing {
                        Toggle("Bật", isOn: $enabled)
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 420)
        .sheet(isPresented: $showAppPicker) {
            // RUNNING tab resolves the selected NSRunningApplication row's own
            // bundle id — the frontend identity the detector sees.
            AppPickerView { app in
                name = app.appName
                bundleIdentifier = app.bundleIdentifier
            }
        }
        .alert("Lỗi", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if let entry = existingEntry {
                name = entry.name
                bundleIdentifier = entry.bundleIdentifier
                profile = entry.profile
                enabled = entry.enabled
                identifierText = entry.signature?.identifier ?? ""
                descriptionsText = joined(entry.signature?.exactDescriptions)
                domClassesText = joined(entry.signature?.domClasses)
            }
        }
    }

    // Exact-match overrides; blank means "use the preset default" (nil).
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Để trống để dùng giá trị mặc định của kiểu.")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack {
                Text("AX Identifier:")
                    .frame(width: 120, alignment: .leading)
                    .font(.caption)
                TextField("VD: urlbar-input", text: $identifierText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top) {
                Text("AX Description:")
                    .frame(width: 120, alignment: .leading)
                    .font(.caption)
                TextField("Mỗi dòng một giá trị", text: $descriptionsText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }

            HStack(alignment: .top) {
                Text("DOM Classes:")
                    .frame(width: 120, alignment: .leading)
                    .font(.caption)
                TextField("Phân cách bằng dấu phẩy hoặc xuống dòng", text: $domClassesText,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedBundle = bundleIdentifier.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            presentError("Vui lòng nhập tên")
            return
        }
        guard !trimmedBundle.isEmpty else {
            presentError("Chọn ứng dụng trước khi lưu.")
            return
        }
        guard !viewModel.containsSameBundle(trimmedBundle, excluding: existingEntry?.id) else {
            presentError("Trình duyệt này đã có trong danh sách.")
            return
        }

        let signature = makeSignature()

        if var entry = existingEntry {
            // Preserve the original id so edits keep a stable identity.
            entry.name = trimmedName
            entry.bundleIdentifier = trimmedBundle
            entry.profile = profile
            entry.enabled = enabled
            entry.signature = signature
            do {
                try viewModel.update(entry)
            } catch {
                presentError(error.localizedDescription)
                return
            }
        } else {
            let entry = BrowserProfileEntry(
                name: trimmedName,
                bundleIdentifier: trimmedBundle,
                profile: profile,
                signature: signature
            )
            do {
                try viewModel.add(entry)
            } catch {
                presentError(error.localizedDescription)
                return
            }
        }
        dismiss()
    }

    /// Blank fields mean "use the preset's built-in values" (nil), never empty arrays.
    private func makeSignature() -> BrowserSignatureOverrides? {
        // Exact descriptions may themselves contain commas ("Address and search bar,
        // edit text"), so the description list is newline-split only. DOM class
        // names never contain separators, so comma or newline both work there.
        let descriptions = descriptionsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let domClasses = domClassesText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let identifier = identifierText.trimmingCharacters(in: .whitespaces)

        guard !descriptions.isEmpty || !domClasses.isEmpty || !identifier.isEmpty else {
            return nil
        }
        return BrowserSignatureOverrides(
            exactDescriptions: descriptions.isEmpty ? nil : descriptions,
            domClasses: domClasses.isEmpty ? nil : domClasses,
            identifier: identifier.isEmpty ? nil : identifier
        )
    }

    private func joined(_ values: [String]?) -> String {
        (values ?? []).joined(separator: "\n")
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }
}
