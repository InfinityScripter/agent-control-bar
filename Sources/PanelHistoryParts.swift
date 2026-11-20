import SwiftUI

// The pieces the Claude and Codex history lists draw the same way.

struct PanelHistorySearchField: View {
    let prompt: String
    let refreshLabel: String
    let query: Binding<String>
    let refreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: query)
                .textFieldStyle(.plain)
            if !query.wrappedValue.isEmpty {
                Button { query.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .help(refreshLabel)
                .accessibilityLabel(refreshLabel)
        }
        .font(.system(size: 11))
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct PanelHistoryLoading: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11))
        }
        .padding(.vertical, 12)
    }
}

struct PanelHistoryMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

/// Said under a list that is one page of a longer history, so an empty search is not read as
/// "this chat does not exist".
struct PanelHistoryPageNote: View {
    let count: Int

    var body: some View {
        Text("Search covers the \(count) most recent entries.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
