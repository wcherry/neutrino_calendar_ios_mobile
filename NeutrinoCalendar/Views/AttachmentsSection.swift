import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import NeutrinoCore

// MARK: - AttachmentOwner

/// What an attachment hangs off, an event or a task: how to list, add and remove its attachments.
struct AttachmentOwner {
    /// Changes when the owner does, to reload.
    let id: String
    let load: () async throws -> [Attachment]
    let add: (CreateAttachmentRequest) async throws -> Attachment
    let delete: (Attachment) async throws -> Void
}

// MARK: - AttachmentsSection

/// The attachments of an event or a task, as a form section: notes, and Drive files that open in
/// Quick Look (decrypted on the phone) or in the Neutrino app that owns their format. New files
/// come from Drive, Photos or Files; the last two are encrypted and put in Drive first.
struct AttachmentsSection: View {
    let owner: AttachmentOwner
    @ObservedObject var presenter: AttachmentsPresenter

    @EnvironmentObject private var files: AttachmentFiles

    @State private var attachments: [Attachment] = []
    @State private var state: LoadState = .loading
    @State private var error: String?
    @State private var newNote = ""
    /// The attachment being fetched for preview, to show progress on its row.
    @State private var opening: String?
    @State private var uploading: String?

    private enum LoadState: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        Section {
            switch state {
            case .loading:
                ProgressView()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .loaded:
                ForEach(attachments) { attachment in
                    row(attachment)
                        .swipeActions {
                            Button(role: .destructive) { Task { await remove(attachment) } } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                if let uploading {
                    HStack {
                        ProgressView()
                        Text("Adding \(uploading)…").foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                addMenu
                TextField("Add a note", text: $newNote)
                    .submitLabel(.done)
                    .onSubmit { Task { await addNote() } }
            }
        } header: {
            Text("Attachments")
        }
        .task(id: owner.id) {
            presenter.onDriveFile = { file in Task { await attach(file) } }
            presenter.onPhoto = { item in Task { await upload(item) } }
            presenter.onFile = { url in Task { await upload(url) } }
            presenter.onPreviewInstead = { file in Task { await open(file) } }
            await load()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ attachment: Attachment) -> some View {
        if let fileID = attachment.fileId {
            Button {
                Task { await open(fileID: fileID) }
            } label: {
                HStack {
                    Label(attachment.name ?? "Drive file", systemImage: Self.symbol(for: attachment.name))
                        .foregroundStyle(.primary)
                    Spacer()
                    if opening == fileID { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .disabled(opening != nil)
            .contextMenu {
                Button { Task { await open(fileID: fileID) } } label: {
                    Label("Preview", systemImage: "eye")
                }
                Button { Task { await openInApp(fileID: fileID) } } label: {
                    Label("Open in Neutrino", systemImage: "arrow.up.forward.app")
                }
            }
            .accessibilityIdentifier("attachment-\(attachment.name ?? fileID)")
        } else {
            Label(attachment.note ?? "", systemImage: "note.text")
                .textSelection(.enabled)
        }
    }

    private var addMenu: some View {
        Menu {
            Button { presenter.pickingFromDrive = true } label: { Label("From Drive", systemImage: "externaldrive") }
            Button { presenter.pickingPhoto = true } label: { Label("Photo or Video", systemImage: "photo") }
            Button { presenter.importingFile = true } label: { Label("From Files", systemImage: "folder") }
        } label: {
            Label("Add File", systemImage: "paperclip")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .disabled(uploading != nil)
    }

    // MARK: - Loading and changes

    private func load() async {
        state = .loading
        do {
            attachments = try await owner.load()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func addNote() async {
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        await perform {
            attachments.append(try await owner.add(.note(note)))
            newNote = ""
        }
    }

    private func attach(_ file: DriveFile) async {
        await perform { attachments.append(try await owner.add(.file(id: file.id, name: file.name))) }
    }

    private func remove(_ attachment: Attachment) async {
        await perform {
            try await owner.delete(attachment)
            attachments.removeAll { $0.id == attachment.id }
        }
    }

    // MARK: - Opening

    private func open(fileID: String) async {
        opening = fileID
        defer { opening = nil }
        await perform { await open(try await files.metadata(fileID: fileID)) }
    }

    private func open(_ file: DriveFile) async {
        opening = file.id
        defer { opening = nil }
        await perform { presenter.preview = try await files.localCopy(of: file) }
    }

    /// Hands the file to the Neutrino app that owns its format: Docs, Sheets, Slides, Notes, or
    /// Drive for anything else. Only the file id travels; the app fetches the file itself.
    private func openInApp(fileID: String) async {
        await perform {
            let file = try await files.metadata(fileID: fileID)
            let kind = NeutrinoAppLink.kind(forMIME: file.mimeType) ?? .file
            guard let url = NeutrinoAppLink.url(kind: kind, fileID: file.id, contentVersion: file.contentVersion) else { return }
            // Universal links only: without the app, Safari would open the web app, which is not
            // what "Open in Neutrino Docs" promised.
            let opened = await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
            if !opened { presenter.notInstalled = .init(appName: kind.appName, file: file) }
        }
    }

    // MARK: - Uploading

    private func upload(_ item: PhotosPickerItem) async {
        let type = item.supportedContentTypes.first ?? .jpeg
        let name = "Photo \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
        await upload(name: name, type: type) {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
    }

    private func upload(_ url: URL) async {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        await upload(name: url.lastPathComponent, type: type) {
            // A file picked from Files is outside the sandbox until this says otherwise.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }
    }

    private func upload(name: String, type: UTType, data: () async throws -> Data) async {
        uploading = name
        defer { uploading = nil }
        await perform {
            let mime = type.preferredMIMEType ?? "application/octet-stream"
            let file = try await files.upload(try await data(), name: name, mimeType: mime)
            attachments.append(try await owner.add(.file(id: file.id, name: file.name)))
        }
    }

    // MARK: - Helpers

    private func perform(_ work: () async throws -> Void) async {
        error = nil
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func symbol(for name: String?) -> String {
        guard let ext = name.map({ ($0 as NSString).pathExtension }), !ext.isEmpty,
              let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }
}

// MARK: - AttachmentsPresenter

/// What `AttachmentsSection` has asked to show: a picker, a preview, an alert. Presented by the
/// form around the section (`attachmentPresentations`), because a sheet attached to a section
/// inside a `List` or `Form` doesn't reliably present.
@MainActor
final class AttachmentsPresenter: ObservableObject {
    @Published var pickingFromDrive = false
    @Published var pickingPhoto = false
    @Published var photo: PhotosPickerItem?
    @Published var importingFile = false
    @Published var preview: URL?
    @Published var notInstalled: NotInstalled?

    /// "Neutrino Docs isn't installed", with the file to preview instead.
    struct NotInstalled: Identifiable {
        let appName: String
        let file: DriveFile
        var id: String { file.id }
    }

    // Set by the section: what to do with what was picked.
    var onDriveFile: (DriveFile) -> Void = { _ in }
    var onPhoto: (PhotosPickerItem) -> Void = { _ in }
    var onFile: (URL) -> Void = { _ in }
    var onPreviewInstead: (DriveFile) -> Void = { _ in }
}

private struct AttachmentPresentations: ViewModifier {
    @ObservedObject var presenter: AttachmentsPresenter

    func body(content: Content) -> some View {
        content
            .quickLookPreview($presenter.preview)
            .sheet(isPresented: $presenter.pickingFromDrive) {
                DriveFilePickerView { presenter.onDriveFile($0) }
            }
            .photosPicker(isPresented: $presenter.pickingPhoto, selection: $presenter.photo,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: presenter.photo) { item in
                guard let item else { return }
                presenter.photo = nil
                presenter.onPhoto(item)
            }
            .fileImporter(isPresented: $presenter.importingFile, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { presenter.onFile(url) }
            }
            .alert(item: $presenter.notInstalled) { missing in
                Alert(title: Text("\(missing.appName) Isn't Installed"),
                      message: Text("Preview the file here instead?"),
                      primaryButton: .default(Text("Preview")) { presenter.onPreviewInstead(missing.file) },
                      secondaryButton: .cancel())
            }
    }
}

extension View {
    /// Presents what an `AttachmentsSection` in this form asks for.
    func attachmentPresentations(_ presenter: AttachmentsPresenter) -> some View {
        modifier(AttachmentPresentations(presenter: presenter))
    }
}
