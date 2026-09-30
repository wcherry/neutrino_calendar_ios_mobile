import SwiftUI

/// "This Event / This and Following Events / All Events": the question asked before an edit or
/// delete of a repeating event or reminder, as the iPhone's Calendar asks it, from an action sheet.
extension View {

    func recurrenceScopeDialog(_ title: String, kind: RecurrenceScope.Kind, destructive: Bool = false,
                               isPresented: Binding<Bool>,
                               choose: @escaping (RecurrenceScope) -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            RecurrenceScopeButtons(kind: kind, destructive: destructive, choose: choose)
        } message: {
            Text("This is a repeating \(kind.noun.lowercased()).")
        }
    }

    /// For a question about one of several things, a reminder in a list: shown while `item` is
    /// set, and answered with it.
    func recurrenceScopeDialog<Item>(_ title: String, kind: RecurrenceScope.Kind, destructive: Bool = false,
                                     item: Binding<Item?>,
                                     choose: @escaping (Item, RecurrenceScope) -> Void) -> some View {
        confirmationDialog(title,
                           isPresented: Binding(get: { item.wrappedValue != nil },
                                                set: { if !$0 { item.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: item.wrappedValue) { value in
            RecurrenceScopeButtons(kind: kind, destructive: destructive) { choose(value, $0) }
        } message: { _ in
            Text("This is a repeating \(kind.noun.lowercased()).")
        }
    }
}

private struct RecurrenceScopeButtons: View {
    let kind: RecurrenceScope.Kind
    let destructive: Bool
    let choose: (RecurrenceScope) -> Void

    var body: some View {
        ForEach(RecurrenceScope.allCases) { scope in
            Button(scope.label(kind), role: destructive ? .destructive : nil) { choose(scope) }
        }
        Button("Cancel", role: .cancel) {}
    }
}
