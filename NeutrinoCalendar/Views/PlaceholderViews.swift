import SwiftUI

// Empty states for the Epic 1 shell. Each one is replaced wholesale by the epic it names in
// agent_docs/road_map.md, so they stay deliberately thin.

struct TasksView: View {
    var body: some View {
        EmptyStateView(
            systemImage: "checklist",
            title: "No Tasks",
            message: "Your task lists will appear here."
        )
        .navigationTitle("Tasks")
    }
}

/// `ContentUnavailableView` is iOS 17+, and the deployment target is 16, so this is a small
/// stand-in with the same layout.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NavigationStack { TasksView() }
}
