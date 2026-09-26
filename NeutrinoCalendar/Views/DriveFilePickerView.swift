import SwiftUI
import NeutrinoAuth

// MARK: - DriveFilePickerView

/// Browses the user's Drive and picks a file: the web's `DriveFilePicker`. Folders open in
/// place; the search field filters the folder on screen by name.
struct DriveFilePickerView: View {
    let onPick: (DriveFile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let root = AccessToken.currentUserID() {
                    DriveFolderList(folderID: root, title: "My Drive", onPick: pick)
                } else {
                    Text("Sign in again to browse Drive.").foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pick(_ file: DriveFile) {
        onPick(file)
        dismiss()
    }
}

// MARK: - DriveFolderList

private struct DriveFolderList: View {
    let folderID: String
    let title: String
    let onPick: (DriveFile) -> Void

    @EnvironmentObject private var files: AttachmentFiles
    @State private var contents: DriveFolderContents?
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        List {
            if let contents {
                let folders = contents.folders.filter(matches).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let files = contents.files.filter(matches).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                ForEach(folders) { folder in
                    NavigationLink {
                        DriveFolderList(folderID: folder.id, title: folder.name, onPick: onPick)
                    } label: {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                }
                ForEach(files) { file in
                    Button { onPick(file) } label: {
                        HStack {
                            Label(file.name, systemImage: AttachmentsSection.symbol(for: file.name))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if folders.isEmpty && files.isEmpty {
                    Text(search.isEmpty ? "This folder is empty." : "No matches.")
                        .foregroundStyle(.secondary)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter by name")
        .task(id: folderID) { await load() }
        .refreshable { await load() }
    }

    private func matches(_ folder: DriveFolder) -> Bool { matches(folder.name) }
    private func matches(_ file: DriveFile) -> Bool { matches(file.name) }
    private func matches(_ name: String) -> Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private func load() async {
        do {
            contents = try await files.folder(id: folderID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
