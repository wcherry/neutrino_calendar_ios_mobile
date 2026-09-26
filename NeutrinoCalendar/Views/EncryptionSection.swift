import SwiftUI
import NeutrinoCrypto
import NeutrinoUI

// MARK: - EncryptionSection

/// Settings › Encryption: whether this iPhone holds the account's encryption key, and the ways to
/// bring it here when it doesn't.
///
/// Calendar's own events aren't encrypted, but their attachments are Drive files, which are. The
/// key is the keyring every Neutrino app on the device shares, so if Drive, Docs or Notes already
/// has it, so does Calendar and there is nothing to do.
///
/// The screens it opens are presented by the list around it (`encryptionFlows`): a sheet
/// attached to a section inside a `List` doesn't reliably present.
struct EncryptionSection: View {
    @Binding var flow: EncryptionFlow?
    /// Bumped when a flow closes, to read the key state again.
    let revision: Int

    @EnvironmentObject private var provisioning: KeyProvisioningService
    @State private var hasKey = DeviceKeys.hasKey
    @State private var canSetUp = false

    var body: some View {
        Section {
            if hasKey {
                Label("This iPhone has your encryption key", systemImage: "checkmark.shield")
            } else {
                Label("No encryption key on this iPhone", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                if canSetUp {
                    Button { flow = .setUp } label: { Label("Set Up Encryption", systemImage: "key") }
                }
                Button { flow = .pair } label: {
                    Label("Pair With Another Device", systemImage: "qrcode.viewfinder")
                }
                Button { flow = .restore } label: {
                    Label("Restore From Recovery Kit", systemImage: "text.book.closed")
                }
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text(hasKey
                 ? "Attached Drive files are decrypted on this iPhone, and new ones are encrypted before they're uploaded. The key is shared with the other Neutrino apps here and never leaves the device."
                 : "Attached Drive files are end-to-end encrypted. To open or add them here, bring your key from a device that has it. If another Neutrino app on this iPhone has it, Calendar uses it too.")
        }
        .task(id: revision) {
            hasKey = DeviceKeys.hasKey
            // First-time setup is only for an account with no key anywhere; any other needs its
            // key brought here instead.
            canSetUp = hasKey ? false : await provisioning.canProvision()
        }
    }
}

// MARK: - EncryptionFlow

enum EncryptionFlow: String, Identifiable {
    case setUp, pair, restore
    var id: String { rawValue }
}

extension View {
    /// Presents the flow `EncryptionSection` asked for, and calls `onClose` when it's done.
    func encryptionFlows(_ flow: Binding<EncryptionFlow?>, provisioning: KeyProvisioningService,
                         onClose: @escaping () -> Void) -> some View {
        let sheet = Binding<EncryptionFlow?>(
            get: { flow.wrappedValue == .setUp ? nil : flow.wrappedValue },
            set: { if $0 == nil { flow.wrappedValue = nil } })
        let cover = Binding<EncryptionFlow?>(
            get: { flow.wrappedValue == .setUp ? .setUp : nil },
            set: { if $0 == nil { flow.wrappedValue = nil } })
        let isShown = Binding<Bool>(get: { flow.wrappedValue != nil },
                                    set: { if !$0 { flow.wrappedValue = nil } })
        return self
            .sheet(item: sheet, onDismiss: onClose) { shown in
                switch shown {
                case .pair:
                    DevicePairingView(isPresented: isShown) { onClose() }
                default:
                    RecoveryKitRestoreView(service: provisioning, isPresented: isShown) { onClose() }
                }
            }
            .fullScreenCover(item: cover, onDismiss: onClose) { _ in
                EncryptionSetupView(service: provisioning) { flow.wrappedValue = nil }
            }
    }
}
