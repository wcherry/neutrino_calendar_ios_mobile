import SwiftUI

/// A task's tags in the task editor: the chosen ones as removable chips, a field to type one, and
/// under it, while the field has focus, the tags already in use that match what is typed.
///
/// The suggestions narrow the list rather than restrict it: Return, a space or a comma adds
/// whatever was typed, so a brand-new tag is as easy as an existing one. Meant to sit in a `Form`
/// section; the suggestions are its rows.
struct TagField: View {
    @Binding var tags: [String]
    /// What is typed but not yet a chip. The editor's Save adds it too, so nothing typed is lost.
    @Binding var draft: String
    /// Every tag in use, in the order to offer them.
    let known: [String]

    @FocusState private var focused: Bool

    /// Enough to pick from without pushing the rest of the form off screen.
    private static let maxSuggestions = 8

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    chip(tag)
                }
            }
            .padding(.vertical, 2)
        }

        TextField("Add a tag", text: $draft)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit {
                commit(draft)
                // Return adds the tag and leaves the field open for the next one.
                focused = true
            }
            .onChange(of: draft) { text in
                // A separator finishes the tag before it, as on the web where tags are split on
                // spaces and commas.
                guard let last = text.lastIndex(where: { $0.isWhitespace || $0 == "," }) else { return }
                commit(String(text[..<last]))
                draft = String(text[text.index(after: last)...])
            }

        if focused {
            ForEach(suggestions, id: \.self) { tag in
                Button { add(tag) } label: {
                    Label("#\(tag)", systemImage: "tag")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Adds this tag")
            }
            if let new = newTag {
                Button { add(new) } label: {
                    Label("Add \u{201C}#\(new)\u{201D}", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(tag)")
        }
        .font(.subheadline)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var suggestions: [String] {
        Array(TaskTags.suggestions(for: draft, in: known, excluding: tags).prefix(Self.maxSuggestions))
    }

    /// The typed tag, when it is neither chosen already nor one of the suggestions.
    private var newTag: String? {
        guard let typed = TaskTags.split(draft).last,
              !tags.contains(typed), !suggestions.contains(typed) else { return nil }
        return typed
    }

    private func add(_ tag: String) {
        if !tags.contains(tag) { tags.append(tag) }
        draft = ""
        focused = true
    }

    private func commit(_ text: String) {
        for tag in TaskTags.split(text) where !tags.contains(tag) {
            tags.append(tag)
        }
        draft = ""
    }
}

// MARK: - FlowLayout

/// Lays its subviews out left to right, wrapping onto a new line when one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
